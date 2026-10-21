// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {Base} from "../Base.t.sol";
import {YoloSweetener} from "../../src/YoloSweetener.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockNFT} from "../mocks/MockNFT.sol";
import {MockDelegateRegistry} from "../mocks/MockDelegateRegistry.sol";
import {MockStarter} from "../mocks/MockStarter.sol";
import {YoloToken} from "../../src/token/YoloToken.sol";
import {YoloSplitter} from "../../src/token/YoloSplitter.sol";
import {ProjectVesting} from "../../src/token/ProjectVesting.sol";
import {LaunchPlan, LocalFactory} from "../../script/LaunchPlan.sol";
import "../../src/VaultTypes.sol";

interface IAuditVesting {
    function startOf(address token) external view returns (uint64);
}

/// @notice The bonus rules: any amount, no swarm check; the bonus is locked like the reward.
/// forge-config: default.isolate = false
contract AuditSweetenerBonus is Base {
    function _sweeten(address who, uint256 taskId, uint256 amount) internal {
        vm.prank(who);
        sweetener.sweeten(taskId, amount);
    }

    function _withdraw(address who, uint256 taskId) internal returns (uint256 got) {
        uint256 before = yolo.balanceOf(who);
        vm.prank(who);
        sweetener.withdraw(taskId);
        got = yolo.balanceOf(who) - before;
    }

    function _acceptByTimer(uint256 t, uint256 s) internal {
        vm.warp(_sub(s).windowEnd);
        vault.poke(t);
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Completed));
    }

    /// @dev payout by the reward's rule: (doer, voters, burned) for a bonus, the NFT right or not, the stake extra.
    /// @dev `bps`: the doer's stake share on the accepted submission (Settlement.stakeBps), 0 = none or they
    ///      sweetened the task themself: extra = bps of the bonus.
    function _split(uint256 bonus, bool nftRight, uint256 bps) internal pure returns (uint256, uint256, uint256) {
        uint256 fee = bonus / 10;
        uint256 nft = bonus * 500 / 10_000;
        uint256 toVoters = nftRight ? nft : 0;
        uint256 bonusX = bonus * bps / 10_000;
        return (bonus - fee + bonusX, toVoters, fee - toVoters - bonusX);
    }

    // ================================================================== no cap

    /// There is no cap at all, not even
    /// combined with the reward: the whole bonus goes by the reward's rule (90% to the doer, the 10% fee burns: no
    /// NFT decision here), nothing goes back to the four sweeteners, nothing stays.
    function test_noCap_wholeBonusPaidByTheRewardRule() public {
        uint256 t = _create(author, ETH, 0.01 ether); // $25
        uint256 a = 6_000_000e18 + 7; // $600
        uint256 b = 3_000_000e18 + 1; // $300
        uint256 c = 333_333e18 + 3; // $33.33: $958.33 total with the reward
        _sweeten(alice, t, a);
        _sweeten(bob, t, b);
        _sweeten(dave, t, c);
        uint256 e = 500_000e18; // $50
        _sweeten(erin, t, e);
        uint256 bonus = a + b + c + e;
        uint256 s = _submit(doer, t);
        _acceptByTimer(t, s);

        uint256 before = yolo.balanceOf(doer);
        uint256 deadBefore = yolo.balanceOf(address(burner));
        sweetener.payout(t);
        (uint256 toDoer,, uint256 burned) = _split(bonus, false, 0);
        assertEq(yolo.balanceOf(doer) - before, toDoer, "the whole bonus minus 10%");
        assertEq(
            yolo.balanceOf(address(burner)) - deadBefore, burned, "the fee burns (no NFT decision, no treasury YOLO)"
        );
        assertEq(toDoer + burned, bonus);
        assertEq(yolo.balanceOf(treasury), 0, "the treasury gets no YOLO");
        assertEq(sweetener.bonusOf(t), 0);
        vm.expectRevert(YoloSweetener.NothingToPay.selector);
        sweetener.payout(t);
        vm.prank(alice);
        vm.expectRevert(YoloSweetener.BonusLocked.selector); // nothing goes back after an acceptance
        sweetener.withdraw(t);
        assertEq(yolo.balanceOf(address(sweetener)), 0, "no dust");
        _claimEverythingAndCheck();
    }

    /// A silent paid call confirms nothing, and it does not matter: accepted by the undecided rule, the whole
    /// bonus is paid.
    function test_silentSwarmCallStillPaysTheWholeBonus() public {
        uint256 t = _create(author, ETH, 0.2 ether); // $500
        _sweeten(alice, t, 5_000_000e18); // $500
        uint256 s = _submit(doer, t);
        _dispute(dave, s);
        _warp(24 hours);
        _callSwarm(erin, s);
        _silent(s);
        vault.poke(t);
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Completed));
        uint256 before = yolo.balanceOf(doer);
        sweetener.payout(t);
        assertEq(yolo.balanceOf(doer) - before, 4_500_000e18, "no cap: the swarm never said yes, paid anyway");
        vm.prank(alice);
        vm.expectRevert(YoloSweetener.BonusLocked.selector);
        sweetener.withdraw(t);
        _claimEverythingAndCheck();
    }

    /// The payout never reads a price at all (no cap to value): it always pays at once.
    function test_payoutNeedsNoPrice() public {
        uint256 t = _create(author, ETH, 0.01 ether);
        _sweeten(alice, t, 1_000e18);
        uint256 s = _submit(doer, t);
        _acceptByTimer(t, s);
        uint256 before = yolo.balanceOf(doer);
        sweetener.payout(t);
        assertEq(yolo.balanceOf(doer) - before, 900e18);
        assertEq(sweetener.bonusOf(t), 0);
        _claimEverythingAndCheck();
    }

    /// What the NFT decided and the
    /// doer stake change the split as for the reward: NFT right -> 5% to the "accept" votes (claimVoter); a doer
    /// with a stake share (also one who sweetened the task themself) -> + that share (power 9M = the $100 reward plus the
    /// $800 add-on in $YOLO, the whole 4% here), the burn takes the rest; an escalation the swarm decided -> no NFT
    /// share.
    function test_splitFollowsTheRewardRule_NftVotesAndStake() public {
        vm.prank(doer);
        hub.lock(9_000_000e18, 52);
        _warp(1); // the lock counts for submissions in later blocks
        uint256 t = _create(author, ETH, 0.04 ether); // $100
        _sweeten(alice, t, 8_000_000e18); // $800
        uint256 s = _submit(doer, t);
        _dispute(dave, s);
        _vote(s, 1, 1, 120, 20); // NFT: accept
        _warp(48 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        assertEq(vault.getSettlement(s).stakeBps, 400);
        uint256 before = yolo.balanceOf(doer);
        uint256 deadBefore = yolo.balanceOf(address(burner));
        sweetener.payout(t);
        assertEq(yolo.balanceOf(doer) - before, 7_520_000e18, "90% + 4% stake extra");
        assertEq(sweetener.voterPool(t), 400_000e18, "5% to the accept votes");
        assertEq(yolo.balanceOf(address(burner)) - deadBefore, 80_000e18, "1% left");
        (uint256 d, uint256 v, uint256 b) = _split(8_000_000e18, true, 400);
        assertEq(d + v + b, 8_000_000e18);
        assertEq(d, 7_520_000e18);
        sweetener.claimVoter(t, voters[1]);
        assertEq(yolo.balanceOf(voters[1]) - 1_000_000_000e18, 400_000e18, "the only accept voter");

        uint256 t2 = _create(author, ETH, 0.04 ether); // escalation, NFT undecided; doer2 sweetened themself
        _sweeten(bob, t2, 8_000_000e18);
        _sweeten(doer2, t2, 1e18);
        vm.prank(doer2);
        hub.lock(10_000_000e18, 52);
        _warp(1);
        uint256 s2 = _submit(doer2, t2);
        _dispute(dave, s2);
        _warp(24 hours); // no NFT votes
        _callSwarm(erin, s2);
        _answer(s2, true); // the swarm: the doer is right
        vault.poke(t2);
        assertEq(uint8(_sub(s2).outcome), uint8(Outcome.Accepted));
        assertEq(vault.getSettlement(s2).stakeBps, 400, "the reward's stake bonus is paid");
        before = yolo.balanceOf(doer2);
        sweetener.payout(t2);
        (uint256 toDoer,,) = _split(8_000_000e18 + 1e18, false, 400);
        assertEq(yolo.balanceOf(doer2) - before, toDoer, "a sweetener of their own task: stake extra as usual");
        assertEq(sweetener.voterPool(t2), 0, "the NFT did not decide: no voter share");
        vm.prank(bob);
        vm.expectRevert(YoloSweetener.BonusLocked.selector);
        sweetener.withdraw(t2);
        _claimEverythingAndCheck();
    }

    // ================================================================== the bonus is locked

    /// The bonus is locked like the reward: no
    /// notice, no way out while the task is open (before or after its deadline while a submission is judged); once
    /// it is past the deadline with nothing in flight, everyone takes their own back; nobody can add after the deadline.
    function test_noWithdrawFromAnOpenTask() public {
        uint256 t = _createWithDeadline(author, ETH, 0.01 ether, uint64(_now() + 2 days));
        _sweeten(alice, t, 1_000e18);
        vm.prank(alice);
        vm.expectRevert(YoloSweetener.BonusLocked.selector);
        sweetener.withdraw(t);
        _warp(1 days);
        uint256 s = _submit(doer, t);
        _dispute(dave, s);
        _vote(s, 1, 2, 120, 15); // the NFT rejects it: margin 15 < instantDelta 20, decided at the vote end
        _sweeten(alice, t, 500e18);
        _warp(1 days + 1); // past the deadline, the submission still judged
        vm.prank(alice);
        vm.expectRevert(YoloSweetener.BonusLocked.selector);
        sweetener.withdraw(t);
        vm.prank(bob);
        vm.expectRevert(YoloSweetener.TaskNotOpen.selector);
        sweetener.sweeten(t, 1e18);
        _warp(48 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Rejected));
        assertEq(uint8(vault.getTask(t).status), uint8(TaskStatus.Expired));
        assertEq(_withdraw(alice, t), 1_500e18);
        assertEq(sweetener.bonusOf(t), 0);
        _claimEverythingAndCheck();
    }

    /// An expired task gives the bonus back at once (also a stored-Open task past its deadline with no
    /// submission in flight: nobody can submit). A task the dev wallet cancelled (Unwound) frees the bonus the
    /// same way (CancelTask.t.sol).
    function test_backOnceNobodyCanSubmit() public {
        uint256 d = _createWithDeadline(author, ETH, 0.01 ether, uint64(_now() + 1 days));
        _sweeten(alice, d, 10e18);
        _sweeten(bob, d, 20e18);
        _warp(1 days + 1);
        assertEq(_withdraw(alice, d), 10e18, "past the deadline, not poked yet");
        vault.poke(d);
        assertEq(uint8(vault.getTask(d).status), uint8(TaskStatus.Expired));
        assertEq(_withdraw(bob, d), 20e18, "expired");
    }
}

