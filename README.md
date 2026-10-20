# PoC — Morpheus DepositPool: self-referral reward double-dip

Foundry fork test demonstrating that `DepositPool.stake` accepts any
`referrer_` — including the staker's own address — with no
`referrer_ != user_` check, so one stake books both incentive legs on the
same capital: the referee's +1% virtual weight AND the referrer-tier
virtual weight (15% at the live tier-3 threshold), diluting honest
stakers through the shared `totalVirtualDeposited` denominator.

## Run

```bash
forge test -vvv
```

One command. Forks Ethereum mainnet at block **26232700** via a public
RPC endpoint (no API key). Expected: 2 passed, 0 failed.

## What the test does

Real deployed stETH DepositPool proxy
`0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790`, pool 0. Fresh unprivileged
attackers; no owner/admin impersonation anywhere. Each scenario stakes
90 stETH from the same snapshot, warps 30 days, cranks `distributeRewards`,
then reads and executes the claims.

- **Honest control** (referrer = address(0)): claimable
  **529.649843806282250748 MOR**.
- **Two-address self-referral** (A stakes, A's second address B is
  referrer): A user reward 534.397746790397891548 + B referrer reward
  79.366001998573944289 = **613.763748788971835837 MOR**.
- **Self-referral** (`referrer_ == msg.sender`): exactly the same total,
  **613.763748788971835837 MOR**.

**Excess: 84.113904982689585089 MOR = 15.88% above the honest reward**,
per 90 stETH per 30 days, for the life of the stake. Both `claim()` and
`claimReferrerTier()` are executed on the fork and consume their
entitlements to exactly 0.

## Disclosed harness accommodations

- Attackers are funded with `vm.deal` ETH converted through the real Lido
  `submit()`. All protocol interactions are the attackers' own calls.
- The ChainLinkDataConsumer is mocked to return the exact live prices read
  at fork time (its 3600s staleness delay makes every real feed "stale"
  after a 30-day warp). Prices are unchanged.
- A 20 stETH donor transfer simulates the Lido rebase (no oracle reports
  occur on a static fork; without it the yield-proportional split gives
  the stETH pool zero). Identical in all scenarios; every measured ratio
  is invariant to it.

Note: on the USDT pool the tier thresholds are configured in raw units
(4e21+) against 6-decimal booking, so the referrer-tier leg is unreachable
there (only the +1% applies). stETH and wETH carry the reachable tier
table used here.
