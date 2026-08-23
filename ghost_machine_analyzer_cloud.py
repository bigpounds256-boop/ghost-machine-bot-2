"""
TheGhostMachine Analyzer — Doctrine Edition (Predictive Wick-Rejection)
------------------------------------------------------------------------
Pulls live H4/H1/M15/M5 candles from TwelveData for a watchlist of
instruments and sends them to Google Gemini for analysis using the
"Preemptive Predictive Wick-Rejection / Defensive Staff" doctrine —
17 price-action/indicator concepts, 5 causal confluences, dual buy/sell
scenario scoring, and a confidence percentage.

Runs standalone (python ghost_machine_analyzer_cloud.py) or via the
GitHub Actions workflow on a schedule.

NOTE on "confidence percentage": this is Gemini's own structured
self-assessment of how many doctrine concepts align — a reasoning aid,
not a statistically backtested probability.
"""

import os
import json
import time
import requests
from datetime import datetime, timezone

# ── CONFIG ────────────────────────────────────────────────────────────
TWELVEDATA_API_KEY = os.environ["TWELVEDATA_API_KEY"]
GEMINI_API_KEY      = os.environ["GEMINI_API_KEY"]

print(f"DEBUG: TWELVEDATA_API_KEY length = {len(TWELVEDATA_API_KEY)}")
print(f"DEBUG: GEMINI_API_KEY length = {len(GEMINI_API_KEY)}")

WATCHLIST = [
    {"symbol": "BTC/USD", "class": "crypto"},
    {"symbol": "EUR/USD", "class": "forex"},
    {"symbol": "XAU/USD", "class": "metals"},
]

H4_BARS  = 30
H1_BARS  = 30
M15_BARS = 48
M5_BARS  = 60

# TwelveData free tier ≈ 8 requests/minute. 4 calls per symbol now
# (H4+H1+M15+M5), so pace requests to stay safely under that limit.
SECONDS_BETWEEN_CALLS = 8

GEMINI_MODEL = "gemini-3.5-flash"  # 2.0-flash was shut down June 2026
GEMINI_URL = f"https://generativelanguage.googleapis.com/v1beta/models/{GEMINI_MODEL}:generateContent"


