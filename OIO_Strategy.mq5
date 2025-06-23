//+------------------------------------------------------------------+
//|                                                 OIO_Strategy.mq5 |
//|                        Copyright 2023, MetaQuotes Software Corp. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2023, MetaQuotes Software Corp."
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict

//--- Inputs
input string InpSymbol = "";
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_CURRENT;
input int InpOrderExpirationBars = 4; // For initial orders
input int InpMagicNumber = 623623;
input double InpSecondOrderLots = 0.02;
input int InpProfitAdjustmentTicks = 3; // TP adjustment in ticks (e.g., 3 * tick_size)

//--- Globals
struct OIO_Pattern {
    double high, low, midpoint;
    datetime time; // K3 open time
    bool isValid;
    void OIO_Pattern() { high=0; low=0; midpoint=0; time=0; isValid=false; }
};
OIO_Pattern g_oio;
datetime g_prevBarOpenTime = 0;

// Tickets
long g_initial_buy_ticket = 0;
long g_initial_sell_ticket = 0;
long g_second_buy_ticket = 0;
long g_second_sell_ticket = 0;

// Active OIO context for second order and TP adjustment
double g_active_oio_midpoint = 0;
double g_active_initial_buy_sl = 0;
double g_active_initial_sell_sl = 0;
datetime g_active_oio_k3_time = 0; // K3 time of the OIO that triggered first/second orders
bool g_initial_order_triggered_for_active_oio = false;

// Store details of the first triggered order for average price calculation
long   g_first_leg_ticket = 0;       // Ticket of the first (initial) order that was filled
double g_first_leg_open_price = 0;
double g_first_leg_lots = 0;
ENUM_ORDER_TYPE g_first_leg_order_type = WRONG_VALUE;


//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit() {
    PrintFormat("EA OnInit: %s, %s", _Symbol, EnumToString(InpTimeframe));
    string currentSymbol = InpSymbol; if(currentSymbol == "") currentSymbol = _Symbol;
    ENUM_TIMEFRAMES currentTimeframe = InpTimeframe; if(currentTimeframe == PERIOD_CURRENT) currentTimeframe = Period();
    PrintFormat("Params: Sym=%s, TF=%s, ExpBars=%d, Magic=%d, SecLots=%.2f, TPAdjTicks=%d",
                currentSymbol, EnumToString(currentTimeframe), InpOrderExpirationBars, InpMagicNumber, InpSecondOrderLots, InpProfitAdjustmentTicks);

    g_oio.isValid = false;
    MqlRates cr[1];
    if(CopyRates(currentSymbol, currentTimeframe, 1, 1, cr) > 0) {
         g_prevBarOpenTime = cr[0].time;
         PrintFormat("OnInit: PrevBarTime: %s", TimeToString(g_prevBarOpenTime, TIME_DATE|TIME_MINUTES));
    } else { g_prevBarOpenTime = 0; Print("OnInit: No completed bars found."); }

    g_initial_order_triggered_for_active_oio = false;
    g_first_leg_ticket = 0; // Reset first leg info
    Print("EA Initialized");
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) { PrintFormat("EA OnDeinit: %d", reason); }

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick() {
    string symbol = InpSymbol; if(symbol == "") symbol = _Symbol;
    ENUM_TIMEFRAMES timeframe = InpTimeframe; if(timeframe == PERIOD_CURRENT) timeframe = Period();
    MqlRates cfb[1];
    if(CopyRates(symbol, timeframe, 0, 1, cfb) < 1) { Print("OnTick: CopyRates fail"); return; }
    datetime cbot = cfb[0].time;

    if(cbot > g_prevBarOpenTime) {
        if (g_prevBarOpenTime != 0) {
            MqlRates oc[3];
            if(CopyRates(symbol, timeframe, 1, 3, oc) == 3) {
                if (oc[2].time == g_prevBarOpenTime) {
                    if(IdentifyOIO(oc[0], oc[1], oc[2], symbol)) {
                        Print("Valid OIO detected!");
                        PrintFormat("OIO H:%.*f L:%.*f M:%.*f K3Time:%s", SymbolInfoInteger(symbol,SYMBOL_DIGITS), g_oio.high, SymbolInfoInteger(symbol,SYMBOL_DIGITS), g_oio.low, SymbolInfoInteger(symbol,SYMBOL_DIGITS), g_oio.midpoint, TimeToString(g_oio.time,TIME_DATE|TIME_MINUTES));
                        PlaceInitialOrders(symbol, timeframe);
                    }
                }
            }
        }
        g_prevBarOpenTime = cbot;
    }
}

