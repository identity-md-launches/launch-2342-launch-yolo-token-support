// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./Base.t.sol";

/// @dev Every optional user field accepts the empty string, and the author may submit a proof to
///      their own task like any doer.
///      Optional fields: the cover, the doer note, the screenshot link for onchain_tx and link, the
///      disputer's own link (DisputeLinkOptional.t.sol covers the swarm question).
/// forge-config: default.isolate = false
contract OptionalFieldsTest is Base {
    uint8 internal constant REJECT = 2;
    string internal constant SHOT = "https://i.imgur.com/screenshot.png";
    string internal constant XPOST = "https://x.com/doer/status/1";
    string internal constant TXHASH = "0x5f3a9c0d2b7e41a8c6f09d3e7b25a1c4e8f60b9d2a7c3e15f4b8d06a9c2e7f13";

    function _createTyped(uint8 proofType, string memory cover) internal returns (uint256 id) {
        vm.prank(author);
        id = vault.createTask(
            address(usdc),
            50e6,
            uint64(_now() + TTL),
            "Title",
            rulesOf("ipfs://task-condition"),
            0,
            proofType,
            cover,
            _noSwap()
        );
        trackedTasks.push(id);
    }

    function _submitAs(address who, uint256 taskId, string memory proof, Evidence memory e)
        internal
        returns (uint256 subId)
    {
        vm.prank(who);
        subId = vault.submit(taskId, proof, e, 0, type(uint256).max, _noSwap());
    }

    // ================================================================== empty optional fields

    function test_Cover_EmptyAccepted_NonEmptyStillChecked() public {
        uint256 t = _createTyped(PROOF_LINK, "");
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Open));
        vm.prank(author);
        vm.expectRevert(BadCover.selector);
        vault.createTask(
            address(usdc),
            50e6,
            uint64(_now() + TTL),
            "Title",
            rulesOf("ipfs://task-condition"),
            0,
            PROOF_LINK,
            "http://not-https.example/x.png",
            _noSwap()
        );
    }

    function test_Note_EmptyAccepted_EveryProofType() public {
        // x_post / video: the screenshot is mandatory, the note stays optional
        uint256 tX = _createTyped(PROOF_X_POST, "");
        uint256 s1 = _submitAs(doer, tX, XPOST, Evidence(SHOT, ""));
        assertEq(_sub(s1).doerNote, "");
        assertEq(_sub(s1).screenshotUrl, SHOT);
        uint256 tV = _createTyped(PROOF_VIDEO, "");
        _submitAs(doer2, tV, XPOST, Evidence(SHOT, ""));
    }

    function test_Screenshot_EmptyAccepted_OnchainTxAndLink() public {
        uint256 tTx = _createTyped(PROOF_ONCHAIN_TX, "");
        uint256 s1 = _submitAs(doer, tTx, TXHASH, Evidence("", ""));
        assertEq(_sub(s1).screenshotUrl, "");
        uint256 tLink = _createTyped(PROOF_LINK, "");
        uint256 s2 = _submitAs(doer2, tLink, XPOST, Evidence("", "note only"));
        assertEq(_sub(s2).screenshotUrl, "");
        assertEq(_sub(s2).doerNote, "note only");
    }

    function test_DisputerLink_EmptyAccepted() public {
        uint256 t = _create(author, address(usdc), 50e6);
        uint256 s = _submit(doer, t);
        vm.prank(dave);
        vault.dispute{value: ETH_BOND_HEADROOM}(s, DISPUTE_REASON, "", _noSwap());
        assertEq(uint8(_phase(s)), uint8(Phase.Voting));
    }

    // ================================================================== the author submits to their own task

    /// @notice Accepted without a dispute: the author is paid as the doer (90% of R + their bond back), treasury 10%.
    function test_AuthorSubmits_AcceptedQuietly_PaidAsDoer() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(author, t);
        assertEq(_sub(s).doer, author);
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Completed));
        assertEq(vault.credits(address(usdc), author), 90e6 + 3e6, "90% of R + his 3 USDC bond");
        _claimEverythingAndCheck();
    }

    /// @notice Disputed like any submission: the author's proof is rejected by the NFT, they lose their bond and the
    ///         reward stays in the task.
    function test_AuthorSubmits_DisputedRejected_LosesBond() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(author, t);
        _dispute(dave, s);
        _vote(s, 1, REJECT, 120, 20);
        _endVote(s);
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Rejected));
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Open), "reward stays, task open");
        assertEq(vault.credits(address(usdc), author), 0, "no reward, no bond back");
        _claimEverythingAndCheck();
    }
}
