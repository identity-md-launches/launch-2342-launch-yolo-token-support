// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TaskStatus, Task, Submission} from "./VaultTypes.sol";

/// @dev The vault views the market reads (the same narrow pattern YoloSweetener uses).
interface IPredictVault {
    function poke(uint256 taskId) external;
    function getTask(uint256 taskId) external view returns (Task memory);
    function getSubmission(uint256 subId) external view returns (Submission memory);
    function registry() external view returns (address);
    function yolo() external view returns (IERC20);
}

/// @title YoloPredict: WILL DO / WON'T DO on "this task gets done by its deadline", in $YOLO only
/// @notice Reads the vault (`getTask`, `getSubmission`); changes nothing in
///         it. No owner.
///
///         A position is $YOLO, irrevocable, placed before the task's deadline while no submission is under review.
///         Of every position 5% is to burn (held in `burnHeld` until the outcome, burned to 0x…dEaD by `settle` unless
///         the task was cancelled), 5% is deferred (`Market.deferred`), 90% (`effPosition`)
///         joins its side's pool with points `effPosition * w`, `w = (time left to the deadline / (deadline - task
///         creation))^2`, frozen at placement. Anyone may predict, including the task's author, a contributor to
///         its reward, or the doer themself.
///
///         Outcome (`settle`, permissionless, also run by the first `claim`): the task `Completed` (a submission made
///         before the deadline may be accepted after it) -> WILL DO wins; `Expired` -> WON'T DO wins; `Unwound`
///         (the dev wallet cancelled the task) -> void: every position comes back in full, 100%
///         of what was put in, with no burn and no deferred part (`paidIn`).
///         Winners get their 90% plus the losing pool by points (`splits`: remaining/remaining, the last claimant
///         takes the dust; a winning side with 0 points in total splits it by position). Nobody on the winning side (no refund
///         of the losing pool): the whole losing pool goes to the author and the doer instead, half each if
///         WILL DO won with nobody on it, entirely to the author if WON'T DO won with nobody on it; the losers get
///         nothing back. The deferred 5%: task `Completed` -> 2.5% to its author and 2.5% to the accepted doer, even
///         with nobody on WILL DO; otherwise they burn.
///
///         No bank cap, no per-address limit, and no price or oracle of any kind: a market opens
///         at the first position, in any task currency, with no $YOLO price needed. The reward is locked until the
///         deadline; the market voids only on `Unwound`.
contract YoloPredict {
    using SafeERC20 for IERC20;

    uint256 private constant BPS = 10_000;
    uint256 private constant BURN_BPS = 500; // 5% burns, held until the outcome
    uint256 private constant DEFER_BPS = 500; // 5% waits for the outcome: 2.5% author + 2.5% doer
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IPredictVault public immutable vault;
    IERC20 public immutable yolo;
    /// @notice Anti-dust floor on a single position, fixed at deployment.
    uint256 public immutable minPosition;

    struct Market {
        uint64 openedAt; // first position (0 = no market)
        bool settled; // deferred paid or burned, the doer's points out of the split
        uint256 willDoPool;
        uint256 wontDoPool;
        uint256 willDoPointsTotal;
        uint256 wontDoPointsTotal;
        uint256 deferred; // 5% of every position, until `settle`
    }

    struct Position {
        uint256 willDoAmount;
        uint256 willDoPoints;
        uint256 wontDoAmount;
        uint256 wontDoPoints;
    }

    enum Resolution {
        Pending,
        Void,
        WillDoWon,
        WontDoWon
    }

    /// @dev What is left of a resolved market's losing pool and of the winning side's points still in the split.
    struct Split {
        bool started;
        uint256 poolLeft;
        uint256 pointsLeft;
    }

    mapping(uint256 => Market) public markets;
    mapping(uint256 => mapping(address => Position)) public positionsOf;
    mapping(uint256 => Split) public splits;
    /// @notice The 5% burn of every position of a market, held until `settle` burns it (or, on a cancelled task,
    ///         returned with the positions): a cancellation gives every position back in full.
    mapping(uint256 => uint256) public burnHeld;
    /// @notice Everything an address put into a market (100% of its positions): what a cancellation returns.
    mapping(uint256 => mapping(address => uint256)) public paidIn;

    event Predicted(
        uint256 indexed taskId,
        address indexed who,
        bool willDo,
        uint256 amount,
        uint256 effPosition,
        uint256 points,
        uint256 burned,
        uint256 deferred
    );
    event Claimed(uint256 indexed taskId, address indexed who, uint256 amount, Resolution resolution);
    /// @notice The deferred 5% of a market: paid to the author and the doer (task done) or burned.
    event Settled(uint256 indexed taskId, Resolution resolution, address doer, uint256 toAuthor, uint256 toDoer, uint256 burned);
    /// @notice Nobody on the winning side: the whole losing pool paid out directly instead of split by points.
    event NoWinner(uint256 indexed taskId, Resolution resolution, uint256 toAuthor, uint256 toDoer);
    /// @notice The held 5% entry burn of a resolved (not cancelled) market sent to 0x…dEaD.
    event EntryBurned(uint256 indexed taskId, uint256 amount);

    error ZeroAmount();
    error ZeroAddress();
    error TaskNotOpen();
    error SubmissionActive();
    error WindowClosed();
    error BelowMinPosition();
    error NotFinal();
    error NothingToClaim();

    constructor(address vault_, uint256 minPosition_) {
        if (vault_ == address(0)) revert ZeroAddress();
        if (minPosition_ == 0) revert ZeroAmount();
        IPredictVault v = IPredictVault(vault_);
        vault = v;
        yolo = v.yolo();
        minPosition = minPosition_;
    }

    /// @notice Predict, with `amount` $YOLO, that `taskId` will be done (`willDo`) or not by its deadline. Anyone
    ///         may predict, including the task's author, a contributor to its reward, or the doer themself.
    function predict(uint256 taskId, bool willDo, uint256 amount) external {
        if (amount < minPosition) revert BelowMinPosition();
        Task memory task = vault.getTask(taskId);
        if (task.activeSub != 0 && block.timestamp < task.deadline) {
            vault.poke(taskId); // play the timers: a submission ended by its timer does not pause predictions
            task = vault.getTask(taskId);
        }
        if (task.status != TaskStatus.Open) revert TaskNotOpen();
        if (block.timestamp >= task.deadline) revert WindowClosed();
        if (task.activeSub != 0) revert SubmissionActive();

        Market storage m = markets[taskId];
        if (m.openedAt == 0) {
            m.openedAt = uint64(block.timestamp);
        }
        uint256 burned = amount * BURN_BPS / BPS;
        uint256 deferred = amount * DEFER_BPS / BPS;
        uint256 effPosition = amount - burned - deferred;

        uint256 remaining = task.deadline - block.timestamp;
        uint256 points = _points(effPosition, remaining, task.deadline - task.createdAt);
        Position storage p = positionsOf[taskId][msg.sender];
        if (willDo) {
            p.willDoAmount += effPosition;
            p.willDoPoints += points;
            m.willDoPool += effPosition;
            m.willDoPointsTotal += points;
        } else {
            p.wontDoAmount += effPosition;
            p.wontDoPoints += points;
            m.wontDoPool += effPosition;
            m.wontDoPointsTotal += points;
        }
        m.deferred += deferred;
        burnHeld[taskId] += burned;
        paidIn[taskId][msg.sender] += amount;

        yolo.safeTransferFrom(msg.sender, address(this), amount);
        emit Predicted(taskId, msg.sender, willDo, amount, effPosition, points, burned, deferred);
    }

    /// @notice Settle a resolved market once (anyone; the first `claim` does it too): the held 5% entry burn to
    ///         0x…dEaD, the deferred 5% to the author and the doer (task done) or to 0x…dEaD; a cancelled task (void)
    ///         burns and pays nothing here, every position comes back in full through `claim`. Nobody on the winning
    ///         side: the whole losing pool pays out right here instead of waiting in the split (half each to
    ///         the author and the doer if WILL DO won with nobody on it, entirely to the author if WON'T DO won with
    ///         nobody on it); the losers get nothing back.
    // slither-disable-next-line reentrancy-no-eth
    function settle(uint256 taskId) public {
        Market storage m = markets[taskId];
        if (m.settled) return;
        vault.poke(taskId); // play the task's timers first: a deadline that passed unpoked still resolves
        Task memory task = vault.getTask(taskId);
        Resolution res = _resolve(task, m);
        if (res == Resolution.Pending) revert NotFinal();
        m.settled = true;
        uint256 held = burnHeld[taskId];
        burnHeld[taskId] = 0; // void: it goes back inside every position's `paidIn`
        if (res != Resolution.Void && held != 0) {
            yolo.safeTransfer(DEAD, held);
            emit EntryBurned(taskId, held);
        }
        uint256 d = m.deferred;
        m.deferred = 0;
        // slither-disable-next-line uninitialized-local
        address doer;
        // slither-disable-next-line uninitialized-local
        uint256 toAuthor;
        // slither-disable-next-line uninitialized-local
        uint256 toDoer;
        // slither-disable-next-line uninitialized-local
        uint256 burnt;
        if (task.status == TaskStatus.Completed) {
            doer = vault.getSubmission(task.activeSub).doer;
            toAuthor = d / 2;
            toDoer = d - toAuthor;
            if (toAuthor != 0) yolo.safeTransfer(task.author, toAuthor);
            if (toDoer != 0) yolo.safeTransfer(doer, toDoer);
        } else if (res != Resolution.Void) {
            burnt = d;
            if (d != 0) yolo.safeTransfer(DEAD, d);
        }
        emit Settled(taskId, res, doer, toAuthor, toDoer, burnt);

        if (res == Resolution.WillDoWon && m.willDoPool == 0 && m.wontDoPool != 0) {
            uint256 pool = m.wontDoPool;
            m.wontDoPool = 0;
            uint256 half = pool / 2;
            if (half != 0) yolo.safeTransfer(task.author, half);
            if (pool - half != 0) yolo.safeTransfer(doer, pool - half);
            emit NoWinner(taskId, res, half, pool - half);
        } else if (res == Resolution.WontDoWon && m.wontDoPool == 0 && m.willDoPool != 0) {
            uint256 pool = m.willDoPool;
            m.willDoPool = 0;
            yolo.safeTransfer(task.author, pool);
            emit NoWinner(taskId, res, pool, 0);
        }
    }

    /// @notice Claim `taskId`: a winner's 90% plus their share of the losing pool. Losers get nothing (no refund).
    ///         A cancelled task (void): everything this address put in, in full.
    // slither-disable-next-line reentrancy-no-eth
    function claim(uint256 taskId) external {
        Position storage p = positionsOf[taskId][msg.sender];
        uint256 willDoAmount = p.willDoAmount;
        uint256 wontDoAmount = p.wontDoAmount;
        if (willDoAmount == 0 && wontDoAmount == 0) revert NothingToClaim();
        settle(taskId);
        Resolution res = _resolve(vault.getTask(taskId), markets[taskId]);

        // slither-disable-next-line uninitialized-local
        uint256 pay;
        if (res == Resolution.WillDoWon || res == Resolution.WontDoWon) {
            bool willDoWon = res == Resolution.WillDoWon;
            pay = willDoWon ? willDoAmount : wontDoAmount;
            uint256 points = willDoWon ? p.willDoPoints : p.wontDoPoints;
            // a winning side with 0 points in total (every position taken at the last second) splits by position
            Market storage m = markets[taskId];
            if ((willDoWon ? m.willDoPointsTotal : m.wontDoPointsTotal) == 0) points = pay;
            if (points != 0) {
                Split storage sp = _split(taskId, willDoWon);
                if (sp.pointsLeft != 0) {
                    uint256 share = Math.mulDiv(sp.poolLeft, points, sp.pointsLeft);
                    sp.poolLeft -= share;
                    sp.pointsLeft -= points;
                    pay += share;
                }
            }
        } else if (res == Resolution.Void) {
            pay = paidIn[taskId][msg.sender];
        }
        // the losing side: nothing.

        delete positionsOf[taskId][msg.sender];
        delete paidIn[taskId][msg.sender];
        if (pay != 0) yolo.safeTransfer(msg.sender, pay);
        emit Claimed(taskId, msg.sender, pay, res);
    }

    /// @notice How `taskId`'s market resolved, for the site (Pending: no market, or the task still open).
    function resolution(uint256 taskId) external view returns (Resolution) {
        return _resolve(vault.getTask(taskId), markets[taskId]);
    }

    // ================================================================== internal

    function _resolve(Task memory task, Market storage m) private view returns (Resolution) {
        if (m.openedAt == 0 || task.status == TaskStatus.Open) return Resolution.Pending;
        if (task.status == TaskStatus.Unwound) return Resolution.Void; // cancelled by the dev wallet: all back
        return task.status == TaskStatus.Completed ? Resolution.WillDoWon : Resolution.WontDoWon;
    }

    /// @dev Starts the split of a resolved market once: the whole losing pool and the winning side's points.
    function _split(uint256 taskId, bool willDoWon) private returns (Split storage sp) {
        sp = splits[taskId];
        if (!sp.started) {
            Market storage m = markets[taskId];
            sp.started = true;
            sp.poolLeft = willDoWon ? m.wontDoPool : m.willDoPool;
            sp.pointsLeft = willDoWon ? m.willDoPointsTotal : m.wontDoPointsTotal;
            if (sp.pointsLeft == 0) sp.pointsLeft = willDoWon ? m.willDoPool : m.wontDoPool; // split by position
        }
    }

    /// @dev `effPosition * (remaining / duration)^2` in two roundings (never overflows); duration > 0 because a task's
    ///      deadline is always after its creation.
    function _points(uint256 effPosition, uint256 remaining, uint256 duration) private pure returns (uint256) {
        uint256 mid = Math.mulDiv(effPosition, remaining, duration);
        return Math.mulDiv(mid, remaining, duration);
    }
}
