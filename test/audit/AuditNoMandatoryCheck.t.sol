// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../Base.t.sol";

/// @title No mandatory check: every reward size is judged the same way
/// @notice No reward size triggers a question to the swarm, nothing rejects a submission without a dispute,
///         and an appeal exists only against an NFT decision (Phase.Decided).
/// forge-config: default.isolate = false
contract AuditNoMandatoryCheckTest is Base {
    uint256 internal t;
    uint256 internal s;

    function setUp() public override {
        super.setUp();
        // fixture: a $400 USDC task
        t = _create(author, address(usdc), 400e6);
        s = _submit(doer, t);
    }

    /// @notice No reward size asks the swarm: at every size tried, from $5 to $1,000, the submission is in Review
    ///         at once.
    function test_NoCheck_AtAnyRewardSize() public {
        uint256[5] memory usd = [uint256(5), 299, 300, 400, 1_000];
        for (uint256 i; i < usd.length; ++i) {
            uint256 ti = _create(author, address(usdc), usd[i] * 1e6);
            uint256 asked = intake.nonce();
            uint256 si = _submit(doer2, ti);
            Submission memory sub = _sub(si);
            assertEq(uint8(sub.phase), uint8(Phase.Review), "the dispute window at once");
            assertEq(sub.windowEnd, _now() + 24 hours);
            assertEq(sub.request, bytes32(0), "no question");
            assertEq(sub.asks, 0);
            assertEq(intake.nonce(), asked, "the Intake got nothing");
        }
        assertEq(imd.balanceOf(swarmPayee), 0, "nobody paid the swarm");
    }

    /// @notice Without an NFT decision there is nothing to appeal: right after submitting appeal and callSwarm revert
    ///         WrongPhase, and the submission can only be accepted by the timer or disputed.
    function test_NothingToAppeal_WithoutAnNftDecision() public {
        assertEq(uint8(_phase(s)), uint8(Phase.Review));
        vm.prank(doer);
        vm.expectRevert(WrongPhase.selector);
        vault.appeal(s, type(uint256).max, _noSwap());
        vm.prank(doer);
        vm.expectRevert(WrongPhase.selector);
        vault.callSwarm(s, true, type(uint256).max, _noSwap(), _genericRuleTexts());
        assertEq(uint8(_sub(s).nftDecision), uint8(Verdict.None));
        _claimEverythingAndCheck();
    }

    /// @notice Without a dispute nothing can reject: the
    ///         $400 submission is accepted by the timer, the doer gets 360 USDC and his whole bond back, the treasury
    ///         no IMD.
    function test_Undisputed_AcceptedByTimer_BondBack() public {
        Bond memory bond = _sub(s).bond;
        assertEq(bond.imd, 0.5e18); // fixed part
        assertEq(bond.rew, 12e6); // 3% of 400 USDC
        _warp(24 hours);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
        assertEq(vault.credits(address(usdc), doer), 360e6 + bond.rew);
        assertEq(vault.treasuryPot(address(usdc)), 40e6);
        assertEq(vault.credits(address(imd), doer), bond.imd);
        assertEq(vault.treasuryPot(address(imd)), 0);
        _claimEverythingAndCheck();
    }

    /// @notice The only rejection to appeal is
    ///         the NFT's, and its appeal takes the doer's side whoever files it (the doer or a third party); the
    ///         doer cannot appeal an NFT acceptance of his own submission.
    function test_AppealOnlyAgainstAnNftDecision() public {
        _dispute(dave, s);
        _vote(s, 1, 2, 120, 20); // NFT: reject
        _endVote(s);
        assertEq(uint8(_phase(s)), uint8(Phase.Decided));
        _appeal(erin, s); // anyone, for the doer
        assertTrue(vault.getAppeal(s).sidesDoer);
        // the ask is lazy: `appeal` only files it, waiting in Phase.Appealed for a
        // later `askAppealSwarm`.
        assertEq(uint8(_phase(s)), uint8(Phase.Appealed));

        uint256 t2 = _create(author, address(usdc), 400e6);
        uint256 s2 = _submit(doer2, t2);
        _dispute(dave, s2);
        _vote(s2, 1, 1, 120, 20); // NFT: accept
        _endVote(s2);
        vm.prank(doer2);
        vm.expectRevert(DoerCannotDispute.selector);
        vault.appeal(s2, type(uint256).max, _noSwap());
        _claimEverythingAndCheck();
    }

    /// @notice One appeal at a time: a second one reverts once the phase is `Appealed`.
    function test_NoDoubleAppeal() public {
        _dispute(dave, s);
        _vote(s, 1, 2, 120, 20);
        _endVote(s);
        _appeal(doer, s);
        assertEq(uint8(_phase(s)), uint8(Phase.Appealed)); // lazy ask
        vm.prank(doer);
        vm.expectRevert(WrongPhase.selector);
        vault.appeal(s, type(uint256).max, _noSwap());
        _claimEverythingAndCheck();
    }
}
