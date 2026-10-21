// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./Base.t.sol";
import {TextRules} from "../src/helpers/TextRules.sol";

/// @notice Host allowlist of proof and screenshot links (TextLib.checkHost): `https://`, at most
/// MAX_LINK_BYTES, the host byte for byte from the list (one `www.` / `m.` / `mobile.` prefix dropped). The
/// list itself is the one in src/helpers/TextRules.sol.
/// forge-config: default.isolate = false
contract HostsTest is Base {
    TextRules internal rules;

    string[22] internal HOSTS = [
        "x.com",
        "twitter.com",
        "pbs.twimg.com",
        "youtube.com",
        "youtu.be",
        "tiktok.com",
        "instagram.com",
        "drive.google.com",
        "lh3.googleusercontent.com",
        "photos.google.com",
        "imgur.com",
        "i.imgur.com",
        "t.me",
        "ibb.co",
        "i.ibb.co",
        "reddit.com",
        "i.redd.it",
        "dropbox.com",
        "arweave.net",
        "etherscan.io",
        "sepolia.etherscan.io",
        "github.com"
    ];

    function setUp() public override {
        super.setUp();
        rules = new TextRules();
    }

    function test_EveryHostPasses() public view {
        for (uint256 i; i < HOSTS.length; ++i) {
            string memory h = HOSTS[i];
            rules.checkProof(string.concat("https://", h, "/p/1"), PROOF_LINK);
            rules.checkProof(string.concat("https://", h), PROOF_LINK);
            rules.checkProof(string.concat("https://", h, "?a=1"), PROOF_LINK);
            rules.checkProof(string.concat("https://", h, "#f"), PROOF_LINK);
            rules.checkProof(string.concat("https://www.", h, "/p"), PROOF_LINK);
            rules.checkProof(string.concat("https://m.", h, "/p"), PROOF_LINK);
            rules.checkProof(string.concat("https://mobile.", h, "/p"), PROOF_LINK);
            rules.checkScreenshotUrl(string.concat("https://", h, "/shot.png"));
        }
    }

    function test_BadHostsRevert() public {
        string[16] memory bad = [
            "https://evil.com/a",
            "https://x.com.evil.com/a",
            "https://evil.com/x.com",
            "http://x.com/a",
            "https://x.com:8080/a",
            "https://user@x.com/a",
            "",
            "https://",
            "https:// x.com/a",
            "https://X.com/a",
            "https://www.www.x.com/a",
            "https://evilx.com/a",
            "https://x.co/a",
            "ftp://x.com/a",
            "https://x.com\\@evil.com/a",
            "https://xx.com/a"
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(HostNotAllowed.selector);
            rules.checkProof(bad[i], PROOF_LINK);
            if (bytes(bad[i]).length != 0) {
                // empty = no screenshot, allowed
                vm.expectRevert(HostNotAllowed.selector);
                rules.checkScreenshotUrl(bad[i]);
            }
        }
    }

    function test_LengthLimit() public {
        bytes memory path = new bytes(MAX_LINK_BYTES - 19); // "https://github.com/" is 19 bytes
        for (uint256 i; i < path.length; ++i) {
            path[i] = "a";
        }
        rules.checkProof(string.concat("https://github.com/", string(path)), PROOF_LINK); // exactly 512
        vm.expectRevert(HostNotAllowed.selector);
        rules.checkProof(string.concat("https://github.com/", string(path), "a"), PROOF_LINK); // 513
    }

    /// @dev The vault enforces it on submit, both for the proof and the screenshot; an empty proof is BadText first.
    function test_SubmitRejectsOffListLinks() public {
        uint256 t = _create(author, address(usdc), 50e6); // PROOF_LINK task: any allowlisted link
        vm.prank(doer);
        vm.expectRevert(HostNotAllowed.selector);
        vault.submit(
            t,
            "https://x.com.evil.com/doer/status/1",
            Evidence("https://i.imgur.com/s.png", ""),
            0,
            type(uint256).max,
            _noSwap()
        );
        vm.prank(doer);
        vm.expectRevert(HostNotAllowed.selector);
        vault.submit(
            t,
            "https://x.com/doer/status/1",
            Evidence("https://evil.com/x.com/s.png", ""),
            0,
            type(uint256).max,
            _noSwap()
        );
        vm.prank(doer);
        vm.expectRevert(BadText.selector);
        vault.submit(t, "", Evidence("https://i.imgur.com/s.png", ""), 0, type(uint256).max, _noSwap());
        vm.prank(doer);
        vault.submit(
            t,
            "https://x.com/doer/status/1",
            Evidence("https://pbs.twimg.com/media/a.jpg", ""),
            0,
            type(uint256).max,
            _noSwap()
        );
    }
}
