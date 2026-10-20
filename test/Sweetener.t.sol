// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./Base.t.sol";

/// @dev "Sweeten with $YOLO": a YOLO bonus on top of any task. Paid on the
///      accepted submission by the reward's rule: 90% to the doer, 5% to the NFT votes if the NFT decided right, the
///      rest burned (the treasury's $YOLO); a doer whose lock earned them the stake bonus on the reward (the share
///      fixed at the submission, 4% x min(1, power / (the pot in $YOLO + the add-on)),
///      `Settlement.stakeBps`) and who
///      never sweetened the task gets that share of it more. Locked like
///      the reward until the deadline; back to each sweetener after an expiry or an unwind. No cap, no notice.
/// forge-config: default.isolate = false
contract SweetenerTest is Base {
    uint8 internal constant ACCEPT = 1;
    uint8 internal constant REJECT = 2;
    /// @dev The ETH reward's $YOLO-equivalent gives 250k; with a 1M or 1.5M add-on the power base is 1.25M or
    ///      1.75M: 2M is the whole 4%.
    uint256 internal constant STAKE = 2_000_000e18;
    uint256 internal t;

    function setUp() public override {
        super.setUp();
        t = _create(author, ETH, 0.01 ether); // a reward in ETH: the bonus does not care about the currency
    }

    function test_AcceptedDoerGetsTheBonusMinusFee() public {
        _sweeten(alice, t, 1_000_000e18);
        _sweeten(bob, t, 500_000e18);
        assertEq(sweetener.bonusOf(t), 1_500_000e18);
        assertEq(yolo.balanceOf(address(sweetener)), 1_500_000e18);

        uint256 s = _submit(doer, t);
        vm.warp(_sub(s).windowEnd + 1);
        vault.poke(t);
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Completed));
        assertEq(vault.getTask(t).activeSub, s, "a Completed task names its accepted submission");

        uint256 doerBefore = yolo.balanceOf(doer);
        uint256 dead0 = yolo.balanceOf(address(burner));
        vm.expectEmit(address(sweetener));
        emit YoloSweetener.BonusPaid(t, s, doer, 1_350_000e18, 0, 150_000e18);
        vm.prank(erin); // anyone may trigger the payout
        sweetener.payout(t);
        assertEq(yolo.balanceOf(doer) - doerBefore, 1_350_000e18, "90% to the doer");
        assertEq(
            yolo.balanceOf(address(burner)) - dead0,
            150_000e18,
            "the 10% fee burned: the treasury's $YOLO, no NFT decision"
        );
        assertEq(yolo.balanceOf(treasury), 0, "the treasury never gets $YOLO");
        assertEq(sweetener.bonusOf(t), 0);
        assertEq(yolo.balanceOf(address(sweetener)), 0);

        vm.expectRevert(YoloSweetener.NothingToPay.selector);
        sweetener.payout(t);
        vm.prank(alice);
        vm.expectRevert(YoloSweetener.BonusLocked.selector);
        sweetener.withdraw(t);
        vm.prank(alice);
        vm.expectRevert(YoloSweetener.TaskNotOpen.selector);
        sweetener.sweeten(t, 1);
        _claimEverythingAndCheck();
    }

    /// Locked while the task is open, before its deadline, busy or idle; free at the deadline when no
    /// submission is in flight (even before anyone pokes the vault into Expired).
    function test_LockedWhileOpen_EvenAfterRejection_FreeAfterDeadline() public {
        _sweeten(alice, t, 2_000_000e18);
        uint256 s = _submit(doer, t);
        vm.prank(alice);
        vm.expectRevert(YoloSweetener.BonusLocked.selector);
        sweetener.withdraw(t);

        // a late bonus during review joins the same bonus and is locked as well
        _sweeten(bob, t, 1e18);
        vm.prank(bob);
        vm.expectRevert(YoloSweetener.BonusLocked.selector);
        sweetener.withdraw(t);

        _dispute(dave, s);
        _vote(s, 0, REJECT, 0, 120);
        _warp(24 hours);
        vault.poke(t);
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Rejected));
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Open));

        vm.expectRevert(YoloSweetener.NotAccepted.selector);
        sweetener.payout(t);
        vm.prank(alice); // open again, before the deadline: still locked
        vm.expectRevert(YoloSweetener.BonusLocked.selector);
        sweetener.withdraw(t);

        vm.warp(vault.getTask(t).deadline);
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Open), "stored Open, nobody poked");
        uint256 before = yolo.balanceOf(alice);
        vm.prank(alice);
        sweetener.withdraw(t);
        assertEq(yolo.balanceOf(alice) - before, 2_000_000e18, "all of it back");
        assertEq(sweetener.bonusOf(t), 1e18, "bob's part stays");
        vm.prank(alice);
        vm.expectRevert(YoloSweetener.ZeroAmount.selector);
        sweetener.withdraw(t);
        vm.prank(bob);
        vm.expectRevert(YoloSweetener.TaskNotOpen.selector);
        sweetener.sweeten(t, 1e18); // past the deadline nobody adds
        _claimEverythingAndCheck();
    }

    function test_ExpiredTaskReturnsTheBonus() public {
        uint256 d = _createWithDeadline(author, address(usdc), 10e6, uint64(_now() + 1 days));
        _sweeten(alice, d, 300e18);
        vm.prank(alice);
        vm.expectRevert(YoloSweetener.BonusLocked.selector);
        sweetener.withdraw(d);
        _warp(1 days + 1);
        vault.poke(d);
        assertEq(uint8(vault.getTask(d).status), uint8(TaskStatus.Expired));
        vm.expectRevert(YoloSweetener.NotAccepted.selector);
        sweetener.payout(d);
        uint256 before = yolo.balanceOf(alice);
        vm.prank(alice);
        sweetener.withdraw(d);
        assertEq(yolo.balanceOf(alice) - before, 300e18);
        assertEq(sweetener.bonusOf(d), 0);
        _claimEverythingAndCheck();
    }

    // test_ExpiredTaskReturnsTheBonus above covers the sweetener's withdraw path on a task that never got
    // accepted; a task the dev wallet cancelled (Unwound) frees the bonus the same way (CancelTask.t.sol).

    /// `payout(taskId)` takes the
    /// accepted submission from the task itself (`activeSub` stays set on Completed): nothing to pick wrong.
    function test_PayoutGoesToTheAcceptedSubmissionOfThatTask() public {
        uint256 other = _create(author, address(imd), 10e18);
        _sweeten(alice, t, 100e18);
        uint256 sOther = _submit(doer2, other);
        uint256 s = _submit(doer, t);
        vm.expectRevert(YoloSweetener.NotAccepted.selector);
        sweetener.payout(t); // under review
        vm.warp(_sub(s).windowEnd + 1);
        vault.poke(t);
        vault.poke(other);
        assertEq(uint8(_sub(sOther).outcome), uint8(Outcome.Accepted));
        assertEq(vault.getTask(t).activeSub, s);
        assertEq(vault.getTask(other).activeSub, sOther);
        vm.expectRevert(YoloSweetener.NothingToPay.selector);
        sweetener.payout(other); // nobody sweetened that one
        uint256 d0 = yolo.balanceOf(doer);
        uint256 d20 = yolo.balanceOf(doer2);
        uint256 dead0 = yolo.balanceOf(address(burner));
        sweetener.payout(t);
        assertEq(yolo.balanceOf(doer) - d0, 90e18);
        assertEq(yolo.balanceOf(doer2), d20, "the doer of another task gets nothing");
        assertEq(yolo.balanceOf(address(burner)) - dead0, 10e18);
        _claimEverythingAndCheck();
    }

    function test_RefusedInputs() public {
        vm.prank(alice);
        vm.expectRevert(YoloSweetener.ZeroAmount.selector);
        sweetener.sweeten(t, 0);
        vm.prank(alice);
        vm.expectRevert(YoloSweetener.TaskNotOpen.selector);
        sweetener.sweeten(999, 1e18); // no such task
        vm.expectRevert(YoloSweetener.NotAccepted.selector);
        sweetener.payout(t); // the task is still open
        vm.expectRevert(YoloSweetener.ZeroAddress.selector);
        new YoloSweetener(address(0));
    }

    /// Locked before the deadline even when idle, and
    /// every wei back at the deadline.
    function test_IdleBeforeDeadlineLocked_AfterDeadlineBack(uint256 amount) public {
        // no cap: bounded only by bob's own balance
        amount = bound(amount, 1, yolo.balanceOf(bob));
        _sweeten(bob, t, amount);
        vm.prank(bob);
        vm.expectRevert(YoloSweetener.BonusLocked.selector);
        sweetener.withdraw(t);
        vm.warp(vault.getTask(t).deadline);
        uint256 before = yolo.balanceOf(bob);
        vm.prank(bob);
        sweetener.withdraw(t);
        assertEq(yolo.balanceOf(bob) - before, amount);
        assertEq(yolo.balanceOf(address(sweetener)), 0);
    }

    // ================================================================== the reward's fee rule on the bonus

    /// Full share (2M locked for a year before the submission, never sweetened this task): 94% to him, 6% burned.
    function test_StakedDoer_FullPower_GetsFourMore() public {
        vm.prank(doer);
        hub.lock(STAKE, 52);
        _warp(1);
        _sweeten(alice, t, 1_000_000e18);
        uint256 s = _submit(doer, t);
        _warp(24 hours);
        vault.poke(t);
        assertEq(vault.getSettlement(s).stakeBps, 400);
        uint256 d0 = yolo.balanceOf(doer);
        uint256 dead0 = yolo.balanceOf(address(burner));
        vm.expectEmit(address(sweetener));
        emit YoloSweetener.BonusPaid(t, s, doer, 940_000e18, 0, 60_000e18);
        sweetener.payout(t);
        assertEq(yolo.balanceOf(doer) - d0, 940_000e18);
        assertEq(yolo.balanceOf(address(burner)) - dead0, 60_000e18);
        _claimEverythingAndCheck();
    }

    /// Part power (312,500 for a year: a quarter of the 250k reward + the 1M add-on = 1.25M):
    /// 1% more, 91% to them, 9% burned. Small power (250k for 13 weeks = 62,500 against 0.01 ETH = 250k + the 1M
    /// add-on): no threshold, 62,500 / 1.25M of 4% = 0.2%, the same share of the bonus: 90.2% to them,
    /// 9.8% burned.
    function test_StakedDoer_PartPowerAndSmallPower() public {
        vm.prank(doer);
        hub.lock(312_500e18, 52);
        vm.prank(doer2);
        hub.lock(250_000e18, 13);
        _warp(1);
        _sweeten(alice, t, 1_000_000e18);
        uint256 s = _submit(doer, t);
        _warp(24 hours);
        vault.poke(t);
        assertEq(vault.getSettlement(s).stakeBps, 100);
        uint256 d0 = yolo.balanceOf(doer);
        uint256 dead0 = yolo.balanceOf(address(burner));
        sweetener.payout(t);
        assertEq(yolo.balanceOf(doer) - d0, 910_000e18);
        assertEq(yolo.balanceOf(address(burner)) - dead0, 90_000e18);

        uint256 t2 = _create(author, ETH, 0.01 ether);
        _sweeten(alice, t2, 1_000_000e18);
        uint256 s2 = _submit(doer2, t2);
        _warp(24 hours);
        vault.poke(t2);
        assertEq(vault.getSettlement(s2).stakeBps, 20);
        d0 = yolo.balanceOf(doer2);
        dead0 = yolo.balanceOf(address(burner));
        sweetener.payout(t2);
        assertEq(yolo.balanceOf(doer2) - d0, 902_000e18);
        assertEq(yolo.balanceOf(address(burner)) - dead0, 98_000e18);
        _claimEverythingAndCheck();
    }

    /// Full power and the NFT decided "accept": 90% + 4% to the doer, 5% to the accept votes, 1% burned.
    function test_StakedDoer_NftRight_VotesFiveDoerFourMore() public {
        vm.prank(doer);
        hub.lock(STAKE, 52);
        _warp(1);
        _sweeten(alice, t, 1_000_000e18);
        uint256 s = _submit(doer, t);
        _dispute(dave, s);
        _vote(s, 1, ACCEPT, 120, 20);
        _endVote(s);
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        assertEq(vault.getSettlement(s).stakeBps, 400);
        uint256 d0 = yolo.balanceOf(doer);
        uint256 dead0 = yolo.balanceOf(address(burner));
        sweetener.payout(t);
        assertEq(yolo.balanceOf(doer) - d0, 940_000e18);
        assertEq(sweetener.voterPool(t), 50_000e18);
        assertEq(yolo.balanceOf(address(burner)) - dead0, 10_000e18);
        _claimEverythingAndCheck();
    }

    /// The NFT decided "accept" and it was accepted: 5% of the bonus to the accept votes (claimVoter, pro rata), 5%
    /// burned, 90% to the doer.
    function test_NftDecidedRight_VotesGetFivePercent() public {
        _sweeten(alice, t, 1_000_000e18);
        uint256 s = _submit(doer, t);
        _dispute(dave, s);
        _vote(s, 1, ACCEPT, 120, 20);
        _endVote(s);
        assertEq(uint8(_phase(s)), uint8(Phase.Decided));
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        assertEq(uint8(_sub(s).nftDecision), uint8(Verdict.Accept));
        uint256 d0 = yolo.balanceOf(doer);
        uint256 dead0 = yolo.balanceOf(address(burner));
        vm.expectEmit(address(sweetener));
        emit YoloSweetener.BonusPaid(t, s, doer, 900_000e18, 50_000e18, 50_000e18);
        sweetener.payout(t);
        assertEq(yolo.balanceOf(doer) - d0, 900_000e18);
        assertEq(yolo.balanceOf(address(burner)) - dead0, 50_000e18);
        assertEq(sweetener.voterPool(t), 50_000e18);
        vm.expectRevert(YoloSweetener.NothingToPay.selector);
        sweetener.claimVoter(t, voters[0]); // did not vote
        uint256 v0 = yolo.balanceOf(voters[1]);
        sweetener.claimVoter(t, voters[1]); // anyone triggers, the votes' payTo is paid
        assertEq(yolo.balanceOf(voters[1]) - v0, 50_000e18);
        vm.expectRevert(YoloSweetener.NothingToPay.selector);
        sweetener.claimVoter(t, voters[1]);
        assertEq(yolo.balanceOf(address(sweetener)), 0);
        _claimEverythingAndCheck();
    }

    /// The NFT decided "reject", the swarm accepted on appeal: the NFT gets nothing, its 5% burns too.
    function test_NftWrong_SwarmAccepts_VotesGetNothing() public {
        _sweeten(alice, t, 1_000_000e18);
        uint256 s = _submit(doer, t);
        _dispute(dave, s);
        _vote(s, 1, REJECT, 120, 20);
        _endVote(s);
        _appeal(doer, s);
        _warp(1 hours); // asked inside swarmTimeout (6 h): a later ask finds the appeal void
        _askAppealSwarm(s); // lazy ask
        _answer(s, true);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        assertEq(uint8(_sub(s).nftDecision), uint8(Verdict.Reject));
        uint256 d0 = yolo.balanceOf(doer);
        uint256 dead0 = yolo.balanceOf(address(burner));
        sweetener.payout(t);
        assertEq(yolo.balanceOf(doer) - d0, 900_000e18);
        assertEq(yolo.balanceOf(address(burner)) - dead0, 100_000e18);
        assertEq(sweetener.voterPool(t), 0);
        vm.expectRevert(YoloSweetener.NothingToPay.selector);
        sweetener.claimVoter(t, voters[1]);
        _claimEverythingAndCheck();
    }

    /// A doer with full power who sweetened the task themself gets the 4% from the bonus as usual.
    function test_DoerWhoSweetened_StakeExtraOnTheBonus() public {
        vm.prank(doer);
        hub.lock(STAKE, 52);
        _warp(1);
        _sweeten(doer, t, 100_000e18);
        _sweeten(alice, t, 900_000e18);
        uint256 s = _submit(doer, t);
        _warp(24 hours);
        vault.poke(t);
        assertEq(vault.getSettlement(s).stakeBps, 400, "the vault's reward bonus does not look at the sweetener");
        assertTrue(sweetener.gave(t, doer));
        uint256 d0 = yolo.balanceOf(doer);
        uint256 dead0 = yolo.balanceOf(address(burner));
        sweetener.payout(t);
        assertEq(yolo.balanceOf(doer) - d0, 940_000e18, "94% of the whole bonus, his own part included");
        assertEq(yolo.balanceOf(address(burner)) - dead0, 60_000e18, "10% - 4%");
        _claimEverythingAndCheck();
    }

    /// There is no cap, so the payout
    /// reads no price at all: it works with no $YOLO price set.
    function test_PayoutNeedsNoYoloPrice() public {
        _sweeten(alice, t, 1_000_000e18);
        uint256 s = _submit(doer, t);
        vm.warp(_sub(s).windowEnd + 1);
        vault.poke(t);
        oracle.set(address(yolo), 0, 18);
        assertFalse(oracle.hasPrice(address(yolo)));
        uint256 d0 = yolo.balanceOf(doer);
        sweetener.payout(t);
        assertEq(yolo.balanceOf(doer) - d0, 900_000e18);
        assertEq(sweetener.bonusOf(t), 0);
    }

    /// A 60-wei add-on's bond is no part of any bond, so this case has no add-on bond at all and leaves nothing
    /// behind.
    function test_TinyAddon_NoBondPart_NothingStuck() public {
        _sweeten(bob, t, 60);
        uint256 s = _submit(doer, t);
        assertEq(_sub(s).bond.rew, _bondOf(vault.getTask(t).pot), "3% of the author's reward only");
        _dispute(dave, s);
        _vote(s, 0, ACCEPT, 0, 120); // NFT: accept
        _endVote(s);
        _appeal(erin, s); // against the doer, 1% of 60 wei = 0 add-on bond
        _askAppealSwarm(s); // lazy ask
        _answer(s, false); // the swarm: rejected, the NFT were wrong
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Rejected));
        _claimEverythingAndCheck();
    }

    function _sweeten(address who, uint256 taskId, uint256 amount) internal {
        vm.prank(who);
        sweetener.sweeten(taskId, amount);
    }
}
