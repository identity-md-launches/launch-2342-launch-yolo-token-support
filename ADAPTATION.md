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

- **The custom-token floor's trade check against the token's clock: open item for the owner and the floor operator**
  (`Token.protected.t.sol`, `test_theSeedAndASwapEachWaySucceed`: the token is deployed in `setUp`, then, at the same
  block timestamp, an ordinary trader buys from the pool and sells back everything it holds; the floor never warps).
  Three rules of the brief, each fixed, meet there: the constructor refuses `openAt < block.timestamp` (`BadOpenAt`),
  a buy out of the PoolManager before `openAt` reverts `TradingNotOpen`, and from `openAt` to minute 30 a sell pays
  30% on top of what goes into the pool (100 sold: 70 to the pool, 30 to the project wallet). So the only timestamp at
  which the constructor and the buy both pass is exactly `openAt`, and at that instant a trader holding exactly what
  it bought cannot settle all of it into the pool: the tax leg takes 3/7 of the balance first, then the main transfer
  fails `ERC20InsufficientBalance` (reproduced: 1,000 YOLO bought, 571.43 left after the tax leg, 1,000 wanted; at
  forge's default timestamp 1 the constructor itself reverts `BadOpenAt`). **There is no single block timestamp at
  which this floor test passes for this token.** It passes only if the harness warps between the deployment
  (`block.timestamp <= openAt`) and the trades (`block.timestamp >= openAt + 3600`, a plain ERC-20 from minute 60), or
  sells less than the whole balance in minutes 0-60, and the floor as read does neither. The earlier wording of this
  note ("passes at `openAt + 3600`") assumed such a warp; it is corrected here. The reviewer's proof
  (`Proof_5837de984c2c.t.sol`) replays the round trip at `openAt` and fails `ERC20InsufficientBalance` on this code,
  as it must by the brief's own arithmetic; it is answered as disputed because it asserts a whole-balance sell in
  minutes 0-30, which the brief forbids, and no change the brief permits (openAt may only move later; the taxes, the
  schedule and `src/` are fixed) could make it pass. The project's own rehearsal against the live factory
  (`test/fork/LaunchRehearsal.fork.t.sol`) warps through the first hour and passes. The decision is the owner's or
  the floor operator's: run the floor's trades at a warped clock, or change the token's design, which this task may not.
- **Snapshot not sealed yet** (above). Unsealed at `openAt`, minutes 0-30 are closed to everyone; the window cannot
  be reopened later. The project wallet's job before 1792584000.
- **The launch deadline** (revision, 20 Oct 2026 ~23:40 UTC, chain time ~1792539500: about 12.4 hours to `openAt`).
  The token is the first contract `launchCustom` creates; its constructor reverts `BadOpenAt(1792584000)` in any block
  with `block.timestamp > 1792584000`, and that revert fails the whole launch transaction (reproduced: at a warp of
  1792584001 the constructor reverts, at 1792584000 it deploys). This is the brief's fixed behaviour, not a defect,
  and `openAt` is not changed here. The brief's one fallback is the manifest step's and the owner's: if the launch
  cannot be mined before 1792584000, `openAt` (the token's fourth constructor argument) may be set later, at most to
  1792594800 (21 Oct 2026 15:00 UTC); past that the job fails. Whichever `openAt` is used, the NftGate must be sealed
  strictly before it, or minutes 0-30 are closed to everyone (`SnapshotNotSealed`); the gate's `sealedAt()` was still 0
  at the last read.
- **Buy tax rounding.** `value * 3000 * (3600 - e) / 18,000,000` rounds down (the buyer keeps the dust);
  `_sellTax` rounds down too (the pool gets exactly what the swap settles, the project wallet the floor of its share).
  Matches the brief.
- **Test authoring note (no project defect).** With `via_ir = true`, a test that derives a warp target from
  `block.timestamp` inside one function can have the compiler re-read `TIMESTAMP` after an earlier `vm.warp`, landing
  the warp in a later window than intended. The repository's own tests use literal bases (`vm.warp(1_800_000_000)`,
  `yolo.openAt() + …`) and are unaffected; the scratch reproductions had to do the same.

## Revision: the independent review's findings (20 Oct 2026), each reproduced, recorded as notes

The accepted work was reopened with nine findings from an independent reviewer. Each was checked against the code;
all nine describe the code correctly. None is changed: each is the brief's fixed design or a fixed number, and the
brief forbids changing the token, the schedule, the taxes, the prices, the timelock or any line of `src/`. The two
that reopened the work are the floor clock and the launch deadline, both detailed under "Further observations" above.
The answers to the reviewer are in `.imd-responses.json`.

1. **[high] The floor's buy-then-sell-all round trip passes at no block timestamp (`YoloToken.sol:74`).** Correct,
   and reproduced with the reviewer's proof (fails `ERC20InsufficientBalance(trader, 571428571428571428572, 1e21)`).
   Disputed as a code defect: the proof asserts a whole-balance sell in minutes 0-30, which the brief's on-top 30% sell
   tax forbids by construction. Open item for the owner / floor operator; see above.
2. **[medium] Launch reverts `BadOpenAt` if mined after 1792584000; the gate must be sealed before `openAt`
   (`YoloToken.sol:74`).** Correct; operational deadline, by design; the brief's fallback (`openAt` at most
   1792594800) is the manifest step's if needed. See above.
