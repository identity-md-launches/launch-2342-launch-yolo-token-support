# Launch texts for the IMD swarm: four launches

Checked against the code in `src/` (Foundry project at the repository root: `foundry.toml`, `src/`, `test/`, `script/`, `lib/`; constructors, `script/LaunchPlan.sol`, `test/fork/LaunchRehearsal.fork.t.sol`).
Where documents disagree, they are not the source: `LaunchPlan.sol` is. The constructor arguments of all four texts
below are checked by the test `test/review/ReviewLaunch.t.sol` (`test_L0_docLaunch0Args_matchPlan`,
`test_L2_docLaunch1Args_matchPlan`, `test_L3_docLaunch2Args_matchPlan`, `test_L5_docLaunch3Args_matchPlan`): there the
argument strings are copied from this file as they are, the placeholders are replaced with the plan's addresses, and
the creation code is compared with `LaunchPlan` byte for byte. Change the arguments here, change them there too. That
the test's strings appear in this file verbatim and that every text fits in 8,000 characters is checked by
`python3 script/check-launch-task.py` (it also prints the fingerprints of the texts for the record): under
the launch rules Foundry does not read files.

The swarm takes the repository as it is, audits it, changes only what is proven, writes `launch.json` and deploys
in one transaction through the IMD ProjectFactory (`0xfF03…7120`), 0.5 IMD per launch.

## The four launches and their gas headroom

- **Launch 0** (`evm_contracts`): `NftGate` (the snapshot of identity.md NFT holders for the first 30 minutes after
  trading opens), four vestings (`IncentivesVesting`, `DevVesting`, `TeamVesting`, `TreasuryVesting`) and
  `YoloSplitter`. In the swarm's manifest `economics.remainderTo` is a static address (no `$contract:`), and the
  token needs the gate's address. So all of these are deployed in advance and know no token (`release(token)`,
  `split(token)`, like OpenZeppelin's `VestingWallet`); the `YoloSplitter` address goes into `remainderTo` of launch
  1, the `NftGate` address into the token's arguments.
- **Launch 1** (`custom_token`): the token, its pool, the swarm's allocation and eight support contracts (the
  factory's maximum per launch). The token goes here because the burner needs the key of its pool and the vault of
  launch 2 needs the token's address.
- **Launch 2** (`evm_contracts`): the core, four contracts: `YoloLockHub` (the doer stake) first, then `CaseDesk`,
  `DisputeDesk`, `TaskVault`. The hub comes first because the desks name it, and a `$contract:` argument can only
  point to a contract deployed before it. The desks and the vault must be one transaction: TaskVault's constructor
  wires the desks, and a desk accepts wiring only in the transaction that created it (a flag in transient storage,
  `src/desks/Desk.sol`).
