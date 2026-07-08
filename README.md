# BladeSpins

A full, standalone Eldorado bot dedicated to Blade Ball **spin orders**,
with a token-rate-based guaranteed-profit pricing engine built in. It is
a complete duplicate of the automation your main bot uses (browser
automation, buyer messaging, Roblox delivery, Lua bridge) — not a
pricing add-on bolted onto your existing bot.

## Why a separate bot instead of extending your main one

You asked for this to be its own project, so BladeSpins never imports,
reads, or writes anything belonging to your main Eldorado bot. The two
can run side by side. To make that safe, BladeSpins **only ever acts on
spin orders** (see "Spin-only filter" below) — everything else is left
completely untouched for your main bot to handle.

## Folder structure

```
BladeSpins/
├── config.py                    # ALL settings — edit this first
├── watcher.py                   # main loop — run this to start the bot
├── core/                        # automation modules (unchanged from a
│   ├── browser.py                proven, working design — only
│   ├── events.py                 watcher.py itself was modified)
│   ├── storage.py
│   ├── messages.py
│   ├── delivery.py
│   ├── roblox.py
│   ├── lua_bridge.py
│   ├── game_automation.py
│   ├── recovery.py
│   ├── alerts.py
│   └── dashboard.py
├── pricing/
│   ├── spin_pricing.py           # guaranteed-profit price calculator
│   └── pricing_in_watcher.py     # embedded periodic pricing cycle
├── scrapers/
│   ├── offers_scraper.py         # scrapes your live Eldorado offers
│   └── token_rate_scraper.py     # scrapes the live token market rate
├── apply/
│   ├── spin_price_apply_plan.py  # dry-run report: what would change
│   └── spin_price_apply.py       # REAL price writes (safety-gated)
└── data/                         # all generated JSON + bot state lives here
```

## What's genuinely new vs. copied unchanged

- **Copied unchanged** from your main bot's proven design: `browser.py`,
  `events.py`, `storage.py`, `messages.py`, `delivery.py`, `roblox.py`,
  `lua_bridge.py`, `game_automation.py`, `recovery.py`, `alerts.py`,
  `dashboard.py`. These are generic Selenium/Roblox/TalkJS automation —
  nothing about them is spin-specific, so they're reused as-is rather
  than rewritten from memory (lower risk of introducing new bugs).
- **Modified**: `watcher.py` — added the spin-only filter and swapped
  the embedded restock cycle for the embedded pricing cycle. Everything
  else in it (notification sweep, username collection, private server
  join, buyer-join watch, Lua dispatch, delivery/cancel logic) is the
  same design as your main bot.
- **New**: everything in `pricing/`, `scrapers/`, `apply/` — the
  token-rate-based pricing engine you originally asked for.

## Spin-only filter

Every order BladeSpins opens gets its real title scraped from the
Eldorado order page first. Only if that title contains one of
`config.SPIN_ORDER_KEYWORDS` (default: `"spin"`, `"spins"`) does the bot
do anything else — send messages, join a server, deliver, or cancel.
Anything else is marked handled in BladeSpins' **own** local storage
only (so it stops reopening the tab every poll) and left completely
alone; your main bot's own storage/state is never touched or read.

## Setup

1. Install dependencies:
   ```
   pip install -r requirements.txt
   ```

2. **Chrome profile — read this carefully.** Two Chrome instances cannot
   safely share the same `--user-data-dir` at the same time. `PROFILE_DIR`
   in `config.py` already points at a different folder than your main
   bot. The first time you run BladeSpins, you will need to log into
   Eldorado again in that new Chrome profile.

