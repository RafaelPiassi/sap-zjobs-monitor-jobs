# ZJOBS — Monitor e limpeza em massa de jobs (SM37)

**Programa:** `ZJOBS` (SE38) · **Transação:** `ZJOBS` (SE93)
**Desenvolvedor:** RPIASSI - Rafael Piassi
**Objetos necessários:** só o programa. **Sem** SE41 (status GUI), **sem** SE51 (tela), **sem** tabela Z.

Seleciona jobs da `TBTCO` por nome / usuário / programa / status / data prevista,
exibe em ALV e permite **cancelar** (interromper) e **deletar em massa** — em
volume que a SM37 não trata bem.

Nasceu do incidente de **12/08/2026 da ZSDR1119** (loop de agendamento que criou
centenas de milhares de jobs `ZSDR1119_BSF_M_*`, **periódicos**, portanto se
reagendando para todos os dias seguintes). A própria ZSDR1119 só cancela 2.000
por clique; aqui o volume é tratado em background, em lotes, sem teto.

---

## 1. Caminho rápido: só o nome do job

Botão **"Cancelar + Deletar TUDO com esse nome"** (bloco *Ação rápida*, logo abaixo
da seleção). É o fluxo de um clique:

1. Digite a máscara em *Nome do job* — ex.: `ZSDR1119*` — ou marque o preset.
2. Clique no botão.

