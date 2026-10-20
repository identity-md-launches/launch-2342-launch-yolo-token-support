// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title ProtocolDirectory: every version of the core, side by side
/// @notice A new version of the protocol is a new vault (with its desks and its $YOLO modules) deployed next to the old
///         ones; nothing is replaced or migrated. This list says which vaults belong to the protocol and which one new
///         tasks go to. The site and off-chain readers read it; no contract of the core reads it, so it holds no money and
///         can stop nothing: tasks of every version keep running in their own vault to the end.
///         - Version 1 is written by the constructor (launch 3: the vault of launch 2 and the modules of launch 3).
///         - The owner (`safe`: the project wallet, an EOA) proposes a new version or a
///           new current version; either takes effect 48 h later (the timelock of ParamsRegistry), anyone executes it
///           then. The owner may cancel a pending proposal before that.
///         - A version is never removed or edited; the current one may only point to a listed version.
///         - The owner is fixed at deployment: no transfer, no other role.
///         Versions sit side by side, one $YOLO forever.
contract ProtocolDirectory {
    uint256 public constant TIMELOCK = 48 hours;
    uint256 public constant MAX_LABEL_BYTES = 32;

    /// @notice One version of the core. Zero module = the version has no such module.
    struct Version {
        address vault; // the address users call; its desks are vault.caseDesk() / vault.disputeDesk()
        address sweetener; // YoloSweetener of this vault
        address trophy; // DareTrophy of this vault
        uint64 fromBlock; // the vault's deployment block: indexers read its events from here
        uint64 addedAt; // when it was listed
        string label; // "v1", "v2", ...
    }

    address public immutable safe;

    Version[] internal _versions; // version n is _versions[n - 1]
    /// @notice The version new tasks are created in (1-based).
    uint256 public current;

    Version internal _pendingVersion;
    uint64 public pendingVersionEta; // 0 = nothing pending
    uint256 public pendingCurrent;
    uint64 public pendingCurrentEta; // 0 = nothing pending

    event VersionProposed(address indexed vault, string label, uint64 eta);
    event VersionCancelled(address indexed vault);
    event VersionAdded(uint256 indexed version, address indexed vault, address sweetener, address trophy, string label);
    event CurrentProposed(uint256 indexed version, uint64 eta);
    event CurrentCancelled(uint256 indexed version);
    event CurrentChanged(uint256 indexed version);

    error NotSafe();
    error NothingPending();
    error TimelockNotPassed();
    error NoCode(address account);
    error BadLabel();
    error UnknownVersion(uint256 version);
    error AlreadyListed(address vault);

    modifier onlySafe() {
        if (msg.sender != safe) revert NotSafe();
        _;
    }

    /// @notice Lists version 1 ("v1") and makes it current.
    /// @param fromBlock the block of the vault's deployment (launch 2)
    constructor(address safe_, address vault, address sweetener, address trophy, uint64 fromBlock) {
        if (safe_ == address(0)) revert NotSafe();
        safe = safe_;
        _add(Version(vault, sweetener, trophy, fromBlock, 0, "v1"));
        current = 1;
        emit CurrentChanged(1);
    }

    // ------------------------------------------------------------------ new version

    /// @notice Proposes a new version (replaces a pending one). `addedAt` is set at execution.
    function proposeVersion(Version calldata v) external onlySafe {
        _check(v);
        _pendingVersion = v;
        pendingVersionEta = uint64(block.timestamp + TIMELOCK);
        emit VersionProposed(v.vault, v.label, pendingVersionEta);
    }

    function cancelVersion() external onlySafe {
        if (pendingVersionEta == 0) revert NothingPending();
        pendingVersionEta = 0;
        emit VersionCancelled(_pendingVersion.vault);
    }

    /// @notice Anyone lists the proposed version after the timelock. It does not become current by itself.
    // slither-disable-next-line incorrect-equality
    function addVersion() external returns (uint256 n) {
        uint64 eta = pendingVersionEta;
        if (eta == 0) revert NothingPending();
        if (block.timestamp < eta) revert TimelockNotPassed();
        pendingVersionEta = 0;
        return _add(_pendingVersion);
    }

    // ------------------------------------------------------------------ current version

    /// @notice Proposes the version new tasks go to (replaces a pending one). It may be a version still pending in
    ///         `proposeVersion`: it has to be listed by the time this executes.
    function proposeCurrent(uint256 n) external onlySafe {
        if (n == 0) revert UnknownVersion(n);
        pendingCurrent = n;
        pendingCurrentEta = uint64(block.timestamp + TIMELOCK);
        emit CurrentProposed(n, pendingCurrentEta);
    }

    function cancelCurrent() external onlySafe {
        if (pendingCurrentEta == 0) revert NothingPending();
        pendingCurrentEta = 0;
        emit CurrentCancelled(pendingCurrent);
    }

    /// @notice Anyone switches the current version after the timelock.
    // slither-disable-next-line incorrect-equality
    function setCurrent() external {
        uint64 eta = pendingCurrentEta;
        if (eta == 0) revert NothingPending();
        if (block.timestamp < eta) revert TimelockNotPassed();
        uint256 v = pendingCurrent;
        if (v > _versions.length) revert UnknownVersion(v);
        pendingCurrentEta = 0;
        current = v;
        emit CurrentChanged(v);
    }

    // ------------------------------------------------------------------ views

    function versionCount() external view returns (uint256) {
        return _versions.length;
    }

    function version(uint256 n) external view returns (Version memory) {
        if (n == 0 || n > _versions.length) revert UnknownVersion(n);
        return _versions[n - 1];
    }

    /// @notice All versions, oldest first (version n at index n - 1).
    function versions() external view returns (Version[] memory) {
        return _versions;
    }

    function pendingVersion() external view returns (Version memory) {
        return _pendingVersion;
    }

    // ------------------------------------------------------------------ internal

    function _add(Version memory v) private returns (uint256 n) {
        _check(v);
        v.addedAt = uint64(block.timestamp);
        _versions.push(v);
        n = _versions.length;
        emit VersionAdded(n, v.vault, v.sweetener, v.trophy, v.label);
    }

    /// @dev A listed vault is a contract and listed once; modules, when given, are contracts; the label is 1..32 bytes.
    ///      Checked at proposal (the owner learns at once) and at listing.
    function _check(Version memory v) private view {
        if (v.vault.code.length == 0) revert NoCode(v.vault);
        if (v.sweetener != address(0) && v.sweetener.code.length == 0) revert NoCode(v.sweetener);
        if (v.trophy != address(0) && v.trophy.code.length == 0) revert NoCode(v.trophy);
        uint256 n = bytes(v.label).length;
        if (n == 0 || n > MAX_LABEL_BYTES) revert BadLabel();
        for (uint256 i; i < _versions.length; ++i) {
            if (_versions[i].vault == v.vault) revert AlreadyListed(v.vault);
        }
    }
}
