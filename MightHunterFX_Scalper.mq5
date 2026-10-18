//+------------------------------------------------------------------+
//| Might Hunter FX Scalper - educational starter EA                 |
//| Intended for EURUSD M5 demo testing on MetaTrader 5              |
//| Not a promise of profit. Review and test before any live use.    |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "EMA crossover + RSI confirmation with ATR SL/TP and risk controls."

#include <Trade/Trade.mqh>
CTrade trade;

input ENUM_TIMEFRAMES SignalTimeframe = PERIOD_M5;
input double RiskPercent = 0.5;             // Intended cash risk as % of equity
input double DailyLossLimitPercent = 2.0;   // Lock entries after daily equity drawdown
input int FastEMAPeriod = 9;
input int SlowEMAPeriod = 21;
input int RSIPeriod = 14;
input double BuyRSIMin = 50.0;
input double SellRSIMax = 50.0;
input int ATRPeriod = 14;
input double ATRStopMultiplier = 1.5;
input double RewardRiskRatio = 1.5;
input double MaxSpreadPoints = 20.0;
input ulong MagicNumber = 18102026;
input int SlippagePoints = 10;

int fastHandle = INVALID_HANDLE;
int slowHandle = INVALID_HANDLE;
int rsiHandle  = INVALID_HANDLE;
int atrHandle  = INVALID_HANDLE;
datetime lastBarTime = 0;
string dailyEquityKey = "";
int dailyDateKey = 0;
bool dailyLocked = false;

int DateKey(datetime when)
{
   MqlDateTime dt;
   TimeToStruct(when, dt);
   return dt.year * 10000 + dt.mon * 100 + dt.day;
}

string MakeDailyKey(int dateKey)
{
   return "MHFX_" + IntegerToString((long)AccountInfoInteger(ACCOUNT_LOGIN)) +
          "_" + IntegerToString(dateKey) + "_START_EQ";
}

bool RefreshDailyEquity()
{
   int today = DateKey(TimeTradeServer());
   if(today != dailyDateKey)
   {
      dailyDateKey = today;
      dailyEquityKey = MakeDailyKey(today);
      dailyLocked = false;
      if(!GlobalVariableCheck(dailyEquityKey))
         GlobalVariableSet(dailyEquityKey, AccountInfoDouble(ACCOUNT_EQUITY));
   }

   if(!GlobalVariableCheck(dailyEquityKey))
      GlobalVariableSet(dailyEquityKey, AccountInfoDouble(ACCOUNT_EQUITY));

   double startEquity = GlobalVariableGet(dailyEquityKey);
   if(startEquity <= 0.0)
      return false;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double lossPct = (startEquity - equity) / startEquity * 100.0;

   if(lossPct >= DailyLossLimitPercent)
      dailyLocked = true;

   return !dailyLocked;
}

bool IsNewBar()
{
   datetime times[1];
   if(CopyTime(_Symbol, SignalTimeframe, 0, 1, times) != 1)
      return false;
   if(times[0] != lastBarTime)
   {
      lastBarTime = times[0];
      return true;
   }
   return false;
}

bool HasOurPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            (ulong)PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            return true;
      }
   }
   return false;
}

double NormalizeVolume(double lots)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0) return 0.0;

   lots = MathMin(lots, maxLot);
   lots = MathFloor(lots / step) * step;
   lots = NormalizeDouble(lots, 8);
   if(lots < minLot) return 0.0; // Do not exceed intended risk to meet minimum lot
   return lots;
}

double LotsForRisk(ENUM_ORDER_TYPE orderType, double entry, double stop)
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskCash = equity * RiskPercent / 100.0;
   if(riskCash <= 0.0) return 0.0;

   double oneLotProfit = 0.0;
   if(!OrderCalcProfit(orderType, _Symbol, 1.0, entry, stop, oneLotProfit))
      return 0.0;

   double oneLotLoss = MathAbs(oneLotProfit);
   if(oneLotLoss <= 0.0) return 0.0;

   return NormalizeVolume(riskCash / oneLotLoss);
}

