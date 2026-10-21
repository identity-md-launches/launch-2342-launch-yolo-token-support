// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./Base.t.sol";
import {AskTerms, Facts} from "../src/desks/DeskApi.sol";
import {LaunchParams} from "../src/VaultParams.sol";

/// @dev A doer stake hub that misbehaves on purpose. The CaseDesk asks `powerAt(who, t)` at the submission (this
/// answers 1M $YOLO, the whole 4% on $100, unless `powerFails`); the DisputeDesk asks `stakePower(who, since)` at
/// the payout with a staticcall: 0 reverts, 1 answers 64 bytes, 2 answers the largest number, 3 answers nothing,
/// 4 answers 1 only for the expected doer and submission time (and 0 otherwise).
contract MockDoerStake {
    uint8 public mode;
    address public expectWho;
    uint64 public expectSince;
    bool public powerFails;

    function set(uint8 m, address who, uint64 since) external {
        (mode, expectWho, expectSince) = (m, who, since);
    }

    function setPowerFails(bool f) external {
        powerFails = f;
    }

    fallback(bytes calldata data) external returns (bytes memory) {
        if (bytes4(data[:4]) == bytes4(keccak256("powerAt(address,uint256)"))) {
            require(!powerFails, "hub down");
            return abi.encode(uint256(1_000_000e18));
        }
        require(bytes4(data[:4]) == bytes4(keccak256("stakePower(address,uint64)")), "selector");
        (address who, uint64 since) = abi.decode(data[4:], (address, uint64));
        if (mode == 0) revert("hub down");
        if (mode == 1) return abi.encode(uint256(1), uint256(1));
        if (mode == 2) return abi.encode(type(uint256).max);
        if (mode == 3) return "";
        return abi.encode(who == expectWho && since == expectSince ? 1 : 0);
    }
}

