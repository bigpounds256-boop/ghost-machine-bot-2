//+------------------------------------------------------------------+
//| HF2_Both_HighFreq.mq5                                            |
//| High-frequency both directions, opposite-signal exit             |
//| SMA 12/50 pure crossover + light martingale                      |
//+------------------------------------------------------------------+
#property copyright "Research EA - HF Candidate 2"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//--- Inputs matching HF-2
input int      InpSmaFast      = 12;
input int      InpSmaSlow      = 50;
input int      InpSmaTrend     = 100;
input int      InpAtrLen       = 7;
input int      InpRsiLen       = 9;
input double   InpRsiOS        = 25.0;
input double   InpRsiOB        = 80.0;
input int      InpMode         = 0;        // pure crossover
input int      InpDirection    = 0;        // both
input double   InpMartMult     = 1.2;
input double   InpMaxMult      = 6.0;
input int      InpExitMode     = 0;        // 0 = opposite signal
input double   InpTrailATR     = 2.15;
input int      InpHoldBars     = 12;       // fallback
input double   InpBaseRiskMoney= 30.0;
input double   InpProtectATR   = 1.8;
input int      InpMagic        = 202612;
input double   InpSlippage     = 15;
input bool     InpShowLogs     = false;

int handleSmaF, handleSmaS, handleSmaT, handleATR, handleRSI;
double curMult = 1.0;
datetime lastBarTime = 0;
int barsInTrade = 0;

int OnInit()
{
   handleSmaF = iMA(_Symbol, PERIOD_CURRENT, InpSmaFast, 0, MODE_SMA, PRICE_CLOSE);
   handleSmaS = iMA(_Symbol, PERIOD_CURRENT, InpSmaSlow, 0, MODE_SMA, PRICE_CLOSE);
   handleSmaT = iMA(_Symbol, PERIOD_CURRENT, InpSmaTrend, 0, MODE_SMA, PRICE_CLOSE);
   handleATR  = iATR(_Symbol, PERIOD_CURRENT, InpAtrLen);
   handleRSI  = iRSI(_Symbol, PERIOD_CURRENT, InpRsiLen, PRICE_CLOSE);
   if(handleSmaF==INVALID_HANDLE || handleSmaS==INVALID_HANDLE || handleATR==INVALID_HANDLE)
      return INIT_FAILED;
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints((ulong)InpSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   IndicatorRelease(handleSmaF); IndicatorRelease(handleSmaS);
   IndicatorRelease(handleSmaT); IndicatorRelease(handleATR); IndicatorRelease(handleRSI);
}

bool CopyBuf(int h, int b, int s, int c, double &a[]) { return CopyBuffer(h,b,s,c,a)==c; }

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

void UpdateMartingaleFromHistory()
{
   if(InpMartMult <= 1.0) { curMult=1.0; return; }
   HistorySelect(0, TimeCurrent());
   for(int i=HistoryDealsTotal()-1; i>=0; i--)
   {
      ulong deal = HistoryDealGetTicket(i);
      if(deal==0) continue;
      if(HistoryDealGetString(deal,DEAL_SYMBOL)!=_Symbol) continue;
      if((long)HistoryDealGetInteger(deal,DEAL_MAGIC)!=InpMagic) continue;
      if(HistoryDealGetInteger(deal,DEAL_ENTRY)!=DEAL_ENTRY_OUT) continue;
      double profit = HistoryDealGetDouble(deal,DEAL_PROFIT)+HistoryDealGetDouble(deal,DEAL_SWAP)+HistoryDealGetDouble(deal,DEAL_COMMISSION);
      if(profit>=0) curMult=1.0;
      else curMult = MathMin(curMult*InpMartMult, InpMaxMult);
      break;
   }
}

bool HasOpenPosition()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
      if(PositionGetSymbol(i)==_Symbol && PositionGetInteger(POSITION_MAGIC)==InpMagic) return true;
   return false;
}

void ManageOpenPosition()
{
   if(!HasOpenPosition()) { barsInTrade=0; return; }
   barsInTrade++;
   // Opposite signal exit is handled by closing when new opposite signal appears
   // Fallback max bars
   if(barsInTrade >= InpHoldBars*3)
   {
      for(int i=PositionsTotal()-1; i>=0; i--)
      {
         ulong ticket=PositionGetTicket(i);
         if(PositionSelectByTicket(ticket) && PositionGetString(POSITION_SYMBOL)==_Symbol && PositionGetInteger(POSITION_MAGIC)==InpMagic)
         {
            trade.PositionClose(ticket);
            barsInTrade=0;
            return;
         }
      }
   }
}

void OnTick()
{
   datetime t[];
   if(CopyTime(_Symbol,PERIOD_CURRENT,0,1,t)<1) return;
   bool isNewBar = (t[0]!=lastBarTime);
   if(isNewBar) lastBarTime=t[0];

   ManageOpenPosition();
   if(!isNewBar) return;

   static bool first=true;
   if(!first) UpdateMartingaleFromHistory();
   first=false;

   double smaF[3], smaS[3], atr[2];
   if(!CopyBuf(handleSmaF,0,0,3,smaF)) return;
   if(!CopyBuf(handleSmaS,0,0,3,smaS)) return;
   if(!CopyBuf(handleATR,0,0,2,atr)) return;

   bool crossUp = (smaF[1]>smaS[1] && smaF[2]<=smaS[2]);
   bool crossDn = (smaF[1]<smaS[1] && smaF[2]>=smaS[2]);

   bool longSig = crossUp;
   bool shortSig = crossDn;
   if(InpDirection==1) shortSig=false;
   if(InpDirection==2) longSig=false;

   // If opposite signal and we have a position → close first
   if(HasOpenPosition())
   {
      for(int i=PositionsTotal()-1; i>=0; i--)
      {
         ulong ticket=PositionGetTicket(i);
         if(!PositionSelectByTicket(ticket)) continue;
         if(PositionGetString(POSITION_SYMBOL)!=_Symbol || PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
         long type = PositionGetInteger(POSITION_TYPE);
         if((type==POSITION_TYPE_BUY && shortSig) || (type==POSITION_TYPE_SELL && longSig))
         {
            trade.PositionClose(ticket);
            barsInTrade=0;
         }
      }
      if(HasOpenPosition()) return;
   }

   double risk = InpBaseRiskMoney * curMult;
   double lot  = CalcLot(risk, atr[1]);
   if(lot<=0) return;

   double protect = atr[1]*InpProtectATR;
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);

   if(shortSig)
   {
      double sl = ask + protect;
      if(trade.Sell(lot,_Symbol,bid,sl,0,"HF2 Short"))
         barsInTrade=0;
   }
   else if(longSig)
   {
      double sl = bid - protect;
      if(trade.Buy(lot,_Symbol,ask,sl,0,"HF2 Long"))
         barsInTrade=0;
   }
}
//+------------------------------------------------------------------+
