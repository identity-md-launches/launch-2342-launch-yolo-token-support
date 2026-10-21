// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./Base.t.sol";
import {YoloPredict} from "../src/YoloPredict.sol";

/// @dev (1) Only the dev wallet (the owner of the task's DevPrices) cancels
/// an open task; (2) everyone takes back exactly what he put in, each with his own claim; (3) the dev wallet gets
/// nothing; swarm fees already paid stay paid; (4) no cancellation after the final payout.
/// forge-config: default.isolate = false
contract CancelTaskTest is Base {
    uint8 internal constant ACCEPT = 1;
    YoloPredict internal yoloPredict;

    function setUp() public override {
        super.setUp();
        yoloPredict = new YoloPredict(address(vault), 0.5e18);
        for (uint256 i; i < actors.length; ++i) {
            vm.prank(actors[i]);
            yolo.approve(address(yoloPredict), type(uint256).max);
        }
    }

    function _bal(address token, address who) internal view returns (uint256) {
        return token == ETH ? who.balance : IERC20(token).balanceOf(who);
    }

    function _snap(address who) internal view returns (uint256[4] memory b) {
        address[4] memory ts = _tokens();
        for (uint256 i; i < 4; ++i) {
            b[i] = _bal(ts[i], who);
        }
    }

    function _withdrawAll(address who) internal {
        address[4] memory ts = _tokens();
        for (uint256 i; i < 4; ++i) {
            if (vault.credits(ts[i], who) != 0) {
                vm.prank(who);
                vault.withdraw(ts[i]);
            }
        }
    }

    function _predict(address who, uint256 t, bool willDo, uint256 amount) internal {
        vm.prank(who);
        yoloPredict.predict(t, willDo, amount);
    }

    // ================================================================== (1) only the dev wallet

    function test_Cancel_OnlyTheDevWallet() public {
        uint256 t = _create(author, address(usdc), 100e6);
        address[4] memory notDev = [author, multisig, doer, address(this)];
        for (uint256 i; i < notDev.length; ++i) {
            vm.prank(notDev[i]);
            vm.expectRevert(NotAuthorized.selector);
            vault.cancelTask(t);
        }
        vm.expectEmit(address(vault));
        emit TaskCancelled(t, devWallet);
        vm.prank(devWallet);
        vault.cancelTask(t);
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Unwound));
        // a new DevPrices owner is the dev wallet from then on (Ownable2Step transfer in the real contract)
        uint256 t2 = _create(author, address(usdc), 100e6);
        oracle.setOwner(alice);
        vm.prank(devWallet);
        vm.expectRevert(NotAuthorized.selector);
        vault.cancelTask(t2);
        vm.prank(alice);
        vault.cancelTask(t2);
    }

    function test_Cancel_UnknownTaskReverts() public {
        vm.prank(devWallet);
        vm.expectRevert(TaskNotOpen.selector);
        vault.cancelTask(42);
    }

    // ================================================================== (2) + (3) everyone gets his own back, dev nothing

    /// A busy task: reward + a top-up + a top-up during the check, a $YOLO add-on, two YOLO Predict positions, an active
    /// submission (disputed, NFT decided, appealed, the swarm question asked and paid) and a queued one. The dev
    /// cancels before the swarm answers. Every participant claims and ends exactly where he started, except the
    /// appellant, who is out the swarm fee the Intake already took. The dev wallet's balances and credits never move.
    function test_Cancel_EveryoneTakesBackExactlyWhatHePutIn_DevGetsNothing() public {
        address[9] memory who = [author, alice, bob, doer, doer2, dave, erin, voters[0], devWallet];
        uint256[4][9] memory before;
        for (uint256 i; i < who.length; ++i) {
            before[i] = _snap(who[i]);
        }

        // no creation fee: the Base helper's voluntary 0.001 ETH tip to the treasury left out
        vm.prank(author);
        uint256 t = vault.createTask(
            address(usdc),
            100e6,
            uint64(_now() + 10 days),
            "Title",
            rulesOf("ipfs://task-condition"),
            0,
            PROOF_LINK, // evidence-required this task's proof type does not matter here, keep it optional
            "",
            _noSwap()
        );
        _topUp(alice, t, 20e6);
        vm.prank(bob);
        sweetener.sweeten(t, 1_000_000e18);
        _predict(alice, t, true, 10e18);
        _predict(bob, t, false, 20e18);

        uint256 s = _submit(doer, t);
        uint256 s2 = _submit(doer2, t); // queued
        _topUp(alice, t, 5e6); // during the check: in the pot at once
        assertEq(_sub(s).bond.rew, 3e6, "3% of the author's 100 USDC (alice's 20 and the add-on are no part of it)");
        _dispute(dave, s);
        _vote(s, 0, ACCEPT, 0, 120);
        _endVote(s);
        _appeal(erin, s);
        _askAppealSwarm(s); // the appeal question is asked: erin's prepaid fee goes to the Intake (lazy ask)
        assertEq(uint8(_sub(s).phase), uint8(Phase.Asked));
        assertGt(yoloPredict.burnHeld(t), 0);

        vm.prank(devWallet);
        vault.cancelTask(t);
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Unwound));
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Unwound));
        assertEq(uint8(yoloPredict.resolution(t)), uint8(YoloPredict.Resolution.Void));

        // every claim is pulled by its owner, one by one
        vm.prank(author);
        vault.withdrawContribution(t);
        vm.prank(alice);
        vault.withdrawContribution(t);
        vm.prank(bob);
        sweetener.withdraw(t);
        vault.claimVoidSubmission(s2);
        vm.prank(dave);
        vault.claimDisputer(s);
        vm.prank(alice);
        yoloPredict.claim(t);
        vm.prank(bob);
        yoloPredict.claim(t);
        for (uint256 i; i < who.length; ++i) {
            _withdrawAll(who[i]);
        }

        address[4] memory ts = _tokens();
        for (uint256 i; i < who.length; ++i) {
            uint256[4] memory afterB = _snap(who[i]);
            for (uint256 k; k < 4; ++k) {
                uint256 lost = who[i] == erin && ts[k] == address(imd) ? PRICE : 0;
                assertEq(afterB[k] + lost, before[i][k], "exactly what he put in comes back");
                assertEq(vault.credits(ts[k], who[i]), 0, "nothing left to claim");
            }
        }
        for (uint256 k; k < 4; ++k) {
            assertEq(vault.liabilities(ts[k]), 0, "the vault owes nothing: every unit went back");
            assertEq(vault.treasuryPot(ts[k]), 0, "no fee, no treasury share on a cancellation");
            assertEq(_bal(ts[k], devWallet), before[8][k], "the dev wallet gets nothing");
        }
        assertEq(yolo.balanceOf(address(sweetener)), 0, "every add-on back");
        assertEq(yolo.balanceOf(address(yoloPredict)), 0, "every position back in full");
        assertEq(yoloPredict.burnHeld(t), 0, "the held 5% went back with the positions");
    }

    /// No submission: the reward back to the author, every YOLO Predict position back in full (100%: no 5% burn, no
    /// 5% deferred), nothing burned anywhere.
    function test_Cancel_OpenTaskNoSubmission_PredictPositionsBackInFull() public {
        uint256 t = _createWithDeadline(author, address(yolo), 1_000_000e18, uint64(_now() + 10 days));
        uint256 dead0 = yolo.balanceOf(DEAD);
        uint256 a0 = yolo.balanceOf(alice);
        uint256 b0 = yolo.balanceOf(bob);
        _predict(alice, t, true, 100e18);
        _predict(bob, t, false, 33e18 + 7);
        vm.prank(devWallet);
        vault.cancelTask(t);
        vm.expectEmit(address(yoloPredict));
        emit YoloPredict.Settled(t, YoloPredict.Resolution.Void, address(0), 0, 0, 0);
        yoloPredict.settle(t);
        vm.prank(alice);
        yoloPredict.claim(t);
        vm.prank(bob);
        yoloPredict.claim(t);
        assertEq(yolo.balanceOf(alice), a0, "100 in, 100 back");
        assertEq(yolo.balanceOf(bob), b0, "33e18 + 7 in, all of it back");
        uint256 au0 = yolo.balanceOf(author);
        vm.prank(author);
        vault.withdrawContribution(t);
        assertEq(yolo.balanceOf(author) - au0, 1_000_000e18);
        assertEq(yolo.balanceOf(DEAD), dead0, "nothing burned on a cancellation");
        assertEq(yolo.balanceOf(address(yoloPredict)), 0);
        assertEq(vault.liabilities(address(yolo)), 0);
    }

    /// After a cancellation nothing new gets in: no top-up, no submission, no add-on, no position.
    function test_Cancel_NothingNewAfterwards() public {
        uint256 t = _create(author, address(usdc), 100e6);
        vm.prank(devWallet);
        vault.cancelTask(t);
        vm.prank(alice);
        vm.expectRevert(TaskNotOpen.selector);
        vault.topUp(t, 1e6, _noSwap());
        vm.prank(doer);
        vm.expectRevert();
        vault.submit{value: ETH_BOND_HEADROOM}(
            t, "https://x.com/doer/status/1", _noEvidence(), 0, type(uint256).max, _noSwap()
        );
        vm.prank(bob);
        vm.expectRevert(YoloSweetener.TaskNotOpen.selector);
        sweetener.sweeten(t, 1_000e18);
        vm.prank(alice);
        vm.expectRevert(YoloPredict.TaskNotOpen.selector);
        yoloPredict.predict(t, true, 1e18);
        vm.prank(devWallet);
        vm.expectRevert(TaskNotOpen.selector);
        vault.cancelTask(t); // once only
    }

    // ================================================================== (4) not after the final payout

    function test_Cancel_AfterThePayout_Reverts() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        vm.warp(_sub(s).windowEnd + 1);
        vault.poke(t);
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Completed));
        vm.prank(devWallet);
        vm.expectRevert(TaskNotOpen.selector);
        vault.cancelTask(t);
    }

    /// The timers decide first: a submission whose window ran out is accepted by the cancellation's own poke, so the
    /// payout stands and the cancellation reverts (nobody can cancel a task that is already done but not yet poked).
    function test_Cancel_AcceptedByTimerButUnpoked_Reverts() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        vm.warp(_sub(s).windowEnd + 1);
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Open), "stored status still Open");
        vm.prank(devWallet);
        vm.expectRevert(TaskNotOpen.selector);
        vault.cancelTask(t);
    }

    function test_Cancel_AfterExpiry_Reverts() public {
        uint256 t = _createWithDeadline(author, address(usdc), 100e6, uint64(_now() + 1 days));
        _warp(1 days);
        vm.prank(devWallet);
        vm.expectRevert(TaskNotOpen.selector);
        vault.cancelTask(t); // the poke inside expires it first
    }
}
