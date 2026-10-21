// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../Base.t.sol";

/// @dev Swarm audit 117cf05a of moneycanbuy d9a1ee5: regressions of findings #3 to #10 (the report gave no source for
/// these; each test follows the report's reproduction and fails on d9a1ee5). #2:
/// VestingClockPreStart.t.sol. #11 (Intake version 2): ReviewLaunch.test_L2 against docs/LAUNCH-TASK.md.
/// forge-config: default.isolate = false
contract SwarmAudit117Test is Base {
    uint8 internal constant ACCEPT = 1;
    uint8 internal constant REJECT = 2;

    // ------------------------------------------------------------------ #3 relayer shortfall vs winners and voters
    // Not applicable: nobody is reimbursed for voting gas (each voter pays his own),
    // so there is no shortfall to grief.

    // ------------------------------------------------------------------ #4 the doer appeals his own acceptance

    function _decidedAccept() internal returns (uint256 t, uint256 s) {
        t = _create(author, address(usdc), 100e6);
        s = _submit(doer, t);
        _dispute(dave, s);
        _vote(s, 0, ACCEPT, 0, 120);
        _endVote(s);
        assertEq(uint8(_phase(s)), uint8(Phase.Decided));
    }

    function test_doerAppealsAgainstOwnAcceptance() public {
        (uint256 t, uint256 s) = _decidedAccept();
        vm.prank(doer);
        vm.expectRevert(DoerCannotDispute.selector);
        vault.appeal(s, type(uint256).max, _noSwap());
        // the slot stays free for an honest disputer; the doer's "why honest" went in at submission (
        // no opponent-reply step on an appeal)
        _appeal(dave, s);
        assertEq(vault.getAppeal(s).appellant, dave);
        _askAppealSwarm(s); // lazy ask
        _claimEverythingAndCheck();
    }

    function test_doerMayStillAppealARejection() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        _dispute(dave, s);
        _vote(s, 0, REJECT, 0, 120);
        _endVote(s);
        _appeal(doer, s); // in his own favour
        assertTrue(vault.getAppeal(s).sidesDoer);
        _claimEverythingAndCheck();
    }

    function test_doerCannotCallTheSwarmAgainstHimself() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        _dispute(dave, s);
        _warp(24 hours); // no votes: NoDecision
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.NoDecision));
        vm.prank(doer);
        vm.expectRevert(DoerCannotDispute.selector);
        vault.callSwarm(s, false, type(uint256).max, _noSwap(), _genericRuleTexts());
        _callSwarm(doer, s, true); // for himself: fine
        assertEq(uint8(_phase(s)), uint8(Phase.Asked));
        _claimEverythingAndCheck();
    }

    // ------------------------------------------------------------------ #5 one wallet, both sides

    function test_walletVotesBothSidesAndIsPaid() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        _dispute(dave, s);
        _vote(s, 2, ACCEPT, 140, 10); // 10 < instantDelta: the vote stays open
        // a second vote of the same wallet reverts, either side (the side cannot change)
        vm.prank(voters[2]);
        vm.expectRevert(AlreadyVoted.selector);
        vault.vote(s, REJECT, voters[2], _ids(140, 10));
        // the other side with another payTo is refused too: the vote belongs to the sender
        vm.prank(voters[2]);
        vm.expectRevert(AlreadyVoted.selector);
        vault.vote(s, REJECT, relayer, _ids(140, 10));
        (uint256 acc, uint256 rej) = vault.votesOf(s, voters[2]);
        assertEq(acc, 10);
        assertEq(rej, 0);
        Dispute memory d = vault.getDispute(s);
        assertEq(d.walletsAccept, 1);
        assertEq(d.walletsReject, 0);
        _claimEverythingAndCheck();
    }

    // ------------------------------------------------------------------ #6 sweetener payout without a price

    // #6 sweetener tests: SwarmAudit117SweetenerTest below (split keeps this contract off solc's 64 KiB tag
    // boundary, "Tag too large for reserved space").

    // ------------------------------------------------------------------ #7 a late answer vs the poke order
    // (the timing rule on a paid call without an NFT decision)

    function _calledAsked() internal returns (uint256 t, uint256 s, uint256 askedAt) {
        t = _create(author, address(usdc), 300e6);
        s = _submit(doer, t);
        _dispute(dave, s);
        _warp(24 hours); // no votes: NoDecision
        _callSwarm(erin, s);
        assertEq(uint8(_phase(s)), uint8(Phase.Asked));
        askedAt = _now();
    }

    function _deliver(uint256 s, bool answer, uint256 issuedAt) internal {
        OracleAttestation.Attestation memory a = _attestation(answer);
        a.issuedAt = uint64(issuedAt);
        intake.complete(_sub(s).request, 0, a, _sign(a, attesterKey));
    }

    /// The report: sequence A (poke at the deadline, then a "no" signed at T+1h delivered at T+6h+60s) ended
    /// Accepted, sequence B (no poke) Rejected. Both end Rejected now.
    function test_pokeAtDeadlineTurnsLateAnswerIntoSilence() public {
        (uint256 t, uint256 s, uint256 askedAt) = _calledAsked();
        uint256 snap = vm.snapshotState();
        // A: someone pokes right at the timeout
        vm.warp(askedAt + 6 hours);
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.Asked), "not silent while the answer may still come");
        vm.warp(askedAt + 6 hours + 60);
        _deliver(s, false, askedAt + 1 hours);
        _warp(24 hours);
        vault.poke(t);
        Outcome a = _sub(s).outcome;
        vm.revertToState(snap);
        // B: nobody pokes
        vm.warp(askedAt + 6 hours + 60);
        _deliver(s, false, askedAt + 1 hours);
        _warp(24 hours);
        vault.poke(t);
        Outcome b = _sub(s).outcome;
        assertEq(uint8(a), uint8(Outcome.Rejected));
        assertEq(uint8(b), uint8(a), "the same answer, the same outcome, whoever poked");
        _claimEverythingAndCheck();
    }

    function test_answerAfterTheGraceIgnoredWhoeverPoked() public {
        (uint256 t, uint256 s, uint256 askedAt) = _calledAsked();
        vm.warp(askedAt + 6 hours + SWARM_DELIVERY_GRACE);
        vault.poke(t); // past the grace: silence, the window opens at the end of the grace
        assertEq(uint8(_phase(s)), uint8(Phase.NoDecision));
        assertEq(_sub(s).callFrom, askedAt + 6 hours + SWARM_DELIVERY_GRACE);
        uint256 snap = vm.snapshotState();
        _deliver(s, false, askedAt + 1 hours); // after the grace: ignored, whoever poked
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        vm.revertToState(snap);
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        _claimEverythingAndCheck();
    }

    function test_answerDeliveredAfterTheGraceIgnoredEvenUnpoked() public {
        (uint256 t, uint256 s, uint256 askedAt) = _calledAsked();
        vm.warp(askedAt + 6 hours + SWARM_DELIVERY_GRACE + 1);
        _deliver(s, false, askedAt + 1 hours); // signed in time, delivered past the grace, nobody poked before
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.NoDecision), "silence: the answer came too late");
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        _claimEverythingAndCheck();
    }

    function test_answerSignedAfterTheTimeoutIsSilenceAtTheEndOfTheGrace() public {
        (uint256 t, uint256 s, uint256 askedAt) = _calledAsked();
        vm.warp(askedAt + 6 hours + 10 minutes);
        _deliver(s, false, askedAt + 6 hours + 5 minutes); // signed late
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.Asked), "decided only at the end of the grace");
        vm.warp(askedAt + 6 hours + SWARM_DELIVERY_GRACE);
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.NoDecision));
        assertEq(_sub(s).callFrom, askedAt + 6 hours + SWARM_DELIVERY_GRACE);
        _claimEverythingAndCheck();
    }

    // ------------------------------------------------------------------ #8 the author pulls the reward
    // (the reward is locked until the deadline: nothing leaves an open task)

    function test_authorFrontRunsSubmitWithWithdrawal() public {
        uint256 t = _create(author, ETH, 0.01 ether);
        // the proof is public; the author tries to pull the reward before the doer's submit lands
        vm.prank(author);
        vm.expectRevert(TaskNotOpen.selector); // locked: nothing leaves an open task
        vault.withdrawContribution(t);
        vm.prank(doer);
        // an ETH-reward task's bond.rew part also comes from msg.value (never transferFrom).
        vault.submit{value: ETH_BOND_HEADROOM}(
            t, "https://x.com/doer/status/1", _noEvidence(), 0.01 ether, type(uint256).max, _noSwap()
        );
        assertEq(vault.getTask(t).pot, 0.01 ether);
        _claimEverythingAndCheck();
    }

    /// No withdrawal notice exists; the reward stays until the deadline,
    /// also past it while a submission is judged, and an accepted one takes it.
    function test_rewardLockedUntilTheDeadlineAndWhileJudged() public {
        uint256 t = _createWithDeadline(author, ETH, 0.01 ether, uint64(_now() + 2 days));
        _warp(2 days - 1);
        vm.prank(author);
        vm.expectRevert(TaskNotOpen.selector);
        vault.withdrawContribution(t);
        uint256 s = _submit(doer, t); // the last second
        _warp(1); // past the deadline, the submission under review
        vm.prank(author);
        vm.expectRevert(TaskNotOpen.selector);
        vault.withdrawContribution(t);
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        vm.prank(author);
        vm.expectRevert(NothingToClaim.selector); // the reward went to the doer
        vault.withdrawContribution(t);
        _claimEverythingAndCheck();
    }

    // A top-up during the check joins the reward: test/ContractRules.t.sol test_UsdcTopUpDuringCheck_InTheDoersPayout
    // (a separate contract keeps this one's bytecode off the 64 KiB solc tag boundary).

    function test_noNoticeNeededAfterExpiry() public {
        uint256 t = _createWithDeadline(author, ETH, 0.01 ether, uint64(_now() + 1 days));
        _warp(1 days);
        uint256 before = author.balance;
        vm.prank(author);
        vault.withdrawContribution(t);
        assertEq(author.balance - before, 0.01 ether);
        _claimEverythingAndCheck();
    }

    // ------------------------------------------------------------------ #9 expired attestation

    function test_expiredAttestationIsIgnored() public {
        (uint256 t, uint256 s,) = _calledAsked();
        bytes32 rid = _sub(s).request;
        OracleAttestation.Attestation memory a = _attestation(false);
        a.expiresAt = uint64(_now() - 1);
        vm.expectEmit(address(vault));
        emit AttestationIgnored(rid, 16);
        intake.complete(rid, 0, a, _sign(a, attesterKey));
        assertFalse(vault.requests(rid).answered, "an expired answer is not recorded");
        a.expiresAt = 0; // no expiry: accepted
        AttestationChecker checker = AttestationChecker(vault.attestationChecker());
        assertEq(checker.check(address(vault), 7, 5, a, _sign(a, attesterKey)), 0);
        vault.poke(t);
        _claimEverythingAndCheck();
    }

    // ------------------------------------------------------------------ #10 the last attester

    function test_lastAttesterCannotBeRemoved() public {
        assertEq(registry.attesterCount(), 1);
        vm.prank(multisig);
        registry.proposeAttester(attester, false);
        _warp(48 hours);
        vm.expectRevert(ParamsRegistry.LastAttester.selector);
        registry.executeAttester(attester, false);
        assertTrue(registry.isAttester(attester));
        // a second one first: then either may go, but never both
        address second = makeAddr("attester2");
        vm.prank(multisig);
        registry.proposeAttester(second, true);
        _warp(48 hours);
        registry.executeAttester(second, true);
        assertEq(registry.attesterCount(), 2);
        vm.startPrank(multisig);
        registry.proposeAttester(attester, false);
        registry.proposeAttester(second, false);
        vm.stopPrank();
        _warp(48 hours);
        registry.executeAttester(attester, false);
        assertEq(registry.attesterCount(), 1);
        assertFalse(registry.isAttester(attester));
        vm.expectRevert(ParamsRegistry.LastAttester.selector);
        registry.executeAttester(second, false);
        assertTrue(registry.isAttester(second));
    }
}

