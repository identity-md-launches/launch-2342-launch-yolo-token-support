// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../Base.t.sol";
import {ParamsBounds} from "../../src/VaultParams.sol";

/// @dev What the contract accepts as a swarm answer. We pay for a panel of 7 agents with a quorum of 5
///      (`bodyFields`: `"panelSize":7,"quorum":5`). An answer check that looked only at `agreed >= quorum`, where
///      both numbers come from the attestation itself, would let a "1 of 1" answer close an appeal and reject a
///      submission with a deposit (the same rule applies to any question to the
///      swarm).
///      Guard: the parameters `minPanelSize = 7` and `minQuorum = 5` (paired with bodyFields, hard limits, changed
///      through a 48 h timelock). An attestation of a smaller panel or quorum is not a verdict: it is discarded
///      (code 14), the question ends in the swarm's silence, the money stays with those who put it in.
/// forge-config: default.isolate = false
contract ReviewAttestation is Base {
    function setUp() public override {
        super.setUp();
    }

    /// @dev Appeal: a "1 of 1" is discarded, the swarm stayed silent, the NFT decision stands, the appellant gets
    ///      their deposit and fee back.
    function test_OnePersonPanelIsSilenceOnAppeal() public {
        (uint256 taskId, uint256 subId) = _disputedAndDecided();
        _appeal(dave, subId);
        _warp(1 hours); // asked inside swarmTimeout (6 h): a later ask finds the appeal void
        _askAppealSwarm(subId); // lazy ask
        assertEq(uint8(_sub(subId).phase), uint8(Phase.Asked));
        (bytes memory body,) = vault.previewSwarmBody(subId, 3, _genericRuleTexts());
        assertTrue(_has(body, '"panelSize":7,"quorum":5'));

        bytes32 rid = _sub(subId).request;
        OracleAttestation.Attestation memory a = _onePerson(false);
        vm.expectEmit(true, false, false, true, address(vault));
        emit AttestationIgnored(rid, 14);
        intake.complete(rid, 0, a, _sign(a, attesterKey));
        assertFalse(_req(subId).answered);

        vault.poke(taskId); // Intake reports the request completed without an answer we accept: silence
        assertEq(uint8(_sub(subId).outcome), uint8(Outcome.None));
        assertEq(uint8(_sub(subId).phase), uint8(Phase.Decided));
        // the disputer's own appeal: no second bond to return, the fee their bond paid is spent
        assertEq(vault.credits(address(imd), dave), 0);
        assertEq(vault.getAppeal(subId).appellant, address(0));
    }

    /// @dev There is no mandatory check for a large submission; the same rule applies to a paid call to the swarm
    ///      without an NFT decision: a "1 of 1 no" answer means silence, again a window with no decision,
    ///      the caller's bond back, the submission not rejected.
    function test_OnePersonPanelIsSilenceOnCall() public {
        (uint256 taskId, uint256 subId) = _calledCase();
        Bond memory bond = _sub(subId).bond;

        OracleAttestation.Attestation memory a = _onePerson(false);
        intake.complete(_sub(subId).request, 0, a, _sign(a, attesterKey));
        assertFalse(_req(subId).answered);

        vault.poke(taskId);
        assertEq(uint8(_sub(subId).outcome), uint8(Outcome.None));
        assertEq(uint8(_sub(subId).phase), uint8(Phase.NoDecision));
        assertEq(_sub(subId).callFrom, _now(), "a new window to call from the silence");
        Bond memory quoted = vault.quoteDisputeBond(subId);
        assertEq(vault.credits(address(imd), erin), quoted.imd, "the caller's bond's fixed part back");
        assertEq(vault.credits(address(usdc), erin), quoted.rew, "the caller's bond's percent part back");
        assertEq(_sub(subId).bond.imd, bond.imd);
        assertEq(_sub(subId).bond.rew, bond.rew);
    }

    /// @dev A panel of 7, but a quorum below the ordered one (4 of 7): also not a verdict.
    function test_QuorumBelowOrderedIsIgnored() public {
        uint256 subId = _called();
        OracleAttestation.Attestation memory a = _attestation(false);
        a.quorum = 4;
        a.agreed = 4;
        intake.complete(_sub(subId).request, 0, a, _sign(a, attesterKey));
        assertFalse(_req(subId).answered);
    }

    /// @dev Agreeing fewer than the quorum, quorum bigger than the panel, agreeing more than the panel: discarded.
    function test_InconsistentCountsAreIgnored() public {
        uint16[3][3] memory bad = [[uint16(7), 5, 4], [uint16(7), 8, 8], [uint16(7), 5, 8]];
        for (uint256 k; k < bad.length; ++k) {
            uint256 subId = _called();
            OracleAttestation.Attestation memory a = _attestation(false);
            (a.panelSize, a.quorum, a.agreed) = (bad[k][0], bad[k][1], bad[k][2]);
            intake.complete(_sub(subId).request, 0, a, _sign(a, attesterKey));
            assertFalse(_req(subId).answered);
        }
    }

    /// @dev The ordered panel answers: 7 / 5 / 5, and a panel bigger than ordered (9 / 6 / 6), are accepted.
    function test_OrderedPanelCounts() public {
        uint256 subId = _called();
        OracleAttestation.Attestation memory a = _attestation(true);
        (a.panelSize, a.quorum, a.agreed) = (7, 5, 5);
        intake.complete(_sub(subId).request, 0, a, _sign(a, attesterKey));
        assertTrue(_req(subId).answered);

        subId = _called();
        a = _attestation(true);
        (a.panelSize, a.quorum, a.agreed) = (9, 6, 6);
        intake.complete(_sub(subId).request, 0, a, _sign(a, attesterKey));
        assertTrue(_req(subId).answered);
    }

    /// @dev There is no public fallback path: neither a "1 of 1" nor the ordered panel passes through
    ///      it, the answer arrives only by callback.
    function test_NoFallback_NeitherOnePersonNorOrderedPanel() public {
        uint256 subId = _called();
        bytes32 rid = _sub(subId).request;
        OracleAttestation.Attestation memory a = _onePerson(false);
        a.questionHash = _req(subId).questionHash;
        intake.completeWithoutCallback(rid);
        _expectNoFallback(rid, a, _sign(a, attesterKey));
        a.panelSize = 7;
        a.quorum = 5;
        a.agreed = 5;
        _expectNoFallback(rid, a, _sign(a, attesterKey));
        assertFalse(_req(subId).answered);
    }

    /// @dev Hard limits: a panel from 3, a quorum of a strict majority and no more than the panel, both exactly as
    ///      in bodyFields.
    function test_PanelBounds() public {
        _expectBound(_withPanel(2, 2, '"panelSize":2,"quorum":2,'), "minPanelSize");
        _expectBound(_withPanel(102, 60, '"panelSize":102,"quorum":60,'), "minPanelSize");
        _expectBound(_withPanel(7, 3, '"panelSize":7,"quorum":3,'), "minQuorum");
        _expectBound(_withPanel(7, 8, '"panelSize":7,"quorum":8,'), "minQuorum");
        _expectBound(_withPanel(7, 5, '"panelSize":9,"quorum":5,'), "bodyPanel");
        _expectBound(_withPanel(7, 5, '"panelSize":7,"quorum":50,'), "bodyQuorum");
        _expectBound(_withPanel(7, 5, '"panelSize":7,'), "bodyQuorum");
        // quorum as the last member (no comma after it) is fine
        Params memory p = _withPanel(9, 6, '"panelSize":9,"quorum":6');
        vm.prank(multisig);
        registry.proposeParams(p);
    }

    /// @dev The panel changes like any parameter: through a 48 h timelock, and only for new tasks.
    function test_PanelChangeWaitsTimelock() public {
        uint256 oldTask = _create(author, address(usdc), 50e6);
        Params memory p = _withPanel(9, 6, '"panelSize":9,"quorum":6,');
        vm.prank(multisig);
        registry.proposeParams(p);
        vm.expectRevert(ParamsRegistry.TimelockNotPassed.selector);
        registry.activateParams();
        _warp(48 hours);
        registry.activateParams();
        assertEq(registry.params(registry.currentVersion()).minPanelSize, 9);
        assertEq(vault.paramsOf(vault.getTask(oldTask).paramsVersion).minPanelSize, 7, "an old task keeps its panel");
        uint256 newTask = _create(author, address(usdc), 50e6);
        assertEq(vault.paramsOf(vault.getTask(newTask).paramsVersion).minPanelSize, 9);
    }

    // ================================================================== helpers

    function _onePerson(bool answer) internal view returns (OracleAttestation.Attestation memory a) {
        a = _attestation(answer);
        (a.panelSize, a.quorum, a.agreed) = (1, 1, 1);
    }

    function _withPanel(uint16 panel, uint16 quorum, bytes memory bodyHead) internal view returns (Params memory p) {
        p = defaultParams();
        p.minPanelSize = panel;
        p.minQuorum = quorum;
        p.bodyFields = bytes.concat('"chainId":1,"answerType":"bool",', bodyHead, '"validForSeconds":2592000');
        if (bodyHead[bodyHead.length - 1] != ",") p.bodyFields = bytes.concat('"chainId":1,', bodyHead);
    }

    function _expectBound(Params memory p, string memory field) internal {
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(ParamsBounds.ParamOutOfBounds.selector, field));
        registry.proposeParams(p);
    }

    /// @dev A submission with a question posed to the swarm (a paid call without an NFT decision).
    function _called() internal returns (uint256 subId) {
        (, subId) = _calledCase();
    }

    function _calledCase() internal returns (uint256 taskId, uint256 subId) {
        taskId = _create(author, address(usdc), 400e6);
        subId = _submit(doer, taskId);
        _dispute(dave, subId);
        _warp(24 hours); // nobody voted: NoDecision
        _callSwarm(erin, subId);
        assertEq(uint8(_sub(subId).phase), uint8(Phase.Asked));
    }

    /// @dev A task, a dispute, NFT holders decide for the doer (phase Decided).
    function _disputedAndDecided() internal returns (uint256 taskId, uint256 subId) {
        taskId = _create(author, address(usdc), 50e6);
        subId = _submit(doer, taskId);
        _dispute(dave, subId);
        _warp(12 hours + 1);
        vault.poke(taskId);
        _vote(subId, 0, VoteLib.SIDE_ACCEPT, 0, 120); // voter0: 120 votes for the doer
        _endVote(subId); // decided at the vote end
        assertEq(uint8(_sub(subId).phase), uint8(Phase.Decided));
    }

    function _req(uint256 subId) internal view returns (SwarmRequest memory) {
        return vault.requests(_sub(subId).request);
    }

    function _has(bytes memory hay, bytes memory needle) internal pure returns (bool) {
        if (needle.length > hay.length) return false;
        for (uint256 i; i <= hay.length - needle.length; ++i) {
            bool ok = true;
            for (uint256 j; j < needle.length; ++j) {
                if (hay[i + j] != needle[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }
}
