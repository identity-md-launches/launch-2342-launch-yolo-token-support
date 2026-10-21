// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./Base.t.sol";

/// @dev claimVoterRewards: the voter rewards of one payTo on many submissions in one transaction pay
///      exactly what the single claims would, $YOLO bonus shares included; nothing claimable is skipped.
/// forge-config: default.isolate = false
contract VoteBatchTest is Base {
    uint8 internal constant ACCEPT = 1;
    uint8 internal constant REJECT = 2;

    /// @dev A dispute the NFT decides "accept" at once (20 NFTs of voters[1] = instantDelta) and that ends accepted.
    function _acceptedAfterVote(address currency, uint256 amount) internal returns (uint256 t, uint256 s) {
        t = _create(author, currency, amount);
        s = _submit(doer, t);
        _dispute(dave, s);
        _vote(s, 1, ACCEPT, 120, 20);
        assertEq(uint8(_phase(s)), uint8(Phase.Decided));
    }

    function _finish(uint256 t) internal {
        _warp(48 hours);
        vault.poke(t);
    }

    function _balances(address who) internal view returns (uint256[4] memory b) {
        b = [imd.balanceOf(who), usdc.balanceOf(who), who.balance, yolo.balanceOf(who)];
    }

    function _delta(uint256[4] memory a, uint256[4] memory b) internal pure returns (uint256[4] memory d) {
        for (uint256 i; i < 4; ++i) {
            d[i] = b[i] - a[i];
        }
    }

    function test_Batch_PaysWhatSingleClaimsPay() public {
        (uint256 t1, uint256 s1) = _acceptedAfterVote(address(usdc), 100e6);
        (uint256 t2, uint256 s2) = _acceptedAfterVote(ETH, 0.01 ether);
        (uint256 t3, uint256 s3) = _acceptedAfterVote(address(usdc), 40e6);
        _finish(t1);
        _finish(t2);
        _finish(t3);
        // a submission still voting, and one voters[1] did not vote on: skipped by the batch
        uint256 t4 = _create(author, address(usdc), 30e6);
        uint256 s4 = _submit(doer, t4);
        _dispute(dave, s4);
        _vote(s4, 2, REJECT, 140, 5);

        uint256 snap = vm.snapshotState();
        uint256[4] memory a = _balances(voters[1]);
        vault.claimVoterReward(s1, voters[1]);
        vault.claimVoterReward(s2, voters[1]);
        vault.claimVoterReward(s3, voters[1]);
        uint256[4] memory single = _delta(a, _balances(voters[1]));
        assertGt(single[0], 0, "IMD bond share");
        assertGt(single[1], 0, "USDC share");
        assertGt(single[2], 0, "ETH share");
        vm.revertToState(snap);

        uint256[] memory ids = new uint256[](5);
        (ids[0], ids[1], ids[2], ids[3], ids[4]) = (s1, s4, s2, s3, s1); // s1 twice: paid once
        a = _balances(voters[1]);
        vm.prank(erin); // anyone may trigger, the money goes to payTo
        vault.claimVoterRewards(ids, voters[1]);
        uint256[4] memory batch = _delta(a, _balances(voters[1]));
        for (uint256 i; i < 4; ++i) {
            assertEq(batch[i], single[i]);
        }
        assertTrue(vault.voterClaimed(s1, voters[1]) && vault.voterClaimed(s2, voters[1]));
        assertTrue(vault.voterClaimed(s3, voters[1]));
        assertFalse(vault.voterClaimed(s4, voters[1]));
        vm.expectRevert(NothingToClaim.selector);
        vault.claimVoterReward(s2, voters[1]);
        _endVote(s4);
        _finish(t4);
        _claimEverythingAndCheck();
    }

    function test_Batch_NothingToClaimReverts() public {
        (uint256 t1, uint256 s1) = _acceptedAfterVote(address(usdc), 100e6);
        uint256[] memory ids = new uint256[](1);
        ids[0] = s1;
        vm.expectRevert(NothingToClaim.selector); // not final yet
        vault.claimVoterRewards(ids, voters[1]);
        _finish(t1);
        vm.expectRevert(NothingToClaim.selector); // voters[2] did not vote
        vault.claimVoterRewards(ids, voters[2]);
        vault.claimVoterRewards(ids, voters[1]);
        vm.expectRevert(NothingToClaim.selector); // already claimed
        vault.claimVoterRewards(ids, voters[1]);
        vm.expectRevert(NothingToClaim.selector);
        vault.claimVoterRewards(new uint256[](0), voters[1]);
        _claimEverythingAndCheck();
    }

    function test_Batch_TakesTheYoloBonusShare() public {
        uint256 t1 = _create(author, ETH, 0.01 ether);
        vm.prank(alice);
        sweetener.sweeten(t1, 1_000_000e18);
        uint256 s1 = _submit(doer, t1);
        _dispute(dave, s1);
        _vote(s1, 1, ACCEPT, 120, 20);
        (uint256 t2, uint256 s2) = _acceptedAfterVote(address(usdc), 100e6);
        _finish(t1);
        _finish(t2);
        sweetener.payout(t1);
        assertEq(sweetener.voterPool(t1), 50_000e18);

        uint256 snap = vm.snapshotState();
        uint256[4] memory a = _balances(voters[1]);
        vault.claimVoterReward(s1, voters[1]);
        vault.claimVoterReward(s2, voters[1]);
        sweetener.claimVoter(t1, voters[1]);
        uint256[4] memory single = _delta(a, _balances(voters[1]));
        // the whole voter pool (voters[1] cast every accept vote); no bond has a $YOLO part
        assertEq(single[3], 50_000e18);
        vm.revertToState(snap);

        uint256[] memory ids = new uint256[](2);
        (ids[0], ids[1]) = (s1, s2);
        a = _balances(voters[1]);
        vault.claimVoterRewards(ids, voters[1]);
        uint256[4] memory batch = _delta(a, _balances(voters[1]));
        for (uint256 i; i < 4; ++i) {
            assertEq(batch[i], single[i]);
        }
        assertTrue(sweetener.voterClaimed(t1, voters[1]));
        vm.expectRevert(YoloSweetener.NothingToPay.selector);
        sweetener.claimVoter(t1, voters[1]);
        _claimEverythingAndCheck();
    }

    /// @dev The bonus is not paid out yet when the voter claims: the vault shares are paid, the bonus share stays
    ///      claimable on the sweetener.
    function test_Batch_BonusNotPaidOutYet_StaysClaimable() public {
        uint256 t1 = _create(author, ETH, 0.01 ether);
        vm.prank(alice);
        sweetener.sweeten(t1, 1_000_000e18);
        uint256 s1 = _submit(doer, t1);
        _dispute(dave, s1);
        _vote(s1, 1, ACCEPT, 120, 20);
        _finish(t1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = s1;
        uint256 e0 = voters[1].balance;
        vault.claimVoterRewards(ids, voters[1]);
        assertGt(voters[1].balance, e0);
        assertFalse(sweetener.voterClaimed(t1, voters[1]));
        sweetener.payout(t1);
        uint256 y0 = yolo.balanceOf(voters[1]);
        sweetener.claimVoter(t1, voters[1]);
        assertEq(yolo.balanceOf(voters[1]) - y0, 50_000e18);
        _claimEverythingAndCheck();
    }
}
