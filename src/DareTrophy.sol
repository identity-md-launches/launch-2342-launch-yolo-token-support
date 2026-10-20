// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {TextRules} from "./helpers/TextRules.sol";
import {Submission, Task, Outcome} from "./VaultTypes.sol";

/// @dev What the trophy reads from the vault and its CaseDesk (all set at deployment or once per task/submission).
interface ITrophyVault {
    function getTask(uint256 taskId) external view returns (Task memory);
    function caseDesk() external view returns (address);
    function textRules() external view returns (TextRules);
    function imd() external view returns (IERC20);
    function usdc() external view returns (IERC20);
    function yolo() external view returns (IERC20);
}

/// @dev The designs (TrophyCatalog): which design a new trophy gets, and a design's name and SVG.
interface ITrophyCatalog {
    function designFor(uint8 category) external view returns (uint256);
    function nameAndImage(uint256 id) external view returns (string memory, bytes memory);
}

interface ITrophyDesk {
    function getSubmission(uint256 subId) external view returns (Submission memory);
}

/// @title DareTrophy: an on-chain NFT trophy of an accepted submission
/// @notice The doer of an accepted submission may mint its trophy, once: the token id is the submission id. The price is
///         paid in $YOLO and burned (sent to 0x…dEaD: the token has no burn function): a fixed PRICE of 7,777 YOLO,
///         no USD conversion and no dev price.
///         Metadata live entirely on chain: tokenURI
///         is a JSON with a 24x24 pixel badge of the task's category (SVG), the task and submission numbers, the
///         title, the reward, the mint date and the proof link. The picture is the design the TrophyCatalog gave the
///         task's category at mint (its id is kept with the trophy and never changes; id 0 = the built-in badge). The title is given by the doer at mint (the vault keeps
///         the task title only in its TaskCreated event), checked with the vault's text rules; everything else comes
///         from the vault. No owner, no admin.
contract DareTrophy is ERC721 {
    using SafeERC20 for IERC20;
    using Strings for uint256;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant MAX_TITLE_BYTES = 64;
    /// @notice YOLO a trophy costs, burned at mint; never changes.
    uint256 public constant PRICE = 7_777e18;

    ITrophyVault public immutable vault;
    ITrophyDesk public immutable caseDesk;
    TextRules public immutable textRules;
    IERC20 public immutable yolo;
    address private immutable _imd;
    address private immutable _usdc;
    /// @notice The trophy designs, run by the project wallet.
    ITrophyCatalog public immutable catalog;

    struct Minted {
        uint64 time;
        uint64 taskId;
        uint64 design; // TrophyCatalog design id at mint, 0 = the built-in badge
        uint256 yoloBurned;
        string title;
    }

    mapping(uint256 => Minted) private _minted;
    /// @notice YOLO burned by all trophies together.
    uint256 public totalBurned;

    event TrophyMinted(uint256 indexed subId, uint256 indexed taskId, address indexed doer, uint256 yoloBurned);

    error BadSetup();
    error NotTheDoer();
    error NotAccepted();
    error BadTitle();

    /// @dev 16x16 pixel icons, 2 bytes per row, in the order of the categories (trash: bin, crazy: skull, action:
    ///      lightning, sport: dumbbell, food: chili, prank: clown mask, shill: megaphone, onchain, other); drawn at
    ///      (4,4) inside the 24x24 badge.
    bytes private constant ICONS =
        hex"000003c004207ffe7ffe00001ff81bd81bd81bd81bd81bd81bd81ff80ff00000000007e01ff83ffc7ffe7ffe63c663c663c67e7e3e7c1ff80db00ff007e00000000000fc01f803f007e00fc01ffc3ff800f801f003c007000c00100000000000000000000000300c700e700ef00ffffffffff00f700e700e300c00000000000000040008003c007e00fc01f803f007e00fc01f803f007c007800300010000000000007e09ff9dffbb99d799e7ffe7e7e7e7e7ffe6ff637ec18180ff003c0000000000008003800f803fa7ff87ffb7ff87ff87ffb7ff833fa30f8303800080000018007e01ff87ffe5ffa47e2418240824082408240826086189806a0018000000180018003c003c0ffff7ffe3ffc1ff80ff00ff01ff81e78381c300c40020000";

    /// @dev `catalog_`: the TrophyCatalog, deployed before the trophy in launch 3.
    constructor(address vault_, address catalog_) ERC721("moneycanbuy.fun trophy", "DARE") {
        if (vault_ == address(0) || catalog_ == address(0)) revert BadSetup();
        catalog = ITrophyCatalog(catalog_);
        ITrophyVault v = ITrophyVault(vault_);
        vault = v;
        caseDesk = ITrophyDesk(v.caseDesk());
        textRules = v.textRules();
        yolo = v.yolo();
        _imd = address(v.imd());
        _usdc = address(v.usdc());
    }

    /// @notice YOLO a trophy costs: always PRICE (a function for the site and off-chain readers).
    function price() public pure returns (uint256) {
        return PRICE;
    }

    /// @notice Mint the trophy of your accepted submission `subId`, burning PRICE in YOLO (pulled with
    ///         transferFrom). `title`: the task title, 1..64 bytes under the vault's text rules.
    function mint(uint256 subId, string calldata title) external {
        Submission memory s = caseDesk.getSubmission(subId);
        if (s.doer != msg.sender) revert NotTheDoer();
        if (s.outcome != Outcome.Accepted) revert NotAccepted();
        if (!textRules.validText(title, MAX_TITLE_BYTES)) revert BadTitle();
        uint256 design = catalog.designFor(vault.getTask(s.taskId).category);
        _minted[subId] = Minted(uint64(block.timestamp), s.taskId, uint64(design), PRICE, title);
        totalBurned += PRICE;
        _mint(msg.sender, subId); // reverts if this submission already has its trophy
        yolo.safeTransferFrom(msg.sender, DEAD, PRICE);
        emit TrophyMinted(subId, s.taskId, msg.sender, PRICE);
    }

    /// @notice Mint record of a trophy (time 0 = none).
    function mintedOf(uint256 subId) external view returns (Minted memory) {
        return _minted[subId];
    }

    function tokenURI(uint256 subId) public view override returns (string memory) {
        _requireOwned(subId);
        Minted memory m = _minted[subId];
        Task memory t = vault.getTask(m.taskId);
        Submission memory s = caseDesk.getSubmission(subId);
        string memory task = uint256(m.taskId).toString();
        (string memory designName, bytes memory image) =
            m.design == 0 ? ("Badge", bytes(badge(t.category))) : catalog.nameAndImage(m.design);
        string memory json = string.concat(
            '{"name":"Dare #',
            task,
            " trophy",
            '","description":"',
            m.title,
            ' (accepted on moneycanbuy.fun)","image":"data:image/svg+xml;base64,',
            Base64.encode(image),
            '","attributes":[{"trait_type":"Task","value":',
            task,
            '},{"trait_type":"Submission","value":',
            subId.toString(),
            '},{"trait_type":"Category","value":"',
            _categoryName(t.category),
            '"},{"trait_type":"Reward","value":"',
            _amount(s.reward, t.currency),
            '"},{"trait_type":"Proof","value":"',
            s.proofUri,
            '"},{"display_type":"date","trait_type":"Minted","value":',
            uint256(m.time).toString(),
            '},{"trait_type":"Design","value":"',
            designName,
            '"}]}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    /// @notice The 24x24 pixel badge of a category: gold frame, the category's colour, its white icon.
    function badge(uint8 category) public pure returns (string memory svg) {
        uint256 c = category < 9 ? category : 8;
        svg = string.concat(
            "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' shape-rendering='crispEdges'>",
            "<rect width='24' height='24' fill='#f5c542'/><rect x='1' y='1' width='22' height='22' fill='#",
            _colour(c),
            "'/>"
        );
        for (uint256 y; y < 16; ++y) {
            uint256 row = (uint256(uint8(ICONS[c * 32 + y * 2])) << 8) | uint8(ICONS[c * 32 + y * 2 + 1]);
            uint256 x;
            while (x < 16) {
                if (row & (1 << (15 - x)) == 0) {
                    ++x;
                    continue;
                }
                // slither-disable-next-line uninitialized-local
                uint256 w;
                while (x + w < 16 && row & (1 << (15 - x - w)) != 0) ++w;
                svg = string.concat(
                    svg,
                    "<rect x='",
                    (x + 4).toString(),
                    "' y='",
                    (y + 4).toString(),
                    "' width='",
                    w.toString(),
                    "' height='1' fill='#fff'/>"
                );
                x += w;
            }
        }
        svg = string.concat(svg, "</svg>");
    }

    function _colour(uint256 c) private pure returns (string memory) {
        return ["5d7a1f", "c2185b", "ef6c00", "1e88e5", "d32f2f", "8e24aa", "1d9bf0", "627eea", "7a7a7a"][c];
    }

    function _categoryName(uint8 c) private pure returns (string memory) {
        return ["Trash", "Crazy", "Action", "Sport", "Food", "Prank", "Shill", "Onchain", "Other"][c < 9 ? c : 8];
    }

    /// @dev "1234.5678 SYM": whole part and at most 4 decimals, trailing zeros trimmed.
    function _amount(uint256 raw, address currency) private view returns (string memory) {
        (uint256 decimals, string memory symbol) = currency == address(0)
            ? (18, "ETH")
            : currency == _usdc ? (6, "USDC") : currency == _imd ? (18, "IMD") : (18, "YOLO");
        uint256 unit = 10 ** decimals;
        uint256 frac = (raw % unit) * 10_000 / unit;
        string memory out = (raw / unit).toString();
        if (frac != 0) {
            bytes memory f = bytes(string.concat(frac < 10 ? "000" : frac < 100 ? "00" : frac < 1000 ? "0" : "", frac.toString()));
            uint256 len = 4;
            while (f[len - 1] == "0") --len;
            assembly ("memory-safe") {
                mstore(f, len)
            }
            out = string.concat(out, ".", string(f));
        }
        return string.concat(out, " ", symbol);
    }
}