/// forge-config: default.isolate = false
contract SwarmAudit117SweetenerTest is Base {
    function _completedSweetened(uint256 bonus) internal returns (uint256 t, uint256 s) {
        t = _create(author, address(usdc), 100e6);
        vm.prank(alice);
        sweetener.sweeten(t, bonus);
        s = _submit(doer, t);
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Completed));
    }

    /// #6: there is no cap (no mandatory check), so the payout reads no price: without one it pays at once.
    function test_sweetenerPayoutWithoutPricePaysAtOnce() public {
        (uint256 t,) = _completedSweetened(100_000e18);
        oracle.set(address(yolo), 0, 18); // no YOLO price set
        uint256 before = yolo.balanceOf(doer);
        vm.prank(alice);
        sweetener.payout(t);
        assertEq(yolo.balanceOf(doer) - before, 90_000e18, "90%, at once");
        assertEq(sweetener.bonusOf(t), 0);
        vm.prank(alice);
        vm.expectRevert(YoloSweetener.BonusLocked.selector); // nothing goes back to the sweetener
        sweetener.withdraw(t);
        oracle.set(address(yolo), 0.0001e18, 18);
        _claimEverythingAndCheck();
    }

    /// Without a price: in full at once, whatever the size.
    function test_sweetenerLargeBonusWithoutPricePaysInFull() public {
        (uint256 t,) = _completedSweetened(9_000_000e18); // $900 at the price of the sweetening ($1,000 with R)
        oracle.set(address(yolo), 0, 18);
        uint256 before = yolo.balanceOf(doer);
        uint256 deadBefore = yolo.balanceOf(address(burner));
        sweetener.payout(t);
        assertEq(yolo.balanceOf(doer) - before, 8_100_000e18);
        assertEq(yolo.balanceOf(address(burner)) - deadBefore, 900_000e18, "the fee burns");
        oracle.set(address(yolo), 0.0001e18, 18);
        _claimEverythingAndCheck();
    }

    /// With a price: no cap either.
    function test_sweetenerNoCapWithAPrice() public {
        (uint256 t,) = _completedSweetened(9_000_000e18); // $900
        uint256 before = yolo.balanceOf(doer);
        uint256 aliceBefore = yolo.balanceOf(alice);
        sweetener.payout(t);
        assertEq(yolo.balanceOf(doer) - before, 8_100_000e18, "the whole bonus minus 10%");
        assertEq(yolo.balanceOf(alice), aliceBefore, "nothing back to the sweetener");
        _claimEverythingAndCheck();
    }
}
