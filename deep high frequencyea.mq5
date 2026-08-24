//+------------------------------------------------------------------+
//|                                            HighFrequencyEA.mq5    |
//|                                    Copyright 2026, Trading Bot   |
//|                                             https://www.tradingbot|
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Trading Bot"
#property link      "https://www.tradingbot"
#property version   "1.00"

//+------------------------------------------------------------------+
//| Include files                                                    |
//+------------------------------------------------------------------+
#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>
#include <Trade/HistoryOrderInfo.mqh>
#include <Math/Stat/Math.mqh>

//+------------------------------------------------------------------+
//| Input parameters                                                 |
//+------------------------------------------------------------------+
// --- Risk Management ---
input double   InpRiskPerTrade    = 0.5;          // Risk per trade (%)
input double   InpMaxDailyLoss    = 2.0;          // Max daily loss (%)
input double   InpMaxDrawdown     = 5.0;          // Max drawdown (%)
input int      InpMaxPositions    = 3;            // Max concurrent positions
input int      InpMaxDailyTrades  = 150;          // Max daily trades
input double   InpStopLoss        = 0.5;          // Stop Loss (%)
input double   InpTakeProfit      = 1.0;          // Take Profit (%)

// --- Strategy Parameters ---
input int      InpTradeInterval   = 5;            // Trade interval (seconds)
input double   InpSpreadMultiplier = 1.5;         // Spread multiplier for MM
input int      InpOrderBookDepth  = 10;           // Order book depth
input double   InpZScoreThreshold = 2.0;          // Z-score threshold for stat arb
input int      InpCorrelationWindow = 20;         // Correlation window

// --- Symbol Configuration ---
input string   InpSymbols         = "EURUSD,GBPUSD,USDJPY,AUDUSD,USDCAD,NZDUSD"; // Trading symbols
input int      InpMagicNumber     = 20260818;     // EA Magic Number

//+------------------------------------------------------------------+
//| Global variables                                                 |
//+------------------------------------------------------------------+
CTrade trade;
CPositionInfo positionInfo;
CHistoryOrderInfo historyInfo;

string symbols[];
double symbolPrices[];
double symbolBid[];
double symbolAsk[];
double symbolSpread[];

int tradeCount = 0;
int dailyTradeCount = 0;
double dailyPnL = 0;
double totalPnL = 0;
double initialBalance = 0;
datetime lastTradeTime = 0;
datetime dayStart = 0;

// Performance tracking
double winRate = 0;
int winningTrades = 0;
int losingTrades = 0;
double sharpeRatio = 0;
double returns[];

// Market data structures
struct OrderBookLevel
{
   double price;
   double volume;
};

struct SymbolData
{
   string name;
   double bid;
   double ask;
   double spread;
   double midPrice;
   double atr;
   double rsi;
   double bbUpper;
   double bbMiddle;
   double bbLower;
   double sma20;
   double sma50;
   double close[];
   double high[];
   double low[];
   double volume[];
   OrderBookLevel bids[];
   OrderBookLevel asks[];
};

SymbolData symbolData[];

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // Initialize trading object
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   
   // Set initial balance
   initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   dayStart = TimeCurrent();
   
   // Parse symbols
   ParseSymbols(InpSymbols);
   
   // Initialize arrays
   ArrayResize(symbolPrices, ArraySize(symbols));
   ArrayResize(symbolBid, ArraySize(symbols));
   ArrayResize(symbolAsk, ArraySize(symbols));
   ArrayResize(symbolSpread, ArraySize(symbols));
   ArrayResize(symbolData, ArraySize(symbols));
   ArrayResize(returns, 0);
   
   // Load historical data
   for(int i = 0; i < ArraySize(symbols); i++)
   {
      LoadHistoricalData(i);
   }
   
   Print("=== High Frequency EA Initialized ===");
   Print("Trading Symbols: ", InpSymbols);
   Print("Max Daily Trades: ", InpMaxDailyTrades);
   Print("Initial Balance: ", initialBalance);
   Print("=====================================");
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("=== High Frequency EA Stopped ===");
   Print("Total Trades: ", tradeCount);
   Print("Total PnL: ", totalPnL);
   Print("Win Rate: ", winRate * 100, "%");
   Print("=================================");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // Check if it's a new day
   if(TimeCurrent() - dayStart >= 86400)
   {
      ResetDailyStats();
      dayStart = TimeCurrent();
   }
   
   // Check if we should trade
   if(!ShouldTrade())
      return;
   
   // Update market data
   UpdateMarketData();
   
   // Generate and execute signals
   GenerateSignals();
   
   // Update performance metrics
   UpdatePerformance();
   
   // Monitor open positions
   ManagePositions();
}

