// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ParamsCore} from "../VaultParams.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IIntake} from "../interfaces/IIntake.sol";
import {DevPrices} from "../DevPrices.sol";
import {SwarmQuestionBuilder} from "../helpers/SwarmQuestion.sol";
import {Desk} from "./Desk.sol";
import {SubmitTerms, SubCore, Facts, Tally, AskTerms, IVault, IDisputeDesk, IDoerStake} from "./DeskApi.sol";
import "../VaultTypes.sol";

/// @title CaseDesk
/// @notice Submissions and the lazy state machine of a task's active submission: activation, the dispute window,
///         the NFT decision, the windows to call the swarm, prepaid questions, the final outcome. Timers move only
///         forward and only here. A prepaid appeal is due at once and asked here by the next `askAppealSwarm`
///         (anyone), so no step waits for a keeper; a failing Intake never blocks the machine (the appeal is void). No task has a mandatory swarm
///         check: the swarm is asked only when somebody pays for it. The money of a final
///         submission is split by the DisputeDesk (`settle`).
contract CaseDesk is Desk {
    /// @inheritdoc Desk
    function isCaseDesk() public pure override returns (bool) {
        return true;
    }

    /// @dev What a submission inherits from its task, fixed at submission: one slot instead of a call per step.
    struct Terms {
        uint32 version;
        address currency;
    }

    SwarmQuestionBuilder internal immutable questionBuilder;
    /// @notice $YOLO: the currency of the add-on and of the doer stake.
    address public immutable yolo;
    /// @notice YoloLockHub: the doer's $YOLO lock behind the stake bonus, read at submission.
    IDoerStake public immutable doerStake;

    uint256 public submissionCount;
    mapping(uint256 => Submission) internal _subs;
    mapping(uint256 => Terms) internal _terms;

    constructor(
        address registry_,
        address imd_,
        address usdc_,
        address textRules_,
        address questionBuilder_,
        address yolo_,
        address doerStake_
    ) Desk(registry_, imd_, usdc_, textRules_) {
        questionBuilder = SwarmQuestionBuilder(questionBuilder_);
        yolo = yolo_;
        doerStake = IDoerStake(doerStake_);
    }

    // ================================================================== user actions (through the vault)

    /// @notice Submit a proof (irrevocable). Bond = 0.5 IMD fixed + 3% of the author's own reward in R's currency:
    ///         top-ups of others and the $YOLO add-on are not in it; always the same, no escalation for rejected
    ///         submissions or the queue. No oracle, no USD conversion.
    ///         The doer stake bonus is fixed here too (`stakeBps`): 4% x min(1, power / (R in $YOLO + the $YOLO
    ///         add-on)), the power of the doer's lock as it stood before this block, R = the task's whole reward at this
    ///         moment (the pot: the author's share and every top-up) converted at the dev-set $YOLO price
    ///         (DevPrices: no oracle, no sample window), the add-on = the task's $YOLO add-on at this moment;
    ///         any power counts, no threshold; no $YOLO price = no bonus (the only
    ///         DevPrices read of a submission; it never blocks a submission).
    ///         `minReward` protects against a top-up merging into the pot between the quote and the transaction;
    ///         `maxBondRew` caps the bond's `rew` part.
    ///         `proofUri` is one link in the form the task's proof type requires (`BadProof` otherwise).
    ///         `evidence`: a screenshot link (`https://` on an allowlisted host, TextLib.checkScreenshotUrl) and a note, sent to
    ///         the swarm with the proof. The screenshot link is mandatory for x_post, x_reply and video
    ///         (`EvidenceRequired` otherwise, allowlisted hosts); for
    ///         onchain_tx and link it stays optional.
    // slither-disable-next-line reentrancy-no-eth
    function submit(
        uint256 taskId,
        string calldata proofUri,
        Evidence calldata evidence,
        uint256 minReward,
        uint256 maxBondRew,
        ImdPay calldata payIn
    ) external routed returns (uint256 subId) {
        address sender = _sender();
        IVault tasks = _bank();
        tasks.advance(taskId);
        SubmitTerms memory t = tasks.submitTerms(taskId, sender);
        if (t.status != TaskStatus.Open) revert TaskNotOpen();
        if (block.timestamp >= t.deadline) revert DeadlinePassed();
        if (t.pot == 0) revert RewardTooSmall();
        if (t.pot < minReward) revert RewardChanged();
        ParamsCore memory p = _params(t.version);
        _checkText(proofUri, p);
        textRules.checkProof(proofUri, t.proofType);
        bool hasNote = bytes(evidence.note).length != 0;
        if (hasNote && !textRules.validText(evidence.note, MAX_NOTE_BYTES)) revert BadEvidence();
        bool hasShot = bytes(evidence.screenshotUrl).length != 0;
        textRules.checkScreenshotUrl(evidence.screenshotUrl);
        // the swarm cannot open X or a video on its own, so a screenshot/clip link is
        // mandatory for those proof types; onchain_tx and link stay as they are (a tx hash or a link is itself
        // the proof the swarm can check). Only hosts of the allowlist (TextLib.checkHost).
        if ((t.proofType == PROOF_X_POST || t.proofType == PROOF_VIDEO) && !hasShot) {
            revert EvidenceRequired();
        }

        subId = ++submissionCount;
        Submission storage s = _subs[subId];
        s.taskId = uint64(taskId);
        s.doer = sender;
        s.submittedAt = uint64(block.timestamp);
        s.proofUri = proofUri;
        s.reward = SafeCast.toUint128(t.pot);
        s.base = uint128(t.base); // a part of the pot
        s.addon = t.addon;
        Bond memory b = _doerBond(t.base, p);
        s.bond = b;
        (s.stakeBps, s.staked) = _stakeBps(t, sender, p);
        _terms[subId] = Terms(t.version, t.currency);

        if (b.rew > maxBondRew) revert CostAboveMax();
        uint256 value = _value();
        IVault bank = _bank();
        // the "rew" part merges into the same collectImd call (and its swap mode) when R is already in IMD
        bool rewIsImd = t.currency == address(imd);
        uint256 ethNeeded = bank.collectImd(sender, value, b.imd + (rewIsImd ? b.rew : 0), p.swapAdapter, payIn);
        if (!rewIsImd) ethNeeded += bank.collectBondPart(sender, value, t.currency, b.rew);

        bool queued = t.busy;
        emit Submitted(subId, taskId, sender, t.pot, b.imd, b.rew, queued, proofUri);
        if (hasShot || hasNote) {
            if (hasShot) s.screenshotUrl = evidence.screenshotUrl;
            if (hasNote) s.doerNote = evidence.note;
            emit EvidenceAttached(subId, evidence.screenshotUrl, evidence.note);
        }
        tasks.place(taskId, subId, queued);
        if (queued) s.phase = Phase.Queued;
        else _activate(subId);
        _bank().settleValue(sender, value, ethNeeded); // excess ETH back last (checks, effects, interactions)
    }

    /// @notice Bond of a queued submission whose task was completed or unwound.
    // slither-disable-next-line reentrancy-no-eth
    function claimVoidSubmission(uint256 subId) external routed {
        Submission storage s = _subs[subId];
        IVault tasks = _bank();
        tasks.advance(s.taskId);
        TaskStatus ts = tasks.statusOf(s.taskId);
        if (s.phase != Phase.Queued || (ts != TaskStatus.Completed && ts != TaskStatus.Unwound)) {
            revert NothingToClaim();
        }
        s.phase = Phase.Void;
        Bond memory b = s.bond;
        address currency = _terms[subId].currency;
        emit VoidSubmissionClaimed(subId, s.doer, b.imd, b.rew);
        IVault bank = _bank();
        bank.pay(address(imd), s.doer, b.imd);
        bank.pay(currency, s.doer, b.rew);
    }

    // No "doer answers the dispute" step: their "why honest" text goes
    // into Evidence.note at submission (Submission.doerNote), read by the swarm question directly.

    // ================================================================== the machine (TaskVault.advance)

    /// @notice The dev wallet cancelled the task (TaskVault.cancelTask): the active submission
    ///         closes as Unwound, every bond and unspent prepayment goes back to its owner (DisputeDesk._settleNeutral;
    ///         disputers take theirs with claimDisputer); swarm fees already paid stay paid.
    function unwind(uint256 subId) external only(vault) {
        _finalize(subId, Outcome.Unwound);
    }

    /// @notice One transition of the active submission. False if nothing can move now.
    // slither-disable-next-line incorrect-equality,reentrancy-no-eth
    function step(uint256 subId) external only(vault) returns (bool) {
        Submission storage s = _subs[subId];
        ParamsCore memory p = _params(_terms[subId].version);
        Phase ph = s.phase;

        if (ph == Phase.Review) {
            if (block.timestamp < s.windowEnd) return false;
            _finalize(subId, Outcome.Accepted); // nobody disputed
            return true;
        }
        if (ph == Phase.Voting) {
            if (block.timestamp < s.voteEnd) return false;
            if (!_tryDecide(subId, IDisputeDesk(disputeDesk).tally(subId), s.voteEnd, p)) {
                s.phase = Phase.NoDecision; // optimistic window: anyone may call the swarm, paying
                s.callFrom = s.voteEnd;
                emit NoNftDecision(subId);
            }
            return true;
        }
        if (ph == Phase.NoDecision || ph == Phase.Decided) {
            if (block.timestamp < uint256(s.callFrom) + p.appealWindow) return false;
            _endUncalled(subId);
            return true;
        }
        if (ph == Phase.Appealed) {
            // `DisputeDesk.appeal` only files the appeal, the ask is lazy. `step`/`poke` still cannot carry the
            // resupplied text (no text channel here, same as every other transition in this function), so this
            // step cannot progress it by itself; the ask happens via the separate permissionless
            // `DisputeDesk.askAppealSwarm(subId, rt)` instead (anyone, including the site right after `appeal` or
            // a poke-bot). Without this timeout, a never-called `askAppealSwarm` would deadlock the submission
            // forever - nothing else in this file has a timeout for `Phase.Appealed` (every other phase above
            // does). Same exit `_askAppeal`'s void-appeal branch already uses when the live price/a broken Intake
            // kills an asked appeal: an appeal that could not be asked has its bond and fee refunded to the
            // appellant, and still counts toward the same 3 calls: full refund via `dropCaller`, back to
            // `Decided`, counts toward MAX_SWARM_CALLS. The appeal was never actually asked,
            // so there is no fee for the swarm to have earned.
            if (block.timestamp < uint256(s.appealedAt) + p.swarmTimeout) return false;
            IDisputeDesk(disputeDesk).dropCaller(subId);
            s.phase = Phase.Decided;
            s.callFrom = uint64(uint256(s.appealedAt) + p.swarmTimeout); // the window reopens at the void, not the poke
            emit AppealVoided(subId, 0);
            if (++s.asks >= MAX_SWARM_CALLS) _endUncalled(subId);
            return true;
        }
        if (ph == Phase.Asked) {
            (SwarmStatus st, bool answer, uint64 at) = _swarmStatus(s.request, p);
            if (st == SwarmStatus.Pending) return false;
            if (st == SwarmStatus.Answered) {
                _finalize(subId, answer ? Outcome.Accepted : Outcome.Rejected); // the swarm is final
            } else {
                // silent: the caller's fee stays paid (no separate refund), the
                // rest of their deposit is theirs (pull); the state before the call stands again and a new window to
                // call the swarm starts at the moment of silence; after MAX_SWARM_CALLS questions the submission
                // ends as if nobody had called (a silent swarm cannot keep the money locked)
                IDisputeDesk(disputeDesk).dropCaller(subId);
                s.phase = s.nftDecision == Verdict.None ? Phase.NoDecision : Phase.Decided;
                s.callFrom = at;
                emit SwarmSilent(subId, s.request, at);
                if (s.asks >= MAX_SWARM_CALLS) _endUncalled(subId);
            }
            return true;
        }
        return false; // Queued / Final / Void are inert
    }

    // ================================================================== for the dispute desk

    /// @notice Plays the task's timers first, then returns the submission as it stands.
    function advanced(uint256 subId) external only(disputeDesk) returns (SubCore memory) {
        _bank().advance(_subs[subId].taskId);
        return _core(subId);
    }

    /// @notice The dispute starts the NFT vote.
    function startVote(uint256 subId, uint32 voteWindow) external only(disputeDesk) {
        Submission storage s = _subs[subId];
        if (s.phase != Phase.Review) return;
        s.phase = Phase.Voting;
        s.voteEnd = uint64(block.timestamp) + voteWindow;
    }

    function markAppealed(uint256 subId) external only(disputeDesk) {
        Submission storage s = _subs[subId];
        s.phase = Phase.Appealed;
        s.appealedAt = uint64(block.timestamp);
    }

    /// @notice The swarm is called while the NFT did not decide: asked at once, paid from the caller's deposit.
    ///         `rt`: DisputeDesk.callSwarm's caller resupplied the task rules and the dispute reason/proof link in
    ///         the same transaction; checked against the stored hashes in `_ask`.
    // slither-disable-next-line reentrancy-no-eth
    function askEscalation(uint256 subId, uint256 price, RuleTexts calldata rt)
        external
        only(disputeDesk)
        returns (bool ok, uint256 spent)
    {
        (ok, spent) = _ask(subId, SWARM_KIND_ESCALATION, price, _params(_terms[subId].version), rt);
        if (ok) _subs[subId].phase = Phase.Asked;
    }

    /// @notice DisputeDesk.askAppealSwarm's lazy ask (not called from `appeal` itself):
    ///         `rt` is the task rules + the filed dispute's reason/proof link, resupplied by whoever
    ///         calls `askAppealSwarm` (any address), checked in `_ask` against the stored hashes. `funds` = the
    ///         appellant's prepaid fee (bond-sourced + wallet-sourced, DisputeDesk._fundCall, read at appeal time).
    function askAppeal(uint256 subId, uint256 funds, RuleTexts calldata rt) external only(disputeDesk) {
        if (_subs[subId].phase != Phase.Appealed) revert WrongPhase();
        _askAppeal(subId, funds, _params(_terms[subId].version), rt);
    }

    // ================================================================== views

    function getSubmission(uint256 subId) external view returns (Submission memory) {
        return _subs[subId];
    }

    /// @notice What a vote needs (DisputeDesk.vote): three slots instead of the whole SubCore.
    function voteState(uint256 subId) external view returns (Phase phase, uint64 voteEnd, uint32 version) {
        Submission storage s = _subs[subId];
        return (s.phase, s.voteEnd, _terms[subId].version);
    }

    /// @notice Dispute bond of `subId`. Appealing or calling the swarm costs the same bond plus `quoteSwarmFee`
    ///         (here, not in DisputeDesk, for room under EIP-170).
    function quoteDisputeBond(uint256 subId) external view returns (Bond memory) {
        SubCore memory s = _core(subId);
        return _disputeBond(s.base, _params(s.version));
    }

    /// @notice Live swarm fee (IMD) for questions about `subId`; 0 = the Intake does not sell the action now.
    function quoteSwarmFee(uint256 subId) external view returns (uint256) {
        return _swarmPrice(_params(_terms[subId].version));
    }

    /// @notice The fixed IMD part of the doer bond (DisputeDesk: a doer's own swarm call is paid from it).
    function doerBondImd(uint256 subId) external view returns (uint256) {
        return _subs[subId].bond.imd;
    }

    function subCore(uint256 subId) external view returns (SubCore memory) {
        return _core(subId);
    }

    /// @notice The bond a new submission to `taskId` would need now.
    function quoteSubmission(uint256 taskId) external view returns (Bond memory bond) {
        SubmitTerms memory t = _bank().submitTerms(taskId, address(0));
        ParamsCore memory p = _params(t.version);
        bond = _doerBond(t.base, p);
    }

    /// @notice When the current step of an active submission times out.
    function stepDeadline(uint256 subId) external view returns (uint256) {
        Submission storage s = _subs[subId];
        ParamsCore memory p = _params(_terms[subId].version);
        Phase ph = s.phase;
        if (ph == Phase.Review) return s.windowEnd;
        if (ph == Phase.Voting) return s.voteEnd;
        if (ph == Phase.NoDecision || ph == Phase.Decided) return uint256(s.callFrom) + p.appealWindow;
        // the appeal's ask is lazy, due from the moment it was filed (markAppealed); not asked within swarmTimeout
        // it is void (step)
        if (ph == Phase.Appealed) return uint256(s.appealedAt) + p.swarmTimeout;
        if (ph == Phase.Asked) {
            // an answer in time, or the Intake already closed the request: the next poke plays it now
            (SwarmStatus st,,) = _swarmStatus(s.request, p);
            if (st != SwarmStatus.Pending) return block.timestamp;
            return uint256(_bank().requests(s.request).askedAt) + p.swarmTimeout + SWARM_DELIVERY_GRACE;
        }
        return type(uint128).max; // not an active step
    }

    /// @notice The JSON body the vault would send now for `kind` (2 escalation, 3 appeal). `rt`: the caller
    ///         supplies the task rules and the dispute reason/proof link - a free
    ///         read-only preview of exactly what a real `callSwarm`/`askAppealSwarm` with the same texts would send,
    ///         checked against the same stored hashes.
    function previewSwarmBody(uint256 subId, uint8 kind, RuleTexts calldata rt)
        external
        view
        returns (bytes memory body, bytes32 qh)
    {
        return questionBuilder.buildFor(vault, subId, kind, _params(_terms[subId].version).maxClaims, rt);
    }

    // ================================================================== internal: activation and decisions

    /// @dev Opens the dispute window of the task's new active submission (the vault already made it active).
    function _activate(uint256 subId) private {
        Submission storage s = _subs[subId];
        s.phase = Phase.Review;
        s.activatedAt = uint64(block.timestamp);
        s.windowEnd = uint64(block.timestamp) + _params(_terms[subId].version).disputeWindow;
        emit Activated(subId, s.windowEnd);
    }

    /// @dev The window to call the swarm ended unused (or the last allowed question stayed silent): NFT undecided ->
    ///      accepted, the disputer bonds to the doer (general rule); NFT decided -> its decision.
    function _endUncalled(uint256 subId) private {
        Submission storage s = _subs[subId];
        _finalize(subId, s.nftDecision == Verdict.Reject ? Outcome.Rejected : Outcome.Accepted);
    }

    /// @dev NFT decision rule at vote end (step, Voting): |accept - reject| >= endDelta and the winning side has
    ///      >= minWinnerWallets distinct signers.
    function _tryDecide(uint256 subId, Tally memory v, uint64 at, ParamsCore memory p) private returns (bool) {
        return _decide(subId, v, at, p.endDelta, p.minWinnerWallets, false);
    }

    /// @notice Instant NFT decision: on every vote, as soon as one side is ahead by
    ///         >= instantDelta with >= minWinnerWallets distinct signers on that side, the submission decides at
    ///         once (NftDecided.instant = true) instead of waiting for the vote window to end. Called by
    ///         DisputeDesk.vote right after it updates the tally; a no-op once already decided.
    function tryInstantDecision(uint256 subId, Tally calldata v) external only(disputeDesk) {
        Submission storage s = _subs[subId];
        if (s.phase != Phase.Voting) return;
        ParamsCore memory p = _params(_terms[subId].version);
        _decide(subId, v, uint64(block.timestamp), p.instantDelta, p.minWinnerWallets, true);
    }

    function _decide(uint256 subId, Tally memory v, uint64 at, uint32 delta, uint32 minWallets, bool instant)
        private
        returns (bool)
    {
        if (v.accept == v.reject) return false;
        bool acceptWins = v.accept > v.reject;
        uint256 diff = acceptWins ? v.accept - v.reject : v.reject - v.accept;
        uint256 wallets = acceptWins ? v.walletsAccept : v.walletsReject;
        if (diff < delta || wallets < minWallets) return false;
        Submission storage s = _subs[subId];
        s.nftDecision = acceptWins ? Verdict.Accept : Verdict.Reject;
        s.decidedAt = at;
        s.callFrom = at; // appeal window
        s.phase = Phase.Decided;
        emit NftDecided(subId, s.nftDecision, instant);
        return true;
    }

    /// @dev The appeal question, asked lazily from `DisputeDesk.askAppealSwarm` (any caller, in a transaction of
    ///      its own after `appeal`; it carries the resupplied `RuleTexts`). If the live price is
    ///      now above the prepaid fee, 0, or the Intake fails, the appeal is void: bond and fee are the appellant's
    ///      again (credit), the NFT decision stands and a new appeal window starts now, unless that was the
    ///      MAX_SWARM_CALLS-th question: then the NFT decision is final.
    // slither-disable-next-line reentrancy-no-eth
    function _askAppeal(uint256 subId, uint256 funds, ParamsCore memory p, RuleTexts calldata rt) private {
        Submission storage s = _subs[subId];
        IDisputeDesk disputes = IDisputeDesk(disputeDesk);
        uint256 price = _swarmPrice(p);
        if (price != 0 && price <= funds) {
            (bool ok, uint256 spent) = _ask(subId, SWARM_KIND_APPEAL, price, p, rt);
            if (ok) {
                s.phase = Phase.Asked;
                disputes.appealAsked(subId, spent);
                return;
            }
        }
        disputes.dropCaller(subId);
        s.phase = Phase.Decided;
        s.callFrom = uint64(block.timestamp);
        emit AppealVoided(subId, price);
        // a void appeal counts against MAX_SWARM_CALLS like a silent one: a broken Intake cannot
        // keep the submission open by appeal after appeal
        if (++s.asks >= MAX_SWARM_CALLS) _endUncalled(subId);
    }

    /// @dev Status of a swarm question. An answer counts if its signed time is within the timeout and it reached
    ///      the vault within SWARM_DELIVERY_GRACE after the timeout; `at` of an answer is the moment it reached the
    ///      vault (a window that follows it is never shortened). Silence: no such answer by the end of the grace
    ///      (moment of silence = ask time + timeout + grace), or no answer recorded and the Intake already reports
    ///      the request completed (status 1 / 2; moment of silence = now). Nothing is settled as silent while an
    ///      answer signed in time can still count. The outcome does not depend on who pokes when, but in the last
    ///      case the moment of silence (and the window that follows it) does: the Intake gives no completion time,
    ///      so it is the first poke after completion, at most swarmTimeout + grace later (7 h by default).
    // slither-disable-next-line unused-return
    function _swarmStatus(bytes32 rid, ParamsCore memory p)
        private
        view
        returns (SwarmStatus status, bool answer, uint64 at)
    {
        SwarmRequest memory r = _bank().requests(rid);
        uint256 deadline = uint256(r.askedAt) + p.swarmTimeout;
        uint256 lastDelivery = deadline + SWARM_DELIVERY_GRACE;
        if (r.answered && r.answerTime <= deadline && r.recordedAt <= lastDelivery) {
            return (SwarmStatus.Answered, r.answer, r.recordedAt);
        }
        if (block.timestamp >= lastDelivery) return (SwarmStatus.Silent, false, uint64(lastDelivery));
        if (r.answered) return (SwarmStatus.Pending, false, 0); // signed too late: silence at the end of the grace
        try IIntake(p.intake).requests(rid) returns (address, address, bytes4, bool completed) {
            if (completed) return (SwarmStatus.Silent, false, uint64(block.timestamp));
        } catch {}
        return (SwarmStatus.Pending, false, 0);
    }

    // ================================================================== internal: settlement

    /// @dev Closes a submission with `o`: the DisputeDesk splits the money, the vault moves the task on (next
    ///      queued submission, completion or unwind; top-ups are already in the pot). Credits only; never transfers.
    // slither-disable-next-line reentrancy-no-eth
    function _finalize(uint256 subId, Outcome o) private {
        Submission storage s = _subs[subId];
        Terms memory tm = _terms[subId];
        uint256 taskId = s.taskId;
        s.phase = Phase.Final;
        s.outcome = o;
        // accepted: the doer gets the whole pot, top-ups made during the check included;
        // `reward` then reads what was paid
        if (o == Outcome.Accepted) s.reward = SafeCast.toUint128(_bank().potOf(taskId));
        Facts memory f = Facts({
            taskId: s.taskId,
            version: tm.version,
            currency: tm.currency,
            doer: s.doer,
            nftDecision: s.nftDecision,
            reward: s.reward,
            bond: s.bond,
            since: s.submittedAt,
            stakeBps: s.stakeBps,
            staked: s.staked
        });
        IDisputeDesk(disputeDesk).settle(subId, o, f);
        emit SubmissionFinal(subId, taskId, o);
        uint256 next = _bank().closeSubmission(taskId, o, s.reward);
        if (next != 0) _activate(next);
    }

    // ================================================================== internal: swarm questions

    /// @dev Builds the question from stored data and has the vault pay the Intake `price` IMD (already held in one
    ///      of the submission's buckets). Never reverts on an Intake failure: ok = false and nothing is spent.
    function _ask(uint256 subId, uint8 kind, uint256 price, ParamsCore memory p, RuleTexts calldata rt)
        private
        returns (bool ok, uint256 spent)
    {
        (bytes memory body, bytes32 qh) = questionBuilder.buildFor(vault, subId, kind, p.maxClaims, rt);
        bytes32 rid;
        (ok, spent, rid) = _bank()
            .ask(AskTerms(uint64(subId), kind, p.minPanelSize, p.minQuorum, p.intake, p.swarmAction, qh, price), body);
        if (!ok) return (false, 0);
        Submission storage s = _subs[subId];
        ++s.asks;
        s.request = rid;
    }

    /// @dev The stake bonus of a new submission in bps of R (see `submit`). A doer who put money into the task's
    ///      own reward gets the bonus too. Never
    ///      blocks a submission: a hub or a DevPrices that fails counts as no stake.
    ///      The power is measured against the whole pot at the submission (`t.pot`: the author's share and every
    ///      top-up) in $YOLO plus the $YOLO add-on (`t.addon`); the share is paid on the pot and on the add-on.
    ///      `staked`: any power with a $YOLO price, also when the share floors to 0 bps (the staked split still applies).
    // slither-disable-next-line incorrect-equality
    function _stakeBps(SubmitTerms memory t, address doer, ParamsCore memory p)
        private
        view
        returns (uint16, bool staked)
    {
        // a hub without code, failing or answering anything but one word counts as no stake
        (bool ok, bytes memory ret) =
            address(doerStake).staticcall(abi.encodeCall(IDoerStake.powerAt, (doer, block.timestamp)));
        if (!ok || ret.length != 32) return (0, false);
        uint256 power = abi.decode(ret, (uint256));
        if (power == 0) return (0, false);
        // slither-disable-next-line uninitialized-local
        uint256 r;
        try DevPrices(p.devPrices).yoloValue(t.currency, t.pot) returns (uint256 y) {
            r = y;
        } catch {}
        if (r == 0) return (0, false); // no $YOLO price
        r += t.addon;
        return (uint16(power >= r ? MAX_STAKE_BONUS_BPS : MAX_STAKE_BONUS_BPS * power / r), true);
    }

    function _core(uint256 subId) private view returns (SubCore memory c) {
        Submission storage s = _subs[subId];
        Terms memory tm = _terms[subId];
        c.taskId = s.taskId;
        c.doer = s.doer;
        c.phase = s.phase;
        c.outcome = s.outcome;
        c.nftDecision = s.nftDecision;
        c.windowEnd = s.windowEnd;
        c.voteEnd = s.voteEnd;
        c.version = tm.version;
        c.currency = tm.currency;
        c.reward = s.reward;
        c.base = s.base;
        c.addon = s.addon;
    }
}
