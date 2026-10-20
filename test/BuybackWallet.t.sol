// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./Base.t.sol";

/// @dev The burner buys and swaps nothing: $YOLO waits for anyone's
///      "Burn" and goes to 0x...dEaD; ETH, USDC, IMD wait for anyone's "Send" (`forward`) and go to the buyback wallet,
///      a dev parameter. Every outcome for R = $100: where the burn share ends up after `forward`.
///      Dollar amounts below follow Base's configured token prices (see Base.t.sol).
/// forge-config: default.isolate = false
contract BuybackWalletTest is Base {
    uint8 internal constant ACCEPT = 1;
    uint8 internal constant REJECT = 2;
    /// @dev 1M $YOLO for 52 weeks = power 1M = R in $YOLO: the whole 4%.
    uint256 internal constant STAKE = 1_000_000e18;
    /// @dev the doer bond's percent part of R = 100 USDC (3%), and the dispute bond's (1%)
    uint256 internal constant DB = 3e6;
    uint256 internal constant SB = 1e6;

    event Forwarded(address indexed token, address indexed to, uint256 amount);
    event BuybackWalletSet(address indexed wallet);

    function _lock(address who, uint256 amount, uint256 weeks_) internal {
        vm.prank(who);
        hub.lock(amount, weeks_);
        _warp(1);
    }

    /// @dev Anyone presses "Send" for ETH, USDC and IMD (a token with nothing waiting is skipped).
    function _sendAll() internal {
        address[3] memory ts = [ETH, address(usdc), address(imd)];
        for (uint256 i; i < 3; ++i) {
            if (_burnerHolds(ts[i]) == 0) continue;
            vm.prank(erin);
            burner.forward(ts[i]);
        }
    }

    function _burnerHolds(address token) internal view returns (uint256) {
        return token == ETH ? address(burner).balance : IERC20(token).balanceOf(address(burner));
    }

    function _wallet(address token) internal view returns (uint256) {
        return token == ETH ? buybackWallet.balance : IERC20(token).balanceOf(buybackWallet);
    }

    /// @dev A USDC task R = 100 for `who`, accepted by the timer.
    function _accepted(address who) internal returns (uint256 t, uint256 s) {
        t = _create(author, address(usdc), 100e6);
        s = _submit(who, t);
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
    }

    // ================================================================== the contract

    function test_Constructor_StartWallet_AndZeroRefused() public {
        assertEq(burner.buybackWallet(), buybackWallet);
        assertEq(burner.dev(), devWallet, "the dev wallet = owner of the DevPrices");
        vm.expectRevert(BuybackBurner.ZeroAddress.selector);
        new BuybackBurner(address(yolo), address(imd), address(usdc), address(oracle), address(0));
    }

    function test_SetBuybackWallet_OnlyDev_WithEvent() public {
        address next = makeAddr("nextBuyback");
        address[4] memory notDev = [author, doer, treasury, multisig];
        for (uint256 i; i < notDev.length; ++i) {
            vm.prank(notDev[i]);
            vm.expectRevert(BuybackBurner.NotDev.selector);
            burner.setBuybackWallet(next);
        }
        vm.prank(devWallet);
        vm.expectRevert(BuybackBurner.ZeroAddress.selector);
        burner.setBuybackWallet(address(0));
        vm.expectEmit(address(burner));
        emit BuybackWalletSet(next);
        vm.prank(devWallet);
        burner.setBuybackWallet(next);
        assertEq(burner.buybackWallet(), next);

        // what waits goes to the new wallet, nothing to the old one
        deal(address(usdc), address(burner), 7e6);
        vm.prank(erin);
        burner.forward(address(usdc));
        assertEq(usdc.balanceOf(next), 7e6);
        assertEq(usdc.balanceOf(buybackWallet), 0);
    }

    /// @dev Even the dev cannot send the money anywhere but the buyback wallet: `forward` is the only way out, and it
    ///      takes no address.
    function test_Forward_AnyoneOnlyToTheWallet_Totals() public {
        vm.deal(address(burner), 0.3 ether);
        deal(address(usdc), address(burner), 12e6);
        deal(address(imd), address(burner), 2e18);
        address[3] memory callers = [erin, devWallet, doer];
        address[3] memory ts = [ETH, address(usdc), address(imd)];
        uint256[3] memory amounts = [uint256(0.3 ether), 12e6, 2e18];
        for (uint256 i; i < 3; ++i) {
            vm.expectEmit(address(burner));
            emit Forwarded(ts[i], buybackWallet, amounts[i]);
            vm.prank(callers[i]);
            assertEq(burner.forward(ts[i]), amounts[i]);
            assertEq(_wallet(ts[i]), amounts[i]);
            assertEq(_burnerHolds(ts[i]), 0);
            assertEq(burner.forwarded(ts[i]), amounts[i]);
        }
        assertEq(callers[1].balance, 0, "the dev got nothing");
        // nothing waiting: refused, the total stays
        vm.expectRevert(BuybackBurner.Nothing.selector);
        burner.forward(address(usdc));
        // a second batch adds up
        deal(address(usdc), address(burner), 3e6);
        burner.forward(address(usdc));
        assertEq(burner.forwarded(address(usdc)), 15e6);
        assertEq(usdc.balanceOf(buybackWallet), 15e6);
    }

    function test_Forward_RefusesYoloAndUnknown() public {
        deal(address(yolo), address(burner), 1_000e18);
        vm.expectRevert(BuybackBurner.NotReserve.selector);
        burner.forward(address(yolo));
        vm.expectRevert(BuybackBurner.NotReserve.selector);
        burner.forward(address(nft));
        assertEq(yolo.balanceOf(buybackWallet), 0);
        assertEq(yolo.balanceOf(address(burner)), 1_000e18);
    }

    function test_BurnYolo_Anyone() public {
        deal(address(yolo), address(burner), 5_000e18);
        uint256 dead0 = yolo.balanceOf(DEAD);
        vm.prank(makeAddr("stranger"));
        burner.burnYolo();
        assertEq(yolo.balanceOf(DEAD) - dead0, 5_000e18);
        assertEq(yolo.balanceOf(address(burner)), 0);
        assertEq(yolo.balanceOf(buybackWallet), 0);
        vm.expectRevert(BuybackBurner.Nothing.selector);
        burner.burnYolo();
    }

    function test_Balances_View() public {
        vm.deal(address(burner), 1 ether);
        deal(address(usdc), address(burner), 2e6);
        deal(address(imd), address(burner), 3e18);
        deal(address(yolo), address(burner), 4e18);
        (uint256 e, uint256 u, uint256 i, uint256 y) = burner.balances();
        assertEq(e, 1 ether);
        assertEq(u, 2e6);
        assertEq(i, 3e18);
        assertEq(y, 4e18);
    }

    /// @dev A buyback wallet that refuses ETH: "Send" fails as a whole, the ETH stays and can be sent after the dev
    ///      sets a wallet that takes it.
    function test_Forward_EthRefused_StaysInTheBurner() public {
        address refuser = address(new RefusesEth());
        vm.prank(devWallet);
        burner.setBuybackWallet(refuser);
        vm.deal(address(burner), 0.1 ether);
        vm.expectRevert(BuybackBurner.EthSendFailed.selector);
        burner.forward(ETH);
        assertEq(address(burner).balance, 0.1 ether);
        assertEq(burner.forwarded(ETH), 0);
        vm.prank(devWallet);
        burner.setBuybackWallet(buybackWallet);
        burner.forward(ETH);
        assertEq(buybackWallet.balance, 0.1 ether);
    }

    // ================================================================== R = $100

    function test_NoStake_Accepted_NothingToTheWallet() public {
        (, uint256 s) = _accepted(doer2);
        assertEq(vault.credits(address(usdc), doer2), 90e6 + DB);
        assertEq(vault.treasuryPot(address(usdc)), 10e6);
        assertEq(_burnerHolds(address(usdc)), 0);
        assertEq(vault.getSettlement(s).stakeBps, 0);
        assertEq(_wallet(address(usdc)), 0);
        _claimEverythingAndCheck();
    }

    /// @dev Example: doer $94, buyback wallet $5.50, treasury $0.50. The $5.50 lands on the buyback
    ///      wallet in the same transaction as the payout: nobody had to press "Send".
    function test_FullStake_Accepted_Doer94_Wallet5_50_Treasury0_50() public {
        _lock(doer2, STAKE, 52);
        (, uint256 s) = _accepted(doer2);
        assertEq(vault.getSettlement(s).stakeBps, 400);
        assertEq(vault.credits(address(usdc), doer2), 94e6 + DB);
        assertEq(vault.treasuryPot(address(usdc)), 0.5e6);
        assertEq(_wallet(address(usdc)), 5.5e6, "5.5 to the buyback wallet, no Send needed");
        assertEq(_burnerHolds(address(usdc)), 0);
        assertEq(burner.forwarded(address(usdc)), 0, "forward was never called, autosend did it");
        _claimEverythingAndCheck();
    }

    /// @dev Power = half of R: bonus 2%, doer $92, buyback wallet $6.50 ($1.50 + the NFT $5), treasury $1.50.
    function test_HalfStake_Accepted_Doer92_Wallet6_50_Treasury1_50() public {
        _lock(doer2, STAKE / 2, 52);
        (, uint256 s) = _accepted(doer2);
        assertEq(vault.getSettlement(s).stakeBps, 200);
        assertEq(vault.credits(address(usdc), doer2), 92e6 + DB);
        assertEq(vault.treasuryPot(address(usdc)), 1.5e6);
        assertEq(_wallet(address(usdc)), 6.5e6);
        assertEq(_burnerHolds(address(usdc)), 0);
        _claimEverythingAndCheck();
    }

    /// @dev Disputed, the NFT decided right, no stake: NFT $5, treasury $5, nothing to the buyback wallet.
    function test_NftRight_NoStake_Wallet0() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer2, t);
        _dispute(dave, s);
        _vote(s, 1, ACCEPT, 120, 20);
        _warp(48 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        assertEq(vault.getSettlement(s).voterFee, 5e6);
        assertEq(vault.treasuryPot(address(usdc)), 5e6);
        assertEq(_wallet(address(usdc)), 0);
        _claimEverythingAndCheck();
    }

    /// @dev Disputed, the NFT decided right, full stake: doer $94, NFT $5, buyback wallet $0.50, treasury $0.50.
    function test_NftRight_FullStake_Wallet0_50() public {
        _lock(doer2, STAKE, 52);
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer2, t);
        _dispute(dave, s);
        _vote(s, 1, ACCEPT, 120, 20);
        _warp(48 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        assertEq(vault.getSettlement(s).voterFee, 5e6);
        assertEq(vault.treasuryPot(address(usdc)), 0.5e6);
        assertEq(_wallet(address(usdc)), 0.5e6);
        assertEq(_burnerHolds(address(usdc)), 0);
        _claimEverythingAndCheck();
    }

    /// @dev The NFT were wrong (decided "reject", the swarm accepted on the doer's appeal), full stake: the NFT get
    ///      nothing, their $5 to the buyback wallet with the $0.50: $5.50; treasury $0.50.
    function test_NftWrong_FullStake_Wallet5_50() public {
        _lock(doer2, STAKE, 52);
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer2, t);
        _dispute(dave, s);
        _vote(s, 1, REJECT, 120, 20);
        _appeal(doer2, s);
        _askAppealSwarm(s); // lazy ask
        _answer(s, true);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        assertEq(vault.getSettlement(s).voterFee, 0, "wrong NFT votes get nothing");
        assertEq(vault.getSettlement(s).stakeBps, 400);
        assertEq(vault.treasuryPot(address(usdc)), 0.5e6);
        assertEq(_wallet(address(usdc)), 5.5e6);
        assertEq(_burnerHolds(address(usdc)), 0);
        _claimEverythingAndCheck();
    }

    /// @dev The NFT were wrong, no stake: their $5 to the treasury ($10), nothing to the buyback wallet.
    function test_NftWrong_NoStake_Wallet0() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer2, t);
        _dispute(dave, s);
        _vote(s, 1, REJECT, 120, 20);
        _appeal(doer2, s);
        _askAppealSwarm(s); // lazy ask
        _answer(s, true);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        assertEq(vault.treasuryPot(address(usdc)), 10e6);
        assertEq(_wallet(address(usdc)), 0);
        _claimEverythingAndCheck();
    }

    /// @dev The NFT undecided, nobody called the swarm, full stake: $5.50 to the buyback wallet, $0.50 treasury.
    function test_NftUndecided_FullStake_Wallet5_50() public {
        _lock(doer2, STAKE, 52);
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer2, t);
        _dispute(dave, s);
        _warp(48 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        assertEq(vault.treasuryPot(address(usdc)), 0.5e6);
        assertEq(_wallet(address(usdc)), 5.5e6);
        assertEq(_burnerHolds(address(usdc)), 0);
        _claimEverythingAndCheck();
    }

    /// @dev Rejected (fake): the reward stays in the task, the bonds split between the sides: nothing to the burner.
    function test_Rejected_NothingToTheWallet() public {
        _lock(doer2, STAKE, 52);
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer2, t);
        _dispute(dave, s);
        _vote(s, 1, REJECT, 120, 20);
        _warp(48 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Rejected));
        assertEq(_burnerHolds(address(usdc)), 0);
        assertEq(_burnerHolds(address(imd)), 0);
        _claimEverythingAndCheck();
        assertEq(_wallet(address(usdc)), 0);
        assertEq(_wallet(address(imd)), 0);
    }

    /// @dev ETH and IMD rewards ($100 each) with full power: the buyback wallet gets 5.5% in that currency, straight
    ///      from the payout, no `forward` call.
    function test_EthAndImd_FullStake_WalletInTheirCurrency() public {
        _lock(doer2, STAKE, 52);
        uint256 tE = _create(author, ETH, 0.04 ether);
        _submit(doer2, tE);
        uint256 tI = _create(author, address(imd), 12.5e18);
        _submit(doer2, tI);
        _warp(24 hours);
        vault.poke(tE);
        vault.poke(tI);
        assertEq(_wallet(ETH), 0.0022 ether);
        assertEq(_wallet(address(imd)), 0.6875e18);
        assertEq(_burnerHolds(ETH), 0);
        assertEq(_burnerHolds(address(imd)), 0);
        assertEq(burner.forwarded(ETH), 0, "forward was never called");
        assertEq(burner.forwarded(address(imd)), 0, "forward was never called");
        _claimEverythingAndCheck();
    }

    /// @dev The buyback wallet refuses ETH (no `receive`): the autosend at payout must not sink the payout itself.
    ///      The doer still gets his 94%; the ETH burn share lands in the BuybackBurner instead and waits for
    ///      `forward`, which sweeps it once the dev sets a wallet that accepts ETH.
    function test_EthWalletReverts_PayoutStillSucceeds_ShareStaysInBurner() public {
        address refuser = address(new RefusesEth());
        vm.prank(devWallet);
        burner.setBuybackWallet(refuser);
        _lock(doer2, STAKE, 52);
        uint256 t = _create(author, ETH, 0.04 ether);
        uint256 s = _submit(doer2, t);
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        // 94% of R (0.0376) plus the bond's 3% rew-part back in ETH (0.0012): 0.0388
        assertEq(vault.credits(ETH, doer2), 0.0388 ether, "the doer got paid despite the refusing wallet");
        assertEq(_wallet(ETH), 0, "the refusing wallet never received anything");
        assertEq(refuser.balance, 0);
        assertEq(_burnerHolds(ETH), 0.0022 ether, "stuck in the burner, not lost");
        assertEq(burner.forwarded(ETH), 0);
        vm.prank(devWallet);
        burner.setBuybackWallet(buybackWallet);
        _sendAll();
        assertEq(_wallet(ETH), 0.0022 ether, "forward sweeps it once the wallet can take it");
        _claimEverythingAndCheck();
    }

    /// @dev The buyback wallet burns gas instead of cleanly reverting (TaskVault._burn): the
    ///      autosend caps the gas it forwards (BURN_SEND_GAS), so a wallet that spins until it runs out of gas can
    ///      burn at most that much, not the rest of the transaction. The doer still gets paid in full and the ETH
    ///      share lands in the burner, exactly like a plain revert.
    function test_EthWalletGriefsGas_PayoutStillSucceeds_ShareStaysInBurner() public {
        address griefer = address(new GriefsGas());
        vm.prank(devWallet);
        burner.setBuybackWallet(griefer);
        _lock(doer2, STAKE, 52);
        uint256 t = _create(author, ETH, 0.04 ether);
        uint256 s = _submit(doer2, t);
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        assertEq(vault.credits(ETH, doer2), 0.0388 ether, "the doer got paid despite the gas-griefing wallet");
        assertEq(_wallet(ETH), 0, "the griefing wallet never received anything");
        assertEq(griefer.balance, 0);
        assertEq(_burnerHolds(ETH), 0.0022 ether, "stuck in the burner, not lost");
        vm.prank(devWallet);
        burner.setBuybackWallet(buybackWallet);
        _sendAll();
        assertEq(_wallet(ETH), 0.0022 ether, "forward sweeps it once the wallet can take it");
        _claimEverythingAndCheck();
    }

    /// @dev A $YOLO reward with full power: 6% wait in the burner for "Burn"; "Send" refuses $YOLO, the buyback
    ///      wallet never sees any.
    function test_YoloReward_FullStake_BurnsNeverToTheWallet() public {
        _lock(doer2, STAKE, 52);
        uint256 dead0 = yolo.balanceOf(DEAD);
        uint256 t = _create(author, address(yolo), 1_000_000e18);
        _submit(doer2, t);
        _warp(24 hours);
        vault.poke(t);
        assertEq(yolo.balanceOf(address(burner)), 60_000e18);
        assertEq(vault.treasuryPot(address(yolo)), 0);
        vm.expectRevert(BuybackBurner.NotReserve.selector);
        burner.forward(address(yolo));
        burner.burnYolo();
        assertEq(yolo.balanceOf(DEAD) - dead0, 60_000e18);
        assertEq(yolo.balanceOf(buybackWallet), 0);
        _claimEverythingAndCheck();
    }

    /// @dev A $YOLO add-on (1M) on a USDC task, no stake: its 10% fee ($YOLO, NFT part unearned + the treasury's)
    ///      waits in the burner and burns; the buyback wallet gets no $YOLO and no USDC.
    function test_YoloAddOn_BurnsNeverToTheWallet() public {
        uint256 t = _create(author, address(usdc), 100e6);
        vm.prank(alice);
        sweetener.sweeten(t, 1_000_000e18);
        uint256 s = _submit(doer2, t);
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        sweetener.payout(t);
        assertEq(yolo.balanceOf(address(burner)), 100_000e18, "the add-on's 10% to the burner");
        burner.burnYolo();
        assertEq(yolo.balanceOf(address(burner)), 0);
        assertEq(yolo.balanceOf(buybackWallet), 0);
        assertEq(_wallet(address(usdc)), 0);
        _claimEverythingAndCheck();
    }
}

contract RefusesEth {
    receive() external payable {
        revert();
    }
}

/// @dev Never reverts: spins writing storage until it runs out of whatever gas it was forwarded, then the call
///      simply fails on out-of-gas (same `ok = false` as a revert, but only after spending every bit of gas it got).
contract GriefsGas {
    uint256 public sink;

    receive() external payable {
        while (true) {
            sink++;
        }
    }
}
