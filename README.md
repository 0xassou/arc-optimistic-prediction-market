# Arc Optimistic Prediction Market

A parimutuel prediction market with a built-in **optimistic-oracle resolution
flow** — a free, forkable alternative to a paid oracle (UMA, Reality.eth-style
mechanisms cost gas *and* fees), purpose-built for [Arc](https://arc.network),
Circle's USDC-native L1.

> Extracted from [Wager](https://wager-arc.vercel.app), a prediction-market
> MVP on Arc Testnet. This repo is the standalone, app-agnostic version of
> that contract — fork it, read it, or import it as a building block for
> your own Arc project.

- **34/34 Hardhat tests**, covering every phase transition and edge case —
  read them as living documentation of the exact expected behavior.
- **No external dependencies at runtime** beyond an ERC-20 token (USDC on
  Arc). No oracle subscription, no keeper network, no off-chain component.
- **~450 lines of commented Solidity.** You can read the whole thing in one
  sitting.

---

## Table of contents

- [Why this exists](#why-this-exists)
- [How it works](#how-it-works)
  - [1. Parimutuel betting](#1-parimutuel-betting)
  - [2. Optimistic resolution](#2-optimistic-resolution)
  - [3. Resolution flow diagram](#3-resolution-flow-diagram)
  - [4. Protocol fee](#4-protocol-fee)
  - [5. Trust model — read this before deploying](#5-trust-model--read-this-before-deploying)
- [Quick start](#quick-start)
- [Deploying to Arc Testnet](#deploying-to-arc-testnet)
- [Integrating this contract into your own project](#integrating-this-contract-into-your-own-project)
  - [Function reference](#function-reference)
  - [Call sequence for a full market lifecycle](#call-sequence-for-a-full-market-lifecycle)
  - [Events to index](#events-to-index)
- [Configuration reference](#configuration-reference)
- [Testing](#testing)
- [Security notes](#security-notes)
- [License](#license)

---

## Why this exists

Prediction markets need a way to determine the outcome of a question. There
are three common approaches, each with a real downside:

| Approach | Downside |
|---|---|
| Trust the market creator completely | A single dishonest party can steal every bettor's funds by lying about the result. |
| Use a paid oracle network (UMA, Chainlink, etc.) | Real cost per resolution, external dependency, integration overhead — often overkill for a hackathon project or a small app. |
| Build a full decentralized voting/staking oracle from scratch | Massive scope for something that's meant to be a building block. |

This contract takes a fourth path: a **two-phase optimistic resolution**
mechanism, entirely self-contained in Solidity, with an economic
anti-spam bond and a human arbiter (the contract owner) as a last resort —
plus a **timeout-based safety net** so funds can never be frozen forever even
if that arbiter disappears. It costs nothing beyond normal gas, and there's
no off-chain infrastructure to run or trust.

If you're building anything on Arc that needs "we all agree on what actually
happened" — prediction markets, conditional payouts, dispute-gated escrows —
this pattern is directly reusable.

## How it works

### 1. Parimutuel betting

- Anyone can call `createMarket(question, endTime)` to open a new market.
- While the market is open (before `endTime`), anyone can call
  `bet(marketId, isYes, amount)` to bet on "Yes" or "No" in the configured
  ERC-20 token (USDC on Arc).
- All "Yes" bets accumulate in one pool, all "No" bets in another. The
  implied odds are simply the ratio between the two pools — no separate
  order book, no AMM curve.
- Once resolved, winners split the losing pool proportionally to their
  stake (like a horse-track tote board): `payout = stake + stake * losingPool / winningPool`.
- Edge case: if nobody bet on the winning side, everyone is refunded their
  exact stake.

### 2. Optimistic resolution

Instead of a single `resolve()` call trusted blindly, resolving a market
goes through up to four steps:

1. **Propose.** After `endTime`, the market's creator calls
   `proposeResolution(marketId, outcome)`. If the creator never shows up,
   the contract owner can step in with `adminProposeResolution` once a
   grace period has passed — so a market can't be stuck forever just
   because its creator disappeared.
2. **Dispute window.** Proposing an outcome does *not* finalize it — it
   opens a challenge window (24h by default). During this window, **anyone**
   can call `disputeResolution(marketId)`, locking a small USDC bond.
3. **Finalize or arbitrate.**
   - If nobody disputes before the window closes, anyone can call
     `finalizeResolution(marketId)` — the proposed outcome becomes final
     and `claim()` opens up.
   - If someone disputes, the market moves to a `Disputed` phase and only
     the contract owner can settle it, via `adminResolve(marketId, finalOutcome)`.
     If the disputer turns out to be right, they get their bond back; if
     not, the bond is forfeited to the protocol fee pot.
4. **Anti-stuck-funds safety net.** If a disputed market is never ruled on
   (the owner loses access, goes offline, whatever), **anyone** can call
   `forceFinalizeDisputeTimeout(marketId)` after a long timeout (30 days by
   default) to trigger a fully neutral refund: every bettor gets their
   exact stake back, the disputer gets their bond back, no fees, no side
   favored. The contract admits "we couldn't determine the truth" instead
   of freezing funds forever.

### 3. Resolution flow diagram

```
                         endTime reached
                              │
                              ▼
                        ┌───────────┐
                        │   Open    │  bets allowed
                        └─────┬─────┘
                              │ proposeResolution()          (creator)
                              │ adminProposeResolution()     (owner, after grace period,
                              │                                if creator stayed inactive)
                              ▼
                        ┌───────────┐
              ┌─────────┤ Proposed  │  dispute window running (24h default)
              │         └─────┬─────┘
   no dispute │               │ disputeResolution()  (anyone, locks a bond)
   before the │               ▼
   window     │         ┌───────────┐
   closes     │         │ Disputed  │  awaiting owner's ruling
              │         └─────┬─────┘
              │      ┌────────┼─────────────────────┐
              │      │        │                      │
              │  adminResolve()             adminTimeout elapses
              │  (owner rules,                (30 days, owner never ruled)
              │   bond refunded                       │
              │   or forfeited)              forceFinalizeDisputeTimeout()
              │      │                        (anyone; neutral refund,
              │      │                         bond returned, no fees)
              │      │                              │
   finalizeResolution() │                              │
   (anyone)      │      │                              │
              ▼      ▼                              ▼
            ┌───────────────────────────────────────────┐
            │                 Finalized                  │
            │      claim() opens for every bettor         │
            └───────────────────────────────────────────┘
```

### 4. Protocol fee

A small fee (0.50% by default, capped at 5% — `MAX_FEE_BPS`) is taken at
claim time, **only on the winnings portion** (the share of the losing pool a
winner receives). It is never applied to the refunded stake itself, and
never applied at all on a full refund (empty winning pool, or the neutral
timeout refund). The rate is owner-configurable via `setFeeBps`, and
accrued fees (plus any forfeited dispute bonds) are withdrawable to a
treasury address via `withdrawFees()`.

### 5. Trust model — read this before deploying

This mechanism protects bettors against **a dishonest market creator**.
It does **not** protect them against a dishonest contract **owner** — the
owner is the arbiter of last resort for every disputed market on the
contract, and also controls the fee rate and treasury address. This is a
deliberate, minimal design: one trusted role instead of zero (blind trust in
creators) or a whole external oracle network.

If your use case needs protection against a malicious owner too, you have
several options that all work without touching the contract's logic:

- Deploy with a **multisig** (e.g. Safe) as the owner instead of an EOA.
- Put `adminResolve` / fee-changing calls behind a **timelock**.
- Fork the contract and swap `Ownable` for a DAO-style voting module.

## Quick start

```bash
git clone <this-repo-url>
cd arc-optimistic-prediction-market
npm install
npx hardhat test        # 34 passing
npx hardhat compile
```

Requires Node.js 18+.

## Deploying to Arc Testnet

1. **Add Arc Testnet to your wallet:**

   | Field | Value |
   |---|---|
   | Network Name | `Arc Testnet` |
   | RPC URL | `https://rpc.testnet.arc.network` |
   | Chain ID | `5042002` |
   | Currency Symbol | `USDC` |
   | Block Explorer | `https://arcscan.io` |

   > On Arc, the **native gas currency is USDC**, not ETH. Double-check the
   > RPC URL against [Arc's docs](https://docs.arc.network) — testnet
   > endpoints can change.

2. **Get testnet USDC** from [faucet.circle.com](https://faucet.circle.com)
   (Arc Testnet network). This pays both gas and covers your test bets.

3. **Configure your environment:**

   ```bash
   cp .env.example .env
   ```

   Fill in `PRIVATE_KEY` (a wallet dedicated to testnets — never a wallet
   holding real funds) and, optionally, `USDC_ADDRESS` (Circle's official
   USDC on Arc Testnet — verify the current address at
   [developers.circle.com](https://developers.circle.com/stablecoins/usdc-contract-addresses)).
   Leave `USDC_ADDRESS` empty to have the script deploy a `MockUSDC` for you
   instead, with a public `faucet()` function.

4. **Deploy:**

   ```bash
   npm run deploy:arc
   ```

   The script prints the deployed `OptimisticPredictionMarket` address, the
   USDC address used, and the treasury address — copy these into whatever
   frontend or integration you're building.

## Integrating this contract into your own project

You can use this contract three ways:

- **Fork it wholesale** and adapt it (rename, add categories, change the
  betting token, etc.) — this is what [Wager](https://wager-arc.vercel.app)
  does.
- **Deploy it as-is** and build a frontend or bot against its ABI.
- **Copy just the resolution state machine** (the `Phase` enum + the five
  `proposeResolution` / `adminProposeResolution` / `disputeResolution` /
  `finalizeResolution` / `adminResolve` / `forceFinalizeDisputeTimeout`
  functions) into your own contract if you don't need parimutuel betting at
  all — e.g. for a conditional-payout escrow that just needs "did X happen?"

### Function reference

**Market lifecycle**

| Function | Caller | When | Effect |
|---|---|---|---|
| `createMarket(question, endTime)` | anyone | anytime | Opens a new market. Returns `marketId`. |
| `bet(marketId, isYes, amount)` | anyone | while `Open`, before `endTime` | Requires prior `token.approve()`. Adds to a pool. |
| `proposeResolution(marketId, outcome)` | market creator | after `endTime` | Starts the dispute window. |
| `adminProposeResolution(marketId, outcome)` | contract owner | after `endTime + proposalGracePeriod`, if creator hasn't proposed | Same effect as above, fallback path. |
| `disputeResolution(marketId)` | anyone except the creator | during the dispute window | Locks `disputeBond`, moves the market to `Disputed`. |
| `finalizeResolution(marketId)` | anyone | after the dispute window closes, undisputed | Locks in the proposed outcome. |
| `adminResolve(marketId, finalOutcome)` | contract owner | while `Disputed` | Settles the dispute; refunds or forfeits the bond. |
| `forceFinalizeDisputeTimeout(marketId)` | anyone | `adminTimeout` after the dispute, still unruled | Neutral refund safety net. |
| `claim(marketId)` | anyone with a position | once `Finalized` | Pays out (or refunds) the caller's stake. |

**Read functions** (all `view`, safe to call off-chain / from a frontend):
`marketCount()`, `getMarket(marketId)`, `getMarkets(offset, limit)`,
`getPosition(marketId, user)`, `getVolume(marketId)`,
`claimableAmount(marketId, user)`.

**Admin functions** (`onlyOwner`): `setFeeBps`, `setTreasury`,
`withdrawFees`, `setDisputeWindow`, `setDisputeBond`,
`setProposalGracePeriod`, `setAdminTimeout`.

### Call sequence for a full market lifecycle

```js
// Outcome enum values (Solidity enums surface as plain integers via ethers.js)
const OUTCOME_YES = 1;
const OUTCOME_NO = 2;

// 1. Create a market
const tx = await market.createMarket("Will BTC top $100k by Dec 31?", endTime);
// marketId = index of this market in the contract's internal array
// (0 for the first market ever created; read it back via marketCount() - 1,
// or parse the MarketCreated event from the receipt)

// 2. Bettors place bets (each needs to approve the token first)
await usdc.connect(alice).approve(market.target, amount);
await market.connect(alice).bet(marketId, true /* isYes */, amount);

// 3. After endTime, the creator proposes an outcome
await market.connect(creator).proposeResolution(marketId, OUTCOME_YES);

// 4a. Nobody disputes -> anyone finalizes after the window closes
await market.finalizeResolution(marketId);

// 4b. ...or someone disputes (needs to approve the bond first)
await usdc.connect(bob).approve(market.target, await market.disputeBond());
await market.connect(bob).disputeResolution(marketId);
// -> the owner then rules:
await market.connect(owner).adminResolve(marketId, OUTCOME_NO);

// 5. Winners claim their payout
await market.connect(alice).claim(marketId);
```

### Events to index

| Event | Emitted when |
|---|---|
| `MarketCreated(marketId, creator, question, endTime)` | a market is created |
| `BetPlaced(marketId, bettor, isYes, amount)` | a bet is placed |
| `ResolutionProposed(marketId, proposer, outcome, disputeDeadline)` | a resolution is proposed (by the creator or the owner) |
| `ResolutionDisputed(marketId, disputer, bondAmount)` | a proposal is disputed |
| `MarketFinalized(marketId, outcome, wasDisputed)` | a market becomes final (`outcome` is `Unresolved` for a neutral timeout refund) |
| `RewardClaimed(marketId, bettor, amount)` | a payout is claimed |
| `FeeUpdated`, `TreasuryUpdated`, `FeesWithdrawn` | admin config changes |

## Configuration reference

All values are set in the constructor and adjustable later by the owner.

| Parameter | Default | Setter | Notes |
|---|---|---|---|
| `feeBps` | `50` (0.50%) | `setFeeBps` | Capped at `MAX_FEE_BPS = 500` (5%), enforced on-chain. |
| `disputeWindow` | `24 hours` | `setDisputeWindow` | Must be non-zero. |
| `disputeBond` | `5_000_000` (5 USDC) | `setDisputeBond` | Size this relative to your typical market volume — too low invites spam disputes, too high discourages legitimate ones. |
| `proposalGracePeriod` | `7 days` | `setProposalGracePeriod` | Time after `endTime` before the owner can propose on the creator's behalf. |
| `adminTimeout` | `30 days` | `setAdminTimeout` | Time after a dispute before anyone can force a neutral refund. Must stay greater than `disputeWindow`. |
| `treasury` | deployer's address (or `TREASURY_ADDRESS` from `.env`) | `setTreasury` | Receives withdrawn fees and forfeited bonds. |

## Testing

```bash
npx hardhat test
```

34 tests, organized by feature: basic lifecycle, `proposeResolution`,
finalization without a dispute, `disputeResolution`, `adminResolve`,
`forceFinalizeDisputeTimeout`, `claim`, protocol fee, and owner
configuration. Every custom error and every phase transition is exercised
at least once — read [`test/OptimisticPredictionMarket.test.js`](test/OptimisticPredictionMarket.test.js)
for the exact expected behavior of any function.

## Security notes

- Uses OpenZeppelin's `SafeERC20`, `ReentrancyGuard`, and `Ownable` —
  audited, widely-used primitives.
- Follows checks-effects-interactions throughout: state is updated before
  any external call.
- Custom errors instead of `require` strings, for lower gas cost.
- **This contract has not been professionally audited.** It's a clean,
  fully-tested reference implementation — review it yourself (it's short)
  before using it with real funds, and consider a proper audit for
  production deployments beyond a testnet or hackathon context.
- See [Trust model](#5-trust-model--read-this-before-deploying) above for
  what this contract does and does not protect against.

## License

MIT — see [LICENSE](LICENSE). Fork it, ship it, no attribution required
(though a mention is always appreciated).