/// @notice The vesting clocks start when the tokens arrive.
contract AuditVestingClock is Test {
    address constant PM = address(0x4444);
    address treasury = makeAddr("treasury");

    /// Launch 1 thirty days after launch 0: the split starts every clock, the gap unlocks nothing, Day 0 is
    /// exactly the at-once parts.
    function test_splitStartsTheClocks() public {
        vm.warp(1_800_000_000);
        MockNFT nft = new MockNFT();
        LocalFactory f = new LocalFactory();
        LaunchPlan.Owners memory o =
            LaunchPlan.Owners(treasury, makeAddr("inc"), makeAddr("stab"), makeAddr("dev"), makeAddr("team"));
        (bytes[] memory codes,, LaunchPlan.Genesis memory g) = LaunchPlan.genesisLaunchWith(f, 0, o, address(nft));
        f.launchContracts(0, codes);
        skip(30 days);
        YoloToken yolo = new YoloToken(PM, g.gate, treasury, block.timestamp);
        yolo.transfer(PM, 150_000_000e18);
        yolo.transfer(makeAddr("swarm"), 100_000_000e18);
        yolo.transfer(g.splitter, 750_000_000e18);
        YoloSplitter(g.splitter).split(address(yolo));
        uint256 splitAt = block.timestamp;
        assertEq(ProjectVesting(g.dev).releasable(address(yolo)), 0, "dev: nothing at the token's first block");
        assertEq(ProjectVesting(g.team).releasable(address(yolo)), 0, "team: nothing at the token's first block");
        assertEq(yolo.balanceOf(o.incentives), 62_500_000e18, "incentives: the at-once quarter, paid by the split");
        assertEq(yolo.balanceOf(o.treasury), 74_074_074e18, "treasury: the at-once third, paid by the split");
        assertEq(IAuditVesting(g.team).startOf(address(yolo)), splitAt);
        skip(365 days);
        assertEq(ProjectVesting(g.team).releasable(address(yolo)), 50_000_000e18, "a full year after the split");
        assertEq(
            ProjectVesting(g.incentives).releasable(address(yolo)), 93_750_000e18, "half the stream after 12 months"
        );
    }

    /// Any token, any order. A release before anything arrived pays 0, never reverts and starts no clock; the
    /// first release while the vesting holds the token starts it; later arrivals ride on the same clock; the sum of
    /// releases is what arrived.
    function test_clockStartsAtTheFirstReleaseWithABalance() public {
        vm.warp(1_800_000_000);
        MockERC20 tok = new MockERC20("T", "T", 18);
        address ben = makeAddr("ben");
        // the YoloSplitter's place: the only starter (swarm audit 117cf05a #2)
        MockStarter st =
            new MockStarter(abi.encodePacked(type(ProjectVesting).creationCode, abi.encode(ben, 100e18, 100 days)));
        ProjectVesting v = ProjectVesting(st.vesting());
        skip(50 days);
        st.start(address(tok)); // nothing here yet
        assertEq(IAuditVesting(address(v)).startOf(address(tok)), 0, "no clock without the token");
        tok.mint(address(v), 1_100e18);
        assertEq(v.releasable(address(tok)), 100e18, "only the at-once part before the clock starts");
        skip(10 days);
        assertEq(v.releasable(address(tok)), 100e18, "still: the clock has not started");
        vm.prank(makeAddr("anyone"));
        v.release(address(tok)); // pays the at-once part, starts nothing: only the starter does
        assertEq(IAuditVesting(address(v)).startOf(address(tok)), 0, "no clock from anyone else");
        assertEq(tok.balanceOf(ben), 100e18);
        st.start(address(tok));
        assertEq(IAuditVesting(address(v)).startOf(address(tok)), block.timestamp);
        assertEq(tok.balanceOf(ben), 100e18);
        v.release(address(tok)); // 0, no revert
        skip(50 days);
        assertEq(v.releasable(address(tok)), 500e18, "half of the 1,000 stream");
        tok.mint(address(v), 200e18); // a later arrival vests on the same clock
        assertEq(v.releasable(address(tok)), 600e18);
        skip(50 days);
        v.release(address(tok));
        assertEq(tok.balanceOf(ben), 1_300e18, "everything that arrived");
        assertEq(tok.balanceOf(address(v)), 0);
    }
}
