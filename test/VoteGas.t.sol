// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./Base.t.sol";

/// @dev Gas of an NFT vote by ids and of the voter's claim. Two figures
///      per step: `exec` = gasleft() around the call inside the test (storage touched earlier in the test is warm),
///      `tx` = vm.lastCallGas().gasTotalUsed. Run with --isolate for `tx` to be a separate transaction (cold storage,
///      21k base and calldata included), as on mainnet. The 25- and 100-NFT votes cross instantDelta (20) and so
///      include the instant decision; `*_noDecide` raise instantDelta to show the vote alone.
/// forge-config: default.isolate = false
contract VoteGasTest is Base {
    uint8 internal constant ACCEPT = 1;
    uint8 internal constant REJECT = 2;

    uint256 internal t;
    uint256 internal s;
    address internal w1;
    address internal w10;
    address internal w15;
    address internal w25;
    address internal w100;

    function setUp() public override {
        super.setUp();
        _create(author, address(usdc), 50e6); // warms the registry and the desks, as on a live chain
        w1 = _holder("w1", 1);
        w10 = _holder("w10", 10);
        w15 = _holder("w15", 15);
        w25 = _holder("w25", 25);
        w100 = _holder("w100", 100);
        t = _create(author, address(usdc), 100e6);
        s = _submit(doer, t);
        _dispute(dave, s);
    }

    function _log(string memory name, uint256 exec) internal {
        emit log_named_uint(string.concat(name, " exec"), exec);
        emit log_named_uint(string.concat(name, " tx"), vm.lastCallGas().gasTotalUsed);
    }

    function _send(address w, uint8 side, string memory name) internal {
        uint256[] memory ids = held[w];
        vm.prank(w);
        uint256 g = gasleft();
        vault.vote(s, side, w, ids);
        _log(name, g - gasleft());
    }

    function _noInstant() internal {
        Params memory p = defaultParams();
        p.instantDelta = 2_000;
        vm.prank(multisig);
        registry.proposeParams(p);
        _warp(48 hours);
        registry.activateParams();
        t = _create(author, address(usdc), 100e6);
        s = _submit(doer, t);
        _dispute(dave, s);
    }

    /// @dev The votes of a small dispute: the first and later votes of wallets with 1, 10 and 15 NFTs (margin stays
    ///      < instantDelta 20 until the vote end).
    function test_VoteGas_Profile() public {
        _send(w1, ACCEPT, "vote 1 NFT (first vote)");
        _send(w10, REJECT, "vote 10 NFT (later vote)");
        _send(w15, ACCEPT, "vote 15 NFT (later vote)");
        _send(voters[4], REJECT, "vote 2 NFT (later vote)");
    }

    function test_VoteGas_First1() public {
        _send(w1, ACCEPT, "vote 1 NFT (first vote)");
    }

    function test_VoteGas_First25() public {
        _send(w25, ACCEPT, "vote 25 NFT (first vote, decides)");
    }

    function test_VoteGas_First100() public {
        _send(w100, ACCEPT, "vote 100 NFT (first vote, decides)");
    }

    function test_VoteGas_First25_noDecide() public {
        _noInstant();
        _send(w25, ACCEPT, "vote 25 NFT (first vote, no decision)");
    }

    function test_VoteGas_First100_noDecide() public {
        _noInstant();
        _send(w100, ACCEPT, "vote 100 NFT (first vote, no decision)");
    }

    /// @dev A delegate.xyz hot wallet votes 25 NFTs of its cold wallet (one more registry read per id).
    function test_VoteGas_Delegate25_noDecide() public {
        _noInstant();
        address hot = makeAddr("hot");
        vm.prank(w25);
        delegates.delegateAll(hot, true);
        uint256[] memory ids = held[w25];
        vm.prank(hot);
        uint256 g = gasleft();
        vault.vote(s, ACCEPT, hot, ids);
        _log("vote 25 NFT as delegate (first vote, no decision)", g - gasleft());
    }

    /// @dev claimVoterReward after the NFT decided right (accepted after a dispute: fee share + bond share).
    function test_VoteGas_Claim() public {
        _vote(s, 1, ACCEPT, 120, 20); // decides at once (instantDelta)
        _warp(48 hours);
        vault.poke(t);
        uint256 g = gasleft();
        vault.claimVoterReward(s, voters[1]);
        _log("claimVoterReward", g - gasleft());
    }

    /// @dev claimVoterRewards over 1, 4 and 5 accepted submissions of one voter.
    function test_VoteGas_ClaimBatch() public {
        uint256[] memory subs = new uint256[](10);
        subs[0] = s;
        _vote(s, 1, ACCEPT, 120, 20);
        for (uint256 i = 1; i < 10; ++i) {
            uint256 ti = _create(author, address(usdc), 100e6);
            subs[i] = _submit(doer, ti);
            _dispute(dave, subs[i]);
            _vote(subs[i], 1, ACCEPT, 120, 20);
        }
        _warp(48 hours);
        for (uint256 i; i < 10; ++i) {
            vault.poke(_sub(subs[i]).taskId);
        }
        uint256[] memory one = new uint256[](1);
        one[0] = subs[0];
        uint256 g = gasleft();
        vault.claimVoterRewards(one, voters[1]);
        _log("claimVoterRewards x1", g - gasleft());
        uint256[] memory four = new uint256[](4);
        for (uint256 i; i < 4; ++i) {
            four[i] = subs[1 + i];
        }
        g = gasleft();
        vault.claimVoterRewards(four, voters[1]);
        _log("claimVoterRewards x4", g - gasleft());
        uint256[] memory five = new uint256[](5);
        for (uint256 i; i < 5; ++i) {
            five[i] = subs[5 + i];
        }
        g = gasleft();
        vault.claimVoterRewards(five, voters[1]);
        _log("claimVoterRewards x5", g - gasleft());
    }
}
