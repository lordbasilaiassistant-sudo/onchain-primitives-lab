# ConditionalTokenDrop

Merkle airdrop unlocked by a programmable on-chain condition.

A project deposits ERC20 tokens plus a merkle root of `(recipient, amount)` leaves
and chooses one of four unlock triggers. Until the trigger fires, no recipient
can claim. After it fires, recipients claim with a standard merkle proof.

## Why this exists

Time-locked airdrops are commodity (Hedgey, Sablier, Llamapay, Disperse). The gap
is *conditional* airdrops: drops that go live based on something happening, not
just a clock running out. Use cases:

- **Milestone-gated rewards** — token unlocks only if treasury hits a target
  price (oracle), or only after a governance vote settles (manual unlock by the
  registrant after they call the vote result on-chain).
- **Block-height drops** — sync claim eligibility to a specific L2 block (useful
  for snapshot-style coordination across chains where timestamps drift).
- **Manual gate** — registrant flips the switch when their off-chain process
  decides recipients earned it (KYC pass, beta completion, etc.). Cheaper than
  redeploying a fresh merkle distributor for every cohort.
- **Refundable commitment** — registrant can cancel and reclaim *until* a real
  claim has happened, which time-only contracts can't do safely.

## Conditions

| Type | Code | Unlocks when |
|------|------|--------------|
| BlockHeight | 1 | `block.number >= conditionValue` |
| Timestamp | 2 | `block.timestamp >= conditionValue` |
| OracleThreshold | 3 | `IPriceOracle(oracle).latestAnswer() >= conditionValue` (negative answers stay locked) |
| Manual | 4 | Registrant calls `unlockManually(id)` |

Oracle interface is intentionally minimal (`latestAnswer() → int256`), compatible
with Chainlink AggregatorV3 feeds (which expose the same getter via the legacy
interface) and with any custom oracle that returns a signed integer.

## Lifecycle

1. Project generates merkle tree off-chain over `(recipient, amount)` leaves.
2. Project calls `token.approve(drop, totalAmount)`.
3. Project calls `registerDrop{value: setupFeeWei}(token, totalAmount, root, conditionType, conditionValue, oracle)`.
   - Tokens pulled in via `transferFrom`.
   - Flat ETH setup fee forwarded to treasury.
   - Excess ETH refunded.
4. Recipients call `claim(id, amount, proof)` once the condition is met.
5. Registrant can `cancel(id)` to reclaim remaining tokens — allowed if no claim
   has settled yet, even after the condition unlocks.

## Fee model

- Flat ETH `setupFeeWei` paid once on `registerDrop`. No percentage cut on the
  ERC20 amount (we don't want to risk fee-on-transfer or rebasing token edge
  cases at the protocol layer).
- Treasury can lower the fee but never above the immutable `maxSetupFeeWei` set
  at deploy.
- Treasury can rotate itself with `setTreasury`.

## Security notes

- Custom errors only; CEI ordering on every state-changing function.
- Merkle leaf hashing uses the OpenZeppelin "double hash" pattern
  (`keccak256(bytes.concat(keccak256(abi.encode(addr, amount))))`) which prevents
  second-preimage attacks against intermediate nodes.
- Sorted-pair hashing in `_verify`, so off-chain tree generators must sort
  siblings before pairing — standard `merkletreejs` `{ sortPairs: true }` works.
- `claim` writes `claimedBy[id][msg.sender] = true` *before* the token transfer.
  Combined with reading `msg.sender` directly into the leaf, this blocks
  reentrancy / double-claim from a single recipient even on a malicious token.
- Token interface is minimal `IERC20` — no return-value coercion. Tokens that
  return false (instead of reverting) on a failed transfer will be caught.
  Tokens that return nothing at all (USDT-style) will revert at the ABI decode
  step in this contract; wrap those in a SafeERC20 adapter or use a wrapper.
- Oracle answer is checked for negative before casting to uint, so a misbehaving
  feed can't underflow the threshold compare.

## Gas snapshot (forge --gas-report)

| Function | Avg gas |
|----------|---------|
| registerDrop | 224,753 |
| claim | 74,731 |
| cancel | 43,868 |
| unlockManually | 29,191 |
| isUnlocked | 8,773 |
| setSetupFee | 24,483 |
| setTreasury | 26,312 |

Deployment: 2,163,298 gas / 10,210 bytes runtime (well under 24kB cap).

## Testing

25 Foundry tests, all passing. Coverage:

- Constructor validation (zero treasury, fee above cap)
- Register flow + fee routing + ETH refund + insufficient-fee revert
- All four condition types: register, isUnlocked transitions, claim
- Oracle: positive threshold, negative answer stays locked, no-oracle on type 3 reverts
- Manual: only registrant unlocks, double-unlock reverts, wrong-type reverts
- Claim: valid proof, invalid proof, tampered amount, double claim, post-cancel
- Cancel: before unlock, after unlock w/o claims, after claim reverts, only registrant, double cancel
- Treasury admin: setSetupFee with cap + onlyTreasury, setTreasury rotation

Run with:

```
forge test --match-path test/ConditionalTokenDrop.t.sol
```

(If sibling teammate contracts have unrelated compile errors, add
`FOUNDRY_SKIP='["AtomicSwapHTLC.sol","AtomicSwapHTLC.t.sol","GroupBountyPool.sol","GroupBountyPool.t.sol"]'`.)

## Honest demand concerns

1. **Time-only is 95% of the market.** Every airdrop ops team I've watched sets a
   hard date and shrugs. Conditional unlock is cool but the buyer who wants
   "release when ETH > $5k" is rare; most projects pick a date and move on.
   Differentiation may need to be a wrapper UX pitch ("set-and-forget kicker")
   rather than the contract itself.
2. **Merkle distributors are nearly free as templates.** Uniswap's distributor
   is unlicensed copy-paste, Disperse runs $0 to spin up. Charging an ETH setup
   fee for a feature most teams won't use means we're competing against a free
   tier on the boring 95% of jobs and the niche 5% may not generate enough
   register events to cover even the tiny flat fee. Path to revenue probably
   looks like a hosted UI bundling the merkle generator + oracle picker, not
   the contract by itself.

## Treasury

Mainnet deployments route fees to `0x7a3E312Ec6e20a9F62fE2405938EB9060312E334`.
