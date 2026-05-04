# AddressTaggingMarket

Stake-weighted on-chain address labels with adversarial slashing.

## What it is

A permissionless registry where anyone can post a labeled claim about any address ("0xAbc... is a Coinbase hot wallet", "0xDef... is a Tornado-Cash sanctioned address", "0x123... is a verified Curve LP") backed by an ETH stake. Stake = confidence weight. Anyone can challenge by posting a counter-label with 2x the current stake. After a configurable challenge window with no further support added by either side, the higher-staked side wins; the loser's stake is split 80% to the winner, 20% to the protocol treasury.

The contract emits indexed events on every state change so off-chain indexers can build reverse-lookups by attester, by label, etc., without paying for additional on-chain storage.

## Why it exists

On-chain address space is anonymous by default. Today, address labeling lives in centralized silos (Etherscan tags, Arkham, Nansen, Chainalysis) — closed datasets, no provenance, no skin in the game from the labelers, no way for software to verify a label without trusting the source.

This contract gives any indexer, AI agent, smart contract, or human a primitive that says: *here is what people are willing to lose money to assert about this address, and here is who is willing to lose money to dispute it.* The label with the most stake is the one the market believes.

## Mechanism

```
attest(address subject, string label) payable → uint256 id
challenge(uint256 id, string counterLabel) payable                 (must stake ≥ 2× attestStake)
support(uint256 id) payable                                        (caller-routed: challenger funds counter side, anyone else funds attest side)
resolve(uint256 id)                                                (anyone, after window)
```

- **Attest fee:** 1% (configurable, capped at deploy time)
- **Slash split:** 80% winner / 20% treasury (configurable, same cap)
- **Tie-breaking:** attester wins ties. Challenger committed 2x minimum upfront; if the attester defends to an exact match, they retain incumbent status. This prevents grief-only challenges from succeeding by exact-stake-matching.
- **Window extension on `support`:** any support call during a challenge resets the window to `block.timestamp + challengeWindow`, giving the other side fresh time to react. This prevents a last-second support bomb from auto-winning.
- **Double-resolve protection:** `resolved` flag is checked at the top of `resolve`, `challenge`, and `support`.

## Read API

- `attestationsOf(address subject) → uint256[]` — full id list. O(n) in the subject's attestation count. Cheap for normal addresses, can grow unbounded for hot subjects.
- `attestationsOfPaginated(address subject, uint256 start, uint256 count) → (uint256[], uint256 total)` — use this for any subject likely to accumulate >100 attestations (CEX hot wallets, sanctioned addresses, popular contracts).
- `topLabel(address subject) → (string label, uint256 stake)` — single-call query for the highest-confidence label. Iterates all attestations for the subject; same caveat as above. Indexers should cache this off-chain.
- `attestations(uint256 id)` — public struct getter for individual attestations.

## Constructor

```solidity
constructor(
    address _treasury,                 // 0x7a3E312Ec6e20a9F62fE2405938EB9060312E334
    uint256 _minStakeWei,              // e.g. 0.0001 ether
    uint64  _challengeWindow,          // e.g. 7 days
    uint16  _attestFeeBps,             // e.g. 100  (1%)
    uint16  _slashTreasuryShareBps,    // e.g. 2000 (20%)
    uint16  _maxFeeBps                 // e.g. 3000 (30%) — immutable cap
)
```

The treasury can lower fees but never above `_maxFeeBps`. `_maxFeeBps` is itself capped at 50% in the constructor.

## Gas Snapshot (forge --gas-report)

| Function | Min | Avg | Median | Max |
|---|---|---|---|---|
| `attest` | 22,293 | 198,719 | 202,341 | 202,533 |
| `challenge` | 24,428 | 100,952 | 120,678 | 120,750 |
| `support` | 23,776 | 34,238 | 37,296 | 40,096 |
| `resolve` | 26,278 | 49,866 | 61,532 | 61,547 |
| `topLabel` | 3,305 | 17,104 | 16,374 | 32,364 |
| `attestationsOfPaginated` | 3,745 | 7,879 | 9,943 | 9,951 |

Deployment: ~2.35M gas, ~11.8KB runtime size. Comfortably under the 24KB EIP-170 limit.

`topLabel` cost grows linearly with attestations-per-subject. At ~14k gas per iteration on hot subjects, ~700 attestations would push it past the 10M view-call comfort zone. Real indexers should mirror this off-chain via the `Attested` / `Resolved` events.

## Honest Demand Concerns

1. **AI-agent adoption is hypothetical.** The pitch — "AI agents and indexers query this to label addresses" — assumes an audience that doesn't exist on-chain at scale yet. Concrete users TODAY are: (a) DeFi-protocol risk teams who already pay for centralized tagging and might prefer an open primitive; (b) wallet UIs that want to surface "this address has been tagged 'phishing' with 5 ETH backing it" — but those teams have to integrate it, and free Etherscan tags are good enough for most. There is no captive demand.
2. **Bootstrapping is brutal.** A tagging market with zero attestations is worth nothing; a tagging market with one attester and no challengers is worth less than nothing because everything trivially "wins". Until the market has enough adversarial liquidity that wrong labels actually get challenged, the data is unreliable, which means no one wants to consume it, which means no one wants to attest. Classic two-sided cold-start. THRYX has no growth lever for this — no audience, no content, no peopling — so the most likely outcome is the contract sits unused on Base while a centralized competitor (Arkham, Nansen) keeps the actual market.

## Files

- `src/AddressTaggingMarket.sol` — contract
- `test/AddressTaggingMarket.t.sol` — 41 Foundry tests (attest, challenge, support, resolve, double-resolve, tied stakes, pagination, treasury admin, constructor guards, fuzz)
- `src/AddressTaggingMarket.README.md` — this file
