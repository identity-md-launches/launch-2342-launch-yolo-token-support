// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../Base.t.sol";
import {YoloPredict} from "../../src/YoloPredict.sol";

/// @dev `YoloPredict` checks with a contributor who also predicts: the reward is locked until the deadline, the
///      market never reads the pot after the outcome and voids only on Unwound, so moving the reward changes no
///      market result; the numbers match the honest outcome.
/// forge-config: default.isolate = false
contract YoloModulesAuditTest is Base {
    YoloPredict internal yoloPredict;
    uint256 internal constant MIN_POSITION = 0.5e18;

    function setUp() public override {
        super.setUp();
        yoloPredict = new YoloPredict(address(vault), MIN_POSITION);
        for (uint256 i; i < actors.length; ++i) {
            vm.prank(actors[i]);
            yolo.approve(address(yoloPredict), type(uint256).max);
        }
    }

    // ================================================================== a contributor who predicts

    /// @notice A contributor may predict (`alice` tops up the pot, then predicts). Her contribution stays
    ///         locked until the deadline and a withdrawal after the outcome changes no market result
    ///         (test_Guard_PostExpiryWithdrawalChangesNothing / test_ResidualGone_NoWithdrawalWhileOpen below).
    function test_ContributorCanPredict() public {
        uint256 t = _createWithDeadline(author, address(imd), 10e18, uint64(_now() + 10 days));
        _topUp(alice, t, 90e18); // pot = 100e18; alice is a contributor; contributing does not block her from predicting

        vm.prank(alice);
        yoloPredict.predict(t, true, 10e18);

        vm.prank(dave);
        sweetener.sweeten(t, 1e18); // a $YOLO bonus counts the same
        vm.prank(dave);
        yoloPredict.predict(t, true, 10e18);

        vm.prank(bob);
        yoloPredict.predict(t, true, 10e18);
        assertEq(uint8(yoloPredict.resolution(t)), uint8(YoloPredict.Resolution.Pending));
    }

    /// @notice There is no pot-based void at
    ///         all (the reward is locked until the deadline): `erin` funds the reward, never
    ///         predicts, pulls her money back the moment the task expired; the market resolves by the task's status
    ///         and bob, the only honest winner, is paid his full 18e18.
    function test_Guard_PostExpiryWithdrawalChangesNothing() public {
        uint256 t = _createWithDeadline(author, address(imd), 10e18, uint64(_now() + 10 days));
        _topUp(erin, t, 90e18); // pot = 100e18

        vm.prank(alice);
        yoloPredict.predict(t, true, 10e18);
        vm.prank(bob);
        yoloPredict.predict(t, false, 10e18); // bob is the sole predictor on the side about to win

        _warp(10 days + 1);
        vault.poke(t);
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Expired), "no submission: 'against' wins");

        vm.prank(erin);
        vault.withdrawContribution(t);
        assertEq(vault.getTask(t).pot, 10e18, "the pot falls after the expiry");
        assertEq(uint8(yoloPredict.resolution(t)), uint8(YoloPredict.Resolution.WontDoWon), "the market ignores it");

        uint256 dead0 = yolo.balanceOf(DEAD);
        uint256 aliceBefore = yolo.balanceOf(alice);
        vm.prank(alice);
        yoloPredict.claim(t);
        assertEq(yolo.balanceOf(alice) - aliceBefore, 0, "alice's losing position pays nothing, no rescue");
        assertEq(
            yolo.balanceOf(DEAD) - dead0, 1e18 + 1e18, "the held entry 5% + the deferred 5% burn at settle: not done"
        );

        uint256 bobBefore = yolo.balanceOf(bob);
        vm.prank(bob);
        yoloPredict.claim(t);
        assertEq(yolo.balanceOf(bob) - bobBefore, 18e18, "bob, the only honest winner, is paid his full 18e18");
        assertEq(yolo.balanceOf(address(yoloPredict)), 0);
    }

    /// @notice Nobody takes the reward back while the task is
    ///         open, so the pot never falls under a market and a falling pot voids nothing; the market resolves by the
    ///         task's status (WON'T DO on the expiry).
    function test_ResidualGone_NoWithdrawalWhileOpen() public {
        uint256 t = _createWithDeadline(author, address(imd), 10e18, uint64(_now() + 30 days));
        _topUp(erin, t, 90e18);

        vm.prank(alice);
        yoloPredict.predict(t, true, 10e18);
        vm.prank(bob);
        yoloPredict.predict(t, false, 10e18);

        vm.prank(erin);
        vm.expectRevert(TaskNotOpen.selector);
        vault.withdrawContribution(t); // well before the deadline: locked
        vm.prank(author);
        vm.expectRevert(TaskNotOpen.selector);
        vault.withdrawContribution(t);
        assertEq(vault.getTask(t).pot, 100e18, "the pot cannot fall while open");
        assertEq(uint8(yoloPredict.resolution(t)), uint8(YoloPredict.Resolution.Pending));

        _warp(30 days);
        vault.poke(t);
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Expired));

        uint256 aliceBefore = yolo.balanceOf(alice);
        vm.prank(alice);
        yoloPredict.claim(t);
        assertEq(yolo.balanceOf(alice) - aliceBefore, 0, "the loser");

        uint256 bobBefore = yolo.balanceOf(bob);
        vm.prank(bob);
        yoloPredict.claim(t);
        assertEq(yolo.balanceOf(bob) - bobBefore, 18e18, "the winner: his 90% + the losing pool");
    }
}
