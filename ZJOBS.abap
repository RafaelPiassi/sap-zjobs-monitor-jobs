*&---------------------------------------------------------------------*
*& Report  ZJOBS
*& Monitor e limpeza em massa de jobs de background (SM37)
*& Transacao: ZJOBS
*& Desenvolvedor: RPIASSI - Rafael Piassi
*&---------------------------------------------------------------------*
*& Objetivo:
*&   Selecionar jobs da TBTCO por nome / usuario / programa / status /
*&   data prevista, exibir em ALV e permitir CANCELAR (interromper) e
*&   DELETAR em massa, em quantidade que a SM37 nao trata bem.
*&
*&   Nasceu do incidente de 12/08/2026 da ZSDR1119, que agendou centenas
*&   de milhares de jobs 'ZSDR1119_BSF_M_*' - e periodicos, portanto se
*&   reagendando para todos os dias seguintes. A propria ZSDR1119 so
*&   cancela 2.000 por clique; aqui o volume e tratado em background, em
*&   lotes, sem teto e sem timeout de dialogo.
*&
*& Dois modos de execucao:
*&   1) ONLINE  - ALV (SALV) com selecao de linhas e botoes proprios:
*&                Marcar tudo / Cancelar / Deletar / Cancelar+Deletar /
*&                Atualizar / Background / Log.
*&                Limitado por P_MAX (teto por execucao) para nao
*&                esbarrar no timeout de dialogo (rdisp/max_wprun_time).
*&   2) DIRETO  - sem ALV, em job de background: le a selecao em lotes
*&                (5.000 por leitura), executa a acao escolhida, faz
*&                COMMIT WORK a cada N jobs e grava o log no spool. E o
*&                modo indicado para dezenas/centenas de milhares.
*&
*& Travas de seguranca (todas ligadas por padrao):
*&   - P_TEST  : simulacao. Nada e cancelado/deletado, so e logado.
*&   - P_PROT  : protege jobs criticos do SAP (SAP_*, RDD*, EU_*, /SDF/*,
*&               DBA:*, ...) e jobs de DDIC/SAPSYS/SAP*/TMSADM.
*&   - P_PROAT : nao mexe em jobs ATIVOS (status R).
*&   - P_MAX   : teto de jobs tratados por execucao (0 = sem teto, e so
*&               aceito em background).
*&   - P_PACK  : COMMIT WORK a cada N jobs (evita LUW gigante).
*&   - S_EXCL  : nomes de job a preservar, informados na tela.
*&   - O proprio job em que o programa esta rodando nunca e deletado
*&     (GET_JOB_RUNTIME_INFO).
*&   - Popup de confirmacao obrigatorio antes de qualquer acao.
*&
*& Premissas tecnicas:
*&   - Nenhum objeto novo alem do programa: SE38 + SE93. O ALV usa
*&     CL_SALV_TABLE com ADD_FUNCTION, portanto NAO precisa de status
*&     GUI proprio (SE41) nem de tela de dialogo (SE51).
*&   - Cancelar/deletar usam as FMs padrao BP_JOB_ABORT e BP_JOB_DELETE,
*&     as mesmas da SM37 - toda a verificacao de autorizacao (S_BTCH_ADM
*&     / S_BTCH_JOB) continua valendo.
*&   - "Cancelar" so faz sentido para job ATIVO (interrompe a execucao).
*&     Job PLANEJADO ou LIBERADO nao se cancela: deleta-se - e o delete
*&     ja remove o agendamento, inclusive de job periodico.
*&
*& Regra herdada do incidente da ZSDR1119: o evento AT SELECTION-SCREEN
*& tambem roda em background, e SSCRFIELDS-UCOMM sobrevive ao roundtrip
*& da tela. Por isso os botoes usam SSCRFIELDS-UCOMM com CLEAR ao final,
*& e as rotinas que criam job sao bloqueadas quando SY-BATCH nao esta
*& vazio.
*&---------------------------------------------------------------------*
" Se o programa for criado com outro nome (ZJOB, ZBCJOBS...), basta
" ajustar esta linha: o reagendamento em background usa SUBMIT
" (sy-repid), nao o nome fixo.
REPORT zjobs NO STANDARD PAGE HEADING LINE-SIZE 255.

TYPE-POOLS: icon, abap.

" Necessaria para ler o codigo de funcao dos pushbuttons da tela.
TABLES sscrfields.

"======================================================================
" Tipos locais
"======================================================================
TYPES:
  " Ranges montados a partir da tela. Range vazio = sem restricao, o que
  " permite um unico SELECT servir a todas as combinacoes de filtro.
  ty_r_job TYPE RANGE OF tbtco-jobname,
  ty_r_dat TYPE RANGE OF tbtco-sdldate,
  ty_r_per TYPE RANGE OF tbtco-periodic,

  " Linha do ALV / do processamento
  BEGIN OF ty_job,
    icone     TYPE c LENGTH 4,        "Semaforo do status
    jobname   TYPE tbtco-jobname,
    jobcount  TYPE tbtco-jobcount,
    status    TYPE tbtco-status,      "P/S/Y/R/F/A/X/Z
    status_tx TYPE c LENGTH 22,
    periodic  TYPE tbtco-periodic,
    period_tx TYPE c LENGTH 22,       "Periodicidade por extenso
    sdldate   TYPE tbtco-sdldate,     "Inicio previsto
    sdltime   TYPE tbtco-sdltime,
    strtdate  TYPE tbtco-strtdate,    "Inicio real
    strttime  TYPE tbtco-strttime,
    enddate   TYPE tbtco-enddate,     "Fim real
    endtime   TYPE tbtco-endtime,
    jobclass  TYPE tbtco-jobclass,
    sdluname  TYPE tbtco-sdluname,    "Quem agendou
    authcknam TYPE tbtco-authcknam,   "Usuario de execucao do step
    progname  TYPE tbtcp-progname,    "1o step
    variant   TYPE tbtcp-variant,
    steps     TYPE i,                 "Qtde de steps
    prdmins   TYPE tbtco-prdmins,     "Periodicidade (bruta)
    prdhours  TYPE tbtco-prdhours,
    prddays   TYPE tbtco-prddays,
    prdweeks  TYPE tbtco-prdweeks,
    prdmonths TYPE tbtco-prdmonths,
    protegido TYPE c LENGTH 1,        "'X' = nao pode ser tratado
    motivo    TYPE c LENGTH 60,       "Por que esta protegido
  END OF ty_job,
  tt_job TYPE STANDARD TABLE OF ty_job WITH DEFAULT KEY,

  " Chave usada para nao reprocessar o mesmo job no modo lote
  BEGIN OF ty_key,
    jobname  TYPE tbtco-jobname,
    jobcount TYPE tbtco-jobcount,
  END OF ty_key,

  " Log de execucao (uma linha por job tratado)
  BEGIN OF ty_log,
    icone    TYPE c LENGTH 4,
    jobname  TYPE tbtco-jobname,
    jobcount TYPE tbtco-jobcount,
    acao     TYPE c LENGTH 20,
    result   TYPE c LENGTH 1,         "S=ok E=erro W=ignorado
    resul_tx TYPE c LENGTH 14,
    msg      TYPE c LENGTH 120,
  END OF ty_log,
  tt_log TYPE STANDARD TABLE OF ty_log WITH DEFAULT KEY,

  ty_pref TYPE c LENGTH 20.

"======================================================================
" Constantes
"======================================================================
CONSTANTS:
  " Acoes que PARAM jobs
  c_can       TYPE c LENGTH 1 VALUE 'C',   "Cancelar (interromper ativo)
  c_del       TYPE c LENGTH 1 VALUE 'D',   "Deletar
  c_cde       TYPE c LENGTH 1 VALUE 'B',   "Cancelar + deletar

  " Acoes que DISPARAM jobs
  c_str       TYPE c LENGTH 1 VALUE 'I',   "Iniciar agora (copia + start)
  c_rel       TYPE c LENGTH 1 VALUE 'L',   "Liberar (job planejado)
  c_res       TYPE c LENGTH 1 VALUE 'G',   "Reagendar (copia p/ nova data)

  " Resultado do log
  c_ok        TYPE c LENGTH 1 VALUE 'S',
  c_er        TYPE c LENGTH 1 VALUE 'E',
  c_ig        TYPE c LENGTH 1 VALUE 'W',

  " Status de job (TBTCO-STATUS)
  c_st_plan   TYPE c LENGTH 1 VALUE 'P',   "Planejado
  c_st_libe   TYPE c LENGTH 1 VALUE 'S',   "Liberado
  c_st_pron   TYPE c LENGTH 1 VALUE 'Y',   "Pronto
  c_st_ativ   TYPE c LENGTH 1 VALUE 'R',   "Ativo
  c_st_conc   TYPE c LENGTH 1 VALUE 'F',   "Concluido
  c_st_canc   TYPE c LENGTH 1 VALUE 'A',   "Cancelado

  " Leitura em lotes no modo direto
  c_pack_sel  TYPE i VALUE 5000,           "Linhas por leitura na TBTCO
  c_max_test  TYPE i VALUE 20000,          "Teto de detalhe em simulacao
  c_max_log   TYPE i VALUE 5000,           "Teto de linhas de log guardadas
  c_max_alv   TYPE i VALUE 20000,          "Default de linhas no ALV
  c_teto_onl  TYPE i VALUE 2000,           "Teto implicito online (P_MAX=0)

  " Teto DURO das acoes de disparo. Parar job em massa e limpeza; iniciar
  " job em massa e carga na maquina - 1.000 execucoes simultaneas ja e
  " mais do que qualquer sistema absorve. Nao existe "sem teto" aqui.
  c_max_disp  TYPE i VALUE 1000,

  " Nome sugerido do job de limpeza em background
  c_job_lim   TYPE btcjob VALUE 'ZJOBS_LIMPEZA',

  " Preset do incidente da ZSDR1119. Abrange as duas familias que o loop
  " criou (ZSDR1119_BSF_M_* e ZSDR1119_ALV_M_*). Cuidado: pega tambem os
  " jobs legitimos do report (ZSDR1119_BSF_DIARIO / _AGORA) - se quiser
  " preserva-los, informe o nome em S_EXCL.
  c_pat_1119  TYPE tbtco-jobname VALUE 'ZSDR1119*',

  " Prefixos de job do proprio SAP / Basis que nunca devem cair numa
  " limpeza em massa feita por programa Z (trava P_PROT).
  c_pref_sap  TYPE c LENGTH 120
    VALUE 'SAP_;RDD;EU_;/SDF/;DBA:;SLCA;RSPO;RSCOL;COLLECTOR;LOAD_GENERATOR;SWW;BPM;SM:;CCMS'.

"======================================================================
" Variaveis globais
"======================================================================
DATA:
  gt_job     TYPE tt_job,
  gt_log     TYPE tt_log,
  gt_feito   TYPE HASHED TABLE OF ty_key WITH UNIQUE KEY jobname jobcount,
  gt_pref    TYPE TABLE OF ty_pref,     "Prefixos protegidos (1x na init)
  gr_alv     TYPE REF TO cl_salv_table,
  gr_log_alv TYPE REF TO cl_salv_table,

  " Contadores da ultima execucao
  gv_tot_sel TYPE i,                  "Total que a selecao retorna (COUNT)
  gv_proc    TYPE i,                  "Jobs tratados
  gv_ok      TYPE i,
  gv_erro    TYPE i,
  gv_ign     TYPE i,

  " Controle de tela / execucao
  gv_cmd     TYPE c LENGTH 1,         "'X' = clique em botao
  gv_acao    TYPE c LENGTH 1,         "Acao corrente (C/D/B/I/L/G)
  gv_mode_bg TYPE c LENGTH 1,         "'X' = modo direto (sem ALV)
  gv_pack    TYPE i,                  "P_PACK ja validado
  gv_teto    TYPE i,                  "Teto real da execucao em lotes
  gv_quick   TYPE c LENGTH 1,         "'X' = acao rapida (so o nome manda)

  " Identificacao do proprio job (para nunca se auto-deletar)
  gv_my_job  TYPE tbtco-jobname,
  gv_my_cnt  TYPE tbtco-jobcount,

  " Campos de referencia da tela de selecao
  gv_jobname TYPE tbtco-jobname,
  gv_uname   TYPE tbtco-sdluname,
  gv_progn   TYPE tbtcp-progname,
  gv_datum   TYPE sy-datum,
  gv_uzeit   TYPE sy-uzeit.

" ATENCAO: TIT_B1..TIT_B5 e BTN_* NAO sao declarados aqui. O proprio
" SELECTION-SCREEN ... WITH FRAME TITLE / PUSHBUTTON ja cria essas
" variaveis; declara-las de novo da o erro '"TIT_B1" ja foi declarado'.
" Os textos sao atribuidos na INITIALIZATION.

" Filtros montados a partir da tela (f_montar_filtros)
DATA: gr_nome TYPE ty_r_job,             "Mascara de nome efetiva
      gr_stat TYPE RANGE OF tbtco-status,"Status marcados
      gr_dat  TYPE ty_r_dat,             "Inicio previsto (P_FUTUR)
      gr_per  TYPE ty_r_per.             "Periodicidade (P_PERIO)

"======================================================================
" Classe local - eventos do ALV (SALV)
"======================================================================
CLASS lcl_alv DEFINITION.
  PUBLIC SECTION.
    CLASS-METHODS:
      on_added_function FOR EVENT added_function OF cl_salv_events
        IMPORTING e_salv_function,
      on_double_click FOR EVENT double_click OF cl_salv_events_table
        IMPORTING row column.
ENDCLASS.

CLASS lcl_alv IMPLEMENTATION.
  METHOD on_added_function.
    CASE e_salv_function.
      WHEN 'MARK'.   PERFORM f_marcar_todos.
      WHEN 'UNMK'.   PERFORM f_desmarcar.
      WHEN 'CANC'.   PERFORM f_acao_selecao USING c_can.
      WHEN 'DELE'.   PERFORM f_acao_selecao USING c_del.
      WHEN 'CDEL'.   PERFORM f_acao_selecao USING c_cde.
      WHEN 'STRT'.   PERFORM f_acao_selecao USING c_str.
      WHEN 'RELS'.   PERFORM f_acao_selecao USING c_rel.
      WHEN 'RESC'.   PERFORM f_acao_selecao USING c_res.
      WHEN 'REFR'.   PERFORM f_atualizar.
      WHEN 'BGND'.   PERFORM f_agendar_bg.
      WHEN 'LOGS'.   PERFORM f_popup_log.
    ENDCASE.
  ENDMETHOD.

  METHOD on_double_click.
    DATA ls_job TYPE ty_job.
    READ TABLE gt_job INTO ls_job INDEX row.
    CHECK sy-subrc = 0.
    PERFORM f_abrir_sm37 USING ls_job.
  ENDMETHOD.
ENDCLASS.

"======================================================================
" Tela de selecao
"======================================================================
SELECTION-SCREEN BEGIN OF BLOCK b1 WITH FRAME TITLE tit_b1.
  SELECT-OPTIONS:
    s_jobnam FOR gv_jobname,           "Nome do job (aceita * como mascara)
    s_criad  FOR gv_uname,             "Usuario que agendou (SDLUNAME)
    s_prog   FOR gv_progn,             "Programa do step (TBTCP)
    s_sdldat FOR gv_datum,             "Data prevista de inicio
    s_sdltim FOR gv_uzeit.             "Hora prevista de inicio
  SELECTION-SCREEN SKIP.
  " Status considerados. Por padrao apenas os que ainda vao rodar - que
  " sao os que interessam numa limpeza de agendamento.
  PARAMETERS:
    p_stpla AS CHECKBOX DEFAULT 'X',   "P - Planejado
    p_stlib AS CHECKBOX DEFAULT 'X',   "S - Liberado
    p_stpro AS CHECKBOX DEFAULT 'X',   "Y - Pronto
    p_stati AS CHECKBOX DEFAULT space, "R - Ativo
    p_stcon AS CHECKBOX DEFAULT space, "F - Concluido
    p_stcan AS CHECKBOX DEFAULT space. "A - Cancelado
  SELECTION-SCREEN SKIP.
  PARAMETERS:
    p_futur  AS CHECKBOX DEFAULT 'X',  "So inicio previsto de hoje p/ frente
    p_perio  AS CHECKBOX DEFAULT space,"So jobs periodicos
    p_step   AS CHECKBOX DEFAULT 'X',  "Ler programa/variante do step
    p_maxlin TYPE i DEFAULT 20000.     "Maximo de linhas exibidas no ALV
SELECTION-SCREEN END OF BLOCK b1.

"----------------------------------------------------------------------
" Acao rapida
"----------------------------------------------------------------------
" O caminho de 90% dos casos: "esse nome de job ai, some com tudo".
" Um clique que ignora TODOS os demais filtros da tela (status, so
" futuro, so periodicos, programa) e trata pelo nome puro - porque numa
" limpeza por nome esses filtros so escondem job que deveria sair.
" Continua respeitando as travas de seguranca: simulacao, protecao de
" jobs SAP, jobs ativos, S_EXCL e confirmacao obrigatoria.
"----------------------------------------------------------------------
SELECTION-SCREEN BEGIN OF BLOCK b6 WITH FRAME TITLE tit_b6.
  SELECTION-SCREEN BEGIN OF LINE.
    SELECTION-SCREEN PUSHBUTTON 1(50) btn_cdm USER-COMMAND ucdm.
  SELECTION-SCREEN END OF LINE.
SELECTION-SCREEN END OF BLOCK b6.

SELECTION-SCREEN BEGIN OF BLOCK b2 WITH FRAME TITLE tit_b2.
  " Atalho para o incidente: forca a mascara ZSDR1119* e ignora o que
  " estiver em S_JOBNAM, para nao arrastar job de terceiro por engano.
  PARAMETERS p_inc AS CHECKBOX DEFAULT space.
SELECTION-SCREEN END OF BLOCK b2.

SELECTION-SCREEN BEGIN OF BLOCK b3 WITH FRAME TITLE tit_b3.
  PARAMETERS:
    p_test  AS CHECKBOX DEFAULT 'X',   "Simulacao (nao executa nada)
    p_prot  AS CHECKBOX DEFAULT 'X',   "Proteger jobs criticos do SAP
    p_proat AS CHECKBOX DEFAULT 'X',   "Nao mexer em jobs ativos
    p_max   TYPE i DEFAULT 5000,       "Teto por execucao (0 = sem teto)
    p_pack  TYPE i DEFAULT 500.        "COMMIT a cada N jobs
  SELECT-OPTIONS s_excl FOR gv_jobname NO INTERVALS. "Nomes a preservar
SELECTION-SCREEN END OF BLOCK b3.

"----------------------------------------------------------------------
" Disparo / reagendamento
"----------------------------------------------------------------------
" Contrapartida do bloco de limpeza: em vez de parar job, fazer job
" rodar. Sao tres operacoes distintas:
"   Iniciar agora - cria uma COPIA do job (mesmos steps, mesmo usuario)
"                   com inicio imediato. E o "repetir job" da SM37: o
"                   agendamento original continua intacto.
"   Liberar       - job PLANEJADO (status P, criado mas nunca liberado)
"                   passa a valer, na data prevista ou agora.
"   Reagendar     - copia o job para outra data/hora, opcionalmente
"                   deletando o original.
"----------------------------------------------------------------------
SELECTION-SCREEN BEGIN OF BLOCK b5 WITH FRAME TITLE tit_b5.
  PARAMETERS:
    p_rimed AS CHECKBOX DEFAULT 'X',   "Iniciar/liberar imediatamente
    p_rdate TYPE sy-datum,             "Data alvo (se nao for imediato)
    p_rtime TYPE sy-uzeit,             "Hora alvo
    p_rdel  AS CHECKBOX DEFAULT space. "Reagendar: deletar o original
SELECTION-SCREEN END OF BLOCK b5.

SELECTION-SCREEN BEGIN OF BLOCK b4 WITH FRAME TITLE tit_b4.
  PARAMETERS:
    p_acan  RADIOBUTTON GROUP g1,                "Cancelar
    p_adel  RADIOBUTTON GROUP g1 DEFAULT 'X',    "Deletar
    p_acde  RADIOBUTTON GROUP g1,                "Cancelar + deletar
    p_astr  RADIOBUTTON GROUP g1,                "Iniciar agora
    p_arel  RADIOBUTTON GROUP g1,                "Liberar
    p_arsc  RADIOBUTTON GROUP g1.                "Reagendar
  SELECTION-SCREEN SKIP.
  PARAMETERS:
    p_jname TYPE btcjob DEFAULT c_job_lim,
    p_jdate TYPE sy-datum,
    p_jtime TYPE sy-uzeit.
  SELECTION-SCREEN SKIP.
  SELECTION-SCREEN BEGIN OF LINE.
    SELECTION-SCREEN PUSHBUTTON  1(30) btn_cnt USER-COMMAND ucnt.
    SELECTION-SCREEN PUSHBUTTON 33(30) btn_bgd USER-COMMAND ubgd.
    SELECTION-SCREEN PUSHBUTTON 66(30) btn_sts USER-COMMAND usts.
  SELECTION-SCREEN END OF LINE.
  " Marcado apenas pelo SUBMIT do job de limpeza: sinaliza execucao
  " direta (sem ALV) e bloqueia os botoes de agendamento.
  PARAMETERS p_batch TYPE c LENGTH 1 NO-DISPLAY.
SELECTION-SCREEN END OF BLOCK b4.

"======================================================================
" Inicializacao
"======================================================================
INITIALIZATION.
  tit_b1 = 'Selecao de jobs (SM37 / TBTCO)'.
  tit_b6 = 'Acao rapida - trata pelo NOME, ignora os demais filtros'.
  tit_b2 = 'Preset do incidente ZSDR1119'.
  tit_b3 = 'Travas de seguranca'.
  tit_b5 = 'Disparo / reagendamento (Iniciar, Liberar, Reagendar)'.
  tit_b4 = 'Acao e execucao em background'.

  " Data/hora alvo do reagendamento: daqui a 1 hora, so como ponto de
  " partida. Com P_RIMED marcado esses campos nem sao usados.
  p_rdate = sy-datum.
  p_rtime = sy-uzeit + 3600.
  IF p_rtime < sy-uzeit.
    p_rdate = sy-datum + 1.
  ENDIF.

  btn_cdm = 'Cancelar + Deletar TUDO com esse nome'.
  btn_cnt = 'Contar jobs da selecao'.
  btn_bgd = 'Executar em background'.
  btn_sts = 'Situacao do job de limpeza'.

  " Proposta de agendamento: daqui a 2 minutos - limpeza de job costuma
  " ser urgente. O usuario ajusta se quiser outra janela.
  p_jdate = sy-datum.
  p_jtime = sy-uzeit + 120.
  IF p_jtime < sy-uzeit.               "virou o dia
    p_jdate = sy-datum + 1.
  ENDIF.

"======================================================================
" Botoes da tela de selecao
"----------------------------------------------------------------------
" LICAO DO INCIDENTE ZSDR1119: este evento tambem e disparado quando o
" programa roda em background, e o codigo de funcao sobrevive ao
" roundtrip da tela. Sem o CLEAR e sem a trava de SY-BATCH, um simples
" ENTER (ou a execucao do proprio job) reexecutaria o agendamento.
"======================================================================
AT SELECTION-SCREEN.
  CLEAR gv_cmd.

  IF sscrfields-ucomm IS NOT INITIAL.
    IF sy-batch IS NOT INITIAL OR p_batch IS NOT INITIAL.
      " Em background nenhum botao de tela e processado.
      CLEAR sscrfields-ucomm.
    ELSE.
      CASE sscrfields-ucomm.
        WHEN 'UCDM'.
          gv_cmd = 'X'.
          PERFORM f_acao_rapida.
        WHEN 'UCNT'.
          gv_cmd = 'X'.
          PERFORM f_popup_contagem.
        WHEN 'UBGD'.
          gv_cmd = 'X'.
          PERFORM f_agendar_bg.
        WHEN 'USTS'.
          gv_cmd = 'X'.
          PERFORM f_popup_status_job.
      ENDCASE.
      CLEAR sscrfields-ucomm.
    ENDIF.
  ENDIF.

"----------------------------------------------------------------------
" Validacoes de campo
"----------------------------------------------------------------------
" IMPORTANTE: so podem falar quando ha um usuario olhando. O SUBMIT ...
" VIA JOB processa esta mesma tela para validar os valores; qualquer
" MESSAGE aqui faz o SAP abrir a tela "Erro no planejamento" em vez de
" agendar silenciosamente - e o job fica criado e nao liberado.
"----------------------------------------------------------------------
AT SELECTION-SCREEN ON p_max.
  " Teto 0 = sem limite, e precisa ser digitavel online para depois ir
  " ao background. O limite online e aplicado em f_teto_efetivo.
  IF p_max < 0 AND sy-batch IS INITIAL AND p_batch IS INITIAL.
    MESSAGE 'Teto invalido (informe 0 ou um numero positivo)' TYPE 'E'.
  ENDIF.

AT SELECTION-SCREEN ON p_pack.
  IF p_pack < 1 AND sy-batch IS INITIAL AND p_batch IS INITIAL.
    MESSAGE 'Bloco de commit deve ser maior que zero' TYPE 'E'.
  ENDIF.

"======================================================================
" Processamento
"======================================================================
START-OF-SELECTION.
  " Clique em botao nao dispara a execucao do relatorio.
  CHECK gv_cmd IS INITIAL.

  PERFORM f_init.
  PERFORM f_montar_filtros.

  IF gv_mode_bg = 'X'.
    " Job de limpeza / execucao em batch: sem ALV, em lotes.
    PERFORM f_exec_direto.
  ELSE.
    PERFORM f_contar USING 'X' 'X' 'X' CHANGING gv_tot_sel.
    PERFORM f_ler_jobs.

    IF gt_job IS INITIAL.
      " Popup (tipo I) e nao mensagem de rodape: mensagem de status na
      " barra inferior passa despercebida e da a impressao de que o
      " programa nao fez nada.
      PERFORM f_msg_vazio.
      RETURN.
    ENDIF.

    PERFORM f_aviso_limite.
    PERFORM f_exibir_alv.
  ENDIF.

"======================================================================
" f_init - contexto de execucao
"======================================================================
FORM f_init.

  CLEAR: gt_job, gt_log, gt_feito, gt_pref,
         gv_proc, gv_ok, gv_erro, gv_ign, gv_tot_sel,
         gv_my_job, gv_my_cnt, gv_mode_bg.

  " Lista de prefixos protegidos montada uma unica vez (f_protegido e
  " chamada uma vez por job - fazer o SPLIT la dentro custaria caro em
  " uma limpeza de centenas de milhares de jobs).
  SPLIT c_pref_sap AT ';' INTO TABLE gt_pref.

  gv_pack = p_pack.
  IF gv_pack < 1.
    gv_pack = 500.
  ENDIF.

  " Sem SAPGUI (job) nao ha ALV possivel: cai no modo direto.
  IF p_batch = 'X' OR sy-batch IS NOT INITIAL.
    gv_mode_bg = 'X'.
  ENDIF.

  " Acao configurada na tela (usada no modo direto).
  IF p_acan = 'X'.
    gv_acao = c_can.
  ELSEIF p_acde = 'X'.
    gv_acao = c_cde.
  ELSEIF p_astr = 'X'.
    gv_acao = c_str.
  ELSEIF p_arel = 'X'.
    gv_acao = c_rel.
  ELSEIF p_arsc = 'X'.
    gv_acao = c_res.
  ELSE.
    gv_acao = c_del.
  ENDIF.

  " Identifica o proprio job para jamais se auto-deletar - cenario real
  " quando a mascara pega 'ZJOBS*' ou a limpeza roda dentro de um job de
  " nome parecido.
  IF sy-batch IS NOT INITIAL.
    CALL FUNCTION 'GET_JOB_RUNTIME_INFO'
      IMPORTING
        jobcount        = gv_my_cnt
        jobname         = gv_my_job
      EXCEPTIONS
        no_runtime_info = 1
        OTHERS          = 2.
    IF sy-subrc <> 0.
      CLEAR: gv_my_job, gv_my_cnt.
    ENDIF.
  ENDIF.

ENDFORM.

"======================================================================
" f_montar_filtros - transforma a tela em ranges
"----------------------------------------------------------------------
" Tudo vira range porque range vazio significa "sem restricao": assim um
" unico SELECT atende a qualquer combinacao de filtro, e o diagnostico
" consegue repetir a contagem desligando um filtro por vez.
"======================================================================
FORM f_montar_filtros.

  DATA: ls_st  TYPE LINE OF ty_r_job,
        ls_stt LIKE LINE OF gr_stat,
        ls_dt  TYPE LINE OF ty_r_dat,
        ls_pe  TYPE LINE OF ty_r_per.

  CLEAR: gr_nome, gr_stat, gr_dat, gr_per.

  " --- Nome do job ----------------------------------------------------
  " Com o preset do incidente a mascara e SEMPRE a do incidente: ignora
  " o que estiver em S_JOBNAM para nao arrastar job de terceiro.
  IF p_inc = 'X'.
    ls_st-sign = 'I'.
    ls_st-option = 'CP'.
    ls_st-low = c_pat_1119.
    APPEND ls_st TO gr_nome.
  ELSE.
    gr_nome = s_jobnam[].
  ENDIF.

  " --- Status ---------------------------------------------------------
  ls_stt-sign = 'I'.
  ls_stt-option = 'EQ'.
  IF p_stpla = 'X'. ls_stt-low = c_st_plan. APPEND ls_stt TO gr_stat. ENDIF.
  IF p_stlib = 'X'. ls_stt-low = c_st_libe. APPEND ls_stt TO gr_stat. ENDIF.
  IF p_stpro = 'X'. ls_stt-low = c_st_pron. APPEND ls_stt TO gr_stat. ENDIF.
  IF p_stati = 'X'. ls_stt-low = c_st_ativ. APPEND ls_stt TO gr_stat. ENDIF.
  IF p_stcon = 'X'. ls_stt-low = c_st_conc. APPEND ls_stt TO gr_stat. ENDIF.
  IF p_stcan = 'X'. ls_stt-low = c_st_canc. APPEND ls_stt TO gr_stat. ENDIF.

  IF gr_stat IS INITIAL.
    MESSAGE 'Selecione ao menos um status de job' TYPE 'E'.
  ENDIF.

  " --- Inicio previsto de hoje para frente ----------------------------
  " ATENCAO: job PLANEJADO (status P) criado e nunca liberado fica com
  " SDLDATE = 00000000 - ele nao tem data prevista nenhuma. Um filtro
  " "sdldate >= hoje" puro descartaria justamente esses jobs, que sao os
  " que mais aparecem num agendamento que deu errado. Por isso o range
  " tem duas entradas: de hoje em diante OU sem data.
  IF p_futur = 'X'.
    ls_dt-sign = 'I'.
    ls_dt-option = 'GE'.
    ls_dt-low = sy-datum.
    APPEND ls_dt TO gr_dat.
    CLEAR ls_dt.
    ls_dt-sign = 'I'.
    ls_dt-option = 'EQ'.
    ls_dt-low = '00000000'.
    APPEND ls_dt TO gr_dat.
  ENDIF.

  " --- Somente periodicos ---------------------------------------------
  IF p_perio = 'X'.
    ls_pe-sign = 'I'.
    ls_pe-option = 'EQ'.
    ls_pe-low = 'X'.
    APPEND ls_pe TO gr_per.
  ENDIF.

  " --- Acao rapida: so o nome manda -----------------------------------
  " Todos os status entram e as restricoes de data/periodicidade caem.
  " Numa limpeza por nome, filtro extra so esconde job que deveria sair -
  " foi o que aconteceu com os ZSDR1119_*, cuja data prevista ficou no
  " passado e sumia sob o "so previsto de hoje p/ frente".
  IF gv_quick = 'X'.
    CLEAR: gr_stat, gr_dat, gr_per.
    ls_stt-sign = 'I'.
    ls_stt-option = 'EQ'.
    ls_stt-low = c_st_plan. APPEND ls_stt TO gr_stat.
    ls_stt-low = c_st_libe. APPEND ls_stt TO gr_stat.
    ls_stt-low = c_st_pron. APPEND ls_stt TO gr_stat.
    ls_stt-low = c_st_ativ. APPEND ls_stt TO gr_stat.
    ls_stt-low = c_st_conc. APPEND ls_stt TO gr_stat.
    ls_stt-low = c_st_canc. APPEND ls_stt TO gr_stat.
  ENDIF.

ENDFORM.

"======================================================================
" f_contar - quantos jobs a selecao retorna (COUNT(*))
"----------------------------------------------------------------------
" Os tres flags permitem repetir a contagem desligando um filtro por vez
" - e o que o diagnostico usa para mostrar QUAL filtro zerou o resultado.
" Com os tres em 'X' e a contagem real da selecao.
"======================================================================
FORM f_contar USING iv_stat TYPE c
                    iv_futur TYPE c
                    iv_perio TYPE c
              CHANGING cv_qtd TYPE i.

  DATA: lt_stat LIKE gr_stat,
        lt_dat  TYPE ty_r_dat,
        lt_per  TYPE ty_r_per.

  CLEAR cv_qtd.

  IF iv_stat  = 'X'. lt_stat = gr_stat. ENDIF.
  IF iv_futur = 'X'. lt_dat  = gr_dat.  ENDIF.
  IF iv_perio = 'X'. lt_per  = gr_per.  ENDIF.

  SELECT COUNT(*) FROM tbtco
    INTO cv_qtd
    WHERE jobname  IN gr_nome
      AND sdluname IN s_criad
      AND sdldate  IN s_sdldat
      AND sdltime  IN s_sdltim
      AND status   IN lt_stat
      AND sdldate  IN lt_dat
      AND periodic IN lt_per.

ENDFORM.

"======================================================================
" f_diagnostico - por que a selecao voltou vazia?
"----------------------------------------------------------------------
" Refaz a contagem acrescentando um filtro de cada vez. O usuario ve em
" que degrau o numero virou zero, em vez de so "nenhum job encontrado".
"======================================================================
FORM f_diagnostico CHANGING cv_txt TYPE any.

  DATA: lv_n0 TYPE i,                    "so mascara/usuario/datas/hora
        lv_n1 TYPE i,                    "+ status
        lv_n2 TYPE i,                    "+ so futuro
        lv_n3 TYPE i,                    "+ so periodico
        lv_c0 TYPE c LENGTH 12,
        lv_c1 TYPE c LENGTH 12,
        lv_c2 TYPE c LENGTH 12,
        lv_c3 TYPE c LENGTH 12.

  PERFORM f_contar USING space space space CHANGING lv_n0.
  PERFORM f_contar USING 'X'   space space CHANGING lv_n1.
  PERFORM f_contar USING 'X'   'X'   space CHANGING lv_n2.
  PERFORM f_contar USING 'X'   'X'   'X'   CHANGING lv_n3.

  WRITE: lv_n0 TO lv_c0 LEFT-JUSTIFIED,
         lv_n1 TO lv_c1 LEFT-JUSTIFIED,
         lv_n2 TO lv_c2 LEFT-JUSTIFIED,
         lv_n3 TO lv_c3 LEFT-JUSTIFIED.

  IF lv_n0 = 0.
    cv_txt = 'A mascara de nome nao encontra nenhum job na TBTCO - confira o nome (use *) ou desmarque o preset do incidente.'.
    RETURN.
  ENDIF.

  CONCATENATE 'Pela mascara:' lv_c0 '| + status marcados:' lv_c1
              '| + so futuro:' lv_c2 '| + so periodicos:' lv_c3
              '- desmarque o filtro que zerou'
         INTO cv_txt SEPARATED BY space.

ENDFORM.

"======================================================================
" f_msg_vazio - "nao achei nada" com o motivo junto
"======================================================================
FORM f_msg_vazio.

  DATA: lv_diag TYPE c LENGTH 200,
        lv_txt  TYPE c LENGTH 250.

  PERFORM f_diagnostico CHANGING lv_diag.
  CONCATENATE 'Nenhum job atende a selecao.' lv_diag
         INTO lv_txt SEPARATED BY space.
  MESSAGE lv_txt TYPE 'I'.

ENDFORM.

"======================================================================
" f_selecionar - le um lote de jobs da TBTCO
"----------------------------------------------------------------------
" iv_max = 0 -> sem limite. Ordenado pela chave primaria para o modo
" direto ser deterministico de um lote para o outro.
"======================================================================
FORM f_selecionar USING iv_max TYPE i
                  CHANGING ct_job TYPE tt_job.

  CLEAR ct_job.

  SELECT jobname jobcount status periodic sdldate sdltime
         strtdate strttime enddate endtime jobclass
         sdluname authcknam
         prdmins prdhours prddays prdweeks prdmonths
    FROM tbtco
    UP TO iv_max ROWS
    INTO CORRESPONDING FIELDS OF TABLE ct_job
    WHERE jobname  IN gr_nome
      AND sdluname IN s_criad
      AND sdldate  IN s_sdldat
      AND sdltime  IN s_sdltim
      AND status   IN gr_stat
      AND sdldate  IN gr_dat
      AND periodic IN gr_per
    ORDER BY PRIMARY KEY.

ENDFORM.

"======================================================================
" f_ler_steps - programa/variante do 1o step + filtro por programa
"----------------------------------------------------------------------
" Feito como pos-filtro (e nao como JOIN) para manter uma unica forma de
" SELECT na TBTCO e permitir o processamento em lotes do modo direto.
"======================================================================
FORM f_ler_steps CHANGING ct_job TYPE tt_job.

  TYPES: BEGIN OF ty_step,
           jobname   TYPE tbtcp-jobname,
           jobcount  TYPE tbtcp-jobcount,
           stepcount TYPE tbtcp-stepcount,
           progname  TYPE tbtcp-progname,
           variant   TYPE tbtcp-variant,
         END OF ty_step.

  DATA: lt_step TYPE SORTED TABLE OF ty_step
                     WITH NON-UNIQUE KEY jobname jobcount,
        ls_step TYPE ty_step,
        lv_tem  TYPE c LENGTH 1.

  FIELD-SYMBOLS <ls_job> TYPE ty_job.

  CHECK ct_job IS NOT INITIAL.

  " Sem filtro por programa e sem pedido de leitura do step nao ha o que
  " fazer - evita ler a TBTCP para dezenas de milhares de jobs a toa.
  IF p_step IS INITIAL AND s_prog[] IS INITIAL.
    RETURN.
  ENDIF.

  SELECT jobname jobcount stepcount progname variant
    FROM tbtcp
    INTO TABLE lt_step
    FOR ALL ENTRIES IN ct_job
    WHERE jobname  = ct_job-jobname
      AND jobcount = ct_job-jobcount.

  LOOP AT ct_job ASSIGNING <ls_job>.
    CLEAR lv_tem.
    LOOP AT lt_step INTO ls_step
         WHERE jobname  = <ls_job>-jobname
           AND jobcount = <ls_job>-jobcount.
      <ls_job>-steps = <ls_job>-steps + 1.
      IF <ls_job>-progname IS INITIAL.
        <ls_job>-progname = ls_step-progname.
        <ls_job>-variant  = ls_step-variant.
      ENDIF.
      IF ls_step-progname IN s_prog.
        lv_tem = 'X'.
      ENDIF.
    ENDLOOP.
    " Filtro por programa: basta um step atender. 'F' e marca temporaria
    " de descarte (o campo e recalculado em f_enriquecer).
    IF s_prog[] IS NOT INITIAL AND lv_tem IS INITIAL.
      <ls_job>-protegido = 'F'.
    ENDIF.
  ENDLOOP.

  DELETE ct_job WHERE protegido = 'F'.

ENDFORM.

"======================================================================
" f_enriquecer - textos, semaforo e avaliacao das protecoes
"======================================================================
FORM f_enriquecer CHANGING ct_job TYPE tt_job.

  FIELD-SYMBOLS <ls_job> TYPE ty_job.

  LOOP AT ct_job ASSIGNING <ls_job>.
    PERFORM f_texto_status  USING <ls_job>-status
                            CHANGING <ls_job>-status_tx <ls_job>-icone.
    PERFORM f_texto_periodo USING <ls_job>
                            CHANGING <ls_job>-period_tx.
    PERFORM f_protegido     USING <ls_job>
                            CHANGING <ls_job>-protegido <ls_job>-motivo.
  ENDLOOP.

ENDFORM.

"======================================================================
" f_texto_status
"======================================================================
FORM f_texto_status USING iv_status TYPE tbtco-status
                    CHANGING cv_texto TYPE any
                             cv_icone TYPE any.

  CASE iv_status.
    WHEN 'P'.
      cv_texto = 'Planejado'.            cv_icone = icon_led_yellow.
    WHEN 'S'.
      cv_texto = 'Liberado'.             cv_icone = icon_led_yellow.
    WHEN 'Y'.
      cv_texto = 'Pronto'.               cv_icone = icon_led_yellow.
    WHEN 'R'.
      cv_texto = 'Ativo'.                cv_icone = icon_led_green.
    WHEN 'F'.
      cv_texto = 'Concluido'.            cv_icone = icon_led_green.
    WHEN 'A'.
      cv_texto = 'Cancelado'.            cv_icone = icon_led_red.
    WHEN 'Z'.
      cv_texto = 'Aguarda predecessor'.  cv_icone = icon_led_inactive.
    WHEN OTHERS.
      cv_texto = 'Desconhecido'.         cv_icone = icon_led_inactive.
  ENDCASE.

ENDFORM.

"======================================================================
" f_texto_periodo - periodicidade por extenso
"----------------------------------------------------------------------
" O que agrava o incidente da ZSDR1119: os jobs sao periodicos, logo se
" reagendam sozinhos para os dias seguintes. Deixar isso visivel no ALV.
"======================================================================
FORM f_texto_periodo USING is_job TYPE ty_job
                     CHANGING cv_texto TYPE any.

  DATA lv_n TYPE n LENGTH 5.

  CLEAR cv_texto.

  IF is_job-periodic IS INITIAL.
    cv_texto = 'Unica'.
    RETURN.
  ENDIF.

  IF is_job-prdmins > 0.
    lv_n = is_job-prdmins.
    CONCATENATE 'A cada' lv_n 'min' INTO cv_texto SEPARATED BY space.
  ELSEIF is_job-prdhours > 0.
    lv_n = is_job-prdhours.
    CONCATENATE 'A cada' lv_n 'h' INTO cv_texto SEPARATED BY space.
  ELSEIF is_job-prddays > 0.
    lv_n = is_job-prddays.
    CONCATENATE 'A cada' lv_n 'dia(s)' INTO cv_texto SEPARATED BY space.
  ELSEIF is_job-prdweeks > 0.
    lv_n = is_job-prdweeks.
    CONCATENATE 'A cada' lv_n 'sem.' INTO cv_texto SEPARATED BY space.
  ELSEIF is_job-prdmonths > 0.
    lv_n = is_job-prdmonths.
    CONCATENATE 'A cada' lv_n 'mes(es)' INTO cv_texto SEPARATED BY space.
  ELSE.
    cv_texto = 'Periodico'.
  ENDIF.

  CONDENSE cv_texto.

ENDFORM.

"======================================================================
" f_protegido - o job pode ser tratado?
"----------------------------------------------------------------------
" Devolve 'X' + motivo quando o job NAO deve ser cancelado/deletado.
" A ordem vai da checagem mais grave (auto-delete) para a mais branda.
"======================================================================
FORM f_protegido USING is_job TYPE ty_job
                 CHANGING cv_prot TYPE any
                          cv_motivo TYPE any.

  DATA: lv_pref TYPE ty_pref,
        lv_nome TYPE c LENGTH 32,
        lv_masc TYPE c LENGTH 21.

  CLEAR: cv_prot, cv_motivo.

  " 1) O proprio job em execucao
  IF gv_my_job IS NOT INITIAL
     AND is_job-jobname  = gv_my_job
     AND is_job-jobcount = gv_my_cnt.
    cv_prot = 'X'.
    cv_motivo = 'E o proprio job de limpeza em execucao'.
    RETURN.
  ENDIF.

  " 2) Job ativo
  IF is_job-status = c_st_ativ AND p_proat = 'X'.
    cv_prot = 'X'.
    cv_motivo = 'Job ativo (trava P_PROAT)'.
    RETURN.
  ENDIF.

  " 3) Exclusoes informadas na tela
  IF s_excl[] IS NOT INITIAL AND is_job-jobname IN s_excl.
    cv_prot = 'X'.
    cv_motivo = 'Nome preservado na tela (S_EXCL)'.
    RETURN.
  ENDIF.

  CHECK p_prot = 'X'.

  " 4) Usuarios de sistema (SAP* cai no teste do asterisco)
  IF is_job-sdluname  CA '*'
     OR is_job-sdluname  = 'DDIC'
     OR is_job-sdluname  = 'SAPSYS'
     OR is_job-sdluname  = 'TMSADM'
     OR is_job-authcknam = 'DDIC'
     OR is_job-authcknam = 'SAPSYS'
     OR is_job-authcknam = 'TMSADM'.
    cv_prot = 'X'.
    cv_motivo = 'Job de usuario de sistema (DDIC/SAPSYS/TMSADM/SAP*)'.
    RETURN.
  ENDIF.

  " 5) Prefixos padrao do SAP
  lv_nome = is_job-jobname.
  TRANSLATE lv_nome TO UPPER CASE.
  LOOP AT gt_pref INTO lv_pref.
    CHECK lv_pref IS NOT INITIAL.
    CONCATENATE lv_pref '*' INTO lv_masc.
    CONDENSE lv_masc NO-GAPS.
    IF lv_nome CP lv_masc.
      cv_prot = 'X'.
      CONCATENATE 'Job padrao SAP (prefixo' lv_pref ')'
             INTO cv_motivo SEPARATED BY space.
      RETURN.
    ENDIF.
  ENDLOOP.

ENDFORM.

"======================================================================
" f_ler_jobs - leitura para o ALV (modo online)
"======================================================================
FORM f_ler_jobs.

  DATA lv_max TYPE i.

  lv_max = p_maxlin.
  IF lv_max <= 0.
    lv_max = c_max_alv.
  ENDIF.

  PERFORM f_selecionar USING lv_max CHANGING gt_job.
  PERFORM f_ler_steps  CHANGING gt_job.
  PERFORM f_enriquecer CHANGING gt_job.

ENDFORM.

"======================================================================
" f_aviso_limite - avisa quando a selecao e maior que o ALV
"======================================================================
FORM f_aviso_limite.

  DATA: lv_c1 TYPE c LENGTH 12,
        lv_c2 TYPE c LENGTH 12,
        lv_ms TYPE c LENGTH 200,
        lv_ex TYPE i.

  lv_ex = lines( gt_job ).
  CHECK gv_tot_sel > lv_ex.

  WRITE gv_tot_sel TO lv_c1 LEFT-JUSTIFIED.
  WRITE lv_ex      TO lv_c2 LEFT-JUSTIFIED.
  CONCATENATE 'A selecao tem' lv_c1 'jobs; exibindo' lv_c2
              '- use "Executar em background" para tratar tudo'
         INTO lv_ms SEPARATED BY space.
  MESSAGE lv_ms TYPE 'S' DISPLAY LIKE 'W'.

ENDFORM.

"======================================================================
" f_exibir_alv - ALV com botoes proprios (sem status GUI na SE41)
"======================================================================
FORM f_exibir_alv.

  DATA: lo_funcs  TYPE REF TO cl_salv_functions_list,
        lo_cols   TYPE REF TO cl_salv_columns_table,
        lo_disp   TYPE REF TO cl_salv_display_settings,
        lo_sel    TYPE REF TO cl_salv_selections,
        lo_events TYPE REF TO cl_salv_events_table,
        lv_titulo TYPE lvc_title,
        lv_txt    TYPE string,
        lx_msg    TYPE REF TO cx_root.

  TRY.
      cl_salv_table=>factory(
        IMPORTING r_salv_table = gr_alv
        CHANGING  t_table      = gt_job ).

      " Funcoes padrao (ordenar, filtrar, layout, export) + as nossas.
      " ADD_FUNCTION dispensa status GUI proprio (SE41).
      lo_funcs = gr_alv->get_functions( ).
      lo_funcs->set_all( abap_true ).

      " Os parametros de ADD_FUNCTION sao TYPE STRING por referencia:
      " passar constante de icone (CHAR4) ou literal direto da erro de
      " compatibilidade. Por isso tudo passa por f_add_func, que recebe
      " por VALUE e converte.
      PERFORM f_add_func USING lo_funcs 'MARK' icon_select_all
              'Marcar tudo'      'Marcar todas as linhas exibidas'.
      PERFORM f_add_func USING lo_funcs 'UNMK' icon_deselect_all
              'Desmarcar'        'Desmarcar todas as linhas'.
      PERFORM f_add_func USING lo_funcs 'CANC' icon_cancel
              'Cancelar'         'Interromper os jobs ativos marcados'.
      PERFORM f_add_func USING lo_funcs 'DELE' icon_delete
              'Deletar'          'Deletar os jobs marcados'.
      PERFORM f_add_func USING lo_funcs 'CDEL' icon_delete
              'Cancelar+Deletar' 'Interromper (se ativo) e deletar'.
      PERFORM f_add_func USING lo_funcs 'STRT' icon_execute_object
              'Iniciar agora'    'Criar copia do job e iniciar imediatamente'.
      PERFORM f_add_func USING lo_funcs 'RELS' icon_activate
              'Liberar'          'Liberar job planejado (status P)'.
      PERFORM f_add_func USING lo_funcs 'RESC' icon_change
              'Reagendar'        'Copiar o job para a data/hora do bloco de disparo'.
      PERFORM f_add_func USING lo_funcs 'REFR' icon_refresh
              'Atualizar'        'Reler a selecao'.
      PERFORM f_add_func USING lo_funcs 'BGND' icon_time
              'Background'       'Agendar a execucao completa em job'.
      PERFORM f_add_func USING lo_funcs 'LOGS' icon_protocol
              'Log'              'Log da ultima acao executada'.

      " Selecao de multiplas linhas pela coluna a esquerda.
      lo_sel = gr_alv->get_selections( ).
      lo_sel->set_selection_mode( if_salv_c_selection_mode=>row_column ).

      lo_events = gr_alv->get_event( ).
      SET HANDLER lcl_alv=>on_added_function FOR lo_events.
      SET HANDLER lcl_alv=>on_double_click   FOR lo_events.

      lo_disp = gr_alv->get_display_settings( ).
      lo_disp->set_striped_pattern( abap_true ).
      PERFORM f_titulo CHANGING lv_titulo.
      lo_disp->set_list_header( lv_titulo ).

      lo_cols = gr_alv->get_columns( ).
      lo_cols->set_optimize( abap_true ).

      PERFORM f_col USING lo_cols 'ICONE'     'St.'.
      PERFORM f_col USING lo_cols 'JOBNAME'   'Nome do job'.
      PERFORM f_col USING lo_cols 'JOBCOUNT'  'Nr. job'.
      PERFORM f_col USING lo_cols 'STATUS'    'S'.
      PERFORM f_col USING lo_cols 'STATUS_TX' 'Situacao'.
      PERFORM f_col USING lo_cols 'PERIODIC'  'Per.'.
      PERFORM f_col USING lo_cols 'PERIOD_TX' 'Periodicidade'.
      PERFORM f_col USING lo_cols 'SDLDATE'   'Dt.prevista'.
      PERFORM f_col USING lo_cols 'SDLTIME'   'Hr.prevista'.
      PERFORM f_col USING lo_cols 'STRTDATE'  'Dt.inicio'.
      PERFORM f_col USING lo_cols 'STRTTIME'  'Hr.inicio'.
      PERFORM f_col USING lo_cols 'ENDDATE'   'Dt.fim'.
      PERFORM f_col USING lo_cols 'ENDTIME'   'Hr.fim'.
      PERFORM f_col USING lo_cols 'JOBCLASS'  'Cl.'.
      PERFORM f_col USING lo_cols 'SDLUNAME'  'Agendou'.
      PERFORM f_col USING lo_cols 'AUTHCKNAM' 'Usr.execucao'.
      PERFORM f_col USING lo_cols 'PROGNAME'  'Programa'.
      PERFORM f_col USING lo_cols 'VARIANT'   'Variante'.
      PERFORM f_col USING lo_cols 'STEPS'     'Steps'.
      PERFORM f_col USING lo_cols 'PROTEGIDO' 'Prot.'.
      PERFORM f_col USING lo_cols 'MOTIVO'    'Motivo da protecao'.

      " Colunas de periodicidade bruta nao interessam na tela.
      PERFORM f_col_hide USING lo_cols 'PRDMINS'.
      PERFORM f_col_hide USING lo_cols 'PRDHOURS'.
      PERFORM f_col_hide USING lo_cols 'PRDDAYS'.
      PERFORM f_col_hide USING lo_cols 'PRDWEEKS'.
      PERFORM f_col_hide USING lo_cols 'PRDMONTHS'.

      gr_alv->display( ).

    CATCH cx_root INTO lx_msg.
      lv_txt = lx_msg->get_text( ).
      MESSAGE lv_txt TYPE 'E'.
  ENDTRY.

ENDFORM.

"======================================================================
" f_add_func - acrescenta um botao proprio a barra do SALV
"----------------------------------------------------------------------
" ADD_FUNCTION tipa NAME/ICON/TEXT/TOOLTIP como STRING e recebe por
" referencia, entao constante de icone (CHAR4) e literal de texto nao
" servem direto - o compilador acusa "nao e compativel com o tipo do
" parametro formal". Aqui os parametros entram por VALUE, o que permite
" a conversao, e so depois viram STRING de verdade.
"======================================================================
FORM f_add_func USING io_funcs TYPE REF TO cl_salv_functions_list
                      VALUE(iv_name) TYPE c
                      VALUE(iv_icon) TYPE c
                      VALUE(iv_text) TYPE c
                      VALUE(iv_tip)  TYPE c.

  DATA: lv_name TYPE salv_de_function,
        lv_icon TYPE string,
        lv_text TYPE string,
        lv_tip  TYPE string,
        lx      TYPE REF TO cx_root.

  lv_name = iv_name.
  lv_icon = iv_icon.
  lv_text = iv_text.
  lv_tip  = iv_tip.

  TRY.
      io_funcs->add_function(
        name     = lv_name
        icon     = lv_icon
        text     = lv_text
        tooltip  = lv_tip
        position = if_salv_c_function_position=>right_of_salv_functions ).
    CATCH cx_root INTO lx.
      " Botao duplicado ou nao suportado no release nao pode impedir o
      " ALV de abrir.
      RETURN.
  ENDTRY.

ENDFORM.

"======================================================================
" f_col - cabecalho de uma coluna do SALV
"----------------------------------------------------------------------
" Parametros por VALUE para aceitar literais na chamada.
"
" A largura NAO e definida aqui de proposito: SET_OUTPUT_LENGTH tem um
" tipo de parametro que varia entre releases (dava "IV_LEN nao e
" compativel com o tipo do parametro formal VALUE") e o
" SET_OPTIMIZE( ABAP_TRUE ) do bloco do ALV ja dimensiona as colunas
" pelo conteudo, que e o comportamento desejado.
"======================================================================
FORM f_col USING io_cols TYPE REF TO cl_salv_columns_table
                 VALUE(iv_name) TYPE lvc_fname
                 VALUE(iv_text) TYPE c.

  DATA: lo_col TYPE REF TO cl_salv_column,
        lv_s   TYPE scrtext_s,
        lv_m   TYPE scrtext_m,
        lv_l   TYPE scrtext_l,
        lx     TYPE REF TO cx_root.

  TRY.
      lo_col = io_cols->get_column( iv_name ).
      lv_s = iv_text.
      lv_m = iv_text.
      lv_l = iv_text.
      lo_col->set_short_text( lv_s ).
      lo_col->set_medium_text( lv_m ).
      lo_col->set_long_text( lv_l ).
    CATCH cx_root INTO lx.
      " Coluna inexistente nao pode derrubar o ALV inteiro.
      RETURN.
  ENDTRY.

