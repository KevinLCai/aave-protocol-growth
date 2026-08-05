-- =====================================================================
-- Q2 — Loopers, filtered to actual loop positions.
--
-- CHANGE: raw top-N-by-debt mixes loop and non-loop positions (some
-- large addresses run conservative LTVs or borrow against other
-- collateral). This version separates the two explicitly:
--   - `loop_flag` marks positions within an LTV band consistent with
--     deliberate E-mode leverage (adjust bounds to your read E-mode LTV)
--   - loop-share metrics are computed only within the loop-flagged set
--   - the full set is still returned, so non-loop addresses are visible
--     and can be discussed separately (organic borrowing, Q5 input)
-- =====================================================================

WITH params AS (
    SELECT
        0x4c9EDD5852cd905f086C759E8383e09bff1E68B3 AS usde,
        0x9D39A5DE30e57443BfF2A8307A4256c8797A3497 AS susde,
        0.85 AS loop_ltv_min,   -- ADJUST to just below your E-mode LTV band
        0.95 AS loop_ltv_max    -- ADJUST to just above it
),

staking_assets AS (
    SELECT SUM(CASE WHEN t.to     = p.susde THEN  CAST(t.value AS DOUBLE)
                    WHEN t."from" = p.susde THEN -CAST(t.value AS DOUBLE)
                    ELSE 0 END) / 1e18 AS total_assets
    FROM erc20_ethereum.evt_Transfer t
    CROSS JOIN params p
    WHERE t.contract_address = p.usde
      AND (t.to = p.susde OR t."from" = p.susde)
),

staking_shares AS (
    SELECT SUM(CASE WHEN t."from" = 0x0000000000000000000000000000000000000000 THEN  CAST(t.value AS DOUBLE)
                    WHEN t.to     = 0x0000000000000000000000000000000000000000 THEN -CAST(t.value AS DOUBLE)
                    ELSE 0 END) / 1e18 AS total_shares
    FROM erc20_ethereum.evt_Transfer t
    CROSS JOIN params p
    WHERE t.contract_address = p.susde
      AND (t."from" = 0x0000000000000000000000000000000000000000
           OR t.to  = 0x0000000000000000000000000000000000000000)
),

exch AS (
    SELECT a.total_assets / NULLIF(s.total_shares, 0) AS susde_rate
    FROM staking_assets a CROSS JOIN staking_shares s
),

borrows AS (
    SELECT b.onBehalfOf AS user_addr,
           CAST(b.amount AS DOUBLE) / 1e18 AS amt,
           b.evt_block_time
    FROM aave_v3_ethereum.Pool_evt_Borrow b
    CROSS JOIN params p
    WHERE b.reserve = p.usde
),

repays AS (
    SELECT r.user AS user_addr, -CAST(r.amount AS DOUBLE) / 1e18 AS amt
    FROM aave_v3_ethereum.Pool_evt_Repay r
    CROSS JOIN params p
    WHERE r.reserve = p.usde
),

debt_liquidations AS (
    SELECT l.user AS user_addr, -CAST(l.debtToCover AS DOUBLE) / 1e18 AS amt
    FROM aave_v3_ethereum.Pool_evt_LiquidationCall l
    CROSS JOIN params p
    WHERE l.debtAsset = p.usde
),

debt AS (
    SELECT user_addr, SUM(amt) AS usde_debt
    FROM (
        SELECT user_addr, amt FROM borrows
        UNION ALL SELECT user_addr, amt FROM repays
        UNION ALL SELECT user_addr, amt FROM debt_liquidations
    )
    GROUP BY 1
    HAVING SUM(amt) > 1000
),

borrow_activity AS (
    SELECT user_addr,
           MIN(evt_block_time) AS first_borrow,
           MAX(evt_block_time) AS last_borrow,
           COUNT(*)            AS n_borrows
    FROM borrows
    GROUP BY 1
),

supplies AS (
    SELECT s.onBehalfOf AS user_addr, CAST(s.amount AS DOUBLE) / 1e18 AS amt
    FROM aave_v3_ethereum.Pool_evt_Supply s
    CROSS JOIN params p
    WHERE s.reserve = p.susde
),

withdrawals AS (
    SELECT w.user AS user_addr, -CAST(w.amount AS DOUBLE) / 1e18 AS amt
    FROM aave_v3_ethereum.Pool_evt_Withdraw w
    CROSS JOIN params p
    WHERE w.reserve = p.susde
),

coll_liquidations AS (
    SELECT l.user AS user_addr,
           -CAST(l.liquidatedCollateralAmount AS DOUBLE) / 1e18 AS amt
    FROM aave_v3_ethereum.Pool_evt_LiquidationCall l
    CROSS JOIN params p
    WHERE l.collateralAsset = p.susde
),

collateral AS (
    SELECT user_addr, SUM(amt) AS susde_collateral
    FROM (
        SELECT user_addr, amt FROM supplies
        UNION ALL SELECT user_addr, amt FROM withdrawals
        UNION ALL SELECT user_addr, amt FROM coll_liquidations
    )
    GROUP BY 1
    HAVING SUM(amt) > 1000
),

contracts AS (
    SELECT DISTINCT address FROM ethereum.creation_traces
),

joined AS (
    SELECT
        d.user_addr,
        CASE WHEN ct.address IS NOT NULL THEN 'contract' ELSE 'EOA' END AS addr_type,
        d.usde_debt,
        c.susde_collateral,
        c.susde_collateral * e.susde_rate AS collateral_usde_equiv,
        d.usde_debt / NULLIF(c.susde_collateral * e.susde_rate, 0) AS ltv_actual,
        ba.first_borrow,
        ba.last_borrow,
        ba.n_borrows
    FROM debt d
    CROSS JOIN exch e
    INNER JOIN collateral c      ON c.user_addr = d.user_addr
    LEFT JOIN borrow_activity ba ON ba.user_addr = d.user_addr
    LEFT JOIN contracts ct       ON ct.address  = d.user_addr
),

flagged AS (
    SELECT j.*,
           CASE WHEN j.ltv_actual BETWEEN p.loop_ltv_min AND p.loop_ltv_max
                THEN TRUE ELSE FALSE END AS is_loop_position
    FROM joined j CROSS JOIN params p
)

SELECT
    ROW_NUMBER() OVER (ORDER BY usde_debt DESC)                     AS rank,
    user_addr,
    addr_type,
    is_loop_position,
    usde_debt,
    collateral_usde_equiv,
    ltv_actual,
    1 / NULLIF(1 - ltv_actual, 0)                                   AS implied_leverage,
    -- share metrics computed WITHIN the loop-flagged set only
    CASE WHEN is_loop_position
         THEN usde_debt / SUM(CASE WHEN is_loop_position THEN usde_debt END) OVER ()
    END AS share_of_loop_debt,
    CASE WHEN is_loop_position THEN
        SUM(CASE WHEN is_loop_position THEN usde_debt END) OVER (
            ORDER BY usde_debt DESC ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
        / SUM(CASE WHEN is_loop_position THEN usde_debt END) OVER ()
    END AS cumulative_share_of_loop,
    -- for reference: this address's share of ALL USDe debt (loop + organic)
    usde_debt / SUM(usde_debt) OVER ()                              AS share_of_total_debt,
    n_borrows,
    first_borrow,
    last_borrow
FROM flagged
ORDER BY usde_debt DESC
LIMIT 20
