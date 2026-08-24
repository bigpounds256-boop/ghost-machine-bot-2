//+------------------------------------------------------------------+
//|                               BollingerForcedChampion_EA.mq5     |
//|  Forced Champion – PF≥1.5 priority + High Trade Frequency        |
//|  Optimized across BTCUSDT / XAUUSD / EURUSD (1m & 5m)            |
//+------------------------------------------------------------------+
#property copyright "Grok Strategy Optimizer"
#property link      ""
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//--- Inputs (Forced Champion defaults)
input group "=== Strategy Parameters (Forced Champion) ==="
input int      InpRSIPeriod       = 11;          // RSI Period
input double   InpRSI_OS          = 31.8;        // RSI Oversold
input double   InpRSI_OB          = 73.4;        // RSI Overbought
input int      InpBBPeriod        = 12;          // Bollinger Period
input double   InpBBDeviation     = 1.82;        // Bollinger Deviation
input int      InpATRPeriod       = 9;           // ATR Period
input double   InpSL_ATR          = 0.93;        // Stop Loss (× ATR)
input double   InpTP_ATR          = 3.85;        // Take Profit (× ATR)

input group "=== Risk & Trade Management ==="
input double   InpRiskPercent     = 1.0;         // Risk per trade (% of equity)
input int      InpMaxTradesDay    = 29;          // Max trades per day
input double   InpMinATRPct       = 0.00025;     // Min ATR% filter (0 = off)
input int      InpMagic           = 20260821;    // Magic Number
input string   InpTradeComment    = "BollForced";// Trade comment

input group "=== General ==="
input bool     InpAllowBuy        = true;        // Allow Long trades
input bool     InpAllowSell       = true;        // Allow Short trades
input int      InpSlippage        = 30;          // Slippage (points)
input bool     InpOnePosition     = true;        // Only one position at a time

//--- Globals
CTrade         trade;
CPositionInfo  posInfo;
CSymbolInfo    symInfo;

int      handleRSI  = INVALID_HANDLE;
int      handleBB   = INVALID_HANDLE;
int      handleATR  = INVALID_HANDLE;
datetime lastBarTime = 0;
int      tradesToday = 0;
int      lastDay     = -1;

//+------------------------------------------------------------------+
int OnInit()
{
   if(!symInfo.Name(_Symbol))
   {
      Print("Failed to initialize symbol info for ", _Symbol);
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   handleRSI = iRSI(_Symbol, PERIOD_CURRENT, InpRSIPeriod, PRICE_CLOSE);
   handleBB  = iBands(_Symbol, PERIOD_CURRENT, InpBBPeriod, 0, InpBBDeviation, PRICE_CLOSE);
   handleATR = iATR(_Symbol, PERIOD_CURRENT, InpATRPeriod);

   if(handleRSI == INVALID_HANDLE || handleBB == INVALID_HANDLE || handleATR == INVALID_HANDLE)
   {
      Print("Failed to create indicator handles");
      return INIT_FAILED;
   }

   Print("BollingerForcedChampion EA started | ", _Symbol, " | ", EnumToString(Period()));
   Print("Defaults: RSI(", InpRSIPeriod, ") OS=", InpRSI_OS, " OB=", InpRSI_OB,
         " BB(", InpBBPeriod, ",", InpBBDeviation, ") SL=", InpSL_ATR, "×ATR TP=", InpTP_ATR, "×ATR");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(handleRSI != INVALID_HANDLE) IndicatorRelease(handleRSI);
   if(handleBB  != INVALID_HANDLE) IndicatorRelease(handleBB);
   if(handleATR != INVALID_HANDLE) IndicatorRelease(handleATR);
}

//+------------------------------------------------------------------+
void OnTick()
{
   // Process only on new bar
   datetime currentBar = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(currentBar == lastBarTime)
      return;
   lastBarTime = currentBar;

   // Daily trade counter reset
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day != lastDay)
   {
      lastDay     = dt.day;
      tradesToday = 0;
   }

   if(tradesToday >= InpMaxTradesDay)
      return;

   // Optional: only one position at a time
   if(InpOnePosition && PositionSelect(_Symbol))
      return;

   // Read indicators from the last closed bar (index 1)
   double rsi[2], bbUpper[2], bbLower[2], atr[2];
   if(CopyBuffer(handleRSI, 0, 1, 2, rsi)     < 2) return;
   if(CopyBuffer(handleBB,  1, 1, 2, bbUpper) < 2) return;  // UPPER
   if(CopyBuffer(handleBB,  2, 1, 2, bbLower) < 2) return;  // LOWER
   if(CopyBuffer(handleATR, 0, 1, 2, atr)     < 2) return;

   double close1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   if(close1 <= 0.0 || atr[0] <= 0.0)
      return;

   // Volatility filter
   if(InpMinATRPct > 0.0)
   {
      if((atr[0] / close1) < InpMinATRPct)
         return;
   }

   bool longSignal  = (rsi[0] < InpRSI_OS && close1 < bbLower[0]);
   bool shortSignal = (rsi[0] > InpRSI_OB && close1 > bbUpper[0]);

   if(longSignal && InpAllowBuy)
      OpenTrade(ORDER_TYPE_BUY, atr[0]);
   else if(shortSignal && InpAllowSell)
      OpenTrade(ORDER_TYPE_SELL, atr[0]);
}

