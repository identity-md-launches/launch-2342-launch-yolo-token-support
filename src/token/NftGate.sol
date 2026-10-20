// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title NftGate
/// @notice Who may buy $YOLO in its first 30 minutes after trading opens, and how much: the wallets of a snapshot of
///         identity.md NFT holders, 500,000 YOLO per NFT the wallet held at the snapshot: no
///         registration, a snapshot taken shortly before the token launch.
///         The snapshot writer (the project treasury wallet, which pays launch 1) writes the list in batches with `record`
///         and closes it with `seal`; after `seal` nobody can change it, ever. Each wallet once. The token reads
///         `sealedAt` and opens its window only for a snapshot sealed before trading opens. Moving an NFT after the
///         snapshot changes nothing: the gate never reads the NFT contract.
///         The token decides when the gate applies (it calls `consume` for a buy in its window); the gate has no
///         clock, no owner and nothing to change after the seal. It keeps the use per calling token, so a contract
///         other than $YOLO calling it only ever spends its own books: the gate needs no token address in advance.
///         It never calls back into the token and holds no funds.
contract NftGate {
    /// @notice YOLO one NFT of the snapshot lets its wallet buy in the window (0.05% of the supply)
    uint256 public constant ALLOWANCE_PER_NFT = 500_000e18;

    /// @notice the identity.md NFT whose holders the snapshot lists (for reference: the gate never calls it)
    address public immutable nft;
    /// @notice the only address that may write and seal the snapshot
    address public immutable writer;

    /// @notice NFTs a wallet held at the snapshot (zero: not in the snapshot)
    mapping(address account => uint256) public nftsOf;
    /// @notice what a calling token has let a buyer take so far
    mapping(address token => mapping(address buyer => uint256)) public used;
    /// @notice NFTs in the snapshot, in total
    uint256 public totalNfts;
    /// @notice wallets in the snapshot
    uint256 public walletCount;
    /// @notice running hash of the snapshot as written: keccak256(previous, account, nfts) per wallet, in order
    bytes32 public snapshotHash;
    /// @notice the block the NFT holders were read at (set by `seal`)
    uint256 public snapshotBlock;
    /// @notice when the snapshot was sealed (zero: still open for writing)
    uint256 public sealedAt;

    event Recorded(address indexed account, uint256 nfts);
    event Sealed(uint256 wallets, uint256 nfts, uint256 snapshotBlock, bytes32 snapshotHash);

    error NotWriter();
    error AlreadySealed();
    error NotSealed();
    error BadBatch();
    error ZeroEntry(uint256 index);
    error AlreadyRecorded(address account);
    error EmptySnapshot();

    /// @param nft_ the identity.md NFT
    /// @param writer_ the snapshot writer (the project wallet)
    constructor(address nft_, address writer_) {
        if (writer_ == address(0)) revert NotWriter();
        nft = nft_;
        writer = writer_;
    }

    /// @notice Writes a batch of the snapshot: each wallet with the number of NFTs it held. Writer only, before the
    ///         seal; each wallet once, no zero address, no zero count.
    function record(address[] calldata accounts, uint256[] calldata nfts) external {
        if (msg.sender != writer) revert NotWriter();
        if (sealedAt != 0) revert AlreadySealed();
        uint256 n = accounts.length;
        if (n == 0 || n != nfts.length) revert BadBatch();
        bytes32 h = snapshotHash;
        // slither-disable-next-line uninitialized-local
        uint256 total;
        for (uint256 i; i < n; ++i) {
            address a = accounts[i];
            uint256 c = nfts[i];
            if (a == address(0) || c == 0) revert ZeroEntry(i);
            if (nftsOf[a] != 0) revert AlreadyRecorded(a);
            nftsOf[a] = c;
            total += c;
            h = keccak256(abi.encode(h, a, c));
            emit Recorded(a, c);
        }
        snapshotHash = h;
        totalNfts += total;
        walletCount += n;
    }

    /// @notice Closes the snapshot for good. Writer only, once, not empty. `snapshotBlock_` is the block the NFT
    ///         holders were read at (for anyone checking the list against the chain).
    function seal(uint256 snapshotBlock_) external {
        if (msg.sender != writer) revert NotWriter();
        if (sealedAt != 0) revert AlreadySealed();
        if (walletCount == 0) revert EmptySnapshot();
        sealedAt = block.timestamp;
        snapshotBlock = snapshotBlock_;
        emit Sealed(walletCount, totalNfts, snapshotBlock_, snapshotHash);
    }

    /// @notice A wallet's whole window allowance.
    function allowanceOf(address account) public view returns (uint256) {
        return nftsOf[account] * ALLOWANCE_PER_NFT;
    }

    /// @notice What `buyer` may still take from `token`.
    function left(address token, address buyer) external view returns (uint256) {
        return allowanceOf(buyer) - used[token][buyer];
    }

    /// @notice Called by a token for a buy in its window. Returns the buyer's allowance and what the calling token
    ///         had let him take before; books `amount` only if it fits. The token rejects the buy otherwise. Reverts
    ///         while the snapshot is not sealed.
    // slither-disable-next-line incorrect-equality
    function consume(address buyer, uint256 amount) external returns (uint256 allowance, uint256 usedBefore) {
        if (sealedAt == 0) revert NotSealed();
        allowance = allowanceOf(buyer);
        usedBefore = used[msg.sender][buyer];
        if (amount <= allowance - usedBefore) used[msg.sender][buyer] = usedBefore + amount;
    }
}