- **Launch 3** (`evm_contracts`): six contracts in this order: `YoloSweetener` ("Sweeten with $YOLO", a bonus on any
  task), `TrophyCatalog` (the trophy designs), `DareTrophy` (an NFT trophy of an accepted submission, paid in burned
  YOLO), `ProtocolDirectory`, `HiddenList`, `YoloPredict` (WILL DO / WON'T DO positions on a task). The modules need
  the vault's address (they read everything else from it), so they come after launch 2. `DareTrophy` takes the
  catalog's address as its second argument (`$contract:TrophyCatalog`), so the catalog comes before it: a `$contract:`
  argument can only point to a contract deployed before it. `TrophyCatalog`: its owner (the project wallet) adds
  designs (a name and an SVG) and picks which design new trophies of each category get; a design never changes once
  added, and a minted trophy keeps the design it got at mint; it holds no money. `ProtocolDirectory`, the list of core
  versions: version 1 = the vault of launch 2 and the modules of this launch, written by the constructor; only in
  launch 3 are all addresses of version 1 known, and so version 1 exists from the first block. It holds no money, and
  the core does not read it. `HiddenList`, the site's hide list: a separate contract, neither reads the core nor is
  read by it, has no `payable`/`receive` and never calls a token. It needs no address from a previous launch, so it
  rides along on launch 3 without another 0.5 IMD.

Everything does not fit in one factory transaction (EIP-7825 cap: 16,777,216 gas). Gas is that of the whole
transaction through the live ProjectFactory on a fork of mainnet, execution metered at the deployer's address,
calldata not below the EIP-7623 floor. The rehearsal (`LaunchRehearsal.fork.t.sol`) and the review tests
(`ReviewLaunch.test_F1_core_realGas_vs_rehearsal`, `test_F1b_support_realGas_vs_rehearsal`, `test_F1d_genesis_realGas`) give the same figures; the method was checked against three real
launches of the platform (0.3–1.5%).

| Launch | What | Gas | Headroom to the cap |
|---|---|---|---|
| 0 `evm_contracts` | NftGate, 4 vestings, YoloSplitter | 3.56M | 13.22M |
| 1 `custom_token` | YoloToken + YOLO/IMD pool (15%) + swarm allocation + 8 support contracts | 12.69M | 4.09M |
| 2 `evm_contracts` | YoloLockHub, CaseDesk, DisputeDesk, TaskVault | 14.88M | 1.90M |
| 3 `evm_contracts` | YoloSweetener, TrophyCatalog, DareTrophy, ProtocolDirectory, HiddenList, YoloPredict | 9.23M | 7.55M |

The swarm's changes will hit the 24,576-byte per-contract limit (EIP-170) before the gas cap: by gas, launch 2 could
take ~8.8 KB more new code (216 gas per byte, `ReviewLaunch.test_F2_marginalGasPerRuntimeByte`). Size headroom (`ReviewLaunch.test_L1_perContractCodeMargin_matchesDoc`):
**DisputeDesk 3,087 bytes**, TaskVault 3,975, CaseDesk 4,512, YoloLockHub 21,357; YoloSweetener 17,828, DareTrophy
12,799, ProtocolDirectory 20,030, HiddenList 20,787, YoloPredict 18,191, TrophyCatalog 20,348; the support contracts from 11,024
(ParamsRegistry) up. A swarm change of more than 3.1 KB in DisputeDesk breaks launch 2 on size. Launch 1 has eight of
the eight contracts the factory allows; launch 2 has four, launch 3 six. Launch 0 has six of eight, all under 4 KB
(NftGate 1,916, vestings 1,888 to 1,936, YoloSplitter 2,113); YoloToken is 4,015.

---

## Launch 0 text (`evm_contracts`, NFT gate, vestings and the $YOLO split)

```
Launch the genesis contracts of moneycanbuy.fun from this repository as they are: an evm_contracts launch on Ethereum mainnet (no token), the first of four. They exist before the project token $YOLO: the token's custom_token launch (the second) takes the YoloSplitter below as its remainderTo and the NftGate below as a constructor argument of the token; the core and the $YOLO modules follow as the third and fourth launches. script/LaunchPlan.sol is all four launches in code (genesisLaunch, then yoloTokenCode and support, then core, then extras).

Contracts, in this order:
1. NftGate, constructorArgs ["0x0000ec93127baa929e58e97dd0095a2bfb38ec1d", "0x3c587Eff6c96eAcF7E3dcC2CFf6416161386E48C"]
2. IncentivesVesting, constructorArgs ["0x7085193516EDc587fAebFF7a48548eAC8db5fAb5"]
3. DevVesting, constructorArgs ["0x8Ad18E99F4C8d8406f9Ba8899CF308000518A981"]
4. TeamVesting, constructorArgs ["0x153D12cc398d79A99B781B23DB6399556b84ca76"]
5. TreasuryVesting, constructorArgs ["0x3c587Eff6c96eAcF7E3dcC2CFf6416161386E48C"]
6. YoloSplitter, constructorArgs ["$contract:IncentivesVesting", "$contract:DevVesting", "$contract:TeamVesting", "$contract:TreasuryVesting", "0xaaB0269b956bd5F97B44529569b042e7BD72B508"]

What they do. NftGate is the snapshot of identity.md NFT holders (0x0000ec93127baa929e58e97dd0095a2bfb38ec1d, 2,000 NFTs) for the first 30 minutes of $YOLO trading: the writer 0x3c587Eff6c96eAcF7E3dcC2CFf6416161386E48C (the project wallet) records wallets with the number of NFTs each held at one block, in batches (record(accounts, nfts): each wallet once, no zero address or count, event Recorded per wallet, a running snapshotHash), then seal(snapshotBlock) closes the list for good: after the seal nobody can change it. Every NFT in the snapshot allows its wallet 500,000 YOLO of buys in the window. The gate never reads the NFT contract, so an NFT moved after the snapshot changes nothing. The token calls consume(buyer, amount) on a buy in its window; consume reverts until the seal; the gate books per calling token (any other caller only spends its own books, so the gate needs no token address), books only if it fits, and returns the allowance and what was used before; it never calls back and holds nothing. No owner and no clock: the window is the token's, and the token counts the snapshot only if it was sealed before trading opened.
IncentivesVesting, DevVesting, TeamVesting and TreasuryVesting are ProjectVesting with their schedules compiled in, none with a cliff, each clock started only by the YoloSplitter, which binds itself as the one starter in this launch's transaction (bindStarter, a transient flag) and starts all four at its split: incentives 62,500,000 at once and the rest linear over 730 days, to 0x7085193516EDc587fAebFF7a48548eAC8db5fAb5 (the project's wallet for incentives it runs itself, off chain); dev linear over 365 days, to 0x8Ad18E99F4C8d8406f9Ba8899CF308000518A981; team linear over 365 days, to 0x153D12cc398d79A99B781B23DB6399556b84ca76; treasury 74,074,074 at once and the rest linear over 365 days, to 0x3c587Eff6c96eAcF7E3dcC2CFf6416161386E48C. They know no token in advance (release(token), like OpenZeppelin's VestingWallet); whatever arrives counts; no owner, no acceleration; anyone may call release, which only pays the beneficiary what the schedule has opened.
YoloSplitter receives the project's 75% of $YOLO from the factory (the remainderTo of the token launch). The first split(token) once more than 527,777,777 have arrived pays 250,000,000 to IncentivesVesting, 150,000,000 to the manual YOLO Stabilizer wallet 0xaaB0269b956bd5F97B44529569b042e7BD72B508 (at once, no vesting), 77,777,777 to DevVesting, 50,000,000 to TeamVesting, and the rest (222,222,223, give or take the factory's rounding of the pool seed) to TreasuryVesting; the factory sends the remainder within the launch transaction, so it has all arrived before anyone can call; anything arriving later goes to TreasuryVesting on the next call. Right after the first split it calls release on the four vestings, which starts their clocks and pays the at-once parts. Anyone may call it. With the swarm's 10% and the pool's 15% that is the whole supply. No share is airdropped or burned.

Constructors take only addresses; the only external call is the YoloSplitter's bindStarter on the four vestings. Nothing here holds funds until the token launch. No owner, admin, pause or upgrade path in any of the six.

Known and accepted by design: the snapshot is written by the project wallet from an off-chain read of ownerOf at one block (script/snapshot/snapshot.py; the json, its block and snapshotHash are published before trading opens, anyone can recompute them); a wallet holding NFTs in a contract at that block (a vault, a marketplace escrow) is listed as that contract; the incentives wallet is a plain wallet that no mechanic pays from, the contract only unlocks it on schedule.

The tests must keep passing: forge test (<TEST_COUNT>), and forge test with FORK_URL set to a mainnet archive RPC: test/fork/LaunchRehearsal.fork.t.sol runs all four launches through the live ProjectFactory (launchContracts, launchCustom, launchContracts, launchContracts), checks each against the 16,777,216 gas cap (this one about 3.6M), splits the remainder and checks every share, and trades the token's opening and first hour through the live Universal Router with a snapshot of real NFT holders, buys with IMD, USDC and ETH routed through IMD.

Audit it as it arrived. Adapt only what the launch rules or a reproduced audit finding require, and record each change in ADAPTATION.md. Do not change the shares, the schedules, the allowance per NFT, the recipients or the constructor arguments, and do not add an owner, a pause, an upgrade path or a fee, unless a reproduced finding requires it; record it in ADAPTATION.md.
Known limitations listed in docs are accepted rules, not findings; do not change them.
```

## Launch 1 text (`custom_token`, $YOLO + support contracts)

```
Launch the $YOLO token and support contracts of moneycanbuy.fun as they are: a custom_token launch from this repository on Ethereum mainnet, paired with IMD, the second of four. From launch #<GENESIS_LAUNCH_NUMBER>: the YoloSplitter (remainderTo) and the NftGate (a token argument); the core (YoloLockHub, CaseDesk, DisputeDesk, TaskVault) follows as an evm_contracts launch taking this one's addresses as static arguments, then the $YOLO modules. script/LaunchPlan.sol is all four launches in code (support is this one).

Token: contract YoloToken, name "YOLO", symbol YOLO, 18 decimals, constructorArgs ["$poolManager", "<NFT_GATE>", "0x3c587Eff6c96eAcF7E3dcC2CFf6416161386E48C", "<OPEN_AT>"], totalSupply 1000000000000000000000000000 (1,000,000,000 minted once to msg.sender, the factory). No owner, no mint, burn or pause, no list anyone can edit. A buy is a transfer out of the Uniswap v4 PoolManager ($poolManager, compared with nothing), a sell a transfer into it. Trading opens at openAt = <OPEN_AT> (unix seconds, immutable, deployment to +30 days, else BadOpenAt); before it every buy reverts TradingNotOpen(openAt), seeding works. From openAt YoloToken._update taxes buys and sells on a fixed self-ending schedule, in YOLO, to the project wallet 0x3c587Eff6c96eAcF7E3dcC2CFf6416161386E48C fixed at deployment (non-zero):
- minutes 0-30: only snapshot wallets buy, untaxed. The token reverts SnapshotNotSealed() unless sealedAt() of the NftGate <NFT_GATE> is before openAt, then calls consume(buyer, amount): NotWhitelisted(buyer) outside the snapshot, NftAllowanceExceeded(buyer, left, wanted) above what is left of 500,000 YOLO per NFT for the window. No code at the gate address means no whitelist (a bare test chain), not a switch. Every sell pays 30%.
- minutes 30-60: anyone trades; the tax on both sides falls linearly from 30% to 0. Buy tax = amount x 3000 x (3600 - seconds since openAt) / 18,000,000 rounded down, taken from what the pool sends.
- from minute 60: a plain ERC-20 for good.
A sell's tax comes on top, from the seller's wallet: the pool gets exactly what the swap settles, the tax is its share of all the seller parts with (100 YOLO sold at 30%: 70 to the pool, 30 to the project wallet). Wallet transfers are never taxed, nor sells before openAt (not refused either); the deployer (the factory: seeding, claimFees, the swarm's share) and the PoolManager are exempt.

Known limits, accepted by design: the gate calls in minutes 0-30 (a fixed address deployed first, writes only its own storage); a buy kept as an ERC-6909 claim in the PoolManager is no transfer, so it skips openAt, the gate and the tax until taken out, and a claim can be sold back untaxed; liquidity added from a wallet after openAt pays the sell tax; YOLO pools outside Uniswap v4 are not taxed; in minutes 0-30 a route paying a router or contract first is refused (the Universal Router's TAKE_ALL passes, fork-tested); the router checks its minimum output before the buy tax; scanners flag the opening time, whitelist, taxes and external calls.

Economics, copied into launch.json exactly: poolBps 1500, initialMarketCapWei 15000000000000000000000, remainderTo <YOLO_SPLITTER>. Pool: fee 12500, tick spacing 60.

Contracts, in this order:
1. DevPrices, constructorArgs ["0x8Ad18E99F4C8d8406f9Ba8899CF308000518A981", "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48", "0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7", "$token", "1000000000000000", "2400000000000000000000", "5500000000000000000"]
2. UniswapV3SwapAdapter, constructorArgs ["0x68b3465833fb72a70ecdf485e0e4c7bd8665fc45", "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2"]
3. ParamsRegistry, constructorArgs ["0x3c587Eff6c96eAcF7E3dcC2CFf6416161386E48C", "0xa43e6f75ee006411f79ac1c84120606c2330de82", "$contract:DevPrices", "$contract:UniswapV3SwapAdapter", "0x0000ec93127baa929e58e97dd0095a2bfb38ec1d", "0x00000000000000447e69651d841bd8d104bed493", "0x3c587Eff6c96eAcF7E3dcC2CFf6416161386E48C", "0x5598aa9146215bc13eb26f2c692ad1461fd32982"]
4. TextRules, constructorArgs []
5. SwarmQuestionBuilder, constructorArgs []
6. VotePower, constructorArgs ["0x0000ec93127baa929e58e97dd0095a2bfb38ec1d", "0x00000000000000447e69651d841bd8d104bed493"]
7. AttestationChecker, constructorArgs ["$contract:ParamsRegistry"]
8. BuybackBurner, constructorArgs ["$token", "0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7", "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48", "$contract:DevPrices", "0x027e55f01e8cf808e5d2a2ad68e5e7f67fd6df6e"]

What each does: DevPrices holds every price the protocol uses, set by hand by its owner, the dev wallet; no oracle. USD per whole YOLO (start 0.001), ETH (start 2,400) and IMD (start 5.5), USDC fixed at $1; zero is refused and one call moves a price at most 10x up or down, each change an event. Prices never decide who is paid: they only set the stake bonus (a doer's YOLO lock against the reward plus the YOLO add-on). The dev wallet alone may cancel a task (everyone takes back what they put in, the dev wallet gets nothing). The adapter swaps ETH or USDC to IMD for bonds paid in another currency. ParamsRegistry holds versioned parameters (version 1 compiled in) and the swarm answer signers; its owner changes both only behind a 48-hour timelock, inside compiled bounds, and can pause new tasks; it never moves or freezes money, but the signer set is global (a change reaches open cases; the last signer stays). TextRules, SwarmQuestionBuilder and AttestationChecker are stateless helpers. VotePower says who may vote with an identity.md NFT now: its owner or the owner's delegate.xyz v2 delegate; no registration, snapshot, state or owner. BuybackBurner swaps nothing: YOLO burn shares wait there and anyone may call burnYolo() (all YOLO to 0x000000000000000000000000000000000000dEaD); the vault sends ETH, USDC and IMD burn shares straight to the buyback wallet at the payout, and anything stuck there anyone sends on with forward(token) or pull(vault, token); no caller reward. The buyback wallet starts at 0x027E55f01e8Cf808E5D2a2Ad68E5e7f67fD6dF6E; only the DevPrices owner changes it (setBuybackWallet, an event).

Every constructor takes only addresses and integers, with no external call. None of these eight contracts holds user funds. Supply: the swarm 10%, the pool 15%, the YoloSplitter 75%.

The tests must keep passing: forge test (<TEST_COUNT>), and forge test with FORK_URL set to a mainnet archive RPC: test/fork/LaunchRehearsal.fork.t.sol runs all four launches through the live ProjectFactory, checks each against the 16,777,216 gas cap (this one ~12.7M), trades YOLO's first hour through the live Universal Router (real NFT holders, edges of minutes 30 and 60, exact taxes), runs tasks end to end and sends the burner's ETH, USDC and IMD to the buyback wallet.

Audit it as it arrived. Adapt only what the launch rules or a reproduced audit finding require, and record each change in ADAPTATION.md. Without such a finding do not change the token, its supply, the gate, the taxes or the schedule, the economics, the recipients, the parameter values, bounds or timelock, the prices or constructor arguments, nor add an owner, a pause, an upgrade path, minting or a fee.
Known limitations listed in docs are accepted rules, not findings; do not change them.
```

## Launch 2 text (`evm_contracts`, core)

```
Launch the core of moneycanbuy.fun from this repository as it is: an evm_contracts launch on Ethereum mainnet (no token), the third of four. It uses the token and the contracts of launch #<SUPPORT_LAUNCH_NUMBER> as static arguments; the fourth launch adds modules that only read this vault. script/LaunchPlan.sol is all four launches in code (core is this one).

Contracts, in this order:
1. YoloLockHub, constructorArgs ["<YOLO>"]
2. CaseDesk, constructorArgs ["<PARAMS_REGISTRY>", "0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7", "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48", "<TEXT_RULES>", "<SWARM_QUESTION_BUILDER>", "<YOLO>", "$contract:YoloLockHub"]
3. DisputeDesk, constructorArgs ["<PARAMS_REGISTRY>", "0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7", "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48", "<TEXT_RULES>", "<VOTE_POWER>", "<YOLO>", "$contract:YoloLockHub"]
4. TaskVault, constructorArgs ["<PARAMS_REGISTRY>", "0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7", "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48", "<YOLO>", "<ATTESTATION_CHECKER>", "<TEXT_RULES>", "$contract:CaseDesk", "$contract:DisputeDesk", "<BUYBACK_BURNER>"]

What it is: an escrow for real-world tasks judged by the IMD swarm. Authors post rewards in ETH, USDC, IMD or YOLO (the token of launch #<SUPPORT_LAUNCH_NUMBER>) at or above a per-currency minimum (5 USDC, 0.002 ETH, 1 IMD, 1,000 YOLO; no reward maximum on a task or across all open tasks), always with a deadline that never changes; no creation fee. Anyone may top up a reward. The reward is locked until the deadline: nobody who put money in takes it back before the task expired or was unwound. Doers submit a proof link with a bond of 0.5 IMD plus 3% of the author's own part of the reward in the reward currency, no doubling for rejected or queued submissions; anyone but the doer may dispute within 24 hours with a 0.5 IMD plus 1% bond. identity.md NFT holders then vote for 24 hours, each with his own transaction and his own gas: vote(subId, side, payTo, tokenIds) with the ids of NFTs he owns now or holds as a delegate.xyz v2 delegate of the owner (VotePower of launch #<SUPPORT_LAUNCH_NUMBER>); each NFT votes once per dispute, more transactions add NFTs to the same side, the side never changes; no registration, no snapshot, no signatures relayed by others. A lead of 20 NFTs decides at once; else at the end a lead of at least 10 decides. The swarm, asked through the Intake 0xa43e6f75ee006411f79ac1c84120606c2330de82 (version 2) only when someone pays for it (an appeal of the NFT decision, or a call when the NFT did not decide), is the final instance, answering no later than 6 hours per call; at most 3 questions per submission, and after a third silence it ends as if nobody had called. No task has a mandatory swarm check. There is no timed emergency exit: once a step's own timer runs out, anyone's next call settles it. The owner of DevPrices may cancel an open task in any phase (cancelTask): it becomes unwound, everyone takes back what he put in except swarm fees already paid, the wallet gets nothing.
Money of an accepted submission: the doer gets 90% of the whole reward (top-ups included); of the 10% fee, 5% go to the NFT votes that decided right after a dispute (else to the treasury) and 5% to the treasury; a doer whose YOLO lock in YoloLockHub had power at his submission gets up to 4% more, 4% x min(1, power / (rewardInYolo + sweetener)) where rewardInYolo is the task's whole pot at submission (every top-up included) at the DevPrices YOLO price at submission and sweetener is the task's YOLO bonus in YoloSweetener at submission (power = amount x weeks / 52; any power counts, no threshold), as usual even if the doer himself put money into the task; the rest of that 5% is half burned, half the treasury's, and the NFT 5% nobody earned is burned. Burned means: YOLO to the BuybackBurner <BUYBACK_BURNER>, where anyone burns it; ETH, USDC and IMD straight to its buyback wallet. YOLO the treasury would get is always burned. A loser's bonds are split in each currency: half to the winning side and half to the correct votes if the NFT decided right, otherwise all to the winning side (so the disputer's bond goes to the doer when the NFT did not decide and nobody called the swarm). A rejected submission leaves the reward in the task.
YoloLockHub is the doer stake: lock(add, weeks) locks YOLO for 1 to 52 weeks (only longer, only more), withdraw after the end, no owner; the power is fixed at the lock, an extension sets it to amount x weeks left / 52; CaseDesk reads powerAt at the submission and fixes the bonus share, DisputeDesk checks stakePower(who, since) at the payout (0 once the lock ended); a hub that fails counts as no stake and never blocks a submission or a payout. TaskVault is the only address users call and approve: it holds all the money, the tasks and the swarm requests, receives the Intake callback (onOracleResult) and forwards the other calls with a plain CALL, never DELEGATECALL, appending the sender and msg.value. CaseDesk keeps submissions and the lazy state machine; DisputeDesk keeps disputes, votes, appeals and settlements. The desks hold no funds and accept calls only from the vault and each other. Money invariant: for every token, the vault's balance >= liabilities[token], and every amount sits in exactly one bucket.

YoloLockHub comes first because the desks name it. TaskVault's constructor wires the two desks, which accept wiring only once, only in the transaction that deployed them (a transient-storage flag) and only into their own slot, so these four contracts must stay one launch, in this order. Constructors take only addresses and make no external call except to the desks of this launch and AttestationChecker.registry().

Known trust assumptions, accepted by design: the swarm attester key set in ParamsRegistry, global for all open cases; the Intake owner sets the swarm price without delay (every payer passes maxImdIn); a swarm answer counts only through the Intake callback; prices are set by hand by the owner of DevPrices and only move the stake bonus; that owner may cancel open tasks (refunds only).

The tests must keep passing: forge test (<TEST_COUNT> including invariants of the money buckets), and forge test with FORK_URL set to a mainnet archive RPC, which runs this launch through the live ProjectFactory against the 16,777,216 gas cap (about 14.9M) and tasks end to end. Keep the launch under the cap; DisputeDesk has about 3.1 KB left under the 24,576-byte contract size limit.

Audit it as it arrived. Adapt only what the launch rules or a reproduced audit finding require, and record each change in ADAPTATION.md. Do not change fees, the fee split, the stake bonus, bonds, windows, shares, limits, recipients, the parameter values, the currencies, the constructor arguments or the split into these four contracts, and do not add an owner, a pause, an upgrade path, minting or a fee, unless a reproduced finding requires it; record it in ADAPTATION.md.
Known limitations listed in docs are accepted rules, not findings; do not change them.
```

## Launch 3 text (`evm_contracts`, $YOLO modules)

```
Launch the $YOLO modules and directories of moneycanbuy.fun as they are: the $YOLO modules, the version directory, the site's hide list and the trophy design catalog, an evm_contracts launch from this repository on Ethereum mainnet (no token), the last of four. The three $YOLO modules only read the TaskVault of launch #<CORE_LAUNCH_NUMBER>, their first address argument; the registry, the token and the desks they read through it; DareTrophy also reads the catalog. The hide list reads nothing here and nothing here reads it. script/LaunchPlan.sol is all four launches in code (extras is this one).

Contracts, in this order:
1. YoloSweetener, constructorArgs ["<TASK_VAULT>"]
2. TrophyCatalog, constructorArgs ["0x3c587Eff6c96eAcF7E3dcC2CFf6416161386E48C"]
3. DareTrophy, constructorArgs ["<TASK_VAULT>", "$contract:TrophyCatalog"]
4. ProtocolDirectory, constructorArgs ["0x3c587Eff6c96eAcF7E3dcC2CFf6416161386E48C", "<TASK_VAULT>", "$contract:YoloSweetener", "$contract:DareTrophy", "<CORE_BLOCK>"]
5. HiddenList, constructorArgs ["0x3c587Eff6c96eAcF7E3dcC2CFf6416161386E48C", "0x0000ec93127baa929e58e97dd0095a2bfb38ec1d", "0x00000000000000447e69651d841bd8d104bed493"]
6. YoloPredict, constructorArgs ["<TASK_VAULT>", "1000000000000000000"]

YoloSweetener holds YOLO bonuses anyone adds to an open task before its deadline, whatever its reward currency; locked like the reward, with no cap on the bonus. It takes deposits only after the ParamsRegistry owner binds it to the TaskVault once (bindSweetener); the bonus is not part of any bond; it is part of the stake bonus's base (with the pot). When a submission is accepted anyone calls payout(task): the doer gets 90%; of the 10% fee, 5% go to the NFT votes on "accept" if the NFT decided right (each claims with claimVoter, pro rata to its votes), the rest goes to the vault's BuybackBurner, where anyone burns it; with the stake bonus the vault paid on that submission the doer also gets the same share of the bonus (up to 4%), as usual even if he sweetened the task himself. Expired or unwound: every sweetener takes back his own. No swarm check. Invariant: its YOLO equals the open bonuses plus unclaimed voter shares.

DareTrophy is an ERC-721: the doer of an accepted submission may mint its trophy once (token id = submission id), paying a fixed 7,777 YOLO (no price reads); the YOLO is burned by a transfer to 0x000000000000000000000000000000000000dEaD and the contract keeps none. tokenURI is on-chain base64 JSON with a 24x24 SVG badge of the task's category, the task and submission numbers, the title the doer gives at mint (vault text rules, 1..64 bytes), the reward, the mint date and the proof link. The picture is the design TrophyCatalog gives the task's category at mint; the trophy keeps that design id and never changes it (id 0 = the built-in badge).

TrophyCatalog holds the trophy designs and no money. Its owner, the project wallet 0x3c587Eff6c96eAcF7E3dcC2CFf6416161386E48C (two-step transfer), adds designs (a name, 1..32 bytes under the text rules, and an SVG of up to 8,192 bytes), chooses the design new trophies of each category and the default get, and switches a design on or off for new mints, with no delay. A design never changes once added; nobody can change the design of a minted trophy.

YoloPredict is a WILL DO / WON'T DO market per task, in YOLO only, at least 1 YOLO a position. A position is irrevocable, placed before the deadline while no submission is under review, by anyone (the task's author, a contributor or the doer included): 5% is held to burn, 5% waits, 90% joins its side's pool with points = 90% x (time left / (deadline - task creation))^2. Completed: WILL DO wins; expired: WON'T DO wins; winners get their 90% plus the losing pool by points; unwound (the task cancelled): everyone gets 100% of his position back, nothing burned or held. Nobody on the winning side: completed with nobody on WILL DO splits the losing pool (90% of WON'T DO) in half between the author and the accepted doer; expired with nobody on WON'T DO sends the whole losing pool (90% of WILL DO) to the author; the losing side gets nothing back either way. The held 5% burns at the outcome. The waiting 5%: task completed -> 2.5% to its author, 2.5% to the accepted doer (same split even when nobody was on WILL DO); otherwise burned. No cap on a market or an address, no price read. All payouts pull, except settle, which sends the deferred 5% and a pool with nobody on the winning side.

ProtocolDirectory lists the versions of the core: a new version is a new vault with its own modules deployed next to the old ones, nothing replaced or migrated, the token the same. Its constructor lists version 1 (the vault of launch #<CORE_LAUNCH_NUMBER>, YoloSweetener and DareTrophy above, <CORE_BLOCK> the block of that launch, label "v1") and makes it current. Only the project wallet 0x3c587Eff6c96eAcF7E3dcC2CFf6416161386E48C, fixed at deployment, proposes a new version or a new current one; either takes effect 48 hours later and anyone executes it then; the wallet may cancel before. Listed versions are never removed or edited. It holds no money and no contract of the core reads it.

HiddenList is the site's hide list: standalone, not read by and not reading any other contract, so it cannot hold, freeze or redirect any task, bond or reward. Key (vault, kind, id), kind 1 a task, 2 a proof. setState(items, state) is the project wallet's only action: instant, batch, sets VISIBLE, HIDDEN or KEPT and closes any open vote round. Any identity.md NFT holder (or delegate.xyz v2 delegate) may vote an item hidden with vote(vault, kind, id, hide, tokenIds): the first hide vote on a VISIBLE item opens a 24-hour round; it passes at 10 or more hide NFTs, more hide than keep NFTs and 3 or more distinct hide owners, read through status(...); a round that reached the hide quorum and drew a keep vote, or one the wallet overruled back to VISIBLE, may be retried 7 days after it ended, any other failed round at once; KEPT blocks rounds. The wallet's state holds until a new round passes. No payable or receive, calls no token.

No $YOLO module nor HiddenList has an owner, an admin, a pause or an upgrade path beyond what is written above; the directory has only the wallet's timelocked list, the catalog only its designs. Constructors make no external call except view calls to the vault of launch #<CORE_LAUNCH_NUMBER>. After the launch, TaskVault.bindSweetener is called once, by the ParamsRegistry owner.

The tests must keep passing: forge test (<TEST_COUNT>), and forge test with FORK_URL set to a mainnet archive RPC, which runs this launch through the live ProjectFactory against the 16,777,216 gas cap (under 9.3M).

Audit it as it arrived. Adapt only what the launch rules or a reproduced audit finding require, and record each change in ADAPTATION.md. Do not change the fees, the bonus and market splits, the price of a trophy, the catalog's owner, the burns, the recipients, the directory's timelock or owner, the hide list's quorum, cooldown or vote window, or the constructor arguments, and do not add an owner, a pause, an upgrade path, minting or a fee, unless a reproduced finding requires it; record it in ADAPTATION.md.
Known limitations listed in docs are accepted rules, not findings; do not change them.
```

## Placeholders between launches

- All four texts: `<TEST_COUNT>`, the number of tests `forge test` runs without a fork at the commit given to the
  swarm, written as `N tests`.
- Launch 1 from launch 0: `<YOLO_SPLITTER>` (the YoloSplitter address, `remainderTo`), `<NFT_GATE>` (the NftGate
  address, a token argument) and `<GENESIS_LAUNCH_NUMBER>`. Plus `<OPEN_AT>`: when trading opens, in unix seconds
  (not before the deployment, not more than 30 days after it).
- Launch 2 from launch 1: seven addresses and the number (from the launch page and `launch.json` in the swarm's
  PR): `<PARAMS_REGISTRY>` (3), `<TEXT_RULES>` (4), `<SWARM_QUESTION_BUILDER>` (5), `<VOTE_POWER>` (6),
  `<ATTESTATION_CHECKER>` (7), `<BUYBACK_BURNER>` (8), `<YOLO>` (the launch's token), `<SUPPORT_LAUNCH_NUMBER>`.
  TaskVault's argument order: `yolo` fourth, between USDC and AttestationChecker, the burner ninth; otherwise the
  constructor takes TextRules for AttestationChecker and reverts.
- Launch 3 from launch 2: `<TASK_VAULT>` (the TaskVault address), `<CORE_LAUNCH_NUMBER>` and `<CORE_BLOCK>` (the
  block number of the launch 2 transaction, in decimal: the site reads the events of version 1 from it).
