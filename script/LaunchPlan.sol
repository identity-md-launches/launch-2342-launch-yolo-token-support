// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TaskVault} from "../src/TaskVault.sol";
import {YoloSweetener} from "../src/YoloSweetener.sol";
import {YoloPredict} from "../src/YoloPredict.sol";
import {YoloLockHub} from "../src/YoloLockHub.sol";
import {BuybackBurner} from "../src/BuybackBurner.sol";
import {DareTrophy} from "../src/DareTrophy.sol";
import {TrophyCatalog} from "../src/TrophyCatalog.sol";
import {ParamsRegistry} from "../src/ParamsRegistry.sol";
import {CaseDesk} from "../src/desks/CaseDesk.sol";
import {DisputeDesk} from "../src/desks/DisputeDesk.sol";
import {TextRules} from "../src/helpers/TextRules.sol";
import {SwarmQuestionBuilder} from "../src/helpers/SwarmQuestion.sol";
import {AttestationChecker} from "../src/helpers/AttestationChecker.sol";
import {VotePower} from "../src/VotePower.sol";
import {UniswapV3SwapAdapter} from "../src/adapters/UniswapV3SwapAdapter.sol";
import {DevPrices} from "../src/DevPrices.sol";
import {YoloToken} from "../src/token/YoloToken.sol";
import {NftGate} from "../src/token/NftGate.sol";
import {YoloSplitter} from "../src/token/YoloSplitter.sol";
import {IncentivesVesting, DevVesting, TeamVesting, TreasuryVesting} from "../src/token/Vestings.sol";
import {ProtocolDirectory} from "../src/ProtocolDirectory.sol";
import {HiddenList} from "../src/HiddenList.sol";

/// @notice What the plan needs from a factory: the address a creation code (with its constructor arguments) gets at
///         a position of a launch. The IMD ProjectFactory and the LocalFactory both answer it.
interface IContractFactory {
    function predictContract(uint64 launchNumber, uint256 index, bytes calldata code) external view returns (address);
}

