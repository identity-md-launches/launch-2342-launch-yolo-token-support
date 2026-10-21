// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";

import {Base} from "../Base.t.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {YoloSweetener} from "../../src/YoloSweetener.sol";
import {ITaskVault} from "../../src/interfaces/ITaskVault.sol";
import {TaskVault} from "../../src/TaskVault.sol";
import "../../src/VaultTypes.sol";
import {rulesOf, rulesForehead, rulesSupermarket, TEST_RULE_PROOF, TEST_RULE_NO} from "../mocks/TaskRulesFixture.sol";

/// @dev "Sweeten and the YOLO price" (YoloSweetener).
/// `test_Guard_*` hold what was checked and found sound.
/// forge-config: default.isolate = false
contract ReviewSweetenerTest is Base {
    uint8 internal constant REJECT = 2;

    function _sweeten(address who, uint256 taskId, uint256 amount) internal {
        vm.prank(who);
        sweetener.sweeten(taskId, amount);
    }

    /// No mandatory swarm check
    /// and no cap at all: the whole bonus goes by the
    /// reward's rule, uncapped, neither alone nor combined with the reward. The
    /// bond counts the add-on separately, in $YOLO itself, not merged in USD with the reward: 3% of the $25 ETH
    /// reward plus, on its own, 3% of the $YOLO add-on.
    function test_Rule_AddonBondsSeparatelyInYolo_NoCap() public {
        uint256 tBig = _create(author, ETH, 0.01 ether); // $25
        vm.prank(alice);
        sweetener.sweeten(tBig, 900_000_000e18); // $90,000: no cap at all, not even combined with the reward
        assertEq(sweetener.bonusOf(tBig), 900_000_000e18);

        uint256 t = _create(author, ETH, 0.01 ether); // $25
        uint256 bonus = 9_750_000e18; // $975 on a $25 task: no combined limit
        _sweeten(alice, t, bonus);
        vm.prank(bob);
        sweetener.sweeten(t, 1e18); // no cap: a further top-up goes through too
        bonus += 1e18;

        uint256 s = _submit(doer, t);
        Submission memory sub = _sub(s);
        assertEq(sub.addon, bonus, "the vault sees the $975 add-on");
        assertEq(sub.bond.imd, _fixedBond());
        assertEq(sub.bond.rew, _bondOf(0.01 ether), "3% of the ETH reward, in ETH");
        // the add-on is no part of the bond, whatever its size
        assertEq(sub.request, bytes32(0), "no swarm question");

        vm.warp(sub.windowEnd);
        vault.poke(t);
        uint256 before = yolo.balanceOf(doer);
        uint256 dead0 = yolo.balanceOf(address(burner));
        vm.expectEmit(address(sweetener));
        emit YoloSweetener.BonusPaid(t, s, doer, 8_775_000.9e18, 0, 975_000.1e18);
        sweetener.payout(t);
        assertEq(yolo.balanceOf(doer) - before, 8_775_000.9e18, "90% of all of it");
        assertEq(yolo.balanceOf(address(burner)) - dead0, 975_000.1e18, "the fee burned");
        assertEq(sweetener.bonusOf(t), 0, "nothing waits for the sweetener");
        vm.expectRevert(YoloSweetener.NothingToPay.selector);
        sweetener.payout(t);
        vm.prank(alice);
        vm.expectRevert(YoloSweetener.BonusLocked.selector);
        sweetener.withdraw(t);
        _claimEverythingAndCheck();
    }

    /// The bonus is locked like the reward, so there is nothing to pull at all
    /// before the deadline; the doer gets the bonus they saw.
    function test_Guard_bonusCannotBePulledBeforeTheDeadline() public {
        uint256 t = _create(author, ETH, 0.01 ether);
        _sweeten(alice, t, 2_000_000e18);
        assertEq(sweetener.bonusOf(t), 2_000_000e18, "what the doer sees on the card");

        vm.prank(alice); // ahead of the doer's transaction: refused
        vm.expectRevert(YoloSweetener.BonusLocked.selector);
        sweetener.withdraw(t);

        uint256 s = _submit(doer, t);
        _warp(1 hours);
        vm.prank(alice);
        vm.expectRevert(YoloSweetener.BonusLocked.selector);
        sweetener.withdraw(t);
        vm.warp(_sub(s).windowEnd);
        vault.poke(t);
        uint256 before = yolo.balanceOf(doer);
        sweetener.payout(t);
        assertEq(yolo.balanceOf(doer) - before, 1_800_000e18, "the doer gets the bonus he saw, minus the fee");
        _claimEverythingAndCheck();
    }

    /// The module plays the task's timers first
    /// (`vault.poke`, like TaskVault.topUp), so it never acts on a stale stored status. Past the deadline but not
    /// yet poked: nobody adds, everyone takes his own back. Accepted by the timer but not yet played: no new add-on
    /// gets in (the task is decided), nobody takes his back, and the payout works without a separate poke.
    function test_Guard_sweetenPlaysTheTimersFirst_NoAddonIntoADecidedTask() public {
        uint256 d = _createWithDeadline(author, ETH, 0.01 ether, uint64(_now() + 1 days));
        _sweeten(alice, d, 10e18);
        _warp(1 days + 1); // effectively expired, stored Open
        assertEq(uint8(vault.getTask(d).status), uint8(TaskStatus.Open), "stored status still Open");
        vm.prank(alice);
        vm.expectRevert(YoloSweetener.TaskNotOpen.selector);
        sweetener.sweeten(d, 10e18); // past the deadline nobody adds
        vm.prank(alice);
        sweetener.withdraw(d);
        assertEq(sweetener.bonusOf(d), 0);

        uint256 t = _create(author, ETH, 0.01 ether);
        _sweeten(alice, t, 10e18);
        uint256 s = _submit(doer, t);
        vm.warp(_sub(s).windowEnd + 1); // accepted by the timer, not played yet
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Open), "stored status still Open");
        vm.prank(bob);
        vm.expectRevert(YoloSweetener.TaskNotOpen.selector);
        sweetener.sweeten(t, 5e18); // the task is decided: no new add-on (and no top-up either)
        vm.prank(bob);
        vm.expectRevert(TaskNotOpen.selector);
        vault.topUp{value: 0.001 ether}(t, 0.001 ether, _noSwap());
        vm.prank(alice);
        vm.expectRevert(YoloSweetener.BonusLocked.selector);
        sweetener.withdraw(t);
        sweetener.payout(t); // plays the acceptance itself
        assertEq(yolo.balanceOf(address(sweetener)), 0);
        _claimEverythingAndCheck();
    }

    /// A rejected submission with one queued behind it: the vault activates the next one in the same transaction,
    /// so there is no moment with the task open and idle, and the bonus goes to the second doer only (the payout
    /// takes the accepted submission from the task).
    function test_Guard_rejectionWithAQueueLeavesNoWithdrawGap() public {
        uint256 t = _create(author, ETH, 0.01 ether);
        _sweeten(alice, t, 1_000e18);
        uint256 s1 = _submit(doer, t);
        uint256 s2 = _submit(doer2, t); // queued
        _dispute(dave, s1);
        _vote(s1, 0, REJECT, 0, 120);
        _endVote(s1); // NFT decision at the vote end
        _warp(24 hours); // appeal window over: rejected, the queued one activated in the same call
        vault.poke(t);
        assertEq(uint8(_sub(s1).outcome), uint8(Outcome.Rejected));
        assertEq(vault.getTask(t).activeSub, s2, "the queued one is active at once");
        vm.prank(alice);
        vm.expectRevert(YoloSweetener.BonusLocked.selector);
        sweetener.withdraw(t);
        vm.expectRevert(YoloSweetener.NotAccepted.selector);
        sweetener.payout(t); // s2 under review

        vm.warp(_sub(s2).windowEnd);
        vault.poke(t);
        assertEq(vault.getTask(t).activeSub, s2);
        uint256 before = yolo.balanceOf(doer2);
        uint256 before1 = yolo.balanceOf(doer);
        sweetener.payout(t);
        assertEq(yolo.balanceOf(doer2) - before, 900e18);
        assertEq(yolo.balanceOf(doer), before1, "the rejected doer gets nothing");
        vm.expectRevert(YoloSweetener.NothingToPay.selector);
        sweetener.payout(t);
        _claimEverythingAndCheck();
    }

    /// Re-entry from the only push in a submission (the excess-ETH refund, sent while the vault holds its lock):
    /// `withdraw` and `payout` both play the timers first (`vault.poke`), which the vault's lock refuses inside
    /// the refund; the bonus stays.
    function test_Guard_reentryFromTheEthRefundIsLocked() public {
        uint256 t = _create(author, ETH, 0.01 ether);
        ReentrantDoer bad = new ReentrantDoer(vault, sweetener, t);
        imd.mint(address(bad), 100e18);
        // he needs 1,000e18 to sweeten; his doer bond has no $YOLO part
        yolo.mint(address(bad), 1_000e18);
        bad.prepare(address(imd), address(yolo));
        bad.sweetenAndSubmit{value: 1 ether}(1_000e18); // all of the ETH comes back: refunded by a push
        assertEq(
            bad.withdrawError(), TaskVault.ReentrancyGuardReentrantCall.selector, "withdraw inside the refund: locked"
        );
        assertEq(
            bad.payoutError(), TaskVault.ReentrancyGuardReentrantCall.selector, "payout inside the refund: refused"
        );
        assertEq(sweetener.bonusOf(t), 1_000e18);
        assertEq(yolo.balanceOf(address(sweetener)), 1_000e18);

        vm.warp(_sub(bad.subId()).windowEnd);
        vault.poke(t);
        uint256 dead0 = yolo.balanceOf(address(burner));
        sweetener.payout(t);
        assertEq(yolo.balanceOf(address(bad)), 900e18, "paid once, 10% fee");
        assertEq(yolo.balanceOf(address(burner)) - dead0, 100e18, "the fee burned");
        assertEq(yolo.balanceOf(treasury), 0);
    }

    /// The module takes only the vault and reads the vault's registry and $YOLO (no CaseDesk link), so no
    /// launch argument can give it a foreign token or another registry's treasury.
    function test_Guard_moduleTakesTokenAndRegistryFromTheVault() public {
        YoloSweetener fresh = new YoloSweetener(address(vault));
        assertEq(address(fresh.yolo()), vault.yolo(), "the vault's YOLO");
        assertEq(address(fresh.registry()), vault.registry(), "the vault's registry");
        assertEq(address(fresh.vault()), address(vault));
        vm.expectRevert(YoloSweetener.ZeroAddress.selector);
        new YoloSweetener(address(0));
    }

    /// Payout after the tie rule (no NFT decision, nobody called the swarm: accepted) works like any acceptance; the
    /// NFT decided nothing, so its 5% burns with the rest of the fee.
    function test_Guard_tieAcceptancePaysTheBonus() public {
        uint256 t = _create(author, ETH, 0.01 ether);
        _sweeten(bob, t, 100e18);
        uint256 s = _submit(doer, t);
        _dispute(dave, s);
        _warp(24 hours); // vote window over without votes
        vault.poke(t);
        _warp(24 hours); // nobody called the swarm
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        uint256 d0 = yolo.balanceOf(doer);
        uint256 dead0 = yolo.balanceOf(address(burner));
        sweetener.payout(t);
        assertEq(sweetener.bonusOf(t), 0);
        assertEq(yolo.balanceOf(doer) - d0, 90e18);
        assertEq(yolo.balanceOf(address(burner)) - dead0, 10e18);
        _claimEverythingAndCheck();
    }
}