//+------------------------------------------------------------------+
//| Parse symbols from input string                                  |
//+------------------------------------------------------------------+
void ParseSymbols(string symbolString)
{
   string tempSymbols[];
   int count = StringSplit(symbolString, ',', tempSymbols);
   
   ArrayResize(symbols, count);
   for(int i = 0; i < count; i++)
   {
      symbols[i] = tempSymbols[i];
      Print("Added symbol: ", symbols[i]);
   }
}

//+------------------------------------------------------------------+
//| Check if we should trade                                        |
//+------------------------------------------------------------------+
bool ShouldTrade()
{
   // Check daily trade limit
   if(dailyTradeCount >= InpMaxDailyTrades)
      return false;
   
   // Check max concurrent positions
   if(PositionsTotal() >= InpMaxPositions)
      return false;
   
   // Check daily loss limit
   double dailyLoss = CalculateDailyLoss();
   if(dailyLoss <= -InpMaxDailyLoss)
   {
      Print("Daily loss limit reached: ", dailyLoss, "%");
      return false;
   }
   
   // Check max drawdown
   double drawdown = CalculateDrawdown();
   if(drawdown <= -InpMaxDrawdown)
   {
      Print("Max drawdown reached: ", drawdown, "%");
      return false;
   }
   
   // Check trade interval
   if(TimeCurrent() - lastTradeTime < InpTradeInterval)
      return false;
   
   return true;
}

//+------------------------------------------------------------------+
//| Update market data for all symbols                              |
//+------------------------------------------------------------------+
void UpdateMarketData()
{
   for(int i = 0; i < ArraySize(symbols); i++)
   {
      MqlTick tick;
      if(SymbolInfoTick(symbols[i], tick))
      {
         symbolBid[i] = tick.bid;
         symbolAsk[i] = tick.ask;
         symbolPrices[i] = (tick.bid + tick.ask) / 2;
         symbolSpread[i] = (tick.ask - tick.bid) / tick.bid * 10000;
         
         symbolData[i].bid = tick.bid;
         symbolData[i].ask = tick.ask;
         symbolData[i].midPrice = (tick.bid + tick.ask) / 2;
         symbolData[i].spread = symbolSpread[i];
         
         // Update order book
         UpdateOrderBook(i);
      }
   }
}

