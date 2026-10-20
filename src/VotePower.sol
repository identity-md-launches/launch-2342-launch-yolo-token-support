// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IDelegateRegistry} from "./interfaces/IDelegateRegistry.sol";

interface IERC721OwnerOf {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @title VotePower
/// @notice Who may vote with an identity.md NFT now: a vote by NFT id, with no registration. The contract remembers,
///         per dispute, that an NFT id already voted so it cannot vote twice in the same dispute:
///         its owner, or a delegate.xyz delegate of its owner (the whole wallet, this NFT contract or this token id).
///         No registration, no snapshot: the DisputeDesk asks at the vote and remembers the voted ids per dispute.
///         Holds no funds and no state, has no owner and nothing to change.
contract VotePower {
    IERC721OwnerOf public immutable nft;
    /// @notice delegate.xyz v2; address(0): only the owner itself votes
    IDelegateRegistry public immutable delegateRegistry;

    constructor(address nft_, address delegateRegistry_) {
        nft = IERC721OwnerOf(nft_);
        delegateRegistry = IDelegateRegistry(delegateRegistry_);
    }

    /// @notice The first of `tokenIds` that `who` may not vote with now, as index + 1; 0: they may vote with all.
    function firstNotHeld(address who, uint256[] calldata tokenIds) external view returns (uint256) {
        for (uint256 i; i < tokenIds.length; ++i) {
            if (!mayVote(who, tokenIds[i])) return i + 1;
        }
        return 0;
    }

    /// @notice `who` owns `id` now or is a delegate.xyz delegate of its owner. Never reverts.
    function mayVote(address who, uint256 id) public view returns (bool) {
        // slither-disable-next-line uninitialized-local
        address owner;
        try nft.ownerOf(id) returns (address o) {
            owner = o;
        } catch {
            return false;
        }
        if (owner == address(0)) return false;
        if (owner == who) return true;
        if (address(delegateRegistry) == address(0)) return false;
        try delegateRegistry.checkDelegateForERC721(who, owner, address(nft), id, bytes32(0)) returns (bool ok) {
            return ok;
        } catch {
            return false;
        }
    }
}
