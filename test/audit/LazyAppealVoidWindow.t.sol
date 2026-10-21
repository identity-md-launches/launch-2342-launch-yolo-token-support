// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "../Base.t.sol";
import "../../src/VaultTypes.sol";

/// @dev Reaudit logic #1: an appeal not asked within 6 h (`swarmTimeout`) is void at `appealedAt + swarmTimeout`, and
///      the 24 h appeal window it reopens counts from that void moment (CaseDesk.step sets `callFrom` to it), not from
///      the poke that plays it (MECHANICS "Known limitations"). The finality does not depend on when somebody pokes:
///      the submission is final at `appealedAt + 6 h + 24 h`.
/// forge-config: default.isolate = false
contract LazyAppealVoidWindowTest is Base {
    uint256 internal t;
    uint256 internal s;

    function _rejectedAndAppealed() internal returns (uint256 appealedAt) {
        t = _create(author, address(usdc), 100e6);
        s = _submit(doer, t);
        _dispute(dave, s);
        _vote(s, 1, 2, 120, 20); // 20 NFT reject: instant decision
        assertEq(uint8(_phase(s)), uint8(Phase.Decided));
        _appeal(doer, s); // the doer appeals the rejection, never asks it
        appealedAt = _now();
        assertEq(uint8(_phase(s)), uint8(Phase.Appealed));
    }

    /// @dev Poke at void + 24 h: the appeal window that reopened at the void moment has ended, the submission must be
    ///      final (Rejected: the NFT decision stands).
    function test_PokeAfterVoidPlusWindow_IsFinal() public {
        uint256 appealedAt = _rejectedAndAppealed();
        uint256 voidAt = appealedAt + 6 hours;
        vm.warp(voidAt + 24 hours);
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.Final), "void + appealWindow passed: must be final");
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Rejected));
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Open)); // deadline not reached: task stays open
    }

    /// @dev The window that `stepDeadline` reports after the void must be voidAt + appealWindow, whatever the poke time.
    function test_WindowAfterVoid_StartsAtTheVoidMoment() public {
        uint256 appealedAt = _rejectedAndAppealed();
        uint256 voidAt = appealedAt + 6 hours;
        vm.warp(voidAt + 20 hours); // a late poke
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.Decided));
        assertEq(vault.stepDeadline(s), voidAt + 24 hours, "the reopened window counts from the void, not the poke");
    }

    /// @dev Nobody pokes for days, then the appellant tries to re-appeal: the call plays the void first, the window
    ///      that reopened at the void moment ended long ago, so the submission is final and the appeal reverts.
    function test_LateReAppealAfterTheVoidWindow_Reverts() public {
        uint256 appealedAt = _rejectedAndAppealed();
        uint256 voidAt = appealedAt + 6 hours;
        vm.warp(voidAt + 10 days); // nobody poked for 10 days
        // the doer's appeal call plays the void first; the window counted from the void moment is over: final
        vm.prank(doer);
        vm.expectRevert(WrongPhase.selector);
        vault.appeal{value: ETH_BOND_HEADROOM}(s, type(uint256).max, _noSwap());
    }
}
