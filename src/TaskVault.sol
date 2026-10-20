// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ParamsRegistry} from "./ParamsRegistry.sol";
import {ParamsCore} from "./VaultParams.sol";
import {OracleAttestation} from "./OracleAttestation.sol";
import {IIntake} from "./interfaces/IIntake.sol";
import {DevPrices} from "./DevPrices.sol";
import {ISwapAdapter} from "./interfaces/ISwapAdapter.sol";
import {ITaskVault} from "./interfaces/ITaskVault.sol";
import {AskTerms, SubmitTerms, ICaseDesk} from "./desks/DeskApi.sol";
import {AttestationChecker} from "./helpers/AttestationChecker.sol";
import {TextRules} from "./helpers/TextRules.sol";
import "./VaultTypes.sol";

/// @dev The vault's YoloSweetener as the vault reads it: the $YOLO add-on of a task.
interface IAddon {
    function vault() external view returns (address);
    function bonusOf(uint256 taskId) external view returns (uint256);
}

interface IDeskWiring {
    function wire(address registry, address imd, address usdc, address caseDesk, address disputeDesk) external;
}

/// @dev Where a burn share of ETH, USDC or IMD is sent directly.
interface IBurnerWallet {
    function buybackWallet() external view returns (address);
}

/// @title TaskVault
/// @notice Escrow for real-world tasks. Rewards in ETH, USDC, IMD or $YOLO; doers post IMD bonds; anyone can dispute;
///         identity.md NFT holders vote, each with their own transaction (`vote(...tokenIds)`); the IMD swarm (Intake) is the
///         final instance.
///
///         One public address. Users call, approve tokens to, and read only this contract (full interface:
///         ITaskVault). It holds all the money, the tasks with their contributions and queues, and the swarm
///         requests, and forwards the rest with a plain CALL (never DELEGATECALL) to the desk that owns that state:
///         CaseDesk (submissions, the state machine, swarm questions), DisputeDesk (disputes, votes, appeals,
///         settlements, claims). The forwarded calldata carries the original sender and msg.value at its end; the
///         ETH stays here. One reentrancy lock covers every state-changing call, here and in the desks.
///
///         Money rules
///         - Every amount held belongs to exactly one bucket: a task pot, a submission's bonds,
///           check or appeal prepayments, a settlement bucket waiting for lazy claims, a treasury
///           pot, or a user credit. `liabilities[token]` is their sum and changes only when money enters or leaves.
///           Invariant: token balance >= liabilities[token]. Nothing is paid from the "general balance". All payouts
///           are pull (claims, `withdraw`). Only this contract moves money; the desks tell it what to book.
///         - Rewards are locked until the deadline: nobody who put money into a task takes it
///           back before the task expired or was unwound; a top-up during a check joins the reward at once.
///         - Burning: $YOLO the treasury would get goes to the BuybackBurner and sits there until anyone presses
///           "Burn". ETH, USDC and IMD burn shares go straight to the buyback wallet in the same transaction as the
///           payout; if that transfer reverts (a wallet
///           with no `receive`), the payout itself must not fail — that share lands in the BuybackBurner instead,
///           for its own `forward` to retry later.
///         - The vault has no owner. The ParamsRegistry owner (the project wallet) can only change parameters for
///           future tasks and the attester set (48h timelock) and pause task creation. The dev wallet (owner of the
///           DevPrices) can cancel an open task (`cancelTask`): all money goes back to whoever put it in, none to it.
///
///         Lifecycle: timers are played lazily at the start of every call that touches a task (`advance`);
///         swarm questions are paid by whoever calls the swarm (`appeal`, `callSwarm`; no mandatory
///         check); prepaid questions are asked lazily by the same machine. The treasury pays for nothing.
contract TaskVault {
    using SafeERC20 for IERC20;

    /// @dev Gas that must remain after a failed Intake call: more than the rest of any caller needs, far less than
    ///      1/64 of what a real Intake request costs to starve.
    uint256 internal constant ASK_GAS_RESERVE = 150_000;
    /// @dev Gas forwarded to the buyback wallet's ETH receive: a wallet that reverts or
    ///      burns gas must not be able to freeze the whole payout by eating the rest of the transaction's gas; this
    ///      is far more than a plain `receive()` needs and far less than it takes to starve the caller.
    uint256 private constant BURN_SEND_GAS = 30_000;
    uint256 private constant ROUTE_VIEW = 1;
    uint256 private constant ROUTE_CALL = 2;
    uint256 private constant ROUTE_PAYABLE = 3;

    /// @dev Who asked a swarm question and on which terms: the Intake that must deliver the answer and the panel
    ///      the answer must come from (the parameters of the submission's task, fixed when it was asked).
    struct AskedVia {
        address intake;
        uint16 minPanelSize;
        uint16 minQuorum;
    }

    IERC20 public immutable imd;
    IERC20 public immutable usdc;
    /// @dev the project token $YOLO: the fourth reward currency (Bonds stay in IMD)
    IERC20 public immutable yolo;
    address public immutable registry;
    AttestationChecker public immutable attestationChecker;
    TextRules public immutable textRules;
    address public immutable caseDesk;
    address public immutable disputeDesk;
    /// @notice BuybackBurner: $YOLO burn shares wait here for anyone's `burnYolo`. ETH, USDC and IMD burn shares
    ///         are sent straight to its buyback wallet at payout; this is only the fallback when that send fails.
    address public immutable burner;

    // tasks
    uint256 public taskCount;
    mapping(uint256 => Task) internal _tasks;
    mapping(uint256 => mapping(address => Contribution)) internal _contributions;
    mapping(uint256 => mapping(uint256 => uint64)) internal _queue; // taskId => index => subId
    /// @dev the newest parameter version a task was created under (ParamsCached is emitted when it changes)
    uint32 internal _lastVersion;
    // money
    mapping(address => uint256) public liabilities; // token => everything the vault owes
    mapping(address => mapping(address => uint256)) public credits; // token => account => withdrawable
    mapping(address => uint256) public treasuryPot; // token => amount owed to the project treasury
    mapping(bytes32 => SwarmRequest) internal _requests;
    mapping(bytes32 => AskedVia) internal _askedVia;
    /// @notice The YoloSweetener of this vault (launch 3), bound once by the registry owner (`bindSweetener`). Its
    ///         $YOLO add-on is paid with the reward; the stake bonus
    ///         share is paid on it too, and the power is measured against the pot plus the add-on. Until it is bound no add-on exists (the sweetener refuses deposits).
    address public sweetener;

    bool private transient _entered;

    error ReentrancyGuardReentrantCall();

    /// @param attestationChecker_, textRules_ stateless helpers (launched with the registry)
    /// @param caseDesk_, disputeDesk_ deployed in the same transaction, before the vault: the constructor wires them to
    ///        this vault (Desk.wire), which they accept only once and only in that transaction.
    constructor(
        address registry_,
        address imd_,
        address usdc_,
        address yolo_,
        address attestationChecker_,
        address textRules_,
        address caseDesk_,
        address disputeDesk_,
        address burner_
    ) {
        if (registry_ == address(0) || imd_ == address(0) || usdc_ == address(0) || yolo_ == address(0)) {
            revert BadCurrency();
        }
        if (burner_.code.length == 0) revert WrongWiring();
        burner = burner_;
        registry = registry_;
        imd = IERC20(imd_);
        usdc = IERC20(usdc_);
        yolo = IERC20(yolo_);
        attestationChecker = AttestationChecker(attestationChecker_);
        if (address(attestationChecker.registry()) != registry_) revert WrongWiring();
        textRules = TextRules(textRules_);
        caseDesk = caseDesk_;
        disputeDesk = disputeDesk_;
        IDeskWiring(caseDesk_).wire(registry_, imd_, usdc_, caseDesk_, disputeDesk_);
        IDeskWiring(disputeDesk_).wire(registry_, imd_, usdc_, caseDesk_, disputeDesk_);
    }

    /// @notice Bind this vault's YoloSweetener, once (the registry owner; the sweetener must name this vault).
    ///         Nothing can move or freeze money through it: it only lets the add-on count with the reward.
    function bindSweetener(address s) external {
        if (msg.sender != ParamsRegistry(registry).owner()) revert NotAuthorized();
        if (sweetener != address(0) || IAddon(s).vault() != address(this)) revert WrongWiring();
        sweetener = s;
        emit SweetenerBound(s);
    }

    modifier nonReentrant() {
        if (_entered) revert ReentrancyGuardReentrantCall();
        _entered = true;
        _;
        _entered = false;
    }

    modifier onlyDesk() {
        if (msg.sender != caseDesk && msg.sender != disputeDesk) revert NotAuthorized();
        _;
    }

    // ================================================================== forwarding

    /// @notice Every function of ITaskVault not implemented here is forwarded to its desk: state-changing ones under
    ///         the reentrancy lock with sender and value appended, views with a STATICCALL and no lock.
    ///         `paramsOf` is answered by the registry (a version's snapshot never changes once activated).
    // slither-disable-next-line reentrancy-no-eth
    fallback() external payable {
        (address target, uint256 route) = _route(msg.sig);
        if (target == address(0)) revert UnknownFunction();
        if (msg.value != 0 && route != ROUTE_PAYABLE) revert NotPayable();
        bytes memory data = abi.encodePacked(msg.data, msg.sender, msg.value);
        bool ok;
        bytes memory ret;
        if (route == ROUTE_VIEW) {
            (ok, ret) = target.staticcall(data);
        } else {
            if (_entered) revert ReentrancyGuardReentrantCall();
            _entered = true;
            (ok, ret) = target.call(data);
            _entered = false;
        }
        assembly ("memory-safe") {
            if iszero(ok) { revert(add(ret, 32), mload(ret)) }
            return(add(ret, 32), mload(ret))
        }
    }

    error NotPayable();

    function _route(bytes4 sig) private view returns (address, uint256) {
        if (sig == ITaskVault.submit.selector) return (caseDesk, ROUTE_PAYABLE);
        if (sig == ITaskVault.claimVoidSubmission.selector) {
            return (caseDesk, ROUTE_CALL);
        }
        if (
            sig == ITaskVault.getSubmission.selector || sig == ITaskVault.submissionCount.selector
                || sig == ITaskVault.stepDeadline.selector || sig == ITaskVault.previewSwarmBody.selector
                || sig == ITaskVault.quoteSubmission.selector
        ) return (caseDesk, ROUTE_VIEW);

        if (
            sig == ITaskVault.dispute.selector || sig == ITaskVault.appeal.selector
                || sig == ITaskVault.callSwarm.selector
        ) return (disputeDesk, ROUTE_PAYABLE);
        if (
            sig == ITaskVault.vote.selector || sig == ITaskVault.claimDisputer.selector
                || sig == ITaskVault.claimVoterReward.selector || sig == ITaskVault.claimVoterRewards.selector
                || sig == ITaskVault.askAppealSwarm.selector
        ) return (disputeDesk, ROUTE_CALL);
        if (
            sig == ITaskVault.getDispute.selector || sig == ITaskVault.getDisputer.selector
                || sig == ITaskVault.getAppeal.selector || sig == ITaskVault.getSettlement.selector
                || sig == ITaskVault.votesOf.selector || sig == ITaskVault.voterClaimed.selector
                || sig == ITaskVault.hasVoted.selector || sig == ITaskVault.votePower.selector
                || sig == ITaskVault.tokenVoted.selector || sig == ITaskVault.sideOf.selector
                || sig == ITaskVault.sideSpent.selector
        ) return (disputeDesk, ROUTE_VIEW);
        if (sig == ITaskVault.quoteDisputeBond.selector || sig == ITaskVault.quoteSwarmFee.selector) {
            return (caseDesk, ROUTE_VIEW);
        }

        if (sig == ITaskVault.paramsOf.selector) return (registry, ROUTE_VIEW);
        return (address(0), 0);
    }

    // ================================================================== tasks

    /// @notice Create a task under the current parameter version. No creation fee. msg.value
    ///         covers the reward for ETH tasks + ETH swapped in mode A (IMD tasks). Excess ETH is refunded.
    ///         `deadline` is required and never changes. The reward is worth at least the currency's own minimum (`minRewardUsdc`/`minRewardEth`/`minRewardImd`/`minRewardYolo`, no USD
    ///         conversion); no upper limit on one task's reward or on all open tasks together.
    ///         `title` (1..MAX_TITLE_BYTES, only in TaskCreated, never sent to the swarm); `rules` (TaskRules: TASK,
    ///         PROOF and NO texts, each 1..maxTextBytes, stored, each one swarm definition); `category` (< CATEGORY_COUNT) and `proofType`
    ///         (< PROOF_TYPE_COUNT: what every proofUri must be) are stored; `cover` (empty, `ipfs://…` or `https://…`,
    ///         at most MAX_COVER_BYTES) is only emitted in TaskCreated. None of them can change later.
    // slither-disable-next-line reentrancy-eth
    function createTask(
        address currency,
        uint256 amount,
        uint64 deadline,
        string calldata title,
        TaskRules calldata rules,
        uint8 category,
        uint8 proofType,
        string calldata cover,
        ImdPay calldata payIn
    ) external payable nonReentrant returns (uint256 taskId) {
        ParamsRegistry reg = ParamsRegistry(registry);
        if (reg.newTasksPaused()) revert Paused();
        if (currency != ETH && currency != address(usdc) && currency != address(imd) && currency != address(yolo)) {
            revert BadCurrency();
        }
        if (deadline <= block.timestamp) revert BadDeadline();
        uint32 version = reg.currentVersion();
        if (version != _lastVersion) {
            _lastVersion = version;
            emit ParamsCached(version);
        }
        ParamsCore memory p = reg.core(version);
        TextRules text = textRules;
        if (!text.validText(title, MAX_TITLE_BYTES)) revert BadTitle();
        uint256 maxText = p.maxTextBytes;
        if (
            !text.validText(rules.task, maxText) || !text.validText(rules.proof, maxText)
                || !text.validText(rules.noIf, maxText)
        ) revert BadText();
        if (category >= CATEGORY_COUNT) revert BadCategory();
        if (proofType >= PROOF_TYPE_COUNT) revert BadProofType();
        text.checkCover(cover);
        if (amount == 0 || amount > type(uint128).max) revert BadAmount();
        if (amount < _minReward(p, currency)) revert RewardTooSmall();

        taskId = ++taskCount;
        Task storage t = _tasks[taskId];
        t.author = msg.sender;
        t.deadline = deadline;
        t.paramsVersion = version;
        t.status = TaskStatus.Open;
        t.currency = currency;
        t.category = category;
        t.proofType = proofType;
        t.createdAt = uint64(block.timestamp);
        // 1 keccak256(abi.encode(...)) instead of 3 SSTORE strings; the texts stay in
        // this call's calldata and TaskCreated below. abi.encode, not concat, so field boundaries cannot shift.
        t.rulesHash = keccak256(abi.encode(rules.task, rules.proof, rules.noIf));
        t.pot = amount;
        Contribution storage ct = _contributions[taskId][msg.sender];
        ct.active = uint128(amount);
        ct.ever = true;

        uint256 ethNeeded = _collect(msg.sender, msg.value, currency, amount, p.swapAdapter, payIn);
        _settleValue(msg.sender, msg.value, ethNeeded);
        emit TaskCreated(taskId, msg.sender, currency, amount, deadline, title, rules, category, proofType, cover);
    }

    /// @notice Add to a task's reward (same currency), locked like the rest until the deadline. A top-up made while
    ///         a submission is being checked joins the reward at once too (like the $YOLO
    ///         add-on): if that submission is accepted, its doer gets it with the rest of the pot. The doer's bond
    ///         stays based on the author's own reward. A decided task takes nothing (`TaskNotOpen`).
    // slither-disable-next-line reentrancy-no-eth
    function topUp(uint256 taskId, uint256 amount, ImdPay calldata payIn) external payable nonReentrant {
        _advance(taskId);
        Task storage t = _tasks[taskId];
        if (t.status != TaskStatus.Open) revert TaskNotOpen();
        if (block.timestamp >= t.deadline) revert DeadlinePassed();
        if (amount == 0 || amount > type(uint128).max) revert BadAmount();
        ParamsCore memory p = ParamsRegistry(registry).core(t.paramsVersion);

        Contribution storage c = _contributions[taskId][msg.sender];
        c.ever = true;
        c.active += uint128(amount);
        t.pot += amount;
        // no contributor fee
        _settleValue(msg.sender, msg.value, _collect(msg.sender, msg.value, t.currency, amount, p.swapAdapter, payIn));
        emit ToppedUp(taskId, msg.sender, amount, t.activeSub != 0);
    }

    /// @notice Take back your share once the reward is unlocked: everything after expiry or a cancellation
    ///         by the dev wallet (`cancelTask`); nothing after an acceptance (the whole pot went to the doer). While
    ///         the task is open nothing leaves, before or after its deadline: a doer may be
    ///         working on it.
    // slither-disable-next-line reentrancy-no-eth
    function withdrawContribution(uint256 taskId) external nonReentrant {
        _advance(taskId);
        Task storage t = _tasks[taskId];
        Contribution storage c = _contributions[taskId][msg.sender];
        TaskStatus st = t.status;
        if (st == TaskStatus.Open) revert TaskNotOpen();
        uint256 amount = st == TaskStatus.Completed ? 0 : c.active;
        if (amount == 0) revert NothingToClaim();
        c.active -= uint128(amount);
        t.pot -= amount;
        emit ContributionWithdrawn(taskId, msg.sender, amount);
        _pay(t.currency, msg.sender, amount);
    }

    // ================================================================== timers and cancellation

    /// @notice Play the expired timers of a task (anyone; every task call does this first). A prepaid appeal
    ///         question is asked by `askAppealSwarm`, which carries the resupplied texts.
    function poke(uint256 taskId) external nonReentrant {
        _advance(taskId);
    }

    /// @notice Cancel a task: only the dev wallet, the owner of the DevPrices of the task's parameter version (the
    ///         wallet that sets the prices), and only while the task is still open after its timers are played, i.e.
    ///         before its final payout. The task becomes Unwound and everyone takes back what they put in except swarm
    ///         fees already paid, each with their own call: the reward and top-ups with `withdrawContribution`, the
    ///         doer's bond and an appellant's bond and unspent prepayment as credits, disputers with `claimDisputer`,
    ///         queued doers with `claimVoidSubmission`, $YOLO add-ons with `YoloSweetener.withdraw`, YOLO Predict
    ///         positions in full with `YoloPredict.claim`. The dev wallet gets nothing in any outcome; swarm fees
    ///         already paid to the Intake are gone and come back to nobody.
    // slither-disable-next-line reentrancy-no-eth
    function cancelTask(uint256 taskId) external nonReentrant {
        Task storage t = _tasks[taskId];
        if (t.author == address(0)) revert TaskNotOpen();
        address dev = Ownable(ParamsRegistry(registry).core(t.paramsVersion).devPrices).owner();
        if (msg.sender != dev) revert NotAuthorized();
        _advance(taskId);
        if (t.status != TaskStatus.Open) revert TaskNotOpen();
        uint256 subId = t.activeSub;
        if (subId != 0) ICaseDesk(caseDesk).unwind(subId); // closeSubmission(Unwound) closes the task
        else _close(taskId, t, TaskStatus.Unwound);
        emit TaskCancelled(taskId, msg.sender);
    }

    // ================================================================== tasks for the desks

    /// @notice Play all expired timers of a task (every action on a submission starts here).
    function advance(uint256 taskId) external onlyDesk {
        _advance(taskId);
    }

    function isContributor(uint256 taskId, address who) external view returns (bool) {
        return _contributions[taskId][who].ever;
    }

    function statusOf(uint256 taskId) external view returns (TaskStatus) {
        return _tasks[taskId].status;
    }

    /// @notice The reward in play of a task: what an accepted doer gets before the fee (CaseDesk._finalize).
    function potOf(uint256 taskId) external view returns (uint256) {
        return _tasks[taskId].pot;
    }

    /// @dev `doer` is not read: no field of `SubmitTerms` depends on it
    ///      (the doer stake bonus does not exclude a doer who contributed to the task).
    function submitTerms(uint256 taskId, address doer) external view returns (SubmitTerms memory r) {
        Task storage t = _tasks[taskId];
        r.status = t.status;
        r.deadline = t.deadline;
        r.version = t.paramsVersion;
        r.currency = t.currency;
        r.proofType = t.proofType;
        r.busy = t.activeSub != 0;
        r.pot = t.pot;
        // the author's own share of the pot (their top-ups included): the base of the bonds
        r.base = _contributions[taskId][t.author].active;
        r.addon = _addon(taskId);
        doer;
    }

    /// @dev The task's $YOLO add-on; 0 while no sweetener is bound.
    function _addon(uint256 taskId) private view returns (uint256) {
        address s = sweetener;
        if (s == address(0)) return 0;
        return IAddon(s).bonusOf(taskId);
    }

    /// @notice A new submission joins its task: active at once, or queued behind the active one.
    function place(uint256 taskId, uint256 subId, bool queued) external onlyDesk {
        Task storage t = _tasks[taskId];
        if (queued) _queue[taskId][t.queueTail++] = uint64(subId);
        else t.activeSub = uint64(subId);
    }

    /// @notice The task side of a final submission: completion, unwind, or the next queued submission (returned for
    ///         the case desk to activate, 0 = none). `reward` is the whole pot on an acceptance (CaseDesk._finalize).
    function closeSubmission(uint256 taskId, Outcome o, uint256 reward) external onlyDesk returns (uint256 next) {
        Task storage t = _tasks[taskId];
        if (o == Outcome.Accepted) {
            // activeSub stays: on a Completed task it names the accepted submission (YoloPredict, YoloSweetener)
            t.pot -= reward;
            _close(taskId, t, TaskStatus.Completed);
            return 0;
        }
        t.activeSub = 0;
        if (o == Outcome.Unwound) {
            _close(taskId, t, TaskStatus.Unwound);
        } else {
            ++t.rejectedCount;
            if (t.queueHead < t.queueTail) {
                next = _queue[taskId][t.queueHead++];
                t.activeSub = uint64(next);
            }
        }
    }

    // ================================================================== swarm answers

    /// @notice Intake callback (selector 0x510379c7). Binding: `requestId` is the Intake id stored at request time
    ///         and msg.sender is that Intake (the attestation's own requestId is the oracle UUID and differs by
    ///         design). Records a verified answer; never reverts on unknown, foreign, duplicate or invalid input.
    ///         Not nonReentrant on purpose: it makes no external call except the attestation check (a view of
    ///         the AttestationChecker and the registry), and the Intake must always be able to deliver.
    ///         The only way an answer reaches the vault (no public fallback). A callback
    ///         that is never delivered is silence: the swarm timeout, or the Intake reporting the request completed
    ///         without a recorded answer (CaseDesk._swarmStatus).
    function onOracleResult(bytes32 requestId, OracleAttestation.Attestation calldata a, bytes calldata signature)
        external
    {
        SwarmRequest storage r = _requests[requestId];
        if (r.subId == 0) {
            emit AttestationIgnored(requestId, 1);
            return;
        }
        AskedVia memory via = _askedVia[requestId];
        if (msg.sender != via.intake) {
            emit AttestationIgnored(requestId, 2);
            return;
        }
        if (r.answered) {
            emit AttestationIgnored(requestId, 3);
            return;
        }
        uint8 code = attestationChecker.check(address(this), via.minPanelSize, via.minQuorum, a, signature);
        if (code != 0) {
            emit AttestationIgnored(requestId, 10 + code);
            return;
        }
        _recordAnswer(r, requestId, a);
    }

    // ================================================================== money out (users)

    function withdraw(address token) external nonReentrant {
        _withdrawTo(token, msg.sender);
    }

    /// @notice Withdraw credited money to `to`.
    function withdrawTo(address token, address to) external nonReentrant {
        _withdrawTo(token, to);
    }

    /// @notice Move the treasury pot of `token` to the treasury address of the registry's current parameters
    ///         (as a credit). The treasury pays for nothing in the protocol flows, so nothing is kept back.
    function sweepTreasury(address token) external nonReentrant {
        ParamsRegistry reg = ParamsRegistry(registry);
        address treasury = reg.core(reg.currentVersion()).treasury; // the current address, even before a new task
        uint256 amount = treasuryPot[token];
        treasuryPot[token] = 0;
        _credit(token, treasury, amount);
        emit TreasurySwept(token, treasury, amount);
    }

    // ================================================================== views

    function getTask(uint256 taskId) external view returns (Task memory) {
        return _tasks[taskId];
    }

    function getContribution(uint256 taskId, address who) external view returns (Contribution memory) {
        return _contributions[taskId][who];
    }

    function requests(bytes32 requestId) external view returns (SwarmRequest memory) {
        return _requests[requestId];
    }

    /// @notice EIP-712 digest of an attestation for this vault: domain ("IdentityMD Oracle", "2", chainid, vault).
    function attestationDigest(OracleAttestation.Attestation calldata a) external view returns (bytes32) {
        return attestationChecker.digest(address(this), a);
    }

    // ================================================================== bank (desks only)
    // Bookkeeping rule: `liabilities[token]` grows when money is booked in and shrinks when it leaves; moves between
    // buckets (pots, settlement buckets, credits, the treasury pot) do not touch it.

    /// @notice Books exactly `needed` IMD from `from` (see _collectImd). Returns the ETH it needs from msg.value.
    function collectImd(address from, uint256 msgValue, uint256 needed, address adapter, ImdPay calldata payIn)
        external
        onlyDesk
        returns (uint256 ethNeeded)
    {
        return _collectImd(from, msgValue, needed, adapter, payIn);
    }

    /// @notice Books `amount` of `currency` from `from` for a bond's "rew" or "add" part: ETH from msg.value, IMD or
    ///         any other token by plain transferFrom. No swap, no oracle.
    // slither-disable-next-line arbitrary-send-erc20
    function collectBondPart(address from, uint256 msgValue, address currency, uint256 amount)
        external
        onlyDesk
        returns (uint256 ethNeeded)
    {
        if (amount == 0) return 0;
        if (currency == ETH) {
            liabilities[ETH] += amount;
            return amount;
        }
        if (currency == address(imd)) {
            // slither-disable-next-line uninitialized-local
            ImdPay memory noSwap;
            return _collectImd(from, msgValue, amount, address(0), noSwap);
        }
        IERC20(currency).safeTransferFrom(from, address(this), amount);
        liabilities[currency] += amount;
        return 0;
    }

    /// @notice msg.value must cover `ethNeeded`; the excess is returned to the payer.
    function settleValue(address payer, uint256 msgValue, uint256 ethNeeded) external onlyDesk {
        _settleValue(payer, msgValue, ethNeeded);
    }

    /// @notice Bucket -> account credit (pull with `withdraw`). Liabilities unchanged.
    function credit(address token, address account, uint256 amount) external onlyDesk {
        _credit(token, account, amount);
    }

    /// @notice Pays an owed amount now; if the transfer fails it stays owed as a credit.
    function pay(address token, address to, uint256 amount) external onlyDesk {
        _pay(token, to, amount);
    }

    /// @notice Bucket -> treasury pot. Liabilities unchanged. $YOLO goes to the burner instead: it waits there for the "Burn" button, BuybackBurner.burnYolo.
    function addTreasury(address token, uint256 amount) external onlyDesk {
        if (token == address(yolo)) _burn(token, amount);
        else treasuryPot[token] += amount;
    }

    /// @notice Bucket -> burn: $YOLO to the BuybackBurner (it waits there for anyone's `burnYolo`); ETH, USDC and
    ///         IMD straight to the buyback wallet, or to the BuybackBurner for its `forward` if that send fails.
    function burn(address token, uint256 amount) external onlyDesk {
        _burn(token, amount);
    }

    /// @notice Pays the Intake `price` IMD (already booked in one of the submission's buckets) and records the
    ///         question. Never reverts on an Intake failure: returns ok = false and nothing is spent; the desk
    ///         deducts `spent` from the paying bucket.
    // slither-disable-next-line reentrancy-balance
    function ask(AskTerms calldata t, bytes calldata body)
        external
        onlyDesk
        returns (bool ok, uint256 spent, bytes32 rid)
    {
        IERC20 imd_ = imd;
        uint256 price = t.price;
        address intake = t.intake;
        uint256 balBefore = imd_.balanceOf(address(this));
        imd_.forceApprove(intake, price);
        try IIntake(intake)
            .request(t.action, body, IIntake.Callback(address(this), CALLBACK_SELECTOR), address(imd_), price) returns (
            bytes32 id
        ) {
            rid = id;
            ok = true;
        } catch {}
        imd_.forceApprove(intake, 0);
        spent = balBefore - imd_.balanceOf(address(this));
        if (spent > price || (ok && (rid == bytes32(0) || _requests[rid].subId != 0)) || (!ok && spent != 0)) {
            revert UnknownRequest(); // an Intake breaking its own interface: only a cancellation (cancelTask) helps
        }
        // a failure caused by a gas limit set just low enough to starve the Intake call must not count as the
        // Intake failing (that would void an appeal or a call of the swarm): revert the whole transaction
        if (!ok && gasleft() < ASK_GAS_RESERVE) revert InsufficientGas();
        if (!ok) return (false, 0, bytes32(0));
        liabilities[address(imd_)] -= spent;
        _requests[rid] = SwarmRequest({
            subId: t.subId,
            askedAt: uint64(block.timestamp),
            answerTime: 0,
            recordedAt: 0,
            kind: t.kind,
            answered: false,
            answer: false,
            questionHash: t.questionHash
        });
        _askedVia[rid] = AskedVia(intake, t.minPanelSize, t.minQuorum);
        emit SwarmAsked(t.subId, rid, t.kind, spent, t.questionHash);
    }

    // ================================================================== internal

    /// @dev Bounded loop: at most a few transitions per call. Expiry happens here; the steps of the active submission
    ///      are played by the case desk (which calls back `closeSubmission` when one becomes final).
    // slither-disable-next-line reentrancy-no-eth
    function _advance(uint256 taskId) private {
        for (uint256 i; i < 8; ++i) {
            Task storage t = _tasks[taskId];
            if (t.status != TaskStatus.Open) return;
            uint256 subId = t.activeSub;
            if (subId == 0) {
                if (block.timestamp >= t.deadline) _close(taskId, t, TaskStatus.Expired);
                return;
            }
            if (!ICaseDesk(caseDesk).step(subId)) return;
        }
    }

    function _close(uint256 taskId, Task storage t, TaskStatus st) private {
        t.status = st;
        emit TaskStatusChanged(taskId, st);
    }

    /// @dev The smallest reward of a new task, in its own currency: no USD conversion, no
    ///      oracle, no upper limit.
    function _minReward(ParamsCore memory p, address currency) private view returns (uint256) {
        if (currency == ETH) return p.minRewardEth;
        if (currency == address(usdc)) return p.minRewardUsdc;
        if (currency == address(imd)) return p.minRewardImd;
        return p.minRewardYolo;
    }

    /// @dev $YOLO always goes to the burner (it only burns from there). ETH, USDC and IMD try the
    ///      buyback wallet directly, in this same transaction; a revert there (no `receive`) must not sink the
    ///      payout, so it falls back to the burner, where `forward` can retry later.
    function _burn(address token, uint256 amount) private {
        if (amount == 0) return;
        if (token == address(yolo)) {
            _pay(token, burner, amount);
        } else {
            address wallet = IBurnerWallet(burner).buybackWallet();
            if (_trySend(token, wallet, amount, BURN_SEND_GAS)) {
                liabilities[token] -= amount;
                emit Paid(token, wallet, amount);
            } else {
                _pay(token, burner, amount);
            }
        }
        emit Burned(token, amount);
    }

    /// @dev Books `amount` of a task currency from `from`. Returns the ETH it needs from the user's msg.value.
    function _collect(
        address from,
        uint256 msgValue,
        address currency,
        uint256 amount,
        address adapter,
        ImdPay calldata payIn
    ) private returns (uint256 ethNeeded) {
        if (currency == ETH) {
            liabilities[ETH] += amount;
            return amount;
        }
        if (currency == address(imd)) return _collectImd(from, msgValue, amount, adapter, payIn);
        // USDC or $YOLO, paid directly (neither charges a transfer fee)
        IERC20(currency).safeTransferFrom(from, address(this), amount);
        liabilities[currency] += amount;
        return 0;
    }

    function _settleValue(address payer, uint256 msgValue, uint256 ethNeeded) private {
        if (msgValue < ethNeeded) revert NotEnoughEth();
        _refundUnbooked(ETH, payer, msgValue - ethNeeded);
    }

    function _pay(address token, address to, uint256 amount) private {
        if (amount == 0) return;
        if (_trySend(token, to, amount)) {
            liabilities[token] -= amount;
            emit Paid(token, to, amount);
        } else {
            _credit(token, to, amount);
        }
    }

    function _withdrawTo(address token, address to) private {
        if (to == address(0)) revert WithdrawToZero();
        uint256 amount = credits[token][msg.sender];
        if (amount == 0) revert NothingToClaim();
        credits[token][msg.sender] = 0;
        liabilities[token] -= amount;
        if (!_trySend(token, to, amount)) revert TransferFailed();
        emit Paid(token, to, amount);
    }

    // slither-disable-next-line incorrect-equality
    function _credit(address token, address account, uint256 amount) private {
        if (amount == 0) return;
        credits[token][account] += amount;
        emit Credited(token, account, amount);
    }

    /// @dev Returns money that was never booked (excess msg.value, swap surplus); credited if the transfer fails.
    // slither-disable-next-line incorrect-equality
    function _refundUnbooked(address token, address to, uint256 amount) private {
        if (amount == 0) return;
        if (!_trySend(token, to, amount)) {
            liabilities[token] += amount;
            _credit(token, to, amount);
        }
    }

    function _trySend(address token, address to, uint256 amount) private returns (bool ok) {
        return _trySend(token, to, amount, gasleft());
    }

    /// @dev `ethGas` caps only the ETH branch (an ERC20 `transfer` runs the token's own code, not the recipient's,
    ///      so it cannot grief the caller the same way).
    // slither-disable-next-line incorrect-equality
    function _trySend(address token, address to, uint256 amount, uint256 ethGas) private returns (bool ok) {
        if (token == ETH) {
            (ok,) = to.call{value: amount, gas: ethGas}("");
            return ok;
        }
        bytes memory ret;
        (ok, ret) = token.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        return ok && (ret.length == 0 || (ret.length == 32 && abi.decode(ret, (bool))));
    }

    /// @dev Books exactly `needed` IMD from `from`: mode B transferFrom, or mode A swap through the adapter
    ///      (exact input, user minOut / deadline, measured by balance difference, surplus returned).
    ///      Returns the ETH it needs from msg.value.
    // slither-disable-next-line arbitrary-send-eth,reentrancy-balance,reentrancy-eth,unused-return
    function _collectImd(address from, uint256 msgValue, uint256 needed, address adapter, ImdPay memory payIn)
        private
        returns (uint256 ethNeeded)
    {
        if (needed == 0) return 0;
        IERC20 imd_ = imd;
        liabilities[address(imd_)] += needed;
        if (payIn.amountIn == 0) {
            uint256 bal = imd_.balanceOf(address(this));
            imd_.safeTransferFrom(from, address(this), needed);
            if (imd_.balanceOf(address(this)) - bal < needed) revert ImdShort(); // no fee-on-transfer surprises
            return 0;
        }
        if (adapter == address(0)) revert SwapDisabled();
        if (block.timestamp > payIn.deadline) revert SwapExpired();
        if (payIn.minImdOut < needed) revert SwapShort();
        uint256 before = imd_.balanceOf(address(this));
        if (payIn.tokenIn == ETH) {
            // never front other users' ETH to the swap; the full msg.value check follows in settleValue
            if (payIn.amountIn > msgValue) revert NotEnoughEth();
            ethNeeded = payIn.amountIn;
            ISwapAdapter(adapter).swapExactIn{value: payIn.amountIn}(
                ETH, address(imd_), payIn.amountIn, payIn.minImdOut, payIn.deadline, payIn.route, address(this)
            );
        } else if (payIn.tokenIn == address(usdc)) {
            IERC20 usdc_ = usdc;
            uint256 usdcBefore = usdc_.balanceOf(address(this));
            usdc_.safeTransferFrom(from, address(this), payIn.amountIn);
            usdc_.forceApprove(adapter, payIn.amountIn);
            ISwapAdapter(adapter)
                .swapExactIn(
                    address(usdc_),
                    address(imd_),
                    payIn.amountIn,
                    payIn.minImdOut,
                    payIn.deadline,
                    payIn.route,
                    address(this)
                );
            usdc_.forceApprove(adapter, 0);
            _refundUnbooked(address(usdc_), from, usdc_.balanceOf(address(this)) - usdcBefore);
        } else {
            revert BadCurrency();
        }
        uint256 got = imd_.balanceOf(address(this)) - before;
        if (got < needed) revert SwapShort();
        _refundUnbooked(address(imd_), from, got - needed);
    }

    /// @dev SwarmAnswered keeps its `viaCallback` field for decoders; it is always true (the only path).
    function _recordAnswer(SwarmRequest storage r, bytes32 requestId, OracleAttestation.Attestation calldata a)
        private
    {
        // the signed issuedAt decides whether the answer came in time; clamped to [askedAt, now]
        uint64 t = a.issuedAt;
        if (t < r.askedAt) t = r.askedAt;
        if (t > block.timestamp) t = uint64(block.timestamp);
        bool answer = uint256(bytes32(a.answer)) == 1;
        r.answered = true;
        r.answer = answer;
        r.answerTime = t;
        r.recordedAt = uint64(block.timestamp);
        emit SwarmAnswered(requestId, r.subId, answer, t, true);
    }
}