ENDFORM.

FORM f_col_hide USING io_cols TYPE REF TO cl_salv_columns_table
                      VALUE(iv_name) TYPE lvc_fname.

  DATA: lo_col TYPE REF TO cl_salv_column,
        lx     TYPE REF TO cx_root.

  TRY.
      lo_col = io_cols->get_column( iv_name ).
      lo_col->set_technical( abap_true ).
    CATCH cx_root INTO lx.
      RETURN.
  ENDTRY.

ENDFORM.

"======================================================================
" f_titulo - cabecalho do ALV com o resumo da selecao
"======================================================================
FORM f_titulo CHANGING cv_titulo TYPE lvc_title.

  DATA: lv_tot TYPE c LENGTH 12,
        lv_exi TYPE c LENGTH 12,
        lv_qtd TYPE i,
        lv_mod TYPE c LENGTH 20.

  lv_qtd = lines( gt_job ).
  WRITE gv_tot_sel TO lv_tot LEFT-JUSTIFIED.
  WRITE lv_qtd     TO lv_exi LEFT-JUSTIFIED.

  IF p_test = 'X'.
    lv_mod = '*** SIMULACAO ***'.
  ELSE.
    lv_mod = 'EXECUCAO REAL'.
  ENDIF.

  CONCATENATE 'Jobs na selecao:' lv_tot '| exibidos:' lv_exi '|' lv_mod
         INTO cv_titulo SEPARATED BY space.

