// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./Base.t.sol";
import {ProtocolDirectory} from "../src/ProtocolDirectory.sol";

/// @dev Versions side by side: version 1 from the constructor, later ones and the
///      current pointer only by the owner (the project wallet) after 48 h, nothing removed, old vaults keep working.
/// forge-config: default.isolate = false
contract DirectoryTest is Base {
    ProtocolDirectory internal dir;
    address internal safe = makeAddr("safe");

    function setUp() public override {
        super.setUp();
        dir = new ProtocolDirectory(safe, address(vault), address(sweetener), address(trophy), 7);
    }

    function _v(address v, address s, address t, string memory label)
        internal
        pure
        returns (ProtocolDirectory.Version memory)
    {
        return ProtocolDirectory.Version(v, s, t, 100, 0, label);
    }

    /// @dev A second core next to the first: same registry and $YOLO, its own desks, vault and modules.
    function _deployV2() internal returns (ITaskVault v2, YoloSweetener s2, DareTrophy t2) {
        (ITaskVault v1, YoloSweetener s1, DareTrophy t1, CaseDesk c1, DisputeDesk d1) =
            (vault, sweetener, trophy, caseDesk, disputeDesk);
        _deployVault();
        (v2, s2, t2) = (vault, sweetener, trophy);
        (vault, sweetener, trophy, caseDesk, disputeDesk) = (v1, s1, t1, c1, d1);
    }

    function test_Version1FromConstructor() public view {
        assertEq(dir.safe(), safe);
        assertEq(dir.versionCount(), 1);
        assertEq(dir.current(), 1);
        ProtocolDirectory.Version memory v = dir.version(1);
        assertEq(v.vault, address(vault));
        assertEq(v.sweetener, address(sweetener));
        assertEq(v.trophy, address(trophy));
        assertEq(v.fromBlock, 7);
        assertEq(v.addedAt, block.timestamp);
        assertEq(v.label, "v1");
        assertEq(dir.versions().length, 1);
    }

    function test_ConstructorChecks() public {
        vm.expectRevert(ProtocolDirectory.NotSafe.selector);
        new ProtocolDirectory(address(0), address(vault), address(0), address(0), 0);
        vm.expectRevert(abi.encodeWithSelector(ProtocolDirectory.NoCode.selector, alice));
        new ProtocolDirectory(safe, alice, address(0), address(0), 0);
        vm.expectRevert(abi.encodeWithSelector(ProtocolDirectory.NoCode.selector, bob));
        new ProtocolDirectory(safe, address(vault), bob, address(0), 0);
        // a version without modules is fine
        ProtocolDirectory bare = new ProtocolDirectory(safe, address(vault), address(0), address(0), 0);
        assertEq(bare.version(1).sweetener, address(0));
    }

    function test_V2SideBySide_AfterTimelock() public {
        uint256 t1 = _create(author, address(imd), 10e18); // a task in v1 before the switch
        (ITaskVault v2, YoloSweetener s2, DareTrophy t2) = _deployV2();

        vm.startPrank(safe);
        dir.proposeVersion(_v(address(v2), address(s2), address(t2), "v2"));
        dir.proposeCurrent(2); // proposed together: v2 must be listed before the switch executes
        vm.stopPrank();
        assertEq(dir.pendingVersion().vault, address(v2));

        vm.warp(vm.getBlockTimestamp() + 48 hours - 1);
        vm.expectRevert(ProtocolDirectory.TimelockNotPassed.selector);
        dir.addVersion();
        vm.expectRevert(ProtocolDirectory.TimelockNotPassed.selector);
        dir.setCurrent();

        vm.warp(vm.getBlockTimestamp() + 1);
        vm.expectRevert(abi.encodeWithSelector(ProtocolDirectory.UnknownVersion.selector, 2));
        dir.setCurrent(); // v2 not listed yet
        vm.prank(erin); // anyone executes
        assertEq(dir.addVersion(), 2);
        vm.prank(erin);
        dir.setCurrent();

        assertEq(dir.current(), 2);
        assertEq(dir.versionCount(), 2);
        assertEq(dir.version(1).vault, address(vault), "v1 stays listed");
        assertEq(dir.version(2).label, "v2");
        assertEq(dir.version(2).addedAt, vm.getBlockTimestamp());
        assertEq(dir.pendingVersionEta(), 0);
        assertEq(dir.pendingCurrentEta(), 0);

        // both vaults work: the v1 task runs to the end, a new one goes to v2; ids restart per vault
        vm.startPrank(author);
        imd.approve(address(v2), type(uint256).max);
        uint256 n2 = v2.createTask{value: 0.001 ether}(
            address(imd), 10e18, uint64(_now() + TTL), "Title", rulesOf("ipfs://task-condition"), 0, 0, "", _noSwap()
        );
        vm.stopPrank();
        assertEq(n2, 1);
        assertEq(uint8(v2.getTask(n2).status), uint8(TaskStatus.Open));
        uint256 s = _submit(doer, t1);
        vm.warp(_sub(s).windowEnd + 1);
        vault.poke(t1);
        assertEq(uint8(vault.getTask(t1).status), uint8(TaskStatus.Completed));
        _claimEverythingAndCheck();
    }

    function test_OnlySafeProposesAndCancels() public {
        (ITaskVault v2,,) = _deployV2();
        vm.startPrank(alice);
        vm.expectRevert(ProtocolDirectory.NotSafe.selector);
        dir.proposeVersion(_v(address(v2), address(0), address(0), "v2"));
        vm.expectRevert(ProtocolDirectory.NotSafe.selector);
        dir.proposeCurrent(1);
        vm.stopPrank();

        vm.startPrank(safe);
        dir.proposeVersion(_v(address(v2), address(0), address(0), "v2"));
        dir.proposeCurrent(2);
        vm.stopPrank();
        vm.startPrank(alice);
        vm.expectRevert(ProtocolDirectory.NotSafe.selector);
        dir.cancelVersion();
        vm.expectRevert(ProtocolDirectory.NotSafe.selector);
        dir.cancelCurrent();
        vm.stopPrank();

        vm.startPrank(safe);
        dir.cancelVersion();
        dir.cancelCurrent();
        vm.expectRevert(ProtocolDirectory.NothingPending.selector);
        dir.cancelVersion();
        vm.expectRevert(ProtocolDirectory.NothingPending.selector);
        dir.cancelCurrent();
        vm.stopPrank();

        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.expectRevert(ProtocolDirectory.NothingPending.selector);
        dir.addVersion();
        vm.expectRevert(ProtocolDirectory.NothingPending.selector);
        dir.setCurrent();
        assertEq(dir.versionCount(), 1);
        assertEq(dir.current(), 1);
    }

    function test_ProposalChecks() public {
        vm.startPrank(safe);
        vm.expectRevert(abi.encodeWithSelector(ProtocolDirectory.AlreadyListed.selector, address(vault)));
        dir.proposeVersion(_v(address(vault), address(0), address(0), "v1 again"));
        vm.expectRevert(abi.encodeWithSelector(ProtocolDirectory.NoCode.selector, alice));
        dir.proposeVersion(_v(alice, address(0), address(0), "v2"));
        vm.expectRevert(abi.encodeWithSelector(ProtocolDirectory.NoCode.selector, bob));
        dir.proposeVersion(_v(address(registry), address(0), bob, "v2"));
        vm.expectRevert(ProtocolDirectory.BadLabel.selector);
        dir.proposeVersion(_v(address(registry), address(0), address(0), ""));
        vm.expectRevert(ProtocolDirectory.BadLabel.selector);
        dir.proposeVersion(_v(address(registry), address(0), address(0), "a label longer than thirty-two by"));
        vm.expectRevert(abi.encodeWithSelector(ProtocolDirectory.UnknownVersion.selector, 0));
        dir.proposeCurrent(0);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(ProtocolDirectory.UnknownVersion.selector, 2));
        dir.version(2);
        vm.expectRevert(abi.encodeWithSelector(ProtocolDirectory.UnknownVersion.selector, 0));
        dir.version(0);
    }

    /// @dev Switching back to an older version is allowed (a v2 found broken): nothing is deleted on the way.
    function test_CurrentMayGoBack() public {
        (ITaskVault v2,,) = _deployV2();
        vm.prank(safe);
        dir.proposeVersion(_v(address(v2), address(0), address(0), "v2"));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        dir.addVersion();
        vm.prank(safe);
        dir.proposeCurrent(2);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        dir.setCurrent();
        vm.prank(safe);
        dir.proposeCurrent(1);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        dir.setCurrent();
        assertEq(dir.current(), 1);
        assertEq(dir.versionCount(), 2);
    }
}