//+------------------------------------------------------------------+
void OpenTrade(ENUM_ORDER_TYPE type, double atrValue)
{
   if(!symInfo.RefreshRates())
      return;

   double point    = symInfo.Point();
   double tickVal  = symInfo.TickValue();
   double tickSize = symInfo.TickSize();
   int    digits   = (int)symInfo.Digits();

   double price  = (type == ORDER_TYPE_BUY) ? symInfo.Ask() : symInfo.Bid();
   double slDist = atrValue * InpSL_ATR;
   double tpDist = atrValue * InpTP_ATR;

   double sl, tp;
   if(type == ORDER_TYPE_BUY)
   {
      sl = NormalizeDouble(price - slDist, digits);
      tp = NormalizeDouble(price + tpDist, digits);
   }
   else
   {
      sl = NormalizeDouble(price + slDist, digits);
      tp = NormalizeDouble(price - tpDist, digits);
   }

   // Risk-based lot calculation
   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * InpRiskPercent / 100.0;
   double slPoints  = MathAbs(price - sl) / point;
   if(slPoints < 1.0)
      return;

   double tickValuePerPoint = tickVal * (point / tickSize);
   if(tickValuePerPoint <= 0.0)
      return;

   double lots = riskMoney / (slPoints * tickValuePerPoint);
   lots = NormalizeVolume(lots);
   if(lots <= 0.0)
      return;

   // Margin safety check
   double margin = 0.0;
   if(!OrderCalcMargin(type, _Symbol, lots, price, margin))
      return;
   if(margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.85)
   {
      lots = NormalizeVolume(lots * 0.5);
      if(lots <= 0.0)
         return;
   }

   bool ok = false;
   if(type == ORDER_TYPE_BUY)
      ok = trade.Buy(lots, _Symbol, price, sl, tp, InpTradeComment);
   else
      ok = trade.Sell(lots, _Symbol, price, sl, tp, InpTradeComment);

   if(ok)
   {
      tradesToday++;
      PrintFormat("Opened %s | lots=%.2f | SL=%.5f | TP=%.5f | ATR=%.5f | Today=%d",
                  EnumToString(type), lots, sl, tp, atrValue, tradesToday);
   }
   else
   {
      Print("Order failed: ", trade.ResultRetcode(), " – ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
double NormalizeVolume(double lots)
{
   double minLot  = symInfo.LotsMin();
   double maxLot  = symInfo.LotsMax();
   double stepLot = symInfo.LotsStep();
   if(stepLot <= 0.0)
      stepLot = 0.01;

   lots = MathFloor(lots / stepLot) * stepLot;
   lots = MathMax(minLot, MathMin(maxLot, lots));
   return NormalizeDouble(lots, 2);
}
//+------------------------------------------------------------------+