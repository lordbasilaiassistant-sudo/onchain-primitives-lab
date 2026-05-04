# GroupBountyPool

K-of-N dead-man pool. A group of participants jointly funds an ETH pool addressed to a single beneficiary. Each participant must `ping()` within `pingInterval`. When **K** participants have lapsed past their deadline, **anyone** may call `trigger()` and pay out the pool to the beneficiary. The triggerer earns a bounty for paying the gas; the treasury earns a fee on register and on trigger.

Cancellation requires a **unanimous on-chain vote** from every participant — no single-party rug.

## Demand cases

These are concrete situations where a group needs a credible, autonomous, on-chain "if multiple of us go quiet, this thing executes" — and where a single-user dead-man switch is insufficient.

- **Family treasuries.** Three siblings co-fund a college account for a niece. If any two of them stop responding for a year, funds release to the niece. No probate, no executor, no off-chain coordination.
- **Multisig succession.** A 3/5 hardware-key cohort wants a fallback: if 3 of the 5 keys go silent for 90 days, the assets route to a designated successor address (fresh multisig, foundation, charity). Replaces "what if half the team gets hit by a bus."
- **Group commitments / pacts.** Five founders escrow ETH on a "we all stay through Series A" pact. If 2+ stop pinging within their cliff window, the pool releases to a charity beneficiary — credible commitment without a third-party escrow.
- **Whistleblower deadman swarm.** N journalists each hold a piece of an encrypted disclosure. Each pings weekly. If K of them go quiet (arrested, silenced), the bounty triggers an on-chain payout to a publication that has the decryption material — encoded as the `beneficiary`.
- **Group subscription / shared infra.** A cohort funds a shared piece of infrastructure. If K members stop pinging (the cohort effectively dissolved), the unspent ETH routes back to whoever they designated as the wind-down beneficiary.

## Honest demand concerns

Two things that would prevent this from being used today, even if it works perfectly on-chain:

1. **Discovery + UX gap.** The set of users who (a) understand "K-of-N dead-man trigger," (b) trust an unaudited, unverified contract enough to lock real ETH for months/years, and (c) can find it without marketing — is microscopic. Without a frontend wallet that surfaces "your group's deadline is X, ping now," participants will lapse for the wrong reasons (forgot, lost key, switched chain) and burn beneficiaries' trust. The contract is the easy part; the *reminder UX* is the actual product.
2. **Liveness vs. catastrophe ambiguity.** Real-world "K of us went silent" almost never means "K of us died" — it usually means "we drifted apart, lost interest, or moved chains." For long-horizon family/succession use cases, a year-long ping cadence is plausible; for shorter-horizon group commitments, the ping cadence is almost identical to a cron-job, and a missed cron beats a real signal. There's a real risk this triggers when nobody actually wanted it to, and the unanimous-cancel vote requires every participant to still hold and use the original key — which is exactly the assumption the contract was built to fail gracefully on.

## Constructor

```solidity
constructor(
  address _treasury,           // recipient of register + trigger fees
  uint16  _registerFeeBps,     // fee taken on createPool, e.g. 100 = 1.00%
  uint16  _triggerBountyBps,   // bounty paid to trigger() caller, e.g. 50 = 0.50%
  uint16  _triggerFeeBps,      // fee paid to treasury on trigger, e.g. 50 = 0.50%
  uint16  _maxFeeBps           // hard cap on every individual bps knob, must be ≤ 5000
)
```

Treasury (mainnet target): `0x7a3E312Ec6e20a9F62fE2405938EB9060312E334`.

## Surface

