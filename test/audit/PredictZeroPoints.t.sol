// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "../Base.t.sol";
import {YoloPredict} from "../../src/YoloPredict.sol";
import "../../src/VaultTypes.sol";

/// @notice Reaudit money #1: "nobody on the winning side" is decided by the pool, not by the points; a winning
///         side with 0 points in total splits the losing pool by position.
/// forge-config: default.isolate = false
contract PredictZeroPointsWinnerTest is Base {
    YoloPredict internal predict;

    function setUp() public override {
        super.setUp();
        predict = new YoloPredict(address(vault), 1e18);
        vm.prank(alice);
        yolo.approve(address(predict), type(uint256).max);
        vm.prank(bob);
        yolo.approve(address(predict), type(uint256).max);
        vm.prank(author);
        yolo.approve(address(predict), type(uint256).max);
    }

    function test_ZeroPointWinner_TakesTheLosingPool() public {
        uint64 deadline = uint64(_now() + 40 * 365 days);
        uint256 t = _createWithDeadline(author, address(usdc), 100e6, deadline);

        vm.prank(bob);
        predict.predict(t, false, 100e18);
        uint256 losingPool = 90e18;

        vm.warp(deadline - 1);
        vm.prank(alice);
        predict.predict(t, true, 1e18);
        (, uint256 willDoPoints,,) = predict.positionsOf(t, alice);
        assertEq(willDoPoints, 0, "points floor to 0");
        (,, uint256 willDoPool,,,,) = predict.markets(t);
        assertEq(willDoPool, 0.9e18, "but alice IS on WILL DO");

        uint256 s = _submit(doer, t);
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Completed));
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));

        uint256 authorBefore = yolo.balanceOf(author);
        uint256 doerBefore = yolo.balanceOf(doer);
        uint256 aliceBefore = yolo.balanceOf(alice);
        vm.prank(alice);
        predict.claim(t);

        uint256 deferred = (100e18 + 1e18) * 500 / 10_000;
        assertEq(yolo.balanceOf(author) - authorBefore, deferred / 2, "author: only the deferred 2.5%");
        assertEq(yolo.balanceOf(doer) - doerBefore, deferred - deferred / 2, "doer: only the deferred 2.5%");
        assertEq(yolo.balanceOf(alice) - aliceBefore, 0.9e18 + losingPool, "winner: 90% back + the losing pool");
    }

    /// @dev Two zero-point winners split the losing pool by position (0.9 : 2.7 of 90 YOLO); 100 years: 2.7 YOLO
    ///      a second before the deadline still floors to 0 points.
    function test_ZeroPointWinners_SplitByPosition() public {
        uint64 deadline = uint64(_now() + 100 * 365 days);
        uint256 t = _createWithDeadline(author, address(usdc), 100e6, deadline);
        vm.prank(bob);
        predict.predict(t, false, 100e18);
        vm.warp(deadline - 1);
        vm.prank(alice);
        predict.predict(t, true, 1e18);
        vm.prank(author);
        predict.predict(t, true, 3e18);
        (,,,, uint256 willDoPointsTotal,,) = predict.markets(t);
        assertEq(willDoPointsTotal, 0, "both positions floor to 0 points");
        _submit(doer, t);
        _warp(24 hours);
        vault.poke(t);

        uint256 aliceBefore = yolo.balanceOf(alice);
        vm.prank(alice);
        predict.claim(t);
        assertEq(yolo.balanceOf(alice) - aliceBefore, 0.9e18 + 22.5e18, "alice: 90% back + a quarter of the pool");
        uint256 authorBefore = yolo.balanceOf(author);
        vm.prank(author);
        predict.claim(t);
        assertEq(yolo.balanceOf(author) - authorBefore, 2.7e18 + 67.5e18, "author: 90% back + the rest of the pool");
    }
}