//+------------------------------------------------------------------+
//| IdentifyOIO                                                      |
//+------------------------------------------------------------------+
bool IdentifyOIO(MqlRates k1, MqlRates k2, MqlRates k3, string symbol) {
    if((k1.high >= k2.high && k3.high >= k2.high) && (k1.low <= k2.low && k3.low <= k2.low)) {
        static datetime last_k3_processed = 0;
        if (k3.time == last_k3_processed) { g_oio.isValid = false; return false; }

        g_oio.high = MathMax(k1.high, MathMax(k2.high, k3.high));
        g_oio.low  = MathMin(k1.low, MathMin(k2.low, k3.low));
        g_oio.midpoint = NormalizeDouble((g_oio.high + g_oio.low) / 2.0, SymbolInfoInteger(symbol, SYMBOL_DIGITS));
        g_oio.time = k3.time;
        g_oio.isValid = true;

        g_initial_order_triggered_for_active_oio = false; // New OIO, reset trigger flag
        g_first_leg_ticket = 0; // Reset first leg info for new OIO
        last_k3_processed = k3.time;
        return true;
    }
    g_oio.isValid = false; return false;
}

//+------------------------------------------------------------------+
//| PlaceInitialOrders                                               |
//+------------------------------------------------------------------+
void PlaceInitialOrders(string symbol, ENUM_TIMEFRAMES timeframe) {
    if(!g_oio.isValid) return;
    if ((g_initial_buy_ticket != 0 && OrderSelect(g_initial_buy_ticket) && OrderGetInteger(ORDER_STATE) < ORDER_STATE_FILLED) ||
        (g_initial_sell_ticket != 0 && OrderSelect(g_initial_sell_ticket) && OrderGetInteger(ORDER_STATE) < ORDER_STATE_FILLED) ) {
        Print("Initial orders already pending."); return;
    }
    if (g_initial_buy_ticket != 0 && !OrderSelect(g_initial_buy_ticket)) g_initial_buy_ticket = 0; // Clean up bad tickets
    if (g_initial_sell_ticket != 0 && !OrderSelect(g_initial_sell_ticket)) g_initial_sell_ticket = 0;


    double ts = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE); int d = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
    if(ts == 0) { Print("TickSize is zero!"); return; }
    int range_ticks = (int)MathRound((g_oio.high - g_oio.low) / ts);
    double lots;
    if(range_ticks <= 0) { PrintFormat("Invalid range_ticks: %d", range_ticks); return;}
    if(range_ticks <= 20) lots = 0.02; else if (range_ticks < 41) lots = 0.01;
    else { PrintFormat("Range %d ticks too large.", range_ticks); g_oio.isValid = false; return; }

    lots = NormalizeLots(lots, symbol);
    if (lots == 0) { Print("Normalized lots is zero."); g_oio.isValid = false; return; }
    PrintFormat("Initial lots: %.2f (Range: %d ticks)", lots, range_ticks);

    double b_op=NormalizeDouble(g_oio.high + ts, d), b_sl=NormalizeDouble(g_oio.low - ts, d), b_tp=NormalizeDouble(b_op + InpProfitAdjustmentTicks*ts, d);
    double s_op=NormalizeDouble(g_oio.low - ts, d), s_sl=NormalizeDouble(g_oio.high + ts, d), s_tp=NormalizeDouble(s_op - InpProfitAdjustmentTicks*ts, d);
    datetime exp = 0; if(InpOrderExpirationBars > 0) { long p_s = PeriodSeconds(timeframe); if(p_s > 0) exp = TimeCurrent() + InpOrderExpirationBars * p_s; }
    string cmt_sfx = TimeToString(g_oio.time, "_%y%m%d%H%M");

    if (g_initial_buy_ticket == 0) SendOrder(ORDER_TYPE_BUY_LIMIT, symbol, lots, b_op, b_sl, b_tp, "OIO_InitBuy"+cmt_sfx, exp, g_initial_buy_ticket);
    if (g_initial_sell_ticket == 0) SendOrder(ORDER_TYPE_SELL_LIMIT, symbol, lots, s_op, s_sl, s_tp, "OIO_InitSell"+cmt_sfx, exp, g_initial_sell_ticket);
}

