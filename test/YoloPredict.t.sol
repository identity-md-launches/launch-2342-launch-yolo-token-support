// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./Base.t.sol";
import {YoloPredict} from "../src/YoloPredict.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev `YoloPredict`: a parimutuel "will this task be done by its deadline" market, $YOLO only. Every position:
///      5% to burn (held until the outcome), 5% deferred, 90% in the pool, weight
///      (time left / (deadline - task creation))^2. Completed -> WILL DO, Expired -> WON'T DO, Unwound -> void (all
///      back). Nobody on the winning side: the losing pool goes to the author and the doer. Deferred 5%: Completed ->
///      2.5% author + 2.5% accepted doer, otherwise burned. Anyone may predict, the author, contributors and the doer
///      included. No cap, no per-address limit, no price.
/// forge-config: default.isolate = false
contract YoloPredictTest is Base {
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

    // ================================================================== helpers

    function _predict(address who, uint256 t, bool willDo, uint256 amount) internal {
        vm.prank(who);
        yoloPredict.predict(t, willDo, amount);
    }

    /// @dev `by` submits and the dispute window runs out: Completed.
    function _accept(address by, uint256 t) internal returns (uint256 s) {
        s = _submit(by, t);
        vm.warp(_sub(s).windowEnd + 1);
        vault.poke(t);
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Completed));
    }

    function _m(uint256 t)
        internal
        view
        returns (uint256 willDoPool, uint256 wontDoPool, uint256 willPts, uint256 wontPts, uint256 deferred)
    {
        (,, willDoPool, wontDoPool, willPts, wontPts, deferred) = yoloPredict.markets(t);
    }

    function _task10d() internal returns (uint256) {
        return _createWithDeadline(author, address(imd), 10e18, uint64(_now() + 10 days)); // $80
    }

    // ================================================================== window, pause, author

    /// Every task has a deadline, a task
    /// without one is not created; a market opens on any task.
    function test_EveryTaskHasADeadline() public {
        vm.prank(author);
        vm.expectRevert(BadDeadline.selector);
        vault.createTask(address(imd), 10e18, 0, "Title", rulesOf("c"), 0, 0, "", _noSwap());
        uint256 t = _create(author, address(imd), 10e18); // Base: deadline = now + TTL
        _predict(alice, t, true, 10e18);
        (,, uint256 willPts,,) = _m(t);
        assertEq(willPts, 9e18, "placed at the task's creation: weight 1");
    }

    function test_ClosesAtDeadline_PausesWhileBusy() public {
        uint256 t = _task10d();
        _warp(10 days + 1);
        vm.prank(alice);
        vm.expectRevert(YoloPredict.WindowClosed.selector);
        yoloPredict.predict(t, true, 10e18);

        uint256 t2 = _task10d();
        uint256 s = _submit(doer, t2);
        vm.prank(alice);
        vm.expectRevert(YoloPredict.SubmissionActive.selector);
        yoloPredict.predict(t2, true, 10e18);
        // rejected: busy clears, predicting resumes before the deadline
        _dispute(dave, s);
        _vote(s, 0, 2, 0, 120);
        _endVote(s);
        _warp(24 hours + 1);
        vault.poke(t2);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Rejected));
        _predict(alice, t2, true, 10e18); // no revert now
    }

    /// Anyone may predict, including the task's own author.
    function test_AuthorCanPredict() public {
        uint256 t = _task10d();
        vm.prank(author);
        yoloPredict.predict(t, true, 10e18);
        (uint256 willDoPool,,,,) = _m(t);
        assertEq(willDoPool, 9e18);
    }

    function test_BelowMinPositionReverts() public {
        uint256 t = _task10d();
        vm.prank(alice);
        vm.expectRevert(YoloPredict.BelowMinPosition.selector);
        yoloPredict.predict(t, true, MIN_POSITION - 1);
    }

    /// The constructor does not take a sweetener address; YoloPredict
    /// does not reference the sweetener at all.
    function test_ConstructorChecks() public {
        vm.expectRevert(YoloPredict.ZeroAddress.selector);
        new YoloPredict(address(0), MIN_POSITION);
        vm.expectRevert(YoloPredict.ZeroAmount.selector);
        new YoloPredict(address(vault), 0);
        assertEq(address(yoloPredict.yolo()), address(yolo));
    }

    // ================================================================== no price, no cap

    /// No
    /// price of any kind is read: IMD and USDC rewards open a market exactly like a $YOLO reward, with no $YOLO
    /// price set, and there is no bank cap and no per-address limit on a position.
    function test_NoPriceNeeded_ImdAndUsdcRewards_MarketOpensAnyway() public {
        uint256 ti = _task10d();
        uint256 tu = _createWithDeadline(author, address(usdc), 100e6, uint64(_now() + 10 days));
        oracle.set(address(yolo), 0, 18); // no $YOLO price anywhere: the market does not care
        _predict(alice, ti, true, 10e18);
        _predict(alice, tu, true, 10e18);
        (uint256 willDoPoolI,,,,) = _m(ti);
        (uint256 willDoPoolU,,,,) = _m(tu);
        assertEq(willDoPoolI, 9e18);
        assertEq(willDoPoolU, 9e18);
    }

    /// No bank cap, no per-address limit: a position far larger than the reward's own value is accepted in full.
    function test_NoCap_LargePositionAccepted() public {
        uint256 t = _createWithDeadline(author, address(yolo), 2_000_000e18, uint64(_now() + 10 days)); // $200
        oracle.set(address(yolo), 0, 18);
        _predict(alice, t, true, 10_000_000e18); // 5x the reward itself, no revert
        (uint256 willDoPool,,,,) = _m(t);
        assertEq(willDoPool, 9_000_000e18);
        _predict(bob, t, false, 20_000_000e18); // an even larger position on the other side, also no revert
        (uint256 willDoPool2, uint256 wontDoPool,,,) = _m(t);
        assertEq(willDoPool2, willDoPool);
        assertEq(wontDoPool, 18_000_000e18);

        _accept(doer, t);
        uint256 a0 = yolo.balanceOf(alice);
        vm.prank(alice);
        yoloPredict.claim(t);
        assertEq(yolo.balanceOf(alice) - a0, 9_000_000e18 + 18_000_000e18);
        vm.prank(bob);
        yoloPredict.claim(t);
        assertEq(yolo.balanceOf(address(yoloPredict)), 0);
    }

    // ================================================================== entry split and weight

    /// 100 YOLO in: 5 to burn, 5 deferred, 90 in the pool. The 5% burn is held until the outcome (a
    /// cancellation returns the position in full).
    function test_EntrySplit_5_5_90() public {
        uint256 t = _task10d();
        uint256 dead0 = yolo.balanceOf(DEAD);
        uint256 a0 = yolo.balanceOf(alice);
        vm.expectEmit(address(yoloPredict));
        emit YoloPredict.Predicted(t, alice, true, 100e18, 90e18, 90e18, 5e18, 5e18);
        _predict(alice, t, true, 100e18);
        assertEq(a0 - yolo.balanceOf(alice), 100e18);
        assertEq(yolo.balanceOf(DEAD) - dead0, 0, "the burn waits for the outcome");
        assertEq(yoloPredict.burnHeld(t), 5e18);
        assertEq(yoloPredict.paidIn(t, alice), 100e18);
        (uint256 willDoPool,,,, uint256 deferred) = _m(t);
        assertEq(willDoPool, 90e18);
        assertEq(deferred, 5e18);
        assertEq(yolo.balanceOf(address(yoloPredict)), 100e18);
    }

    /// Weight counts over [task creation, deadline]; a market opened
    /// halfway gives its first position a quarter of the weight.
    function test_Weight_CountsFromTaskCreation() public {
        uint256 t = _task10d();
        _warp(5 days);
        _predict(alice, t, true, 10e18);
        (,, uint256 willPts,,) = _m(t);
        assertEq(willPts, 2.25e18, "9e18 x (5/10)^2");
        (uint256 amt, uint256 pts,,) = yoloPredict.positionsOf(t, alice);
        assertEq(amt, 9e18);
        assertEq(pts, 2.25e18);
    }

    // ================================================================== numeric example

    function test_NumericExample_AliceBobCarl() public {
        // A 10-day task; Alice 1000 YOLO day 0 ("will"), Bob 400 YOLO day 8 ("will"),
        // Carl 800 YOLO ("won't"); 5% burned + 5% deferred at entry.
        uint256 t = _task10d();
        uint256 dead0 = yolo.balanceOf(DEAD);

        _predict(alice, t, true, 1000e18); // day 0 = the task's creation, w = 1.0
        _warp(8 days);
        _predict(bob, t, true, 400e18); // day 8, w = (2/10)^2 = 0.04
        _predict(carl(), t, false, 800e18);

        assertEq(yolo.balanceOf(DEAD) - dead0, 0, "the 5% burn is held until the outcome");
        assertEq(yoloPredict.burnHeld(t), 50e18 + 20e18 + 40e18, "5% per position, to burn at settle");

        (uint256 willDoPool, uint256 wontDoPool, uint256 willDoPointsTotal,, uint256 deferred) = _m(t);
        assertEq(willDoPool, 900e18 + 360e18);
        assertEq(wontDoPool, 720e18);
        assertEq(deferred, 110e18);
        uint256 bobPoints = Math.mulDiv(Math.mulDiv(360e18, 2 days, 10 days), 2 days, 10 days);
        assertEq(bobPoints, 14.4e18, "no rounding loss on this particular day split");
        assertEq(willDoPointsTotal, 900e18 + bobPoints);

        // the task is accepted: "will" wins
        uint256 author0 = yolo.balanceOf(author);
        uint256 doer0 = yolo.balanceOf(doer);
        _accept(doer, t);

        uint256 expectedAlice = 900e18 + Math.mulDiv(720e18, 900e18, willDoPointsTotal);
        uint256 expectedBob = 360e18 + Math.mulDiv(720e18, bobPoints, willDoPointsTotal);

        uint256 aliceBefore = yolo.balanceOf(alice);
        vm.prank(alice);
        yoloPredict.claim(t); // the first claim settles: the deferred 110 -> 55 author, 55 doer
        uint256 alicePay = yolo.balanceOf(alice) - aliceBefore;
        assertEq(alicePay, expectedAlice, "exactly the payout formula");
        assertApproxEqAbs(alicePay, 1608.66e18, 2e15, "close to ~1608.66 YOLO computed by hand");
        assertEq(yolo.balanceOf(author) - author0, 55e18, "2.5% of every position to the author");
        assertEq(yolo.balanceOf(doer) - doer0, 55e18, "2.5% of every position to the doer");

        uint256 bobBefore = yolo.balanceOf(bob);
        vm.prank(bob);
        yoloPredict.claim(t);
        uint256 bobPay = yolo.balanceOf(bob) - bobBefore;
        // the last winner to claim is paid from what is left of the losing pool, so they also take the dust
        assertApproxEqAbs(bobPay, expectedBob, 1);
        assertEq(alicePay + bobPay, 1260e18 + 720e18, "the whole losing pool paid out, to the wei");
        assertApproxEqAbs(bobPay, 371.34e18, 2e15, "close to ~371.34 YOLO computed by hand");

        assertEq(
            alicePay + bobPay + (yolo.balanceOf(DEAD) - dead0) + 55e18 + 55e18,
            2200e18,
            "payouts + burn + deferred == deposits, no dust left"
        );

        uint256 carlBefore = yolo.balanceOf(carl());
        vm.prank(carl());
        yoloPredict.claim(t); // a pure loser's claim succeeds harmlessly with a zero payout
        assertEq(yolo.balanceOf(carl()), carlBefore, "Carl lost everything, nothing paid");
        assertEq(yolo.balanceOf(address(yoloPredict)), 0);
        _claimEverythingAndCheck();
    }

    function carl() internal view returns (address) {
        return dave; // reuse Base's `dave` actor as "Carl" to avoid adding a new funded address
    }

    // ================================================================== the reward is locked until the deadline

    /// The reward is locked until the deadline: nobody takes it back while the task is open, `claim` reverts `NotFinal`
    /// until the task is final, and after the outcome every claim is paid in full, to the wei, whatever happens to
    /// the reward after the deadline (the market never reads the pot again).
    function test_RewardLockedUntilDeadline_WinnersPaidInFull() public {
        uint256 t = _createWithDeadline(author, address(imd), 100e18, uint64(_now() + 30 days)); // $800
        _topUp(erin, t, 20e18); // $960
        uint256 dead0 = yolo.balanceOf(DEAD);
        _predict(alice, t, true, 100e18); // eff 90
        _predict(bob, t, false, 50e18); // eff 45
        _predict(dave, t, false, 30e18); // eff 27

        // the reward cannot fall while the task is open, before the deadline or a second before it
        vm.prank(author);
        vm.expectRevert(TaskNotOpen.selector);
        vault.withdrawContribution(t);
        vm.prank(erin);
        vm.expectRevert(TaskNotOpen.selector);
        vault.withdrawContribution(t);
        assertEq(vault.getTask(t).pot, 120e18);
        // nobody takes anything out of the market before the outcome
        vm.prank(alice);
        vm.expectRevert(YoloPredict.NotFinal.selector);
        yoloPredict.claim(t);
        vm.prank(bob);
        vm.expectRevert(YoloPredict.NotFinal.selector);
        yoloPredict.claim(t);
        vm.expectRevert(YoloPredict.NotFinal.selector);
        yoloPredict.settle(t);
        vm.warp(vault.getTask(t).deadline - 1);
        vm.prank(erin);
        vm.expectRevert(TaskNotOpen.selector);
        vault.withdrawContribution(t);

        _warp(1);
        vault.poke(t);
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Expired));
        // after the expiry the reward goes back; the market does not care
        vm.prank(author);
        vault.withdrawContribution(t);
        vm.prank(erin);
        vault.withdrawContribution(t);
        assertEq(vault.getTask(t).pot, 0);
        assertEq(uint8(yoloPredict.resolution(t)), uint8(YoloPredict.Resolution.WontDoWon));

        uint256 a0 = yolo.balanceOf(alice);
        uint256 b0 = yolo.balanceOf(bob);
        uint256 d0 = yolo.balanceOf(dave);
        vm.prank(alice);
        yoloPredict.claim(t);
        vm.prank(bob);
        yoloPredict.claim(t);
        vm.prank(dave);
        yoloPredict.claim(t);
        assertEq(yolo.balanceOf(alice) - a0, 0, "the loser gets nothing back");
        assertEq(yolo.balanceOf(bob) - b0, 45e18 + 56.25e18, "45 + 90 x 45/72");
        assertEq(yolo.balanceOf(dave) - d0, 27e18 + 33.75e18, "27 + 90 x 27/72");
        assertEq(yolo.balanceOf(DEAD) - dead0, 9e18 + 9e18, "5% at entry + the deferred 5% (not done)");
        assertEq(yolo.balanceOf(address(yoloPredict)), 0, "everyone paid in full, nothing left");
        assertEq(
            (yolo.balanceOf(bob) - b0) + (yolo.balanceOf(dave) - d0) + (yolo.balanceOf(DEAD) - dead0),
            180e18,
            "paid + burned == deposited, to the wei"
        );
    }

    // ================================================================== completion, unwind, rounding

    function test_CompletedTask_PotPaidOut_StillWillDoWon() public {
        uint256 t = _task10d();
        _predict(alice, t, true, 1e18);
        uint256 author0 = yolo.balanceOf(author);
        _accept(doer, t);
        assertEq(vault.getTask(t).pot, 0, "pot pays out to zero on acceptance");
        assertEq(uint8(yoloPredict.resolution(t)), uint8(YoloPredict.Resolution.WillDoWon));
        uint256 before = yolo.balanceOf(alice);
        vm.prank(alice);
        yoloPredict.claim(t); // lone winner, no loser side: her own 90% back
        assertEq(yolo.balanceOf(alice) - before, 0.9e18);
        assertEq(yolo.balanceOf(author) - author0, 0.025e18);
    }

    // A market voids only when the dev wallet cancels the task (Unwound, CancelTask.t.sol); a stuck dispute
    // resolves by its own timers (Emergency.t.sol covers that path generically).

    /// A winning side whose points all rounded to zero is not empty (reaudit money #1): no division by zero,
    /// the losing pool is split by position among its winners, the author gets nothing from it, the loser nothing.
    function test_TotalPointsRoundingToZero_SplitByPositionInsteadOfReverting() public {
        uint256 longDeadline = uint64(_now() + 1_000_000_000); // ~31.7 years: duration dominates a small effPosition
        uint256 t = _createWithDeadline(author, address(imd), 10e18, uint64(longDeadline));
        uint256 dead0 = yolo.balanceOf(DEAD);
        _predict(alice, t, true, 1e18); // at the task's creation: w = 1.0

        vm.warp(longDeadline - 1); // 1 second left, duration ~1e9: weight rounds to zero twice over
        _predict(bob, t, false, MIN_POSITION); // effPosition = 0.45e18, points -> 0 (floor twice)
        (, uint256 wontDoPool,, uint256 wontDoPointsTotal,) = _m(t);
        assertGt(wontDoPool, 0);
        assertEq(wontDoPointsTotal, 0, "weight rounded to zero even though a real position was taken");

        vm.warp(longDeadline + 1);
        vault.poke(t);
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Expired), "no submission: against side wins");
        assertEq(uint8(yoloPredict.resolution(t)), uint8(YoloPredict.Resolution.WontDoWon));

        uint256 author0 = yolo.balanceOf(author);
        uint256 bobBefore = yolo.balanceOf(bob);
        vm.prank(bob);
        yoloPredict.claim(t); // must not revert dividing by zero totalPoints
        assertEq(yolo.balanceOf(bob) - bobBefore, 0.45e18 + 0.9e18, "zero-point winner: 90% back + the losing pool");
        assertEq(yolo.balanceOf(author) - author0, 0, "somebody is on WON'T DO: nothing to the author");
        uint256 aliceBefore = yolo.balanceOf(alice);
        vm.prank(alice);
        yoloPredict.claim(t);
        assertEq(yolo.balanceOf(alice) - aliceBefore, 0, "the loser: nothing back");
        assertEq(yolo.balanceOf(DEAD) - dead0, 0.075e18 + 0.075e18, "entry 5% + deferred 5% (not done)");
        assertEq(yolo.balanceOf(address(yoloPredict)), 0);
    }

    // ================================================================== the accepted doer predicts too

    /// Anyone may predict, the accepted doer included, with no
    /// exclusion from the split at all - they keep their full winner's share like any other predictor, lone winner
    /// or not.
    function test_Doer_PositionBeforeSubmission_GetsFullWinnerShare() public {
        uint256 t = _task10d();
        _predict(doer, t, true, 10e18); // the future doer predicts from their own address before submitting
        _predict(bob, t, false, 10e18);
        uint256 s = _accept(doer, t);
        assertEq(vault.getTask(t).activeSub, s);

        uint256 dead0 = yolo.balanceOf(DEAD);
        uint256 author0 = yolo.balanceOf(author);
        uint256 doer0 = yolo.balanceOf(doer);
        vm.expectEmit(address(yoloPredict));
        emit YoloPredict.Settled(t, YoloPredict.Resolution.WillDoWon, doer, 0.5e18, 0.5e18, 0);
        vm.prank(erin); // anyone, no position needed
        yoloPredict.settle(t);
        assertEq(yolo.balanceOf(author) - author0, 0.5e18, "2.5% to the author");
        assertEq(yolo.balanceOf(doer) - doer0, 0.5e18, "2.5% to the doer, deferred part");
        assertEq(
            yolo.balanceOf(DEAD) - dead0, 1e18, "only the held entry 5%: the doer is still in the split, lone winner"
        );
        yoloPredict.settle(t); // once only

        doer0 = yolo.balanceOf(doer);
        vm.prank(doer);
        yoloPredict.claim(t);
        assertEq(yolo.balanceOf(doer) - doer0, 9e18 + 9e18, "own 90% plus bob's whole losing pool, lone winner");
        vm.prank(bob);
        yoloPredict.claim(t);
        assertEq(yolo.balanceOf(address(yoloPredict)), 0);
    }

    /// Claiming first, before anyone settles, gives the same full share.
    function test_Doer_ClaimingFirst_StillGetsFullShare() public {
        uint256 t = _task10d();
        uint256 dead0 = yolo.balanceOf(DEAD);
        _predict(doer, t, true, 10e18);
        _predict(bob, t, false, 10e18);
        _accept(doer, t);

        uint256 doerBefore = yolo.balanceOf(doer);
        vm.prank(doer);
        yoloPredict.claim(t);
        assertEq(yolo.balanceOf(doer) - doerBefore, 9e18 + 9e18 + 0.5e18, "own 90% + bob's pool + the deferred 2.5%");
        vm.prank(bob);
        yoloPredict.claim(t);
        assertEq(yolo.balanceOf(DEAD) - dead0, 1e18, "only the entry 5%, nothing left unclaimed");
        assertEq(yolo.balanceOf(address(yoloPredict)), 0);
    }

    /// The doer's points count in the split like anyone else's: the losing pool is shared by points, not handed
    /// whole to the other winner.
    function test_Doer_SharesTheLosingPoolByPoints() public {
        uint256 t = _task10d();
        _predict(alice, t, true, 10e18);
        _predict(doer, t, true, 10e18);
        _predict(bob, t, false, 20e18);
        uint256 dead0 = yolo.balanceOf(DEAD);
        _accept(doer, t);
        uint256 a0 = yolo.balanceOf(alice);
        uint256 doer0 = yolo.balanceOf(doer); // claiming first also settles: their deferred 2.5% lands now
        vm.prank(alice);
        yoloPredict.claim(t);
        assertEq(yolo.balanceOf(alice) - a0, 9e18 + 9e18, "her own 90% plus half the losing pool (equal points)");
        assertEq(yolo.balanceOf(doer) - doer0, 1e18, "the deferred 2.5% of 40, settled by alice's claim");
        doer0 = yolo.balanceOf(doer);
        vm.prank(doer);
        yoloPredict.claim(t);
        assertEq(yolo.balanceOf(doer) - doer0, 9e18 + 9e18, "own 90% plus the other half of the losing pool");
        assertEq(yolo.balanceOf(DEAD) - dead0, 2e18, "only the held entry 5% of 40: the doer is still in the split");
        assertEq(yolo.balanceOf(address(yoloPredict)), 0);
    }

    // ================================================================== a contributor after their position

    /// A contributor to the reward (or its $YOLO bonus) may still
    /// predict and keeps her full split share like anyone else - no exclusion, no cap on her share.
    function test_ContributorAfterPosition_StillGetsHerFullSplitShare() public {
        uint256 t = _task10d();
        _predict(alice, t, true, 10e18);
        _predict(dave, t, true, 10e18);
        _predict(bob, t, false, 20e18);
        _topUp(alice, t, 1e18); // after her position
        vm.prank(alice);
        yoloPredict.predict(t, true, 1e18); // a contributor may still take a new position too
        _accept(doer, t);

        uint256 dead0 = yolo.balanceOf(DEAD);
        uint256 d0 = yolo.balanceOf(dave);
        vm.prank(dave);
        yoloPredict.claim(t);
        uint256 daveShare = yolo.balanceOf(dave) - d0 - 9e18;
        // same timestamp, same weight: dave holds 9 of the 18.9 winning points
        assertApproxEqAbs(daveShare, uint256(18e18) * 90 / 189, 10, "dave: his points' share of the losing pool");
        uint256 a0 = yolo.balanceOf(alice);
        vm.prank(alice);
        yoloPredict.claim(t);
        assertEq(
            yolo.balanceOf(alice) - a0,
            9e18 + 0.9e18 + 18e18 - daveShare,
            "her two positions' 90% plus the rest of the pool"
        );
        assertEq(yolo.balanceOf(DEAD) - dead0, 2.05e18, "only the held entry 5% of 41, at settle");
        assertEq(yolo.balanceOf(address(yoloPredict)), 0);
    }

    /// A $YOLO bonus (YoloSweetener) after the position counts like a top-up (`gave`) and does not block a new
    /// position either.
    function test_SweetenerAfterPosition_StillGetsFullShare() public {
        uint256 t = _task10d();
        _predict(alice, t, true, 10e18);
        _predict(bob, t, false, 10e18);
        vm.prank(alice);
        sweetener.sweeten(t, 1e18);
        vm.prank(alice);
        yoloPredict.predict(t, true, 1e18);
        _accept(doer, t);
        uint256 a0 = yolo.balanceOf(alice);
        vm.prank(alice);
        yoloPredict.claim(t);
        assertEq(
            yolo.balanceOf(alice) - a0,
            9e18 + 0.9e18 + 9e18,
            "both her positions' 90% plus bob's whole pool (lone winner)"
        );
        vm.prank(bob);
        yoloPredict.claim(t);
        assertEq(yolo.balanceOf(address(yoloPredict)), 0);
    }

    // ================================================================== the deferred 5%

    /// Completed: half to the author, the rest (the odd wei too) to the accepted doer, straight from the market.
    function test_Deferred_HalfToAuthorHalfToDoer() public {
        uint256 t = _task10d();
        _predict(alice, t, true, 1e18 + 20); // burn = deferred = 5e16 + 1, eff = 9e17 + 18
        _predict(bob, t, false, 60e18); // burn = deferred = 3e18, eff = 54e18
        (,,,, uint256 deferred) = _m(t);
        assertEq(deferred, 3.05e18 + 1);
        uint256 author0 = yolo.balanceOf(author);
        uint256 doer0 = yolo.balanceOf(doer2);
        _accept(doer2, t);
        vm.expectEmit(address(yoloPredict));
        emit YoloPredict.Settled(t, YoloPredict.Resolution.WillDoWon, doer2, 1.525e18, 1.525e18 + 1, 0);
        yoloPredict.settle(t);
        assertEq(yolo.balanceOf(author) - author0, 1.525e18);
        assertEq(yolo.balanceOf(doer2) - doer0, 1.525e18 + 1);
        (uint64 openedAt, bool settled,,,,, uint256 left) = yoloPredict.markets(t);
        assertGt(openedAt, 0);
        assertTrue(settled);
        assertEq(left, 0);
        uint256 a0 = yolo.balanceOf(alice);
        vm.prank(alice);
        yoloPredict.claim(t);
        assertEq(yolo.balanceOf(alice) - a0, 9e17 + 18 + 54e18);
        vm.prank(bob);
        yoloPredict.claim(t);
        assertEq(yolo.balanceOf(address(yoloPredict)), 0);
    }

    /// Completed with nobody on WILL DO: the losing pool half to the author,
    /// half to the doer; the deferred still 2.5% / 2.5%; the loser gets nothing back.
    function test_Deferred_NobodyOnWillDo_PoolToAuthorAndDoer() public {
        uint256 t = _task10d();
        _predict(bob, t, false, 10e18);
        uint256 author0 = yolo.balanceOf(author);
        uint256 doer0 = yolo.balanceOf(doer);
        uint256 dead0 = yolo.balanceOf(DEAD);
        _accept(doer, t);
        assertEq(uint8(yoloPredict.resolution(t)), uint8(YoloPredict.Resolution.WillDoWon));
        vm.expectEmit(address(yoloPredict));
        emit YoloPredict.Settled(t, YoloPredict.Resolution.WillDoWon, doer, 0.25e18, 0.25e18, 0);
        yoloPredict.settle(t);
        assertEq(yolo.balanceOf(author) - author0, 0.25e18 + 4.5e18, "2.5% + half the losing pool");
        assertEq(yolo.balanceOf(doer) - doer0, 0.25e18 + 4.5e18, "2.5% + half the losing pool");
        uint256 b0 = yolo.balanceOf(bob);
        vm.prank(bob);
        yoloPredict.claim(t);
        assertEq(yolo.balanceOf(bob) - b0, 0, "the loser: nothing back");
        assertEq(yolo.balanceOf(DEAD) - dead0, 0.5e18, "only the held entry 5%, at settle");
        assertEq(yolo.balanceOf(address(yoloPredict)), 0);
    }

    /// Expired: the deferred 5% burns (nobody did it).
    function test_Deferred_BurnedOnExpiry() public {
        uint256 t = _task10d();
        _predict(alice, t, true, 10e18);
        _predict(bob, t, false, 10e18);
        uint256 author0 = yolo.balanceOf(author);
        uint256 dead0 = yolo.balanceOf(DEAD);
        _warp(10 days);
        vault.poke(t);
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Expired));
        vm.expectEmit(address(yoloPredict));
        emit YoloPredict.Settled(t, YoloPredict.Resolution.WontDoWon, address(0), 0, 0, 1e18);
        yoloPredict.settle(t);
        assertEq(yolo.balanceOf(DEAD) - dead0, 1e18 + 1e18, "the held entry 5% + the deferred 5%");
        assertEq(yolo.balanceOf(author), author0, "the author gets nothing on an expiry");
        uint256 b0 = yolo.balanceOf(bob);
        vm.prank(bob);
        yoloPredict.claim(t);
        assertEq(yolo.balanceOf(bob) - b0, 18e18);
        vm.prank(alice);
        yoloPredict.claim(t);
        assertEq(yolo.balanceOf(address(yoloPredict)), 0);
    }

    // ================================================================== claim / settle before final

    function test_ClaimBeforeFinalReverts() public {
        uint256 t = _task10d();
        _predict(alice, t, true, 1e18);
        vm.prank(alice);
        vm.expectRevert(YoloPredict.NotFinal.selector);
        yoloPredict.claim(t);
        vm.expectRevert(YoloPredict.NotFinal.selector);
        yoloPredict.settle(t);
    }

    // ================================================================== invariant-style fuzz: exact balance

    /// Burned + paid (claims and the deferred 5%) == deposited, to the wei; the market ends at 0; no double claim.
    function testFuzz_BurnedPlusPaidEqualsDeposited(uint256 aAmt, uint256 bAmt, uint256 cAmt, bool accept) public {
        aAmt = bound(aAmt, MIN_POSITION, 10_000e18);
        bAmt = bound(bAmt, MIN_POSITION, 10_000e18);
        cAmt = bound(cAmt, MIN_POSITION, 10_000e18);
        uint256 t = _createWithDeadline(author, address(imd), 10e18, uint64(_now() + 30 days));
        address[5] memory who = [alice, bob, dave, author, doer2];
        uint256[5] memory bal0;
        for (uint256 i; i < 5; ++i) {
            bal0[i] = yolo.balanceOf(who[i]);
        }
        uint256 dead0 = yolo.balanceOf(DEAD);

        _predict(alice, t, true, aAmt);
        _warp(1 days);
        _predict(bob, t, false, bAmt);
        _warp(1 days);
        _predict(dave, t, true, cAmt);

        if (accept) {
            _accept(doer2, t);
        } else {
            _warp(30 days);
            vault.poke(t);
        }

        for (uint256 i; i < 3; ++i) {
            vm.prank(who[i]);
            try yoloPredict.claim(t) {} catch {}
        }
        assertEq(yolo.balanceOf(address(yoloPredict)), 0, "nothing left: the last winner takes the dust");
        uint256 paid;
        uint256[3] memory dep = [aAmt, bAmt, cAmt];
        for (uint256 i; i < 5; ++i) {
            paid += yolo.balanceOf(who[i]) + (i < 3 ? dep[i] : 0) - bal0[i];
        }
        uint256 burned = yolo.balanceOf(DEAD) - dead0;
        assertEq(burned + paid, aAmt + bAmt + cAmt, "burned + paid == deposited, to the wei");

        // nobody can claim twice: a second round of claims must add nothing more
        uint256 snap = yolo.balanceOf(alice) + yolo.balanceOf(bob) + yolo.balanceOf(dave) + yolo.balanceOf(DEAD);
        for (uint256 i; i < 3; ++i) {
            vm.prank(who[i]);
            try yoloPredict.claim(t) {} catch {}
        }
        assertEq(
            yolo.balanceOf(alice) + yolo.balanceOf(bob) + yolo.balanceOf(dave) + yolo.balanceOf(DEAD),
            snap,
            "no double claim"
        );
    }
}
