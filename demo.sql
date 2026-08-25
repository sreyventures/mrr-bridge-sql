-- ============================================================================
-- mrr-foundation — demo.sql
--
-- A complete, self-contained MRR foundation: subscriptions in, monthly MRR
-- bridge out. Synthetic data is inlined below, so you can paste this whole
-- file into a BigQuery console and run it. No setup, no credentials, no tables.
--
-- What it builds, in order:
--   1. raw_subscriptions      synthetic Stripe-shaped subscription rows
--   2. customer_month_mrr     one row per customer per month  <- the spine
--   3. mrr_movement           new / expansion / contraction / churn / reactivation
--   4. mrr_summary            the monthly bridge (the output below)
--
-- Every judgment call lives in the POLICY block. Nothing after it encodes an
-- opinion. Search this file for "OPINION:" to see the complete list.
-- ============================================================================

WITH

-- ─── POLICY ─────────────────────────────────────────────────────────────────
-- Change these, re-run, the bridge still balances.
policy AS (
  SELECT
    0.01  AS materiality_threshold,   -- OPINION: |change| below this is no_change, not expansion/contraction
    2     AS rounding_dp,             -- OPINION: round before comparing, so float dust never becomes "movement"
    TRUE  AS absent_month_means_zero  -- OPINION: a customer-month with no subscription = 0 MRR (not unknown)
),

-- ─── 1. RAW INPUT (synthetic) ───────────────────────────────────────────────
-- Shaped like a Stripe subscription-items export. Replace this CTE with your
-- own source and everything downstream still works.
--   ended_at NULL = still active
raw_subscriptions AS (
  SELECT * FROM UNNEST([
    STRUCT<subscription_id STRING, customer_id STRING, unit_amount_cents INT64,
           billing_interval STRING, quantity INT64, started_at DATE, ended_at DATE>
    -- steady customer: new, then flat
    ('sub_001', 'cus_apex',    50000, 'month', 1, DATE '2026-01-15', NULL),
    -- upgrade mid-life: new, then expansion
    ('sub_002', 'cus_borealis',20000, 'month', 1, DATE '2026-02-03', DATE '2026-03-31'),
    ('sub_003', 'cus_borealis',35000, 'month', 1, DATE '2026-04-01', NULL),
    -- downgrade: new, then contraction
    ('sub_004', 'cus_cedar',   80000, 'month', 1, DATE '2026-01-08', DATE '2026-02-28'),
    ('sub_005', 'cus_cedar',   45000, 'month', 1, DATE '2026-03-01', NULL),
    -- churn: leaves in March, never returns
    ('sub_006', 'cus_dune',    30000, 'month', 1, DATE '2026-01-20', DATE '2026-03-31'),
    -- win-back: churns in Feb, returns in May => reactivation
    ('sub_007', 'cus_ember',   25000, 'month', 1, DATE '2026-01-05', DATE '2026-02-28'),
    ('sub_008', 'cus_ember',   25000, 'month', 1, DATE '2026-05-01', NULL),
    -- annual plan: proves interval normalization (120000/yr = 10000/mo)
    ('sub_009', 'cus_frost',  1200000,'year',  1, DATE '2026-02-10', NULL),
    -- seat expansion via quantity, not price
    ('sub_010', 'cus_glade',   10000, 'month', 3, DATE '2026-01-12', DATE '2026-04-30'),
    ('sub_011', 'cus_glade',   10000, 'month', 7, DATE '2026-05-01', NULL)
  ])
),

-- ─── 2. NORMALIZE TO MONTHLY MRR ────────────────────────────────────────────
-- Annual/quarterly plans are divided down to a monthly figure. Cents -> currency.
subscription_mrr AS (
  SELECT
    subscription_id,
    customer_id,
    started_at,
    ended_at,
    ROUND(
      (unit_amount_cents * quantity / 100.0)
      / CASE billing_interval           -- OPINION: annual plans are spread evenly,
          WHEN 'year'    THEN 12        -- not recognized in the month they are billed
          WHEN 'quarter' THEN 3
          ELSE 1
        END
    , 2) AS monthly_mrr
  FROM raw_subscriptions
),

-- Month spine: every month the dataset spans.
months AS (
  SELECT month
  FROM UNNEST(GENERATE_DATE_ARRAY(
    (SELECT DATE_TRUNC(MIN(started_at), MONTH) FROM subscription_mrr),
    (SELECT DATE_TRUNC(MAX(COALESCE(ended_at, CURRENT_DATE())), MONTH) FROM subscription_mrr),
    INTERVAL 1 MONTH
  )) AS month
),

