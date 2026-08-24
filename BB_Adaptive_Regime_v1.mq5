//+------------------------------------------------------------------+
//| BB_Adaptive_Regime_v1.mq5                                        |
//| Bollinger Band + ADX/RSI regime-filter strategy                  |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"

#include <Trade/Trade.mqh>
CTrade trade;

input double Lots              = 0.01;
input int    BB_Period         = 20;
input double BB_Deviation      = 2.0;
input int    RSI_Period        = 14;
input double RSI_BuyLevel      = 30.0;
input double RSI_SellLevel     = 70.0;
input int    ADX_Period        = 14;
input double MaxADXForMR       = 25.0;
input int    ATR_Period        = 14;
input double SL_ATR            = 1.5;
input double TP_ATR            = 2.0;
input double MaxSpreadPoints   = 100.0;
input long   MagicNumber       = 26082026;
input bool   UseTrendFilter    = true;
input int    TrendMAPeriod     = 100;

int bbHandle, rsiHandle, adxHandle, atrHandle, maHandle;
datetime lastBar = 0;

bool NewBar()
{
   datetime t = iTime(_Symbol, _Period, 0);
   if(t != lastBar)
   {
      lastBar = t;
      return true;
   }
   return false;
}

bool HasPosition()
{
   return PositionSelect(_Symbol);
}

int OnInit()
{
   bbHandle  = iBands(_Symbol, _Period, BB_Period, 0, BB_Deviation, PRICE_CLOSE);
   rsiHandle = iRSI(_Symbol, _Period, RSI_Period, PRICE_CLOSE);
   adxHandle = iADX(_Symbol, _Period, ADX_Period);
   atrHandle = iATR(_Symbol, _Period, ATR_Period);
   maHandle  = iMA(_Symbol, _Period, TrendMAPeriod, 0, MODE_EMA, PRICE_CLOSE);

   if(bbHandle == INVALID_HANDLE || rsiHandle == INVALID_HANDLE ||
      adxHandle == INVALID_HANDLE || atrHandle == INVALID_HANDLE ||
      maHandle == INVALID_HANDLE)
      return INIT_FAILED;

   trade.SetExpertMagicNumber(MagicNumber);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   IndicatorRelease(bbHandle);
   IndicatorRelease(rsiHandle);
   IndicatorRelease(adxHandle);
   IndicatorRelease(atrHandle);
   IndicatorRelease(maHandle);
}

void OnTick()
{
   if(!NewBar()) return;
   if(HasPosition()) return;

   double spread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) -
                    SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;
   if(spread > MaxSpreadPoints) return;

   double upper[3], middle[3], lower[3];
   double rsi[3], adx[3], atr[3], ma[3];

   ArraySetAsSeries(upper,true);
   ArraySetAsSeries(middle,true);
   ArraySetAsSeries(lower,true);
   ArraySetAsSeries(rsi,true);
   ArraySetAsSeries(adx,true);
   ArraySetAsSeries(atr,true);
   ArraySetAsSeries(ma,true);

   if(CopyBuffer(bbHandle,0,0,3,upper) < 3) return;
   if(CopyBuffer(bbHandle,1,0,3,middle) < 3) return;
   if(CopyBuffer(bbHandle,2,0,3,lower) < 3) return;
   if(CopyBuffer(rsiHandle,0,0,3,rsi) < 3) return;
   if(CopyBuffer(adxHandle,0,0,3,adx) < 3) return;
   if(CopyBuffer(atrHandle,0,0,3,atr) < 3) return;
   if(CopyBuffer(maHandle,0,0,3,ma) < 3) return;

   double close1 = iClose(_Symbol,_Period,1);

   // Mean-reversion regime: avoid strong trends.
   if(adx[1] > MaxADXForMR) return;

   bool longSignal  = close1 <= lower[1] && rsi[1] <= RSI_BuyLevel;
   bool shortSignal = close1 >= upper[1] && rsi[1] >= RSI_SellLevel;

   // Optional broad directional filter.
   if(UseTrendFilter)
   {
      longSignal  = longSignal  && close1 >= ma[1];
      shortSignal = shortSignal && close1 <= ma[1];
   }

   double ask = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol,SYMBOL_BID);

   if(longSignal)
   {
      double sl = ask - atr[1] * SL_ATR;
      double tp = ask + atr[1] * TP_ATR;
      trade.Buy(Lots,_Symbol,ask,sl,tp,"BB_MR_LONG");
   }
   else if(shortSignal)
   {
      double sl = bid + atr[1] * SL_ATR;
      double tp = bid - atr[1] * TP_ATR;
      trade.Sell(Lots,_Symbol,bid,sl,tp,"BB_MR_SHORT");
   }
}
