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
    {"symbol": "EUR/USD", "class": "forex"},
    {"symbol": "XAU/USD", "class": "metals"},
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

    prompt = f"""You are a Supply & Demand trading analyst. Your analysis must be based
ENTIRELY AND ONLY on Supply & Demand zones — nothing else determines direction
or entry. Do NOT use moving averages, trend filters, ICT concepts like
Break of Structure / Change of Character, Order Block terminology, or
liquidity-sweep language. The zones themselves are the entire basis.
Volatility, momentum, and volume indicators are used ONLY as confirmation
on top of a zone reaction, never as the primary signal.

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

=== STRATEGY RULES (Supply & Demand only) ===
Timeframes: Higher Timeframe Context = H1 | Entry Timeframe = M15

1. Identify Supply Zones:
   - A Supply Zone is a small area of consolidation/base immediately before
     price departed sharply downward (a strong, mostly one-directional move
     away from that base). The base itself is the zone.
   - The stronger and faster the departure (the bigger the imbalance left
     behind), the higher-quality the zone.

2. Identify Demand Zones:
   - A Demand Zone is a small area of consolidation/base immediately before
     price departed sharply upward. The base itself is the zone.
   - Same quality principle: a stronger, faster departure = higher-quality zone.

3. Zone Freshness:
   - Prefer zones price has not returned to since they formed ("fresh"
     zones). A zone that has already been retested and held once is
     lower quality; one retested multiple times is likely close to failing.

4. Order-Based Entry Logic (pending orders placed AT the zone, not chased):
   - This is an order-based strategy: you identify the zone first, then place
     a pending limit order directly inside it, and let price come to the
     order rather than reacting after the fact.
   - SELL-LIMIT: placed inside a valid, relevant Supply Zone, anticipating
     price will rise into the zone and reverse down from it.
   - BUY-LIMIT: placed inside a valid, relevant Demand Zone, anticipating
     price will fall into the zone and reverse up from it.
   - The order's price should sit within the zone boundaries — not at the
     very edge, and not requiring price to have already reacted there yet.
     The whole point is the order is resting and waiting.
   - Only propose an order if price is currently within a reasonable
     approach distance of the zone (close enough that the order is likely
     to actually get filled in a sensible timeframe). If price is far away
     with no realistic path to the zone soon, that is NO TRADE.
   - If no valid zone exists near current price at all, that is NO TRADE
     regardless of anything else happening on the chart.

5. Confirmation layer (secondary — never overrides the zone read):
   - Volatility (ATR): the zone reaction should have enough volatility for a
     sensible SL/TP. Dead/flat conditions at the zone weaken the setup.
   - Momentum (RSI): a bullish reaction from a demand zone is more convincing
     if RSI is turning up from lower levels; a bearish reaction from a
     supply zone is more convincing if RSI is turning down from higher
     levels.
   - Volume: a volume ratio at/above ~1.0 on the original departure from the
     zone, or on the current reaction, adds confidence.

Risk Rules:
- Minimum Risk:Reward = 1:2
- Stop Loss placed just beyond the far edge of the Supply/Demand zone
- Entry is ALWAYS a pending limit order resting inside the zone (BUY-LIMIT
  in a Demand Zone, SELL-LIMIT in a Supply Zone) — never a market entry

No-Trade Conditions (any of these → output NO TRADE):
- No valid, relevant Supply or Demand zone near current price
- Price already left the zone without a clean reaction
- The only nearby zone is stale/overused (tested multiple times already)
- Risk:Reward below 1:2
- Confirmation indicators strongly contradict the zone reaction (e.g. zero
  volatility, or momentum firmly opposite the expected direction)

=== OUTPUT FORMAT (MANDATORY) ===
Reply with ONLY raw JSON, no markdown fences, no extra text. Use exactly this structure.

If a valid setup exists:
{{
  "trade_signal_Theghostmachine": {{
    "date": "YYYY-MM-DD",
    "current_price": "XXXX.XX",
    "pair": "{symbol}",
    "trade_type": "BUY-LIMIT or SELL-LIMIT",
    "entry_price": "XXXX.XX",
    "stop_loss": "XXXX.XX",
    "take_profit": "XXXX.XX",
    "risk_reward": "1:X.X",
    "analysis": {{
      "zone_type": "Supply Zone or Demand Zone",
      "zone_range": "XXXX.XX - XXXX.XX",
      "zone_freshness": "...",
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

Be disciplined: only propose a pending limit order when a genuine, relevant
Supply or Demand zone exists within realistic reach of current price, with
the indicators only supporting — never replacing — that zone-based read."""
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

    max_retries = 3
    r = None
    for attempt in range(max_retries):
        r = requests.post(GEMINI_URL, json=payload, headers=headers, timeout=30)
        if r.status_code == 429:
            wait = 20 * (attempt + 1)  # 20s, then 40s, then 60s
            print(f"Gemini rate-limited (429). Waiting {wait}s before retry {attempt + 1}/{max_retries}...")
            time.sleep(wait)
            continue
        break

    if r.status_code == 429:
        raise RuntimeError("Gemini still rate-limited after all retries — free tier quota likely exhausted for now.")
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
    time.sleep(SECONDS_BETWEEN_CALLS)  # space out Gemini calls between symbols too
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
