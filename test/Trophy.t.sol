// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./Base.t.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {console} from "forge-std/console.sol";
import {LaunchPlan, LocalFactory} from "../script/LaunchPlan.sol";

/// @dev DareTrophy: the doer of an accepted submission mints its NFT trophy once, burning its price in YOLO; the
///      metadata (JSON + SVG badge) are built on chain.
/// forge-config: default.isolate = false
contract TrophyTest is Base {
    function test_DoerMintsOnceBurningYolo() public {
        (uint256 t, uint256 s) = _accepted(address(usdc), 12_345_678, 3); // 12.345678 USDC, category sport
        assertEq(trophy.price(), 7_777e18, "fixed 7,777 YOLO");
        uint256 before = yolo.balanceOf(doer);
        uint256 dead0 = yolo.balanceOf(DEAD);
        _mint(doer, s, "Scream at the Charging Bull");
        assertEq(trophy.ownerOf(s), doer);
        assertEq(before - yolo.balanceOf(doer), 7_777e18);
        assertEq(yolo.balanceOf(DEAD) - dead0, 7_777e18, "burned to the dead address");
        assertEq(yolo.balanceOf(address(trophy)), 0, "the trophy keeps no YOLO");
        assertEq(trophy.totalBurned(), 7_777e18);
        assertEq(trophy.mintedOf(s).taskId, t);

        vm.prank(doer);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidSender.selector, address(0)));
        trophy.mint(s, "Again");
    }

    function test_OnlyTheDoerOfAnAcceptedSubmission() public {
        uint256 t = _create(author, address(imd), 10e18);
        uint256 s = _submit(doer, t);
        vm.prank(doer);
        vm.expectRevert(DareTrophy.NotAccepted.selector);
        trophy.mint(s, "Too early"); // still in review
        vm.warp(_sub(s).windowEnd + 1);
        vault.poke(t);
        vm.prank(doer2);
        vm.expectRevert(DareTrophy.NotTheDoer.selector);
        trophy.mint(s, "Not mine");
        vm.prank(doer);
        vm.expectRevert(DareTrophy.NotTheDoer.selector);
        trophy.mint(999, "No such submission");

        // a rejected submission has no trophy
        uint256 t2 = _create(author, address(imd), 10e18);
        uint256 s2 = _submit(doer2, t2);
        _dispute(dave, s2);
        _vote(s2, 0, 2, 0, 120);
        _warp(48 hours);
        vault.poke(t2);
        assertEq(uint8(_sub(s2).outcome), uint8(Outcome.Rejected));
        vm.prank(doer2);
        vm.expectRevert(DareTrophy.NotAccepted.selector);
        trophy.mint(s2, "Rejected");
        _claimEverythingAndCheck();
    }

    function test_TitleGuards() public {
        (, uint256 s) = _accepted(address(imd), 10e18, 0);
        string[3] memory bad = ["", 'say "hi"', "0123456789012345678901234567890123456789012345678901234567890123x"];
        for (uint256 i; i < 3; ++i) {
            vm.prank(doer);
            vm.expectRevert(DareTrophy.BadTitle.selector);
            trophy.mint(s, bad[i]);
        }
    }

    /// 7,777 YOLO, whatever the dev price of YOLO is, set, zero or
    /// broken: the trophy never reads it.
    function test_FixedPrice_IgnoresTheDevPrice() public {
        assertEq(trophy.PRICE(), 7_777e18);
        oracle.set(address(yolo), 0, 18);
        assertEq(trophy.price(), 7_777e18);
        oracle.setBroken(true);
        assertEq(trophy.price(), 7_777e18);
        oracle.setBroken(false);
        oracle.set(address(yolo), 0.01e18, 18);
        assertEq(trophy.price(), 7_777e18);
    }

    function test_MetadataOnChain() public {
        (uint256 t, uint256 s) = _accepted(address(usdc), 12_345_678, 2);
        _mint(doer, s, "Scream at the Charging Bull");
        string memory uri = trophy.tokenURI(s);
        string memory prefix = "data:application/json;base64,";
        assertTrue(_startsWith(uri, prefix));
        string memory json = string(_b64decode(_slice(bytes(uri), bytes(prefix).length)));
        assertEq(vm.parseJsonString(json, ".name"), string.concat("Dare #", vm.toString(t), " trophy"));
        assertEq(vm.parseJsonString(json, ".description"), "Scream at the Charging Bull (accepted on moneycanbuy.fun)");
        assertEq(vm.parseJsonUint(json, ".attributes[0].value"), t);
        assertEq(vm.parseJsonUint(json, ".attributes[1].value"), s);
        assertEq(vm.parseJsonString(json, ".attributes[2].value"), "Action");
        assertEq(vm.parseJsonString(json, ".attributes[3].value"), "12.3456 USDC");
        assertEq(vm.parseJsonString(json, ".attributes[4].value"), "https://x.com/doer/status/1");
        assertEq(vm.parseJsonUint(json, ".attributes[5].value"), _now());
        string memory img = vm.parseJsonString(json, ".image");
        string memory svg = string(_b64decode(_slice(bytes(img), 26))); // "data:image/svg+xml;base64,"
        assertEq(svg, trophy.badge(2));
        assertTrue(_startsWith(svg, "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'"));

        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 999));
        trophy.tokenURI(999);
    }

    function test_RewardFormatting() public {
        (, uint256 s1) = _accepted(ETH, 0.01 ether, 1);
        _mint(doer, s1, "ETH task");
        assertTrue(_contains(_json(s1), '"Reward","value":"0.01 ETH"'));
        (, uint256 s2) = _accepted(address(yolo), 2_000_000e18, 6);
        _mint(doer, s2, "YOLO task");
        assertTrue(_contains(_json(s2), '"Reward","value":"2000000 YOLO"'));
    }

    /// @dev Every category has its own badge, every badge is a valid 24x24 SVG with at least one pixel of its icon.
    function test_BadgesPerCategory() public view {
        for (uint8 c; c < 10; ++c) {
            string memory svg = trophy.badge(c);
            assertTrue(_startsWith(svg, "<svg"));
            assertTrue(_contains(svg, "fill='#fff'/>"));
            if (c > 0 && c < 9) assertNotEq(keccak256(bytes(svg)), keccak256(bytes(trophy.badge(c - 1))));
        }
        assertEq(trophy.badge(9), trophy.badge(8), "an unknown category draws as other");
    }

    // ------------------------------------------------------------------ helpers

    // ---- TrophyCatalog ----

    string constant SVG1 =
        "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'><rect width='24' height='24' fill='#f5c542'/></svg>";
    string constant SVG2 =
        "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'><circle cx='12' cy='12' r='10' fill='#1e88e5'/></svg>";

    function _add(string memory name, string memory svg) internal returns (uint256 id) {
        vm.prank(multisig);
        id = catalog.addDesign(name, bytes(svg));
    }

    function _image(uint256 s) internal view returns (string memory) {
        string memory img = vm.parseJsonString(_json(s), ".image");
        return string(_b64decode(_slice(bytes(img), 26)));
    }

    /// Scenario 1: the owner adds a design; nothing changes for new trophies until it is assigned.
    function test_Catalog_OwnerAddsDesign() public {
        assertEq(catalog.owner(), multisig);
        assertEq(address(trophy.catalog()), address(catalog));
        vm.expectEmit(address(catalog));
        emit TrophyCatalog.DesignAdded(1, "Gold v1", bytes(SVG1).length);
        uint256 id = _add("Gold v1", SVG1);
        assertEq(id, 1);
        assertEq(catalog.designCount(), 1);
        TrophyCatalog.Design memory d = catalog.design(1);
        assertEq(d.name, "Gold v1");
        assertEq(string(d.image), SVG1);
        assertTrue(d.enabled);
        assertEq(d.addedAt, _now());
        assertEq(catalog.designFor(3), 0, "not assigned: built-in badge");
        (, uint256 s) = _accepted(address(imd), 10e18, 3);
        _mint(doer, s, "Sport");
        assertEq(trophy.mintedOf(s).design, 0);
        assertEq(_image(s), trophy.badge(3));
        assertEq(vm.parseJsonString(_json(s), ".attributes[6].value"), "Badge");
    }

    /// Scenario 2 + 3: the owner updates a category's trophy (new design, reassign); the doer mints and gets it.
    function test_Catalog_UpdateThenMint() public {
        uint256 v1 = _add("Sport v1", SVG1);
        vm.prank(multisig);
        catalog.setCategoryDesign(3, v1);
        (, uint256 s1) = _accepted(address(imd), 10e18, 3);
        _mint(doer, s1, "Sport one");
        assertEq(trophy.mintedOf(s1).design, v1);
        assertEq(_image(s1), SVG1);
        assertEq(vm.parseJsonString(_json(s1), ".attributes[6].value"), "Sport v1");
        assertEq(trophy.totalBurned(), 7_777e18, "price and burn unchanged");

        uint256 v2 = _add("Sport v2", SVG2);
        vm.prank(multisig);
        catalog.setCategoryDesign(3, v2);
        (, uint256 s2) = _accepted(address(imd), 10e18, 3);
        _mint(doer, s2, "Sport two");
        assertEq(trophy.mintedOf(s2).design, v2);
        assertEq(_image(s2), SVG2);
        // scenario 4: the old trophy keeps v1
        assertEq(_image(s1), SVG1);
        // another category falls back to the default, then to the badge
        (, uint256 s3) = _accepted(address(imd), 10e18, 4);
        vm.prank(multisig);
        catalog.setDefaultDesign(v1);
        _mint(doer, s3, "Food");
        assertEq(trophy.mintedOf(s3).design, v1, "default design");
        vm.prank(multisig);
        catalog.setDefaultDesign(0);
        assertEq(catalog.designFor(4), 0);
        assertEq(catalog.designFor(3), v2);
    }

    /// Scenario 4: switching a design off affects new mints only; minted trophies keep it.
    function test_Catalog_DisableKeepsMinted() public {
        uint256 v1 = _add("Sport v1", SVG1);
        uint256 v2 = _add("Any v2", SVG2);
        vm.startPrank(multisig);
        catalog.setCategoryDesign(3, v1);
        catalog.setDefaultDesign(v2);
        vm.stopPrank();
        (, uint256 s1) = _accepted(address(imd), 10e18, 3);
        _mint(doer, s1, "Sport one");
        vm.prank(multisig);
        catalog.setDesignEnabled(v1, false);
        assertEq(catalog.designFor(3), v2, "switched off: default");
        assertEq(_image(s1), SVG1, "minted trophy unchanged");
        (, uint256 s2) = _accepted(address(imd), 10e18, 3);
        _mint(doer, s2, "Sport two");
        assertEq(trophy.mintedOf(s2).design, v2);
        vm.prank(multisig);
        catalog.setDesignEnabled(v2, false);
        assertEq(catalog.designFor(3), 0, "everything off: badge");
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(TrophyCatalog.DesignOff.selector, v1));
        catalog.setCategoryDesign(3, v1);
        vm.prank(multisig);
        catalog.setDesignEnabled(v1, true);
        assertEq(catalog.designFor(3), v1, "back on");
    }

    /// Scenario 5: a stranger cannot add, assign or switch designs; nobody can rewrite a design or a minted trophy.
    function test_Catalog_StrangerCannotEdit() public {
        uint256 v1 = _add("Gold v1", SVG1);
        address x = makeAddr("stranger");
        bytes memory err = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, x);
        vm.startPrank(x);
        vm.expectRevert(err);
        catalog.addDesign("Mine", bytes(SVG2));
        vm.expectRevert(err);
        catalog.setCategoryDesign(3, v1);
        vm.expectRevert(err);
        catalog.setDefaultDesign(v1);
        vm.expectRevert(err);
        catalog.setDesignEnabled(v1, false);
        vm.expectRevert(err);
        catalog.transferOwnership(x);
        vm.stopPrank();
        // two-step owner change, like the ParamsRegistry
        vm.prank(multisig);
        catalog.transferOwnership(x);
        assertEq(catalog.owner(), multisig);
        vm.prank(x);
        catalog.acceptOwnership();
        assertEq(catalog.owner(), x);
    }

    function test_Catalog_Guards() public {
        vm.startPrank(multisig);
        vm.expectRevert(TrophyCatalog.BadName.selector);
        catalog.addDesign("", bytes(SVG1));
        vm.expectRevert(TrophyCatalog.BadName.selector);
        catalog.addDesign('a "quote"', bytes(SVG1));
        vm.expectRevert(TrophyCatalog.BadName.selector);
        catalog.addDesign("0123456789012345678901234567890123", bytes(SVG1));
        vm.expectRevert(TrophyCatalog.BadImage.selector);
        catalog.addDesign("x", bytes("<png>"));
        vm.expectRevert(TrophyCatalog.BadImage.selector);
        catalog.addDesign("x", bytes("<svg></svgx"));
        vm.expectRevert(TrophyCatalog.BadImage.selector);
        catalog.addDesign("x", abi.encodePacked("<svg>", hex"00", "</svg>"));
        vm.expectRevert(TrophyCatalog.BadImage.selector);
        catalog.addDesign("x", abi.encodePacked("<svg>", hex"c3a9", "</svg>"));
        bytes memory big = new bytes(8_193);
        for (uint256 i; i < big.length; ++i) {
            big[i] = "a";
        }
        bytes memory pre = "<svg";
        bytes memory post = "</svg>";
        for (uint256 i; i < 4; ++i) {
            big[i] = pre[i];
        }
        for (uint256 i; i < 6; ++i) {
            big[big.length - 6 + i] = post[i];
        }
        vm.expectRevert(TrophyCatalog.BadImage.selector);
        catalog.addDesign("x", big);
        assembly ("memory-safe") {
            mstore(big, 8192)
        }
        for (uint256 i; i < 6; ++i) {
            big[8192 - 6 + i] = post[i];
        }
        uint256 g = gasleft();
        uint256 id = catalog.addDesign("Max", big);
        console.log("addDesign gas, 8192-byte SVG:", g - gasleft());
        vm.expectRevert(TrophyCatalog.BadCategory.selector);
        catalog.setCategoryDesign(9, id);
        vm.expectRevert(abi.encodeWithSelector(TrophyCatalog.NoDesign.selector, 2));
        catalog.setCategoryDesign(0, 2);
        vm.expectRevert(abi.encodeWithSelector(TrophyCatalog.NoDesign.selector, 0));
        catalog.setDesignEnabled(0, false);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(TrophyCatalog.NoDesign.selector, 5));
        catalog.design(5);
        assertEq(catalog.designFor(200), 0, "unknown category: badge");
    }

    function test_Catalog_NeedsAddress() public {
        vm.expectRevert(DareTrophy.BadSetup.selector);
        new DareTrophy(address(vault), address(0));
    }

    /// Launch 3 (LaunchPlan.extrasWith, six contracts with TrophyCatalog) in one transaction: execution gas through the
    /// local factory, plus intrinsic gas (21,000 + 16 per calldata byte, an upper bound) under the 16,777,216 cap.
    function test_Catalog_Launch3Gas() public {
        LocalFactory f = new LocalFactory();
        (bytes[] memory codes, bytes32[] memory names, address[] memory addrs) =
            LaunchPlan.extrasWith(f, 3, address(vault), multisig, 1, address(nft), address(delegates));
        uint256 g = gasleft();
        address[] memory out = f.launchContracts(3, codes);
        uint256 used = g - gasleft();
        bytes memory cd = abi.encodeCall(LocalFactory.launchContracts, (3, codes));
        uint256 total = used + 21_000 + 16 * cd.length;
        for (uint256 i; i < out.length; ++i) {
            assertEq(out[i], addrs[i]);
            console.log(string(abi.encodePacked(names[i])), out[i].code.length, "runtime bytes");
            assertLe(out[i].code.length, 24_576);
        }
        console.log("launch 3 execution gas", used);
        console.log("launch 3 calldata bytes", cd.length);
        console.log("launch 3 total gas (upper bound)", total);
        assertLt(total, 16_777_216);
        assertEq(TrophyCatalog(out[1]).owner(), multisig);
        assertEq(address(DareTrophy(out[2]).catalog()), out[1], "the catalog is deployed before the trophy");
    }

    function _accepted(address currency, uint256 amount, uint8 category) internal returns (uint256 t, uint256 s) {
        uint256 value = currency == ETH ? amount : 0;
        vm.prank(author);
        t = vault.createTask{value: value}(
            currency,
            amount,
            uint64(_now() + TTL),
            "Title",
            rulesOf("ipfs://task-condition"),
            category,
            PROOF_LINK, // evidence-required: trophy tests don't care about proof type, keep it optional
            "",
            _noSwap()
        );
        trackedTasks.push(t);
        s = _submit(doer, t); // no task has a mandatory swarm check
        vm.warp(_sub(s).windowEnd + 1);
        vault.poke(t);
        assertEq(uint8(_sub(s).outcome), uint8(Outcome.Accepted));
    }

    function _mint(address who, uint256 s, string memory title) internal {
        vm.prank(who);
        trophy.mint(s, title);
    }

    function _json(uint256 s) internal view returns (string memory) {
        return string(_b64decode(_slice(bytes(trophy.tokenURI(s)), 29)));
    }

    function _startsWith(string memory a, string memory p) internal pure returns (bool) {
        bytes memory x = bytes(a);
        bytes memory y = bytes(p);
        if (x.length < y.length) return false;
        for (uint256 i; i < y.length; ++i) {
            if (x[i] != y[i]) return false;
        }
        return true;
    }

    function _contains(string memory a, string memory n) internal pure returns (bool) {
        bytes memory x = bytes(a);
        bytes memory y = bytes(n);
        for (uint256 i; i + y.length <= x.length; ++i) {
            bool ok = true;
            for (uint256 j; j < y.length && ok; ++j) {
                ok = x[i + j] == y[j];
            }
            if (ok) return true;
        }
        return false;
    }

    function _slice(bytes memory b, uint256 from) internal pure returns (bytes memory out) {
        out = new bytes(b.length - from);
        for (uint256 i; i < out.length; ++i) {
            out[i] = b[from + i];
        }
    }

    function _b64decode(bytes memory d) internal pure returns (bytes memory out) {
        bytes memory table = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        uint8[128] memory rev;
        for (uint8 i; i < 64; ++i) {
            rev[uint8(table[i])] = i;
        }
        uint256 pad = d.length > 0 && d[d.length - 1] == "=" ? (d.length > 1 && d[d.length - 2] == "=" ? 2 : 1) : 0;
        out = new bytes(d.length / 4 * 3 - pad);
        uint256 k;
        for (uint256 i; i < d.length; i += 4) {
            uint256 n = (uint256(rev[uint8(d[i])]) << 18) | (uint256(rev[uint8(d[i + 1])]) << 12)
                | (uint256(d[i + 2] == "=" ? 0 : rev[uint8(d[i + 2])]) << 6)
                | uint256(d[i + 3] == "=" ? 0 : rev[uint8(d[i + 3])]);
            if (k < out.length) out[k++] = bytes1(uint8(n >> 16));
            if (k < out.length) out[k++] = bytes1(uint8(n >> 8));
            if (k < out.length) out[k++] = bytes1(uint8(n));
        }
    }
}
