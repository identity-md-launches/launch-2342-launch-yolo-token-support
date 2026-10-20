// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./Base.t.sol";

/// @dev Fuzzed end-to-end cases. Whatever the path, after everyone claims: the vault holds exactly what it owes,
///      and owes nothing after the treasury is swept. IMD only left to the swarm payee and the burner.
/// forge-config: default.isolate = false
contract ScenariosTest is Base {
    bool internal callerSidesDoer;

    struct Case {
        uint8 currency; // 0 ETH, 1 USDC, 2 IMD, 3 YOLO
        uint256 amount;
        bool topUp;
        uint8 disputers; // 0..1 (one dispute, one disputer)
        uint8 acceptVotes; // 0..120 (voter0)
        uint8 rejectVotes; // 0..30 (voter1 + voter2)
        uint8 swarm; // first swarm call: 0 true, 1 false, 2 silent, 3 nobody calls
        uint8 swarm2; // call after a silence: same coding
        uint8 swarm3; // the third and last call (MAX_SWARM_CALLS) after a second silence: same coding
        uint8 lockWeeks; // 0 = no doer lock; 1..52: the doer locks `lockAmount` YOLO for that many weeks before
        uint256 lockAmount; //   his submission (power amount x weeks / 52; may end before the payout, may be < R / 10)
        bool callerSidesDoer; // side of a NoDecision swarm caller
        uint32 basefeeGwei;
        uint16 intakePriceCenti; // 10..100 => 0.1..1 IMD
        uint16 priceChangeCenti; // price at the time of the second call
    }

    function testFuzz_Scenario(Case memory c) public {
        c.currency = uint8(bound(c.currency, 0, 3));
        // the minimum is a dev parameter in the reward's own currency, with no USD floor;
        // no cap on the reward, bounded here only by _fund's balances
        if (c.currency == 0) c.amount = bound(c.amount, 0.002e18, 0.2 ether);
        else if (c.currency == 1) c.amount = bound(c.amount, 5e6, 600_000e6);
        else if (c.currency == 2) c.amount = bound(c.amount, 1e18, 6_000e18);
        else c.amount = bound(c.amount, 1_000e18, 600_000_000e18);
        c.disputers = uint8(bound(c.disputers, 0, 1));
        c.acceptVotes = uint8(bound(c.acceptVotes, 0, 120));
        c.rejectVotes = uint8(bound(c.rejectVotes, 0, 30));
        c.swarm = uint8(bound(c.swarm, 0, 3));
        c.swarm2 = uint8(bound(c.swarm2, 0, 3));
        c.swarm3 = uint8(bound(c.swarm3, 0, 3));
        c.basefeeGwei = uint32(bound(c.basefeeGwei, 0, 200));
        c.intakePriceCenti = uint16(bound(c.intakePriceCenti, 10, 100));
        c.priceChangeCenti = uint16(bound(c.priceChangeCenti, 10, 150));
        c.lockWeeks = uint8(bound(c.lockWeeks, 0, 52));
        c.lockAmount = bound(c.lockAmount, 1e18, 20_000_000e18);
        uint256 s = _run(c);
        assertLe(_sub(s).asks, MAX_SWARM_CALLS, "more swarm questions than allowed");
        assertEq(uint8(_phase(s)), uint8(Phase.Final), "not final");
        _checkStake(c, s);
        _claimEverythingAndCheck();
        // dave, erin (disputers) and bob (caller) never contributed, so they never get the reward itself, but a
        // winning disputer/caller is owed a pro-rata share of the loser's forfeited bond on top of their own bond
        // back - not a bug, the whole incentive to dispute/call honestly.
        // Bounded generously by the worst case: every one of up to 3 disputers' bond.rew (1% of R, no escalation),
        // all redirected to a single winner.
        // the top-up (c.amount / 2, when present) is also part of R for the bond math, so the worst-case pool
        // scales off the full post-top-up reward, not just the author's original amount.
        uint256 maxReward = c.topUp ? c.amount + c.amount / 2 : c.amount;
        if (c.currency == 1) {
            uint256 cap1 = 1_000_000e6 + (maxReward / 100) * 3 * 2;
            assertLe(usdc.balanceOf(dave), cap1, "reward to a disputer");
            assertLe(usdc.balanceOf(erin), cap1, "reward to a disputer");
            assertLe(usdc.balanceOf(bob), cap1, "reward to a caller");
        }
        if (c.currency == 3) {
            uint256 cap3 = 1_000_000_000e18 + (maxReward / 100) * 3 * 2;
            assertLe(yolo.balanceOf(dave), cap3, "reward to a disputer");
            assertLe(yolo.balanceOf(erin), cap3, "reward to a disputer");
            assertLe(yolo.balanceOf(bob), cap3, "reward to a caller");
        }
        // value conservation for IMD: everything minted is with actors, the vault, the swarm payee, the burner or
        // the buyback wallet (IMD burn shares autosend there)
        uint256 total = imd.balanceOf(address(vault)) + imd.balanceOf(swarmPayee) + imd.balanceOf(address(adapter))
            + imd.balanceOf(address(burner)) + imd.balanceOf(buybackWallet);
        for (uint256 i; i < actors.length; ++i) {
            total += imd.balanceOf(actors[i]);
        }
        assertEq(total, imd.totalSupply());
    }

    function _run(Case memory c) internal returns (uint256 s) {
        address cur =
            c.currency == 0 ? ETH : c.currency == 1 ? address(usdc) : c.currency == 2 ? address(imd) : address(yolo);
        intake.setPrice(uint256(c.intakePriceCenti) * 1e16);
        vm.fee(uint256(c.basefeeGwei) * 1 gwei);
        callerSidesDoer = c.callerSidesDoer;
        uint256 t = _create(author, cur, c.amount);
        if (c.topUp) _topUp(alice, t, c.amount / 2);
        if (c.lockWeeks != 0) {
            vm.prank(doer);
            hub.lock(c.lockAmount, c.lockWeeks);
            _warp(1); // a lock counts for submissions in later blocks
        }
        s = _submit(doer, t);
        _submit(doer2, t); // a queued competitor, judged afterwards
        // no mandatory swarm check on any task: the dispute window is open at once
        assertEq(uint8(_phase(s)), uint8(Phase.Review));
        if (c.disputers != 0) _dispute(dave, s); // at most one disputer per submission
        if (c.disputers == 0) return _finish(s); // accepted by the timer
        if (c.acceptVotes != 0) _vote(s, 0, 1, 0, c.acceptVotes);
        if (_phase(s) == Phase.Voting && c.rejectVotes != 0) {
            uint256 fromV1 = c.rejectVotes > 20 ? 20 : c.rejectVotes;
            _vote(s, 1, 2, 120, fromV1);
            if (c.rejectVotes > 20 && _phase(s) == Phase.Voting) _vote(s, 2, 2, 140, c.rejectVotes - 20);
        }
        if (_phase(s) == Phase.Voting) {
            _warp(24 hours);
            vault.poke(t);
        }
        // NoDecision: anyone calls the swarm paying; Decided: an appeal against the decision
        if (!_call(s, c.swarm, bob)) return _finish(s);
        _warp(6 hours);
        vault.poke(t);
        if (_phase(s) != Phase.NoDecision && _phase(s) != Phase.Decided) return _finish(s);
        intake.setPrice(uint256(c.priceChangeCenti) * 1e16);
        if (!_call(s, c.swarm2, erin)) return _finish(s);
        _warp(6 hours);
        vault.poke(t);
        if (_phase(s) != Phase.NoDecision && _phase(s) != Phase.Decided) return _finish(s);
        bool silent3 = _call(s, c.swarm3, bob);
        if (silent3) {
            // the third question stayed silent: the submission ends at once as if nobody had called
            _warp(6 hours);
            vault.poke(t);
            assertEq(_sub(s).asks, MAX_SWARM_CALLS);
            assertEq(uint8(_phase(s)), uint8(Phase.Final), "third silence must end the submission");
            Outcome want = _sub(s).nftDecision == Verdict.Reject ? Outcome.Rejected : Outcome.Accepted;
            assertEq(uint8(_sub(s).outcome), uint8(want));
        }
        return _finish(s);
    }

    /// @dev The doer stake: the submission fixes 4% x min(1, power / R in $YOLO) (power
    ///      = amount x weeks / 52, locked a second before; R = the whole pot at the submission, alice's top-up included,
    ///      converted at the dev-set $YOLO price), from any power (no threshold); the settlement pays that share
    ///      only if the submission was accepted and the lock still runs; for a USDC or YOLO reward the doer is
    ///      credited exactly R - 10% + share x R (they never contribute; their bonds and rewards are in IMD).
    function _checkStake(Case memory c, uint256 s) internal view {
        Submission memory sb = _sub(s);
        uint256 fixedBps;
        if (c.lockWeeks != 0) {
            uint256 power = c.lockAmount * c.lockWeeks / 52;
            address cur = c.currency == 0
                ? ETH
                : c.currency == 1 ? address(usdc) : c.currency == 2 ? address(imd) : address(yolo);
            uint256 rY = oracle.yoloValue(cur, sb.reward); // the whole pot at the submission
            fixedBps = rY == 0 ? 0 : power >= rY ? 400 : 400 * power / rY;
        }
        assertEq(sb.stakeBps, fixedBps, "share fixed at the submission");
        uint256 paid = vault.getSettlement(s).stakeBps;
        if (sb.outcome != Outcome.Accepted) {
            assertEq(paid, 0, "stake share without an acceptance");
        } else {
            // the lock may have ended before the payout (checked here later: ended by now)
            bool ended = c.lockWeeks != 0 && _now() >= sb.submittedAt - 1 + uint256(c.lockWeeks) * 7 days;
            if (paid != fixedBps) assertTrue(paid == 0 && ended, "paid share != the fixed one while the lock runs");
        }
        if (c.currency == 1 || c.currency == 3) {
            address cur = c.currency == 1 ? address(usdc) : address(yolo);
            uint256 r = sb.reward;
            // No escalation: on acceptance the doer's own rew bond (sb.bond.rew, flat 3% of
            // R) is credited back alongside the reward itself. With no dispute this is the whole
            // story and the credit is exact; with disputers the doer (winner) also gets a pro-rata share of
            // their forfeited bonds, which this generic fuzz harness does not reconstruct
            // (it would duplicate DisputeDesk._splitCurrency's NFT/winnerBondBps math), so that case is bounded.
            if (c.disputers == 0) {
                uint256 want = sb.outcome == Outcome.Accepted ? r - r / 10 + r * paid / 10_000 + sb.bond.rew : 0;
                assertEq(vault.credits(cur, doer), want, "doer credit != R - 10% + stake bonus + his rew bond back");
            } else if (sb.outcome == Outcome.Accepted) {
                uint256 floor = r - r / 10 + r * paid / 10_000 + sb.bond.rew;
                // ceiling: the disputer's whole bond.rew, plus every swarm caller's bond.rew across the up to
                // MAX_SWARM_CALLS (3) rounds, could end up with the doer (NFT undecided/wrong, winnerBondBps =
                // 100% to the winner) - 3 bonds, 1% of R each, with a 2x margin (every bond is 1% of R; at most
                // one disputer per submission, swarm callers one per round)
                uint256 ceil = floor + (r / 100) * 3 * 2;
                assertGe(vault.credits(cur, doer), floor, "doer credit below the no-penalty-share floor");
                assertLe(
                    vault.credits(cur, doer),
                    ceil,
                    "doer credit above the disputer bond plus three swarm callers' bonds, 2x margin"
                );
            } else {
                // rejected: the doer never gets the reward or their bond back (forfeited), but every silent
                // swarm call he made gives back the bond it posted (the fee stays paid) regardless of
                // the final outcome (up to MAX_SWARM_CALLS = 3 of them, swarm/swarm2/swarm3), so his credit is
                // not always exactly 0 - bounded generously by that many extra bonds (2x margin).
                assertLe(vault.credits(cur, doer), (r / 100) * 3 * 2, "doer credit too high on a non-accepted outcome");
            }
        }
    }

    /// @dev Lets every timer of the submission run out (windows, the queued competitor) and returns it.
    function _finish(uint256 s) internal returns (uint256) {
        for (uint256 i; i < 6 && _phase(s) != Phase.Final; ++i) {
            _warp(2 days);
            vault.poke(_sub(s).taskId);
        }
        return s;
    }

    /// @dev One paid call to the swarm in the current state; true if the swarm stayed silent.
    function _call(uint256 s, uint8 mode, address who) internal returns (bool silent) {
        if (mode == 3) return false; // nobody calls: the standing state finalizes by the timer
        if (_phase(s) == Phase.NoDecision) {
            _callSwarm(who, s, callerSidesDoer);
        } else {
            address appellant = _sub(s).nftDecision == Verdict.Accept ? who : doer;
            _appeal(appellant, s);
            _warp(1 hours); // asked inside swarmTimeout (6 h): a later ask finds the appeal void
            _askAppealSwarm(s); // asks; may void the appeal if the price moved above the prepaid fee (lazy ask)
            if (_phase(s) != Phase.Asked) return false;
        }
        if (mode == 2) {
            _silent(s);
            return true;
        }
        _answer(s, mode == 0);
        return false;
    }
}
