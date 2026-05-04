# SlashablePromiseVault

StickK-on-chain commitment device. Stake ETH on a goal and name a "nemesis" — the address that gets your stake if you fail. Pick a verification mode, set a deadline, and let either the deadline or your own attestation decide where the money lands.

## How it works

1. **register(nemesis, referee, deadline)** — payable. The user picks the address they would *least* like to fund (their political opponent, an ex, a charity they hate) and a deadline. If `referee` is `address(0)`, the promise is in *self-attest* mode. Otherwise it runs in *counterparty* mode and the named referee is the only address that can confirm success.
2. **succeed(id)** — only the user, only in self-attest mode, only before the deadline. Funds are returned to the user minus a 1% protocol fee.
3. **confirm(id)** — only the named referee, only in counterparty mode, only before the deadline. Same 1% fee, funds returned to the user.
4. **slash(id)** — anyone, only after the deadline, only if still active. Funds go to the nemesis minus a 2% protocol fee and a 0.5% bounty paid to whoever called `slash`. The bounty is what makes deadline enforcement reliable: bots will sweep expired promises for the 0.5%, so users who fail can't quietly leave their stake locked forever.

Constructor:
```solidity
constructor(
    address _treasury,        // 0x7a3E312Ec6e20a9F62fE2405938EB9060312E334 on Base
    uint16  _successFeeBps,   // 100  = 1.00%
    uint16  _slashFeeBps,     // 200  = 2.00%
    uint16  _slashBountyBps,  // 50   = 0.50%
    uint16  _maxFeeBps        // 1000 = 10.00% (immutable cap; treasury can lower fees but never above this)
)
```

Treasury can call `setFees(...)` and `setTreasury(...)`. The cap is immutable so users can register a promise knowing the fee can only go down, never up beyond `maxFeeBps`.

## Verification mode tradeoffs

Two modes ship in the same contract because the right answer is user-dependent.

### Self-attest mode (`referee = address(0)`)

