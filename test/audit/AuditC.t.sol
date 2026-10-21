// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../Base.t.sol";
import {TextLib} from "../../src/helpers/TextRules.sol";

/// @dev An ERC-1271 "wallet" that says "valid" in a simulation (eth_call / eth_estimateGas run with gas price 0) and
/// burns every unit of gas it gets in a real transaction. It needs no NFT to poison a batch: the signature is
/// checked before ownership.
contract GasBurner1271 {
    function isValidSignature(bytes32, bytes calldata) external view returns (bytes4) {
        if (tx.gasprice == 0) return 0x1626ba7e;
        uint256 x;
        while (true) {
            x = uint256(keccak256(abi.encode(x)));
        }
        return 0x1626ba7e;
    }
}

/// @dev A plain contract wallet: valid if its owner key signed the hash.
contract OwnerWallet1271 {
    address public immutable owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function isValidSignature(bytes32 h, bytes calldata sig) external view returns (bytes4) {
        (uint8 v, bytes32 r, bytes32 s) = (uint8(sig[64]), bytes32(sig[0:32]), bytes32(sig[32:64]));
        return ecrecover(h, v, r, s) == owner ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

/// @dev Harness: TextLib.validText against a byte-by-byte reference implementation.
contract TextHarness {
    function fast(string calldata s, uint256 maxLen) external pure returns (bool) {
        return TextLib.validText(s, maxLen);
    }
}

/// @title Submission and dispute checks: regression tests and guards.
/// forge-config: default.isolate = false
contract AuditCTest is Base {
    uint8 internal constant ACCEPT = 1;
    uint8 internal constant REJECT = 2;

    function _contains(bytes memory hay, bytes memory needle) internal pure returns (bool) {
        if (needle.length > hay.length) return false;
        for (uint256 i; i <= hay.length - needle.length; ++i) {
            uint256 k;
            while (k < needle.length && hay[i + k] == needle[k]) ++k;
            if (k == needle.length) return true;
        }
        return false;
    }

    function _disputeWith(address who, uint256 subId, string memory reason, uint256) internal {
        vm.prank(who);
        vault.dispute(subId, reason, DISPUTER_PROOF, _noSwap());
    }

    // =====================================================================================================
    // The inputs of a swarm question are first-come: the side the question is meant to hear can be
    // locked out of it (appeal / call slot, first maxClaims reasons). An appeal carries no text, so the doer's own
    // appeal adds nothing to the question (below);
    // the Sybil remainder is acknowledged.
    // =====================================================================================================

    /// @dev The doer cannot dispute his own submission, and there is no opponent-reply step: the appeal question
    /// (asked lazily by askAppealSwarm) carries only the real disputer's claim
    /// and the doer's own note (Evidence.note, written at submission): there is no reply slot to steal.
    function test_Guard_DoerCannotAnswerHisOwnAppealInTheNameOfTheDisputers() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        vm.deal(doer, 1 ether);
        vm.prank(doer); // the doer tries to dispute himself first
        vm.expectRevert(DoerCannotDispute.selector);
        vault.dispute(s, "placeholder", "placeholder-proof", _noSwap());
        _disputeWith(dave, s, "The post was published before the task was created", 0.001 ether);
        _vote(s, 0, REJECT, 0, 120); // the NFT holders agree with dave
        _endVote(s); // decided at the vote end: reject
        assertEq(uint8(_phase(s)), uint8(Phase.Decided));

        // Appeal carries no text of its own - the doer cannot
        // smuggle "My proof is valid" into the question through it. The ask is lazy -
        // appeal only files it; askAppealSwarm resupplies rt and asks, so the preview is taken before that call.
        RuleTexts memory rt = _genericRuleTexts();
        rt.disputeReason = "The post was published before the task was created";
        rt.disputerProofUri = DISPUTER_PROOF;
        (bytes memory body,) = vault.previewSwarmBody(s, SWARM_KIND_APPEAL, rt);
        vm.prank(doer);
        vault.appeal(s, type(uint256).max, _noSwap());
        assertTrue(vault.getAppeal(s).sidesDoer);
        assertEq(uint8(_phase(s)), uint8(Phase.Appealed));
        vault.askAppealSwarm(s, rt); // lazy ask
        assertEq(uint8(_phase(s)), uint8(Phase.Asked));
        assertEq(intake.lastBodyHash(), keccak256(body), "this is the body the swarm got");
        assertTrue(_contains(body, bytes('"claim_1":"The post was published before the task was created"')));
        assertFalse(_contains(body, bytes("My proof is valid")), "no text channel for the doer's own appeal");
        assertFalse(_contains(body, bytes("withdraw the claim")));
        assertFalse(_contains(body, bytes("placeholder")), "no claim of the doer");
    }

    // =====================================================================================================
    // Mixing sides in a relayed batch does not survive a public mempool: anyone can lift
    // one side's ballots out of the pending batch and relay them first. So nobody
    // relays another voter's ballot.
    // =====================================================================================================

    /// @dev A vote counts only from the holder's own transaction. Honest votes:
    /// 120 accept + 115 reject (margin 5, no decision at the vote end). A front-runner without a single NFT
    /// copies the 120-accept ballot out of the mempool and sends it first to trigger the instant decision
    /// (120 >= instantDelta 20): it reverts, nothing is counted, the vote stays open. The holders' own votes
    /// land and the vote end gives the full-count result: no decision.
    function test_Guard_FrontRunnerCannotLiftABallotAndDecide() public {
        uint256 rKey = 0xB0B6;
        address rVoter = vm.addr(rKey);
        for (uint256 id = 1000; id < 1115; ++id) {
            nft.mint(rVoter, id);
        }
        vm.roll(vm.getBlockNumber() + 1);
        actors.push(rVoter); // claims his voter reward at the end
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        _dispute(dave, s);

        Ballot[] memory acceptBallot = new Ballot[](1);
        acceptBallot[0] = _ballot(s, 0, ACCEPT, _ids(0, 120), voters[0]);
        Ballot[] memory rejectBallot = new Ballot[](1);
        rejectBallot[0] = _ballotByKey(s, rKey, REJECT, _ids(1000, 115), rVoter, _sub(s).voteEnd);

        vm.fee(1 gwei);
        address frontRunner = makeAddr("frontRunner");
        vm.prank(frontRunner);
        vm.expectPartialRevert(NotTokenHolder.selector);
        _submitVotes(s, acceptBallot);
        assertEq(uint8(_phase(s)), uint8(Phase.Voting), "a lifted ballot decides nothing");
        assertEq(uint8(_sub(s).nftDecision), uint8(Verdict.None));
        assertEq(vault.getDispute(s).votesAccept, 0, "and counts nothing");

        // only holders' own votes count: here the reject holder votes first, and his own 115 decide at once
        // (each holder sends his own vote with the ids of NFTs he holds; nobody votes another's NFTs)
        vm.prank(rVoter);
        _submitVotes(s, rejectBallot);
        assertEq(uint8(_phase(s)), uint8(Phase.Decided), "115 of the holder themselves: instant decision");
        assertEq(uint8(_sub(s).nftDecision), uint8(Verdict.Reject));
        assertEq(vault.getDispute(s).votesAccept, 0, "the front-runner's lift never counted");
        _claimEverythingAndCheck();
    }

    /// @dev The mixed case: both holders vote themselves in an order that never crosses instantDelta on the
    /// way; the front-runner's attempts to lift either ballot revert; the full count decides at the vote end.
    function test_Guard_HoldersOwnVotesDecideAtTheVoteEnd() public {
        uint256 rKey = 0xB0B6;
        address rVoter = vm.addr(rKey);
        for (uint256 id = 1000; id < 1015; ++id) {
            nft.mint(rVoter, id);
        }
        address aVoter = _holder("acceptHolder", 19);
        actors.push(rVoter);
        actors.push(aVoter);
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        _dispute(dave, s);

        Ballot[] memory acceptBallot = new Ballot[](1);
        acceptBallot[0] =
            Ballot({voter: aVoter, side: ACCEPT, payTo: aVoter, tokenIds: new uint256[](0), signature: ""});
        Ballot[] memory rejectBallot = new Ballot[](1);
        rejectBallot[0] = _ballotByKey(s, rKey, REJECT, _ids(1000, 15), rVoter, _sub(s).voteEnd);

        address frontRunner = makeAddr("frontRunner");
        vm.prank(frontRunner);
        vm.expectPartialRevert(NotTokenHolder.selector);
        _submitVotes(s, rejectBallot);
        vm.prank(aVoter);
        _submitVotes(s, acceptBallot); // 19 < instantDelta
        vm.prank(frontRunner);
        vm.expectPartialRevert(TokenVoted.selector); // the ids already voted; not his anyway
        _submitVotes(s, acceptBallot);
        vm.prank(rVoter);
        _submitVotes(s, rejectBallot);
        assertEq(vault.getDispute(s).votesAccept, 19);
        assertEq(vault.getDispute(s).votesReject, 15);
        _endVote(s);
        assertEq(uint8(_phase(s)), uint8(Phase.NoDecision), "the full count: margin 4 < endDelta, no decision");
        _claimEverythingAndCheck();
    }

    // =====================================================================================================
    // One ERC-1271 ballot could make a whole vote batch revert ("bad ballots are skipped, never revert")
    // =====================================================================================================

    /// @dev A vote carries no signature, so no ERC-1271 call is made at all and there is no batch to
    /// poison: each holder (EOA or contract wallet) sends his own vote. A gas-burning wallet with no NFT reverts
    /// at the ownership check, alone; the honest holder's own vote counts.
    function test_NoBatchToPoison() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        _dispute(dave, s);
        GasBurner1271 b1 = new GasBurner1271();
        vm.txGasPrice(1 gwei);
        vm.prank(address(b1));
        vm.expectPartialRevert(NotTokenHolder.selector);
        vault.vote(s, ACCEPT, address(b1), _ids(120, 20));
        _vote(s, 1, REJECT, 120, 20);
        assertEq(vault.getDispute(s).votesReject, 20, "the honest holder's own vote counts");
    }

    /// @dev A contract wallet that holds NFTs votes by sending the vote itself (no ERC-1271 signature).
    function test_Fix_ContractWalletVotesItself() public {
        // contract wallets send their NFT ids themselves (a vote names the NFT ids)
        GasBurner1271 burner = new GasBurner1271();
        nft.mint(address(burner), 9000);
        OwnerWallet1271 w = new OwnerWallet1271(vm.addr(0xC0FFEE));
        for (uint256 id = 9100; id < 9105; ++id) {
            nft.mint(address(w), id);
        }
        vm.roll(vm.getBlockNumber() + 1);
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        _dispute(dave, s);
        vm.txGasPrice(1 gwei);
        vm.prank(address(burner));
        vault.vote{gas: 16_000_000}(s, ACCEPT, address(burner), _ids(9000, 1));
        assertEq(vault.getDispute(s).votesAccept, 1, "its isValidSignature is never called");

        vm.prank(address(w));
        vault.vote(s, ACCEPT, address(w), _ids(9100, 5));
        assertEq(vault.getDispute(s).votesAccept, 6, "contract wallet counted");
        (uint256 acc,) = vault.votesOf(s, address(w));
        assertEq(acc, 5);
    }

    // =====================================================================================================
    // Checked: the word-at-a-time ASCII path of TextLib.validText equals a byte-by-byte reference
    // =====================================================================================================

    /// @dev English only, printable ASCII 0x20..0x7e, no quote/backslash; any byte >= 0x80 (a UTF-8
    /// continuation included) is rejected outright.
    function _refValid(bytes memory b, uint256 maxLen) internal pure returns (bool) {
        uint256 len = b.length;
        if (len == 0 || len > maxLen) return false;
        for (uint256 i; i < len; ++i) {
            uint8 c = uint8(b[i]);
            if (c < 0x20 || c >= 0x7f || c == 0x22 || c == 0x5c) return false;
        }
        return true;
    }

    function testFuzz_ValidTextMatchesReference(bytes memory raw, uint8 mode, uint8 at) public {
        TextHarness h = new TextHarness();
        // mostly printable ASCII (to exercise the 32-byte path), with one injected byte
        bytes memory b = new bytes(raw.length % 200 + 1);
        for (uint256 i; i < b.length; ++i) {
            b[i] = bytes1(uint8(0x20 + uint8(i < raw.length ? raw[i] : bytes1(0)) % 0x5f));
        }
        if (mode % 3 == 0) b[at % b.length] = bytes1(uint8(raw.length != 0 ? raw[0] : bytes1(0)));
        else if (mode % 3 == 1) b[at % b.length] = bytes1(uint8(mode));
        assertEq(h.fast(string(b), 256), _refValid(b, 256));
        assertEq(h.fast(string(raw), 256), _refValid(raw, 256));
    }
}
