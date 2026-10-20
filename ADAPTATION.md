# ADAPTATION — launch 1 of 4: the $YOLO token and support contracts (custom_token, Ethereum mainnet, paired with IMD)

This file records the adaptation of the repository for its second launch through the IMD ProjectFactory: the
`YoloToken` with the eight support contracts (DevPrices, UniswapV3SwapAdapter, ParamsRegistry, TextRules,
SwarmQuestionBuilder, VotePower, AttestationChecker, BuybackBurner), as `script/LaunchPlan.sol` `support` describes it
and `docs/LAUNCH-TASK.md` ("Launch 1 text") asks for it. Genesis (launch #2292) deployed the NftGate at
`0x97C8Fe82527F1a65A147bB0b425C717E4EC547C2` and the YoloSplitter at `0xF165884070B1A1E571F4A3b50FD727FE8380Bee4`.

## Changes

**None to the code.** No line of `src/`, `script/`, `test/`, the configuration or the dependencies changed. The project
arrived launchable as it is: every contract of this launch already satisfies the custom_token launch rules (checked
below), and none of the audit findings below is a defect the launch rules require fixing. The brief for this launch
forbids changing the token, its supply, the gate, the taxes or the schedule, the economics, the recipients, the
parameter values, bounds or timelock, the prices or the constructor arguments, and forbids adding an owner, a pause,
an upgrade path, minting or a fee; it asks for each audit finding to be recorded here as a note without a code change.
That is what this file does.

`launch.json` is not written here: the manifest step writes it after this work is accepted. The values that step
copies are repeated in the next section so they can be checked against the code.

## Launch-rule conformance (checked, nothing to adapt)

| Rule (custom-token-launch reference) | State of the repository |
|---|---|
| The token's constructor mints the whole supply to `msg.sender` (the factory) once; nothing mints afterwards | `YoloToken` constructor: `_mint(msg.sender, TOTAL_SUPPLY)`, 1,000,000,000e18; no mint, burn, pause or owner function exists (`src/token/YoloToken.sol`) |
| `token.totalSupply` in the manifest = what the constructor mints | 1000000000000000000000000000 (1e27), 18 decimals |
| Contract name ≤ 32 characters, a Solidity identifier | `YoloToken` (9); the longest project name is `SwarmQuestionBuilder` (20) |
| Launch flows exact: factory → distributor, distributor → claimant, seed into the PoolManager, trader buys and sells | The factory (`launcher`) is exempt on both sides; wallet-to-wallet transfers (distributor → claimant) are never taxed; the seed is a transfer from the launcher. Reproduced in a scratch test (whole supply to the deployer, 10% to a distributor and on to a claimant whole, 15% seeded before and after `openAt` untaxed, the factory's fee claim out of the pool ungated and untaxed) |
| Constructors: nonpayable, only addresses and integers, ≤ 16 arguments, no external call, no code required at any address | All nine: YoloToken 4 args, DevPrices 7, adapter 2, registry 8, TextRules 0, builder 0, VotePower 2, checker 1, burner 5. `ParamsRegistry`'s constructor calls only internal library functions (`LaunchParams.initial`, `ParamsBounds.validate`); `forge inspect … bytecode` shows no link placeholder in any of the nine creation codes |
| No owner set to `msg.sender` or `tx.origin`; no contract owned by the factory or IMD | DevPrices owner = `0x8Ad18E99F4C8d8406f9Ba8899CF308000518A981` (dev wallet, argument); ParamsRegistry owner = `0x3c587Eff6c96eAcF7E3dcC2CFf6416161386E48C` (project wallet, argument); the other seven have no owner |
| No DELEGATECALL, CALLCODE, SELFDESTRUCT, proxies or upgradeability | None in `src/` nor in the OpenZeppelin `ERC20` / `Ownable2Step` the contracts inherit (grep over sources); runtime sizes 942 to 13,552 bytes, all under EIP-170 |
| No privileged call moves or freezes a holder's balance | The token has no such function; the eight support contracts hold no user funds |
| Library functions internal | Yes (no unlinked bytecode, see above) |
| Not a Uniswap v4 hook | None of the nine is a hook |
| Swarm share: the factory's 10%, no contract here receives supply at launch | Nothing here is allocated supply; `YoloSplitter` (launch 0) is `remainderTo` |

Manifest values for the manifest step, exactly as the brief fixes them (checked against `script/LaunchPlan.sol`,
which encodes the same arguments in the same order):

- token: `YoloToken`, name `YOLO`, symbol `YOLO`, decimals 18, totalSupply `1000000000000000000000000000`,
  constructorArgs `["$poolManager", "0x97C8Fe82527F1a65A147bB0b425C717E4EC547C2", "0x3c587Eff6c96eAcF7E3dcC2CFf6416161386E48C", "1792584000"]`
- contracts, in order: DevPrices, UniswapV3SwapAdapter, ParamsRegistry, TextRules, SwarmQuestionBuilder, VotePower,
  AttestationChecker, BuybackBurner, with the constructorArgs of the brief (`$token`, `$contract:DevPrices`,
  `$contract:UniswapV3SwapAdapter`, `$contract:ParamsRegistry` where the brief has them). The adapter's first
  argument is typed `ISwapRouter02` in Solidity, which is an `address` in the ABI.
- pool: pairedCurrency `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` (IMD), fee 12500, tickSpacing 60,
  initialPrice `79228162514264337593543950336` (provenance only; the deployer derives the opening price)
- economics: `{"poolBps":1500,"initialMarketCapWei":"15000000000000000000000","remainderTo":"0xf165884070b1a1e571f4a3b50fd727fe8380bee4"}`

## Mainnet checks (read on 20 Oct 2026, block 26,236,321, timestamp 1,792,529,723)

- NftGate `0x97C8…47C2` holds code; `writer()` = the project wallet `0x3c58…E48C`, `nft()` = the identity.md NFT
  `0x0000eC93…8ec1D`. `sealedAt()` = 0, `walletCount()` = 0: **the snapshot is not yet written or sealed.** The token
  opens minutes 0-30 only for a snapshot sealed before `openAt`; unsealed, nobody buys in minutes 0-30
  (`SnapshotNotSealed`), which is the documented behaviour, not a defect. The project wallet has to record and seal
  the snapshot before 1792584000.
- YoloSplitter `0xF165…Bee4` holds code (the `remainderTo`).
- Counterparties hold code: the PoolManager `0x0000…8A90`, the Intake `0xa43e…DE82`, the delegate.xyz v2 registry
  `0x0000…d493`, the identity.md NFT `0x0000eC93…8ec1D`, SwapRouter02 `0x68b3…Fc45`, IMD (`symbol()` = "IMD"). The
  buyback wallet `0x027E…dF6E`, the attester `0x5598…2982`, the dev wallet and the project wallet are EOAs, as intended.
- **Clock.** `openAt` = 1792584000 (21 Oct 2026 12:00 UTC) is about 15 hours after that block. The token's
  constructor refuses `openAt` earlier than the deployment block (`BadOpenAt`), so the launch has to be mined before
  then; the brief allows moving `openAt` later, at most to 1792594800 (21 Oct 2026 15:00 UTC), only if it cannot. Not
  changed here.

## Audit findings, as they arrived (10), reproduced, recorded as notes

Each finding was reproduced in a scratch test (`test/scratch/`, not part of the delivery) against the code as it
arrived. All ten reproduce exactly as described. None is changed: the brief fixes the design the findings describe
(owner powers, the timelock, the schedule) and asks for notes, and none is a loss-of-funds or permission bypass.

1. **[low] `DevPrices.renounceOwnership()` kills `BuybackBurner.setBuybackWallet` and `TaskVault.cancelTask`
   (`src/BuybackBurner.sol:76`).** Reproduces: after `renounceOwnership()` from the dev wallet, `owner()` and
   `burner.dev()` are `address(0)`; `setBuybackWallet` reverts `NotDev()` from every caller and the price setters revert
   `OwnableUnauthorizedAccount`. Trust note on a privileged power, no bypass: the dev wallet can only remove its own
   powers, and the burner, the prices and the vault keep working (`forward`, `burnYolo`, payouts never read the owner).
   Not changed: adding a `renounceOwnership` override changes `src/`, which the brief forbids; the dev wallet is told
   here not to call it.
2. **[low] `ParamsRegistry.setNewTasksPaused(true)` then `renounceOwnership()` pauses task creation forever
   (`src/ParamsRegistry.sol:208`).** Reproduces: `owner()` = 0, `newTasksPaused()` = true, `setNewTasksPaused(false)`,
   `proposeAttester` and `proposeParams` revert from every caller. Liveness/trust note: open tasks finish, deposits stay
   withdrawable (the owner has no function over money). Same reason not changed; same instruction to the project
   wallet. The pause itself is a documented owner power.
3. **[low] Timelocked proposals never expire (`src/ParamsRegistry.sol:176`).** Reproduces: with attester A,
   `proposeAttester(B, true)` and `proposeAttester(A, false)`; after 48 h B is added; 180 days later any address
   executes the removal of A (count 2 → 1). A `proposeParams` from a year earlier activates on the first
   `activateParams()`. Bounded: the owner can `cancelAttester` / `cancelParams` at any time and re-add behind 48 h; the
   last attester can never be removed. Not changed (timelock mechanics are fixed by the brief); operational rule: cancel
   every proposal that is not meant to execute.
4. **[info] `cancelParams` leaves `_pendingParams` in storage (`src/ParamsRegistry.sol:86`).** Reproduces:
   after propose + cancel, `pendingParamsEta()` = 0 while `pendingParams().feeBps` still shows the cancelled value;
   `activateParams()` correctly reverts `NothingPending`. View-only inconsistency: a reader must take
   `pendingParamsEta() != 0` as "pending", never `pendingParams()` alone. Not changed.
5. **[info] `proposeAttester` accepts `address(0)` (`src/ParamsRegistry.sol:175`).** Reproduces: the zero address
   becomes an attester after 48 h (count 2), the real signer can then be removed (count 1), and
   `AttestationChecker.check` returns 5 for a signature recovering to nobody (OpenZeppelin `ECDSA.tryRecover` reports an
   error), so no attestation is ever accepted on it: every swarm answer would be silence. Owner foot-gun only; the owner
   can re-add a real signer behind 48 h. Not changed.
6. **[info] `VotePower.mayVote` reverts when the NFT or the delegate registry address has no code
   (`src/VotePower.sol:38`).** Reproduces: `new VotePower(0x1234, 0)` → `mayVote` reverts (the extcodesize check of a
   high-level call happens outside the `try`); with a real NFT and a code-less registry the owner path returns true and
   the delegate path reverts. On mainnet both arguments (`0x0000eC93…8ec1D`, `0x0000…d493`) hold code (checked above),
   so the launched contract never hits this. Not changed.
7. **[info] `UniswapV3SwapAdapter` forwards `amountIn == 0`, SwapRouter02's CONTRACT_BALANCE sentinel
   (`src/adapters/UniswapV3SwapAdapter.sol:58`).** Reproduces at unit level with a router mock implementing the
   sentinel: the adapter pulls nothing from the caller and the router's own 1 USDC is swapped to the caller. Nobody
   loses (such dust is already anyone's through the router), and the only intended caller, TaskVault mode A, refuses
   `amountIn == 0`. Not changed.
8. **[info] A non-factory LP's liquidity removal is a buy (`src/token/YoloToken.sol:136`).** Reproduces: before
   `openAt` a PoolManager → wallet transfer reverts `TradingNotOpen`; at minute 10 a non-snapshot wallet adds 700,000
   YOLO (300,000 sell tax on top to the project wallet) and cannot remove it (`NotWhitelisted`); at minute 45 the
   removal pays 15% (595,000 back, 105,000 to the project wallet). The mirror of the documented add-liquidity limit:
   **accepted limit, recorded here as the finding asked:** a wallet that adds YOLO liquidity in the first hour is
   gated and taxed like a buyer when it removes it; only the factory holds liquidity at launch and it is exempt; from
   minute 60 everything is plain. Not changed.
9. **[info] `BuybackBurner.pull(vault, token)` calls an arbitrary, caller-chosen address
   (`src/BuybackBurner.sol:124`).** Reproduces: anyone makes the burner the `msg.sender` of `withdraw(address)` on any
   contract. The burner holds no approvals and grants nothing to a caller; no value moves. The vault is an argument
   because it does not exist yet at this launch (launch 2). Not changed; noted for any future contract that would trust
   `msg.sender == burner` on that selector.
10. **[info] `whitelistActive()` is true while every buy reverts `SnapshotNotSealed` (`src/token/YoloToken.sol:125`).**
    Reproduces: unsealed gate, `openAt + 1`: the view returns true and a PoolManager → wallet transfer reverts
    `SnapshotNotSealed`. The transfer behaves as documented; only the view ignores the seal. A front end must read
    `NftGate.sealedAt()` (non-zero and `< openAt`) together with the view. Not changed. This is live today: the gate
    is unsealed (see mainnet checks).

## Further observations from this review (no change)

- **The custom-token floor's trade check against the token's clock** (`Token.protected.t.sol`,
  `test_theSeedAndASwapEachWaySucceed`: an ordinary trader buys from the pool and sells the whole amount back). The
  token's constructor requires `openAt >= block.timestamp`, so at the deployment time a buy out of the PoolManager
  reverts `TradingNotOpen` until `openAt`; in minutes 0-60 after `openAt` a sell of everything the trader holds reverts
  (the sell tax is taken on top, from the seller's wallet: 100 held, 100 settled into the pool, the 30/70 tax has no
  balance left); from minute 60 both pass. Reproduced in a scratch matrix (deployment time, minute 0, minute 45,
  minute 60; no code at the gate address = no whitelist, as on a bare chain). So that floor test passes only if the
  floor runs it at a block time at least `openAt + 3600`, i.e. more than an hour after the deployment it simulates.
  This is the token's documented behaviour, fixed by the brief ("before it every buy reverts TradingNotOpen(openAt),
  seeding works"), and the project's own rehearsal against the live factory warps through the first hour. Nothing
  here can change it without changing the token; recorded so the floor's clock is set knowingly.
- **Snapshot not sealed yet** (above). Unsealed at `openAt`, minutes 0-30 are closed to everyone; the window cannot
  be reopened later. The project wallet's job before 1792584000.
- **Buy tax rounding.** `value * 3000 * (3600 - e) / 18,000,000` rounds down (the buyer keeps the dust);
  `_sellTax` rounds down too (the pool gets exactly what the swap settles, the project wallet the floor of its share).
  Matches the brief.
- **Test authoring note (no project defect).** With `via_ir = true`, a test that derives a warp target from
  `block.timestamp` inside one function can have the compiler re-read `TIMESTAMP` after an earlier `vm.warp`, landing
  the warp in a later window than intended. The repository's own tests use literal bases (`vm.warp(1_800_000_000)`,
  `yolo.openAt() + …`) and are unaffected; the scratch reproductions had to do the same.

## Verification

- `forge build`: succeeds (warnings only, unchanged from the arrival state).
- `forge test` with `FOUNDRY_FUZZ_SEED=0xa7e6d465f44313e5b383a0fb0c3d65be95bc04ed142fef126b8d1fa92192855a`:
  686 passed, 0 failed, 3 skipped (the fork tests without `FORK_URL`), as the brief states.
- `FORK_URL=<mainnet RPC> forge test --match-path test/fork/LaunchRehearsal.fork.t.sol` at block 26,236,321: 2 passed
  (`test_fourLaunchesFitAndWork`, `test_swarmWorkerSellTax`): all four launches through the live ProjectFactory under
  the gas cap, the first hour's trades through the live Universal Router, tasks end to end, the burner's forwards.
- Scratch reproductions (`test/scratch/AuditRepro.t.sol`, deleted before submission): 12 passed (the ten findings, the
  floor clock matrix, the launch flows).