ENDFORM.

"======================================================================
" f_marcar_todos / f_desmarcar
"======================================================================
FORM f_marcar_todos.

  DATA: lo_sel  TYPE REF TO cl_salv_selections,
        lt_rows TYPE salv_t_row,
        lv_i    TYPE i,
        lv_n    TYPE i.

  CHECK gr_alv IS BOUND.

  lo_sel = gr_alv->get_selections( ).
  lv_n = lines( gt_job ).
  DO lv_n TIMES.
    lv_i = sy-index.
    APPEND lv_i TO lt_rows.
  ENDDO.
  lo_sel->set_selected_rows( lt_rows ).
  gr_alv->refresh( ).

ENDFORM.

FORM f_desmarcar.

  DATA: lo_sel  TYPE REF TO cl_salv_selections,
        lt_rows TYPE salv_t_row.

  CHECK gr_alv IS BOUND.

  lo_sel = gr_alv->get_selections( ).
  lo_sel->set_selected_rows( lt_rows ).
  gr_alv->refresh( ).

ENDFORM.

"======================================================================
" f_acao_selecao - executa a acao nas linhas marcadas do ALV
"======================================================================
FORM f_acao_selecao USING iv_acao TYPE c.

  DATA: lo_sel  TYPE REF TO cl_salv_selections,
        lt_rows TYPE salv_t_row,
        lv_row  TYPE i,
        lt_alvo TYPE tt_job,
        ls_job  TYPE ty_job,
        lv_qtd  TYPE i,
        lv_teto TYPE i,
        lv_resp TYPE c LENGTH 1,
        lv_c1   TYPE c LENGTH 12,
        lv_c2   TYPE c LENGTH 12,
        lv_tx   TYPE c LENGTH 200.

  CHECK gr_alv IS BOUND.

  lo_sel = gr_alv->get_selections( ).
  lt_rows = lo_sel->get_selected_rows( ).

  IF lt_rows IS INITIAL.
    MESSAGE 'Marque ao menos uma linha (ou use "Marcar tudo")' TYPE 'S'
            DISPLAY LIKE 'W'.
    RETURN.
  ENDIF.

  LOOP AT lt_rows INTO lv_row.
    READ TABLE gt_job INTO ls_job INDEX lv_row.
    CHECK sy-subrc = 0.
    APPEND ls_job TO lt_alvo.
  ENDLOOP.

  lv_qtd = lines( lt_alvo ).

  " O teto tambem vale para a acao pelo ALV: online o risco e estourar o
  " tempo maximo de dialogo no meio da limpeza.
  PERFORM f_teto_efetivo USING iv_acao CHANGING lv_teto.
  IF lv_qtd > lv_teto.
    WRITE lv_qtd  TO lv_c1 LEFT-JUSTIFIED.
    WRITE lv_teto TO lv_c2 LEFT-JUSTIFIED.
    CONCATENATE 'Marcados' lv_c1 'jobs, acima do teto de' lv_c2
                '- reduza a marcacao ou use o modo background'
           INTO lv_tx SEPARATED BY space.
    MESSAGE lv_tx TYPE 'S' DISPLAY LIKE 'E'.
    RETURN.
  ENDIF.

  PERFORM f_confirmar USING iv_acao lv_qtd CHANGING lv_resp.
  CHECK lv_resp = '1'.

  " Cada clique tem o seu proprio log.
  CLEAR: gt_log, gv_proc, gv_ok, gv_erro, gv_ign.

  PERFORM f_processar USING iv_acao CHANGING lt_alvo.

  " Tira do ALV o que realmente saiu do sistema (o reagendamento com
  " P_RDEL tambem deleta o original).
  IF p_test IS INITIAL
     AND ( iv_acao = c_del OR iv_acao = c_cde OR iv_acao = c_res ).
    PERFORM f_remover_deletados.
  ENDIF.

  gr_alv->refresh( ).
  PERFORM f_popup_log.