/// @dev A doer contract that re-enters the sweetener from the ETH refund of its own `submit`.
contract ReentrantDoer {
    ITaskVault immutable vault;
    YoloSweetener immutable sw;
    uint256 immutable taskId;
    uint256 public subId;
    bytes4 public withdrawError;
    bytes4 public payoutError;
    bool armed;

    constructor(ITaskVault v, YoloSweetener s, uint256 t) {
        vault = v;
        sw = s;
        taskId = t;
    }

    function prepare(address imd, address yolo) external {
        MockERC20(imd).approve(address(vault), type(uint256).max);
        MockERC20(yolo).approve(address(sw), type(uint256).max);
        // (an allowance to the vault too: no bond has an add-on part, so the vault pulls no $YOLO)
        MockERC20(yolo).approve(address(vault), type(uint256).max);
    }

    function sweetenAndSubmit(uint256 amount) external payable {
        sw.sweeten(taskId, amount);
        armed = true;
        ImdPay memory none;
        subId = vault.submit{value: msg.value}(
            taskId, "https://x.com/doer/status/1", Evidence("", ""), 0, type(uint256).max, none
        );
        armed = false;
    }

    receive() external payable {
        if (!armed) return;
        armed = false;
        try sw.withdraw(taskId) {}
        catch (bytes memory e) {
            withdrawError = bytes4(e);
        }
        try sw.payout(taskId) {}
        catch (bytes memory e) {
            payoutError = bytes4(e);
        }
    }
}

