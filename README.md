# mrr-foundation

**MRR, movement, and retention from your subscription data — as tables you own, not a dashboard you rent.**

You have subscriptions in Stripe. You need monthly MRR per customer, a movement
breakdown (new / expansion / contraction / churn / reactivation), and a bridge that
explains why revenue changed. Building that yourself is a few weeks of edge cases.
This is that foundation, pre-built.

## Try it in 30 seconds

Copy [`demo.sql`](demo.sql) into a BigQuery console and run it. Synthetic data is
inlined — no tables, no credentials, no setup. It processes 0 bytes.

| Month | Opening | New | Expansion | Contraction | Churn | Reactivation | Closing |
|---|---|---|---|---|---|---|---|
| 2026-01 | 0 | 2,150 | 0 | 0 | 0 | 0 | 2,150 |
| 2026-02 | 2,150 | 1,200 | 0 | 0 | 0 | 0 | 3,350 |
| 2026-03 | 3,350 | 0 | 0 | -350 | -250 | 0 | 2,750 |
| 2026-04 | 2,750 | 0 | 150 | 0 | -300 | 0 | 2,600 |
| 2026-05 | 2,600 | 0 | 400 | 0 | 0 | 250 | 3,250 |

Every row balances: `opening + new + expansion + contraction + churn + reactivation = closing`.

The synthetic data deliberately includes the three cases most hand-rolled models get wrong:

- **Annual plans** — a $12,000/yr subscription contributes $1,000/mo, not a one-month spike.
- **Reactivation vs. new** — a customer who churns and returns is `reactivation`, not `new`.
- **Seat changes** — 3 → 7 seats at the same unit price is `expansion`, not a new subscription.

## The opinions

Every judgment call lives in one `policy` block at the top of the model. Nothing below
it encodes an opinion. To see the complete list:

```bash
grep -rn "OPINION:" .
```

Current defaults: annual plans spread evenly across 12 months; a customer-month with no
subscription counts as 0 MRR (so churn is a visible row, not an absent one); changes below
$0.01 are `no_change`; amounts round to 2dp before comparison so float dust never becomes
"movement".

## Status

Early. `demo.sql` is complete and verified end-to-end.

Roadmap:

- [x] `demo.sql` — self-contained, runnable, reconciles
- [ ] Split models: `stg_stripe__*`, `customer_month_mrr`, `mrr_movement`, `mrr_summary`
- [ ] Read a real Stripe replica (Fivetran / Airbyte schemas) instead of inlined data
- [ ] `customer_bridge` — match Stripe customers to your production database
      (override seed > Stripe metadata key > normalized email)
- [ ] `customer_bridge_exceptions` — who didn't match, who is active but unbilled,
      who is billed but churned
- [ ] Edge-case fixtures as proper tests + CI
- [ ] `DECISIONLOG.md` — documented judgment calls, including subscription-based vs.
      invoice-based MRR (this package uses subscription-based: it sees churn cleanly,
      where invoice-based cannot, since absence of an invoice is not an event)

## Design notes

- **Input contract:** the model needs one row per customer per month with an MRR
  amount. `demo.sql` derives that from subscription rows; a real source does the same.
- **Single currency.** Multi-currency normalization is deliberately out of scope.
- **Deterministic matching only** for the customer bridge. Ambiguous cases get
  reported, not guessed.

## License

Apache-2.0