3. **[low] DevPrices starts YOLO at $0.001, about 12.12x the pool's opening price (`script/LaunchPlan.sol:74`).**
   Correct: the pool opens at 15,000 IMD x $5.5 / 1e9 = $0.0000825 per YOLO. `yoloValue(USDC, 100e6)` = 100,000 YOLO
   at the start price against 1,212,121 YOLO at the pool price, so until the dev wallet lowers the price a doer earns the
   full stake bonus with about 1/12 of the YOLO the reward is worth. Prices never decide who is paid; they only size the
   stake bonus. The step limit (`MAX_STEP` = 10) means one `setYoloPriceUsd(82.5e12)` reverts `PriceSanity`; two calls
   (1e14, then 82.5e12) land it. The start price is fixed by the brief; operational note for the dev wallet.
4. **[low] `transferFrom` into the PoolManager in the first hour debits the allowance for `value` and the sell tax
   from the owner on top (`YoloToken.sol:133`).** Correct: approve 70, `transferFrom(H, PM, 70)` at `openAt + 1` moves
   100 from H (30 to the project wallet), allowance 0. The documented on-top design; a router or spender settles exactly
   what it asked for, the holder pays the tax. Note only.
5. **[low] Contradictory attester proposals for one address coexist (`ParamsRegistry.sol:177`).** Correct:
   `(A, true)` and `(A, false)` are separate keys (`keccak256(abi.encode(attester, allowed))`), so both can be executed
   after 48 h by anyone, in either order, and the later execution decides. The owner can `cancelAttester` either one;
   the last attester can never be removed. Timelock mechanics are fixed by the brief; operational rule: never leave
   both directions pending for one address.
6. **[info] The project wallet's own buys and sells are effectively untaxed (`YoloToken.sol:133`).** Correct: with
   `from == taxRecipient` the tax leg is a self-transfer; a sell of 70 from the project wallet at `openAt` lowers its
   balance by 70, not 100, and a buy's tax lands back in its own wallet. Nothing is lost or created; the exemption is
   implicit in "tax paid to the project wallet". Note only.
7. **[info] `AttestationChecker` treats `expiresAt == 0` as never expiring and does not compare `issuedAt` to the
   clock (`AttestationChecker.sol:54`).** Correct and documented in the contract's NatSpec ("0 = no expiry");
   `issuedAt` is part of the signed digest, so it cannot be altered, only not checked against the clock. An attester
   signature is still required, so there is no bypass; the swarm's attester decides whether to sign an answer without
   an expiry. Note only.
8. **[info] `buyTaxBps()` / `sellTaxBps()` round to whole bps while the charged tax is not rounded (`YoloToken.sol:93`).**
   Correct: at `openAt + 1801` the view says 2998 bps while a 1e24 buy pays 299,833.33e18 (2998.33 bps). The views are
   informational; `sellTax(intoPool)` and the `_update` arithmetic are exact. Integrators should use `sellTax()`.
9. (merged into 1 by the reviewer) **A whole-balance sell in minutes 0-60 reverts.** Same root cause as 1: the tax is
   on top, so a seller must keep `sellTax(amount)` in the wallet, or sell `balance x (10000 x 1800 - num) / (10000 x
   1800)`. Documented behaviour.

## Verification

- `forge build`: succeeds (warnings only, unchanged from the arrival state). A cold build of the 176 files with
  `via_ir` takes about 8m40s on the task machine.
- `forge test` with `FOUNDRY_FUZZ_SEED=0xa7e6d465f44313e5b383a0fb0c3d65be95bc04ed142fef126b8d1fa92192855a`:
  686 passed, 0 failed, 3 skipped (the fork tests without `FORK_URL`), as the brief states. No line of code changed in
  the revision, so the suite is the one that was accepted; what was rerun in the revision is listed next.
- Revision: the reviewer's proof `Proof_5837de984c2c.t.sol`, copied under `test/scratch/`, fails
  `ERC20InsufficientBalance(trader, 571428571428571428572, 1000000000000000000000)` on this code, as the reviewer
  reported and as the brief's arithmetic requires.
- `FORK_URL=<mainnet RPC> forge test --match-path test/fork/LaunchRehearsal.fork.t.sol` at block 26,236,321: 2 passed
  (`test_fourLaunchesFitAndWork`, `test_swarmWorkerSellTax`): all four launches through the live ProjectFactory under
  the gas cap, the first hour's trades through the live Universal Router, tasks end to end, the burner's forwards.
- Scratch reproductions (`test/scratch/AuditRepro.t.sol`, deleted before submission): 12 passed (the ten findings, the
  floor clock matrix, the launch flows).
