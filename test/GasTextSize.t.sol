// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./Base.t.sol";
import {rulesForehead, rulesSupermarket} from "./mocks/TaskRulesFixture.sol";

/// @dev createTask / submit / dispute gas with representative real-world task
///      texts (forehead, supermarket) and with 3x512B (every field at the maxTextBytes ceiling), split into
///      "text bytes" vs "everything else" by diffing against a 1-byte-text baseline on the same contract call path.
/// forge-config: default.isolate = false
contract GasTextSizeTest is Base {
    function setUp() public override {
        super.setUp();
        _create(author, address(usdc), 50e6); // warms the registry/desks once, same as GasTest
    }

    uint256 internal g0;

    function _start() internal {
        g0 = gasleft();
    }

    function _measure(string memory name) internal returns (uint256 g) {
        g = g0 - gasleft();
        emit log_named_uint(name, g);
    }

    function _bytes(bytes1 ch, uint256 n) internal pure returns (string memory) {
        bytes memory b = new bytes(n);
        for (uint256 i; i < n; ++i) {
            b[i] = ch;
        }
        return string(b);
    }

    function _createWithRules(TaskRules memory r) internal returns (uint256 id) {
        vm.prank(author);
        id = vault.createTask{value: 0.001 ether}(
            address(usdc), 50e6, uint64(_now() + TTL), "Title", r, 1, PROOF_X_POST, "", _noSwap()
        );
    }

    /// forge-config: default.isolate = true
    function test_CreateTask_RealExamples_And_MaxText() public {
        // minimal baseline: 1 byte per field (3 bytes of rule text total)
        TaskRules memory tiny = TaskRules(_bytes("a", 1), _bytes("a", 1), _bytes("a", 1));
        _start();
        _createWithRules(tiny);
        uint256 gTiny = _measure("createTask (1+1+1 B rules, floor)");

        _start();
        _createWithRules(rulesForehead()); // 114 / 376 / 219 B (a real-world task text example)
        uint256 gForehead = _measure("createTask (forehead: 114+376+219=709 B)");
        emit log_named_uint("  of which text-size delta over floor", gForehead - gTiny);

        _start();
        _createWithRules(rulesSupermarket()); // 307 / 405 / 188 B
        uint256 gSuper = _measure("createTask (supermarket: 307+405+188=900 B)");
        emit log_named_uint("  of which text-size delta over floor", gSuper - gTiny);

        TaskRules memory max3 = TaskRules(_bytes("b", 512), _bytes("c", 512), _bytes("d", 512));
        _start();
        _createWithRules(max3); // 3x512 = 1536 B, the absolute ceiling (maxTextBytes=512 each)
        uint256 gMax = _measure("createTask (3x512=1536 B, ceiling)");
        emit log_named_uint("  of which text-size delta over floor", gMax - gTiny);
    }

    function test_Submit_MaxProofAndExplanation() public {
        uint256 t = _create(author, address(usdc), 100e6); // _create's task is PROOF_LINK
        string memory proof = string.concat("https://x.com/", _bytes("a", 512 - 14)); // 512 B, allowlisted host + link form
        _start();
        vm.prank(doer);
        vault.submit{value: ETH_BOND_HEADROOM}(
            t, proof, Evidence("", _bytes("n", MAX_NOTE_BYTES)), 0, type(uint256).max, _noSwap()
        );
        _measure("submit (proof 512B link + explanation/doerNote 200B, the max note)");
    }

    function test_Dispute_MaxReason() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        _start();
        vm.prank(dave);
        // disputerProofUri field, same 512B cap as reason.
        vault.dispute{value: ETH_BOND_HEADROOM}(s, _bytes("r", 512), _bytes("p", 512), _noSwap());
        _measure("dispute (reason 512B + disputerProofUri 512B)");
    }

    /// @dev callSwarm resupplying the task's 3x512B rules + the disputer's
    ///      512B reason/proof in the same call that asks the swarm - this is the full "after" cost of an escalation,
    ///      not just the text-storage delta (compare against test/Disputes.t.sol-style callSwarm gas separately).
    function test_CallSwarm_MaxResupply() public {
        TaskRules memory max3 = TaskRules(_bytes("b", 512), _bytes("c", 512), _bytes("d", 512));
        uint256 t = _createWithRules(max3);
        // _createWithRules uses PROOF_X_POST, which needs a screenshot (EvidenceRequired
        // otherwise) - _submit's plain _noEvidence() does not carry one, unlike every other test in this file.
        vm.prank(doer);
        uint256 s = vault.submit{value: ETH_BOND_HEADROOM}(
            t,
            "https://x.com/doer/status/1",
            Evidence("https://i.imgur.com/screenshot.png", ""),
            0,
            type(uint256).max,
            _noSwap()
        );
        vm.prank(dave);
        vault.dispute{value: ETH_BOND_HEADROOM}(s, _bytes("r", 512), _bytes("p", 512), _noSwap());
        _warp(24 hours); // Review -> Voting with no votes -> NoDecision
        vault.poke(t);
        _start();
        vm.prank(erin);
        vault.callSwarm{value: ETH_BOND_HEADROOM}(
            s,
            false,
            type(uint256).max,
            _noSwap(),
            RuleTexts(max3.task, max3.proof, max3.noIf, _bytes("r", 512), _bytes("p", 512))
        );
        _measure("callSwarm (resupply: 3x512B rules + reason 512B + disputerProofUri 512B, hash+calldata scheme)");
    }
}
