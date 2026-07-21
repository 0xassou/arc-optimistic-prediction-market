// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * ============================================================================
 *  OPTIMISTIC PREDICTION MARKET — reusable primitive for Arc
 * ============================================================================
 *
 *  A simple parimutuel prediction market with a built-in "optimistic
 *  oracle" resolution flow — no external paid oracle dependency.
 *
 *  Parimutuel mechanics:
 *
 *  1. Anyone can CREATE a market (a question + an end time).
 *  2. Anyone can BET "Yes" or "No" in USDC while the market is open
 *     (before the end time).
 *  3. All "Yes" bets go into one pool, all "No" bets into another. Odds
 *     are simply the ratio between the two pools.
 *  5. Winners get their stake back plus a proportional share of the
 *     losing pool (parimutuel, same mechanism used at horse tracks).
 *  6. Edge case: if nobody bet on the winning side, everyone is
 *     refunded their stake.
 *
 *  Two-phase optimistic resolution:
 *
 *  - Standard "resolve()" designs trust a single party (the market
 *    creator) completely. This contract instead uses a lightweight
 *    "optimistic oracle" pattern — the kind of mechanism used by
 *    systems like UMA or Reality.eth, minus any paid infrastructure:
 *  - After the market ends, the CREATOR proposes an outcome
 *    (proposeResolution). If the creator stays inactive past
 *    `proposalGracePeriod`, the contract OWNER can propose on their
 *    behalf (adminProposeResolution) — this keeps a market from being
 *    stuck forever just because its creator disappeared.
 *  - This opens a dispute window (`disputeWindow`, 24h by default).
 *    ANYONE can dispute (disputeResolution) by locking a USDC bond
 *    (`disputeBond`).
 *  - If nobody disputes before the window closes, anyone can finalize
 *    (finalizeResolution) — the proposal becomes final and claims open.
 *  - If disputed, the market enters the Disputed phase and ONLY THE
 *    OWNER can rule (adminResolve). If the disputer was right, their
 *    bond is refunded; if not, it's forfeited and added to the
 *    protocol fee pot (accruedFees), withdrawable to the treasury.
 *  - Anti-stuck-funds safety net: if a disputed market is never ruled
 *    on (lost keys, unavailable owner...), ANYONE can, after a long
 *    timeout (`adminTimeout`, 30 days by default from the dispute),
 *    trigger a neutral full refund (forceFinalizeDisputeTimeout) —
 *    every stake and the disputer's bond are returned, no fees, no
 *    side favored. This admits "we couldn't determine the truth"
 *    instead of freezing funds forever.
 *
 *  Trust model: this mechanism protects against a dishonest MARKET
 *  CREATOR. It does NOT protect against a dishonest contract OWNER,
 *  who remains the arbiter of last resort for disputed markets (same
 *  as for the fee configuration below). If you need protection against
 *  a malicious owner too, consider making the owner a multisig or a
 *  DAO-controlled address, or wiring `adminResolve` behind a timelock.
 *
 *  Protocol fee:
 *  - A low fee (0.50% by default — well under the ~2% charged by most
 *    large platforms) is taken at claim time, ONLY on the WINNINGS
 *    portion (the share of the losing pool) — never on the refunded
 *    stake, and no fee at all on refunds.
 *  - The rate is owner-configurable (capped at MAX_FEE_BPS to protect
 *    users), and accrued fees are withdrawable by the owner to a
 *    treasury address.
 *
 *  Security:
 *  - SafeERC20: safe token transfers (handles non-standard tokens).
 *  - ReentrancyGuard: protects claim() and the arbitration functions.
 *  - Ownable: admin functions restricted to the contract owner.
 *  - Checks-Effects-Interactions: state is updated BEFORE any transfer.
 *
 *  Deployed and battle-tested on Arc Testnet as part of Wager, a
 *  prediction-market MVP — this file is the standalone, app-agnostic
 *  version of that contract, meant to be forked or imported as a
 *  building block for other Arc projects.
 * ============================================================================
 */

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract OptimisticPredictionMarket is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------
    //  TYPES
    // ------------------------------------------------------------------

    /// Market outcome. `Unresolved` until a result is finalized (also
    /// the final value of a neutrally-refunded market, see
    /// `forceFinalizeDisputeTimeout`).
    enum Outcome {
        Unresolved,
        Yes,
        No
    }

    /// Where a market currently sits in the resolution cycle.
    enum Phase {
        Open, // betting allowed, no resolution proposed yet
        Proposed, // outcome proposed, dispute window running
        Disputed, // disputed, awaiting owner arbitration
        Finalized // final outcome set, claims open
    }

    /// All data for one market.
    struct Market {
        address creator; // whoever created the market (may propose a resolution)
        string question; // e.g. "Will BTC top $100k by Dec 31?"
        uint64 endTime; // Unix timestamp after which betting closes
        Phase phase; // current phase of the resolution cycle
        Outcome outcome; // final outcome once Finalized (Unresolved if neutrally refunded)
        Outcome proposedOutcome; // proposed outcome (kept for reference even after finalization)
        uint64 proposedAt; // timestamp of the proposal (0 until one exists)
        uint64 disputedAt; // timestamp of the dispute (0 if never disputed)
        address disputer; // who disputed (address(0) if none)
        uint256 disputeBondLocked; // bond amount locked, snapshotted at dispute time
        bool forceRefunded; // true if finalized via the anti-stuck-funds safety net
        uint256 yesPool; // total USDC bet on "Yes" (6 decimals)
        uint256 noPool; // total USDC bet on "No" (6 decimals)
        uint256 betCount; // total number of bets placed (for stats)
    }

    /// One user's position on one market.
    struct Position {
        uint256 yesAmount; // USDC staked on "Yes" by this user
        uint256 noAmount; // USDC staked on "No" by this user
        bool claimed; // true once this user has claimed their payout
    }

    // ------------------------------------------------------------------
    //  STATE
    // ------------------------------------------------------------------

    /// The ERC-20 token used for all bets (immutable = fixed at deployment).
    /// On Arc, this is expected to be USDC, but any standard ERC-20 works.
    IERC20 public immutable usdc;

    /// All markets. A market's ID is its index in this array.
    Market[] private _markets;

    /// positions[marketId][user] => Position
    mapping(uint256 => mapping(address => Position)) public positions;

    // ------------------------------------------------------------------
    //  RESOLUTION & DISPUTE CONFIG
    // ------------------------------------------------------------------

    /// Length of the dispute window after a proposal. Default: 24h.
    uint64 public disputeWindow;

    /// USDC bond required to dispute a proposal (6 decimals).
    /// Default: 5 USDC. Forfeited if the dispute is rejected by the owner.
    uint256 public disputeBond;

    /// Delay after `endTime` beyond which the owner may propose a
    /// resolution in place of a creator who stayed inactive. Default: 7 days.
    uint64 public proposalGracePeriod;

    /// Delay after a dispute beyond which, if the owner still hasn't
    /// ruled, anyone can trigger a neutral refund (anti-stuck-funds
    /// safety net). Default: 30 days.
    uint64 public adminTimeout;

    // ------------------------------------------------------------------
    //  PROTOCOL FEE
    // ------------------------------------------------------------------

    /// Absolute cap on the fee rate: 5% (500 basis points).
    /// The owner can NEVER exceed this cap — protects bettors.
    uint16 public constant MAX_FEE_BPS = 500;

    /// Fee rate in basis points (1 bps = 0.01%). Default: 50 = 0.50%.
    /// Applied only to the WINNINGS portion at claim time.
    uint16 public feeBps = 50;

    /// Address that receives fees via withdrawFees() (and forfeited
    /// dispute bonds, which join the same pot).
    address public treasury;

    /// Accrued fees + forfeited dispute bonds not yet withdrawn to the treasury.
    uint256 public accruedFees;

    // ------------------------------------------------------------------
    //  EVENTS  (integrators should index these for off-chain state)
    // ------------------------------------------------------------------

    event MarketCreated(
        uint256 indexed marketId,
        address indexed creator,
        string question,
        uint64 endTime
    );

    event BetPlaced(
        uint256 indexed marketId,
        address indexed bettor,
        bool isYes,
        uint256 amount
    );

    /// @param proposer The creator, or the owner if the creator was inactive.
    /// @param disputeDeadline Timestamp after which the dispute window closes.
    event ResolutionProposed(
        uint256 indexed marketId,
        address indexed proposer,
        Outcome outcome,
        uint64 disputeDeadline
    );

    event ResolutionDisputed(
        uint256 indexed marketId,
        address indexed disputer,
        uint256 bondAmount
    );

    /// @param wasDisputed true if the market went through owner arbitration
    /// (or the neutral safety net — in which case `outcome` is Unresolved).
    event MarketFinalized(uint256 indexed marketId, Outcome outcome, bool wasDisputed);

    event RewardClaimed(
        uint256 indexed marketId,
        address indexed bettor,
        uint256 amount
    );

    event FeeUpdated(uint16 oldFeeBps, uint16 newFeeBps);
    event TreasuryUpdated(address oldTreasury, address newTreasury);
    event FeesWithdrawn(address indexed to, uint256 amount);

    // ------------------------------------------------------------------
    //  CUSTOM ERRORS  (cheaper in gas than require strings)
    // ------------------------------------------------------------------

    error QuestionEmpty();
    error EndTimeInPast();
    error MarketNotFound();
    error BettingClosed();
    error AmountZero();
    error NotCreator();
    error TooEarlyToResolve();
    error InvalidOutcome();
    error NothingToClaim();
    error AlreadyClaimed();
    error FeeTooHigh();
    error TreasuryZero();
    error NoFeesToWithdraw();
    error AlreadyProposed();
    error NotProposed();
    error NotDisputed();
    error NotFinalized();
    error DisputeWindowClosed();
    error DisputeWindowOpen();
    error CreatorCannotDispute();
    error GracePeriodNotElapsed();
    error TimeoutNotReached();
    error InvalidConfig();

    // ------------------------------------------------------------------
    //  CONSTRUCTOR
    // ------------------------------------------------------------------

    /// @param bettingToken     ERC-20 token used for bets (e.g. USDC on Arc).
    /// @param treasuryAddress  Address that will receive protocol fees.
    constructor(
        address bettingToken,
        address treasuryAddress
    ) Ownable(msg.sender) {
        require(bettingToken != address(0), "betting token address zero");
        if (treasuryAddress == address(0)) revert TreasuryZero();
        usdc = IERC20(bettingToken);
        treasury = treasuryAddress;

        disputeWindow = 24 hours;
        disputeBond = 5_000_000; // 5 USDC (6 decimals)
        proposalGracePeriod = 7 days;
        adminTimeout = 30 days;
    }

    // ------------------------------------------------------------------
    //  1. CREATE A MARKET
    // ------------------------------------------------------------------

    /**
     * Creates a new prediction market.
     * @param question The question being asked (must be non-empty).
     * @param endTime  Unix timestamp (seconds) when betting closes — must be in the future.
     * @return marketId The ID of the created market.
     */
    function createMarket(
        string calldata question,
        uint64 endTime
    ) external returns (uint256 marketId) {
        if (bytes(question).length == 0) revert QuestionEmpty();
        if (endTime <= block.timestamp) revert EndTimeInPast();

        marketId = _markets.length;

        // Pools start at zero, phase starts at Open.
        _markets.push(
            Market({
                creator: msg.sender,
                question: question,
                endTime: endTime,
                phase: Phase.Open,
                outcome: Outcome.Unresolved,
                proposedOutcome: Outcome.Unresolved,
                proposedAt: 0,
                disputedAt: 0,
                disputer: address(0),
                disputeBondLocked: 0,
                forceRefunded: false,
                yesPool: 0,
                noPool: 0,
                betCount: 0
            })
        );

        emit MarketCreated(marketId, msg.sender, question, endTime);
    }

    // ------------------------------------------------------------------
    //  2. BET
    // ------------------------------------------------------------------

    /**
     * Bets `amount` on "Yes" or "No".
     * The caller must have already called `token.approve(thisContract, amount)`.
     * @param marketId ID of the market.
     * @param isYes    true = bet "Yes", false = bet "No".
     * @param amount   Amount in the betting token's smallest unit (e.g. USDC has 6 decimals, so 10 USDC = 10_000_000).
     */
    function bet(uint256 marketId, bool isYes, uint256 amount) external {
        Market storage market = _getMarket(marketId);

        if (market.phase != Phase.Open) revert BettingClosed();
        if (block.timestamp >= market.endTime) revert BettingClosed();
        if (amount == 0) revert AmountZero();

        // --- Effects: update state BEFORE the transfer ---
        Position storage position = positions[marketId][msg.sender];
        if (isYes) {
            market.yesPool += amount;
            position.yesAmount += amount;
        } else {
            market.noPool += amount;
            position.noAmount += amount;
        }
        market.betCount += 1;

        // --- Interaction: pull the tokens from the caller's wallet ---
        usdc.safeTransferFrom(msg.sender, address(this), amount);

        emit BetPlaced(marketId, msg.sender, isYes, amount);
    }

    // ------------------------------------------------------------------
    //  3. TWO-PHASE RESOLUTION (propose -> dispute -> finalize/arbitrate)
    // ------------------------------------------------------------------

    /**
     * The creator proposes an outcome after the market has ended. Anyone
     * can then dispute it during `disputeWindow`.
     */
    function proposeResolution(uint256 marketId, Outcome outcome) external {
        Market storage market = _getMarket(marketId);

        if (msg.sender != market.creator) revert NotCreator();
        if (block.timestamp < market.endTime) revert TooEarlyToResolve();
        if (market.phase != Phase.Open) revert AlreadyProposed();

        _propose(market, marketId, outcome);
    }

    /**
     * Safety net: if the creator stays inactive for more than
     * `proposalGracePeriod` after betting closes, the owner may propose
     * an outcome in their place — keeps a market from being stuck just
     * because its creator is unavailable. Goes through the same dispute
     * window as a creator-submitted proposal.
     */
    function adminProposeResolution(uint256 marketId, Outcome outcome) external onlyOwner {
        Market storage market = _getMarket(marketId);

        if (market.phase != Phase.Open) revert AlreadyProposed();
        if (block.timestamp < uint256(market.endTime) + proposalGracePeriod) {
            revert GracePeriodNotElapsed();
        }

        _propose(market, marketId, outcome);
    }

    /// Shared logic between proposeResolution / adminProposeResolution.
    function _propose(Market storage market, uint256 marketId, Outcome outcome) private {
        if (outcome != Outcome.Yes && outcome != Outcome.No) revert InvalidOutcome();

        market.phase = Phase.Proposed;
        market.proposedOutcome = outcome;
        market.proposedAt = uint64(block.timestamp);

        emit ResolutionProposed(
            marketId,
            msg.sender,
            outcome,
            uint64(block.timestamp) + disputeWindow
        );
    }

    /**
     * Disputes the current proposal by locking `disputeBond` tokens.
     * The market's creator cannot dispute their own market. Must be
     * called during the dispute window.
     */
    function disputeResolution(uint256 marketId) external nonReentrant {
        Market storage market = _getMarket(marketId);

        if (market.phase != Phase.Proposed) revert NotProposed();
        if (block.timestamp > uint256(market.proposedAt) + disputeWindow) {
            revert DisputeWindowClosed();
        }
        if (msg.sender == market.creator) revert CreatorCannotDispute();

        uint256 bond = disputeBond;

        // --- Effects before Interaction ---
        market.phase = Phase.Disputed;
        market.disputer = msg.sender;
        market.disputeBondLocked = bond;
        market.disputedAt = uint64(block.timestamp);

        usdc.safeTransferFrom(msg.sender, address(this), bond);

        emit ResolutionDisputed(marketId, msg.sender, bond);
    }

    /**
     * Finalizes an undisputed proposal once the dispute window has
     * closed. Anyone can call this (it only locks in an outcome that's
     * already committed — no token transfer, no special privilege).
     */
    function finalizeResolution(uint256 marketId) external {
        Market storage market = _getMarket(marketId);

        if (market.phase != Phase.Proposed) revert NotProposed();
        if (block.timestamp <= uint256(market.proposedAt) + disputeWindow) {
            revert DisputeWindowOpen();
        }

        market.phase = Phase.Finalized;
        market.outcome = market.proposedOutcome;

        emit MarketFinalized(marketId, market.proposedOutcome, false);
    }

    /**
     * Owner arbitration on a disputed market.
     * - If `finalOutcome` matches the original proposal: the disputer
     *   was wrong, their bond is forfeited and joins accruedFees.
     * - Otherwise: the disputer was right, their bond is refunded.
     */
    function adminResolve(uint256 marketId, Outcome finalOutcome) external onlyOwner nonReentrant {
        Market storage market = _getMarket(marketId);

        if (market.phase != Phase.Disputed) revert NotDisputed();
        if (finalOutcome != Outcome.Yes && finalOutcome != Outcome.No) revert InvalidOutcome();

        bool disputeUpheld = finalOutcome != market.proposedOutcome;
        uint256 bond = market.disputeBondLocked;
        address disputerAddress = market.disputer;

        // --- Effects before Interaction ---
        market.phase = Phase.Finalized;
        market.outcome = finalOutcome;
        if (!disputeUpheld) {
            accruedFees += bond;
        }

        if (disputeUpheld) {
            usdc.safeTransfer(disputerAddress, bond);
        }

        emit MarketFinalized(marketId, finalOutcome, true);
    }

    /**
     * Anti-stuck-funds safety net: if a disputed market still hasn't
     * been ruled on by the owner after `adminTimeout` (30 days by
     * default) since the dispute was raised, ANYONE can trigger a
     * neutral refund — nobody is favored, everybody gets their stake
     * back (and the disputer their bond), with no fees.
     */
    function forceFinalizeDisputeTimeout(uint256 marketId) external nonReentrant {
        Market storage market = _getMarket(marketId);

        if (market.phase != Phase.Disputed) revert NotDisputed();
        if (block.timestamp <= uint256(market.disputedAt) + adminTimeout) {
            revert TimeoutNotReached();
        }

        uint256 bond = market.disputeBondLocked;
        address disputerAddress = market.disputer;

        // --- Effects before Interaction ---
        market.phase = Phase.Finalized;
        market.forceRefunded = true;
        // outcome stays Unresolved: _calculatePayout short-circuits via forceRefunded.

        usdc.safeTransfer(disputerAddress, bond);

        emit MarketFinalized(marketId, Outcome.Unresolved, true);
    }

    // ------------------------------------------------------------------
    //  4. CLAIM WINNINGS
    // ------------------------------------------------------------------

    /**
     * Claims a payout after finalization.
     *
     * Parimutuel calculation:
     *   gross payout = winning stake + (winning stake / winning pool) * losing pool
     *
     * Fee: feeBps applies ONLY to the winnings portion (the share of the
     * losing pool), never to the refunded stake. The net amount is paid
     * out, the fee accrues in accruedFees.
     *
     * Special cases (fee-free):
     *  - Empty winning pool: everyone is refunded their stake.
     *  - Neutrally-refunded market (safety net): everyone gets back
     *    everything they staked on both sides.
     */
    function claim(uint256 marketId) external nonReentrant {
        Market storage market = _getMarket(marketId);
        if (market.phase != Phase.Finalized) revert NotFinalized();

        Position storage position = positions[marketId][msg.sender];
        if (position.claimed) revert AlreadyClaimed();

        (uint256 netPayout, uint256 fee) = _calculatePayout(market, position);
        if (netPayout == 0) revert NothingToClaim();

        // --- Effects before Interaction (reentrancy protection) ---
        position.claimed = true;
        accruedFees += fee;

        usdc.safeTransfer(msg.sender, netPayout);

        emit RewardClaimed(marketId, msg.sender, netPayout);
    }

    // ------------------------------------------------------------------
    //  READ FUNCTIONS  (for indexers, dashboards, and other frontends)
    // ------------------------------------------------------------------

    /// Total number of markets created.
    function marketCount() external view returns (uint256) {
        return _markets.length;
    }

    /// Fetches a market by ID.
    function getMarket(uint256 marketId) external view returns (Market memory) {
        if (marketId >= _markets.length) revert MarketNotFound();
        return _markets[marketId];
    }

    /**
     * Fetches a page of markets (for listing UIs).
     * @param offset Starting index.
     * @param limit  Maximum number of markets to return.
     */
    function getMarkets(
        uint256 offset,
        uint256 limit
    ) external view returns (Market[] memory page) {
        uint256 total = _markets.length;
        if (offset >= total) return new Market[](0);

        uint256 end = offset + limit;
        if (end > total) end = total;

        page = new Market[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            page[i - offset] = _markets[i];
        }
    }

    /// A user's position on a market.
    function getPosition(
        uint256 marketId,
        address user
    ) external view returns (Position memory) {
        return positions[marketId][user];
    }

    /// Total volume (Yes + No) of a market, in the betting token's smallest unit.
    function getVolume(uint256 marketId) external view returns (uint256) {
        Market storage market = _getMarket(marketId);
        return market.yesPool + market.noPool;
    }

    /**
     * NET (post-fee) amount `user` can claim on a market (0 if nothing,
     * already claimed, or not yet finalized). Lets a frontend show a
     * "Claim" button without reimplementing the payout math.
     */
    function claimableAmount(
        uint256 marketId,
        address user
    ) external view returns (uint256) {
        if (marketId >= _markets.length) return 0;
        Market storage market = _markets[marketId];
        if (market.phase != Phase.Finalized) return 0;

        Position storage position = positions[marketId][user];
        if (position.claimed) return 0;

        (uint256 netPayout, ) = _calculatePayout(market, position);
        return netPayout;
    }

    // ------------------------------------------------------------------
    //  INTERNAL FUNCTIONS
    // ------------------------------------------------------------------

    /// Returns the market or reverts if it doesn't exist.
    function _getMarket(uint256 marketId) private view returns (Market storage) {
        if (marketId >= _markets.length) revert MarketNotFound();
        return _markets[marketId];
    }

    /**
     * Computes a position's NET payout on a finalized market, along with
     * the corresponding protocol fee (see claim()).
     * @return netPayout Amount paid to the bettor (stake + winnings − fee).
     * @return fee       Fee taken (0 on a refund or a loss).
     */
    function _calculatePayout(
        Market storage market,
        Position storage position
    ) private view returns (uint256 netPayout, uint256 fee) {
        if (market.forceRefunded) {
            // Safety net triggered: nobody "won", everyone gets their
            // full stake back on both sides, fee-free.
            return (position.yesAmount + position.noAmount, 0);
        }

        bool yesWon = market.outcome == Outcome.Yes;

        uint256 winningPool = yesWon ? market.yesPool : market.noPool;
        uint256 losingPool = yesWon ? market.noPool : market.yesPool;
        uint256 userWinningStake = yesWon ? position.yesAmount : position.noAmount;
        uint256 userLosingStake = yesWon ? position.noAmount : position.yesAmount;

        if (winningPool == 0) {
            // Nobody bet on the winning side: refund, no fee.
            return (userLosingStake, 0);
        }

        if (userWinningStake == 0) {
            // This user lost: nothing to claim.
            return (0, 0);
        }

        // Proportional share of the losing pool = the pure "winnings".
        uint256 winnings = (userWinningStake * losingPool) / winningPool;

        // Fee only on winnings — never on the refunded stake.
        fee = (winnings * feeBps) / 10_000;
        netPayout = userWinningStake + winnings - fee;
    }

    // ------------------------------------------------------------------
    //  ADMIN (owner only)
    // ------------------------------------------------------------------

    /// Updates the protocol fee rate (capped at MAX_FEE_BPS = 5%).
    function setFeeBps(uint16 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_FEE_BPS) revert FeeTooHigh();
        emit FeeUpdated(feeBps, newFeeBps);
        feeBps = newFeeBps;
    }

    /// Changes the treasury address that receives fees.
    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert TreasuryZero();
        emit TreasuryUpdated(treasury, newTreasury);
        treasury = newTreasury;
    }

    /// Sends accrued fees to the treasury.
    function withdrawFees() external onlyOwner {
        uint256 amount = accruedFees;
        if (amount == 0) revert NoFeesToWithdraw();

        // Effects before Interaction.
        accruedFees = 0;
        usdc.safeTransfer(treasury, amount);

        emit FeesWithdrawn(treasury, amount);
    }

    /// Updates the dispute window length.
    function setDisputeWindow(uint64 newWindow) external onlyOwner {
        if (newWindow == 0) revert InvalidConfig();
        disputeWindow = newWindow;
    }

    /// Updates the required dispute bond amount.
    function setDisputeBond(uint256 newBond) external onlyOwner {
        disputeBond = newBond;
    }

    /// Updates the grace period before a creator is considered inactive.
    function setProposalGracePeriod(uint64 newPeriod) external onlyOwner {
        proposalGracePeriod = newPeriod;
    }

    /// Updates the anti-stuck-funds safety net delay (must stay strictly
    /// greater than the dispute window, otherwise it could expire before
    /// a dispute is even possible).
    function setAdminTimeout(uint64 newTimeout) external onlyOwner {
        if (newTimeout <= disputeWindow) revert InvalidConfig();
        adminTimeout = newTimeout;
    }
}
