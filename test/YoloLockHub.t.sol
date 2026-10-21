// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./Base.t.sol";

/// @dev `YoloLockHub`: the doer stake as a $YOLO lock.
/// `lock(add, weeks)`: 1..52
/// weeks, the end never moves earlier, the amount only grows, an ended lock may be locked again with a term;
/// `withdraw` only after the end, all of it. Power = amount x term in weeks / 52, fixed at the lock and constant
/// until its end unless the lock is changed: extending sets it to the whole amount x weeks left / 52, adding without
/// a term to power + added x weeks left / 52. Read from the lock as it stood strictly before the moment asked
/// (checkpoints). The CaseDesk fixes the bonus at the submission: b = 4% x min(1, power / R in $YOLO), R = the
/// whole pot at the submission, converted at the DevPrices $YOLO price, plus the $YOLO add-on; any power counts, no threshold. The DisputeDesk pays it if
/// the same lock still runs (`stakePower(who, since)`); the rest of the stakers' 5% splits half to the burn
/// (rounded down), half to the treasury. Base prices $YOLO at $0.0001: a $100 reward = 1M $YOLO.
/// forge-config: default.isolate = false
contract YoloLockHubTest is Base {
    uint256 internal constant WEEK = 7 days;
    uint256 internal constant FULL = 1_000_000e18; // the power of $100 at $0.0001: the whole 4% on a $100 reward

    function _lock(address who, uint256 add, uint256 weeks_) internal {
        vm.prank(who);
        hub.lock(add, weeks_);
    }

    function _amount(address who) internal view returns (uint256 a) {
        (a,,) = hub.locks(who);
    }

    function _end(address who) internal view returns (uint256 e) {
        (, e,) = hub.locks(who);
    }

    function test_ConstructorTakesYolo() public {
        assertEq(address(hub.yolo()), address(yolo));
        assertEq(hub.WEEK(), WEEK);
        assertEq(hub.MAX_WEEKS(), 52);
        vm.expectRevert(YoloLockHub.ZeroAddress.selector);
        new YoloLockHub(address(0));
    }

    // ================================================================== lock / extend / add / withdraw

    /// Lock pulls the $YOLO and sets the end; withdraw only after it.
    function test_LockAndWithdrawAfterTheEnd() public {
        uint256 end = _now() + 52 * WEEK;
        uint256 b0 = yolo.balanceOf(alice);
        vm.expectEmit(address(hub));
        emit YoloLockHub.Locked(alice, 500e18, 500e18, uint64(end), 500e18);
        _lock(alice, 500e18, 52);
        assertEq(_amount(alice), 500e18);
        assertEq(_end(alice), end);
        assertEq(b0 - yolo.balanceOf(alice), 500e18);
        assertEq(yolo.balanceOf(address(hub)), 500e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(YoloLockHub.LockRunning.selector, uint64(end)));
        hub.withdraw();
        vm.warp(end - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(YoloLockHub.LockRunning.selector, uint64(end)));
        hub.withdraw();

        vm.warp(end);
        vm.expectEmit(address(hub));
        emit YoloLockHub.Withdrawn(alice, 500e18);
        vm.prank(alice);
        hub.withdraw();
        assertEq(yolo.balanceOf(alice), b0, "the whole amount back");
        assertEq(_amount(alice), 0);
        assertEq(_end(alice), 0);
        assertEq(hub.power(alice), 0);
        vm.prank(alice);
        vm.expectRevert(YoloLockHub.ZeroAmount.selector);
        hub.withdraw();
    }

    /// The term is 1..52 weeks, a new lock needs a term and an
    /// amount, a call that changes nothing is refused.
    function test_LockTermsAndZero() public {
        vm.prank(alice);
        vm.expectRevert(YoloLockHub.ZeroAmount.selector);
        hub.lock(0, 0);
        vm.prank(alice);
        vm.expectRevert(YoloLockHub.BadTerm.selector);
        hub.lock(100e18, 53);
        vm.prank(alice);
        vm.expectRevert(YoloLockHub.BadTerm.selector);
        hub.lock(100e18, 0); // no lock yet: a term is needed
        vm.prank(alice);
        vm.expectRevert(YoloLockHub.ZeroAmount.selector);
        hub.lock(0, 10); // a term without any amount
        vm.prank(alice);
        vm.expectRevert(YoloLockHub.ZeroAmount.selector);
        hub.withdraw();
        _lock(alice, 1, 1); // the smallest lock: 1 wei for 1 week
        assertEq(_end(alice), _now() + WEEK);
        _lock(bob, 1e18, 52);
        assertEq(_end(bob), _now() + 52 * WEEK);
    }

    /// The end never moves earlier, the amount only grows; adding keeps the end.
    function test_EndOnlyLater_AmountOnlyGrows() public {
        uint256 t0 = _now();
        _lock(alice, 100e18, 10);
        vm.prank(alice);
        vm.expectRevert(YoloLockHub.BadTerm.selector);
        hub.lock(0, 9); // earlier than the end
        _lock(alice, 0, 10); // the same end: allowed, nothing changes
        assertEq(_end(alice), t0 + 10 * WEEK);
        _warp(WEEK);
        _lock(alice, 0, 9); // 9 weeks from now = the same end
        vm.prank(alice);
        vm.expectRevert(YoloLockHub.BadTerm.selector);
        hub.lock(0, 8);
        _lock(alice, 50e18, 0); // add only: the end stays
        assertEq(_amount(alice), 150e18);
        assertEq(_end(alice), t0 + 10 * WEEK);
        _lock(alice, 25e18, 20); // add and extend at once
        assertEq(_amount(alice), 175e18);
        assertEq(_end(alice), _now() + 20 * WEEK);
        assertEq(yolo.balanceOf(address(hub)), 175e18);
    }

    /// A lock that ended can be locked again (needs a
    /// term; adding to it alone is refused) and then is held again until its new end.
    function test_EndedLockLockedAgain() public {
        _lock(alice, 100e18, 1);
        _warp(WEEK);
        assertEq(hub.power(alice), 0, "ended");
        vm.prank(alice);
        vm.expectRevert(YoloLockHub.BadTerm.selector);
        hub.lock(1e18, 0);
        _lock(alice, 0, 4);
        assertEq(_amount(alice), 100e18);
        assertEq(_end(alice), _now() + 4 * WEEK);
        assertEq(hub.power(alice), 7_692_307_692_307_692_307, "100 x 4 / 52");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(YoloLockHub.LockRunning.selector, uint64(_now() + 4 * WEEK)));
        hub.withdraw();
        // withdraw and lock from zero
        _warp(4 * WEEK);
        vm.prank(alice);
        hub.withdraw();
        _lock(alice, 7e18, 2);
        assertEq(_amount(alice), 7e18);
        assertEq(yolo.balanceOf(address(hub)), 7e18);
    }

    // ================================================================== power

    /// the power is fixed at the lock and does not fall: 250k for 13 weeks = 62,500 from the first second
    /// to the last, 0 from the end on. 250k for a year and 1M for a quarter are both 250k.
    function test_Power_FixedAtTheLock_DoesNotFall() public {
        uint256 t0 = _now();
        _lock(alice, 250_000e18, 13);
        assertEq(hub.powerAt(alice, t0 + 1), 62_500e18);
        assertEq(hub.power(alice), 62_500e18);
        assertEq(hub.powerAt(alice, t0 + WEEK), 62_500e18, "a week later: the same");
        assertEq(hub.powerAt(alice, t0 + 13 * WEEK - 1), 62_500e18, "the last second: the same");
        assertEq(hub.powerAt(alice, t0 + 13 * WEEK), 0, "the end");
        _warp(12 * WEEK);
        assertEq(hub.power(alice), 62_500e18);
        _lock(bob, 250_000e18, 52);
        _lock(dave, 1_000_000e18, 13);
        assertEq(hub.power(bob), 250_000e18);
        assertEq(hub.power(dave), 250_000e18);
    }

    /// Adding and extending recompute the power: an added token counts with the weeks it is locked from now on,
    /// an extension sets the whole amount with the weeks left. So a big amount added for the last week of a long
    /// lock does not get a year's power.
    function test_Power_AddAndExtend() public {
        _lock(alice, 520e18, 52); // 520
        _warp(26 * WEEK); // 26 weeks left
        _lock(alice, 520e18, 0); // 520 + 520 x 26 / 52 = 780 (the whole 1,040 x 26 / 52 = 520 is less)
        assertEq(hub.power(alice), 780e18);
        _lock(alice, 0, 52); // extended to a year from now: 1,040 x 52 / 52
        assertEq(hub.power(alice), 1_040e18);
        _lock(alice, 0, 52); // the same end again: nothing changes
        assertEq(hub.power(alice), 1_040e18);
        // extending a short lock: 52 for 4 weeks = 4, then to 52 weeks = 52
        _lock(bob, 52e18, 4);
        assertEq(hub.power(bob), 4e18);
        _warp(1);
        _lock(bob, 0, 52);
        assertEq(hub.power(bob), 52e18);
        // 1 wei for a year, then 1M added in the last week: 1M / 52 more, not 1M
        _lock(dave, 1, 52);
        _warp(51 * WEEK + 1);
        _lock(dave, 1_000_000e18, 0);
        assertEq(hub.power(dave), 1 + uint256(1_000_000e18) / 52);
        // a lock that ended starts afresh when set again (the old power is gone)
        _warp(WEEK);
        assertEq(hub.power(dave), 0);
        _lock(dave, 0, 1);
        assertEq(hub.power(dave), uint256(1_000_000e18 + 1) / 52);
    }

    /// An extension sets the power from the weeks actually left: a 52-week lock served to its last day and then
    /// rolled one week at a time carries one week's power (amount / 52), not the full amount.
    function test_Power_RollingOneWeekExtensionDropsToOneWeek() public {
        uint256 t0 = _now();
        _lock(alice, 1_000e18, 52);
        assertEq(hub.power(alice), 1_000e18);
        _warp(52 * WEEK - 1 days);
        _lock(alice, 0, 1);
        assertEq(_end(alice), _now() + WEEK);
        assertEq(hub.power(alice), uint256(1_000e18) / 52, "one week left: 1/52");
        for (uint256 i; i < 3; ++i) {
            _warp(WEEK - 1 days);
            _lock(alice, 0, 1);
            assertEq(hub.power(alice), uint256(1_000e18) / 52, "rolled again: still 1/52");
        }
        assertEq(hub.powerAt(alice, t0 + 1), 1_000e18, "the past is kept");
        // a shorter extension inside the year lowers the power as well: 26 weeks in, set to 26 weeks = 520
        _lock(bob, 1_040e18, 52);
        _warp(26 * WEEK);
        _lock(bob, 0, 26);
        assertEq(hub.power(bob), 520e18);
    }

    /// The checkpoint: the power at `t` is read from the lock as it stood strictly before `t`. A lock made in the
    /// block of a submission does not count for it; what is added later does not change the power at earlier times.
    function test_PowerAt_ReadsTheLockStrictlyBefore() public {
        uint256 t0 = _now();
        assertEq(hub.powerAt(alice, t0), 0, "nothing locked");
        _lock(alice, 250_000e18, 52);
        assertEq(hub.powerAt(alice, t0), 0, "locked in this block: not before it");
        assertEq(hub.powerAt(alice, t0 + 1), 250_000e18);
        _warp(10);
        _lock(alice, 250_000e18, 0); // added at t0 + 10, 52 weeks left (rounded up)
        assertEq(hub.powerAt(alice, t0 + 5), 250_000e18, "history kept");
        assertEq(hub.powerAt(alice, t0 + 10), 250_000e18, "the add counts only after its block");
        assertEq(hub.powerAt(alice, t0 + 11), 500_000e18);
        // two changes in one block: the last state of the block counts
        _lock(bob, 100e18, 2);
        _lock(bob, 100e18, 0);
        assertEq(hub.powerAt(bob, _now() + 1), 7_692_307_692_307_692_306, "100 x 2 / 52 twice, each rounded down");
        // an extension counts only after its block
        _lock(dave, 52e18, 26);
        _warp(WEEK);
        uint256 t1 = _now();
        _lock(dave, 0, 52);
        assertEq(hub.powerAt(dave, t1), 26e18);
        assertEq(hub.powerAt(dave, t1 + 1), 52e18);
    }

    /// `stakePower(who, since)`: the power at `since` while the same lock runs now; 0 once it ended, 0 for a moment
    /// before it, 0 after a withdrawal even if locked again (another epoch).
    function test_StakePower_RunningLockOnly() public {
        uint256 t0 = _now();
        assertEq(hub.stakePower(alice, uint64(t0)), 0, "nothing locked");
        _lock(alice, 100_000e18, 13);
        _lock(dave, 2_000_000e18, 52);
        _warp(1);
        uint64 since = uint64(_now());
        assertEq(hub.stakePower(alice, since), 25_000e18);
        assertEq(hub.stakePower(dave, since), 2_000_000e18, "no cap here: the CaseDesk caps the share");
        assertEq(hub.stakePower(dave, uint64(t0)), 0, "a moment before the lock");
        vm.warp(t0 + 13 * WEEK);
        assertEq(hub.powerAt(alice, since), 25_000e18);
        assertEq(hub.stakePower(alice, since), 0, "the lock ended");
        assertEq(hub.stakePower(dave, since), 2_000_000e18, "still running");
        vm.prank(alice);
        hub.withdraw();
        _lock(alice, 100_000e18, 52);
        assertEq(hub.stakePower(alice, since), 0, "withdrawn and locked again: another lock");
    }

    // ================================================================== at the payout (vault)

    function _acceptQuietly(uint256 t) internal returns (uint256 s) {
        s = _submit(doer, t);
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Completed));
    }

    function _usdcTask() internal returns (uint256 t) {
        _warp(1);
        t = _create(author, address(usdc), 100e6);
    }

    /// Example 1: power worth the reward ($100 = 1M $YOLO for a year): doer $94, burner $0.50 + the NFT $5
    /// nobody earned, treasury $0.50.
    function test_Vault_PowerEqualsReward_Bonus4() public {
        _lock(doer, FULL, 52);
        uint256 s = _acceptQuietly(_usdcTask());
        assertEq(_sub(s).stakeBps, 400);
        assertEq(vault.getSettlement(s).stakeBps, 400);
        assertEq(vault.credits(address(usdc), doer), 94e6 + 3e6, "90%+stake plus his rew bond back");
        assertEq(usdc.balanceOf(buybackWallet), 0.5e6 + 5e6);
        assertEq(usdc.balanceOf(address(burner)), 0, "autosent, nothing waits in the burner");
        assertEq(vault.treasuryPot(address(usdc)), 0.5e6);
        _claimEverythingAndCheck();
    }

    /// Example 2: power worth $50 (1M for half a year = 500k): bonus 2%, doer $92, burner $1.50 + $5,
    /// treasury $1.50.
    function test_Vault_PowerHalfTheReward_Bonus2() public {
        _lock(doer, FULL, 26);
        uint256 s = _acceptQuietly(_usdcTask());
        assertEq(vault.getSettlement(s).stakeBps, 200);
        assertEq(vault.credits(address(usdc), doer), 92e6 + 3e6, "90%+stake plus his rew bond back");
        assertEq(usdc.balanceOf(buybackWallet), 1.5e6 + 5e6);
        assertEq(usdc.balanceOf(address(burner)), 0, "autosent, nothing waits in the burner");
        assertEq(vault.treasuryPot(address(usdc)), 1.5e6);
        _claimEverythingAndCheck();
    }

    // Power worth 5% of the reward (bonus 0.2%) and a tiny stake in whole bps: test/ContractRules.t.sol
    // (a separate contract: with them here solc 0.8.28 via-ir fails with "Tag too large for reserved space").

    /// No fixed threshold: power above the reward is capped at 4% (2M on a $100 task), and the same lock
    /// that is the whole 4% on $100 is 0.4% on $1,000. 250k for 13 weeks (62,500 = $6.25) is 0.25% on $100.
    function test_Vault_RelativeToTheReward() public {
        _lock(doer, 2 * FULL, 52);
        uint256 s1 = _acceptQuietly(_usdcTask());
        assertEq(vault.getSettlement(s1).stakeBps, 400, "capped at 4%");
        _warp(1);
        uint256 t2 = _create(author, address(usdc), 1_000e6);
        _warp(1);
        uint256 s2 = _acceptQuietly(t2);
        assertEq(vault.getSettlement(s2).stakeBps, 80, "2M on $1,000 (10M YOLO): 20% of it, 0.8%");
        assertEq(
            vault.credits(address(usdc), doer),
            94e6 + 3e6 + 908e6 + 30e6,
            "both tasks' reward share plus their rew bonds"
        );
        _lock(doer2, 250_000e18, 13);
        uint256 t3 = _usdcTask();
        uint256 s3 = _submit(doer2, t3);
        _warp(24 hours);
        vault.poke(t3);
        assertEq(vault.getSettlement(s3).stakeBps, 25, "62,500 of 1M: 0.25%, no threshold");
        _claimEverythingAndCheck();
    }

    /// The conversion uses the $YOLO price DevPrices returns (`yoloValue`): at half the price,
    /// $100 = 2M $YOLO, so 1M of power is only half of it: 2%, doer $92.
    function test_Vault_LowestPriceOfTheWindow() public {
        oracle.setYolo(address(yolo), 0.00005e18);
        _lock(doer, FULL, 52);
        uint256 s = _acceptQuietly(_usdcTask());
        assertEq(vault.getSettlement(s).stakeBps, 200);
        assertEq(vault.credits(address(usdc), doer), 92e6 + 3e6, "90%+stake plus his rew bond back");
    }

    /// No $YOLO price: no bonus (the USDC task is still submitted and paid as without a stake).
    function test_Vault_NoYoloPrice_NoBonus() public {
        _lock(doer, FULL, 52);
        uint256 t = _usdcTask();
        oracle.set(address(yolo), 0, 18); // no $YOLO price
        uint256 s = _acceptQuietly(t);
        assertEq(vault.getSettlement(s).stakeBps, 0);
        assertEq(vault.credits(address(usdc), doer), 90e6 + 3e6, "90% plus his rew bond back");
        assertEq(vault.treasuryPot(address(usdc)), 10e6);
    }

    /// What was added after the submission does not count for it, what stood before does: 500k for a year (+500k and
    /// an extension during the review) = 2%, doer $92.
    function test_Vault_AddedAfterTheSubmission_NotCounted() public {
        _lock(doer, FULL / 2, 52);
        uint256 t = _usdcTask();
        uint256 s = _submit(doer, t);
        _lock(doer, FULL / 2, 0); // in the block of the submission: already after it
        _warp(1 hours);
        _lock(doer, 0, 52);
        assertEq(hub.power(doer), FULL);
        _warp(23 hours);
        vault.poke(t);
        assertEq(vault.getSettlement(s).stakeBps, 200, "what stood before the submission");
        assertEq(vault.credits(address(usdc), doer), 92e6 + 3e6, "90%+stake plus his rew bond back");
        _claimEverythingAndCheck();
    }

    /// Locked in the block of the submission or after it: no bonus.
    function test_Vault_LockedInTheSubmissionBlockOrLater_NoBonus() public {
        uint256 t1 = _create(author, address(usdc), 100e6);
        _lock(doer, FULL, 52);
        uint256 s1 = _submit(doer, t1); // the same block
        uint256 t2 = _create(author, address(usdc), 100e6);
        uint256 s2 = _submit(doer2, t2);
        _warp(1);
        _lock(doer2, FULL, 52); // after
        _warp(24 hours);
        vault.poke(t1);
        vault.poke(t2);
        assertEq(vault.getSettlement(s1).stakeBps, 0, "locked in the submission's block");
        assertEq(vault.getSettlement(s2).stakeBps, 0, "locked after the submission");
        assertEq(vault.credits(address(usdc), doer), 90e6 + 3e6, "90% plus his rew bond back");
        assertEq(vault.credits(address(usdc), doer2), 90e6 + 3e6, "90% plus his rew bond back");
        assertEq(vault.treasuryPot(address(usdc)), 20e6);
        _claimEverythingAndCheck();
    }

    /// A lock that ends before the payout gives no bonus even if the submission fixed one (10M for a week, submitted
    /// a day before its end); the same amount locked again before the next submission gives it.
    function test_Vault_LockEndedBeforePayout_NoBonus_RelockedBonus() public {
        _lock(doer, 10 * FULL, 1);
        _warp(6 days);
        uint256 t1 = _create(author, address(usdc), 100e6);
        uint256 s1 = _submit(doer, t1);
        assertEq(_sub(s1).stakeBps, 76, "10M x 1 / 52 = 192,307 of 1M: 4% x 0.1923 = 0.76% (rounded down)");
        _warp(24 hours); // the lock ends at this second: not running at the payout
        vault.poke(t1);
        assertEq(vault.getSettlement(s1).stakeBps, 0, "ended before the payout");
        assertEq(vault.credits(address(usdc), doer), 90e6 + 3e6, "90% plus his rew bond back");

        _lock(doer, 0, 52); // the same 10M locked again for a year: the whole 4%
        uint256 s2 = _acceptQuietly(_usdcTask());
        assertEq(vault.getSettlement(s2).stakeBps, 400);
        assertEq(
            vault.credits(address(usdc), doer), 90e6 + 3e6 + 94e6 + 3e6, "both tasks' 90%(+stake) plus their rew bonds"
        );
        _claimEverythingAndCheck();
    }

    /// A $YOLO reward is compared directly: 1M $YOLO reward, 1M of power: doer 94%; the NFT 5%, the burn half and the
    /// treasury half (its $YOLO burns too) go to 0x...dEaD: 6% instead of 10%.
    function test_Vault_YoloReward_Direct() public {
        _lock(doer, FULL, 52);
        _warp(1);
        uint256 t = _create(author, address(yolo), 1_000_000e18); // $100
        uint256 dead0 = yolo.balanceOf(address(burner));
        uint256 s = _acceptQuietly(t);
        assertEq(vault.getSettlement(s).stakeBps, 400);
        assertEq(vault.credits(address(yolo), doer), 940_000e18 + 30_000e18, "90%+stake plus his 3% rew bond back");
        assertEq(yolo.balanceOf(address(burner)) - dead0, 60_000e18);
        assertEq(vault.treasuryPot(address(yolo)), 0);
        _claimEverythingAndCheck();
    }

    // The $YOLO add-on and others' top-ups are in the power base: test/ContractRules.t.sol.

    /// The power is fixed at the submission, also for a queued one: locked 1M for half a year (500k, 2%), submitted
    /// into the queue, 1M more added while queued: still 2% when it is activated and accepted.
    function test_Rule_QueuedDoer_PowerAtTheSubmission() public {
        _lock(doer, FULL, 26);
        uint256 t = _usdcTask();
        uint256 s1 = _submit(doer2, t); // active
        uint256 s2 = _submit(doer, t); // queued
        assertEq(uint8(_phase(s2)), uint8(Phase.Queued));
        assertEq(_sub(s2).stakeBps, 200);
        _warp(1);
        _lock(doer, FULL, 0); // while queued
        _dispute(dave, s1);
        _vote(s1, 1, 2, 120, 20); // reject
        _endVote(s1);
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s1).outcome), uint8(Outcome.Rejected));
        assertEq(uint8(_phase(s2)), uint8(Phase.Review), "activated now");
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s2).outcome), uint8(Outcome.Accepted));
        assertEq(vault.getSettlement(s2).stakeBps, 200, "fixed at the submission");
        assertEq(_sub(s2).bond.rew, 3e6, "no escalation: same bond, queued or not");
        assertEq(vault.credits(address(usdc), doer), 92e6 + 3e6, "90%+stake plus his rew bond back");
    }

    // ================================================================== balance invariant

    function testFuzz_LockThenWithdrawReturnsExactAmount(uint256 amount, uint256 weeks_) public {
        amount = bound(amount, 1, 1_000_000_000e18);
        weeks_ = bound(weeks_, 1, 52);
        uint256 b0 = yolo.balanceOf(alice);
        _lock(alice, amount, weeks_);
        _warp(weeks_ * WEEK - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(YoloLockHub.LockRunning.selector, uint64(_now() + 1)));
        hub.withdraw();
        _warp(1);
        vm.prank(alice);
        hub.withdraw();
        assertEq(yolo.balanceOf(alice), b0, "every wei locked comes back, none created, none stuck");
        assertEq(yolo.balanceOf(address(hub)), 0, "nothing left behind");
    }

    /// The power stays amount x weeks / 52 through the whole term, never exceeds the amount, and is 0 from the end.
    function testFuzz_PowerConstantThroughTheTerm(uint256 amount, uint256 weeks_, uint256 dt) public {
        amount = bound(amount, 1, 1_000_000_000e18);
        weeks_ = bound(weeks_, 1, 52);
        uint256 t0 = _now();
        _lock(alice, amount, weeks_);
        uint256 end = t0 + weeks_ * WEEK;
        dt = bound(dt, 1, weeks_ * WEEK + 1 weeks);
        uint256 p = hub.powerAt(alice, t0 + dt);
        assertLe(p, amount);
        if (t0 + dt >= end) assertEq(p, 0);
        else assertEq(p, amount * weeks_ / 52);
    }
}
