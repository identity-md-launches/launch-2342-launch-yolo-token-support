// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../Base.t.sol";

/// @dev Swarm answers only through the Intake callback, votes only from the holder's own transaction,
///      the doer never disputes his own submission. Errors are matched by signature.
/// forge-config: default.isolate = false
contract AuditNoFallbackOwnVoteTest is Base {
    uint8 internal constant ACCEPT = 1;
    uint8 internal constant REJECT = 2;

    /// @dev No public fallback for swarm answers. The swarm caller's question gets a "no", but the Intake
    ///      callback fails (out of gas). Nobody can hand the signed answer in another way: `submitAttestation` is an
    ///      unknown selector, the lost callback is silence and the undecided rule accepts (the disputer bond to the doer).
    function test_LostCallbackIsSilence_NoPublicFallback() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        _dispute(dave, s);
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.NoDecision));
        _callSwarm(erin, s); // against the doer
        bytes32 rid = _sub(s).request;

        intake.setCallbackGas(5_000); // the callback runs out of gas
        OracleAttestation.Attestation memory a = _attestation(false);
        a.questionHash = vault.requests(rid).questionHash; // bound to our exact question
        bytes memory sig = _sign(a, attesterKey);
        intake.complete(rid, 0, a, sig);
        assertFalse(intake.lastDelivered());

        (bool ok, bytes memory ret) =
            address(vault).call(abi.encodeCall(IAttestationFallback.submitAttestation, (rid, a, sig)));
        assertFalse(ok, "there is no public fallback");
        assertEq(bytes4(ret), UnknownFunction.selector);
        assertFalse(vault.requests(rid).answered, "the lost answer is not recorded");

        vault.poke(t); // the Intake reports the request completed without an answer: silence
        assertEq(uint8(_phase(s)), uint8(Phase.NoDecision));
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted), "undecided rule, not the undelivered no");
        _claimEverythingAndCheck();
    }

    /// @dev A partial count lifted out of the mempool by someone without the NFTs decides nothing. A margin
    ///      >= instantDelta (20) decides at once, so the guarantee is that a
    ///      120-accept ballot sent by anyone but its holder reverts, nothing is counted and the vote stays open for
    ///      the other side. Only the holder themself can cast it (and then the instant decision applies to their own vote).
    function test_PartialCountRelayedByAnOutsiderDecidesNothing() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        _dispute(dave, s);

        Ballot[] memory bs = new Ballot[](1);
        bs[0] = _ballot(s, 0, ACCEPT, _ids(0, 120), voters[0]);
        vm.prank(relayer);
        vm.expectPartialRevert(NotTokenHolder.selector);
        _submitVotes(s, bs);
        // (a ballot carries no tokenIds; another holder sending it votes only their own power)
        assertEq(uint8(_phase(s)), uint8(Phase.Voting), "no decision from a relayed partial count");
        assertEq(uint8(_sub(s).nftDecision), uint8(Verdict.None));
        assertEq(vault.getDispute(s).votesAccept, 0);

        _vote(s, 1, REJECT, 120, 14); // the other side still lands
        assertEq(vault.getDispute(s).votesReject, 14);
        assertEq(uint8(_phase(s)), uint8(Phase.Voting));
        _endVote(s);
        assertEq(uint8(_phase(s)), uint8(Phase.Decided), "the full count: 14 reject >= endDelta");
        assertEq(uint8(_sub(s).nftDecision), uint8(Verdict.Reject));
        _claimEverythingAndCheck();
    }

    /// @dev A margin under instantDelta still decides nothing until the vote end, and the full count then
    ///      applies endDelta (numbers chosen so the accept side alone
    ///      never crosses instantDelta: 19 accept, 14 reject, final margin 5 < endDelta 10).
    function test_NoDecisionBelowInstantDelta() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        _dispute(dave, s);

        _vote(s, 0, ACCEPT, 0, 19); // < instantDelta (20): no decision
        assertEq(uint8(_phase(s)), uint8(Phase.Voting), "no decision below instantDelta");
        assertEq(uint8(_sub(s).nftDecision), uint8(Verdict.None));

        _vote(s, 1, REJECT, 120, 14); // margin now 5: still < instantDelta, no decision
        assertEq(uint8(_phase(s)), uint8(Phase.Voting), "no decision on a partial count");
        assertEq(vault.getDispute(s).votesReject, 14);

        vm.warp(_sub(s).voteEnd - 1);
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.Voting));
        _endVote(s);
        assertEq(uint8(_phase(s)), uint8(Phase.NoDecision), "the full count: margin 5 < endDelta");
        _claimEverythingAndCheck();
    }

    /// @dev The doer cannot dispute his own submission, so he can never answer an appeal "as a disputer".
    ///      There is no opponent-reply step either: the appeal question is asked lazily by askAppealSwarm.
    function test_DoerCannotDispute() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        vm.prank(doer);
        vm.expectRevert(abi.encodeWithSignature("DoerCannotDispute()"));
        vault.dispute(s, "placeholder", "placeholder-proof", _noSwap());
        assertEq(vault.getDisputer(s, doer).bond.imd, 0);
        assertEq(uint8(_phase(s)), uint8(Phase.Review), "no vote started by the doer");

        _dispute(dave, s);
        _vote(s, 0, REJECT, 0, 120);
        if (_phase(s) == Phase.Voting) _endVote(s); // decided either way
        assertEq(uint8(_phase(s)), uint8(Phase.Decided));
        _appeal(doer, s); // sides with the doer: the opponents are the disputers
        _askAppealSwarm(s); // lazy ask
        assertEq(uint8(_phase(s)), uint8(Phase.Asked));
        _claimEverythingAndCheck();
    }
}
