# BladeSpins — Growth & Profit Ideas

Working list of ideas beyond the pricing engine itself. Six of these are already implemented (marked ✅) as of 2026-07-12; everything else is a candidate worth considering, roughly ordered by how directly it moves profit or sell-through speed.

## 1. Pricing & inventory (implemented this session)

- ✅ **Volume-tiered supplier cost.** `TOKEN_ACQUISITION_COST_TIERS_USD_PER_K` in `config.py` — buying more from your Discord supplier in one deal automatically lowers the modeled acquisition cost, which lowers the floor and widens margin. Update the thresholds ($2.60 at 20K, $2.55 at 50K, $2.50 at 100K are placeholders) the moment you actually negotiate real numbers.
- ✅ **Inventory-scaled velocity floor.** The more tokens you're sitting on, the more the price floor relaxes toward (never below) the hard safety minimum, so you sell a big pile faster instead of protecting margin/unit while it sits exposed to risk. Only kicks in when a competitor's price is actually low enough to justify it — doesn't race to the bottom for no reason.
- ✅ **Banked-margin windfall mode.** When a competitor prices high (like your $4.30 example) and undercutting them still clears target margin by a wide amount, the excess gets banked. Once the bank has $5+ in it, you're allowed to intentionally undercut below the target floor (funded by real collected margin, not free) to move inventory faster — this is the literal "we could actually go to like $3.80 afterward" mechanic you described.
- ✅ **Real per-sale profit ledger.** `pricing/token_sales_ledger.py` — now reads actual completed Currency orders from `sales_history_scraper.py` and credits/debits the margin bank off real sold price vs. cost, not a per-cycle guess. Falls back to the old approximation automatically until your first real completed token sale shows up in the scraped history.
- ✅ **Anomaly alerts + stockout forecast.** Same module tracks consecutive unhealthy-margin cycles (flags after 3 in a row) and consecutive velocity-mode cycles (flags after 5 in a row, signaling possible oversupply), and estimates real days-until-stockout from actual sell-through rate. All logged automatically each pricing cycle — check `[TokenPricing] ALERT` lines in the watcher log.
- ✅ **Quantity break points / multi-tier offers.** `config.BLADESPINS_TOKEN_OFFERS` now supports multiple Eldorado Currency listings at different minimum quantities (e.g. your 1K-min retail offer + a 10K-min bulk offer once you create it), each priced independently against same-tier competitors, with its own target margin, and a safety clamp so the bulk tier can never end up costing MORE per K than retail. Just paste the bulk offer's ID into `BLADESPINS_TOKEN_OFFERS` once you've created the listing — everything else (pricing, enable/disable, apply) is already wired up.
- **Time-of-day / day-of-week price elasticity.** If sales data shows certain hours have less competition (fewer sellers online, less price-checking), your floor could relax slightly during those windows and tighten during peak competition hours. Needs `sales_history_scraper` timestamps to test whether this pattern actually exists before building it.

## 2. Supplier relationship

- **Lock in a standing volume discount, not a one-off.** A single $2.50/K purchase is worth less to you long-term than negotiating "every deal over 50K is $2.50/K, going forward" — turns a one-time win into a permanent lower cost basis.
- **Multiple suppliers, ranked.** Relying on one Discord seller means their price (or their disappearance) is a single point of failure. Cultivating 2-3 suppliers you can compare in real time gives you negotiating leverage ("someone else is offering 2.60, can you match") and backup if one goes quiet.
- **Pay in whatever's cheapest for THEM to receive, not just cheapest for you to send.** If a supplier prefers a stablecoin or a specific coin because it saves them a conversion step, they may pass some of that savings back in the form of a better rate — worth asking directly.
- **Track supplier reliability, not just price.** A seller at $2.60/K who reliably delivers in 10 minutes is worth more than one at $2.55/K who sometimes ghosts mid-deal and leaves you holding paid-for crypto with no tokens. If you deal with the same suppliers repeatedly, a simple reliability note (delivered on time, delayed, no-show) pays off the next time you're choosing who to buy from.

## 3. Sell-through speed / demand generation