ENDFORM.

"======================================================================
" f_teto_efetivo - teto real de jobs por execucao
"----------------------------------------------------------------------
" Tres regras se sobrepoem, da mais fraca para a mais forte:
"   1. P_MAX manda (0 = sem teto).
"   2. Online nunca e ilimitado: uma limpeza sem fim derrubaria a sessao
"      por timeout no meio, deixando parte tratada e parte nao.
"   3. Acao de DISPARO nunca e ilimitada, nem em background: iniciar
"      job em massa e carga na maquina, nao limpeza. Teto duro
"      C_MAX_DISP, que nenhum parametro de tela consegue furar.
"======================================================================
FORM f_teto_efetivo USING iv_acao TYPE c
                    CHANGING cv_teto TYPE i.

  cv_teto = p_max.

  IF gv_mode_bg IS INITIAL AND cv_teto <= 0.
    cv_teto = c_teto_onl.
  ENDIF.

  IF iv_acao = c_str OR iv_acao = c_rel OR iv_acao = c_res.
    IF cv_teto <= 0 OR cv_teto > c_max_disp.
      cv_teto = c_max_disp.
    ENDIF.
  ENDIF.

ENDFORM.

"======================================================================
" f_nome_acao - nome da acao por extenso (popup, log e spool)
"======================================================================
FORM f_nome_acao USING iv_acao TYPE c
                 CHANGING cv_nome TYPE any.

  CASE iv_acao.
    WHEN c_can. cv_nome = 'CANCELAR'.
    WHEN c_del. cv_nome = 'DELETAR'.
    WHEN c_cde. cv_nome = 'CANCELAR e DELETAR'.
    WHEN c_str. cv_nome = 'INICIAR AGORA'.
    WHEN c_rel. cv_nome = 'LIBERAR'.
    WHEN c_res. cv_nome = 'REAGENDAR'.
    WHEN OTHERS. cv_nome = 'ACAO DESCONHECIDA'.
  ENDCASE.

