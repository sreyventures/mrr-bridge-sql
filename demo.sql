-- ============================================================================
-- MRR Bridge SQL - demo.sql
--
-- Self-contained BigQuery Standard SQL for subscription MRR movements and a
-- reconciled monthly bridge. Synthetic Stripe-shaped data is inlined below.
--
-- Run this file as-is in BigQuery. Replace raw_subscriptions with your source
-- relation when adapting it to a warehouse.
-- ============================================================================
WITH

-- Configuration used by every downstream model.
policy AS (
  SELECT
    DATE '2026-05-31' AS as_of_date,
    0.01 AS materiality_threshold,
    2 AS rounding_dp
),

-- Synthetic input. Amounts are in cents; dates are inclusive by month.
raw_subscriptions AS (
  SELECT *
  FROM UNNEST([
    STRUCT<subscription_id STRING, customer_id STRING, unit_amount_cents INT64, billing_interval STRING, quantity INT64, started_at DATE, ended_at DATE>
      ('sub_new', 'cus_new', 10000, 'month', 1, DATE '2026-01-05', NULL),
    STRUCT<subscription_id STRING, customer_id STRING, unit_amount_cents INT64, billing_interval STRING, quantity INT64, started_at DATE, ended_at DATE>
      ('sub_expand_base', 'cus_expand', 20000, 'month', 1, DATE '2026-01-05', NULL),
    STRUCT<subscription_id STRING, customer_id STRING, unit_amount_cents INT64, billing_interval STRING, quantity INT64, started_at DATE, ended_at DATE>
      ('sub_expand_addon', 'cus_expand', 10000, 'month', 1, DATE '2026-03-05', NULL),
    STRUCT<subscription_id STRING, customer_id STRING, unit_amount_cents INT64, billing_interval STRING, quantity INT64, started_at DATE, ended_at DATE>
      ('sub_contract_old', 'cus_contract', 40000, 'month', 1, DATE '2026-01-05', DATE '2026-02-28'),
    STRUCT<subscription_id STRING, customer_id STRING, unit_amount_cents INT64, billing_interval STRING, quantity INT64, started_at DATE, ended_at DATE>
      ('sub_contract_new', 'cus_contract', 25000, 'month', 1, DATE '2026-03-01', NULL),
    STRUCT<subscription_id STRING, customer_id STRING, unit_amount_cents INT64, billing_interval STRING, quantity INT64, started_at DATE, ended_at DATE>
      ('sub_churn', 'cus_churn', 30000, 'month', 1, DATE '2026-01-05', DATE '2026-03-31'),
    STRUCT<subscription_id STRING, customer_id STRING, unit_amount_cents INT64, billing_interval STRING, quantity INT64, started_at DATE, ended_at DATE>
      ('sub_reactivate_first', 'cus_reactivate', 25000, 'month', 1, DATE '2026-01-05', DATE '2026-02-28'),
    STRUCT<subscription_id STRING, customer_id STRING, unit_amount_cents INT64, billing_interval STRING, quantity INT64, started_at DATE, ended_at DATE>
      ('sub_reactivate_return', 'cus_reactivate', 25000, 'month', 1, DATE '2026-04-01', NULL),
    STRUCT<subscription_id STRING, customer_id STRING, unit_amount_cents INT64, billing_interval STRING, quantity INT64, started_at DATE, ended_at DATE>
      ('sub_annual', 'cus_annual', 1200000, 'year', 1, DATE '2026-01-10', NULL),
    STRUCT<subscription_id STRING, customer_id STRING, unit_amount_cents INT64, billing_interval STRING, quantity INT64, started_at DATE, ended_at DATE>
      ('sub_seats_old', 'cus_seats', 5000, 'month', 3, DATE '2026-01-05', DATE '2026-02-28'),
    STRUCT<subscription_id STRING, customer_id STRING, unit_amount_cents INT64, billing_interval STRING, quantity INT64, started_at DATE, ended_at DATE>
      ('sub_seats_new', 'cus_seats', 5000, 'month', 7, DATE '2026-03-01', NULL)
  ])
),

-- Normalize recurring amounts to monthly MRR.
subscription_mrr AS (
  SELECT
    subscription_id,
    customer_id,
    started_at,
    ended_at,
    ROUND(
      (unit_amount_cents * quantity / 100.0)
        / CASE billing_interval
            WHEN 'year' THEN 12
            WHEN 'quarter' THEN 3
            ELSE 1
          END,
      (SELECT rounding_dp FROM policy)
    ) AS monthly_mrr
  FROM raw_subscriptions
),

