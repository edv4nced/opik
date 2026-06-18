//+------------------------------------------------------------------+
//|  FOREX_Exaustao_Tendencia.mq5                                    |
//|  Expert Advisor — Exaustão de Tendência por Volatilidade e Volume|
//|                                                                  |
//|  Estratégia: Reversão à média por exaustão institucional         |
//|  Filtros  : Bollinger (rejeição) + Tick Volume + ADX + RSI       |
//|             + EMA tendência + ATR dinâmico + disciplina diária   |
//|                                                                  |
//|  Versão MQL5 — adaptada da versão NTSL/Profit Pro v3.1          |
//|  Compatível com MetaTrader 5 (build 3000+)                       |
//|                                                                  |
//|  Como instalar:                                                  |
//|    1. Copiar este arquivo para:                                  |
//|       MQL5/Experts/ (pasta do seu terminal MT5)                  |
//|    2. Compilar no MetaEditor (F7)                                |
//|    3. Arrastar o EA para o gráfico do par desejado               |
//|    4. Configurar os parâmetros na aba "Entradas"                 |
//|    5. Habilitar "Negociação ao vivo" nas configurações do EA     |
//|                                                                  |
//|  Backtesting (Strategy Tester):                                  |
//|    Menu: Exibir → Strategy Tester (Ctrl+R)                       |
//|    Modo: "Cada tick baseado em preços reais" (mais preciso)      |
//|    Ou:   "Preços de abertura" (mais rápido, adequado para M5+)  |
//+------------------------------------------------------------------+
#property copyright   "Exaustão de Tendência EA"
#property version     "1.00"
#property description "Reversão à média por exaustão institucional"
#property description "Bollinger + Tick Volume + ADX + RSI + EMA + ATR"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//+------------------------------------------------------------------+
//| SEÇÃO 1: PARÂMETROS DE ENTRADA                                   |
//+------------------------------------------------------------------+

// ATENÇÃO HORÁRIO: MT5 usa o fuso do servidor da corretora.
// Verifique em: Ferramentas → Opções → Servidor → Hora local vs. servidor.
// Brokers europeus: geralmente UTC+2 (verão) ou UTC+3 (inverno/EET).
// Brokers brasileiros: pode ser BRT (UTC-3) ou outro.

input group "=== Horário de Operação ==="
input int  HoraInicio  = 1300; // Início da janela (HHMM no fuso do servidor)
input int  HoraFim     = 1700; // Fim de novas entradas
input int  HoraZerar   = 1730; // Fechamento compulsório de posições
input bool FecharNoDia = true; // true=day trade puro | false=pode carregar overnight

input group "=== Bandas de Bollinger ==="
input int    PeriodoBanda = 20;  // Períodos da banda (SMA base)
input double DesvioBanda  = 2.5; // Número de desvios padrão

input group "=== Filtro de Tick Volume ==="
// No Forex NÃO existe volume financeiro real. Apenas tick volume
// (número de variações de preço por candle) está disponível.
// FatorVolume mais alto (2.0) compensa o maior ruído do tick volume.
input int    PeriodoVolume = 20;  // Períodos da média de tick volume
input double FatorVolume   = 2.0; // Limiar: volume mínimo = média × fator

input group "=== ADX — Regime de Mercado ==="
// ADX < LimiteADX = mercado lateral = terreno para reversão.
// ADX alto = tendência = Bollinger falha = bloqueado.
input int    PeriodoADX = 14;   // Período do ADX
input double LimiteADX  = 25.0; // Acima deste valor → tendência → não opera

input group "=== RSI — Exaustão Direcional ==="
input int    PeriodoRSI      = 14;   // Período do RSI
input double LimiteRSIBaixo  = 35.0; // RSI abaixo = sobrevenda confirmada (Long)
input double LimiteRSIAlto   = 65.0; // RSI acima = sobrecompra confirmada (Short)

input group "=== Filtro de Largura de Banda ==="
// Banda muito estreita = mercado comprimido, explosão iminente.
// Banda muito larga = tendência disfarçada.
// Ajuste por par: EURUSD M5 → Min 0.05 / Max 0.60
//                 GBPUSD M5 → Min 0.06 / Max 0.70
input double LarguraMinPct = 0.05; // Largura mínima em % do preço médio
input double LarguraMaxPct = 0.60; // Largura máxima em % do preço médio

