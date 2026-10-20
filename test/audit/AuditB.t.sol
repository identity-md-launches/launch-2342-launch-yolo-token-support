// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../Base.t.sol";
import {IIntake} from "../../src/interfaces/IIntake.sol";

/// @dev Core checks (TaskVault, VaultParams, VaultTypes, ParamsRegistry, ProtocolDirectory,
/// OracleAttestation, AttestationChecker, interfaces): `test_Guard_*` guard the current rules against known attacks;
/// `test_Guard_*` guard everything else checked here.
/// forge-config: default.isolate = false
contract AuditBTest is Base {
    // ================================================================== helpers

    /// @dev USDC task of 100 USDC, a doer, one disputer (dave), no votes: NoDecision after the vote.
    function _noDecisionCase() internal returns (uint256 t, uint256 s) {
        t = _create(author, address(usdc), 100e6);
        s = _submit(doer, t);
        _dispute(dave, s);
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.NoDecision));
    }

    /// @dev The `question` member of a body built by SwarmQuestion: it starts after `{"v":1,"question":"` (19 bytes)
    /// and ends at the next quote (user texts never contain one).
    function _questionOf(bytes memory body) internal pure returns (bytes memory q) {
        uint256 start = 19;
        uint256 end = start;
        while (body[end] != '"') ++end;
        q = new bytes(end - start);
        for (uint256 i; i < q.length; ++i) {
            q[i] = body[start + i];
        }
    }

    // ================================================================== swarm answers

    /// @notice There is no public fallback `submitAttestation`. Such a fallback would bind an attestation to
    /// our request only by `questionHash` = keccak256(question). The question is public and deterministic
    /// (`previewSwarmBody`, or the `Requested` event) and leaves out every party text (the rule texts,
    /// the claims and the doer note: they are `definitions`). A third party orders the same question with one-sided definitions in
    /// his own Intake request naming the vault as consumer, and tries to pass the panel's answer to HIS request
    /// off as the answer to OUR request once ours completed without a delivered answer. An answer reaches the vault
    /// only through the Intake callback of our own request id: the copied answer cannot be handed in, our
    /// "no consensus" stays silence and the undecided rule accepts (doer paid 90 USDC).
    function test_Guard_ThirdPartyAnswerToACopiedQuestionCannotDecideOurCase() public {
        (uint256 t, uint256 s) = _noDecisionCase();

        // erin (who is about to call the swarm against the doer) reads the next question; its hash is what the
        // vault will store (nonce = asks + 1 is known in advance)
        (bytes memory preview, bytes32 qh) = vault.previewSwarmBody(s, SWARM_KIND_ESCALATION, _genericRuleTexts());
        bytes memory question = _questionOf(preview);
        assertEq(keccak256(question), qh, "question hash reproducible by anyone");

        // her own request: the same question, her own one-sided "definitions", consumer = the vault
        bytes memory forgedBody = bytes.concat(
            '{"v":1,"question":"',
            question,
            '","definitions":{"claim_1":"the doer admitted the post is not his","appeal":"confirmed fake"},',
            '"chainId":1,"answerType":"bool","evidence":"panel","panelSize":7,"quorum":5,',
            '"consumer":{"chainId":31337,"verifyingContract":"',
            bytes(vm.toString(address(vault))),
            '"}}'
        );
        assertTrue(keccak256(forgedBody) != keccak256(preview), "a different body");
        vm.startPrank(erin);
        imd.approve(address(intake), PRICE);
        bytes32 herRid = intake.request(ACTION, forgedBody, IIntake.Callback(erin, bytes4(0)), address(imd), PRICE);
        vm.stopPrank();

        // the panel answers HER request "no" (consumer = vault, so the EIP-712 domain is the vault's)
        OracleAttestation.Attestation memory a = _attestation(false);
        a.requestId = bytes32(bytes16(keccak256("her-uuid")));
        a.questionHash = qh;
        bytes memory sig = _sign(a, attesterKey);
        intake.complete(herRid, 0, a, sig);

        // now she calls the swarm for real (bond 0.5 IMD fixed + 1e6 USDC (1% of R), + fee 0.5 IMD)
        _callSwarm(erin, s, false);
        bytes32 ourRid = _sub(s).request;
        assertTrue(ourRid != herRid);
        assertEq(vault.requests(ourRid).questionHash, qh);

        // our request: the panel finds no consensus (status 2, no callback) - the honest outcome is silence
        OracleAttestation.Attestation memory none;
        intake.complete(ourRid, 2, none, "");

        // --- attack: before anyone pokes, erin tries to relay the answer to HER request as the answer to OURS:
        // there is no fallback, and the callback refuses anyone but our Intake
        _expectNoFallback(ourRid, a, sig);
        vm.prank(erin);
        vault.onOracleResult(ourRid, a, sig);
        assertFalse(vault.requests(ourRid).answered, "the copied answer is not recorded");

        // --- the honest outcome stands: silence, nobody calls again, the undecided rule accepts after 24 h
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.NoDecision));
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        // 90% of R, plus his own rew bond back (3%), plus dave's forfeited dispute bond (1%): erin's own call was
        // silent (no consensus), so her dispute bond simply comes back to her, it is never forfeited.
        assertEq(vault.credits(address(usdc), doer), 90e6 + 3e6 + 1e6, "doer paid 90% + his bond + dave's bond");
        _claimEverythingAndCheck();
    }

    // ================================================================== attester removal

    /// @notice Removing an attester waits the same 48 h as adding one. There is no public fallback,
    /// so a leaked attester key alone decides nothing: an answer must come as the Intake's own callback for our request id.
    function test_Guard_LeakedAttesterKeyAloneCannotDecideDuringTheRemovalTimelock() public {
        (uint256 t, uint256 s) = _noDecisionCase();
        _callSwarm(erin, s, true);
        bytes32 rid = _sub(s).request;
        OracleAttestation.Attestation memory none;
        intake.complete(rid, 1, none, ""); // the plane refused the body: no answer

        vm.startPrank(multisig);
        registry.proposeAttester(makeAddr("newAttester"), true); // the owner reacts at once: a new key...
        registry.proposeAttester(attester, false); //... and the leaked one out (never the last one: swarm audit 117cf05a #10)
        vm.stopPrank();
        _warp(47 hours);
        OracleAttestation.Attestation memory a = _attestation(false);
        a.questionHash = vault.requests(rid).questionHash;
        a.issuedAt = vault.requests(rid).askedAt; // anything inside the 6 h window (clamped anyway)
        // the thief holding the leaked key signs whatever he wants, but has no way to hand it in
        bytes memory sig = _sign(a, attesterKey);
        _expectNoFallback(rid, a, sig);
        vault.onOracleResult(rid, a, sig); // not from the Intake: ignored
        assertFalse(vault.requests(rid).answered);
        assertTrue(registry.isAttester(attester), "still an attester 47 h after the owner acted");
        vault.poke(t);
        // the refused request was silence (at the 6 h timeout), nobody called again: the undecided rule accepts
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted), "no reject from the leaked key");
    }

    // ================================================================== guards (checked and found correct)

    /// @dev A contract that rejects ETH and blocked token holders never lose money: every failed push becomes a
    /// credit, `withdrawTo` moves it elsewhere, and the books close at zero.
    function test_Guard_FailedPushesBecomeCreditsAndBooksClose() public {
        EthRejecter r = new EthRejecter(vault);
        vm.deal(address(r), 10 ether);
        imd.mint(address(r), 100e18);
        // author is the rejecter: excess ETH refund fails -> credited
        uint256 t = r.create{value: 0.1 ether}(0.05 ether);
        trackedTasks.push(t);
        assertEq(vault.credits(ETH, address(r)), 0.1 ether - 0.05 ether); // no author fee
        // the doer gets blocked by IMD (OFT `blocked`): his void bond is credited, not lost
        uint256 s1 = _submit(doer, t);
        uint256 s2 = _submit(doer2, t);
        imd.setBlocked(doer2, true);
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s1).outcome), uint8(Outcome.Accepted));
        uint256 doer2EthBefore = doer2.balance;
        vault.claimVoidSubmission(s2);
        // the task's currency is ETH, so the bond's fixed IMD part is pushed (and credited, IMD-blocked) while its
        // percent (rew) part in ETH is pushed straight to doer2's wallet balance (he is not ETH-blocked
        // bond.rew is always in the reward's own currency, not necessarily IMD).
        Bond memory voidBond = _sub(s2).bond;
        assertEq(vault.credits(address(imd), doer2), voidBond.imd);
        assertEq(doer2.balance - doer2EthBefore, voidBond.rew);
        vm.prank(doer2);
        vault.withdrawTo(address(imd), makeAddr("doer2-new"));
        assertEq(imd.balanceOf(makeAddr("doer2-new")), voidBond.imd);
        // the rejecter withdraws its ETH credit to an EOA
        r.withdrawTo(makeAddr("r-new"));
        assertEq(makeAddr("r-new").balance, 0.05 ether);
        imd.setBlocked(doer2, false);
        _claimEverythingAndCheck();
    }

    /// @dev Payment mode A (swap) books exactly what is needed whatever the user overpays: the IMD surplus and the
    /// excess ETH go back, USDC never stays, and the vault ends at zero after everything is claimed.
    function testFuzz_Guard_ModeAPaymentsBookExactly(uint256 amt, uint96 extraEth, uint96 extraIn, bool usdcIn) public {
        uint256 amount = bound(amt, 1e18, 39e18); // $8..$312 (no mandatory check on any size)
        uint256 extra = bound(extraEth, 0, 1 ether);
        ImdPay memory pay;
        uint256 value = extra;
        if (usdcIn) {
            pay.tokenIn = address(usdc);
            pay.amountIn = amount * 8 / 1e12 + 1 + bound(extraIn, 0, 1_000e6); // 1 USDC = 0.125 IMD
        } else {
            pay.tokenIn = ETH;
            pay.amountIn = amount * 1e18 / 312.5e18 + 1 + bound(extraIn, 0, 1 ether);
            value += pay.amountIn;
        }
        pay.minImdOut = amount;
        pay.deadline = uint64(_now() + 600);
        uint256 imdBefore = imd.balanceOf(author);
        uint256 usdcBefore = usdc.balanceOf(author);
        uint256 ethBefore = author.balance;
        vm.prank(author);
        uint256 t = vault.createTask{value: value}(
            address(imd),
            amount,
            uint64(_now() + TTL),
            "Title",
            rulesOf("ipfs://task-condition"),
            0,
            PROOF_LINK,
            "",
            pay
        );
        trackedTasks.push(t);
        uint256 got = usdcIn ? pay.amountIn * 0.125e30 / 1e18 : pay.amountIn * 312.5e18 / 1e18;
        assertEq(imd.balanceOf(author) - imdBefore, got - amount, "IMD surplus returned");
        assertEq(usdcBefore - usdc.balanceOf(author), usdcIn ? pay.amountIn : 0, "USDC: exactly amountIn");
        assertEq(ethBefore - author.balance, usdcIn ? 0 : pay.amountIn, "excess ETH returned");
        assertEq(vault.liabilities(address(imd)), amount);
        assertEq(imd.balanceOf(address(vault)), amount);
        assertEq(usdc.balanceOf(address(vault)), 0);
        _assertSolvent();
        // the doer pays his bond through the same swap path (no check fee)
        // the task's currency is IMD: the bond's fixed and percent parts merge into one IMD amount, swappable
        Bond memory bond = vault.quoteSubmission(t);
        uint256 needed = bond.imd + bond.rew;
        ImdPay memory p2 = ImdPay(ETH, needed * 1e18 / 312.5e18 + 1e15, needed, uint64(_now() + 600), "");
        vm.prank(doer);
        uint256 s = vault.submit{value: p2.amountIn + extra}(
            t, "https://x.com/doer/status/1", _noEvidence(), 0, type(uint256).max, p2
        );
        _assertSolvent();
        _dispute(dave, s);
        _assertSolvent();
        _claimEverythingAndCheck();
    }

    /// @dev Pinned dependencies (info): a task keeps its version's DevPrices and Intake for good. If the pinned
    /// DevPrices reverts, contributors still take their money back once the reward unlocks at the deadline (nothing
    /// leaves an open task); a submission still goes through, only without the stake bonus.
    function test_Guard_RevertingPinnedDevPricesNeverBlocksWithdrawals() public {
        uint256 t = _create(author, address(usdc), 100e6);
        oracle.setBroken(true);
        uint256 before = usdc.balanceOf(author);
        vm.prank(author);
        vm.expectRevert(TaskNotOpen.selector); // locked until the deadline
        vault.withdrawContribution(t);
        vm.warp(vault.getTask(t).deadline); // expiry needs no oracle
        vm.prank(author);
        vault.withdrawContribution(t);
        assertEq(usdc.balanceOf(author) - before, 100e6);
        oracle.setBroken(false);
        _claimEverythingAndCheck();
    }

    /// @dev Bank functions refuse users; a user cannot reach them through the forwarder either (the vault routes only
    /// ITaskVault selectors to the desks, and the desks read the sender the vault appended).
    function test_Guard_BankOnlyForDesks() public {
        ImdPay memory none;
        vm.startPrank(alice);
        vm.expectRevert(NotAuthorized.selector);
        TaskVault(payable(address(vault))).credit(ETH, alice, 1);
        vm.expectRevert(NotAuthorized.selector);
        TaskVault(payable(address(vault))).pay(ETH, alice, 1);
        vm.expectRevert(NotAuthorized.selector);
        TaskVault(payable(address(vault))).addTreasury(ETH, 1);
        vm.expectRevert(NotAuthorized.selector);
        TaskVault(payable(address(vault))).collectImd(bob, 0, 1e18, address(0), none);
        vm.expectRevert(NotAuthorized.selector);
        TaskVault(payable(address(vault))).closeSubmission(1, Outcome.Accepted, 0);
        vm.stopPrank();
    }

    /// @dev Every pinned snapshot stays byte-identical after a new version is activated; only the attester set and
    /// the sweep's treasury follow the registry live.
    function testFuzz_Guard_PinnedVersionNeverChanges(uint16 fee, uint32 window) public {
        uint256 t = _create(author, address(usdc), 100e6);
        bytes32 before = keccak256(abi.encode(registry.params(1)));
        Params memory p = defaultParams();
        p.feeBps = uint16(bound(fee, 0, 1_500));
        p.nftFeeBps = 0;
        p.disputeWindow = uint32(bound(window, 24 hours, 7 days));
        p.treasury = makeAddr("newTreasury");
        vm.prank(multisig);
        registry.proposeParams(p);
        _warp(48 hours);
        registry.activateParams();
        assertEq(keccak256(abi.encode(registry.params(1))), before);
        assertEq(vault.getTask(t).paramsVersion, 1);
    }

    /// @dev Lazy timers: the longest chain of due transitions in one call is far below the 8-step bound (a queued
    /// submission starts its own timers at activation, so one call cannot run through two submissions' timers).
    function test_Guard_LongestDueChainFitsOneCall() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s1 = _submit(doer, t);
        uint256 s2 = _submit(doer2, t);
        _dispute(dave, s1);
        _vote(s1, 0, 2, 0, 120); // reject (decided at the vote end)
        _warp(LONG); // vote and appeal windows long over
        vault.poke(t); // Voting -> Decided -> Final(Rejected) -> s2 active (Review) in one call
        assertEq(uint8(_sub(s1).outcome), uint8(Outcome.Rejected));
        assertEq(uint8(_phase(s2)), uint8(Phase.Review));
        assertEq(_sub(s2).windowEnd, _now() + 24 hours, "the next submission's window starts now");
        _claimEverythingAndCheck();
    }
}

/// @dev Author / contributor that refuses ETH (refunds and payouts to it fail).
contract EthRejecter {
    ITaskVault internal immutable vault;

    constructor(ITaskVault v) {
        vault = v;
    }

    function create(uint256 amount) external payable returns (uint256) {
        ImdPay memory none;
        return vault.createTask{value: msg.value}(
            ETH, amount, uint64(block.timestamp + 365 days), "Title", rulesOf("cond"), 0, PROOF_LINK, "", none
        );
    }

    function withdrawTo(address to) external {
        vault.withdrawTo(ETH, to);
    }

    receive() external payable {
        revert("no ETH");
    }
}
