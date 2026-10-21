// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./Base.t.sol";

/// @dev Every step is closed by its own timer, any caller can trigger the close, and the result is final:
///      there is no separate "stuck" fallback (the dev wallet's cancelTask is covered in CancelTask.t.sol).
/// forge-config: default.isolate = false
contract EmergencyTest is Base {
    /// @dev the fixed IMD part of every bond: never doubled, same for the doer and dispute bond.
    uint256 internal constant F = 0.5e18;

    uint256 internal t;
    uint256 internal s;
    uint256 internal s2;

    function setUp() public override {
        super.setUp();
        t = _create(author, address(usdc), 100e6);
        _topUp(alice, t, 50e6);
        s = _submit(doer, t);
        s2 = _submit(doer2, t); // queued
        _topUp(bob, t, 20e6); // pending
        _dispute(dave, s);
    }

    function test_AppealAskedLazily_ResolvesByTimer() public {
        _vote(s, 1, 1, 120, 20); // = instantDelta: decides at once
        _appeal(erin, s);
        _warp(12 hours + 31 days); // nobody asked within swarmTimeout (6 h): the appeal is void
        vm.expectRevert(WrongPhase.selector);
        _askAppealSwarm(s); // a late ask plays the timers first and finds the appeal void
        // void at appealedAt + 6 h: bond and fee back to erin, the new appeal window counts from the void (reaudit
        // logic #1), so it ended long before this poke: the NFT decision (accept) stands at once
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.Final));
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        _claimEverythingAndCheck();
    }

    function test_NoDecision_ResolvesItselfByTimer() public {
        _warp(24 hours); // vote over, no votes -> NoDecision, nobody calls the swarm
        _warp(31 days);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        assertFalse(vault.getSettlement(s).neutral);
        _claimEverythingAndCheck();
    }

    function test_SwarmNeverAnswers_ResolvesByTimer() public {
        _warp(24 hours);
        _callSwarm(erin, s);
        // the swarm never answers and nobody pokes for a long time: silence, then the undecided window ends
        _warp(40 days);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        assertEq(vault.credits(address(imd), erin), F); // her bond's fixed part back, the fee went to the swarm
        assertEq(vault.credits(address(usdc), erin), 1e6); // her bond's percent part back: 1% of the author's 100
        vault.claimVoidSubmission(s2);
        _claimEverythingAndCheck();
    }

    function test_ResolvesByTimer_WhenTheStateMachineCanResolve() public {
        _vote(s, 1, 1, 120, 20);
        _warp(24 hours + 24 hours + 31 days); // decided, appeal window over long ago
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        _claimEverythingAndCheck();
    }

    function _expectBack(address who, address token, uint256 amount) internal {
        uint256 before = IERC20(token).balanceOf(who);
        vm.prank(who);
        vault.withdrawContribution(t);
        assertEq(IERC20(token).balanceOf(who) - before, amount);
    }
}