input group "=== EMA — Tendência Intraday ==="
// Long só acima da EMA, Short só abaixo.
// 50 períodos em M5 ≈ últimas 4h | em M15 ≈ últimas 12h.
input int PeriodoEMA = 50;

input group "=== ATR — Stop e Alvo Dinâmicos ==="
// Stop = ATR × MultiplicadorStop | Alvo = ATR × MultiplicadorAlvo
// R:R ≈ 2.5 / 1.5 = 1.67 (constante, adapta-se à volatilidade do dia)
input int    PeriodoATR        = 14;  // Período do ATR
input double MultiplicadorStop = 1.5; // Stop  = ATR × este valor
input double MultiplicadorAlvo = 2.5; // Alvo  = ATR × este valor

input group "=== Gestão de Lote ==="
input double LotSize = 0.01; // Lote por operação (0.01 = micro, 0.10 = mini, 1.00 = padrão)

input group "=== Disciplina Operacional ==="
input int MaxTradesDia = 3; // Máximo de entradas por sessão
input int BaresEspera  = 3; // Candles de pausa após encerrar posição

input group "=== Meta e Perda Diária (em pips) ==="
// Exemplos EURUSD: MetaPipsDia=150 → para ao lucrar 150 pips
//                  MaxPerdaDiariaPips=100 → para ao perder 100 pips
// Exemplos USDJPY: mesmos valores em pips (1 pip USDJPY = 0.01)
input int MetaPipsDia        = 150; // Meta de ganho diária em pips
input int MaxPerdaDiariaPips = 100; // Stop de perda diária em pips

//+------------------------------------------------------------------+
//| SEÇÃO 2: VARIÁVEIS GLOBAIS                                       |
//+------------------------------------------------------------------+

// Objetos de trading
CTrade        trade;
CPositionInfo posInfo;

// Handles de indicadores (criados no OnInit, liberados no OnDeinit)
int handleBB;
int handleADX;
int handleRSI;
int handleEMA;
int handleATR;

// Número mágico único deste EA (identifica suas ordens no servidor)
const long EA_MAGIC = 20250618;

// Tamanho do pip calculado no OnInit
double pipSize;

// Estado persistente entre barras (resetado no OnInit)
datetime lastBarTime      = 0;
datetime DataAnterior     = 0;
int      ContadorTrades   = 0;
double   LucroDiario      = 0.0;
int      CoolDown         = 0;
bool     PosicaoAnt       = false;
double   PrecoEntradaSalvo = 0.0;
double   PrecoAlvoSalvo    = 0.0;
double   PrecoStopSalvo    = 0.0;
bool     DirecaoLong       = true;
double   ValorRSIAnt       = 50.0;

