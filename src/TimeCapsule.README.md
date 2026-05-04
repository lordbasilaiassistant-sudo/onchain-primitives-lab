# TimeCapsule

Store an opaque ciphertext blob on-chain that becomes "officially revealed" via
event emission once an unlock condition (timestamp or block height) is met.

## What it actually does

- `seal(ciphertext, unlockAt, recipient, mode)` — pay a per-byte storage fee, get
  back a `capsuleId`. Excess `msg.value` is refunded; the fee is forwarded to
  the treasury inside the same tx.
- `isUnlocked(id)` — view; true once `block.timestamp >= unlockAt` (Time mode)
  or `block.number >= unlockAt` (Block mode).
- `reveal(id)` — anyone can call after unlock. Emits
  `Revealed(id, revealer, recipient, ciphertext)` so wallets / indexers can
  pick up the bytes through normal log-subscription paths.
- `getCapsule(id)` / `peekCiphertext(id)` — view the metadata or raw bytes.
- `capsulesByCreator(addr)` / `capsulesByRecipient(addr)` — enumeration.
- Treasury can adjust `feePerByteWei` up to an immutable `maxFeePerByteWei` and
  rotate the treasury address. No admin can read, alter, delete, or unlock
  user capsules.

## CRITICAL: this contract does NOT keep your data secret

Read this twice. The contract is named "TimeCapsule" because the *reveal event*
is time-locked, not because the *bytes* are hidden.

- The `ciphertext` you pass to `seal()` is stored in plain contract storage.
  Anyone with an archive node, an RPC endpoint, or even just a block explorer
  can read it from the moment your tx confirms.
- It's also forever visible in the `seal()` calldata of your own transaction.
- `peekCiphertext(id)` is exposed precisely to make this honest — there is no
  scenario where the bytes are reachable to the recipient but unreachable to
  everyone else.
- The `revealed` flag and the `Revealed` event are a **UX coordination
  primitive**, not a cryptographic one. They tell wallets *when* to attempt
  decryption; they do not gate *whether* the bytes can be read.

If you need actual secrecy, **encrypt off-chain BEFORE calling `seal()`**.
Recommended approaches:

- **ECIES / X25519 to recipient pubkey** — encrypt the blob to the recipient's
  public key before sealing. Only they can decrypt. Trivial to do with libsodium
  / noble-curves. Best for single-recipient capsules.
- **Threshold MPC / time-lock encryption** — services like drand's tlock can
  encrypt to a future drand round; nobody (including you) can decrypt until the
  drand network releases the round signature. Best when the unlock time matters
  cryptographically, not just socially.
- **Symmetric encryption + key commitment** — encrypt with a random symmetric
  key, share the key out-of-band (or via a separate decryption-time release
  mechanism). Lowest dependency.

What the contract guarantees, narrowly:

- Anyone can verify *when* a capsule was created (`Sealed` event block).
- Anyone can verify *when* the official reveal happened (`Revealed` event
  block) and that it occurred at or after `unlockAt`.
- The original creator cannot quietly swap the ciphertext after the fact.
- The treasury cannot censor a reveal — `reveal()` has no admin gate.

What the contract does NOT guarantee:

- Confidentiality before unlock.
- That `recipient` is the only one who can read the cleartext (depends entirely
  on your encryption choice).
- That unsealed bytes are invisible — they aren't.

## Constructor

```solidity
constructor(address _treasury, uint256 _feePerByteWei, uint256 _maxFeePerByteWei)
```

For Base mainnet deploy use:

- `_treasury = 0x7a3E312Ec6e20a9F62fE2405938EB9060312E334`
- `_feePerByteWei = 1_000_000_000_000` (0.000001 ETH/byte = ~$0.0035/KB at $3.5k ETH)
- `_maxFeePerByteWei = 1_000_000_000_000_000` (1000x cap so treasury can raise but not gouge)

A 1 KB capsule costs **~0.001 ETH** in protocol fee at the default rate; gas
to actually store 1 KB on Base will dwarf that (calldata + 32-byte storage
slots), which is the real reason the per-byte fee is small — L1/L2 gas already
disincentivises large blobs.

## Errors

`NotTreasury`, `ZeroAddress`, `EmptyBlob`, `UnlockInPast`, `InvalidMode`,
`FeeAboveCap`, `InsufficientFee`, `AlreadyRevealed`, `StillSealed`,
`UnknownCapsule`, `TransferFailed`.

## Tests

26 Foundry tests covering: constructor validation, both unlock modes, fee
collection / refund / zero-fee path, all revert paths, admin gates, fee cap
enforcement, the explicit "bytes are public while sealed" honesty test, and a
256-run fuzz of the seal→warp→reveal round-trip.

Run with:

```bash
forge test --match-path test/TimeCapsule.t.sol -vv
```

## Gas snapshot (`--gas-report`)

Deployment: **1,713,548 gas**, code size **8,114 bytes**.

| Function              | Min     | Avg     | Median  | Max       |
|-----------------------|--------:|--------:|--------:|----------:|
| `seal`                |  22,940 | 892,781 | 296,808 | 3,112,999 |
| `reveal`              |  23,835 | 112,054 |  52,145 |   347,299 |
| `isUnlocked`          |   2,633 |   5,503 |   5,509 |     5,509 |
| `getCapsule`          |  10,809 |  10,813 |  10,809 |    10,823 |
| `peekCiphertext`      |   6,003 |   6,003 |   6,003 |     6,003 |
| `setFeePerByte`       |  23,861 |  25,983 |  24,798 |    30,474 |
| `setTreasury`         |  23,965 |  25,552 |  23,967 |    28,726 |

`seal` and `reveal` scale with blob size. The high max values come from the
fuzz test pushing 4 KB blobs. A typical 256-byte capsule reveals for ~50k gas;
seal for ~290k gas (most of which is calldata + storage write of the bytes).

## Honest demand concerns

1. **The same UX is achievable with one IPFS pin + a plain timestamp.** If you
   only need "release this content at time T", a CID + a `release(time, cid)`
   event is cheaper than putting bytes on-chain. The on-chain blob makes sense
   only when the user wants the blob's *availability* to live or die with the
   chain itself (no IPFS pinning service to fail). That's a real but narrow
   demand.
2. **The "sealed but readable" property confuses non-technical users and is a
   reputational landmine.** Anyone who treats it as a sealed envelope and
   stores cleartext (or a low-entropy passphrase that's brute-forceable) will
   leak. The README screams about this, but a wallet integration could still
   misrepresent it. Surface in any UI as "queued reveal," not "sealed,"
   and force the user through an explicit "I encrypted this myself" step.

## Secrecy caveat (repeat for emphasis)

The on-chain blob is **public bytes** the moment `seal()` confirms.
"Encrypted" status depends entirely on whether the user encrypted off-chain
before calling. The contract enforces *event-based reveal*, not *cryptographic
secrecy*.
