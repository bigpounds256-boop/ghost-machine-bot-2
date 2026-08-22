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

SYMBOL   = "BTC/USD"
H1_BARS  = 25
M15_BARS = 40

GEMINI_MODEL = "gemini-2.0-flash"  # fast + free-tier friendly
GEMINI_URL = f"https://generativelanguage.googleapis.com/v1beta/models/{GEMINI_MODEL}:generateContent"


# ── STEP 1: Fetch live candles from TwelveData ──────────────────────────
def fetch_candles(interval: str, count: int):
    url = "https://api.twelvedata.com/time_series"
    params = {
        "symbol": SYMBOL,
        "interval": interval,       # "1h" or "15min"
        "outputsize": count,
        "apikey": TWELVEDATA_API_KEY,
        "order": "desc",
    }
    r = requests.get(url, params=params, timeout=15)
    r.raise_for_status()
    data = r.json()
    if "values" not in data:
        raise RuntimeError(f"TwelveData error: {data}")
    return data["values"]  # newest first


def format_candles(candles):
    lines = []
    for c in candles:
        lines.append(
            f"{c['datetime']} | O:{c['open']} H:{c['high']} L:{c['low']} C:{c['close']}"
        )
    return "\n".join(lines)


# ── STEP 2: Build the SMC strategy prompt ───────────────────────────────
def build_prompt(h1_candles, m15_candles, current_price):
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

    prompt = f"""You are an elite Smart Money Concepts (SMC) trading analyst specialized in high-probability "sniper" setups.
Analyze the following live market data strictly according to the rules below.

=== MARKET DATA ===
Symbol: {SYMBOL}
Current Price: {current_price}
Time: {now}

--- H1 Candles (newest first) ---
{format_candles(h1_candles)}

--- M15 Candles (newest first) ---
{format_candles(m15_candles)}

=== STRICT STRATEGY RULES ===
Timeframes: Higher Timeframe Bias = H1 | Entry Timeframe = M15

Required Conditions for a Valid Setup (ALL must be present):
1. Clear Higher Timeframe Bias (bullish or bearish) on H1.
2. Confirmed Break of Structure (BOS) on M15 in the direction of the HTF bias.
3. A valid Breaker Block on M15 that aligns with the BOS.
4. Price is currently pulling back into the Breaker Block zone (or has just reached it).
5. Relevant liquidity context supporting the trade idea.
6. Volatility is moderate to high.
7. Prefer active trading sessions.

Risk Rules:
- Minimum Risk:Reward = 1:2 (preferably higher)
- Stop Loss tight, just beyond the Breaker Block or most recent structural swing
- Entry preferably a Limit order (BUY-LIMIT or SELL-LIMIT) at the Breaker Block

No-Trade Conditions (any of these → output NO TRADE):
- No clear HTF bias / No clean M15 BOS / No valid Breaker Block
- Price already left the zone without reaction
- Low volatility / choppy market
- Risk:Reward below 1:2
- Setup against HTF bias

=== OUTPUT FORMAT (MANDATORY) ===
Reply with ONLY raw JSON, no markdown fences, no extra text. Use exactly this structure.

If a valid setup exists:
{{
  "trade_signal_Theghostmachine": {{
    "date": "YYYY-MM-DD",
    "current_price": "XXXX.XX",
    "pair": "{SYMBOL}",
    "trade_type": "BUY-LIMIT or SELL-LIMIT",
    "entry_price": "XXXX.XX",
    "stop_loss": "XXXX.XX",
    "take_profit": "XXXX.XX",
    "risk_reward": "1:X.X",
    "analysis": {{
      "trend_detection": "...",
      "volatility_level": "...",
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

Be extremely selective. Only call a setup when it truly meets every single rule."""
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
def main():
    print("Fetching live H1 candles...")
    h1 = fetch_candles("1h", H1_BARS)

    print("Fetching live M15 candles...")
    m15 = fetch_candles("15min", M15_BARS)

    current_price = m15[0]["close"]

    print("Building prompt...")
    prompt = build_prompt(h1, m15, current_price)

    print("Sending to Gemini for SMC analysis...")
    signal = get_ai_analysis(prompt)

    print("\n========== TRADE SIGNAL ==========")
    print(json.dumps(signal, indent=2))
    print("===================================")

    # Save to file for logging / later automation
    with open("last_signal.json", "w") as f:
        json.dump(signal, f, indent=2)


if __name__ == "__main__":
    main()
