// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import "./Base.t.sol";

/// @dev Random sequences of every user action over a few tasks. Every call is wrapped in try/catch.
contract Handler is CommonBase, StdCheats, StdUtils {
    ITaskVault internal vault;
    YoloSweetener internal sweetener;
    DareTrophy internal trophy;
    YoloLockHub internal hub;
    MockIntake internal intake;
    uint256 internal attesterKey;
    address[] internal people; // authors / contributors / doers / disputers
    uint256[5] internal voterKeys;
    address[5] internal voterAddrs;
    uint256[] public tasks;
    uint256[] public subs;
    mapping(bytes32 => uint256) internal _calls;
    /// @notice Ghosts: everything ever put into a task's reward (creation + top-ups), everything taken back with
    /// withdrawContribution, and every $YOLO ever put on its bonus.
    mapping(uint256 => uint256) public deposited;
    mapping(uint256 => uint256) public withdrawn;
    mapping(uint256 => uint256) public sweetened;
    /// @notice A withdrawal that succeeded while the reward was still locked (must stay 0).
    uint256 public earlyWithdrawals;

    function calls(bytes32 k) external view returns (uint256) {
        return _calls[k];
    }

    constructor(
        ITaskVault v,
        MockIntake i,
        uint256 attKey,
        address[] memory p,
        uint256[5] memory vk,
        address[5] memory va,
        YoloSweetener sw,
        DareTrophy tr,
        YoloLockHub h
    ) {
        vault = v;
        sweetener = sw;
        trophy = tr;
        hub = h;
        intake = i;
        attesterKey = attKey;
        people = p;
        voterKeys = vk;
        voterAddrs = va;
    }

    function taskCount() external view returns (uint256) {
        return tasks.length;
    }

    function _who(uint256 seed) internal view returns (address) {
        return people[seed % people.length];
    }

    function _task(uint256 seed) internal view returns (uint256) {
        return tasks.length == 0 ? 0 : tasks[seed % tasks.length];
    }

    function _sub(uint256 seed) internal view returns (uint256) {
        return subs.length == 0 ? 0 : subs[seed % subs.length];
    }

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    // ------------------------------------------------------------------ actions

    function createTask(uint256 seed, uint256 amount) external {
        uint256 c = seed % 4;
        address cur = c == 0 ? ETH : c == 1 ? vault.usdc() : c == 2 ? vault.imd() : vault.yolo();
        // every task has a deadline; short ones so that random runs reach expiries
        uint64 deadline = uint64(_now() + bound(seed >> 16, 1 hours, 4 days));
        if (c == 0) amount = bound(amount, 0.002 ether, 0.4 ether); // $5..$1,000 at $2,500
        else if (c == 1) amount = bound(amount, 5e6, 1_000e6);
        else if (c == 2) amount = bound(amount, 0.625e18, 125e18); // $5..$1,000 at $8
        else amount = bound(amount, 50_000e18, 10_000_000e18); // $5..$1,000 at $0.0001
        ImdPay memory none;
        uint256 fee = (seed >> 8) % 2 == 0 ? 0 : 0.001 ether; // no creation fee: extra ETH comes back
        vm.prank(_who(seed));
        try vault.createTask{value: fee + (c == 0 ? amount : 0)}(
            cur, amount, deadline, "Title", rulesOf("c"), 0, 0, "", none
        ) returns (
            uint256 id
        ) {
            tasks.push(id);
            deposited[id] += amount;
            _calls[keccak256("createTask")]++;
        } catch {}
    }

    function topUp(uint256 seed, uint256 amount) external {
        uint256 t = _task(seed);
        if (t == 0) return;
        address cur = vault.getTask(t).currency;
        amount = bound(
            amount, 1, cur == ETH ? 0.5 ether : cur == vault.usdc() ? 500e6 : cur == vault.imd() ? 50e18 : 5_000_000e18
        );
        ImdPay memory none;
        vm.prank(_who(seed >> 8));
        try vault.topUp{value: cur == ETH ? amount : 0}(t, amount, none) {
            deposited[t] += amount;
            _calls[keccak256("topUp")]++;
        } catch {}
    }

    /// @dev The reward is locked until the deadline: a withdrawal may succeed only once the task
    /// expired (at or after its deadline) or was unwound; never on a completed task.
    function withdrawContribution(uint256 seed) external {
        _withdraw(_task(seed), _who(seed >> 8));
    }

    /// @dev Lets a random task reach its deadline, then its author (or a random person) takes his share back: the
    /// expiry path, which short random runs reach rarely by themselves.
    function expireAndWithdraw(uint256 seed) external {
        uint256 t = _task(seed);
        if (t == 0) return;
        Task memory tk = vault.getTask(t);
        if (tk.status == TaskStatus.Open && _now() < tk.deadline) vm.warp(tk.deadline);
        _withdraw(t, seed % 2 == 0 ? tk.author : _who(seed >> 8));
    }

    function _withdraw(uint256 t, address who) internal {
        Contribution memory c0 = vault.getContribution(t, who);
        vm.prank(who);
        try vault.withdrawContribution(t) {
            Task memory tk = vault.getTask(t);
            Contribution memory c1 = vault.getContribution(t, who);
            withdrawn[t] += uint256(c0.active) - c1.active;
            // a completed task returns nothing: the whole pot went to the doer
            if (tk.status == TaskStatus.Completed) earlyWithdrawals++;
            if (tk.status == TaskStatus.Open) earlyWithdrawals++;
            if (tk.status == TaskStatus.Expired && _now() < tk.deadline) earlyWithdrawals++;
            _calls[keccak256("withdrawContribution")]++;
            if (tk.status == TaskStatus.Expired) _calls[keccak256("withdrawExpired")]++;
        } catch {}
    }

    function submit(uint256 seed, bool swapWithEth) external {
        uint256 t = _task(seed);
        if (t == 0) return;
        ImdPay memory pay;
        uint256 value;
        if (swapWithEth) {
            try vault.quoteSubmission(t) returns (Bond memory bond) {
                uint256 needed = bond.imd; // only the fixed IMD part supports the ETH swap
                value = needed * 1e18 / 312.5e18 + 1e15;
                pay = ImdPay({
                    tokenIn: ETH, amountIn: value, minImdOut: needed, deadline: uint64(_now() + 600), route: ""
                });
            } catch {
                return;
            }
        }
        vm.prank(_who(seed >> 8));
        try vault.submit{value: value}(
            t, "https://x.com/doer/status/1", Evidence("", ""), 0, type(uint256).max, pay
        ) returns (
            uint256 s
        ) {
            subs.push(s);
            _calls[keccak256("submit")]++;
        } catch {}
    }

    /// @dev Every createTask here uses the fixed `rulesOf("c")`, so this is the
    /// correct resupply for every appeal/callSwarm fired from this handler, whichever task/sub seed hits.
    function _handlerRuleTexts() internal pure returns (RuleTexts memory rt) {
        TaskRules memory r = rulesOf("c");
        rt.task = r.task;
        rt.taskProof = r.proof;
        rt.taskNo = r.noIf;
        rt.disputeReason = "reason";
        rt.disputerProofUri = "reason-proof";
    }

    function dispute(uint256 seed, uint256) external {
        uint256 s = _sub(seed);
        ImdPay memory none;
        vm.prank(_who(seed >> 8));
        try vault.dispute(s, "reason", "reason-proof", none) {
            _calls[keccak256("dispute")]++;
        } catch {}
    }

    // No "doer answers the dispute" step: the protocol has no reply.

    function vote(uint256 seed, uint8 side, uint256 voterSeed, uint256, uint256 basefee) external {
        uint256 s = _sub(seed);
        if (s == 0) return;
        Submission memory sub = vault.getSubmission(s);
        if (sub.phase != Phase.Voting) return;
        uint256 vi = voterSeed % 5;
        side = side % 2 == 0 ? 1 : 2;
        vm.fee(bound(basefee, 0, 100 gwei));
        // anyone sends voter vi's NFT ids: only the holder's own vote passes, others revert
        uint256[5] memory from = [uint256(0), 120, 140, 150, 155];
        uint256[5] memory cnt = [uint256(120), 20, 10, 5, 2];
        uint256[] memory ids = new uint256[](cnt[vi]);
        for (uint256 i; i < ids.length; ++i) {
            ids[i] = from[vi] + i;
        }
        vm.prank(seed % 2 == 0 ? voterAddrs[vi] : _who(seed >> 16));
        try vault.vote(s, side, voterAddrs[vi], ids) {
            _calls[keccak256("vote")]++;
        } catch {}
    }

    function appeal(uint256 seed) external {
        uint256 s = _sub(seed);
        ImdPay memory none;
        vm.prank(_who(seed >> 8));
        try vault.appeal(s, type(uint256).max, none) {
            _calls[keccak256("appeal")]++;
        } catch {}
    }

    /// @dev the appeal's ask is a separate step - a separate handler for it, permissionless.
    function askAppealSwarm(uint256 seed) external {
        uint256 s = _sub(seed);
        try vault.askAppealSwarm(s, _handlerRuleTexts()) {
            _calls[keccak256("askAppealSwarm")]++;
        } catch {}
    }

    // No opponent-reply step on an appeal: the appeal question is asked by askAppealSwarm
    // (lazy, any caller).

    function breakIntake(uint256 seed) external {
        intake.setBroken(seed % 7 == 0); // sometimes the Intake reverts on request
        _calls[keccak256("breakIntake")]++;
    }

    function callSwarm(uint256 seed) external {
        uint256 s = _sub(seed);
        ImdPay memory none;
        vm.prank(_who(seed >> 8));
        try vault.callSwarm(s, (seed >> 4) % 2 == 0, type(uint256).max, none, _handlerRuleTexts()) {
            _calls[keccak256("callSwarm")]++;
        } catch {}
    }

    function answer(uint256 seed, uint8 mode) external {
        uint256 s = _sub(seed);
        if (s == 0) return;
        bytes32 rid = vault.getSubmission(s).request;
        if (rid == bytes32(0)) return;
        (,,, bool done) = intake.requests(rid);
        if (done) return;
        OracleAttestation.Attestation memory a;
        a.answerType = 0;
        a.answer = abi.encode(mode % 3 == 0);
        a.panelSize = 7;
        a.quorum = 5;
        a.agreed = 5;
        a.issuedAt = uint64(_now());
        bytes memory sig;
        if (mode % 3 != 2) {
            (uint8 v, bytes32 r, bytes32 ss) = vm.sign(attesterKey, vault.attestationDigest(a));
            sig = abi.encodePacked(r, ss, v);
        }
        try intake.complete(rid, mode % 3 == 2 ? 2 : 0, a, sig) {
            _calls[keccak256("answer")]++;
        } catch {}
    }

    /// @dev Moves the active submission of a random task one step down its path (deep phases otherwise rare).
    function progress(uint256 seed, uint8 choice) external {
        uint256 t = _task(seed);
        if (t == 0) return;
        vault.poke(t);
        uint256 s = vault.getTask(t).activeSub;
        if (s == 0) {
            if (vault.getTask(t).status == TaskStatus.Open) {
                this.submit(_indexOfTask(t) + tasks.length * (uint256(choice) + 1), choice % 5 == 0);
            }
            return;
        }
        Submission memory sub = vault.getSubmission(s);
        Phase ph = sub.phase;
        _calls[keccak256(abi.encode("phase", ph))]++;
        if (sub.asks > 1) _calls[keccak256("repeatedAsk")]++;
        uint256 i = _indexOf(s);
        uint256 other = i + subs.length * (uint256(choice) * 977 + 1); // same submission, another person
        if (ph == Phase.Review) {
            if (choice % 4 != 0) this.dispute(other, 0.001 ether);
            else this.warp(1 days);
        } else if (ph == Phase.Voting) {
            if (choice % 3 == 0) this.warp(1 days);
            else this.vote(i, choice, choice, choice % 2 == 0 ? 120 : 15, 0);
        } else if (ph == Phase.Decided) {
            if (choice % 2 == 0) this.appeal(other);
            else this.warp(1 days);
        } else if (ph == Phase.NoDecision) {
            if (choice % 3 != 0) this.callSwarm(other);
            else this.warp(1 days);
        } else if (ph == Phase.Appealed) {
            // the appeal question is asked only by askAppealSwarm (its own handler action); poke plays the timers.
            this.poke(seed);
        } else if (ph == Phase.Asked) {
            if (choice % 4 == 3) this.warp(7 hours);
            else this.answer(i, choice);
        }
        _calls[keccak256("progress")]++;
    }

    // aliases: give the path-driving action more weight in the random selector choice
    function progressA(uint256 seed, uint8 choice) external {
        this.progress(seed, choice);
    }

    function progressB(uint256 seed, uint8 choice) external {
        this.progress(seed >> 3, choice);
    }

    function progressC(uint256 seed, uint8 choice) external {
        this.progress(seed >> 5, choice ^ 0x5a);
    }

    function progressD(uint256 seed, uint8 choice) external {
        this.progress(seed >> 7, choice ^ 0xa5);
    }

    function _indexOfTask(uint256 t) internal view returns (uint256) {
        for (uint256 i; i < tasks.length; ++i) {
            if (tasks[i] == t) return i;
        }
        return 0;
    }

    function _indexOf(uint256 s) internal view returns (uint256) {
        for (uint256 i; i < subs.length; ++i) {
            if (subs[i] == s) return i;
        }
        return 0;
    }

    function setIntakePrice(uint256 p) external {
        intake.setPrice(bound(p, 0.1e18, 1.2e18));
    }

    function warp(uint256 dt) external {
        vm.warp(_now() + bound(dt, 1 minutes, 1 days));
        _calls[keccak256("warp")]++;
    }

    function poke(uint256 seed) external {
        uint256 t = _task(seed);
        try vault.poke(t) {} catch {}
    }

    function claim(uint256 seed, uint8 kind) external {
        uint256 s = _sub(seed);
        address who = _who(seed >> 8);
        kind = kind % 4;
        vm.prank(who);
        if (kind == 0) {
            try vault.claimDisputer(s) {
                _calls[keccak256("claimDisputer")]++;
            } catch {}
        } else if (kind == 1) {
            try vault.claimVoterReward(s, voterAddrs[seed % 5]) {
                _calls[keccak256("claimVoter")]++;
            } catch {}
        } else if (kind == 2) {
            try vault.claimVoidSubmission(s) {
                _calls[keccak256("claimVoid")]++;
            } catch {}
        } else {
            address[4] memory ts = [ETH, vault.usdc(), vault.imd(), vault.yolo()];
            try vault.withdraw(ts[seed % 4]) {
                _calls[keccak256("withdraw")]++;
            } catch {}
        }
    }

    // ------------------------------------------------------------------ $YOLO bonus (YoloSweetener)

    function sweeten(uint256 seed, uint256 amount) external {
        uint256 t = _task(seed);
        amount = bound(amount, 1, 50_000_000e18);
        vm.prank(_who(seed >> 8));
        try sweetener.sweeten(t, amount) {
            sweetened[t] += amount;
            _calls[keccak256("sweeten")]++;
        } catch {}
    }

    /// @dev The bonus is locked like the reward: taking it back works only after expiry or unwind (or past the
    /// deadline with nothing in flight, which the vault turns into an expiry).
    function withdrawBonus(uint256 seed) external {
        uint256 t = _task(seed);
        vm.prank(_who(seed >> 8));
        try sweetener.withdraw(t) {
            // the status after the call: withdraw plays the task's timers first (vault.poke), so a
            // submission the swarm already answered closes inside the call and the task may only now be Expired
            Task memory st = vault.getTask(t);
            bool free = st.status == TaskStatus.Expired || st.status == TaskStatus.Unwound
                || (st.status == TaskStatus.Open && st.activeSub == 0 && _now() >= st.deadline);
            if (!free) earlyWithdrawals++;
            _calls[keccak256("withdrawBonus")]++;
        } catch {}
    }

    function payoutBonus(uint256 seed) external {
        try sweetener.payout(_task(seed)) {
            _calls[keccak256("payoutBonus")]++;
        } catch {}
    }

    // ------------------------------------------------------------------ doer stake (YoloLockHub)

    /// @notice Ghost: $YOLO put into the hub and taken back by everybody (the hub must hold exactly the difference).
    uint256 public hubIn;
    uint256 public hubOut;
    /// @notice A lock taken back before its end (must stay 0).
    uint256 public earlyUnlocks;

    /// @dev Somebody locks $YOLO (a doer whose lock had any power (no threshold)
    /// at their submission and still runs at the payout gets 4% x min(1, power / reward), the rest of the
    /// stakers' 5% half burns, half treasury): exercises the stake payout path in random runs. Adds, extends
    /// (weeks 0 = add only) or locks anew; short terms so that locks also end inside a run.
    function lock(uint256 seed, uint256 amount, uint256 weeks_) external {
        amount = bound(amount, 0, 3_000_000e18);
        weeks_ = bound(weeks_, 0, 52);
        if (weeks_ > 4 && seed % 2 == 0) weeks_ = 1 + weeks_ % 2; // half of the terms: 1-2 weeks
        vm.prank(_who(seed));
        try hub.lock(amount, weeks_) {
            hubIn += amount;
            _calls[keccak256("lock")]++;
        } catch {}
    }

    /// @dev Somebody takes his lock back (only after its end, all of it).
    function withdrawLock(uint256 seed) external {
        address who = _who(seed);
        (uint96 amount, uint64 end,) = hub.locks(who);
        vm.prank(who);
        try hub.withdraw() {
            if (_now() < end) earlyUnlocks++;
            hubOut += amount;
            _calls[keccak256("withdrawLock")]++;
        } catch {}
    }

    /// @dev the doer of a random submission (or anybody) tries to mint its trophy; minted ids are kept for checks
    uint256[] public minted;

    function mintedCount() external view returns (uint256) {
        return minted.length;
    }

    function mintTrophy(uint256 seed, bool asDoer) external {
        uint256 s = _sub(seed);
        // as the doer: the first accepted submission from a random start (acceptances are rare in random runs)
        for (uint256 i; asDoer && i < subs.length; ++i) {
            uint256 c = subs[(seed + i) % subs.length];
            if (vault.getSubmission(c).outcome == Outcome.Accepted) {
                s = c;
                break;
            }
        }
        address who = asDoer && s != 0 ? vault.getSubmission(s).doer : _who(seed >> 8);
        vm.prank(who);
        try trophy.mint(s, "Trophy") {
            minted.push(s);
            _calls[keccak256("mintTrophy")]++;
        } catch {}
    }

    function sweep(uint256 seed) external {
        address[4] memory ts = [ETH, vault.usdc(), vault.imd(), vault.yolo()];
        try vault.sweepTreasury(ts[seed % 4]) {} catch {}
    }

    receive() external payable {}
}

