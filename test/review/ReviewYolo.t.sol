// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";

import {Base} from "../Base.t.sol";
import {MockStarter} from "../mocks/MockStarter.sol";

import {YoloToken} from "../../src/token/YoloToken.sol";
import {ProjectVesting} from "../../src/token/ProjectVesting.sol";
import {NftGate} from "../../src/token/NftGate.sol";
import {MockNFT} from "../mocks/MockNFT.sol";
import "../../src/VaultTypes.sol";
import {rulesOf, rulesForehead, rulesSupermarket, TEST_RULE_PROOF, TEST_RULE_NO} from "../mocks/TaskRulesFixture.sol";

/// @dev The vesting clock and the NFT gate. The $YOLO price is a dev parameter (DevPrices), not a sampled TWAP,
///      so there is no pool window, floor or sandwich to attack.
contract ReviewYoloUnit is Test {
    /// ProjectVesting: no cliff anywhere. The unlocked part is free at once, the rest streams
    /// linearly from the token's arrival: the first `release` while the vesting holds it starts the clock.
    /// The vesting is deployed in launch 0 and knows no token in advance.
    function test_vestingStreamsFromArrivalWithoutACliff() public {
        YoloToken t = new YoloToken(address(0xBEEF), address(0), address(0x5AFE), block.timestamp);
        address multisig = address(0xA11CE);
        // the YoloSplitter's place: the only starter (swarm audit 117cf05a #2)
        MockStarter st = new MockStarter(
            abi.encodePacked(type(ProjectVesting).creationCode, abi.encode(multisig, 150_000_000e18, 365 days))
        );
        ProjectVesting v = ProjectVesting(st.vesting());
        t.transfer(address(v), 700_000_000e18);
        assertEq(v.releasable(address(t)), 150_000_000e18);
        skip(1 days);
        assertEq(v.releasable(address(t)), 150_000_000e18, "no clock before the first release");
        st.start(address(t)); // YoloSplitter.split does this right after paying the vestings
        assertEq(t.balanceOf(multisig), 150_000_000e18);
        skip(1 days);
        assertEq(v.releasable(address(t)), uint256(550_000_000e18) * 1 days / 365 days);
        skip(364 days - 1);
        assertLt(v.releasable(address(t)) + t.balanceOf(multisig), 700_000_000e18);
        skip(1);
        assertEq(v.releasable(address(t)) + t.balanceOf(multisig), 700_000_000e18, "all vested at day 365");
    }

    /// The NFT gate: in the first 30 minutes the gate checks the RECEIVER of
    /// the transfer out of the PoolManager. A route that takes the output to a router first is refused even for a
    /// snapshot wallet (the router is not in the snapshot), and the reason survives as NotWhitelisted(router); the
    /// Universal Router's TAKE_ALL pays the buyer directly and passes (fork: LaunchRehearsal).
    function test_whitelistRefusesOutputTakenToARouter() public {
        address poolManager = address(0xBEEF);
        MockNFT nft = new MockNFT();
        NftGate gate = new NftGate(address(nft), address(this));
        address holder = address(0xA);
        address[] memory w = new address[](1);
        uint256[] memory n = new uint256[](1);
        (w[0], n[0]) = (holder, 1);
        gate.record(w, n);
        gate.seal(block.number);
        YoloToken t = new YoloToken(poolManager, address(gate), address(0x5AFE), block.timestamp + 1);
        t.transfer(poolManager, 200_000_000e18);
        skip(1);
        address router = address(0x5555);
        vm.prank(poolManager);
        vm.expectRevert(abi.encodeWithSelector(YoloToken.NotWhitelisted.selector, router));
        t.transfer(router, 1_000e18);
        vm.prank(poolManager);
        t.transfer(holder, 1_000e18);
    }
}

/// @dev With the vault (MockPriceOracle as DevPrices): what a depressed YOLO price does to the vault.
/// forge-config: default.isolate = false
contract ReviewYoloVault is Base {
    /// A YOLO price that exists (hasPrice) but is ~0 does not touch task creation at all (the minimum is in
    /// $YOLO itself, no USD limits, no price read). An existing task's bond is unaffected by the
    /// price (the bond's percent part is 3% of R in $YOLO itself, no oracle, no floor). DevPrices has no
    /// sampling window to attack, and
    /// a price alone, however extreme, never touches an existing bond.
    function test_depressedPrice_touchesNeitherNewYoloTasksNorAnExistingBond() public {
        uint256 R = 10_000_000e18; // $1,000 at the Base price of $0.0001
        uint256 t = _create(author, address(yolo), R);
        uint256 snap = vm.snapshotState();
        uint256 s1 = _submit(doer, t);
        Submission memory honest = _sub(s1);
        vm.revertToState(snap);

        oracle.set(address(yolo), 1, 18); // the dev mis-set the price: hasPrice true, value ~0
        assertTrue(oracle.hasPrice(address(yolo)));
        uint256 s2 = _submit(doer, t);
        Submission memory attacked = _sub(s2);
        console.log("doer bond rew, honest / attacked:", honest.bond.rew, attacked.bond.rew);
        assertEq(honest.bond.rew, 300_000e18, "3% of R, in $YOLO");
        assertEq(attacked.bond.rew, honest.bond.rew, "the price manipulation does not touch the bond at all");

        vm.prank(alice);
        vault.createTask(address(yolo), R, uint64(_now() + 1 days), "Title", rulesOf("c"), 0, 0, "", _noSwap()); // no price read
    }
}
