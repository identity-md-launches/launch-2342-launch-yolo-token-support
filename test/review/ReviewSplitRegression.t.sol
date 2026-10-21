// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Vm} from "forge-std/Vm.sol";
import "../Base.t.sol";

/// @dev A regression test of the core: TaskVault + CaseDesk + DisputeDesk + helpers.
///      The scenarios below use only `vault` and the Base helpers;
///      "golden" accounting hashes (credits, treasury, liabilities, balances after every payout) pin down the
///      money of each outcome, checked by hand against the inline assertions in each scenario.
///      `Submission.bond` is the `Bond` struct (imd/rew/add); no oracle sizes the bond.
abstract contract SplitScenarios is Base {
    /// @dev All the money a user can see: credits and balances of participants in three currencies, the vault's
    ///      balances, the treasury and liabilities. Contract addresses are not part of this.
    function _ledger() internal view returns (bytes32 h) {
        address[13] memory who = [
            author, alice, bob, doer, doer2, dave, erin, relayer, voters[0], voters[1], voters[2], treasury, swarmPayee
        ];
        address[3] memory ts = [ETH, address(usdc), address(imd)];
        for (uint256 k; k < 3; ++k) {
            h = keccak256(
                abi.encode(h, vault.liabilities(ts[k]), vault.treasuryPot(ts[k]), _bal(ts[k], address(vault)))
            );
            for (uint256 i; i < who.length; ++i) {
                h = keccak256(abi.encode(h, vault.credits(ts[k], who[i]), _bal(ts[k], who[i])));
            }
        }
    }

    function _bal(address t, address a) internal view returns (uint256) {
        return t == ETH ? a.balance : IERC20(t).balanceOf(a);
    }

    /// @dev The Intake request id hashes the Intake address, which depends on the test deployment: left out.
    function _settled(uint256 s) internal view returns (bytes32) {
        Submission memory sb = vault.getSubmission(s);
        sb.request = bytes32(0);
        return keccak256(abi.encode(vault.getSettlement(s), sb, vault.getDispute(s)));
    }

    /// @return a the ledger right after settlement, b the settlement record, c the ledger after every payout and withdrawal
    /// @dev The sums of each outcome were checked by hand and pinned by assertions right in the scenario: the
    ///      golden hashes below were taken only after that (one dispute, one disputer: dave).
    ///      R = 150 USDC (author 100 + alice 50). Bonds are counted only against the author's reward (100):
    ///      doer bond 0.5 IMD + 3 USDC; dispute bond 0.5 IMD + 1 USDC.
    ///      The NFT decided right, accepted: the doer gets 135 USDC + 3 (their bond) + 0.5 (half of dave's bond)
    ///      = 138.5; the treasury 7.5 (5%), the votes 7.5 + 0.5; dave's bond (1 USDC, 0.5 IMD): half to the doer,
    ///      half to the votes.
    function _s1AcceptedNftRight() internal returns (bytes32 a, bytes32 b, bytes32 c) {
        uint256 t = _create(author, address(usdc), 100e6);
        _topUp(alice, t, 50e6);
        uint256 s = _submit(doer, t);
        assertEq(_sub(s).bond.imd, _fixedBond());
        assertEq(_sub(s).bond.rew, 3e6, "3% of the author's $100 (alice's $50 is no part of it)");
        _dispute(dave, s);
        _vote(s, 0, 1, 0, 120); // +120 accept
        _endVote(s); // decided at the vote end
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        assertEq(uint8(_sub(s).nftDecision), uint8(Verdict.Accept));
        assertEq(
            vault.credits(address(usdc), doer), 135e6 + 3e6 + 0.5e6, "90% of R, his bond back, half of dave's bond"
        );
        assertEq(vault.getSettlement(s).voterBond.rew, 0.5e6, "half of dave's 1 USDC");
        assertEq(vault.treasuryPot(address(usdc)), 7.5e6);
        assertEq(vault.getSettlement(s).voterFee, 7.5e6);
        assertEq(
            vault.credits(address(imd), doer),
            _fixedBond() + _fixedBond() / 2,
            "fixed bond back + half of dave's 0.5 IMD"
        );
        assertEq(vault.getSettlement(s).voterBond.imd, _fixedBond() / 2, "half of dave's 0.5 IMD");
        assertEq(vault.treasuryPot(address(imd)), 0);
        (a, b) = (_ledger(), _settled(s));
        _claimEverythingAndCheck();
        c = _ledger();
    }

    /// @dev IMD R = 30 (reward and bonds share the same token): doer bond 0.5 IMD + 0.9 (3% of 30); dave's
    ///      (dispute) and erin's (appeal) bond 0.5 IMD + 0.3 (1%) each. NFT "accept", swarm "no" (doer loses): the
    ///      penalty is the doer's bond (0.5 imd + 0.9 rew). Erin's swarm fee (0.5 IMD) comes back to her out of
    ///      the imd penalty, which then empties. The rew penalty (0.9), NFT was wrong: 100% to the winners pro
    ///      rata to their bonds (dave 0.3 + erin 0.3 = 0.6): erin gets 0.9 x 0.3/0.6 = 0.45 directly (the
    ///      appellant gets their share directly), the remaining 0.45 is dave's, but claimDisputer has not been
    ///      called yet, so credits show only erin's share right away.
    function _s2AppealSwarmOverturns() internal returns (bytes32 a, bytes32 b, bytes32 c) {
        uint256 t = _create(author, address(imd), 30e18);
        uint256 s = _submit(doer, t);
        assertEq(_sub(s).bond.imd, _fixedBond());
        assertEq(_sub(s).bond.rew, 0.9e18, "3% of 30 IMD");
        _dispute(dave, s);
        _vote(s, 0, 1, 0, 120); // NFT: accept
        _endVote(s); // decided at the vote end
        _appeal(erin, s); // against the doer
        _askAppealSwarm(s); // lazy ask
        _answer(s, false); // swarm: rejected, NFT was wrong, the caller wins
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Rejected));
        // her 0.5 IMD swarm fee is simply
        // spent, win or lose - no separate fee-refund credit. dave is the only disputer; erin never
        // disputed, only appealed and won - she is a stranger appellant, so she gets 0.5 IMD off the top of the
        // imd-leg (fixed) penalty first. That penalty is exactly the doer's fixed bond (0.5 IMD = p.bondFixedImd),
        // so her stranger carve-out consumes it entirely: nothing is left for a 50/50 split on that leg, dave's
        // fixed-leg disputerReward is 0. The rew leg (3%-of-R, 0.9) has no such carve-out: 50/50 between dave and
        // erin (erin's direct carve-out 0.45, dave's matching share waits in disputerReward).
        assertEq(
            vault.credits(address(imd), erin),
            0.5e18 /* her bond.imd back */ + 0.3e18 /* her bond.rew back */ + 0.5e18 /* stranger carve-out */
                + 0.45e18, /* rew-leg carve-out */
            "erin: bond back + stranger carve-out + rew-leg carve-out (no fee refund)"
        );
        assertEq(vault.getSettlement(s).disputerReward.rew, 0.45e18, "dave's unclaimed share of the rew-leg penalty");
        assertEq(
            vault.getSettlement(s).disputerReward.imd, 0, "erin's stranger carve-out took the whole fixed-leg penalty"
        );
        assertEq(vault.getSettlement(s).voterBond.imd, 0);
        assertEq(vault.treasuryPot(address(imd)), 0);
        (a, b) = (_ledger(), _settled(s));
        _claimEverythingAndCheck();
        c = _ledger();
    }

    /// @dev ETH R = 0.02 ($50): NFT 10 : 10, nobody called the swarm: accepted, the disputers' bond (0.5 IMD +
    ///      1%, dave alone) goes entirely to the doer (a tie), a 10% ETH fee to the treasury.
    function _s3UndecidedNobodyCalls() internal returns (bytes32 a, bytes32 b, bytes32 c) {
        uint256 t = _create(author, ETH, 0.02 ether);
        uint256 s = _submit(doer, t);
        _dispute(dave, s);
        _vote(s, 2, 1, 140, 10);
        _vote(s, 1, 2, 120, 10);
        _warp(24 hours);
        vault.poke(t); // NoDecision
        _warp(24 hours);
        vault.poke(t); // accepted: undecided, nobody called
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        assertEq(uint8(_sub(s).nftDecision), uint8(Verdict.None));
        assertEq(
            vault.credits(ETH, doer), 0.018 ether + 0.0006 ether + 0.0002 ether, "90% of R, his bond and dave's bond"
        );
        assertEq(vault.treasuryPot(ETH), 0.002 ether, "the whole 10% (no author fee)");
        assertEq(vault.credits(address(imd), doer), _fixedBond() + _fixedBond(), "his fixed bond + dave's");
        assertEq(vault.treasuryPot(address(imd)), 0);
        (a, b) = (_ledger(), _settled(s));
        _claimEverythingAndCheck();
        c = _ledger();
    }

    /// @dev IMD R = 50: s (bond 0.5 IMD + 1.5 rew) is disputed and the NFT rejects it correctly (the penalty is
    ///      s's bond, the NFT was right: half to dave, half to the votes: imd 0.25/0.25, rew 0.75/0.75), the
    ///      queued s2 (bond 0.5 IMD fixed + 1.5 rew, no doubling) activates with no question to the swarm and
    ///      is accepted by the timer: 45 IMD + its bond 1.5 to the doer, 5 to the treasury. Bob's 5 IMD top-up
    ///      during the check joins the reward at once: s2 gets 90% of 55 = 49.5, the treasury 5.5.
    function _s4RejectedThenQueuedAccepted() internal returns (bytes32 a, bytes32 b, bytes32 c) {
        uint256 t = _create(author, address(imd), 50e18);
        uint256 s = _submit(doer, t);
        uint256 s2 = _submit(doer2, t); // queued, the same bond (no doubling)
        _topUp(bob, t, 5e18); // during the check: joins the pot at once
        _dispute(dave, s);
        _vote(s, 1, 2, 120, 20); // NFT: reject
        _warp(48 hours);
        vault.poke(t); // rejected; s2 activated, nothing asked
        assertEq(uint8(_phase(s2)), uint8(Phase.Review));
        assertEq(_sub(s2).request, bytes32(0));
        _warp(24 hours);
        vault.poke(t); // accepted
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Rejected));
        assertEq(uint8(_sub(s2).outcome), uint8(Outcome.Accepted));
        assertEq(_sub(s).bond.imd, _fixedBond());
        assertEq(_sub(s).bond.rew, 1.5e18, "3% of 50 IMD");
        assertEq(_sub(s2).bond.imd, _fixedBond(), "fixed part never doubles");
        assertEq(_sub(s2).bond.rew, _sub(s).bond.rew, "queued rew bond: the same 3%, never doubled");
        assertEq(vault.getSettlement(s).voterBond.imd, _fixedBond() / 2);
        assertEq(vault.getSettlement(s).voterBond.rew, 0.75e18);
        assertEq(vault.getSettlement(s).disputerReward.imd, _fixedBond() / 2);
        assertEq(vault.getSettlement(s).disputerReward.rew, 0.75e18);
        assertEq(
            vault.credits(address(imd), doer2),
            49.5e18 + 1.5e18 + _fixedBond(),
            "90% of R (50 + bob 5), his rew bond, his fixed bond"
        );
        assertEq(vault.treasuryPot(address(imd)), 5.5e18);
        assertEq(_sub(s2).reward, 55e18, "bob's top-up during the check is in the reward");
        (a, b) = (_ledger(), keccak256(abi.encode(_settled(s), _settled(s2))));
        _claimEverythingAndCheck();
        c = _ledger();
    }

    /// @dev USDC R = 60: bonds 0.5 IMD + 1% (0.6) / 3% (1.8) R. bob (for the doer) called the swarm, silence:
    ///      bond back, fee lost (their side lost). erin (against) called, swarm said "no": the penalty is the
    ///      doer's bond (0.5 IMD + 1.8 USDC), two legs. swarm fees are never returned separately. dave is
    ///      the only disputer; erin only called - a stranger appellant, who on winning gets 0.5 IMD (the whole
    ///      imd-leg penalty, since the penalty equals F = bondFixedImd) entirely, with no usual split. The rew
    ///      leg (1.8 USDC, the NFT did not decide) has no carve-out: pro rata to the winners' bonds (dave 0.6 +
    ///      erin 0.6 = 1.2): erin gets 1.8 x 0.6/1.2 = 0.9 directly, the remaining 0.9 is dave's (claimDisputer).
    function _s5CallSwarmSilentThenCalledAgain() internal returns (bytes32 a, bytes32 b, bytes32 c) {
        uint256 t = _create(author, address(usdc), 60e6);
        uint256 s = _submit(doer, t);
        _dispute(dave, s);
        _vote(s, 3, 1, 150, 5); // too few to decide (endDelta 10)
        _warp(24 hours);
        vault.poke(t); // NoDecision
        _callSwarm(bob, s, true);
        _silent(s);
        vault.poke(t); // silence: bob's fee lost (his side loses in the end), bond back, new window
        _callSwarm(erin, s, false);
        _answer(s, false); // rejected, erin wins
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Rejected));
        assertEq(_sub(s).asks, 2);
        assertEq(vault.credits(address(imd), bob), _fixedBond(), "his bond.imd back on silence");
        assertEq(
            vault.credits(address(imd), erin),
            _fixedBond() /* her bond.imd back */ + _fixedBond(), /* her stranger carve-out: the whole imd-leg penalty */
            "erin: bond back + stranger carve-out (no fee refund)"
        );
        assertEq(
            vault.credits(address(usdc), erin),
            0.6e6 /* her bond.rew back */ + 0.9e6,
            /* her pro-rata share */
            "erin: bond + penalty share"
        );
        assertEq(vault.getSettlement(s).disputerReward.rew, 0.9e6, "dave's unclaimed share");
        assertEq(
            vault.getSettlement(s).disputerReward.imd, 0, "erin's stranger carve-out took the whole imd-leg penalty"
        );
        (a, b) = (_ledger(), _settled(s));
        _claimEverythingAndCheck();
        c = _ledger();
    }

    // A task the dev wallet cancels (Unwound) is covered in CancelTask.t.sol.
}

