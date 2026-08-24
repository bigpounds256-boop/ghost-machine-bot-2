//+------------------------------------------------------------------+
//| Aggressive Grid Bot - XAUUSD                                    |
//| Range: 4544.035 - 4742.535 | 50 levels | 0.01 lots/level        |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "Aggressive Grid EA with Smart Protection/news windows."

#include <Trade/Trade.mqh>
CTrade trade;

//---- Grid settings
input double InpHighPrice        = 4742.535;
input double InpLowPrice         = 4544.035;
input int    InpGridLevels       = 50;
input double InpLotsPerLevel     = 0.01;

//---- Direction
enum GridDirection { BUY_GRID=0, SELL_GRID=1, BOTH_GRID=2 };
input GridDirection InpDirection = BOTH_GRID;

//---- Smart Protection
input bool InpSmartProtection    = true;

// News filters require MT5 Economic Calendar.
// These are enabled by default.
input bool InpHighImpactNews     = true;
input int  InpHighBeforeMin      = 10;
input int  InpHighAfterMin       = 40;

input bool InpMediumImpactNews   = true;
input int  InpMediumBeforeMin    = 5;
input int  InpMediumAfterMin     = 20;

// General no-trade window around detected news
input bool InpNoTradeWindow      = true;
input int  InpNoTradeBeforeMin   = 30;
input int  InpNoTradeAfterMin    = 30;

//---- Execution
input ulong InpMagic             = 8242026;
input int   InpDeviationPoints   = 50;
input bool  InpUsePendingOrders  = true;
input bool  InpDeleteOutsideGrid = true;

double g_step = 0.0;
datetime g_lastNewsCheck = 0;
bool g_newsBlocked = false;

