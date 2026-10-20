// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ParamsRegistry} from "./ParamsRegistry.sol";
import {ParamsCore} from "./VaultParams.sol";
import {SubmitTerms} from "./desks/DeskApi.sol";
import {TaskStatus, Outcome, Verdict, Task, Submission, Settlement, Dispute} from "./VaultTypes.sol";

/// @dev The vault views the sweetener reads (the vault forwards the desk views).
interface ISweetenedVault {
    function submitTerms(uint256 taskId, address doer) external view returns (SubmitTerms memory);
    function getTask(uint256 taskId) external view returns (Task memory);
    function getSubmission(uint256 subId) external view returns (Submission memory);
    function getSettlement(uint256 subId) external view returns (Settlement memory);
    function getDispute(uint256 subId) external view returns (Dispute memory);
    function votesOf(uint256 subId, address payTo) external view returns (uint256 accept, uint256 reject);
    function registry() external view returns (address);
    function yolo() external view returns (IERC20);
    function sweetener() external view returns (address);
    function burner() external view returns (address);
    function poke(uint256 taskId) external;
}

/// @title YoloSweetener: a $YOLO bonus on top of any task, whatever the currency of its reward
/// @notice Anyone may add $YOLO to an open task before its deadline. The bonus sits here, apart from the vault's pots,
///         and follows the task:
///         - no limit on the bonus (no limit on a task's reward or on
///           the add-on either);
///         - locked like the reward: nobody takes it back while the task is open, before or after the deadline;
///         - the task expires: each sweetener takes back their own (`withdraw`);
///         - a submission is accepted (`Completed`): anyone calls `payout`. The whole bonus goes by the reward's
///           rule: 10% fee, of it 5% (`nftFeeBps`) to the NFT votes on "accept" if the
///           NFT decided right (claimed here, `claimVoter`, pro rata to their votes), the rest goes to the vault's
///           burner, where it waits for anyone's "Burn" (the treasury's $YOLO income is burned); if the vault paid the doer the stake bonus on this
///           submission, they get the same share of the bonus even if they sweetened this task themselves.
///           (`Settlement.stakeBps`: 4% x min(1, power / (the whole reward + the $YOLO add-on at submission, in $YOLO))). The 5%
///           of YOLO Predict positions never come here: YoloPredict pays them itself.
///         Takes deposits only once the vault bound it (`TaskVault.bindSweetener`): only then does the core read the
///         add-on with the reward, and pays the stake bonus share on it.
///         Reads the vault (task, accepted submission, its settlement and votes); changes nothing in it. No owner.
contract YoloSweetener {
    using SafeERC20 for IERC20;

    uint256 private constant BPS = 10_000;

    ISweetenedVault public immutable vault;
    ParamsRegistry public immutable registry;
    IERC20 public immutable yolo;

    /// @notice $YOLO held for a task until it is paid out or taken back.
    mapping(uint256 => uint256) public bonusOf;
    /// @notice What `who` put on a task and has not taken back.
    mapping(uint256 => mapping(address => uint256)) public givenBy;
    /// @notice Whether `who` ever sweetened a task (a record only: a doer who did keeps their stake bonus).
    mapping(uint256 => mapping(address => bool)) public gave;
    /// @notice The NFT votes' share of a paid-out bonus not claimed yet, and their votes not claimed yet.
    mapping(uint256 => uint256) public voterPool;
    mapping(uint256 => uint256) public voterVotesLeft;
    mapping(uint256 => mapping(address => bool)) public voterClaimed;

    event Sweetened(uint256 indexed taskId, address indexed from, uint256 amount, uint256 bonus);
    event BonusWithdrawn(uint256 indexed taskId, address indexed to, uint256 amount, uint256 bonus);
    event BonusPaid(
        uint256 indexed taskId, uint256 indexed subId, address indexed doer, uint256 toDoer, uint256 toVoters, uint256 burned
    );
    event VoterBonusClaimed(uint256 indexed taskId, address indexed payTo, uint256 votes, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error TaskNotOpen();
    error BonusLocked();
    error NotAccepted();
    error NothingToPay();
    /// @notice The vault has not bound this sweetener (`TaskVault.bindSweetener`): its add-on would not count.
    error NotBound();

    constructor(address vault_) {
        if (vault_ == address(0)) revert ZeroAddress();
        ISweetenedVault v = ISweetenedVault(vault_);
        vault = v;
        registry = ParamsRegistry(v.registry());
        yolo = v.yolo();
    }

    /// @notice Add `amount` $YOLO (pulled with transferFrom) to the bonus of an open task before its deadline. No
    ///         limit on the bonus. The task's timers are played first
    ///         (`poke`, like TaskVault.topUp): nothing gets into a task that is already decided or expired but not yet
    ///         poked.
    function sweeten(uint256 taskId, uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        if (vault.sweetener() != address(this)) revert NotBound();
        vault.poke(taskId);
        Task memory task = vault.getTask(taskId);
        if (task.status != TaskStatus.Open || block.timestamp >= task.deadline) revert TaskNotOpen();
        uint256 bonus = bonusOf[taskId] + amount;
        bonusOf[taskId] = bonus;
        givenBy[taskId][msg.sender] += amount;
        gave[taskId][msg.sender] = true;
        yolo.safeTransferFrom(msg.sender, address(this), amount);
        emit Sweetened(taskId, msg.sender, amount, bonus);
    }

    /// @notice Take back all you put on a task once nobody can earn it: it expired or was unwound (or it is past its
    ///         deadline with no submission in flight, which the vault turns into an expiry at the next call).
    function withdraw(uint256 taskId) external {
        vault.poke(taskId);
        SubmitTerms memory t = vault.submitTerms(taskId, address(0));
        bool free = t.status == TaskStatus.Expired || t.status == TaskStatus.Unwound
            || (t.status == TaskStatus.Open && !t.busy && block.timestamp >= t.deadline);
        if (!free) revert BonusLocked();
        uint256 amount = givenBy[taskId][msg.sender];
        if (amount == 0) revert ZeroAmount();
        givenBy[taskId][msg.sender] = 0;
        uint256 bonus = bonusOf[taskId] - amount;
        bonusOf[taskId] = bonus;
        yolo.safeTransfer(msg.sender, amount);
        emit BonusWithdrawn(taskId, msg.sender, amount, bonus);
    }

    /// @notice Pay the bonus of a completed task (anyone): to the doer of its accepted submission, the NFT share and
    ///         the burn by the reward's rule (see the contract notice).
    function payout(uint256 taskId) external {
        vault.poke(taskId); // an acceptance by timer counts without a separate poke
        Task memory task = vault.getTask(taskId);
        if (task.status != TaskStatus.Completed) revert NotAccepted();
        uint256 bonus = bonusOf[taskId];
        if (bonus == 0) revert NothingToPay();
        uint256 subId = task.activeSub; // the accepted submission (TaskVault keeps it on Completed)
        Submission memory s = vault.getSubmission(subId);
        if (s.outcome != Outcome.Accepted) revert NotAccepted();
        ParamsCore memory p = registry.core(task.paramsVersion);
        bonusOf[taskId] = 0;

        uint256 fee = bonus * p.feeBps / BPS;
        uint256 nftPart = bonus * p.nftFeeBps / BPS;
        // slither-disable-next-line uninitialized-local
        uint256 toVoters;
        if (s.nftDecision == Verdict.Accept) {
            toVoters = nftPart;
            voterPool[taskId] = nftPart;
            voterVotesLeft[taskId] = vault.getDispute(subId).votesAccept;
        }
        // slither-disable-next-line uninitialized-local
        uint256 extra;
        uint256 bps = vault.getSettlement(subId).stakeBps;
        if (bps != 0) {
            extra = bonus * bps / BPS;
            if (extra > fee - nftPart) extra = fee - nftPart;
        }
        uint256 burned = fee - toVoters - extra;
        uint256 toDoer = bonus - fee + extra;
        yolo.safeTransfer(s.doer, toDoer);
        if (burned != 0) yolo.safeTransfer(vault.burner(), burned);
        emit BonusPaid(taskId, subId, s.doer, toDoer, toVoters, burned);
    }

    /// @notice An NFT voter's share of a paid-out bonus (anyone may trigger; money goes to `payTo`, the address the
    ///         votes named), pro rata to its "accept" votes on the accepted submission. The last one takes the rest.
    // slither-disable-next-line unused-return
    function claimVoter(uint256 taskId, address payTo) external {
        uint256 subId = vault.getTask(taskId).activeSub;
        (uint256 n,) = vault.votesOf(subId, payTo);
        uint256 left = voterVotesLeft[taskId];
        if (n == 0 || left == 0 || voterClaimed[taskId][payTo]) revert NothingToPay();
        voterClaimed[taskId][payTo] = true;
        uint256 pool = voterPool[taskId];
        uint256 share = Math.mulDiv(pool, n, left);
        voterPool[taskId] = pool - share;
        voterVotesLeft[taskId] = left - n;
        if (share != 0) yolo.safeTransfer(payTo, share);
        emit VoterBonusClaimed(taskId, payTo, n, share);
    }
}