-- Every customer x every month, so a drop to zero is an explicit row we can see.
-- Without this, churn is the *absence* of a row and becomes invisible.
customer_months AS (
  SELECT c.customer_id, m.month
  FROM (SELECT DISTINCT customer_id FROM subscription_mrr) c
  CROSS JOIN months m
),

-- ─── 3. customer_month_mrr — THE SPINE ──────────────────────────────────────
customer_month_mrr AS (
  SELECT
    cm.customer_id,
    cm.month,
    ROUND(COALESCE(SUM(s.monthly_mrr), 0), (SELECT rounding_dp FROM policy)) AS mrr
  FROM customer_months cm
  LEFT JOIN subscription_mrr s
    ON  s.customer_id = cm.customer_id
    -- a subscription counts for a month if it was active at any point in it
    AND DATE_TRUNC(s.started_at, MONTH) <= cm.month
    AND cm.month <= DATE_TRUNC(COALESCE(s.ended_at, CURRENT_DATE()), MONTH)
  GROUP BY cm.customer_id, cm.month
),

-- ─── 4. mrr_movement — THE STATE MACHINE ────────────────────────────────────
with_prior AS (
  SELECT
    customer_id,
    month,
    mrr,
    COALESCE(LAG(mrr) OVER (PARTITION BY customer_id ORDER BY month), 0) AS prior_mrr,
    -- has this customer ever had MRR before this month? distinguishes new vs reactivation
    COALESCE(
      MAX(CASE WHEN mrr > 0 THEN 1 ELSE 0 END)
        OVER (PARTITION BY customer_id ORDER BY month
              ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS had_mrr_before
  FROM customer_month_mrr
),

mrr_movement AS (
  SELECT
    w.customer_id,
    w.month,
    w.mrr,
    w.prior_mrr,
    ROUND(w.mrr - w.prior_mrr, p.rounding_dp) AS mrr_change,
    CASE
      WHEN w.mrr > 0 AND w.prior_mrr = 0 AND w.had_mrr_before = 0 THEN 'new'
      WHEN w.mrr > 0 AND w.prior_mrr = 0 AND w.had_mrr_before = 1 THEN 'reactivation'
      WHEN w.mrr = 0 AND w.prior_mrr > 0                          THEN 'churn'
      WHEN w.mrr = 0 AND w.prior_mrr = 0                          THEN 'inactive'
      WHEN ABS(w.mrr - w.prior_mrr) < p.materiality_threshold     THEN 'no_change'
      WHEN w.mrr > w.prior_mrr                                    THEN 'expansion'
      ELSE                                                             'contraction'
    END AS movement_class
  FROM with_prior w
  CROSS JOIN policy p
),

-- ─── 5. mrr_summary — THE BRIDGE ────────────────────────────────────────────
bridge AS (
  SELECT
    month,
    ROUND(SUM(prior_mrr), 2)                                                  AS opening_mrr,
    ROUND(SUM(IF(movement_class = 'new',          mrr, 0)), 2)                AS new_mrr,
    ROUND(SUM(IF(movement_class = 'reactivation', mrr, 0)), 2)                AS reactivation_mrr,
    ROUND(SUM(IF(movement_class = 'expansion',    mrr_change, 0)), 2)         AS expansion_mrr,
    ROUND(SUM(IF(movement_class = 'contraction',  mrr_change, 0)), 2)         AS contraction_mrr,
    ROUND(SUM(IF(movement_class = 'churn',       -prior_mrr, 0)), 2)          AS churn_mrr,
    ROUND(SUM(mrr), 2)                                                        AS closing_mrr
  FROM mrr_movement
  GROUP BY month
)

-- ─── OUTPUT ─────────────────────────────────────────────────────────────────
-- reconciles = TRUE means opening + all movements = closing, exactly.
-- If this is ever FALSE, the model is wrong. That is the whole point.
SELECT
  FORMAT_DATE('%Y-%m', month) AS month,
  opening_mrr,
  new_mrr,
  expansion_mrr,
  contraction_mrr,
  churn_mrr,
  reactivation_mrr,
  closing_mrr,
  ROUND(opening_mrr + new_mrr + expansion_mrr + contraction_mrr
        + churn_mrr + reactivation_mrr, 2) = closing_mrr AS reconciles
FROM bridge
ORDER BY month