//+------------------------------------------------------------------+
//| SEÇÃO 3: OnInit — Inicialização do EA                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   // Reseta estado (importante ao mudar parâmetros sem reiniciar)
   lastBarTime       = 0;
   DataAnterior      = 0;
   ContadorTrades    = 0;
   LucroDiario       = 0.0;
   CoolDown          = 0;
   PosicaoAnt        = false;
   PrecoEntradaSalvo = 0.0;
   PrecoAlvoSalvo    = 0.0;
   PrecoStopSalvo    = 0.0;
   DirecaoLong       = true;
   ValorRSIAnt       = 50.0;

   // Calcula tamanho do pip conforme o número de dígitos do par:
   //   5 dígitos (EURUSD, GBPUSD): _Point = 0.00001, pip = 0.0001
   //   3 dígitos (USDJPY, EURJPY): _Point = 0.001,   pip = 0.01
   pipSize = (_Digits == 5 || _Digits == 3) ? 10.0 * _Point : _Point;

   // Cria handles dos indicadores (alocação na memória do terminal)
   handleBB  = iBands(_Symbol, PERIOD_CURRENT, PeriodoBanda, 0, DesvioBanda, PRICE_CLOSE);
   handleADX = iADX(_Symbol,   PERIOD_CURRENT, PeriodoADX);
   handleRSI = iRSI(_Symbol,   PERIOD_CURRENT, PeriodoRSI, PRICE_CLOSE);
   handleEMA = iMA(_Symbol,    PERIOD_CURRENT, PeriodoEMA, 0, MODE_EMA, PRICE_CLOSE);
   handleATR = iATR(_Symbol,   PERIOD_CURRENT, PeriodoATR);

   if(handleBB  == INVALID_HANDLE || handleADX == INVALID_HANDLE ||
      handleRSI == INVALID_HANDLE || handleEMA == INVALID_HANDLE ||
      handleATR == INVALID_HANDLE)
     {
      Print("ERRO: falha ao criar handles dos indicadores. EA não iniciado.");
      return INIT_FAILED;
     }

   // Configurações do objeto de trade
   trade.SetExpertMagicNumber(EA_MAGIC);
   trade.SetDeviationInPoints(30); // Slippage máximo aceito (30 pontos)

   // Define o tipo de preenchimento suportado pelo broker/símbolo
   ENUM_ORDER_TYPE_FILLING fillingMode = GetFillingMode();
   trade.SetTypeFilling(fillingMode);

   PrintFormat("EA iniciado | Par: %s | Dígitos: %d | Pip: %.5f | Lote: %.2f | Filling: %s",
               _Symbol, _Digits, pipSize, LotSize, EnumToString(fillingMode));
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| SEÇÃO 4: OnDeinit — Limpeza ao remover o EA                     |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   IndicatorRelease(handleBB);
   IndicatorRelease(handleADX);
   IndicatorRelease(handleRSI);
   IndicatorRelease(handleEMA);
   IndicatorRelease(handleATR);
   PrintFormat("EA removido. Motivo: %d", reason);
  }

//+------------------------------------------------------------------+
//| SEÇÃO 5: FUNÇÕES AUXILIARES                                      |
//+------------------------------------------------------------------+

// Retorna o tipo de preenchimento suportado pelo símbolo
ENUM_ORDER_TYPE_FILLING GetFillingMode()
  {
   uint fillingBits = (uint)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((fillingBits & SYMBOL_FILLING_IOC) != 0) return ORDER_FILLING_IOC;
   if((fillingBits & SYMBOL_FILLING_FOK) != 0) return ORDER_FILLING_FOK;
   return ORDER_FILLING_RETURN;
  }

// Retorna horário atual como inteiro HHMM (ex: 13h25 = 1325)
int GetHoraAtual()
  {
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   return t.hour * 100 + t.min;
  }

// Lê um valor de buffer de indicador na barra FECHADA (shift=1)
// shift=1 → última barra completa (evita leitura de barra em formação)
double GetBuffer(int handle, int bufferIdx, int shift = 1)
  {
   double arr[];
   ArraySetAsSeries(arr, true);
   if(CopyBuffer(handle, bufferIdx, shift, 1, arr) != 1)
     {
      PrintFormat("AVISO: erro ao ler buffer %d do handle %d.", bufferIdx, handle);
      return 0.0;
     }
   return arr[0];
  }

// Calcula a média de tick volume das últimas N barras fechadas
double GetMediaVolume(int periodo)
  {
   long vol[];
   ArraySetAsSeries(vol, true);
   // shift=1: começa da última barra fechada, não da atual (em formação)
   if(CopyTickVolume(_Symbol, PERIOD_CURRENT, 1, periodo, vol) != periodo)
      return 0.0;
   double soma = 0.0;
   for(int i = 0; i < periodo; i++) soma += (double)vol[i];
   return soma / periodo;
  }

// Verifica se há posição aberta deste EA neste símbolo
bool HasPosition()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetSymbol(i) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == EA_MAGIC)
         return true;
     }
   return false;
  }

// Fecha todas as posições deste EA neste símbolo
void FecharPosicao()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetSymbol(i) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == EA_MAGIC)
        {
         ulong ticket = PositionGetInteger(POSITION_TICKET);
         trade.PositionClose(ticket);
        }
     }
  }

