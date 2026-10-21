// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {console} from "forge-std/console.sol";
import {Base} from "../Base.t.sol";
import "../../src/VaultTypes.sol";

/// @dev The call to the Intake in TaskVault.ask (reached from CaseDesk._ask) is wrapped in try/catch; a failure
///      with less than ASK_GAS_RESERVE (150,000) gas left reverts the whole transaction (InsufficientGas).
///      Hypothesis: a transaction with gas set tight pushes the Intake into OOG, the catch branch fires, and the
///      question to the swarm is skipped / the appeal is voided. Sweeping the gas limit in steps of 2000 finds no
///      such limit: every starved call reverts. These tests confirm it with a mock Intake.
/// forge-config: default.isolate = false
contract ReviewGasGrief is Base {
    uint8 constant REJECT = 2;

    /// The same trick on a paid swarm call made before an NFT decision: a call with gas set tight cannot go
    /// through in a way that skips sending the question to Intake (the bond and fee are taken, but the swarm is
    /// never asked).
    function test_CallSwarmWithTightGas_CannotSkipTheQuestion() public {
        uint256 t = _create(author, address(usdc), 1_000e6);
        uint256 s = _submit(doer, t);
        _dispute(dave, s);
        _warp(24 hours);
        vault.poke(t); // NoDecision
        uint256 found;
        for (uint256 g = 200_000; g < 1_500_000; g += 2_000) {
            uint256 snap = vm.snapshotState();
            uint256 asked = intake.nonce();
            vm.prank(erin);
            try vault.callSwarm{gas: g}(s, false, type(uint256).max, _noSwap(), _genericRuleTexts()) {
                if (_phase(s) != Phase.Asked || intake.nonce() != asked + 1 || _sub(s).request == bytes32(0)) {
                    found = g;
                    break;
                }
                vm.revertToState(snap);
                break; // went through normally, with the question sent to the swarm: more gas isn't needed
            } catch {
                vm.revertToState(snap);
            }
        }
        console.log("callSwarm gas that skips the question:", found);
        assertEq(found, 0, "a gas limit skips the question");
    }

    /// A side that won against the NFT voids someone else's appeal with a cheap ask call with gas set tight.
    /// The ask call is lazy and permissionless - it lives in a separate function, `askAppealSwarm`, because
    /// poke/step does not carry text for a re-ask. This test sweeps gas on that function (a
    /// gas-griefing check).
    function test_PokeWithTightGas_CannotVoidAppeal() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        _dispute(dave, s);
        _vote(s, 0, REJECT, 0, 100); // NFT: reject
        _endVote(s); // decided at the end of voting
        _appeal(doer, s);
        _warp(1 hours); // inside swarmTimeout (6 h); the question is asked by the first askAppealSwarm call
        RuleTexts memory rt = _genericRuleTexts();
        uint256 found;
        for (uint256 g = 100_000; g < 2_000_000; g += 2_000) {
            uint256 snap = vm.snapshotState();
            vm.prank(dave);
            try vault.askAppealSwarm{gas: g}(s, rt) {
                if (_phase(s) == Phase.Decided) {
                    found = g;
                    break;
                }
                vm.revertToState(snap);
                break;
            } catch {
                vm.revertToState(snap);
            }
        }
        console.log("askAppealSwarm gas that voids the appeal:", found);
        assertEq(found, 0, "a gas limit voids the appeal");
    }
}
