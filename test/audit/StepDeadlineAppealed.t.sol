// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "../Base.t.sol";
import "../../src/VaultTypes.sol";

/// @dev Finding (swarm logic audit, low): stepDeadline returned appealedAt in Phase.Appealed, a moment already
///      past. The real timer is the void at appealedAt + swarmTimeout (6 h): an appeal not asked by then is void.
/// forge-config: default.isolate = false
contract StepDeadlineAppealedTest is Base {
    function test_StepDeadlineAppealed_IsVoidMoment() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        _dispute(dave, s);
        _vote(s, 1, 2, 120, 20); // 20 NFT reject
        _endVote(s);
        assertEq(uint8(_phase(s)), uint8(Phase.Decided));
        _appeal(doer, s);
        uint256 t0 = _now();
        assertEq(uint8(_phase(s)), uint8(Phase.Appealed));
        assertEq(vault.stepDeadline(s), t0 + 6 hours, "void moment: appealedAt + swarmTimeout");
        vm.warp(t0 + 6 hours - 1);
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.Appealed), "still open one second before");
        vm.warp(t0 + 6 hours);
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.Decided), "void at the deadline");
    }
}
