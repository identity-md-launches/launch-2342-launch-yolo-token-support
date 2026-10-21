// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Base} from "../Base.t.sol";
import {TaskVault} from "../../src/TaskVault.sol";
import {ParamsRegistry} from "../../src/ParamsRegistry.sol";
import {Params, ParamsBounds} from "../../src/VaultParams.sol";
import "../../src/VaultTypes.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @dev Attack scenarios, each checked to fail against the contracts.
/// forge-config: default.isolate = false
contract ReviewProofs is Base {
    uint8 constant ACCEPT = 1;
    uint8 constant REJECT = 2;

    // The reward is locked until the deadline: the author cannot withdraw it, so swapping it out from under a
    //     submission is impossible; the minReward guard still applies (a reward lower than expected -> RewardChanged,
    //     the doer loses nothing).
    function test_FrontrunReward_SubmitRevertsWithMinReward() public {
        uint256 t = _create(author, address(usdc), 1_000e6);
        vm.prank(author);
        vm.expectRevert(TaskNotOpen.selector);
        vault.withdrawContribution(t);
        assertEq(vault.getTask(t).pot, 1_000e6);
        uint256 before = imd.balanceOf(doer);
        vm.prank(doer);
        vm.expectRevert(RewardChanged.selector);
        vault.submit(t, "https://x.com/doer/status/1", _noEvidence(), 1_000e6 + 1, type(uint256).max, _noSwap());
        assertEq(imd.balanceOf(doer), before);
        vm.prank(doer);
        uint256 s = vault.submit(t, "https://x.com/doer/status/1", _noEvidence(), 1_000e6, type(uint256).max, _noSwap());
        assertEq(_sub(s).reward, 1_000e6);
    }

    // No doubling: a submission placed after another one pays the same quote, maxImdIn = the quote passes.
    function test_BondNeverDoubles_SubmitPassesWithQuotedMax() public {
        uint256 t = _create(author, address(usdc), 100e6);
        Bond memory quoted = vault.quoteSubmission(t);
        _submit(doer2, t);
        vm.prank(doer);
        uint256 s = vault.submit(t, "https://x.com/doer/status/1", _noEvidence(), 100e6, quoted.rew, _noSwap());
        assertEq(_sub(s).bond.rew, quoted.rew, "the same 3%, no doubling behind another submission");
        assertEq(_sub(s).bond.imd, quoted.imd, "the same 0.5 IMD");
    }

    // The swarm price rose from 0.5 to 200 IMD: an appeal with maxImdIn at the old quote reverts.
    function test_AppealPriceJump_RevertsWithMaxImdIn() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        _dispute(dave, s);
        _vote(s, 0, REJECT, 0, 100);
        _endVote(s); // the NFT decides at the vote end
        assertEq(uint8(_phase(s)), uint8(Phase.Decided));
        uint256 quoted = vault.quoteDisputeBond(s).imd + vault.quoteSwarmFee(s);
        intake.setPrice(200e18);
        vm.prank(doer);
        vm.expectRevert(CostAboveMax.selector);
        vault.appeal(s, quoted, _noSwap());
    }

    // Invalid UTF-8 is not accepted; valid non-ASCII text neither (only English, ASCII 0x20..0x7e).
    function test_InvalidUtf8Rejected_NonAsciiRejected() public {
        uint256 t = _create(author, address(usdc), 1_000e6);
        bytes[5] memory bad = [
            bytes(hex"68747470733a2f2f78fffe"), // 0xFF
            bytes(hex"c0af"), // overlong '/'
            bytes(hex"eda080"), // surrogate
            bytes(hex"d0"), // truncated
            bytes(hex"e282")
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(doer);
            vm.expectRevert(BadText.selector);
            vault.submit(t, string(bad[i]), _noEvidence(), 0, type(uint256).max, _noSwap());
        }
        // the proof is a link by task type, the text rule (printable ASCII) comes first; non-ASCII is checked on the dispute reason
        uint256 s = _submit(doer, _create(author, address(usdc), 100e6)); // small: the dispute window opens at once
        vm.prank(dave);
        vm.expectRevert(BadText.selector); // only English, accented Latin reverts
        vault.dispute(s, "Post d\u00e9l\u00e9t\u00e9, code Z7 not visible", "ipfs://r4-proof", _noSwap());
        vm.prank(dave);
        vault.dispute(s, "Post deleted, code Z7 not visible", "ipfs://r4-proof", _noSwap());
        RuleTexts memory rt = _genericRuleTexts();
        rt.disputeReason = "Post deleted, code Z7 not visible";
        rt.disputerProofUri = "ipfs://r4-proof";
        (bytes memory body,) = vault.previewSwarmBody(s, SWARM_KIND_ESCALATION, rt);
        assertGt(body.length, 0);
    }

    // Parameter bounds do not let the question body exceed the Intake limit. (one dispute, one disputer):
    //     a dispute can have only one disputer at a time - a second dispute() reverts, its money is never taken;
    //     the question body (its reason plus the swarm caller's reason) stays within the limit even at the
    //     maximum maxTextBytes.
    function test_BodyBoundedByParams_OneDisputerOnly() public {
        Params memory p = defaultParams();
        p.maxClaims = 32;
        p.maxTextBytes = 512;
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(ParamsBounds.ParamOutOfBounds.selector, "bodySize"));
        registry.proposeParams(p);
        p.maxClaims = 33;
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(ParamsBounds.ParamOutOfBounds.selector, "maxClaims"));
        registry.proposeParams(p);

        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        bytes memory reason = new bytes(256);
        for (uint256 i; i < 256; ++i) {
            reason[i] = "a";
        }
        string memory proof = "ipfs://r5-proof";
        vm.prank(dave);
        vault.dispute(s, string(reason), proof, _noSwap());
        assertEq(vault.getDispute(s).disputer, dave);
        // a second disputer is rejected outright; their money never leaves their wallet
        uint256 erinBefore = usdc.balanceOf(erin);
        vm.prank(erin);
        vm.expectRevert(AlreadyDisputed.selector);
        vault.dispute(s, string(reason), proof, _noSwap());
        assertEq(usdc.balanceOf(erin), erinBefore, "the second disputer's money is untouched");
        assertEq(vault.getDispute(s).disputer, dave, "the first disputer stands");
        _warp(24 hours);
        vault.poke(t);
        RuleTexts memory rt = _genericRuleTexts();
        rt.disputeReason = string(reason);
        rt.disputerProofUri = proof;
        vm.prank(erin);
        // works: dave's reason/proof resupplied + erin's own call, well within the body limit (no "appeal" text
        // of its own)
        vault.callSwarm(s, false, type(uint256).max, _noSwap(), rt);
        assertLe(intake.lastBodyLength(), 16_384);
        assertEq(uint8(_phase(s)), uint8(Phase.Asked));
    }

    // The task deadline does not block a dispute, votes or an appeal on an already-active submission:
    //     the contract accepts them, so the site should not hide these buttons after the deadline.
    function test_DisputeVoteAppealAfterTaskDeadline() public {
        uint256 t = _createWithDeadline(author, address(usdc), 100e6, uint64(_now() + 1 days));
        uint256 s = _submit(doer, t);
        _warp(23 hours);
        _dispute(dave, s);
        _warp(2 hours); // the task deadline has passed
        assertGt(_now(), vault.getTask(t).deadline);
        _vote(s, 0, REJECT, 0, 100); // votes are accepted
        _endVote(s); // decided at the vote end
        assertEq(uint8(_phase(s)), uint8(Phase.Decided));
        _appeal(doer, s); // the appeal too
        // the ask is lazy: the appeal is only filed
        assertEq(uint8(_phase(s)), uint8(Phase.Appealed));
    }

    // An NFT holder with EIP-7702 delegation (code 0xef0100||impl on the address) votes with their own
    //     transaction: a vote carries no signature, so the delegated code changes nothing.
    function test_Eip7702Voter_EcdsaSignatureCounted() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        _dispute(dave, s);
        address impl = address(new MockERC20("x", "x", 18)); // any contract without isValidSignature
        vm.etch(voters[1], abi.encodePacked(hex"ef0100", impl));
        _vote(s, 1, REJECT, 120, 20); // sent by the holder, the NFT is theirs
        assertEq(vault.getDispute(s).votesReject, 20, "the delegated holder's own vote counted");
    }
}
