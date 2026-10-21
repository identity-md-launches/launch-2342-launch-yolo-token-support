// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./Base.t.sol";

/// @dev Steady-state gas of the main functions (warm-ish storage like on mainnet after the first task). Printed with
///      -vv; numbers are also asserted against loose ceilings (vault + two desks, parameters read from the
///      registry per call). createTask reads no price (no USD lookup, no DevPrices call): cheaper than
///      its 450k ceiling, a loose upper bound.
/// forge-config: default.isolate = false
contract GasTest is Base {
    function setUp() public override {
        super.setUp();
        _create(author, address(usdc), 50e6); // the first task of the version: warms the registry and the desks
    }

    uint256 internal g0;

    function _start() internal {
        g0 = gasleft();
    }

    /// @dev Gas between _start and here, minus the test's own overhead of ~3k (SLOAD/SSTORE of g0 + prank).
    function _measure(string memory name) internal returns (uint256 g) {
        g = g0 - gasleft();
        emit log_named_uint(name, g);
    }

    function test_GasProfile() public {
        _start();
        uint256 t = _create(author, address(usdc), 100e6);
        // three rule texts stored (the test task: 21 + 44 + 14 B)
        assertLt(_measure("createTask (USDC, mode B)"), 500_000);

        _start();
        _create(author, ETH, 0.05 ether);
        _measure("createTask (ETH)");

        _start();
        _topUp(alice, t, 10e6);
        _measure("topUp (idle task)");

        _start();
        uint256 s = _submit(doer, t);
        assertLt(_measure("submit (small task, mode B)"), 500_000);

        _start();
        _topUp(bob, t, 10e6);
        _measure("topUp (pending, during submission)");

        _start();
        _dispute(dave, s);
        _measure("dispute (starts the vote)");
        // One dispute, one disputer - a second dispute() on the same submission
        // reverts; there is no "second disputer" gas profile.

        // There is no "doer answers the dispute" step - the doer's "why honest" text
        // is attached at submission (Evidence.note), there is no separate reply() gas profile.

        // votes by NFT ids: every wallet here votes all its NFTs. The accept votes go first so the running
        // margin stays under instantDelta (20): 5 -> 7 -> 13 (reject), decided at the vote end (endDelta 10).
        vm.prank(voters[3]);
        vault.vote(s, 1, voters[3], held[voters[3]]);
        _start();
        vm.prank(voters[4]);
        vault.vote(s, 1, voters[4], held[voters[4]]);
        _measure("vote (2 NFTs, not the first vote)");
        _start();
        vm.prank(voters[1]); // the holder sends their own vote
        vault.vote(s, 2, voters[1], held[voters[1]]);
        _measure("vote (20 NFTs, not the first vote)");

        _warp(24 hours);
        _start();
        vault.poke(t);
        _measure("poke (vote end -> decided)");

        _start();
        _appeal(doer, s);
        _measure("appeal");

        _warp(1 hours); // asked inside swarmTimeout (6 h): a later ask finds the appeal void
        _start();
        _askAppealSwarm(s); // lazy ask
        _measure("askAppealSwarm (asks the filed appeal; builds body, pays Intake)");

        OracleAttestation.Attestation memory a = _attestation(false);
        bytes memory sig = _sign(a, attesterKey);
        intake.complete(_sub(s).request, 0, a, sig);
        emit log_named_uint("onOracleResult (inside the 200k callback budget)", intake.lastCallbackGasUsed());

        _start();
        vault.poke(t);
        _measure("poke (final settlement, rejected)");

        _start();
        vm.prank(dave);
        vault.claimDisputer(s);
        _measure("claimDisputer (bond + share + ETH)");

        _start();
        vault.claimVoterReward(s, voters[1]);
        _measure("claimVoterReward (bond share)");

        // next submission on the same task: accepted without dispute
        uint256 s2 = _submit(doer2, t);
        _warp(24 hours);
        _start();
        vault.poke(t);
        _measure("poke (accept + fee split)");
        assertEq(uint8(_sub(s2).outcome), uint8(Outcome.Accepted));

        _start();
        vm.prank(doer2);
        vault.withdraw(address(imd));
        _measure("withdraw (IMD credit)");

        // the reward is locked until the deadline: a contributor takes their share back after expiry
        uint256 t4 = _createWithDeadline(author, address(usdc), 100e6, uint64(_now() + 1 days));
        _topUp(bob, t4, 10e6);
        _warp(1 days);
        _start();
        vm.prank(bob);
        vault.withdrawContribution(t4);
        _measure("withdrawContribution (expires the task on the way)");

        // NFT undecided: a paid call to the swarm
        uint256 t3 = _create(author, address(usdc), 100e6);
        uint256 s3 = _submit(doer3, t3);
        _dispute(dave, s3);
        _warp(24 hours);
        vault.poke(t3);
        _start();
        _callSwarm(erin, s3);
        _measure("callSwarm (no NFT decision: bond + fee, builds body, pays Intake)");
        _silent(s3);
        _warp(6 hours);
        _start();
        vault.poke(t3);
        _measure("poke (swarm silent -> back to the undecided window)");

        // a $500 task: no mandatory swarm check, the submission costs what a small one does
        uint256 tl = _create(author, address(usdc), 500e6);
        _start();
        _submit(doer, tl);
        assertLt(_measure("submit ($500 task, no Intake request)"), 500_000);
    }

    /// @dev Submit with and without the doer's evidence from the same state (snapshot): the difference is the cost
    ///      of the screenshot link and the note alone.
    function test_GasSubmitEvidence() public {
        bytes memory note = new bytes(MAX_NOTE_BYTES);
        for (uint256 i; i < note.length; ++i) {
            note[i] = "n";
        }
        Evidence[4] memory variants = [
            _noEvidence(),
            Evidence("https://i.imgur.com/screenshot.png", ""),
            Evidence("", "Reply is the 3rd one under the post"),
            Evidence("https://i.imgur.com/screenshot.png", string(note))
        ];
        string[4] memory names = [
            "submit, proof link only",
            "submit, + screenshot",
            "submit, + 35-byte note",
            "submit, + screenshot + 200-byte note"
        ];
        uint256[2] memory amounts = [uint256(100e6), 500e6]; // $100 and $500: the same path (no mandatory check)
        for (uint256 a; a < 2; ++a) {
            uint256 t = _create(author, address(usdc), amounts[a]);
            uint256 base;
            for (uint256 v; v < 4; ++v) {
                uint256 snap = vm.snapshotState();
                _start();
                vm.prank(doer);
                vault.submit(t, "https://x.com/doer/status/1", variants[v], 0, type(uint256).max, _noSwap());
                uint256 g = _measure(string.concat(a == 0 ? "$100 task: " : "$500 task: ", names[v]));
                if (v == 0) base = g;
                else emit log_named_uint("  extra gas", g - base);
                vm.revertToState(snap);
            }
        }
    }
}
