# Onchain Primitives Lab — 7 immutable primitives on Base

Seven small, focused, single-purpose contracts on **Base mainnet**. Each one is permissionless, immutable, and routes a small fee to the protocol treasury on every fee-bearing call. 220 tests passing across the suite.

## Live on Base mainnet (chainId 8453)

| Contract | What it is | Address |
|---|---|---|
| StealthAddressRegistry | EIP-5564 stealth meta-address registry | [`0xD227B45aF37591E6227EB30B757232c1D541c016`](https://basescan.org/address/0xD227B45aF37591E6227EB30B757232c1D541c016) |
| SlashablePromiseVault | commit ETH, slash to nemesis if you fail | [`0xe2b5AfF3e1e05f999BbF48EDD27C4c872b953268`](https://basescan.org/address/0xe2b5AfF3e1e05f999BbF48EDD27C4c872b953268) |
| ConditionalTokenDrop | time-gated permissionless airdrop pull | [`0x8Fb1224e814fcfE4dcd952a6d3DFF722d86862Ae`](https://basescan.org/address/0x8Fb1224e814fcfE4dcd952a6d3DFF722d86862Ae) |
| TimeCapsule | post a sealed-but-readable message at T | [`0x52E5829b8C71A8F4878B5569Df4255dfeB909a0C`](https://basescan.org/address/0x52E5829b8C71A8F4878B5569Df4255dfeB909a0C) |
| AddressTaggingMarket | stake-weighted attestation market on addresses | [`0x0288DfE67bE8876D92c0EA41c190b506cd99eD63`](https://basescan.org/address/0x0288DfE67bE8876D92c0EA41c190b506cd99eD63) |
| GroupBountyPool | n-of-m signers release a shared bounty | [`0xaB4C7B22B952f99cC8Bf280D17230E8CaDd6CbD4`](https://basescan.org/address/0xaB4C7B22B952f99cC8Bf280D17230E8CaDd6CbD4) |
| AtomicSwapHTLC | hash-time-locked atomic swap | [`0xc3D0CBC815DE1938D4714bf2603b33400f588433`](https://basescan.org/address/0xc3D0CBC815DE1938D4714bf2603b33400f588433) |

All 7 verified on Basescan. Treasury `0x7a3E312Ec6e20a9F62fE2405938EB9060312E334`.
Total mainnet deploy spend: 0.000204 ETH.
Total tests: 220 passing, 0 failing.

## Engineering highlights

- **promise-builder** (35 tests): ETH-conservation fuzz, malicious-nemesis test, forbids self-slash escape hatches.
- **tagging-builder** (41 tests): tied-stake-attester-wins (incumbent bias prevents grief), support-extends-deadline (stops last-second bombs).
- **capsule-builder**: deliberately added `peekCiphertext()` view so the "bytes are public" warning is concrete.
- **drop-builder**: flat ETH setup fee instead of % on token total — avoids fee-on-transfer / rebasing edge cases.
- **swap-builder**: claim/refund windows are *strictly disjoint* — no race conditions.

## Per-contract notes

Each contract has its own `*.README.md` next to its source in `src/`. Honest builder demand reads are in `LAB_REPORT.md`.

## Build / test

```bash
forge install
forge build
forge test -vv
```

## Part of the THRYX onchain surface

Companion deployments:
- DeadManSwitch: https://github.com/lordbasilaiassistant-sudo/deadman-switch
- Keeper-bounty patterns: https://github.com/lordbasilaiassistant-sudo/keeper-bounty-lab

Project home: https://thryx.fun

## License

MIT.
