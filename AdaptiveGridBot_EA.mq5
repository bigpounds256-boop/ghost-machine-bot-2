//+------------------------------------------------------------------+
//| AdaptiveGridBot_EA.mq5                                           |
//| Adaptive version of the supplied TradingView Grid Bot concept   |
//+------------------------------------------------------------------+
#property strict
#property version "2.00"
#property description "Adaptive grid EA based on the original Grid Bot principle."

#include <Trade/Trade.mqh>
CTrade trade;

//========================= CORE SETTINGS ============================//
input int    GridCount              = 10;
input int    RangeLookback          = 200;   // bars used to discover the trading range
input int    ATRPeriod              = 14;
input double ATRBufferMultiplier    = 0.50;  // expands discovered range
input double MinRangeATR            = 6.0;   // minimum range width in ATRs
input double MaxRangeATR            = 20.0;  // maximum range width in ATRs
input bool   RecalculateRange       = true;
input int    RangeRefreshBars       = 20;

input string DirectionMode          = "auto"; // auto, up, neutral, down
input int    TrendLookback          = 50;
input double TrendThresholdATR      = 1.0;

input bool   UseHighLowSignals      = true;
input bool   AvoidDuplicateLevel    = true;
input bool   OnlyOnePosition        = false;
input bool   OneTradePerBar         = true;

input double Lots                   = 0.01;
input double RiskPercent            = 0.0;   // 0 = fixed Lots
input int    StopLossATR            = 0;     // 0 = no SL; otherwise ATR multiples
input double TakeProfitGridMultiple = 1.0;   // TP measured in grid intervals; 0 = no TP

input ulong  MagicNumber            = 26082026;
input int    MaxSpreadPoints        = 0;     // 0 = disabled

input bool   DrawAdaptiveGrid       = true;
input bool   DrawRange              = true;

//========================= STATE ====================================//
double UpperLimit = 0.0;
double LowerLimit = 0.0;
double GridInterval = 0.0;
double SignalLine = 0.0;

int LastSignal = 0;
int LastSignalIndex = 0;
int BarsSinceRangeUpdate = 999999;
datetime LastBarTime = 0;

int atrHandle = INVALID_HANDLE;

//========================= HELPERS ==================================//
double GetATR(int shift=1)
{
   if(atrHandle == INVALID_HANDLE) return 0.0;

   double b[];
   ArraySetAsSeries(b,true);

   if(CopyBuffer(atrHandle,0,shift,1,b) != 1)
      return 0.0;

   return b[0];
}

double NormalizeVolume(double volume)
{
   double minLot = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);

   volume = MathMax(minLot,MathMin(maxLot,volume));

   if(step > 0)
      volume = MathFloor(volume/step)*step;

   int digits=2;
   if(step==1.0) digits=0;
   else if(step==0.1) digits=1;
   else if(step==0.01) digits=2;

   return NormalizeDouble(volume,digits);
}

double CalculateLots(double slDistance)
{
   if(RiskPercent <= 0.0 || slDistance <= 0.0)
      return NormalizeVolume(Lots);

   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney=equity*RiskPercent/100.0;

   double tickSize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   double tickValue=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);

   if(tickSize<=0 || tickValue<=0)
      return NormalizeVolume(Lots);

   double lossPerLot=(slDistance/tickSize)*tickValue;
   if(lossPerLot<=0)
      return NormalizeVolume(Lots);

   return NormalizeVolume(riskMoney/lossPerLot);
}

bool SpreadOK()
{
   if(MaxSpreadPoints<=0) return true;

   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);

   return ((ask-bid)/_Point <= MaxSpreadPoints);
}

bool HasOurPosition()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;

      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL)==_Symbol &&
            (ulong)PositionGetInteger(POSITION_MAGIC)==MagicNumber)
            return true;
      }
   }
   return false;
}

double GridValue(int index)
{
   return LowerLimit + GridInterval*index;
}