ENDFORM.

"======================================================================
" f_confirmar - popup obrigatorio antes de qualquer acao
"======================================================================
FORM f_confirmar USING iv_acao TYPE c
                       iv_qtd TYPE i
                 CHANGING cv_resp TYPE c.

  DATA: lv_qtd  TYPE c LENGTH 12,
        lv_tit  TYPE c LENGTH 60,
        lv_perg TYPE c LENGTH 200,
        lv_acao TYPE c LENGTH 20.

  CLEAR cv_resp.
  WRITE iv_qtd TO lv_qtd LEFT-JUSTIFIED.

  PERFORM f_nome_acao USING iv_acao CHANGING lv_acao.

  IF p_test = 'X'.
    lv_tit = 'Simulacao'.
    CONCATENATE 'Simular' lv_acao lv_qtd
                'job(s)? Nada sera alterado (P_TEST marcado).'
           INTO lv_perg SEPARATED BY space.
  ELSEIF iv_acao = c_str OR iv_acao = c_rel OR iv_acao = c_res.
    " Disparo: o alerta nao e "nao da para desfazer", e sim "vai rodar".
    lv_tit = 'ATENCAO - os jobs vao executar'.
    CONCATENATE lv_acao lv_qtd
                'job(s)? Eles VAO RODAR de verdade, com carga real no sistema.'
           INTO lv_perg SEPARATED BY space.
  ELSE.
    lv_tit = 'ATENCAO - execucao real'.
    CONCATENATE lv_acao lv_qtd
                'job(s) definitivamente? A operacao nao pode ser desfeita.'
           INTO lv_perg SEPARATED BY space.
  ENDIF.

  CALL FUNCTION 'POPUP_TO_CONFIRM'
    EXPORTING
      titlebar              = lv_tit
      text_question         = lv_perg
      text_button_1         = 'Confirmar'
      text_button_2         = 'Voltar'
      default_button        = '2'
      display_cancel_button = space
    IMPORTING
      answer                = cv_resp
    EXCEPTIONS
      text_not_found        = 1
      OTHERS                = 2.
  IF sy-subrc <> 0.
    CLEAR cv_resp.
  ENDIF.

ENDFORM.

"======================================================================
" f_processar - executa a acao numa tabela de jobs
"----------------------------------------------------------------------
" Ponto unico de execucao: usado tanto pelo ALV quanto pelo modo direto.
" COMMIT WORK a cada GV_PACK jobs para nao formar uma LUW gigante.
"======================================================================
FORM f_processar USING iv_acao TYPE c
                 CHANGING ct_job TYPE tt_job.

  DATA: ls_log  TYPE ty_log,
        lv_txt  TYPE c LENGTH 60,
        lv_num  TYPE c LENGTH 12,
        lv_n    TYPE i,
        lv_perc TYPE i,
        lv_tot  TYPE i.

  FIELD-SYMBOLS <ls_job> TYPE ty_job.

  lv_tot = lines( ct_job ).
  CHECK lv_tot > 0.

  LOOP AT ct_job ASSIGNING <ls_job>.
    lv_n = sy-tabix.

    " Barra de progresso a cada 100 jobs (a cada job custaria mais que o
    " proprio processamento).
    IF gv_mode_bg IS INITIAL AND lv_n MOD 100 = 1.
      lv_perc = lv_n * 100 / lv_tot.
      WRITE lv_n TO lv_num LEFT-JUSTIFIED.
      CONCATENATE 'Tratando job' lv_num INTO lv_txt SEPARATED BY space.
      CALL FUNCTION 'SAPGUI_PROGRESS_INDICATOR'
        EXPORTING
          percentage = lv_perc
          text       = lv_txt.
    ENDIF.

    " Reavalia as protecoes na hora da execucao: o status pode ter mudado
    " desde a leitura do ALV.
    PERFORM f_protegido USING <ls_job>
                        CHANGING <ls_job>-protegido <ls_job>-motivo.

    IF <ls_job>-protegido = 'X'.
      CLEAR ls_log.
      ls_log-jobname  = <ls_job>-jobname.
      ls_log-jobcount = <ls_job>-jobcount.
      ls_log-acao     = 'IGNORADO'.
      ls_log-result   = c_ig.
      ls_log-msg      = <ls_job>-motivo.
      PERFORM f_add_log USING ls_log.
      CONTINUE.
    ENDIF.

    PERFORM f_exec_um USING <ls_job> iv_acao.

    gv_proc = gv_proc + 1.
    IF p_test IS INITIAL AND gv_proc MOD gv_pack = 0.
      COMMIT WORK.
    ENDIF.
  ENDLOOP.

  IF p_test IS INITIAL.
    COMMIT WORK.
  ENDIF.

ENDFORM.

"======================================================================
" f_exec_um - cancela e/ou deleta UM job
"======================================================================
FORM f_exec_um USING is_job TYPE ty_job
                     iv_acao TYPE c.

  DATA ls_log TYPE ty_log.

  CLEAR ls_log.
  ls_log-jobname  = is_job-jobname.
  ls_log-jobcount = is_job-jobcount.

  " --- Cancelar (so faz sentido para job ATIVO) -----------------------
  IF iv_acao = c_can OR iv_acao = c_cde.
    IF is_job-status = c_st_ativ.
      PERFORM f_abortar USING is_job CHANGING ls_log.
      PERFORM f_add_log USING ls_log.

      " So cancelar: terminou aqui. Cancelar+deletar: se o abort falhou,
      " nao arrisca o delete de um job que continua rodando.
      IF iv_acao = c_can OR ls_log-result = c_er.
        RETURN.
      ENDIF.

      CLEAR ls_log.
      ls_log-jobname  = is_job-jobname.
      ls_log-jobcount = is_job-jobcount.

    ELSEIF iv_acao = c_can.
      " Job planejado/liberado nao se "cancela": deleta-se. Registrar no
      " log evita a impressao de que a acao funcionou.
      ls_log-acao   = 'CANCELAR'.
      ls_log-result = c_ig.
      ls_log-msg    = 'Job nao esta ativo - use Deletar para remover o agendamento'.
      PERFORM f_add_log USING ls_log.
      RETURN.
    ENDIF.
  ENDIF.

  " --- Deletar --------------------------------------------------------
  IF iv_acao = c_del OR iv_acao = c_cde.
    PERFORM f_deletar USING is_job CHANGING ls_log.
    PERFORM f_add_log USING ls_log.
    RETURN.
  ENDIF.

  " --- Iniciar agora (copia do job com inicio imediato) ---------------
  IF iv_acao = c_str.
    PERFORM f_iniciar_agora USING is_job.
    RETURN.
  ENDIF.

  " --- Liberar job planejado ------------------------------------------
  IF iv_acao = c_rel.
    PERFORM f_liberar USING is_job.
    RETURN.
  ENDIF.

  " --- Reagendar (copia para nova data/hora) --------------------------
  IF iv_acao = c_res.
    PERFORM f_reagendar USING is_job.
    RETURN.
  ENDIF.

ENDFORM.

"======================================================================
" f_data_alvo - quando o job disparado deve comecar
"======================================================================
FORM f_data_alvo CHANGING cv_imed TYPE c
                          cv_data TYPE sy-datum
                          cv_hora TYPE sy-uzeit.

  CLEAR: cv_imed, cv_data, cv_hora.

  IF p_rimed = 'X'.
    cv_imed = 'X'.
    RETURN.
  ENDIF.

  cv_data = p_rdate.
  cv_hora = p_rtime.

  " Data/hora ja vencida (a tela ficou aberta um tempo) vira execucao
  " imediata, em vez de erro de data invalida no JOB_CLOSE.
  IF cv_data IS INITIAL
     OR cv_data < sy-datum
     OR ( cv_data = sy-datum AND cv_hora <= sy-uzeit ).
    cv_imed = 'X'.
    CLEAR: cv_data, cv_hora.
  ENDIF.

ENDFORM.

"======================================================================
" f_iniciar_agora - "repetir job" da SM37
"----------------------------------------------------------------------
" Cria uma COPIA do job (mesmo nome, mesmos steps, mesmo usuario de
" execucao) e inicia. O agendamento original fica intacto - e isso e
" proposital: quem manda rodar agora quase nunca quer perder a
" periodicidade que ja estava valendo.
"======================================================================
FORM f_iniciar_agora USING is_job TYPE ty_job.

  DATA: ls_log  TYPE ty_log,
        lv_data TYPE sy-datum,
        lv_hora TYPE sy-uzeit,
        lv_novo TYPE tbtco-jobcount.

  CLEAR ls_log.
  ls_log-jobname  = is_job-jobname.
  ls_log-jobcount = is_job-jobcount.
  ls_log-acao     = 'INICIAR AGORA'.

  " Job ja rodando nao se "inicia de novo" por engano.
  IF is_job-status = c_st_ativ.
    ls_log-result = c_ig.
    ls_log-msg = 'Job ja esta ativo - nada a iniciar'.
    PERFORM f_add_log USING ls_log.
    RETURN.
  ENDIF.

  " Aqui o inicio e sempre imediato ('X'); quem quer outra data/hora usa
  " Reagendar, que le P_RDATE/P_RTIME.
  PERFORM f_copiar_job USING is_job 'X' lv_data lv_hora
                       CHANGING lv_novo ls_log.
  PERFORM f_add_log USING ls_log.

ENDFORM.

