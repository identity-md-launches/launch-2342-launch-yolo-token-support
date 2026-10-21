// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "../Base.t.sol";
import "../../src/VaultTypes.sol";
import {YoloPredict} from "../../src/YoloPredict.sol";

/// @dev Predictions are paused only while a submission is active. A submission rejected by the NFT whose 24 h
///      appeal window has passed is over even if nobody has poked the vault yet: predict plays the vault's timers
///      first (vault.poke, as settle does), so the position goes through.
/// forge-config: default.isolate = false
contract PredictAfterTimerTest is Base {
    YoloPredict internal yoloPredict;
    uint256 internal t;
    uint256 internal s;

    function setUp() public override {
        super.setUp();
        yoloPredict = new YoloPredict(address(vault), 0.5e18);
        vm.prank(alice);
        yolo.approve(address(yoloPredict), type(uint256).max);
    }

    /// @dev Rejected by 20 NFT at once, nobody appeals, the appeal window passes, nobody pokes.
    function _rejectedWindowPassed() internal {
        t = _create(author, address(usdc), 100e6);
        s = _submit(doer, t);
        _dispute(dave, s);
        _vote(s, 1, 2, 120, 20); // 20 NFT reject: instant decision
        assertEq(uint8(_phase(s)), uint8(Phase.Decided));
        vm.warp(_sub(s).callFrom + 24 hours + 1);
        assertLt(_now(), vault.getTask(t).deadline, "still before the deadline");
    }

    /// @dev The submission is over, so a position is allowed without a separate poke.
    function test_PredictAfterTimerEnded_WithoutPoke_IsAllowed() public {
        _rejectedWindowPassed();
        vm.prank(alice);
        yoloPredict.predict(t, true, 1e18);
        assertEq(vault.getTask(t).activeSub, 0, "predict played the timers");
    }
}
