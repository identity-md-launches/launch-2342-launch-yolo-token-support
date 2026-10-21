// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/console.sol";
import {Base} from "../Base.t.sol";
import "../../src/VaultTypes.sol";

/// @dev Gas of the heaviest lazy step: one disputer with a 256-byte reason and proof, the longest doer note.
/// forge-config: default.isolate = false
contract ReviewGas is Base {
    uint8 constant REJECT = 2;

    function _longText(bytes1 c) internal pure returns (string memory) {
        bytes memory b = new bytes(256);
        for (uint256 i; i < 256; ++i) {
            b[i] = c;
        }
        return string(b);
    }

    /// @dev The longest allowed Evidence.note (MAX_NOTE_BYTES = 512).
    function _longNote(bytes1 c) internal pure returns (string memory) {
        bytes memory b = new bytes(MAX_NOTE_BYTES);
        for (uint256 i; i < MAX_NOTE_BYTES; ++i) {
            b[i] = c;
        }
        return string(b);
    }

    /// @dev A long proof: a link to an X post (task type x_post), padded to 256 bytes with a query tail.
    function _longProof() internal pure returns (string memory) {
        bytes memory head = "https://x.com/doer/status/1?";
        bytes memory b = new bytes(256);
        for (uint256 i; i < 256; ++i) {
            b[i] = i < head.length ? head[i] : bytes1("p");
        }
        return string(b);
    }

    /// @dev One dispute, one disputer - the worst-case question body is just
    ///      one 256-byte reason plus the doer's max-length note (no "first maxClaims of many"). The doer's
    ///      "why honest" text is the Evidence.note attached at submission; there is no separate doer reply.
    function _fullCase() internal returns (uint256 t, uint256 s) {
        t = _create(author, address(usdc), 100e6);
        vm.prank(doer);
        s = vault.submit(t, _longProof(), Evidence("", _longNote("d")), 0, type(uint256).max, _noSwap());
        address d = address(uint160(0xD15000));
        _fund(d); // the dispute bond's rew part is in the task's own currency (USDC here), not IMD
        vm.prank(d);
        vault.dispute(s, _longText("r"), _longText("p"), _noSwap());
    }

    /// @dev Worst-case resupply for `_fullCase` - the task's 3 rule texts
    ///      (generic, `_genericRuleTexts()`) plus the 256B dispute reason/proof `_fullCase` actually filed.
    function _fullCaseRuleTexts() internal pure returns (RuleTexts memory rt) {
        rt = _genericRuleTexts();
        rt.disputeReason = _longText("r");
        rt.disputerProofUri = _longText("p");
    }

    /// The ask is a separate step - appeal() only files it; `askAppealSwarm` resupplies
    /// (3x task rules + reason + proof) and asks; it must stay under 1.5M gas.
    function test_AppealAskGas_Under1_5M() public {
        (uint256 t, uint256 s) = _fullCase();
        _vote(s, 0, REJECT, 0, 100);
        _endVote(s); // the NFT decides at the vote end
        vm.prank(doer);
        vault.appeal(s, type(uint256).max, _noSwap());
        assertEq(uint8(_phase(s)), uint8(Phase.Appealed));
        uint256 g = gasleft();
        vault.askAppealSwarm(s, _fullCaseRuleTexts());
        g -= gasleft();
        console.log("askAppealSwarm -> swarm question (lazy ask, with resupply), gas:", g);
        console.log("body bytes:", intake.lastBodyLength());
        assertEq(uint8(_phase(s)), uint8(Phase.Asked));
        assertLt(g, 1_500_000);
        vault.poke(t); // no-op: already Asked
    }

    function test_CallSwarmGas_MaxBody() public {
        (uint256 t, uint256 s) = _fullCase();
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_phase(s)), uint8(Phase.NoDecision));
        vm.prank(dave);
        uint256 g = gasleft();
        vault.callSwarm(s, false, type(uint256).max, _noSwap(), _fullCaseRuleTexts());
        g -= gasleft();
        console.log("callSwarm max body (with resupply), gas:", g);
        console.log("body bytes:", intake.lastBodyLength());
    }
}