/// forge-config: default.isolate = false
contract InvariantTest is Base {
    Handler internal handler;

    function setUp() public override {
        super.setUp();
        address[] memory people = new address[](9);
        people[0] = author;
        people[1] = alice;
        people[2] = bob;
        people[3] = doer;
        people[4] = doer2;
        people[5] = doer3;
        people[6] = dave;
        people[7] = erin;
        people[8] = relayer;
        handler = new Handler(vault, intake, attesterKey, people, voterKeys, voters, sweetener, trophy, hub);
        vm.deal(address(handler), 1_000_000 ether); // msg.value of pranked calls is paid by the handler
        targetContract(address(handler));
    }

    /// @dev After every call: the vault holds exactly what it owes, to the wei, per currency (nobody sends it tokens
    /// outside the protocol in this run, so every unit in it is booked in some bucket), and what it owes covers
    /// at least the task pots, the treasury pots and the credits of every actor.
    function invariant_BalanceEqualsLiabilities() public view {
        _assertSolvent();
        address[4] memory ts = _tokens();
        for (uint256 i; i < 4; ++i) {
            address tk = ts[i];
            assertEq(_balance(tk), vault.liabilities(tk), "balance != liabilities");
            uint256 owed = vault.treasuryPot(tk);
            for (uint256 a; a < actors.length; ++a) {
                owed += vault.credits(tk, actors[a]);
            }
            owed += vault.credits(tk, address(handler));
            for (uint256 j; j < handler.taskCount(); ++j) {
                Task memory t = vault.getTask(handler.tasks(j));
                if (t.currency == tk) owed += t.pot;
            }
            assertGe(vault.liabilities(tk), owed, "liabilities below the known buckets");
        }
    }

    /// @dev After every call: the reward is locked until the deadline. While a task is Open its
    /// pot is exactly everything ever put in and nothing was ever taken back; after expiry or unwind pot +
    /// taken back = put in; a completed task paid out everything put in as the accepted reward (top-ups during
    /// a check included). No withdrawal ever succeeded while the money was locked.
    function invariant_RewardLockedUntilDeadline() public view {
        assertEq(handler.earlyWithdrawals(), 0, "money left a task before its deadline");
        for (uint256 i; i < handler.taskCount(); ++i) {
            uint256 id = handler.tasks(i);
            Task memory t = vault.getTask(id);
            uint256 inn = handler.deposited(id);
            uint256 out = handler.withdrawn(id);
            if (t.status == TaskStatus.Open) {
                assertEq(out, 0, "withdrawal from an open task");
                assertEq(t.pot, inn, "open task lost reward money");
                assertEq(t.pending, 0, "no pending top-ups");
            } else if (t.status == TaskStatus.Completed) {
                assertEq(t.pot, 0, "completed task keeps an active pot");
                uint256 reward = vault.getSubmission(t.activeSub).reward;
                assertEq(uint8(vault.getSubmission(t.activeSub).outcome), uint8(Outcome.Accepted));
                assertEq(reward + out, inn, "completed task: reward + returned != put in");
            } else {
                assertEq(t.pot + out, inn, "expired / unwound task: left + returned != put in");
            }
        }
    }

    /// @dev After every call: the sweetener holds exactly the unpaid bonuses plus the unclaimed NFT shares of paid
    /// ones; a bonus is exactly what its sweeteners put in and may take back until it is paid out (only on a
    /// completed task); nothing of it left before the task expired.
    function invariant_SweetenerHoldsEveryBonus() public view {
        uint256 sum;
        for (uint256 i; i < handler.taskCount(); ++i) {
            uint256 t = handler.tasks(i);
            uint256 bonus = sweetener.bonusOf(t);
            sum += bonus + sweetener.voterPool(t);
            uint256 given;
            for (uint256 a; a < actors.length; ++a) {
                given += sweetener.givenBy(t, actors[a]);
            }
            Task memory tk = vault.getTask(t);
            TaskStatus st = tk.status;
            if (st == TaskStatus.Completed) {
                // paid out (bonus 0) or still waiting for payout (the whole bonus); givenBy stays after a payout
                if (bonus != 0) assertEq(given, bonus, "unpaid bonus != what its sweeteners put in");
                assertEq(given, handler.sweetened(t), "completed task: a sweetener took his bonus back");
                continue;
            }
            assertEq(sweetener.voterPool(t), 0, "voter share of a task that is not completed");
            assertEq(given, bonus, "bonus != what its sweeteners put in");
            // locked while somebody can still earn it: before the deadline, or with a submission in flight (past
            // the deadline with nothing in flight the sweetener already lets it go, the vault expires it lazily)
            if (st == TaskStatus.Open && (_now() < tk.deadline || tk.activeSub != 0)) {
                assertEq(bonus, handler.sweetened(t), "bonus left an open task");
            }
        }
        assertEq(yolo.balanceOf(address(sweetener)), sum, "sweetener balance != open bonuses + voter shares");
    }

    /// @dev After every call: the hub holds exactly the locked amounts of everybody (= put in - taken back), nobody
    /// took a lock back before its end (withdraw reverts then), every submission's stake share is 0 or between a
    /// tenth of 4% and 4% (the bonus never exceeds 4%), and a paid share is the one fixed at
    /// that submission, only on an acceptance.
    function invariant_HubHoldsEveryLock_StakePowerBounded() public view {
        uint256 sum;
        for (uint256 a; a < actors.length; ++a) {
            (uint96 amount, uint64 end,) = hub.locks(actors[a]);
            sum += amount;
            if (amount == 0) assertEq(end, 0, "an empty lock with an end");
        }
        assertEq(yolo.balanceOf(address(hub)), sum, "hub balance != the locks");
        assertEq(sum, handler.hubIn() - handler.hubOut(), "hub locks != put in - taken back");
        assertEq(handler.earlyUnlocks(), 0, "a lock taken back before its end");
        uint256 subs = vault.submissionCount();
        for (uint256 s = 1; s <= subs; ++s) {
            uint256 fixedBps = vault.getSubmission(s).stakeBps;
            assertLe(fixedBps, 400, "stake share above 4%");
            uint256 p = vault.getSettlement(s).stakeBps;
            if (p == 0) continue;
            assertEq(uint8(vault.getSubmission(s).outcome), uint8(Outcome.Accepted), "stake share of a non-acceptance");
            assertEq(p, fixedBps, "paid share != the share fixed at the submission");
        }
    }

    /// @dev After every call: every trophy belongs to an accepted submission and was minted by its doer (it is still his:
    /// nobody transfers in this run), the YOLO burned equals the sum of what the trophies cost, the trophy contract
    /// keeps no YOLO.
    function invariant_TrophiesOnlyForAcceptedDoersAndEveryYoloBurned() public view {
        uint256 sum;
        for (uint256 i; i < handler.mintedCount(); ++i) {
            uint256 s = handler.minted(i);
            Submission memory sub = vault.getSubmission(s);
            assertEq(uint8(sub.outcome), uint8(Outcome.Accepted), "trophy of a submission that was not accepted");
            assertEq(trophy.ownerOf(s), sub.doer, "trophy not of the doer");
            sum += trophy.mintedOf(s).yoloBurned;
        }
        assertEq(trophy.totalBurned(), sum);
        // 0x...dEaD also gets the $YOLO the treasury would have had (fees of YOLO tasks, sweetener burns)
        assertGe(yolo.balanceOf(DEAD), sum, "burned < paid for trophies");
        assertEq(yolo.balanceOf(address(trophy)), 0);
    }

    /// @dev At the end of every run: play all timers, unwind what waits, claim everything; the vault must hold
    /// exactly what it owes and owe only protocol buckets.
    function afterInvariant() public {
        string[21] memory names = [
            "createTask",
            "topUp",
            "submit",
            "dispute",
            "vote",
            "appeal",
            "breakIntake",
            "callSwarm",
            "answer",
            "claimDisputer",
            "claimVoter",
            "claimVoid",
            "withdrawContribution",
            "withdrawExpired",
            "progress",
            "sweeten",
            "withdrawBonus",
            "payoutBonus",
            "mintTrophy",
            "lock",
            "withdrawLock"
        ];
        for (uint256 i; i < names.length; ++i) {
            emit log_named_uint(names[i], handler.calls(keccak256(bytes(names[i]))));
        }
        emit log_named_uint("repeatedAsk", handler.calls(keccak256("repeatedAsk")));
        for (uint8 ph = uint8(Phase.Review); ph <= uint8(Phase.Asked); ++ph) {
            emit log_named_uint(
                string.concat("progress at phase ", vm.toString(ph)),
                handler.calls(keccak256(abi.encode("phase", Phase(ph))))
            );
        }
        for (uint256 i; i < handler.taskCount(); ++i) {
            trackedTasks.push(handler.tasks(i));
        }
        intake.setBroken(false);
        _claimEverythingAndCheck();
    }
}
