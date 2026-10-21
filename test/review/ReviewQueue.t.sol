// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "../Base.t.sol";
import "../../src/VaultTypes.sol";

/// @dev The submission queue + top-ups during review + withdrawing shares + the task deadline.
///      Check per contributor: if the task was accepted, he loses exactly his active share at the moment of the
///      accepted submission and gets everything else back; if not accepted, he gets back everything he put in.
/// forge-config: default.isolate = false
contract ReviewQueue is Base {
    uint8 constant REJECT = 2;

    struct Case {
        uint8 ops; // number of steps
        uint256 seed;
    }

    function testFuzz_QueueContributorsGetExactlyTheirs(Case memory c) public {
        uint256 steps = bound(c.ops, 4, 24);
        address[3] memory cs = [author, alice, bob];
        uint256[3] memory paidIn;
        uint256 t = _createWithDeadline(author, address(usdc), 50e6, uint64(_now() + 10 days));
        paidIn[0] = 50e6;
        uint256[3] memory before = [usdc.balanceOf(author) + 50e6, usdc.balanceOf(alice), usdc.balanceOf(bob)];
        address[3] memory doers = [doer, doer2, doer3];
        uint256 rnd = c.seed;
        for (uint256 i; i < steps; ++i) {
            rnd = uint256(keccak256(abi.encode(rnd, i)));
            uint256 op = rnd % 6;
            // the timers are played out before the state snapshot: otherwise the task may already be accepted
            // or expired by its timer, and the step would decide on a stale snapshot (a top-up into a task its
            // timer already decided reverts TaskNotOpen)
            vault.poke(t);
            Task memory tk = vault.getTask(t);
            if (tk.status != TaskStatus.Open) break;
            if (op == 0) {
                uint256 k = (rnd >> 8) % 3;
                uint256 amt = 1e6 + (rnd >> 16) % 100e6;
                // there is no cap on the reward: only the deadline gates it
                if (_now() < tk.deadline) {
                    _topUp(cs[k], t, amt);
                    paidIn[k] += amt;
                }
            } else if (op == 1) {
                // the reward is locked until the deadline: an open task returns nothing, to
                // nobody, idle or busy, reward or top-up (the timers were played just above)
                uint256 k = (rnd >> 8) % 3;
                vm.prank(cs[k]);
                vm.expectRevert(TaskNotOpen.selector);
                vault.withdrawContribution(t);
            } else if (op == 2) {
                if (_now() < tk.deadline && tk.pot != 0) {
                    vm.prank(doers[(rnd >> 8) % 3]);
                    try vault.submit(t, "https://x.com/d/status/1", _noEvidence(), 0, type(uint256).max, _noSwap()) {}
                        catch {}
                }
            } else if (op == 3) {
                // the active submission is disputed and the NFT rejects it
                if (tk.activeSub != 0 && _phase(tk.activeSub) == Phase.Review && _sub(tk.activeSub).windowEnd > _now())
                {
                    uint256 s = tk.activeSub;
                    _dispute(dave, s);
                    _vote(s, 0, REJECT, 0, 100);
                    _warp(24 hours + 1);
                    vault.poke(t);
                }
            } else if (op == 4) {
                _warp(1 days + (rnd >> 8) % 2 days);
                vault.poke(t);
            } else {
                _warp(1 hours);
            }
        }
        // play it out: whatever is left in review is accepted by its window; then withdraw
        uint256 acceptedSub;
        _claimEverythingAndCheck();
        Task memory fin = vault.getTask(t);
        if (fin.status == TaskStatus.Completed) {
            for (uint256 s = 1; s <= vault.submissionCount(); ++s) {
                if (_sub(s).outcome == Outcome.Accepted) acceptedSub = s;
            }
        }
        uint256 reward = acceptedSub != 0 ? _sub(acceptedSub).reward : 0;
        uint256 lost;
        for (uint256 k; k < 3; ++k) {
            uint256 after_ = usdc.balanceOf(cs[k]);
            uint256 start = before[k]; // the balance before the first contribution (for the author: before creating the task)
            assertGe(after_, start - paidIn[k], "contributor lost more than he put in");
            assertLe(after_, start, "contributor got more than he put in");
            lost += start - after_;
        }
        // the contributors together lost exactly the accepted reward (or nothing)
        assertEq(lost, reward, "contributors lost != accepted reward");
    }
}
