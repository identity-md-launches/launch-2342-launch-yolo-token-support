// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {Submission, Task, RuleTexts, RulesMismatch} from "../VaultTypes.sol";

/// @title SwarmQuestion
/// @notice Builds the Intake JSON body (action oracle.request(at)oracle-1, docs "Ask the oracle") on-chain, so no
///         party can smuggle its own question. The task's rule texts and the dispute's reason/proof link are not
///         read from storage: they come in as `RuleTexts`, resupplied by
///         whoever is asking the swarm now, and are checked against Task.rulesHash / DisputerInfo.reasonHash
///         before they ever reach this builder (`SwarmQuestionBuilder.buildFor`):
///         {"v":1,"question":"<prefix>TASK: definitions task, task_proof and task_no | PROOF: .. | PROOF TYPE: x_post
///                             | DOER: 0x.. | CASE: t/s/n",
///          "definitions":{<template definitions>,"task":"..","task_proof":"..","task_no":"..",
///                         "claim_1":"..","claim_1_proof":"..",...,"doer_note":"..",
///                         "doer_shot":"<https:// link, allowlisted host>"},
///          <bodyFields: chainId, window, answerType "bool", evidence, panelSize, quorum, validForSeconds, ...>,
///          "consumer":{"chainId":<chain>,"verifyingContract":"<vault>"}}
///         The question stays short (Intake limit 2000 chars); the task's three rule texts (TaskRules: TASK, PROOF,
///         NO) and the party texts go to `definitions` (values <= 512)
///         and the template must tell the panel they are untrusted claims. All strings were checked at input to
///         contain no quote, backslash or control characters, so they are embedded verbatim.
///         `questionHash` returned here is keccak256(question): the real derivation used by the IMD plane is
///         UNVERIFIED. It is only recorded (SwarmAsked, SwarmRequest): the callback path does not use it.
library SwarmQuestion {
    // kind 1 is reserved
    uint8 internal constant KIND_ESCALATION = 2; // = SWARM_KIND_ESCALATION
    uint8 internal constant KIND_APPEAL = 3; // = SWARM_KIND_APPEAL
    /// @dev Where the question points the panel for the task: its rules are the definitions task (TASK), task_proof
    ///      (WINDOW, WHO, PROOF, SOURCE) and task_no (NO if). Counted in ParamsBounds.QUESTION_FIXED.
    bytes internal constant TASK_REF = "TASK: definitions task, task_proof and task_no";

    struct Input {
        bytes prefix;
        bytes definitionFields; // template definitions: compact JSON members, may be empty
        bytes bodyFields;
        string task; // TaskRules.task: definition "task"
        string taskProof; // TaskRules.proof: definition "task_proof"
        string taskNo; // TaskRules.noIf: definition "task_no"
        string proofUri;
        string proofType; // x_post | video | onchain_tx | link
        string screenshotUrl; // Evidence.screenshotUrl: empty = none
        string doerNote;
        address doer;
        uint256 taskId;
        uint256 subId;
        uint256 nonce;
        uint8 kind;
        string[] claims; // dispute reasons, in filing order
        string[] claimProofs; // parallel to claims: the disputer's own proof link
        uint256 chainId;
        address consumer;
    }

    function build(Input memory q) internal pure returns (bytes memory body, bytes32 questionHash) {
        bytes memory question = bytes.concat(
            q.prefix,
            TASK_REF,
            " | PROOF: ",
            bytes(q.proofUri),
            " | PROOF TYPE: ",
            bytes(q.proofType),
            " | DOER: ",
            bytes(Strings.toHexString(q.doer)),
            " | CASE: ",
            bytes(Strings.toString(q.taskId)),
            "/",
            bytes(Strings.toString(q.subId)),
            "/",
            bytes(Strings.toString(q.nonce))
        );
        questionHash = keccak256(question);

        bytes memory defs = q.definitionFields;
        // the task's rules, one definition each (each 1..maxTextBytes <= 512, the Intake limit of a definition value)
        defs = _member(defs, "task", bytes(q.task));
        defs = _member(defs, "task_proof", bytes(q.taskProof));
        defs = _member(defs, "task_no", bytes(q.taskNo));
        for (uint256 i; i < q.claims.length; ++i) {
            bytes memory idx = bytes(Strings.toString(i + 1));
            defs = _member(defs, bytes.concat("claim_", idx), bytes(q.claims[i]));
            // the disputer's own proof link, one definition per claim (parallel to
            // claim_N), not merged into the reason text.
            defs = _member(defs, bytes.concat("claim_", idx, "_proof"), bytes(q.claimProofs[i]));
        }
        // the doer's "why honest" text, attached to the proof at submission (no separate
        // "doer answers the dispute" step)
        defs = _member(defs, "doer_note", bytes(q.doerNote));
        defs = _member(defs, "doer_shot", bytes(q.screenshotUrl));
        // no "appeal" definition: an appeal/call of the swarm carries no text.

        body = bytes.concat('{"v":1,"question":"', question, '"');
        if (defs.length != 0) body = bytes.concat(body, ',"definitions":{', defs, "}");
        body = bytes.concat(
            body,
            ",",
            q.bodyFields,
            ',"consumer":{"chainId":',
            bytes(Strings.toString(q.chainId)),
            ',"verifyingContract":"',
            bytes(Strings.toHexString(q.consumer)),
            '"}}'
        );
    }

    /// @dev Name of a proof type in the question (the same words the site and the templates use).
    function proofTypeName(uint8 proofType) internal pure returns (string memory) {
        if (proofType == 0) return "x_post";
        if (proofType == 1) return "video";
        if (proofType == 2) return "onchain_tx";
        return "link";
    }

    /// @dev Appends `"key":"value"` to a list of JSON members; empty values are skipped.
    function _member(bytes memory list, bytes memory key, bytes memory value) private pure returns (bytes memory) {
        if (value.length == 0) return list;
        bytes memory m = bytes.concat('"', key, '":"', value, '"');
        return list.length == 0 ? m : bytes.concat(list, ",", m);
    }
}