- ✅ **Multiple quantity tiers as separate listings** — done, see section 1. Pricing/apply logic is ready for a 1K-min + 10K-min bulk split; you just need to create the actual second listing on Eldorado and paste its offer ID in.
- **Fast-delivery as a selling point, tracked and advertised.** If your average delivery time is meaningfully faster than competitors (plausible, since this is automated end-to-end), that's a real differentiator worth stating in the offer title/description — buyers on Eldorado do price-compare AND read reviews/speed claims.
- **Review/reputation compounding.** Eldorado sellers with more completed orders and better ratings tend to rank higher / get picked more often at equal price. Early on it can be worth pricing slightly more aggressively than the model strictly requires, specifically to build order count and rating faster — a deliberate short-term margin sacrifice for long-term ranking, which is a different (and probably better-targeted) reason to dip toward the velocity floor than pure inventory pressure.
- **Bundle offers.** If Blade Ball players commonly want both tokens and specific items/spins, a bundle discount (tokens + spins together, slightly cheaper than buying separately) increases average order size and could out-convert two separate smaller listings.

## 4. Risk management

- **Diversify off a single game.** Blade Ball's economy depends entirely on the game staying popular and the developer not changing the token economy (nerfing exchange rates, disabling trading, banning bulk accounts). If you haven't already, keep a running note of what a sudden rule change would do to inventory value, and consider whether a second Roblox game with a similar tradeable-currency economy is worth scouting as a hedge.
- **Account risk spreading.** If everything routes through one Roblox account (`Ioadstr2`), a single ban ends the whole operation instantly. Whether it's worth running a second account in parallel (more infrastructure, but no single point of failure) is a real tradeoff — at minimum, know what your actual exposure is if that account gets flagged.
- **Cash-out cadence vs. holding.** Holding proceeds as crypto vs. converting immediately to fiat has real volatility risk (LTC/USD moved noticeably even within this session's price checks). A simple rule — e.g. "convert to fiat within 48 hours of receipt" — removes you from having to time crypto markets, which isn't the business you're actually in.
- **Middleman/escrow counterparty risk.** The whole LEG1/LEG2 fee chain depends on trusting the same middleman bot for both fiat→crypto and crypto→tokens. Worth knowing their track record/reputation and having a fallback if they ever become unavailable or untrustworthy mid-deal.

## 5. Operational efficiency (mostly software, since that's what's already being built)

- ✅ **Per-sale profit ledger** — done, see section 1. `pricing/token_sales_ledger.py` now measures realized profit off actual completed sales instead of only projecting it, and this is also the data source the fee-chain model (Eldorado 15% + Skrill + LEG1/LEG2) could eventually be validated against over time, once enough real sales accumulate.
- ✅ **Alerting on anomalies** — done, see section 1. Consecutive-unhealthy-margin and consecutive-velocity-mode streaks now flag automatically in the pricing cycle log.
- ✅ **Predictive stockout forecasting** — done, see section 1 (`days_until_stockout`). Note this is the forecasting half only; the other half (auto-timing supplier purchases off that forecast) is still manual, listed again below.
- **Automated supplier price tracking.** If suppliers post rates in a Discord channel, a simple watcher that logs rate changes over time would tell you the real distribution of rates available (not just today's one deal), which directly informs whether $2.65 is actually a good baseline or whether better deals are common and you're leaving money on the table.

## 6. Bigger swings (lower priority, higher effort/uncertainty)

- **Auto-negotiation with suppliers** — a bot that messages known suppliers on a schedule asking for current rates at your typical purchase size, so you always have fresh comparison data without manually checking Discord.
- **Predictive restocking (purchase timing)** — the forecasting piece (`days_until_stockout`) is now live; the remaining piece is using it to actually time supplier purchases (e.g. auto-message you, or auto-suggest a purchase amount) before you'd run out, rather than just reporting the number.
- **Cross-market arbitrage** — if Blade Ball tokens or items trade on any other marketplace besides Eldorado at meaningfully different rates, the same buy-low/sell-high logic already built here could extend there. Only worth exploring once the Eldorado side is running smoothly and consistently profitable.

---

*Note: the pricing-engine ideas in section 1 are live in `pricing/token_pricing.py` and `config.py` as of this session. Everything else here is a candidate, not yet built — flag whichever ones are worth prioritizing and I can help implement them.*
