//+------------------------------------------------------------------+
//| HF1_Short_HighFreq.mq5                                           |
//| High-frequency short-only (target >=5 trades/day)                |
//| SMA 3/30 pure crossover, hold 3 bars, no/low martingale          |
//| WARNING: High frequency + any martingale increases risk of ruin. |
//+------------------------------------------------------------------+
#property copyright "Research EA - HF Candidate 1"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//--- Inputs matching HF-1
input int      InpSmaFast      = 3;        // SMA Fast
input int      InpSmaSlow      = 30;       // SMA Slow
input int      InpSmaTrend     = 150;      // SMA Trend (used only if mode needs it)
input int      InpAtrLen       = 5;        // ATR period
input int      InpRsiLen       = 7;        // RSI period
input double   InpRsiOS        = 35.0;     // RSI OS
input double   InpRsiOB        = 75.0;     // RSI OB
input int      InpMode         = 0;        // 0=pure crossover (high freq)
input int      InpDirection    = 2;        // 2 = short-only
input double   InpMartMult     = 1.0;      // 1.0 = no martingale
input double   InpMaxMult      = 2.0;      // Cap
input int      InpExitMode     = 2;        // 2 = fixed bars
input double   InpTrailATR     = 1.97;     // Trail (if used)
input int      InpHoldBars     = 3;        // Very short hold for frequency
input double   InpBaseRiskMoney= 30.0;     // Risk $ per base unit
input double   InpProtectATR   = 1.8;      // Protective stop ATR mult
input int      InpMagic        = 202611;   // Magic
input double   InpSlippage     = 15;       // Slippage points
input bool     InpShowLogs     = false;    // Logs (off for high freq)

//--- Globals
int handleSmaF, handleSmaS, handleSmaT, handleATR, handleRSI;
double curMult = 1.0;
datetime lastBarTime = 0;
int barsInTrade = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   handleSmaF = iMA(_Symbol, PERIOD_CURRENT, InpSmaFast, 0, MODE_SMA, PRICE_CLOSE);
   handleSmaS = iMA(_Symbol, PERIOD_CURRENT, InpSmaSlow, 0, MODE_SMA, PRICE_CLOSE);
   handleSmaT = iMA(_Symbol, PERIOD_CURRENT, InpSmaTrend, 0, MODE_SMA, PRICE_CLOSE);
   handleATR  = iATR(_Symbol, PERIOD_CURRENT, InpAtrLen);
   handleRSI  = iRSI(_Symbol, PERIOD_CURRENT, InpRsiLen, PRICE_CLOSE);
   if(handleSmaF==INVALID_HANDLE || handleSmaS==INVALID_HANDLE || handleATR==INVALID_HANDLE)
   {
      Print("Indicator init failed");
      return INIT_FAILED;
   }
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints((ulong)InpSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(handleSmaF); IndicatorRelease(handleSmaS);
   IndicatorRelease(handleSmaT); IndicatorRelease(handleATR); IndicatorRelease(handleRSI);
}

//+------------------------------------------------------------------+
bool CopyBuf(int h, int b, int s, int c, double &a[]) { return CopyBuffer(h,b,s,c,a)==c; }

//+------------------------------------------------------------------+
double CalcLot(double riskMoney, double atrVal)
{
   double stopDist = atrVal * InpProtectATR;
   if(stopDist <= 0) return 0.01;
   double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize= SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickVal<=0 || tickSize<=0) return 0.01;
   double moneyPerPoint = tickVal / tickSize;
   double points = stopDist / _Point;
   double lot = riskMoney / (points * moneyPerPoint);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathFloor(lot/step)*step;
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;
   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
void UpdateMartingaleFromHistory()
{
   if(InpMartMult <= 1.0) { curMult = 1.0; return; }
   HistorySelect(0, TimeCurrent());
   for(int i = HistoryDealsTotal()-1; i >= 0; i--)
   {
      ulong deal = HistoryDealGetTicket(i);
      if(deal==0) continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol) continue;
      if((long)HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagic) continue;
      if(HistoryDealGetInteger(deal, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      double profit = HistoryDealGetDouble(deal, DEAL_PROFIT) + HistoryDealGetDouble(deal, DEAL_SWAP) + HistoryDealGetDouble(deal, DEAL_COMMISSION);
      if(profit >= 0) curMult = 1.0;
      else curMult = MathMin(curMult * InpMartMult, InpMaxMult);
      break;
   }
}

//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
      if(PositionGetSymbol(i)==_Symbol && PositionGetInteger(POSITION_MAGIC)==InpMagic) return true;
   return false;
}

//+------------------------------------------------------------------+
void ManageOpenPosition()
{
   if(!HasOpenPosition()) { barsInTrade=0; return; }
   barsInTrade++;
   if(InpExitMode==2 && barsInTrade >= InpHoldBars)
   {
      for(int i=PositionsTotal()-1; i>=0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(PositionSelectByTicket(ticket) && PositionGetString(POSITION_SYMBOL)==_Symbol && PositionGetInteger(POSITION_MAGIC)==InpMagic)
         {
            trade.PositionClose(ticket);
            barsInTrade = 0;
            return;
         }
      }
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   datetime t[];
   if(CopyTime(_Symbol, PERIOD_CURRENT, 0, 1, t) < 1) return;
   bool isNewBar = (t[0] != lastBarTime);
   if(isNewBar) lastBarTime = t[0];

   ManageOpenPosition();
   if(HasOpenPosition()) return;
   if(!isNewBar) return;

   static bool first=true;
   if(!first) UpdateMartingaleFromHistory();
   first=false;

   double smaF[3], smaS[3], atr[2];
   if(!CopyBuf(handleSmaF,0,0,3,smaF)) return;
   if(!CopyBuf(handleSmaS,0,0,3,smaS)) return;
   if(!CopyBuf(handleATR,0,0,2,atr)) return;

   bool crossUp = (smaF[1] > smaS[1] && smaF[2] <= smaS[2]);
   bool crossDn = (smaF[1] < smaS[1] && smaF[2] >= smaS[2]);

   bool longSig = false, shortSig = false;
   if(InpMode == 0) { longSig = crossUp; shortSig = crossDn; }
   // other modes omitted for pure high-freq focus; can be extended

   if(InpDirection == 1) shortSig = false;
   if(InpDirection == 2) longSig  = false;

   double risk = InpBaseRiskMoney * curMult;
   double lot  = CalcLot(risk, atr[1]);
   if(lot <= 0) return;

   double protect = atr[1] * InpProtectATR;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(shortSig)
   {
      double sl = ask + protect;
      if(trade.Sell(lot, _Symbol, bid, sl, 0, "HF1 Short"))
         barsInTrade = 0;
   }
   else if(longSig)
   {
      double sl = bid - protect;
      if(trade.Buy(lot, _Symbol, ask, sl, 0, "HF1 Long"))
         barsInTrade = 0;
   }
}
//+------------------------------------------------------------------+