3. Open `config.py` and fill in:
   - `CHROMEDRIVER_PATH` — same chromedriver your main bot uses is fine.
   - `PRIVATE_SERVER_LINK` — your Blade Ball private server share link.
   - `ROBLOX_EXE_PATH` — path to `RobloxPlayerBeta.exe`.
   - `ROBLOX_COOKIE` env var, or hardcode `ROBLOX_COOKIE` (same account
     your main bot uses is fine, they don't conflict).
   - `AUTOTRADE_SPIN_TOKEN_COSTS` / `AUTOTRADE_SPIN_TIERS` — your real,
     confirmed pack costs and the tiers you sell.
   - Fee/margin are pre-filled from confirmed real numbers (15% Items
     fee, 12% margin, $0.05 profit floor) — adjust if needed.

4. **Start safe.** Two settings are deliberately conservative by default
   until you've verified a real delivery end-to-end:
   - `AUTOTRADE_GIFT_DRY_RUN = True` — Lua will simulate the gift instead
     of actually sending it.
   - `AUTOTRADE_ALLOW_TOKEN_SPEND = False` — blocks real token spend.

   Flip both to `True`/enabled only once you've watched one full order
   go through safely.

## Shared workspace with your main bot — important

`AUTOTRADE_WORKSPACE_DIR` in `config.py` points at your **real, single**
executor/tool workspace (e.g. `...\AppData\Local\Madium\Workspace`) —
the same one your main bot uses. This is not a preference; the tool that
runs the Lua AutoTrade script can only read/write inside its own one
fixed folder, so this genuinely is shared, not something BladeSpins can
have a private copy of.

Because of that, `core/lua_bridge.py` wraps every read-modify-write to
the shared `autotrade_bridge.json` queue in a small cross-process file
lock (`_bridge_queue_lock()` — atomic lock-file creation, portable across
Windows/POSIX). This means **running BladeSpins and your main bot at the
same time is safe**: both can enqueue/remove jobs on the same queue
without one silently overwriting the other's job during a race. The
single underlying Roblox session just processes both bots' jobs from one
shared queue, in whatever order they land.

## Demand-aware enable/disable + quantity sizing

Beyond pricing, BladeSpins decides which spin tiers should be **enabled
vs paused**, and what **quantity** each should list at, based on two real
signals — not guesses:

1. **Your live token balance** (`pricing/token_balance.py`) — requested
   from the SAME shared Lua analyzer your main bot's `restock_cycle.py`
   uses (namespaced request/report files so it never collides with your
   main bot's own restock files in that shared workspace).
2. **Real sales demand per tier** (`scrapers/sales_history_scraper.py` +
   `pricing/spin_demand.py`) — scraped from your actual sold-orders
   history (`/dashboard/orders/sold`), not assumed. A tier that's cheap
   to fulfill but rarely sells shouldn't outrank one that sells
   constantly, and vice versa — the ranking metric is **expected profit
   per day** (`profit_per_sale × real sales_per_day`).

If the sales-history sample is too thin
(`AUTOTRADE_SPIN_MIN_SAMPLE_ORDERS`, default 10 completed spin orders),
the demand signal is explicitly NOT trusted and the engine falls back to
plain profit ranking with equal demand weighting — it will never make a
confident "this tier never sells" call from a handful of data points.

Decision logic, in order:
1. **Hard cutoff** — if you can't afford even one order at a tier
   (`tokens_needed > available_after_reserve`), it's disabled outright.
2. Everything else is **ranked by expected profit per day**, highest
   first.
3. Walking down that ranking, tiers are kept enabled as long as they
   still fit the remaining token budget — the rest get paused.

Enabled tiers get a **quantity** sized to roughly
`AUTOTRADE_SPIN_TARGET_DAYS_OF_STOCK` days of expected sales (clamped
between `AUTOTRADE_SPIN_MIN_QUANTITY` and `AUTOTRADE_SPIN_MAX_QUANTITY_CAP`),
or the configured minimum if demand isn't trusted yet.

Run it standalone:
```
python scrapers/sales_history_scraper.py
python scrapers/offers_scraper.py
python pricing/spin_pricing.py
python pricing/spin_offer_enablement.py     # requests live balance, builds the plan, prints it
python apply/spin_offer_control_apply.py    # DRY RUN by default
```

Applying real enable/disable/quantity changes needs both:
```
set BLADESPINS_APPLY_OFFER_CONTROL=1
set BLADESPINS_CONFIRM_OFFER_CONTROL=YES_APPLY_OFFER_CONTROL
python apply/spin_offer_control_apply.py
```

The embedded cycle inside `watcher.py` runs all of this automatically
(sales history → live balance → enablement plan) every cycle, but only
applies real enable/disable/quantity changes if `AUTOTRADE_EMBEDDED_ENABLEMENT_DRY_RUN`
is `False` AND those same two env vars are set — otherwise it's always
a dry run, logged to the console.

**Note on sales-history depth**: the sold-orders page defaults to a
"Recent" date-range filter (separate from "All statuses"). The scraper
does not currently change that filter automatically — if you want a
longer lookback than whatever "Recent" covers, widen it manually before
running, or send the opened dropdown's HTML and this can be automated.

## Running the bot

Run directly:
```
python watcher.py
```

Or run it supervised (recommended for anything unattended) — auto-restarts
on crash, blocks restarts during dangerous phases or an active order,
same design as your main bot's guardian:
```
python guardian.py
```

`guardian.py` reads/writes the SHARED heartbeat and bridge queue (same
reasoning as above — genuinely shared, not a private copy), but its own
status/state/manual-block files are namespaced (`bladespins_supervisor_*`)
so pausing BladeSpins with `python guardian.py --clear-manual-block` never
affects your main bot's guardian, and vice versa. It also only ever
matches BladeSpins' own Chrome process (via its own `PROFILE_DIR`), so
running both guardians at the same time is safe.

## Pricing engine — running it standalone

You don't have to wait for the embedded cycle; each piece is runnable on
its own for testing:

```
python scrapers/offers_scraper.py
python scrapers/token_rate_scraper.py
python pricing/spin_pricing.py
python apply/spin_price_apply_plan.py     # dry-run report only
```

That last command prints exactly what would change and why, and writes
`data/spin_price_apply_report.json`. **Nothing is changed on Eldorado
by any of the above.**

## Applying real price changes

The price field is directly editable on the Eldorado offers **list**
page itself (confirmed from the real card HTML) — an
`<input aria-label="Numeric input field">` plus a `"Confirm price"`
button. `apply/spin_price_apply.py` implements this, and is **dry-run by
default**. To actually write prices:

```
set BLADESPINS_APPLY_PRICES=1
set BLADESPINS_CONFIRM_PRICES=YES_APPLY_PRICES
python apply/spin_price_apply.py
```

Both environment variables are required — this mirrors the same
two-flag safety pattern your main bot uses for real restock applies.
Results (including any offer where the value didn't stick, which is
verified after clicking "Confirm price") are written to
`data/spin_price_apply_result.json`.

The embedded cycle inside `watcher.py` respects the exact same two env
vars — if they're not both set, it always runs as a dry run, regardless
of `config.AUTOTRADE_EMBEDDED_PRICING_DRY_RUN`.

## How the pricing math works

For each spin tier:

1. If it's a pack you sell directly (in `AUTOTRADE_SPIN_TOKEN_COSTS`),
   that token cost is used.
2. Otherwise, the cheapest EXACT combination of your real packs is found
   automatically (e.g. 100x = 2×50x) — a general knapsack solver, not
   hardcoded, with a tiebreaker that prefers fewer total packs when two
   combinations cost the same (fewer separate gifts to send).
3. Token cost → USD using the live scraped market rate (lowest price/K
   visible across all sellers on the public token page).
4. Price is set so that AFTER Eldorado's confirmed 15% fee, you still
   net your token cost plus a profit margin (12% of cost, or a $0.05
   floor — whichever is higher). Prices always round UP to the next
   cent, never down.

## Safety notes

- `apply/spin_price_apply.py` only ever touches offers matched by
  `apply/spin_price_apply_plan.py`, which requires BOTH `"Spins"` in the
  offer's scraped categories AND a leading `{N}x` in its title. Anything
  else is left alone and listed under "skipped" with a reason.
- The embedded pricing cycle checks the Lua heartbeat before running and
  skips entirely if it's in a dangerous/mid-delivery phase, or if
  `data/bladespins_manual_block.json` exists (create this file manually
  to pause pricing without stopping the whole bot).
- Nothing in this project touches your main bot's `config.py`,
  `orders.json`, `handled_orders.json`, or Chrome profile.