//========================= ADAPTIVE RANGE ============================//
// The original Pine script uses manually selected UpperLimit/LowerLimit.
// This EA replaces those fixed numbers with a market-derived range.
//
// Principle:
// 1. Find recent structural high/low.
// 2. Measure volatility using ATR.
// 3. Add an ATR buffer so normal noise does not immediately break the range.
// 4. Prevent an absurdly narrow/wide grid by constraining range width in ATRs.
bool BuildAdaptiveRange()
{
   if(Bars(_Symbol,_Period) < RangeLookback+TrendLookback+20)
      return false;

   double highs[], lows[];
   ArraySetAsSeries(highs,true);
   ArraySetAsSeries(lows,true);

   int copiedH=CopyHigh(_Symbol,_Period,1,RangeLookback,highs);
   int copiedL=CopyLow(_Symbol,_Period,1,RangeLookback,lows);

   if(copiedH<RangeLookback || copiedL<RangeLookback)
      return false;

   double swingHigh=highs[0];
   double swingLow =lows[0];

   for(int i=1;i<RangeLookback;i++)
   {
      if(highs[i]>swingHigh) swingHigh=highs[i];
      if(lows[i] <swingLow)  swingLow =lows[i];
   }

   double atr=GetATR(1);
   if(atr<=0) return false;

   double buffer=atr*ATRBufferMultiplier;

   double discoveredHigh=swingHigh+buffer;
   double discoveredLow =swingLow-buffer;

   double width=discoveredHigh-discoveredLow;

   double minWidth=atr*MinRangeATR;
   double maxWidth=atr*MaxRangeATR;

   if(width<minWidth)
   {
      double mid=(discoveredHigh+discoveredLow)/2.0;
      discoveredHigh=mid+minWidth/2.0;
      discoveredLow =mid-minWidth/2.0;
   }
   else if(width>maxWidth)
   {
      // Keep the range centered around current price while avoiding
      // an excessively huge grid.
      double mid=iClose(_Symbol,_Period,1);
      discoveredHigh=mid+maxWidth/2.0;
      discoveredLow =mid-maxWidth/2.0;
   }

   // Keep the current market inside the discovered grid whenever possible.
   double price=iClose(_Symbol,_Period,1);

   if(price>discoveredHigh)
   {
      discoveredHigh=price+buffer;
      discoveredLow=discoveredHigh-maxWidth;
   }
   if(price<discoveredLow)
   {
      discoveredLow=price-buffer;
      discoveredHigh=discoveredLow+maxWidth;
   }

   UpperLimit=NormalizeDouble(discoveredHigh,_Digits);
   LowerLimit=NormalizeDouble(discoveredLow,_Digits);

   GridInterval=(UpperLimit-LowerLimit)/(double)(GridCount-1);

   if(GridInterval<=0)
      return false;

   // If the old signal is outside the new grid, reset it.
   if(SignalLine<LowerLimit || SignalLine>UpperLimit)
   {
      SignalLine=0.0;
      LastSignal=0;
      LastSignalIndex=0;
   }

   return true;
}

//========================= TREND/DIRECTION ==========================//
int GetDirection()
{
   if(DirectionMode=="up") return 1;
   if(DirectionMode=="down") return -1;
   if(DirectionMode=="neutral") return 0;

   // AUTO: compare current price with price TrendLookback bars ago.
   double atr=GetATR(1);
   if(atr<=0) return 0;

   double now=iClose(_Symbol,_Period,1);
   double old=iClose(_Symbol,_Period,TrendLookback);

   double displacement=now-old;

   if(displacement > atr*TrendThresholdATR)
      return 1;

   if(displacement < -atr*TrendThresholdATR)
      return -1;

   return 0;
}

//========================= GRID SIGNALS ==============================//
int GetBuyIndex(double previousClose,double currentLow)
{
   int idx=0;

   for(int x=0;x<GridCount;x++)
   {
      double g=GridValue(x);

      if(UseHighLowSignals)
      {
         double previousHigh=iHigh(_Symbol,_Period,1);

         if(previousHigh>g && currentLow<=g)
            idx=x;
      }
      else
      {
         double currentClose=iClose(_Symbol,_Period,0);

         if(previousClose>g && currentClose<=g)
            idx=x;
      }
   }

   return idx;
}

int GetSellIndex(double previousClose,double currentHigh)
{
   int idx=0;

   for(int x=0;x<GridCount;x++)
   {
      double g=GridValue(x);

      if(UseHighLowSignals)
      {
         double previousLow=iLow(_Symbol,_Period,1);

         if(previousLow<g && currentHigh>=g)
            idx=x;
      }
      else
      {
         double currentClose=iClose(_Symbol,_Period,0);

         if(previousClose<g && currentClose>=g)
            idx=x;
      }
   }

   return idx;
}

//========================= DRAWING ==================================//
void DrawLine(string name,double price,color clr,int width=1)
{
   ObjectDelete(0,name);

   if(!ObjectCreate(0,name,OBJ_HLINE,0,0,price))
      return;

   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,name,OBJPROP_WIDTH,width);
   ObjectSetInteger(0,name,OBJPROP_STYLE,STYLE_DOT);
}

void DrawAdaptiveLevels()
{
   if(!DrawAdaptiveGrid) return;

   for(int i=0;i<GridCount;i++)
   {
      string name="AdaptiveGrid_"+IntegerToString(i);
      DrawLine(name,GridValue(i),clrSilver,1);
   }

   if(DrawRange)
   {
      DrawLine("AdaptiveUpper",UpperLimit,clrRed,2);
      DrawLine("AdaptiveLower",LowerLimit,clrGreen,2);
   }

   ChartRedraw();
}

//========================= EXECUTION ================================//
void OpenBuy()
{
   if(!SpreadOK()) return;
   if(OnlyOnePosition && HasOurPosition()) return;

   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double atr=GetATR(1);

   double sl=0.0,tp=0.0;
   double slDistance=0.0;

   if(StopLossATR>0 && atr>0)
   {
      slDistance=atr*StopLossATR;
      sl=NormalizeDouble(ask-slDistance,_Digits);
   }

   if(TakeProfitGridMultiple>0)
      tp=NormalizeDouble(ask+GridInterval*TakeProfitGridMultiple,_Digits);

   double volume=CalculateLots(slDistance);

   trade.SetExpertMagicNumber(MagicNumber);
   trade.Buy(volume,_Symbol,0.0,sl,tp,"Adaptive Grid Buy");
}