# ── STEP 1: Fetch live candles from TwelveData ──────────────────────────
def fetch_candles(symbol: str, interval: str, count: int):
    url = "https://api.twelvedata.com/time_series"
    params = {
        "symbol": symbol,
        "interval": interval,
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
    return round(sum(trs[-period:]) / period, 5)

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
    return round(100 - (100 / (1 + rs)), 1)

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


# ── STEP 2: Build the doctrine-based prompt ─────────────────────────────
def build_prompt(symbol, h4, h1, m15, m5, current_price):
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

    h4_trend  = compute_trend(h4)
    h1_trend  = compute_trend(h1)
    m15_trend = compute_trend(m15)
    m5_trend  = compute_trend(m5)
    atr = compute_atr(m15)
    rsi = compute_rsi(m15)
    vol_ratio = compute_volume_ratio(m15)

    indicator_block = f"""H4 Trend: {h4_trend}
H1 Trend: {h1_trend}
M15 Trend: {m15_trend}
M5 Trend: {m5_trend}
M15 ATR(14) [volatility]: {atr if atr is not None else "N/A"}
M15 RSI(14) [momentum]: {rsi if rsi is not None else "N/A"}
M15 Volume Ratio (current vs 20-bar avg) [volume]: {vol_ratio if vol_ratio is not None else "N/A"}

Note: only trend/ATR/RSI/Volume above are pre-computed with exact math.
For any other indicator you reference below (Ichimoku, ADX, MACD, Stochastic,
CCI, TRIX, AO, Bollinger Bands, Keltner, OBV, CMF, VPVR, VROC, A/D, Fibonacci
levels, SD), reason about it qualitatively from the raw candle data provided
— do not invent precise numeric values for indicators you have not been
given exact figures for; describe their likely state/direction in words."""

    prompt = f"""You are a trading analyst operating strictly under the doctrine below —
"Preemptive Predictive Wick-Rejection / Defensive Staff." Apply it exactly
as written. Do not substitute a different strategy or simplify it.

=== MARKET DATA ===
Symbol: {symbol}
Current Price: {current_price}
Time: {now}

--- Computed / Reasoning Anchors ---
{indicator_block}

--- H4 Candles (newest first) ---
{format_candles(h4)}

--- H1 Candles (newest first) ---
{format_candles(h1)}

--- M15 Candles (newest first) ---
{format_candles(m15)}

--- M5 Candles (newest first) ---
{format_candles(m5)}

=== DOCTRINE ===

1. Price Action Concepts (use all 10 — no single concept alone is sufficient):
ICT / Smart Money Concepts (SMC); MSNR / Malaysian SNR; CRT (Candle Range
Theory); Supply and Demand Zones; Trendline Breaks & Bounces; Chart Patterns;
Candlestick Patterns; Quarter Theory (QT); Break of Structure (BOS); Fair
Value Gap (FVG) / Unmitigated Gaps.
Each of the 5 confluences below must integrate at least 3 of these concepts
plus at least 1 indicator alignment.

2. Core Indicators Concepts (all four types actively analyzed):
Trend: EMA50/200, Ichimoku, ADX, MACD.
Momentum: RSI, Stochastic, CCI, TRIX, AO.
Volatility: ATR, Bollinger Bands, SD, Keltner.
Volume: OBV, CMF, VPVR, VROC, Accumulation/Distribution.
Indicators validate concept alignment and confluence.

3. Additional Tools:
Fibonacci Retracement (0.382, 0.5, 0.618); Fibonacci Circles; Standard
Deviation (SD). These enhance precision in locating predictive defensive
staff zones.

4. Predictive Wick-Rejection / Defensive Staff:
Principle: enter preemptively at the predicted wick-rejection point — do not
wait for confirmation. The market reacts at internal defensive zones; deep
textbook zones are secondary. Stop Loss sits just beyond the HTF invalidation
of the defensive staff. Take Profit is based on HTF liquidity clusters, swing
highs, and BOS — aim for 1:10+ Risk:Reward where the structure genuinely
supports it.

5. Take Profit and Risk Management:
Primary TP: first HTF liquidity zone or swing high (conservative).
Extreme TP: extended HTF move, maintaining 1:10+ R:R where realistic.
SL: tight, doctrine-compliant, preemptive, placed just below/above the
predicted defensive staff.

6. Confluence Rules:
Exactly 5 confluences per signal. Each integrates at least 3 price-action
concepts plus at least 1 indicator alignment. Reasoning must be causal
(explain HOW the concepts interact), not just a list of names. Composition
is flexible — rotate concepts based on actual chart context, not a fixed
template.

7. Dual-Scenario Evaluation:
Score BOTH a Buy scenario and a Sell scenario. For each, state which
concepts align, which fail, and why. Select the higher-confidence scenario
as the bias.

8. Confidence Percentage:
Calculate as (aligned concepts ÷ 17) × 100 for both Buy and Sell. Only treat
a scenario as executable if confidence is ≥ 80%. If neither scenario reaches
80%, this is NO TRADE.

9. Entry Module (order-based):
This is an order-based strategy: you must output a SPECIFIC price for a
pending order — a BUY-LIMIT resting price for buys or a SELL-LIMIT resting
price for sells — not just a zone description. The order rests and waits;
price is not chased. entry_price must be a single actionable number sitting
within the defensive staff zone (entry_zone gives the zone's boundaries for
context, but entry_price is the exact order price). SL tight at HTF
invalidation below/above the predicted defensive staff. TP aligns with HTF
liquidity clusters / swing highs. Requires multi-concept + indicator
validation. Do not wait for wick confirmation before placing the order —
the order itself is the preemptive action.

10. Signal Selection Logic:
Evaluate all 17 concepts → build 5 valid confluences → score Buy vs Sell →
compute confidence % → select the higher-confidence scenario (if ≥ 80%) →
define the preemptive entry with tight SL.

11. Market Contexts:
Consider trend, structure, volatility, session/timing, and sentiment.
Multi-timeframe alignment across H4/H1/M15/M5 (all provided above) is
mandatory. Include liquidity clusters and HTF BOS in your reasoning.

12. Current Price Behavior:
Analyze the anticipated defensive staff, BOS, structure interactions,
indicator alignment, trend, momentum, and volume at current price.

13. Possible Outcome & News:
State the Success case (price reacts at the defensive staff, continuation
occurs), Failure case (SL invalidation at the HTF level), and Neutral case
(consolidation/delayed move). No live news feed is provided here — only
mention news if it's reasoned from price behavior itself, don't fabricate
specific headlines.

=== OUTPUT FORMAT (MANDATORY) ===
Reply with ONLY raw JSON, no markdown fences, no extra text.

If confidence >= 80% for the winning scenario, use exactly this structure:
{{
  "trade_signal_doctrine": {{
    "asset": "{symbol}",
    "bias": "BUY or SELL",
    "trade_type": "BUY-LIMIT or SELL-LIMIT",
    "entry_zone": "XXXX.XX - XXXX.XX",
    "entry_price": "XXXX.XX",
    "invalidation_stop": "XXXX.XX",
    "take_profit": {{
      "primary_tp": "XXXX.XX",
      "extreme_tp": "XXXX.XX",
      "risk_reward_ratio": "1:X"
    }},
    "timeframes_used": ["H4", "H1", "M15", "M5"],
    "entry_logic": "Preemptive entry at predicted wick-rejection zone (defensive staff) with tight SL; no waiting for confirmation.",
    "confluences": [
      "Confluence 1: ...reasoning and concepts...",
      "Confluence 2: ...reasoning and concepts...",
      "Confluence 3: ...reasoning and concepts...",
      "Confluence 4: ...reasoning and concepts...",
      "Confluence 5: ...reasoning and concepts..."
    ],
    "confidence_model": {{
      "total_doctrine_checks": 17,
      "buy_conditions_met": 0,
      "sell_conditions_met": 0,
      "confidence_percentage": "",
      "dominant_bias_reason": "..."
    }},
    "risk_profile": {{
      "expected_rr": "1:X",
      "stop_type": "HTF structure invalidation (preemptive)",
      "note": "Preemptive entry captures full HTF continuation without waiting for wick confirmation."
    }},
    "status": "PENDING - valid only if price taps predictive zone"
  }}
}}

If confidence is below 80% for both scenarios, or no valid predictive
defensive staff zone can be identified, use exactly this structure instead:
{{
  "trade_signal_doctrine": {{
    "status": "NO TRADE",
    "reason": "...",
    "confidence_model": {{
      "total_doctrine_checks": 17,
      "buy_conditions_met": 0,
      "sell_conditions_met": 0,
      "confidence_percentage": "",
      "dominant_bias_reason": "..."
    }}
  }}
}}

Apply the doctrine exactly. Do not lower the 80% threshold and do not invent
precise numeric values for indicators you were not given computed figures for."""
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
        r = requests.post(GEMINI_URL, json=payload, headers=headers, timeout=60)
        if r.status_code == 429:
            wait = 20 * (attempt + 1)
            print(f"Gemini rate-limited (429). Waiting {wait}s before retry {attempt + 1}/{max_retries}...")
            time.sleep(wait)
            continue
        break

    if r.status_code == 429:
        raise RuntimeError("Gemini still rate-limited after all retries — free tier quota likely exhausted for now.")
    if r.status_code == 401:
        raise RuntimeError(
            "Gemini returned 401 Unauthorized. If you're on a new 'AQ.' format key, "
            "double check it was copied in full and hasn't been regenerated since."
        )
    r.raise_for_status()
    data = r.json()
    text = data["candidates"][0]["content"]["parts"][0]["text"]

    text = text.strip().removeprefix("```json").removeprefix("```").removesuffix("```").strip()
    return json.loads(text)


# ── MAIN ──────────────────────────────────────────────────────────────
def analyze_symbol(symbol: str) -> dict:
    print(f"\n--- {symbol} ---")

    print("Fetching live H4 candles...")
    h4 = fetch_candles(symbol, "4h", H4_BARS)
    time.sleep(SECONDS_BETWEEN_CALLS)

    print("Fetching live H1 candles...")
    h1 = fetch_candles(symbol, "1h", H1_BARS)
    time.sleep(SECONDS_BETWEEN_CALLS)

    print("Fetching live M15 candles...")
    m15 = fetch_candles(symbol, "15min", M15_BARS)
    time.sleep(SECONDS_BETWEEN_CALLS)

    print("Fetching live M5 candles...")
    m5 = fetch_candles(symbol, "5min", M5_BARS)
    time.sleep(SECONDS_BETWEEN_CALLS)

    current_price = m5[0]["close"]

    print("Building doctrine prompt...")
    prompt = build_prompt(symbol, h4, h1, m15, m5, current_price)

    print("Sending to Gemini for doctrine analysis...")
    signal = get_ai_analysis(prompt)
    time.sleep(SECONDS_BETWEEN_CALLS)
    return signal


def main():
    results = {}

    for entry in WATCHLIST:
        symbol = entry["symbol"]
        asset_class = entry["class"]
        try:
            signal = analyze_symbol(symbol)
            results[symbol] = {"asset_class": asset_class, "signal": signal}
            print(f"OK: {symbol}")
        except Exception as e:
            print(f"SKIPPED {symbol}: {e}")
            results[symbol] = {"asset_class": asset_class, "signal": {"error": str(e)}}

    output = {
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC"),
        "doctrine": "Preemptive Predictive Wick-Rejection / Defensive Staff",
        "results": results,
    }

    print("\n========== ALL SIGNALS ==========")
    print(json.dumps(output, indent=2))
    print("===================================")

    with open("last_signal.json", "w") as f:
        json.dump(output, f, indent=2)


if __name__ == "__main__":
    main()
