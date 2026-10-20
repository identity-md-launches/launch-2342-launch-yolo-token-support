// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../Base.t.sol";

/// @dev No personal code with the doer's wallet in the proof. One label for everybody,
///      the text `moneycanbuy.fun`, optional: it counts only when the task condition requires it. A proof handed in
///      first by somebody else is a matter for the dispute (NFT, swarm). Tests: the swarm question carries no doer
///      code, the same shape for every doer, and the prompt tells the panel the label is optional.
/// forge-config: default.isolate = false
contract ReviewProofLabel is Base {
    address internal honest = 0xabCDEf1111111111111111111111111111111111;
    address internal thief = 0xaBcdef2222222222222222222222222222222222;

    string internal constant COND = "Post a thread on X about IMD";
    string internal constant PROOF = "https://x.com/honestdoer/status/1934567890123456789";

    function setUp() public override {
        super.setUp();
        _fund(honest);
        _fund(thief);
    }

    function _task() internal returns (uint256) {
        vm.prank(author);
        return vault.createTask{value: 0.001 ether}(
            address(usdc), 50e6, uint64(_now() + TTL), "Thread about IMD", rulesOf(COND), 1, PROOF_X_POST, "", _noSwap()
        );
    }

    string internal constant _SCREENSHOT = "https://i.imgur.com/screenshot.png";

    function _submitAs(address who, uint256 t) internal returns (uint256) {
        vm.prank(who);
        // this task is PROOF_X_POST, a screenshot is mandatory.
        return vault.submit(t, PROOF, Evidence(_SCREENSHOT, ""), 0, type(uint256).max, _noSwap());
    }

    /// @dev No doer code in the question: no "DOER CODE", no `IMD-<task>-` string; DOER stays (onchain_tx is checked
    ///      against the sender).
    function test_QuestionHasNoDoerCode() public {
        uint256 t = _task();
        uint256 s = _submitAs(honest, t);
        bytes memory q = _question(s);
        assertFalse(_has(q, "DOER CODE"));
        assertFalse(_has(q, bytes(string.concat("IMD-", vm.toString(t), "-"))));
        assertTrue(
            _has(
                q,
                bytes(
                    string.concat(
                        " | PROOF TYPE: x_post | DOER: 0xabcdef1111111111111111111111111111111111 | CASE: ",
                        vm.toString(t),
                        "/",
                        vm.toString(s),
                        "/1"
                    )
                )
            )
        );
    }

    /// @dev The prompt: the label is optional, it counts only when the condition requires it.
    function test_PromptSaysTheLabelIsOptional() public {
        bytes memory q = _question(_submitAs(honest, _task()));
        assertTrue(
            _has(
                q,
                "The text moneycanbuy.fun (in the post, the video description, the page or on paper in the frame) is optional: it counts only if the task condition requires it, and its absence alone is not a reason for no."
            )
        );
        assertTrue(_has(q, "For PROOF TYPE onchain_tx the transaction must be sent from DOER."));
    }

    /// @dev Somebody else hands in the same link first: their question differs from the honest one only in DOER and
    ///      CASE (no secret to compare); the honest doer disputes and the panel decides.
    function test_SameLinkFirst_SameQuestionButDoerAndCase() public {
        uint256 t = _task();
        uint256 first = _submitAs(thief, t);
        uint256 mine = _submitAs(honest, t);
        assertEq(uint8(vault.getSubmission(first).phase), uint8(Phase.Review));
        assertEq(uint8(vault.getSubmission(mine).phase), uint8(Phase.Queued));
        _dispute(honest, first);
        _warp(24 hours);
        vault.poke(t);
        bytes memory q = _question(first);
        assertTrue(_has(q, bytes(PROOF)));
        assertTrue(_has(q, " | DOER: 0xabcdef2222222222222222222222222222222222 | CASE: "));
        assertFalse(_has(q, "0xabcdef1111111111111111111111111111111111"));
        assertFalse(_has(q, "DOER CODE"));
    }

    // ================================================================== helpers

    /// @dev Every task here is `_task()` = `rulesOf(COND)`; the dispute reason/proof only matter once a dispute
    ///      was actually filed (the hash check is skipped with none), so passing DISPUTE_REASON/DISPUTER_PROOF
    ///      unconditionally is safe for both the undisputed and the disputed call sites below.
    function _question(uint256 subId) internal view returns (bytes memory q) {
        (bytes memory body,) = vault.previewSwarmBody(
            subId, 2, RuleTexts(COND, TEST_RULE_PROOF, TEST_RULE_NO, DISPUTE_REASON, DISPUTER_PROOF)
        );
        bytes memory head = '{"v":1,"question":"';
        uint256 i = head.length;
        while (body[i] != '"') ++i;
        q = new bytes(i - head.length);
        for (uint256 k; k < q.length; ++k) {
            q[k] = body[head.length + k];
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
