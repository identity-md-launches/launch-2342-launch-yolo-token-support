// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./Base.t.sol";

/// @dev What the alternative designs would cost: a cover kept in storage vs only emitted in an event.
contract CoverSink {
    string internal stored;

    event Cover(string cover);

    function store(string calldata c) external {
        stored = c;
    }

    function emitOnly(string calldata c) external {
        emit Cover(c);
    }
}

/// @dev Category and cover set once at creation: limits, the TaskCreated event, the swarm question without them, gas.
/// forge-config: default.isolate = false
contract CoverTest is Base {
    /// @dev A real CIDv1 (raw, sha256, base32): 59 characters, 66 bytes with the scheme.
    string internal constant IPFS_COVER = "ipfs://bafkreidivzimqfqtoqxkrpge6bjyhlvxqs3rhe73owtmdulaxr5do5in7u";

    function setUp() public override {
        super.setUp();
        _create(author, address(usdc), 50e6); // caches the parameter snapshot, so gas below is steady state
    }

    function _createWith(uint8 category, string memory cover) internal returns (uint256) {
        vm.prank(author);
        return vault.createTask{value: 0.001 ether}(
            address(usdc),
            50e6,
            uint64(_now() + TTL),
            "Title",
            rulesOf("Post a thread on X | Proof: link"),
            category,
            PROOF_LINK, // cover/category tests don't care about proof type, keep it optional
            cover,
            _noSwap()
        );
    }

    function _expectBadCover(string memory cover) internal {
        vm.prank(author);
        vm.expectRevert(BadCover.selector);
        vault.createTask{value: 0.001 ether}(
            address(usdc), 50e6, uint64(_now() + TTL), "Title", rulesOf("c"), 0, 0, cover, _noSwap()
        );
    }

    function test_CategoryStoredAndCoverEmitted() public {
        uint256 next = vault.taskCount() + 1;
        vm.expectEmit(address(vault));
        emit TaskCreated(
            next,
            author,
            address(usdc),
            50e6,
            uint64(_now() + TTL),
            "Title",
            rulesOf("Post a thread on X | Proof: link"),
            4,
            PROOF_LINK,
            IPFS_COVER
        );
        uint256 t = _createWith(4, IPFS_COVER);
        assertEq(t, next);
        Task memory task = vault.getTask(t);
        assertEq(task.category, 4);
        // storage holds only the hash; the full text is in the TaskCreated event
        // asserted above (vm.expectEmit) - this checks the hash still matches it byte for byte.
        assertEq(
            task.rulesHash, keccak256(abi.encode("Post a thread on X | Proof: link", TEST_RULE_PROOF, TEST_RULE_NO))
        );
        assertEq(uint8(task.status), uint8(TaskStatus.Open));
        assertEq(task.currency, address(usdc)); // packing the category next to it did not corrupt the slot
        assertEq(task.busyEpoch, 0);
    }

    function test_EmptyCoverAndEveryCategory() public {
        for (uint8 c; c < CATEGORY_COUNT; ++c) {
            assertEq(vault.getTask(_createWith(c, "")).category, c);
        }
        vm.prank(author);
        vm.expectRevert(BadCategory.selector);
        vault.createTask{value: 0.001 ether}(
            address(usdc), 50e6, uint64(_now() + TTL), "Title", rulesOf("c"), CATEGORY_COUNT, 0, "", _noSwap()
        );
        vm.prank(author);
        vm.expectRevert(BadCategory.selector);
        vault.createTask{value: 0.001 ether}(
            address(usdc), 50e6, uint64(_now() + TTL), "Title", rulesOf("c"), 255, 0, "", _noSwap()
        );
    }

    function test_CoverLinksAccepted() public {
        _createWith(0, IPFS_COVER);
        _createWith(0, "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi/cover.png");
        _createWith(0, "https://example.com/a.png?x=1&y=%20#f");
        _createWith(0, "ipfs://x");
        string memory max = string(abi.encodePacked("https://", _repeat("a", MAX_COVER_BYTES - 8)));
        assertEq(bytes(max).length, MAX_COVER_BYTES);
        _createWith(0, max);
    }

    function test_CoverLinksRejected() public {
        _expectBadCover(string(abi.encodePacked("https://", _repeat("a", MAX_COVER_BYTES - 7)))); // 161 bytes
        _expectBadCover("ipfs://");
        _expectBadCover("https://");
        _expectBadCover("http://example.com/a.png");
        _expectBadCover("IPFS://bafkrei");
        _expectBadCover("data:image/png;base64,AAAA");
        _expectBadCover("javascript:alert(1)");
        _expectBadCover("media:0123456789abcdef0123456789abcdef");
        _expectBadCover("https://a.com/x y.png");
        _expectBadCover('https://a.com/"onerror=x');
        _expectBadCover("https://a.com/<b>");
        _expectBadCover("https://a.com/x>");
        _expectBadCover("https://a.com/\\x");
        _expectBadCover("https://a.com/\x7f");
        _expectBadCover("https://a.com/\n");
        _expectBadCover("https://b\u00fccher.de/a.png"); // non-ASCII: IDNs go in punycode
    }

    /// @dev The swarm reads the condition and the claims only: a cover never reaches the question.
    function test_CoverNotInSwarmQuestion() public {
        uint256 t = _createWith(2, IPFS_COVER);
        uint256 s = _submit(doer, t);
        _dispute(dave, s);
        _warp(24 hours);
        vault.poke(t);
        (bytes memory body,) = vault.previewSwarmBody(
            s,
            2,
            RuleTexts("Post a thread on X | Proof: link", TEST_RULE_PROOF, TEST_RULE_NO, DISPUTE_REASON, DISPUTER_PROOF)
        );
        assertFalse(_contains(body, bytes("bafkrei")));
        assertFalse(_contains(body, bytes("ipfs://bafk")));
        assertTrue(_contains(body, bytes("Post a thread on X | Proof: link")));
    }

    /// @dev Neither field changes during the life of a task (no cover swap during a dispute).
    function test_CategoryUnchangedThroughDispute() public {
        uint256 t = _createWith(5, IPFS_COVER);
        uint256 s = _submit(doer, t);
        _dispute(dave, s);
        _warp(24 hours);
        // _createWith's task rules are not the generic fixture's ("ipfs://task-condition"): resupply the right
        // text here instead of _callSwarm's _genericRuleTexts(), or CaseDesk._ask reverts RulesMismatch.
        TaskRules memory r = rulesOf("Post a thread on X | Proof: link");
        RuleTexts memory rt = _genericRuleTexts();
        rt.task = r.task;
        rt.taskProof = r.proof;
        rt.taskNo = r.noIf;
        vm.prank(erin);
        vault.callSwarm{value: ETH_BOND_HEADROOM}(s, false, type(uint256).max, _noSwap(), rt);
        _answer(s, true);
        _warp(30 days);
        vault.poke(t);
        assertEq(vault.getTask(t).category, 5);
        _claimEverythingAndCheck();
    }

    /// forge-config: default.isolate = true
    function test_GasCover() public {
        uint256 g = gasleft();
        _createWith(0, "");
        uint256 noCover = g - gasleft();
        g = gasleft();
        _createWith(0, IPFS_COVER);
        uint256 withCover = g - gasleft();
        emit log_named_uint("createTask, no cover", noCover);
        emit log_named_uint("createTask, ipfs cover 66 bytes", withCover);
        emit log_named_uint("cover in the event, extra gas", withCover - noCover);
        assertLt(withCover - noCover, 20_000); // the byte check loop and the log; no storage

        CoverSink fresh = new CoverSink();
        fresh.emitOnly("warm"); // both measured calls below hit a warm account
        g = gasleft();
        fresh.store(IPFS_COVER);
        uint256 stored = g - gasleft();
        g = gasleft();
        fresh.emitOnly(IPFS_COVER);
        uint256 emitted = g - gasleft();
        emit log_named_uint("66-byte cover kept in storage (4 new slots)", stored);
        emit log_named_uint("66-byte cover only in an event", emitted);
        assertGt(stored, emitted + 80_000);
    }

    // ================================================================== helpers

    function _repeat(bytes1 ch, uint256 n) internal pure returns (bytes memory out) {
        out = new bytes(n);
        for (uint256 i; i < n; ++i) {
            out[i] = ch;
        }
    }

    function _contains(bytes memory hay, bytes memory needle) internal pure returns (bool) {
        if (needle.length > hay.length) return false;
        for (uint256 i; i <= hay.length - needle.length; ++i) {
            bool ok = true;
            for (uint256 j; j < needle.length; ++j) {
                if (hay[i + j] != needle[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }
}
