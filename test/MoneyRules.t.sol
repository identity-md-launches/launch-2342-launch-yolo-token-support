// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Base, Ballot} from "./Base.t.sol";
import {Params} from "../src/VaultParams.sol";
import {YoloPredict} from "../src/YoloPredict.sol";
import {YoloSweetener} from "../src/YoloSweetener.sol";
import {ITaskVault} from "../src/interfaces/ITaskVault.sol";
import {TaskVault} from "../src/TaskVault.sol";
import {CaseDesk} from "../src/desks/CaseDesk.sol";
import {DisputeDesk} from "../src/desks/DisputeDesk.sol";
import {TextRules} from "../src/helpers/TextRules.sol";
import {SwarmQuestionBuilder} from "../src/helpers/SwarmQuestion.sol";
import {AttestationChecker} from "../src/helpers/AttestationChecker.sol";
import "../src/VaultTypes.sol";
import {rulesOf, rulesForehead, rulesSupermarket, TEST_RULE_PROOF, TEST_RULE_NO} from "./mocks/TaskRulesFixture.sol";

/// @notice One test per protocol money rule: the $100 examples to the wei, the reward minimums, the lock of the
///         reward, the bonds, the swarm calls, the doer stake, the burn and the treasury. Prices of Base: IMD $8,
///         ETH $2500, USDC $1, YOLO $0.0001; swarm fee 0.5 IMD; every bond has a fixed 0.5 IMD part.
/// forge-config: default.isolate = false
contract MoneyRulesTest is Base {
    uint8 internal constant ACCEPT = 1;
    uint8 internal constant REJECT = 2;
    /// @dev The whole 4% needs power worth the reward; $100 = 1M $YOLO at $0.0001.
    uint256 internal constant STAKE = 1_000_000e18;

    // ================================================================== helpers

    function _createRaw(address who, address currency, uint256 amount, uint64 deadline) internal returns (uint256 id) {
        vm.prank(who);
        id = vault.createTask{value: currency == ETH ? amount : 0}(
            currency,
            amount,
            deadline,
            "Title",
            rulesOf("ipfs://task-condition"),
            0,
            PROOF_LINK, // proof type is not what these money-rule tests check
            "",
            _noSwap()
        );
        trackedTasks.push(id);
    }

    /// @dev `who` locks `amount` $YOLO for `weeks_` weeks, then a second passes: the power of a lock counts only for
    ///      submissions in a later block (YoloLockHub.powerAt reads the lock strictly before the submission).
    function _lock(address who, uint256 amount, uint256 weeks_) internal {
        vm.prank(who);
        hub.lock(amount, weeks_);
        _warp(1);
    }

    /// @dev `amount` $YOLO for 52 weeks: power = amount (STAKE: the whole 4% on $100).
    function _stake(address who, uint256 amount) internal {
        _lock(who, amount, 52);
    }

    /// @dev Submission accepted without a dispute: 24 h window, poke.
    function _acceptQuietly(uint256 t) internal returns (uint256 s) {
        s = _submit(doer, t);
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Completed), "not completed");
    }

    /// @dev dave disputes, voter1 (20 NFT) votes `side`: decided at the vote end; the appeal window then runs out.
    function _disputeDecided(uint256 t, uint8 side) internal returns (uint256 s) {
        s = _submit(doer, t);
        _dispute(dave, s);
        _vote(s, 1, side, 120, 20);
        _endVote(s);
        assertEq(uint8(_phase(s)), uint8(Phase.Decided), "not decided");
    }

    function _finishAppealWindow(uint256 t) internal {
        _warp(24 hours);
        vault.poke(t);
    }

    // ================================================================== creation

    /// @notice the minimum reward is a dev parameter in the reward's
    ///         own currency (minRewardUsdc/Eth/Imd/Yolo), no conversion to dollars at creation.
    function test_MinRewardPerCurrency() public {
        uint64 dl = uint64(_now() + 7 days);
        vm.expectRevert(RewardTooSmall.selector);
        _createRaw(author, address(usdc), 5e6 - 1, dl);
        _createRaw(author, address(usdc), 5e6, dl);
        vm.expectRevert(RewardTooSmall.selector);
        _createRaw(author, ETH, 0.002e18 - 1, dl);
        _createRaw(author, ETH, 0.002e18, dl);
        vm.expectRevert(RewardTooSmall.selector);
        _createRaw(author, address(imd), 1e18 - 1, dl);
        _createRaw(author, address(imd), 1e18, dl);
        vm.expectRevert(RewardTooSmall.selector);
        _createRaw(author, address(yolo), 1_000e18 - 1, dl);
        _createRaw(author, address(yolo), 1_000e18, dl);
    }

    /// @notice no price is read at creation: a $YOLO task is created with no $YOLO price set for it at all.
    function test_NoPriceReadAtCreation() public {
        oracle.set(address(yolo), 0, 18);
        uint256 t = _createRaw(author, address(yolo), 1_000_000e18, uint64(_now() + 7 days));
        assertEq(vault.getTask(t).pot, 1_000_000e18);
    }

    /// @notice no creation fee: createTask takes no fee at all (no such argument) and no ETH for a USDC task.
    function test_NoCreationFee() public {
        _createRaw(author, address(usdc), 100e6, uint64(_now() + 7 days));
        assertEq(vault.treasuryPot(ETH), 0);
        assertEq(vault.liabilities(ETH), 0);
    }

    /// @notice a task without a deadline (or with one already passed) cannot be created.
    function test_DeadlineRequired() public {
        vm.expectRevert(BadDeadline.selector);
        _createRaw(author, address(usdc), 100e6, 0);
        vm.expectRevert(BadDeadline.selector);
        _createRaw(author, address(usdc), 100e6, uint64(_now()));
        uint256 t = _createRaw(author, address(usdc), 100e6, uint64(_now() + 1));
        assertEq(vault.getTask(t).createdAt, _now());
    }

    /// @notice the reward is locked until the deadline: neither the author nor a contributor takes anything back
    ///         before it (also while a submission made before the deadline is still judged after it); after the
    ///         expiry everyone takes back exactly his own.
    function test_RewardLockedUntilDeadline() public {
        uint64 dl = uint64(_now() + 3 days);
        uint256 t = _createRaw(author, address(usdc), 100e6, dl);
        _topUp(alice, t, 50e6);
        vm.prank(author);
        vm.expectRevert(TaskNotOpen.selector);
        vault.withdrawContribution(t);
        vm.prank(alice);
        vm.expectRevert(TaskNotOpen.selector);
        vault.withdrawContribution(t);

        // a submission just before the deadline, disputed and rejected after it: the reward stays locked meanwhile
        vm.warp(dl - 1 hours);
        uint256 s = _submit(doer, t);
        _dispute(dave, s);
        vm.warp(dl + 1);
        vm.prank(author);
        vm.expectRevert(TaskNotOpen.selector);
        vault.withdrawContribution(t);
        _vote(s, 1, REJECT, 120, 20);
        _endVote(s);
        _finishAppealWindow(t);
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Expired));

        uint256 a0 = usdc.balanceOf(author);
        uint256 b0 = usdc.balanceOf(alice);
        vm.prank(author);
        vault.withdrawContribution(t);
        vm.prank(alice);
        vault.withdrawContribution(t);
        assertEq(usdc.balanceOf(author) - a0, 100e6);
        assertEq(usdc.balanceOf(alice) - b0, 50e6);
        _claimEverythingAndCheck();
    }

    /// @notice no limits, neither on one task's reward
    ///         nor on the sum of open tasks - a $10,000,000 reward is created fine, and so is an uncapped top-up.
    function test_NoCap_LargeRewardOpenTotalAndTopUp() public {
        uint64 dl = uint64(_now() + 2 days);
        uint256 t = _createRaw(author, address(usdc), 900_000e6, dl); // a large reward is created fine
        assertEq(vault.getTask(t).pot, 900_000e6);
        for (uint256 i; i < 19; ++i) {
            // 19 x $50,000 = $950,000 open at once
            _createRaw(doer, address(usdc), 50_000e6, uint64(_now() + 30 days));
        }
        vm.prank(alice);
        vault.topUp(t, 90_000e6, _noSwap()); // no cap on a top-up either
        assertEq(vault.getTask(t).pot, 990_000e6);
    }

    /// @notice the $YOLO add-on has no cap, and
    ///         neither it nor the reward's own size limits the other.
    function test_NoAddonLimit() public {
        uint256 t = _create(author, address(usdc), 25e6);
        vm.prank(alice);
        sweetener.sweeten(t, 9_000_000e18);
        vm.prank(alice);
        vault.topUp(t, 10_000e6, _noSwap()); // no cap on the reward either, add-on already large
        assertEq(vault.getTask(t).pot, 10_025e6);
        vm.prank(bob);
        sweetener.sweeten(t, 9_000_000e18); // no cap on the add-on either
        assertEq(sweetener.bonusOf(t), 18_000_000e18);
    }

    /// @notice The add-on counts only once the vault bound its sweetener (the registry owner, once): an unbound or a
    ///         second sweetener takes no deposits, and nobody else can bind.
    function test_SweetenerBoundOnceByTheOwner() public {
        assertEq(vault.sweetener(), address(sweetener));
        vm.prank(multisig);
        vm.expectRevert(WrongWiring.selector);
        vault.bindSweetener(address(sweetener));
        YoloSweetener other = new YoloSweetener(address(vault));
        uint256 t = _create(author, address(usdc), 25e6);
        vm.prank(alice);
        vm.expectRevert(YoloSweetener.NotBound.selector);
        other.sweeten(t, 1e18);
        vm.prank(alice);
        vm.expectRevert(NotAuthorized.selector);
        vault.bindSweetener(address(other));
    }

    // ================================================================== submission

    /// @notice the doer bond is 0.5 IMD fixed + 3% of the reward in the reward's own currency.
    ///         No oracle, no $5 floor: a $100 reward bonds 0.5 IMD + 3 USDC.
    function test_DoerBond_FixedImdPlusThreePercent() public {
        uint256 small = _create(author, address(usdc), 100e6);
        uint256 large = _create(author, address(usdc), 1_000e6);
        Bond memory qSmall = vault.quoteSubmission(small);
        assertEq(qSmall.imd, _fixedBond());
        assertEq(qSmall.rew, 3e6, "3% of $100");
        Bond memory qLarge = vault.quoteSubmission(large);
        assertEq(qLarge.imd, _fixedBond());
        assertEq(qLarge.rew, 30e6, "3% of $1,000");
        uint256 s = _submit(doer, small);
        assertEq(_sub(s).bond.imd, _fixedBond());
        assertEq(_sub(s).bond.rew, 3e6);
    }

    /// @notice No escalation. The percent part of the bond
    ///         stays 3% of R for every submission, queued or after a rejection; the fixed IMD part never doubled
    ///         either way.
    function test_NoDoubling_SameBondForEverySubmission() public {
        uint256 t = _create(author, address(usdc), 20e6); // 3% = 0.6
        uint256 s1 = _submit(doer, t);
        uint256 s2 = _submit(doer2, t); // queued, one ahead
        uint256 s3 = _submit(doer3, t); // queued, two ahead
        uint256 s4 = _submit(bob, t); // queued, three ahead
        assertEq(_sub(s1).bond.rew, 0.6e6);
        assertEq(_sub(s2).bond.rew, 0.6e6, "no doubling for a submission queued behind another");
        assertEq(_sub(s3).bond.rew, 0.6e6);
        assertEq(_sub(s4).bond.rew, 0.6e6);
        assertEq(_sub(s1).bond.imd, _fixedBond());
        assertEq(_sub(s4).bond.imd, _fixedBond(), "fixed part unaffected either way");
    }

    /// @notice the $YOLO add-on is no part of any bond; the bonds are 3%/1% of the author's reward only.
    function test_BondsIgnoreTheAddon() public {
        uint256 t = _create(author, address(usdc), 25e6);
        Bond memory q0 = vault.quoteSubmission(t);
        assertEq(q0.rew, 0.75e6, "3% of $25");
        vm.prank(alice);
        sweetener.sweeten(t, 1_000_000e18);
        Bond memory q1 = vault.quoteSubmission(t);
        assertEq(q1.imd, _fixedBond());
        assertEq(q1.rew, 0.75e6, "unchanged by the add-on");
        uint256 y0 = yolo.balanceOf(doer);
        uint256 s = _submit(doer, t);
        assertEq(yolo.balanceOf(doer), y0, "no $YOLO bond");
        assertEq(_sub(s).bond.imd, _fixedBond());
        assertEq(_sub(s).bond.rew, 0.75e6);
        assertEq(vault.quoteDisputeBond(s).rew, 0.25e6, "1% of the author's $25");
        // no escalation: a submission queued behind another pays the same bond
        uint256 s2 = _submit(doer2, t);
        assertEq(_sub(s2).bond.rew, 0.75e6);
    }

    /// @notice no mandatory swarm check at any reward: a $1,000 task is accepted after the 24 h window and the
    ///         swarm is never asked.
    function test_NoMandatorySwarmCheck() public {
        uint256 t = _create(author, address(usdc), 1_000e6);
        uint256 n0 = intake.nonce();
        uint256 s = _submit(doer, t);
        assertEq(uint8(_phase(s)), uint8(Phase.Review));
        assertEq(_sub(s).windowEnd, _now() + 24 hours);
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Completed));
        assertEq(intake.nonce(), n0, "the swarm was asked");
        assertEq(vault.credits(address(usdc), doer), 900e6 + 30e6, "90% plus his rew bond back");
    }

    // ================================================================== dispute

    /// @notice the dispute bond is 0.5 IMD fixed + 1% of the reward in the reward's own currency, never doubled.
    ///         No oracle, no $5 floor: a $100 reward disputes at 0.5 IMD + 1 USDC.
    function test_DisputeBond_FixedImdPlusOnePercent() public {
        uint256 s1 = _submit(doer, _create(author, address(usdc), 100e6));
        uint256 s2 = _submit(doer, _create(author, address(usdc), 1_000e6));
        Bond memory q1 = vault.quoteDisputeBond(s1);
        assertEq(q1.imd, _fixedBond());
        assertEq(q1.rew, 1e6, "1% of $100");
        Bond memory q2 = vault.quoteDisputeBond(s2);
        assertEq(q2.imd, _fixedBond());
        assertEq(q2.rew, 10e6, "1% of $1,000");
    }

    /// @notice The $100 reward example: the doer bonds 0.5 IMD + 3 USDC, the disputer
    ///         who loses bonds 0.5 IMD + 1 USDC and forfeits it to the doer (tie: NFT did not decide).
    function test_Example_HundredDollarReward() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        assertEq(_sub(s).bond.imd, _fixedBond(), "Alice: -0.5 IMD");
        assertEq(_sub(s).bond.rew, 3e6, "Alice: -3 USDC");
        _dispute(dave, s);
        assertEq(vault.getDisputer(s, dave).bond.imd, _fixedBond(), "Bob: -0.5 IMD");
        assertEq(vault.getDisputer(s, dave).bond.rew, 1e6, "Bob: -1 USDC");
        uint256 doerUsdcBefore = vault.credits(address(usdc), doer);
        _endVote(s); // NFT did not decide (nobody voted)
        _finishAppealWindow(t); // nobody called the swarm: NFT did not decide, accepted, disputer bond to the doer
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Completed));
        assertEq(
            vault.credits(address(usdc), doer) - doerUsdcBefore,
            90e6 + 3e6 + 1e6,
            "reward 90% + his own rew bond back + Bob's forfeited bond"
        );
    }

    /// @notice the NFT did not decide and nobody called the swarm: accepted, and the disputers' bonds go 100% to
    ///         the doer, nothing to the treasury.
    /// @dev one dispute, one disputer - dave alone.
    function test_Tie_DoerTakesEveryDisputerBond() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        _dispute(dave, s);
        _endVote(s);
        assertEq(uint8(_phase(s)), uint8(Phase.NoDecision));
        _finishAppealWindow(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        // no $5 floor, the fixed IMD part is always 0.5 IMD (_fixedBond()).
        assertEq(vault.credits(address(imd), doer), _fixedBond() * 2, "own bond + dave's disputer bond");
        assertEq(vault.treasuryPot(address(imd)), 0);
        assertEq(
            vault.credits(address(usdc), doer), 90e6 + 3e6 + 1e6, "90% + his rew bond back + dave's forfeited rew bond"
        );
        _claimEverythingAndCheck();
    }

    /// @notice no swarm fee is ever
    ///         refunded, silent or answered, winner or loser - two silences and a "yes", all three paid by the
    ///         doer as their own appellant. one dispute, one disputer (dave alone).
    function test_NoSwarmFeeRefund_ThreeCallsByTheDoer() public {
        uint256 t = _create(author, address(usdc), 1_000e6); // bonds: doer 3.75, dispute 1.25
        uint256 s = _submit(doer, t);
        _dispute(dave, s);
        _endVote(s);
        uint256 before = imd.balanceOf(doer);
        for (uint256 i; i < 2; ++i) {
            _callSwarm(doer, s, true);
            _silent(s);
            vault.poke(t);
            assertEq(uint8(_phase(s)), uint8(Phase.NoDecision), "silence: back to the window");
        }
        _callSwarm(doer, s, true);
        _answer(s, true);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        vm.prank(doer);
        vault.withdraw(address(imd));
        // the fixed IMD part of every bond/fee is flat 0.5 IMD, not scaled by the reward (no $5
        // floor). The doer paid 3 x (0.5 dispute bond + 0.5 fee) = 3 IMD calling the swarm as their own
        // appellant (none of the three fees ever come back): the two silent calls return their own bond right
        // away (2 x 0.5), the third (answered, doer wins as the caller) returns its own bond at settlement (0.5)
        // plus his original 0.5 submission bond again, and dave's whole forfeited bond (0.5 IMD) on top (doer is
        // not a stranger appellant - he is the doer himself, no 0.5 IMD carve-out applies). Net: -3 (calls'
        // bonds + fees) + 0.5*2 (silent bonds back) + 0.5 (third call's own bond) + 0.5 (submission bond) + 0.5
        // (dave's whole bond) = -3 + 2.5 = -0.5, the three fees (1.5 IMD) minus dave's one forfeited bond (0.5).
        assertEq(imd.balanceOf(doer), before - 0.5e18, "fees never refunded; only dave's forfeited bond comes back");
        _claimEverythingAndCheck();
    }

    /// @notice at most 3 swarm questions per submission; after the third silence it ends as if nobody had
    ///         called: NFT undecided -> accepted, the disputer bonds to the doer.
    function test_ThirdSilence_EndsAsWithoutCall_Undecided() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        _dispute(dave, s);
        _endVote(s);
        for (uint256 i; i < 3; ++i) {
            _callSwarm(dave, s);
            _silent(s);
            vault.poke(t);
        }
        assertEq(uint8(_phase(s)), uint8(Phase.Final), "closed right after the third silence");
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        assertEq(_sub(s).asks, 3);
        assertEq(
            vault.credits(address(usdc), doer), 90e6 + 3e6 + 1e6, "90% + his rew bond back + dave's forfeited rew bond"
        );
        _claimEverythingAndCheck();
    }

    /// @notice the same with an NFT decision: after the third silent appeal the NFT decision stands.
    function test_ThirdSilence_EndsAsWithoutCall_Decided() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _disputeDecided(t, REJECT);
        for (uint256 i; i < 3; ++i) {
            _appeal(doer, s);
            _warp(1 hours); // asked inside swarmTimeout (6 h): a later ask finds the appeal void
            _askAppealSwarm(s); // lazy ask
            _silent(s);
            vault.poke(t);
        }
        assertEq(uint8(_phase(s)), uint8(Phase.Final));
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Rejected));
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Open), "fake: the reward stays in the task");
        _claimEverythingAndCheck();
    }

    /// @notice an appeal made void because the Intake failed or its price rose counts towards
    ///         the 3 questions like a silent one: after the third void appeal the NFT decision stands, final.
    function test_VoidAppealsCountTowardsThree() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _disputeDecided(t, REJECT);
        for (uint256 i; i < 3; ++i) {
            assertEq(uint8(_phase(s)), uint8(Phase.Decided));
            _appeal(doer, s);
            _warp(1 hours); // asked inside swarmTimeout (6 h): a later ask finds the appeal void
            intake.setBroken(true);
            _askAppealSwarm(s); // void: bond and fee back to the doer (lazy ask)
            intake.setBroken(false);
            assertEq(_sub(s).asks, i + 1);
        }
        assertEq(uint8(_phase(s)), uint8(Phase.Final), "closed right after the third void appeal");
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Rejected));
        _claimEverythingAndCheck();
    }

    // ================================================================== where the money goes, reward $100

    function _treasuryAfterSweep(address token) internal returns (uint256) {
        vault.sweepTreasury(token);
        return vault.credits(token, treasury);
    }

    /// @notice accepted without a dispute, no stake: doer $90 + his 3 USDC bond back, treasury $10.
    function test_NoDispute_NoStake() public {
        uint256 t = _create(author, address(usdc), 100e6);
        _acceptQuietly(t);
        assertEq(vault.credits(address(usdc), doer), 90e6 + 3e6);
        assertEq(_treasuryAfterSweep(address(usdc)), 10e6);
        assertEq(usdc.balanceOf(address(burner)), 0);
        _claimEverythingAndCheck();
    }

    /// @notice accepted without a dispute, doer's lock worth the reward (1M $YOLO for a year): doer $94 + his 3
    ///         USDC bond back, burner $5.50 (half of the stakers' 1% left after the 4% bonus, plus the NFT 5% nobody
    ///         earned), treasury $0.50.
    function test_NoDispute_Staked() public {
        _stake(doer, STAKE);
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _acceptQuietly(t);
        assertEq(vault.getSettlement(s).stakeBps, 400);
        assertEq(vault.credits(address(usdc), doer), 94e6 + 3e6);
        assertEq(usdc.balanceOf(buybackWallet), 5.5e6);
        assertEq(usdc.balanceOf(address(burner)), 0, "autosent, nothing waits in the burner");
        assertEq(_treasuryAfterSweep(address(usdc)), 0.5e6);
        _claimEverythingAndCheck();
    }

    /// @notice disputed, the NFT decided right, accepted, no stake: doer $90 + his 3 USDC bond back, NFT $5,
    ///         treasury $5; the disputer's bond 50/50 to the doer and the correct votes.
    function test_NftRight_NoStake() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _disputeDecided(t, ACCEPT);
        _finishAppealWindow(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        assertEq(vault.credits(address(usdc), doer), 90e6 + 3e6 + 0.5e6, "90% of R, his bond, half of dave's rew bond");
        vault.claimVoterReward(s, voters[1]);
        assertEq(usdc.balanceOf(voters[1]) - 1_000_000e6, 5e6 + 0.5e6, "the 5% reward fee plus half of dave's rew bond");
        assertEq(imd.balanceOf(voters[1]) - 10_000e18, 0.25e18, "half of dave's 0.5 IMD fixed bond");
        assertEq(vault.credits(address(imd), doer), _fixedBond() + 0.25e18, "his fixed bond back + half of dave's");
        assertEq(_treasuryAfterSweep(address(usdc)), 5e6);
        _claimEverythingAndCheck();
    }

    /// @notice disputed, the NFT decided right, doer at full stake power: doer $94 + bond + half of dave's rew bond,
    ///         NFT $5, burner $0.50, treasury $0.50.
    function test_NftRight_Staked() public {
        _stake(doer, STAKE);
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _disputeDecided(t, ACCEPT);
        _finishAppealWindow(t);
        assertEq(vault.credits(address(usdc), doer), 94e6 + 3e6 + 0.5e6);
        vault.claimVoterReward(s, voters[1]);
        assertEq(usdc.balanceOf(voters[1]) - 1_000_000e6, 5e6 + 0.5e6, "the 5% reward fee plus half of dave's rew bond");
        assertEq(usdc.balanceOf(buybackWallet), 0.5e6);
        assertEq(usdc.balanceOf(address(burner)), 0, "autosent, nothing waits in the burner");
        assertEq(_treasuryAfterSweep(address(usdc)), 0.5e6);
        _claimEverythingAndCheck();
    }

    /// @notice the NFT was wrong (rejected) and the swarm accepted on appeal: the NFT get nothing; their 5% go to
    ///         the treasury (no stake) or the burner (stake). The doer also gets his bond and the appellant's winning
    ///         share of the disputer's rew bond back (he is the winning appellant here).
    function test_NftWrong_SwarmAccepts() public {
        _stake(doer2, STAKE);
        // no stake
        uint256 t1 = _create(author, address(usdc), 100e6);
        uint256 s1 = _disputeDecided(t1, REJECT);
        _appeal(doer, s1);
        _warp(1 hours); // asked inside swarmTimeout (6 h): a later ask finds the appeal void
        _askAppealSwarm(s1); // lazy ask
        _answer(s1, true);
        vault.poke(t1);
        assertEq(uint8(_sub(s1).outcome), uint8(Outcome.Accepted));
        // the doer appeals out of their own bond (no second bond): their bond and dave's whole rew
        // penalty (no other winner to share it with) come back to him
        assertEq(vault.credits(address(usdc), doer), 90e6 + 3e6 + 1e6, "90% of R, his bond, dave's rew penalty");
        assertEq(vault.getSettlement(s1).voterFee, 0);
        assertEq(vault.treasuryPot(address(usdc)), 10e6);
        // stake
        uint256 t2 = _create(author, address(usdc), 100e6);
        uint256 s2 = _submit(doer2, t2);
        _dispute(dave, s2);
        _vote(s2, 1, REJECT, 120, 20);
        _endVote(s2);
        _appeal(doer2, s2);
        _warp(1 hours); // asked inside swarmTimeout (6 h): a later ask finds the appeal void
        _askAppealSwarm(s2); // lazy ask
        _answer(s2, true);
        vault.poke(t2);
        assertEq(vault.credits(address(usdc), doer2), 94e6 + 3e6 + 1e6, "90%+stake, his bond, dave's rew penalty");
        assertEq(usdc.balanceOf(buybackWallet), 5.5e6, "half of 1% + the NFT 5% the wrong NFT did not earn");
        assertEq(usdc.balanceOf(address(burner)), 0, "autosent, nothing waits in the burner");
        assertEq(vault.treasuryPot(address(usdc)), 10e6 + 0.5e6);
        _claimEverythingAndCheck();
    }

    /// @notice rejected (fake): the reward stays in the task, which stays open; the doer's bond is split 50/50
    ///         between the disputer and the correct votes (after the swarm fee and gas, none here).
    function test_Fake_RewardStaysTaskOpen() public {
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _disputeDecided(t, REJECT);
        _finishAppealWindow(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Rejected));
        Task memory tk = vault.getTask(t);
        assertEq(uint8(tk.status), uint8(TaskStatus.Open));
        assertEq(tk.pot, 100e6);
        assertEq(vault.credits(address(usdc), doer), 0);
        uint256 d0 = imd.balanceOf(dave);
        vm.prank(dave);
        vault.claimDisputer(s);
        // NFT right: his own 0.5 IMD bond back + half of the doer's 0.5 IMD penalty (the other half to the votes)
        assertEq(imd.balanceOf(dave) - d0, _fixedBond() + _fixedBond() / 2);
        _claimEverythingAndCheck();
    }

    /// @notice the deadline passed and nobody did it: the whole reward back to the author.
    function test_Expired_AuthorGetsAllBack() public {
        uint256 t = _createWithDeadline(author, address(usdc), 100e6, uint64(_now() + 1 days));
        _warp(1 days);
        vault.poke(t);
        uint256 a0 = usdc.balanceOf(author);
        vm.prank(author);
        vault.withdrawContribution(t);
        assertEq(usdc.balanceOf(author) - a0, 100e6);
    }

    /// @notice a $YOLO reward: what the treasury would get is burned at once: 10% to
    ///         0x...dEaD without a stake, 6% at full stake power (4% to the doer); the treasury pot never holds $YOLO.
    function test_YoloReward_TreasuryShareBurned() public {
        uint256 t1 = _create(author, address(yolo), 1_000_000e18); // $100
        uint256 dead0 = yolo.balanceOf(address(burner));
        _acceptQuietly(t1);
        assertEq(vault.credits(address(yolo), doer), 900_000e18 + 30_000e18, "90% of R + his 3% rew bond back");
        assertEq(yolo.balanceOf(address(burner)) - dead0, 100_000e18);
        assertEq(vault.treasuryPot(address(yolo)), 0);

        _stake(doer, STAKE);
        uint256 t2 = _create(author, address(yolo), 1_000_000e18);
        dead0 = yolo.balanceOf(address(burner));
        _acceptQuietly(t2);
        assertEq(
            vault.credits(address(yolo), doer),
            900_000e18 + 30_000e18 + 940_000e18 + 30_000e18,
            "t1's 90%+bond plus t2's 94%+bond"
        );
        assertEq(yolo.balanceOf(address(burner)) - dead0, 60_000e18);
        assertEq(vault.treasuryPot(address(yolo)), 0);
        _claimEverythingAndCheck();
    }

    /// @notice the $YOLO bonus of a task follows the reward's
    ///         rule, with no cap at all: 90% to the doer, the rest burned (the treasury's $YOLO), 5% to the correct
    ///         NFT votes after a dispute they decided right; with a full stake the doer gets 4% more.
    function test_YoloBonus_SameRuleAsReward() public {
        uint256 t1 = _create(author, address(usdc), 100e6);
        vm.prank(alice);
        sweetener.sweeten(t1, 9_000_000e18); // no cap, not even combined with the $100 reward
        _acceptQuietly(t1);
        uint256 d0 = yolo.balanceOf(doer);
        uint256 dead0 = yolo.balanceOf(address(burner));
        sweetener.payout(t1);
        assertEq(yolo.balanceOf(doer) - d0, 8_100_000e18);
        assertEq(yolo.balanceOf(address(burner)) - dead0, 900_000e18);

        // NFT decided right, doer at full stake power (2M, the author's $100 needs 1M): 94% doer, 5% votes,
        // 1% burned
        _stake(doer2, 2 * STAKE);
        uint256 t2 = _create(author, address(usdc), 100e6);
        vm.prank(bob);
        sweetener.sweeten(t2, 1_000_000e18);
        uint256 s2 = _submit(doer2, t2);
        _dispute(dave, s2);
        _vote(s2, 1, ACCEPT, 120, 20);
        _endVote(s2);
        _finishAppealWindow(t2);
        d0 = yolo.balanceOf(doer2);
        dead0 = yolo.balanceOf(address(burner));
        sweetener.payout(t2);
        assertEq(yolo.balanceOf(doer2) - d0, 940_000e18);
        assertEq(yolo.balanceOf(address(burner)) - dead0, 10_000e18);
        uint256 v0 = yolo.balanceOf(voters[1]);
        sweetener.claimVoter(t2, voters[1]);
        assertEq(yolo.balanceOf(voters[1]) - v0, 50_000e18);
        assertEq(yolo.balanceOf(address(sweetener)), 0);
    }

    /// @notice the $YOLO bonus is locked like the reward and goes back to whoever put it in after the expiry.
    function test_YoloBonus_LockedUntilExpiry() public {
        uint256 t = _createWithDeadline(author, address(usdc), 100e6, uint64(_now() + 2 days));
        vm.prank(alice);
        sweetener.sweeten(t, 1_000e18);
        vm.prank(alice);
        vm.expectRevert(bytes4(keccak256("BonusLocked()")));
        sweetener.withdraw(t);
        _warp(2 days);
        vault.poke(t);
        uint256 a0 = yolo.balanceOf(alice);
        vm.prank(alice);
        sweetener.withdraw(t);
        assertEq(yolo.balanceOf(alice) - a0, 1_000e18);
    }

    // ================================================================== YOLO Predict (entry split; the rest in YoloPredict tests)

    /// @notice a position of 100 YOLO: 5 burn, 5 wait, 90 in the pool; the task done -> 2.5 to the author and
    ///         2.5 to the doer straight from YoloPredict (no fee).
    function test_Predict_Entry_5_5_90_And_Deferred_2_5_Each() public {
        YoloPredict predict = new YoloPredict(address(vault), 1e18);
        uint256 t = _create(author, address(usdc), 100e6); // no cap on positions
        vm.startPrank(erin);
        yolo.approve(address(predict), type(uint256).max);
        uint256 dead0 = yolo.balanceOf(DEAD);
        predict.predict(t, true, 100_000e18);
        vm.stopPrank();
        assertEq(yolo.balanceOf(DEAD) - dead0, 0, "the 5% burn is held until the outcome");
        assertEq(predict.burnHeld(t), 5_000e18);
        (,, uint256 willDo,,,, uint256 deferred) = predict.markets(t);
        assertEq(willDo, 90_000e18);
        assertEq(deferred, 5_000e18);
        _acceptQuietly(t);
        uint256 a0 = yolo.balanceOf(author);
        uint256 d0 = yolo.balanceOf(doer);
        predict.settle(t);
        assertEq(yolo.balanceOf(author) - a0, 2_500e18);
        assertEq(yolo.balanceOf(doer) - d0, 2_500e18);
        assertEq(yolo.balanceOf(DEAD) - dead0, 5_000e18, "the 5% burned at settle");
        vm.prank(erin);
        predict.claim(t);
        assertEq(yolo.balanceOf(address(predict)), 0);
    }

    // ================================================================== doer stake

    /// @notice b = 4% x min(1, power / R in $YOLO), the power fixed at the lock.
    ///         $100 USDC examples: power worth $100 (1M for a year) -> $94 / burn $0.50 (+ NFT $5) /
    ///         treasury $0.50; worth $50 (1M for half a year) -> $92 / $1.50 (+ $5) / $1.50; worth $5 (50k for a year)
    ///         -> 0.2%: $90.20 / $2.40 (+ $5) / $2.40, no threshold. 250k for 13 weeks
    ///         (62,500 = $6.25) -> 0.25%.
    function test_WorkedExamples() public {
        _lock(doer, STAKE, 52);
        uint256 s1 = _acceptQuietly(_create(author, address(usdc), 100e6));
        assertEq(vault.getSettlement(s1).stakeBps, 400);
        assertEq(vault.credits(address(usdc), doer), 94e6 + 3e6, "94% plus his rew bond back");
        assertEq(usdc.balanceOf(buybackWallet), 0.5e6 + 5e6);
        assertEq(vault.treasuryPot(address(usdc)), 0.5e6);

        _lock(doer2, STAKE, 26);
        uint256 t2 = _create(author, address(usdc), 100e6);
        uint256 s2 = _submit(doer2, t2);
        _warp(24 hours);
        vault.poke(t2);
        assertEq(vault.getSettlement(s2).stakeBps, 200);
        assertEq(vault.credits(address(usdc), doer2), 92e6 + 3e6, "92% plus his rew bond back");
        assertEq(usdc.balanceOf(buybackWallet), 5.5e6 + 1.5e6 + 5e6);
        assertEq(usdc.balanceOf(address(burner)), 0, "autosent, nothing waits in the burner");
        assertEq(vault.treasuryPot(address(usdc)), 0.5e6 + 1.5e6);

        _lock(doer3, 50_000e18, 52);
        uint256 t3 = _create(author, address(usdc), 100e6);
        uint256 s3 = _submit(doer3, t3);
        _warp(24 hours);
        vault.poke(t3);
        // stake 5% of the reward (50k of 1M YOLO): no threshold, bonus 0.2% = $0.20
        assertEq(vault.getSettlement(s3).stakeBps, 20);
        assertEq(vault.credits(address(usdc), doer3), 90.2e6 + 3e6, "90.2% plus his rew bond back");
        assertEq(usdc.balanceOf(buybackWallet), 5.5e6 + 1.5e6 + 5e6 + 2.4e6 + 5e6, "half of the 4.8% left + the NFT 5%");
        assertEq(vault.treasuryPot(address(usdc)), 2e6 + 2.4e6);

        _lock(bob, 250_000e18, 13);
        uint256 t4 = _create(author, address(usdc), 100e6);
        uint256 s4 = _submit(bob, t4);
        _warp(24 hours);
        vault.poke(t4);
        assertEq(vault.getSettlement(s4).stakeBps, 25, "62,500 of 1M: 6.25% of the reward, 0.25%");
        assertEq(vault.credits(address(usdc), bob), 90.25e6 + 3e6, "90.25% plus his rew bond back");
        _claimEverythingAndCheck();
    }

    /// @notice the power does not fall: a year's lock 40 weeks in still gives the whole 4%; locked after the
    ///         submission = no bonus; added after the submission = only what stood before counts.
    function test_PowerFixed_SubmissionMomentCounts() public {
        _lock(doer, STAKE, 52);
        _warp(40 weeks);
        uint256 s1 = _acceptQuietly(_create(author, address(usdc), 100e6));
        assertEq(vault.getSettlement(s1).stakeBps, 400);

        uint256 t2 = _create(author, address(usdc), 100e6);
        uint256 s2 = _submit(doer3, t2);
        _lock(doer3, STAKE, 52);
        _warp(24 hours);
        vault.poke(t2);
        assertEq(vault.getSettlement(s2).stakeBps, 0, "locked after the submission");

        _lock(bob, STAKE / 2, 52);
        uint256 t3 = _create(author, address(usdc), 100e6);
        uint256 s3 = _submit(bob, t3);
        _lock(bob, STAKE, 0);
        _warp(24 hours);
        vault.poke(t3);
        assertEq(vault.getSettlement(s3).stakeBps, 200, "what stood before the submission");
        assertEq(vault.credits(address(usdc), bob), 92e6 + 3e6, "92% plus his rew bond back");
    }

    /// @notice the lock must still run at the payout: 13M for one week (power 250k, 1%) ends before the 24 h
    ///         window does: no bonus.
    function test_LockEndedBeforePayout_NoBonus() public {
        yolo.mint(doer, 13_000_000e18);
        _lock(doer, 13_000_000e18, 1);
        assertEq(hub.power(doer), 250_000e18);
        _warp(6 days);
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        assertEq(_sub(s).stakeBps, 100);
        _warp(24 hours);
        vault.poke(t);
        assertEq(vault.getSettlement(s).stakeBps, 0, "the lock ended a day before the payout");
        assertEq(vault.credits(address(usdc), doer), 90e6 + 3e6, "90% plus his rew bond back");
        vm.prank(doer);
        hub.withdraw();
        assertEq(yolo.balanceOf(address(hub)), 0);
    }

    /// @notice the lock that gave the power must still run at the payout: taking it back after its end and
    ///         locking 1 wei again (another epoch) does not keep the bonus.
    function test_WithdrawnAndRelocked_NoBonus() public {
        yolo.mint(doer, 13_000_000e18);
        _lock(doer, 13_000_000e18, 1);
        _warp(6 days);
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        assertEq(_sub(s).stakeBps, 100);
        _warp(1 days); // the lock ended
        vm.startPrank(doer);
        hub.withdraw();
        hub.lock(1, 1); // a new lock, epoch 1
        vm.stopPrank();
        _warp(1 hours);
        vault.poke(t);
        assertEq(vault.getSettlement(s).stakeBps, 0, "the lock of the submission was withdrawn");
        assertEq(vault.credits(address(usdc), doer), 90e6 + 3e6, "90% plus his rew bond back");
    }

    /// @notice a doer who put money into the task gets the bonus as usual,
    ///         topping up after the submission included.
    function test_ContributorAfterSubmission_GetsBonus() public {
        _stake(doer, STAKE);
        uint256 t = _create(author, address(usdc), 100e6);
        uint256 s = _submit(doer, t);
        assertEq(_sub(s).stakeBps, 400);
        _topUp(doer, t, 5e6); // during their own check: in the reward at once, R = 105
        _warp(24 hours);
        vault.poke(t);
        assertEq(vault.getSettlement(s).stakeBps, 400);
        assertEq(vault.credits(address(usdc), doer), 98.7e6 + 3e6, "94% (90% + 4% stake) of 105 plus his rew bond back");
        assertEq(vault.treasuryPot(address(usdc)), 0.525e6, "treasury half of the 1% left");
    }

    /// @notice one lock gives its full power to every concurrent submission of the doer at
    ///         once, not split between them: two $100 tasks at the same time, each gets the whole 4%.
    function test_OneLock_FullPowerOnEveryConcurrentSubmission() public {
        _stake(doer, STAKE); // power 1M = one $100 reward in $YOLO
        uint256 t1 = _create(author, address(usdc), 100e6);
        uint256 t2 = _create(author, address(usdc), 100e6);
        uint256 s1 = _submit(doer, t1);
        uint256 s2 = _submit(doer, t2);
        assertEq(_sub(s1).stakeBps, 400);
        assertEq(_sub(s2).stakeBps, 400, "the same lock, the whole 4% again");
        _warp(24 hours);
        vault.poke(t1);
        vault.poke(t2);
        assertEq(vault.credits(address(usdc), doer), 2 * (94e6 + 3e6), "94% plus his bond back, on both");
    }

    /// @notice a fake does not touch the stake (the bond is the penalty).
    function test_FakeLeavesStakeAlone() public {
        _stake(doer, STAKE);
        uint256 t = _create(author, address(usdc), 100e6);
        _disputeDecided(t, REJECT);
        _finishAppealWindow(t);
        (uint96 locked,,) = hub.locks(doer);
        assertEq(locked, STAKE);
        assertEq(yolo.balanceOf(address(hub)), STAKE);
    }

    /// @notice no fixed threshold: the same lock is the whole 4% on $100, 0.4% on $1,000; the
    ///         reward in USDC is converted at the DevPrices $YOLO price (`yoloValue`; no pool is read, so a trade
    ///         cannot raise the share): at half the price $100 = 2M $YOLO, 1M of power = 2%.
    function test_RelativeToTheReward_LowestPrice() public {
        _stake(doer, STAKE);
        uint256 s1 = _acceptQuietly(_create(author, address(usdc), 1_000e6));
        assertEq(vault.getSettlement(s1).stakeBps, 40);
        assertEq(vault.credits(address(usdc), doer), 904e6 + 30e6, "904 plus his rew bond back (3% of 1,000)");
        oracle.setYolo(address(yolo), 0.00005e18);
        uint256 s2 = _acceptQuietly(_create(author, address(usdc), 100e6));
        assertEq(vault.getSettlement(s2).stakeBps, 200);
        assertEq(vault.credits(address(usdc), doer), 904e6 + 30e6 + 92e6 + 3e6, "plus both rew bonds back");
        // no $YOLO price at all: no bonus, the USDC task is paid as without a stake
        oracle.setYolo(address(yolo), 0);
        oracle.set(address(yolo), 0, 18);
        uint256 s3 = _acceptQuietly(_create(author, address(usdc), 100e6));
        assertEq(vault.getSettlement(s3).stakeBps, 0);
    }

    /// @notice the power is measured against the pot plus the $YOLO add-on: $100 + a $100 add-on with 2M of
    ///         power = the whole 4%, paid on the reward ($94) and on the add-on (900k + 40k $YOLO); 1M of power on
    ///         the same task = 2%.
    function test_AddonInPowerBase() public {
        _stake(doer, 2 * STAKE);
        uint256 t = _create(author, address(usdc), 100e6);
        vm.prank(alice);
        sweetener.sweeten(t, 1_000_000e18);
        uint256 s = _acceptQuietly(t);
        assertEq(vault.getSettlement(s).stakeBps, 400);
        assertEq(vault.credits(address(usdc), doer), 94e6 + 3e6, "94% plus his rew bond back");
        uint256 b0 = yolo.balanceOf(doer);
        sweetener.payout(t);
        assertEq(yolo.balanceOf(doer) - b0, 940_000e18);
        _stake(doer2, STAKE);
        uint256 t2 = _create(author, address(usdc), 100e6);
        vm.prank(alice);
        sweetener.sweeten(t2, 1_000_000e18);
        assertEq(_sub(_submit(doer2, t2)).stakeBps, 200, "1M against $100 (1M) + the 1M add-on");
    }

    /// @notice the stake check never blocks a submission or a payout: a vault whose hub address has no code (a
    ///         deployment mistake) pays as without a stake instead of reverting.
    function test_HubWithoutCode_PaysAsWithoutStake() public {
        TextRules text = new TextRules();
        address r = address(registry);
        CaseDesk cd = new CaseDesk(
            r,
            address(imd),
            address(usdc),
            address(text),
            address(new SwarmQuestionBuilder()),
            address(yolo),
            address(0xBEEF)
        );
        DisputeDesk dd = new DisputeDesk(
            r, address(imd), address(usdc), address(text), address(votePower), address(yolo), address(0xBEEF)
        );
        ITaskVault v = ITaskVault(
            address(
                new TaskVault(
                    r,
                    address(imd),
                    address(usdc),
                    address(yolo),
                    address(new AttestationChecker(r)),
                    address(text),
                    address(cd),
                    address(dd),
                    address(burner)
                )
            )
        );
        vm.startPrank(author);
        usdc.approve(address(v), type(uint256).max);
        uint256 t = v.createTask(
            address(usdc), 100e6, uint64(_now() + 7 days), "T", rulesOf("ipfs://c"), 0, PROOF_LINK, "", _noSwap()
        );
        vm.stopPrank();
        vm.startPrank(doer);
        imd.approve(address(v), type(uint256).max);
        usdc.approve(address(v), type(uint256).max);
        uint256 s = v.submit(t, "https://x.com/doer/status/1", _noEvidence(), 0, type(uint256).max, _noSwap());
        vm.stopPrank();
        _warp(24 hours);
        v.poke(t);
        assertEq(uint8(v.getSubmission(s).outcome), uint8(Outcome.Accepted));
        assertEq(v.getSettlement(s).stakeBps, 0);
        assertEq(v.credits(address(usdc), doer), 90e6 + 3e6, "90% plus his rew bond back");
    }

    // ================================================================== burner

    /// @notice the burner contract has no owner, swaps nothing and sends $YOLO only to 0x...dEaD (ETH, USDC, IMD
    ///         only to the buyback wallet): anyone may burn the $YOLO it holds.
    function test_Burner_NoOwner_AnyoneBurns() public {
        (bool ok,) = address(burner).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok, "owner()");
        yolo.mint(address(burner), 123e18);
        uint256 dead0 = yolo.balanceOf(DEAD);
        vm.prank(makeAddr("anyone"));
        burner.burnYolo();
        assertEq(yolo.balanceOf(DEAD) - dead0, 123e18);
        assertEq(yolo.balanceOf(address(burner)), 0);
    }

    /// @notice the autosend tries the buyback wallet first, then the burner itself; if both pushes fail the
    ///         amount stays a credit in the vault, and anyone pulls it into the burner.
    function test_Burner_PullsFailedPush() public {
        _stake(doer, STAKE);
        usdc.setBlocked(buybackWallet, true);
        usdc.setBlocked(address(burner), true);
        uint256 t = _create(author, address(usdc), 100e6);
        _acceptQuietly(t);
        assertEq(vault.credits(address(usdc), address(burner)), 5.5e6);
        usdc.setBlocked(buybackWallet, false);
        usdc.setBlocked(address(burner), false);
        burner.pull(address(vault), address(usdc));
        assertEq(usdc.balanceOf(address(burner)), 5.5e6);
        _claimEverythingAndCheck();
    }

    // ================================================================== treasury

    /// @notice the treasury gets only its share, in the reward currency, and pays for nothing; confiscated bonds
    ///         without a winner do not exist (no mandatory check), so a rejection gives it nothing.
    function test_TreasuryGetsOnlyItsShare() public {
        uint256 t = _createRaw(author, ETH, 0.04 ether, uint64(_now() + 7 days)); // $100
        _acceptQuietly(t);
        assertEq(_treasuryAfterSweep(ETH), 0.004 ether);
        uint256 t2 = _create(author, address(usdc), 100e6);
        _disputeDecided(t2, REJECT);
        _finishAppealWindow(t2);
        assertEq(vault.treasuryPot(address(imd)), 0);
        assertEq(vault.treasuryPot(address(usdc)), 0);
        _claimEverythingAndCheck();
    }
}
