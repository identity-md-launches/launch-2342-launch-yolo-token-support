// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../Base.t.sol";

/// @dev Reaudit logic #7: in Phase.Asked, stepDeadline is askedAt + 6 h + grace while the request is pending, and
///      now once the Intake closed the request without an answer (the next poke declares the silence at once).
/// forge-config: default.isolate = false
contract StepDeadlineAskedTest is Base {
    uint256 internal t;
    uint256 internal s;

    function setUp() public override {
        super.setUp();
        t = _create(author, address(usdc), 100e6);
        s = _submit(doer, t);
        _dispute(dave, s);
        _warp(24 hours);
        _callSwarm(erin, s);
        assertEq(uint8(_phase(s)), uint8(Phase.Asked));
    }

    function test_Pending_IsTheSilenceDeadline() public view {
        uint256 askedAt = vault.requests(_sub(s).request).askedAt;
        assertEq(vault.stepDeadline(s), askedAt + 6 hours + SWARM_DELIVERY_GRACE);
    }

    function test_IntakeCompletedWithoutAnswer_IsDueNow() public {
        OracleAttestation.Attestation memory a;
        intake.complete(_sub(s).request, 1, a, ""); // refused by the body checks: no callback
        _warp(1 hours);
        assertEq(vault.stepDeadline(s), _now(), "the next poke plays the silence now");
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.NoDecision));
    }
}
