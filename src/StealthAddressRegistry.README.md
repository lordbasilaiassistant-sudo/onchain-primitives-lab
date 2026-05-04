# StealthAddressRegistry

Minimal on-chain home for [EIP-5564](https://eips.ethereum.org/EIPS/eip-5564) (stealth address scheme) and [EIP-6538](https://eips.ethereum.org/EIPS/eip-6538) (stealth meta-address registry). Receivers publish a meta-address; senders broadcast announcements; receivers scan logs off-chain. The contract never touches payment funds — it is a key directory plus an indexed event bus.

## Two responsibilities

1. **Registry (EIP-6538)** — `registerKeys(schemeId, stealthMetaAddress)` stores a per-`(registrant, schemeId)` blob. Re-registering overwrites. Lookup via `stealthMetaAddressOf(registrant, schemeId)`.
2. **Announcer (EIP-5564)** — `announce(schemeId, stealthAddress, ephemeralPubKey, metadata)` emits an `Announcement` event indexed by `schemeId`, `stealthAddress`, and `caller`. Receivers scan logs filtered on the view-tag inside `metadata`.

`schemeId = 1` is the secp256k1 default per EIP-5564. Other schemes (BLS, lattice) are accepted by id; the contract is scheme-agnostic.

## Spec compliance notes

- **EIP-5564** specifies an `Announcer` with the exact event shape `Announcement(uint256 indexed schemeId, address indexed stealthAddress, address indexed caller, bytes32 ephemeralPubKey, bytes metadata)`. Ours matches, plus a trailing `uint256 fee` for treasury accounting. Scanners that decode by topic + the first two non-indexed words remain compatible; strict ABI-decoders that expect exactly two non-indexed fields will see one extra word.
- **EIP-6538** specifies `registerKeys(uint256 schemeId, bytes stealthMetaAddress)` and `stealthMetaAddressOf(address registrant, uint256 schemeId) -> bytes`. Both match exactly.
- The view-tag (1-byte prefix recommended by EIP-5564 §"View tags") lives inside `metadata` — the contract does not parse it. Off-chain scanners filter announcements by `metadata[0]` to drop ~99% of non-matches before doing the expensive ECDH check.
- Fees are an additive deviation from the spec. Pure spec implementations are free. We charge to fund treasury and rate-limit spam announcers. Treasury can drop fees to 0 if adoption demands it.

## Fees

| Param | Default | Hard cap (immutable) |
|---|---|---|
| `registerFeeWei` | 0.0001 ETH | 0.001 ETH |
| `announceFeeWei` | 0.00001 ETH | 0.0001 ETH |

Treasury can `setFees(...)` between 0 and the cap. Excess `msg.value` above the fee on either call is forwarded to treasury as a tip — no refunds, no accumulation in the contract.

Constructor: `(address treasury, uint256 registerFeeWei, uint256 maxRegisterFeeWei, uint256 announceFeeWei, uint256 maxAnnounceFeeWei)`.

## Tests

29 tests, all pass:

```
forge test --match-path test/StealthAddressRegistry.t.sol
```

Coverage: constructor validation, register store/overwrite/multi-scheme/excess-tip/fee paths, announce emit/counter/zero-checks/empty-metadata, treasury fee + treasury rotation, transfer-failure path via a rejecting treasury, plus two fuzz tests over arbitrary meta blobs and announcement metadata.

## Gas snapshot (`--gas-report`)

| Item | Gas |
|---|---|
| Deployment | 1,208,977 (size 5,853 bytes) |
| `registerKeys` (avg) | 120,053 |
| `registerKeys` (median) | 109,305 |
| `announce` (avg) | 87,720 |
| `announce` (median) | 88,578 |
| `setFees` (avg) | 27,631 |
| `setTreasury` (avg) | 25,565 |
| `stealthMetaAddressOf` (avg view) | 7,160 |

`announce` cost is dominated by the calldata + log4 emission of the variable-length `metadata` blob. `registerKeys` cost grows with meta-address length (1 SSTORE-cold for the slot pointer + N SSTORE-cold for the blob words).

## Honest demand concerns

1. **Umbra already owns this category on Optimism / mainnet.** They have working dapp UX, RPC integrations, and a decent receiver-scanner. A fresh registry on Base needs either (a) a noticeably better scanner than Umbra's (slow, charges its own fee) or (b) a Base-native population that doesn't already use Umbra's chain. Neither is automatic — without a scanner front-end this contract is a tree falling in an empty forest.
2. **Receiver-scanning is the actual bottleneck.** Posting a stealth meta-address is one tx. Receiving privately requires the receiver to pull every `Announcement` event since their last scan and run an ECDH check against each one. At 100k+ announcements that's a meaningful client-side cost; without a hosted indexer (which leaks the receiver's identity to whoever runs it), most users won't scan and most senders won't bother sending. The contract is a necessary primitive but not a sufficient product — the value lives in the off-chain scanner that nobody is paid to build.

## File layout

- `src/StealthAddressRegistry.sol` — the contract
- `test/StealthAddressRegistry.t.sol` — Foundry tests
- `src/StealthAddressRegistry.README.md` — this file
