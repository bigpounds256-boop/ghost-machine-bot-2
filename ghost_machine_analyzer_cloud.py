"""
TheGhostMachine Analyzer — Standalone Edition
------------------------------------------------
No MetaTrader required. Pulls live XAUUSD candles from TwelveData
and sends them to Google Gemini for Smart Money Concepts (SMC) analysis.
Outputs a strict JSON trade signal.

SETUP (one time):
  1. pip install requests
  2. Fill in your keys below (or set as environment variables — safer).
  3. Run:  python ghost_machine_analyzer.py

Get keys:
  TwelveData : https://twelvedata.com/  (free tier, you already have one)
  Gemini     : https://aistudio.google.com/ (free, no card required)
"""

import os
import json
import time
import requests
from datetime import datetime, timezone

# ── CONFIG ────────────────────────────────────────────────────────────
# Keys come from GitHub Secrets (set as environment variables in the
# workflow) — never hardcode keys in a public repo, they get scraped
# and abused within hours if committed in plain text.
TWELVEDATA_API_KEY = os.environ["TWELVEDATA_API_KEY"]
GEMINI_API_KEY      = os.environ["GEMINI_API_KEY"]

print(f"DEBUG: TWELVEDATA_API_KEY length = {len(TWELVEDATA_API_KEY)}")
print(f"DEBUG: GEMINI_API_KEY length = {len(GEMINI_API_KEY)}")

# Watchlist across asset classes. TwelveData symbol format shown.
# NOTE: Indices (US500/NAS100/DJI) often require a paid TwelveData plan —
# if your free tier rejects them, the script logs it and skips that
# instrument rather than crashing the whole run.
WATCHLIST = [
    {"symbol": "BTC/USD", "class": "crypto"},
    {"symbol": "ETH/USD", "class": "crypto"},
    {"symbol": "EUR/USD", "class": "forex"},
    {"symbol": "GBP/USD", "class": "forex"},
    {"symbol": "USD/JPY", "class": "forex"},
    {"symbol": "XAU/USD", "class": "metals"},
    {"symbol": "XAG/USD", "class": "metals"},
    {"symbol": "US500",   "class": "indices"},
    {"symbol": "NAS100",  "class": "indices"},
]

H1_BARS  = 25
M15_BARS = 40

# TwelveData free tier ≈ 8 requests/minute. 2 calls per symbol (H1+M15),
# so pace requests to stay safely under that limit across the whole run.
SECONDS_BETWEEN_CALLS = 8

GEMINI_MODEL = "gemini-3.5-flash"  # 2.0-flash was shut down June 2026
GEMINI_URL = f"https://generativelanguage.googleapis.com/v1beta/models/{GEMINI_MODEL}:generateContent"


# ── STEP 1: Fetch live candles from TwelveData ──────────────────────────
def fetch_candles(symbol: str, interval: str, count: int):
    url = "https://api.twelvedata.com/time_series"
    params = {
        "symbol": symbol,
        "interval": interval,       # "1h" or "15min"
        "outputsize": count,
        "apikey": TWELVEDATA_API_KEY,
        "order": "desc",
    }
    r = requests.get(url, params=params, timeout=15)
    r.raise_for_status()
    data = r.json()
    if "values" not in data:
        raise RuntimeError(f"TwelveData error for {symbol}: {data}")
    return data["values"]  # newest first


def format_candles(candles):
    lines = []
    for c in candles:
        lines.append(
            f"{c['datetime']} | O:{c['open']} H:{c['high']} L:{c['low']} C:{c['close']}"
        )
    return "\n".join(lines)


# ── STEP 1b: Compute technical indicators from candle data ──────────────
# TwelveData returns newest-first; these need oldest-first for calculation.

def _chronological(candles):
    return list(reversed(candles))

def compute_atr(candles, period=14):
    c = _chronological(candles)
    if len(c) < period + 1:
        return None
    trs = []
    for i in range(1, len(c)):
        high = float(c[i]["high"])
        low = float(c[i]["low"])
        prev_close = float(c[i - 1]["close"])
        tr = max(high - low, abs(high - prev_close), abs(low - prev_close))
        trs.append(tr)
    atr = sum(trs[-period:]) / period
    return round(atr, 2)

def compute_rsi(candles, period=14):
    c = _chronological(candles)
    if len(c) < period + 1:
        return None
    closes = [float(x["close"]) for x in c]
    gains, losses = [], []
    for i in range(1, len(closes)):
        change = closes[i] - closes[i - 1]
        gains.append(max(change, 0))
        losses.append(max(-change, 0))
    avg_gain = sum(gains[-period:]) / period
    avg_loss = sum(losses[-period:]) / period
    if avg_loss == 0:
        return 100.0
    rs = avg_gain / avg_loss
    rsi = 100 - (100 / (1 + rs))
    return round(rsi, 1)

