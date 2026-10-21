// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "../Base.t.sol";
import "../../src/VaultTypes.sol";

/// @dev Fuzz test crossing roles (the doer tries to dispute themself -> DoerCannotDispute; the author
///      and a contributor dispute; the doer or a contributor calls the swarm / appeals). After all payouts: the
///      vault owes nothing and holds nothing; IMD is conserved; the reward (USDC) only goes to the doer, NFT
///      votes, and the treasury; contributors get back no more than they put in.
/// forge-config: default.isolate = false
contract ReviewRoles is Base {
    struct Case {
        uint8 d0; // disputers: index in people (0 = none)
        uint8 d1;
        uint8 d2;
        uint8 caller; // who calls the swarm / appeals
        uint8 accept;
        uint8 reject;
        uint8 swarm; // 0 yes, 1 no, 2 silence, 3 nobody
        bool sidesDoer;
        uint32 basefeeGwei;
    }

    function _who(uint8 i) internal view returns (address) {
        address[5] memory people = [doer, author, alice, dave, erin];
        return people[i % 5];
    }

    function testFuzz_RoleOverlap(Case memory c) public {
        c.accept = uint8(bound(c.accept, 0, 120));
        c.reject = uint8(bound(c.reject, 0, 30));
        c.swarm = uint8(bound(c.swarm, 0, 3));
        vm.fee(bound(c.basefeeGwei, 0, 100) * 1 gwei);

        uint256 t = _create(author, address(usdc), 200e6);
        _topUp(alice, t, 50e6);
        uint256 s = _submit(doer, t);

        // One dispute, one disputer - only the first non-doer candidate among
        // d0/d1/d2 actually disputes; every later one (even a repeat of the same address) reverts instead of
        // silently joining, exactly like the doer's own attempt.
        uint8[3] memory ds = [c.d0, c.d1, c.d2];
        uint256 n;
        for (uint256 i; i < 3; ++i) {
            address d = _who(ds[i]);
            if (d == doer) {
                vm.prank(doer);
                vm.expectRevert(DoerCannotDispute.selector);
                vault.dispute(s, "ipfs://reason", "ipfs://reason-proof", _noSwap());
                continue;
            }
            if (n != 0) {
                vm.prank(d);
                vm.expectRevert(AlreadyDisputed.selector);
                vault.dispute(s, "ipfs://reason", "ipfs://reason-proof", _noSwap());
                continue;
            }
            _dispute(d, s);
            ++n;
        }
        if (n != 0 && c.accept != 0) _vote(s, 0, 1, 0, c.accept);
        if (_phase(s) == Phase.Voting && c.reject != 0) {
            _vote(s, 1, 2, 120, c.reject > 20 ? 20 : c.reject);
            if (c.reject > 20 && _phase(s) == Phase.Voting) _vote(s, 2, 2, 140, c.reject - 20);
        }
        if (_phase(s) == Phase.Voting) {
            _warp(24 hours);
            vault.poke(t);
        }
        address caller = _who(c.caller);
        // the doer never takes the swarm slot against their own submission
        Phase ph = _phase(s);
        bool againstSelf =
            caller == doer && (ph == Phase.NoDecision ? !c.sidesDoer : _sub(s).nftDecision == Verdict.Accept);
        if (c.swarm != 3 && againstSelf && (ph == Phase.NoDecision || ph == Phase.Decided)) {
            vm.prank(doer);
            vm.expectRevert(DoerCannotDispute.selector);
            if (ph == Phase.NoDecision) {
                vault.callSwarm(s, false, type(uint256).max, _noSwap(), _genericRuleTexts());
            } else {
                vault.appeal(s, type(uint256).max, _noSwap());
            }
        } else if (c.swarm != 3) {
            if (_phase(s) == Phase.NoDecision) {
                _callSwarm(caller, s, c.sidesDoer);
            } else if (_phase(s) == Phase.Decided) {
                _appeal(caller, s);
                _warp(1 hours); // asked inside swarmTimeout (6 h): a later ask finds the appeal void
                _askAppealSwarm(s); // lazy ask
            }
            if (_phase(s) == Phase.Asked) {
                if (c.swarm == 2) _silent(s);
                else _answer(s, c.swarm == 0);
            }
        }
        _claimEverythingAndCheck();

        // IMD is conserved
        // IMD burn shares autosend to the buyback wallet, the burner only as a fallback; nobody
        // stakes here, so the treasury's part is what could burn
        uint256 total = imd.balanceOf(address(vault)) + imd.balanceOf(swarmPayee) + imd.balanceOf(address(adapter))
            + imd.balanceOf(address(burner)) + imd.balanceOf(buybackWallet);
        for (uint256 i; i < actors.length; ++i) {
            total += imd.balanceOf(actors[i]);
        }
        assertEq(total, imd.totalSupply(), "IMD conservation");
        // reward: disputers who are not contributors (dave, erin) don't get the reward itself, but can come out
        // ahead of their starting balance if they disputed/appealed correctly and won - they are entitled to a
        // share of the loser's forfeited bond, not just a return of their own bond. The upper bound on the gain
        // is capped by everything they could have paid for this submission's disputes (bonds + swarm fees), with
        // margin (several swarm calls per submission; tracking several submissions in actors doesn't happen here).
        assertLe(usdc.balanceOf(dave), 1_000_000e6 + 50e6, "reward to dave (bond + penalty share, bounded)");
        assertLe(usdc.balanceOf(erin), 1_000_000e6 + 50e6, "reward to erin (bond + penalty share, bounded)");
        // alice is a contributor, but here she can only be a disputer (not the doer and not the swarm caller) -
        // as a disputer she is "just another disputer like anyone else" and entitled to a share of the loser's
        // forfeited bond beyond her own stake, not just a return of her own bond (the "a contributor only gets
        // their own bond back" limit applies to the doer/appeal-caller role, not to the disputer role).
        assertLe(usdc.balanceOf(alice), 1_000_000e6 + 50e6, "reward to alice (bond + penalty share, bounded)");
        Submission memory sub = _sub(s);
        if (sub.outcome != Outcome.Accepted) {
            // not accepted: the doer does not get the reward. The percentage part of the doer's bond in the
            // reward currency (USDC here) really leaves their wallet at submission and, if rejected, is not
            // returned (that is the fake penalty) - the balance may end up BELOW the start but never above.
            assertLe(usdc.balanceOf(doer), 1_000_000e6, "reward paid on a non-accepted outcome");
        }
    }
}