int OnInit()
{
   if(RiskPercent <= 0 || RiskPercent > 0.5 ||
      DailyLossLimitPercent <= 0 || FastEMAPeriod <= 0 ||
      SlowEMAPeriod <= FastEMAPeriod || ATRStopMultiplier <= 0 ||
      RewardRiskRatio <= 0 || MaxSpreadPoints <= 0)
   {
      Print("Invalid input. RiskPercent must be >0 and <=0.5; check all settings.");
      return INIT_PARAMETERS_INCORRECT;
   }

   fastHandle = iMA(_Symbol, SignalTimeframe, FastEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   slowHandle = iMA(_Symbol, SignalTimeframe, SlowEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   rsiHandle  = iRSI(_Symbol, SignalTimeframe, RSIPeriod, PRICE_CLOSE);
   atrHandle  = iATR(_Symbol, SignalTimeframe, ATRPeriod);

   if(fastHandle == INVALID_HANDLE || slowHandle == INVALID_HANDLE ||
      rsiHandle == INVALID_HANDLE || atrHandle == INVALID_HANDLE)
   {
      Print("Could not create indicator handles. Error: ", GetLastError());
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   dailyDateKey = 0;
   RefreshDailyEquity();
   Print("Might Hunter FX Scalper initialized. Demo testing only.");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(fastHandle != INVALID_HANDLE) IndicatorRelease(fastHandle);
   if(slowHandle != INVALID_HANDLE) IndicatorRelease(slowHandle);
   if(rsiHandle  != INVALID_HANDLE) IndicatorRelease(rsiHandle);
   if(atrHandle  != INVALID_HANDLE) IndicatorRelease(atrHandle);
}

void OnTick()
{
   if(!RefreshDailyEquity())
   {
      Comment("Might Hunter FX: DAILY LOSS LOCK ACTIVE. No new trades.");
      return;
   }
   Comment("Might Hunter FX Scalper | Risk: ", DoubleToString(RiskPercent, 2),
           "% | Daily limit: ", DoubleToString(DailyLossLimitPercent, 2), "%");

   if(!IsNewBar() || HasOurPosition())
      return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0.0)
      return;

   double spreadPoints = (tick.ask - tick.bid) / point;
   if(spreadPoints > MaxSpreadPoints)
   {
      Print("Entry skipped: spread too high (", DoubleToString(spreadPoints, 1), " points).");
      return;
   }

   double fast[3], slow[3], rsi[3], atr[3];
   ArraySetAsSeries(fast, true);
   ArraySetAsSeries(slow, true);
   ArraySetAsSeries(rsi, true);
   ArraySetAsSeries(atr, true);

   if(CopyBuffer(fastHandle, 0, 0, 3, fast) != 3 ||
      CopyBuffer(slowHandle, 0, 0, 3, slow) != 3 ||
      CopyBuffer(rsiHandle, 0, 0, 3, rsi) != 3 ||
      CopyBuffer(atrHandle, 0, 0, 3, atr) != 3)
      return;

   // Use closed bars: bar 2 -> bar 1 crossover, confirmed by bar 1 RSI.
   bool buySignal  = (fast[2] <= slow[2] && fast[1] > slow[1] && rsi[1] > BuyRSIMin);
   bool sellSignal = (fast[2] >= slow[2] && fast[1] < slow[1] && rsi[1] < SellRSIMax);
   if(!buySignal && !sellSignal)
      return;

   double stopDistance = atr[1] * ATRStopMultiplier;
   int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minStop = stopsLevel * point;
   stopDistance = MathMax(stopDistance, minStop + 2.0 * point);
   if(stopDistance <= 0.0)
      return;

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(buySignal)
   {
      double entry = tick.ask;
      double sl = NormalizeDouble(entry - stopDistance, digits);
      double tp = NormalizeDouble(entry + stopDistance * RewardRiskRatio, digits);
      double lots = LotsForRisk(ORDER_TYPE_BUY, entry, sl);
      if(lots <= 0.0)
      {
         Print("BUY skipped: calculated lot is below broker minimum or risk calculation failed.");
         return;
      }
      if(!trade.Buy(lots, _Symbol, 0.0, sl, tp, "MightHunter BUY"))
         Print("BUY failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
   }
   else if(sellSignal)
   {
      double entry = tick.bid;
      double sl = NormalizeDouble(entry + stopDistance, digits);
      double tp = NormalizeDouble(entry - stopDistance * RewardRiskRatio, digits);
      double lots = LotsForRisk(ORDER_TYPE_SELL, entry, sl);
      if(lots <= 0.0)
      {
         Print("SELL skipped: calculated lot is below broker minimum or risk calculation failed.");
         return;
      }
      if(!trade.Sell(lots, _Symbol, 0.0, sl, tp, "MightHunter SELL"))
         Print("SELL failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
   }
}