/// @notice The launch in code: which contracts, in which order, with which constructor arguments (`launch.json`
///         written as Solidity). The whole system does not fit one transaction under the 16,777,216 gas cap
///         (EIP-7825), so it goes in launches:
///         0. `genesisLaunch` (evm_contracts): the NFT gate (snapshot) of $YOLO's first 30 minutes, the four
///            vestings and the YoloSplitter, the fixed `remainderTo` of launch 1 that hands the project's 75% out.
///         1. `support` as the custom_token launch of $YOLO (`yoloTokenCode`): the token, its YOLO/IMD pool and the
///            swarm's share (the factory's), then DevPrices (fixed prices, no oracle), the
///            swap adapter, the parameter registry, the four stateless helpers and the BuybackBurner (8 contracts:
///            the factory's maximum per launch). Nothing here holds user money.
///         2. `core` (the main launch): the doer stake (YoloLockHub) first, then the two desks and the vault, last.
///            The vault's constructor wires the desks (Desk.wire), which only works inside the transaction that
///            deployed them, so the desks and the vault must be one launch; the DisputeDesk names the hub of this
///            launch ($contract: may only name an earlier contract). Every address of launch 1 is a static argument.
///            Indices: 0 YoloLockHub, 1 CaseDesk, 2 DisputeDesk, 3 TaskVault (`CORE_*`).
///         3. `extras` (evm_contracts): the $YOLO modules of that vault and the lists, in this order: YoloSweetener,
///            TrophyCatalog, DareTrophy, ProtocolDirectory, HiddenList, YoloPredict.
///         Used by the fork rehearsal against the live ProjectFactory (test/fork/LaunchRehearsal.fork.t.sol) and by
///         local deployments. docs/LAUNCH-TASK.md is the same plan in words.
library LaunchPlan {
    // ---- Ethereum mainnet counterparties (see script/DeployMainnet.s.sol)
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant ROUTER02 = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address internal constant DELEGATE_XYZ = 0x00000000000000447e69651d841bD8D104Bed493;
    // the swarm Intake, version 2 (the swarm reference: "use version 2 for anything new"; it keeps every function of
    // version 1, 0x1397434cd35e8a9c8ac312a61d3a285eb31dea56, which is still served; swarm audit 117cf05a #11)
    address internal constant INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    address internal constant NFT = 0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D;
    address internal constant ATTESTER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;
    // Uniswap v4 on mainnet: the PoolManager that holds the YOLO/IMD pool the launch factory opens
    address internal constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    // the key every launch-factory pool gets (Initialize of launch #1298, tx 0xf00465dd…): the factory's
    // PoolInitializationGuard hook, a 1.25% LP fee, tick spacing 60
    address internal constant POOL_GUARD = 0x784FF9a3ac5d88A30bfff6F7f2a270161FBE6000;
    uint24 internal constant POOL_FEE = 12_500;
    int24 internal constant POOL_TICK_SPACING = 60;
    // DevPrices starting parameters: fixed prices, no oracle, set by hand.
    // $YOLO, ETH and IMD: fixed starting prices in USD per whole token. These prices may be updated
    // afterwards as the market moves (at most x10 per call); they size only the stake bonus (the trophy has a
    // fixed 7,777 YOLO price).
    uint256 internal constant YOLO_PRICE_USD = 0.001e18;
    uint256 internal constant ETH_USD_START = 2_400e18;
    uint256 internal constant IMD_USD_START = 5.5e18;
    // $YOLO: 1B. Trading opens at openAt, fixed at deployment. Minutes 0-30 after it: the wallets of the
    // NFT gate's snapshot of identity.md NFT holders only (500,000 per NFT, no registration), minutes
    // 30-60 buy and sell tax 30% -> 0 to the project wallet, then a plain ERC-20 (YoloToken)
    uint256 internal constant YOLO_SUPPLY = 1_000_000_000e18;
    // shares: swarm 10% and pool 15% by the
    // factory, the project's 75% through the YoloSplitter: incentives 25% (vesting), Stabilizer 15%, dev 7.7777777%, team
    // 5%, treasury the rest (22.2222223%)
    uint16 internal constant YOLO_POOL_BPS = 1_500;
    // the opening valuation of the 1B YOLO in IMD (`economics.initialMarketCapWei` of launch 1, policy 250..250,000)
    uint256 internal constant YOLO_OPENING_MCAP_IMD = 15_000e18;
    // YoloPredict: anti-dust floor of one position, 1 YOLO
    uint256 internal constant PREDICT_MIN_POSITION = 1e18;

    /// @notice Addresses of launch 1 (all of them are static constructor arguments of launch 2).
    struct Support {
        address devPrices;
        address swapAdapter;
        address registry;
        address textRules;
        address questionBuilder;
        address votePower; // who may vote with an NFT now; no state
        address attestationChecker;
        address burner; // BuybackBurner
    }

    /// @notice The counterparties of the parameter registry's version 1. Mainnet: `mainnet(owner, treasury)`.
    struct Counterparties {
        address owner; // ParamsRegistry owner: the project wallet PROJECT_TREASURY (no Safe)
        address intake;
        address nft;
        address delegateRegistry;
        address treasury; // project treasury
        address attester;
        address imd;
        address usdc;
    }

    function mainnet(address owner, address treasury) internal pure returns (Counterparties memory c) {
        c = Counterparties(owner, INTAKE, NFT, DELEGATE_XYZ, treasury, ATTESTER, IMD, USDC);
    }

    /// @notice The YOLO/IMD pool key the launch factory opens (no price reads it: DevPrices is a dev parameter).
    struct YoloPool {
        address token;
        address hooks;
        uint24 fee;
        int24 tickSpacing;
    }

    /// @notice The pool the launch factory opens for `token` against IMD.
    function yoloPool(address token) internal pure returns (YoloPool memory) {
        return YoloPool(token, POOL_GUARD, POOL_FEE, POOL_TICK_SPACING);
    }

    /// @notice The $YOLO creation code (with its constructor arguments) as the factory deploys it: `$poolManager`, the
    ///         NftGate of launch 0, the project wallet (the treasury) that receives the buy tax and `openAt`, when
    ///         trading opens (unix seconds, not before the deployment, at most 30 days after it).
    function yoloTokenCode(address gate, address taxRecipient, uint256 openAt) internal pure returns (bytes memory) {
        return abi.encodePacked(type(YoloToken).creationCode, abi.encode(POOL_MANAGER, gate, taxRecipient, openAt));
    }

    // ---- the project's wallets (EOAs, checksums checked): plan arguments only, no contract
    // holds them. docs/LAUNCH-TASK.md writes the same addresses into the launch texts.
    address internal constant PROJECT_TREASURY = 0x3c587Eff6c96eAcF7E3dcC2CFf6416161386E48C; // treasury, buy tax, owner of registry + directory
    address internal constant PROJECT_INCENTIVES = 0x7085193516EDc587fAebFF7a48548eAC8db5fAb5;
    address internal constant PROJECT_STABILIZER = 0xaaB0269b956bd5F97B44529569b042e7BD72B508;
    address internal constant PROJECT_DEV = 0x8Ad18E99F4C8d8406f9Ba8899CF308000518A981;
    address internal constant PROJECT_TEAM = 0x153D12cc398d79A99B781B23DB6399556b84ca76;
    // the buyback wallet: the BuybackBurner's `forward` sends ETH, USDC
    // and IMD here; a dev parameter afterwards (BuybackBurner.setBuybackWallet)
    address internal constant PROJECT_BUYBACK = 0x027E55f01e8Cf808E5D2a2Ad68E5e7f67fD6dF6E;

    /// @notice The project's wallets for the mainnet launch.
    function projectOwners() internal pure returns (Owners memory) {
        return Owners(PROJECT_TREASURY, PROJECT_INCENTIVES, PROJECT_STABILIZER, PROJECT_DEV, PROJECT_TEAM);
    }

    /// @notice The owner's addresses of launch 0 (mainnet: `projectOwners()`; tests use their own).
    struct Owners {
        address treasury; // the project wallet (an EOA): beneficiary of the treasury vesting, receives the buy tax,
        // owns ParamsRegistry and ProtocolDirectory (passed to `mainnet` and `extras`), writes and seals the NftGate
        // snapshot
        address incentives; // beneficiary of the incentives vesting
        address stabilizer; // the manual YOLO Stabilizer wallet, 150M at once
        address dev; // beneficiary of the dev vesting
        address team; // beneficiary of the team vesting
    }

    /// @notice Addresses of launch 0.
    struct Genesis {
        address gate;
        address incentives;
        address dev;
        address team;
        address treasury;
        address splitter;
    }

    /// @notice Launch 0 (evm_contracts, before the $YOLO launch): the NftGate of the first 30 minutes, the four
    ///         vestings and the YoloSplitter. The $YOLO launch's `remainderTo` must be a fixed address and the token
    ///         needs the gate's, so all of it exists first and knows no token in advance. The project wallet
    ///         (`o.treasury`) writes the gate's snapshot of NFT holders shortly before the token launch and seals it
    ///         before `openAt` (script/snapshot/: holders read at a block, json + batches).
    function genesisLaunch(IContractFactory f, uint64 launchNumber, Owners memory o)
        internal
        view
        returns (bytes[] memory codes, bytes32[] memory names, Genesis memory g)
    {
        return genesisLaunchWith(f, launchNumber, o, NFT);
    }

    /// @notice Launch 0 with any NFT (a local deployment uses a mock).
    function genesisLaunchWith(IContractFactory f, uint64 launchNumber, Owners memory o, address nft)
        internal
        view
        returns (bytes[] memory codes, bytes32[] memory names, Genesis memory g)
    {
        codes = new bytes[](6);
        names = new bytes32[](6);
        codes[0] = abi.encodePacked(type(NftGate).creationCode, abi.encode(nft, o.treasury));
        names[0] = "NftGate";
        g.gate = f.predictContract(launchNumber, 0, codes[0]);
        codes[1] = abi.encodePacked(type(IncentivesVesting).creationCode, abi.encode(o.incentives));
        names[1] = "IncentivesVesting";
        g.incentives = f.predictContract(launchNumber, 1, codes[1]);
        codes[2] = abi.encodePacked(type(DevVesting).creationCode, abi.encode(o.dev));
        names[2] = "DevVesting";
        g.dev = f.predictContract(launchNumber, 2, codes[2]);
        codes[3] = abi.encodePacked(type(TeamVesting).creationCode, abi.encode(o.team));
        names[3] = "TeamVesting";
        g.team = f.predictContract(launchNumber, 3, codes[3]);
        codes[4] = abi.encodePacked(type(TreasuryVesting).creationCode, abi.encode(o.treasury));
        names[4] = "TreasuryVesting";
        g.treasury = f.predictContract(launchNumber, 4, codes[4]);
        codes[5] = abi.encodePacked(
            type(YoloSplitter).creationCode, abi.encode(g.incentives, g.dev, g.team, g.treasury, o.stabilizer)
        );
        names[5] = "YoloSplitter";
        g.splitter = f.predictContract(launchNumber, 5, codes[5]);
    }

    /// @notice Launch 1 on mainnet: DevPrices (fixed prices, no oracle) and the real swap adapter. The DevPrices owner is
    ///         the dev wallet PROJECT_DEV (the wallet that receives the dev vesting; the treasury pays every launch), not the
    ///         parameter owner: TaskVault.cancelTask and BuybackBurner.setBuybackWallet accept only that owner (only
    ///         the dev wallet cancels a task).
    function support(IContractFactory f, uint64 launchNumber, Counterparties memory c, YoloPool memory y)
        internal
        view
        returns (bytes[] memory codes, bytes32[] memory names, Support memory s)
    {
        bytes memory prices = abi.encodePacked(
            type(DevPrices).creationCode,
            abi.encode(PROJECT_DEV, c.usdc, c.imd, y.token, YOLO_PRICE_USD, ETH_USD_START, IMD_USD_START)
        );
        bytes memory adapter = abi.encodePacked(type(UniswapV3SwapAdapter).creationCode, abi.encode(ROUTER02, WETH));
        return supportWith(f, launchNumber, c, prices, adapter, y.token, PROJECT_BUYBACK);
    }

    /// @notice Launch 1 with any DevPrices and swap adapter creation codes (a local deployment uses mocks).
    function supportWith(
        IContractFactory f,
        uint64 launchNumber,
        Counterparties memory c,
        bytes memory devPricesCode,
        bytes memory adapterCode,
        address yolo,
        address buyback
    ) internal view returns (bytes[] memory codes, bytes32[] memory names, Support memory s) {
        codes = new bytes[](8);
        names = new bytes32[](8);
        codes[0] = devPricesCode;
        names[0] = "DevPrices";
        s.devPrices = f.predictContract(launchNumber, 0, codes[0]);
        codes[1] = adapterCode;
        names[1] = "UniswapV3SwapAdapter";
        s.swapAdapter = f.predictContract(launchNumber, 1, codes[1]);
        codes[2] = abi.encodePacked(
            type(ParamsRegistry).creationCode,
            abi.encode(
                c.owner, c.intake, s.devPrices, s.swapAdapter, c.nft, c.delegateRegistry, c.treasury, c.attester
            )
        );
        names[2] = "ParamsRegistry";
        s.registry = f.predictContract(launchNumber, 2, codes[2]);
        codes[3] = type(TextRules).creationCode;
        names[3] = "TextRules";
        s.textRules = f.predictContract(launchNumber, 3, codes[3]);
        codes[4] = type(SwarmQuestionBuilder).creationCode;
        names[4] = "SwarmQuestionBuilder";
        s.questionBuilder = f.predictContract(launchNumber, 4, codes[4]);
        codes[5] = abi.encodePacked(type(VotePower).creationCode, abi.encode(c.nft, c.delegateRegistry));
        names[5] = "VotePower";
        s.votePower = f.predictContract(launchNumber, 5, codes[5]);
        codes[6] = abi.encodePacked(type(AttestationChecker).creationCode, abi.encode(s.registry));
        names[6] = "AttestationChecker";
        s.attestationChecker = f.predictContract(launchNumber, 6, codes[6]);
        // the burner swaps nothing: $YOLO burned by anyone, ETH/USDC/IMD forwarded by
        // anyone to the buyback wallet
        codes[7] =
            abi.encodePacked(type(BuybackBurner).creationCode, abi.encode(yolo, c.imd, c.usdc, s.devPrices, buyback));
        names[7] = "BuybackBurner";
        s.burner = f.predictContract(launchNumber, 7, codes[7]);
    }

    // positions in launch 2 (`core`)
    uint256 internal constant CORE_HUB = 0;
    uint256 internal constant CORE_CASE = 1;
    uint256 internal constant CORE_DISPUTE = 2;
    uint256 internal constant CORE_VAULT = 3;

    /// @notice Launch 2: the doer stake, the desks, then the vault with their addresses ($contract:...).
    function core(IContractFactory f, uint64 launchNumber, Support memory s, address imd, address usdc, address yolo)
        internal
        view
        returns (bytes[] memory codes, bytes32[] memory names, address[] memory addrs)
    {
        codes = new bytes[](4);
        names = new bytes32[](4);
        addrs = new address[](4);
        codes[0] = abi.encodePacked(type(YoloLockHub).creationCode, abi.encode(yolo));
        names[0] = "YoloLockHub";
        addrs[0] = f.predictContract(launchNumber, 0, codes[0]);
        codes[1] = abi.encodePacked(
            type(CaseDesk).creationCode,
            abi.encode(s.registry, imd, usdc, s.textRules, s.questionBuilder, yolo, addrs[0])
        );
        names[1] = "CaseDesk";
        codes[2] = abi.encodePacked(
            type(DisputeDesk).creationCode,
            abi.encode(s.registry, imd, usdc, s.textRules, s.votePower, yolo, addrs[0])
        );
        names[2] = "DisputeDesk";
        addrs[1] = f.predictContract(launchNumber, 1, codes[1]);
        addrs[2] = f.predictContract(launchNumber, 2, codes[2]);
        codes[3] = abi.encodePacked(
            type(TaskVault).creationCode,
            abi.encode(s.registry, imd, usdc, yolo, s.attestationChecker, s.textRules, addrs[1], addrs[2], s.burner)
        );
        names[3] = "TaskVault";
        addrs[3] = f.predictContract(launchNumber, 3, codes[3]);
    }

    /// @notice Launch 3 on mainnet: real NFT and delegate.xyz.
    function extras(IContractFactory f, uint64 launchNumber, address vault, address safe, uint64 coreBlock)
        internal
        view
        returns (bytes[] memory codes, bytes32[] memory names, address[] memory addrs)
    {
        return extrasWith(f, launchNumber, vault, safe, coreBlock, NFT, DELEGATE_XYZ);
    }

    /// @notice Launch 3, in this order (every address argument points back, never forward): YoloSweetener (the vault
    ///         of launch 2, which it only reads), TrophyCatalog (owner `safe`), DareTrophy (the
    ///         vault and that catalog; registry, $YOLO and the CaseDesk come from the vault), then the
    ///         ProtocolDirectory with version 1 = that vault and these modules (`safe`, the project
    ///         wallet, adds later versions after 48 h, `coreBlock` is the block of launch 2). Outside the core so that
    ///         launch 2 keeps its gas and code margin for the swarm's fixes. Fifth: HiddenList, the site's hide list,
    ///         its own standalone owner/nft/delegateRegistry triple, same `safe` and the same NFT and delegate registry
    ///         as the other project-wallet contracts of this plan; it reads nothing here and nothing here reads it.
    ///         Sixth: YoloPredict (vault, PREDICT_MIN_POSITION).
    function extras(
        IContractFactory f,
        uint64 launchNumber,
        address vault,
        address safe,
        uint64 coreBlock,
        address nft,
        address delegateRegistry
    ) internal view returns (bytes[] memory codes, bytes32[] memory names, address[] memory addrs) {
        return extrasWith(f, launchNumber, vault, safe, coreBlock, nft, delegateRegistry);
    }

    /// @notice Launch 3 with any NFT and delegate registry (a local deployment uses a mock NFT).
    function extrasWith(
        IContractFactory f,
        uint64 launchNumber,
        address vault,
        address safe,
        uint64 coreBlock,
        address nft,
        address delegateRegistry
    ) internal view returns (bytes[] memory codes, bytes32[] memory names, address[] memory addrs) {
        codes = new bytes[](6);
        names = new bytes32[](6);
        addrs = new address[](6);
        codes[0] = abi.encodePacked(type(YoloSweetener).creationCode, abi.encode(vault));
        names[0] = "YoloSweetener";
        addrs[0] = f.predictContract(launchNumber, 0, codes[0]);
        codes[1] = abi.encodePacked(type(TrophyCatalog).creationCode, abi.encode(safe));
        names[1] = "TrophyCatalog";
        addrs[1] = f.predictContract(launchNumber, 1, codes[1]);
        codes[2] = abi.encodePacked(type(DareTrophy).creationCode, abi.encode(vault, addrs[1]));
        names[2] = "DareTrophy";
        addrs[2] = f.predictContract(launchNumber, 2, codes[2]);
        codes[3] = abi.encodePacked(
            type(ProtocolDirectory).creationCode, abi.encode(safe, vault, addrs[0], addrs[2], coreBlock)
        );
        names[3] = "ProtocolDirectory";
        addrs[3] = f.predictContract(launchNumber, 3, codes[3]);
        codes[4] = abi.encodePacked(type(HiddenList).creationCode, abi.encode(safe, nft, delegateRegistry));
        names[4] = "HiddenList";
        addrs[4] = f.predictContract(launchNumber, 4, codes[4]);
        codes[5] = abi.encodePacked(type(YoloPredict).creationCode, abi.encode(vault, PREDICT_MIN_POSITION));
        names[5] = "YoloPredict";
        addrs[5] = f.predictContract(launchNumber, 5, codes[5]);
    }
}

