// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./Base.t.sol";

/// @dev A side of the dispute (the doer, or the disputer against the doer)
///      calls the swarm for itself out of its dispute bond: no second bond, no new fee from its wallet; the 0.5 IMD
///      for the swarm leave its bond. Won: the rest of its bond + the loser's bond. Lost: the rest of its bond to the
///      winner. A stranger posts a dispute bond and pays the fee. USDC task R = 100, F = 0.5 IMD, swarm
///      fee PRICE = 0.5 IMD (Base.t.sol), doer bond DB = 3 USDC, dispute bond SB = 1 USDC.
/// forge-config: default.isolate = false
contract SideCallsTest is Base {
    uint8 internal constant ACCEPT = 1;
    uint8 internal constant REJECT = 2;
    uint256 internal constant F = 0.5e18;
    uint256 internal constant DB = 3e6;
    uint256 internal constant SB = 1e6;

    uint256 internal t;
    uint256 internal s;

    function setUp() public override {
        super.setUp();
        t = _create(author, address(usdc), 100e6);
        s = _submit(doer, t);
        _dispute(dave, s);
    }

    function _net(address who) internal returns (int256 imdGain, int256 usdcGain) {
        vm.prank(who);
        try vault.claimDisputer(s) {} catch {}
        vm.startPrank(who);
        if (vault.credits(address(imd), who) != 0) vault.withdraw(address(imd));
        if (vault.credits(address(usdc), who) != 0) vault.withdraw(address(usdc));
        vm.stopPrank();
        imdGain = int256(imd.balanceOf(who)) - int256(10_000e18);
        usdcGain = int256(usdc.balanceOf(who)) - int256(1_000_000e6);
    }

    /// The disputer appeals for himself and loses: the swarm got PRICE out of his bond, the rest goes to the winner.
    function test_DisputerAppeal_Loses_RestOfBondToWinner() public {
        _vote(s, 1, ACCEPT, 120, 20);
        uint256 i0 = imd.balanceOf(dave);
        _appeal(dave, s);
        assertEq(imd.balanceOf(dave), i0, "no second bond, no fee from his wallet");
        _askAppealSwarm(s); // lazy ask
        assertEq(imd.balanceOf(swarmPayee), PRICE, "the swarm is paid out of his bond");
        _answer(s, true);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        (int256 daveImd, int256 daveUsdc) = _net(dave);
        assertEq(daveImd, -int256(F));
        assertEq(daveUsdc, -int256(SB));
        (int256 doerImd, int256 doerUsdc) = _net(doer);
        assertEq(doerImd, 0, "his own bond back; dave's IMD left with the fee");
        assertEq(doerUsdc, int256(90e6 + SB / 2), "90% of R + half of dave's SB (NFT right)");
        _claimEverythingAndCheck();
    }

    /// The doer appeals for himself and wins: the rest of his bond + the disputer's whole bond.
    function test_DoerAppeal_Wins_RestOfBondPlusLoserBond() public {
        _vote(s, 1, REJECT, 120, 20);
        uint256 i0 = imd.balanceOf(doer);
        _appeal(doer, s);
        assertEq(imd.balanceOf(doer), i0);
        assertEq(vault.getAppeal(s).bond.imd, 0, "no second bond");
        _askAppealSwarm(s); // lazy ask
        _answer(s, true);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        (int256 doerImd, int256 doerUsdc) = _net(doer);
        assertEq(doerImd, 0, "F - PRICE of his bond + dave's F: the loser's 0.5 covers his fee");
        assertEq(doerUsdc, int256(90e6 + SB));
        (int256 daveImd, int256 daveUsdc) = _net(dave);
        assertEq(daveImd, -int256(F));
        assertEq(daveUsdc, -int256(SB));
        _claimEverythingAndCheck();
    }

    /// A stranger appeals: dispute bond + fee from his wallet.
    function test_StrangerAppeal_PaysBondAndFee() public {
        _vote(s, 1, REJECT, 120, 20);
        uint256 i0 = imd.balanceOf(erin);
        uint256 u0 = usdc.balanceOf(erin);
        _appeal(erin, s);
        assertEq(i0 - imd.balanceOf(erin), F + PRICE);
        assertEq(u0 - usdc.balanceOf(erin), SB);
        assertEq(vault.getAppeal(s).fromBond, 0);
        _askAppealSwarm(s); // lazy ask
        _answer(s, true);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        _claimEverythingAndCheck();
    }

    /// The disputer calling the swarm for the doer's side is no side of his own: he pays like a stranger.
    function test_DisputerCallingForTheDoer_PaysLikeAStranger() public {
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.NoDecision));
        uint256 i0 = imd.balanceOf(dave);
        _callSwarm(dave, s, true);
        assertEq(i0 - imd.balanceOf(dave), F + PRICE);
        assertEq(vault.getAppeal(s).bond.imd, F);
        _answer(s, true);
        vault.poke(t);
        _claimEverythingAndCheck();
    }

    /// The swarm costs more than the side's bond holds: the bond pays its IMD, the wallet the rest, capped by
    /// maxImdIn; still no second bond.
    function test_FeeAboveBond_WalletPaysOnlyTheRest() public {
        _vote(s, 1, REJECT, 120, 20);
        intake.setPrice(0.8e18);
        vm.prank(doer);
        vm.expectRevert(CostAboveMax.selector);
        vault.appeal{value: ETH_BOND_HEADROOM}(s, 0.3e18 - 1, _noSwap());
        uint256 i0 = imd.balanceOf(doer);
        vm.prank(doer);
        vault.appeal{value: ETH_BOND_HEADROOM}(s, 0.3e18, _noSwap());
        assertEq(i0 - imd.balanceOf(doer), 0.3e18, "0.8 fee: 0.5 from his bond, 0.3 from his wallet");
        assertEq(vault.getAppeal(s).fromBond, F);
        assertEq(vault.getAppeal(s).funds, 0.3e18);
        _askAppealSwarm(s); // lazy ask
        assertEq(imd.balanceOf(swarmPayee), 0.8e18);
        _answer(s, false); // the swarm agrees with the NFT: the doer lost
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Rejected));
        (int256 doerImd,) = _net(doer);
        assertEq(doerImd, -int256(F + 0.3e18));
        _claimEverythingAndCheck();
    }

    /// A void appeal (price raised above what the side put in): its bond is whole again, nothing went to the swarm.
    function test_VoidSideAppeal_BondWhole() public {
        _vote(s, 1, ACCEPT, 120, 20);
        _appeal(dave, s);
        intake.setPrice(2e18);
        _askAppealSwarm(s); // void: lazy ask
        assertEq(uint8(_phase(s)), uint8(Phase.Decided));
        assertEq(imd.balanceOf(swarmPayee), 0);
        intake.setPrice(PRICE);
        // a second appeal of his, again out of the whole bond
        uint256 i0 = imd.balanceOf(dave);
        _appeal(dave, s);
        assertEq(imd.balanceOf(dave), i0);
        assertEq(vault.getAppeal(s).fromBond, PRICE);
        _askAppealSwarm(s); // lazy ask
        _answer(s, false);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Rejected));
        (int256 daveImd, int256 daveUsdc) = _net(dave);
        assertEq(daveImd, 0, "F - PRICE + the doer's F");
        assertEq(daveUsdc, int256(DB));
        _claimEverythingAndCheck();
    }

    /// Both sides call, the first one silent: each side's fee comes out of its own bond only.
    function test_BothSidesCall_EachPaysFromItsOwnBond() public {
        _warp(24 hours);
        vault.poke(t);
        _callSwarm(dave, s, false); // the disputer, silent
        _silent(s);
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.NoDecision));
        _callSwarm(doer, s, true); // the doer, answered: accepted
        _answer(s, true);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        assertEq(imd.balanceOf(swarmPayee), 2 * PRICE);
        (int256 doerImd, int256 doerUsdc) = _net(doer);
        (int256 daveImd, int256 daveUsdc) = _net(dave);
        // both bonds' IMD went to the swarm: nothing left in IMD for the winner
        assertEq(doerImd, -int256(F));
        assertEq(doerUsdc, int256(90e6 + SB));
        assertEq(daveImd, -int256(F));
        assertEq(daveUsdc, -int256(SB));
        _claimEverythingAndCheck();
    }

    /// Cancelled by the dev wallet after the sides' calls went silent: every bond back, minus what it
    /// already paid the swarm.
    function test_Cancel_AfterSideCalls_BondsBackMinusFees() public {
        _warp(24 hours);
        vault.poke(t);
        _callSwarm(doer, s, true);
        _silent(s);
        vault.poke(t);
        vm.prank(devWallet);
        vault.cancelTask(t);
        (int256 doerImd, int256 doerUsdc) = _net(doer);
        (int256 daveImd, int256 daveUsdc) = _net(dave);
        assertEq(doerImd, -int256(PRICE), "his bond back minus the fee it paid");
        assertEq(doerUsdc, 0);
        assertEq(daveImd, 0);
        assertEq(daveUsdc, 0);
        _claimEverythingAndCheck();
    }

    // ================================================================== a repeat call of the same side
    // The side's first call is paid out of its
    // bond; the same side calling again posts no second bond and pays the new swarm fee from its wallet.

    /// The doer calls (NFT undecided) out of his bond, silence, calls again from his wallet and wins.
    function test_RepeatCall_Doer_Wins() public {
        _warp(24 hours);
        vault.poke(t);
        uint256 i0 = imd.balanceOf(doer);
        _callSwarm(doer, s, true);
        assertEq(imd.balanceOf(doer), i0, "the first call: out of his bond");
        _silent(s);
        vault.poke(t);
        _callSwarm(doer, s, true);
        assertEq(i0 - imd.balanceOf(doer), PRICE, "the repeat call: 0.5 IMD from his wallet");
        assertEq(vault.getAppeal(s).bond.imd, 0, "no second bond");
        assertEq(vault.getAppeal(s).bond.rew, 0);
        _answer(s, true);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        assertEq(imd.balanceOf(swarmPayee), 2 * PRICE);
        (int256 doerImd, int256 doerUsdc) = _net(doer);
        (int256 daveImd, int256 daveUsdc) = _net(dave);
        // doer: F - PRICE of his bond back + dave's F (NFT undecided: 100%), the wallet's PRICE spent
        assertEq(doerImd, int256(F) - int256(PRICE) + int256(F) - int256(F) - int256(PRICE));
        assertEq(doerUsdc, int256(90e6 + SB));
        assertEq(daveImd, -int256(F));
        assertEq(daveUsdc, -int256(SB));
        _claimEverythingAndCheck();
    }

    /// The same, but the swarm rejects: the rest of his bond (F - PRICE) and its USDC part go to the disputer.
    function test_RepeatCall_Doer_Loses() public {
        _warp(24 hours);
        vault.poke(t);
        _callSwarm(doer, s, true);
        _silent(s);
        vault.poke(t);
        uint256 i0 = imd.balanceOf(doer);
        _callSwarm(doer, s, true);
        assertEq(i0 - imd.balanceOf(doer), PRICE);
        _answer(s, false);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Rejected));
        (int256 doerImd, int256 doerUsdc) = _net(doer);
        (int256 daveImd, int256 daveUsdc) = _net(dave);
        assertEq(doerImd, -int256(F + PRICE), "his bond paid the first call, his wallet the second");
        assertEq(doerUsdc, -int256(DB));
        assertEq(daveImd, int256(F - PRICE), "his bond back + the rest of the doer's IMD (F - PRICE = 0)");
        assertEq(daveUsdc, int256(DB));
        assertEq(imd.balanceOf(swarmPayee), 2 * PRICE);
        _claimEverythingAndCheck();
    }

    /// The disputer appeals the NFT's acceptance out of his bond, silence, appeals again from his wallet and wins.
    function test_RepeatCall_Disputer_Wins() public {
        _vote(s, 1, ACCEPT, 120, 20);
        uint256 i0 = imd.balanceOf(dave);
        _appeal(dave, s);
        _askAppealSwarm(s); // lazy ask
        _silent(s);
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.Decided));
        assertEq(imd.balanceOf(dave), i0);
        _appeal(dave, s);
        assertEq(i0 - imd.balanceOf(dave), PRICE, "the repeat appeal: 0.5 IMD from his wallet");
        assertEq(vault.getAppeal(s).fromBond, 0);
        assertEq(vault.getAppeal(s).funds, PRICE);
        _askAppealSwarm(s); // lazy ask
        _answer(s, false);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Rejected));
        (int256 daveImd, int256 daveUsdc) = _net(dave);
        (int256 doerImd, int256 doerUsdc) = _net(doer);
        // dave: F - PRICE of his bond back + the doer's F (NFT wrong: 100%), his wallet's PRICE spent
        assertEq(daveImd, int256(F) - 2 * int256(PRICE));
        assertEq(daveUsdc, int256(DB));
        assertEq(doerImd, -int256(F));
        assertEq(doerUsdc, -int256(DB));
        _claimEverythingAndCheck();
    }

    /// The disputer's repeat appeal loses: his wallet's fee is gone, the rest of his bond goes to the doer.
    function test_RepeatCall_Disputer_Loses() public {
        _vote(s, 1, ACCEPT, 120, 20);
        _appeal(dave, s);
        _askAppealSwarm(s); // lazy ask
        _silent(s);
        vault.poke(t);
        _appeal(dave, s);
        _askAppealSwarm(s); // lazy ask
        _answer(s, true);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        (int256 daveImd, int256 daveUsdc) = _net(dave);
        (int256 doerImd, int256 doerUsdc) = _net(doer);
        assertEq(daveImd, -int256(F + PRICE));
        assertEq(daveUsdc, -int256(SB));
        assertEq(doerImd, 0, "his bond back; dave's IMD left with the first fee");
        assertEq(doerUsdc, int256(90e6 + SB / 2), "90% of R + half of dave's SB (NFT right)");
        _claimEverythingAndCheck();
    }

    /// The swarm costs less than the bond's IMD: the bond pays the first call only; the rest of it stays in the
    /// bond, the repeat calls (up to the limit of 3) are paid from the wallet.
    function test_RepeatCall_CheaperThanBond_ThreeCalls() public {
        uint256 fee = 0.3e18;
        intake.setPrice(fee);
        _warp(24 hours);
        vault.poke(t);
        uint256 i0 = imd.balanceOf(doer);
        for (uint256 i; i < 3; ++i) {
            _callSwarm(doer, s, true);
            assertEq(i0 - imd.balanceOf(doer), i * fee, "first from the bond, then the wallet");
            if (i < 2) {
                _silent(s);
                vault.poke(t);
                assertEq(uint8(_phase(s)), uint8(Phase.NoDecision));
            }
        }
        assertEq(_sub(s).asks, 3);
        _answer(s, true);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        assertEq(imd.balanceOf(swarmPayee), 3 * fee);
        (int256 doerImd, int256 doerUsdc) = _net(doer);
        // his bond back minus the first fee (0.2 IMD), dave's F, two fees from his wallet
        assertEq(doerImd, int256(F - fee) + int256(F) - int256(F) - 2 * int256(fee));
        assertEq(doerUsdc, int256(90e6 + SB));
        (int256 daveImd,) = _net(dave);
        assertEq(daveImd, -int256(F));
        _claimEverythingAndCheck();
    }

    /// Each side's first call comes out of its own bond, whoever called before: the doer after the disputer's
    /// silent call still pays from his bond; the disputer calling again pays from his wallet.
    function test_RepeatCall_EachSideOwnFirst() public {
        _warp(24 hours);
        vault.poke(t);
        _callSwarm(dave, s, false); // dave's first: his bond
        _silent(s);
        vault.poke(t);
        uint256 doer0 = imd.balanceOf(doer);
        _callSwarm(doer, s, true); // the doer's first: his bond
        assertEq(imd.balanceOf(doer), doer0);
        _silent(s);
        vault.poke(t);
        uint256 dave0 = imd.balanceOf(dave);
        _callSwarm(dave, s, false); // dave's second: his wallet
        assertEq(dave0 - imd.balanceOf(dave), PRICE);
        _answer(s, false);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Rejected));
        (int256 daveImd, int256 daveUsdc) = _net(dave);
        (int256 doerImd, int256 doerUsdc) = _net(doer);
        // dave: F - PRICE of his bond back, nothing of the doer's IMD (F - PRICE = 0: it paid the doer's call), his
        // wallet's PRICE spent
        assertEq(daveImd, -2 * int256(PRICE));
        assertEq(daveUsdc, int256(DB));
        assertEq(doerImd, -int256(F));
        assertEq(doerUsdc, -int256(DB));
        assertEq(imd.balanceOf(swarmPayee), 3 * PRICE);
        _claimEverythingAndCheck();
    }

    /// view sideSpent: what each side's own bond already paid the swarm (reaudit logic #5). A void call spends
    /// nothing, a repeat call from the wallet does not count, a stranger's call never does.
    function test_SideSpent_View() public {
        _warp(24 hours);
        vault.poke(t);
        assertEq(vault.sideSpent(s).doer, 0);
        assertEq(vault.sideSpent(s).disputer, 0);
        _callSwarm(dave, s, false); // the disputer's first: his bond
        assertEq(vault.sideSpent(s).disputer, PRICE);
        assertEq(vault.sideSpent(s).doer, 0);
        _silent(s);
        vault.poke(t);
        _callSwarm(doer, s, true); // the doer's first: his bond
        assertEq(vault.sideSpent(s).doer, PRICE);
        _silent(s);
        vault.poke(t);
        _callSwarm(dave, s, false); // the disputer's second: his wallet, the bond spends no more
        assertEq(vault.sideSpent(s).disputer, PRICE);
        assertEq(vault.sideSpent(s).doer, PRICE);
        _answer(s, false);
        vault.poke(t);
        assertEq(vault.sideSpent(s).disputer, PRICE, "kept after settlement");
        _claimEverythingAndCheck();
    }
}
