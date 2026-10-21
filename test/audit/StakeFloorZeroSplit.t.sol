// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base} from "../Base.t.sol";
import "../../src/VaultTypes.sol";

/// @dev Finding (swarm money audit, medium): a doer with a running lock whose bonus floors to 0 bps was settled
///      by the no-stake split (treasury 10%). Rule: any power is a stake, no threshold; the stakers'
///      5% minus b goes half to the burn, half to the treasury, and the NFT 5% nobody earned is burned.
/// forge-config: default.isolate = false
contract StakeFloorZeroSplitTest is Base {
    /// @dev $100 USDC at YOLO $0.0001 = 1M $YOLO; 1 bp needs power >= 2,500 YOLO. 2,000 for a year: b = 0.8 -> 0 bps.
    function test_StakeFlooredToZero_UsesStakedSplit() public {
        vm.prank(doer);
        hub.lock(2_000e18, 52);
        _warp(1);
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        assertEq(_sub(s).stakeBps, 0, "b floors to 0 bps");
        assertTrue(_sub(s).staked, "a lock with power is a stake");
        _warp(24 hours);
        vault.poke(t);
        assertEq(vault.getSettlement(s).stakeBps, 0);
        assertEq(vault.credits(address(usdc), doer), 90e6 + 3e6, "90% plus his rew bond back");
        assertEq(usdc.balanceOf(buybackWallet), 7.5e6, "burn 7.5% of R: half of the stakers' 5% + the NFT 5%");
        assertEq(vault.treasuryPot(address(usdc)), 2.5e6, "treasury 2.5% of R");
        _claimEverythingAndCheck();
    }

    /// @dev Control: no lock at all keeps the no-stake split (treasury 10%, nothing to the burn).
    function test_NoLock_NoStakeSplit() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        assertFalse(_sub(s).staked);
        _warp(24 hours);
        vault.poke(t);
        assertEq(vault.credits(address(usdc), doer), 90e6 + 3e6);
        assertEq(usdc.balanceOf(buybackWallet), 0);
        assertEq(vault.treasuryPot(address(usdc)), 10e6);
        _claimEverythingAndCheck();
    }
}
