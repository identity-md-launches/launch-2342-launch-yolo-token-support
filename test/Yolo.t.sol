// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./Base.t.sol";

/// @dev $YOLO, the fourth reward currency: paid and refunded in YOLO, the bonds' percent part in $YOLO itself
///      (no oracle, no IMD conversion). There is no mandatory swarm check at any size, the smallest reward is
///      minRewardYolo in $YOLO itself (no USD limit), no price is read at task creation,
///      the treasury's share of a $YOLO reward burned, the reward
///      locked until the deadline.
/// forge-config: default.isolate = false
contract YoloTest is Base {
    // sized relative to the test YOLO and IMD prices set in Base.t.sol
    uint256 constant R = 2_000_000e18;

    function test_YoloTaskAcceptedPaysInYolo() public {
        uint256 authorBefore = yolo.balanceOf(author);
        uint256 t = _create(author, address(yolo), R);
        assertEq(yolo.balanceOf(author), authorBefore - R);
        uint256 s = _submit(doer, t);
        Submission memory sub = _sub(s);
        assertEq(sub.bond.imd, _fixedBond(), "0.5 IMD fixed");
        assertEq(sub.bond.rew, 60_000e18, "3% of R, in $YOLO itself");
        assertEq(sub.bond.rew, _bondOf(R));
        assertEq(sub.request, bytes32(0), "no swarm question");
        uint256 dead0 = yolo.balanceOf(address(burner));
        vm.warp(sub.windowEnd + 1);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        // the reward and the doer's own rew bond are both credited (never pushed straight to their
        // wallet) on acceptance, so nothing here is paid "direct" outside the credits ledger; `_paidDirect` would
        // underflow regardless (they already paid their bond out of their wallet balance, not yet refunded as a balance).
        assertEq(
            vault.credits(address(yolo), doer), R * 90 / 100 + _bondOf(R), "R - 10% in YOLO, plus his rew bond back"
        );
        assertEq(vault.treasuryPot(address(yolo)), 0, "the treasury never holds $YOLO");
        assertEq(
            yolo.balanceOf(address(burner)) - dead0, R / 10, "the treasury's 10% in $YOLO burned (no stake, no NFT)"
        );
        _claimEverythingAndCheck();
    }

    /// There is no mandatory swarm check at any size, and no cap on the reward: a large reward is created fine.
    function test_YoloNoMandatoryCheckAtAnySize() public {
        uint256 t = _create(author, address(yolo), 10_000_000e18);
        uint256 s = _submit(doer, t);
        Submission memory sub = _sub(s);
        assertEq(uint8(sub.phase), uint8(Phase.Review), "straight to the dispute window");
        assertEq(sub.request, bytes32(0), "no swarm question");
        assertEq(sub.asks, 0);
        assertEq(sub.reward, 10_000_000e18);
        assertEq(sub.bond.rew, 300_000e18, "3% of R, in $YOLO");
        uint256 big = _create(author, address(yolo), 100_000_000e18); // no cap
        assertEq(vault.getTask(big).pot, 100_000_000e18);
    }

    /// minRewardYolo = 1000e18: the reward's own currency, no dollars.
    function test_YoloBelowMinimumRefused() public {
        vm.prank(author);
        vm.expectRevert(RewardTooSmall.selector);
        vault.createTask(
            address(yolo), 1_000e18 - 1, uint64(_now() + 1 days), "Title", rulesOf("c"), 0, 0, "", _noSwap()
        );
    }

    /// A task without a deadline cannot be created.
    function test_NoDeadlineRefused() public {
        vm.prank(author);
        vm.expectRevert(BadDeadline.selector);
        vault.createTask(address(yolo), R, 0, "Title", rulesOf("c"), 0, 0, "", _noSwap());
    }

    /// No price is needed anywhere: creation, topUp and the
    /// doer bond read no price (minReward is per-currency, there is no USD limit, and the bond's percent part is
    /// paid in the reward's own currency with no IMD conversion).
    function test_UnpricedYolo_NoPriceNeededAnywhere() public {
        oracle.set(address(yolo), 0, 18); // no $YOLO price
        assertFalse(oracle.hasPrice(address(yolo)));
        vm.prank(author);
        uint256 t = vault.createTask(
            address(yolo), R, uint64(_now() + 1 days), "Title", rulesOf("c"), 0, PROOF_LINK, "", _noSwap()
        );
        trackedTasks.push(t);

        vm.prank(alice);
        vault.topUp(t, 1e18, _noSwap()); // still no price: topUp goes through anyway
        assertEq(vault.getTask(t).pot, R + 1e18);
        vm.prank(author);
        vm.expectRevert(TaskNotOpen.selector);
        vault.withdrawContribution(t); // locked until the deadline, price or not

        Bond memory quoted = vault.quoteSubmission(t); // no revert: the bond needs no oracle
        assertEq(quoted.rew, _bondOf(R), "3% of the author's R (alice's top-up is no part of it)");
        uint256 s = _submit(doer, t); // still no price: submission goes through anyway
        assertEq(_sub(s).bond.rew, _bondOf(R));
        _claimEverythingAndCheck();
    }

    /// The bond reads no price
    /// at all: a DevPrices that reverts only drops the (optional) doer stake bonus,
    /// never the submission itself.
    function test_YoloWithRevertingDevPrices_SubmissionStillWorks() public {
        uint256 t = _create(author, address(yolo), 100_000e18); // $10
        oracle.setBroken(true);
        Bond memory bond = vault.quoteSubmission(t); // no revert: no oracle call in the bond quote
        assertEq(bond.rew, _bondOf(100_000e18));
        uint256 s = _submit(doer, t); // no revert either
        assertEq(_sub(s).bond.rew, bond.rew);
        oracle.setBroken(false);
    }

    /// A contributor's top-up is locked until the deadline;
    /// after the expiry everyone takes back their own.
    function test_YoloTopUp_LockedUntilExpiry_ThenBack() public {
        uint256 t = _createWithDeadline(author, address(yolo), R, uint64(_now() + 10 days));
        _topUp(alice, t, R);
        assertEq(vault.getTask(t).pot, 2 * R);
        vm.prank(alice);
        vm.expectRevert(TaskNotOpen.selector);
        vault.withdrawContribution(t);
        _warp(10 days);
        vault.poke(t);
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Expired));
        uint256 before = yolo.balanceOf(alice);
        vm.prank(alice);
        vault.withdrawContribution(t);
        assertEq(yolo.balanceOf(alice) - before, R);
        before = yolo.balanceOf(author);
        vm.prank(author);
        vault.withdrawContribution(t);
        assertEq(yolo.balanceOf(author) - before, R);
    }

    function test_OtherTokensStillRefused() public {
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        vm.prank(author);
        vm.expectRevert(BadCurrency.selector);
        vault.createTask(address(other), 1e18, uint64(_now() + 1 days), "Title", rulesOf("c"), 0, 0, "", _noSwap());
    }

    // ------------------------------------------------------------------ helpers

    function _paidDirect(address who) internal view returns (uint256) {
        return yolo.balanceOf(who) - 1_000_000_000e18;
    }
}
