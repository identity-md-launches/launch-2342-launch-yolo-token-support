// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title YoloLockHub: the doer stake, a $YOLO lock for a term
/// @notice A doer locks an amount of
///         $YOLO for 1 to 52 weeks. The lock's power = amount x term in weeks / 52 is fixed when the lock is set and
///         does not change until its end unless the lock is changed: setting a term again (extending) recomputes it
///         from the whole amount and the weeks actually left, `amount x weeks left / 52`; adding without a new term
///         adds `added x weeks left / 52` to the power. The bonus itself is not computed here:
///         the CaseDesk reads `powerAt` at a submission and compares it with the task's whole reward at the submission
///         in $YOLO plus the task's $YOLO add-on (4% x min(1, power / (reward + add-on))); the DisputeDesk checks `stakePower` at the payout (the same lock still running, never withdrawn
///         in between: a lock's `epoch` grows at every withdrawal). This contract pays nothing itself.
///
///         `lock(add, weeks)` adds to the amount and/or sets the end to `weeks` from now (1..52); the end cannot move
///         earlier, the amount only grow; a lock that ended may be locked again. `withdraw` takes the whole amount once
///         the lock ended. Every change is checkpointed, so the power at any past moment can be read back. No owner,
///         no admin. Constructor takes $YOLO directly: deployed first in launch 2.
contract YoloLockHub {
    using SafeERC20 for IERC20;

    uint256 public constant WEEK = 7 days;
    uint256 public constant MAX_WEEKS = 52;
    uint256 public constant MAX_LOCK = MAX_WEEKS * WEEK;

    IERC20 public immutable yolo;

    struct Lock {
        uint96 amount; // the whole $YOLO supply (1e27) fits
        uint64 end;
        uint32 epoch; // +1 at every withdrawal: a new lock after it is another lock
    }

    /// @dev A lock as it stood from `at` on (until the next point).
    struct Point {
        uint64 at;
        uint64 end;
        uint96 power;
        uint32 epoch;
    }

    mapping(address => Lock) public locks;
    // slither-disable-next-line uninitialized-state
    mapping(address => Point[]) internal _history;

    event Locked(address indexed who, uint256 added, uint256 amount, uint64 end, uint256 power);
    event Withdrawn(address indexed who, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error BadTerm();
    error LockRunning(uint64 end);

    constructor(address yolo_) {
        if (yolo_ == address(0)) revert ZeroAddress();
        yolo = IERC20(yolo_);
    }

    /// @notice Add `add` $YOLO (pulled with transferFrom) and, if `weeks_` is not 0, set the end to `weeks_` weeks from
    ///         now (1..52, never earlier than the current end). A lock that is not running needs a term.
    ///         With a term the power becomes the whole amount x weeks left / 52; without one (add only) it grows by
    ///         added x weeks left / 52.
    // slither-disable-next-line divide-before-multiply,incorrect-equality
    function lock(uint256 add, uint256 weeks_) external {
        Lock memory l = locks[msg.sender];
        if (l.end != 0 && l.end <= block.timestamp) ++l.epoch; // an ended lock set again is a new lock: no stake bonus
        uint256 end = l.end;
        // power of the running lock (0 once it ended: a lock set again starts afresh)
        uint256 old = end > block.timestamp ? _last(msg.sender).power : 0;
        if (weeks_ != 0) {
            if (weeks_ > MAX_WEEKS) revert BadTerm();
            uint256 newEnd = block.timestamp + weeks_ * WEEK;
            if (newEnd < end) revert BadTerm();
            end = newEnd;
        } else if (add == 0) {
            revert ZeroAmount();
        }
        if (end <= block.timestamp) revert BadTerm(); // adding to a lock that ended needs a new term
        uint256 amount = l.amount + add;
        if (amount == 0) revert ZeroAmount();
        if (amount > type(uint96).max) revert BadTerm();
        uint256 left = (end - block.timestamp + WEEK - 1) / WEEK; // whole weeks, rounded up
        // a new term: the whole amount with the weeks left; an add only: the running power plus the added tokens
        uint256 pw = weeks_ != 0 ? amount * left / MAX_WEEKS : old + add * left / MAX_WEEKS;
        locks[msg.sender] = Lock(uint96(amount), uint64(end), l.epoch);
        _checkpoint(msg.sender, uint96(pw), uint64(end), l.epoch);
        if (add != 0) yolo.safeTransferFrom(msg.sender, address(this), add);
        emit Locked(msg.sender, add, amount, uint64(end), pw);
    }

    /// @notice Take the whole amount back once the lock ended.
    // slither-disable-next-line incorrect-equality
    function withdraw() external {
        Lock memory l = locks[msg.sender];
        if (l.amount == 0) revert ZeroAmount();
        if (block.timestamp < l.end) revert LockRunning(l.end);
        locks[msg.sender] = Lock(0, 0, l.epoch + 1);
        _checkpoint(msg.sender, 0, 0, l.epoch + 1);
        yolo.safeTransfer(msg.sender, l.amount);
        emit Withdrawn(msg.sender, l.amount);
    }

    /// @notice Power of `who` at `t`, from the lock as it stood strictly before `t` (0 if that lock ended by `t`).
    function powerAt(address who, uint256 t) public view returns (uint256) {
        Point memory p = _pointBefore(who, t);
        return p.end > t ? p.power : 0;
    }

    /// @notice The power a submission made at `since` keeps at the payout: `powerAt(who, since)` if the lock it came
    ///         from was never withdrawn since (same epoch) and is running now, else 0.
    function stakePower(address who, uint64 since) external view returns (uint256) {
        Point memory p = _pointBefore(who, since);
        Lock memory l = locks[who];
        if (p.epoch != l.epoch || l.end <= block.timestamp || p.end <= since) return 0;
        return p.power;
    }

    /// @notice The current power of `who` (for the site).
    function power(address who) external view returns (uint256) {
        return powerAt(who, block.timestamp + 1);
    }

    /// @dev The last point strictly before `t` (zeros if none).
    function _pointBefore(address who, uint256 t) private view returns (Point memory p) {
        Point[] storage h = _history[who];
        // slither-disable-next-line uninitialized-local
        uint256 lo;
        uint256 hi = h.length;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (h[mid].at < t) lo = mid + 1;
            else hi = mid;
        }
        if (lo != 0) p = h[lo - 1];
    }

    function _last(address who) private view returns (Point memory p) {
        Point[] storage h = _history[who];
        if (h.length != 0) p = h[h.length - 1];
    }

    // slither-disable-next-line incorrect-equality
    function _checkpoint(address who, uint96 pw, uint64 end, uint32 epoch) private {
        Point[] storage h = _history[who];
        uint256 n = h.length;
        if (n != 0 && h[n - 1].at == block.timestamp) {
            h[n - 1] = Point(uint64(block.timestamp), end, pw, epoch);
        } else {
            h.push(Point(uint64(block.timestamp), end, pw, epoch));
        }
    }
}
