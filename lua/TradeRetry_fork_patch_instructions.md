# Trade-retry safety patch — AutoTrade fork

Context: `watcher.py` now retries `TradeMain`/`TokenTradeMain` once when the
Lua bridge reports `buyer_ready_timeout` or `buyer_confirm_timeout`
(buyer joined the server but never accepted/confirmed the trade — usually
Roblox trading privacy). This is safe on the Python side (job re-queued
into `autotrade_bridge.json` after re-verifying the buyer is still in the
server), but it depends on one Lua-side guarantee that needs to be
checked/patched: **the trade window must be fully closed before a retry's
`Start()` runs, or the second attempt can add tokens/items into an already-open
trade window on top of what's already sitting there — buyer receives 2x.**

## The risk

If `TradeMain.Start()` / `TokenTradeMain.Start()` times out waiting for
`ready`/`confirm` but leaves the Roblox trade UI open (rather than
cancelling it), and the retry then calls `addTokensToTrade(amount)` /
the item-add equivalent again without first clearing the existing trade,
the buyer's trade window ends up with double the tokens/items. If they
accept at that point, that's a real, uncapped overpayment out of your
reserve — worse than just cancelling the order outright.

## Required patch

In both `TradeMain.lua` and `TokenTradeMain.lua`, at the very start of
`Start()`, before anything else runs:

```lua
-- Idempotent reset: always start from a clean trade state, in case a
-- previous attempt (this retry) left a trade window open.
if TradeActions.isTradeWindowOpen and TradeActions.isTradeWindowOpen() then
    TradeActions.declineOrCloseTrade()
    task.wait(1) -- let the client settle before opening a new one
end
```

(`isTradeWindowOpen` / `declineOrCloseTrade` — use whatever your fork's
`TradeActions.lua` already exposes for cancelling/closing an open trade;
if neither exists yet, add a small `declineOrCloseTrade()` that fires
whatever remote/UI action your existing successful-completion path uses
to close the trade window, and a matching `isTradeWindowOpen()` that
checks whether the trade frame is currently visible.)

Also, at the point where `Start()` currently times out waiting for
ready/confirm and returns the failure reason, make sure it explicitly
closes the trade window itself before returning — don't rely only on the
next `Start()` call's reset to clean up, since the window may sit open
in-game for the full 60s gap before the retry even happens.

## Verify before trusting this live

Test on the alt account: force a `buyer_ready_timeout` (buyer joins, sees
the trade request, but never hits Ready) and confirm on the retry that
the trade window shows only ONE set of tokens/items, not a stacked
amount, before letting this run unattended on real orders.
