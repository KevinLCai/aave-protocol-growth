-- =====================================================================
-- Aave V3 Ethereum USDe — carry, utilisation, and supply/borrow balances
--
-- v3 adds total supply and total borrow, reconstructed from scaled
-- balances. This gives an INDEPENDENT utilisation figure that should
-- match the rate-derived one — if they diverge, the reserve factor is
-- wrong.
--
-- VERIFY BEFORE RUNNING (all from getReserveData(USDe) on the Pool):
--   - a_token          = aTokenAddress
--   - var_debt_token   = variableDebtTokenAddress
--   - reserve_factor   = from reserve configuration
--
-- METHOD NOTE: Aave V3 scaled-balance tokens mint/burn SCALED amounts,
-- so Transfer events to/from the zero address carry scaled values.
-- Actual balance = scaledBalance * index. Verify this against the app
-- on one date before trusting it.
-- =====================================================================

WITH params AS (
    SELECT
        0x4c9EDD5852cd905f086C759E8383e09bff1E68B3 AS usde,           -- VERIFY
        0x9D39A5DE30e57443BfF2A8307A4256c8797A3497 AS staked_usde,    -- VERIFY
        0x0000000000000000000000000000000000000000 AS a_token,        -- REPLACE
        0x0000000000000000000000000000000000000000 AS var_debt_token, -- REPLACE
        0.25                                       AS reserve_factor, -- confirmed via getReserveConfigurationData
        31536000.0                                 AS secs_per_year,
        DATE '2024-01-01'                          AS start_day,
        DATE '2025-11-01'                          AS window_start
),

calendar AS (
    SELECT d AS day
    FROM params p
    CROSS JOIN UNNEST(SEQUENCE(p.start_day, CURRENT_DATE, INTERVAL '1' DAY)) AS t(d)
),

-- ---------- Aave rates and indices ----------
aave_raw AS (
    SELECT
        date_trunc('day', r.evt_block_time) AS day,
        r.evt_block_number,
        CAST(r.liquidityRate        AS DOUBLE) / 1e27 AS supply_apr,
        CAST(r.variableBorrowRate   AS DOUBLE) / 1e27 AS borrow_apr,
        CAST(r.liquidityIndex       AS DOUBLE) / 1e27 AS liq_index,
        CAST(r.variableBorrowIndex  AS DOUBLE) / 1e27 AS debt_index,
        ROW_NUMBER() OVER (
            PARTITION BY date_trunc('day', r.evt_block_time)
            ORDER BY r.evt_block_number DESC, r.evt_index DESC
        ) AS rn
    FROM aave_v3_ethereum.Pool_evt_ReserveDataUpdated r
    CROSS JOIN params p
    WHERE r.reserve = p.usde
      AND r.evt_block_time >= p.start_day
),

aave_daily AS (
    SELECT day, evt_block_number, supply_apr, borrow_apr, liq_index, debt_index
    FROM aave_raw WHERE rn = 1
),

-- ---------- Scaled balances ----------
-- aToken mints/burns (scaled)
a_flows AS (
    SELECT date_trunc('day', t.evt_block_time) AS day,
           SUM(CASE WHEN t."from" = 0x0000000000000000000000000000000000000000 THEN  CAST(t.value AS DOUBLE)
                    WHEN t.to     = 0x0000000000000000000000000000000000000000 THEN -CAST(t.value AS DOUBLE)
                    ELSE 0 END) / 1e18 AS net_scaled
    FROM erc20_ethereum.evt_Transfer t
    CROSS JOIN params p
    WHERE t.contract_address = p.a_token
      AND (t."from" = 0x0000000000000000000000000000000000000000
           OR t.to  = 0x0000000000000000000000000000000000000000)
    GROUP BY 1
),

-- variable debt token mints/burns (scaled)
d_flows AS (
    SELECT date_trunc('day', t.evt_block_time) AS day,
           SUM(CASE WHEN t."from" = 0x0000000000000000000000000000000000000000 THEN  CAST(t.value AS DOUBLE)
                    WHEN t.to     = 0x0000000000000000000000000000000000000000 THEN -CAST(t.value AS DOUBLE)
                    ELSE 0 END) / 1e18 AS net_scaled
    FROM erc20_ethereum.evt_Transfer t
    CROSS JOIN params p
    WHERE t.contract_address = p.var_debt_token
      AND (t."from" = 0x0000000000000000000000000000000000000000
           OR t.to  = 0x0000000000000000000000000000000000000000)
    GROUP BY 1
),