"======================================================================
" f_liberar - libera job PLANEJADO (status P)
"----------------------------------------------------------------------
" Job planejado e um job criado e nunca liberado: existe na TBTCO, mas
" nunca vai rodar. JOB_CLOSE sobre o par jobname/jobcount existente e o
" que a SM37 faz ao liberar.
"======================================================================
FORM f_liberar USING is_job TYPE ty_job.

  DATA: ls_log  TYPE ty_log,
        lv_imed TYPE c LENGTH 1,
        lv_data TYPE sy-datum,
        lv_hora TYPE sy-uzeit,
        lv_name TYPE tbtcjob-jobname,
        lv_cnt  TYPE tbtcjob-jobcount.

  CLEAR ls_log.
  ls_log-jobname  = is_job-jobname.
  ls_log-jobcount = is_job-jobcount.
  ls_log-acao     = 'LIBERAR'.

  IF is_job-status <> c_st_plan.
    ls_log-result = c_ig.
    ls_log-msg = 'So job PLANEJADO (status P) pode ser liberado'.
    PERFORM f_add_log USING ls_log.
    RETURN.
  ENDIF.

  PERFORM f_data_alvo CHANGING lv_imed lv_data lv_hora.

  " Sem data alvo e sem P_RIMED, mantem o inicio previsto original.
  IF lv_imed IS INITIAL AND lv_data IS INITIAL.
    lv_data = is_job-sdldate.
    lv_hora = is_job-sdltime.
  ENDIF.

  IF p_test = 'X'.
    ls_log-result = c_ok.
    IF lv_imed = 'X'.
      ls_log-msg = 'SIMULADO - job seria liberado com inicio imediato'.
    ELSE.
      ls_log-msg = 'SIMULADO - job seria liberado na data prevista'.
    ENDIF.
    PERFORM f_add_log USING ls_log.
    RETURN.
  ENDIF.

  lv_name = is_job-jobname.
  lv_cnt  = is_job-jobcount.

  IF lv_imed = 'X'.
    CALL FUNCTION 'JOB_CLOSE'
      EXPORTING
        jobcount             = lv_cnt
        jobname              = lv_name
        strtimmed            = 'X'
      EXCEPTIONS
        cant_start_immediate = 1
        invalid_startdate    = 2
        jobname_missing      = 3
        job_close_failed     = 4
        job_nosteps          = 5
        job_notex            = 6
        lock_failed          = 7
        OTHERS               = 8.
  ELSE.
    CALL FUNCTION 'JOB_CLOSE'
      EXPORTING
        jobcount             = lv_cnt
        jobname              = lv_name
        sdlstrtdt            = lv_data
        sdlstrttm            = lv_hora
      EXCEPTIONS
        cant_start_immediate = 1
        invalid_startdate    = 2
        jobname_missing      = 3
        job_close_failed     = 4
        job_nosteps          = 5
        job_notex            = 6
        lock_failed          = 7
        OTHERS               = 8.
  ENDIF.

  CASE sy-subrc.
    WHEN 0.
      ls_log-result = c_ok.
      IF lv_imed = 'X'.
        ls_log-msg = 'Job liberado com inicio imediato'.
      ELSE.
        ls_log-msg = 'Job liberado'.
      ENDIF.
    WHEN 1.
      ls_log-result = c_er.
      ls_log-msg = 'Sem processo de background livre para inicio imediato'.
    WHEN 5.
      ls_log-result = c_er.
      ls_log-msg = 'Job sem steps - nada a liberar'.
    WHEN 6.
      ls_log-result = c_ig.
      ls_log-msg = 'Job nao existe mais'.
    WHEN 7.
      ls_log-result = c_er.
      ls_log-msg = 'Job bloqueado por outro processo'.
    WHEN OTHERS.
      ls_log-result = c_er.
      ls_log-msg = 'Falha ao liberar o job (use Reagendar para recria-lo)'.
  ENDCASE.

  PERFORM f_add_log USING ls_log.

ENDFORM.

"======================================================================
" f_reagendar - copia o job para outra data/hora
"----------------------------------------------------------------------
" Nao existe API padrao liberada para "desliberar" um job ja liberado e
" mudar a data. O caminho seguro e o que a propria SM37 sugere: criar a
" copia na data nova e, se o usuario quiser, deletar o original
" (P_RDEL). Assim nunca se fica sem nenhum dos dois.
"======================================================================
FORM f_reagendar USING is_job TYPE ty_job.

  DATA: ls_log  TYPE ty_log,
        lv_imed TYPE c LENGTH 1,
        lv_data TYPE sy-datum,
        lv_hora TYPE sy-uzeit,
        lv_novo TYPE tbtco-jobcount.

  CLEAR ls_log.
  ls_log-jobname  = is_job-jobname.
  ls_log-jobcount = is_job-jobcount.
  ls_log-acao     = 'REAGENDAR'.

  PERFORM f_data_alvo CHANGING lv_imed lv_data lv_hora.

  PERFORM f_copiar_job USING is_job lv_imed lv_data lv_hora
                       CHANGING lv_novo ls_log.
  PERFORM f_add_log USING ls_log.

  " So deleta o original depois que a copia existe de verdade.
  CHECK p_rdel = 'X'.
  CHECK ls_log-result = c_ok.

  CLEAR ls_log.
  ls_log-jobname  = is_job-jobname.
  ls_log-jobcount = is_job-jobcount.
  PERFORM f_deletar USING is_job CHANGING ls_log.
  PERFORM f_add_log USING ls_log.

ENDFORM.

"======================================================================
" f_copiar_job - cria um novo job com os steps de um job existente
"----------------------------------------------------------------------
" Le os steps na TBTCP e reconstroi o job com JOB_OPEN + JOB_SUBMIT +
" JOB_CLOSE. Steps de comando externo (sem PROGNAME) nao sao copiaveis
" por esta via e sao reportados como erro, sem criar job pela metade.
"
" ANTI-LOOP: o novo job entra em GT_FEITO na hora. Sem isso, no modo
" direto o proximo lote leria o job recem-criado (mesmo nome, mesma
" mascara) e o dispararia de novo, e de novo - exatamente o tipo de
" laco que gerou o incidente da ZSDR1119.
"======================================================================
FORM f_copiar_job USING is_job TYPE ty_job
                        iv_imed TYPE c
                        iv_data TYPE sy-datum
                        iv_hora TYPE sy-uzeit
                  CHANGING cv_novo TYPE tbtco-jobcount
                           cs_log TYPE ty_log.

  TYPES: BEGIN OF ty_st,
           stepcount TYPE tbtcp-stepcount,
           progname  TYPE tbtcp-progname,
           variant   TYPE tbtcp-variant,
           authcknam TYPE tbtcp-authcknam,
         END OF ty_st.

  DATA: lt_st   TYPE STANDARD TABLE OF ty_st,
        ls_st   TYPE ty_st,
        lv_name TYPE tbtcjob-jobname,
        lv_cnt  TYPE tbtcjob-jobcount,
        lv_var  TYPE raldb_vari,
        lv_user TYPE tbtcjob-authcknam,
        lv_qtd  TYPE i,
        lv_c    TYPE c LENGTH 12,
        ls_key  TYPE ty_key.

  CLEAR cv_novo.

  SELECT stepcount progname variant authcknam
    FROM tbtcp
    INTO TABLE lt_st
    WHERE jobname  = is_job-jobname
      AND jobcount = is_job-jobcount
    ORDER BY stepcount.

  IF lt_st IS INITIAL.
    cs_log-result = c_er.
    cs_log-msg = 'Job sem steps na TBTCP - nada a copiar'.
    RETURN.
  ENDIF.

  " Step de comando externo / programa externo nao tem PROGNAME.
  LOOP AT lt_st INTO ls_st WHERE progname IS INITIAL.
    cs_log-result = c_er.
    cs_log-msg = 'Job tem step externo (comando SM49) - copie pela SM37'.
    RETURN.
  ENDLOOP.

  IF p_test = 'X'.
    lv_qtd = lines( lt_st ).
    WRITE lv_qtd TO lv_c LEFT-JUSTIFIED.
    cs_log-result = c_ok.
    IF iv_imed = 'X'.
      CONCATENATE 'SIMULADO - copia com' lv_c
                  'step(s) seria criada e iniciada agora'
             INTO cs_log-msg SEPARATED BY space.
    ELSE.
      CONCATENATE 'SIMULADO - copia com' lv_c 'step(s) seria agendada'
             INTO cs_log-msg SEPARATED BY space.
    ENDIF.
    RETURN.
  ENDIF.

  lv_name = is_job-jobname.

  CALL FUNCTION 'JOB_OPEN'
    EXPORTING
      jobname          = lv_name
      jobclass         = is_job-jobclass
    IMPORTING
      jobcount         = lv_cnt
    EXCEPTIONS
      cant_create_job  = 1
      invalid_job_data = 2
      jobname_missing  = 3
      OTHERS           = 4.
  IF sy-subrc <> 0.
    cs_log-result = c_er.
    cs_log-msg = 'Nao foi possivel criar o job (JOB_OPEN)'.
    RETURN.
  ENDIF.

  " Registra a copia ANTES de liberar: mesmo que algo falhe adiante, o
  " novo jobcount ja esta marcado como tratado e nao volta pelo laco.
  ls_key-jobname = lv_name.
  ls_key-jobcount = lv_cnt.
  READ TABLE gt_feito WITH TABLE KEY jobname  = ls_key-jobname
                                     jobcount = ls_key-jobcount
                      TRANSPORTING NO FIELDS.
  IF sy-subrc <> 0.
    INSERT ls_key INTO TABLE gt_feito.
  ENDIF.

  LOOP AT lt_st INTO ls_st.
    lv_var = ls_st-variant.
    lv_user = ls_st-authcknam.
    IF lv_user IS INITIAL.
      lv_user = is_job-authcknam.
    ENDIF.
    IF lv_user IS INITIAL.
      lv_user = sy-uname.
    ENDIF.

    CALL FUNCTION 'JOB_SUBMIT'
      EXPORTING
        authcknam               = lv_user
        jobcount                = lv_cnt
        jobname                 = lv_name
        report                  = ls_st-progname
        variant                 = lv_var
      EXCEPTIONS
        bad_priparams           = 1
        bad_xpgflags            = 2
        invalid_jobdata         = 3
        jobname_missing         = 4
        job_notex               = 5
        job_submit_failed       = 6
        lock_failed             = 7
        program_missing         = 8
        prog_abap_and_extpg_set = 9
        OTHERS                  = 10.
    IF sy-subrc <> 0.
      cs_log-result = c_er.
      CONCATENATE 'Falha ao copiar o step do programa' ls_st-progname
             INTO cs_log-msg SEPARATED BY space.
      " Job aberto sem step nenhum e removido para nao virar lixo.
      CALL FUNCTION 'BP_JOB_DELETE'
        EXPORTING
          jobcount = lv_cnt
          jobname  = lv_name
        EXCEPTIONS
          OTHERS   = 1.
      RETURN.
    ENDIF.
  ENDLOOP.

  IF iv_imed = 'X'.
    CALL FUNCTION 'JOB_CLOSE'
      EXPORTING
        jobcount             = lv_cnt
        jobname              = lv_name
        strtimmed            = 'X'
      EXCEPTIONS
        cant_start_immediate = 1
        invalid_startdate    = 2
        jobname_missing      = 3
        job_close_failed     = 4
        job_nosteps          = 5
        job_notex            = 6
        lock_failed          = 7
        OTHERS               = 8.
  ELSE.
    CALL FUNCTION 'JOB_CLOSE'
      EXPORTING
        jobcount             = lv_cnt
        jobname              = lv_name
        sdlstrtdt            = iv_data
        sdlstrttm            = iv_hora
      EXCEPTIONS
        cant_start_immediate = 1
        invalid_startdate    = 2
        jobname_missing      = 3
        job_close_failed     = 4
        job_nosteps          = 5
        job_notex            = 6
        lock_failed          = 7
        OTHERS               = 8.
  ENDIF.

  IF sy-subrc <> 0.
    cs_log-result = c_er.
    IF sy-subrc = 1.
      cs_log-msg = 'Sem processo de background livre para inicio imediato'.
    ELSE.
      cs_log-msg = 'Copia criada mas nao liberada - veja a SM37'.
    ENDIF.
    RETURN.
  ENDIF.

  cv_novo = lv_cnt.
  cs_log-result = c_ok.
  IF iv_imed = 'X'.
    CONCATENATE 'Copia iniciada agora - novo nr. de job' lv_cnt
           INTO cs_log-msg SEPARATED BY space.
  ELSE.
    CONCATENATE 'Copia agendada - novo nr. de job' lv_cnt
           INTO cs_log-msg SEPARATED BY space.
  ENDIF.

ENDFORM.

"======================================================================
" f_abortar - interrompe job ativo (BP_JOB_ABORT)
"======================================================================
FORM f_abortar USING is_job TYPE ty_job
               CHANGING cs_log TYPE ty_log.

  cs_log-acao = 'CANCELAR'.

  IF p_test = 'X'.
    cs_log-result = c_ok.
    cs_log-msg = 'SIMULADO - job ativo seria interrompido'.
    RETURN.
  ENDIF.

  CALL FUNCTION 'BP_JOB_ABORT'
    EXPORTING
      jobcount                   = is_job-jobcount
      jobname                    = is_job-jobname
    EXCEPTIONS
      checking_of_job_has_failed = 1
      job_abort_failed           = 2
      job_does_not_exist         = 3
      job_is_not_active          = 4
      no_abort_privilege_given   = 5
      OTHERS                     = 6.

  CASE sy-subrc.
    WHEN 0.
      cs_log-result = c_ok.
      cs_log-msg = 'Job interrompido'.
    WHEN 3.
      cs_log-result = c_ig.
      cs_log-msg = 'Job nao existe mais'.
    WHEN 4.
      cs_log-result = c_ig.
      cs_log-msg = 'Job nao estava ativo'.
    WHEN 5.
      cs_log-result = c_er.
      cs_log-msg = 'Sem autorizacao para interromper (S_BTCH_ADM)'.
    WHEN OTHERS.
      cs_log-result = c_er.
      cs_log-msg = 'Falha ao interromper o job'.
  ENDCASE.

ENDFORM.

"======================================================================
" f_deletar - deleta o job (BP_JOB_DELETE)
"----------------------------------------------------------------------
" Para job periodico, deletar a ocorrencia agendada e o que interrompe a
" corrente: nao existe sucessor pendente em outro lugar.
"======================================================================
FORM f_deletar USING is_job TYPE ty_job
               CHANGING cs_log TYPE ty_log.

  cs_log-acao = 'DELETAR'.

  IF p_test = 'X'.
    cs_log-result = c_ok.
    cs_log-msg = 'SIMULADO - job seria deletado'.
    RETURN.
  ENDIF.

  CALL FUNCTION 'BP_JOB_DELETE'
    EXPORTING
      jobcount                = is_job-jobcount
      jobname                 = is_job-jobname
    EXCEPTIONS
      cant_delete_event_entry = 1
      cant_delete_job         = 2
      job_delete_failed       = 3
      job_doesnt_exist        = 4
      job_is_already_running  = 5
      no_delete_authority     = 6
      OTHERS                  = 7.

  CASE sy-subrc.
    WHEN 0.
      cs_log-result = c_ok.
      cs_log-msg = 'Job deletado'.
    WHEN 4.
      cs_log-result = c_ig.
      cs_log-msg = 'Job ja nao existe'.
    WHEN 5.
      cs_log-result = c_er.
      cs_log-msg = 'Job em execucao - use Cancelar+Deletar'.
    WHEN 6.
      cs_log-result = c_er.
      cs_log-msg = 'Sem autorizacao para deletar (S_BTCH_ADM/S_BTCH_JOB)'.
    WHEN 1.
      cs_log-result = c_er.
      cs_log-msg = 'Nao foi possivel remover a entrada de evento do job'.
    WHEN OTHERS.
      cs_log-result = c_er.
      cs_log-msg = 'Falha ao deletar o job'.
  ENDCASE.

ENDFORM.

"======================================================================
" f_add_log - acumula log + contadores
"----------------------------------------------------------------------
" O detalhe e limitado a C_MAX_LOG linhas: numa limpeza de centenas de
" milhares de jobs guardar tudo em memoria nao ajuda ninguem. Erro
" sempre entra; os contadores continuam somando alem do teto.
"======================================================================
FORM f_add_log USING is_log TYPE ty_log.

  DATA ls_log TYPE ty_log.

  ls_log = is_log.

  CASE ls_log-result.
    WHEN c_ok.
      gv_ok = gv_ok + 1.
      ls_log-icone = icon_led_green.
      ls_log-resul_tx = 'OK'.
    WHEN c_er.
      gv_erro = gv_erro + 1.
      ls_log-icone = icon_led_red.
      ls_log-resul_tx = 'ERRO'.
    WHEN OTHERS.
      gv_ign = gv_ign + 1.
      ls_log-icone = icon_led_yellow.
      ls_log-resul_tx = 'IGNORADO'.
  ENDCASE.

  IF ls_log-result = c_er OR lines( gt_log ) < c_max_log.
    APPEND ls_log TO gt_log.
  ENDIF.

