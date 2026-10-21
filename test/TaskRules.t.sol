// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./Base.t.sol";
import {ParamsBounds, LaunchParams} from "../src/VaultParams.sol";

/// @dev Task rules in three fields: TASK, PROOF (WINDOW + WHO + PROOF + SOURCE) and NO, each
///      1..maxTextBytes, each its own swarm definition. Runs under the launch value maxTextBytes = 512.
/// forge-config: default.isolate = false
contract TaskRulesTest is Base {
    function setUp() public override {
        super.setUp();
        Params memory p = defaultParams();
        p.maxTextBytes = 512; // LaunchParams.initial
        vm.prank(multisig);
        registry.proposeParams(p);
        _warp(48 hours);
        registry.activateParams();
        assertEq(registry.core(registry.currentVersion()).maxTextBytes, 512);
    }

    function _createRules(TaskRules memory r, uint8 proofType) internal returns (uint256 id) {
        vm.prank(author);
        id = vault.createTask(address(usdc), 50e6, uint64(_now() + TTL), "Title", r, 0, proofType, "", _noSwap());
        trackedTasks.push(id);
    }

    function _expectBadText(TaskRules memory r) internal {
        vm.prank(author);
        vm.expectRevert(BadText.selector);
        vault.createTask(address(usdc), 50e6, uint64(_now() + TTL), "Title", r, 0, PROOF_LINK, "", _noSwap());
    }

    function _chars(bytes1 ch, uint256 n) internal pure returns (string memory) {
        bytes memory b = new bytes(n);
        for (uint256 i; i < n; ++i) {
            b[i] = ch;
        }
        return string(b);
    }

    function _max() internal pure returns (TaskRules memory) {
        return TaskRules(_chars("t", 512), _chars("p", 512), _chars("n", 512));
    }

    // storage holds only the hash (the text is in the TaskCreated event).
    function _assertStored(uint256 id, TaskRules memory r) internal view {
        Task memory t = vault.getTask(id);
        assertEq(t.rulesHash, keccak256(abi.encode(r.task, r.proof, r.noIf)));
    }

    // ================================================================== long rule examples

    /// @dev A 700 B example in one text: does not fit one 512 B field, fits three.
    function test_OwnerExample_Forehead_Creates() public {
        TaskRules memory r = rulesForehead();
        assertGt(bytes(r.task).length + bytes(r.proof).length + bytes(r.noIf).length, 512);
        uint256 next = vault.taskCount() + 1;
        vm.expectEmit(address(vault));
        emit TaskCreated(next, author, address(usdc), 50e6, uint64(_now() + TTL), "Title", r, 0, PROOF_X_POST, "");
        uint256 id = _createRules(r, PROOF_X_POST);
        _assertStored(id, r);
    }

    /// @dev An 899 B example in one text: TASK + SPEECH, PROOF block, NO block.
    function test_OwnerExample_Supermarket_Creates() public {
        TaskRules memory r = rulesSupermarket();
        assertGt(bytes(r.task).length + bytes(r.proof).length + bytes(r.noIf).length, 512);
        uint256 id = _createRules(r, PROOF_VIDEO);
        _assertStored(id, r);
    }

    /// @dev 3 x 512 B = 1536 B of rules: the largest task the launch parameters accept.
    function test_ThreeTimes512_Creates() public {
        TaskRules memory r = _max();
        uint256 id = _createRules(r, PROOF_LINK);
        _assertStored(id, r);
    }

    // ================================================================== limits

    /// @dev 513 bytes in any of the three fields reverts; so does an empty one or a straight quote.
    function test_EachField_513BytesReverts() public {
        string memory big = _chars("x", 513);
        TaskRules memory r = _max();
        r.task = big;
        _expectBadText(r);
        r = _max();
        r.proof = big;
        _expectBadText(r);
        r = _max();
        r.noIf = big;
        _expectBadText(r);
    }

    function test_EachField_EmptyOrBadCharReverts() public {
        TaskRules memory r = rulesForehead();
        r.task = "";
        _expectBadText(r);
        r = rulesForehead();
        r.proof = "";
        _expectBadText(r);
        r = rulesForehead();
        r.noIf = "";
        _expectBadText(r);
        r = rulesForehead();
        r.proof = 'PROOF: a "quoted" word';
        _expectBadText(r);
        r = rulesForehead();
        r.noIf = "NO if: line\nbreak";
        _expectBadText(r);
    }

    // ================================================================== the swarm question

    /// @dev Each rule text is its own definition, verbatim; the question only points to them and stays <= 2000.
    function test_SwarmBody_ThreeDefinitions() public {
        TaskRules memory r = rulesSupermarket();
        uint256 t = _createRules(r, PROOF_LINK);
        uint256 s = _submit(doer, t);
        _dispute(dave, s);
        _warp(24 hours);
        vault.poke(t);
        (bytes memory body,) = vault.previewSwarmBody(
            s, SWARM_KIND_ESCALATION, RuleTexts(r.task, r.proof, r.noIf, DISPUTE_REASON, DISPUTER_PROOF)
        );
        assertTrue(_has(body, bytes.concat('"task":"', bytes(r.task), '"')));
        assertTrue(_has(body, bytes.concat('"task_proof":"', bytes(r.proof), '"')));
        assertTrue(_has(body, bytes.concat('"task_no":"', bytes(r.noIf), '"')));
        assertTrue(_has(body, "TASK: definitions task, task_proof and task_no | PROOF: https://x.com/doer/status/1"));
        bytes memory q = _question(body);
        assertFalse(_has(q, bytes(r.task)));
        assertLe(q.length, 2_000);
        assertLe(body.length, 16_384);
        emit log_named_uint("supermarket: question bytes", q.length);
        emit log_named_uint("supermarket: body bytes", body.length);
    }

    /// @dev The launch parameters (maxTextBytes 512, maxClaims 10) pass the bounds with the three rule texts counted.
    function test_LaunchParams_PassBounds() public pure {
        Params memory p = LaunchParams.initial(address(1), address(1), address(1), address(1), address(1), address(1));
        assertEq(p.maxTextBytes, 512);
        ParamsBounds.validate(p);
    }

    // ================================================================== gas

    /// @dev createTask gas for the long-rule examples and the 3 x 512 B case, each in its own test (cold state, like a
    ///      real transaction). `exec` is measured around the call; `tx` adds the 21000 base and the calldata
    ///      (EIP-2028: 16 per nonzero byte, 4 per zero byte).
    function test_Gas_CreateTask_Forehead() public {
        _gas("forehead", rulesForehead(), PROOF_X_POST);
    }

    function test_Gas_CreateTask_Supermarket() public {
        _gas("supermarket", rulesSupermarket(), PROOF_VIDEO);
    }

    function test_Gas_CreateTask_3x512() public {
        _gas("3x512", _max(), PROOF_LINK);
    }

    function _gas(string memory name, TaskRules memory r, uint8 proofType) internal {
        bytes memory data = abi.encodeCall(
            ITaskVault.createTask, (address(usdc), 50e6, uint64(_now() + TTL), "Title", r, 0, proofType, "", _noSwap())
        );
        uint256 cd;
        for (uint256 i; i < data.length; ++i) {
            cd += data[i] == 0 ? 4 : 16;
        }
        vm.prank(author);
        uint256 g = gasleft();
        (bool ok,) = address(vault).call(data);
        uint256 exec = g - gasleft();
        assertTrue(ok);
        emit log_named_uint(string.concat("createTask ", name, " exec gas"), exec);
        emit log_named_uint(string.concat("createTask ", name, " tx gas (exec + 21000 + calldata)"), exec + 21_000 + cd);
    }

    // ================================================================== helpers

    function _has(bytes memory hay, bytes memory needle) internal pure returns (bool) {
        if (needle.length > hay.length) return false;
        for (uint256 i; i <= hay.length - needle.length; ++i) {
            uint256 k;
            while (k < needle.length && hay[i + k] == needle[k]) ++k;
            if (k == needle.length) return true;
        }
        return false;
    }

    function _question(bytes memory body) internal pure returns (bytes memory q) {
        bytes memory head = '{"v":1,"question":"';
        uint256 i = head.length;
        while (body[i] != '"') ++i;
        q = new bytes(i - head.length);
        for (uint256 k; k < q.length; ++k) {
            q[k] = body[head.length + k];
        }
    }
}
