//+------------------------------------------------------------------+
//| Champion_4334.mq5                                                |
//| 6-chart benchmark implementation                                 |
//| Strategy parameters supplied by the research summary             |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"

#include <Trade/Trade.mqh>
CTrade trade;

input double Lots               = 0.01;
input double ScoreThreshold     = 2.144;
input double TP_ATR_Multiple    = 2.5;
input double SL_ATR_Multiple    = 1.0;
input int    ATR_Period         = 14;
input int    HoldBars           = 8;
input int    MaxTradesPerDay    = 10;
input ulong  MagicNumber        = 4334;
input bool   AllowBuy           = true;
input bool   AllowSell          = true;

datetime lastBar = 0;
int atrHandle = INVALID_HANDLE;

struct PositionInfo
{
   ulong ticket;
   datetime open_time;
};

int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   atrHandle = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);
   if(atrHandle == INVALID_HANDLE)
      return INIT_FAILED;
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(atrHandle != INVALID_HANDLE)
      IndicatorRelease(atrHandle);
}

bool NewBar()
{
   datetime t = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(t == 0 || t == lastBar) return false;
   lastBar = t;
   return true;
}

int TradesToday()
{
   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);
   now.hour=0; now.min=0; now.sec=0;
   datetime dayStart=StructToTime(now);

   int count=0;
   if(!HistorySelect(dayStart, TimeCurrent()))
      return 0;

   int deals=HistoryDealsTotal();
   for(int i=0;i<deals;i++)
   {
      ulong deal=HistoryDealGetTicket(i);
      if(deal==0) continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL)!=_Symbol) continue;
      if((ulong)HistoryDealGetInteger(deal, DEAL_MAGIC)!=MagicNumber) continue;
      if(HistoryDealGetInteger(deal, DEAL_ENTRY)==DEAL_ENTRY_IN)
         count++;
   }
   return count;
}

double ATR()
{
   double b[];
   ArraySetAsSeries(b,true);
   if(CopyBuffer(atrHandle,0,1,1,b)!=1) return 0;
   return b[0];
}

// A transparent, deterministic approximation of the research score:
// normalized directional body + short/medium momentum + candle-position.
// This is intentionally parameterized so the exact research formula can
// be replaced without changing the execution/risk engine.
double Score()
{
   double o1=iOpen(_Symbol,PERIOD_CURRENT,1);
   double h1=iHigh(_Symbol,PERIOD_CURRENT,1);
   double l1=iLow(_Symbol,PERIOD_CURRENT,1);
   double c1=iClose(_Symbol,PERIOD_CURRENT,1);
   double o2=iOpen(_Symbol,PERIOD_CURRENT,2);
   double c2=iClose(_Symbol,PERIOD_CURRENT,2);
   double o3=iOpen(_Symbol,PERIOD_CURRENT,3);
   double c3=iClose(_Symbol,PERIOD_CURRENT,3);

   double a=ATR();
   if(a<=0) return 0;

   double body=(c1-o1)/a;
   double mom=((c1-c2)+(c2-c3))/a;
   double range=h1-l1;
   double pos=(range>0)?(2.0*(c1-l1)/range-1.0):0.0;

   // Weighted directional score.
   return 1.00*body + 0.75*mom + 0.394*pos;
}

void OpenTrade(ENUM_ORDER_TYPE type)
{
   double a=ATR();
   if(a<=0) return;

   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   int digits=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);

   if(type==ORDER_TYPE_BUY)
   {
      double sl=NormalizeDouble(ask-SL_ATR_Multiple*a,digits);
      double tp=NormalizeDouble(ask+TP_ATR_Multiple*a,digits);
      trade.Buy(Lots,_Symbol,0,sl,tp,"4334");
   }
   else
   {
      double sl=NormalizeDouble(bid+SL_ATR_Multiple*a,digits);
      double tp=NormalizeDouble(bid-TP_ATR_Multiple*a,digits);
      trade.Sell(Lots,_Symbol,0,sl,tp,"4334");
   }
}

void ManageTimeExit()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;

      datetime opened=(datetime)PositionGetInteger(POSITION_TIME);
      int bars=iBarShift(_Symbol,PERIOD_CURRENT,opened,false);
      if(bars>=HoldBars)
         trade.PositionClose(ticket);
   }
}

void OnTick()
{
   ManageTimeExit();

   if(!NewBar()) return;
   if(TradesToday()>=MaxTradesPerDay) return;

   double s=Score();

   if(s>=ScoreThreshold && AllowBuy)
      OpenTrade(ORDER_TYPE_BUY);
   else if(s<=-ScoreThreshold && AllowSell)
      OpenTrade(ORDER_TYPE_SELL);
}
