// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {YoloToken} from "../src/token/YoloToken.sol";
import {NftGate} from "../src/token/NftGate.sol";
import {BuybackBurner} from "../src/BuybackBurner.sol";
import {DevPrices} from "../src/DevPrices.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev The launch's fixed values, as the brief gives them.
abstract contract LaunchValues {
    uint256 internal constant OPEN_AT = 1792584000;
    uint256 internal constant OPEN_AT_LATEST = 1792594800;
    address internal constant GATE = 0x97C8Fe82527F1a65A147bB0b425C717E4EC547C2;
    address internal constant PROJECT = 0x3c587Eff6c96eAcF7E3dcC2CFf6416161386E48C;
    address internal constant DEV = 0x8Ad18E99F4C8d8406f9Ba8899CF308000518A981;
    address internal constant BUYBACK = 0x027E55f01e8Cf808E5D2a2Ad68E5e7f67fD6dF6E;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant SUPPLY = 1_000_000_000e18;
    /// @dev 10,000 bps x 1,800 s: the schedule's denominator
    uint256 internal constant D = 18_000_000;
}

/// @notice Audit of the support launch's token as it arrived: the brief's numbers, the edges of every window, and the
///         failure paths. The PoolManager is a plain address: the token only compares with it.
contract LaunchSupportTokenTest is Test, LaunchValues {
    address internal pm = makeAddr("poolManager");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal stranger = makeAddr("stranger");

    YoloToken internal yolo;
    NftGate internal gate;

    function setUp() public {
        vm.warp(OPEN_AT - 1 days);
        yolo = new YoloToken(pm, GATE, PROJECT, OPEN_AT);
        // the seed: the deployer's transfer into the pool before openAt
        yolo.transfer(pm, 150_000_000e18);
    }

    // ---------------------------------------------------------------- deployment

    function test_BriefArguments_DeployAsSpecified() public view {
        assertEq(yolo.name(), "YOLO");
        assertEq(yolo.symbol(), "YOLO");
        assertEq(yolo.decimals(), 18);
        assertEq(yolo.totalSupply(), SUPPLY);
        assertEq(yolo.balanceOf(address(this)) + yolo.balanceOf(pm), SUPPLY);
        assertEq(yolo.openAt(), OPEN_AT);
        assertEq(yolo.gate(), GATE);
        assertEq(yolo.taxRecipient(), PROJECT);
        assertEq(yolo.launcher(), address(this));
        assertEq(yolo.poolManager(), pm);
        assertFalse(yolo.tradingOpen());
    }

    function test_OpenAt_EdgesOfTheDeploymentWindow() public {
        // exactly at deployment and exactly 30 days later are allowed
        new YoloToken(pm, GATE, PROJECT, block.timestamp);
        new YoloToken(pm, GATE, PROJECT, block.timestamp + 30 days);
        vm.expectRevert(abi.encodeWithSelector(YoloToken.BadOpenAt.selector, block.timestamp - 1));
        new YoloToken(pm, GATE, PROJECT, block.timestamp - 1);
        vm.expectRevert(abi.encodeWithSelector(YoloToken.BadOpenAt.selector, block.timestamp + 30 days + 1));
        new YoloToken(pm, GATE, PROJECT, block.timestamp + 30 days + 1);
    }

    function test_OpenAt_BriefValuesUnmineableAfterTheirTime() public {
        // the launch can no longer be mined once openAt has passed: the constructor refuses it
        vm.warp(OPEN_AT + 1);
        vm.expectRevert(abi.encodeWithSelector(YoloToken.BadOpenAt.selector, OPEN_AT));
        new YoloToken(pm, GATE, PROJECT, OPEN_AT);
        // the latest openAt the brief allows still deploys then
        new YoloToken(pm, GATE, PROJECT, OPEN_AT_LATEST);
    }

    function test_Constructor_ZeroPoolManagerOrRecipientRefused_ZeroGateAllowed() public {
        vm.expectRevert(YoloToken.ZeroAddress.selector);
        new YoloToken(address(0), GATE, PROJECT, OPEN_AT);
        vm.expectRevert(YoloToken.ZeroAddress.selector);
        new YoloToken(pm, GATE, address(0), OPEN_AT);
        // a gate address without code means no whitelist
        YoloToken t = new YoloToken(pm, address(0), PROJECT, OPEN_AT);
        assertEq(t.gate(), address(0));
    }

    // ---------------------------------------------------------------- before openAt

    function test_BeforeOpenAt_EveryBuyReverts_LastSecond() public {
        vm.warp(OPEN_AT - 1);
        vm.prank(pm);
        vm.expectRevert(abi.encodeWithSelector(YoloToken.TradingNotOpen.selector, OPEN_AT));
        yolo.transfer(alice, 1);
    }

    function test_BeforeOpenAt_SellsNeitherRefusedNorTaxed_AndTheLauncherTakesOut() public {
        yolo.transfer(alice, 100e18);
        vm.warp(OPEN_AT - 1);
        vm.prank(alice);
        yolo.transfer(pm, 100e18);
        assertEq(yolo.balanceOf(alice), 0);
        assertEq(yolo.balanceOf(PROJECT), 0);
        // the factory's fee claim before openAt: out of the pool to the launcher, allowed and untaxed
        vm.prank(pm);
        yolo.transfer(address(this), 5e18);
        assertEq(yolo.balanceOf(PROJECT), 0);
    }

    function test_ZeroValueTransferOutOfThePool_NeverReverts() public {
        vm.warp(OPEN_AT - 1);
        vm.prank(pm);
        yolo.transfer(alice, 0);
        assertEq(yolo.balanceOf(alice), 0);
    }

    // ---------------------------------------------------------------- minutes 0-30 with a gate

    function _gatedToken() internal returns (YoloToken t) {
        gate = new NftGate(makeAddr("nft"), PROJECT);
        t = new YoloToken(pm, address(gate), PROJECT, OPEN_AT);
        t.transfer(pm, 150_000_000e18);
        address[] memory w = new address[](1);
        uint256[] memory n = new uint256[](1);
        w[0] = alice;
        n[0] = 2;
        vm.startPrank(PROJECT);
        gate.record(w, n);
        gate.seal(block.number);
        vm.stopPrank();
    }

    function test_Window_AllowanceExceeded_ReportsLeftAndWanted_BooksNothing() public {
        YoloToken t = _gatedToken();
        vm.warp(OPEN_AT);
        vm.prank(pm);
        t.transfer(alice, 400_000e18);
        assertEq(gate.left(address(t), alice), 600_000e18);
        vm.prank(pm);
        vm.expectRevert(
            abi.encodeWithSelector(YoloToken.NftAllowanceExceeded.selector, alice, 600_000e18, 600_000e18 + 1)
        );
        t.transfer(alice, 600_000e18 + 1);
        // the refused buy booked nothing: the exact rest still passes, untaxed
        vm.warp(OPEN_AT + 1799);
        vm.prank(pm);
        t.transfer(alice, 600_000e18);
        assertEq(t.balanceOf(alice), 1_000_000e18);
        assertEq(t.balanceOf(PROJECT), 0);
        assertEq(gate.left(address(t), alice), 0);
        vm.prank(pm);
        vm.expectRevert(abi.encodeWithSelector(YoloToken.NftAllowanceExceeded.selector, alice, 0, 1));
        t.transfer(alice, 1);
    }

    function test_Window_OutsiderRefused_UntilMinute30Exactly() public {
        YoloToken t = _gatedToken();
        vm.warp(OPEN_AT + 1799);
        vm.prank(pm);
        vm.expectRevert(abi.encodeWithSelector(YoloToken.NotWhitelisted.selector, stranger));
        t.transfer(stranger, 1e18);
        // second 1800: anyone, at 30% tax
        vm.warp(OPEN_AT + 1800);
        vm.prank(pm);
        t.transfer(stranger, 100e18);
        assertEq(t.balanceOf(stranger), 70e18);
        assertEq(t.balanceOf(PROJECT), 30e18);
    }

    function test_Window_LauncherFeeClaimNeitherGatedNorTaxed() public {
        YoloToken t = _gatedToken();
        vm.warp(OPEN_AT + 10);
        uint256 before = t.balanceOf(address(this));
        vm.prank(pm);
        t.transfer(address(this), 1_000_000e18);
        assertEq(t.balanceOf(address(this)), before + 1_000_000e18);
        assertEq(t.balanceOf(PROJECT), 0);
    }

    function test_Window_SellPays30Percent_OnTop_EvenForSnapshotWallets() public {
        YoloToken t = _gatedToken();
        t.transfer(alice, 100e18);
        vm.warp(OPEN_AT);
        vm.prank(alice);
        t.transfer(pm, 70e18);
        assertEq(t.balanceOf(alice), 0);
        assertEq(t.balanceOf(PROJECT), 30e18);
    }

    function test_Window_UnsealedGateRefusesBuysButNotSells() public {
        gate = new NftGate(makeAddr("nft"), PROJECT);
        YoloToken t = new YoloToken(pm, address(gate), PROJECT, OPEN_AT);
        t.transfer(pm, 1_000e18);
        t.transfer(alice, 100e18);
        vm.warp(OPEN_AT);
        vm.prank(pm);
        vm.expectRevert(YoloToken.SnapshotNotSealed.selector);
        t.transfer(alice, 1);
        vm.prank(alice);
        t.transfer(pm, 70e18);
        assertEq(t.balanceOf(PROJECT), 30e18);
        // the writer cannot rescue the window by sealing after openAt
        address[] memory w = new address[](1);
        uint256[] memory n = new uint256[](1);
        w[0] = alice;
        n[0] = 1;
        vm.startPrank(PROJECT);
        gate.record(w, n);
        gate.seal(1);
        vm.stopPrank();
        vm.prank(pm);
        vm.expectRevert(YoloToken.SnapshotNotSealed.selector);
        t.transfer(alice, 1);
    }

    function test_Gate_ConsumeFromAnyCallerCannotSpendTheTokensBooking() public {
        YoloToken t = _gatedToken();
        // a stranger calling consume books against its own address, never against the token's
        vm.prank(stranger);
        gate.consume(alice, 1_000_000e18);
        assertEq(gate.left(address(t), alice), 1_000_000e18);
        assertEq(gate.left(stranger, alice), 0);
    }

    function test_Gate_RecordFailurePaths() public {
        gate = new NftGate(makeAddr("nft"), PROJECT);
        address[] memory w = new address[](2);
        uint256[] memory n = new uint256[](1);
        vm.startPrank(PROJECT);
        vm.expectRevert(NftGate.BadBatch.selector);
        gate.record(w, n);
        vm.expectRevert(NftGate.BadBatch.selector);
        gate.record(new address[](0), new uint256[](0));
        n = new uint256[](2);
        w[0] = alice;
        n[0] = 1;
        w[1] = alice;
        n[1] = 1;
        vm.expectRevert(abi.encodeWithSelector(NftGate.AlreadyRecorded.selector, alice));
        gate.record(w, n);
        w[1] = bob;
        n[1] = 0;
        vm.expectRevert(abi.encodeWithSelector(NftGate.ZeroEntry.selector, 1));
        gate.record(w, n);
        vm.expectRevert(NftGate.EmptySnapshot.selector);
        gate.seal(1);
        vm.expectRevert(NftGate.NotSealed.selector);
        gate.consume(alice, 1);
        vm.stopPrank();
        vm.expectRevert(NftGate.NotWriter.selector);
        new NftGate(address(1), address(0));
    }

    function test_Window_SealedExactlyAtOpenAtRefused_OneSecondBeforeAccepted() public {
        address[] memory w = new address[](1);
        uint256[] memory n = new uint256[](1);
        w[0] = alice;
        n[0] = 1;
        // sealed at openAt itself: too late, the window stays shut
        NftGate late = new NftGate(makeAddr("nft"), PROJECT);
        YoloToken t1 = new YoloToken(pm, address(late), PROJECT, OPEN_AT);
        t1.transfer(pm, 1_000_000e18);
        // sealed one second before openAt: the window opens for the snapshot
        NftGate early = new NftGate(makeAddr("nft"), PROJECT);
        YoloToken t2 = new YoloToken(pm, address(early), PROJECT, OPEN_AT);
        t2.transfer(pm, 1_000_000e18);
        vm.startPrank(PROJECT);
        late.record(w, n);
        early.record(w, n);
        vm.warp(OPEN_AT - 1);
        early.seal(1);
        vm.warp(OPEN_AT);
        late.seal(1);
        vm.stopPrank();
        vm.prank(pm);
        vm.expectRevert(YoloToken.SnapshotNotSealed.selector);
        t1.transfer(alice, 1);
        vm.prank(pm);
        t2.transfer(alice, 500_000e18);
        assertEq(t2.balanceOf(alice), 500_000e18);
        assertEq(early.left(address(t2), alice), 0);
    }

    function test_Window_PoolToPoolAndZeroValueNotGated() public {
        YoloToken t = _gatedToken();
        vm.warp(OPEN_AT + 5);
        // the PoolManager moving to itself and a zero-value buy by an outsider touch neither the gate nor the tax
        vm.startPrank(pm);
        t.transfer(pm, 1e18);
        t.transfer(stranger, 0);
        vm.stopPrank();
        assertEq(t.balanceOf(PROJECT), 0);
        assertEq(gate.used(address(t), stranger), 0);
    }

    function test_Gate_WriterOnly_AndNothingChangesAfterSeal() public {
        gate = new NftGate(makeAddr("nft"), PROJECT);
        address[] memory w = new address[](1);
        uint256[] memory n = new uint256[](1);
        w[0] = alice;
        n[0] = 3;
        vm.startPrank(stranger);
        vm.expectRevert(NftGate.NotWriter.selector);
        gate.record(w, n);
        vm.expectRevert(NftGate.NotWriter.selector);
        gate.seal(1);
        vm.stopPrank();
        vm.startPrank(PROJECT);
        gate.record(w, n);
        gate.seal(42);
        w[0] = bob;
        vm.expectRevert(NftGate.AlreadySealed.selector);
        gate.record(w, n);
        vm.expectRevert(NftGate.AlreadySealed.selector);
        gate.seal(43);
        vm.stopPrank();
        assertEq(gate.snapshotBlock(), 42);
        assertEq(gate.walletCount(), 1);
        assertEq(gate.totalNfts(), 3);
        assertEq(gate.allowanceOf(alice), 1_500_000e18);
        assertEq(gate.nftsOf(bob), 0);
        assertEq(gate.snapshotHash(), keccak256(abi.encode(bytes32(0), alice, uint256(3))));
    }

    // ---------------------------------------------------------------- minutes 30-60 and after

    function test_Schedule_Edges_Buy() public {
        // second 3599: 1/1800 of 30%
        vm.warp(OPEN_AT + 3599);
        vm.prank(pm);
        yolo.transfer(alice, 18_000_000);
        assertEq(yolo.balanceOf(PROJECT), 3_000);
        assertEq(yolo.balanceOf(alice), 18_000_000 - 3_000);
        assertEq(yolo.buyTaxBps(), 1);
        // second 3600: free for good
        vm.warp(OPEN_AT + 3600);
        assertEq(yolo.buyTaxBps(), 0);
        assertEq(yolo.sellTaxBps(), 0);
        vm.prank(pm);
        yolo.transfer(bob, 1e18);
        assertEq(yolo.balanceOf(bob), 1e18);
        vm.prank(bob);
        yolo.transfer(pm, 1e18);
        assertEq(yolo.balanceOf(PROJECT), 3_000);
    }

    function test_Schedule_BpsViews_AtEachEdge() public {
        assertEq(yolo.sellTaxBps(), 0);
        vm.warp(OPEN_AT);
        assertEq(yolo.buyTaxBps(), 0);
        assertEq(yolo.sellTaxBps(), 3000);
        assertFalse(yolo.whitelistActive()); // no code at the gate address here
        vm.warp(OPEN_AT + 1800);
        assertEq(yolo.buyTaxBps(), 3000);
        assertEq(yolo.sellTaxBps(), 3000);
        vm.warp(OPEN_AT + 2700);
        assertEq(yolo.buyTaxBps(), 1500);
        assertEq(yolo.sellTaxBps(), 1500);
        assertEq(yolo.sellTax(85e18), 15e18);
    }

    function test_Sell_WholeBalanceRefusedWhileTaxed_TaxIsOnTop() public {
        yolo.transfer(alice, 100e18);
        vm.warp(OPEN_AT + 100);
        uint256 tax = yolo.sellTax(100e18);
        assertEq(tax, 42857142857142857142);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 100e18 - tax, 100e18)
        );
        yolo.transfer(pm, 100e18);
    }

    function test_Sell_ViaTransferFrom_AllowanceCoversOnlyThePoolPart() public {
        yolo.transfer(alice, 100e18);
        vm.prank(alice);
        yolo.approve(bob, 70e18);
        vm.warp(OPEN_AT + 1);
        vm.prank(bob);
        yolo.transferFrom(alice, pm, 70e18);
        assertEq(yolo.balanceOf(alice), 0);
        assertEq(yolo.balanceOf(PROJECT), 30e18);
        assertEq(yolo.allowance(alice, bob), 0);
    }

    function test_WalletTransfers_NeverTaxed_InAnyWindow() public {
        yolo.transfer(alice, 300e18);
        uint256[3] memory at = [OPEN_AT, OPEN_AT + 2000, OPEN_AT + 4000];
        for (uint256 i; i < 3; ++i) {
            vm.warp(at[i]);
            vm.prank(alice);
            yolo.transfer(bob, 100e18);
        }
        assertEq(yolo.balanceOf(bob), 300e18);
        assertEq(yolo.balanceOf(PROJECT), 0);
    }

    // ---------------------------------------------------------------- properties

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_BuyTax_IsTheBriefFormula(uint256 amount, uint256 e) public {
        amount = bound(amount, 0, 150_000_000e18);
        e = bound(e, 0, 7200);
        vm.warp(OPEN_AT + e);
        vm.prank(pm);
        yolo.transfer(alice, amount);
        uint256 tax = (e >= 1800 && e < 3600) ? amount * 3000 * (3600 - e) / D : 0;
        assertEq(yolo.balanceOf(PROJECT), tax);
        assertEq(yolo.balanceOf(alice), amount - tax);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_SellTax_IsTheShareOfAllTheSellerPartsWith_RoundedDown(uint256 intoPool, uint256 e) public {
        intoPool = bound(intoPool, 0, 100_000_000e18);
        e = bound(e, 0, 7200);
        yolo.transfer(alice, 200_000_000e18);
        vm.warp(OPEN_AT + e);
        uint256 pmBefore = yolo.balanceOf(pm);
        vm.prank(alice);
        yolo.transfer(pm, intoPool);
        uint256 tax = yolo.balanceOf(PROJECT);
        uint256 num = e < 1800 ? 3000 * 1800 : (e < 3600 ? 3000 * (3600 - e) : 0);
        assertEq(yolo.balanceOf(pm) - pmBefore, intoPool, "pool gets exactly the settled amount");
        assertEq(200_000_000e18 - yolo.balanceOf(alice), intoPool + tax, "seller parts with pool part + tax");
        assertEq(yolo.sellTaxBps(), num / 1800);
        // tax / (intoPool + tax) <= num / D, and one more wei would exceed it (rounded down, never more)
        assertLe(tax * D, num * (intoPool + tax));
        if (num != 0) assertGt((tax + 1) * D, num * (intoPool + tax + 1));
        else assertEq(tax, 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_TaxNeverRisesWithTime(uint256 a, uint256 b) public {
        a = bound(a, OPEN_AT - 10, OPEN_AT + 4000);
        b = bound(b, a, OPEN_AT + 4000);
        vm.warp(a);
        uint256 sa = yolo.sellTaxBps();
        uint256 ba = yolo.buyTaxBps();
        vm.warp(b);
        if (a >= OPEN_AT) assertLe(yolo.sellTaxBps(), sa);
        if (a >= OPEN_AT + 1800) assertLe(yolo.buyTaxBps(), ba);
        assertLe(yolo.sellTaxBps(), 3000);
        assertLe(yolo.buyTaxBps(), 3000);
    }
}

/// @notice Burner and prices: failure paths and the 10x step.
contract LaunchSupportBurnerTest is Test, LaunchValues {
    DevPrices internal prices;
    BuybackBurner internal burner;
    MockERC20 internal usdc;
    MockERC20 internal imd;
    MockERC20 internal yoloT;

    function setUp() public {
        usdc = new MockERC20("USDC", "USDC", 6);
        imd = new MockERC20("IMD", "IMD", 18);
        yoloT = new MockERC20("YOLO", "YOLO", 18);
        prices = new DevPrices(DEV, address(usdc), address(imd), address(yoloT), 1e15, 2400e18, 5.5e18);
        burner = new BuybackBurner(address(yoloT), address(imd), address(usdc), address(prices), BUYBACK);
    }

    function test_BriefStartPrices() public view {
        assertEq(prices.owner(), DEV);
        assertEq(prices.yoloPriceUsd(), 1e15);
        assertEq(prices.ethUsd(), 2400e18);
        assertEq(prices.imdUsd(), 5.5e18);
        assertEq(prices.priceOf(address(usdc)), 1e18);
        assertEq(prices.usdValue(address(usdc), 1e6), 1e18);
        // 1000 YOLO at 0.001 USD = 1 USD
        assertEq(prices.usdValue(address(yoloT), 1000e18), 1e18);
        assertEq(burner.buybackWallet(), BUYBACK);
        assertEq(burner.dev(), DEV);
    }

    function test_UnknownToken_Refused() public {
        vm.expectRevert(DevPrices.UnknownToken.selector);
        prices.usdValue(address(0xBEEF), 1);
        vm.expectRevert(DevPrices.UnknownToken.selector);
        prices.imdValue(address(0xBEEF), 1);
        assertEq(prices.imdValue(address(imd), 7), 7);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_PriceStep_AcceptedIffWithinTenTimes(uint256 next) public {
        uint256 cur = prices.imdUsd();
        next = bound(next, 0, cur * 20);
        bool ok = next != 0 && next <= cur * 10 && next * 10 >= cur;
        vm.prank(DEV);
        if (!ok) vm.expectRevert();
        prices.setImdUsd(next);
        assertEq(prices.imdUsd(), ok ? next : cur);
    }

    function test_PriceSetters_OnlyOwner_TwoStepHandover() public {
        vm.expectRevert();
        prices.setEthUsd(2500e18);
        address next = makeAddr("nextDev");
        vm.prank(DEV);
        prices.transferOwnership(next);
        // still the old dev until the new one accepts: the burner follows the owner
        assertEq(burner.dev(), DEV);
        vm.prank(next);
        prices.acceptOwnership();
        assertEq(burner.dev(), next);
        vm.prank(DEV);
        vm.expectRevert(BuybackBurner.NotDev.selector);
        burner.setBuybackWallet(DEV);
    }

    function test_Burner_FailurePaths() public {
        vm.expectRevert(BuybackBurner.Nothing.selector);
        burner.burnYolo();
        vm.expectRevert(BuybackBurner.Nothing.selector);
        burner.forward(address(0));
        vm.expectRevert(BuybackBurner.Nothing.selector);
        burner.forward(address(usdc));
        vm.expectRevert(BuybackBurner.NotReserve.selector);
        burner.forward(address(yoloT));
        vm.prank(DEV);
        vm.expectRevert(BuybackBurner.ZeroAddress.selector);
        burner.setBuybackWallet(address(0));
        vm.expectRevert(BuybackBurner.ZeroAddress.selector);
        new BuybackBurner(address(yoloT), address(imd), address(usdc), address(prices), address(0));
    }
}

/// @dev Drives the token, the burner and the price owner in random order; keeps ghost totals the invariants check.
contract SupportHandler is Test, LaunchValues {
    YoloToken public yolo;
    BuybackBurner public burner;
    DevPrices public prices;
    MockERC20 public usdc;
    MockERC20 public imd;
    address public pm = address(0x9000);
    address[3] public actors = [address(0xA1), address(0xA2), address(0xA3)];
    address[2] public wallets = [BUYBACK, address(0xB2)];

    uint256 public ghostTax;
    uint256 public ghostBurned;
    uint256 public ghostYoloToBurner;
    mapping(address => uint256) public ghostIn;
    mapping(address => uint256) public ghostReceivedByWallets;
    uint256 public calls;

    constructor() {
        vm.warp(OPEN_AT - 2 hours);
        yolo = new YoloToken(pm, GATE, PROJECT, OPEN_AT);
        yolo.transfer(pm, 150_000_000e18);
        for (uint256 i; i < 3; ++i) {
            yolo.transfer(actors[i], 1_000_000e18);
        }
        usdc = new MockERC20("USDC", "USDC", 6);
        imd = new MockERC20("IMD", "IMD", 18);
        prices = new DevPrices(DEV, address(usdc), address(imd), address(yolo), 1e15, 2400e18, 5.5e18);
        burner = new BuybackBurner(address(yolo), address(imd), address(usdc), address(prices), BUYBACK);
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 20 minutes));
        ++calls;
    }

    function buy(uint256 who, uint256 amount) external {
        address to = actors[who % 3];
        amount = bound(amount, 1, 1_000_000e18);
        uint256 projectBefore = yolo.balanceOf(PROJECT);
        uint256 toBefore = yolo.balanceOf(to);
        vm.prank(pm);
        if (block.timestamp < OPEN_AT) {
            vm.expectRevert(abi.encodeWithSelector(YoloToken.TradingNotOpen.selector, OPEN_AT));
            yolo.transfer(to, amount);
            return;
        }
        yolo.transfer(to, amount);
        uint256 e = block.timestamp - OPEN_AT;
        uint256 tax = (e >= 1800 && e < 3600) ? amount * 3000 * (3600 - e) / D : 0;
        assertEq(yolo.balanceOf(PROJECT) - projectBefore, tax);
        assertEq(yolo.balanceOf(to) - toBefore, amount - tax);
        ghostTax += tax;
        ++calls;
    }

    function sell(uint256 who, uint256 amount) external {
        address from = actors[who % 3];
        uint256 bal = yolo.balanceOf(from);
        // at most 70% of the balance always fits the tax on top
        amount = bound(amount, 0, bal * 7 / 10);
        uint256 projectBefore = yolo.balanceOf(PROJECT);
        uint256 pmBefore = yolo.balanceOf(pm);
        vm.prank(from);
        yolo.transfer(pm, amount);
        uint256 tax = yolo.balanceOf(PROJECT) - projectBefore;
        assertEq(yolo.balanceOf(pm) - pmBefore, amount);
        assertEq(bal - yolo.balanceOf(from), amount + tax);
        assertLe(tax * 10, (amount + tax) * 3);
        if (block.timestamp < OPEN_AT || block.timestamp >= OPEN_AT + 3600) assertEq(tax, 0);
        ghostTax += tax;
        ++calls;
    }

    function move(uint256 a, uint256 b, uint256 amount) external {
        address from = actors[a % 3];
        address to = actors[b % 3];
        amount = bound(amount, 0, yolo.balanceOf(from));
        uint256 projectBefore = yolo.balanceOf(PROJECT);
        vm.prank(from);
        yolo.transfer(to, amount);
        assertEq(yolo.balanceOf(PROJECT), projectBefore);
        ++calls;
    }

    function yoloToBurner(uint256 who, uint256 amount) external {
        address from = actors[who % 3];
        amount = bound(amount, 0, yolo.balanceOf(from));
        vm.prank(from);
        yolo.transfer(address(burner), amount);
        ghostYoloToBurner += amount;
        ++calls;
    }

    function burn() external {
        uint256 bal = yolo.balanceOf(address(burner));
        if (bal == 0) {
            vm.expectRevert(BuybackBurner.Nothing.selector);
            burner.burnYolo();
            return;
        }
        burner.burnYolo();
        ghostBurned += bal;
        assertEq(yolo.balanceOf(address(burner)), 0);
        ++calls;
    }

    function fund(uint256 which, uint256 amount) external {
        amount = bound(amount, 1, 1e30);
        address t = _reserve(which);
        if (t == address(0)) {
            vm.deal(address(this), amount);
            (bool ok,) = address(burner).call{value: amount}("");
            assertTrue(ok);
        } else {
            MockERC20(t).mint(address(burner), amount);
        }
        ghostIn[t] += amount;
        ++calls;
    }

    function forward(uint256 which) external {
        address t = _reserve(which);
        address to = burner.buybackWallet();
        uint256 bal = t == address(0) ? address(burner).balance : MockERC20(t).balanceOf(address(burner));
        if (bal == 0) {
            vm.expectRevert(BuybackBurner.Nothing.selector);
            burner.forward(t);
            return;
        }
        uint256 amount = burner.forward(t);
        assertEq(amount, bal);
        ghostReceivedByWallets[t] += amount;
        assertEq(to, burner.buybackWallet());
        ++calls;
    }

    function setWallet(uint256 which, bool asDev) external {
        address w = wallets[which % 2];
        if (!asDev) {
            vm.prank(actors[which % 3]);
            vm.expectRevert(BuybackBurner.NotDev.selector);
            burner.setBuybackWallet(w);
            return;
        }
        vm.prank(DEV);
        burner.setBuybackWallet(w);
        ++calls;
    }

    function _reserve(uint256 which) internal view returns (address) {
        uint256 k = which % 3;
        return k == 0 ? address(0) : (k == 1 ? address(usdc) : address(imd));
    }

    function walletsHold(address t) external view returns (uint256 s) {
        for (uint256 i; i < 2; ++i) {
            s += t == address(0) ? wallets[i].balance : MockERC20(t).balanceOf(wallets[i]);
        }
    }

    function tracked() external view returns (uint256 s) {
        s = yolo.balanceOf(address(this)) + yolo.balanceOf(pm) + yolo.balanceOf(PROJECT)
            + yolo.balanceOf(address(burner)) + yolo.balanceOf(DEAD);
        for (uint256 i; i < 3; ++i) {
            s += yolo.balanceOf(actors[i]);
        }
    }
}

/// @notice Invariants over random sequences: fixed supply, every YOLO accounted for, the tax wallet holds exactly the
///         taxes, the burner owes nothing it does not hold and only ever pays the buyback wallet.
contract LaunchSupportInvariantTest is Test, LaunchValues {
    SupportHandler internal h;

    function setUp() public {
        h = new SupportHandler();
        targetContract(address(h));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 60
    function invariant_SupplyFixedAndFullyAccounted() public view {
        assertEq(h.yolo().totalSupply(), SUPPLY);
        assertEq(h.tracked(), SUPPLY);
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 60
    function invariant_ProjectWalletHoldsExactlyTheTaxes() public view {
        assertEq(h.yolo().balanceOf(PROJECT), h.ghostTax());
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 60
    function invariant_BurnerConservation() public view {
        BuybackBurner b = h.burner();
        YoloToken y = h.yolo();
        assertEq(y.balanceOf(DEAD), h.ghostBurned());
        assertEq(y.balanceOf(address(b)) + h.ghostBurned(), h.ghostYoloToBurner());
        address[3] memory ts = [address(0), address(h.usdc()), address(h.imd())];
        for (uint256 i; i < 3; ++i) {
            address t = ts[i];
            uint256 held = t == address(0) ? address(b).balance : h.usdc().balanceOf(address(b));
            if (t == address(h.imd())) held = h.imd().balanceOf(address(b));
            assertEq(held + b.forwarded(t), h.ghostIn(t));
            assertEq(b.forwarded(t), h.ghostReceivedByWallets(t));
            assertEq(h.walletsHold(t), b.forwarded(t));
        }
    }
}

/// @dev Drives buys in minutes 0-30 against a sealed gate: snapshot wallets with 1, 2 and 3 NFTs and one outsider.
contract GateWindowHandler is Test, LaunchValues {
    YoloToken public yolo;
    NftGate public gate;
    address public pm = address(0x9000);
    address[4] public buyers = [address(0xC1), address(0xC2), address(0xC3), address(0xC4)];
    mapping(address => uint256) public ghostBought;
    uint256 public refused;

    constructor() {
        vm.warp(OPEN_AT - 1 days);
        gate = new NftGate(address(0x1D), PROJECT);
        yolo = new YoloToken(pm, address(gate), PROJECT, OPEN_AT);
        yolo.transfer(pm, 150_000_000e18);
        address[] memory w = new address[](3);
        uint256[] memory n = new uint256[](3);
        for (uint256 i; i < 3; ++i) {
            w[i] = buyers[i];
            n[i] = i + 1;
        }
        vm.startPrank(PROJECT);
        gate.record(w, n);
        gate.seal(block.number);
        vm.stopPrank();
        vm.warp(OPEN_AT);
    }

    function warp(uint256 dt) external {
        // stay inside the window
        uint256 next = block.timestamp + bound(dt, 0, 120);
        vm.warp(next > OPEN_AT + 1799 ? OPEN_AT + 1799 : next);
    }

    function buy(uint256 who, uint256 amount) external {
        address to = buyers[who % 4];
        uint256 allowance = gate.allowanceOf(to);
        uint256 used = gate.used(address(yolo), to);
        amount = bound(amount, 1, 2_000_000e18);
        vm.prank(pm);
        if (allowance == 0) {
            vm.expectRevert(abi.encodeWithSelector(YoloToken.NotWhitelisted.selector, to));
            yolo.transfer(to, amount);
            ++refused;
            return;
        }
        if (amount > allowance - used) {
            vm.expectRevert(
                abi.encodeWithSelector(YoloToken.NftAllowanceExceeded.selector, to, allowance - used, amount)
            );
            yolo.transfer(to, amount);
            ++refused;
            return;
        }
        yolo.transfer(to, amount);
        ghostBought[to] += amount;
    }

    /// @dev someone other than the token calling the gate directly
    function poke(uint256 who, uint256 amount) external {
        gate.consume(buyers[who % 4], bound(amount, 0, 2_000_000e18));
    }
}

/// @notice Over random buy sequences in minutes 0-30: nobody takes more than 500,000 YOLO per NFT, the gate books exactly
///         what was bought, outsiders get nothing, window buys are untaxed, and direct calls to the gate spend no token's
///         books.
contract LaunchSupportGateInvariantTest is Test, LaunchValues {
    GateWindowHandler internal h;

    function setUp() public {
        h = new GateWindowHandler();
        targetContract(address(h));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 60
    function invariant_GateBooksExactlyWhatWasBought_NeverAboveAllowance() public view {
        NftGate g = h.gate();
        YoloToken y = h.yolo();
        uint256 total;
        for (uint256 i; i < 4; ++i) {
            address b = h.buyers(i);
            assertEq(g.used(address(y), b), h.ghostBought(b));
            assertEq(y.balanceOf(b), h.ghostBought(b));
            assertLe(g.used(address(y), b), g.allowanceOf(b));
            total += y.balanceOf(b);
        }
        assertEq(y.balanceOf(h.buyers(3)), 0);
        assertEq(y.balanceOf(PROJECT), 0);
        assertEq(y.balanceOf(h.pm()), 150_000_000e18 - total);
        assertEq(y.totalSupply(), SUPPLY);
    }
}