/// @title SwarmQuestionBuilder
/// @notice Stateless helper of the CaseDesk: assembles the question of a submission from what the vault's desks
///         store (their public views) and builds the Intake body. Read-only; the vault pays and sends it.
contract SwarmQuestionBuilder {
    /// @param maxClaims how many dispute reasons go into the question (the task's parameter version)
    /// @param rt the task rule texts and the filed dispute's reason/proof link,
    ///        resupplied by whoever is asking the swarm now (DisputeDesk.callSwarm, CaseDesk.askAppealSwarm) -
    ///        storage holds only their hashes (Task.rulesHash, DisputerInfo.reasonHash).
    function buildFor(address vault, uint256 subId, uint8 kind, uint256 maxClaims, RuleTexts calldata rt)
        external
        view
        returns (bytes memory body, bytes32 questionHash)
    {
        IQuestionSources v = IQuestionSources(vault);
        Submission memory s = IQuestionSources(v.caseDesk()).getSubmission(subId);
        Task memory t = v.getTask(s.taskId);
        if (keccak256(abi.encode(rt.task, rt.taskProof, rt.taskNo)) != t.rulesHash) revert RulesMismatch();
        // slither-disable-next-line uninitialized-local
        SwarmQuestion.Input memory q;
        (q.prefix, q.definitionFields, q.bodyFields) = IQuestionSources(v.registry()).template(t.paramsVersion);
        q.task = rt.task;
        q.taskProof = rt.taskProof;
        q.taskNo = rt.taskNo;
        q.proofType = SwarmQuestion.proofTypeName(t.proofType);
        q.proofUri = s.proofUri;
        q.screenshotUrl = s.screenshotUrl;
        q.doerNote = s.doerNote;
        q.doer = s.doer;
        q.taskId = s.taskId;
        q.subId = subId;
        q.nonce = uint256(s.asks) + 1; // unique per question of this submission
        q.kind = kind;
        // at most one dispute reason (one dispute, one disputer). No "appeal" text.
        (q.claims, q.claimProofs) =
            IQuestionSources(v.disputeDesk()).questionPart(subId, maxClaims, rt.disputeReason, rt.disputerProofUri);
        q.chainId = block.chainid;
        q.consumer = vault;
        return SwarmQuestion.build(q);
    }
}

/// @dev The views the builder reads: the vault's tasks and desk addresses, the desks' records, the registry's template.
interface IQuestionSources {
    function registry() external view returns (address);
    function caseDesk() external view returns (address);
    function disputeDesk() external view returns (address);
    function getSubmission(uint256 subId) external view returns (Submission memory);
    function getTask(uint256 taskId) external view returns (Task memory);
    function template(uint32 version) external view returns (bytes memory, bytes memory, bytes memory);
    function questionPart(uint256 subId, uint256 maxClaims, string calldata reason, string calldata disputerProofUri)
        external
        view
        returns (string[] memory claims, string[] memory claimProofs);
}