/// @notice Local stand-in for the IMD ProjectFactory's `launchContracts`: deploys creation codes in order with
///         CREATE2 and the same salt scheme, in ONE transaction (the vault's constructor wires the desks, which is only
///         possible in the transaction that deployed them). Local chains only.
contract LocalFactory is IContractFactory {
    error DeploymentFailed(uint256 index);
    error NotTheDeployer();

    /// @dev Only its creator may launch through it: the salt is (launch number, index), so anyone watching the
    ///      mempool could otherwise deploy the real desks at the predicted addresses and wire them to a contract of
    ///      their own.
    address public immutable deployer = msg.sender;

    function contractSalt(uint64 launchNumber, uint256 index) public pure returns (bytes32) {
        return keccak256(abi.encode(uint256(launchNumber), index));
    }

    function predictContract(uint64 launchNumber, uint256 index, bytes calldata code) external view returns (address) {
        bytes32 h = keccak256(
            abi.encodePacked(bytes1(0xff), address(this), contractSalt(launchNumber, index), keccak256(code))
        );
        return address(uint160(uint256(h)));
    }

    function launchContracts(uint64 launchNumber, bytes[] calldata codes) external returns (address[] memory out) {
        if (msg.sender != deployer) revert NotTheDeployer();
        out = new address[](codes.length);
        for (uint256 i; i < codes.length; ++i) {
            bytes memory code = codes[i];
            bytes32 salt = contractSalt(launchNumber, i);
            address a;
            assembly ("memory-safe") {
                a := create2(0, add(code, 0x20), mload(code), salt)
            }
            if (a == address(0)) revert DeploymentFailed(i);
            out[i] = a;
        }
    }
}
