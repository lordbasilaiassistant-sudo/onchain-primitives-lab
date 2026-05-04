# AtomicSwapHTLC

Hash time-locked contract for trustless same-chain P2P swaps between any
combination of native ETH and ERC-20 tokens. No price oracle, no liquidity
pool, no settlement layer beyond the EVM itself — two parties name a price
off-chain, lock both legs on-chain against the same `keccak256(secret)`, and
either settle atomically or refund after a deadline.

## Mechanism

1. **`openMaker(hashlock, taker, tokenA, amountA, deadline)`** — maker locks
   asset A. `tokenA = address(0)` for native ETH (must send `msg.value =
   amountA`); otherwise must `approve` first. Maker keeps the preimage
   off-chain.
2. **`openTaker(swapId, tokenB, amountB)`** — only the named taker can match.
   Taker locks asset B against the same hash on the same swap id.
3. **`claim(swapId, preimage)`** — permissionless. Anyone holding the
   preimage settles both legs atomically: `tokenA → taker`, `tokenB → maker`.
   Treasury fee (`swapFeeBps`, default 0.5 %) is skimmed from each leg and
   forwarded immediately. Disabled after `deadline`.
4. **`refund(swapId)`** — after `deadline`, each side refunds its own lock
   independently. Maker and taker refund separately, so a missing
   counterparty does not strand the other side.

### Atomicity

The whole game. `claim()` reads both legs in one transaction, sets both
amounts to zero, then pays out — there is no path where only one leg moves.
Two reinforcing properties:

- The taker cannot pre-claim: `claim` requires `status == Matched`, which is
  only reachable through `openTaker`, which itself requires the taker to
  actually lock asset B.
- A claim race cannot beat a refund: `claim` rejects `block.timestamp >
  deadline`; `refund` rejects `block.timestamp <= deadline`. The two windows
  are disjoint.

### Treasury

Constructor takes `(treasury, swapFeeBps, maxSwapFeeBps)`. `swapFeeBps` is
mutable by treasury via `setFees`, but never above the immutable
`maxSwapFeeBps`, which itself is capped at 50 % of `BPS_DENOMINATOR` (5000
bps). `setTreasury` rotates the recipient.

## Tests

`forge test --match-path test/AtomicSwapHTLC.t.sol` — **33 tests, all
passing**. Coverage includes:

- ETH ↔ ERC-20 and ERC-20 ↔ ERC-20 happy paths
- Wrong preimage, double claim, claim-before-match, claim-after-deadline
- Refund-before-deadline (rejected), refund-after-deadline (works for both
  sides independently)
- Stranger cannot refund, double-refund rejected
- Atomicity: taker cannot reach claim() without locking, claim() releases
  both legs in one tx
- Constructor input validation, fee cap enforcement, treasury-only admin
- Per-maker / per-taker swap indexes

## Gas (forge --gas-report, optimizer default)

| Function    | Min    | Median | Max     |
|-------------|--------|--------|---------|
| `openMaker` | 23 150 | 217 499 | 271 256 |
| `openTaker` | 27 180 | 113 020 | 113 020 |
| `claim`     | 24 483 | 86 651  | 154 809 |
| `refund`    | 26 169 | 31 229  | 50 229  |

Deployment: ~2.66M gas, runtime size 12 818 bytes (well under the 24 KB
limit).

## Demand: where this could matter

- **Long-tail / non-DEX tokens** — pairs with no AMM liquidity. OTC desks
  use multisigs and trust; this needs neither.
- **OTC blocks** — sizes that would move a thin AMM. Trade is priced
  off-chain (Discord/email/Signal), settled on-chain.
- **Cross-asset ETH ↔ ERC-20** without quoting through a router or paying
  pool fees on top of price impact.

## Honest demand concerns

1. **Liquid pairs already have AMMs.** For anything Uniswap lists with depth,
   a swap is one click and one tx. HTLC's value collapses to the long-tail
   and OTC slice. The addressable market is real but narrow, and price
   discovery still has to happen somewhere off-chain — meaning a separate
   product (chat, order book, bot) needs to exist before this contract gets
   used. That second product is the actual bottleneck, not the settlement
   layer.

2. **Same-chain HTLCs solve a problem most users don't have on one chain.**
   The canonical HTLC use case is *cross-chain* (Bitcoin ↔ Ethereum,
   Lightning ↔ EVM). Same-chain, an escrow with a designated mediator or a
   simple `swapExactlyTwo()` style atomic call would feel more natural to
   most users than "publish your secret to settle." The contract is correct
   and gas-efficient, but adoption hinges on convincing users that
   trustlessness is worth the two-tx UX overhead vs. just trusting a
   counterparty with a 0.5% fee on a Telegram OTC trade.