Ele **ignora todos os demais filtros da tela** (status, "só futuro", "só
periódicos", programa): numa limpeza por nome esses filtros só escondem job que
deveria sair. Todos os status entram, sem restrição de data nem de periodicidade.

As travas continuam valendo: simulação (`P_TEST`), proteção de jobs SAP, jobs
ativos, `S_EXCL` e o popup de confirmação.

- Até o teto online (2.000, ou o `P_MAX` informado) → executa na hora e mostra o log.
- Acima disso → pergunta se pode agendar o job de background, que roda **sem teto**
  até limpar tudo.

---

## 2. Os dois modos de execução

| Modo | Quando | O que faz |
|---|---|---|
| **Online (ALV)** | Investigar, conferir, limpar poucos milhares | ALV com seleção de linhas e botões próprios. Limitado por `P_MAX` para não estourar o timeout de diálogo (`rdisp/max_wprun_time`). |
| **Direto (background)** | Volume grande (dezenas/centenas de milhares) | Sem ALV. Lê a TBTCO em lotes de 5.000, executa a ação, `COMMIT WORK` a cada N jobs e grava o log no spool. Sem teto e sem timeout. |

O modo direto é acionado de duas formas: pelo botão **"Executar em background"**
(cria o job com a seleção da tela, sem variante) ou agendando o programa na SM36
— ao rodar com `SY-BATCH`, ele já entra no modo direto sozinho.

### Botões do ALV

| Botão | Função |
|---|---|
| Marcar tudo / Desmarcar | Marca todas as linhas exibidas |
| **Cancelar** | `BP_JOB_ABORT` — interrompe os jobs **ativos** marcados |
| **Deletar** | `BP_JOB_DELETE` — deleta os jobs marcados |
| **Cancelar+Deletar** | Interrompe (se ativo) e deleta; se o abort falhar, não deleta |
| **Iniciar agora** | Cria uma **cópia** do job (mesmos steps, mesmo usuário) e inicia imediatamente — o "repetir job" da SM37. O agendamento original fica intacto |
| **Liberar** | Job **planejado** (status P, criado e nunca liberado) passa a valer — na data prevista ou imediatamente |
| **Reagendar** | Copia o job para a data/hora do bloco *Disparo*, opcionalmente deletando o original (`P_RDEL`) |
| Atualizar | Relê a seleção |
| Background | Agenda a execução completa em job |
| Log | Log da última ação (OK / Erros / Ignorados) |

### Disparo de jobs (bloco *Disparo / reagendamento*)

| Campo | Efeito |
|---|---|
| `P_RIMED` | Início imediato (padrão). Desmarcado, usa `P_RDATE`/`P_RTIME` |
| `P_RDATE` / `P_RTIME` | Data/hora alvo do **Liberar** e do **Reagendar**. Data já vencida vira início imediato, em vez de erro |
| `P_RDEL` | No **Reagendar**, deleta o job original — **só depois** de a cópia existir de verdade |

Como é feito, e por quê: **Iniciar agora** e **Reagendar** leem os steps na `TBTCP`
e reconstroem o job com `JOB_OPEN` + `JOB_SUBMIT` + `JOB_CLOSE`. Não existe API
padrão liberada para "desliberar" um job já liberado e mudar a data — por isso o
reagendamento é cópia + delete opcional, que usa só API documentada e nunca deixa
você sem nenhum dos dois. **Liberar** é `JOB_CLOSE` sobre o job planejado que já
existe, exatamente o que a SM37 faz.

Step de **comando externo** (SM49, sem `PROGNAME`) não é copiável por essa via:
o job entra no log como erro, sem criar nada pela metade — copie pela SM37.

> **Dois tetos que não têm como furar:** ações de disparo (Iniciar / Liberar /
> Reagendar) têm teto **duro de 1.000 jobs por execução**, mesmo em background e
> mesmo com `P_MAX = 0`. Parar job em massa é limpeza; iniciar job em massa é
> carga na máquina. E o job recém-criado entra na tabela de "já tratados" **no
> ato da criação** — sem isso, o lote seguinte leria a própria cópia (mesmo nome,
> mesma máscara) e dispararia de novo, e de novo: exatamente o laço que gerou o
> incidente da ZSDR1119.

Duplo clique na linha abre a SM37.

> **Cancelar ≠ Deletar.** Job planejado ou liberado não se "cancela": deleta-se —
> e o delete já remove o agendamento, **inclusive de job periódico**. Se você
> mandar "Cancelar" num job não ativo, ele entra no log como *ignorado*, com o
> motivo, em vez de dar a falsa impressão de que funcionou.

---

## 3. Travas de segurança (todas ligadas por padrão)

| Trava | Padrão | O que faz |
|---|---|---|
| `P_TEST` | **marcado** | Simulação. Nada é cancelado/deletado; o log mostra o que *seria* feito. |
| `P_PROT` | marcado | Protege jobs padrão do SAP: prefixos `SAP_`, `RDD`, `EU_`, `/SDF/`, `DBA:`, `SLCA`, `RSPO`, `RSCOL`, `COLLECTOR`, `LOAD_GENERATOR`, `SWW`, `BPM`, `SM:`, `CCMS` e jobs de `DDIC`/`SAPSYS`/`TMSADM`/`SAP*`. |
| `P_PROAT` | marcado | Não mexe em jobs **ativos** (status R). |
| `P_MAX` | 5.000 | Teto de jobs por execução. `0` = **sem teto**, e sem teto só existe em background — no ALV online vale um teto implícito de 2.000 por clique, para a sessão não cair por timeout no meio da limpeza. |
| `P_PACK` | 500 | `COMMIT WORK` a cada N jobs (evita LUW gigante). |
| `S_EXCL` | vazio | Nomes de job a preservar, informados na tela. |
| — | sempre | O **próprio job** em que o programa roda nunca é deletado (`GET_JOB_RUNTIME_INFO`). |
| — | sempre | Popup de confirmação antes de qualquer ação, com o botão "Voltar" pré-selecionado. |

Autorização: as FMs usadas são as mesmas da SM37, então `S_BTCH_ADM` / `S_BTCH_JOB`
continuam valendo — sem autorização o job entra no log como erro, e nada é apagado.

---

## 4. Receita para o incidente da ZSDR1119 (os ~658 mil jobs)

> **Atalho:** marque `P_INC` (ou digite `ZSDR1119*` no nome) e use o botão
> **"Cancelar + Deletar TUDO com esse nome"** da seção 1 — ele já ignora os
> filtros que atrapalham e manda para background sozinho quando o volume é
> grande. O roteiro abaixo é a versão passo a passo, para conferir antes.

1. **Marque `P_INC`** (bloco *Preset do incidente ZSDR1119*). Ele força a máscara
   `ZSDR1119*` — que cobre as duas famílias criadas pelo loop
   (`ZSDR1119_BSF_M_*` e `ZSDR1119_ALV_M_*`) — e **ignora** o que estiver em
   `S_JOBNAM`, então não tem como pegar job de terceiro por engano. Ela pega
   também os jobs legítimos do report (`ZSDR1119_BSF_DIARIO`): se quiser
   preservá-los, informe o nome em `S_EXCL`.
2. Deixe `P_FUTUR` marcado e os status **Planejado / Liberado / Pronto** marcados.
   **Não marque `P_PERIO`**: job planejado que nunca foi liberado não é periódico,
   e esse filtro zeraria a seleção.
3. Clique em **"Contar jobs da seleção"** e confira o número — tem que bater com o
   que a SM37 mostra.
4. Rode uma vez **com `P_TEST` marcado** (online mesmo) e olhe o ALV: confira nome,
   periodicidade e a coluna *Motivo da proteção*.
5. **Desmarque `P_TEST`**, ponha `P_MAX = 0` (sem teto), ação = **Deletar**, e
   clique em **"Executar em background"**.
6. Acompanhe pelo botão **"Situação do job de limpeza"** ou pela SM37. Ao terminar,
   o spool do job traz o resumo (tratados / OK / ignorados / erros) e o detalhe.

**Paralelizar (opcional, para ir mais rápido):** agende 3–4 jobs de limpeza com
nomes diferentes (`P_JNAME` = `ZJOBS_LIMPEZA_1`, `_2`, …) e faixas de data
distintas em `S_SDLDAT` (ex.: um por trimestre). Como cada job trata uma faixa
diferente, eles não brigam pelo mesmo registro. Não vale a pena passar de ~4
jobs simultâneos: o gargalo vira o enqueue da BTC.

**Depois da limpeza:** só reagende a extração da ZSDR1119 **após** transportar a
correção (ano/mês como `NUMC` + data por offset, `sscrfields-ucomm` limpo e
bloqueio por `sy-batch`) — senão o loop recria tudo.

---

## 5. Instalação

1. **SE38** → criar o programa executável (tipo 1 - programa executável), colar o
   fonte de [ZJOBS.abap](ZJOBS.abap) e ativar. **O nome do programa pode ser
   qualquer um** (`ZJOB`, `ZJOBS`, `ZBCJOBS`…): o reagendamento em background usa
   `SUBMIT (sy-repid)`, então ele se reagenda com o nome que tiver de fato.
   Só o `REPORT` da primeira linha precisa bater com o nome escolhido.
2. **SE38 → Ir para → Textos de seleção** → informar os textos da tabela abaixo
   (os títulos dos blocos e dos botões já vêm por código, na `INITIALIZATION`).
3. **SE93** → criar a transação `ZJOBS`, tipo *Transação de report*, programa
   `ZJOBS`, com "Sinalizador SAPGUI para HTML/Windows/Java" marcado.
4. Restringir a transação a Basis/TI no perfil — o programa apaga jobs.

### Textos de seleção (SE38 → Textos de seleção)

Na ordem em que a SE38 lista (ordem de declaração no programa). Título do
programa: **Monitor e controle de jobs de background**. Os títulos dos blocos e
os textos dos botões vêm por código, na `INITIALIZATION` — não precisa cadastrar.

| # | Campo | Texto |
|---|---|---|
| 1 | `S_JOBNAM` | Nome do job (aceita *) |
| 2 | `S_CRIAD` | Usuário que agendou |
| 3 | `S_PROG` | Programa do step |
| 4 | `S_SDLDAT` | Data prevista de início |
| 5 | `S_SDLTIM` | Hora prevista de início |
| 6 | `P_STPLA` | Status Planejado (P) |
| 7 | `P_STLIB` | Status Liberado (S) |
| 8 | `P_STPRO` | Status Pronto (Y) |
| 9 | `P_STATI` | Status Ativo (R) |
| 10 | `P_STCON` | Status Concluído (F) |
| 11 | `P_STCAN` | Status Cancelado (A) |
| 12 | `P_FUTUR` | Só previsto de hoje p/ frente |
| 13 | `P_PERIO` | Só jobs periódicos |
| 14 | `P_STEP` | Ler programa/variante do step |
| 15 | `P_MAXLIN` | Máximo de linhas no ALV |
| 16 | `P_INC` | Preset incidente ZSDR1119 |
| 17 | `P_TEST` | Simulação (não executa) |
| 18 | `P_PROT` | Proteger jobs padrão do SAP |
| 19 | `P_PROAT` | Não mexer em jobs ativos |
| 20 | `P_MAX` | Teto por execução (0=sem teto) |
| 21 | `P_PACK` | COMMIT a cada N jobs |
| 22 | `S_EXCL` | Nomes de job a preservar |
| 23 | `P_RIMED` | Iniciar/liberar imediatamente |
| 24 | `P_RDATE` | Data alvo (liberar/reagendar) |
| 25 | `P_RTIME` | Hora alvo (liberar/reagendar) |
| 26 | `P_RDEL` | Reagendar: deletar o original |
| 27 | `P_ACAN` | Ação: Cancelar |
| 28 | `P_ADEL` | Ação: Deletar |
| 29 | `P_ACDE` | Ação: Cancelar + Deletar |
| 30 | `P_ASTR` | Ação: Iniciar agora |
| 31 | `P_AREL` | Ação: Liberar |
| 32 | `P_ARSC` | Ação: Reagendar |
| 33 | `P_JNAME` | Nome do job de limpeza |
| 34 | `P_JDATE` | Data de início do job |
| 35 | `P_JTIME` | Hora de início do job |

`P_BATCH` é `NO-DISPLAY` — aparece na lista, mas pode ficar em branco.

---

### Se a seleção vier vazia

Job **planejado** (status P na TBTCO, "escalonado" na SM37) criado e nunca
liberado fica com `SDLDATE = 00000000` — **não tem data prevista nenhuma**. Por
isso `P_FUTUR` não é `sdldate >= hoje` puro: o range é *de hoje em diante* **ou**
*sem data*, senão o filtro descartaria justamente os jobs de um agendamento que
deu errado, que é o caso mais comum de uso desta transação.

Quando mesmo assim não vier nada, o popup traz o **diagnóstico**: a contagem é
refeita acrescentando um filtro por vez —

`Pela máscara: 12 | + status marcados: 12 | + só futuro: 12 | + só periódicos: 0`

— e você vê em que degrau virou zero, em vez de só "nenhum job encontrado".

---

## 6. Detalhes de implementação

- **ALV sem status GUI:** `CL_SALV_TABLE` + `get_functions( )->add_function( )`
  coloca os botões próprios na barra padrão, e
  `set_selection_mode( row_column )` dá a coluna de marcação. Por isso não é
  preciso status na SE41 nem tela na SE51.
- **Leitura em lotes (modo direto):** a cada volta o mesmo `SELECT ... UP TO 5000
  ROWS ... ORDER BY PRIMARY KEY` é refeito. Como os jobs deletados somem da leitura
  seguinte, a fila "anda" sozinha. O que falha ou está protegido fica numa tabela
  hashed (`GT_FEITO`) para não ser reprocessado; quando um lote inteiro só traz
  jobs já tentados, o laço encerra e o log informa quantos restaram.
- **Simulação em background** não deleta nada, logo o `SELECT` não anda: nesse caso
  o programa lê uma única vez até 20.000 linhas de detalhe e reporta o total real
  pelo `COUNT(*)`.
- **Log:** erros sempre entram; sucessos até 5.000 linhas (numa limpeza de 600 mil
  jobs, guardar tudo em memória não ajuda). Os contadores continuam somando.
- **Periodicidade** (`PRDMINS`…`PRDMONTHS`) vem no mesmo `SELECT` da TBTCO e é
  traduzida em memória — nada de um `SELECT SINGLE` por linha.
- **Lição da ZSDR1119 aplicada aqui:** `AT SELECTION-SCREEN` também roda em
  background e o código de função sobrevive ao roundtrip da tela. Por isso os
  botões são lidos de `SSCRFIELDS-UCOMM`, com `CLEAR` ao final, e o agendamento é
  bloqueado quando `SY-BATCH`/`P_BATCH` não está vazio.

---

## 7. Pendências

- [ ] Criar e ativar o programa na SE38 (DEV) + textos de seleção
- [ ] Criar a transação na SE93 e restringir autorização
- [ ] Teste em QAS: simulação → limpeza pequena com teto → limpeza em background
- [ ] Executar a limpeza dos jobs `ZSDR1119_BSF*` em PRD
- [ ] Só então transportar/reagendar a extração corrigida da ZSDR1119
