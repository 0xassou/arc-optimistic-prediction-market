/**
 * Tests for OptimisticPredictionMarket — run against the local Hardhat
 * network. These also serve as living documentation of the contract's
 * expected behavior; read through them if you want to see exactly how
 * each function behaves in practice.
 *
 * Usage:  npx hardhat test
 *
 * Covers:
 *  - market creation -> Yes/No bets
 *  - two-phase resolution: propose -> dispute window -> finalize (no
 *    dispute), owner arbitration (dispute upheld or overturned),
 *    anti-stuck-funds safety net
 *  - protocol fee: 0.50% by default, on WINNINGS only
 *  - betting/claiming is impossible until the market is finalized
 */
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-toolbox/network-helpers");

// 1 USDC = 1_000_000 (6 decimals)
const USDC = (n) => ethers.parseUnits(n.toString(), 6);

// Enum values from the contract
const OUTCOME_UNRESOLVED = 0;
const OUTCOME_YES = 1;
const OUTCOME_NO = 2;
const PHASE_OPEN = 0;
const PHASE_PROPOSED = 1;
const PHASE_DISPUTED = 2;
const PHASE_FINALIZED = 3;

const DISPUTE_WINDOW = 24 * 3600;
const DISPUTE_BOND = USDC(5);

describe("OptimisticPredictionMarket", function () {
  let usdc, market, creator, alice, bob, treasury;

  beforeEach(async function () {
    // `creator` deploys the contract -> they're also the owner.
    [creator, alice, bob, treasury] = await ethers.getSigners();

    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    usdc = await MockUSDC.deploy();
    for (const user of [creator, alice, bob]) {
      await usdc.mint(user.address, USDC(1000));
    }

    const OptimisticPredictionMarket = await ethers.getContractFactory(
      "OptimisticPredictionMarket"
    );
    market = await OptimisticPredictionMarket.deploy(
      await usdc.getAddress(),
      treasury.address
    );

    for (const user of [creator, alice, bob]) {
      await usdc.connect(user).approve(await market.getAddress(), USDC(1000));
    }
  });

  /// Creates a market that ends in 1 hour and returns its ID (0).
  async function createTestMarket() {
    const endTime = (await time.latest()) + 3600;
    await market.createMarket("Will BTC top $100k?", endTime);
    return { marketId: 0, endTime };
  }

  /// Calls proposeResolution and returns the exact timestamp of the mined
  /// block (avoids guessing the timestamp — more robust than computing it
  /// ahead of time, since every transaction advances the clock by at
  /// least 1 second).
  async function proposeAndGetTimestamp(marketId, outcome) {
    const tx = await market.proposeResolution(marketId, outcome);
    const receipt = await tx.wait();
    const block = await ethers.provider.getBlock(receipt.blockNumber);
    return block.timestamp;
  }

  /// Creates a market, places bets, fast-forwards past the end time, and
  /// proposes a "Yes" resolution. Returns the market's end timestamp.
  async function marketWithProposal() {
    const { endTime } = await createTestMarket();
    await market.connect(alice).bet(0, true, USDC(100));
    await market.connect(bob).bet(0, false, USDC(400));
    await time.increaseTo(endTime + 1);
    await market.proposeResolution(0, OUTCOME_YES);
    return endTime;
  }

  // ==================================================================
  //  Basic lifecycle
  // ==================================================================

  it("creates a market with the right data", async function () {
    const { endTime } = await createTestMarket();
    const m = await market.getMarket(0);

    expect(m.creator).to.equal(creator.address);
    expect(m.question).to.equal("Will BTC top $100k?");
    expect(m.endTime).to.equal(endTime);
    expect(m.phase).to.equal(PHASE_OPEN);
    expect(await market.marketCount()).to.equal(1);
  });

  it("rejects an end time in the past", async function () {
    const past = (await time.latest()) - 10;
    await expect(
      market.createMarket("Question?", past)
    ).to.be.revertedWithCustomError(market, "EndTimeInPast");
  });

  it("accepts bets and updates the pools", async function () {
    await createTestMarket();

    await market.connect(alice).bet(0, true, USDC(100));
    await market.connect(bob).bet(0, false, USDC(300));

    const m = await market.getMarket(0);
    expect(m.yesPool).to.equal(USDC(100));
    expect(m.noPool).to.equal(USDC(300));
    expect(m.betCount).to.equal(2);
    expect(await market.getVolume(0)).to.equal(USDC(400));
  });

  it("rejects bets after the end time", async function () {
    const { endTime } = await createTestMarket();
    await time.increaseTo(endTime + 1);

    await expect(
      market.connect(alice).bet(0, true, USDC(10))
    ).to.be.revertedWithCustomError(market, "BettingClosed");
  });

  it("rejects bets once a resolution has been proposed", async function () {
    await marketWithProposal();
    await expect(
      market.connect(alice).bet(0, true, USDC(10))
    ).to.be.revertedWithCustomError(market, "BettingClosed");
  });

  // ==================================================================
  //  Proposing a resolution
  // ==================================================================

  describe("proposeResolution", function () {
    it("only the creator can propose, and only after the market ends", async function () {
      const { endTime } = await createTestMarket();

      await expect(
        market.proposeResolution(0, OUTCOME_YES)
      ).to.be.revertedWithCustomError(market, "TooEarlyToResolve");

      await time.increaseTo(endTime + 1);

      await expect(
        market.connect(alice).proposeResolution(0, OUTCOME_YES)
      ).to.be.revertedWithCustomError(market, "NotCreator");

      const proposedAt = await proposeAndGetTimestamp(0, OUTCOME_YES);
      const filter = market.filters.ResolutionProposed(0);
      const [event] = await market.queryFilter(filter);
      expect(event.args.proposer).to.equal(creator.address);
      expect(event.args.outcome).to.equal(OUTCOME_YES);
      expect(event.args.disputeDeadline).to.equal(BigInt(proposedAt) + BigInt(DISPUTE_WINDOW));

      const m = await market.getMarket(0);
      expect(m.phase).to.equal(PHASE_PROPOSED);
      expect(m.proposedOutcome).to.equal(OUTCOME_YES);
    });

    it("rejects a second proposal", async function () {
      await marketWithProposal();
      await expect(
        market.proposeResolution(0, OUTCOME_NO)
      ).to.be.revertedWithCustomError(market, "AlreadyProposed");
    });

    it("lets the owner propose on behalf of an inactive creator after the grace period", async function () {
      const { endTime } = await createTestMarket();
      await time.increaseTo(endTime + 1);

      // Too early: the 7-day grace period hasn't elapsed yet.
      await expect(
        market.adminProposeResolution(0, OUTCOME_YES)
      ).to.be.revertedWithCustomError(market, "GracePeriodNotElapsed");

      await time.increase(7 * 86400 + 1);

      const tx = await market.adminProposeResolution(0, OUTCOME_YES);
      const receipt = await tx.wait();
      const block = await ethers.provider.getBlock(receipt.blockNumber);
      const [event] = await market.queryFilter(market.filters.ResolutionProposed(0));
      expect(event.args.proposer).to.equal(creator.address);
      expect(event.args.disputeDeadline).to.equal(BigInt(block.timestamp) + BigInt(DISPUTE_WINDOW));

      const m = await market.getMarket(0);
      expect(m.phase).to.equal(PHASE_PROPOSED);
    });

    it("a non-owner cannot propose on behalf of the creator", async function () {
      const { endTime } = await createTestMarket();
      await time.increaseTo(endTime + 7 * 86400 + 2);
      await expect(
        market.connect(alice).adminProposeResolution(0, OUTCOME_YES)
      ).to.be.revertedWithCustomError(market, "OwnableUnauthorizedAccount");
    });
  });

  // ==================================================================
  //  Finalization without a dispute
  // ==================================================================

  describe("finalization without a dispute", function () {
    it("rejects finalization before the window expires", async function () {
      await marketWithProposal();
      await expect(
        market.finalizeResolution(0)
      ).to.be.revertedWithCustomError(market, "DisputeWindowOpen");
    });

    it("lets anyone finalize once the window expires, and opens claims", async function () {
      await marketWithProposal();
      await time.increase(DISPUTE_WINDOW + 1);

      await expect(market.connect(bob).finalizeResolution(0))
        .to.emit(market, "MarketFinalized")
        .withArgs(0, OUTCOME_YES, false);

      const m = await market.getMarket(0);
      expect(m.phase).to.equal(PHASE_FINALIZED);
      expect(m.outcome).to.equal(OUTCOME_YES);

      // Alice (100 on Yes) wins: winning pool 100, losing pool 400,
      // pure winnings = 400, 0.5% fee = 2, net = 100 + 400 - 2 = 498.
      expect(await market.claimableAmount(0, alice.address)).to.equal(USDC(498));
      await market.connect(alice).claim(0);
    });
  });

  // ==================================================================
  //  Disputing
  // ==================================================================

  describe("disputeResolution", function () {
    it("locks the bond and moves the market to Disputed", async function () {
      await marketWithProposal();

      const before = await usdc.balanceOf(bob.address);
      await expect(market.connect(bob).disputeResolution(0))
        .to.emit(market, "ResolutionDisputed")
        .withArgs(0, bob.address, DISPUTE_BOND);
      const after = await usdc.balanceOf(bob.address);

      expect(before - after).to.equal(DISPUTE_BOND);
      const m = await market.getMarket(0);
      expect(m.phase).to.equal(PHASE_DISPUTED);
      expect(m.disputer).to.equal(bob.address);
      expect(m.disputeBondLocked).to.equal(DISPUTE_BOND);
    });

    it("the creator cannot dispute their own market", async function () {
      await marketWithProposal();
      await expect(
        market.connect(creator).disputeResolution(0)
      ).to.be.revertedWithCustomError(market, "CreatorCannotDispute");
    });

    it("rejects disputes after the window has closed", async function () {
      await marketWithProposal();
      await time.increase(DISPUTE_WINDOW + 1);
      await expect(
        market.connect(bob).disputeResolution(0)
      ).to.be.revertedWithCustomError(market, "DisputeWindowClosed");
    });

    it("rejects a second dispute (already Disputed)", async function () {
      await marketWithProposal();
      await market.connect(bob).disputeResolution(0);
      await expect(
        market.connect(alice).disputeResolution(0)
      ).to.be.revertedWithCustomError(market, "NotProposed");
    });

    it("blocks finalizeResolution once disputed", async function () {
      await marketWithProposal();
      await market.connect(bob).disputeResolution(0);
      await time.increase(DISPUTE_WINDOW + 1);
      await expect(
        market.finalizeResolution(0)
      ).to.be.revertedWithCustomError(market, "NotProposed");
    });

    it("blocks claim() while the market is Disputed", async function () {
      await marketWithProposal();
      await market.connect(bob).disputeResolution(0);
      await expect(
        market.connect(alice).claim(0)
      ).to.be.revertedWithCustomError(market, "NotFinalized");
    });
  });

  // ==================================================================
  //  Arbitration (adminResolve)
  // ==================================================================

  describe("adminResolve", function () {
    it("confirms the original proposal: the disputer's bond is forfeited", async function () {
      await marketWithProposal(); // Alice 100 Yes, Bob 400 No, proposed Yes
      await market.connect(bob).disputeResolution(0); // Bob disputes (thinks it's No)

      await expect(market.adminResolve(0, OUTCOME_YES))
        .to.emit(market, "MarketFinalized")
        .withArgs(0, OUTCOME_YES, true);

      const m = await market.getMarket(0);
      expect(m.phase).to.equal(PHASE_FINALIZED);
      expect(m.outcome).to.equal(OUTCOME_YES);

      // Bob's bond (5 USDC) joins accrued fees.
      expect(await market.accruedFees()).to.equal(DISPUTE_BOND);

      // Alice can still claim normally.
      expect(await market.claimableAmount(0, alice.address)).to.equal(USDC(498));
    });

    it("overturns the original proposal: the disputer's bond is refunded", async function () {
      await marketWithProposal(); // creator proposed Yes
      const before = await usdc.balanceOf(bob.address);
      await market.connect(bob).disputeResolution(0);

      await expect(market.adminResolve(0, OUTCOME_NO))
        .to.emit(market, "MarketFinalized")
        .withArgs(0, OUTCOME_NO, true);

      const after = await usdc.balanceOf(bob.address);
      // Bob gets his bond back in full (no bonus, by design).
      expect(after - before).to.equal(0);

      expect(await market.accruedFees()).to.equal(0);

      const m = await market.getMarket(0);
      expect(m.outcome).to.equal(OUTCOME_NO);

      // Bob (400 on No) now wins: winning pool 400, losing pool 100,
      // pure winnings = 100, 0.5% fee = 0.5 -> truncated to 0.
      const claimable = await market.claimableAmount(0, bob.address);
      expect(claimable).to.be.gt(USDC(400)); // stake + winnings, net of fees
    });

    it("only the owner can arbitrate", async function () {
      await marketWithProposal();
      await market.connect(bob).disputeResolution(0);
      await expect(
        market.connect(alice).adminResolve(0, OUTCOME_YES)
      ).to.be.revertedWithCustomError(market, "OwnableUnauthorizedAccount");
    });

    it("rejects arbitration on an undisputed market", async function () {
      await marketWithProposal();
      await expect(
        market.adminResolve(0, OUTCOME_YES)
      ).to.be.revertedWithCustomError(market, "NotDisputed");
    });
  });

  // ==================================================================
  //  Anti-stuck-funds safety net
  // ==================================================================

  describe("forceFinalizeDisputeTimeout", function () {
    it("rejects before the admin timeout elapses", async function () {
      await marketWithProposal();
      await market.connect(bob).disputeResolution(0);
      await expect(
        market.forceFinalizeDisputeTimeout(0)
      ).to.be.revertedWithCustomError(market, "TimeoutNotReached");
    });

    it("refunds everyone neutrally if the owner never rules", async function () {
      await marketWithProposal(); // Alice 100 Yes, Bob 400 No
      await market.connect(bob).disputeResolution(0);

      await time.increase(30 * 86400 + 1); // default adminTimeout

      const bobBefore = await usdc.balanceOf(bob.address);
      await expect(market.connect(alice).forceFinalizeDisputeTimeout(0))
        .to.emit(market, "MarketFinalized")
        .withArgs(0, OUTCOME_UNRESOLVED, true);
      const bobAfter = await usdc.balanceOf(bob.address);

      // Bob gets his dispute bond back immediately.
      expect(bobAfter - bobBefore).to.equal(DISPUTE_BOND);

      const m = await market.getMarket(0);
      expect(m.phase).to.equal(PHASE_FINALIZED);
      expect(m.forceRefunded).to.equal(true);

      // Alice and Bob EACH get their full stake back, fee-free.
      expect(await market.claimableAmount(0, alice.address)).to.equal(USDC(100));
      expect(await market.claimableAmount(0, bob.address)).to.equal(USDC(400));

      await market.connect(alice).claim(0);
      await market.connect(bob).claim(0);
      expect(await market.accruedFees()).to.equal(0);
    });

    it("rejects if the market isn't Disputed", async function () {
      await marketWithProposal();
      await expect(
        market.forceFinalizeDisputeTimeout(0)
      ).to.be.revertedWithCustomError(market, "NotDisputed");
    });
  });

  // ==================================================================
  //  Claims
  // ==================================================================

  describe("claim", function () {
    it("distributes winnings proportionally, net of fees (parimutuel)", async function () {
      await marketWithProposal(); // Alice 100 Yes, Bob 400 No, proposed Yes
      await time.increase(DISPUTE_WINDOW + 1);
      await market.finalizeResolution(0);

      expect(await market.claimableAmount(0, alice.address)).to.equal(USDC(498));

      const before = await usdc.balanceOf(alice.address);
      await market.connect(alice).claim(0);
      const after = await usdc.balanceOf(alice.address);
      expect(after - before).to.equal(USDC(498));

      expect(await market.claimableAmount(0, bob.address)).to.equal(0);
      await expect(market.connect(bob).claim(0)).to.be.revertedWithCustomError(
        market,
        "NothingToClaim"
      );

      await expect(market.connect(alice).claim(0)).to.be.revertedWithCustomError(
        market,
        "AlreadyClaimed"
      );
    });

    it("refunds everyone if nobody bet on the winning side (fee-free)", async function () {
      const { endTime } = await createTestMarket();
      await market.connect(alice).bet(0, false, USDC(50));
      await market.connect(bob).bet(0, false, USDC(150));
      await time.increaseTo(endTime + 1);
      await market.proposeResolution(0, OUTCOME_YES);
      await time.increase(DISPUTE_WINDOW + 1);
      await market.finalizeResolution(0);

      expect(await market.claimableAmount(0, alice.address)).to.equal(USDC(50));
      const before = await usdc.balanceOf(alice.address);
      await market.connect(alice).claim(0);
      expect((await usdc.balanceOf(alice.address)) - before).to.equal(USDC(50));
      expect(await market.accruedFees()).to.equal(0);
    });

    it("rejects any claim until the market is finalized", async function () {
      const { endTime } = await createTestMarket();
      await market.connect(alice).bet(0, true, USDC(10));
      await expect(
        market.connect(alice).claim(0)
      ).to.be.revertedWithCustomError(market, "NotFinalized");

      await time.increaseTo(endTime + 1);
      await expect(
        market.connect(alice).claim(0)
      ).to.be.revertedWithCustomError(market, "NotFinalized");

      await market.proposeResolution(0, OUTCOME_YES);
      await expect(
        market.connect(alice).claim(0)
      ).to.be.revertedWithCustomError(market, "NotFinalized");
    });
  });

  // ==================================================================
  //  Protocol fee (admin functions)
  // ==================================================================

  describe("protocol fee", function () {
    it("has the right defaults", async function () {
      expect(await market.feeBps()).to.equal(50);
      expect(await market.MAX_FEE_BPS()).to.equal(500);
      expect(await market.treasury()).to.equal(treasury.address);
      expect(await market.owner()).to.equal(creator.address);
      expect(await market.disputeWindow()).to.equal(DISPUTE_WINDOW);
      expect(await market.disputeBond()).to.equal(DISPUTE_BOND);
    });

    it("lets the owner withdraw fees (including forfeited bonds) to the treasury", async function () {
      await marketWithProposal();
      await market.connect(bob).disputeResolution(0);
      await market.adminResolve(0, OUTCOME_YES); // confirms -> Bob's bond forfeited (5 USDC)
      await market.connect(alice).claim(0); // + claim fee (2 USDC on 400 of winnings)

      const expected = await market.accruedFees();
      expect(expected).to.equal(USDC(7)); // 5 (forfeited bond) + 2 (claim fee)

      const before = await usdc.balanceOf(treasury.address);
      await market.withdrawFees();
      const after = await usdc.balanceOf(treasury.address);
      expect(after - before).to.equal(expected);
      expect(await market.accruedFees()).to.equal(0);
    });

    it("lets the owner change the rate, capped at 5%", async function () {
      await expect(market.setFeeBps(501)).to.be.revertedWithCustomError(
        market,
        "FeeTooHigh"
      );
      await expect(
        market.connect(alice).setFeeBps(100)
      ).to.be.revertedWithCustomError(market, "OwnableUnauthorizedAccount");
    });
  });

  // ==================================================================
  //  Dispute system configuration
  // ==================================================================

  describe("owner configuration", function () {
    it("lets the owner adjust disputeWindow, disputeBond and proposalGracePeriod", async function () {
      await market.setDisputeWindow(3600);
      expect(await market.disputeWindow()).to.equal(3600);

      await market.setDisputeBond(USDC(10));
      expect(await market.disputeBond()).to.equal(USDC(10));

      await market.setProposalGracePeriod(86400);
      expect(await market.proposalGracePeriod()).to.equal(86400);
    });

    it("rejects a zero dispute window", async function () {
      await expect(market.setDisputeWindow(0)).to.be.revertedWithCustomError(
        market,
        "InvalidConfig"
      );
    });

    it("rejects an adminTimeout at or below disputeWindow", async function () {
      const currentWindow = await market.disputeWindow();
      await expect(
        market.setAdminTimeout(currentWindow)
      ).to.be.revertedWithCustomError(market, "InvalidConfig");
    });

    it("only the owner can change the configuration", async function () {
      await expect(
        market.connect(alice).setDisputeWindow(3600)
      ).to.be.revertedWithCustomError(market, "OwnableUnauthorizedAccount");
      await expect(
        market.connect(alice).setDisputeBond(USDC(1))
      ).to.be.revertedWithCustomError(market, "OwnableUnauthorizedAccount");
    });
  });
});
