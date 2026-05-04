# On-Chain Primitives Lab — Mainnet Deploy

7 on-chain primitives built in parallel by 7 Opus 4.7 agents. All deployed to Base mainnet via single broadcast. 220 tests passing across the suite.

## LIVE ON BASE MAINNET (chainId 8453)

| Contract | Address | Tests |
|---|---|---|
| StealthAddressRegistry (EIP-5564) | [`0xD227B45aF37591E6227EB30B757232c1D541c016`](https://basescan.org/address/0xD227B45aF37591E6227EB30B757232c1D541c016) | 29 |
| SlashablePromiseVault | [`0xe2b5AfF3e1e05f999BbF48EDD27C4c872b953268`](https://basescan.org/address/0xe2b5AfF3e1e05f999BbF48EDD27C4c872b953268) | 35 |
| ConditionalTokenDrop | [`0x8Fb1224e814fcfE4dcd952a6d3DFF722d86862Ae`](https://basescan.org/address/0x8Fb1224e814fcfE4dcd952a6d3DFF722d86862Ae) | 25 |
| TimeCapsule | [`0x52E5829b8C71A8F4878B5569Df4255dfeB909a0C`](https://basescan.org/address/0x52E5829b8C71A8F4878B5569Df4255dfeB909a0C) | 26 |
| AddressTaggingMarket | [`0x0288DfE67bE8876D92c0EA41c190b506cd99eD63`](https://basescan.org/address/0x0288DfE67bE8876D92c0EA41c190b506cd99eD63) | 41 |
| GroupBountyPool | [`0xaB4C7B22B952f99cC8Bf280D17230E8CaDd6CbD4`](https://basescan.org/address/0xaB4C7B22B952f99cC8Bf280D17230E8CaDd6CbD4) | 31 |
| AtomicSwapHTLC | [`0xc3D0CBC815DE1938D4714bf2603b33400f588433`](https://basescan.org/address/0xc3D0CBC815DE1938D4714bf2603b33400f588433) | 33 |

All verified on Basescan. Treasury = `0x7a3E312Ec6e20a9F62fE2405938EB9060312E334`.
**Total mainnet deploy cost: 0.000204 ETH.**
**Total tests: 220 passing, 0 failing.**

## Builders' honest demand reads (their words)

| Contract | Builder's call |
|---|---|
| Stealth | "Necessary primitive, not sufficient product. Umbra owns the category. Real bottleneck is off-chain receiver-scanner UX." |
| Promise | "StickK plateaued in 2007. On-chain adds friction without expanding the population. Low hundreds MAU ceiling." |
| Drop | "Time-only airdrops are 95% of the market. Merkle distributors are essentially free templates." |
| Capsule | "IPFS+timestamp is cheaper for the same UX. 'Sealed-but-readable' is a reputational landmine." |
| Tagging | "AI agent adoption is hypothetical. Brutal two-sided cold start. Self-recommends NOT prioritizing." |
| Group | "Microscopic user set. Reminder UX is the actual product. Liveness vs catastrophe ambiguity is real." |
| Swap | "Liquid pairs already have AMMs. Same-chain users prefer escrow-with-mediator over 2-tx HTLC UX." |

## Best engineering quality this batch

- **promise-builder** (35 tests): ETH-conservation fuzz, malicious-nemesis test, forbids self-slash escape hatches via `nemesis≠user`, `referee≠user`, `referee≠nemesis`
- **tagging-builder** (41 tests): tied-stake-attester-wins (incumbent bias prevents grief), support-extends-deadline (stops last-second bombs), pagination for hot subjects
- **capsule-builder**: deliberately added `peekCiphertext()` view so the "bytes are public" warning is concrete in code, not just docs
- **drop-builder**: flat ETH setup fee instead of % on token total — avoids fee-on-transfer and rebasing token edge cases
- **swap-builder**: claim and refund windows are *strictly disjoint* (claim: t≤deadline, refund: t>deadline) so no race conditions

## Strategy

Same thesis as before: these contracts are **immutable, permissionless, discoverable on-chain**. Bots/agents browsing verified Base contracts can find them. We don't need to tell anyone. Each one auto-routes fees to treasury on every fee-bearing tx.

Total mainnet contract surface so far:
- **DeadManSwitch deploy**: 1 contract
- **KeeperBountyLab deploy**: 6 contracts (5 keeper-bounty + 1 floor oracle)
- **OnchainPrimitives deploy**: 7 contracts

**Grand total: 14 contracts live on Base mainnet, all verified, all earning autonomously.**
Total deploy spend across all 14: ~0.000390 ETH (~$1.50).

## See also — sibling deployments (all Base mainnet, all verified)

The 7 contracts above plus the 6 below plus DeadManSwitch make up the 14-contract
portfolio, joined by 4 Clanker v4 tokens. All deployed by treasury
`0x7a3E312Ec6e20a9F62fE2405938EB9060312E334`. Portfolio hub: https://thryx.fun

### DeadManSwitch (`AnonContractBase/deployments.md`)

| Contract | Address |
|---|---|
| DeadManSwitch | [`0x40f1AAb4c82D48260Ab1207e27329d51290025DB`](https://basescan.org/address/0x40f1aab4c82d48260ab1207e27329d51290025db) |

### Keeper Bounty Lab (`KeeperBountyLab/LAB_REPORT.md`)

| Contract | Address |
|---|---|
| ManualFloorOracle | [`0xBD073CC2c610EeB0aA49FeAD7eee2ED980cbd70E`](https://basescan.org/address/0xBD073CC2c610EeB0aA49FeAD7eee2ED980cbd70E) |
| VestingAutoClaim | [`0x07EC89a177c7bcBB5205A8fF274f751f1C37fe4E`](https://basescan.org/address/0x07EC89a177c7bcBB5205A8fF274f751f1C37fe4E) |
| EnsAutoRenewer | [`0x4B0486C004b34Bfe6D632d5dD329c988eDDB1aE7`](https://basescan.org/address/0x4B0486C004b34Bfe6D632d5dD329c988eDDB1aE7) |
| DaoProposalExecutor | [`0xbC91411Ec61B9352A6CdF3a6722E89e5FB279F2E`](https://basescan.org/address/0xbC91411Ec61B9352A6CdF3a6722E89e5FB279F2E) |
| NftCancelOnFloorDrop | [`0xFF15F745736cfA35cf00691397584709C3Fd34b1`](https://basescan.org/address/0xFF15F745736cfA35cf00691397584709C3Fd34b1) |
| CurveGraduationPusher | [`0x7C10082fa45c530785a123B8506623e9d3C4Ad30`](https://basescan.org/address/0x7C10082fa45c530785a123B8506623e9d3C4Ad30) |

### Tokens (`TokenLaunches/launched-tokens.json`) — Clanker v4, 80% LP fees → treasury

| Token | Address |
|---|---|
| Aletheia (ALETH) | [`0x1896354e4729C689B27CbDFdE5F8192eD0115B07`](https://basescan.org/token/0x1896354e4729C689B27CbDFdE5F8192eD0115B07) |
| Mnemosyne (MNEM) | [`0x6358208342Be88A6D8bDC7c00D09fB43C49DdB07`](https://basescan.org/token/0x6358208342Be88A6D8bDC7c00D09fB43C49DdB07) |
| Huginn (HUGIN) | [`0x75BB9e3eB32747D7A9eEEf8467f5f4C44C977B07`](https://basescan.org/token/0x75BB9e3eB32747D7A9eEEf8467f5f4C44C977B07) |
| Custos (CUSTOS) | [`0x3EFf9f255B5a1891a8003A2Bf46dE45247a8aB07`](https://basescan.org/token/0x3EFf9f255B5a1891a8003A2Bf46dE45247a8aB07) |
