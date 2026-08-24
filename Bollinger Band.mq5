//+------------------------------------------------------------------+
//|                                      BollingerChampion_EA.mq5    |
//|  Multi-asset Bollinger + RSI Mean-Reversion Champion             |
//|  Optimized across BTCUSDT / XAUUSD / EURUSD (1m & 5m)            |
//+------------------------------------------------------------------+
#property copyright "Grok Strategy Optimizer"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//--- Inputs
input group "=== Strategy Parameters (Champion) ==="
input int      InpRSIPeriod       = 6;           // RSI Period
input double   InpRSI_OS          = 27.5;        // RSI Oversold
input double   InpRSI_OB          = 78.1;        // RSI Overbought
input int      InpBBPeriod        = 15;          // Bollinger Period
input double   InpBBDeviation     = 1.85;        // Bollinger Deviation
input int      InpATRPeriod       = 9;           // ATR Period
input double   InpSL_ATR          = 0.97;        // Stop Loss (× ATR)
input double   InpTP_ATR          = 3.07;        // Take Profit (× ATR)

input group "=== Risk & Trade Management ==="
input double   InpRiskPercent     = 1.0;         // Risk per trade (% of equity)
input int      InpMaxTradesDay    = 21;          // Max trades per day
input double   InpMinATRPct       = 0.0003;      // Min ATR% filter (0 = disabled)
input int      InpMagic           = 20260820;    // Magic Number
input string   InpTradeComment    = "BollChamp"; // Trade comment

input group "=== General ==="
input bool     InpAllowBuy        = true;        // Allow Long trades
input bool     InpAllowSell       = true;        // Allow Short trades
input int      InpSlippage        = 30;          // Slippage (points)

//--- Globals
CTrade         trade;
CPositionInfo  posInfo;
CSymbolInfo    symInfo;

int handleRSI, handleBB, handleATR;
datetime lastBarTime = 0;
int tradesToday = 0;
int lastDay = -1;

//+------------------------------------------------------------------+
int OnInit()
{
   if(!symInfo.Name(_Symbol))
   {
      Print("Failed to init symbol info");
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
      Print("Failed to create indicators");
      return INIT_FAILED;
   }

   Print("BollingerChampion EA initialized | Symbol=", _Symbol, " TF=", EnumToString(Period()));
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
   // Work only on new bar
   datetime currentBar = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(currentBar == lastBarTime) return;
   lastBarTime = currentBar;

   // Reset daily trade counter
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day != lastDay)
   {
      lastDay = dt.day;
      tradesToday = 0;
   }

   if(tradesToday >= InpMaxTradesDay) return;
   if(PositionSelect(_Symbol)) return;   // only one position at a time

   // Indicator values from the last closed bar
   double rsi[2], bbUpper[2], bbLower[2], atr[2];
   if(CopyBuffer(handleRSI, 0, 1, 2, rsi) < 2) return;
   if(CopyBuffer(handleBB,  1, 1, 2, bbUpper) < 2) return;  // UPPER band
   if(CopyBuffer(handleBB,  2, 1, 2, bbLower) < 2) return;  // LOWER band
   if(CopyBuffer(handleATR, 0, 1, 2, atr) < 2) return;

   double close1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   if(close1 <= 0.0 || atr[0] <= 0.0) return;

   // Optional volatility filter
   if(InpMinATRPct > 0.0)
   {
      if((atr[0] / close1) < InpMinATRPct) return;
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
   if(!symInfo.RefreshRates()) return;

   double point    = symInfo.Point();
   double tickVal  = symInfo.TickValue();
   double tickSize = symInfo.TickSize();
   int    digits   = (int)symInfo.Digits();

   double price = (type == ORDER_TYPE_BUY) ? symInfo.Ask() : symInfo.Bid();
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

   // Risk-based lot size
   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * InpRiskPercent / 100.0;
   double slPoints  = MathAbs(price - sl) / point;
   if(slPoints < 1.0) return;

   double tickValuePerPoint = tickVal * (point / tickSize);
   if(tickValuePerPoint <= 0.0) return;

   double lots = riskMoney / (slPoints * tickValuePerPoint);
   lots = NormalizeVolume(lots);
   if(lots <= 0.0) return;

   // Margin safety
   double margin = 0.0;
   if(!OrderCalcMargin(type, _Symbol, lots, price, margin)) return;
   if(margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.9)
   {
      lots = NormalizeVolume(lots * 0.5);
      if(lots <= 0.0) return;
   }

   bool ok = false;
   if(type == ORDER_TYPE_BUY)
      ok = trade.Buy(lots, _Symbol, price, sl, tp, InpTradeComment);
   else
      ok = trade.Sell(lots, _Symbol, price, sl, tp, InpTradeComment);

   if(ok)
   {
      tradesToday++;
      Print("Opened ", EnumToString(type),
            " | lots=", DoubleToString(lots, 2),
            " | SL=", DoubleToString(sl, digits),
            " | TP=", DoubleToString(tp, digits),
            " | ATR=", DoubleToString(atrValue, digits),
            " | TradesToday=", tradesToday);
   }
   else
   {
      Print("Order failed: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
double NormalizeVolume(double lots)
{
   double minLot  = symInfo.LotsMin();
   double maxLot  = symInfo.LotsMax();
   double stepLot = symInfo.LotsStep();
   if(stepLot <= 0.0) stepLot = 0.01;

   lots = MathFloor(lots / stepLot) * stepLot;
   lots = MathMax(minLot, MathMin(maxLot, lots));
   return NormalizeDouble(lots, 2);
}
//+------------------------------------------------------------------+