// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "../Base.t.sol";
import {VoteLib} from "../../src/libraries/VoteLib.sol";
import "../../src/VaultTypes.sol";

/// @notice Reaudit money #3: an add-on sweetened during the review is paid to the right votes by the batch
///         claimVoterRewards too, also when the submission itself carries no add-on (s.addon == 0).
/// forge-config: default.isolate = false
contract AddonAfterSubmissionTest is Base {
    function test_AddonAfterSubmission_BatchClaimPaysSweetener() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        assertEq(_sub(s).addon, 0);
        vm.prank(alice);
        sweetener.sweeten(t, 10_000e18);
        _dispute(dave, s);
        _vote(s, 1, VoteLib.SIDE_ACCEPT, 120, 20); // instant decision: accept
        assertEq(uint8(_phase(s)), uint8(Phase.Decided));
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Completed));
        sweetener.payout(t);
        assertEq(sweetener.voterPool(t), 500e18, "5% of the add-on to the right votes");

        uint256[] memory ids = new uint256[](1);
        ids[0] = s;
        uint256 before = yolo.balanceOf(voters[1]);
        vault.claimVoterRewards(ids, voters[1]);
        assertEq(yolo.balanceOf(voters[1]) - before, 500e18, "the batch claim pays the add-on share too");
        assertEq(sweetener.voterPool(t), 0);
    }

    /// @dev Control: the add-on before the submission is claimed in the batch.
    function test_AddonBeforeSubmission_BatchClaimPaysSweetener() public {
        uint256 t = _create(author, address(usdc), 100e6);
        vm.prank(alice);
        sweetener.sweeten(t, 10_000e18);
        uint256 s = _submit(doer, t);
        assertEq(_sub(s).addon, 10_000e18);
        _dispute(dave, s);
        _vote(s, 1, VoteLib.SIDE_ACCEPT, 120, 20);
        _warp(24 hours);
        vault.poke(t);
        sweetener.payout(t);
        uint256[] memory ids = new uint256[](1);
        ids[0] = s;
        uint256 before = yolo.balanceOf(voters[1]);
        vault.claimVoterRewards(ids, voters[1]);
        assertEq(yolo.balanceOf(voters[1]) - before, 500e18);
    }
}