| function | who | purpose |
|---|---|---|
| `createPool(participants[], contributions[], beneficiary, pingInterval, thresholdK) payable` | anyone | create a pool. `msg.value` must equal `sum(contributions)`. caller does **not** need to be a participant |
| `ping(poolId)` | participant | refresh your alive timestamp |
| `cancelVote(poolId)` | participant | cast a one-way unanimous-cancel vote |
| `cancel(poolId)` | anyone (after unanimity) | refund pool pro-rata by recorded contribution |
| `trigger(poolId)` | anyone | payout when ≥ K participants are past deadline |
| `canTrigger(poolId)` view | anyone | `(ready, missedCount)` |
| `setFees`, `setTreasury` | treasury only | governance, capped by immutable `maxFeeBps` |

Reverse indexes: `poolsByParticipant(addr)`, `poolsByBeneficiary(addr)`. Per-pool reads: `getPool`, `getParticipants`, `isParticipant`, `lastPing`, `contributionOf`, `hasVotedCancel`, `deadlineOf`.

## Invariants

- `thresholdK ∈ [1, n]` and `n ∈ [1, 255]`.
- `sum(contributions) == msg.value` at create time. Register fee is taken from the pool, not from any single participant.
- Duplicate participant addresses revert at create.
- `ping`, `cancelVote`, and `trigger` revert with `AlreadyClaimed` once the pool is resolved (either triggered or cancelled).
- `cancel()` requires `cancelVotes == participantCount` (unanimous), and refunds pro-rata to the original contribution weights. The last participant in the array receives the rounding remainder so dust isn't lost.
- Trigger bounty + trigger fee combined can never exceed 100% of the pool (constructor and `setFees` enforce `bounty + fee ≤ 10_000`).
- Treasury can only **lower** fees below the immutable `maxFeeBps` cap; never raise above it.

## CEI ordering

State writes (zero out `amount`, set `claimed`) happen **before** any external transfer. All ETH sends use a `_send` helper that reverts on failure (`TransferFailed`). No reentrancy guard needed because the contract has no callable surface that depends on stale state — once `claimed` is true, every other entrypoint reverts.

## Testing

```bash
forge test --match-path test/GroupBountyPool.t.sol
```

31 tests. Coverage:

- constructor validation (zero treasury, max-fee > 50%, register/bounty above max, bounty+fee > 100%)
- `createPool`: 3-participant happy path, **single-user degenerate case**, k > n revert, k = 0 revert, length mismatch, contribution mismatch, **duplicate participant**, zero beneficiary, zero interval, zero-address participant
- `ping`: refreshes timestamp, reverts for non-participants
- `canTrigger`: partial pings below threshold reports correct missed count without flagging ready
- `trigger`: **k=1** any single lapse triggers, **k=n** all-must-lapse path, k=n fails if one re-pings, before-threshold revert, **double-trigger revert**
- cancel-vote: unanimity required, double-vote revert, non-participant revert, cancel after trigger reverts
- treasury admin: only-treasury, fee cap enforced, treasury rotation
- view: reverse indexes populated correctly

## Gas snapshot

`forge test --gas-report` (Solidity 0.8.33, default optimizer):

| Function | Min | Avg | Median | Max |
|---|---:|---:|---:|---:|
| `createPool` (1 → 5 participants) | 23,640 | 360,990 | 526,692 | 757,606 |
| `ping` | 28,432 | 34,700 | 35,596 | 35,596 |
| `cancelVote` | 26,125 | 44,786 | 57,061 | 57,061 |
| `cancel` (unanimity refund) | 26,567 | 53,900 | 53,900 | 81,234 |
| `trigger` | 26,124 | 75,571 | 98,469 | 109,015 |
| `canTrigger` (view) | 13,201 | 21,360 | 23,424 | 33,230 |
| `setFees` | 24,461 | 24,486 | 24,486 | 24,511 |
| `setTreasury` | 28,736 | 28,736 | 28,736 | 28,736 |
| **Deployment** | — | — | — | **2,723,758 (13,570 bytes)** |

`createPool` is the expensive op — three writes per participant (index, lastPing, contribution) plus the array push. For a 5-person pool that's ~750k gas ≈ $0.05–$0.10 at typical Base mainnet conditions.
