// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./Base.t.sol";
import {Vm} from "forge-std/Vm.sol";

/// @dev The task's rules, the submission's proof link, the evidence (screenshot +
///      doer note) and the disputer's reason/proof link all live on chain only as hashes (Task.rulesHash,
///      DisputerInfo.reasonHash) - everything a reader needs to reconstruct the original text is in the logs
///      only. This test decodes the four events straight from `vm.getRecordedLogs()` (the same bytes a block
///      explorer or an indexer would see, no access to this test's local variables) and checks every string
///      comes back byte-for-byte identical to what was sent in, with no help from storage.
/// forge-config: default.isolate = false
contract LogReconstructionTest is Base {
    string internal constant SHOT = "https://i.imgur.com/screenshot.png";
    string internal constant NOTE = "The Transfer log of the transaction shows the full amount.";

    function test_AllTextsRecoverableFromLogsByteForByte() public {
        TaskRules memory rules = rulesOf("ipfs://task-condition");

        vm.recordLogs();
        uint256 t = _create(author, address(usdc), 50e6);
        vm.prank(doer);
        uint256 s = vault.submit{value: ETH_BOND_HEADROOM}(
            t, "https://x.com/doer/status/1", Evidence(SHOT, NOTE), 0, type(uint256).max, _noSwap()
        );
        _dispute(dave, s);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool sawCreated;
        bool sawSubmitted;
        bool sawEvidence;
        bool sawDisputed;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.topics[0] == TaskCreated.selector) {
                (,,, string memory title, TaskRules memory r,,, string memory cover) =
                    abi.decode(l.data, (address, uint256, uint64, string, TaskRules, uint8, uint8, string));
                // taskId/author are indexed topics, not re-checked here; every non-indexed text field must
                // round-trip exactly as given to createTask.
                assertEq(title, "Title");
                assertEq(r.task, rules.task);
                assertEq(r.proof, rules.proof);
                assertEq(r.noIf, rules.noIf);
                assertEq(cover, "");
                sawCreated = true;
            } else if (l.topics[0] == Submitted.selector) {
                (,,,, string memory proofUri) = abi.decode(l.data, (uint256, uint256, uint256, bool, string));
                assertEq(proofUri, "https://x.com/doer/status/1"); // _submitWith's fixed proof link
                sawSubmitted = true;
            } else if (l.topics[0] == EvidenceAttached.selector) {
                (string memory screenshotUrl, string memory note) = abi.decode(l.data, (string, string));
                assertEq(screenshotUrl, SHOT);
                assertEq(note, NOTE);
                sawEvidence = true;
            } else if (l.topics[0] == Disputed.selector) {
                (,, string memory reason, string memory disputerProofUri) =
                    abi.decode(l.data, (uint256, uint256, string, string));
                assertEq(reason, DISPUTE_REASON);
                assertEq(disputerProofUri, DISPUTER_PROOF);
                sawDisputed = true;
            }
        }
        assertTrue(sawCreated, "TaskCreated missing from logs");
        assertTrue(sawSubmitted, "Submitted missing from logs");
        assertTrue(sawEvidence, "EvidenceAttached missing from logs");
        assertTrue(sawDisputed, "Disputed missing from logs");
    }
}
