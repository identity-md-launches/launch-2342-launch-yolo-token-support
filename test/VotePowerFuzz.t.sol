// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./Base.t.sol";

/// @dev Fuzz of the NFT vote by ids: no registration needed; the contract remembers that an NFT cannot vote
///      twice in the same dispute, and with only 2000 NFTs total, vote counts can never exceed 2000. A random
///      sequence of NFT transfers (also into an escrow), delegations, dispute openings and
/// votes with random id lists runs against a model kept here. After every step:
/// - a vote passes exactly when the side is 1/2, the wallet has no other side, every id is held by the voter now
/// (owner or delegate) and none voted in this dispute (nor repeats in the list); then it counts the ids;
/// - per dispute, the votes equal the ids marked voted, never more than the NFTs in existence.
/// forge-config: default.isolate = false
contract VotePowerFuzzTest is Base {
    uint256 internal constant N = 24; // NFTs of the fuzz: ids FIRST..FIRST+N-1
    uint256 internal constant FIRST = 50_000;
    uint256 internal constant W = 5; // wallets
    uint256 internal constant MAX_DISPUTES = 8;

    address[W] internal w;
    address internal escrow;
    mapping(uint256 => mapping(uint256 => bool)) internal counted; // dispute => id => voted
    mapping(uint256 => mapping(address => uint8)) internal sideOfModel;
    mapping(uint256 => uint256) internal votesModel;
    uint256[] internal subs;
    uint256 internal votesOk;
    uint256 internal votesRefused;

    function setUp() public override {
        super.setUp();
        for (uint256 i; i < W; ++i) {
            w[i] = makeAddr(string.concat("fw", vm.toString(i)));
        }
        escrow = makeAddr("escrow");
        for (uint256 i; i < N; ++i) {
            nft.mint(w[i % W], FIRST + i);
        }
        // w4 lets w3 vote for it (delegate.xyz, the whole wallet)
        vm.prank(w[4]);
        delegates.delegateAll(w[3], true);
        // no instant decision: every vote of the sequence can land
        Params memory p = defaultParams();
        p.instantDelta = 2_000;
        vm.prank(multisig);
        registry.proposeParams(p);
        _warp(48 hours);
        registry.activateParams();
    }

    function _mayVote(address who, uint256 id) internal view returns (bool) {
        address o = nft.ownerOf(id);
        return o == who || (who == w[3] && o == w[4]);
    }

    function _step(uint256 r) internal {
        uint256 kind = r % 4;
        r >>= 8;
        if (kind == 0) {
            // transfer an NFT to another wallet or the escrow
            uint256 id = FIRST + r % N;
            address from = nft.ownerOf(id);
            address to = (r >> 8) % (W + 1) == W ? escrow : w[(r >> 8) % W];
            if (from == escrow || to == from) return;
            vm.prank(from);
            nft.transferFrom(from, to, id);
        } else if (kind == 1 && subs.length < MAX_DISPUTES) {
            uint256 t = _create(author, address(usdc), 100e6);
            uint256 s = _submit(doer, t);
            _dispute(dave, s);
            subs.push(s);
        } else if (subs.length != 0) {
            uint256 s = subs[r % subs.length];
            address v = w[(r >> 8) % W];
            uint8 side = uint8(1 + (r >> 16) % 2);
            uint256 len = 1 + (r >> 24) % 4;
            uint256[] memory ids = new uint256[](len);
            bool ok = sideOfModel[s][v] == 0 || sideOfModel[s][v] == side;
            for (uint256 i; i < len; ++i) {
                ids[i] = FIRST + (r >> (32 + i * 8)) % N;
                if (!_mayVote(v, ids[i]) || counted[s][ids[i]]) ok = false;
                for (uint256 j; j < i; ++j) {
                    if (ids[j] == ids[i]) ok = false;
                }
            }
            if (_phase(s) != Phase.Voting || block.timestamp >= _sub(s).voteEnd) ok = false;
            vm.prank(v);
            (bool success,) = address(vault).call(abi.encodeCall(ITaskVault.vote, (s, side, v, ids)));
            assertEq(success, ok, "vote passes exactly by the model");
            if (success) {
                for (uint256 i; i < len; ++i) {
                    counted[s][ids[i]] = true;
                }
                sideOfModel[s][v] = side;
                votesModel[s] += len;
                ++votesOk;
            } else {
                ++votesRefused;
            }
        }
        for (uint256 i; i < subs.length; ++i) {
            Dispute memory d = vault.getDispute(subs[i]);
            assertEq(uint256(d.votesAccept) + d.votesReject, votesModel[subs[i]], "votes = ids voted");
            assertLe(uint256(d.votesAccept) + d.votesReject, N, "never more votes than NFTs");
            for (uint256 id = FIRST; id < FIRST + N; ++id) {
                assertEq(vault.tokenVoted(subs[i], id), counted[subs[i]][id]);
            }
        }
    }

    function testFuzz_OneVotePerNft(uint256 seed) public {
        for (uint256 i; i < 40; ++i) {
            _step(uint256(keccak256(abi.encode(seed, i))));
        }
    }

    function test_OneVotePerNft_Fixed() public {
        for (uint256 i; i < 120; ++i) {
            _step(uint256(keccak256(abi.encode("fixed", i))));
        }
        assertGt(votesOk, 5);
        assertGt(votesRefused, 5);
    }
}
