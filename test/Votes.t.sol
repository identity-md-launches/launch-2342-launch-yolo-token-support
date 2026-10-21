// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./Base.t.sol";

/// @dev NFT votes by NFT ids, without registration: the contract remembers, and an NFT cannot vote twice in the
///      same dispute. The sender sends ids they own now or hold a delegate.xyz delegation for; each id votes once
///      per dispute; the vote counts the ids; more transactions for the same side add NFTs, the side cannot change.
///      Every voter pays their own gas.
///      Base setUp: voter0..4 hold 120 / 20 / 10 / 5 / 2 NFTs (ids 0..156).
///      USDC task R = 100: the doer and dispute bonds are 0.5 IMD fixed (`B`) + 3%/1% of R in USDC.
/// forge-config: default.isolate = false
contract VotesTest is Base {
    uint8 internal constant ACCEPT = 1;
    uint8 internal constant REJECT = 2;
    uint256 internal constant B = 0.5e18;

    uint256 internal t;
    uint256 internal s;

    function setUp() public override {
        super.setUp();
        t = _create(author, address(usdc), 100e6);
        s = _submit(doer, t);
        _dispute(dave, s);
    }

    /// @dev A new task, submission and dispute (opened in the current block).
    function _newDispute() internal returns (uint256 tt, uint256 ss) {
        tt = _create(author, address(usdc), 100e6);
        ss = _submit(doer2, tt);
        _dispute(erin, ss);
    }

    function _send(address from, address to, uint256 fromId, uint256 count) internal {
        for (uint256 id = fromId; id < fromId + count; ++id) {
            vm.prank(from);
            nft.transferFrom(from, to, id);
        }
    }

    // ================================================================== the vote itself

    function _one(uint256 id) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = id;
    }

    /// @dev Scenarios 1-3: 1, 25 and 100 NFTs, each counted in full in the dispute.
    function test_VoteCountsEverySentNft() public {
        // instant decisions off so that all three votes count in one dispute
        Params memory p = defaultParams();
        p.instantDelta = 2_000;
        vm.prank(multisig);
        registry.proposeParams(p);
        _warp(48 hours);
        registry.activateParams();
        (, uint256 s2) = _newDispute();
        address w1 = _holder("w1", 1);
        address w25 = _holder("w25", 25);
        address w100 = _holder("w100", 100);
        _voteAs(s2, w1, ACCEPT);
        _voteAs(s2, w25, REJECT);
        _voteAs(s2, w100, ACCEPT);
        Dispute memory d = vault.getDispute(s2);
        assertEq(d.votesAccept, 101);
        assertEq(d.votesReject, 25);
        assertEq(d.walletsAccept, 2);
        assertEq(d.walletsReject, 1);
        (uint256 acc,) = vault.votesOf(s2, w100);
        assertEq(acc, 100);
        assertTrue(vault.tokenVoted(s2, held[w25][24]));
        assertEq(vault.sideOf(s2, w25), REJECT);
    }

    /// @dev NFTs minted to a wallet after the dispute opened vote in it (no snapshot, no registration).
    function test_NftsGotAfterOpeningVote() public {
        address late = _holder("late", 25);
        _voteAs(s, late, REJECT);
        assertEq(vault.getDispute(s).votesReject, 25);
    }

    /// @dev Scenario 4: an NFT passed on after its vote does not vote again in this dispute; it does in the next.
    function test_TransferredAfterVote_NoSecondVote() public {
        _vote(s, 2, REJECT, 140, 10);
        vm.prank(voters[2]);
        nft.transferFrom(voters[2], bob, 140);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TokenVoted.selector, 140));
        vault.vote(s, ACCEPT, bob, _one(140));
        assertEq(vault.getDispute(s).votesAccept, 0);
        (, uint256 s2) = _newDispute();
        vm.prank(bob);
        vault.vote(s2, ACCEPT, bob, _one(140));
        assertEq(vault.getDispute(s2).votesAccept, 1);
    }

    /// @dev Scenario 5: a delegate.xyz hot wallet votes the cold wallet's NFTs; the owner cannot vote them again.
    function test_Delegate_VotesForTheOwner_IdsOnce() public {
        address hot = makeAddr("hot");
        vm.prank(hot);
        vm.expectRevert(abi.encodeWithSelector(NotTokenHolder.selector, 120));
        vault.vote(s, ACCEPT, hot, _ids(120, 20));
        vm.prank(voters[1]);
        delegates.delegateAll(hot, true);
        vm.prank(hot);
        vault.vote(s, ACCEPT, hot, _ids(120, 10));
        (uint256 acc,) = vault.votesOf(s, hot);
        assertEq(acc, 10);
        vm.prank(voters[1]);
        vm.expectRevert(abi.encodeWithSelector(TokenVoted.selector, 120));
        vault.vote(s, ACCEPT, voters[1], _ids(120, 20));
        // the owner votes the other 10 themselves
        vm.prank(voters[1]);
        vault.vote(s, ACCEPT, voters[1], _ids(130, 10));
        assertEq(vault.getDispute(s).votesAccept, 20);
    }

    /// @dev A delegation for one token id only covers that id.
    function test_Delegate_OneTokenOnly() public {
        address hot = makeAddr("hot");
        vm.prank(voters[1]);
        delegates.delegateERC721(hot, address(nft), 125, true);
        vm.prank(hot);
        vm.expectRevert(abi.encodeWithSelector(NotTokenHolder.selector, 126));
        vault.vote(s, REJECT, hot, _ids(125, 2));
        vm.prank(hot);
        vault.vote(s, REJECT, hot, _one(125));
        assertEq(vault.getDispute(s).votesReject, 1);
    }

    /// @dev Scenario 6: two transactions for the same side add up; the wallet counts once.
    function test_TwoTransactionsSameSide() public {
        vm.startPrank(voters[1]);
        vault.vote(s, REJECT, voters[1], _ids(120, 10));
        vault.vote(s, REJECT, voters[1], _ids(130, 9));
        vm.stopPrank();
        Dispute memory d = vault.getDispute(s);
        assertEq(d.votesReject, 19);
        assertEq(d.walletsReject, 1);
        (, uint256 rej) = vault.votesOf(s, voters[1]);
        assertEq(rej, 19);
        assertTrue(vault.hasVoted(s, voters[1]));
    }

    /// @dev Scenario 7: the side cannot change.
    function test_SideCannotChange() public {
        vm.startPrank(voters[1]);
        vault.vote(s, REJECT, voters[1], _ids(120, 10));
        vm.expectRevert(AlreadyVoted.selector);
        vault.vote(s, ACCEPT, voters[1], _ids(130, 10));
        vm.stopPrank();
        assertEq(vault.getDispute(s).votesAccept, 0);
        assertFalse(vault.tokenVoted(s, 130));
    }

    /// @dev Scenario 8: an id the sender neither owns nor holds a delegation for reverts the whole vote.
    function test_NotOwnId_RevertsAll() public {
        vm.prank(voters[2]);
        vm.expectRevert(abi.encodeWithSelector(NotTokenHolder.selector, 119));
        vault.vote(s, REJECT, voters[2], _ids(119, 2)); // 119 voter0's, 120 voter1's: ids voted first, then owners
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(NotTokenHolder.selector, 5_000)); // never minted
        vault.vote(s, REJECT, relayer, _one(5_000));
        assertEq(vault.getDispute(s).votesReject, 0);
        assertFalse(vault.tokenVoted(s, 140));
    }

    /// @dev Scenario 9: the same id twice in one list reverts; nothing counted.
    function test_RepeatInList_Reverts() public {
        uint256[] memory ids = new uint256[](3);
        ids[0] = 140;
        ids[1] = 141;
        ids[2] = 140;
        vm.prank(voters[2]);
        vm.expectRevert(abi.encodeWithSelector(TokenVoted.selector, 140));
        vault.vote(s, REJECT, voters[2], ids);
        assertEq(vault.getDispute(s).votesReject, 0);
        assertFalse(vault.hasVoted(s, voters[2]));
    }

    /// @dev Scenario 10: the batch that reaches +20 decides at once; the next batch reverts.
    function test_InstantDecision_NextBatchReverts() public {
        vm.startPrank(voters[0]);
        vault.vote(s, ACCEPT, voters[0], _ids(0, 19));
        assertEq(uint8(_phase(s)), uint8(Phase.Voting));
        vault.vote(s, ACCEPT, voters[0], _ids(19, 1));
        assertEq(uint8(_phase(s)), uint8(Phase.Decided));
        vm.expectRevert(WrongPhase.selector);
        vault.vote(s, ACCEPT, voters[0], _ids(20, 10));
        vm.stopPrank();
        assertEq(vault.getDispute(s).votesAccept, 20);
    }

    /// @dev Scenario 12 and bad arguments.
    function test_BadVotesRevert() public {
        vm.startPrank(voters[1]);
        vm.expectRevert(NoTokens.selector);
        vault.vote(s, REJECT, voters[1], new uint256[](0));
        vm.expectRevert(BadVote.selector);
        vault.vote(s, 3, voters[1], _one(120));
        vm.expectRevert(BadVote.selector);
        vault.vote(s, 0, voters[1], _one(120));
        vm.expectRevert(BadVote.selector);
        vault.vote(s, REJECT, address(0), _one(120));
        vm.stopPrank();
        assertEq(vault.getDispute(s).votesReject, 0);
    }

    function test_VotesAfterVoteEndRevert() public {
        _warp(24 hours);
        vm.prank(voters[1]);
        vm.expectRevert(WrongPhase.selector);
        vault.vote(s, REJECT, voters[1], _one(120));
    }

    function test_NoVoteWithoutDispute() public {
        uint256 t2 = _create(author, address(usdc), 100e6);
        uint256 s2 = _submit(doer2, t2);
        vm.prank(voters[1]);
        vm.expectRevert(WrongPhase.selector);
        vault.vote(s2, REJECT, voters[1], _one(120));
    }

    /// @dev A third party cannot vote a holder's NFTs: the sender is the voter; payTo only takes the reward.
    function test_OnlyTheHolderVotesHisNfts() public {
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(NotTokenHolder.selector, 120));
        vault.vote(s, REJECT, voters[1], _ids(120, 20));
        vm.prank(voters[2]);
        vault.vote(s, REJECT, bob, _ids(140, 10));
        (, uint256 rej) = vault.votesOf(s, bob);
        assertEq(rej, 10);
        (, rej) = vault.votesOf(s, voters[2]);
        assertEq(rej, 0);
        assertTrue(vault.hasVoted(s, voters[2]));
    }

    /// @dev An NFT in an escrow or staking contract votes with nobody (unless the escrow delegates it).
    function test_NftInEscrow() public {
        Escrow e = new Escrow();
        vm.prank(voters[2]);
        nft.transferFrom(voters[2], address(e), 140);
        vm.prank(voters[2]);
        vm.expectRevert(abi.encodeWithSelector(NotTokenHolder.selector, 140));
        vault.vote(s, REJECT, voters[2], _ids(140, 10));
        vm.prank(voters[2]);
        vault.vote(s, REJECT, voters[2], _ids(141, 9));
        assertEq(vault.getDispute(s).votesReject, 9);
    }

    /// @dev The batch mint of the test collection (MockNFT): one transaction, consecutive ids.
    function test_MockNft_MintBatch() public {
        address w = makeAddr("batch");
        nft.mintBatch(w, 50_000, 100);
        assertEq(nft.balanceOf(w), 100);
        assertEq(nft.ownerOf(50_099), w);
        vm.prank(w);
        vault.vote(s, REJECT, w, _ids(50_000, 100));
        assertEq(vault.getDispute(s).votesReject, 100);
    }

    // ================================================================== decisions

    /// @dev 20 votes on one side decide at once (instantDelta).
    function test_Instant_20Votes() public {
        _vote(s, 1, REJECT, 120, 20);
        assertEq(uint8(_phase(s)), uint8(Phase.Decided));
        assertEq(uint8(_sub(s).nftDecision), uint8(Verdict.Reject));
    }

    /// @dev 19 do not; 10 decide at the vote end (endDelta 10).
    function test_10Votes_DecideAtTheVoteEnd() public {
        address w19 = _holder("w19", 19);
        (uint256 t2, uint256 s2) = _newDispute();
        _voteAs(s2, w19, ACCEPT);
        assertEq(uint8(_phase(s2)), uint8(Phase.Voting), "19 < instantDelta");
        _vote(s, 2, REJECT, 140, 10);
        assertEq(uint8(_phase(s)), uint8(Phase.Voting));
        _warp(24 hours);
        vault.poke(t);
        vault.poke(t2);
        assertEq(uint8(_phase(s)), uint8(Phase.Decided));
        assertEq(uint8(_sub(s).nftDecision), uint8(Verdict.Reject));
        assertEq(uint8(_sub(s2).nftDecision), uint8(Verdict.Accept));
    }

    function test_5Votes_NoDecision() public {
        _vote(s, 3, REJECT, 150, 5); // 5 < endDelta 10
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.NoDecision));
    }

    /// @dev One wallet: with minWinnerWallets = 2 its 120 votes decide nothing.
    function test_OneWallet_MinWinnerWallets() public {
        Params memory p = defaultParams();
        p.minWinnerWallets = 2;
        vm.prank(multisig);
        registry.proposeParams(p);
        _warp(48 hours);
        registry.activateParams();
        vm.roll(vm.getBlockNumber() + 1);
        uint256 t2 = _create(author, address(usdc), 100e6);
        uint256 s2 = _submit(doer2, t2);
        _dispute(dave, s2);
        _vote(s2, 0, ACCEPT, 0, 120);
        assertEq(uint8(_phase(s2)), uint8(Phase.Voting));
        _warp(24 hours);
        vault.poke(t2);
        assertEq(uint8(_phase(s2)), uint8(Phase.NoDecision));
    }

    /// @dev One wallet with the default minWinnerWallets = 1 decides at once.
    function test_OneWallet_DecidesAlone() public {
        _vote(s, 0, ACCEPT, 0, 120);
        assertEq(uint8(_phase(s)), uint8(Phase.Decided));
        assertEq(uint8(_sub(s).nftDecision), uint8(Verdict.Accept));
    }

    // ================================================================== 2,000 NFTs

    /// @dev Only 2,000 NFTs exist in total, so there cannot be more than 2,000 votes: with every NFT of the
    ///      collection voting and some passed on to wallets that try again, the votes of a dispute never exceed 2,000.
    function test_TwoThousandNfts_NeverMoreVotes() public {
        // the 157 of setUp plus 1,843 fresh ones make 2,000 here
        address big = makeAddr("big");
        nft.mintBatch(big, 10_000, 1_843);
        Params memory p = defaultParams();
        p.instantDelta = 2_000; // never reached: every wallet can vote
        vm.prank(multisig);
        registry.proposeParams(p);
        _warp(48 hours);
        registry.activateParams();
        (, uint256 s2) = _newDispute();
        vm.prank(big);
        vault.vote(s2, REJECT, big, _ids(10_000, 1_000));
        // 30 voted ones go to `buyer`, who tries again
        address buyer = makeAddr("buyer");
        _send(big, buyer, 10_000, 30);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(TokenVoted.selector, 10_000));
        vault.vote(s2, ACCEPT, buyer, _ids(10_000, 30));
        vm.prank(big);
        vault.vote(s2, REJECT, big, _ids(11_000, 843));
        for (uint256 i; i < 5; ++i) {
            vm.prank(voters[i]);
            vault.vote(s2, ACCEPT, voters[i], held[voters[i]]);
        }
        Dispute memory d = vault.getDispute(s2);
        assertEq(uint256(d.votesAccept) + d.votesReject, 2_000);
        assertEq(d.votesReject, 1_843);
        assertEq(d.walletsReject, 1);
        assertEq(d.walletsAccept, 5);
    }

    /// @dev Fuzz: whatever ids a wallet sends, a dispute counts each id at most once.
    function testFuzz_EachIdOnce(uint8 a, uint8 b) public {
        uint256 na = uint256(a) % 21;
        uint256 nb = uint256(b) % 21;
        vm.assume(na + nb > 0);
        Params memory p = defaultParams();
        p.instantDelta = 2_000;
        vm.prank(multisig);
        registry.proposeParams(p);
        _warp(48 hours);
        registry.activateParams();
        (, uint256 s2) = _newDispute();
        if (na > 0) {
            vm.prank(voters[0]);
            vault.vote(s2, ACCEPT, voters[0], _ids(0, na));
        }
        // the first `nb` ids again (overlap with the first vote) revert; fresh ones count
        if (nb > 0 && na > 0) {
            vm.prank(voters[0]);
            vm.expectRevert(abi.encodeWithSelector(TokenVoted.selector, 0));
            vault.vote(s2, ACCEPT, voters[0], _ids(0, nb));
        }
        if (nb > 0) {
            vm.prank(voters[0]);
            vault.vote(s2, ACCEPT, voters[0], _ids(na, nb));
        }
        assertEq(vault.getDispute(s2).votesAccept, na + nb);
        assertEq(vault.getDispute(s2).walletsAccept, 1);
    }

    // ================================================================== rewards

    function test_VoterRewardSplitByCorrectVotes() public {
        // 20 + 10 correct accept votes, 5 wrong reject votes; reject and the smaller accept vote go first so the
        // running delta never reaches instantDelta (20) before every voter below is counted
        _vote(s, 3, REJECT, 150, 5);
        _vote(s, 2, ACCEPT, 140, 10);
        _vote(s, 1, ACCEPT, 120, 20);
        _warp(48 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        Settlement memory st = vault.getSettlement(s);
        assertEq(st.voterVotesLeft, 30);
        assertEq(st.voterFee, 5e6); // 5% of R in USDC
        assertEq(st.voterBond.imd, B / 2); // half of dave's bond.imd
        assertEq(st.voterBond.rew, 0.5e6, "half of dave's bond.rew");
        vm.expectRevert(NothingToClaim.selector);
        vault.claimVoterReward(s, voters[3]); // wrong side
        vault.claimVoterReward(s, voters[1]);
        vault.claimVoterReward(s, voters[2]);
        assertEq(usdc.balanceOf(voters[1]) - 1_000_000e6, 3_666_666); // 5.5 USDC x 20 / 30, rounded down
        assertEq(usdc.balanceOf(voters[2]) - 1_000_000e6, 1_833_334); // exact rest
        assertEq(imd.balanceOf(voters[1]) - 10_000e18, (B / 2) * 20 / 30);
        assertEq(imd.balanceOf(voters[2]) - 10_000e18, B / 2 - (B / 2) * 20 / 30); // exact rest
        assertTrue(vault.voterClaimed(s, voters[1]));
        vm.expectRevert(NothingToClaim.selector);
        vault.claimVoterReward(s, voters[1]);
        _claimEverythingAndCheck();
    }
}

/// @dev A staking / marketplace escrow holding NFTs.
contract Escrow {}