/// @dev What the vault does with every state of the YOLO price (MockPriceOracle as DevPrices).
/// There is no oracle: DevPrices is a dev parameter, not a sampled TWAP, so there is no sample window or floor
/// to attack, and the bond never reads a price at all.
/// forge-config: default.isolate = false
contract ReviewYoloStrictTest is Base {
    /// The bond needs no oracle at all, so a vanished (or never set) $YOLO price
    /// cannot surprise the doer; his quote holds whatever DevPrices does meanwhile.
    function test_Guard_PriceVanishingAfterTheQuoteDoesNotAffectTheSubmission() public {
        uint256 t = _create(author, address(yolo), 1_000_000e18); // $100 at the Base price
        Bond memory bond = vault.quoteSubmission(t);
        assertEq(bond.rew, _bondOf(1_000_000e18), "3% of R, in $YOLO itself: no USD floor");
        oracle.set(address(yolo), 0, 18); // the dev never set a price for it
        vm.prank(doer);
        uint256 s = vault.submit(t, "https://x.com/doer/status/1", _noEvidence(), 0, bond.rew, _noSwap());
        assertEq(_sub(s).bond.rew, bond.rew);
    }

    /// The bond reads
    /// no price, so a DevPrices that reverts still lets a submission through unaffected.
    function test_Guard_RevertingDevPricesDoesNotAffectTheSubmission() public {
        uint256 t = _create(author, address(yolo), 1_000_000e18);
        vm.mockCallRevert(address(oracle), abi.encodeWithSignature("usdValue(address,uint256)"), "down");
        uint256 s = _submit(doer, t); // no revert: the bond quote never calls usdValue
        vm.clearMockedCalls();
        assertEq(_sub(s).reward, 1_000_000e18);
        assertEq(_sub(s).bond.rew, _bondOf(1_000_000e18));
    }

    /// Creation needs no price at all: the minimum is the fixed
    /// minRewardYolo = 1000e18, price or not.
    function test_Guard_creationNeedsNoPrice() public {
        uint64 dl = uint64(_now() + 1 days);
        oracle.set(address(yolo), 0, 18);
        vm.prank(author);
        vm.expectRevert(RewardTooSmall.selector);
        vault.createTask(address(yolo), 1_000e18 - 1, dl, "Title", rulesOf("c"), 0, 0, "", _noSwap());
        vm.prank(alice);
        vault.createTask(address(yolo), 1_000e18, dl, "Title", rulesOf("c"), 0, 0, "", _noSwap()); // exactly the minimum, no price set
    }
}
