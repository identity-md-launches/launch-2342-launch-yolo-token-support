// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Swarm audit 117cf05a, finding #2: the report's PoC, unchanged except this header. It fails on d9a1ee5 ("clock must
// start at the split: 1 != 2592001"); here only the YoloSplitter starts a clock.

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {DevVesting} from "src/token/Vestings.sol";
import {YoloSplitter} from "src/token/YoloSplitter.sol";
import {ProjectVesting} from "src/token/ProjectVesting.sol";

contract DustToken is ERC20 {
    constructor() ERC20("YOLO", "YOLO") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice docs/TOKENOMICS.md and docs/LAUNCH-TASK.md: "the vesting clocks start when the tokens arrive: the first
///         split right after launch pays the at-once parts and starts every clock". ProjectVesting.release
///         starts the clock at the first call that finds ANY balance, by anyone. Between the token launch and the split
///         anybody can send 1 wei of YOLO to a vesting and call release: the clock then runs before the share arrives,
///         and the share vests pro rata to that head start the moment the split pays it.
/// forge-config: default.isolate = false
contract VestingClockPreStartTest is Test {
    DustToken yolo;
    DevVesting dev;
    YoloSplitter splitter;
    address beneficiary = address(0xBEEF);

    function setUp() public {
        yolo = new DustToken();
        dev = new DevVesting(beneficiary);
        // the other three recipients are plain wallets here (the splitter skips release on addresses without code)
        splitter = new YoloSplitter(address(0xA1), address(dev), address(0xA3), address(0xA4), address(0xA5));
    }

    function test_clockCannotBeStartedBeforeTheShareArrives() public {
        // launch 1: the token exists, the project's 75% sits in the splitter, nobody has called split yet
        yolo.mint(address(splitter), 750_000_000e18);

        // anyone (the dev wallet itself) buys dust and primes the dev vesting's clock
        yolo.mint(address(this), 1);
        yolo.transfer(address(dev), 1);
        dev.release(address(yolo));

        // the split happens 30 days later (nothing in the code forces it earlier)
        vm.warp(block.timestamp + 30 days);
        splitter.split(address(yolo));

        // docs: the clock starts at the split, so nothing of the 77,777,777 is free at that moment
        // (on this code 30/365 of the share, about 6.39M YOLO, is already releasable)
        assertEq(dev.startOf(address(yolo)), uint64(block.timestamp), "clock must start at the split");
        assertEq(yolo.balanceOf(beneficiary), 0, "no dev YOLO free at the split");
        assertEq(dev.releasable(address(yolo)), 0, "nothing releasable at the split");
    }
}

/// @dev The fix: the splitter binds itself as the only starter in the launch transaction; nobody binds later.
/// forge-config: default.isolate = false
contract VestingStarterBindingTest is Test {
    DevVesting lone; // deployed in setUp, a transaction before every test

    function setUp() public {
        lone = new DevVesting(address(0xBEEF));
    }

    function test_starterIsTheSplitterAndCannotBeRebound() public {
        DevVesting dev = new DevVesting(address(0xBEEF));
        YoloSplitter splitter =
            new YoloSplitter(address(0xA1), address(dev), address(0xA3), address(0xA4), address(0xA5));
        assertEq(dev.starter(), address(splitter));
        vm.expectRevert(ProjectVesting.BindingClosed.selector);
        dev.bindStarter(); // already bound, even inside the same transaction
    }

    function test_bindingClosesWithTheDeploymentTransaction() public {
        assertEq(lone.starter(), address(0));
        vm.expectRevert(ProjectVesting.BindingClosed.selector);
        lone.bindStarter();
        // a splitter deployed in a later transaction cannot take it over either
        vm.expectRevert(ProjectVesting.BindingClosed.selector);
        new YoloSplitter(address(0xA1), address(lone), address(0xA3), address(0xA4), address(0xA5));
    }

    function test_unboundVestingStartsNoClock() public {
        DustToken t = new DustToken();
        t.mint(address(lone), 100e18);
        lone.release(address(t));
        assertEq(lone.startOf(address(t)), 0, "no starter, no clock: only the at-once part (0 for dev) is free");
        assertEq(lone.releasable(address(t)), 0);
    }
}