ENDFORM.

"======================================================================
" f_remover_deletados - tira do ALV os jobs que sairam do sistema
"======================================================================
FORM f_remover_deletados.

  DATA ls_log TYPE ty_log.

  LOOP AT gt_log INTO ls_log WHERE result = c_ok AND acao = 'DELETAR'.
    DELETE gt_job WHERE jobname  = ls_log-jobname
                    AND jobcount = ls_log-jobcount.
  ENDLOOP.

ENDFORM.

"======================================================================
" f_atualizar - rele a selecao (botao Atualizar do ALV)
"======================================================================
FORM f_atualizar.

  DATA: lo_disp TYPE REF TO cl_salv_display_settings,
        lv_tit  TYPE lvc_title.

  PERFORM f_contar USING 'X' 'X' 'X' CHANGING gv_tot_sel.
  PERFORM f_ler_jobs.

  IF gr_alv IS BOUND.
    lo_disp = gr_alv->get_display_settings( ).
    PERFORM f_titulo CHANGING lv_tit.
    lo_disp->set_list_header( lv_tit ).
    gr_alv->refresh( ).
  ENDIF.

ENDFORM.

"======================================================================
" f_popup_log - log da ultima acao em ALV popup
"======================================================================
FORM f_popup_log.

  DATA: lo_cols TYPE REF TO cl_salv_columns_table,
        lo_disp TYPE REF TO cl_salv_display_settings,
        lv_tit  TYPE lvc_title,
        lv_c1   TYPE c LENGTH 12,
        lv_c2   TYPE c LENGTH 12,
        lv_c3   TYPE c LENGTH 12,
        lv_txt  TYPE string,
        lx      TYPE REF TO cx_root.

  IF gt_log IS INITIAL.
    MESSAGE 'Nenhuma acao executada nesta sessao' TYPE 'S'
            DISPLAY LIKE 'W'.
    RETURN.
  ENDIF.

  TRY.
      cl_salv_table=>factory(
        IMPORTING r_salv_table = gr_log_alv
        CHANGING  t_table      = gt_log ).

      lo_cols = gr_log_alv->get_columns( ).
      lo_cols->set_optimize( abap_true ).
      PERFORM f_col USING lo_cols 'ICONE'    'St.'.
      PERFORM f_col USING lo_cols 'JOBNAME'  'Nome do job'.
      PERFORM f_col USING lo_cols 'JOBCOUNT' 'Nr. job'.
      PERFORM f_col USING lo_cols 'ACAO'     'Acao'.
      PERFORM f_col USING lo_cols 'RESULT'   'R'.
      PERFORM f_col USING lo_cols 'RESUL_TX' 'Resultado'.
      PERFORM f_col USING lo_cols 'MSG'      'Mensagem'.

      WRITE gv_ok   TO lv_c1 LEFT-JUSTIFIED.
      WRITE gv_erro TO lv_c2 LEFT-JUSTIFIED.
      WRITE gv_ign  TO lv_c3 LEFT-JUSTIFIED.
      CONCATENATE 'Log - OK:' lv_c1 '| Erros:' lv_c2 '| Ignorados:' lv_c3
             INTO lv_tit SEPARATED BY space.
      lo_disp = gr_log_alv->get_display_settings( ).
      lo_disp->set_list_header( lv_tit ).

      gr_log_alv->set_screen_popup( start_column = 5
                                    end_column   = 160
                                    start_line   = 2
                                    end_line     = 25 ).
      gr_log_alv->display( ).

    CATCH cx_root INTO lx.
      lv_txt = lx->get_text( ).
      MESSAGE lv_txt TYPE 'S' DISPLAY LIKE 'E'.
  ENDTRY.

ENDFORM.

"======================================================================
" f_abrir_sm37 - duplo clique na linha
"======================================================================
FORM f_abrir_sm37 USING is_job TYPE ty_job.

  SET PARAMETER ID 'BTC' FIELD is_job-jobname.
  CALL TRANSACTION 'SM37'.

ENDFORM.

"======================================================================
" f_acao_rapida - botao "Cancelar + Deletar TUDO com esse nome"
"----------------------------------------------------------------------
" Fluxo de um clique: digite o nome (ex.: ZSDR1119*) e mande apagar.
" Ignora status / so futuro / so periodicos / programa - so o nome (ou o
" preset do incidente) manda. As travas continuam todas valendo:
" simulacao, protecao de job SAP, job ativo, S_EXCL e confirmacao.
"
" Ate o teto online roda na hora e ja mostra o log; acima disso oferece
" o job de background, que e o unico caminho viavel para dezenas de
" milhares de jobs.
"======================================================================
FORM f_acao_rapida.

  DATA: lv_qtd  TYPE i,
        lv_teto TYPE i,
        lv_resp TYPE c LENGTH 1,
        lv_c1   TYPE c LENGTH 12,
        lv_c2   TYPE c LENGTH 12,
        lv_perg TYPE c LENGTH 200,
        lt_alvo TYPE tt_job.

  " f_init prepara o contexto (prefixos protegidos, GV_PACK, identificacao
  " do proprio job). Ela nao mexe em GV_QUICK.
  PERFORM f_init.
  gv_quick = 'X'.

  PERFORM f_montar_filtros.

  IF gr_nome IS INITIAL.
    MESSAGE 'Informe o nome do job (ex.: ZSDR1119*) ou marque o preset'
            TYPE 'I'.
    CLEAR gv_quick.
    RETURN.
  ENDIF.

  PERFORM f_contar USING 'X' 'X' 'X' CHANGING lv_qtd.
  IF lv_qtd = 0.
    PERFORM f_msg_vazio.
    CLEAR gv_quick.
    RETURN.
  ENDIF.

  PERFORM f_teto_efetivo USING c_cde CHANGING lv_teto.

  " --- Volume grande: vai para background -----------------------------
  IF lv_qtd > lv_teto.
    WRITE lv_qtd  TO lv_c1 LEFT-JUSTIFIED.
    WRITE lv_teto TO lv_c2 LEFT-JUSTIFIED.
    CONCATENATE 'Sao' lv_c1 'job(s), acima do teto online de' lv_c2
                '- agendar a limpeza completa em background?'
           INTO lv_perg SEPARATED BY space.

    CALL FUNCTION 'POPUP_TO_CONFIRM'
      EXPORTING
        titlebar              = 'Volume alto'
        text_question         = lv_perg
        text_button_1         = 'Agendar job'
        text_button_2         = 'Voltar'
        default_button        = '2'
        display_cancel_button = space
      IMPORTING
        answer                = lv_resp
      EXCEPTIONS
        OTHERS                = 2.

    IF lv_resp = '1'.
      PERFORM f_agendar_bg.
    ENDIF.
    CLEAR gv_quick.
    RETURN.
  ENDIF.

  " --- Volume pequeno: resolve na hora --------------------------------
  PERFORM f_confirmar USING c_cde lv_qtd CHANGING lv_resp.
  IF lv_resp <> '1'.
    CLEAR gv_quick.
    RETURN.
  ENDIF.

  PERFORM f_selecionar USING lv_teto CHANGING lt_alvo.
  PERFORM f_enriquecer CHANGING lt_alvo.

  CLEAR: gt_log, gv_proc, gv_ok, gv_erro, gv_ign.
  PERFORM f_processar USING c_cde CHANGING lt_alvo.
  PERFORM f_popup_log.

  CLEAR gv_quick.

ENDFORM.

"======================================================================
" f_popup_contagem - botao "Contar jobs da selecao"
"======================================================================
FORM f_popup_contagem.

  DATA: lv_qtd TYPE i,
        lv_c   TYPE c LENGTH 15,
        lv_tx  TYPE c LENGTH 200.

  PERFORM f_montar_filtros.
  PERFORM f_contar USING 'X' 'X' 'X' CHANGING lv_qtd.

  IF lv_qtd = 0.
    PERFORM f_msg_vazio.
    RETURN.
  ENDIF.

  WRITE lv_qtd TO lv_c LEFT-JUSTIFIED.
  CONCATENATE 'A selecao atinge' lv_c 'job(s).'
         INTO lv_tx SEPARATED BY space.

  IF lv_qtd > p_maxlin.
    CONCATENATE lv_tx
                'Acima do limite do ALV - use "Executar em background".'
           INTO lv_tx SEPARATED BY space.
  ENDIF.

  MESSAGE lv_tx TYPE 'I'.

ENDFORM.

"======================================================================
" f_agendar_bg - cria o job que executa a limpeza completa
"----------------------------------------------------------------------
" Caminho recomendado para volumes grandes: o job herda a selecao da
" tela (sem variante), roda com P_BATCH = 'X' (execucao direta, sem ALV)
" e nao sofre timeout de dialogo.
"======================================================================
FORM f_agendar_bg.

  DATA: lv_jobcount TYPE tbtcjob-jobcount,
        lv_jobname  TYPE tbtcjob-jobname,
        lv_qtd      TYPE i,
        lv_c        TYPE c LENGTH 15,
        lv_perg     TYPE c LENGTH 200,
        lv_resp     TYPE c LENGTH 1,
        lv_ac       TYPE c LENGTH 1,
        lv_acao     TYPE c LENGTH 20,
        lv_ja       TYPE c LENGTH 1,
        lv_repid    TYPE sy-repid,
        lv_teto     TYPE i,
        lv_tx       TYPE c LENGTH 200,
        " Valores efetivamente enviados ao job
        lv_s1       TYPE c LENGTH 1,
        lv_s2       TYPE c LENGTH 1,
        lv_s3       TYPE c LENGTH 1,
        lv_s4       TYPE c LENGTH 1,
        lv_s5       TYPE c LENGTH 1,
        lv_s6       TYPE c LENGTH 1,
        lv_fut      TYPE c LENGTH 1,
        lv_per      TYPE c LENGTH 1,
        lv_a1       TYPE c LENGTH 1,
        lv_a2       TYPE c LENGTH 1,
        lv_a3       TYPE c LENGTH 1,
        lv_a4       TYPE c LENGTH 1,
        lv_a5       TYPE c LENGTH 1,
        lv_a6       TYPE c LENGTH 1,
        lv_mx       TYPE i.

  " Trava herdada do incidente: nunca agendar a partir de uma execucao
  " que ja esta em background.
  IF sy-batch IS NOT INITIAL OR p_batch IS NOT INITIAL.
    MESSAGE 'Agendamento bloqueado em execucao de background' TYPE 'S'
            DISPLAY LIKE 'W'.
    RETURN.
  ENDIF.

  PERFORM f_montar_filtros.
  PERFORM f_contar USING 'X' 'X' 'X' CHANGING lv_qtd.

  IF lv_qtd = 0.
    PERFORM f_msg_vazio.
    RETURN.
  ENDIF.

  " A acao vem dos radios do bloco b4; f_init ainda nao rodou aqui.
  IF p_acan = 'X'.
    lv_ac = c_can.
  ELSEIF p_acde = 'X'.
    lv_ac = c_cde.
  ELSEIF p_astr = 'X'.
    lv_ac = c_str.
  ELSEIF p_arel = 'X'.
    lv_ac = c_rel.
  ELSEIF p_arsc = 'X'.
    lv_ac = c_res.
  ELSE.
    lv_ac = c_del.
  ENDIF.

  " Valores que o JOB vai receber. Sao variaveis, e nao os campos de
  " tela, porque a acao rapida precisa sobrescrever tudo: todos os
  " status, sem filtro de data/periodicidade, cancelar+deletar e sem
  " teto - exatamente o que o botao promete.
  lv_s1 = p_stpla. lv_s2 = p_stlib. lv_s3 = p_stpro.
  lv_s4 = p_stati. lv_s5 = p_stcon. lv_s6 = p_stcan.
  lv_fut = p_futur.
  lv_per = p_perio.
  lv_a1 = p_acan. lv_a2 = p_adel. lv_a3 = p_acde.
  lv_a4 = p_astr. lv_a5 = p_arel. lv_a6 = p_arsc.
  lv_mx = p_max.

  IF gv_quick = 'X'.
    lv_s1 = 'X'. lv_s2 = 'X'. lv_s3 = 'X'.
    lv_s4 = 'X'. lv_s5 = 'X'. lv_s6 = 'X'.
    CLEAR: lv_fut, lv_per.
    CLEAR: lv_a1, lv_a2, lv_a4, lv_a5, lv_a6.
    lv_a3 = 'X'.
    lv_mx = 0.
    lv_ac = c_cde.
  ENDIF.

  " Job sem status nenhum morreria em execucao com mensagem de erro;
  " melhor barrar aqui, com o usuario ainda na tela.
  IF lv_s1 IS INITIAL AND lv_s2 IS INITIAL AND lv_s3 IS INITIAL
     AND lv_s4 IS INITIAL AND lv_s5 IS INITIAL AND lv_s6 IS INITIAL.
    MESSAGE 'Marque ao menos um status de job antes de agendar' TYPE 'I'.
    RETURN.
  ENDIF.

  PERFORM f_nome_acao USING lv_ac CHANGING lv_acao.

  WRITE lv_qtd TO lv_c LEFT-JUSTIFIED.
  CONCATENATE 'Agendar job' p_jname 'para' lv_acao lv_c 'job(s)?'
         INTO lv_perg SEPARATED BY space.
  " Teto que o JOB vai aplicar: gv_mode_bg e ligado so para o calculo,
  " porque quem vai rodar e o job, nao esta sessao.
  gv_mode_bg = 'X'.
  PERFORM f_teto_efetivo USING lv_ac CHANGING lv_teto.
  CLEAR gv_mode_bg.

  IF p_test = 'X'.
    CONCATENATE lv_perg 'Modo SIMULACAO - nada sera alterado.'
           INTO lv_perg SEPARATED BY space.
  ELSEIF lv_teto = 0.
    CONCATENATE lv_perg 'EXECUCAO REAL sem teto: vai ate limpar tudo.'
           INTO lv_perg SEPARATED BY space.
  ELSE.
    WRITE lv_teto TO lv_c LEFT-JUSTIFIED.
    CONCATENATE lv_perg 'EXECUCAO REAL, teto de' lv_c 'nesta rodada.'
           INTO lv_perg SEPARATED BY space.
  ENDIF.

  CALL FUNCTION 'POPUP_TO_CONFIRM'
    EXPORTING
      titlebar              = 'Execucao em background'
      text_question         = lv_perg
      text_button_1         = 'Agendar'
      text_button_2         = 'Voltar'
      default_button        = '2'
      display_cancel_button = space
    IMPORTING
      answer                = lv_resp
    EXCEPTIONS
      OTHERS                = 2.
  CHECK lv_resp = '1'.

  lv_jobname = p_jname.
  CALL FUNCTION 'JOB_OPEN'
    EXPORTING
      jobname          = lv_jobname
    IMPORTING
      jobcount         = lv_jobcount
    EXCEPTIONS
      cant_create_job  = 1
      invalid_job_data = 2
      jobname_missing  = 3
      OTHERS           = 4.
  IF sy-subrc <> 0.
    MESSAGE 'Nao foi possivel criar o job de limpeza' TYPE 'S'
            DISPLAY LIKE 'E'.
    RETURN.
  ENDIF.

  " A selecao inteira viaja no SUBMIT - inclusive P_BATCH = 'X', que faz
  " o job rodar em modo direto (sem ALV) e ignorar os botoes de tela.
  " P_STEP vai desligado: em background a leitura da TBTCP so serve ao
  " filtro por programa, que continua funcionando via S_PROG.
  "
  " SUBMIT dinamico por SY-REPID: o programa se reagenda com o nome que
  " ele realmente tem no sistema (ZJOB, ZJOBS, ZBCJOBS...), sem depender
  " de um nome fixo no fonte.
  lv_repid = sy-repid.
  SUBMIT (lv_repid)
    WITH s_jobnam IN s_jobnam
    WITH s_criad  IN s_criad
    WITH s_prog   IN s_prog
    WITH s_sdldat IN s_sdldat
    WITH s_sdltim IN s_sdltim
    WITH s_excl   IN s_excl
    WITH p_stpla  = lv_s1
    WITH p_stlib  = lv_s2
    WITH p_stpro  = lv_s3
    WITH p_stati  = lv_s4
    WITH p_stcon  = lv_s5
    WITH p_stcan  = lv_s6
    WITH p_futur  = lv_fut
    WITH p_perio  = lv_per
    WITH p_step   = space
    WITH p_maxlin = p_maxlin
    WITH p_inc    = p_inc
    WITH p_test   = p_test
    WITH p_prot   = p_prot
    WITH p_proat  = p_proat
    WITH p_max    = lv_mx
    WITH p_pack   = p_pack
    WITH p_acan   = lv_a1
    WITH p_adel   = lv_a2
    WITH p_acde   = lv_a3
    WITH p_astr   = lv_a4
    WITH p_arel   = lv_a5
    WITH p_arsc   = lv_a6
    WITH p_rimed  = p_rimed
    WITH p_rdate  = p_rdate
    WITH p_rtime  = p_rtime
    WITH p_rdel   = p_rdel
    WITH p_batch  = 'X'
    USER sy-uname
    VIA JOB lv_jobname NUMBER lv_jobcount
    AND RETURN.
  IF sy-subrc <> 0.
    " O job ja existe (JOB_OPEN) mas ficou sem step: sem isso ele fica
    " para sempre "escalonado" na SM37, virando lixo - foi o que
    " aconteceu com o primeiro ZJOBS_LIMPEZA.
    PERFORM f_matar_job_orfao USING lv_jobname lv_jobcount.
    MESSAGE 'Nao foi possivel montar o step do job - o job vazio foi removido'
            TYPE 'I'.
    RETURN.
  ENDIF.

  " Data/hora ja vencida (tipico: a tela ficou aberta um tempo) vira
  " execucao imediata em vez de erro de data invalida.
  IF p_jdate < sy-datum
     OR ( p_jdate = sy-datum AND p_jtime <= sy-uzeit ).
    lv_ja = 'X'.
  ENDIF.

  IF lv_ja = 'X'.
    CALL FUNCTION 'JOB_CLOSE'
      EXPORTING
        jobcount             = lv_jobcount
        jobname              = lv_jobname
        strtimmed            = 'X'
      EXCEPTIONS
        cant_start_immediate = 1
        invalid_startdate    = 2
        jobname_missing      = 3
        job_close_failed     = 4
        job_nosteps          = 5
        job_notex            = 6
        lock_failed          = 7
        OTHERS               = 8.
  ELSE.
    CALL FUNCTION 'JOB_CLOSE'
      EXPORTING
        jobcount             = lv_jobcount
        jobname              = lv_jobname
        sdlstrtdt            = p_jdate
        sdlstrttm            = p_jtime
      EXCEPTIONS
        cant_start_immediate = 1
        invalid_startdate    = 2
        jobname_missing      = 3
        job_close_failed     = 4
        job_nosteps          = 5
        job_notex            = 6
        lock_failed          = 7
        OTHERS               = 8.
  ENDIF.

  IF sy-subrc <> 0.
    PERFORM f_matar_job_orfao USING lv_jobname lv_jobcount.
    MESSAGE 'Falha ao liberar o job - verifique processos de background livres (SM50)'
            TYPE 'I'.
    RETURN.
  ENDIF.

  CONCATENATE 'Job' lv_jobname
              'agendado - acompanhe pela SM37 ou pelo botao "Situacao do job"'
         INTO lv_tx SEPARATED BY space.
  MESSAGE lv_tx TYPE 'S'.

