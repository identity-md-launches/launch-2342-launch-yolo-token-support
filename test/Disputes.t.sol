// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./Base.t.sol";

/// @dev Disputes, NFT votes, decisions, paid swarm calls without an NFT decision, appeals, swarm silence, the doer
/// stake bonus and the burn.
/// Standard case: USDC task R = 100. No oracle, no USD floor. Every
/// bond is 0.5 IMD fixed (`F`) plus a percent of R in USDC itself: the doer bond's percent part is `DB` = 3%
/// of 100 USDC = 3 USDC, the dispute bond's is `SB` = 1% = 1 USDC. Swarm fee 0.5 IMD (`PRICE`, Base.t.sol).
/// No ETH dispute fee (the disputer and every NFT voter pay their own gas, nobody is
/// reimbursed). Rules: the loser bond, separately in each currency (IMD, USDC), goes
/// 50/50 to the winning side and the NFT votes on the final side when the NFT decided right, all of it to the
/// winners otherwise (no separate swarm-fee refund); NFT undecided and nobody called the swarm:
/// accepted, the disputer bonds 100% to the doer. At most 3 swarm questions per submission: after the third
/// silence it ends as if nobody had called.
/// Fee 10%: 5% to correct NFT votes (else the treasury) + 5% stakers' part (the treasury without a stake); a doer
/// whose $YOLO lock (YoloLockHub) had any power P at his submission and still runs at the payout gets
/// b = 4% x min(1, P / R in $YOLO) of R from the stakers' 5%, the rest of it half burns, half treasury, and the
/// NFT 5% nobody earned burns too.
/// forge-config: default.isolate = false
contract DisputesTest is Base {
    uint8 internal constant ACCEPT = 1;
    uint8 internal constant REJECT = 2;
    /// @dev the fixed IMD part of every bond: never doubled, same for the doer and dispute bond.
    uint256 internal constant F = 0.5e18;
    /// @dev doer bond's percent part: 3% of R = 100 USDC, in USDC itself.
    uint256 internal constant DB = 3e6;
    /// @dev dispute bond's percent part: 1% of R = 100 USDC, in USDC itself (never doubled).
    uint256 internal constant SB = 1e6;

    uint256 internal t;
    uint256 internal s;

    function setUp() public override {
        super.setUp();
        t = _create(author, address(usdc), 100e6);
        s = _submit(doer, t);
        assertEq(_sub(s).bond.imd, F, "doer bond: 0.5 IMD fixed");
        assertEq(_sub(s).bond.rew, DB, "doer bond: 3% of R, in USDC");
        Bond memory db = vault.quoteDisputeBond(s);
        assertEq(db.imd, F, "dispute bond: 0.5 IMD fixed");
        assertEq(db.rew, SB, "dispute bond: 1% of R, in USDC");
    }

    /// @dev Claims `who`'s disputer bond of `s` (harmless no-op if he never disputed or already claimed), then his
    /// net IMD and USDC gain since setUp's funding, after withdrawing both credits.
    function _gains(address who) internal returns (int256 imdGain, int256 usdcGain) {
        return _gains(who, s);
    }

    /// @dev Same as `_gains(address)`, claiming `who`'s disputer bond of `subId` instead of the shared `s`.
    function _gains(address who, uint256 subId) internal returns (int256 imdGain, int256 usdcGain) {
        vm.prank(who);
        try vault.claimDisputer(subId) {} catch {}
        vm.startPrank(who);
        if (vault.credits(address(imd), who) != 0) vault.withdraw(address(imd));
        if (vault.credits(address(usdc), who) != 0) vault.withdraw(address(usdc));
        vm.stopPrank();
        imdGain = int256(imd.balanceOf(who)) - int256(10_000e18);
        usdcGain = int256(usdc.balanceOf(who)) - int256(1_000_000e6);
    }

    // ================================================================== NFT decides

    function test_Dispute_NftRejects_BondSplit5050() public {
        _dispute(dave, s); // one dispute, one disputer
        assertEq(uint8(_phase(s)), uint8(Phase.Voting));
        _vote(s, 1, REJECT, 120, 20); // = instantDelta: decides at once
        assertEq(uint8(_phase(s)), uint8(Phase.Decided));
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Rejected));
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Open));
        assertEq(vault.getTask(t).rejectedCount, 1);
        assertEq(vault.getTask(t).pot, 100e6); // the reward stays in the task, never to the disputers

        // doer bond penalty: F (IMD) and DB (USDC), nftRight (winnerBondBps 50%): half to dave (the one disputer),
        // half to the 20 correct NFT votes; dave also gets his own bond back, so his net gain is only his half-
        // share: F/2 (IMD), DB/2 (USDC)
        (int256 daveImd, int256 daveUsdc) = _gains(dave);
        assertEq(daveImd, int256(F / 2));
        assertEq(daveUsdc, int256(DB / 2));
        assertEq(vault.credits(address(imd), doer), 0);
        vault.claimVoterReward(s, voters[1]);
        assertEq(imd.balanceOf(voters[1]) - 10_000e18, F / 2);
        assertEq(usdc.balanceOf(voters[1]) - 1_000_000e6, DB / 2, "no fee on a rejection, only the bond share");
        assertEq(dave.balance, 100 ether); // dispute pot fully back (no gas price in this test)
        _claimEverythingAndCheck();
    }

    /// @dev The fee split is 5/5: 5% to the votes, 5% to the treasury.
    function test_Dispute_NftAccepts_Fee5To5_Bond5050() public {
        _dispute(dave, s); // one dispute, one disputer
        _vote(s, 1, ACCEPT, 120, 20);
        _warp(48 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        // the doer wins: his own bond back in full (DB, F), plus 50% of dave's (the loser's) forfeited bond -
        // dave's bond is SB (1%) / F (IMD), so the penalty pool is SB (USDC) and F (IMD).
        assertEq(vault.credits(address(usdc), doer), 90e6 + DB + SB / 2, "reward 90% + own bond + 50% of dave's bond");
        assertEq(vault.credits(address(imd), doer), F + F / 2); // own bond + 50% of dave's bond
        // accepted after a dispute the NFT decided right: 5% to the correct votes, 5% to the treasury
        assertEq(vault.treasuryPot(address(usdc)), 5e6);
        assertEq(vault.getSettlement(s).voterFee, 5e6);
        assertEq(vault.getSettlement(s).stakeBps, 0);
        // voters[1] cast every vote (120 accept vs 20 reject is all him): he gets the whole voter share of dave's
        // forfeited bond (50% of F IMD, 50% of SB USDC), plus the reward's 5% NFT fee.
        vault.claimVoterReward(s, voters[1]);
        assertEq(imd.balanceOf(voters[1]) - 10_000e18, F / 2, "bond share");
        assertEq(usdc.balanceOf(voters[1]) - 1_000_000e6, SB / 2 + 5e6, "bond share + the reward's fee share");
        vm.expectRevert(NothingToClaim.selector);
        vault.claimVoterReward(s, voters[1]);
        (int256 daveImd, int256 daveUsdc) = _gains(dave);
        assertEq(daveImd, -int256(F));
        assertEq(daveUsdc, -int256(SB));
        _claimEverythingAndCheck();
    }

    function test_ClaimsPlayTimersThemselves_NoPokeNeeded() public {
        _dispute(dave, s);
        _vote(s, 1, REJECT, 120, 20);
        _warp(48 hours); // nobody poked: vote end and appeal window passed
        // dave's own dispute bond (F, SB) back, plus the whole doer-bond penalty split 50/50 (he is the only
        // disputer): F/2 (IMD) and DB/2 (USDC)
        vm.expectEmit(address(disputeDesk));
        emit DisputerClaimed(s, dave, F + F / 2, SB + DB / 2);
        vm.prank(dave);
        vault.claimDisputer(s);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Rejected));
        vault.claimVoterReward(s, voters[1]);
        assertFalse(vault.hasVoted(s, voters[0]));
        assertTrue(vault.hasVoted(s, voters[1]));
        _claimEverythingAndCheck();
    }

    /// @dev A partial count under `instantDelta` does not decide, but once a side is ahead by
    /// >= instantDelta the submission decides at once (NftDecided.instant = true), without waiting for the
    /// vote end.
    function test_InstantDecision_FiresOnceTheDeltaIsCrossed() public {
        _dispute(dave, s);
        _vote(s, 2, ACCEPT, 140, 10); // 10 < instantDelta (20): no decision yet
        _vote(s, 3, ACCEPT, 150, 5); // 15
        _vote(s, 4, ACCEPT, 155, 2); // 17
        assertEq(uint8(_phase(s)), uint8(Phase.Voting), "no decision below instantDelta");
        assertEq(_sub(s).decidedAt, 0);
        _vote(s, 0, ACCEPT, 0, 120); // 137: crosses instantDelta, decides at once
        assertEq(uint8(_phase(s)), uint8(Phase.Decided));
        assertEq(_sub(s).decidedAt, _now());
        assertEq(_sub(s).callFrom, _now());
        // voting is closed once decided, even before the vote end
        vm.prank(voters[1]);
        vm.expectRevert(WrongPhase.selector);
        vault.vote(s, REJECT, voters[1], held[voters[1]]);
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        _claimEverythingAndCheck();
    }

    /// @dev An NFT tie, nobody calls: the
    /// tie is the general rule "NFT undecided: everything to the winning side": all of it to the doer.
    function test_NoDecision_NobodyCalls_Accepted_DisputerBondsAllToDoer() public {
        _dispute(dave, s); // one dispute, one disputer
        // reject first so the running delta never reaches instantDelta (20) before the final 20 vs 12
        _vote(s, 2, REJECT, 140, 10);
        _vote(s, 4, REJECT, 155, 2);
        _vote(s, 1, ACCEPT, 120, 20); // 20 vs 12: delta 8
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.NoDecision));
        assertEq(_sub(s).callFrom, _sub(s).voteEnd);
        _warp(24 hours - 1);
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.NoDecision));
        _warp(1);
        vault.poke(t);
        // nobody called the swarm: accepted; dave's disputer bond (F IMD, SB USDC) to the doer; fee all treasury
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Completed));
        assertFalse(vault.getSettlement(s).neutral);
        assertEq(vault.credits(address(usdc), doer), 90e6 + DB + SB, "reward + own bond + dave's disputer bond");
        assertEq(vault.credits(address(imd), doer), F + F);
        assertEq(vault.treasuryPot(address(usdc)), 10e6);
        assertEq(vault.treasuryPot(address(imd)), 0, "nothing of the bonds to the treasury");
        (int256 daveImd, int256 daveUsdc) = _gains(dave);
        assertEq(daveImd, -int256(F));
        assertEq(daveUsdc, -int256(SB));
        (int256 doerImd, int256 doerUsdc) = _gains(doer);
        assertEq(doerImd, int256(F));
        assertEq(doerUsdc, int256(90e6 + SB));
        assertEq(dave.balance, 100 ether); // dispute pot back
        vm.expectRevert(NothingToClaim.selector); // the NFT did not decide: votes are not looked at
        vault.claimVoterReward(s, voters[1]);
        _claimEverythingAndCheck();
    }

    function test_DisputeWindowClosedAndLimits() public {
        _warp(24 hours);
        vm.prank(dave);
        vm.expectRevert(WrongPhase.selector); // accepted by the lazy timer first
        vault.dispute(s, "r", "rp", _noSwap());

        uint256 t2 = _create(author, address(usdc), 100e6);
        uint256 s2 = _submit(doer2, t2);
        _warp(1 hours); // the vote (24h from the first dispute) outlives the dispute window (24h from activation)
        vm.startPrank(dave);
        vault.dispute(s2, "r", "rp", _noSwap());
        vm.expectRevert(AlreadyDisputed.selector);
        vault.dispute(s2, "r", "rp", _noSwap());
        vm.stopPrank();
        // one dispute, one disputer - a second disputer is rejected even while
        // the dispute window is still open and voting runs, not just once the window later closes.
        _warp(22 hours);
        vm.prank(erin);
        vm.expectRevert(AlreadyDisputed.selector);
        vault.dispute(s2, "r", "rp", _noSwap());
        _warp(1 hours);
        vm.prank(bob);
        vm.expectRevert(WindowClosed.selector); // now the window itself is closed too
        vault.dispute(s2, "r", "rp", _noSwap());
    }

    /// @dev No "doer answers the dispute" step - his "why honest" text
    /// goes into Evidence.note at submission time (Submission.doerNote), read by the question builder directly.
    function test_DoerReply() public {
        _dispute(dave, s);
        assertEq(_sub(s).doerNote, "", "no note was attached at submission in this test's _submit helper");
        uint256 t2 = _create(author, address(usdc), 100e6);
        vm.prank(doer2);
        uint256 s2 = vault.submit(
            t2, "https://x.com/doer/status/1", Evidence("", "ipfs://my-answer"), 0, type(uint256).max, _noSwap()
        );
        _dispute(dave, s2);
        assertEq(_sub(s2).doerNote, "ipfs://my-answer", "his 'why honest' text, attached at submission");
    }

    // ================================================================== contributors in the case

    /// a disputer who is also a contributor (here: topped up the task's reward) is treated like
    /// any other disputer, his pro-rata share included (no redirect to the correct votes).
    /// @dev one dispute, one disputer - alice (a contributor) disputes alone and
    /// gets her full pro-rata share like any other disputer,
    /// not limited to her own bond the way a contributor doer/appellant-caller would be.
    function test_ContributorDisputerWins_SameShareAsAnyDisputer() public {
        _topUp(alice, t, 10e6); // pending, but alice is a contributor of this task now
        _dispute(alice, s);
        _vote(s, 1, REJECT, 120, 20);
        _warp(48 hours);
        vault.poke(t);
        // doer bond penalty F (IMD) / DB (USDC): half to the votes outright, half to alice (the one disputer).
        assertEq(vault.getSettlement(s).voterBond.imd, F / 2);
        assertEq(vault.getSettlement(s).voterBond.rew, DB / 2);
        (int256 aliceImd, int256 aliceUsdc) = _gains(alice);
        assertEq(aliceImd, int256(F / 2));
        // her 10e6 top-up (locked until the task's deadline; returned at once only if THIS
        // submission is accepted) stays locked in the still-open task, since this submission was rejected.
        assertEq(aliceUsdc, int256(DB / 2) - 10e6);
        vault.claimVoterReward(s, voters[1]);
        assertEq(imd.balanceOf(voters[1]) - 10_000e18, F / 2);
        assertEq(usdc.balanceOf(voters[1]) - 1_000_000e6, DB / 2);
        _claimEverythingAndCheck();
    }

    /// A doer who put money into the task
    /// (here its author) and wins the dispute gets his share of the loser's bond like any winner. NFT right: half of
    /// dave's bond to him, half to the votes, in each currency.
    function test_ContributorDoerWins_GetsHisShareLikeAnyWinner() public {
        uint256 t2 = _create(author, address(usdc), 100e6);
        uint256 s2 = _submit(author, t2); // the author submits to his own task
        _dispute(dave, s2);
        _vote(s2, 1, ACCEPT, 120, 20);
        _warp(48 hours);
        vault.poke(t2);
        assertEq(uint8(_sub(s2).outcome), uint8(Outcome.Accepted));
        assertEq(vault.credits(address(imd), author), F + F / 2, "own bond + half of dave's 0.5 IMD");
        assertEq(vault.credits(address(usdc), author), 90e6 + DB + SB / 2, "90% + own bond + half of dave's 1%");
        assertEq(vault.getSettlement(s2).voterBond.imd, F / 2, "the votes: the other half");
        assertEq(vault.getSettlement(s2).voterBond.rew, SB / 2);
        _claimEverythingAndCheck();
    }

    /// An appellant who contributed to the task (after appealing, too) and wins gets his share of the loser's
    /// bond like any winner: NFT wrong (rejected, the swarm accepted) -> all of dave's bond to the winners, alice as
    /// a stranger appellant takes 0.5 IMD off the top, the 1% leg pro rata to bonds: alice 1 of 4 -> 0.25 USDC.
    function test_ContributorAppellantWins_GetsHisShareLikeAnyWinner() public {
        _dispute(dave, s);
        _vote(s, 1, REJECT, 120, 20);
        _endVote(s);
        _appeal(alice, s); // stands for the doer against the NFT's "reject"
        _topUp(alice, t, 5e6); // and puts money into the task: in the reward at once, R = 105
        _askAppealSwarm(s); // lazy ask
        _answer(s, true); // the swarm: accepted, the NFT were wrong
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        assertEq(vault.credits(address(usdc), alice), SB + SB / 4, "own 1% bond + her pro-rata quarter of dave's");
        assertEq(vault.credits(address(imd), alice), F + F, "own 0.5 IMD + the stranger 0.5 IMD off the top");
        assertEq(
            vault.credits(address(usdc), doer),
            94.5e6 + DB + SB * 3 / 4,
            "the doer: 90% of 105 + the other three quarters"
        );
        assertEq(vault.treasuryPot(address(usdc)), 10.5e6, "only the 10% fee (NFT wrong): no redirect of her share");
        _claimEverythingAndCheck();
    }

    /// becoming a contributor after disputing changes nothing; dave is the only
    /// disputer, so he gets the whole winner's half of the penalty, same as before he topped up.
    function test_DisputerWhoTopsUpLater_StillGetsHisFullShare() public {
        _dispute(dave, s);
        _topUp(dave, t, 1e6); // becomes a contributor after disputing
        _vote(s, 1, REJECT, 120, 20);
        _warp(48 hours);
        vault.poke(t);
        (int256 daveImd, int256 daveUsdc) = _gains(dave);
        assertEq(daveImd, int256(F / 2));
        // his 1e6 top-up stays locked in the still-open task: this submission was rejected.
        assertEq(daveUsdc, int256(DB / 2) - 1e6);
        assertEq(vault.treasuryPot(address(imd)), 0, "nothing redirected to the treasury");
        assertEq(vault.treasuryPot(address(usdc)), 0);
        _claimEverythingAndCheck();
    }

    // ================================================================== NFT undecided: anyone calls the swarm, paying

    /// no separate fee refund; the caller's pro-rata share of the penalty is his only
    /// return. one dispute, one disputer; bob the caller is a stranger (not the
    /// doer, not dave the disputer), so he also gets 0.5 IMD off the top of the imd-leg penalty first.
    function test_NoDecision_CallSwarm_Rejects_CallerGetsOnlyHisShare() public {
        _dispute(dave, s);
        _vote(s, 3, REJECT, 150, 5); // delta 5 < 10
        _warp(24 hours);
        uint256 bobBefore = imd.balanceOf(bob);
        uint256 bobUsdcBefore = usdc.balanceOf(bob);
        _callSwarm(bob, s); // advances to NoDecision, then asks at once
        assertEq(uint8(_phase(s)), uint8(Phase.Asked));
        assertEq(bobBefore - imd.balanceOf(bob), F + PRICE); // dispute bond's fixed part + fee
        assertEq(bobUsdcBefore - usdc.balanceOf(bob), SB); // dispute bond's percent part, in USDC
        assertEq(imd.balanceOf(swarmPayee), PRICE);
        Appeal memory a = vault.getAppeal(s);
        assertEq(a.appellant, bob);
        assertFalse(a.sidesDoer);
        assertEq(a.spent, PRICE);
        _answer(s, false);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Rejected));
        // imd-leg penalty = doer bond F, minus bob's stranger-appellant carve-out (0.5 IMD = F here), the rest
        // (F - F = 0) split between bob and dave pro rata; rew-leg penalty DB has no stranger carve-out (0.5
        // IMD only ever comes from the imd leg), split pro rata between bob and dave (equal bonds).
        uint256 bobPartUsdc = DB * SB / (2 * SB);
        assertEq(
            vault.credits(address(imd), bob),
            F /* stranger carve-out */ + F,
            /* his own bond back */
            "his stranger fee + his own bond back"
        );
        assertEq(vault.credits(address(usdc), bob), bobPartUsdc + SB, "his share + his own bond back");
        assertEq(vault.treasuryPot(address(imd)), 0);
        assertEq(vault.treasuryPot(address(usdc)), 0);
        assertEq(vault.credits(address(imd), doer), 0);
        (int256 daveImd, int256 daveUsdc) = _gains(dave);
        assertEq(daveImd, 0, "nothing left of the imd-leg penalty after bob's stranger carve-out");
        assertEq(daveUsdc, int256(DB - bobPartUsdc));
        vm.expectRevert(NothingToClaim.selector); // NFT undecided: no voter reward
        vault.claimVoterReward(s, voters[3]);
        _claimEverythingAndCheck();
    }

    /// @dev one dispute, one disputer; dave calls the swarm himself, so he is not a stranger appellant (he is
    /// already the disputer) - no 0.5 IMD carve-out, his pro-rata share covers both his roles' bonds.
    function test_NoDecision_CallSwarm_Accepts_CallerLosesBondAndFee() public {
        _dispute(dave, s);
        _warp(24 hours); // nobody voted
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.NoDecision));
        uint256 i0 = imd.balanceOf(dave);
        _callSwarm(dave, s); // the disputer calls for his own side: out of his bond
        assertEq(imd.balanceOf(dave), i0);
        _answer(s, true);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        // loser: dave's bond minus the fee it paid (0 IMD / SB), all to the doer (NFT undecided)
        assertEq(vault.credits(address(imd), doer), F);
        assertEq(vault.credits(address(usdc), doer), 90e6 + DB + SB);
        assertEq(vault.treasuryPot(address(imd)), 0);
        assertEq(vault.treasuryPot(address(usdc)), 10e6, "the reward's fee: NFT undecided, all to the treasury");
        (int256 daveImd, int256 daveUsdc) = _gains(dave);
        assertEq(daveImd, -int256(F), "his bond: PRICE of it to the swarm, the rest to the doer");
        assertEq(daveUsdc, -int256(SB));
        _claimEverythingAndCheck();
    }

    /// @dev Since the undecided rule pays the doer everything anyway, his own call only moves the fee. the doer
    /// is never a stranger appellant, so
    /// there is no 0.5 IMD carve-out here - he just gets both his own bonds back plus dave's forfeited one.
    function test_NoDecision_DoerCallsSwarm_Confirmed() public {
        _dispute(dave, s);
        _warp(24 hours);
        uint256 i0 = imd.balanceOf(doer);
        uint256 u0 = usdc.balanceOf(doer);
        _callSwarm(doer, s, true);
        assertTrue(vault.getAppeal(s).sidesDoer);
        assertEq(imd.balanceOf(doer), i0, "no second bond, the fee out of their doer bond");
        assertEq(usdc.balanceOf(doer), u0);
        _answer(s, true);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        // dave's bond F / SB (the only loser), all to the doer (NFT undecided), on top of what is left of his own
        // bond (F - PRICE = 0 IMD, DB)
        assertEq(vault.credits(address(imd), doer), F, "dave's whole F: it covers the doer's fee");
        assertEq(vault.credits(address(usdc), doer), 90e6 + DB + SB, "reward + own doer bond + dave's whole bond");
        (int256 doerImd,) = _gains(doer);
        assertEq(doerImd, int256(F) - int256(PRICE), "his call fee is spent, never refunded");
        _claimEverythingAndCheck();
    }

    function test_NoDecision_DoerCallsSwarm_Rejected() public {
        _dispute(dave, s);
        _warp(24 hours);
        uint256 i0 = imd.balanceOf(doer);
        _callSwarm(doer, s, true);
        assertEq(imd.balanceOf(doer), i0, "the doer calls for themselves out of their doer bond");
        _answer(s, false);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Rejected));
        // loser: the doer bond minus the fee it paid (0 IMD / DB), all to dave (NFT undecided)
        (int256 daveImd, int256 daveUsdc) = _gains(dave);
        (int256 doerImd, int256 doerUsdc) = _gains(doer);
        assertEq(daveImd, 0);
        assertEq(daveUsdc, int256(DB));
        assertEq(doerImd, -int256(F));
        assertEq(doerUsdc, -int256(DB));
        _claimEverythingAndCheck();
    }

    /// @dev The general rule: all to the doer.
    function test_NoDecision_SilentStatus2_NobodyCallsAgain_GeneralRule() public {
        _dispute(dave, s);
        _warp(24 hours);
        _callSwarm(erin, s);
        _warp(1 hours);
        _silent(s); // status 2: no callback, the Intake reports the request completed
        vault.poke(t);
        // back to the undecided state at once, a new window from the moment of silence; erin's bond is hers
        assertEq(uint8(_phase(s)), uint8(Phase.NoDecision));
        assertEq(_sub(s).callFrom, _now());
        assertEq(vault.credits(address(imd), erin), F);
        assertEq(vault.credits(address(usdc), erin), SB);
        assertEq(vault.getAppeal(s).appellant, address(0));
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        (int256 daveImd, int256 daveUsdc) = _gains(dave);
        (int256 erinImd, int256 erinUsdc) = _gains(erin);
        assertEq(daveImd, -int256(F)); // all of it to the doer
        assertEq(daveUsdc, -int256(SB));
        assertEq(erinImd, -int256(PRICE)); // only her fee is lost (her side lost: not refunded, bond fully back)
        assertEq(erinUsdc, 0);
        assertEq(vault.credits(address(imd), doer), F + F);
        assertEq(vault.credits(address(usdc), doer), 90e6 + DB + SB);
        assertEq(vault.treasuryPot(address(imd)), 0);
        _claimEverythingAndCheck();
    }

    function test_NoDecision_SilentTimeout_WindowFromSilence() public {
        _dispute(dave, s);
        _warp(24 hours);
        _callSwarm(erin, s);
        uint256 askedAt = _now();
        // silence only after the timeout and the delivery grace (swarm audit 117cf05a #7)
        _warp(6 hours + SWARM_DELIVERY_GRACE - 1);
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.Asked));
        _warp(1);
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.NoDecision));
        assertEq(_sub(s).callFrom, askedAt + 6 hours + SWARM_DELIVERY_GRACE);
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        _claimEverythingAndCheck();
    }

    /// no separate fee refund, in call order or otherwise. Every call's fee is simply
    /// spent; the penalty splits pro-rata among the winners (dave the disputer, erin's first silent call does not
    /// count as a winner once a later caller, bob, gets the real answer: only the answered caller and the
    /// disputer(s) share the penalty).
    function test_NoDecision_Silent_CalledAgain_Answers_NoFeeRefund() public {
        _dispute(dave, s);
        _warp(24 hours);
        _callSwarm(erin, s);
        bytes32 first = _sub(s).request;
        _warp(6 hours + 23 hours); // timeout, then inside the new window
        _callSwarm(bob, s);
        assertEq(_sub(s).asks, 2);
        assertTrue(_sub(s).request != first);
        _answer(s, false);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Rejected));
        // bob is a stranger caller (not the doer, not dave the disputer), so he gets 0.5 IMD (= F here) off
        // the top of the imd-leg penalty (F = dave's dispute bond) first - consuming it entirely, leaving dave's
        // imd-leg disputer claim at 0. The rew leg (DB) has no such carve-out: split pro rata between dave and bob
        // (equal bonds, half each). Erin's silent call lost nothing but her fee (her bond came back at the
        // silence); bob's fee is simply spent, not refunded from the penalty.
        assertEq(
            vault.credits(address(imd), bob),
            F /* stranger carve-out */ + F,
            /* his own bond back */
            "stranger fee + own bond"
        );
        assertEq(vault.credits(address(imd), erin), F); // her bond back at the silence; her fee was simply spent
        assertEq(vault.credits(address(usdc), erin), SB); // her bond's percent part, back at the silence
        (int256 daveImd, int256 daveUsdc) = _gains(dave);
        (int256 erinImd, int256 erinUsdc) = _gains(erin);
        (int256 bobImd, int256 bobUsdc) = _gains(bob);
        assertEq(daveImd, 0, "bob's stranger carve-out took the whole imd-leg penalty");
        assertEq(daveUsdc, int256(DB / 2));
        assertEq(erinImd, -int256(PRICE), "her fee is simply spent, not refunded");
        assertEq(erinUsdc, 0);
        assertEq(bobImd, int256(F) - int256(PRICE), "his stranger carve-out minus his own fee");
        assertEq(bobUsdc, int256(DB / 2));
        assertEq(imd.balanceOf(swarmPayee), 2 * PRICE);
        _claimEverythingAndCheck();
    }

    /// @dev At
    /// most MAX_SWARM_CALLS (3) questions per submission: the third silence ends it as if nobody had called
    /// (NFT undecided: accepted, the disputer bond to the doer); a fourth call is impossible.
    function test_SilenceLoop_ThirdSilenceEndsTheCase() public {
        assertEq(MAX_SWARM_CALLS, 3);
        _dispute(dave, s);
        _warp(24 hours);
        for (uint256 i; i < 3; ++i) {
            _callSwarm(erin, s);
            _silent(s);
            vault.poke(t);
            if (i < 2) assertEq(uint8(_phase(s)), uint8(Phase.NoDecision));
        }
        assertEq(_sub(s).asks, 3);
        assertEq(uint8(_phase(s)), uint8(Phase.Final), "the third silence closes at once");
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        vm.prank(erin);
        vm.expectRevert(WrongPhase.selector);
        vault.callSwarm(s, false, type(uint256).max, _noSwap(), _genericRuleTexts());
        assertEq(imd.balanceOf(swarmPayee), 3 * PRICE);
        assertEq(vault.credits(address(imd), erin), 3 * F); // three bonds back (fixed part)
        assertEq(vault.credits(address(usdc), erin), 3 * SB); // three bonds back (percent part)
        assertEq(vault.credits(address(imd), doer), F + F, "dave's bond to the doer");
        assertEq(vault.credits(address(usdc), doer), 90e6 + SB + DB, "reward + dave's bond share + the doer's own back");
        (int256 erinImd, int256 erinUsdc) = _gains(erin);
        assertEq(erinImd, -int256(3 * PRICE), "her side lost: no fee back");
        assertEq(erinUsdc, 0, "every one of her three bonds came back in full");
        _claimEverythingAndCheck();
    }

    function test_NoDecision_CallAfterWindow_Reverts() public {
        _dispute(dave, s);
        _warp(48 hours);
        vm.prank(erin);
        vm.expectRevert(WrongPhase.selector); // the lazy timer accepts the submission first
        vault.callSwarm(s, false, type(uint256).max, _noSwap(), _genericRuleTexts());
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        _claimEverythingAndCheck();
    }

    function test_CallSwarm_ActionNotSold_DefaultStands() public {
        _dispute(dave, s);
        _warp(24 hours);
        intake.setPrice(0); // priceOf returns 0: the Intake does not sell the action
        vm.prank(erin);
        vm.expectRevert(ActionNotSold.selector);
        vault.callSwarm(s, false, type(uint256).max, _noSwap(), _genericRuleTexts());
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        _claimEverythingAndCheck();
    }

    /// no fee refund (`intake.setPrice` only shows the swarm fee itself is unaffected by
    /// the bond, which stays the one fixed at submission).
    function test_CallSwarm_LowerPrice_NoFeeRefund() public {
        _dispute(dave, s);
        _warp(24 hours);
        intake.setPrice(0.2e18); // the bond stays the one fixed at submission: no oracle, no live price involved
        _callSwarm(erin, s);
        _answer(s, false);
        vault.poke(t);
        // erin is a stranger caller (not the doer, not dave the disputer), so she gets 0.5 IMD (= F here) off
        // the top of the imd-leg penalty (F = dave's dispute bond) first - consuming it entirely here, leaving
        // dave's imd-leg disputer claim at 0. The rew leg (DB) has no such carve-out: split pro rata between
        // dave and erin (equal bonds, half each).
        assertEq(
            vault.credits(address(imd), erin),
            F /* stranger carve-out */ + F,
            /* her own bond back */
            "stranger fee + own bond"
        );
        assertEq(vault.credits(address(usdc), erin), SB + DB / 2, "own bond + her rew-leg share");
        (int256 daveImd, int256 daveUsdc) = _gains(dave);
        assertEq(daveImd, 0, "erin's stranger carve-out took the whole imd-leg penalty");
        assertEq(daveUsdc, int256(DB / 2));
        _claimEverythingAndCheck();
    }

    function test_CallSwarm_WrongPhase() public {
        vm.expectRevert(WrongPhase.selector);
        vault.callSwarm(s, false, type(uint256).max, _noSwap(), _genericRuleTexts());
        _dispute(dave, s);
        vm.expectRevert(WrongPhase.selector); // still voting
        vault.callSwarm(s, false, type(uint256).max, _noSwap(), _genericRuleTexts());
    }

    // ================================================================== every fee of the winning side back

    /// no fee refund, in call order or otherwise. Two silent calls and an answered one,
    /// all for the disputers' side: every fee is simply spent; the penalty splits pro rata only between dave (the
    /// disputer) and erin (the final, answered, winning caller) - a silent call's bond comes back at the silence,
    /// nothing more.
    function test_SwarmFees_NoRefund_TwoSilencesThenAnswer() public {
        uint256 DB2 = 30e6; // doer bond's percent part: 3% of R = 1,000 USDC
        uint256 SB2 = 10e6; // dispute bond's percent part: 1% of R
        uint256 t2 = _create(author, address(usdc), 1_000e6);
        uint256 s2 = _submit(doer2, t2);
        assertEq(_sub(s2).bond.imd, F);
        assertEq(_sub(s2).bond.rew, DB2);
        Bond memory qdb = vault.quoteDisputeBond(s2);
        assertEq(qdb.imd, F);
        assertEq(qdb.rew, SB2);
        _dispute(dave, s2);
        _warp(24 hours);
        _callSwarm(erin, s2); // 1: silent
        _silent(s2);
        vault.poke(t2);
        _callSwarm(bob, s2); // 2: silent
        _silent(s2);
        vault.poke(t2);
        assertEq(uint8(_phase(s2)), uint8(Phase.NoDecision));
        _callSwarm(erin, s2); // 3: answered
        _answer(s2, false);
        vault.poke(t2);
        assertEq(uint8(_sub(s2).outcome), uint8(Outcome.Rejected));
        assertEq(imd.balanceOf(swarmPayee), 3 * PRICE);
        // erin: her first (silent) call's bond came back at the silence (dropCaller); her second (answered,
        // winning) call's own bond back; both her fees simply spent (no separate fee
        // refund). she is a stranger caller (not the doer, not dave the disputer), so her winning
        // call also carves 0.5 IMD (= F here) off the top of the imd-leg penalty (F = dave's only bond) first -
        // consuming it entirely, leaving dave's imd-leg disputer claim at 0. The rew leg (DB2) has no such
        // carve-out: split pro rata between dave and erin (equal bonds, half each).
        assertEq(
            vault.credits(address(imd), erin),
            2 * F /* both bonds back */ + F /* stranger carve-out */
        );
        assertEq(vault.credits(address(usdc), erin), 2 * SB2 + DB2 / 2);
        assertEq(vault.credits(address(imd), bob), F, "silent call: bond back, fee simply spent");
        assertEq(vault.credits(address(usdc), bob), SB2);
        vm.prank(dave);
        vault.claimDisputer(s2);
        (int256 erinImd, int256 erinUsdc) = _gains(erin, s2);
        (int256 bobImd, int256 bobUsdc) = _gains(bob, s2);
        (int256 daveImd, int256 daveUsdc) = _gains(dave, s2);
        (int256 doer2Imd, int256 doer2Usdc) = _gains(doer2, s2);
        assertEq(erinImd, -int256(2 * PRICE) + int256(F), "two fees spent, her stranger carve-out of the penalty");
        assertEq(erinUsdc, int256(DB2 / 2));
        assertEq(bobImd, -int256(PRICE));
        assertEq(bobUsdc, 0);
        assertEq(daveImd, 0, "erin's stranger carve-out took the whole imd-leg penalty");
        assertEq(daveUsdc, int256(DB2 / 2));
        assertEq(doer2Imd, -int256(F));
        assertEq(doer2Usdc, -int256(DB2));
        _claimEverythingAndCheck();
    }

    /// @dev Calls on both sides: the doer's silent call is refunded when the doer wins in the end (from the disputer
    /// bond), erin's answered call against him is not (her side lost).
    function test_SwarmFees_WinnerSideOnly_DoerSilentCallRefunded() public {
        uint256 DB2 = 30e6; // doer bond's percent part: 3% of R = 1,000 USDC
        uint256 SB2 = 10e6; // dispute bond's percent part: 1% of R
        uint256 t2 = _create(author, address(usdc), 1_000e6);
        uint256 s2 = _submit(doer2, t2);
        _dispute(dave, s2); // F, SB2
        _warp(24 hours);
        _callSwarm(doer2, s2, true); // silent, for the doer: paid out of his doer bond
        _silent(s2);
        vault.poke(t2);
        _callSwarm(erin, s2, false); // a stranger, answered: the doer is right
        _answer(s2, true);
        vault.poke(t2);
        assertEq(uint8(_sub(s2).outcome), uint8(Outcome.Accepted));
        // IMD penalty 2F (dave's bond + erin's losing call bond), all to doer2 (no NFT decision); his own bond
        // comes back minus the fee it paid (F - PRICE = 0). USDC: both bonds' 2*SB2 + his own DB2.
        assertEq(vault.credits(address(imd), doer2), 2 * F);
        assertEq(vault.credits(address(usdc), doer2), 900e6 + DB2 + 2 * SB2);
        (int256 doer2Imd, int256 doer2Usdc) = _gains(doer2, s2);
        (int256 erinImd, int256 erinUsdc) = _gains(erin, s2);
        assertEq(doer2Imd, int256(F), "the penalty (2F) minus his bond's F, of which PRICE paid his silent call");
        assertEq(doer2Usdc, int256(900e6 + 2 * SB2), "reward 90% + the whole USDC penalty: dave's and erin's bonds");
        assertEq(erinImd, -int256(F + PRICE), "her call bond and fee, both lost: her side lost");
        assertEq(erinUsdc, -int256(SB2));
        _claimEverythingAndCheck();
    }

    /// @dev The third silence after an NFT decision: the decision stands at once (here "reject"), no fourth appeal.
    function test_ThirdSilence_Decided_NftDecisionStands() public {
        _dispute(dave, s);
        _vote(s, 1, REJECT, 120, 20);
        _endVote(s);
        assertEq(uint8(_phase(s)), uint8(Phase.Decided));
        uint256 i0 = imd.balanceOf(doer);
        for (uint256 i; i < 3; ++i) {
            _appeal(doer, s);
            // the first fee comes out of his doer bond (F = PRICE); the bond spent, the next ones from his wallet,
            // still without a second bond
            assertEq(i0 - imd.balanceOf(doer), i * PRICE);
            _askAppealSwarm(s); // lazy ask
            assertEq(uint8(_phase(s)), uint8(Phase.Asked));
            _silent(s);
            vault.poke(t);
            if (i < 2) assertEq(uint8(_phase(s)), uint8(Phase.Decided));
        }
        assertEq(_sub(s).asks, 3);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Rejected), "the NFT decision, at the third silence");
        vm.prank(doer);
        vm.expectRevert(WrongPhase.selector);
        vault.appeal(s, type(uint256).max, _noSwap());
        // the doer bond minus the fee it paid (0 IMD / DB): half to dave, half to the 20 correct votes
        (int256 daveImd, int256 daveUsdc) = _gains(dave);
        assertEq(daveImd, 0);
        assertEq(daveUsdc, int256(DB / 2));
        (int256 doerImd, int256 doerUsdc) = _gains(doer);
        assertEq(doerImd, -int256(F + 2 * PRICE));
        assertEq(doerUsdc, -int256(DB));
        vault.claimVoterReward(s, voters[1]);
        assertEq(imd.balanceOf(voters[1]) - 10_000e18, 0);
        assertEq(usdc.balanceOf(voters[1]) - 1_000_000e6, DB / 2);
        _claimEverythingAndCheck();
    }

    /// @dev The third silence while the NFT is undecided, with calls from both sides: accepted at once, the disputer
    /// bond to the doer; the doer's own silent fee comes back from it.
    function test_ThirdSilence_NoDecision_AcceptedDisputerBondToDoer() public {
        _dispute(dave, s);
        _warp(24 hours);
        _callSwarm(erin, s, false);
        _silent(s);
        vault.poke(t);
        _callSwarm(doer, s, true); // the doer's own call: out of his doer bond
        _silent(s);
        vault.poke(t);
        _callSwarm(bob, s, false);
        _silent(s);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Completed));
        // dave's bond F / SB to the doer in full (sole winner, no NFT decision); the doer's own bond comes back
        // minus the fee it paid (F - PRICE = 0)
        assertEq(vault.credits(address(imd), doer), F, "dave's F; his own bond's F paid his call");
        assertEq(vault.credits(address(usdc), doer), 90e6 + DB + SB, "reward + own bond + dave's SB");
        (int256 doerImd,) = _gains(doer);
        (int256 erinImd, int256 erinUsdc) = _gains(erin);
        (int256 bobImd, int256 bobUsdc) = _gains(bob);
        assertEq(doerImd, 0, "net: dave's F offsets his own call's fee");
        assertEq(erinImd, -int256(PRICE));
        assertEq(erinUsdc, 0, "her call bond came back in full at the silence");
        assertEq(bobImd, -int256(PRICE));
        assertEq(bobUsdc, 0);
        _claimEverythingAndCheck();
    }

    // ================================================================== appeals

    function test_Appeal_SwarmAgrees() public {
        _decideAccept();
        uint256 beforeImd = imd.balanceOf(dave);
        uint256 beforeUsdc = usdc.balanceOf(dave);
        _appeal(dave, s); // dave appeals the "accept" decision
        // his own side's appeal, paid out of his dispute bond: nothing from his wallet
        assertEq(beforeImd - imd.balanceOf(dave), 0);
        assertEq(beforeUsdc - usdc.balanceOf(dave), 0);
        assertEq(uint8(_phase(s)), uint8(Phase.Appealed));
        assertEq(vault.getAppeal(s).funds, 0);
        assertEq(vault.getAppeal(s).fromBond, PRICE);
        _askAppealSwarm(s); // lazy ask
        assertEq(uint8(_phase(s)), uint8(Phase.Asked));
        _answer(s, true); // agrees with the NFT
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        // loser: dave's bond minus the fee it paid = 0 IMD / SB: half to the doer, half to the accept voters
        assertEq(vault.credits(address(imd), doer), F, "own bond only: dave's IMD went to the swarm");
        assertEq(vault.credits(address(usdc), doer), 90e6 + DB + SB / 2);
        assertEq(vault.credits(address(imd), dave), 0);
        assertEq(vault.credits(address(usdc), dave), 0);
        vault.claimVoterReward(s, voters[1]);
        assertEq(imd.balanceOf(voters[1]) - 10_000e18, 0);
        assertEq(usdc.balanceOf(voters[1]) - 1_000_000e6, SB / 2 + 5e6, "bond share + the reward's fee share");
        assertEq(vault.treasuryPot(address(usdc)), 5e6);
        (int256 daveImd, int256 daveUsdc) = _gains(dave);
        assertEq(daveImd, -int256(F), "his whole bond: PRICE to the swarm, the rest (0) to the winners");
        assertEq(daveUsdc, -int256(SB));
        _claimEverythingAndCheck();
    }

    /// no fee refund. The NFT was wrong, so the whole doer-bond penalty goes to the
    /// winners pro rata (dave's appeal bond, dave's dispute bond, erin's dispute bond: equal bonds, a third each).
    function test_Appeal_SwarmFlips_NoFeeRefund_WinnerTakesAll() public {
        _decideAccept();
        uint256 i0 = imd.balanceOf(dave);
        uint256 u0 = usdc.balanceOf(dave);
        _appeal(dave, s);
        // the disputer appeals for his own side out of his dispute bond, no
        // second bond, no new fee from his wallet
        assertEq(imd.balanceOf(dave), i0);
        assertEq(usdc.balanceOf(dave), u0);
        assertEq(vault.getAppeal(s).fromBond, PRICE);
        _askAppealSwarm(s); // lazy ask
        assertEq(uint8(_phase(s)), uint8(Phase.Asked));
        _answer(s, false); // flips: rejected
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Rejected));
        // NFT wrong: the doer's whole bond (F / DB) to dave; his own bond back minus the fee it paid (F - PRICE)
        assertEq(vault.credits(address(imd), dave), 0, "nothing credited directly: dave has no caller bond");
        (int256 daveImd, int256 daveUsdc) = _gains(dave);
        assertEq(daveImd, 0, "paid F; back: F - PRICE of his own bond + the doer's F: the loser's 0.5 covers the fee");
        assertEq(daveUsdc, int256(DB), "his SB back + the doer's DB");
        vm.expectRevert(NothingToClaim.selector); // wrong NFT votes get nothing
        vault.claimVoterReward(s, voters[1]);
        _claimEverythingAndCheck();
    }

    function test_Appeal_ByDoerSide_Flip() public {
        _dispute(dave, s);
        _vote(s, 1, REJECT, 120, 20); // = instantDelta: decides at once
        uint256 i0 = imd.balanceOf(doer);
        _appeal(doer, s); // the doer appeals the "reject" decision, out of his doer bond
        assertEq(imd.balanceOf(doer), i0);
        assertTrue(vault.getAppeal(s).sidesDoer);
        _askAppealSwarm(s); // lazy ask
        _answer(s, true); // flip to accepted
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        // NFT wrong: dave's whole bond F / SB to the doer; his own bond back minus the fee (F - PRICE = 0 IMD)
        assertEq(vault.credits(address(usdc), doer), 90e6 + DB + SB, "reward + own bond + dave's SB");
        assertEq(vault.treasuryPot(address(usdc)), 10e6); // the NFT was wrong: the whole fee to the treasury
        assertEq(vault.credits(address(imd), doer), F, "dave's F: the loser's 0.5 covers his fee");
        _claimEverythingAndCheck();
    }

    function test_Appeal_Silent_DecisionStands_NewWindow() public {
        _decideAccept();
        _appeal(dave, s);
        _warp(1 hours); // asked inside swarmTimeout (6 h): a later ask finds the appeal void
        _askAppealSwarm(s); // lazy ask
        _warp(1 hours);
        _silent(s);
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.Decided));
        assertEq(_sub(s).callFrom, _now());
        assertEq(vault.credits(address(imd), dave), 0, "no second bond to return; the fee his bond paid is spent");
        assertEq(vault.credits(address(usdc), dave), 0);
        assertEq(vault.getAppeal(s).appellant, address(0));
        _warp(24 hours - 1);
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.Decided));
        _warp(1);
        vault.poke(t); // nobody appealed again: the NFT decision is final
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        // dave lost: what is left of his bond (0 IMD / SB) splits half to the doer, half to the accept voters
        assertEq(vault.credits(address(imd), doer), F);
        assertEq(vault.credits(address(usdc), doer), 90e6 + DB + SB / 2);
        (int256 daveImd, int256 daveUsdc) = _gains(dave);
        assertEq(daveImd, -int256(F), "his bond's IMD went to the swarm");
        assertEq(daveUsdc, -int256(SB), "forfeited dispute bond's rew part");
        _claimEverythingAndCheck();
    }

    /// no fee refund. Dave's first appeal was silent (bond back, fee simply spent);
    /// the winners are dave (disputer), erin (disputer) and erin (the second, answered, winning appellant) - three
    /// equal bonds, a third of the penalty each.
    function test_Appeal_Silent_ReappealFlips() public {
        _decideAccept();
        _appeal(dave, s);
        _warp(1 hours); // asked inside swarmTimeout (6 h): a later ask finds the appeal void
        _askAppealSwarm(s); // lazy ask
        _silent(s);
        _warp(1 hours);
        _appeal(erin, s); // advances to Decided (silence), then appeals in the new window
        assertEq(vault.getAppeal(s).appellant, erin);
        _askAppealSwarm(s); // lazy ask
        assertEq(_sub(s).asks, 2);
        _answer(s, false);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Rejected));
        // dave is the only disputer (his first, silent appeal bond is already
        // back and out of the picture); erin never disputed, only appealed and won - she is a stranger appellant
        // (not the doer, not dave the disputer), so she gets 0.5 IMD (= F here) off the top of the imd-leg penalty
        // first (appellant pos carve-out), which consumes the whole imd-leg penalty
        // (dave's F dispute bond), leaving dave's disputer claim on the imd leg at 0. The rew leg has no such
        // carve-out (0.5 IMD only ever comes from the imd leg): erin's appellant carve-out and dave's
        // disputer share split DB pro rata to their equal rew bonds (both SB).
        assertEq(
            vault.credits(address(imd), erin),
            F /* stranger carve-out */ + F,
            /* her own appeal bond back */
            "stranger fee + her own bond back"
        );
        uint256 appPartUsdc = DB * SB / (2 * SB);
        (int256 daveImd, int256 daveUsdc) = _gains(dave);
        (int256 erinImd, int256 erinUsdc) = _gains(erin);
        // dave's appeal bond round-trips to zero (posted, then dropCaller returns it in full on silence); his
        // appeal fee (PRICE) does not - it was asked and spent before going silent, and a spent fee is never
        // refunded. His disputer claim on the imd leg is 0 (erin's stranger carve-out took all of it).
        assertEq(daveImd, -int256(PRICE), "his silent appeal fee was simply spent; nothing left of the imd-leg penalty");
        assertEq(daveUsdc, int256(DB - appPartUsdc));
        // erin wins as the stranger appellant: she paid F (appeal bond) + PRICE (fee) once, and gets back F (her
        // own bond) + F (the stranger carve-out) = F + PRICE net back - exactly what she paid, net zero.
        assertEq(erinImd, 0, "paid F + PRICE once, got F (own bond) + F (stranger carve-out) back");
        assertEq(erinUsdc, int256(appPartUsdc), "her pro-rata share of the rew-leg penalty");
        _claimEverythingAndCheck();
    }

    function test_Appeal_LateAnswerAfterSilenceIgnored() public {
        _decideAccept();
        _appeal(dave, s);
        _warp(1 hours); // asked inside swarmTimeout (6 h): a later ask finds the appeal void
        _askAppealSwarm(s); // lazy ask
        bytes32 first = _sub(s).request;
        _warp(6 hours + SWARM_DELIVERY_GRACE); // the timeout and the delivery grace (swarm audit 117cf05a #7)
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.Decided));
        OracleAttestation.Attestation memory a = _attestation(false);
        intake.complete(first, 0, a, _sign(a, attesterKey)); // recorded, but too late
        assertTrue(vault.requests(first).answered);
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.Decided));
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        _claimEverythingAndCheck();
    }

    function test_Appeal_PriceRaised_AppealVoided() public {
        _decideAccept();
        _appeal(dave, s);
        _warp(1 hours); // asked inside swarmTimeout (6 h): a later ask finds the appeal void
        intake.setPrice(2e18);
        _askAppealSwarm(s); // the live price is above the fee his bond covers: nothing is asked (lazy ask)
        assertEq(uint8(_phase(s)), uint8(Phase.Decided));
        assertEq(_sub(s).callFrom, _now());
        assertEq(_sub(s).asks, 1, "a voided appeal counts towards the 3");
        assertEq(vault.credits(address(imd), dave), 0, "his own appeal: no second bond, the fee never left his bond");
        assertEq(vault.credits(address(usdc), dave), 0);
        assertEq(imd.balanceOf(swarmPayee), 0);
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        assertEq(vault.credits(address(imd), doer), F + F / 2, "dave's bond is whole: half of F to the doer");
        _claimEverythingAndCheck();
    }

    function test_Appeal_IntakeReverts_AppealVoided() public {
        _decideAccept();
        _appeal(dave, s);
        _warp(1 hours); // asked inside swarmTimeout (6 h): a later ask finds the appeal void
        intake.setBroken(true); // request reverts: the machine must not get stuck
        _askAppealSwarm(s); // lazy ask
        assertEq(uint8(_phase(s)), uint8(Phase.Decided));
        // the disputer's own appeal paid nothing from his wallet and nothing went to the swarm: his bond is whole
        assertEq(vault.credits(address(imd), dave), 0);
        assertEq(vault.credits(address(usdc), dave), 0);
        intake.setBroken(false);
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        assertEq(vault.credits(address(imd), doer), F + F / 2, "own bond + half of dave's whole F");
        _claimEverythingAndCheck();
    }

    /// Nobody ever calls `askAppealSwarm` after `appeal` files it - the only text-carrying
    /// step is lazy and permissionless, so this must not deadlock the submission forever. Same outcome as a voided
    /// appeal that WAS asked but couldn't reach the swarm (test_Appeal_PriceRaised_AppealVoided above): full
    /// refund, counts toward the 3 swarm calls, NFT decision stands.
    function test_Appeal_NeverAsked_TimesOut() public {
        _decideAccept();
        _appeal(dave, s);
        _warp(6 hours); // swarmTimeout (Base.t.sol fixture) - askAppealSwarm never called
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.Decided));
        assertEq(_sub(s).callFrom, _now());
        assertEq(_sub(s).asks, 1, "counts towards the 3, same as any other voided appeal");
        assertEq(vault.getAppeal(s).appellant, address(0));
        assertEq(vault.credits(address(imd), dave), 0, "his own appeal: no second bond, nothing ever left his bond");
        assertEq(vault.credits(address(usdc), dave), 0);
        assertEq(imd.balanceOf(swarmPayee), 0, "the swarm was never asked, never paid");
        _warp(24 hours);
        vault.poke(t); // nobody appealed again within the new window: the NFT decision is final
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        assertEq(vault.credits(address(imd), doer), F + F / 2, "dave's bond is whole: half of F to the doer");
        _claimEverythingAndCheck();
    }

    /// Three such never-asked timeouts in a row must end the submission exactly like three
    /// silent/voided swarm calls always have (MAX_SWARM_CALLS: after the third one, the outcome stands as if
    /// there had been no appeal) - this is that case: nobody ever calls askAppealSwarm, repeatedly.
    function test_Appeal_NeverAsked_ThirdTimeEndsUncalled() public {
        _decideAccept();
        for (uint256 i; i < MAX_SWARM_CALLS; ++i) {
            _appeal(dave, s);
            _warp(6 hours);
            vault.poke(t);
        }
        assertEq(_sub(s).asks, MAX_SWARM_CALLS);
        assertEq(uint8(_phase(s)), uint8(Phase.Final), "3rd never-asked appeal ends it, same as 3 silent calls");
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        _claimEverythingAndCheck();
    }

    function test_Appeal_WindowClosed() public {
        _decideAccept();
        _warp(24 hours);
        vm.prank(dave);
        vm.expectRevert(WrongPhase.selector);
        vault.appeal(s, type(uint256).max, _noSwap());
    }

    function test_Appeal_ActionNotSold() public {
        _decideAccept();
        intake.setPrice(0);
        vm.prank(dave);
        vm.expectRevert(ActionNotSold.selector);
        vault.appeal(s, type(uint256).max, _noSwap());
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        _claimEverythingAndCheck();
    }

    // ================================================================== doer stake bonus and burn

    /// @dev power worth the reward = the whole 4%; $100 = 1M $YOLO at $0.0001.
    uint256 internal constant STAKE = 1_000_000e18;

    /// @dev `who` locks `amount` $YOLO for `weeks_` weeks, then a second passes: a lock counts only for submissions
    /// in a later block (YoloLockHub reads the lock strictly before the submission).
    function _lock(address who, uint256 amount, uint256 weeks_) internal {
        vm.prank(who);
        hub.lock(amount, weeks_);
        _warp(1);
    }

    /// @dev A fresh USDC task R = 100 for doer2, accepted by the timer (no dispute).
    function _acceptedPlain() internal returns (uint256 t2, uint256 s2) {
        t2 = _create(author, address(usdc), 100e6);
        s2 = _submit(doer2, t2);
        _warp(24 hours);
        vault.poke(t2);
        assertEq(uint8(_sub(s2).outcome), uint8(Outcome.Accepted));
    }

    function test_Stake_None_FeeToTreasury() public {
        (, uint256 s2) = _acceptedPlain();
        assertEq(vault.credits(address(usdc), doer2), 90e6 + 3e6, "90% plus his rew bond back");
        assertEq(vault.treasuryPot(address(usdc)), 10e6);
        assertEq(usdc.balanceOf(address(burner)), 0);
        assertEq(vault.getSettlement(s2).stakeBps, 0);
        _claimEverythingAndCheck();
    }

    /// @dev Full power (1M = $100 for a year) since before the submission, no dispute: 94 to the doer; the stakers' 5%
    /// leaves 1 after his 4%: 0.5 burned, 0.5 treasury; the NFT 5% nobody earned burns: 5.5 to the BuybackBurner.
    function test_Stake_FullPower_NoDispute_Bonus_AndBurnToBurner() public {
        _lock(doer2, STAKE, 52);
        uint256 t2 = _create(author, address(usdc), 100e6);
        uint256 s2 = _submit(doer2, t2);
        _warp(24 hours);
        vm.expectEmit(address(vault));
        emit Burned(address(usdc), 5.5e6);
        vault.poke(t2);
        assertEq(uint8(_sub(s2).outcome), uint8(Outcome.Accepted));
        assertEq(vault.credits(address(usdc), doer2), 94e6 + 3e6, "90%+stake plus his rew bond back");
        assertEq(usdc.balanceOf(buybackWallet), 5.5e6);
        assertEq(usdc.balanceOf(address(burner)), 0, "autosent, nothing waits in the burner");
        assertEq(vault.treasuryPot(address(usdc)), 0.5e6);
        assertEq(vault.getSettlement(s2).stakeBps, 400);
        _claimEverythingAndCheck();
    }

    /// @dev Part power (1M for 13 weeks = 250k, a quarter of R), no dispute: 91 doer (1%), the rest of the 5% = 4: 2 burned,
    /// 2 treasury, plus the NFT 5% burned.
    function test_Stake_PartPower_NoDispute() public {
        _lock(doer2, STAKE, 13);
        (, uint256 s2) = _acceptedPlain();
        assertEq(vault.getSettlement(s2).stakeBps, 100);
        assertEq(vault.credits(address(usdc), doer2), 91e6 + 3e6, "90%+stake plus his rew bond back");
        assertEq(usdc.balanceOf(buybackWallet), 2e6 + 5e6);
        assertEq(usdc.balanceOf(address(burner)), 0, "autosent, nothing waits in the burner");
        assertEq(vault.treasuryPot(address(usdc)), 2e6);
        _claimEverythingAndCheck();
    }

    /// @dev Full power, disputed, the NFT decided right: 94 doer, 5 NFT votes, 0.5 burned, 0.5 treasury.
    /// (A fresh task: a lock in the submission's block does not count, see the next test.)
    function test_Stake_FullPower_NftRight_VotesFive_BurnHalf_TreasuryHalf() public {
        _lock(doer2, STAKE, 52);
        uint256 t2 = _create(author, address(usdc), 100e6);
        uint256 s2 = _submit(doer2, t2);
        _dispute(dave, s2);
        _vote(s2, 1, ACCEPT, 120, 20);
        _warp(48 hours);
        vault.poke(t2);
        assertEq(uint8(_sub(s2).outcome), uint8(Outcome.Accepted));
        assertEq(vault.getSettlement(s2).stakeBps, 400);
        assertEq(
            vault.credits(address(usdc), doer2), 94e6 + 3e6 + 0.5e6, "90%+stake, his rew bond, half of dave's rew bond"
        );
        assertEq(vault.getSettlement(s2).voterFee, 5e6);
        assertEq(usdc.balanceOf(buybackWallet), 0.5e6);
        assertEq(usdc.balanceOf(address(burner)), 0, "autosent, nothing waits in the burner");
        assertEq(vault.treasuryPot(address(usdc)), 0.5e6);
        _claimEverythingAndCheck();
    }

    /// @dev A lock made in the block of the submission does not count for it (power read strictly before).
    function test_Stake_LockedInTheSubmissionBlock_NoBonus() public {
        vm.prank(doer);
        hub.lock(STAKE, 52); // setUp's submission is in this block
        _dispute(dave, s);
        _vote(s, 1, ACCEPT, 120, 20);
        _warp(48 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        assertEq(vault.getSettlement(s).stakeBps, 0);
        assertEq(vault.credits(address(usdc), doer), 90e6 + DB + SB / 2, "90%, his rew bond, half of dave's rew bond");
        assertEq(vault.treasuryPot(address(usdc)), 5e6);
        assertEq(usdc.balanceOf(address(burner)), 0);
        _claimEverythingAndCheck();
    }

    /// @dev Full power, the NFT undecided (nobody called): the 5% nobody earned burn with the 0.5: 5.5 burned, 0.5
    /// treasury; the disputer bond goes to the doer as without a stake.
    function test_Stake_FullPower_NftUndecided_BurnFiveAndHalf() public {
        _lock(doer2, STAKE, 52);
        uint256 t2 = _create(author, address(usdc), 100e6);
        uint256 s2 = _submit(doer2, t2);
        _dispute(dave, s2);
        _warp(48 hours);
        vault.poke(t2);
        assertEq(uint8(_sub(s2).outcome), uint8(Outcome.Accepted));
        // reward (staked, 94e6) + dave's dispute-bond share (SB) + the doer's own bond back (DB)
        assertEq(vault.credits(address(usdc), doer2), 94e6 + SB + DB);
        assertEq(usdc.balanceOf(buybackWallet), 5.5e6);
        assertEq(usdc.balanceOf(address(burner)), 0, "autosent, nothing waits in the burner");
        assertEq(vault.treasuryPot(address(usdc)), 0.5e6);
        assertEq(vault.credits(address(imd), doer2), F + F, "the disputer bond's fixed part, as without a stake");
        _claimEverythingAndCheck();
    }

    /// @dev A stake topped up during the review: the top-up does not count for this
    /// submission, the lock as it stood before it does: 400k for a year (+600k during the review) = power
    /// 400,000 of 1M, bonus 1.6: doer 91.6; the rest 3.4: 1.7 burned (+5 NFT part), 1.7 treasury.
    function test_Stake_ToppedUpAfterSubmission_OnlyThePowerBeforeCounts() public {
        _lock(doer2, 400_000e18, 52);
        uint256 t2 = _create(author, address(usdc), 100e6);
        uint256 s2 = _submit(doer2, t2);
        _warp(1 hours);
        _lock(doer2, 600_000e18, 0);
        _warp(23 hours);
        vault.poke(t2);
        assertEq(uint8(_sub(s2).outcome), uint8(Outcome.Accepted));
        assertEq(vault.getSettlement(s2).stakeBps, 160);
        assertEq(vault.credits(address(usdc), doer2), 91.6e6 + 3e6, "90%+stake plus his rew bond back");
        assertEq(vault.treasuryPot(address(usdc)), 1.7e6);
        assertEq(usdc.balanceOf(buybackWallet), 1.7e6 + 5e6);
        assertEq(usdc.balanceOf(address(burner)), 0, "autosent, nothing waits in the burner");
        _claimEverythingAndCheck();
    }

    /// @notice A doer who contributes to the
    /// task's own reward (before or after his submission) still gets the stake bonus as usual.
    function test_Stake_ContributedAfterSubmission_StillGetsBonus() public {
        _lock(doer2, STAKE, 52);
        uint256 t2 = _create(author, address(usdc), 100e6);
        uint256 s2 = _submit(doer2, t2);
        _topUp(doer2, t2, 5e6);
        assertTrue(vault.getContribution(t2, doer2).ever);
        _warp(24 hours);
        vault.poke(t2);
        assertEq(uint8(_sub(s2).outcome), uint8(Outcome.Accepted));
        assertEq(vault.getSettlement(s2).stakeBps, 400, "full 4% stake bonus, fixed at submission");
        // his top-up during the check joined the reward: R = 105
        assertEq(
            vault.credits(address(usdc), doer2), 98.7e6 + 3e6, "94% (90% + 4% stake) of 105 plus his rew bond back"
        );
        assertEq(vault.treasuryPot(address(usdc)), 0.525e6, "stake, full power: half of the 1% left");
        vm.prank(doer2);
        vm.expectRevert(NothingToClaim.selector);
        vault.withdrawContribution(t2);
        _claimEverythingAndCheck();
    }

    /// @dev The
    /// lock must run at the payout: 13M for 1 week, submitted 6 days in (power 13M / 52 = 250k, a quarter of R:
    /// 1% fixed), ended before the 24 h window did: no bonus. A lock that ended and was locked again before the
    /// submission counts (doer3: 1M for 1 week, ended, locked again for 52 weeks: the whole 4%).
    function test_Stake_LockEndedBeforePayout_NoBonus_RelockCounts() public {
        _lock(doer2, 13_000_000e18, 1);
        _warp(6 days);
        uint256 t2 = _create(author, address(usdc), 100e6);
        uint256 s2 = _submit(doer2, t2);
        assertEq(hub.powerAt(doer2, _now()), 250_000e18);
        assertEq(_sub(s2).stakeBps, 100);
        _warp(24 hours);
        vault.poke(t2);
        assertEq(
            vault.credits(address(usdc), doer2), 90e6 + 3e6, "the lock ended: as without a stake, plus his rew bond"
        );
        assertEq(vault.getSettlement(s2).stakeBps, 0);
        vm.prank(doer2);
        hub.withdraw(); // ended: free to leave

        _lock(doer3, STAKE, 1);
        _warp(1 weeks); // ended
        assertEq(hub.power(doer3), 0);
        _lock(doer3, 0, 52); // locked again for a year
        uint256 t3 = _create(author, address(usdc), 100e6);
        uint256 s3 = _submit(doer3, t3);
        _warp(24 hours);
        vault.poke(t3);
        assertEq(
            vault.credits(address(usdc), doer3), 94e6 + 3e6, "locked again before the submission, plus his rew bond"
        );
        assertEq(vault.getSettlement(s3).stakeBps, 400);
        _claimEverythingAndCheck();
    }

    /// @dev $YOLO reward: the treasury's $YOLO goes to the burner contract (never the treasury pot, never straight to
    /// 0x...dEaD: it waits for anyone's "Burn", swarm audit 117cf05a #7);
    /// with full power the doer takes 4% and the other 6% go to the burner (NFT 5%, half 0.5%, the treasury's
    /// 0.5%). `burnYolo` then burns all of it.
    function test_YoloReward_TreasuryPartToBurner_FullPowerSix() public {
        uint256 r = 1_000_000e18; // $100 at $0.0001
        uint256 dead0 = yolo.balanceOf(DEAD);
        uint256 deadBefore = yolo.balanceOf(address(burner));
        uint256 t2 = _create(author, address(yolo), r);
        uint256 s2 = _submit(doer2, t2);
        assertEq(_sub(s2).bond.imd, F, "fixed part, the same for every currency");
        assertEq(_sub(s2).bond.rew, 30_000e18, "3% of R, in $YOLO itself");
        _warp(24 hours);
        vault.poke(t2);
        assertEq(vault.credits(address(yolo), doer2), 900_000e18 + 30_000e18, "90% plus his 3% rew bond back");
        assertEq(yolo.balanceOf(address(burner)) - deadBefore, 100_000e18, "no stake: the whole 10% to the burner");
        assertEq(vault.treasuryPot(address(yolo)), 0);
        assertEq(yolo.balanceOf(DEAD), dead0, "nothing straight to 0x...dEaD: it waits for the Burn button");

        _lock(doer3, STAKE, 52);
        uint256 t3 = _create(author, address(yolo), r);
        _submit(doer3, t3);
        _warp(24 hours);
        vault.poke(t3);
        assertEq(vault.credits(address(yolo), doer3), 940_000e18 + 30_000e18, "90%+stake plus his 3% rew bond back");
        assertEq(yolo.balanceOf(address(burner)) - deadBefore, 100_000e18 + 60_000e18, "full power: 6% to the burner");
        assertEq(vault.treasuryPot(address(yolo)), 0);
        assertEq(yolo.balanceOf(DEAD), dead0);
        vm.prank(erin); // anyone
        burner.burnYolo();
        assertEq(yolo.balanceOf(DEAD) - dead0, 160_000e18, "the Burn button burns what waited");
        assertEq(yolo.balanceOf(address(burner)), 0);
        _claimEverythingAndCheck();
    }

    /// @dev The 10% fee of a
    /// $YOLO reward splits like any reward's: NFT right -> 5% to the "accept" votes, the doer with full power 4%,
    /// the last 1% (half "burn", half "treasury") all to the burner, since the treasury's $YOLO burns too.
    function test_YoloReward_FeeSplitsLikeAnyReward_Votes5_Doer4_Burner1() public {
        uint256 r = 1_000_000e18; // $100 at $0.0001
        _lock(doer3, STAKE, 52); // power 1M = R: the whole 4%
        uint256 t3 = _create(author, address(yolo), r);
        uint256 s3 = _submit(doer3, t3);
        _dispute(dave, s3);
        _vote(s3, 1, ACCEPT, 120, 20);
        _endVote(s3);
        uint256 burner0 = yolo.balanceOf(address(burner));
        _warp(24 hours);
        vault.poke(t3);
        assertEq(uint8(_sub(s3).outcome), uint8(Outcome.Accepted));
        assertEq(vault.getSettlement(s3).voterFee, 50_000e18, "5% to the NFT votes");
        assertEq(vault.getSettlement(s3).stakeBps, 400);
        assertEq(
            vault.credits(address(yolo), doer3),
            940_000e18 + 30_000e18 + 5_000e18,
            "90% + 4% stake + his 3% bond + half of dave's 1% bond"
        );
        assertEq(yolo.balanceOf(address(burner)) - burner0, 10_000e18, "the 1% left: to the burner, none to a pot");
        assertEq(vault.treasuryPot(address(yolo)), 0);
        _claimEverythingAndCheck();
    }

    /// @dev ETH and IMD rewards with full power: the burn share lands on the buyback wallet in that currency, in
    /// the same transaction as the payout.
    /// ETH 0.04: doer 0.036 + 0.0016; wallet 0.0002 + 0.002 (NFT part); treasury 0.0002.
    /// IMD 12.5: doer 11.25 + 0.5; wallet 0.0625 + 0.625; treasury 0.0625.
    function test_Stake_EthAndImdBurnShareToBurner() public {
        _lock(doer2, STAKE, 52);
        uint256 tE = _create(author, ETH, 0.04 ether); // $100
        uint256 sE = _submit(doer2, tE);
        uint256 tI = _create(author, address(imd), 12.5e18); // $100
        uint256 sI = _submit(doer2, tI);
        _warp(24 hours);
        vault.poke(tE);
        vault.poke(tI);
        assertEq(uint8(_sub(sE).outcome), uint8(Outcome.Accepted));
        assertEq(uint8(_sub(sI).outcome), uint8(Outcome.Accepted));
        assertEq(buybackWallet.balance, 0.0022 ether);
        assertEq(imd.balanceOf(buybackWallet), 0.6875e18);
        assertEq(address(burner).balance, 0, "autosent, nothing waits in the burner");
        assertEq(imd.balanceOf(address(burner)), 0, "autosent, nothing waits in the burner");
        // no dispute on either submission: each doer bond (fixed IMD part + percent part in its own currency)
        // comes straight back. ETH: reward 0.0376 + the bond's percent part (3% of 0.04 ether = 0.0012).
        // IMD: reward 11.75 + the bond's fixed part (F) from each of the two submissions + the IMD task's own
        // bond's percent part (3% of 12.5 IMD = 0.375), which lands in IMD too since R is already IMD.
        assertEq(vault.credits(ETH, doer2), 0.0376 ether + 0.0012 ether);
        assertEq(vault.credits(address(imd), doer2), 11.75e18 + F + F + 0.375e18, "reward + both bonds back");
        assertEq(vault.treasuryPot(ETH), 0.0002 ether, "0.5%, no author fees");
        assertEq(vault.treasuryPot(address(imd)), 0.0625e18);
        _claimEverythingAndCheck();
    }

    // ================================================================== helpers

    /// @dev one dispute, one disputer - dave alone. The vote (20, = instantDelta,
    ///) decides at once; no need to warp to the vote end.
    function _decideAccept() internal {
        _dispute(dave, s);
        _vote(s, 1, ACCEPT, 120, 20);
        assertEq(uint8(_phase(s)), uint8(Phase.Decided));
    }
}