//+------------------------------------------------------------------+
int OnInit()
{
   if(InpGridLevels < 2)
   {
      Print("ERROR: Grid levels must be >= 2.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpHighPrice <= InpLowPrice)
   {
      Print("ERROR: High price must be above low price.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpLotsPerLevel <= 0)
   {
      Print("ERROR: Lots per level must be > 0.");
      return INIT_PARAMETERS_INCORRECT;
   }

   g_step = (InpHighPrice - InpLowPrice) / (double)(InpGridLevels - 1);

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpDeviationPoints);

   Print("Aggressive Grid Bot initialized.");
   PrintFormat("Range %.3f -> %.3f | Levels %d | Step %.5f | Lots %.2f",
               InpLowPrice, InpHighPrice, InpGridLevels, g_step, InpLotsPerLevel);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnTick()
{
   if(!TradingAllowed())
      return;

   UpdateNewsState();

   // Do not add new grid orders during protection.
   if(InpSmartProtection && g_newsBlocked)
      return;

   if(InpUsePendingOrders)
      MaintainPendingGrid();
   else
      MaintainMarketGrid();

   if(InpDeleteOutsideGrid)
      RemoveOutOfRangePendingOrders();
}

//+------------------------------------------------------------------+
bool TradingAllowed()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return false;

   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
      return false;

   return true;
}

//+------------------------------------------------------------------+
//| MT5 Economic Calendar based protection                            |
//+------------------------------------------------------------------+
void UpdateNewsState()
{
   if(!InpSmartProtection)
   {
      g_newsBlocked = false;
      return;
   }

   datetime now = TimeTradeServer();
   if(now == 0)
      now = TimeCurrent();

   // Avoid expensive calendar scans on every tick.
   if(g_lastNewsCheck != 0 && (now - g_lastNewsCheck) < 30)
      return;

   g_lastNewsCheck = now;
   g_newsBlocked = false;

   MqlCalendarValue values[];
   datetime from = now - 3600;
   datetime to   = now + 3600;

   int count = CalendarValueHistory(values, from, to);
   if(count <= 0)
      return;

   string currency = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);
   if(currency == "")
      currency = "USD";

   for(int i=0; i<count; i++)
   {
      MqlCalendarEvent ev;
      if(!CalendarEventById(values[i].event_id, ev))
         continue;

      // Restrict to events whose currency is relevant to the traded symbol.
      if(ev.currency != currency && ev.currency != "USD")
         continue;

      ENUM_CALENDAR_EVENT_IMPORTANCE imp = ev.importance;
      if(imp == CALENDAR_IMPORTANCE_HIGH && !InpHighImpactNews)
         continue;
      if(imp == CALENDAR_IMPORTANCE_MODERATE && !InpMediumImpactNews)
         continue;
      if(imp != CALENDAR_IMPORTANCE_HIGH && imp != CALENDAR_IMPORTANCE_MODERATE)
         continue;

      datetime eventTime = values[i].time;
      int before = InpNoTradeBeforeMin;
      int after  = InpNoTradeAfterMin;

      if(imp == CALENDAR_IMPORTANCE_HIGH)
      {
         before = MathMax(before, InpHighBeforeMin);
         after  = MathMax(after, InpHighAfterMin);
      }
      else if(imp == CALENDAR_IMPORTANCE_MODERATE)
      {
         before = MathMax(before, InpMediumBeforeMin);
         after  = MathMax(after, InpMediumAfterMin);
      }

      if(!InpNoTradeWindow)
      {
         if(imp == CALENDAR_IMPORTANCE_HIGH)
         {
            before = InpHighBeforeMin;
            after  = InpHighAfterMin;
         }
         else
         {
            before = InpMediumBeforeMin;
            after  = InpMediumAfterMin;
         }
      }

      datetime startBlock = eventTime - before * 60;
      datetime endBlock   = eventTime + after * 60;

      if(now >= startBlock && now <= endBlock)
      {
         g_newsBlocked = true;
         PrintFormat("SMART PROTECTION: New orders blocked around news event at %s",
                     TimeToString(eventTime, TIME_DATE|TIME_MINUTES));
         return;
      }
   }
}

//+------------------------------------------------------------------+
//| Pending grid                                                      |
//| Buy grid uses Buy Limit below market and Buy Stop above market.   |
//| Sell grid uses Sell Stop below market and Sell Limit above.       |
//+------------------------------------------------------------------+
void MaintainPendingGrid()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   for(int i=0; i<InpGridLevels; i++)
   {
      double price = NormalizeDouble(InpLowPrice + i*g_step, _Digits);

      if(price < InpLowPrice - _Point || price > InpHighPrice + _Point)
         continue;

      if(InpDirection == BUY_GRID || InpDirection == BOTH_GRID)
      {
         if(price < bid)
            EnsurePending(ORDER_TYPE_BUY_LIMIT, price);
         else if(price > ask)
            EnsurePending(ORDER_TYPE_BUY_STOP, price);
      }

      if(InpDirection == SELL_GRID || InpDirection == BOTH_GRID)
      {
         if(price < bid)
            EnsurePending(ORDER_TYPE_SELL_STOP, price);
         else if(price > ask)
            EnsurePending(ORDER_TYPE_SELL_LIMIT, price);
      }
   }
}

//+------------------------------------------------------------------+
void EnsurePending(ENUM_ORDER_TYPE type, double price)
{
   if(HasOrderAtLevel(type, price))
      return;

   double vol = NormalizeVolume(InpLotsPerLevel);
   if(vol <= 0)
      return;

   string comment = StringFormat("AGGRID %.3f", price);

   bool ok = false;
   if(type == ORDER_TYPE_BUY_LIMIT)
      ok = trade.BuyLimit(vol, price, _Symbol, 0, 0, ORDER_TIME_GTC, 0, comment);
   else if(type == ORDER_TYPE_BUY_STOP)
      ok = trade.BuyStop(vol, price, _Symbol, 0, 0, ORDER_TIME_GTC, 0, comment);
   else if(type == ORDER_TYPE_SELL_LIMIT)
      ok = trade.SellLimit(vol, price, _Symbol, 0, 0, ORDER_TIME_GTC, 0, comment);
   else if(type == ORDER_TYPE_SELL_STOP)
      ok = trade.SellStop(vol, price, _Symbol, 0, 0, ORDER_TIME_GTC, 0, comment);

   if(!ok)
      PrintFormat("Order failed at %.3f. Retcode=%u %s",
                  price, trade.ResultRetcode(), trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
bool HasOrderAtLevel(ENUM_ORDER_TYPE type, double price)
{
   double tolerance = MathMax(_Point*2.0, g_step*0.02);

   for(int i=OrdersTotal()-1; i>=0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;

      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;

      if((ulong)OrderGetInteger(ORDER_MAGIC) != InpMagic)
         continue;

      ENUM_ORDER_TYPE ot = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(ot != type)
         continue;

      double op = OrderGetDouble(ORDER_PRICE_OPEN);
      if(MathAbs(op-price) <= tolerance)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
void RemoveOutOfRangePendingOrders()
{
   for(int i=OrdersTotal()-1; i>=0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;

      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;

      if((ulong)OrderGetInteger(ORDER_MAGIC) != InpMagic)
         continue;

      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type != ORDER_TYPE_BUY_LIMIT && type != ORDER_TYPE_BUY_STOP &&
         type != ORDER_TYPE_SELL_LIMIT && type != ORDER_TYPE_SELL_STOP)
         continue;

      double p = OrderGetDouble(ORDER_PRICE_OPEN);
      if(p < InpLowPrice-_Point || p > InpHighPrice+_Point)
      {
         if(!trade.OrderDelete(ticket))
            PrintFormat("Failed deleting out-of-range order %I64u: %s",
                        ticket, trade.ResultRetcodeDescription());
      }
   }
}

//+------------------------------------------------------------------+
//| Optional market-grid mode                                        |
//| Opens one 0.01 lot position when price crosses a grid level.      |
//+------------------------------------------------------------------+
void MaintainMarketGrid()
{
   static double lastBid = 0.0;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(lastBid == 0.0)
   {
      lastBid = bid;
      return;
   }

   if(bid < InpLowPrice || bid > InpHighPrice)
   {
      lastBid = bid;
      return;
   }

   int oldLevel = PriceToLevel(lastBid);
   int newLevel = PriceToLevel(bid);

   if(oldLevel != newLevel)
   {
      int stepDir = (newLevel > oldLevel) ? 1 : -1;
      int level = newLevel;

      double p = NormalizeDouble(InpLowPrice + level*g_step, _Digits);

      if(stepDir > 0)
      {
         if(InpDirection == BUY_GRID || InpDirection == BOTH_GRID)
            OpenBuyIfMissing(p);
         if(InpDirection == SELL_GRID || InpDirection == BOTH_GRID)
            OpenSellIfMissing(p);
      }
      else
      {
         if(InpDirection == BUY_GRID || InpDirection == BOTH_GRID)
            OpenBuyIfMissing(p);
         if(InpDirection == SELL_GRID || InpDirection == BOTH_GRID)
            OpenSellIfMissing(p);
      }
   }

   lastBid = bid;
}

//+------------------------------------------------------------------+
int PriceToLevel(double price)
{
   int level = (int)MathRound((price-InpLowPrice)/g_step);
   return MathMax(0, MathMin(InpGridLevels-1, level));
}

//+------------------------------------------------------------------+
void OpenBuyIfMissing(double levelPrice)
{
   if(HasPositionAtLevel(POSITION_TYPE_BUY, levelPrice))
      return;

   double vol = NormalizeVolume(InpLotsPerLevel);
   if(vol > 0 && !trade.Buy(vol, _Symbol, 0, 0, 0, "AGGRID BUY"))
      PrintFormat("Market BUY failed: %s", trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
void OpenSellIfMissing(double levelPrice)
{
   if(HasPositionAtLevel(POSITION_TYPE_SELL, levelPrice))
      return;

   double vol = NormalizeVolume(InpLotsPerLevel);
   if(vol > 0 && !trade.Sell(vol, _Symbol, 0, 0, 0, "AGGRID SELL"))
      PrintFormat("Market SELL failed: %s", trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
bool HasPositionAtLevel(ENUM_POSITION_TYPE type, double levelPrice)
{
   double tolerance = MathMax(_Point*5.0, g_step*0.15);

   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;

      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type)
         continue;

      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      if(MathAbs(open-levelPrice) <= tolerance)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
double NormalizeVolume(double lots)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(step <= 0)
      step = 0.01;

   lots = MathMax(minLot, MathMin(maxLot, lots));
   lots = MathFloor(lots/step + 1e-8)*step;

   int digits = 2;
   if(step < 0.01) digits = 3;
   if(step < 0.001) digits = 4;

   return NormalizeDouble(lots, digits);
}
//+------------------------------------------------------------------+
