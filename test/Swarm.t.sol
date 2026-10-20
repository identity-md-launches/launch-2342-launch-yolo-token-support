// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./Base.t.sol";

/// @dev Swarm answers (callback only, spoofing, late / duplicate answers); no mandatory check.
///      USDC task R = 100: the doer bond is 0.5 IMD + 3 USDC (3% of R).
/// forge-config: default.isolate = false
contract SwarmTest is Base {
    uint256 internal t;
    uint256 internal s;

    function setUp() public override {
        super.setUp();
        t = _create(author, address(usdc), 100e6);
        s = _submit(doer, t);
        _dispute(dave, s);
        _warp(24 hours);
        _callSwarm(erin, s); // no votes: erin pays fee + bond and calls the swarm
    }

    function test_CallbackSelectorMatchesDocs() public pure {
        assertEq(ITaskVault.onOracleResult.selector, bytes4(0x510379c7));
        assertEq(CALLBACK_SELECTOR, bytes4(0x510379c7));
    }

    function test_RequestShapeAndBody() public {
        bytes32 rid = _sub(s).request;
        assertEq(rid, keccak256(abi.encode(block.chainid, address(intake), uint256(1))));
        // the preview shows the next question exactly as it will be sent
        uint256 t2 = _create(author, address(usdc), 100e6);
        uint256 s2 = _submit(doer2, t2);
        _dispute(dave, s2);
        _warp(24 hours);
        vault.poke(t2);
        (bytes memory body,) = vault.previewSwarmBody(s2, 2, _genericRuleTexts());
        _callSwarm(erin, s2);
        assertLe(body.length, 16_384);
        // a call carries no text of its own - callSwarm resupplies the exact same RuleTexts the preview used,
        // so the sent body is byte-identical to the preview, not preview-plus-extra.
        assertEq(intake.lastBodyLength(), body.length);
        // starts with the fixed header, includes the claim and its proof link, and the consumer
        assertEq(bytes(string(body))[0], "{");
        assertTrue(_contains(body, '"claim_1":"ipfs://reason"'));
        assertTrue(_contains(body, '"claim_1_proof":"ipfs://reason-proof"'));
        assertTrue(_contains(body, '"answerType":"bool"'));
        assertTrue(_contains(body, '"verifyingContract":"0x'));
    }

    function test_CallbackGasUnder100k() public {
        _answer(s, true);
        assertLt(intake.lastCallbackGasUsed(), 100_000);
        emit log_named_uint("callback gas", intake.lastCallbackGasUsed());
    }

    function test_DuplicateAnswerIgnored_FirstWins() public {
        _answer(s, false);
        bytes32 rid = _sub(s).request;
        OracleAttestation.Attestation memory a = _attestation(true);
        bytes memory sig = _sign(a, attesterKey);
        // second delivery through the real path cannot happen (Intake completes once); a direct second
        // callback from the Intake address is ignored without revert
        vm.expectEmit(address(vault));
        emit AttestationIgnored(rid, 3);
        vm.prank(address(intake));
        vault.onOracleResult(rid, a, sig);
        assertFalse(vault.requests(rid).answer);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Rejected));
        _claimEverythingAndCheck();
    }

    function test_SpoofedCallbackIgnored() public {
        bytes32 rid = _sub(s).request;
        OracleAttestation.Attestation memory a = _attestation(true);
        bytes memory sig = _sign(a, attesterKey);
        vm.expectEmit(address(vault));
        emit AttestationIgnored(rid, 2);
        vm.prank(dave);
        vault.onOracleResult(rid, a, sig); // not the Intake
        assertFalse(vault.requests(rid).answered);
        // unknown request id from the Intake: ignored
        vm.expectEmit(address(vault));
        emit AttestationIgnored(keccak256("other"), 1);
        vm.prank(address(intake));
        vault.onOracleResult(keccak256("other"), a, sig);
        // wrong signer from the Intake: ignored, the request stays open
        bytes memory fakeSig = _sign(a, 0xBAD);
        vm.expectEmit(address(vault));
        emit AttestationIgnored(rid, 15);
        vm.prank(address(intake));
        vault.onOracleResult(rid, a, fakeSig);
        assertFalse(vault.requests(rid).answered);
        // non-bool answer / bad quorum: ignored
        a.answerType = 3;
        sig = _sign(a, attesterKey);
        vm.expectEmit(address(vault));
        emit AttestationIgnored(rid, 12);
        vm.prank(address(intake));
        vault.onOracleResult(rid, a, sig);
        a.answerType = 0;
        a.agreed = 4;
        sig = _sign(a, attesterKey);
        vm.expectEmit(address(vault));
        emit AttestationIgnored(rid, 14);
        vm.prank(address(intake));
        vault.onOracleResult(rid, a, sig);
        assertFalse(vault.requests(rid).answered);
        // a valid one from the Intake is recorded
        a.agreed = 6;
        sig = _sign(a, attesterKey);
        vm.prank(address(intake));
        vault.onOracleResult(rid, a, sig);
        assertTrue(vault.requests(rid).answered);
    }

    function test_LateAnswerIgnored_Timeout() public {
        _warp(7 hours);
        _answer(s, false); // issuedAt after askedAt + 6h: counts as silence
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.NoDecision));
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted)); // NFT undecided, nobody called again
        _claimEverythingAndCheck();
    }

    function test_AnswerAfterSilenceIgnored() public {
        _warp(6 hours + SWARM_DELIVERY_GRACE); // the timeout and the delivery grace (swarm audit 117cf05a #7)
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.NoDecision));
        _answer(s, false); // recorded, but the question is closed
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.NoDecision));
        _claimEverythingAndCheck();
    }

    function test_RefusedBody_Status1_IsSilence() public {
        OracleAttestation.Attestation memory a;
        intake.complete(_sub(s).request, 1, a, ""); // refused by the body checks: no callback
        vault.poke(t); // the Intake reports the request completed without an answer: silence at once
        assertEq(uint8(_phase(s)), uint8(Phase.NoDecision));
        assertEq(_sub(s).callFrom, _now());
        assertEq(vault.credits(address(imd), erin), 0.5e18); // her bond.imd back (flat, no $5 floor)
        _claimEverythingAndCheck();
    }

    /// @dev A lost callback is silence: the signed answer cannot be handed in by anyone.
    function test_LostCallback_IsSilence_NoPublicFallback() public {
        intake.setCallbackGas(5_000); // callback runs out of gas
        bytes32 rid = _sub(s).request;
        OracleAttestation.Attestation memory a = _attestation(false);
        a.questionHash = vault.requests(rid).questionHash;
        intake.complete(rid, 0, a, _sign(a, attesterKey));
        assertFalse(intake.lastDelivered());
        assertFalse(vault.requests(rid).answered);
        _warp(3 hours);
        _expectNoFallback(rid, a, _sign(a, attesterKey));
        vault.poke(t); // the Intake reports the request completed without an answer: silence at once
        assertFalse(vault.requests(rid).answered);
        assertEq(uint8(_phase(s)), uint8(Phase.NoDecision));
        assertEq(_sub(s).callFrom, _now());
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted)); // undecided rule, not the lost "no"
        _claimEverythingAndCheck();
    }

    /// @dev There is no public fallback for any input: foreign, incomplete, badly signed, unknown or valid.
    function test_NoPublicFallback_ForAnyAttestation() public {
        bytes32 rid = _sub(s).request;
        OracleAttestation.Attestation memory a = _attestation(true);
        bytes memory sig = _sign(a, attesterKey);
        _expectNoFallback(rid, a, sig); // another question
        a.questionHash = vault.requests(rid).questionHash;
        sig = _sign(a, attesterKey);
        _expectNoFallback(rid, a, sig); // right question, request not completed
        intake.completeWithoutCallback(rid);
        _expectNoFallback(rid, a, _sign(a, 0xBAD)); // bad signer
        _expectNoFallback(keccak256("x"), a, sig); // unknown request
        _expectNoFallback(rid, a, sig); // completed, valid, our question
        assertFalse(vault.requests(rid).answered);
    }

    function test_AttesterRotationTimelocked() public {
        uint256 newKey = 0xC0FFEE;
        address newAttester = vm.addr(newKey);
        vm.prank(multisig);
        registry.proposeAttester(newAttester, true);
        bytes32 rid = _sub(s).request;
        OracleAttestation.Attestation memory a = _attestation(true);
        bytes memory sig = _sign(a, newKey);
        vm.prank(address(intake));
        vault.onOracleResult(rid, a, sig);
        assertFalse(vault.requests(rid).answered); // not yet an attester
        vm.expectRevert(ParamsRegistry.TimelockNotPassed.selector);
        registry.executeAttester(newAttester, true);
        _warp(48 hours);
        registry.executeAttester(newAttester, true);
        assertTrue(registry.isAttester(newAttester));
        // removal of the old key also takes 48h
        vm.prank(multisig);
        registry.proposeAttester(attester, false);
        _warp(48 hours);
        registry.executeAttester(attester, false);
        assertFalse(registry.isAttester(attester));
        // a new request answered by the rotated key is accepted (the set is global, old tasks included)
        uint256 t2 = _create(author, address(usdc), 100e6);
        uint256 s2 = _submit(doer2, t2);
        _dispute(dave, s2);
        _warp(24 hours);
        _callSwarm(erin, s2);
        bytes32 rid2 = _sub(s2).request;
        a = _attestation(true);
        sig = _sign(a, newKey);
        intake.complete(rid2, 0, a, sig);
        assertTrue(vault.requests(rid2).answered);
    }

    // ================================================================== no mandatory check
    // Every submission, of any reward, opens its dispute window at once, and the swarm is asked only when
    // somebody pays for it (callSwarm, appeal).

    /// @dev A $1,000 reward (there is no maximum) costs the doer only their bond (0.5 IMD + 3% = 30 USDC), asks nothing,
    ///      and is accepted by the timer.
    function test_NoMandatoryCheck_MaxReward_NothingAsked_AcceptedByTimer() public {
        uint256 tl = _create(author, address(usdc), 1_000e6);
        uint256 asked = intake.nonce();
        uint256 payeeBefore = imd.balanceOf(swarmPayee);
        uint256 before = imd.balanceOf(doer2);
        uint256 sl = _submit(doer2, tl);
        Submission memory sub = _sub(sl);
        assertEq(sub.bond.imd, _fixedBond());
        assertEq(sub.bond.rew, 30e6, "3% of $1,000");
        assertEq(before - imd.balanceOf(doer2), _fixedBond(), "the fixed IMD part, nothing on top");
        assertEq(sub.request, bytes32(0), "no question");
        assertEq(sub.asks, 0);
        assertEq(intake.nonce(), asked, "the Intake got no request");
        assertEq(imd.balanceOf(swarmPayee), payeeBefore);
        assertEq(uint8(sub.phase), uint8(Phase.Review));
        assertEq(sub.windowEnd, _now() + 24 hours, "the dispute window opens at once");
        _warp(24 hours);
        vault.poke(tl);
        assertEq(uint8(_sub(sl).outcome), uint8(Outcome.Accepted));
        assertEq(vault.credits(address(usdc), doer2), 900e6 + 30e6, "90% of R plus the rew bond back");
        assertEq(vault.treasuryPot(address(usdc)), 100e6);
        assertEq(vault.credits(address(imd), doer2), _fixedBond());
        _claimEverythingAndCheck();
    }

    /// @dev With no check, nobody disputing means accepted, and a bond is never forfeited without a disputer.
    function test_NoMandatoryCheck_ImdTask_NoDispute_AcceptedBondBack() public {
        uint256 tl = _create(author, address(imd), 100e18); // $800
        uint256 sl = _submit(doer2, tl);
        assertEq(_sub(sl).bond.imd, _fixedBond());
        assertEq(_sub(sl).bond.rew, 3e18); // 3% of 100 IMD, merged into the same IMD currency as R
        assertEq(_sub(sl).request, bytes32(0));
        _warp(24 hours);
        vault.poke(tl);
        assertEq(uint8(_sub(sl).outcome), uint8(Outcome.Accepted));
        assertEq(
            vault.credits(address(imd), doer2),
            90e18 + 3e18 + _fixedBond(),
            "the reward minus 10%, the rew bond and the fixed IMD part"
        );
        assertEq(vault.treasuryPot(address(imd)), 10e18);
        assertEq(vault.getTask(tl).rejectedCount, 0);
        _claimEverythingAndCheck();
    }

    /// @dev For any reward $5..$1,000 in any currency the submission is in Review at once with its window, asks
    ///      nothing and bonds 0.5 IMD + 3% R in R's own currency: no oracle, no USD floor.
    /// @dev The minimum is a dev parameter in each currency's own terms, not a shared USD floor, so the fuzz
    ///      range is bounded per currency, with no common USD figure.
    function testFuzz_NoMandatoryCheck_AnyRewardSize(uint256 amt, uint8 cur) public {
        address currency = [ETH, address(usdc), address(imd), address(yolo)][cur % 4];
        uint256 amount = currency == ETH
            ? bound(amt, 0.002e18, 1 ether)
            : currency == address(usdc)
                ? bound(amt, 5e6, 900_000e6)
                : currency == address(imd) ? bound(amt, 1e18, 9_000e18) : bound(amt, 1_000e18, 900_000_000e18);
        uint256 tl = _create(author, currency, amount);
        uint256 asked = intake.nonce();
        uint256 sl = _submit(doer2, tl);
        Submission memory sub = _sub(sl);
        assertEq(uint8(sub.phase), uint8(Phase.Review));
        assertEq(sub.windowEnd, _now() + 24 hours);
        assertEq(sub.request, bytes32(0));
        assertEq(intake.nonce(), asked);
        assertEq(sub.bond.imd, _fixedBond());
        assertEq(sub.bond.rew, _bondOf(amount), "3% of R, in R's own currency");
    }

    /// @dev Disputed right after submitting, no waiting for a check; the dispute window counts from the
    ///      submission.
    function test_LargeTask_DisputedAtOnce_Rejected() public {
        uint256 tl = _create(author, ETH, 0.2 ether); // $500
        uint256 sl = _submit(doer2, tl);
        uint256 at = _now();
        _dispute(erin, sl);
        assertEq(_sub(sl).windowEnd, at + 24 hours);
        assertEq(uint8(_phase(sl)), uint8(Phase.Voting));
        _vote(sl, 1, 2, 120, 20);
        _warp(48 hours);
        vault.poke(tl);
        assertEq(uint8(_sub(sl).outcome), uint8(Outcome.Rejected));
        assertEq(_sub(sl).asks, 0, "the swarm never heard of it");
        _claimEverythingAndCheck();
    }

    /// @dev A queued submission prepays nothing (bond only, the same as the one ahead), and its activation asks
    ///      nothing, whatever the swarm price is by then.
    function test_LargeTask_QueuedSubmission_ActivatedWithoutQuestion() public {
        uint256 tl = _create(author, address(usdc), 400e6);
        uint256 s1 = _submit(doer2, tl);
        uint256 before = imd.balanceOf(doer3);
        uint256 s2 = _submit(doer3, tl); // queued
        assertEq(_sub(s1).bond.rew, 12e6, "3% of $400");
        assertEq(_sub(s2).bond.rew, 12e6, "no escalation: same bond, queued or not");
        assertEq(before - imd.balanceOf(doer3), _fixedBond(), "the fixed IMD part only, no prepaid question");
        assertEq(uint8(_phase(s2)), uint8(Phase.Queued));
        _dispute(dave, s1);
        _vote(s1, 1, 2, 120, 20);
        intake.setPrice(1e18);
        uint256 asked = intake.nonce();
        _warp(48 hours);
        vault.poke(tl); // s1 rejected -> s2 active, nothing asked
        assertEq(uint8(_sub(s1).outcome), uint8(Outcome.Rejected));
        assertEq(uint8(_phase(s2)), uint8(Phase.Review));
        assertEq(_sub(s2).windowEnd, _now() + 24 hours);
        assertEq(_sub(s2).request, bytes32(0));
        assertEq(intake.nonce(), asked);
        assertEq(vault.credits(address(imd), doer3), 0, "no prepayment to give back");
        _warp(24 hours);
        vault.poke(tl);
        assertEq(uint8(_sub(s2).outcome), uint8(Outcome.Accepted));
        _claimEverythingAndCheck();
    }

    /// @dev A broken Intake does not touch submissions at all.
    function test_IntakeBroken_LargeSubmitUnaffected() public {
        uint256 tl = _create(author, address(usdc), 1_000e6);
        intake.setBroken(true); // request() reverts
        uint256 before = imd.balanceOf(doer2);
        uint256 sl = _submit(doer2, tl);
        assertEq(before - imd.balanceOf(doer2), _sub(sl).bond.imd);
        assertEq(_sub(sl).windowEnd, _now() + 24 hours);
        assertEq(vault.credits(address(imd), doer2), 0);
        intake.setBroken(false);
        _warp(24 hours);
        vault.poke(tl);
        assertEq(uint8(_sub(sl).outcome), uint8(Outcome.Accepted));
        _claimEverythingAndCheck();
    }

    function test_CallSwarm_IntakeBroken_Reverts_NothingTaken() public {
        uint256 t2 = _create(author, address(usdc), 100e6);
        uint256 s2 = _submit(doer2, t2);
        _dispute(dave, s2);
        _warp(24 hours);
        intake.setBroken(true);
        uint256 before = imd.balanceOf(erin);
        vm.prank(erin);
        vm.expectRevert(SwarmUnavailable.selector);
        vault.callSwarm(s2, false, type(uint256).max, _noSwap(), _genericRuleTexts());
        assertEq(imd.balanceOf(erin), before);
        intake.setBroken(false);
    }

    /// @dev An answer to a paid call signed early and delivered 5 hours later (inside the timeout) counts; the
    ///      swarm is final, so no window follows it.
    function test_AnswerSignedEarly_DeliveredLate_Counts() public {
        uint256 askedAt = vault.requests(_sub(s).request).askedAt;
        _warp(5 hours);
        OracleAttestation.Attestation memory a = _attestation(false);
        a.issuedAt = uint64(askedAt + 1 minutes); // signed early, delivered 5h later
        intake.complete(_sub(s).request, 0, a, _sign(a, attesterKey));
        assertEq(vault.requests(_sub(s).request).recordedAt, _now());
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Rejected));
        _claimEverythingAndCheck();
    }

    /// @dev A $1,000 task is disputed at once and judged by the NFT like any other; the fee splits 5/5 (NFT
    ///      right).
    function test_LargeTask_DisputedNftAccepts_Fee5To5() public {
        uint256 tl = _create(author, address(usdc), 1_000e6);
        uint256 sl = _submit(doer2, tl);
        _dispute(erin, sl); // 1% of $1,000 = $10
        assertEq(vault.getDisputer(sl, erin).bond.imd, _fixedBond());
        assertEq(vault.getDisputer(sl, erin).bond.rew, 10e6);
        _vote(sl, 1, 1, 120, 20);
        _warp(48 hours);
        vault.poke(tl);
        assertEq(uint8(_sub(sl).outcome), uint8(Outcome.Accepted));
        assertEq(vault.credits(address(usdc), doer2), 900e6 + 30e6 + 5e6, "90% of R, the rew bond and half of erin's");
        assertEq(vault.getSettlement(sl).voterFee, 50e6);
        assertEq(vault.treasuryPot(address(usdc)), 50e6);
        assertEq(
            vault.credits(address(imd), doer2), _fixedBond() + _fixedBond() / 2, "fixed bond back + half of erin's"
        );
        _claimEverythingAndCheck();
    }

    /// @dev No submission asks the swarm by itself, so a task of any size (here $500) takes submissions even when
    ///      the Intake stops selling the action; only paid calls need the Intake's price.
    function test_ActionNotSold_LargeSubmitStillWorks() public {
        intake.setPrice(0);
        uint256 tl = _create(author, address(usdc), 500e6);
        uint256 sl = _submit(doer3, tl);
        assertEq(_sub(sl).bond.imd, _fixedBond());
        assertEq(_sub(sl).bond.rew, 15e6, "3% of $500");
        _dispute(dave, sl);
        _warp(24 hours);
        vm.prank(erin);
        vm.expectRevert(ActionNotSold.selector);
        vault.callSwarm(sl, false, type(uint256).max, _noSwap(), _genericRuleTexts());
        _warp(24 hours);
        vault.poke(tl);
        assertEq(uint8(_sub(sl).outcome), uint8(Outcome.Accepted));
        _claimEverythingAndCheck();
    }

    // ================================================================== helpers

    function _contains(bytes memory hay, bytes memory needle) internal pure returns (bool) {
        if (needle.length > hay.length) return false;
        for (uint256 i; i <= hay.length - needle.length; ++i) {
            bool ok = true;
            for (uint256 j; j < needle.length; ++j) {
                if (hay[i + j] != needle[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }
}