def compute_volume_ratio(candles, period=20):
    c = _chronological(candles)
    if len(c) < period + 1 or "volume" not in c[0]:
        return None
    volumes = [float(x.get("volume", 0)) for x in c]
    current = volumes[-1]
    avg = sum(volumes[-(period + 1):-1]) / period
    if avg == 0:
        return None
    return round(current / avg, 2)

def compute_trend(candles, short=8, long=21):
    c = _chronological(candles)
    closes = [float(x["close"]) for x in c]
    if len(closes) < long:
        return "insufficient data"
    sma_short = sum(closes[-short:]) / short
    sma_long = sum(closes[-long:]) / long
    if sma_short > sma_long * 1.001:
        return "bullish"
    elif sma_short < sma_long * 0.999:
        return "bearish"
    return "sideways/neutral"


# ── STEP 2: Build the strategy prompt ────────────────────────────────
def build_prompt(symbol, h1_candles, m15_candles, current_price):
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

    atr = compute_atr(m15_candles)
    rsi = compute_rsi(m15_candles)
    vol_ratio = compute_volume_ratio(m15_candles)

    indicator_block = f"""M15 ATR(14) [volatility]: {atr if atr is not None else "N/A"}
M15 RSI(14) [momentum]: {rsi if rsi is not None else "N/A"}
M15 Volume Ratio (current vs 20-bar avg) [volume]: {vol_ratio if vol_ratio is not None else "N/A"}"""

    prompt = f"""You are an ICT/SMC (Inner Circle Trader / Smart Money Concepts) trading analyst.
Your analysis must be based ENTIRELY on Supply & Demand zones, Order Blocks, and
core SMC/ICT structural concepts. Do NOT use moving averages or simple trend
filters as your basis for direction — direction comes purely from market
structure (BOS/CHoCH) and where price sits relative to Order Blocks / Supply
and Demand zones. Volatility, momentum, and volume indicators are used only
as CONFIRMATION on top of the structural read, never as the primary signal.

=== MARKET DATA ===
Symbol: {symbol}
Current Price: {current_price}
Time: {now}

--- Confirmation Indicators (secondary, not primary signal) ---
{indicator_block}

--- H1 Candles (newest first) ---
{format_candles(h1_candles)}

--- M15 Candles (newest first) ---
{format_candles(m15_candles)}

=== STRATEGY RULES (pure ICT/SMC) ===
Timeframes: Higher Timeframe Context = H1 | Entry Timeframe = M15

1. Market Structure (primary basis for direction — H1 and M15):
   - Identify the current structure using swing highs/lows: is price making
     Higher Highs/Higher Lows (bullish structure) or Lower Highs/Lower Lows
     (bearish structure)?
   - Look for a Break of Structure (BOS) — price breaking a prior swing
     high/low in the direction of the prevailing structure — or a Change of
     Character (CHoCH) — the first break AGAINST the prevailing structure,
     signaling a possible reversal.
   - HTF (H1) structure sets the directional context; M15 is where the entry
     trigger (BOS/CHoCH + Order Block reaction) is found.

2. Supply & Demand Zones / Order Blocks:
   - A bullish Order Block is the last down-close candle (or cluster) before
     a strong impulsive move up that caused a BOS.
   - A bearish Order Block is the last up-close candle (or cluster) before a
     strong impulsive move down that caused a BOS.
   - A valid setup requires price to return to (or approach) an Order Block /
     Supply-Demand zone that aligns with the current structural bias, and
     show a reaction (rejection wick, shift in momentum) from that zone.
   - Prefer zones that are still "fresh" (untested since formation) over
     zones price has already returned to multiple times.

3. Liquidity:
   - Look for evidence of liquidity being taken — price sweeping above a
     prior high (buy-side liquidity) or below a prior low (sell-side
     liquidity) — right before the reversal into the Order Block / BOS.
   - This liquidity sweep is a strong supporting factor, though not always
     present. Its absence alone should not disqualify an otherwise clean
     structural setup.

4. Confirmation layer (secondary — do not use to override structure):
   - Volatility (ATR): the zone reaction should occur with enough volatility
     that a sensible SL/TP is achievable. Extremely flat/dead conditions
     around the zone weaken the setup.
   - Momentum (RSI): a bullish reaction from a demand zone is more convincing
     if RSI is turning up from lower levels (not already extremely
     overbought); a bearish reaction from a supply zone is more convincing if
     RSI is turning down from higher levels (not already extremely oversold).
   - Volume: a volume ratio at/above ~1.0 on the impulsive move that created
     the Order Block, or on the reaction at the zone, adds confidence. Very
     low volume on the reaction is a warning sign.

Risk Rules:
- Minimum Risk:Reward = 1:2
- Stop Loss placed just beyond the Order Block / Supply-Demand zone boundary
  (beyond the wick that defines it)
- Entry at the Order Block / zone — either a limit order at the zone, or
  confirmation entry once a reaction candle closes

No-Trade Conditions (any of these → output NO TRADE):
- No clear market structure (choppy, no discernible swing pattern)
- No valid, relevant Order Block / Supply-Demand zone near current price
- Price has already moved away from the zone without a clean reaction
- Risk:Reward below 1:2
- Confirmation indicators strongly contradict the structural read (e.g. zero
  volatility, or momentum firmly opposite the expected reaction direction)

=== OUTPUT FORMAT (MANDATORY) ===
Reply with ONLY raw JSON, no markdown fences, no extra text. Use exactly this structure.

If a valid setup exists:
{{
  "trade_signal_Theghostmachine": {{
    "date": "YYYY-MM-DD",
    "current_price": "XXXX.XX",
    "pair": "{symbol}",
    "trade_type": "BUY or SELL",
    "entry_price": "XXXX.XX",
    "stop_loss": "XXXX.XX",
    "take_profit": "XXXX.XX",
    "risk_reward": "1:X.X",
    "analysis": {{
      "market_structure": "...",
      "order_block_or_zone": "...",
      "liquidity_context": "...",
      "volatility_level": "...",
      "momentum_rsi": "...",
      "volume_confirmation": "...",
      "technical_indicators": ["...", "...", "...", "...", "..."]
    }},
    "possible_outcomes": "..."
  }}
}}

If NO valid setup exists:
{{
  "trade_signal_Theghostmachine": {{
    "status": "NO TRADE",
    "reason": "..."
  }}
}}

Be disciplined: the setup must be justified primarily by structure (BOS/CHoCH)
and a genuine Order Block / Supply-Demand reaction, with the indicators only
supporting — never replacing — that structural read."""
    return prompt