//+------------------------------------------------------------------+
//| Update order book for symbol                                    |
//+------------------------------------------------------------------+
void UpdateOrderBook(int index)
{
   MqlBookInfo bookInfo[];
   if(SymbolInfoTick(symbols[index], bookInfo))
   {
      int bidCount = 0, askCount = 0;
      ArrayResize(symbolData[index].bids, 0);
      ArrayResize(symbolData[index].asks, 0);
      
      for(int i = 0; i < ArraySize(bookInfo); i++)
      {
         if(bookInfo[i].type == BOOK_TYPE_SELL && bidCount < InpOrderBookDepth)
         {
            ArrayResize(symbolData[index].bids, bidCount + 1);
            symbolData[index].bids[bidCount].price = bookInfo[i].price;
            symbolData[index].bids[bidCount].volume = bookInfo[i].volume;
            bidCount++;
         }
         else if(bookInfo[i].type == BOOK_TYPE_BUY && askCount < InpOrderBookDepth)
         {
            ArrayResize(symbolData[index].asks, askCount + 1);
            symbolData[index].asks[askCount].price = bookInfo[i].price;
            symbolData[index].asks[askCount].volume = bookInfo[i].volume;
            askCount++;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Load historical data for symbol                                 |
//+------------------------------------------------------------------+
void LoadHistoricalData(int index)
{
   string symbol = symbols[index];
   int bars = iBars(symbol, PERIOD_M1);
   
   if(bars < 100)
      return;
   
   // Copy data
   ArrayResize(symbolData[index].close, bars);
   ArrayResize(symbolData[index].high, bars);
   ArrayResize(symbolData[index].low, bars);
   ArrayResize(symbolData[index].volume, bars);
   
   CopyClose(symbol, PERIOD_M1, 0, bars, symbolData[index].close);
   CopyHigh(symbol, PERIOD_M1, 0, bars, symbolData[index].high);
   CopyLow(symbol, PERIOD_M1, 0, bars, symbolData[index].low);
   CopyTickVolume(symbol, PERIOD_M1, 0, bars, symbolData[index].volume);
   
   // Calculate indicators
   CalculateIndicators(index);
}

//+------------------------------------------------------------------+
//| Calculate technical indicators                                  |
//+------------------------------------------------------------------+
void CalculateIndicators(int index)
{
   string symbol = symbols[index];
   int handle;
   double buffer[];
   
   // RSI
   handle = iRSI(symbol, PERIOD_M1, 14, PRICE_CLOSE);
   if(handle != INVALID_HANDLE)
   {
      CopyBuffer(handle, 0, 0, 1, buffer);
      symbolData[index].rsi = buffer[0];
      IndicatorRelease(handle);
   }
   
   // Bollinger Bands
   handle = iBands(symbol, PERIOD_M1, 20, 0, 2, PRICE_CLOSE);
   if(handle != INVALID_HANDLE)
   {
      CopyBuffer(handle, 0, 0, 1, buffer);
      symbolData[index].bbMiddle = buffer[0];
      CopyBuffer(handle, 1, 0, 1, buffer);
      symbolData[index].bbUpper = buffer[0];
      CopyBuffer(handle, 2, 0, 1, buffer);
      symbolData[index].bbLower = buffer[0];
      IndicatorRelease(handle);
   }
   
   // SMA
   handle = iMA(symbol, PERIOD_M1, 20, 0, MODE_SMA, PRICE_CLOSE);
   if(handle != INVALID_HANDLE)
   {
      CopyBuffer(handle, 0, 0, 1, buffer);
      symbolData[index].sma20 = buffer[0];
      IndicatorRelease(handle);
   }
   
   handle = iMA(symbol, PERIOD_M1, 50, 0, MODE_SMA, PRICE_CLOSE);
   if(handle != INVALID_HANDLE)
   {
      CopyBuffer(handle, 0, 0, 1, buffer);
      symbolData[index].sma50 = buffer[0];
      IndicatorRelease(handle);
   }
   
   // ATR
   handle = iATR(symbol, PERIOD_M1, 14);
   if(handle != INVALID_HANDLE)
   {
      CopyBuffer(handle, 0, 0, 1, buffer);
      symbolData[index].atr = buffer[0];
      IndicatorRelease(handle);
   }
}

//+------------------------------------------------------------------+
//| Generate trading signals                                        |
//+------------------------------------------------------------------+
void GenerateSignals()
{
   // Market Making Strategy
   for(int i = 0; i < ArraySize(symbols); i++)
   {
      if(ShouldTrade())
      {
         double bidPrice, askPrice;
         if(CalculateMarketMakingPrices(i, bidPrice, askPrice))
         {
            // Place buy order (bid)
            if(ExecuteTrade(symbols[i], ORDER_TYPE_BUY_LIMIT, bidPrice, InpRiskPerTrade / 2, "Market Making"))
            {
               dailyTradeCount++;
               tradeCount++;
               lastTradeTime = TimeCurrent();
            }
            
            // Place sell order (ask)
            if(ShouldTrade() && ExecuteTrade(symbols[i], ORDER_TYPE_SELL_LIMIT, askPrice, InpRiskPerTrade / 2, "Market Making"))
            {
               dailyTradeCount++;
               tradeCount++;
               lastTradeTime = TimeCurrent();
            }
         }
      }
   }
   
   // Statistical Arbitrage Strategy
   if(ShouldTrade())
   {
      for(int i = 0; i < ArraySize(symbols) - 1; i++)
      {
         double zScore;
         int signal = CalculateStatArbSignal(i, i+1, zScore);
         
         if(signal != 0 && MathAbs(zScore) > InpZScoreThreshold)
         {
            if(signal > 0)
            {
               if(ExecuteTrade(symbols[i], ORDER_TYPE_BUY, 0, InpRiskPerTrade, "Stat Arb"))
               {
                  dailyTradeCount++;
                  tradeCount++;
                  lastTradeTime = TimeCurrent();
               }
            }
            else
            {
               if(ExecuteTrade(symbols[i], ORDER_TYPE_SELL, 0, InpRiskPerTrade, "Stat Arb"))
               {
                  dailyTradeCount++;
                  tradeCount++;
                  lastTradeTime = TimeCurrent();
               }
            }
         }
      }
   }
   
   // Momentum Strategy
   if(ShouldTrade())
   {
      for(int i = 0; i < MathMin(3, ArraySize(symbols)); i++)
      {
         double price = symbolPrices[i];
         
         // RSI-based momentum
         if(symbolData[i].rsi < 30 && price < symbolData[i].sma20)
         {
            if(ExecuteTrade(symbols[i], ORDER_TYPE_BUY, 0, InpRiskPerTrade * 0.8, "Momentum"))
            {
               dailyTradeCount++;
               tradeCount++;
               lastTradeTime = TimeCurrent();
            }
         }
         else if(symbolData[i].rsi > 70 && price > symbolData[i].sma20)
         {
            if(ExecuteTrade(symbols[i], ORDER_TYPE_SELL, 0, InpRiskPerTrade * 0.8, "Momentum"))
            {
               dailyTradeCount++;
               tradeCount++;
               lastTradeTime = TimeCurrent();
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Calculate market making prices                                  |
//+------------------------------------------------------------------+
bool CalculateMarketMakingPrices(int index, double &bidPrice, double &askPrice)
{
   if(ArraySize(symbolData[index].bids) == 0 || ArraySize(symbolData[index].asks) == 0)
      return false;
   
   double bestBid = symbolData[index].bids[0].price;
   double bestAsk = symbolData[index].asks[0].price;
   double midPrice = (bestBid + bestAsk) / 2;
   
   // Calculate spread based on volatility
   double atr = symbolData[index].atr;
   double volatilitySpread = atr / midPrice;
   double spread = MathMax(0.001, volatilitySpread * InpSpreadMultiplier);
   
   // Inventory adjustment (simplified)
   double inventoryAdjustment = CalculateInventoryAdjustment(index);
   
   bidPrice = midPrice * (1 - spread / 2 - inventoryAdjustment);
   askPrice = midPrice * (1 + spread / 2 - inventoryAdjustment);
   
   return true;
}

//+------------------------------------------------------------------+
//| Calculate inventory adjustment                                  |
//+------------------------------------------------------------------+
double CalculateInventoryAdjustment(int index)
{
   // Track inventory in production system
   // For demo, return small adjustment
   return (MathRand() / 32768.0 - 0.5) * 0.0005;
}

//+------------------------------------------------------------------+
//| Calculate statistical arbitrage signal                          |
//+------------------------------------------------------------------+
int CalculateStatArbSignal(int index1, int index2, double &zScore)
{
   // Simplified calculation
   // In production, use correlation and cointegration
   double price1 = symbolPrices[index1];
   double price2 = symbolPrices[index2];
   
   if(price1 == 0 || price2 == 0)
      return 0;
   
   // Normalize prices
   static double initialPrice1 = price1;
   static double initialPrice2 = price2;
   
   double norm1 = price1 / initialPrice1;
   double norm2 = price2 / initialPrice2;
   
   double spread = norm1 - norm2;
   
   // Calculate z-score with limited history
   static double spreadHistory[];
   ArrayResize(spreadHistory, ArraySize(spreadHistory) + 1);
   spreadHistory[ArraySize(spreadHistory) - 1] = spread;
   
   if(ArraySize(spreadHistory) < InpCorrelationWindow)
      return 0;
   
   double mean = 0, std = 0;
   for(int i = 0; i < InpCorrelationWindow; i++)
   {
      mean += spreadHistory[ArraySize(spreadHistory) - 1 - i];
   }
   mean /= InpCorrelationWindow;
   
   for(int i = 0; i < InpCorrelationWindow; i++)
   {
      std += MathPow(spreadHistory[ArraySize(spreadHistory) - 1 - i] - mean, 2);
   }
   std = MathSqrt(std / InpCorrelationWindow);
   
   if(std == 0)
      return 0;
   
   zScore = (spread - mean) / std;
   
   if(zScore > InpZScoreThreshold)
      return -1;  // Short
   else if(zScore < -InpZScoreThreshold)
      return 1;   // Long
   
   return 0;
}

//+------------------------------------------------------------------+
//| Execute trade                                                   |
//+------------------------------------------------------------------+
bool ExecuteTrade(string symbol, ENUM_ORDER_TYPE orderType, double price, double risk, string strategy)
{
   // Calculate position size
   double lotSize = CalculateLotSize(symbol, risk);
   if(lotSize <= 0)
      return false;
   
   // Get current price if not specified
   if(price == 0)
   {
      MqlTick tick;
      if(SymbolInfoTick(symbol, tick))
      {
         price = (orderType == ORDER_TYPE_BUY || orderType == ORDER_TYPE_BUY_LIMIT) ? 
                 tick.ask : tick.bid;
      }
      else
         return false;
   }
   
   // Calculate SL and TP
   double slPrice = 0, tpPrice = 0;
   CalculateSLTP(symbol, orderType, price, slPrice, tpPrice);
   
   // Place order
   bool result = false;
   if(orderType == ORDER_TYPE_BUY || orderType == ORDER_TYPE_BUY_LIMIT)
   {
      result = trade.PositionOpen(symbol, orderType, lotSize, price, 
                                 slPrice, tpPrice, strategy);
   }
   else if(orderType == ORDER_TYPE_SELL || orderType == ORDER_TYPE_SELL_LIMIT)
   {
      result = trade.PositionOpen(symbol, orderType, lotSize, price, 
                                 slPrice, tpPrice, strategy);
   }
   
   if(result)
   {
      Print("Trade executed: ", strategy, " on ", symbol, 
            " Lot: ", lotSize, " Price: ", price);
   }
   
   return result;
}

//+------------------------------------------------------------------+
//| Calculate lot size based on risk                                |
//+------------------------------------------------------------------+
double CalculateLotSize(string symbol, double riskPercent)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * riskPercent / 100;
   
   // Get tick value
   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double stopLossPoints = InpStopLoss * 100;  // Convert to points
   
   if(tickValue <= 0 || tickSize <= 0)
      return 0;
   
   // Calculate lot size based on stop loss
   double lotSize = riskAmount / (stopLossPoints * tickValue / tickSize);
   
   // Apply volatility adjustment
   double atr = 0;
   int atrHandle = iATR(symbol, PERIOD_M1, 14);
   if(atrHandle != INVALID_HANDLE)
   {
      double buffer[];
      CopyBuffer(atrHandle, 0, 0, 1, buffer);
      atr = buffer[0];
      IndicatorRelease(atrHandle);
   }
   
   if(atr > 0)
   {
      double volatilityFactor = 1 - MathMin(0.5, atr / price * 10);
      lotSize *= volatilityFactor;
   }
   
   // Apply min/max limits
   double minLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   
   lotSize = MathMax(minLot, MathMin(maxLot, lotSize));
   lotSize = MathFloor(lotSize / stepLot) * stepLot;
   
   return lotSize;
}

//+------------------------------------------------------------------+
//| Calculate stop loss and take profit                            |
//+------------------------------------------------------------------+
void CalculateSLTP(string symbol, ENUM_ORDER_TYPE orderType, double price, 
                   double &slPrice, double &tpPrice)
{
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   
   if(orderType == ORDER_TYPE_BUY || orderType == ORDER_TYPE_BUY_LIMIT)
   {
      slPrice = price - price * InpStopLoss / 100;
      tpPrice = price + price * InpTakeProfit / 100;
   }
   else
   {
      slPrice = price + price * InpStopLoss / 100;
      tpPrice = price - price * InpTakeProfit / 100;
   }
   
   // Round to valid price levels
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   slPrice = NormalizeDouble(slPrice, digits);
   tpPrice = NormalizeDouble(tpPrice, digits);
}

//+------------------------------------------------------------------+
//| Manage open positions                                           |
//+------------------------------------------------------------------+
void ManagePositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(positionInfo.SelectByIndex(i))
      {
         if(positionInfo.Magic() == InpMagicNumber)
         {
            // Check if position should be closed early
            double profit = positionInfo.Profit();
            double openPrice = positionInfo.PriceOpen();
            double currentPrice = positionInfo.PriceCurrent();
            double pipValue = SymbolInfoDouble(positionInfo.Symbol(), SYMBOL_POINT);
            
            // Trailing stop logic
            if(profit > 0)
            {
               double trailingStop = CalculateTrailingStop(positionInfo.Symbol(), profit);
               if(trailingStop > 0)
               {
                  // Implement trailing stop
                  if(positionInfo.PositionType() == POSITION_TYPE_BUY)
                  {
                     double newSL = currentPrice - trailingStop * pipValue;
                     if(newSL > positionInfo.StopLoss())
                        trade.PositionModify(positionInfo.Ticket(), newSL, positionInfo.TakeProfit());
                  }
                  else
                  {
                     double newSL = currentPrice + trailingStop * pipValue;
                     if(newSL < positionInfo.StopLoss())
                        trade.PositionModify(positionInfo.Ticket(), newSL, positionInfo.TakeProfit());
                  }
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Calculate trailing stop                                         |
//+------------------------------------------------------------------+
double CalculateTrailingStop(string symbol, double profit)
{
   if(profit <= 0)
      return 0;
   
   double breakEvenLevel = 10;  // Points
   double maxTrailingPoints = InpStopLoss * 100;  // Convert to points
   
   // Dynamic trailing based on profit
   if(profit > 10)
      return breakEvenLevel + MathMin(profit / 10, maxTrailingPoints);
   else
      return 0;
}

//+------------------------------------------------------------------+
//| Update performance metrics                                      |
//+------------------------------------------------------------------+
void UpdatePerformance()
{
   // Get closed trades
   double totalProfit = 0;
   int totalTrades = 0;
   int wins = 0;
   
   if(HistorySelect(0, TimeCurrent()))
   {
      for(int i = 0; i < HistoryTotal(); i++)
      {
         if(HistoryOrderGetInteger(i, ORDER_MAGIC) == InpMagicNumber)
         {
            double profit = HistoryOrderGetDouble(i, ORDER_PROFIT);
            totalProfit += profit;
            totalTrades++;
            
            if(profit > 0)
               wins++;
         }
      }
   }
   
   // Update metrics
   totalPnL = totalProfit;
   winningTrades = wins;
   losingTrades = totalTrades - wins;
   winRate = (totalTrades > 0) ? (double)wins / totalTrades : 0;
   
   // Calculate daily PnL
   if(HistorySelect(dayStart, TimeCurrent()))
   {
      dailyPnL = 0;
      for(int i = 0; i < HistoryTotal(); i++)
      {
         if(HistoryOrderGetInteger(i, ORDER_MAGIC) == InpMagicNumber)
         {
            dailyPnL += HistoryOrderGetDouble(i, ORDER_PROFIT);
         }
      }
   }
   
   // Update returns array for Sharpe ratio
   ArrayResize(returns, totalTrades);
   if(totalTrades > 0 && HistorySelect(0, TimeCurrent()))
   {
      for(int i = 0; i < totalTrades; i++)
      {
         returns[i] = HistoryOrderGetDouble(i, ORDER_PROFIT);
      }
      
      if(totalTrades > 1)
      {
         double mean = 0, std = 0;
         for(int i = 0; i < totalTrades; i++)
         {
            mean += returns[i];
         }
         mean /= totalTrades;
         
         for(int i = 0; i < totalTrades; i++)
         {
            std += MathPow(returns[i] - mean, 2);
         }
         std = MathSqrt(std / totalTrades);
         
         if(std > 0)
            sharpeRatio = mean / std * MathSqrt(252);
      }
   }
}

//+------------------------------------------------------------------+
//| Calculate daily loss                                            |
//+------------------------------------------------------------------+
double CalculateDailyLoss()
{
   if(initialBalance == 0)
      return 0;
   
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double lossPercent = (currentBalance - initialBalance) / initialBalance * 100;
   
   return lossPercent;
}

//+------------------------------------------------------------------+
//| Calculate drawdown                                              |
//+------------------------------------------------------------------+
double CalculateDrawdown()
{
   static double maxBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   
   if(currentBalance > maxBalance)
      maxBalance = currentBalance;
   
   double drawdown = (currentBalance - maxBalance) / maxBalance * 100;
   return drawdown;
}

//+------------------------------------------------------------------+
//| Reset daily statistics                                          |
//+------------------------------------------------------------------+
void ResetDailyStats()
{
   dailyTradeCount = 0;
   dailyPnL = 0;
   initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   Print("=== New Trading Day Started ===");
   Print("Initial Balance: ", initialBalance);
   Print("===============================");
}

//+------------------------------------------------------------------+
//| Chart event handler                                              |
//+------------------------------------------------------------------+
void OnChartEvent(const int id,
                  const long &lparam,
                  const double &dparam,
                  const string &sparam)
{
   if(id == CHARTEVENT_CLICK)
   {
      // Display performance on chart
      string comment = "=== High Frequency EA ===\n";
      comment += "Daily Trades: " + IntegerToString(dailyTradeCount) + "/" + IntegerToString(InpMaxDailyTrades) + "\n";
      comment += "Total Trades: " + IntegerToString(tradeCount) + "\n";
      comment += "Daily PnL: " + DoubleToString(dailyPnL, 2) + "\n";
      comment += "Total PnL: " + DoubleToString(totalPnL, 2) + "\n";
      comment += "Win Rate: " + DoubleToString(winRate * 100, 1) + "%\n";
      comment += "Sharpe Ratio: " + DoubleToString(sharpeRatio, 2) + "\n";
      comment += "==========================";
      
      Comment(comment);
   }
}

//+------------------------------------------------------------------+
//| Timer function                                                   |
//+------------------------------------------------------------------+
void OnTimer()
{
   // Update performance display
   if(TimeCurrent() % 60 == 0)  // Every minute
   {
      string comment = "=== High Frequency EA ===\n";
      comment += "Daily Trades: " + IntegerToString(dailyTradeCount) + "/" + IntegerToString(InpMaxDailyTrades) + "\n";
      comment += "Total Trades: " + IntegerToString(tradeCount) + "\n";
      comment += "Daily PnL: $" + DoubleToString(dailyPnL, 2) + "\n";
      comment += "Total PnL: $" + DoubleToString(totalPnL, 2) + "\n";
      comment += "Win Rate: " + DoubleToString(winRate * 100, 1) + "%\n";
      comment += "Sharpe Ratio: " + DoubleToString(sharpeRatio, 2) + "\n";
      comment += "Drawdown: " + DoubleToString(CalculateDrawdown(), 2) + "%\n";
      comment += "==========================";
      
      Comment(comment);
   }
}

//+------------------------------------------------------------------+
//| Custom function to calculate RSI                                 |
//+------------------------------------------------------------------+
double CalculateRSI(string symbol, int period, int shift)
{
   double rsi = 0;
   int handle = iRSI(symbol, PERIOD_M1, period, PRICE_CLOSE);
   if(handle != INVALID_HANDLE)
   {
      double buffer[];
      CopyBuffer(handle, 0, shift, 1, buffer);
      rsi = buffer[0];
      IndicatorRelease(handle);
   }
   return rsi;
}

//+------------------------------------------------------------------+
//| Custom function to calculate Bollinger Bands                    |
//+------------------------------------------------------------------+
bool CalculateBollingerBands(string symbol, int period, int shift, 
                            double &upper, double &middle, double &lower)
{
   int handle = iBands(symbol, PERIOD_M1, period, 0, 2, PRICE_CLOSE);
   if(handle != INVALID_HANDLE)
   {
      double buffer[];
      CopyBuffer(handle, 0, shift, 1, buffer);
      middle = buffer[0];
      CopyBuffer(handle, 1, shift, 1, buffer);
      upper = buffer[0];
      CopyBuffer(handle, 2, shift, 1, buffer);
      lower = buffer[0];
      IndicatorRelease(handle);
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Custom function to calculate SMA                                |
//+------------------------------------------------------------------+
double CalculateSMA(string symbol, int period, int shift)
{
   double sma = 0;
   int handle = iMA(symbol, PERIOD_M1, period, 0, MODE_SMA, PRICE_CLOSE);
   if(handle != INVALID_HANDLE)
   {
      double buffer[];
      CopyBuffer(handle, 0, shift, 1, buffer);
      sma = buffer[0];
      IndicatorRelease(handle);
   }
   return sma;
}

//+------------------------------------------------------------------+
//| Custom function to calculate ATR                               |
//+------------------------------------------------------------------+
double CalculateATR(string symbol, int period, int shift)
{
   double atr = 0;
   int handle = iATR(symbol, PERIOD_M1, period);
   if(handle != INVALID_HANDLE)
   {
      double buffer[];
      CopyBuffer(handle, 0, shift, 1, buffer);
      atr = buffer[0];
      IndicatorRelease(handle);
   }
   return atr;
}

//+------------------------------------------------------------------+