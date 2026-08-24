//+------------------------------------------------------------------+
//| Automatic Grid Bot - MT5 EA                                     |
//| Based on "AUTOMATIC GRID BOT STRATEGY [lovealgotrading]"         |
//| Core logic: 20-grid, sequential entries, 1-grid TP per entry.   |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>
CTrade trade;

enum TradeDirection
{
   LONG_ONLY = 0,
   SHORT_ONLY = 1,
   BOTH_DIRECTIONS = 2
};

input double InpHighPrice       = 0.0;      // Grid high
input double InpLowPrice        = 0.0;      // Grid low
input TradeDirection InpDirection = BOTH_DIRECTIONS;
input double InpDollarsPerEntry = 100.0;    // Approx USD value per grid entry
input int    InpGridLevels      = 20;       // 10 or 20
input int    InpMagic           = 20260820;
input bool   InpUseStop         = false;
input double InpHighStop        = 0.0;
input double InpLowStop         = 0.0;
input bool   InpCloseAllOnStop  = false;
input int    InpMaxEntries      = 20;
input int    InpSlippagePoints  = 20;

double grid[20];
double step=0.0;
datetime last_bar=0;

//--- Count open positions for this EA/symbol/direction.
int CountPositions(ENUM_POSITION_TYPE type)
{
   int n=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((int)PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE)==type) n++;
   }
   return n;
}

//--- Get volume corresponding to dollars per entry.
double CalcVolume()
{
   double price=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double contract=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_CONTRACT_SIZE);
   double minv=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxv=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double stepv=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);

   if(price<=0 || contract<=0) return minv;

   double vol=InpDollarsPerEntry/(price*contract);
   vol=MathMax(minv,MathMin(maxv,vol));
   if(stepv>0) vol=MathFloor(vol/stepv)*stepv;
   return NormalizeDouble(vol,8);
}

//--- Build evenly spaced grid, high -> low.
void BuildGrid()
{
   step=(InpHighPrice-InpLowPrice)/(InpGridLevels-1);
   for(int i=0;i<InpGridLevels;i++)
      grid[i]=InpHighPrice-step*i;
}

//--- Find the grid zone index nearest to price.
int GridIndex(double price)
{
   if(step<=0) return -1;
   int idx=(int)MathRound((InpHighPrice-price)/step);
   if(idx<0) idx=0;
   if(idx>=InpGridLevels) idx=InpGridLevels-1;
   return idx;
}

//--- Normalize a price to the symbol tick size.
double NormPrice(double p)
{
   double tick=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tick<=0) tick=_Point;
   return NormalizeDouble(MathRound(p/tick)*tick,(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS));
}

//--- Open one long with TP one grid spacing above entry.
bool OpenLong(int level)
{
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double tp=NormPrice(ask+step);
   double vol=CalcVolume();

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);
   return trade.Buy(vol,_Symbol,0.0,0.0,tp,"GRID_LONG_"+IntegerToString(level));
}

//--- Open one short with TP one grid spacing below entry.
bool OpenShort(int level)
{
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double tp=NormPrice(bid-step);
   double vol=CalcVolume();

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);
   return trade.Sell(vol,_Symbol,0.0,0.0,tp,"GRID_SHORT_"+IntegerToString(level));
}

//--- Close all EA positions.
void CloseAll()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if((int)PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      trade.PositionClose(ticket);
   }
}

//--- Stop handling.
bool StopTriggered()
{
   if(!InpUseStop) return false;
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);

   bool hitHigh=(InpHighStop>0 && bid>=InpHighStop);
   bool hitLow =(InpLowStop>0  && ask<=InpLowStop);
   if(hitHigh || hitLow)
   {
      if(InpCloseAllOnStop) CloseAll();
      return true;
   }
   return false;
}

//--- Main grid logic. This follows the source's sequential grid concept.
//    Longs are accumulated from the lower half; shorts from the upper half.
//    A new entry is only added after the prior level is occupied.
void ProcessGrid()
{
   if(InpHighPrice<=InpLowPrice || step<=0) return;
   if(StopTriggered()) return;

   double close=iClose(_Symbol,_Period,0);
   if(close<=0) return;

   int longs=CountPositions(POSITION_TYPE_BUY);
   int shorts=CountPositions(POSITION_TYPE_SELL);

   // Lower-half long ladder.
   if(InpDirection==LONG_ONLY || InpDirection==BOTH_DIRECTIONS)
   {
      int nextLong=longs;
      int maxLong=MathMin(InpGridLevels/2,InpMaxEntries);

      if(nextLong<maxLong)
      {
         int level=InpGridLevels/2 + nextLong;
         if(level>=InpGridLevels-1) level=InpGridLevels-2;
         double trigger=(grid[level]+grid[level+1])/2.0;

         // For 20 grids: level 10->11, 11->12 ... 18->19.
         // Only add the next position after price is below that midpoint.
         if(close<trigger)
            OpenLong(nextLong+1);
      }
   }

   // Upper-half short ladder.
   if(InpDirection==SHORT_ONLY || InpDirection==BOTH_DIRECTIONS)
   {
      int nextShort=shorts;
      int maxShort=MathMin(InpGridLevels/2,InpMaxEntries);

      if(nextShort<maxShort)
      {
         int level=(InpGridLevels/2)-1-nextShort;
         if(level<0) level=0;
         double trigger=(grid[level]+grid[level+1])/2.0;

         if(close>trigger)
            OpenShort(nextShort+1);
      }
   }
}

int OnInit()
{
   if(InpGridLevels!=10 && InpGridLevels!=20)
   {
      Print("InpGridLevels must be 10 or 20.");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpHighPrice<=InpLowPrice)
   {
      Print("Set InpHighPrice greater than InpLowPrice.");
      return INIT_PARAMETERS_INCORRECT;
   }

   BuildGrid();
   trade.SetExpertMagicNumber(InpMagic);
   return INIT_SUCCEEDED;
}

void OnTick()
{
   ProcessGrid();
}
