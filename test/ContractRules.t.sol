// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./Base.t.sol";

/// @notice Stake and top-up rules:
///         (1) the doer stake bonus has no threshold: 4% x min(1, power / R in $YOLO) from any power;
///         (2) a top-up made while a proof is being checked joins the reward at once (like the $YOLO add-on): the
///             accepted doer is paid it, it never goes back to the contributor; the doer's bond stays 3% of the
///             author's own reward; a decided task takes no top-up.
///         (3) the stake power is measured against the task's whole reward at the submission (the pot with
///             every top-up) plus its $YOLO add-on; the bonus share is paid on the whole reward and on the add-on. Base prices: $YOLO at $0.0001, $100 = 1M $YOLO.
/// forge-config: default.isolate = false
contract ContractRulesTest is Base {
    uint8 internal constant REJECT = 2;

    function _lock(address who, uint256 add, uint256 weeks_) internal {
        vm.prank(who);
        hub.lock(add, weeks_);
    }

    /// (1) a stake worth 5% of the reward (50k $YOLO for a year on a $100 = 1M $YOLO task): bonus 0.2% of R = $0.20;
    ///     of the stakers' 5% the other 4.8% half to the buyback wallet, half to the treasury; the NFT 5% nobody
    ///     earned to the buyback wallet.
    function test_Stake5PercentOfReward_Bonus02Percent() public {
        _lock(doer, 50_000e18, 52);
        _warp(1);
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        assertEq(_sub(s).stakeBps, 20, "fixed at the submission: 0.2%");
        _warp(24 hours);
        vault.poke(t);
        assertEq(vault.getSettlement(s).stakeBps, 20);
        assertEq(vault.credits(address(usdc), doer), 90.2e6 + 3e6, "90% + 0.2% plus his rew bond back");
        assertEq(usdc.balanceOf(buybackWallet), 2.4e6 + 5e6);
        assertEq(vault.treasuryPot(address(usdc)), 2.4e6);
        _claimEverythingAndCheck();
    }

    /// (1) even a tiny stake counts, in whole bps rounded down: 2,500 $YOLO of power on 1M = 0.25% of R -> 1 bps;
    ///     2,499 -> 0.
    function test_TinyStake_WholeBpsRoundedDown() public {
        _lock(doer, 2_500e18, 52);
        _lock(doer2, 2_499e18, 52);
        _warp(1);
        uint256 s1 = _submit(doer, _create(author, address(usdc), 100e6));
        uint256 s2 = _submit(doer2, _create(author, address(usdc), 100e6));
        assertEq(_sub(s1).stakeBps, 1);
        assertEq(_sub(s2).stakeBps, 0);
    }

    /// (2) a USDC top-up during the check, the proof accepted: the doer is paid 90% of 100 + 50, his bond stays 3% of
    ///     the author's 100; bob gets nothing back; the decided task takes no more.
    function test_UsdcTopUpDuringCheck_InTheDoersPayout() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        vm.expectEmit(true, true, false, true, address(vault));
        emit ToppedUp(t, bob, 50e6, true);
        _topUp(bob, t, 50e6);
        assertEq(vault.potOf(t), 150e6);
        assertEq(_sub(s).bond.rew, 3e6, "the bond: 3% of the author's 100");
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        assertEq(_sub(s).reward, 150e6, "the reward paid");
        assertEq(vault.credits(address(usdc), doer), 135e6 + 3e6, "90% of 150 plus his rew bond back");
        assertEq(vault.treasuryPot(address(usdc)), 15e6);
        vm.prank(bob);
        vm.expectRevert(NothingToClaim.selector);
        vault.withdrawContribution(t);
        vm.prank(bob);
        vm.expectRevert(TaskNotOpen.selector);
        vault.topUp(t, 1e6, _noSwap());
        _claimEverythingAndCheck();
    }

    /// (2) an ETH top-up during the check (swarm audit 117cf05a: "pending top-up back at once after the acceptance").
    function test_EthTopUpDuringCheck_PaidToTheDoer() public {
        uint256 t = _create(author, ETH, 0.01 ether);
        uint256 s = _submit(doer, t);
        _topUp(alice, t, 0.004 ether);
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        vm.prank(alice);
        vm.expectRevert(NothingToClaim.selector);
        vault.withdrawContribution(t);
        assertEq(vault.credits(ETH, doer), 0.0126 ether + 0.0003 ether, "0.014 minus 10%, plus his rew bond back");
        _claimEverythingAndCheck();
    }

    /// (2) a top-up during a check that ends in a rejection stays in the reward: the next proof is checked for it and
    ///     its doer is paid it.
    function test_TopUpDuringRejectedCheck_PaidToTheNextDoer() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        _topUp(bob, t, 20e6);
        _dispute(dave, s);
        _vote(s, 1, REJECT, 120, 20);
        _warp(48 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Rejected));
        assertEq(vault.potOf(t), 120e6);
        uint256 s2 = _submit(doer2, t);
        assertEq(_sub(s2).reward, 120e6);
        assertEq(_sub(s2).bond.rew, 3e6, "3% of the author's 100 only");
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s2).outcome), uint8(Outcome.Accepted));
        assertEq(vault.credits(address(usdc), doer2), 108e6 + 3e6, "90% of 120 plus his rew bond back");
        _claimEverythingAndCheck();
    }

    /// (3) an example: author $100 USDC + a $YOLO add-on worth $50 (500k), power worth $150 (1.5M for a year):
    ///     the whole 4%, paid on both: $94 of the reward and 94% of the add-on (470k $YOLO).
    function test_AddonInPowerBase_FullBonusOnBoth() public {
        _lock(doer, 1_500_000e18, 52);
        _warp(1);
        uint256 t = _create(author, address(usdc), 100e6);
        vm.prank(alice);
        sweetener.sweeten(t, 500_000e18);
        uint256 s = _submit(doer, t);
        assertEq(_sub(s).stakeBps, 400, "1.5M of power against the reward's 1M + the 500k add-on");
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        assertEq(vault.getSettlement(s).stakeBps, 400);
        assertEq(vault.credits(address(usdc), doer), 94e6 + 3e6, "90% + 4% plus his rew bond back");
        uint256 b0 = yolo.balanceOf(doer);
        sweetener.payout(t);
        assertEq(yolo.balanceOf(doer) - b0, 470_000e18, "94% of the add-on");
        _claimEverythingAndCheck();
    }

    /// (3) others' top-ups are in the power base: author $100, bob tops up $100 before the proof; power
    ///     worth $50 (500k for a year) is 1% (against the whole $200), paid on the whole $200: $182 to the doer.
    function test_TopUpInPowerBase_BonusOnTheWholeReward() public {
        _lock(doer, 500_000e18, 52);
        _warp(1);
        uint256 t = _create(author, address(usdc), 100e6);
        _topUp(bob, t, 100e6);
        assertEq(vault.potOf(t), 200e6);
        uint256 s = _submit(doer, t);
        assertEq(_sub(s).stakeBps, 100, "500k against the whole 2M");
        assertEq(_sub(s).bond.rew, 3e6, "the bond: 3% of the author's 100");
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        assertEq(vault.credits(address(usdc), doer), 182e6 + 3e6, "91% of 200 plus his rew bond back");
        _claimEverythingAndCheck();
    }

    /// (3) a friend tops up the pool: author $5, bob $995. A lock worth only the author's $5 (50k for a year) is
    ///     50k / 10M of 4% = 2 bps of the $1,000, not the whole 4%; the full 4% needs power worth the whole pool.
    function test_FriendTopUp_BonusNeedsLockAgainstTheWholePool() public {
        _lock(doer, 50_000e18, 52);
        _lock(dave, 10_000_000e18, 52);
        _warp(1);
        uint256 t = _create(author, address(usdc), 5e6);
        _topUp(bob, t, 995e6);
        assertEq(vault.potOf(t), 1_000e6);
        uint256 s = _submit(doer, t);
        assertEq(_sub(s).stakeBps, 2, "50k against the whole 10M");
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        assertEq(vault.credits(address(usdc), doer), 900e6 + 0.2e6 + 0.15e6, "90% + 0.02% of 1,000 plus the rew bond");
        uint256 t2 = _create(author, address(usdc), 5e6);
        _topUp(bob, t2, 995e6);
        uint256 s2 = _submit(dave, t2);
        assertEq(_sub(s2).stakeBps, 400, "power worth the whole pool: the whole 4%");
        _claimEverythingAndCheck();
    }

    /// (3) a big add-on on a small reward: 1,000 $YOLO reward + a 10M $YOLO add-on. A lock worth the reward only
    ///     (1,000 for a year) is 1,000 / 10,001,000 of 4% = 0 bps: no bonus out of the add-on (90% of it, not 94%).
    ///     The full 4% needs power worth the reward plus the add-on: 10,001,000.
    function test_BigAddon_BonusNeedsLockAgainstRewardPlusAddon() public {
        _lock(doer, 1_000e18, 52);
        _lock(dave, 10_001_000e18, 52);
        _warp(1);
        uint256 t = _create(author, address(yolo), 1_000e18);
        vm.prank(alice);
        sweetener.sweeten(t, 10_000_000e18);
        uint256 s = _submit(doer, t);
        assertEq(_sub(s).stakeBps, 0, "1,000 against 1,000 + 10M: floors to 0");
        assertTrue(_sub(s).staked);
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        assertEq(vault.getSettlement(s).stakeBps, 0);
        uint256 b0 = yolo.balanceOf(doer);
        sweetener.payout(t);
        assertEq(yolo.balanceOf(doer) - b0, 9_000_000e18, "90% of the add-on, no stake share");

        uint256 t2 = _create(author, address(yolo), 1_000e18);
        vm.prank(alice);
        sweetener.sweeten(t2, 10_000_000e18);
        uint256 s2 = _submit(dave, t2);
        assertEq(_sub(s2).stakeBps, 400, "power worth the reward plus the add-on: the whole 4%");
        _warp(24 hours);
        vault.poke(t2);
        assertEq(uint8(_sub(s2).outcome), uint8(Outcome.Accepted));
        b0 = yolo.balanceOf(dave);
        sweetener.payout(t2);
        assertEq(yolo.balanceOf(dave) - b0, 9_400_000e18, "94% of the add-on");
        _claimEverythingAndCheck();
    }
}
