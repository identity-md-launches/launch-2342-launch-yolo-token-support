// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./Base.t.sol";
import {ParamsBounds} from "../src/VaultParams.sol";

/// @dev Tasks, contributions, withdrawals, deadlines, the queue and the flat bond, parameter versions.
/// forge-config: default.isolate = false
contract TasksTest is Base {
    // ================================================================== creation

    function test_CreateTask_AllCurrencies() public {
        uint256 t1 = _create(author, ETH, 0.01 ether); // $25
        uint256 t2 = _create(author, address(usdc), 50e6);
        uint256 t3 = _create(author, address(imd), 5e18);
        assertEq(vault.getTask(t1).pot, 0.01 ether);
        assertEq(vault.getTask(t2).pot, 50e6);
        assertEq(vault.getTask(t3).pot, 5e18);
        // no author fee: the treasury pot gets nothing at creation
        assertEq(vault.treasuryPot(ETH), 0);
        assertEq(vault.liabilities(ETH), 0.01 ether);
        assertEq(vault.liabilities(address(usdc)), 50e6);
        assertEq(vault.liabilities(address(imd)), 5e18);
        _assertSolvent();
        _claimEverythingAndCheck();
    }

    function test_CreateTask_Reverts() public {
        uint64 dl = uint64(_now() + 1 days);
        vm.startPrank(author);
        // minReward is a dev parameter in the reward's own currency, with no conversion to dollars
        vm.expectRevert(RewardTooSmall.selector);
        vault.createTask(address(usdc), 5e6 - 1, dl, "Title", rulesOf("ipfs://c"), 0, 0, "", _noSwap());
        vm.expectRevert(RewardTooSmall.selector);
        vault.createTask(address(imd), 1e18 - 1, dl, "Title", rulesOf("ipfs://c"), 0, 0, "", _noSwap());
        vm.expectRevert(RewardTooSmall.selector);
        vault.createTask(address(yolo), 1_000e18 - 1, dl, "Title", rulesOf("ipfs://c"), 0, 0, "", _noSwap());
        vm.expectRevert(BadCurrency.selector);
        vault.createTask(address(nft), 10e18, dl, "Title", rulesOf("ipfs://c"), 0, 0, "", _noSwap());
        // only a task without a deadline is refused
        vm.expectRevert(BadDeadline.selector);
        vault.createTask(address(usdc), 10e6, 0, "Title", rulesOf("ipfs://c"), 0, 0, "", _noSwap());
        vm.expectRevert(NotEnoughEth.selector); // an ETH reward must still be paid in full
        vault.createTask{value: 0.01 ether - 1}(ETH, 0.01 ether, dl, "Title", rulesOf("ipfs://c"), 0, 0, "", _noSwap());
        vm.expectRevert(BadText.selector);
        vault.createTask{value: 0.001 ether}(
            address(usdc), 10e6, dl, "Title", rulesOf('ipfs://"x'), 0, 0, "", _noSwap()
        );
        vm.expectRevert(BadText.selector);
        vault.createTask{value: 0.001 ether}(address(usdc), 10e6, dl, "Title", rulesOf(""), 0, 0, "", _noSwap());
        vm.expectRevert(BadDeadline.selector);
        vault.createTask{value: 0.001 ether}(
            address(usdc), 10e6, uint64(_now()), "Title", rulesOf("c"), 0, 0, "", _noSwap()
        );
        vm.stopPrank();
        // no cap on the reward: a large reward is created fine
        vm.prank(author);
        uint256 big = vault.createTask(address(usdc), 900_000e6, dl, "Title", rulesOf("c"), 0, 0, "", _noSwap());
        assertEq(vault.getTask(big).pot, 900_000e6);
        // no price needed: a task is created fine with no price set for its currency
        oracle.set(address(yolo), 0, 18);
        vm.prank(author);
        uint256 t = vault.createTask(address(yolo), 1_000_000e18, dl, "Title", rulesOf("c"), 0, 0, "", _noSwap());
        assertEq(vault.getTask(t).pot, 1_000_000e18);
    }

    /// @notice No creation fee: a task is created with msg.value 0, the treasury gets nothing.
    function test_CreateTask_NoAuthorFee() public {
        vm.prank(author);
        uint256 t =
            vault.createTask(address(usdc), 5e6, uint64(_now() + 1 days), "Title", rulesOf("c"), 0, 0, "", _noSwap());
        trackedTasks.push(t);
        assertEq(vault.treasuryPot(ETH), 0);
        assertEq(vault.liabilities(ETH), 0);
        Task memory tk = vault.getTask(t);
        assertEq(tk.pot, 5e6);
        assertEq(tk.createdAt, _now());
        _claimEverythingAndCheck();
    }

    /// @notice No caps: neither one task's reward (pot + every top-up) nor the sum of all open tasks
    ///         is capped.
    function test_NoCap_RewardTopUpsAndOpenTotal() public {
        uint256 t = _create(author, address(usdc), 900e6);
        _topUp(alice, t, 100e6);
        vm.prank(bob);
        vault.topUp(t, 900_000e6, _noSwap()); // no cap on a top-up
        assertEq(vault.getTask(t).pot, 901_000e6);
        // 19 more tasks of $50,000 each, with no open-total limit
        for (uint256 i; i < 19; ++i) {
            _createWithDeadline(doer, address(usdc), 50_000e6, uint64(_now() + 2 days));
        }
        _create(doer2, address(usdc), 5e6); // still no OpenLimit revert
        _claimEverythingAndCheck();
    }

    function test_PauseStopsOnlyNewTasks() public {
        uint256 t = _create(author, address(usdc), 50e6);
        vm.prank(multisig);
        registry.setNewTasksPaused(true);
        vm.expectRevert(Paused.selector);
        vm.prank(author);
        vault.createTask{value: 0.001 ether}(address(usdc), 50e6, 0, "Title", rulesOf("c"), 0, 0, "", _noSwap());
        // existing task still works end to end
        uint256 s = _submit(doer, t);
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        vm.expectRevert();
        vm.prank(author);
        registry.setNewTasksPaused(false); // not the owner
    }

    function test_ExcessEthRefunded() public {
        uint256 before = author.balance;
        vm.prank(author);
        vault.createTask{value: 1 ether}(
            address(usdc), 50e6, uint64(_now() + 1 days), "Title", rulesOf("c"), 0, 0, "", _noSwap()
        );
        assertEq(before - author.balance, 0, "no author fee: every wei sent back");
    }

    // ================================================================== no dispute

    function test_NoDispute_AuthorOnly_24hWindow_USDC() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 imdBefore = imd.balanceOf(doer);
        uint256 s = _submit(doer, t);
        assertEq(_sub(s).bond.imd, _fixedBond());
        assertEq(_sub(s).bond.rew, 3e6); // 3% of $100
        assertEq(_sub(s).windowEnd, _now() + 24 hours); // 24h for every task, even author-only money

        _warp(24 hours - 1);
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.Review));
        _warp(1);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Completed));

        // R - 10% to the doer; without a dispute the whole 10% goes to the treasury (in USDC)
        assertEq(vault.credits(address(usdc), doer), 90e6 + 3e6); // reward share plus his rew bond back
        assertEq(vault.treasuryPot(address(usdc)), 10e6);
        assertEq(vault.credits(address(imd), doer), _fixedBond()); // fixed bond back
        vm.startPrank(doer);
        vault.withdraw(address(usdc));
        vault.withdraw(address(imd));
        vm.stopPrank();
        assertEq(imd.balanceOf(doer), imdBefore);
        _claimEverythingAndCheck();
    }

    function test_NoDispute_ForeignMoney_24hWindow_ETH() public {
        uint256 t = _create(author, ETH, 0.02 ether); // $50
        _topUp(alice, t, 0.02 ether);
        uint256 s = _submit(doer, t);
        assertEq(_sub(s).windowEnd, _now() + 24 hours);
        assertEq(_sub(s).reward, 0.04 ether);
        _warp(12 hours);
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.Review));
        _warp(12 hours);
        vault.poke(t);
        // their bond is 3% of the author's 0.02 ETH only (alice's top-up is no part of it)
        assertEq(vault.credits(ETH, doer), 0.036 ether + 0.0006 ether, "90% plus his 3% rew bond back");
        assertEq(vault.treasuryPot(ETH), 0.004 ether); // 10%, no author fee
        _claimEverythingAndCheck();
    }

    function test_NoDispute_IMDReward() public {
        uint256 t = _create(author, address(imd), 20e18); // $160
        uint256 s = _submit(doer, t);
        assertEq(_sub(s).bond.imd, _fixedBond());
        assertEq(_sub(s).bond.rew, 0.6e18, "3% of 20 IMD");
        _warp(24 hours);
        vault.poke(t);
        assertEq(vault.credits(address(imd), doer), 18e18 + 0.6e18 + _fixedBond());
        assertEq(vault.treasuryPot(address(imd)), 2e18);
        _claimEverythingAndCheck();
    }

    /// @notice Accepted without a dispute, $100: no stake -> doer $90, treasury $10; doer lock
    ///         worth the reward (1M YOLO = $100 for a year) -> doer $94, burn $0.50 + the NFT $5 nobody
    ///         earned (USDC: to the buyback wallet), treasury $0.50. The lock counts only as it stood before the
    ///         submission and only if it still runs at the payout; a doer who put money into the task gets it as usual.
    function test_NoDispute_StakeBonusAndBurn() public {
        vm.prank(doer);
        hub.lock(1_000_000e18, 52);
        vm.prank(doer3);
        hub.lock(1_000_000e18, 52);
        _warp(1);
        uint256 t1 = _create(author, address(usdc), 100e6);
        uint256 t2 = _create(author, address(usdc), 100e6);
        uint256 t3 = _create(author, address(usdc), 100e6);
        uint256 s1 = _submit(doer, t1); // locked before the submission: bonus
        uint256 s2 = _submit(doer2, t2);
        _warp(1);
        vm.prank(doer2);
        hub.lock(1_000_000e18, 52); // locked after his submission: no bonus for it
        uint256 s3 = _submit(doer3, t3);
        _topUp(doer3, t3, 10e6); // locked and a contributor of their task: bonus as usual; the
        // top-up during the check joins their reward at once: R = 110
        _warp(24 hours);
        vault.poke(t1);
        vault.poke(t2);
        vault.poke(t3);

        assertEq(vault.credits(address(usdc), doer), 94e6 + 3e6, "94% plus his rew bond back");
        assertEq(vault.getSettlement(s1).stakeBps, 400);
        assertEq(
            usdc.balanceOf(buybackWallet),
            5.5e6 + 6.05e6,
            "per staked payout: half of the 1% left + the unearned NFT 5%"
        );
        assertEq(usdc.balanceOf(address(burner)), 0, "autosent, nothing waits in the burner");
        assertEq(vault.credits(address(usdc), doer2), 90e6 + 3e6, "90% plus his rew bond back");
        assertEq(vault.getSettlement(s2).stakeBps, 0);
        assertEq(
            vault.credits(address(usdc), doer3),
            103.4e6 + 3e6,
            "contributor doer: 94% of 100 + 10, plus his rew bond back"
        );
        assertEq(vault.getSettlement(s3).stakeBps, 400);
        assertEq(
            vault.treasuryPot(address(usdc)),
            0.5e6 + 10e6 + 0.55e6,
            "half the 1% left of each staked payout, 10 from doer2"
        );
        // doer3's top-up went into his payout: nothing to take back
        vm.prank(doer3);
        vm.expectRevert(NothingToClaim.selector);
        vault.withdrawContribution(t3);
        _claimEverythingAndCheck();
    }

    /// @notice A $YOLO reward: the treasury's $YOLO is burned (0x...dEaD), never pooled; with the
    ///         doer lock at full power the doer takes 4% and 6% burns instead of 10%.
    function test_NoDispute_YoloReward_TreasuryShareBurned() public {
        uint256 t1 = _create(author, address(yolo), 1_000_000e18); // $100
        uint256 t2 = _create(author, address(yolo), 1_000_000e18);
        _submit(doer, t1);
        vm.prank(doer2);
        hub.lock(1_000_000e18, 52);
        _warp(1); // the lock counts for submissions in later blocks
        _submit(doer2, t2);
        uint256 dead0 = yolo.balanceOf(address(burner));
        _warp(24 hours);
        vault.poke(t1);
        assertEq(vault.credits(address(yolo), doer), 900_000e18 + 30_000e18, "90% plus his rew bond back");
        assertEq(yolo.balanceOf(address(burner)) - dead0, 100_000e18);
        assertEq(vault.treasuryPot(address(yolo)), 0);
        vault.poke(t2);
        assertEq(vault.credits(address(yolo), doer2), 940_000e18 + 30_000e18, "94% plus his rew bond back");
        assertEq(yolo.balanceOf(address(burner)) - dead0, 160_000e18);
        assertEq(vault.treasuryPot(address(yolo)), 0);
        _claimEverythingAndCheck();
    }

    // ================================================================== contributions

    /// @notice A USDC top-up made while the proof is being checked joins the reward at once
    ///         (like the $YOLO add-on); the submission is accepted, so the doer is paid it with the rest; the doer's
    ///         bond stays 3% of the author's own reward; the contributor gets nothing back.
    function test_TopUpDuringSubmission_PaidToDoerOnAcceptance() public {
        uint256 t = _create(author, address(usdc), 50e6);
        uint256 s = _submit(doer, t);
        assertEq(_sub(s).bond.rew, 1.5e6, "bond: 3% of the author's 50");
        vm.expectEmit(true, true, false, true, address(vault));
        emit ToppedUp(t, alice, 500e6, true);
        _topUp(alice, t, 500e6);
        assertEq(vault.getTask(t).pending, 0);
        assertEq(vault.getTask(t).pot, 550e6);
        assertEq(vault.potOf(t), 550e6);
        assertEq(_sub(s).bond.rew, 1.5e6, "the bond of the running submission does not change");
        _warp(24 hours);
        vault.poke(t);
        assertEq(_sub(s).reward, 550e6, "reward reads what was paid");
        assertEq(vault.credits(address(usdc), doer), 495e6 + 1.5e6, "90% of 50 + 500, plus his rew bond back");
        assertEq(vault.getTask(t).pot, 0);
        vm.prank(alice);
        vm.expectRevert(NothingToClaim.selector);
        vault.withdrawContribution(t);
        vm.prank(author);
        vm.expectRevert(NothingToClaim.selector);
        vault.withdrawContribution(t);
        // a decided task takes no more top-ups
        vm.prank(alice);
        vm.expectRevert(TaskNotOpen.selector);
        vault.topUp(t, 1e6, _noSwap());
        _claimEverythingAndCheck();
    }

    function test_TopUpDuringSubmission_StaysInRewardAfterRejection() public {
        uint256 t = _create(author, address(usdc), 50e6);
        uint256 s = _submit(doer, t);
        _topUp(alice, t, 100e6);
        assertEq(vault.getTask(t).pot, 150e6);
        _rejectByVote(s);
        Task memory tk = vault.getTask(t);
        assertEq(tk.pot, 150e6);
        assertEq(tk.pending, 0);
        assertEq(vault.getContribution(t, alice).active, 100e6);
        assertEq(vault.getContribution(t, alice).pending, 0);
        uint256 s2 = _submit(doer2, t);
        assertEq(_sub(s2).reward, 150e6);
        // alice's share is at stake: locked like the rest of the reward until the deadline
        vm.prank(alice);
        vm.expectRevert(TaskNotOpen.selector);
        vault.withdrawContribution(t);
        _claimEverythingAndCheck();
    }

    /// @notice The reward is locked until the deadline: nothing leaves an Open task, idle or busy, before or
    ///         after its deadline; after expiry everyone takes back exactly what they put in.
    function test_WithdrawRules() public {
        uint256 t = _createWithDeadline(author, address(usdc), 50e6, uint64(_now() + 10 days));
        _topUp(alice, t, 30e6);
        // idle task: locked
        vm.prank(alice);
        vm.expectRevert(TaskNotOpen.selector);
        vault.withdrawContribution(t);
        vm.prank(author);
        vm.expectRevert(TaskNotOpen.selector);
        vault.withdrawContribution(t);
        uint256 s = _submit(doer, t);
        // active submission: shares and a top-up made during the check alike are locked; the top-up is in the pot
        _topUp(bob, t, 10e6);
        assertEq(vault.getTask(t).pot, 90e6);
        vm.prank(bob);
        vm.expectRevert(TaskNotOpen.selector);
        vault.withdrawContribution(t);
        vm.prank(alice);
        vm.expectRevert(TaskNotOpen.selector);
        vault.withdrawContribution(t);
        // the submission ends without acceptance: still locked, the top-up stays in the pot
        _rejectByVote(s);
        assertEq(vault.getTask(t).pot, 90e6);
        vm.prank(author);
        vm.expectRevert(TaskNotOpen.selector);
        vault.withdrawContribution(t);
        // a submission running over the deadline keeps the task open (and the money locked)
        vm.warp(vault.getTask(t).deadline - 1 hours);
        uint256 s2 = _submit(doer2, t);
        _warp(2 hours);
        vault.poke(t);
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Open));
        vm.prank(alice);
        vm.expectRevert(TaskNotOpen.selector);
        vault.withdrawContribution(t);
        vm.prank(alice);
        vm.expectRevert(DeadlinePassed.selector); // and nobody adds to it
        vault.topUp(t, 1e6, _noSwap());
        _rejectByVote(s2);
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Expired));
        // expired: every share back, in full
        uint256 a0 = usdc.balanceOf(author);
        uint256 al0 = usdc.balanceOf(alice);
        uint256 b0 = usdc.balanceOf(bob);
        vm.prank(author);
        vault.withdrawContribution(t);
        vm.prank(alice);
        vault.withdrawContribution(t);
        vm.prank(bob);
        vault.withdrawContribution(t);
        assertEq(usdc.balanceOf(author) - a0, 50e6);
        assertEq(usdc.balanceOf(alice) - al0, 30e6);
        assertEq(usdc.balanceOf(bob) - b0, 10e6);
        assertEq(vault.getTask(t).pot, 0);
        vm.prank(alice);
        vm.expectRevert(NothingToClaim.selector);
        vault.withdrawContribution(t);
        _claimEverythingAndCheck();
    }

    /// @notice The same place checks that a top-up made just before the deadline is locked like the rest and
    ///         comes back in full after expiry, and that an expired task takes no more money.
    function test_TopUpRightBeforeDeadline_LockedThenReturned() public {
        uint256 t = _createWithDeadline(author, address(usdc), 50e6, uint64(_now() + 2 days));
        _topUp(alice, t, 30e6);
        _warp(2 days - 1);
        _topUp(alice, t, 900e6);
        vm.prank(alice);
        vm.expectRevert(TaskNotOpen.selector);
        vault.withdrawContribution(t);
        _warp(1);
        vm.prank(alice);
        vm.expectRevert(TaskNotOpen.selector); // the lazy timer expires the task first
        vault.topUp(t, 1e6, _noSwap());
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.withdrawContribution(t);
        assertEq(usdc.balanceOf(alice) - before, 930e6);
        assertEq(vault.getTask(t).pot, 50e6);
        _claimEverythingAndCheck();
    }

    /// @notice The author cannot pull the reward from under a doer: the withdrawal reverts and the submission
    ///         goes through.
    function test_AuthorCannotWithdrawOpenTask_SubmitWorks() public {
        uint256 t = _create(author, address(usdc), 50e6);
        vm.prank(author);
        vm.expectRevert(TaskNotOpen.selector);
        vault.withdrawContribution(t);
        uint256 s = _submit(doer, t);
        assertEq(_sub(s).reward, 50e6);
        _claimEverythingAndCheck();
    }

    // ================================================================== deadline

    function test_DeadlineRefund() public {
        uint256 t = _createWithDeadline(author, ETH, 0.01 ether, uint64(_now() + 3 days));
        _topUp(alice, t, 0.02 ether);
        _warp(3 days);
        vm.prank(doer);
        vm.expectRevert(TaskNotOpen.selector); // the lazy timer expires the task first
        vault.submit(t, "https://x.com/doer/status/1", _noEvidence(), 0, type(uint256).max, _noSwap());
        uint256 a0 = alice.balance;
        vm.prank(alice);
        vault.withdrawContribution(t);
        assertEq(alice.balance - a0, 0.02 ether);
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Expired));
        vm.prank(alice);
        vm.expectRevert(TaskNotOpen.selector);
        vault.topUp{value: 1}(t, 1, _noSwap());
        _claimEverythingAndCheck();
    }

    function test_DeadlineDuringSubmission_SubmissionStillRuns() public {
        uint256 t = _createWithDeadline(author, address(usdc), 50e6, uint64(_now() + 1 hours));
        uint256 s = _submit(doer, t);
        uint256 s2 = _submit(doer2, t); // queued before the deadline
        _warp(2 hours);
        vault.poke(t);
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Open));
        _rejectByVote(s);
        assertEq(uint8(_phase(s2)), uint8(Phase.Review)); // queued one is still judged
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s2).outcome), uint8(Outcome.Accepted));
        _claimEverythingAndCheck();
    }

    function test_DeadlineDuringSubmission_ExpiresAfterRejection() public {
        uint256 t = _createWithDeadline(author, address(usdc), 50e6, uint64(_now() + 1 hours));
        uint256 s = _submit(doer, t);
        _warp(2 hours);
        _rejectByVote(s);
        vault.poke(t);
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Expired));
        _claimEverythingAndCheck();
    }

    // ================================================================== queue and the flat bond

    /// @notice No escalation. The queue and void-refund mechanics are unaffected; every submission's bond
    ///         stays flat at 3% of R.
    function test_Queue_FlatBondAndVoidRefund() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s1 = _submit(doer, t);
        uint256 s2 = _submit(doer2, t);
        uint256 s3 = _submit(doer3, t);
        // R = $100: rew part 3% = 3e6, flat for every submission; the fixed imd part never doubled either way
        assertEq(_sub(s1).bond.rew, 3e6);
        assertEq(_sub(s2).bond.rew, 3e6, "queued one ahead: same bond");
        assertEq(_sub(s3).bond.rew, 3e6, "queued two ahead: same bond");
        assertEq(_sub(s1).bond.imd, _fixedBond());
        assertEq(_sub(s3).bond.imd, _fixedBond());
        assertEq(uint8(_phase(s2)), uint8(Phase.Queued));

        _rejectByVote(s1); // s2 becomes active
        assertEq(uint8(_phase(s2)), uint8(Phase.Review));
        assertEq(vault.getTask(t).rejectedCount, 1);
        Bond memory quote = vault.quoteSubmission(t);
        assertEq(quote.rew, 3e6, "1 rejected + 2 ahead (s2 active, s3 queued): still flat 3e6");
        assertEq(quote.imd, _fixedBond());

        _warp(24 hours); // s2 accepted
        vault.poke(t);
        assertEq(uint8(_sub(s2).outcome), uint8(Outcome.Accepted));
        // s3 is void: its bond comes back in full, the fixed part in IMD and the rew part in USDC
        uint256 imdBefore = imd.balanceOf(doer3);
        uint256 usdcBefore = usdc.balanceOf(doer3);
        vault.claimVoidSubmission(s3);
        assertEq(imd.balanceOf(doer3) - imdBefore, _fixedBond());
        assertEq(usdc.balanceOf(doer3) - usdcBefore, 3e6);
        vm.expectRevert(NothingToClaim.selector);
        vault.claimVoidSubmission(s3);
        _claimEverythingAndCheck();
    }

    /// @notice No escalation. The doer bond is always 0.5 IMD fixed + 3% of R in R's own currency, whatever
    ///         the queue looks like: the third submission after two rejected ones pays exactly the same bond
    ///         as the first.
    function test_NoEscalation_SameBondAfterRejections() public {
        uint256 t = _create(author, address(usdc), 100e6); // 3% = 3e6
        uint256 s1 = _submit(doer, t);
        assertEq(_sub(s1).bond.rew, 3e6);
        _dispute(dave, s1);
        _vote(s1, 0, 2, 0, 120); // reject
        _endVote(s1);
        _warp(24 hours + 1);
        vault.poke(t);
        assertEq(uint8(_sub(s1).outcome), uint8(Outcome.Rejected));

        uint256 s2 = _submit(doer2, t);
        assertEq(_sub(s2).bond.rew, 3e6, "second submission: same bond, no doubling");
        _dispute(dave, s2);
        _vote(s2, 0, 2, 0, 120);
        _endVote(s2);
        _warp(24 hours + 1);
        vault.poke(t);
        assertEq(uint8(_sub(s2).outcome), uint8(Outcome.Rejected));

        uint256 s3 = _submit(doer3, t);
        assertEq(_sub(s3).bond.rew, 3e6, "third submission after two rejected: still the same bond");
        assertEq(_sub(s3).bond.imd, _fixedBond(), "fixed part unaffected either way");
        assertEq(vault.quoteSubmission(t).rew, 3e6);
    }

    /// @notice Bond = 0.5 IMD fixed + 3% of R in R's own currency. No oracle, no USD floor: every reward size
    ///         (here $10, $299 and $300) bonds the same percent of its own reward, whatever the IMD price is.
    function test_QuoteBondFormula() public {
        uint256 t = _create(author, address(usdc), 299e6);
        Bond memory q = vault.quoteSubmission(t);
        assertEq(q.imd, _fixedBond());
        assertEq(q.rew, 8.97e6, "3% of $299");
        uint256 t2 = _create(author, address(usdc), 300e6);
        assertEq(vault.quoteSubmission(t2).rew, 9e6, "3% of $300");
        uint256 t3 = _create(author, address(usdc), 10e6);
        assertEq(vault.quoteSubmission(t3).rew, 0.3e6, "3% of $10, no floor");
        // the IMD price does not touch the bond at all: raising it changes nothing here
        oracle.set(address(imd), 2e18, 18);
        assertEq(vault.quoteSubmission(t3).rew, 0.3e6);
        uint256 s = _submit(doer, t3);
        assertEq(_sub(s).bond.imd, _fixedBond());
        assertEq(_sub(s).bond.rew, 0.3e6);
    }

    // ================================================================== parameter versions

    function test_ParamChange_DoesNotAffectExistingTasks() public {
        uint256 tOld = _create(author, address(usdc), 100e6);
        Params memory p = defaultParams();
        p.disputeWindow = 36 hours;
        p.feeBps = 1_500;
        p.nftFeeBps = 900;
        vm.prank(multisig);
        registry.proposeParams(p);
        vm.expectRevert(ParamsRegistry.TimelockNotPassed.selector);
        registry.activateParams();
        _warp(48 hours);
        registry.activateParams();
        assertEq(registry.currentVersion(), 2);

        uint256 tNew = _create(author, address(usdc), 100e6);
        assertEq(vault.getTask(tOld).paramsVersion, 1);
        assertEq(vault.getTask(tNew).paramsVersion, 2);

        uint256 sOld = _submit(doer, tOld);
        uint256 sNew = _submit(doer2, tNew);
        assertEq(_sub(sOld).windowEnd, _now() + 24 hours);
        assertEq(_sub(sNew).windowEnd, _now() + 36 hours);
        _warp(24 hours);
        vault.poke(tOld);
        vault.poke(tNew);
        assertEq(uint8(_phase(sNew)), uint8(Phase.Review)); // v2 window still open
        _warp(12 hours);
        vault.poke(tNew);
        assertEq(vault.credits(address(usdc), doer), 90e6 + 3e6); // 10% under v1, plus his rew bond back
        assertEq(vault.credits(address(usdc), doer2), 85e6 + 3e6); // 15% under v2, plus his rew bond back
        _claimEverythingAndCheck();
    }

    function test_ParamBounds() public {
        Params memory p = defaultParams();
        p.feeBps = 1_600;
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(ParamsBounds.ParamOutOfBounds.selector, "feeBps"));
        registry.proposeParams(p);
        p = defaultParams();
        p.swarmTimeout = 5 minutes;
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(ParamsBounds.ParamOutOfBounds.selector, "swarmTimeout"));
        registry.proposeParams(p);
        p = defaultParams();
        p.disputeWindow = 23 hours; // never below 24h
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(ParamsBounds.ParamOutOfBounds.selector, "disputeWindow"));
        registry.proposeParams(p);
        p = defaultParams();
        p.maxTextBytes = 600;
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(ParamsBounds.ParamOutOfBounds.selector, "maxTextBytes"));
        registry.proposeParams(p);
        // no reward cap; minRewardUsdc is bounded directly
        p = defaultParams();
        p.minRewardUsdc = 1_000e6 + 1;
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(ParamsBounds.ParamOutOfBounds.selector, "minRewardUsdc"));
        registry.proposeParams(p);
        p = defaultParams();
        p.bondFixedImd = 200e18; // no oracle, no USD floor; the fixed IMD part is bounded directly
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(ParamsBounds.ParamOutOfBounds.selector, "bondFixedImd"));
        registry.proposeParams(p);
        vm.expectRevert(); // not the owner
        registry.proposeParams(defaultParams());
    }

    function test_ParamProposalCancel() public {
        vm.startPrank(multisig);
        registry.proposeParams(defaultParams());
        registry.cancelParams();
        vm.stopPrank();
        _warp(3 days);
        vm.expectRevert(ParamsRegistry.NothingPending.selector);
        registry.activateParams();
    }

    // ================================================================== helpers

    /// @dev Dispute and reject `s` through the NFT vote (no appeal).
    function _rejectByVote(uint256 s) internal {
        _dispute(dave, s);
        _vote(s, 1, 2, 120, 20); // 20 NFTs reject = instantDelta: decides at once
        _warp(24 hours);
        vault.poke(_sub(s).taskId); // appeal window over
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Rejected));
    }
}