ENDFORM.

"======================================================================
" f_matar_job_orfao - remove job aberto que nao chegou a ser liberado
"----------------------------------------------------------------------
" Job criado por JOB_OPEN e nao liberado fica "escalonado" na SM37 para
" sempre, sem nunca rodar. Se o agendamento falhou no meio, ele nao pode
" sobrar.
"======================================================================
FORM f_matar_job_orfao USING iv_jobname TYPE tbtcjob-jobname
                             iv_jobcount TYPE tbtcjob-jobcount.

  CHECK iv_jobname IS NOT INITIAL AND iv_jobcount IS NOT INITIAL.

  CALL FUNCTION 'BP_JOB_DELETE'
    EXPORTING
      jobcount = iv_jobcount
      jobname  = iv_jobname
    EXCEPTIONS
      OTHERS   = 1.

  IF sy-subrc = 0.
    COMMIT WORK.
  ENDIF.

ENDFORM.

"======================================================================
" f_popup_status_job - ultimas execucoes do job de limpeza
"======================================================================
FORM f_popup_status_job.

  TYPES: BEGIN OF ty_lin,
           jobcount TYPE tbtco-jobcount,
           situacao TYPE c LENGTH 22,
           sdldata  TYPE c LENGTH 10,
           sdlhora  TYPE c LENGTH 8,
           exedata  TYPE c LENGTH 10,
           exehora  TYPE c LENGTH 8,
         END OF ty_lin.

  DATA: lt_lin  TYPE TABLE OF ty_lin,
        ls_lin  TYPE ty_lin,
        lt_o    TYPE TABLE OF tbtco,
        ls_o    TYPE tbtco,
        lv_icon TYPE c LENGTH 4,
        lv_sel  TYPE sy-tabix.

  SELECT * FROM tbtco
    UP TO 20 ROWS
    INTO TABLE lt_o
    WHERE jobname = p_jname
    ORDER BY sdldate DESCENDING sdltime DESCENDING.

  IF lt_o IS INITIAL.
    MESSAGE 'Nenhum job de limpeza encontrado com esse nome' TYPE 'S'
            DISPLAY LIKE 'W'.
    RETURN.
  ENDIF.

  LOOP AT lt_o INTO ls_o.
    CLEAR ls_lin.
    ls_lin-jobcount = ls_o-jobcount.
    PERFORM f_texto_status USING ls_o-status
                           CHANGING ls_lin-situacao lv_icon.
    WRITE ls_o-sdldate TO ls_lin-sdldata.
    WRITE ls_o-sdltime TO ls_lin-sdlhora.
    IF ls_o-strtdate IS NOT INITIAL.
      WRITE ls_o-strtdate TO ls_lin-exedata.
      WRITE ls_o-strttime TO ls_lin-exehora.
    ENDIF.
    APPEND ls_lin TO lt_lin.
  ENDLOOP.

  CALL FUNCTION 'POPUP_WITH_TABLE_DISPLAY'
    EXPORTING
      endpos_col   = 90
      endpos_row   = 22
      startpos_col = 5
      startpos_row = 3
      titletext    = 'Ultimas execucoes do job de limpeza'
    IMPORTING
      choise       = lv_sel
    TABLES
      valuetab     = lt_lin
    EXCEPTIONS
      break_off    = 1
      OTHERS       = 2.

ENDFORM.

"======================================================================
" f_exec_direto - modo sem ALV (job de limpeza / execucao em batch)
"----------------------------------------------------------------------
" Le a TBTCO em lotes de C_PACK_SEL e vai tratando. Como os jobs
" deletados somem da leitura seguinte, o mesmo SELECT "anda" sozinho
" pela fila; o que falha (ou esta protegido) fica registrado em GT_FEITO
" para nao ser reprocessado - e quando um lote inteiro so traz jobs ja
" tentados, o laco encerra.
"======================================================================
FORM f_exec_direto.

  DATA: lt_pak   TYPE tt_job,
        lt_todo  TYPE tt_job,
        ls_job   TYPE ty_job,
        ls_key   TYPE ty_key,
        lv_novos TYPE i,
        lv_falta TYPE i,
        lv_from  TYPE i,
        lv_lim   TYPE i.

  " Teto real desta execucao (acao de disparo tem teto duro).
  PERFORM f_teto_efetivo USING gv_acao CHANGING gv_teto.

  PERFORM f_contar USING 'X' 'X' 'X' CHANGING gv_tot_sel.

  IF gv_tot_sel = 0.
    PERFORM f_write_cab.
    WRITE: / 'Nenhum job atende a selecao informada.'.
    RETURN.
  ENDIF.

  " --- Simulacao ------------------------------------------------------
  " Sem delete o SELECT nao anda, entao le uma unica vez ate o teto de
  " detalhe; o total real vem do COUNT(*).
  IF p_test = 'X'.
    lv_lim = gv_teto.
    IF lv_lim <= 0 OR lv_lim > c_max_test.
      lv_lim = c_max_test.
    ENDIF.
    PERFORM f_selecionar USING lv_lim CHANGING lt_todo.
    PERFORM f_ler_steps  CHANGING lt_todo.
    PERFORM f_enriquecer CHANGING lt_todo.
    PERFORM f_processar  USING gv_acao CHANGING lt_todo.
    PERFORM f_write_log.
    RETURN.
  ENDIF.

  " --- Execucao real, em lotes ----------------------------------------
  DO.
    PERFORM f_selecionar USING c_pack_sel CHANGING lt_pak.
    IF lt_pak IS INITIAL.
      EXIT.
    ENDIF.

    PERFORM f_ler_steps  CHANGING lt_pak.
    PERFORM f_enriquecer CHANGING lt_pak.

    " Descarta o que ja foi tentado neste run (protegido ou com erro).
    CLEAR: lt_todo, lv_novos.
    LOOP AT lt_pak INTO ls_job.
      ls_key-jobname  = ls_job-jobname.
      ls_key-jobcount = ls_job-jobcount.
      READ TABLE gt_feito WITH TABLE KEY jobname  = ls_key-jobname
                                         jobcount = ls_key-jobcount
                          TRANSPORTING NO FIELDS.
      IF sy-subrc = 0.
        CONTINUE.
      ENDIF.
      INSERT ls_key INTO TABLE gt_feito.
      APPEND ls_job TO lt_todo.
      lv_novos = lv_novos + 1.
    ENDLOOP.

    " Lote inteiro composto de jobs ja tentados: nao ha mais progresso
    " possivel - o que resta esta protegido ou deu erro.
    IF lv_novos = 0.
      EXIT.
    ENDIF.

    " Respeita o teto desta execucao (GV_TETO = 0 -> sem teto, o que so
    " acontece em limpeza; disparo sempre tem teto).
    IF gv_teto > 0.
      lv_falta = gv_teto - gv_proc.
      IF lv_falta <= 0.
        EXIT.
      ENDIF.
      IF lines( lt_todo ) > lv_falta.
        lv_from = lv_falta + 1.
        DELETE lt_todo FROM lv_from.
      ENDIF.
    ENDIF.

    PERFORM f_processar USING gv_acao CHANGING lt_todo.

    IF gv_teto > 0 AND gv_proc >= gv_teto.
      EXIT.
    ENDIF.
  ENDDO.

  PERFORM f_write_log.

ENDFORM.

"======================================================================
" f_write_cab - cabecalho do log em lista (spool do job)
"======================================================================
FORM f_write_cab.

  DATA: lv_acao TYPE c LENGTH 20,
        lv_modo TYPE c LENGTH 20.

  PERFORM f_nome_acao USING gv_acao CHANGING lv_acao.

  IF p_test = 'X'.
    lv_modo = 'SIMULACAO'.
  ELSE.
    lv_modo = 'EXECUCAO REAL'.
  ENDIF.

  WRITE: / 'ZJOBS - controle de jobs de background'.
  WRITE: / 'Data/hora......:', sy-datum, sy-uzeit.
  WRITE: / 'Usuario........:', sy-uname.
  WRITE: / 'Modo...........:', lv_modo.
  WRITE: / 'Acao...........:', lv_acao.
  WRITE: / 'Jobs na selecao:', gv_tot_sel.
  IF gv_teto > 0.
    WRITE: / 'Teto da rodada.:', gv_teto.
    IF gv_teto <> p_max.
      WRITE: '(teto de seguranca aplicado sobre o P_MAX informado)'.
    ENDIF.
  ELSE.
    WRITE: / 'Teto da rodada.: sem teto'.
  ENDIF.
  ULINE.

ENDFORM.

"======================================================================
" f_write_log - resumo + detalhe no spool
"======================================================================
FORM f_write_log.

  DATA: ls_log  TYPE ty_log,
        lv_rest TYPE i.

  PERFORM f_write_cab.

  WRITE: / 'Jobs tratados..:', gv_proc.
  WRITE: / 'Sucesso........:', gv_ok.
  WRITE: / 'Ignorados......:', gv_ign.
  WRITE: / 'Erros..........:', gv_erro.

  lv_rest = gv_tot_sel - gv_proc.
  IF lv_rest > 0.
    WRITE: / 'Restaram.......:', lv_rest,
             '(reagende o job para continuar a limpeza)'.
  ENDIF.
  ULINE.

  IF gt_log IS INITIAL.
    RETURN.
  ENDIF.

  WRITE: / 'Detalhe (erros sempre listados; sucessos ate o teto de log)'.
  ULINE.
  FORMAT COLOR COL_HEADING.
  WRITE: /(32) 'Job', (10) 'Nr.', (20) 'Acao', (14) 'Resultado',
          (80) 'Mensagem'.
  FORMAT COLOR OFF.

  LOOP AT gt_log INTO ls_log.
    IF ls_log-result = c_er.
      FORMAT COLOR COL_NEGATIVE.
    ELSEIF ls_log-result = c_ig.
      FORMAT COLOR COL_TOTAL.
    ELSE.
      FORMAT COLOR OFF.
    ENDIF.
    WRITE: /(32) ls_log-jobname, (10) ls_log-jobcount,
            (20) ls_log-acao, (14) ls_log-resul_tx, (80) ls_log-msg.
  ENDLOOP.
  FORMAT COLOR OFF.

ENDFORM.
