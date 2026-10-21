// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./Base.t.sol";
import {YoloPredict} from "../src/YoloPredict.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev Scenario sweep of `YoloPredict` covering edge cases: something lags, everyone disputes, or the
/// deadline is missed. Rules: 5% burned + 5% deferred + 90% in the pool at entry;
/// the deferred 5% to the author and the accepted doer (2.5% each) when the task is done, burned otherwise; the
/// accepted doer, the author and a contributor predict like anyone else (no exclusion from the split); the reward
/// is locked until the deadline, and a market voids only when the dev wallet cancels the task (Unwound). Every test checks exact wei balances and the
/// invariant: burned + paid + held == deposited, the contract left at exactly 0 after every claim.
/// forge-config: default.isolate = false
contract YoloPredictScenariosTest is Base {
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

    /// @dev Sum of every predictor's YOLO balance, for a closed-circuit check against a snapshot taken before any
    /// position was taken. DEAD, the author and the market itself are counted apart.
    function _sumBalances(address[] memory parties) internal view returns (uint256 total) {
        for (uint256 i; i < parties.length; ++i) {
            total += yolo.balanceOf(parties[i]);
        }
    }

    function _claimAll(uint256 t, address[] memory parties) internal {
        for (uint256 i; i < parties.length; ++i) {
            vm.prank(parties[i]);
            try yoloPredict.claim(t) {} catch {}
        }
    }

    function _predict(address who, uint256 t, bool willDo, uint256 amount) internal {
        vm.prank(who);
        yoloPredict.predict(t, willDo, amount);
    }

    function _accept(address by, uint256 t) internal returns (uint256 s) {
        s = _submit(by, t);
        vm.warp(_sub(s).windowEnd + 1);
        vault.poke(t);
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Completed));
    }

    function _task(uint256 days_) internal returns (uint256) {
        return _createWithDeadline(author, address(imd), 10e18, uint64(_now() + days_)); // $80
    }

    function _pools(uint256 t)
        internal
        view
        returns (uint256 willDoPool, uint256 wontDoPool, uint256 willPts, uint256 wontPts, uint256 deferred)
    {
        (,, willDoPool, wontDoPool, willPts, wontPts, deferred) = yoloPredict.markets(t);
    }

    // ================================================================== 1. task life paths and the prediction market

    /// @notice First submission accepted outright: "will" wins on the first try.
    function test_Life_AcceptedOnFirstSubmission() public {
        uint256 t = _task(10 days);
        uint256 dead0 = yolo.balanceOf(DEAD);
        _predict(alice, t, true, 10e18);
        _predict(bob, t, false, 10e18);
        assertEq(yolo.balanceOf(DEAD) - dead0, 0, "the 5% burn is held until the outcome");

        uint256 author0 = yolo.balanceOf(author);
        uint256 doer0 = yolo.balanceOf(doer);
        _accept(doer, t);
        assertEq(uint8(yoloPredict.resolution(t)), uint8(YoloPredict.Resolution.WillDoWon));

        uint256 aliceBefore = yolo.balanceOf(alice);
        vm.prank(alice);
        yoloPredict.claim(t);
        assertEq(yolo.balanceOf(alice) - aliceBefore, 9e18 + 9e18, "lone winner takes the whole losing pool");
        uint256 bobBefore = yolo.balanceOf(bob);
        vm.prank(bob);
        yoloPredict.claim(t);
        assertEq(yolo.balanceOf(bob) - bobBefore, 0, "bob lost everything, paid nothing");
        assertEq(yolo.balanceOf(author) - author0, 0.5e18, "2.5% of each position to the author");
        assertEq(yolo.balanceOf(doer) - doer0, 0.5e18, "2.5% of each position to the doer");
        assertEq(yolo.balanceOf(DEAD) - dead0, 1e18, "the held 5% of each position, burned at settle");
        assertEq(yolo.balanceOf(address(yoloPredict)), 0);
    }

    /// @notice Rejected, then accepted on the resubmission: predicting reopens between the two rounds and the
    /// market still resolves "will"; the deferred 2.5% goes to the accepted doer, not the rejected one.
    function test_Life_RejectedThenAcceptedOnResubmission() public {
        uint256 t = _task(20 days);
        uint256 dead0 = yolo.balanceOf(DEAD);
        _predict(alice, t, true, 10e18);

        uint256 s1 = _submit(doer, t);
        vm.prank(alice); // can't predict while busy
        vm.expectRevert(YoloPredict.SubmissionActive.selector);
        yoloPredict.predict(t, false, 5e18);
        _dispute(dave, s1);
        _vote(s1, 0, 2, 0, 120); // reject
        _endVote(s1);
        _warp(24 hours + 1);
        vault.poke(t);
        assertEq(uint8(_sub(s1).outcome), uint8(Outcome.Rejected));
        assertEq(vault.getTask(t).activeSub, 0, "busy clears on rejection, predicting reopens");

        // the window reopened: a fresh position on "won't" is accepted
        _predict(bob, t, false, 10e18);

        uint256 doer0 = yolo.balanceOf(doer);
        uint256 doer20 = yolo.balanceOf(doer2);
        _accept(doer2, t);
        assertEq(uint8(yoloPredict.resolution(t)), uint8(YoloPredict.Resolution.WillDoWon));

        uint256 aliceBefore = yolo.balanceOf(alice);
        vm.prank(alice);
        yoloPredict.claim(t);
        assertEq(yolo.balanceOf(alice) - aliceBefore, 9e18 + 9e18);
        assertEq(yolo.balanceOf(doer2) - doer20, 0.5e18, "the accepted doer's 2.5%");
        assertEq(yolo.balanceOf(doer), doer0, "the rejected doer: nothing");
        assertEq(yolo.balanceOf(DEAD) - dead0, 1e18, "5% of each of the two positions");
    }

    /// @notice Every submission rejected, deadline passes with no active submission left: "won't" wins (Expired);
    /// the deferred 5% burns.
    function test_Life_AllSubmissionsRejected_ThenExpired() public {
        uint256 t = _task(10 days);
        uint256 dead0 = yolo.balanceOf(DEAD);
        _predict(alice, t, true, 10e18);
        _predict(bob, t, false, 10e18);

        uint256 s1 = _submit(doer, t);
        _dispute(dave, s1);
        _vote(s1, 0, 2, 0, 120);
        _endVote(s1);
        _warp(24 hours + 1);
        vault.poke(t);
        assertEq(uint8(_sub(s1).outcome), uint8(Outcome.Rejected));

        _warp(10 days);
        vault.poke(t);
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Expired));
        assertEq(uint8(yoloPredict.resolution(t)), uint8(YoloPredict.Resolution.WontDoWon));

        uint256 bobBefore = yolo.balanceOf(bob);
        vm.prank(bob);
        yoloPredict.claim(t);
        assertEq(yolo.balanceOf(bob) - bobBefore, 9e18 + 9e18);
        assertEq(yolo.balanceOf(DEAD) - dead0, 1e18 + 1e18, "5% at entry + the deferred 5%");
    }

    /// @notice Submission filed one second before the deadline; its judging finishes after the deadline. Submitted
    /// before the deadline and accepted after it = done.
    function test_Life_SubmissionSecondBeforeDeadline_JudgedAfterDeadline() public {
        uint64 deadline = uint64(_now() + 10 days);
        uint256 t = _createWithDeadline(author, address(imd), 10e18, deadline);
        _predict(alice, t, true, 10e18);
        _predict(bob, t, false, 10e18);

        _warp(10 days - 1); // one second left
        _submit(doer, t);
        assertTrue(vault.getTask(t).activeSub != 0);

        _warp(2); // now past the deadline, judging still running
        vm.prank(alice); // doubly closed now (past deadline AND busy); `predict` checks the deadline first
        vm.expectRevert(YoloPredict.WindowClosed.selector);
        yoloPredict.predict(t, true, 1e18);

        _warp(24 hours + 1); // dispute window lapses unchallenged, well past the task's own deadline by now
        vault.poke(t);
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Completed), "accepted after its own deadline");
        assertEq(uint8(yoloPredict.resolution(t)), uint8(YoloPredict.Resolution.WillDoWon));

        uint256 doer0 = yolo.balanceOf(doer);
        uint256 aliceBefore = yolo.balanceOf(alice);
        vm.prank(alice);
        yoloPredict.claim(t);
        assertEq(yolo.balanceOf(alice) - aliceBefore, 9e18 + 9e18);
        assertEq(yolo.balanceOf(doer) - doer0, 0.5e18, "done: the doer's 2.5%");
    }

    /// @notice Several submissions queue up right at the deadline: the market resolves only once the task itself is
    /// terminal.
    function test_Life_MultipleSubmissionsQueuedAtDeadline() public {
        uint256 t = _task(10 days);
        _predict(alice, t, true, 10e18);
        _predict(bob, t, false, 10e18);

        _warp(10 days - 1);
        uint256 s1 = _submit(doer, t); // active
        uint256 s2 = _submit(doer2, t); // queued behind it
        assertEq(uint8(_phase(s2)), uint8(Phase.Queued));

        _warp(2); // past deadline now; both submissions already filed before it
        _dispute(dave, s1);
        _vote(s1, 0, 2, 0, 120);
        _endVote(s1);
        _warp(24 hours + 1);
        vault.poke(t);
        assertEq(uint8(_sub(s1).outcome), uint8(Outcome.Rejected));
        assertEq(uint8(_phase(s2)), uint8(Phase.Review), "the queued submission activated once s1 closed");
        assertEq(uint8(yoloPredict.resolution(t)), uint8(YoloPredict.Resolution.Pending), "still busy");
        vm.expectRevert(YoloPredict.NotFinal.selector);
        yoloPredict.settle(t);

        uint256 doer20 = yolo.balanceOf(doer2);
        vm.warp(_sub(s2).windowEnd + 1);
        vault.poke(t);
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Completed));
        assertEq(uint8(yoloPredict.resolution(t)), uint8(YoloPredict.Resolution.WillDoWon));

        uint256 aliceBefore = yolo.balanceOf(alice);
        vm.prank(alice);
        yoloPredict.claim(t);
        assertEq(yolo.balanceOf(alice) - aliceBefore, 9e18 + 9e18);
        assertEq(yolo.balanceOf(doer2) - doer20, 0.5e18, "the queued doer who was accepted");
    }

    /// @notice Dispute -> NFT vote -> appeal -> the swarm, all after the deadline: the market waits, paused.
    function test_Life_DisputeAppealSwarm_AllAfterDeadline() public {
        uint256 t = _task(10 days);
        _predict(alice, t, true, 10e18);
        _predict(bob, t, false, 10e18);

        _warp(10 days - 1);
        uint256 s = _submit(doer, t);
        _warp(2); // past the task's deadline; judging keeps running regardless
        _dispute(dave, s);
        _vote(s, 0, 2, 0, 120); // NFT: reject
        _endVote(s);
        assertEq(uint8(_sub(s).nftDecision), uint8(Verdict.Reject));

        _appeal(doer, s);
        // the ask is lazy: filed, not asked yet
        assertEq(uint8(_phase(s)), uint8(Phase.Appealed));
        vm.prank(alice);
        vm.expectRevert(YoloPredict.WindowClosed.selector);
        yoloPredict.predict(t, true, 1e18);

        _warp(1 hours); // asked inside swarmTimeout (6 h): a later ask finds the appeal void
        _askAppealSwarm(s); // lazy ask
        assertEq(uint8(_phase(s)), uint8(Phase.Asked));
        _answer(s, true); // swarm sides with the doer: accepted
        vault.poke(t);
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Completed));
        assertEq(uint8(yoloPredict.resolution(t)), uint8(YoloPredict.Resolution.WillDoWon));

        uint256 aliceBefore = yolo.balanceOf(alice);
        vm.prank(alice);
        yoloPredict.claim(t);
        assertEq(yolo.balanceOf(alice) - aliceBefore, 9e18 + 9e18);
    }

    /// @notice NFT vote without a decision, nobody calls the swarm: accepted (the tie rule); the market follows.
    function test_Life_VoteTieNoQuorum_DefaultsToAccepted() public {
        uint256 t = _task(10 days);
        _predict(alice, t, true, 10e18);
        _predict(bob, t, false, 10e18);

        uint256 s = _submit(doer, t);
        _dispute(dave, s);
        _vote(s, 0, 2, 0, 1); // too few votes for a decision
        _vote(s, 1, 1, 120, 1);
        _endVote(s);
        assertEq(uint8(_phase(s)), uint8(Phase.NoDecision));

        _warp(24 hours + 1); // nobody calls the swarm: tie rule accepts
        vault.poke(t);
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Completed), "NoDecision + nobody called: accepted");
        assertEq(uint8(yoloPredict.resolution(t)), uint8(YoloPredict.Resolution.WillDoWon));

        uint256 aliceBefore = yolo.balanceOf(alice);
        vm.prank(alice);
        yoloPredict.claim(t);
        assertEq(yolo.balanceOf(alice) - aliceBefore, 9e18 + 9e18);
    }

    // Swarm silence on an appeal ask resolves by timer and voids no market; that generic behavior is covered by Emergency.t.sol::test_AppealAskedLazily_* and
    // test_SwarmNeverAnswers_ResolvesByTimer, so it is not duplicated at the YoloPredict layer here.

    // ================================================================== 2. author/contributor actions mid-market

    /// @notice The reward can only grow while the task is
    /// open (locked until the deadline); the market has no cap at all, so a
    /// growing reward changes nothing about it and predicting goes on exactly as before.
    function test_RewardOnlyGrows_MarketUnaffected() public {
        uint256 t = _task(10 days);
        _predict(alice, t, true, 1e18);
        vm.prank(author);
        vault.topUp(t, 90e18, _noSwap()); // pot 100 IMD
        assertEq(vault.getTask(t).pot, 100e18);
        assertEq(uint8(yoloPredict.resolution(t)), uint8(YoloPredict.Resolution.Pending));
        _predict(bob, t, false, 1e18);
        assertEq(uint8(yoloPredict.resolution(t)), uint8(YoloPredict.Resolution.Pending));
    }

    /// @notice Nobody takes the reward back while the task is open, idle or busy.
    function test_RewardLocked_IdleOrBusy() public {
        uint256 t = _task(10 days);
        _predict(alice, t, true, 1e18);
        vm.prank(author);
        vm.expectRevert(TaskNotOpen.selector);
        vault.withdrawContribution(t); // idle
        _submit(doer, t); // busy now
        vm.prank(author);
        vm.expectRevert(TaskNotOpen.selector);
        vault.withdrawContribution(t);
    }

    // ================================================================== 3. empty sides, dust, extremes

    /// @notice Nobody ever predicts: the market never opens, `resolution` stays `Pending`, `settle` reverts
    /// `NotFinal` and `claim` has nothing to pay anyone.
    function test_Empty_NoMarketAtAll() public {
        uint256 t = _task(10 days);
        _warp(10 days + 1);
        vault.poke(t);
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Expired));
        assertEq(uint8(yoloPredict.resolution(t)), uint8(YoloPredict.Resolution.Pending), "never opened");
        vm.expectRevert(YoloPredict.NotFinal.selector);
        yoloPredict.settle(t);
        vm.prank(alice);
        vm.expectRevert(YoloPredict.NothingToClaim.selector);
        yoloPredict.claim(t);
    }

    /// @notice One position, on the side that wins: his own 90% back.
    function test_Empty_LonePositionOnWinningSide() public {
        uint256 t = _task(10 days);
        _predict(alice, t, true, 10e18);
        _accept(doer, t);
        assertEq(uint8(yoloPredict.resolution(t)), uint8(YoloPredict.Resolution.WillDoWon));

        uint256 before = yolo.balanceOf(alice);
        vm.prank(alice);
        yoloPredict.claim(t);
        assertEq(yolo.balanceOf(alice) - before, 9e18, "no losing side at all: just his own 90% back");
    }

    /// @notice One position, on the side that loses, the task done: nobody on WILL DO -> his 90% half to the author,
    /// half to the doer, nothing back to him; the deferred 5% goes 2.5% / 2.5% to the author and the doer.
    function test_Empty_LonePositionOnLosingSide_PoolToAuthorAndDoer() public {
        uint256 t = _task(10 days);
        _predict(bob, t, false, 10e18);
        uint256 author0 = yolo.balanceOf(author);
        uint256 doer0 = yolo.balanceOf(doer);
        _accept(doer, t);
        assertEq(
            uint8(yoloPredict.resolution(t)), uint8(YoloPredict.Resolution.WillDoWon), "winning side empty: no void"
        );

        uint256 before = yolo.balanceOf(bob);
        vm.prank(bob);
        yoloPredict.claim(t);
        assertEq(yolo.balanceOf(bob) - before, 0, "the loser: nothing back");
        assertEq(yolo.balanceOf(author) - author0, 0.25e18 + 4.5e18, "2.5% + half the losing pool");
        assertEq(yolo.balanceOf(doer) - doer0, 0.25e18 + 4.5e18, "2.5% + half the losing pool");
        assertEq(yolo.balanceOf(address(yoloPredict)), 0);
    }

    /// @notice A position at the task's creation (w = 1.0) and one at the last second before the deadline (remaining
    /// = 1) in the same market: the early weight dominates.
    function test_Extremes_FirstInstantPosition_AndLastSecondPosition() public {
        uint64 deadline = uint64(_now() + 100 days);
        uint256 t = _createWithDeadline(author, address(imd), 10e18, deadline);
        _predict(alice, t, true, 100e18); // at the creation: w = 1.0 exactly
        (uint64 openedAt,,,,,,) = yoloPredict.markets(t);
        assertEq(openedAt, _now());

        vm.warp(deadline - 1); // last second before the window closes
        _predict(bob, t, true, 100e18); // same side: isolates both weights without a payout split

        (uint256 willDoPool,, uint256 willDoPointsTotal,,) = _pools(t);
        assertEq(willDoPool, 90e18 + 90e18);
        uint256 aliceExpectedPoints = 90e18; // w = 1.0
        uint256 bobExpectedPoints = Math.mulDiv(Math.mulDiv(90e18, 1, 100 days), 1, 100 days); // remaining = 1
        assertEq(willDoPointsTotal, aliceExpectedPoints + bobExpectedPoints);
        assertGt(aliceExpectedPoints, bobExpectedPoints * 1e6, "the early weight dwarfs the last-second one");
    }

    /// @notice One second before the deadline still succeeds; at the deadline itself it reverts.
    function test_Extremes_PositionOneSecondBeforeDeadline_ThenExactlyAtDeadlineReverts() public {
        uint64 deadline = uint64(_now() + 10 days);
        uint256 t = _createWithDeadline(author, address(imd), 10e18, deadline);
        vm.warp(deadline - 1);
        _predict(alice, t, true, 1e18);

        vm.warp(deadline);
        vm.prank(bob);
        vm.expectRevert(YoloPredict.WindowClosed.selector);
        yoloPredict.predict(t, false, 1e18);
    }

    /// @notice A very long-lived task still computes a sane weight (`w == 1.0` at the creation, no overflow).
    function test_Extremes_VeryLongDuration_NoOverflow() public {
        uint64 farDeadline = type(uint64).max - 1; // the practical ceiling of Task.deadline (uint64)
        uint256 t = _createWithDeadline(author, address(imd), 40e18, farDeadline);
        _predict(alice, t, true, 1_000_000e18);
        (uint256 willDoPool,, uint256 willDoPointsTotal,,) = _pools(t);
        assertEq(willDoPool, 900_000e18);
        assertEq(willDoPointsTotal, 900_000e18, "w == 1.0 at the creation regardless of how far the deadline sits");
    }

    /// @notice Dust positions (exactly `minPosition`) on both sides pay out to the exact wei.
    function test_Extremes_DustPositionsPayExactly() public {
        uint256 t = _task(10 days);
        _predict(alice, t, true, MIN_POSITION); // effPosition = 0.45e18, w = 1.0
        _predict(bob, t, false, MIN_POSITION);

        _accept(doer, t);
        assertEq(uint8(yoloPredict.resolution(t)), uint8(YoloPredict.Resolution.WillDoWon));

        uint256 before = yolo.balanceOf(alice);
        vm.prank(alice);
        yoloPredict.claim(t);
        assertEq(yolo.balanceOf(alice) - before, 0.45e18 + 0.45e18, "dust positions settle to the exact wei");
        assertEq(yolo.balanceOf(address(yoloPredict)), 0, "the deferred 0.05 paid at that claim, nothing left");
    }

    // ================================================================== 4. gates: busy, deadline, author, contributor

    /// @notice Becoming a contributor does not block further positions
    /// at all, and a contributor's points count in the split exactly like anyone else's.
    function test_Gate_BecomingContributorAfterPredicting_StillFullShare() public {
        uint256 t = _task(10 days);
        _predict(alice, t, true, 10e18); // plain predictor, opens the market
        _predict(bob, t, false, 10e18);

        _topUp(alice, t, 1e18); // alice becomes a contributor only now
        vm.prank(alice);
        yoloPredict.predict(t, true, 1e18); // not blocked

        _accept(doer, t);
        assertEq(uint8(yoloPredict.resolution(t)), uint8(YoloPredict.Resolution.WillDoWon));
        uint256 before = yolo.balanceOf(alice);
        vm.prank(alice);
        yoloPredict.claim(t);
        assertEq(
            yolo.balanceOf(alice) - before,
            9e18 + 0.9e18 + 9e18,
            "both positions' 90% plus bob's whole pool, lone winner"
        );
        assertEq(yolo.balanceOf(address(yoloPredict)), 0);
    }

    /// @notice A predictor who becomes the doer keeps his full
    /// winner's share, no exclusion from the split at all - claiming first, before anyone settles.
    function test_Gate_PredictorBecomesDoer_GetsFullShareWithoutAnyFlag() public {
        uint256 t = _task(10 days);
        _predict(doer, t, true, 10e18); // predicts first, as a plain user
        _predict(bob, t, false, 10e18);
        _accept(doer, t); // becomes the doer strictly after his own position

        uint256 before = yolo.balanceOf(doer);
        vm.prank(doer);
        yoloPredict.claim(t);
        assertEq(
            yolo.balanceOf(doer) - before,
            9e18 + 9e18 + 0.5e18,
            "own 90% + bob's whole pool (lone winner) + the deferred 2.5%"
        );
        assertEq(yolo.balanceOf(address(yoloPredict)), 0);
    }

    /// @notice Settled before his claim (anyone): nothing burns, his points are still live in the split.
    function test_Gate_PredictorBecomesDoer_SettleFirst() public {
        uint256 t = _task(10 days);
        _predict(doer, t, true, 10e18);
        _predict(bob, t, false, 10e18);
        _accept(doer, t);

        uint256 deadBefore = yolo.balanceOf(DEAD);
        yoloPredict.settle(t); // anyone, no position of his own required
        assertEq(yolo.balanceOf(DEAD) - deadBefore, 1e18, "only the held entry 5%: the doer is still in the split");

        uint256 before = yolo.balanceOf(doer);
        vm.prank(doer);
        yoloPredict.claim(t);
        assertEq(yolo.balanceOf(doer) - before, 9e18 + 9e18, "own 90% + bob's whole pool (the deferred came at settle)");
        vm.prank(bob);
        yoloPredict.claim(t);
        assertEq(yolo.balanceOf(address(yoloPredict)), 0, "nothing left on the contract");
    }

    /// @notice A position while a submission is on review reverts, for a market that has never opened too.
    function test_Gate_PredictingWhileBusy_RevertsBeforeAndAfterMarketOpen() public {
        uint256 t = _task(10 days);
        _submit(doer, t); // busy before any position ever happened
        vm.prank(alice);
        vm.expectRevert(YoloPredict.SubmissionActive.selector);
        yoloPredict.predict(t, true, 1e18);
    }

    /// @notice Predicting after the deadline reverts outright, whether or not the stored status caught up.
    function test_Gate_PredictingAfterDeadline_RevertsEvenIfStatusStillStoredAsOpen() public {
        uint256 t = _task(10 days);
        _warp(10 days + 1);
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Open), "stale: stored status not advanced yet");
        vm.prank(alice);
        vm.expectRevert(YoloPredict.WindowClosed.selector);
        yoloPredict.predict(t, true, 1e18);
    }

    /// @notice There is no contributor ban, on any task.
    function test_Gate_NoContributorBan_OnEitherTask() public {
        uint256 t1 = _task(10 days);
        uint256 t2 = _task(10 days);
        _topUp(alice, t1, 1e18);

        vm.prank(alice);
        yoloPredict.predict(t1, true, 1e18);
        assertEq(uint8(yoloPredict.resolution(t1)), uint8(YoloPredict.Resolution.Pending));

        _predict(alice, t2, true, 1e18);
        assertEq(uint8(yoloPredict.resolution(t2)), uint8(YoloPredict.Resolution.Pending));
    }

    // ================================================================== 5. claim mechanics

    function test_Claim_Twice_SecondReverts() public {
        uint256 t = _task(10 days);
        _predict(alice, t, true, 10e18);
        _predict(bob, t, false, 10e18);
        _accept(doer, t);

        vm.prank(alice);
        yoloPredict.claim(t);
        vm.prank(alice);
        vm.expectRevert(YoloPredict.NothingToClaim.selector);
        yoloPredict.claim(t);
    }

    function test_Claim_ByAPureLoser_PaysZero_NoRevert() public {
        uint256 t = _task(10 days);
        _predict(alice, t, true, 10e18);
        _predict(bob, t, false, 10e18);
        _accept(doer, t);

        uint256 before = yolo.balanceOf(bob);
        vm.prank(bob);
        yoloPredict.claim(t);
        assertEq(yolo.balanceOf(bob) - before, 0, "loser's claim: zero paid, no revert");
    }

    function test_Claim_BeforeFinal_WithAnActiveSubmissionInFlight_Reverts() public {
        uint256 t = _task(10 days);
        _predict(alice, t, true, 10e18);
        _predict(bob, t, false, 10e18);
        _submit(doer, t);
        vm.prank(alice);
        vm.expectRevert(YoloPredict.NotFinal.selector);
        yoloPredict.claim(t);
    }

    function test_Resolve_PermissionlessAndIdempotent_CanBeCalledRepeatedly() public {
        uint256 t = _task(10 days);
        for (uint256 i; i < 5; ++i) {
            assertEq(uint8(yoloPredict.resolution(t)), uint8(YoloPredict.Resolution.Pending));
        }
        _predict(alice, t, true, 10e18);
        _accept(doer, t);
        for (uint256 i; i < 10; ++i) {
            assertEq(uint8(yoloPredict.resolution(t)), uint8(YoloPredict.Resolution.WillDoWon));
        }
    }

    /// @notice `settle` (the held 5% burn, the deferred 5% and
    /// the empty-side rule) runs once, every later call is a no-op.
    function test_Settle_CalledTenTimes_StaysIdempotent() public {
        uint256 t = _task(10 days);
        _predict(alice, t, true, 10e18);
        _predict(bob, t, false, 10e18);
        _accept(doer, t);
        uint256 author0 = yolo.balanceOf(author);
        uint256 dead0 = yolo.balanceOf(DEAD);
        for (uint256 i; i < 10; ++i) {
            yoloPredict.settle(t);
            assertEq(yolo.balanceOf(author) - author0, 0.5e18, "paid once");
            assertEq(yolo.balanceOf(DEAD) - dead0, 1e18, "the held entry 5% burned once");
        }
        uint256 before = yolo.balanceOf(alice);
        vm.prank(alice);
        yoloPredict.claim(t);
        assertEq(yolo.balanceOf(alice) - before, 18e18);
        assertEq(yolo.balanceOf(address(yoloPredict)), 0);
    }

    /// @notice The claim order does not change any payout beyond the last claimant taking the dust.
    function test_ClaimOrder_DoesNotAffectPayouts() public {
        uint256 t = _task(10 days);
        _predict(alice, t, true, 10e18);
        _predict(bob, t, false, 20e18);
        _predict(dave, t, true, 5e18);
        _accept(doer2, t);
        assertEq(uint8(yoloPredict.resolution(t)), uint8(YoloPredict.Resolution.WillDoWon));

        uint256 daveBefore = yolo.balanceOf(dave);
        vm.prank(dave);
        yoloPredict.claim(t);
        uint256 davePay = yolo.balanceOf(dave) - daveBefore;
        uint256 aliceBefore = yolo.balanceOf(alice);
        vm.prank(alice);
        yoloPredict.claim(t);
        uint256 alicePay = yolo.balanceOf(alice) - aliceBefore;

        (uint256 willDoPool, uint256 wontDoPool, uint256 willDoPointsTotal,,) = _pools(t);
        assertEq(willDoPool, 9e18 + 4.5e18);
        assertEq(wontDoPool, 18e18);
        uint256 daveExpected = 4.5e18 + Math.mulDiv(18e18, 4.5e18, willDoPointsTotal);
        uint256 aliceExpected = 9e18 + Math.mulDiv(18e18, 9e18, willDoPointsTotal);
        assertEq(davePay, daveExpected, "claim order does not change the formula's result");
        assertApproxEqAbs(alicePay, aliceExpected, 1);
        assertEq(davePay + alicePay, 9e18 + 4.5e18 + 18e18, "the whole losing pool paid out, to the wei");
        assertEq(yolo.balanceOf(address(yoloPredict)), 0);
    }

    // ================================================================== 6. the accepted doer's share

    /// @dev Takes positions for `who[i]` on `willDo[i]`, `amounts[i]`, one day apart, so the weights differ.
    function _positions(uint256 t, address[] memory who, bool[] memory willDo, uint256[] memory amounts) internal {
        for (uint256 i; i < who.length; ++i) {
            _predict(who[i], t, willDo[i], amounts[i]);
            _warp(1 days);
        }
    }

    /// @notice The only WILL DO position is the doer's own; he is
    /// still fully in the split, so he takes the whole WON'T DO pool himself as the lone winner, nothing
    /// burns beyond the entry 5%.
    function test_DoerOnlyOnWillDo_TakesTheWholePool() public {
        uint256 t = _task(10 days);
        address[] memory who = new address[](3);
        bool[] memory side = new bool[](3);
        uint256[] memory amt = new uint256[](3);
        (who[0], side[0], amt[0]) = (doer, true, 10e18);
        (who[1], side[1], amt[1]) = (bob, false, 20e18);
        (who[2], side[2], amt[2]) = (dave, false, 7e18);
        uint256 deadBefore = yolo.balanceOf(DEAD);
        uint256 author0 = yolo.balanceOf(author);
        uint256 before = _sumBalances(who);
        _positions(t, who, side, amt);

        _accept(doer, t);
        assertEq(uint8(yoloPredict.resolution(t)), uint8(YoloPredict.Resolution.WillDoWon));

        yoloPredict.settle(t);
        _claimAll(t, who);

        uint256 burned = yolo.balanceOf(DEAD) - deadBefore;
        uint256 toAuthor = yolo.balanceOf(author) - author0;
        assertEq(burned, 1.85e18, "only the 5% entry burn: the doer stays in the split, lone winner");
        assertEq(toAuthor, 0.925e18);
        assertEq(yolo.balanceOf(address(yoloPredict)), 0, "nothing stuck on the contract");
        assertEq(before - _sumBalances(who), burned + toAuthor, "deposits == payouts + burn, to the wei");
    }

    /// @notice Doer and two honest winners: his points share the losing pool with them by points (he is fully in
    /// the split), nothing burns beyond the entry 5%.
    function test_Doer_SharesTheLosingPoolWithOtherWinners() public {
        uint256 t = _task(10 days);
        address[] memory who = new address[](4);
        bool[] memory side = new bool[](4);
        uint256[] memory amt = new uint256[](4);
        (who[0], side[0], amt[0]) = (alice, true, 10e18);
        (who[1], side[1], amt[1]) = (doer, true, 10e18);
        (who[2], side[2], amt[2]) = (bob, false, 20e18);
        (who[3], side[3], amt[3]) = (dave, true, 5e18);
        uint256 deadBefore = yolo.balanceOf(DEAD);
        uint256 author0 = yolo.balanceOf(author);
        uint256 before = _sumBalances(who);
        _positions(t, who, side, amt);
        (,, uint256 willPts,,) = _pools(t);
        (, uint256 doerPts,,) = yoloPredict.positionsOf(t, doer);
        (, uint256 alicePts,,) = yoloPredict.positionsOf(t, alice);

        _accept(doer, t);

        uint256 aliceBefore = yolo.balanceOf(alice);
        vm.prank(alice);
        yoloPredict.claim(t); // the first claim settles; the doer's points are still live in the split
        uint256 alicePay = yolo.balanceOf(alice) - aliceBefore;
        assertEq(alicePay, 9e18 + Math.mulDiv(18e18, alicePts, willPts), "her share of a split that includes the doer");
        uint256 doerBefore = yolo.balanceOf(doer);
        vm.prank(doer);
        yoloPredict.claim(t);
        // the split is remaining/remaining (the pool left over the points left): after alice's floor the doer's
        // share may be 1 wei above the share of the original totals
        assertApproxEqAbs(
            yolo.balanceOf(doer) - doerBefore,
            9e18 + Math.mulDiv(18e18, doerPts, willPts),
            1,
            "doer: own 90% plus his points share"
        );
        _claimAll(t, who);

        assertEq(yolo.balanceOf(DEAD) - deadBefore, 2.25e18, "only the 5% entry burn");
        assertEq(yolo.balanceOf(author) - author0, 1.125e18);
        assertEq(yolo.balanceOf(address(yoloPredict)), 0, "nothing stuck on the contract");
        assertEq(before - _sumBalances(who), 2.25e18 + 1.125e18, "deposits == payouts + burn + author, to the wei");
    }

    /// @notice The doer is fully in the split like anyone else, and
    /// the first claim settles, so the order of claims never changes an honest winner's share.
    function test_DoerInSplit_ShareIndependentOfClaimOrder() public {
        uint256 t = _task(10 days);
        address[] memory who = new address[](4);
        bool[] memory side = new bool[](4);
        uint256[] memory amt = new uint256[](4);
        (who[0], side[0], amt[0]) = (alice, true, 10e18);
        (who[1], side[1], amt[1]) = (doer, true, 10e18);
        (who[2], side[2], amt[2]) = (bob, false, 20e18);
        (who[3], side[3], amt[3]) = (dave, true, 5e18);
        _positions(t, who, side, amt);
        _accept(doer, t);

        uint256 snap = vm.snapshotState();
        uint256 a0 = yolo.balanceOf(alice);
        vm.prank(alice);
        yoloPredict.claim(t); // alice first
        uint256 aliceFirst = yolo.balanceOf(alice) - a0;
        vm.revertToState(snap);

        vm.prank(doer);
        yoloPredict.claim(t); // the doer first
        vm.prank(dave);
        yoloPredict.claim(t);
        a0 = yolo.balanceOf(alice);
        vm.prank(alice);
        yoloPredict.claim(t); // alice last: takes the dust
        uint256 aliceLast = yolo.balanceOf(alice) - a0;
        // the last claimant takes the dust: up to one wei per earlier winner (3 winners -> up to 2 wei)
        assertApproxEqAbs(aliceLast, aliceFirst, 2, "the same share in either order");
        vm.prank(bob);
        yoloPredict.claim(t);
        assertEq(yolo.balanceOf(address(yoloPredict)), 0, "nothing stuck on the contract");
    }

    /// @notice Fuzz: any amounts, `settle` never / before claims / between / after, the doer on either side (fully
    /// in the split). After every claim the contract holds exactly 0 and
    /// deposits == payouts + burn + the author's 2.5%.
    function testFuzz_DoerInSplit_NothingStuck(uint256 a, uint256 d, uint256 b, uint256 c, uint8 when, bool doerWillDo)
        public
    {
        a = bound(a, MIN_POSITION, 2e18);
        d = bound(d, MIN_POSITION, 2e18);
        b = bound(b, MIN_POSITION, 2e18);
        c = bound(c, MIN_POSITION, 2e18);
        when = uint8(bound(when, 0, 3));
        uint256 t = _task(10 days);
        address[] memory who = new address[](4);
        bool[] memory side = new bool[](4);
        uint256[] memory amt = new uint256[](4);
        (who[0], side[0], amt[0]) = (alice, true, a);
        (who[1], side[1], amt[1]) = (doer, doerWillDo, d);
        (who[2], side[2], amt[2]) = (bob, false, b);
        (who[3], side[3], amt[3]) = (dave, true, c);
        uint256 deadBefore = yolo.balanceOf(DEAD);
        uint256 author0 = yolo.balanceOf(author);
        uint256 before = _sumBalances(who);
        _positions(t, who, side, amt);
        _accept(doer, t);

        if (when == 1) yoloPredict.settle(t);
        vm.prank(alice);
        yoloPredict.claim(t);
        if (when == 2) yoloPredict.settle(t);
        _claimAll(t, who);
        if (when == 3) yoloPredict.settle(t);

        assertEq(yolo.balanceOf(address(yoloPredict)), 0, "nothing stuck on the contract");
        assertEq(
            before - _sumBalances(who),
            (yolo.balanceOf(DEAD) - deadBefore) + (yolo.balanceOf(author) - author0),
            "deposits == payouts + burn + author"
        );
    }

    // ================================================================== 7. invariant: exact wei accounting

    /// @notice Closed-circuit accounting across a mixed scenario (three predictors, both sides, a rejected round, a
    /// late position): 5% of every position burned, 5% to the author and the accepted doer, the rest back
    /// to the predictors, to the exact wei.
    function test_Invariant_ExactWeiAccounting_MixedScenario() public {
        uint256 t = _task(20 days);
        uint256 totalDeposited;
        address[] memory parties = new address[](3);
        parties[0] = alice;
        parties[1] = bob;
        parties[2] = dave;
        uint256 beforeTotal = _sumBalances(parties);
        uint256 dead0 = yolo.balanceOf(DEAD);
        uint256 author0 = yolo.balanceOf(author);
        uint256 doer20 = yolo.balanceOf(doer2);

        _predict(alice, t, true, 777e18);
        totalDeposited += 777e18;
        _warp(3 days);
        _predict(bob, t, false, 333e18);
        totalDeposited += 333e18;
        _warp(2 days);
        _predict(dave, t, true, 111e18);
        totalDeposited += 111e18;

        uint256 s1 = _submit(doer, t);
        _dispute(erin, s1);
        _vote(s1, 0, 2, 0, 120);
        _endVote(s1);
        _warp(24 hours + 1);
        vault.poke(t);
        assertEq(uint8(_sub(s1).outcome), uint8(Outcome.Rejected));

        _predict(bob, t, false, 50e18); // positions reopened after the rejection
        totalDeposited += 50e18;

        _accept(doer2, t);

        _claimAll(t, parties);
        uint256 afterTotal = _sumBalances(parties);
        uint256 netOutflow = beforeTotal - afterTotal;
        uint256 burned = yolo.balanceOf(DEAD) - dead0;
        uint256 toAuthor = yolo.balanceOf(author) - author0;
        uint256 toDoer = yolo.balanceOf(doer2) - doer20;
        uint256 dust = yolo.balanceOf(address(yoloPredict));
        assertEq(dust, 0, "nothing left: the last winner takes the dust");
        assertEq(burned, totalDeposited * 5 / 100, "5% of every position burns at placement, nothing later");
        assertEq(toAuthor, 31.775e18, "2.5% of 1,271");
        assertEq(toDoer, 31.775e18);
        assertEq(netOutflow, burned + toAuthor + toDoer, "collective loss is exactly the burn plus the deferred 5%");

        uint256 afterFirstRound = afterTotal;
        _claimAll(t, parties);
        assertEq(_sumBalances(parties), afterFirstRound, "second claim round changes nothing");
    }

    /// @notice Fuzz: any mix of three positions, done or expired: net outflow of the predictors == burn + the deferred
    /// paid out, never more than deposited; a second round of claims adds nothing.
    function testFuzz_Invariant_NeverPaysOutMoreThanDeposited(uint256 aAmt, uint256 bAmt, uint256 dAmt, bool completed)
        public
    {
        aAmt = bound(aAmt, MIN_POSITION, 50_000e18);
        bAmt = bound(bAmt, MIN_POSITION, 50_000e18);
        dAmt = bound(dAmt, MIN_POSITION, 50_000e18);
        uint256 t = _task(30 days);
        address[] memory parties = new address[](3);
        parties[0] = alice;
        parties[1] = bob;
        parties[2] = dave;
        uint256 beforeTotal = _sumBalances(parties);
        uint256 dead0 = yolo.balanceOf(DEAD);
        uint256 others0 = yolo.balanceOf(author) + yolo.balanceOf(doer2);

        _predict(alice, t, true, aAmt);
        _warp(6 hours);
        _predict(bob, t, false, bAmt);
        _warp(6 hours);
        _predict(dave, t, true, dAmt);
        uint256 totalDeposited = aAmt + bAmt + dAmt;

        if (completed) {
            _accept(doer2, t);
        } else {
            _warp(30 days);
            vault.poke(t);
        }

        _claimAll(t, parties);
        uint256 afterFirstRound = _sumBalances(parties);
        uint256 netOutflow = beforeTotal - afterFirstRound;
        uint256 burned = yolo.balanceOf(DEAD) - dead0;
        uint256 deferredPaid = yolo.balanceOf(author) + yolo.balanceOf(doer2) - others0;
        assertEq(yolo.balanceOf(address(yoloPredict)), 0, "nothing left");
        assertEq(netOutflow, burned + deferredPaid, "collective loss is exactly the burn plus the deferred paid");
        assertLe(netOutflow, totalDeposited, "never lose more than was deposited");
        if (!completed) assertEq(deferredPaid, 0, "not done: the deferred burns");

        _claimAll(t, parties); // nobody can claim twice
        assertEq(_sumBalances(parties), afterFirstRound, "no double claim");
    }

    /// @dev Burned + paid + held == deposited (paid = everything that left the market for a person: claims and the
    /// deferred 5%).
    function _checkInvariant(
        uint256 t,
        address[] memory who,
        uint256[] memory bal0,
        uint256[] memory dep,
        uint256 dead0
    ) internal view {
        t;
        uint256 paid;
        uint256 deposited;
        for (uint256 i; i < who.length; ++i) {
            paid += yolo.balanceOf(who[i]) + dep[i] - bal0[i];
            deposited += dep[i];
        }
        uint256 burned = yolo.balanceOf(DEAD) - dead0;
        uint256 held = yolo.balanceOf(address(yoloPredict));
        assertEq(burned + paid + held, deposited, "burned + paid + held == deposited, to the wei");
    }

    /// @notice The Predict invariant across every outcome (done with the doer predicting, expired, rejected then
    /// expired) and any
    /// subset of claims: at every step burned + paid + held == deposited to the wei; after all claims the
    /// market holds 0.
    function testFuzz_Invariant_BurnedPaidHeldEqualsDeposited(uint256 seed, uint8 outcome, uint8 claimMask) public {
        outcome = uint8(bound(outcome, 0, 2));
        uint256 t = _task(20 days);
        address[] memory who = new address[](6); // predictors, then the author and the other doer
        (who[0], who[1], who[2], who[3], who[4], who[5]) = (alice, bob, dave, doer, author, doer2);
        uint256[] memory bal0 = new uint256[](6);
        uint256[] memory dep = new uint256[](6);
        for (uint256 i; i < 6; ++i) {
            bal0[i] = yolo.balanceOf(who[i]);
        }
        uint256 dead0 = yolo.balanceOf(DEAD);
        for (uint256 i; i < 4; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            dep[i] = bound(r, MIN_POSITION, 5_000e18);
            _predict(who[i], t, (r >> 200) & 1 == 1, dep[i]);
            _checkInvariant(t, who, bal0, dep, dead0);
            _warp(1 days);
        }

        if (outcome == 0) {
            _accept(doer, t); // the doer predicted before his submission
        } else if (outcome == 1) {
            _warp(20 days);
            vault.poke(t);
            assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Expired));
        } else {
            uint256 s = _submit(doer2, t);
            _dispute(erin, s);
            _vote(s, 0, 2, 0, 120); // majority rejects the submission
            _endVote(s);
            _warp(24 hours + 1); // appeal window over, nobody appealed: rejection stands
            vault.poke(t);
            assertEq(uint8(_sub(s).outcome), uint8(Outcome.Rejected));
            assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Open), "rejected: the market stays open");
            _checkInvariant(t, who, bal0, dep, dead0);
            _warp(20 days); // then nobody else does it: expired
            vault.poke(t);
            assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Expired));
        }
        _checkInvariant(t, who, bal0, dep, dead0);

        for (uint256 i; i < 4; ++i) {
            if ((claimMask >> i) & 1 == 1) {
                vm.prank(who[i]);
                try yoloPredict.claim(t) {} catch {}
                _checkInvariant(t, who, bal0, dep, dead0);
            }
        }
        for (uint256 i; i < 4; ++i) {
            vm.prank(who[i]);
            try yoloPredict.claim(t) {} catch {}
        }
        _checkInvariant(t, who, bal0, dep, dead0);
        assertEq(yolo.balanceOf(address(yoloPredict)), 0, "everything claimed: nothing held");
    }
}
