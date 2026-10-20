// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title ProjectVesting
/// @notice A $YOLO share on a schedule: of every token it holds, `unlocked` is the beneficiary's at once, the rest
///         streams linearly over `duration` (no cliff) from the moment its clock starts (`startOf`). Only the
///         `starter` starts a clock, by calling `release(token)` while this contract holds some of it: the starter is
///         the YoloSplitter, bound in the launch transaction (`bindStarter`), and it calls `release` right after it
///         pays the vestings, so the $YOLO clocks start at the split and nobody can start one earlier with dust.
///         Before its clock starts only the `unlocked` part is free. It
///         knows no token in advance (`release(token)`, like OpenZeppelin's VestingWallet): it is deployed in a launch
///         of its own before the $YOLO launch, whose `remainderTo` must be a fixed address.
///         Whatever arrives counts, so the stream always covers exactly what was sent; a token the starter never
///         releases has no clock (only its `unlocked` part is free). No owner, no acceleration, the beneficiary
///         can't be changed and nothing can be taken back; anyone may call `release`, which only ever pays the
///         beneficiary what the schedule has opened (0 is fine).
contract ProjectVesting {
    using SafeERC20 for IERC20;

    /// @dev transient slot: 1 from the constructor until the end of the deployment transaction
    bytes32 private constant BINDING_SLOT = keccak256("imd.yolo.vesting.starter");

    address public immutable beneficiary;
    uint256 public immutable unlocked;
    uint64 public immutable duration;
    mapping(address => uint256) public released;
    /// @notice When the linear clock of `token` started (0 = not yet: only `unlocked` is free).
    mapping(address => uint64) public startOf;
    /// @notice The only address whose `release` starts a clock: the YoloSplitter (0 = not bound: no clock starts).
    address public starter;

    event Released(address indexed token, uint256 amount);
    event ClockStarted(address indexed token, uint64 start);
    event StarterBound(address indexed starter);

    error BadSchedule();
    error BindingClosed();

    /// @param beneficiary_ who receives the share
    /// @param unlocked_ of each token, what the beneficiary may take right away (the rest vests)
    /// @param durationSeconds the vested part streams linearly over this long from the token's arrival
    constructor(address beneficiary_, uint256 unlocked_, uint256 durationSeconds) {
        if (beneficiary_ == address(0) || durationSeconds == 0 || durationSeconds > 10 * 365 days) {
            revert BadSchedule();
        }
        beneficiary = beneficiary_;
        unlocked = unlocked_;
        duration = uint64(durationSeconds);
        bytes32 slot = BINDING_SLOT;
        assembly ("memory-safe") {
            tstore(slot, 1)
        }
    }

    /// @notice Makes the caller the `starter`. Works once and only inside the transaction that deployed this
    ///         contract (a transient flag, like Desk.wire): the launch deploys the vestings and then the YoloSplitter,
    ///         whose constructor calls this, in one transaction, so nobody else can bind first or rebind later.
    function bindStarter() external {
        bytes32 slot = BINDING_SLOT;
        uint256 open;
        assembly ("memory-safe") {
            open := tload(slot)
            tstore(slot, 0)
        }
        if (open == 0 || starter != address(0)) revert BindingClosed();
        starter = msg.sender;
        emit StarterBound(msg.sender);
    }

    /// @notice Everything ever received of `token` (held + released) that is the beneficiary's at `time`.
    // slither-disable-next-line incorrect-equality
    function vestedAmount(address token, uint256 time) public view returns (uint256) {
        uint256 total = IERC20(token).balanceOf(address(this)) + released[token];
        uint256 free = total < unlocked ? total : unlocked;
        uint256 start = startOf[token];
        if (start == 0 || time <= start) return free;
        uint256 elapsed = time - start;
        if (elapsed >= duration) return total;
        return free + (total - free) * elapsed / duration;
    }

    function releasable(address token) public view returns (uint256) {
        return vestedAmount(token, block.timestamp) - released[token];
    }

    /// @notice Pay the beneficiary what has vested of `token` and is not yet paid (possibly 0). Called by the
    ///         `starter` while the token is here and its clock has not started, it first starts the clock.
    // slither-disable-next-line incorrect-equality
    function release(address token) external {
        if (msg.sender == starter && startOf[token] == 0 && IERC20(token).balanceOf(address(this)) != 0) {
            startOf[token] = uint64(block.timestamp);
            emit ClockStarted(token, uint64(block.timestamp));
        }
        uint256 amount = releasable(token);
        if (amount != 0) {
            released[token] += amount;
            IERC20(token).safeTransfer(beneficiary, amount);
        }
        emit Released(token, amount);
    }
}
