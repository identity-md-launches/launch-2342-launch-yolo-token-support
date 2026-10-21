// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./Base.t.sol";

contract RejectsEth {
    ITaskVault internal immutable vault;

    constructor(ITaskVault v) {
        vault = v;
    }

    function create() external payable returns (uint256) {
        ImdPay memory none;
        return vault.createTask{value: msg.value}(
            address(0), 0.01 ether, uint64(block.timestamp + 1 days), "Title", rulesOf("c"), 0, 0, "", none
        );
    }

    function withdrawTo(address to) external {
        vault.withdrawTo(address(0), to);
    }

    receive() external payable {
        revert("no ETH");
    }
}

/// @dev A disputer contract that tries to re-enter the vault when it receives ETH.
contract ReentrantDisputer {
    ITaskVault internal immutable vault;
    uint256 public subId;
    bool public reentered;

    constructor(ITaskVault v) {
        vault = v;
    }

    function approveImd(address imd) external {
        (bool ok,) = imd.call(abi.encodeWithSignature("approve(address,uint256)", address(vault), type(uint256).max));
        require(ok);
    }

    /// @dev the dispute bond's percent part is paid in the reward's own currency, not only IMD.
    function approveUsdc(address token) external {
        (bool ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", address(vault), type(uint256).max));
        require(ok);
    }

    function dispute(uint256 s) external payable {
        subId = s;
        ImdPay memory none;
        vault.dispute{value: msg.value}(s, "r", "rp", none);
    }

    function claim() external {
        vault.claimDisputer(subId);
    }

    receive() external payable {
        // any re-entry must fail; the vault then keeps the ETH as a credit
        try vault.claimDisputer(subId) {
            reentered = true;
        } catch {}
        try vault.withdraw(address(0)) {
            reentered = true;
        } catch {}
        revert("take it as credit");
    }
}

/// @dev Payment mode A (swap adapter), refunds, credits, blocked receivers, treasury sweep.
/// forge-config: default.isolate = false
contract PaymentsTest is Base {
    function test_ModeA_SubmitWithEth_SurplusAndExcessRefunded() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 imdBefore = imd.balanceOf(doer);
        uint256 ethBefore = doer.balance;
        ImdPay memory pay = ImdPay({
            tokenIn: ETH,
            amountIn: 0.01 ether, // 3.125 IMD
            minImdOut: 1e18,
            deadline: uint64(_now() + 600),
            route: hex"01"
        });
        vm.prank(doer);
        uint256 s =
            vault.submit{value: 0.05 ether}(t, "https://x.com/doer/status/1", _noEvidence(), 0, type(uint256).max, pay);
        // no oracle, no floor. The swap (mode A) pays only the bond's fixed IMD part (0.5); the
        // percent part (3% of 100 USDC = 3 USDC) is collected separately, in USDC, no swap involved.
        assertEq(_sub(s).bond.imd, 0.5e18);
        assertEq(_sub(s).bond.rew, 3e6);
        assertEq(doer.balance, ethBefore - 0.01 ether); // excess 0.04 back
        assertEq(imd.balanceOf(doer) - imdBefore, 2.625e18); // surplus IMD back: 3.125 - 0.5
        assertEq(vault.liabilities(address(imd)), 0.5e18);
        _assertSolvent();
        _claimEverythingAndCheck();
    }

    function test_ModeA_DisputeWithUsdc() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        ImdPay memory pay = ImdPay({
            tokenIn: address(usdc),
            amountIn: 10e6, // 1.25 IMD
            minImdOut: 1e18,
            deadline: uint64(_now() + 600),
            route: ""
        });
        uint256 usdcBefore = usdc.balanceOf(dave);
        vm.prank(dave);
        vault.dispute(s, "r", "rp", pay);
        // the swap (mode A) pays only the bond's fixed IMD part; its percent part (1% of 100 USDC = 1 USDC) is
        // collected separately, in USDC, no swap
        assertEq(usdcBefore - usdc.balanceOf(dave), 10e6 + 1e6);
        assertEq(imd.balanceOf(dave), 10_000e18 + 0.75e18); // 1.25 IMD in, bond's fixed part 0.5: surplus 0.75
        assertEq(usdc.allowance(address(vault), address(adapter)), 0);
        _claimEverythingAndCheck();
    }

    function test_ModeA_CreateImdTaskWithEth() public {
        ImdPay memory pay = ImdPay({
            tokenIn: ETH,
            amountIn: 0.02 ether, // 6.25 IMD
            minImdOut: 5e18,
            deadline: uint64(_now() + 600),
            route: ""
        });
        vm.prank(author);
        uint256 t = vault.createTask{value: 0.021 ether}(
            address(imd), 5e18, uint64(_now() + 1 days), "Title", rulesOf("c"), 0, 0, "", pay
        );
        trackedTasks.push(t);
        assertEq(vault.getTask(t).pot, 5e18);
        assertEq(imd.balanceOf(author), 10_000e18 + 1.25e18);
        _claimEverythingAndCheck();
    }

    function test_ModeA_Reverts() public {
        uint256 t = _create(author, address(usdc), 100e6);
        ImdPay memory pay =
            ImdPay({tokenIn: ETH, amountIn: 0.001 ether, minImdOut: 0.3e18, deadline: uint64(_now() + 600), route: ""});
        vm.startPrank(doer);
        vm.expectRevert(SwapShort.selector); // user minOut 0.3 below the bond 0.625
        vault.submit{value: 0.001 ether}(t, "https://x.com/doer/status/1", _noEvidence(), 0, type(uint256).max, pay);
        pay.minImdOut = 1e18;
        vm.expectRevert("minOut"); // the adapter cannot deliver 1 IMD for 0.001 ETH (0.3125)
        vault.submit{value: 0.001 ether}(t, "https://x.com/doer/status/1", _noEvidence(), 0, type(uint256).max, pay);
        pay.amountIn = 0.01 ether;
        pay.deadline = uint64(_now() - 1);
        vm.expectRevert(SwapExpired.selector);
        vault.submit{value: 0.01 ether}(t, "https://x.com/doer/status/1", _noEvidence(), 0, type(uint256).max, pay);
        pay.deadline = uint64(_now() + 600);
        vm.expectRevert(NotEnoughEth.selector);
        vault.submit{value: 0.005 ether}(t, "https://x.com/doer/status/1", _noEvidence(), 0, type(uint256).max, pay);
        pay.tokenIn = address(nft);
        vm.expectRevert(BadCurrency.selector);
        vault.submit(t, "https://x.com/doer/status/1", _noEvidence(), 0, type(uint256).max, pay);
        vm.stopPrank();
    }

    function test_ModeA_Disabled() public {
        Params memory p = defaultParams();
        p.swapAdapter = address(0);
        vm.prank(multisig);
        registry.proposeParams(p);
        _warp(48 hours);
        registry.activateParams();
        uint256 t = _create(author, address(usdc), 100e6);
        ImdPay memory pay =
            ImdPay({tokenIn: ETH, amountIn: 0.01 ether, minImdOut: 1e18, deadline: uint64(_now() + 600), route: ""});
        vm.prank(doer);
        vm.expectRevert(SwapDisabled.selector);
        vault.submit{value: 0.01 ether}(t, "https://x.com/doer/status/1", _noEvidence(), 0, type(uint256).max, pay);
        _submit(doer, t); // mode B still works
    }

    function test_EthRefundToRejectingContract_IsCredited() public {
        RejectsEth c = new RejectsEth(vault);
        vm.deal(address(c), 1 ether);
        uint256 t = c.create{value: 0.5 ether}(); // excess 0.49 cannot be pushed back (no author fee)
        trackedTasks.push(t);
        assertEq(vault.credits(ETH, address(c)), 0.49 ether);
        _assertSolvent();
        address to = makeAddr("sink");
        c.withdrawTo(to);
        assertEq(to.balance, 0.49 ether);
    }

    /// @dev withdrawTo(token, address(0)) reverts before touching credits or liabilities: a plain value `call`
    /// to 0x0 has no code to fail, so it would burn the money.
    function test_WithdrawTo_ZeroAddress_Reverts() public {
        RejectsEth c = new RejectsEth(vault);
        vm.deal(address(c), 1 ether);
        c.create{value: 0.5 ether}();
        assertEq(vault.credits(ETH, address(c)), 0.49 ether);
        vm.expectRevert(WithdrawToZero.selector);
        c.withdrawTo(address(0));
        assertEq(vault.credits(ETH, address(c)), 0.49 ether, "nothing moved");
        assertEq(vault.liabilities(ETH), 0.5 ether, "the task's own 0.01 pot + the 0.49 credit, nothing extra");
    }

    function test_BlockedReceiver_PaidAsCredit() public {
        uint256 t1 = _createWithDeadline(author, address(usdc), 100e6, uint64(_now() + 1 days));
        _topUp(alice, t1, 50e6);
        usdc.setBlocked(alice, true);
        // a blocked doer does not block the task's settlement: block him only after he paid his bond (
        // needs a real USDC transfer from him to submit, which a frozen account cannot send either)
        uint256 t = _create(author, address(usdc), 100e6);
        _submit(doer, t);
        usdc.setBlocked(doer, true);
        _warp(24 hours);
        vault.poke(t);
        assertEq(vault.credits(address(usdc), doer), 90e6 + 3e6, "90% plus his rew bond back");
        // t1 expired meanwhile (the reward is locked until then): alice's share cannot be pushed, it is credited
        vm.prank(alice);
        vault.withdrawContribution(t1); // transfer fails -> credited, no revert
        assertEq(uint8(vault.getTask(t1).status), uint8(TaskStatus.Expired));
        assertEq(vault.credits(address(usdc), alice), 50e6);
        vm.prank(alice);
        vm.expectRevert(TransferFailed.selector);
        vault.withdraw(address(usdc));
        address fresh = makeAddr("fresh");
        vm.prank(alice);
        vault.withdrawTo(address(usdc), fresh);
        assertEq(usdc.balanceOf(fresh), 50e6);
        _assertSolvent();
    }

    function test_TreasurySweep_TakesEverything() public {
        // $800 IMD task: no mandatory swarm check, accepted when nobody disputes
        uint256 t = _create(author, address(imd), 100e18);
        _submit(doer, t);
        _warp(24 hours);
        vault.poke(t);
        // fee 10 IMD, without a dispute and without a doer stake all to the single treasury
        assertEq(vault.treasuryPot(address(imd)), 10e18);
        vault.sweepTreasury(address(imd));
        assertEq(vault.treasuryPot(address(imd)), 0); // nothing kept back: the treasury pays for nothing
        assertEq(vault.credits(address(imd), treasury), 10e18);
        assertEq(vault.treasuryPot(ETH), 0); // no author fee
        _claimEverythingAndCheck();
    }

    function test_ModeA_CallSwarmWithEth() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        _dispute(dave, s);
        _warp(24 hours);
        ImdPay memory pay = ImdPay({
            tokenIn: ETH,
            amountIn: 0.005 ether, // $12.5 at $2500/ETH = 1.5625 IMD at $8/IMD, for bond 0.5 + fee 0.5
            minImdOut: 1.5e18,
            deadline: uint64(_now() + 600),
            route: ""
        });
        uint256 ethBefore = erin.balance;
        vm.prank(erin);
        vault.callSwarm{value: 0.01 ether}(s, false, type(uint256).max, pay, _genericRuleTexts());
        assertEq(ethBefore - erin.balance, 0.005 ether);
        assertEq(imd.balanceOf(erin), 10_000e18 + 0.5625e18); // surplus IMD back: 1.5625 - (0.5 bond + 0.5 fee)
        assertEq(uint8(_phase(s)), uint8(Phase.Asked));
        _claimEverythingAndCheck();
    }

    function test_ReentrancyOnEthPayout_BlockedAndCredited() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        ReentrantDisputer r = new ReentrantDisputer(vault);
        imd.mint(address(r), 10e18);
        usdc.mint(address(r), 10e6);
        r.approveImd(address(imd));
        r.approveUsdc(address(usdc));
        vm.deal(address(this), 1 ether);
        r.dispute{value: 0.001 ether}(s);
        _vote(s, 1, 2, 120, 20);
        _warp(48 hours);
        vault.poke(t);
        r.claim();
        assertFalse(r.reentered());
        assertEq(vault.credits(ETH, address(r)), 0.001 ether); // ETH leftover kept as credit
        // fixed IMD bond is flat 0.5 (own bond back) + half of the doer's 0.5 IMD penalty (NFT decided
        // right, winnerBondBps 50%) = 0.5 + 0.25 = 0.75 credited on top of what he started with.
        assertEq(imd.balanceOf(address(r)), 10e18 + 0.25e18);
        _assertSolvent();
    }

    function test_TopUpHasNoFee() public {
        uint256 t = _create(author, address(usdc), 100e6);
        vm.prank(alice);
        vault.topUp(t, 10e6, _noSwap()); // no ETH needed: contributors pay no fee
        assertEq(vault.treasuryPot(ETH), 0); // no author fee either
        _claimEverythingAndCheck();
    }
}