- **Pros:** Zero coordination cost. No counterparty risk — no one can grief you by refusing to confirm. Works for solo goals (write 1k words/day, no smoking, finish the side project).
- **Cons:** Honor system. A user who's willing to lie can call `succeed()` even if they failed. The contract can't verify the off-chain claim. The deterrent is *psychological*: the nemesis stake is the consequence, but only if the user is honest enough to admit failure or apathetic enough to let the deadline lapse.
- **Why it still works:** Behavioral-economics research behind StickK (Dean Karlan's work) shows that *the act of naming the nemesis and signing the contract* is most of the commitment effect. People who'd cheat at the end mostly never register in the first place. Self-attest mode replicates this — the friction is in the registration, not the verification.

### Counterparty mode (`referee = trusted third party`)

- **Pros:** Verifiable. The referee is someone who can observe whether you actually quit smoking, finished the manuscript, ran the marathon. The user can't unilaterally claim success.
- **Cons:** Counterparty risk in both directions. A malicious or unresponsive referee can let the deadline lapse → user's stake gets slashed even if they succeeded. A colluding referee can confirm a friend's lie. Pick referees you'd trust with cash.
- **Tip:** Referees should be people with social skin in the game (a coach, a sponsor, a sibling) — not random escrow services. The contract has no opinion on this; it just enforces the address you named.

### What this contract deliberately *doesn't* do

- **No referee voting / k-of-n:** A single referee keeps gas and UX simple. Multi-sig commitment devices exist but kill the "name your friend" flow that makes StickK work psychologically. Build a separate primitive if you need it.
- **No mid-flight referee swap:** Letting users change the referee after registration would defeat the point — the user could set a deadbeat referee right before the deadline to force a self-attest fallback. Same goes for nemesis swap.
- **No partial credit / progress unlocks:** A vesting commitment device is a different primitive (continuous penalty curves, not a binary). This contract is intentionally binary: succeed = full refund, fail = full slash. Cleaner mental model, fewer edge cases.
- **No oracle integration:** Adding Chainlink/UMA for objective verification (race time, weight, GitHub commits) would be a v2 — but most StickK goals are fundamentally subjective and untouchable by oracles.

## Honest demand concerns

This is a *legitimately* useful primitive. It's also one of the hardest categories of crypto product to monetize at scale. Calling out the two biggest risks:

1. **Demand is real but tiny per-user, and StickK already exists.** The original StickK has been around since 2007 with referee-based commitment contracts and has plateaued at niche use. The reason it didn't go mainstream isn't the lack of an on-chain version — it's that the people who *will* commit money to a behavior change are a small slice of the population, and the people who'd benefit most from external commitment generally won't pay for it. Going on-chain adds gas costs, wallet UX friction, and a new class of failure modes (lost keys, wrong nemesis address) without expanding the addressable population. Optimistic ceiling: high-conviction crypto-native users with concrete deadline-bound goals (ship a product, complete a degree, hit a fitness milestone). Realistic monthly active: low hundreds across all referees combined.
2. **Nemesis incentive is the whole product, and it's psychologically uneven.** The economic logic ("I will not skip the gym because $500 will go to [hated political party]") works best for users with strong out-group antipathy and strong loss aversion. Users without a vivid nemesis target degenerate to picking a random address or "burn" address, which removes the punishment-aversion mechanism entirely and makes the contract behave like a pure forfeit-on-failure escrow — at which point a simpler "burn-on-failure" design with no nemesis would do the same job. The contract is honest about this: nemesis is `address(0)` -reverting and self-must-not-equal, but it can't enforce that the named address actually motivates the user. That motivation work has to happen *before* the user opens the dapp.

A third, smaller concern: if a single referee turns out to be unreachable (lost key, dead, jailed), the user has no recovery path other than waiting for the deadline and getting slashed. A `referee == address(0)` rescue path would create a backdoor for the user to escape the commitment, which would defeat the contract's purpose, so this is intentional — but it means counterparty-mode users are taking a small but real "referee unavailability" risk.

## Files

- `src/SlashablePromiseVault.sol` — contract (~210 lines)
- `test/SlashablePromiseVault.t.sol` — 35 Foundry tests including a fuzz test on payout conservation
- `src/SlashablePromiseVault.README.md` — this file

## Test results

```
forge test --match-path test/SlashablePromiseVault.t.sol
Suite result: ok. 35 passed; 0 failed; 0 skipped
```

Coverage:
- Constructor input validation (treasury, max-fee, per-fee caps)
- `register` in both modes + every revert path (zero value, zero/self/aliased nemesis, self/aliased referee, past deadline)
- `succeed` happy path + wrong-mode + non-user + post-deadline + double-resolve
- `confirm` happy path + wrong-mode + non-referee (incl. user calling confirm) + post-deadline
- `slash` payout split + anyone-can-call + before-deadline + at-exact-deadline + double-slash + already-succeeded + nemesis-rejects-ETH (via no-receive contract)
- Admin: `setFees`/`setTreasury` access control + cap enforcement + zero-address guard
- Views: `isActive`/`isExpired` lifecycle + index lookups
- Fuzz: ETH conservation across `slash` for arbitrary stake + bounty bps

## Gas snapshot

```
Deployment cost: 1,977,606 (size 9,937 bytes — well under EIP-170)

Function     min      avg      median   max      calls
register     22,475   187,275  189,836  242,952  283
succeed      26,157   49,737   28,769   79,405   7
confirm      26,446   39,282   28,621   83,929   5
slash        26,113   86,799   89,726   114,726  265
setFees      24,483   30,123   30,241   30,253   259
setTreasury  23,987   25,710   24,193   28,952   3
```

`register` is the hot path (cold storage write + 3 index pushes). `slash` averages ~87k because it routes ETH to up to three addresses (nemesis, slasher, treasury). `succeed`/`confirm` are cheaper because they only touch two (user, treasury). All sub-100k median except `slash` — reasonable for a payable, multi-recipient settlement function.

## Security notes

- **CEI ordering:** State writes (`amount = 0`, `status = ...`) happen before any external call in `succeed`, `confirm`, and `slash`. No reentrancy guard needed; the storage flip prevents double-resolve even if a recipient calls back in.
- **Pull vs push:** This contract pushes payouts (matching the reference `DeadManSwitch` design). The trade-off: a malicious nemesis contract that reverts in `receive()` will cause `slash` to revert (`TransferFailed`), so funds remain locked indefinitely. This is preferable to silently swallowing the failure — the slasher knows their tx failed and the funds are still recoverable if the nemesis address ever becomes a normal EOA. A v2 could add a `nemesisRescue()` that lets anyone re-trigger slash to a treasury escrow if a configurable timeout passes after the deadline; out of scope here.
- **Front-run safe:** The slash bounty is small (0.5%) and only payable once. There's nothing to MEV beyond "be the first bot at the deadline" — and that's the intended behavior.
- **No ETH stuck on-deploy:** No constructor seeding (per global rule #8). The contract holds only what users register.
