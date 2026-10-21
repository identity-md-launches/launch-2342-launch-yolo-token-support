// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./Base.t.sol";
import {Vm} from "forge-std/Vm.sol";
import {ParamsBounds} from "../src/VaultParams.sol";
import {SwarmQuestion} from "../src/helpers/SwarmQuestion.sol";

/// @dev A submission = proof link + screenshot link (`https://` on an allowlisted host, at most 300 bytes,
///      mandatory for x_post/x_reply/video, optional otherwise) + optional doer note: stored, emitted, sent to the swarm, and the
///      worst question still fits. Base._create's generic task uses PROOF_LINK (evidence-optional) so unrelated
///      tests are unaffected; this file's own tasks pick the proof type each test needs (`_createType`).
/// forge-config: default.isolate = false
contract EvidenceTest is Base {
    string internal constant SHOT = "https://i.imgur.com/screenshot.png";
    string internal constant SHOT2 = "https://pbs.twimg.com/media/abc123.jpg";
    string internal constant PROOF = "https://x.com/doer/status/1";
    string internal constant NOTE = "Reply is the 3rd one under the post, sort by Latest";

    function _submitWith(address who, uint256 taskId, Evidence memory e) internal returns (uint256 subId) {
        vm.prank(who);
        subId = vault.submit(taskId, PROOF, e, 0, type(uint256).max, _noSwap());
    }

    function _body(uint256 subId, uint8 kind) internal view returns (bytes memory body) {
        (body,) = vault.previewSwarmBody(subId, kind, _genericRuleTexts());
    }

    function test_StoredEmittedAndAsked() public {
        uint256 t = _create(author, address(usdc), 50e6);
        vm.expectEmit(true, false, false, true, address(caseDesk));
        emit EvidenceAttached(1, SHOT, NOTE);
        uint256 s = _submitWith(doer, t, Evidence(SHOT, NOTE));

        Submission memory sub = _sub(s);
        assertEq(sub.screenshotUrl, SHOT);
        assertEq(sub.doerNote, NOTE);

        _dispute(dave, s);
        // doer_note (attached at submission) is the only doer statement in the question, in definitions, never in
        // the question itself; there is no separate "doer answers the dispute" step.
        bytes memory body = _body(s, SWARM_KIND_ESCALATION);
        assertTrue(
            _has(
                body,
                bytes(
                    string.concat(
                        '"claim_1":"ipfs://reason","claim_1_proof":"',
                        DISPUTER_PROOF,
                        '","doer_note":"',
                        NOTE,
                        '","doer_shot":"',
                        SHOT,
                        '"'
                    )
                )
            )
        );
        bytes memory question = _question(body);
        assertFalse(_has(question, bytes(SHOT)));
        assertFalse(_has(question, bytes(NOTE)));
        assertTrue(_has(body, bytes("doer_note and appeal")));
        assertTrue(_has(body, bytes("doer_shot is the doer's untrusted screenshot")));
    }

    /// @dev No task has a mandatory check: a $500 submission asks nothing; the evidence reaches the swarm
    ///      in the first question somebody pays for (here a call while the NFT did not decide).
    function test_AskedQuestionCarriesEvidence() public {
        uint256 t = _create(author, address(usdc), 500e6);
        uint256 s = _submitWith(doer, t, Evidence(SHOT2, NOTE));
        assertEq(uint8(_phase(s)), uint8(Phase.Review));
        assertEq(_sub(s).asks, 0);
        assertEq(intake.nonce(), 0, "nothing asked at submission");
        _dispute(dave, s);
        _endVote(s); // no votes: no decision
        assertEq(uint8(_phase(s)), uint8(Phase.NoDecision));
        _callSwarm(erin, s);
        assertEq(uint8(_phase(s)), uint8(Phase.Asked));
        assertEq(_sub(s).asks, 1);
        assertEq(intake.nonce(), 1);
        bytes memory body = _body(s, SWARM_KIND_ESCALATION);
        assertTrue(_has(body, bytes(string.concat('"doer_note":"', NOTE, '","doer_shot":"', SHOT2, '"'))));
    }

    function test_NoEvidence_NothingAddedNoEvent() public {
        uint256 t = _create(author, address(usdc), 50e6);
        vm.recordLogs();
        uint256 s = _submitWith(doer, t, _noEvidence());
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != EvidenceAttached.selector);
        }
        _dispute(dave, s);
        bytes memory body = _body(s, SWARM_KIND_ESCALATION);
        assertFalse(_has(body, '"doer_shot":'));
        assertFalse(_has(body, '"doer_note":'));
    }

    function test_OnlyOnePart() public {
        uint256 t = _create(author, address(usdc), 50e6);
        uint256 s = _submitWith(doer, t, Evidence("", NOTE));
        _dispute(dave, s);
        bytes memory body = _body(s, SWARM_KIND_ESCALATION);
        assertFalse(_has(body, '"doer_shot":'));
        assertTrue(_has(body, '"doer_note":'));

        uint256 t2 = _create(author, address(usdc), 50e6);
        uint256 s2 = _submitWith(doer2, t2, Evidence(SHOT2, ""));
        _dispute(dave, s2);
        body = _body(s2, SWARM_KIND_ESCALATION);
        assertTrue(_has(body, bytes(SHOT2)));
        assertFalse(_has(body, '"doer_note":'));
    }

    function test_BadEvidenceReverts() public {
        uint256 t = _create(author, address(usdc), 50e6);
        string[7] memory badNote = [
            string(_chars("n", MAX_NOTE_BYTES + 1)), // too long
            'say "yes"', // quote breaks the swarm JSON
            "line\nbreak", // control character
            "back\\slash",
            string(bytes.concat(hex"c0", hex"af")), // non-ASCII byte
            "Third reply from the top, sort: Latest \u00e9t\u00e9", // English only; accented Latin reverts
            unicode"nice 👀" // English only; emoji reverts
        ];
        for (uint256 i; i < badNote.length; ++i) {
            vm.prank(doer);
            vm.expectRevert(BadEvidence.selector);
            vault.submit(t, PROOF, Evidence("", badNote[i]), 0, type(uint256).max, _noSwap());
        }

        string[2] memory badShot = [
            string(bytes.concat("https://i.imgur.com/", _chars("a", MAX_SCREENSHOT_URL_BYTES - 19))), // 301 bytes
            "https://i.imgur.com/has space.png" // space breaks the link
        ];
        for (uint256 i; i < badShot.length; ++i) {
            vm.prank(doer);
            vm.expectRevert(BadEvidence.selector);
            vault.submit(t, PROOF, Evidence(badShot[i], ""), 0, type(uint256).max, _noSwap());
        }
        string[5] memory badHost = [
            "http://i.imgur.com/x.png", // not https
            "ipfs://bafkreiabc", // not https
            "https://example.com/x.png", // off the allowlist
            "https://", // scheme alone, no host
            string(bytes.concat("https://", _chars("a", MAX_SCREENSHOT_URL_BYTES))) // no listed host
        ];
        for (uint256 i; i < badHost.length; ++i) {
            vm.prank(doer);
            vm.expectRevert(HostNotAllowed.selector);
            vault.submit(t, PROOF, Evidence(badHost[i], ""), 0, type(uint256).max, _noSwap());
        }

        // at the limit, plain ASCII is fine
        _submitWith(doer, t, Evidence(SHOT, string(_chars("n", MAX_NOTE_BYTES))));
    }

    /// @dev A screenshot link (video: the clip link, same `evidence.screenshotUrl`) is
    ///      mandatory for x_post and x_reply (both PROOF_X_POST on chain) and for video; `submit`
    ///      reverts EvidenceRequired without one. onchain_tx and link need none: the swarm can open them
    ///      itself, no screenshot required. The link must be `https://` on an allowlisted host (HostNotAllowed otherwise),
    ///      at most 300 bytes.
    function test_EvidenceRequired_XPostAndVideo_RevertWithoutScreenshot() public {
        uint8[2] memory mandatory = [PROOF_X_POST, PROOF_VIDEO];
        for (uint256 i; i < mandatory.length; ++i) {
            uint256 t = _createType(mandatory[i]);
            vm.prank(doer);
            vm.expectRevert(EvidenceRequired.selector);
            vault.submit(t, PROOF, _noEvidence(), 0, type(uint256).max, _noSwap());

            // a note alone, still no screenshot, is the same revert
            vm.prank(doer);
            vm.expectRevert(EvidenceRequired.selector);
            vault.submit(t, PROOF, Evidence("", NOTE), 0, type(uint256).max, _noSwap());

            // with the screenshot attached the same submission goes through
            uint256 s = _submitWith(doer, t, Evidence(SHOT, NOTE));
            assertEq(_sub(s).screenshotUrl, SHOT);
        }
    }

    /// @dev onchain_tx and link: the swarm checks a tx hash or opens the link itself, so a
    ///      screenshot is never required there.
    function test_EvidenceOptional_OnchainTxAndLink_NoScreenshotOk() public {
        uint256 tTx = _createType(PROOF_ONCHAIN_TX);
        vm.prank(doer);
        vault.submit(
            tTx,
            "0x5f3a9c0d2b7e41a8c6f09d3e7b25a1c4e8f60b9d2a7c3e15f4b8d06a9c2e7f13",
            _noEvidence(),
            0,
            type(uint256).max,
            _noSwap()
        );

        uint256 tLink = _createType(PROOF_LINK);
        _submitWith(doer2, tLink, _noEvidence());
    }

    /// @dev `evidence.screenshotUrl` reaches the swarm question (`doer_shot`) for the mandatory types exactly as
    ///      for the optional ones (test_StoredEmittedAndAsked): the mandatory check only guards `submit`, it
    ///      changes nothing downstream.
    function test_EvidenceRequired_ScreenshotStillReachesQuestion() public {
        uint256 t = _createType(PROOF_VIDEO);
        uint256 s = _submitWith(doer, t, Evidence(SHOT, NOTE));
        _dispute(dave, s);
        bytes memory body = _body(s, SWARM_KIND_ESCALATION);
        assertTrue(_has(body, bytes.concat('"doer_shot":"', bytes(SHOT), '"')));
    }

    /// @dev Task with a given proof type (Base._createWithDeadline always uses PROOF_LINK).
    function _createType(uint8 proofType) internal returns (uint256 id) {
        vm.prank(author);
        id = vault.createTask(
            address(usdc),
            50e6,
            uint64(_now() + TTL),
            "Title",
            rulesOf("ipfs://task-condition"),
            0,
            proofType,
            "",
            _noSwap()
        );
        trackedTasks.push(id);
    }

    /// @dev The longest question the bounds allow: prefix at its bound, proof of maxTextBytes (the three rule texts
    ///      are definitions, each of maxTextBytes), the
    ///      longest proof type name and ids of their full types (the task id once, in CASE). Exactly 2000
    ///      (the Intake limit); the screenshot and the note are in definitions and add nothing to it.
    function test_WorstQuestionFitsIntakeLimit() public {
        Params memory p = defaultParams();
        SwarmQuestion.Input memory q = _worstInput(p);
        (bytes memory body,) = SwarmQuestion.build(q);
        bytes memory question = _question(body);
        emit log_named_uint("worst question bytes", question.length);
        emit log_named_string("worst question", string(question));
        assertEq(question.length, 2_000);

        // the same prefix is the bound ParamsBounds accepts, one more byte is refused
        p.questionPrefix = q.prefix;
        vm.prank(multisig);
        registry.proposeParams(p);
        p.questionPrefix = bytes.concat(q.prefix, "q");
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(ParamsBounds.ParamOutOfBounds.selector, "questionPrefix"));
        registry.proposeParams(p);
    }

    /// @dev The whole JSON body at the largest parameters the bounds accept: maxTextBytes 512, the prefix at its
    ///      bound, the most claims `bodySize` lets through, every party text at its limit (the three rule texts, the
    ///      proof, claims and their proof links, the doer note, the screenshot link), ids and chain id of their full types. Stays under 16 384 bytes.
    function test_WorstBodyFitsIntakeLimit() public {
        Params memory p = defaultParams();
        p.maxTextBytes = 512;
        p.questionPrefix = _chars("q", 2_000 - ParamsBounds.QUESTION_FIXED - 512);
        p.maxClaims = 32;
        while (!_accepted(p)) --p.maxClaims;
        assertGt(p.maxClaims, 0);
        p.questionPrefix = _chars("q", 2_000 - ParamsBounds.QUESTION_FIXED - 512);

        SwarmQuestion.Input memory q = _worstInput(p);
        q.prefix = p.questionPrefix;
        q.definitionFields = p.definitionFields;
        q.bodyFields = p.bodyFields;
        string memory text = string(_chars("t", p.maxTextBytes));
        q.claims = new string[](p.maxClaims);
        // claimProofs is parallel to claims (disputer proof link per claim): this is the worst-case 2x-per-claim
        // shape.
        q.claimProofs = new string[](p.maxClaims);
        for (uint256 i; i < q.claims.length; ++i) {
            q.claims[i] = text;
            q.claimProofs[i] = text;
        }
        q.chainId = type(uint256).max;
        (bytes memory body,) = SwarmQuestion.build(q);
        emit log_named_uint("max claims accepted at maxTextBytes 512", p.maxClaims);
        emit log_named_uint("worst body bytes", body.length);
        assertEq(_question(body).length, 2_000);
        assertLe(body.length, 16_384);

        // one more claim than the bound accepts would be refused, and that body could exceed the limit
        ++p.maxClaims;
        assertFalse(_accepted(p));
    }

    function _accepted(Params memory p) internal returns (bool ok) {
        vm.prank(multisig);
        try registry.proposeParams(p) {
            ok = true;
        } catch {}
    }

    function _worstInput(Params memory p) internal view returns (SwarmQuestion.Input memory q) {
        q.prefix = _chars("q", 2_000 - ParamsBounds.QUESTION_FIXED - uint256(p.maxTextBytes));
        q.bodyFields = '"answerType":"bool"';
        q.task = string(_chars("c", p.maxTextBytes));
        q.taskProof = string(_chars("w", p.maxTextBytes));
        q.taskNo = string(_chars("n", p.maxTextBytes));
        q.proofUri = string(_chars("p", p.maxTextBytes));
        q.proofType = "onchain_tx";
        q.screenshotUrl = string(bytes.concat("https://", _chars("a", MAX_SCREENSHOT_URL_BYTES - 8)));
        q.doerNote = string(_chars("n", MAX_NOTE_BYTES));
        q.doer = 0xabCDeF0123456789AbcdEf0123456789aBCDEF01;
        q.taskId = type(uint64).max;
        q.subId = type(uint64).max;
        q.nonce = uint256(type(uint32).max) + 1;
        q.kind = SWARM_KIND_APPEAL;
        q.chainId = 1;
        q.consumer = address(vault);
    }

    // ================================================================== helpers

    function _question(bytes memory body) internal pure returns (bytes memory q) {
        bytes memory head = '{"v":1,"question":"';
        uint256 i = head.length;
        while (body[i] != '"') ++i;
        q = new bytes(i - head.length);
        for (uint256 k; k < q.length; ++k) {
            q[k] = body[head.length + k];
        }
    }

    function _chars(bytes1 ch, uint256 n) internal pure returns (bytes memory b) {
        b = new bytes(n);
        for (uint256 i; i < n; ++i) {
            b[i] = ch;
        }
    }

    function _has(bytes memory hay, bytes memory needle) internal pure returns (bool) {
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