void OpenSell()
{
   if(!SpreadOK()) return;
   if(OnlyOnePosition && HasOurPosition()) return;

   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double atr=GetATR(1);

   double sl=0.0,tp=0.0;
   double slDistance=0.0;

   if(StopLossATR>0 && atr>0)
   {
      slDistance=atr*StopLossATR;
      sl=NormalizeDouble(bid+slDistance,_Digits);
   }

   if(TakeProfitGridMultiple>0)
      tp=NormalizeDouble(bid-GridInterval*TakeProfitGridMultiple,_Digits);

   double volume=CalculateLots(slDistance);

   trade.SetExpertMagicNumber(MagicNumber);
   trade.Sell(volume,_Symbol,0.0,sl,tp,"Adaptive Grid Sell");
}

//========================= MAIN SIGNAL ENGINE =======================//
void ProcessSignals()
{
   if(GridInterval<=0) return;

   double previousClose=iClose(_Symbol,_Period,1);
   double currentClose =iClose(_Symbol,_Period,0);
   double currentLow   =iLow(_Symbol,_Period,0);
   double currentHigh  =iHigh(_Symbol,_Period,0);

   int buyIndex =GetBuyIndex(previousClose,currentLow);
   int sellIndex=GetSellIndex(previousClose,currentHigh);

   bool buy =(buyIndex>0);
   bool sell=(sellIndex>0);

   double previousSignalLine=SignalLine;

   // Same core principle as the supplied Pine:
   // avoid repeatedly trading around the same grid level.
   if(AvoidDuplicateLevel && previousSignalLine!=0.0)
   {
      if(UseHighLowSignals)
      {
         if(currentLow>=previousSignalLine-GridInterval)
            buy=false;

         if(currentHigh<=previousSignalLine+GridInterval)
            sell=false;
      }
      else
      {
         if(currentClose>=previousSignalLine-GridInterval)
            buy=false;

         if(currentClose<=previousSignalLine+GridInterval)
            sell=false;
      }
   }

   // Don't trade outside the adaptive range.
   if(currentClose>=UpperLimit) buy=false;
   if(currentClose< LowerLimit) buy=false;
   if(currentClose<=LowerLimit) sell=false;
   if(currentClose> UpperLimit) sell=false;

   // Automatic directional regime filter.
   int direction=GetDirection();

   if(direction==-1 && previousSignalLine!=0.0 &&
      currentLow>=previousSignalLine-GridInterval*2.0)
      buy=false;

   if(direction==1 && previousSignalLine!=0.0 &&
      currentHigh<=previousSignalLine+GridInterval*2.0)
      sell=false;

   if(buy)
   {
      LastSignal=1;
      LastSignalIndex=buyIndex;
      SignalLine=GridValue(LastSignalIndex);

      OpenBuy();
   }
   else if(sell)
   {
      LastSignal=-1;
      LastSignalIndex=sellIndex;
      SignalLine=GridValue(LastSignalIndex);

      OpenSell();
   }
}

//========================= MT5 EVENTS ===============================//
int OnInit()
{
   if(GridCount<3)
   {
      Print("GridCount must be at least 3.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(RangeLookback<20 || ATRPeriod<2)
   {
      Print("RangeLookback/ATRPeriod settings are too small.");
      return INIT_PARAMETERS_INCORRECT;
   }

   atrHandle=iATR(_Symbol,_Period,ATRPeriod);

   if(atrHandle==INVALID_HANDLE)
   {
      Print("Could not create ATR handle.");
      return INIT_FAILED;
   }

   if(!BuildAdaptiveRange())
      return INIT_FAILED;

   DrawAdaptiveLevels();

   LastBarTime=iTime(_Symbol,_Period,0);

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(atrHandle!=INVALID_HANDLE)
      IndicatorRelease(atrHandle);

   for(int i=0;i<GridCount;i++)
      ObjectDelete(0,"AdaptiveGrid_"+IntegerToString(i));

   ObjectDelete(0,"AdaptiveUpper");
   ObjectDelete(0,"AdaptiveLower");
}

void OnTick()
{
   datetime currentBar=iTime(_Symbol,_Period,0);

   if(OneTradePerBar && currentBar==LastBarTime)
      return;

   if(currentBar!=LastBarTime)
   {
      LastBarTime=currentBar;
      BarsSinceRangeUpdate++;
   }

   if(RecalculateRange && BarsSinceRangeUpdate>=RangeRefreshBars)
   {
      if(BuildAdaptiveRange())
      {
         DrawAdaptiveLevels();
         BarsSinceRangeUpdate=0;
      }
   }

   ProcessSignals();
}