// Normaliza e ajusta o lote dentro dos limites do broker
double ValidarLote(double lotDesejado)
  {
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double lotMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double lotMax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lot     = MathRound(lotDesejado / lotStep) * lotStep;
   return NormalizeDouble(MathMax(lotMin, MathMin(lotMax, lot)), 2);
  }

// Garante que SL/TP respeita a distância mínima exigida pelo broker
double AjustarNivelStop(double precoEntrada, double nivel,
                        bool ehStop, bool ehLong)
  {
   int    stopPontos = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double distMin    = stopPontos * _Point;
   double dist       = MathAbs(precoEntrada - nivel);

   if(dist < distMin)
     {
      if(ehLong)
         nivel = ehStop ? precoEntrada - distMin : precoEntrada + distMin;
      else
         nivel = ehStop ? precoEntrada + distMin : precoEntrada - distMin;

      PrintFormat("AVISO: nível ajustado para distância mínima de %d pontos.", stopPontos);
     }

   return NormalizeDouble(nivel, _Digits);
  }

//+------------------------------------------------------------------+
//| SEÇÃO 6: OnTick — Lógica Principal (executa a cada tick)         |
//+------------------------------------------------------------------+
void OnTick()
  {
   //----------------------------------------------------------------
   // GATE DE BARRA: só executa no abrir de cada nova barra (bar-close)
   // Garante que os sinais são avaliados sobre barras completas.
   //----------------------------------------------------------------
   datetime barraAtual = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(barraAtual == lastBarTime) return;
   lastBarTime = barraAtual;

   //----------------------------------------------------------------
   // RESET DIÁRIO
   // Compara a data atual com a da última execução.
   // Zera ContadorTrades e LucroDiario no início de cada sessão.
   //----------------------------------------------------------------
   MqlDateTime hoje;
   TimeToStruct(TimeCurrent(), hoje);
   datetime inicioDia = StringToTime(
      StringFormat("%04d.%02d.%02d 00:00", hoje.year, hoje.mon, hoje.day));

   if(inicioDia != DataAnterior)
     {
      ContadorTrades = 0;
      LucroDiario    = 0.0;
      DataAnterior   = inicioDia;
      PrintFormat("Nova sessão: %s | Contadores zerados.", TimeToString(inicioDia, TIME_DATE));
     }

   //----------------------------------------------------------------
   // RASTREAMENTO DE P&L PÓS-ENCERRAMENTO
   // Detecta quando posição fechou (PosicaoAnt=true, HasPosition=false).
   // Determina resultado pelo nível atingido na barra de saída (índice 1).
   //----------------------------------------------------------------
   bool posicaoAtual = HasPosition();

   if(PosicaoAnt && !posicaoAtual)
     {
      // Preços da barra em que a posição foi encerrada (índice 1 = última fechada)
      double highSaida  = iHigh(_Symbol,  PERIOD_CURRENT, 1);
      double lowSaida   = iLow(_Symbol,   PERIOD_CURRENT, 1);
      double closeSaida = iClose(_Symbol, PERIOD_CURRENT, 1);
      double resultado  = 0.0;

      if(DirecaoLong)
        {
         if(lowSaida <= PrecoStopSalvo)
            resultado = PrecoStopSalvo - PrecoEntradaSalvo;    // Stop atingido (negativo)
         else if(highSaida >= PrecoAlvoSalvo)
            resultado = PrecoAlvoSalvo - PrecoEntradaSalvo;    // Alvo atingido (positivo)
         else
            resultado = closeSaida - PrecoEntradaSalvo;        // Zeragem/manual
        }
      else
        {
         if(highSaida >= PrecoStopSalvo)
            resultado = PrecoEntradaSalvo - PrecoStopSalvo;    // Stop atingido (negativo)
         else if(lowSaida <= PrecoAlvoSalvo)
            resultado = PrecoEntradaSalvo - PrecoAlvoSalvo;    // Alvo atingido (positivo)
         else
            resultado = PrecoEntradaSalvo - closeSaida;        // Zeragem/manual
        }

      LucroDiario += resultado;
      CoolDown     = BaresEspera;

      PrintFormat("Encerramento %s | Resultado: %+.1f pips | Lucro dia: %+.1f pips",
                  DirecaoLong ? "LONG" : "SHORT",
                  resultado    / pipSize,
                  LucroDiario  / pipSize);
     }

   PosicaoAnt = posicaoAtual;

   // Decrementa cool-down a cada barra
   if(CoolDown > 0) CoolDown--;

   //----------------------------------------------------------------
   // CONTROLE DE HORÁRIO
   //----------------------------------------------------------------
   int  horaAtual    = GetHoraAtual();
   bool janelaAberta = (horaAtual >= HoraInicio) && (horaAtual < HoraFim);
   bool deveZerar    = FecharNoDia && (horaAtual >= HoraZerar);

   //----------------------------------------------------------------
   // ZERAGEM COMPULSÓRIA (prioridade máxima)
   //----------------------------------------------------------------
   if(deveZerar && HasPosition())
     {
      FecharPosicao();
      Print("Zeragem compulsória executada.");
      return;
     }

   //----------------------------------------------------------------
   // LEITURA DOS INDICADORES
   // Todos com shift=1: valores da última barra FECHADA.
   // iBands buffers: 0=Média, 1=Superior, 2=Inferior
   // iADX  buffers: 0=ADX, 1=+DI, 2=-DI
   //----------------------------------------------------------------
   double bandaSup = GetBuffer(handleBB,  1); // Banda Superior
   double bandaInf = GetBuffer(handleBB,  2); // Banda Inferior
   double bandaMid = GetBuffer(handleBB,  0); // Média central (SMA)
   double valorADX = GetBuffer(handleADX, 0); // ADX
   double valorRSI = GetBuffer(handleRSI, 0); // RSI
   double valorEMA = GetBuffer(handleEMA, 0); // EMA(50)
   double valorATR = GetBuffer(handleATR, 0); // ATR(14)

   // Preços OHLC da barra fechada (índice 1)
   double closeAnt = iClose(_Symbol, PERIOD_CURRENT, 1);
   double highAnt  = iHigh(_Symbol,  PERIOD_CURRENT, 1);
   double lowAnt   = iLow(_Symbol,   PERIOD_CURRENT, 1);

   // Tick volume da barra fechada e média dos últimos N períodos
   long   volBruto[1];
   ArraySetAsSeries(volBruto, true);
   CopyTickVolume(_Symbol, PERIOD_CURRENT, 1, 1, volBruto);
   double volAtual  = (double)volBruto[0];
   double mediaVol  = GetMediaVolume(PeriodoVolume);

   // Largura percentual da banda (bandaMid != 0 evita divisão por zero)
   double larguraPct = (bandaMid > 0) ? ((bandaSup - bandaInf) / bandaMid) * 100.0 : 0.0;

   //----------------------------------------------------------------
   // AVALIAÇÃO DOS CRITÉRIOS ATÔMICOS
   // Cada critério é uma variável bool independente.
   // Separação facilita debug no log do terminal e ablação no tester.
   //----------------------------------------------------------------

   // [v1] Critérios base
   bool crit_RejeicaoLong  = (lowAnt  < bandaInf) && (closeAnt >= bandaInf);
   bool crit_RejeicaoShort = (highAnt > bandaSup) && (closeAnt <= bandaSup);
   bool crit_Volume        = (mediaVol > 0) && (volAtual > mediaVol * FatorVolume);
   bool crit_ADX           = (valorADX < LimiteADX);
   bool crit_RSILong       = (valorRSI < LimiteRSIBaixo);
   bool crit_RSIShort      = (valorRSI > LimiteRSIAlto);
   bool crit_LarguraBanda  = (larguraPct >= LarguraMinPct) && (larguraPct <= LarguraMaxPct);

   // [v3] Critérios de alta precisão
   bool crit_EMALong       = (closeAnt > valorEMA);
   bool crit_EMAShort      = (closeAnt < valorEMA);
   bool crit_MomLong       = (ValorRSIAnt > 0) && (valorRSI > ValorRSIAnt);  // RSI virando ↑
   bool crit_MomShort      = (ValorRSIAnt > 0) && (valorRSI < ValorRSIAnt);  // RSI virando ↓

   // [disciplina] Meta e perda em pips convertidos para unidades de preço
   double metaPreco  = MetaPipsDia        * pipSize;
   double perdaPreco = MaxPerdaDiariaPips * pipSize;
   bool crit_Disciplina = (ContadorTrades < MaxTradesDia)
                       && (LucroDiario    < metaPreco)
                       && (LucroDiario    > -perdaPreco);

   //----------------------------------------------------------------
   // COMPOSIÇÃO DOS SINAIS FINAIS
   // Todos os critérios devem ser TRUE simultaneamente.
   //----------------------------------------------------------------
   bool sinalLong  = crit_RejeicaoLong  && crit_Volume && crit_ADX
                  && crit_RSILong       && crit_LarguraBanda
                  && crit_EMALong       && crit_MomLong  && crit_Disciplina;

   bool sinalShort = crit_RejeicaoShort && crit_Volume && crit_ADX
                  && crit_RSIShort      && crit_LarguraBanda
                  && crit_EMAShort      && crit_MomShort && crit_Disciplina;

   //----------------------------------------------------------------
   // EXECUÇÃO DAS ORDENS
   // Só executa se: dentro do horário + sem posição + sem cool-down
   //----------------------------------------------------------------
   if(janelaAberta && !HasPosition() && CoolDown == 0)
     {
      double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double lote = ValidarLote(LotSize);

      // ── COMPRA (LONG) ──────────────────────────────────────────
      if(sinalLong)
        {
         // Calcula SL e TP baseados no ATR da barra fechada
         double sl = NormalizeDouble(ask - valorATR * MultiplicadorStop, _Digits);
         double tp = NormalizeDouble(ask + valorATR * MultiplicadorAlvo, _Digits);

         // Garante distância mínima exigida pelo broker
         sl = AjustarNivelStop(ask, sl, true,  true);
         tp = AjustarNivelStop(ask, tp, false, true);

         if(trade.Buy(lote, _Symbol, ask, sl, tp, "Exaustao_Long"))
           {
            PrecoEntradaSalvo = ask;
            PrecoStopSalvo    = sl;
            PrecoAlvoSalvo    = tp;
            DirecaoLong       = true;
            ContadorTrades++;

            PrintFormat("LONG ↑ | Entrada: %.5f | SL: %.5f (-%.0f pips) | TP: %.5f (+%.0f pips) | Lote: %.2f",
                        ask, sl, (ask - sl) / pipSize, tp, (tp - ask) / pipSize, lote);
           }
         else
           {
            PrintFormat("ERRO ao abrir LONG: %d — %s", GetLastError(), trade.ResultComment());
           }
        }

      // ── VENDA A DESCOBERTO (SHORT) ─────────────────────────────
      else if(sinalShort)
        {
         double sl = NormalizeDouble(bid + valorATR * MultiplicadorStop, _Digits);
         double tp = NormalizeDouble(bid - valorATR * MultiplicadorAlvo, _Digits);

         sl = AjustarNivelStop(bid, sl, true,  false);
         tp = AjustarNivelStop(bid, tp, false, false);

         if(trade.Sell(lote, _Symbol, bid, sl, tp, "Exaustao_Short"))
           {
            PrecoEntradaSalvo = bid;
            PrecoStopSalvo    = sl;
            PrecoAlvoSalvo    = tp;
            DirecaoLong       = false;
            ContadorTrades++;

            PrintFormat("SHORT ↓ | Entrada: %.5f | SL: %.5f (+%.0f pips) | TP: %.5f (-%.0f pips) | Lote: %.2f",
                        bid, sl, (sl - bid) / pipSize, tp, (bid - tp) / pipSize, lote);
           }
         else
           {
            PrintFormat("ERRO ao abrir SHORT: %d — %s", GetLastError(), trade.ResultComment());
           }
        }
     }

   //----------------------------------------------------------------
   // ATUALIZAÇÃO DE ESTADO PARA PRÓXIMA BARRA
   // ValorRSIAnt deve ser atualizado fora de qualquer condicional
   // para refletir sempre o RSI real da barra atual.
   //----------------------------------------------------------------
   ValorRSIAnt = valorRSI;
  }
//+------------------------------------------------------------------+
