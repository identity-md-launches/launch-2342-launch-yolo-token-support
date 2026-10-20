// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Where the burner may have a credit instead of a transfer (TaskVault.pay credits a failed push).
interface IVaultWithdraw {
    function withdraw(address token) external;
}

/// @dev The dev wallet is the owner of the DevPrices (the same source as TaskVault.cancelTask).
interface IOwned {
    function owner() external view returns (address);
}

/// @title BuybackBurner
/// @notice The burn share of the fee (with a staked doer half of what the stakers' 5% leaves after
///         their bonus, plus the NFT 5% nobody earned) and the $YOLO the treasury would get come here. The contract buys
///         and swaps nothing.
///         - $YOLO: anyone presses "Burn" (`burnYolo`) and all of it goes to 0x…dEaD. It never goes anywhere else.
///         - ETH, USDC, IMD: anyone presses "Send" (`forward`) and all of it goes to the buyback wallet. Nothing else
///           can move them. The buyback wallet is a parameter of the dev wallet (the owner of the DevPrices), changed
///           with one transaction and an event (`setBuybackWallet`); the dev cannot send the money anywhere else.
///         Nobody is paid for calling; uncalled, the money just waits here.
contract BuybackBurner {
    using SafeERC20 for IERC20;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address internal constant ETH = address(0);

    IERC20 public immutable yolo;
    IERC20 public immutable imd;
    IERC20 public immutable usdc;
    /// @notice DevPrices: its owner is the dev wallet, the only one who may change the buyback wallet.
    address public immutable devPrices;

    /// @notice Where `forward` sends ETH, USDC and IMD.
    address public buybackWallet;
    /// @notice Everything `forward` sent to a buyback wallet, per token (ETH = address(0)).
    mapping(address => uint256) public forwarded;

    event Burned(uint256 yoloAmount);
    event Forwarded(address indexed token, address indexed to, uint256 amount);
    event BuybackWalletSet(address indexed wallet);

    error Nothing();
    error NotDev();
    error NotReserve();
    error ZeroAddress();
    error EthSendFailed();

    /// @dev Addresses only (launch rule: a launch's constructorArgs cannot express a struct).
    constructor(address yolo_, address imd_, address usdc_, address devPrices_, address buybackWallet_) {
        if (
            yolo_ == address(0) || imd_ == address(0) || usdc_ == address(0) || devPrices_ == address(0)
                || buybackWallet_ == address(0)
        ) revert ZeroAddress();
        yolo = IERC20(yolo_);
        imd = IERC20(imd_);
        usdc = IERC20(usdc_);
        devPrices = devPrices_;
        buybackWallet = buybackWallet_;
        emit BuybackWalletSet(buybackWallet_);
    }

    receive() external payable {}

    /// @notice The dev wallet: owner of the DevPrices.
    function dev() public view returns (address) {
        return IOwned(devPrices).owner();
    }

    /// @notice The dev wallet changes where `forward` sends (a dev parameter, as the treasury).
    function setBuybackWallet(address wallet) external {
        if (msg.sender != dev()) revert NotDev();
        if (wallet == address(0)) revert ZeroAddress();
        buybackWallet = wallet;
        emit BuybackWalletSet(wallet);
    }

    /// @notice Burn every $YOLO held here (anyone).
    // slither-disable-next-line incorrect-equality
    function burnYolo() external {
        uint256 bal = yolo.balanceOf(address(this));
        if (bal == 0) revert Nothing();
        yolo.safeTransfer(DEAD, bal);
        emit Burned(bal);
    }

    /// @notice Send all of `token` held here (ETH = address(0), USDC or IMD) to the buyback wallet (anyone).
    ///         $YOLO is refused: it only burns.
    // slither-disable-next-line arbitrary-send-eth,incorrect-equality
    function forward(address token) external returns (uint256 amount) {
        if (token != ETH && token != address(usdc) && token != address(imd)) revert NotReserve();
        address to = buybackWallet;
        if (token == ETH) {
            amount = address(this).balance;
            if (amount == 0) revert Nothing();
            forwarded[ETH] += amount;
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert EthSendFailed();
        } else {
            amount = IERC20(token).balanceOf(address(this));
            if (amount == 0) revert Nothing();
            forwarded[token] += amount;
            IERC20(token).safeTransfer(to, amount);
        }
        emit Forwarded(token, to, amount);
    }

    /// @notice What the site shows: ETH, USDC, IMD waiting for "Send" and the $YOLO waiting for "Burn".
    function balances() external view returns (uint256 eth, uint256 usdcBal, uint256 imdBal, uint256 yoloBal) {
        return (
            address(this).balance,
            usdc.balanceOf(address(this)),
            imd.balanceOf(address(this)),
            yolo.balanceOf(address(this))
        );
    }

    /// @notice Take a credit the vault holds for this contract (a push that failed, TaskVault.pay). Anyone.
    function pull(address vault, address token) external {
        IVaultWithdraw(vault).withdraw(token);
    }
}
