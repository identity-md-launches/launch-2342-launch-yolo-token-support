// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./Base.t.sol";

/// @dev The disputer's own proof link is optional: an empty link passes and
///      leaves no "claim_1_proof" definition in the swarm question; a non-empty link follows the text rule; the
///      reason stays mandatory.
/// forge-config: default.isolate = false
contract DisputeLinkOptionalTest is Base {
    function _disputeWith(address who, uint256 subId, string memory reason, string memory link) internal {
        vm.prank(who);
        vault.dispute{value: ETH_BOND_HEADROOM}(subId, reason, link, _noSwap());
    }

    function _texts(string memory link) internal pure returns (RuleTexts memory rt) {
        rt = _genericRuleTexts();
        rt.disputerProofUri = link;
    }

    function _has(bytes memory hay, bytes memory needle) internal pure returns (bool) {
        if (needle.length > hay.length) return false;
        for (uint256 i; i + needle.length <= hay.length; ++i) {
            bool ok = true;
            for (uint256 j; j < needle.length; ++j) {
                if (hay[i + j] != needle[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }

    function test_EmptyLinkPasses() public {
        uint256 t = _create(author, address(usdc), 50e6);
        uint256 s = _submit(doer, t);
        vm.expectEmit(true, true, false, false);
        emit Disputed(s, dave, 0, 0, "", "");
        uint256 g = gasleft();
        _disputeWith(dave, s, DISPUTE_REASON, "");
        emit log_named_uint("dispute gas, empty link (test env)", g - gasleft());
        assertEq(uint8(_phase(s)), uint8(Phase.Voting));

        // the swarm question: the reason is there, no claim_1_proof definition at all
        (bytes memory body,) = vault.previewSwarmBody(s, SWARM_KIND_ESCALATION, _texts(""));
        assertTrue(_has(body, bytes(string.concat('"claim_1":"', DISPUTE_REASON, '"'))));
        assertFalse(_has(body, bytes("claim_1_proof")));

        // the stored hash binds the empty link: resupplying any other link is a mismatch
        vm.expectRevert(RulesMismatch.selector);
        vault.previewSwarmBody(s, SWARM_KIND_ESCALATION, _texts(DISPUTER_PROOF));
    }

    function test_NonEmptyLinkStillChecked() public {
        uint256 t = _create(author, address(usdc), 50e6);
        uint256 s = _submit(doer, t);
        vm.expectRevert(BadText.selector);
        _disputeWith(dave, s, DISPUTE_REASON, "ipfs://bad\"quote");
        vm.expectRevert(BadText.selector);
        _disputeWith(dave, s, DISPUTE_REASON, unicode"https://x.com/é");
        bytes memory long = new bytes(513);
        for (uint256 i; i < long.length; ++i) {
            long[i] = "a";
        }
        vm.expectRevert(BadText.selector);
        _disputeWith(dave, s, DISPUTE_REASON, string(long));
        // a valid link still works and reaches the swarm as claim_1_proof
        uint256 g = gasleft();
        _disputeWith(dave, s, DISPUTE_REASON, DISPUTER_PROOF);
        emit log_named_uint("dispute gas, with link (test env)", g - gasleft());
        (bytes memory body,) = vault.previewSwarmBody(s, SWARM_KIND_ESCALATION, _texts(DISPUTER_PROOF));
        assertTrue(_has(body, bytes(string.concat('"claim_1_proof":"', DISPUTER_PROOF, '"'))));
    }

    function test_ReasonStillMandatory() public {
        uint256 t = _create(author, address(usdc), 50e6);
        uint256 s = _submit(doer, t);
        vm.expectRevert(BadText.selector);
        _disputeWith(dave, s, "", "");
        vm.expectRevert(BadText.selector);
        _disputeWith(dave, s, "", DISPUTER_PROOF);
    }
}