scaled_state AS (
    SELECT
        c.day,
        SUM(COALESCE(a.net_scaled, 0)) OVER (ORDER BY c.day) AS scaled_supply,
        SUM(COALESCE(d.net_scaled, 0)) OVER (ORDER BY c.day) AS scaled_debt
    FROM calendar c
    LEFT JOIN a_flows a ON a.day = c.day
    LEFT JOIN d_flows d ON d.day = c.day
),

-- ---------- Ethena leg (unchanged) ----------
usde_flows AS (
    SELECT date_trunc('day', t.evt_block_time) AS day,
           SUM(CASE WHEN t.to     = p.staked_usde THEN  CAST(t.value AS DOUBLE)
                    WHEN t."from" = p.staked_usde THEN -CAST(t.value AS DOUBLE)
                    ELSE 0 END) / 1e18 AS net_usde
    FROM erc20_ethereum.evt_Transfer t
    CROSS JOIN params p
    WHERE t.contract_address = p.usde
      AND (t.to = p.staked_usde OR t."from" = p.staked_usde)
    GROUP BY 1
),

susde_flows AS (
    SELECT date_trunc('day', t.evt_block_time) AS day,
           SUM(CASE WHEN t."from" = 0x0000000000000000000000000000000000000000 THEN  CAST(t.value AS DOUBLE)
                    WHEN t.to     = 0x0000000000000000000000000000000000000000 THEN -CAST(t.value AS DOUBLE)
                    ELSE 0 END) / 1e18 AS net_susde
    FROM erc20_ethereum.evt_Transfer t
    CROSS JOIN params p
    WHERE t.contract_address = p.staked_usde
      AND (t."from" = 0x0000000000000000000000000000000000000000
           OR t.to  = 0x0000000000000000000000000000000000000000)
    GROUP BY 1
),

staking_state AS (
    SELECT c.day,
           SUM(COALESCE(u.net_usde,  0)) OVER (ORDER BY c.day) AS total_assets,
           SUM(COALESCE(s.net_susde, 0)) OVER (ORDER BY c.day) AS total_shares
    FROM calendar c
    LEFT JOIN usde_flows  u ON u.day = c.day
    LEFT JOIN susde_flows s ON s.day = c.day
),

exch AS (
    SELECT day,
           CASE WHEN total_shares > 0 AND total_assets > 0
                THEN total_assets / total_shares END AS exch_rate
    FROM staking_state
),

susde_yield AS (
    SELECT day,
           exch_rate,
           -- 30d annualisation: less noise amplification than 7d
           CASE WHEN exch_rate > 0
                 AND LAG(exch_rate, 30) OVER (ORDER BY day) > 0
                THEN POWER(exch_rate / LAG(exch_rate, 30) OVER (ORDER BY day), 365.0 / 30.0) - 1
           END AS susde_apy_30d
    FROM exch
)

-- ---------- Output ----------
SELECT
    c.day,
    CAST(YEAR(c.day) AS VARCHAR)                                  AS year,
    CAST(YEAR(c.day) AS VARCHAR) || '-Q' || CAST(QUARTER(c.day) AS VARCHAR) AS quarter,
    date_format(c.day, '%Y-%m')                                   AS month,
    CASE WHEN c.day < DATE '2026-02-01' THEN '1. Nov-Jan'
         WHEN c.day < DATE '2026-05-01' THEN '2. Feb-Apr'
         ELSE                                '3. May-Aug'
    END AS period,
    a.evt_block_number,
    POWER(1 + a.borrow_apr / p.secs_per_year, p.secs_per_year) - 1 AS usde_borrow_apy,
    POWER(1 + a.supply_apr / p.secs_per_year, p.secs_per_year) - 1 AS usde_supply_apy,

    -- balances, in USDe
    s.scaled_supply * a.liq_index  AS total_supply,
    s.scaled_debt   * a.debt_index AS total_borrow,

    -- utilisation, two independent methods
    CASE WHEN s.scaled_supply * a.liq_index > 0
         THEN (s.scaled_debt * a.debt_index) / (s.scaled_supply * a.liq_index)
         END AS utilisation_balances,
    CASE WHEN a.borrow_apr > 0
         THEN a.supply_apr / (a.borrow_apr * (1 - p.reserve_factor))
         END AS utilisation_rates,

    y.susde_apy_30d,
    y.exch_rate AS susde_exchange_rate,
    y.susde_apy_30d - (POWER(1 + a.borrow_apr / p.secs_per_year, p.secs_per_year) - 1) AS carry
FROM calendar c
CROSS JOIN params p
LEFT JOIN aave_daily   a ON a.day = c.day
LEFT JOIN scaled_state s ON s.day = c.day
LEFT JOIN susde_yield  y ON y.day = c.day
WHERE a.borrow_apr IS NOT NULL
  AND c.day >= p.window_start
ORDER BY c.day
