// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice What the token asks the NFT gate (NftGate, launch 0).
interface INftGate {
    function sealedAt() external view returns (uint256);
    function consume(address buyer, uint256 amount) external returns (uint256 allowance, uint256 usedBefore);
}

/// @title YoloToken ($YOLO)
/// @notice The project token: 1,000,000,000 YOLO minted once to the deployer (the IMD launch factory, which seeds the
///         YOLO/IMD pool and hands out the rest). No owner, no pause, no minting or burning, no list anyone can edit.
///         A buy is a transfer out of the Uniswap v4 PoolManager. Trading opens at `openAt`, a time fixed at
///         deployment: before it nobody buys from the pool (`TradingNotOpen`). From `openAt` buys
///         follow a fixed schedule that ends by itself:
///         - minutes 0-30: only wallets of the NFT gate's snapshot of identity.md NFT holders buy, 500,000 YOLO per
///           NFT in the snapshot for the whole window (`NotWhitelisted` / `NftAllowanceExceeded` otherwise). The
///           snapshot must be sealed before `openAt`; if it is not, nobody buys in minutes 0-30
///           (`SnapshotNotSealed`). If the gate address holds no code (a chain without the gate), there is no
///           whitelist.
///         - minutes 30-60: anyone buys and sells, with a tax on both sides that falls linearly from 30% at minute
///           30 to 0 at minute 60.
///         - from minute 60: a plain ERC-20 for good.
///         A sell is a transfer into the PoolManager. From `openAt` to minute 30 every sell pays 30%.
///         The tax of a buy is taken from what the pool sends; the tax of a sell is taken from the
///         seller's wallet on top of what goes into the pool, so the pool gets exactly what the swap settles and
///         the tax is that share of all the seller parts with: selling 100 YOLO at 30% sends 70 into the pool and
///         30 to the treasury. Taxes are paid in YOLO to the project wallet fixed at deployment. Transfers between
///         wallets are never touched; before `openAt` sells are untaxed. The deployer (the factory: seeding, its
///         fee claims) and the PoolManager itself are exempt.
///         Known limits, accepted: a buy kept as an ERC-6909 claim inside the PoolManager is no transfer until it is
///         taken out (then the rule of that moment applies), and a claim can be sold back into a pool without ever
///         being taken out: a contract can buy any amount before `openAt` or in minutes 0-30 and resell it
///         untaxed, or take it out after minute 60 untaxed, so the gate, the opening time and the taxes bind only
///         buyers who take the token out and sellers who bring it in inside their window; in minutes
///         0-30 a route whose output goes to a router first is refused, since the router is not in the snapshot
///         (the Universal Router's TAKE_ALL pays the buyer directly). Adding liquidity from a wallet is a transfer
///         into the PoolManager and pays the sell tax like a sell.
contract YoloToken is ERC20 {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;
    uint256 public constant WHITELIST_SECONDS = 30 minutes;
    uint256 public constant TAX_END_SECONDS = 60 minutes;
    /// @notice the tax at minute 30 (both sides) and of every sell in minutes 0-30, in basis points; it reaches 0
    ///         at minute 60
    uint256 public constant TAX_START_BPS = 3_000;
    /// @notice the latest `openAt` a deployment may set, counted from the deployment
    uint256 public constant MAX_OPEN_DELAY = 30 days;

    address public immutable poolManager;
    /// @notice the deployer (the launch factory): never gated or taxed
    address public immutable launcher;
    /// @notice NftGate of launch 0 (the snapshot); no code there = no whitelist
    address public immutable gate;
    /// @notice the project wallet (the treasury): receives the buy and sell tax
    address public immutable taxRecipient;
    /// @notice when trading opens (fixed at deployment): no buy before it; the window and the tax count from it
    uint256 public immutable openAt;

    error TradingNotOpen(uint256 openAt);
    error SnapshotNotSealed();
    error BadOpenAt(uint256 openAt);
    error NotWhitelisted(address buyer);
    error NftAllowanceExceeded(address buyer, uint256 left, uint256 wanted);
    error ZeroAddress();

    /// @param poolManager_ the Uniswap v4 PoolManager (every v4 buy is a transfer from it)
    /// @param gate_ NftGate (launch 0)
    /// @param taxRecipient_ the project wallet (the treasury)
    /// @param openAt_ when trading opens (unix seconds): not before the deployment, at most MAX_OPEN_DELAY after it
    constructor(address poolManager_, address gate_, address taxRecipient_, uint256 openAt_) ERC20("YOLO", "YOLO") {
        if (poolManager_ == address(0) || taxRecipient_ == address(0)) revert ZeroAddress();
        if (openAt_ < block.timestamp || openAt_ > block.timestamp + MAX_OPEN_DELAY) revert BadOpenAt(openAt_);
        poolManager = poolManager_;
        launcher = msg.sender;
        gate = gate_;
        taxRecipient = taxRecipient_;
        openAt = openAt_;
        _mint(msg.sender, TOTAL_SUPPLY);
    }

    /// @notice Whether buys from the pool are open (from `openAt` on).
    function tradingOpen() public view returns (bool) {
        return block.timestamp >= openAt;
    }

    /// @notice The buy tax now, in basis points (0 outside minutes 30-60 after `openAt`).
    function buyTaxBps() public view returns (uint256) {
        if (block.timestamp < openAt) return 0;
        uint256 e = block.timestamp - openAt;
        if (e < WHITELIST_SECONDS) return 0;
        return _taxNum(e) / (TAX_END_SECONDS - WHITELIST_SECONDS);
    }

    /// @notice The sell tax now, in basis points of all the seller parts with (30% in minutes 0-30 after `openAt`,
    ///         then down to 0 at minute 60; 0 before `openAt`).
    function sellTaxBps() public view returns (uint256) {
        if (block.timestamp < openAt) return 0;
        return _taxNum(block.timestamp - openAt) / (TAX_END_SECONDS - WHITELIST_SECONDS);
    }

    /// @notice The sell tax now, in YOLO, of a sell that puts `intoPool` into the pool (taken on top of it).
    function sellTax(uint256 intoPool) public view returns (uint256) {
        if (block.timestamp < openAt) return 0;
        return _sellTax(intoPool, _taxNum(block.timestamp - openAt));
    }

    /// @dev the tax `e` seconds after `openAt`, in basis points x 30 minutes: 30% until minute 30, then linear to 0
    function _taxNum(uint256 e) internal pure returns (uint256) {
        if (e < WHITELIST_SECONDS) return TAX_START_BPS * (TAX_END_SECONDS - WHITELIST_SECONDS);
        if (e < TAX_END_SECONDS) return TAX_START_BPS * (TAX_END_SECONDS - e);
        return 0;
    }

    /// @dev on top of `value`, so that the tax is `num` of value + tax, rounded down
    // slither-disable-next-line incorrect-equality
    function _sellTax(uint256 value, uint256 num) internal pure returns (uint256) {
        if (num == 0) return 0;
        return value * num / (10_000 * (TAX_END_SECONDS - WHITELIST_SECONDS) - num);
    }

    /// @notice Whether buys are for the snapshot's wallets only right now (minutes 0-30 after `openAt`).
    function whitelistActive() public view returns (bool) {
        return block.timestamp >= openAt && block.timestamp - openAt < WHITELIST_SECONDS && gate.code.length != 0;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (value != 0 && from != launcher && block.timestamp >= openAt) {
            if (to == poolManager && from != poolManager) {
                // a sell: the pool gets `value` (what the swap settles), the tax comes on top from the seller
                uint256 tax = _sellTax(value, _taxNum(block.timestamp - openAt));
                if (tax != 0) super._update(from, taxRecipient, tax);
            }
        }
        if (from == poolManager && value != 0 && to != poolManager && to != launcher) {
            if (block.timestamp < openAt) revert TradingNotOpen(openAt);
            uint256 e = block.timestamp - openAt;
            if (e < WHITELIST_SECONDS) {
                if (gate.code.length != 0) {
                    // the snapshot counts only if it was sealed before trading opened
                    uint256 sealedAt = INftGate(gate).sealedAt();
                    if (sealedAt == 0 || sealedAt >= openAt) revert SnapshotNotSealed();
                    (uint256 allowance, uint256 usedBefore) = INftGate(gate).consume(to, value);
                    if (allowance == 0) revert NotWhitelisted(to);
                    if (value > allowance - usedBefore) {
                        revert NftAllowanceExceeded(to, allowance - usedBefore, value);
                    }
                }
            } else if (e < TAX_END_SECONDS) {
                // value x 30% x (60 min - e) / 30 min, rounded down
                uint256 tax = value * _taxNum(e) / (10_000 * (TAX_END_SECONDS - WHITELIST_SECONDS));
                if (tax != 0) {
                    super._update(from, taxRecipient, tax);
                    value -= tax;
                }
            }
        }
        super._update(from, to, value);
    }
}