# ── STEP 3: Send to Gemini for analysis ─────────────────────────────────
def get_ai_analysis(prompt: str) -> dict:
    payload = {
        "contents": [{"parts": [{"text": prompt}]}],
        "generationConfig": {"temperature": 0.2},
    }
    headers = {
        "x-goog-api-key": GEMINI_API_KEY,
        "Content-Type": "application/json",
    }
    r = requests.post(
        GEMINI_URL,
        json=payload,
        headers=headers,
        timeout=30,
    )
    if r.status_code == 401:
        raise RuntimeError(
            "Gemini returned 401 Unauthorized. If you're on a new 'AQ.' format key, "
            "double check it was copied in full (they're long) and that it hasn't been "
            "regenerated since — regenerating invalidates the old string immediately."
        )
    r.raise_for_status()
    data = r.json()
    text = data["candidates"][0]["content"]["parts"][0]["text"]

    # Strip accidental markdown fences if the model adds them
    text = text.strip().removeprefix("```json").removeprefix("```").removesuffix("```").strip()

    return json.loads(text)


# ── MAIN ──────────────────────────────────────────────────────────────
def analyze_symbol(symbol: str) -> dict:
    print(f"\n--- {symbol} ---")
    print("Fetching live H1 candles...")
    h1 = fetch_candles(symbol, "1h", H1_BARS)
    time.sleep(SECONDS_BETWEEN_CALLS)

    print("Fetching live M15 candles...")
    m15 = fetch_candles(symbol, "15min", M15_BARS)
    time.sleep(SECONDS_BETWEEN_CALLS)

    current_price = m15[0]["close"]

    print("Building prompt...")
    prompt = build_prompt(symbol, h1, m15, current_price)

    print("Sending to Gemini for analysis...")
    signal = get_ai_analysis(prompt)
    return signal


def main():
    results = {}

    for entry in WATCHLIST:
        symbol = entry["symbol"]
        asset_class = entry["class"]
        try:
            signal = analyze_symbol(symbol)
            results[symbol] = {
                "asset_class": asset_class,
                "signal": signal,
            }
            print(f"OK: {symbol}")
        except Exception as e:
            # Don't let one bad/unsupported symbol (e.g. indices needing a
            # paid TwelveData plan) kill the whole run — skip and continue.
            print(f"SKIPPED {symbol}: {e}")
            results[symbol] = {
                "asset_class": asset_class,
                "signal": {"error": str(e)},
            }

    output = {
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC"),
        "results": results,
    }

    print("\n========== ALL SIGNALS ==========")
    print(json.dumps(output, indent=2))
    print("===================================")

    with open("last_signal.json", "w") as f:
        json.dump(output, f, indent=2)


if __name__ == "__main__":
    main()