/// @dev The launch split: one public vault, two desks behind it. Who may call what, and the forwarding itself.
/// forge-config: default.isolate = false
contract DesksTest is Base {
    address internal stranger = makeAddr("stranger");

    // ------------------------------------------------------------------ wiring

    function test_DesksAreWiredToThisVaultOnce() public {
        assertEq(caseDesk.vault(), address(vault));
        assertEq(disputeDesk.vault(), address(vault));
        assertEq(vault.caseDesk(), address(caseDesk));
        assertEq(vault.disputeDesk(), address(disputeDesk));
        vm.prank(stranger);
        vm.expectRevert(WiringClosed.selector);
        caseDesk.wire(address(registry), address(imd), address(usdc), stranger, stranger);
        vm.expectRevert(WiringClosed.selector);
        disputeDesk.wire(address(registry), address(imd), address(usdc), stranger, stranger);
    }

    function test_VaultRefusesDesksOfAnotherEnvironment() public {
        TextRules text = new TextRules();
        CaseDesk cd = new CaseDesk(
            address(registry),
            address(imd),
            address(usdc),
            address(text),
            address(new SwarmQuestionBuilder()),
            address(yolo),
            address(hub)
        );
        DisputeDesk dd = new DisputeDesk(
            address(registry),
            address(usdc),
            address(usdc),
            address(text),
            address(votePower),
            address(yolo),
            address(hub)
        );
        AttestationChecker checker = new AttestationChecker(address(registry));
        vm.expectRevert(WrongWiring.selector); // the dispute desk was built for another IMD address
        new TaskVault(
            address(registry),
            address(imd),
            address(usdc),
            address(yolo),
            address(checker),
            address(text),
            address(cd),
            address(dd),
            address(burner)
        );
    }

    /// @notice The burner is paid on every staked payout: a burner without code cannot be wired (WrongWiring). The
    /// doer stake (YoloLockHub) may be deployed after the desk in the same launch, so the desk takes any
    /// address; a hub without code (or a failing one) only means "not staked": the payout goes on (10% fee).
    function test_BurnerMustHaveCode_DoerStakeMayBeLater() public {
        TextRules text = new TextRules();
        address ballots = address(votePower);
        assertEq(stranger.code.length, 0);
        CaseDesk cd = new CaseDesk(
            address(registry),
            address(imd),
            address(usdc),
            address(text),
            address(new SwarmQuestionBuilder()),
            address(yolo),
            address(hub)
        );
        DisputeDesk dd = new DisputeDesk(
            address(registry), address(imd), address(usdc), address(text), ballots, address(yolo), stranger
        );
        assertEq(address(dd.doerStake()), stranger);
        cd = new CaseDesk(
            address(registry),
            address(imd),
            address(usdc),
            address(text),
            address(new SwarmQuestionBuilder()),
            address(yolo),
            stranger
        );
        AttestationChecker checker = new AttestationChecker(address(registry));
        vm.expectRevert(WrongWiring.selector);
        new TaskVault(
            address(registry),
            address(imd),
            address(usdc),
            address(yolo),
            address(checker),
            address(text),
            address(cd),
            address(dd),
            stranger
        );
        // the same desks with a real burner: a vault whose doer stake has no code still pays every acceptance
        ITaskVault v2 = ITaskVault(
            address(
                new TaskVault(
                    address(registry),
                    address(imd),
                    address(usdc),
                    address(yolo),
                    address(checker),
                    address(text),
                    address(cd),
                    address(dd),
                    address(burner)
                )
            )
        );
        vm.prank(author);
        usdc.approve(address(v2), type(uint256).max);
        vm.prank(doer);
        imd.approve(address(v2), type(uint256).max);
        vm.prank(author);
        uint256 t =
            v2.createTask(address(usdc), 100e6, uint64(_now() + 1 days), "Title", rulesOf("c"), 0, 0, "", _noSwap());
        vm.prank(doer);
        uint256 s = v2.submit(t, "https://x.com/doer/status/1", _noEvidence(), 0, type(uint256).max, _noSwap());
        _warp(24 hours);
        v2.poke(t);
        assertEq(uint8(v2.getSubmission(s).outcome), uint8(Outcome.Accepted));
        assertEq(v2.credits(address(usdc), doer), 90e6);
        assertEq(v2.treasuryPot(address(usdc)), 10e6);
        assertEq(v2.getSettlement(s).stakeBps, 0);
        assertEq(vault.burner(), address(burner));
        assertEq(address(disputeDesk.doerStake()), address(hub));
    }

    /// @dev A vault (with fresh desks) whose DisputeDesk asks `hub_` for the doer stake.
    function _vaultWithHub(address hub_) internal returns (ITaskVault v) {
        TextRules text = new TextRules();
        address r = address(registry);
        CaseDesk cd = new CaseDesk(
            r, address(imd), address(usdc), address(text), address(new SwarmQuestionBuilder()), address(yolo), hub_
        );
        DisputeDesk dd =
            new DisputeDesk(r, address(imd), address(usdc), address(text), address(votePower), address(yolo), hub_);
        v = ITaskVault(
            address(
                new TaskVault(
                    r,
                    address(imd),
                    address(usdc),
                    address(yolo),
                    address(new AttestationChecker(r)),
                    address(text),
                    address(cd),
                    address(dd),
                    address(burner)
                )
            )
        );
        vm.prank(author);
        usdc.approve(address(v), type(uint256).max);
        vm.startPrank(doer);
        imd.approve(address(v), type(uint256).max);
        usdc.approve(address(v), type(uint256).max); // the doer bond's rew part is in R's own currency
        vm.stopPrank();
    }

    /// @notice The stake check never blocks a submission or a payout and never pays more than 4%:
    /// at the payout a hub that reverts, answers anything but one word or nothing counts as no stake ($90 /
    /// treasury $10); any running answer pays the share fixed at the submission, never more ($94, burner
    /// $5.50, treasury $0.50). The desk asks for the doer and the submission's time (`submittedAt`). A hub that
    /// fails at the submission: the submission goes through without a bonus.
    function test_DoerStakeHub_FailingOrOversizedAnswer() public {
        MockDoerStake m = new MockDoerStake();
        ITaskVault v = _vaultWithHub(address(m));
        uint256[5] memory bps = [uint256(0), 0, 400, 0, 400];
        for (uint8 mode; mode < 5; ++mode) {
            _warp(1);
            vm.prank(author);
            uint256 t = v.createTask(
                address(usdc), 100e6, uint64(_now() + 7 days), "Title", rulesOf("c"), 0, PROOF_LINK, "", _noSwap()
            );
            vm.prank(doer);
            uint256 s = v.submit(t, "https://x.com/doer/status/1", _noEvidence(), 0, type(uint256).max, _noSwap());
            assertEq(v.getSubmission(s).stakeBps, 400, "fixed at the submission");
            m.set(mode, doer, v.getSubmission(s).submittedAt);
            uint256 credit0 = v.credits(address(usdc), doer);
            uint256 pot0 = v.treasuryPot(address(usdc));
            uint256 burn0 = usdc.balanceOf(buybackWallet);
            _warp(24 hours);
            v.poke(t);
            assertEq(uint8(v.getSubmission(s).outcome), uint8(Outcome.Accepted));
            assertEq(v.getSettlement(s).stakeBps, bps[mode], "stake share");
            bool bonus = bps[mode] != 0;
            assertEq(v.credits(address(usdc), doer) - credit0, bonus ? 94e6 + 3e6 : 90e6 + 3e6, "doer");
            assertEq(v.treasuryPot(address(usdc)) - pot0, bonus ? 0.5e6 : 10e6, "treasury");
            assertEq(usdc.balanceOf(buybackWallet) - burn0, bonus ? 5.5e6 : 0, "buyback wallet");
            assertEq(usdc.balanceOf(address(burner)), 0, "autosent, nothing waits in the burner");
        }
        // mode 4 with another submission time expected: the desk passes submittedAt, so the answer is 0
        vm.prank(author);
        uint256 t2 = v.createTask(
            address(usdc), 100e6, uint64(_now() + 7 days), "Title", rulesOf("c"), 0, PROOF_LINK, "", _noSwap()
        );
        vm.prank(doer);
        uint256 s2 = v.submit(t2, "https://x.com/doer/status/1", _noEvidence(), 0, type(uint256).max, _noSwap());
        m.set(4, doer, v.getSubmission(s2).submittedAt + 1);
        _warp(24 hours);
        v.poke(t2);
        assertEq(v.getSettlement(s2).stakeBps, 0);
        // the hub fails at the submission: submitted all the same, no bonus fixed
        m.setPowerFails(true);
        vm.prank(author);
        uint256 t3 = v.createTask(
            address(usdc), 100e6, uint64(_now() + 7 days), "Title", rulesOf("c"), 0, PROOF_LINK, "", _noSwap()
        );
        vm.prank(doer);
        uint256 s3 = v.submit(t3, "https://x.com/doer/status/1", _noEvidence(), 0, type(uint256).max, _noSwap());
        assertEq(v.getSubmission(s3).stakeBps, 0);
    }

    function test_VaultRefusesCheckerOfAnotherRegistry() public {
        TextRules text = new TextRules();
        CaseDesk cd = new CaseDesk(
            address(registry),
            address(imd),
            address(usdc),
            address(text),
            address(new SwarmQuestionBuilder()),
            address(yolo),
            address(hub)
        );
        DisputeDesk dd = new DisputeDesk(
            address(registry),
            address(imd),
            address(usdc),
            address(text),
            address(votePower),
            address(yolo),
            address(hub)
        );
        AttestationChecker foreign = new AttestationChecker(stranger);
        vm.expectRevert(WrongWiring.selector);
        new TaskVault(
            address(registry),
            address(imd),
            address(usdc),
            address(yolo),
            address(foreign),
            address(text),
            address(cd),
            address(dd),
            address(burner)
        );
    }

    // ------------------------------------------------------------------ desks accept only the vault and each other

    function test_DeskUserFunctionsOnlyThroughTheVault() public {
        uint256 t = _create(author, address(imd), 10e18);
        ImdPay memory none;
        vm.startPrank(doer);
        vm.expectRevert(NotAuthorized.selector);
        caseDesk.submit(t, "https://github.com/p", _noEvidence(), 0, 100e18, none);
        vm.expectRevert(NotAuthorized.selector);
        disputeDesk.claimDisputer(1);
        vm.stopPrank();
    }

    function test_DeskInternalFunctionsRefuseStrangers() public {
        vm.startPrank(stranger);
        vm.expectRevert(NotAuthorized.selector);
        caseDesk.step(1);
        vm.expectRevert(NotAuthorized.selector);
        caseDesk.advanced(1);
        vm.expectRevert(NotAuthorized.selector);
        caseDesk.startVote(1, 1);
        vm.expectRevert(NotAuthorized.selector);
        caseDesk.markAppealed(1);
        RuleTexts memory rt;
        vm.expectRevert(NotAuthorized.selector);
        caseDesk.askEscalation(1, 1, rt);
        vm.expectRevert(NotAuthorized.selector);
        caseDesk.askAppeal(1, 1, rt);
        vm.expectRevert(NotAuthorized.selector);
        disputeDesk.appealAsked(1, 1);
        vm.expectRevert(NotAuthorized.selector);
        disputeDesk.dropCaller(1);
        Facts memory f;
        vm.expectRevert(NotAuthorized.selector);
        disputeDesk.settle(1, Outcome.Accepted, f);
        vm.stopPrank();
    }

    function test_VaultBankAndTaskHooksRefuseStrangers() public {
        TaskVault v = TaskVault(payable(address(vault)));
        ImdPay memory none;
        AskTerms memory at;
        vm.startPrank(stranger);
        vm.expectRevert(NotAuthorized.selector);
        v.collectImd(alice, 0, 1e18, address(0), none);
        vm.expectRevert(NotAuthorized.selector);
        v.credit(address(imd), stranger, 1e18);
        vm.expectRevert(NotAuthorized.selector);
        v.pay(address(imd), stranger, 1e18);
        vm.expectRevert(NotAuthorized.selector);
        v.addTreasury(address(imd), 1e18);
        vm.expectRevert(NotAuthorized.selector);
        v.burn(address(imd), 1e18);
        vm.expectRevert(NotAuthorized.selector);
        v.settleValue(stranger, 1 ether, 0);
        vm.expectRevert(NotAuthorized.selector);
        v.ask(at, "");
        vm.expectRevert(NotAuthorized.selector);
        v.advance(1);
        vm.expectRevert(NotAuthorized.selector);
        v.place(1, 1, false);
        vm.expectRevert(NotAuthorized.selector);
        v.closeSubmission(1, Outcome.Accepted, 0);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ forwarding

    function test_UnknownFunctionAndStrayEthRevert() public {
        (bool ok, bytes memory ret) = address(vault).call(abi.encodeWithSignature("nope()"));
        assertFalse(ok);
        assertEq(bytes4(ret), UnknownFunction.selector);
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (ok,) = address(vault).call{value: 1}("");
        assertFalse(ok, "plain ETH has no route");
    }

    function test_ValueOnlyToPayableRoutes() public {
        uint256 t = _create(author, address(imd), 10e18);
        uint256 s = _submit(doer, t);
        vm.deal(doer, 1 ether);
        vm.prank(doer);
        (bool ok, bytes memory ret) = address(vault).call{value: 1}(abi.encodeCall(ITaskVault.claimVoidSubmission, (s)));
        assertFalse(ok);
        assertEq(bytes4(ret), TaskVault.NotPayable.selector);
        vm.prank(doer);
        (ok,) = address(vault).call{value: 1}(abi.encodeCall(ITaskVault.getSubmission, (s)));
        assertFalse(ok, "views take no ETH");
    }

    function test_ForwardedCallsKeepTheSender() public {
        uint256 t = _create(author, address(imd), 10e18);
        uint256 s = _submit(doer, t);
        assertEq(vault.getSubmission(s).doer, doer, "the doer is the caller of the vault, not the vault");
        assertEq(vault.getTask(t).author, author);
    }

    function test_DeskErrorsBubbleUnchanged() public {
        vm.prank(stranger);
        vm.expectRevert(NothingToClaim.selector);
        vault.claimVoidSubmission(1);
    }

    function test_ParamsOfIsTheRegistrySnapshot() public view {
        assertEq(vault.paramsOf(1).bondFixedImd, registry.params(1).bondFixedImd);
        assertEq(vault.paramsOf(1).minRewardUsdc, registry.params(1).minRewardUsdc);
        assertEq(vault.paramsOf(1).questionPrefix, registry.params(1).questionPrefix);
    }

    // ------------------------------------------------------------------ launch parameters

    /// @dev The numbers compiled into the registry are the ones the tests
    /// use: the test defaults and LaunchParams must not drift apart.
    function test_LaunchParamsEqualTheTestedOnes() public view {
        // split in two (via-IR stack-too-deep on the whole-program build with every test file): each
        // half holds only one big Params struct live at a time instead of two plus the registry's snapshot.
        _checkLaunchParamsFields();
        _checkLaunchParamsHash();
    }

    function _checkLaunchParamsFields() internal view {
        Params memory a = LaunchParams.initial(
            address(intake), address(oracle), address(adapter), address(nft), address(delegates), treasury
        );
        // the fields of the batch, one by one (a drift shows which one)
        assertEq(a.minRewardUsdc, 5e6);
        assertEq(a.minRewardEth, 0.002e18);
        assertEq(a.minRewardImd, 1e18);
        assertEq(a.minRewardYolo, 1_000e18);
        assertEq(a.bondFixedImd, 0.5e18);
        assertEq(a.doerBondBps, 300);
        assertEq(a.disputeBondBps, 100);
        assertEq(a.feeBps, 1_000);
        assertEq(a.nftFeeBps, 500);
    }

    function _checkLaunchParamsHash() internal view {
        Params memory a = LaunchParams.initial(
            address(intake), address(oracle), address(adapter), address(nft), address(delegates), treasury
        );
        Params memory d = defaultParams();
        assertEq(d.minRewardUsdc, a.minRewardUsdc);
        assertEq(d.minRewardEth, a.minRewardEth);
        assertEq(d.minRewardImd, a.minRewardImd);
        assertEq(d.minRewardYolo, a.minRewardYolo);
        assertEq(d.bondFixedImd, a.bondFixedImd);
        assertEq(d.nftFeeBps, a.nftFeeBps);
        assertEq(keccak256(abi.encode(a)), keccak256(abi.encode(d)));
        assertEq(keccak256(abi.encode(registry.params(1))), keccak256(abi.encode(a)));
    }
}