//+------------------------------------------------------------------+
//| OnTradeTransaction                                               |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans, const MqlTradeRequest& req, const MqlTradeResult& res) {
    if (trans.symbol != _Symbol && (InpSymbol != "" && trans.symbol != InpSymbol)) return;
    if (trans.magic != InpMagicNumber) return;

    string symbol = trans.symbol; // Use actual transaction symbol
    ENUM_TIMEFRAMES timeframe = InpTimeframe; if(timeframe == PERIOD_CURRENT) timeframe = Period();


    if (trans.type == TRADE_TRANSACTION_DEAL_ADD) {
        ulong deal_ticket = trans.deal;
        if (!HistoryDealSelect(deal_ticket)) return;

        long order_ticket = HistoryDealGetInteger(deal_ticket, DEAL_ORDER);
        ENUM_ORDER_TYPE order_type = (ENUM_ORDER_TYPE)HistoryDealGetInteger(deal_ticket, DEAL_TYPE);
        ENUM_DEAL_ENTRY deal_entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal_ticket, DEAL_ENTRY);
        ENUM_DEAL_REASON deal_reason = (ENUM_DEAL_REASON)HistoryDealGetInteger(deal_ticket, DEAL_REASON);
        double deal_lots = HistoryDealGetDouble(deal_ticket, DEAL_VOLUME);
        double deal_price = HistoryDealGetDouble(deal_ticket, DEAL_PRICE);

        PrintFormat("TradeTX: Deal #%d for Order #%d, Type:%s, Entry:%s, Reason:%s, Magic:%d, Vol:%.2f",
                    deal_ticket, order_ticket, EnumToString(order_type), EnumToString(deal_entry), EnumToString(deal_reason), trans.magic, deal_lots);

        // --- Scenario 1: Initial order hits TP ---
        if (deal_reason == DEAL_REASON_TP && deal_entry == DEAL_ENTRY_OUT) { // Order closed by TP
             // Check if this TP'd order was our g_first_leg_ticket (the first part of the OIO strategy that got filled)
             // And ensure the second leg is still pending
            if (order_ticket == g_first_leg_ticket) { // Check if it's the first leg that TP'd
                PrintFormat("Initial order #%d (first leg) hit TP.", order_ticket);
                if (order_type == ORDER_TYPE_BUY) { // Initial was a buy
                    if (g_second_buy_ticket != 0) {
                        PrintFormat("Cancelling second buy order #%d due to first leg TP.", g_second_buy_ticket);
                        CancelOrder(g_second_buy_ticket, "InitBuy TP");
                        g_second_buy_ticket = 0;
                    }
                } else if (order_type == ORDER_TYPE_SELL) { // Initial was a sell
                    if (g_second_sell_ticket != 0) {
                        PrintFormat("Cancelling second sell order #%d due to first leg TP.", g_second_sell_ticket);
                        CancelOrder(g_second_sell_ticket, "InitSell TP");
                        g_second_sell_ticket = 0;
                    }
                }
                g_first_leg_ticket = 0; // Reset as this OIO sequence is complete or part-complete
            }
            return; // Processed TP closure
        }


        // --- Scenario 2 & 3: Initial or Second order gets filled (opened) ---
        if (deal_entry == DEAL_ENTRY_IN) { // Order opened
            // --- Initial order triggered ---
            if (!g_initial_order_triggered_for_active_oio || g_active_oio_k3_time != g_oio.time) { // Check if this is a new OIO trigger
                if (order_ticket == g_initial_buy_ticket && order_type == ORDER_TYPE_BUY) {
                    PrintFormat("Initial Buy Order #%d Triggered.", order_ticket);
                    if(!OrderSelect(order_ticket)) return;
                    g_active_oio_midpoint = g_oio.midpoint;
                    g_active_initial_buy_sl = OrderGetDouble(ORDER_SL);
                    g_active_oio_k3_time = g_oio.time; // Associate with current OIO time

                    g_first_leg_ticket = order_ticket; // Store as first leg
                    g_first_leg_open_price = deal_price; // or OrderOpenPrice()
                    g_first_leg_lots = deal_lots; // or OrderLots()
                    g_first_leg_order_type = ORDER_TYPE_BUY;

                    CancelOrder(g_initial_sell_ticket, "InitBuy Triggered"); g_initial_sell_ticket = 0;
                    PlaceSecondOrder(ORDER_TYPE_BUY_LIMIT, symbol, timeframe);
                    g_initial_buy_ticket = 0; // Clear initial ticket as it's now a market order
                    g_initial_order_triggered_for_active_oio = true;

                } else if (order_ticket == g_initial_sell_ticket && order_type == ORDER_TYPE_SELL) {
                    PrintFormat("Initial Sell Order #%d Triggered.", order_ticket);
                    if(!OrderSelect(order_ticket)) return;
                    g_active_oio_midpoint = g_oio.midpoint;
                    g_active_initial_sell_sl = OrderGetDouble(ORDER_SL);
                    g_active_oio_k3_time = g_oio.time;

                    g_first_leg_ticket = order_ticket;
                    g_first_leg_open_price = deal_price;
                    g_first_leg_lots = deal_lots;
                    g_first_leg_order_type = ORDER_TYPE_SELL;

                    CancelOrder(g_initial_buy_ticket, "InitSell Triggered"); g_initial_buy_ticket = 0;
                    PlaceSecondOrder(ORDER_TYPE_SELL_LIMIT, symbol, timeframe);
                    g_initial_sell_ticket = 0;
                    g_initial_order_triggered_for_active_oio = true;
                }
            }

            // --- Second order triggered ---
            // Check if the K3 time of active OIO matches current g_oio.time to ensure context
            if (g_initial_order_triggered_for_active_oio && g_active_oio_k3_time == g_oio.time) {
                 if ((order_ticket == g_second_buy_ticket && order_type == ORDER_TYPE_BUY) ||
                     (order_ticket == g_second_sell_ticket && order_type == ORDER_TYPE_SELL)) {
                    PrintFormat("Second %s Order #%d Triggered.", (order_type == ORDER_TYPE_BUY ? "Buy" : "Sell"), order_ticket);

                    if (g_first_leg_ticket == 0 || g_first_leg_lots == 0) {
                        Print("Error: First leg data missing for TP adjustment.");
                        return;
                    }
                    if (!OrderSelect(g_first_leg_ticket) || !OrderSelect(order_ticket)) {
                         Print("Error: Cannot select both orders for TP adjustment.");
                         return;
                    }

                    double second_leg_open_price = deal_price; // or OrderOpenPrice() for second order
                    double second_leg_lots = deal_lots; // or OrderLots() for second order

                    double total_lots = g_first_leg_lots + second_leg_lots;
                    if (total_lots == 0) { Print("Error: Total lots is zero for TP adjustment."); return; }

                    double avg_open_price = ((g_first_leg_open_price * g_first_leg_lots) + (second_leg_open_price * second_leg_lots)) / total_lots;
                    avg_open_price = NormalizeDouble(avg_open_price, SymbolInfoInteger(symbol, SYMBOL_DIGITS));
                    PrintFormat("Avg Open Price for #%d & #%d: %.5f (L1:%.2f@%.5f, L2:%.2f@%.5f)",
                                g_first_leg_ticket, order_ticket, avg_open_price,
                                g_first_leg_lots, g_first_leg_open_price, second_leg_lots, second_leg_open_price);

                    double tick_size = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
                    double new_tp_price;

                    if (order_type == ORDER_TYPE_BUY) { // Both orders are buys
                        new_tp_price = NormalizeDouble(avg_open_price + InpProfitAdjustmentTicks * tick_size, SymbolInfoInteger(symbol, SYMBOL_DIGITS));
                        PrintFormat("Adjusting TP for Buy orders #%d and #%d to %.5f", g_first_leg_ticket, order_ticket, new_tp_price);
                        ModifyOrderTP(g_first_leg_ticket, new_tp_price);
                        ModifyOrderTP(order_ticket, new_tp_price);
                        g_second_buy_ticket = 0; // Clear as it's now a market order
                    } else if (order_type == ORDER_TYPE_SELL) { // Both orders are sells
                        new_tp_price = NormalizeDouble(avg_open_price - InpProfitAdjustmentTicks * tick_size, SymbolInfoInteger(symbol, SYMBOL_DIGITS));
                        PrintFormat("Adjusting TP for Sell orders #%d and #%d to %.5f", g_first_leg_ticket, order_ticket, new_tp_price);
                        ModifyOrderTP(g_first_leg_ticket, new_tp_price);
                        ModifyOrderTP(order_ticket, new_tp_price);
                        g_second_sell_ticket = 0; // Clear as it's now a market order
                    }
                    // After TP adjustment, this OIO sequence's active management is mostly done from TP/SL perspective
                    // g_first_leg_ticket = 0; // Consider resetting, or wait for positions to close.
                 }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| PlaceSecondOrder                                                 |
//+------------------------------------------------------------------+
void PlaceSecondOrder(ENUM_ORDER_TYPE orderType, string symbol, ENUM_TIMEFRAMES timeframe) {
    if (g_active_oio_midpoint == 0) { Print("SecOrder: OIO Midpoint not set."); return; }
    if ((orderType == ORDER_TYPE_BUY_LIMIT && g_second_buy_ticket != 0 && OrderSelect(g_second_buy_ticket)) ||
        (orderType == ORDER_TYPE_SELL_LIMIT && g_second_sell_ticket != 0 && OrderSelect(g_second_sell_ticket))) {
         if(OrderGetInteger(ORDER_STATE) < ORDER_STATE_FILLED) {Print("SecOrder already pending."); return;}
    }

    int d = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
    double lots = NormalizeLots(InpSecondOrderLots, symbol);
    if(lots == 0) { Print("SecOrder: Normalized lots is zero."); return; }

    double open_price = NormalizeDouble(g_active_oio_midpoint, d);
    double sl = 0; string cmt = "";

    if(orderType == ORDER_TYPE_BUY_LIMIT) {
        if(g_active_initial_buy_sl == 0) { Print("SecBuy SL not set!"); return; }
        sl = NormalizeDouble(g_active_initial_buy_sl, d);
        cmt = "OIO_SecBuy" + TimeToString(g_active_oio_k3_time, "_%y%m%d%H%M");
        SendOrder(orderType, symbol, lots, open_price, sl, 0, cmt, 0, g_second_buy_ticket); // No TP, GTC
    } else if (orderType == ORDER_TYPE_SELL_LIMIT) {
        if(g_active_initial_sell_sl == 0) { Print("SecSell SL not set!"); return; }
        sl = NormalizeDouble(g_active_initial_sell_sl, d);
        cmt = "OIO_SecSell" + TimeToString(g_active_oio_k3_time, "_%y%m%d%H%M");
        SendOrder(orderType, symbol, lots, open_price, sl, 0, cmt, 0, g_second_sell_ticket); // No TP, GTC
    }
}

//+------------------------------------------------------------------+
//| CancelOrder                                                      |
//+------------------------------------------------------------------+
void CancelOrder(long ticket, string reason = "") {
    if (ticket == 0) return;
    if (OrderSelect(ticket)) {
        if (OrderGetInteger(ORDER_TYPE) >= ORDER_TYPE_BUY_LIMIT && OrderGetInteger(ORDER_TYPE) <= ORDER_TYPE_SELL_STOP_LIMIT) { // Is pending
            MqlTradeRequest req; MqlTradeResult res; ZeroMemory(req); ZeroMemory(res);
            req.action = TRADE_ACTION_REMOVE; req.order = ticket;
            PrintFormat("Cancelling Order #%d. Reason: %s", ticket, reason);
            if (!OrderSend(req, res)) PrintFormat("Cancel #%d Failed. Err: %d", ticket, GetLastError());
            else PrintFormat("Cancel #%d Sent. RetCode: %d", ticket, res.retcode);
        }
    }
}

//+------------------------------------------------------------------+
//| ModifyOrderTP                                                    |
//+------------------------------------------------------------------+
bool ModifyOrderTP(long ticket, double new_tp_price) {
    if (ticket == 0 || new_tp_price <= 0) return false;
    if (!OrderSelect(ticket)) { PrintFormat("ModifyTP: OrderSelect #%d failed.", ticket); return false; }

    // Ensure it's a market order (not pending)
    if (OrderGetInteger(ORDER_STATE) != ORDER_STATE_FILLED && OrderGetInteger(ORDER_STATE) != ORDER_STATE_STARTED /*might be partially filled*/) {
         PrintFormat("ModifyTP: Order #%d is not a market order. State: %s", ticket, EnumToString((ENUM_ORDER_STATE)OrderGetInteger(ORDER_STATE)));
         return false;
    }

    MqlTradeRequest request; MqlTradeResult result;
    ZeroMemory(request); ZeroMemory(result);

    request.action = TRADE_ACTION_SLTP; // Action for modifying SL/TP
    request.symbol = OrderGetString(ORDER_SYMBOL);
    request.order = ticket;
    request.tp = new_tp_price;
    request.sl = OrderGetDouble(ORDER_SL); // Keep original SL

    PrintFormat("Modifying TP for order #%d to %.5f (SL remains %.5f)", ticket, new_tp_price, request.sl);
    if (!OrderSend(request, result)) {
        PrintFormat("Modify TP for #%d Failed. Error: %d", ticket, GetLastError());
        return false;
    } else {
        PrintFormat("Modify TP for #%d Sent. RetCode: %d. Server Comment: %s", ticket, result.retcode, result.comment);
        if (result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_PLACED) return true; // Placed might mean accepted for processing
    }
    return false;
}

//+------------------------------------------------------------------+
//| SendOrder (helper)                                               |
//+------------------------------------------------------------------+
void SendOrder(ENUM_ORDER_TYPE type, string symbol, double lots, double price, double sl, double tp, string comment, datetime expiration, long& ticket_var) {
    MqlTradeRequest req; MqlTradeResult res; ZeroMemory(req); ZeroMemory(res);
    req.action = (type >= ORDER_TYPE_BUY_LIMIT && type <= ORDER_TYPE_SELL_STOP_LIMIT) ? TRADE_ACTION_PENDING : TRADE_ACTION_DEAL;
    req.symbol = symbol; req.volume = lots; req.magic = InpMagicNumber;
    req.type = type; req.price = price; req.sl = sl; req.tp = tp;
    req.comment = comment; req.expiration = expiration;
    req.type_filling = ORDER_FILLING_RETURN; // Try to get a result

    string typeStr = EnumToString(type);
    PrintFormat("Sending %s: V%.2f P%.*f SL%.*f TP%.*f Exp:%s Cmt:%s", typeStr, lots,
                SymbolInfoInteger(symbol, SYMBOL_DIGITS), price, SymbolInfoInteger(symbol, SYMBOL_DIGITS), sl, SymbolInfoInteger(symbol, SYMBOL_DIGITS), tp,
                TimeToString(expiration), comment);

    if (!OrderSend(req, res)) PrintFormat("%s Send Failed. Err: %d", typeStr, GetLastError());
    else {
        PrintFormat("%s Sent. RetCode:%d, Deal:%d, Order:%d, Comment:%s", typeStr, res.retcode, res.deal, res.order, res.comment);
        if (res.retcode == TRADE_RETCODE_PLACED || res.retcode == TRADE_RETCODE_DONE) { // For pending, Placed is key
            if (req.action == TRADE_ACTION_PENDING) ticket_var = res.order;
            // For market orders, res.order might be the market order ticket
        } else if (res.retcode == TRADE_RETCODE_REJECT) {
             PrintFormat("Order REJECTED by server. Reason: %s", res.comment);
        }
    }
}
//+------------------------------------------------------------------+
//| NormalizeLots (helper)                                           |
//+------------------------------------------------------------------+
double NormalizeLots(double lots, string symbol) {
    double min_lot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
    double max_lot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
    double lot_step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
    if (lot_step == 0) { Print("LotStep is zero!"); return 0;} // Avoid division by zero

    lots = MathMax(min_lot, MathRound(lots / lot_step) * lot_step);
    lots = MathMin(max_lot, lots);
    if (lots < min_lot && min_lot > 0) lots = min_lot; // ensure it's at least min_lot if min_lot is positive
    if (lots > max_lot && max_lot > 0) lots = max_lot; // ensure it's not over max_lot
    return lots;
}
//+------------------------------------------------------------------+

```

**步骤4的关键逻辑点：**

1.  **新的全局变量**：
    *   `InpProfitAdjustmentTicks`: 输入参数，用于调整止盈时，平均成本价 +/- N \* tick\_size。
    *   `g_first_leg_ticket`, `g_first_leg_open_price`, `g_first_leg_lots`, `g_first_leg_order_type`: 存储第一个被触发的初始订单的详细信息，用于后续计算平均成本。

2.  **`IdentifyOIO()`**:
    *   在识别新的有效OIO时，重置 `g_first_leg_ticket = 0;`，为新的OIO序列做准备。

3.  **`OnTradeTransaction()`**:
    *   **处理初始单止盈 (DEAL\_REASON\_TP)**:
        *   如果成交的订单是 `g_first_leg_ticket`（即已记录的第一个触发的初始单），并且是由于止盈平仓。
        *   则取消对应的第二挂单（`g_second_buy_ticket` 或 `g_second_sell_ticket`）。
        *   清零 `g_second_buy_ticket`/`g_second_sell_ticket` 和 `g_first_leg_ticket`。
    *   **处理初始单触发 (DEAL\_ENTRY\_IN for g\_initial\_buy/sell\_ticket)**:
        *   （与步骤3逻辑类似）当初始订单触发时，除了之前的操作，还会将该订单的票号、开仓价、手数和类型存储到 `g_first_leg_...` 系列全局变量中。
    *   **处理第二单触发 (DEAL\_ENTRY\_IN for g\_second\_buy/sell\_ticket)**:
        *   确保 `g_first_leg_ticket` 有效（即初始单已触发并记录）。
        *   获取第二单的开仓价和手数。
        *   计算 `g_first_leg_order` 和当前第二单的**平均开仓价**。
        *   根据平均开仓价和 `InpProfitAdjustmentTicks` 计算新的统一止盈价。
        *   调用 `ModifyOrderTP()` 分别修改第一单（`g_first_leg_ticket`）和当前第二单的止盈到这个新价格。它们的原始止损保持不变。
        *   清零 `g_second_buy_ticket`/`g_second_sell_ticket` 因为它们现在是市价单，其挂单身份已结束。

4.  **新函数 `ModifyOrderTP()`**:
    *   接收订单票号和新的止盈价格。
    *   使用 `TRADE_ACTION_SLTP` 来修改指定订单的止盈，保持其原始止损不变。

5.  **辅助函数 `SendOrder()` 和 `NormalizeLots()`**:
    *   `SendOrder` 是一个集中的下单函数，简化了 `OrderSend` 的调用。
    *   `NormalizeLots` 用于确保手数符合服务器要求。

这个版本的 `OnTradeTransaction` 变得相当复杂，因为它需要处理多种成交事件和订单状态转换。我已经尽力确保逻辑的清晰和覆盖README的要求。