-- One row per month in the configured reporting window.
months AS (
  SELECT month
  FROM UNNEST(GENERATE_DATE_ARRAY(
    DATE_TRUNC((SELECT MIN(started_at) FROM subscription_mrr), MONTH),
    DATE_TRUNC((SELECT as_of_date FROM policy), MONTH),
    INTERVAL 1 MONTH
  )) AS month
),

-- The complete customer-month spine makes churn an explicit zero-MRR row.
customer_months AS (
  SELECT c.customer_id, m.month
  FROM (SELECT DISTINCT customer_id FROM subscription_mrr) AS c
  CROSS JOIN months AS m
),

-- Customer-month MRR.
customer_month_mrr AS (
  SELECT
    cm.customer_id,
    cm.month,
    ROUND(
      COALESCE(SUM(s.monthly_mrr), 0),
      (SELECT rounding_dp FROM policy)
    ) AS mrr
  FROM customer_months AS cm
  LEFT JOIN subscription_mrr AS s
    ON s.customer_id = cm.customer_id
    AND DATE_TRUNC(s.started_at, MONTH) <= cm.month
    AND cm.month <= DATE_TRUNC(COALESCE(s.ended_at, (SELECT as_of_date FROM policy)), MONTH)
  GROUP BY cm.customer_id, cm.month
),

-- Compare each customer-month with its previous state.
with_prior AS (
  SELECT
    customer_id,
    month,
    mrr,
    COALESCE(LAG(mrr) OVER (PARTITION BY customer_id ORDER BY month), 0) AS prior_mrr,
    COALESCE(
      MAX(CASE WHEN mrr > 0 THEN 1 ELSE 0 END) OVER (
        PARTITION BY customer_id
        ORDER BY month
        ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
      ),
      0
    ) AS had_mrr_before
  FROM customer_month_mrr
),

-- Classify the movement and calculate its signed MRR change.
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
      WHEN w.mrr = 0 AND w.prior_mrr > 0 THEN 'churn'
      WHEN w.mrr = 0 AND w.prior_mrr = 0 THEN 'inactive'
      WHEN ABS(w.mrr - w.prior_mrr) < p.materiality_threshold THEN 'no_change'
      WHEN w.mrr > w.prior_mrr THEN 'expansion'
      ELSE 'contraction'
    END AS movement_class
  FROM with_prior AS w
  CROSS JOIN policy AS p
),

-- Aggregate customer movements into the monthly bridge.
bridge AS (
  SELECT
    month,
    ROUND(SUM(prior_mrr), (SELECT rounding_dp FROM policy)) AS opening_mrr,
    ROUND(SUM(IF(movement_class = 'new', mrr, 0)), (SELECT rounding_dp FROM policy)) AS new_mrr,
    ROUND(SUM(IF(movement_class = 'reactivation', mrr, 0)), (SELECT rounding_dp FROM policy)) AS reactivation_mrr,
    ROUND(SUM(IF(movement_class = 'expansion', mrr_change, 0)), (SELECT rounding_dp FROM policy)) AS expansion_mrr,
    ROUND(SUM(IF(movement_class = 'contraction', mrr_change, 0)), (SELECT rounding_dp FROM policy)) AS contraction_mrr,
    ROUND(SUM(IF(movement_class = 'churn', -prior_mrr, 0)), (SELECT rounding_dp FROM policy)) AS churn_mrr,
    ROUND(SUM(mrr), (SELECT rounding_dp FROM policy)) AS closing_mrr
  FROM mrr_movement
  GROUP BY month
),

-- Final output. TRUE means the bridge reconciles exactly at the configured precision.
mrr_summary AS (
  SELECT
    FORMAT_DATE('%Y-%m', month) AS month,
    opening_mrr,
    new_mrr,
    expansion_mrr,
    contraction_mrr,
    churn_mrr,
    reactivation_mrr,
    closing_mrr,
    ROUND(
      opening_mrr + new_mrr + expansion_mrr + contraction_mrr + churn_mrr + reactivation_mrr,
      (SELECT rounding_dp FROM policy)
    ) = closing_mrr AS reconciles
  FROM bridge
)
SELECT *
FROM mrr_summary
ORDER BY month;