/// forge-config: default.isolate = false
contract ReviewSplitRegression is SplitScenarios {
    // ---------------------------------------------------------------- golden ledgers
    // Each constant below is a hash of the ledger (see _ledger) or the settlement record (see _settled) for one
    // scenario, checked against the inline assertions in that scenario. They are regenerated whenever a money
    // rule or a field layout changes on purpose; the inline assertEq calls in each _sN...() function are
    // re-verified by hand first, and the new hashes are then taken from the _golden() log output.
    bytes32 internal constant S1_A = 0x4830ea4fcc6dc5027c1f37bcad5852e0b11e2b542d5bf3a1b4e0bf9f8b5d8d55;
    bytes32 internal constant S1_B = 0xa4018a5ae1f016fc869c28d2e27ea22d88e1d937e0efb0592baa756f921319ad;
    bytes32 internal constant S1_C = 0x65dcffba9fa5f218c43b4c3f810b8d61e0676b615cd88c2200be717a94fa422b;
    bytes32 internal constant S2_A = 0x08d27cc2a8693d93d430a64d7a89b5d993f0bc3aaa0f468e9d26ec43c1adc65d;
    bytes32 internal constant S2_B = 0x7d5a35e896f5cc60c3cebee7443c57120a4abf9130d2d794c36a86769c152705;
    bytes32 internal constant S2_C = 0x808551d4f18f1c9f9021bde675a4cd14dd60e843467f3bfd666fd1221b8bddd1;
    bytes32 internal constant S3_A = 0xbb589401078dd43b88cbc7c1c174981c2ee68b3027a30d9ffdcf05a917cc491d;
    bytes32 internal constant S3_B = 0x880d35a1a6c101757740019ffe504083f1353824cf6c05eb99c4e48fe76bf58a;
    bytes32 internal constant S3_C = 0x4755fc921943fe650cc0871884c69218df089678208e1ea5cc2d2410865f21ce;
    bytes32 internal constant S4_A = 0x76984c0edfd7138e1eeafbca442dc75eac4cdca48dfce84a332a3dbe3eb570fd;
    bytes32 internal constant S4_B = 0xdb27e0d67237b840a3897b3e94d0bc38e88d80d4f00b209c05909985a9e9b9f4;
    bytes32 internal constant S4_C = 0xf9dbd032a0ab92846b8ead6e767bad8491ba22ce779070f3e67373d796740420;
    bytes32 internal constant S5_A = 0x38cc28fed888cc3bcd65c4d5b72aa4ec16f7b4731c45419596c21cda6e366d7a;
    bytes32 internal constant S5_B = 0x12641fdf0b0d28314e7cdd711051407e007d2e0d2c3006ec555db150a1bb11c5;
    bytes32 internal constant S5_C = 0xa82fdb047f774ed464eb049c7e6b261d5bc214d5978856d853700b07460f2f09;

    // disputeWindow/voteWindow/appealWindow/swarmTimeout hold the production values 24h/24h/24h/6h. Only every B
    // (settlement record, which encodes timestamps) moves when a window value changes; A and C (the money)
    // stay unchanged.

    function _golden(bytes32[3] memory got, bytes32[3] memory want) internal {
        emit log_named_bytes32("ledger after settlement", got[0]);
        emit log_named_bytes32("settlement record", got[1]);
        emit log_named_bytes32("ledger after every payout", got[2]);
        assertEq(got[0], want[0], "ledger after settlement differs from the golden value");
        assertEq(got[1], want[1], "settlement record differs from the golden value");
        assertEq(got[2], want[2], "ledger after payouts differs from the golden value");
    }

    function test_golden_AcceptedAfterDispute_NftRight() public {
        (bytes32 a, bytes32 b, bytes32 c) = _s1AcceptedNftRight();
        _golden([a, b, c], [S1_A, S1_B, S1_C]);
    }

    function test_golden_AppealSwarmOverturnsNft() public {
        (bytes32 a, bytes32 b, bytes32 c) = _s2AppealSwarmOverturns();
        _golden([a, b, c], [S2_A, S2_B, S2_C]);
    }

    function test_golden_UndecidedNobodyCallsSwarm() public {
        (bytes32 a, bytes32 b, bytes32 c) = _s3UndecidedNobodyCalls();
        _golden([a, b, c], [S3_A, S3_B, S3_C]);
    }

    function test_golden_RejectedThenQueuedAccepted() public {
        (bytes32 a, bytes32 b, bytes32 c) = _s4RejectedThenQueuedAccepted();
        _golden([a, b, c], [S4_A, S4_B, S4_C]);
    }

    function test_golden_CallSwarmSilentThenCalledAgain() public {
        (bytes32 a, bytes32 b, bytes32 c) = _s5CallSwarmSilentThenCalledAgain();
        _golden([a, b, c], [S5_A, S5_B, S5_C]);
    }

    // ---------------------------------------------------------------- what the split changed

    string internal constant R256 =
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    // R200: a 200-byte Evidence.note the doer attaches at submission (under MAX_NOTE_BYTES, 512).
    string internal constant R200 =
        "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef01234567";

    /// @dev A dispute collects no ETH and nobody is paid for voting gas: a third party cannot send another
    ///      voter's ballot; the voter sends it themself.
    function test_minor_NoEthInDisputes_VoterSendsOwnBallot() public {
        uint256 t = _create(author, address(usdc), 50e6); // no author fee
        uint256 s = _submit(doer, t);
        uint256 beforeDispute = address(vault).balance;
        _dispute(dave, s); // no ETH collected
        assertEq(address(vault).balance, beforeDispute, "dispute adds no ETH of its own");
        // the vote carries no signature, the sender is the voter
        bytes memory cd = abi.encodeCall(ITaskVault.vote, (s, 1, voters[2], _ids(140, 10)));
        vm.fee(1 gwei);
        vm.prank(relayer);
        (bool ok,) = address(vault).call(cd);
        assertFalse(ok, "relaying another voter's ballot reverts");
        vm.prank(voters[2]);
        (ok,) = address(vault).call(cd);
        assertTrue(ok, "the voter sends his own ballot");
        assertEq(vault.getDispute(s).votesAccept, 10);
        assertEq(vault.credits(ETH, voters[2]), 0, "nobody is paid for sending a vote");
    }

    /// @dev Gas of the heaviest separate step, logged: `askAppealSwarm` asks the appeal question (mock Intake).
    /// @dev one dispute, one disputer - the question body is the one disputer's 256-byte reason and proof
    ///      plus the doer's note; an appeal carries no text.
    /// @dev The ask is played by `askAppealSwarm` (anyone), in a transaction of its own after `appeal`.
    function test_minor_HeaviestLazyStepGasCost() public {
        uint256 t = _create(author, address(usdc), 50e6);
        vm.prank(doer3);
        uint256 s = vault.submit(t, "https://x.com/doer/status/1", Evidence("", R200), 0, type(uint256).max, _noSwap());
        address d = makeAddr("disputer0");
        _fund(d); // the dispute bond's rew part is in the task's own currency (USDC here), not IMD
        vm.prank(d);
        vault.dispute(s, R256, R256, _noSwap());
        _vote(s, 0, 2, 0, 120);
        _endVote(s); // reject at the vote end
        // the ask is lazy: `appeal` only files it; the resupply (task rules +
        // dispute reason/proof) and the ask itself happen in the separate, permissionless `askAppealSwarm`
        // call.
        RuleTexts memory rt = _genericRuleTexts();
        rt.disputeReason = R256;
        rt.disputerProofUri = R256;
        vm.prank(doer3);
        vault.appeal(s, type(uint256).max, _noSwap());
        assertEq(uint8(_phase(s)), uint8(Phase.Appealed));
        uint256 g0 = gasleft();
        vault.askAppealSwarm(s, rt);
        emit log_named_uint("gas of the heaviest separate step (askAppealSwarm)", g0 - gasleft());
        assertEq(uint8(_phase(s)), uint8(Phase.Asked), "asked by askAppealSwarm");
    }

    /// @dev Intentional: the vault's ABI lists all 33 events, but
    ///      submission, dispute, vote and settlement events come from CaseDesk and DisputeDesk. An off-chain
    ///      reader reads all three addresses. This test pins the "event -> address" map so moving an event
    ///      between contracts cannot slip past an off-chain reader silently.
    function test_events_EmitterMap() public {
        vm.recordLogs();
        _s2AppealSwarmOverturns();
        _s3UndecidedNobodyCalls();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32[12] memory fromVault = [
            TaskCreated.selector,
            TaskStatusChanged.selector,
            Credited.selector,
            Paid.selector,
            SwarmAsked.selector,
            SwarmAnswered.selector,
            TreasurySwept.selector,
            ParamsCached.selector,
            ContributionWithdrawn.selector,
            ToppedUp.selector,
            AttestationIgnored.selector,
            Burned.selector // burn shares (none in these two scenarios, mapped anyway)
        ];
        bytes32[8] memory fromCase = [
            Submitted.selector,
            Activated.selector,
            NftDecided.selector,
            NoNftDecision.selector,
            SubmissionFinal.selector,
            SwarmSilent.selector,
            AppealVoided.selector,
            DoerReplied.selector
        ];
        bytes32[7] memory fromDispute = [
            Disputed.selector,
            VoteLib.VoteCounted.selector,
            Appealed.selector,
            AppealReplied.selector,
            SubmissionSettled.selector,
            DisputerClaimed.selector,
            VoterRewardClaimed.selector
        ];
        uint256 seen;
        for (uint256 i; i < logs.length; ++i) {
            address e = logs[i].emitter;
            if (e != address(vault) && e != address(caseDesk) && e != address(disputeDesk)) continue;
            bytes32 t0 = logs[i].topics[0];
            address want;
            for (uint256 k; k < fromVault.length; ++k) {
                if (t0 == fromVault[k]) want = address(vault);
            }
            for (uint256 k; k < fromCase.length; ++k) {
                if (t0 == fromCase[k]) want = address(caseDesk);
            }
            for (uint256 k; k < fromDispute.length; ++k) {
                if (t0 == fromDispute[k]) want = address(disputeDesk);
            }
            assertTrue(want != address(0), "an event outside the map");
            assertEq(e, want, "event emitted by another contract: the indexer reads vault + caseDesk + disputeDesk");
            ++seen;
        }
        assertGt(seen, 40);
    }
}
