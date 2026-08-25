# MRR Bridge SQL

BigQuery SQL for transforming subscription data into customer-level MRR movements and a reconciled monthly bridge.

For a short explanation of the model and its scope, see the [MRR Bridge SQL resource on MRRWorks](https://mrrworks.com/resources/mrr-bridge-sql/).

## Who this is for

This project is for data and analytics engineers building revenue models for subscription businesses.

It assumes an existing SQL warehouse and subscription data from Stripe or a similar billing source. The demo uses synthetic, Stripe-shaped data; adapt the input relation to your warehouse schema.

## What it produces

- Customer-month MRR
- Per-customer MRR movement classifications
- A monthly MRR bridge
- A reconciliation check

Movement classifications include New Business, Expansion, Contraction, Churn, Reactivation, and Unchanged.

## Quick start

1. Open BigQuery.
2. Copy [`demo.sql`](demo.sql) into a query.
3. Run it.
4. Confirm that the output `reconciles` column is `TRUE`.

The demo data is inlined. It requires no source tables, credentials, or setup, and processes zero source bytes.

## Input relation

The query expects subscription records with these fields:

| Field | Description |
|---|---|
| `customer_id` | Stable customer identifier |
| `subscription_id` | Stable subscription identifier |
| `started_at` | Subscription start date |
| `ended_at` | Subscription end date, if ended |
| `unit_amount` | Recurring price per unit in the source currency |
| `quantity` | Quantity or seat count |
| `interval` | Billing interval, currently `month` or `year` |

Replace the demo `subscriptions` CTE with a relation from your warehouse. The query is written for BigQuery Standard SQL.

## Output models

The query builds these models as CTEs and returns `mrr_summary` as its final result:

- `customer_month_mrr`: one row per customer and month, including zero-MRR months needed to show churn.
- `mrr_movement`: one row per customer and month with the movement classification and amount.
- `mrr_summary`: the monthly bridge from opening MRR to closing MRR, including the reconciliation check.

## Metric definitions

- Monthly MRR is the recurring subscription amount normalized to a monthly value. Annual plans are divided by 12.
- New Business is the first positive MRR for a customer.
- Expansion is an increase from one positive customer-month to the next.
- Contraction is a decrease while the customer remains active.
- Churn is a change from positive MRR to zero.
- Reactivation is a return to positive MRR after a prior churn.
- Unchanged is a movement below the configured materiality threshold.

## Policy decisions

Assumptions are grouped in the `policy` CTE at the top of `demo.sql`. The current defaults are:

- A customer-month without active subscription MRR is treated as zero.
- Changes below `0.01` are treated as no change.
- Amounts are rounded to two decimal places before comparison.
- The demo uses an explicit as-of date so its result is reproducible.

Review these decisions before adapting the query to production data.

## Scope and limitations

This is a SQL starting point, not a complete Stripe connector or dbt package. It does not fetch data from Stripe, define a warehouse ingestion process, or cover every billing configuration.

Before production use, validate the model against your subscription schema and business rules, including trials, discounts, taxes, credits, refunds, multiple subscription items, currency handling, backdated changes, pauses, and cancellations.

## Status

Early release. The self-contained demo is runnable and includes a reconciliation check. Split warehouse models, real Stripe-replica inputs, and broader test coverage are planned.

## License

Apache-2.0. See [`LICENSE`](LICENSE).
