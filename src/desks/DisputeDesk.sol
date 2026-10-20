// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ParamsCore} from "../VaultParams.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ParamsRegistry} from "../ParamsRegistry.sol";
import {VoteBook, VoterRec, VoteLib, IVotePower} from "../libraries/VoteLib.sol";
import {Desk} from "./Desk.sol";
import {SubCore, Facts, Tally, AppealCore, ICaseDesk, IVault, IDoerStake} from "./DeskApi.sol";
import "../VaultTypes.sol";

/// @dev YoloSweetener: a voter's share of a paid-out $YOLO bonus (anyone may trigger; money goes to payTo).
interface IVoterBonus {
    function claimVoter(uint256 taskId, address payTo) external;
}

/// @title DisputeDesk
/// @notice Disputes, the NFT votes (sent by the holders themselves), appeals and calls of the swarm, the money split
///         of a final submission and its lazy per-claimant payouts. The phases these actions move are kept by the
///         CaseDesk; the money is held by the vault.
contract DisputeDesk is Desk {
    /// @inheritdoc Desk
    function isCaseDesk() public pure override returns (bool) {
        return false;
    }

    mapping(uint256 => Dispute) internal _disputes;
    mapping(uint256 => mapping(address => DisputerInfo)) internal _disputerInfo;
    mapping(uint256 => Appeal) internal _appeals;
    mapping(uint256 => SideSpent) internal _sideSpent;
    mapping(uint256 => Settlement) internal _settlements;
    mapping(uint256 => VoteBook) internal _votes;

    /// @notice VotePower: who may vote with an NFT now, its owner or a delegate.xyz delegate.
    IVotePower public immutable votePower;
    /// @notice YoloLockHub: the doer's $YOLO lock behind the bonus of up to 4%; checked at the payout.
    IDoerStake public immutable doerStake;
    /// @notice $YOLO (a constructor argument of the launch plan; no bond has a $YOLO part).
    address public immutable yolo;

    constructor(
        address registry_,
        address imd_,
        address usdc_,
        address textRules_,
        address votePower_,
        address yolo_,
        address doerStake_
    ) Desk(registry_, imd_, usdc_, textRules_) {
        // the hub may be deployed after this desk in the same launch (LaunchPlan.core): no code check here
        votePower = IVotePower(votePower_);
        doerStake = IDoerStake(doerStake_);
        yolo = yolo_;
    }

    /// @dev `a += b`, per currency.
    function _addBond(Bond storage a, Bond memory b) private {
        a.imd += b.imd;
        a.rew += b.rew;
    }

    /// @dev Books a bond (fixed IMD + `extraImd` more IMD, its "rew" part in `currency`): the "rew" part merges
    ///      into the same collectImd call (and its swap mode) when R is already in IMD.
    function _collectBond(
        address sender,
        uint256 value,
        address currency,
        Bond memory b,
        uint256 extraImd,
        address swapAdapter,
        ImdPay calldata payIn
    ) private returns (uint256 ethNeeded) {
        IVault bank = _bank();
        bool rewIsImd = currency == address(imd);
        ethNeeded = bank.collectImd(sender, value, b.imd + extraImd + (rewIsImd ? b.rew : 0), swapAdapter, payIn);
        if (!rewIsImd) ethNeeded += bank.collectBondPart(sender, value, currency, b.rew);
    }

    // ================================================================== disputes and votes (through the vault)

    /// @notice Dispute the active submission inside its window: one dispute, one disputer —
    ///         whoever's transaction lands first; a second dispute
    ///         reverts, their money untouched (not its doer, who therefore can never answer an appeal as a disputer).
    ///         Bond 0.5 IMD fixed + 1% of the author's own reward in R's currency (no top-ups of others, no $YOLO
    ///         add-on), never doubled. No ETH fee: NFT votes cost
    ///         nothing to relay (the voter pays their own gas). The dispute starts the NFT vote (no doer
    ///         reply step: the doer argues once, with the submission).
    /// @param disputerProofUri the disputer's own link proving the submission fails
    ///        the rule, optional (empty allowed; non-empty: same text rule and byte cap as `reason`). Only a hash of both is stored; whoever later
    ///        calls the swarm resupplies them (RuleTexts), checked against it.
    function dispute(uint256 subId, string calldata reason, string calldata disputerProofUri, ImdPay calldata payIn)
        external
        routed
    {
        address sender = _sender();
        SubCore memory s = ICaseDesk(caseDesk).advanced(subId);
        Phase ph = s.phase;
        if (ph != Phase.Review && ph != Phase.Voting) revert WrongPhase();
        if (sender == s.doer) revert DoerCannotDispute(); // the doer never disputes his own submission
        if (s.windowEnd == 0 || block.timestamp >= s.windowEnd) revert WindowClosed();
        Dispute storage d = _disputes[subId];
        if (d.disputer != address(0)) revert AlreadyDisputed();
        ParamsCore memory p = _params(s.version);
        _checkText(reason, p);
        // the link is optional: empty passes and is left out of the swarm
        // question (SwarmQuestion._member skips empty values, so no "claim_N_proof" definition); a non-empty link
        // follows the same text rule as the reason.
        if (bytes(disputerProofUri).length != 0) _checkText(disputerProofUri, p);
        DisputerInfo storage info = _disputerInfo[subId][sender];

        Bond memory bond = _disputeBond(s.base, p);
        info.bond = bond;
        // 1 keccak256(abi.encode(...)) instead of 1 SSTORE string + a new string;
        // both texts stay in this call's calldata and the Disputed event below.
        info.reasonHash = keccak256(abi.encode(reason, disputerProofUri));
        d.disputer = sender;
        d.openBlock = uint32(block.number);
        _addBond(d.bondTotal, bond);

        if (ph == Phase.Review) ICaseDesk(caseDesk).startVote(subId, p.voteWindow);
        uint256 value = _value();
        uint256 ethNeeded = _collectBond(sender, value, s.currency, bond, 0, p.swapAdapter, payIn);
        _bank().settleValue(sender, value, ethNeeded);
        emit Disputed(subId, sender, bond.imd, bond.rew, reason, disputerProofUri);
    }

    /// @notice Cast an NFT vote with NFT ids, until the vote end: a vote by NFT id, with no registration. The
    ///         sender owns each id now or is a delegate.xyz delegate of its owner
    ///         (VotePower); each id votes once in a dispute (remembered here, an NFT passed on after its vote does not
    ///         vote again in it); the vote counts the number of ids, no snapshot, no registration. More transactions
    ///         for the same side add NFTs (many NFTs do not fit one block); the side cannot change. The voter
    ///         pays their own gas. The reward of the vote goes to `payTo`. After every vote, an instant decision is
    ///         tried once a side is ahead by instantDelta (CaseDesk.tryInstantDecision);
    ///         otherwise the NFT decides at the vote end (CaseDesk.step). No timers are played here: while the vote
    ///         runs, the task has no due step.
    // slither-disable-next-line unused-return
    function vote(uint256 subId, uint8 side, address payTo, uint256[] calldata tokenIds) external routed {
        (Phase ph, uint64 voteEnd, uint32 version) = ICaseDesk(caseDesk).voteState(subId);
        if (ph != Phase.Voting || block.timestamp >= voteEnd) revert WrongPhase();
        if ((side != VoteLib.SIDE_ACCEPT && side != VoteLib.SIDE_REJECT) || payTo == address(0)) revert BadVote();
        uint256 power = tokenIds.length;
        if (power == 0) revert NoTokens();
        address voter = _sender();
        VoteBook storage book = _votes[subId];
        VoterRec memory r = book.recs[voter];
        bool newWallet = r.side == 0;
        if (!newWallet && r.side != side) revert AlreadyVoted();
        // each id once per dispute: a repeat in the list or an id voted before reverts the whole vote
        for (uint256 i; i < power; ++i) {
            uint256 id = tokenIds[i];
            uint256 bit = 1 << (id & 0xff);
            uint256 word = book.votedIds[id >> 8];
            if (word & bit != 0) revert TokenVoted(id);
            book.votedIds[id >> 8] = word | bit;
        }
        uint256 bad = votePower.firstNotHeld(voter, tokenIds);
        if (bad != 0) revert NotTokenHolder(tokenIds[bad - 1]);
        Dispute storage d = _disputes[subId];
        r.side = side;
        if (voter == payTo) {
            if (side == VoteLib.SIDE_ACCEPT) r.accept += uint120(power);
            else r.reject += uint120(power);
        } else {
            VoterRec storage pr = book.recs[payTo];
            if (side == VoteLib.SIDE_ACCEPT) pr.accept += uint120(power);
            else pr.reject += uint120(power);
        }
        book.recs[voter] = r;
        emit VoteLib.VoteCounted(subId, voter, payTo, side, power);

        Tally memory v = _tally(d);
        // a wallet counts once, at its first vote in the dispute
        if (side == VoteLib.SIDE_ACCEPT) {
            v.accept += power;
            if (newWallet) ++v.walletsAccept;
        } else {
            v.reject += power;
            if (newWallet) ++v.walletsReject;
        }
        d.votesAccept = SafeCast.toUint32(v.accept);
        d.votesReject = SafeCast.toUint32(v.reject);
        d.walletsAccept = SafeCast.toUint32(v.walletsAccept);
        d.walletsReject = SafeCast.toUint32(v.walletsReject);
        // the same test as CaseDesk._decide: the case desk is called only when the vote can decide now
        if (v.accept != v.reject) {
            (,, uint32 instantDelta, uint32 minWallets) = ParamsRegistry(registry).voteParams(version);
            bool acceptWins = v.accept > v.reject;
            uint256 diff = acceptWins ? v.accept - v.reject : v.reject - v.accept;
            uint256 wallets = acceptWins ? v.walletsAccept : v.walletsReject;
            if (diff >= instantDelta && wallets >= minWallets) ICaseDesk(caseDesk).tryInstantDecision(subId, v);
        }
    }

    // ================================================================== appeals and calls of the swarm

    /// @notice Appeal an NFT decision within the appeal window (24h from the decision, or from the last silence
    ///         of the swarm). Anyone may appeal (the doer only a rejection of their submission); the appellant takes the
    ///         side opposite to the decision and pays a dispute bond plus the live swarm fee now. The question is
    ///         asked lazily, at the next call that carries it: `step`/`poke` cannot carry the resupplied text, so
    ///         the ask happens via the separate permissionless `askAppealSwarm`, not in this transaction.
    ///         `maxImdIn` caps bond + fee in IMD (with the bond's "rew" part when R is in IMD): the Intake price
    ///         may differ at call time. The doer or the
    ///         disputer appealing for their own side posts no second bond: the fee comes out of their dispute bond
    ///         (`_fundCall`).
    /// @dev No `reason` parameter: an appeal is a button, not
    ///      a text field. No `RuleTexts` here either: this call only files the appeal and funds
    ///      it; the text resupply + hash check happens later, in `askAppealSwarm`.
    function appeal(uint256 subId, uint256 maxImdIn, ImdPay calldata payIn) external routed {
        address sender = _sender();
        SubCore memory s = ICaseDesk(caseDesk).advanced(subId);
        if (s.phase != Phase.Decided) revert WrongPhase();
        // the doer may appeal a rejection, never their own acceptance (swarm audit 117cf05a #4, as DoerCannotDispute)
        bool sidesDoer = s.nftDecision == Verdict.Reject;
        if (sender == s.doer && !sidesDoer) revert DoerCannotDispute();
        ParamsCore memory p = _params(s.version);
        uint256 fee = _swarmPrice(p);
        if (fee == 0) revert ActionNotSold();
        Appeal storage a = _appeals[subId];
        a.appellant = sender;
        a.sidesDoer = sidesDoer;
        uint256 ethNeeded = _fundCall(a, subId, s, fee, maxImdIn, p, payIn);
        ICaseDesk(caseDesk).markAppealed(subId);
        _bank().settleValue(sender, _value(), ethNeeded);
        emit Appealed(subId, sender, a.bond.imd, a.bond.rew, fee);
    }

    /// @notice Lazy ask for a filed appeal: `appeal` above cannot carry the swarm's text
    ///         payload and ask at once in the same transaction, because the lazy step
    ///         (`CaseDesk.step`/`TaskVault.poke`) has no text channel (same limit every other lazy
    ///         transition already has). Anyone may call this once a submission sits in `Phase.Appealed`, resupplying
    ///         the task rules + the filed dispute's reason/proof link; `CaseDesk.askAppeal`/`_ask` check them against
    ///         the stored hashes and revert `RulesMismatch` otherwise.
    ///         The fee/bond were already fixed in `appeal`, this only spends them.
    // slither-disable-next-line unused-return
    function askAppealSwarm(uint256 subId, RuleTexts calldata rt) external routed {
        // play due timers first: an appeal not asked within swarmTimeout is void (CaseDesk.step), the late ask
        // then reverts WrongPhase in CaseDesk.askAppeal
        ICaseDesk(caseDesk).advanced(subId);
        Appeal storage a = _appeals[subId];
        uint256 funds = a.funds + a.fromBond; // read before the ask: a void question drops the caller below
        ICaseDesk(caseDesk).askAppeal(subId, funds, rt);
    }

    /// @notice The NFT did not decide (NoDecision window): anyone may call the swarm, paying the live fee plus a
    ///         dispute bond, and picks a side (the doer only their own). The swarm is asked at once with the disputes
    ///         and the doer's submission text. Win: the caller shares the loser bond as a winner (no separate fee refund:
    ///         the fee is not returned to them apart from that). Silence: the fee stays paid (the
    ///         bond is credited back) and a new window starts. Nobody calls: accepted, the disputer bonds to the doer.
    ///         The doer, or the disputer against the doer, calls out of their dispute bond (no second bond, `_fundCall`).
    /// @dev No `reason` parameter (same button-not-text rule as `appeal`). `rt`: this call asks the
    ///      swarm at once, in the same transaction, so the sender resupplies the task's rule texts and the filed
    ///      dispute's reason/proof link here, checked in `CaseDesk._ask` against
    ///      Task.rulesHash / DisputerInfo.reasonHash. `rt.disputeReason`/`rt.disputerProofUri` must match what the
    ///      disputer filed; the caller need not be the disputer themselves, only know what they filed (the `Disputed`
    ///      event).
    // slither-disable-next-line reentrancy-no-eth
    function callSwarm(uint256 subId, bool sidesDoer, uint256 maxImdIn, ImdPay calldata payIn, RuleTexts calldata rt)
        external
        routed
    {
        address sender = _sender();
        SubCore memory s = ICaseDesk(caseDesk).advanced(subId);
        if (s.phase != Phase.NoDecision) revert WrongPhase();
        if (sender == s.doer && !sidesDoer) revert DoerCannotDispute(); // swarm audit 117cf05a #4
        ParamsCore memory p = _params(s.version);
        uint256 price = _swarmPrice(p);
        if (price == 0) revert ActionNotSold();
        Appeal storage a = _appeals[subId];
        a.appellant = sender;
        a.sidesDoer = sidesDoer;
        uint256 ethNeeded = _fundCall(a, subId, s, price, maxImdIn, p, payIn);
        (bool ok, uint256 spent) = ICaseDesk(caseDesk).askEscalation(subId, price, rt);
        if (!ok) revert SwarmUnavailable();
        _charge(subId, a, spent);
        emit SwarmCalled(subId, sender, sidesDoer, a.bond.imd, a.bond.rew, price);
        _bank().settleValue(sender, _value(), ethNeeded);
    }

    /// @dev What the swarm caller `a.appellant` puts in for a question costing `fee`, collected now. A side of the
    ///      dispute calling for itself (the doer; the disputer against the doer) posts no second bond. Its first
    ///      call is paid out of its dispute bond's IMD, from its wallet only what that does not cover;
    ///      once its bond has paid the swarm, every later call of that side is paid wholly
    ///      from its wallet, still with no second bond. Anyone else posts
    ///      a dispute bond and pays the whole fee. At most `maxImdIn` IMD.
    function _fundCall(
        Appeal storage a,
        uint256 subId,
        SubCore memory s,
        uint256 fee,
        uint256 maxImdIn,
        ParamsCore memory p,
        ImdPay calldata payIn
    ) private returns (uint256 ethNeeded) {
        address sender = a.appellant;
        bool sidesDoer = a.sidesDoer;
        Dispute storage d = _disputes[subId];
        // slither-disable-next-line uninitialized-local
        Bond memory bond;
        // slither-disable-next-line uninitialized-local
        uint256 fromBond;
        if (sender == s.doer ? sidesDoer : sender == d.disputer && !sidesDoer) {
            SideSpent memory sp = _sideSpent[subId];
            // the bond pays the side's first call only (a void call spent nothing: the next one is still the first)
            if ((sidesDoer ? sp.doer : sp.disputer) == 0) {
                uint256 bondImd = sidesDoer ? ICaseDesk(caseDesk).doerBondImd(subId) : d.bondTotal.imd;
                fromBond = fee < bondImd ? fee : bondImd;
            }
        } else {
            bond = _disputeBond(s.base, p);
        }
        uint256 pay = fee - fromBond;
        // the bond's "rew" part is IMD too on an IMD task: _collectBond pulls it in the same collectImd call
        if (bond.imd + pay + (s.currency == address(imd) ? bond.rew : 0) > maxImdIn) revert CostAboveMax();
        a.bond = bond;
        a.fromBond = fromBond;
        a.funds = pay;
        ethNeeded = _collectBond(sender, _value(), s.currency, bond, pay, p.swapAdapter, payIn);
    }

    /// @dev The question was asked for `spent`: a side's own bond pays first, then the caller's prepaid fee.
    function _charge(uint256 subId, Appeal storage a, uint256 spent) private {
        uint256 fromBond = a.fromBond;
        uint256 own = spent < fromBond ? spent : fromBond;
        if (own != 0) {
            if (a.sidesDoer) _sideSpent[subId].doer += uint128(own);
            else _sideSpent[subId].disputer += uint128(own);
        }
        a.fromBond = 0;
        a.funds -= spent - own;
        a.spent = spent;
    }

    // No opponent-reply step on an appeal — it goes to the swarm at
    // once, with the doer's "why honest" text (Submission.doerNote, written at submission) read directly.

    // ================================================================== claims (through the vault)

    /// @notice Disputer: own bond back if the disputers won or the task was cancelled, plus a pro-rata share of the
    ///         won bonds. Treated like any other disputer whether or not they are also the task's author or a
    ///         contributor.
    function claimDisputer(uint256 subId) external routed {
        address sender = _sender();
        SubCore memory s = ICaseDesk(caseDesk).advanced(subId); // play due timers first: no separate poke needed
        if (s.phase != Phase.Final) revert NotFinal();
        DisputerInfo storage info = _disputerInfo[subId][sender];
        if (info.bond.imd == 0 || info.claimed) revert NothingToClaim();
        info.claimed = true;
        Settlement storage st = _settlements[subId];
        IVault bank = _bank();
        // slither-disable-next-line uninitialized-local
        Bond memory payout;
        if (st.neutral || st.disputersWon) {
            payout = info.bond;
            payout.imd -= _sideSpent[subId].disputer; // its own swarm calls (one dispute, one disputer)
        }
        if (st.disputersWon) {
            if (st.disputerRewardBonds.imd != 0) {
                uint256 share = st.disputerReward.imd * info.bond.imd / st.disputerRewardBonds.imd;
                st.disputerReward.imd -= share;
                st.disputerRewardBonds.imd -= info.bond.imd;
                payout.imd += share;
            }
            if (st.disputerRewardBonds.rew != 0) {
                uint256 share = st.disputerReward.rew * info.bond.rew / st.disputerRewardBonds.rew;
                st.disputerReward.rew -= share;
                st.disputerRewardBonds.rew -= info.bond.rew;
                payout.rew += share;
            }
        }
        emit DisputerClaimed(subId, sender, payout.imd, payout.rew);
        bank.pay(address(imd), sender, payout.imd);
        bank.pay(s.currency, sender, payout.rew);
    }

    /// @notice NFT voter reward for `payTo` (anyone may trigger; money goes to payTo). Only when the NFT decided
    ///         and the final outcome agrees: a share of the loser bonds (per currency) and of the reward fee
    ///         (reward currency), pro rata to the votes on the final side.
    function claimVoterReward(uint256 subId, address payTo) external routed {
        (, address currency, uint256 imdShare, uint256 rewShare,) = _claimVoter(subId, payTo, true);
        IVault bank = _bank();
        bank.pay(address(imd), payTo, imdShare);
        bank.pay(currency, payTo, rewShare);
    }

    /// @notice The voter rewards of `payTo` on many submissions in one transaction: every
    ///         submission with something to claim pays as claimVoterReward would; one without is skipped. Every
    ///         currency is paid once, summed. Reverts only when none of them had anything. An accepted submission
    ///         with a $YOLO add-on also claims `payTo`'s share of its paid-out bonus (YoloSweetener.claimVoter; skipped
    ///         if the bonus is not paid out yet or nothing is left for payTo there).
    // slither-disable-next-line reentrancy-no-eth
    function claimVoterRewards(uint256[] calldata subIds, address payTo) external routed {
        // slither-disable-next-line uninitialized-local
        uint256 imdTotal;
        address[] memory cur = new address[](subIds.length);
        uint256[] memory amt = new uint256[](subIds.length);
        // slither-disable-next-line uninitialized-local
        uint256 n;
        // slither-disable-next-line uninitialized-local
        bool any;
        // slither-disable-next-line uninitialized-local
        address sweet;
        for (uint256 i; i < subIds.length; ++i) {
            (bool ok, address currency, uint256 imdShare, uint256 rewShare, uint256 bonusTask) =
                _claimVoter(subIds[i], payTo, false);
            if (!ok) continue;
            if (bonusTask != 0) {
                if (sweet == address(0)) sweet = _bank().sweetener();
                // an add-on may come during the review (after the submission): ask the sweetener on every acceptance
                if (sweet.code.length != 0) try IVoterBonus(sweet).claimVoter(bonusTask, payTo) {} catch {}
            }
            any = true;
            imdTotal += imdShare;
            uint256 k;
            while (k < n && cur[k] != currency) ++k;
            if (k == n) cur[n++] = currency;
            amt[k] += rewShare;
        }
        if (!any) revert NothingToClaim();
        IVault bank = _bank();
        bank.pay(address(imd), payTo, imdTotal);
        for (uint256 k; k < n; ++k) {
            bank.pay(cur[k], payTo, amt[k]);
        }
    }

    /// @dev Books the voter reward of `payTo` on `subId`. Nothing to claim: reverts (NotFinal / NothingToClaim) when
    ///      `strict`, else returns ok = false. `rewShare` includes the reward-fee share (both in the reward currency).
    ///      `bonusTask`: the task id when the submission was accepted (a $YOLO add-on, if any, has a voter pool).
    function _claimVoter(uint256 subId, address payTo, bool strict)
        private
        returns (bool ok, address currency, uint256 imdShare, uint256 rewShare, uint256 bonusTask)
    {
        SubCore memory s = ICaseDesk(caseDesk).advanced(subId); // play due timers first: no separate poke needed
        if (s.phase != Phase.Final) {
            if (strict) revert NotFinal();
            return (false, address(0), 0, 0, 0);
        }
        Settlement storage st = _settlements[subId];
        VoterRec storage r = _votes[subId].recs[payTo];
        uint256 n = s.outcome == Outcome.Accepted ? r.accept : r.reject;
        uint256 left = st.voterVotesLeft;
        if (n == 0 || left == 0 || r.claimed != 0) {
            if (strict) revert NothingToClaim();
            return (false, address(0), 0, 0, 0);
        }
        r.claimed = 1;
        ok = true;
        imdShare = st.voterBond.imd * n / left;
        rewShare = st.voterBond.rew * n / left;
        uint256 feeShare = st.voterFee * n / left;
        st.voterBond.imd -= imdShare;
        st.voterBond.rew -= rewShare;
        st.voterFee -= feeShare;
        st.voterVotesLeft = left - n;
        emit VoterRewardClaimed(subId, payTo, n, imdShare, rewShare, feeShare);
        currency = s.currency;
        rewShare += feeShare;
        if (s.outcome == Outcome.Accepted) bonusTask = s.taskId;
    }

    // ================================================================== for the case desk and the question builder

    function tally(uint256 subId) external view returns (Tally memory) {
        return _tally(_disputes[subId]);
    }

    function appealCore(uint256 subId) external view returns (AppealCore memory c) {
        Appeal storage a = _appeals[subId];
        c.appellant = a.appellant;
        c.sidesDoer = a.sidesDoer;
        c.funds = a.funds + a.fromBond; // what the question may cost
    }

    /// @notice The one dispute reason + proof link (one dispute, one disputer), resupplied
    ///         by the caller of the swarm and checked against DisputerInfo.reasonHash
    ///         here, `RulesMismatch` otherwise. `maxClaims` bounds the parameters (the body size check);
    ///         this returns 0 or 1 claim. No `appealReason` (button
    ///         not text). No opponent-reply text — the doer's "why honest" (Submission.doerNote,
    ///         written at submission) is read by the question builder directly from the vault, not through here.
    function questionPart(uint256 subId, uint256 maxClaims, string calldata reason, string calldata disputerProofUri)
        external
        view
        returns (string[] memory claims, string[] memory claimProofs)
    {
        address disputer = _disputes[subId].disputer;
        uint256 n = disputer == address(0) || maxClaims == 0 ? 0 : 1;
        claims = new string[](n);
        claimProofs = new string[](n);
        if (n != 0) {
            if (keccak256(abi.encode(reason, disputerProofUri)) != _disputerInfo[subId][disputer].reasonHash) {
                revert RulesMismatch();
            }
            claims[0] = reason;
            claimProofs[0] = disputerProofUri;
        }
    }

    /// @notice The appeal question was asked: its price leaves the prepaid fee.
    function appealAsked(uint256 subId, uint256 spent) external only(caseDesk) {
        _charge(subId, _appeals[subId], spent);
    }

    /// @notice The caller's question was void or the swarm stayed silent: their bond and unspent fee are theirs again.
    // slither-disable-next-line reentrancy-no-eth
    function dropCaller(uint256 subId) external only(caseDesk) {
        _refundCaller(_appeals[subId], ICaseDesk(caseDesk).subCore(subId).currency);
        delete _appeals[subId];
    }

    /// @notice The money of a final submission: a cancellation (TaskVault.cancelTask) returns every bond; otherwise the reward is paid
    ///         (accepted) and the loser bonds are split (`_settleDecided`). Credits only; never transfers.
    // slither-disable-next-line reentrancy-no-eth
    function settle(uint256 subId, Outcome o, Facts calldata f) external only(caseDesk) {
        Settlement storage st = _settlements[subId];
        Dispute storage d = _disputes[subId];

        if (o == Outcome.Unwound) {
            st.neutral = true;
            _settleNeutral(subId, f);
        } else {
            ParamsCore memory p = _params(f.version);
            bool doerWins = o == Outcome.Accepted;
            // the NFT decided and the final outcome agrees with it
            bool nftRight = f.nftDecision != Verdict.None && (f.nftDecision == Verdict.Accept) == doerWins;
            if (nftRight) st.voterVotesLeft = doerWins ? d.votesAccept : d.votesReject;
            if (doerWins) _payReward(subId, f, nftRight, p);
            _settleDecided(subId, f, doerWins, nftRight, p);
        }
    }

    // ================================================================== views

    function getDispute(uint256 subId) external view returns (Dispute memory) {
        return _disputes[subId];
    }

    function getDisputer(uint256 subId, address who) external view returns (DisputerInfo memory) {
        return _disputerInfo[subId][who];
    }

    function getAppeal(uint256 subId) external view returns (Appeal memory) {
        return _appeals[subId];
    }

    function getSettlement(uint256 subId) external view returns (Settlement memory) {
        return _settlements[subId];
    }

    /// @notice IMD each side's own dispute bond already paid to the swarm for its calls (taken off what it gets back).
    function sideSpent(uint256 subId) external view returns (SideSpent memory) {
        return _sideSpent[subId];
    }

    function votesOf(uint256 subId, address payTo) external view returns (uint256 accept, uint256 reject) {
        VoterRec storage r = _votes[subId].recs[payTo];
        return (r.accept, r.reject);
    }

    function voterClaimed(uint256 subId, address payTo) external view returns (bool) {
        return _votes[subId].recs[payTo].claimed != 0;
    }

    /// @notice Whether `voter` already voted on a submission (then only for the same side again).
    function hasVoted(uint256 subId, address voter) external view returns (bool) {
        return _votes[subId].recs[voter].side != 0;
    }

    /// @notice The side `voter` voted on a submission: 0 none, 1 accept, 2 reject.
    function sideOf(uint256 subId, address voter) external view returns (uint8) {
        return _votes[subId].recs[voter].side;
    }

    /// @notice Whether NFT `tokenId` already voted on a submission (each id once per dispute).
    function tokenVoted(uint256 subId, uint256 tokenId) external view returns (bool) {
        return _votes[subId].votedIds[tokenId >> 8] & (1 << (tokenId & 0xff)) != 0;
    }

    // ================================================================== internal

    function _tally(Dispute storage d) private view returns (Tally memory) {
        return Tally(d.votesAccept, d.votesReject, d.walletsAccept, d.walletsReject);
    }

    /// @dev Cancelled by the dev wallet: every bond and unused prepayment back (disputers claim theirs with claimDisputer).
    ///      Swarm fees already paid stay paid.
    // slither-disable-next-line reentrancy-no-eth
    function _settleNeutral(uint256 subId, Facts calldata f) private {
        IVault bank = _bank();
        bank.credit(address(imd), f.doer, f.bond.imd - _sideSpent[subId].doer);
        bank.credit(f.currency, f.doer, f.bond.rew);
        Appeal storage a = _appeals[subId];
        if (a.appellant != address(0)) {
            _refundCaller(a, f.currency);
            a.funds = 0;
        }
    }

    /// @dev The swarm caller's bond and unspent prepaid fee are theirs again (credit).
    function _refundCaller(Appeal storage a, address currency) private {
        IVault bank = _bank();
        bank.credit(address(imd), a.appellant, a.bond.imd + a.funds);
        bank.credit(currency, a.appellant, a.bond.rew);
    }

    /// @dev The loser's bond (disputers, or the doer; plus a losing swarm caller) and the winner's bond, in one
    ///      currency: the loser's bond is split separately in each currency.
    ///      `doerBond`/`disputersBond`/`callerBond` are that currency's part of `f.bond` / `d.bondTotal` /
    ///      `a.bond`.
    function _penaltyAndWinnerBonds(
        bool doerWins,
        bool callerWins,
        bool hasCaller,
        uint256 doerBond,
        uint256 disputersBond,
        uint256 callerBond
    ) private pure returns (uint256 penalty, uint256 winnerBonds) {
        uint256 callerLost = hasCaller && !callerWins ? callerBond : 0;
        uint256 callerWon = hasCaller && callerWins ? callerBond : 0;
        if (doerWins) {
            penalty = disputersBond + callerLost;
            winnerBonds = doerBond + callerWon;
        } else {
            penalty = doerBond + callerLost;
            winnerBonds = disputersBond + callerWon;
        }
    }

    /// @dev Accepted or Rejected. The losing side's bonds (disputers, or the doer; plus a losing swarm caller) are
    ///      the penalty, split separately in each currency (IMD, the reward currency; no bond has a $YOLO add-on
    ///      part): no separate
    ///      refund of swarm fees.
    ///      - NFT decided right: winnerBondBps to the winning side pro rata to bonds, the rest to the correct votes;
    ///      - NFT wrong or undecided (also: undecided and nobody called the swarm): everything to the winning side.
    ///      Every winner gets their share, also one who put money into the task: the doer, an appellant or a disputer
    ///      who is its author or a contributor.
    // slither-disable-next-line reentrancy-no-eth
    function _settleDecided(uint256 subId, Facts calldata f, bool doerWins, bool nftRight, ParamsCore memory p)
        private
    {
        Dispute storage d = _disputes[subId];
        Appeal storage a = _appeals[subId];
        Settlement storage st = _settlements[subId];
        IVault bank = _bank();
        st.disputersWon = !doerWins;

        // a caller still recorded here got a swarm answer (silence clears them)
        bool hasCaller = a.appellant != address(0);
        bool callerWins = hasCaller && a.sidesDoer == doerWins;
        // a stranger appellant (not the doer, not the submission's one disputer)
        // who wins the appeal gets up to 0.5 IMD off the top of the loser's bond first (their swarm-call fee back),
        // only if something is left in the loser's IMD bond (it may have paid the loser's own unanswered call: then
        // nothing), the rest of the split follows as usual. Not a general fee refund (everyone else gets none).
        bool appellantIsStranger = hasCaller && a.appellant != f.doer && a.appellant != d.disputer;

        (uint256 penaltyImd, uint256 winnerBondsImd) =
            _penaltyAndWinnerBonds(doerWins, callerWins, hasCaller, f.bond.imd, d.bondTotal.imd, a.bond.imd);
        // the losing side's own swarm calls already went to the swarm out of its bond: the winner gets the rest;
        // the bonds as posted stay the weights of the split
        penaltyImd -= doerWins ? _sideSpent[subId].disputer : _sideSpent[subId].doer;
        (uint256 penaltyRew, uint256 winnerBondsRew) =
            _penaltyAndWinnerBonds(doerWins, callerWins, hasCaller, f.bond.rew, d.bondTotal.rew, a.bond.rew);

        if (appellantIsStranger && callerWins && penaltyImd != 0) {
            uint256 strangerFee = p.bondFixedImd > penaltyImd ? penaltyImd : p.bondFixedImd;
            penaltyImd -= strangerFee;
            bank.credit(address(imd), a.appellant, strangerFee);
        }

        uint256 toVotersImd;
        uint256 toTreasuryImd;
        (toVotersImd, toTreasuryImd, st.disputerReward.imd, st.disputerRewardBonds.imd) = _splitCurrency(
            f.doer,
            doerWins,
            a.appellant,
            callerWins,
            nftRight,
            p.winnerBondBps,
            penaltyImd,
            winnerBondsImd,
            a.bond.imd,
            d.bondTotal.imd,
            address(imd)
        );
        st.voterBond.imd = toVotersImd;
        bank.addTreasury(address(imd), toTreasuryImd);

        uint256 toVotersRew;
        uint256 toTreasuryRew;
        (toVotersRew, toTreasuryRew, st.disputerReward.rew, st.disputerRewardBonds.rew) = _splitCurrency(
            f.doer,
            doerWins,
            a.appellant,
            callerWins,
            nftRight,
            p.winnerBondBps,
            penaltyRew,
            winnerBondsRew,
            a.bond.rew,
            d.bondTotal.rew,
            f.currency
        );
        st.voterBond.rew = toVotersRew;
        bank.addTreasury(f.currency, toTreasuryRew);

        emit SubmissionSettled(
            subId,
            nftRight,
            penaltyImd,
            toVotersImd,
            toTreasuryImd,
            penaltyRew,
            toVotersRew,
            toTreasuryRew
        );

        // 3. direct credits: the winner's own bond back (doer, or the caller if they also won)
        if (doerWins) {
            bank.credit(address(imd), f.doer, f.bond.imd - _sideSpent[subId].doer);
            bank.credit(f.currency, f.doer, f.bond.rew);
        }
        if (hasCaller) {
            bank.credit(address(imd), a.appellant, a.funds + (callerWins ? a.bond.imd : 0));
            a.funds = 0;
            if (callerWins) {
                bank.credit(f.currency, a.appellant, a.bond.rew);
            }
        }
    }

    /// @dev Accepted: R - 10% to the doer, in the reward currency. Of the 10% fee: nftFeeBps (5%)
    ///      to the correct votes after a dispute the NFT decided right; the other 5% is the stakers' part. A doer
    ///      whose submission had a stake (`Facts.staked`; bonus `Facts.stakeBps`, 4% x min(1, power / (the whole reward + the $YOLO add-on at submission, in $YOLO)),
    ///      CaseDesk, may floor to 0 bps) and
    ///      whose lock still runs (YoloLockHub.stakePower) gets that share of R from that part, even if they put money
    ///      into this task themselves, the rest of it is
    ///      split half to the burn, half to the treasury, and the NFT 5% nobody earned is
    ///      burned. Without a stake both 5% go to the treasury. $YOLO the treasury gets goes to the
    ///      BuybackBurner. (The vault takes R out of the pot on closing.)
    function _payReward(uint256 subId, Facts calldata f, bool nftRight, ParamsCore memory p) private {
        uint256 r = f.reward;
        uint256 fee = r * p.feeBps / BPS;
        uint256 nftPart = r * p.nftFeeBps / BPS;
        uint256 toVoters = nftRight ? nftPart : 0;
        Settlement storage st = _settlements[subId];
        st.voterFee = toVoters;
        IVault bank = _bank();
        uint256 toTreasury = fee - toVoters;
        // slither-disable-next-line uninitialized-local
        uint256 bonus;
        uint256 bps = f.stakeBps;
        if (f.staked && _lockRuns(f)) {
            st.stakeBps = bps;
            uint256 stakers = fee - nftPart;
            bonus = r * bps / BPS;
            if (bonus > stakers) bonus = stakers;
            uint256 half = (stakers - bonus) / 2;
            toTreasury = stakers - bonus - half;
            bank.burn(f.currency, half + nftPart - toVoters);
        }
        bank.addTreasury(f.currency, toTreasury);
        bank.credit(f.currency, f.doer, r - fee + bonus);
    }

    /// @dev The lock behind the bonus still runs (never withdrawn since the submission). Never blocks a payout: a
    ///      hub that reverts, has no code or answers anything but one word counts as no stake.
    function _lockRuns(Facts calldata f) private view returns (bool) {
        (bool ok, bytes memory ret) =
            address(doerStake).staticcall(abi.encodeCall(IDoerStake.stakePower, (f.doer, f.since)));
        return ok && ret.length == 32 && abi.decode(ret, (uint256)) != 0;
    }

    /// @dev One currency's loser-penalty split: NFT share (if `nftRight`) carved out by the caller first, then the
    ///      doer (if they won, direct credit) or the disputers, bucketed for `claimDisputer`'s pro-rata share. Every
    ///      winner gets their share, a contributor to the task included.
    function _splitCurrency(
        address doer,
        bool doerWins,
        address appellant,
        bool callerWins,
        bool nftRight,
        uint16 winnerBondBps,
        uint256 penalty,
        uint256 winnerBonds,
        uint256 callerBond,
        uint256 disputersBondTotal,
        address token
    ) private returns (uint256 toVoters, uint256 toTreasury, uint256 disputerReward, uint256 disputerRewardBonds) {
        if (penalty == 0) return (0, 0, 0, 0);
        toVoters = nftRight ? penalty - penalty * winnerBondBps / BPS : 0;
        uint256 winnerShare = penalty - toVoters;
        if (winnerShare == 0) return (toVoters, 0, 0, 0);
        // the winning side has no bond in this currency (a tiny base: 1% of it rounded to 0): nobody to share the
        // dust with pro rata, so it goes to the treasury instead of staying stuck in the vault
        if (winnerBonds == 0) return (toVoters, winnerShare, 0, 0);
        uint256 appPart = callerWins ? winnerShare * callerBond / winnerBonds : 0;
        if (appPart != 0) _bank().credit(token, appellant, appPart);
        uint256 rest = winnerShare - appPart;
        if (doerWins) {
            if (rest != 0) _bank().credit(token, doer, rest);
        } else if (rest != 0 && disputersBondTotal != 0) {
            // every disputer gets their pro-rata share, author/contributor included; claimDisputer pays it lazily
            // per claimant
            disputerReward = rest;
            disputerRewardBonds = disputersBondTotal;
        }
    }
}
