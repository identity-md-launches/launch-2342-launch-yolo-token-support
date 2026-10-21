// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./Base.t.sol";

/// @dev The doer bond is 0.5 IMD + 3% and the dispute bond 0.5 IMD + 1% of the author's own reward
///      only. Top-ups of other contributors and the $YOLO add-on are no part of any bond; the loser's bond is split
///      in the currencies left (IMD and the reward currency). The author's own top-ups are their reward too.
/// forge-config: default.isolate = false
contract BondBaseTest is Base {
    uint8 internal constant ACCEPT = 1;
    uint8 internal constant REJECT = 2;
    uint256 internal constant F = 0.5e18;

    /// An ETH reward with a $YOLO add-on bonds 0.5 IMD + 3% of the ETH, no $YOLO.
    function test_EthRewardWithYoloAddon_BondIsImdPlusThreePercentEth() public {
        uint256 t = _create(author, ETH, 1 ether);
        vm.prank(alice);
        sweetener.sweeten(t, 1_000_000e18);
        Bond memory q = vault.quoteSubmission(t);
        assertEq(q.imd, F);
        assertEq(q.rew, 0.03 ether, "3% of the author's 1 ETH");
        uint256 e0 = doer.balance;
        uint256 i0 = imd.balanceOf(doer);
        uint256 y0 = yolo.balanceOf(doer);
        uint256 s = _submit(doer, t);
        assertEq(e0 - doer.balance, 0.03 ether);
        assertEq(i0 - imd.balanceOf(doer), F);
        assertEq(yolo.balanceOf(doer), y0, "no $YOLO in the bond");
        assertEq(_sub(s).bond.rew, 0.03 ether);
        assertEq(_sub(s).base, 1 ether);
        assertEq(_sub(s).addon, 1_000_000e18);
        Bond memory d = vault.quoteDisputeBond(s);
        assertEq(d.imd, F);
        assertEq(d.rew, 0.01 ether, "1% of the author's 1 ETH");
        uint256 dy0 = yolo.balanceOf(dave);
        uint256 de0 = dave.balance;
        _dispute(dave, s);
        assertEq(yolo.balanceOf(dave), dy0, "no $YOLO in the dispute bond");
        assertEq(de0 - dave.balance, 0.01 ether);
    }

    /// The NFT reject it and are right: the doer's bond (0.5 IMD + 0.03 ETH) is split in IMD and ETH only, half to
    /// the disputer, half to the votes; nobody's $YOLO moves; the add-on waits for the next submission.
    function test_Rejected_LoserBondSplitInImdAndEthOnly() public {
        uint256 t = _create(author, ETH, 1 ether);
        vm.prank(alice);
        sweetener.sweeten(t, 1_000_000e18);
        uint256 s = _submit(doer, t);
        _dispute(dave, s);
        uint256 dy0 = yolo.balanceOf(dave);
        uint256 vy0 = yolo.balanceOf(voters[1]);
        _vote(s, 1, REJECT, 120, 20); // decides at once
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Rejected));
        Settlement memory st = vault.getSettlement(s);
        assertEq(st.voterBond.imd, F / 2);
        assertEq(st.voterBond.rew, 0.015 ether);
        assertEq(st.disputerReward.imd, F / 2);
        assertEq(st.disputerReward.rew, 0.015 ether);
        uint256 de0 = dave.balance;
        uint256 di0 = imd.balanceOf(dave);
        vm.prank(dave);
        vault.claimDisputer(s);
        assertEq(dave.balance - de0, 0.01 ether + 0.015 ether, "his 1% back + half of the doer's 3%");
        assertEq(imd.balanceOf(dave) - di0, F + F / 2);
        vault.claimVoterReward(s, voters[1]);
        assertEq(yolo.balanceOf(dave), dy0);
        assertEq(yolo.balanceOf(voters[1]), vy0);
        assertEq(sweetener.bonusOf(t), 1_000_000e18, "the add-on stays with the task");
        _claimEverythingAndCheck();
    }

    /// Accepted: the doer gets their bond (0.5 IMD + 0.03 ETH) back with 90% of R; the add-on is paid by the
    /// sweetener.
    function test_Accepted_BondBackWithoutYolo() public {
        uint256 t = _create(author, ETH, 1 ether);
        vm.prank(alice);
        sweetener.sweeten(t, 1_000_000e18);
        uint256 s = _submit(doer, t);
        vm.warp(_sub(s).windowEnd);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        assertEq(vault.credits(ETH, doer), 0.9 ether + 0.03 ether);
        assertEq(vault.credits(address(imd), doer), F);
        assertEq(vault.credits(address(yolo), doer), 0);
        uint256 y0 = yolo.balanceOf(doer);
        sweetener.payout(t);
        assertEq(yolo.balanceOf(doer) - y0, 900_000e18, "90% of the add-on");
        _claimEverythingAndCheck();
    }

    /// Top-ups of others are paid to the doer with R but are no part of the bonds; the author's own top-up is.
    function test_TopUps_OnlyTheAuthorsCount() public {
        uint256 t = _create(author, address(usdc), 100e6);
        _topUp(bob, t, 50e6);
        assertEq(vault.getTask(t).pot, 150e6);
        assertEq(vault.quoteSubmission(t).rew, 3e6, "3% of the author's 100, not of 150");
        _topUp(author, t, 20e6);
        assertEq(vault.quoteSubmission(t).rew, 3.6e6, "3% of the author's 120");
        uint256 s = _submit(doer, t);
        assertEq(_sub(s).reward, 170e6, "R: everything in the pot");
        assertEq(_sub(s).base, 120e6);
        assertEq(_sub(s).bond.rew, 3.6e6);
        assertEq(vault.quoteDisputeBond(s).rew, 1.2e6, "1% of the author's 120");
        vm.warp(_sub(s).windowEnd);
        vault.poke(t);
        assertEq(vault.credits(address(usdc), doer), 153e6 + 3.6e6, "90% of all 170 + his bond back");
        _claimEverythingAndCheck();
    }

    /// Top-ups made while a submission is judged join the pot at once; the running
    /// submission keeps its bond, the next one's bond counts the author's top-up, a contributor's does not.
    function test_AuthorsTopUpDuringCheck_CountsOnceInThePot() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        _topUp(author, t, 10e6); // during the check: in the pot at once
        _topUp(bob, t, 40e6);
        assertEq(vault.getTask(t).pot, 150e6);
        assertEq(_sub(s).bond.rew, 3e6, "the running submission keeps its bond");
        assertEq(vault.quoteSubmission(t).rew, 3.3e6, "3% of the author's 110, bob's 40 not counted");
        _dispute(dave, s);
        _vote(s, 1, REJECT, 120, 20);
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Rejected));
        assertEq(vault.getTask(t).pot, 150e6);
        assertEq(vault.quoteSubmission(t).rew, 3.3e6, "3% of the author's 110");
        uint256 s2 = _submit(doer2, t);
        assertEq(_sub(s2).bond.rew, 3.3e6);
        assertEq(_sub(s2).base, 110e6);
        _claimEverythingAndCheck();
    }

    /// The doer bond of a queued submission is fixed at its submission, from the author's base then.
    function test_QueuedSubmission_BondFixedAtSubmission() public {
        uint256 t = _create(author, address(usdc), 100e6);
        _submit(doer, t);
        uint256 s2 = _submit(doer2, t); // queued
        assertEq(_sub(s2).bond.rew, 3e6);
        vm.prank(alice);
        sweetener.sweeten(t, 5_000_000e18);
        assertEq(vault.quoteSubmission(t).rew, 3e6, "the add-on changes no bond");
        _claimEverythingAndCheck();
    }
}
