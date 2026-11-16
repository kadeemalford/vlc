# Arquivos e mudanças planejadas

**Atualização:** o mapa abaixo continua sendo o plano para alterar os fontes
originais. A implementação inicial foi feita como entrypoint separado de pesquisa,
sem aplicar esses diffs; ver [LIVE_INTEGRATION.md](LIVE_INTEGRATION.md).

Os paths abaixo são relativos a `medical_telemetry_system/`. As cópias estão em
`reference/<path>.reference`, sem modificações. Linhas citadas correspondem à
revisão de 16/11/2026; conferir `source_manifest.json` antes de implementar.

## Alvos diretos no MATLAB

### 1. `vlc-system-matlab/src/scripts/alarm-care-pro/real_time_mae_vlc.m`

É o ponto principal, não a versão simplificada da pasta irmã.

- `maeStart` (89+): introduzir opção explícita `opts.neural` (desabilitada por
  padrão), identidade de modelo, sinal HR/PR, política de entrega e log. Carregar
  e validar o codec **uma vez**, antes de abrir instrumentos/servidores. Não
  alterar amplitude ou reabrir VISA de forma implícita no modo de pesquisa.
- `ensureServers`, callbacks e `processHl7` (412+, 534+): no modo neural abrir
  somente monitor/2222, usar enquadramento MLLP completo, selecionar HR **ou** PR
  explicitamente. O buffer oportunista atual pode consumir mensagens incompletas.
  Adaptar a lógica validada de `codificacao_neural/monitor_capture.py`, sem executar
  esse listener e o servidor MATLAB simultaneamente. Proibir comandos de retorno.
- `fifoPush` (626+): hoje descarta chunks antigos acima de seis, sem métricas.
  Contar recebidos, enfileirados, descartados e entregues. Não confundir descarte
  de fila com BER. Definir fila por mensagem lógica, sem misturar fragmentos.
- `maeTick`/`transmitAndShow` (185+, 681+): inserir encoder/framing NC1 antes de
  `vlcSystem.communicate`; transmitir todos os fragmentos, decodificar exclusivamente
  RX, verificar CRC/modelo e reconstruir antes de `show(frameRx)`. No começo,
  preferir um frame de 10 bytes (392 bits) por transação, sem batching de seis.
- Não aplicar `stringToBits` (731+) aos pacotes binários NC1: ela acrescenta um
  header ASCII de comprimento incompatível. Não passar NC1 a `bitsToString` (748+).
  Manter ambas apenas no modo legado.
- Hoje um frame divergente de TX ainda passa a `show` (725–728). No modo neural,
  falha de validação deve ser bloqueante; igualdade TX é **métrica do avaliador**,
  não entrada do decoder ou único mecanismo de validade.
- Separar `syncOk`, `codecOk`, `messageComplete` e `deliveryOk` no resultado do
  tick. Capturar tentativas mesmo quando encoder/framing/sync/CRC falharem; não
  registrar apenas waveforms aceitas. Captura atual não é o contrato auditável dos
  MATs do protótipo: exige adaptação explícita.
- `maeStop`: encerrar somente recursos pertencentes à sessão e salvar logs, sem
  presumir que fechar VISA desliga LED/AFG.

### 2. `vlc-system-matlab/src/main/model/system/system1tx1rx/System1tx1rx.m`

Manter Manchester como PHY, sem equalizador neural. O encoder neural vive acima
desta classe, não no lugar de `signalEncoder`.

- `communicate` (22+): validar orçamento de bits/taxas, expor tentativa(s) e erro
  final. Hoje há até três aquisições para sincronizar; usar uma tentativa inicial
  ou registrar todas. Não ocultar descartes numa BER calculada só na última RX.
- Sincronização assistida TX continua declarada. Uma integração não cria receptor
  independente automaticamente. Não transplantar nomes/valores de score do piloto
  sem portar o sincronizador: a rotina `SignalUtils` desta versão é diferente.
- BER de bits NC1 é distinta de reconstrução da fonte. Ausência de RX alinhado
  deve produzir métrica desconhecida, não zero.
- Verificar erros de amostragem antes de reamostrar; o piloto validou TX/RX iguais.
  Não considerar a reamostragem legada evidência de suporte multitaxa.

### 3. `vlc-system-matlab/src/main/model/system/system1tx1rx/System1tx1rxResponse.m`

Adicionar campos de diagnóstico do PHY: contagem/registro de tentativas, motivos,
taxas consultadas e status medido/desconhecido. Manter `rxBits` como bits NC1 no
modo neural, `txBits` somente para avaliação. Preferir resultado neural separado
no orquestrador para não misturar mensagens lógicas com fragmentos/response PHY.
Campos usados pelos gráficos existentes devem permanecer compatíveis.

### 4. `vlc-system-matlab/src/main/model/logicanalizers/Mdo3012/Mdo3012Analyzer.m`

- A inicialização atual liga AFG e configura amplitude/canais; reconexão também
  pode alterar o setup. Separar conexão passiva de configuração/ativação autorizada.
- Receber sessão já aberta/emprestada é uma opção; adaptar o padrão de
  `ExistingVisaMdo3012Analyzer`, sem carregar duas classes com mesmo nome no path.
- Consultar canal, XINcr, registro, modo e estado AFG, registrar o setup. Não
  inferir 10 MS/s de variável interna se a leitura falhar.
- Upload continua substituindo waveform/período; confirmar operação presencialmente.
  Não ligar saídas como efeito colateral de carregar modelo ou iniciar UI.

## UIs MATLAB — alterar somente a que for realmente usada

### 5–6. `vlc-system-matlab/src/main/view/alarm-care-pro/TestEopSystemViewMae.m`
### e `.../TestEopSystemViewMaeNew.m`

- Ambas chamam `real_time_mae_vlc('start'/'tick'/'stop')`; identificar no PC qual
  app/`.mlapp` é o entrypoint. Não copiar uma alteração de forma cega entre versões.
- `startMaeServices`: passar opções neurais e referência do modelo, sem retreinar,
  reinicializar instrumento ou ativar transmissão automaticamente.
- `onMaeTick`: exibir falha de CRC/modelo/reassembly separadamente de sync.
  Corrigir apresentação de BER desconhecida como zero (na UI antiga há esse
  fallback), identificar bits codificados vs fonte e distinguir Q/BER estimada.
- Plotar o PHY real; “sync aceito” não significa que mensagem foi entregue ao painel.
  Diagnóstico deve informar entrega/latência/expansão sem alegação de sigilo.
- Se `.mlapp` for a fonte operacional, avaliar a ferramenta
  `sync_mlapp_from_m.m` numa cópia, sem sobrescrever app de trabalho não revisado.

## Referências contratuais — não modificar no caminho mínimo

### `.../src/scripts/alarm-care-pro/mae_frontend.m`

Já transforma `PR` em `Puls Oxim Puls Rate`, `HR` em `Ecg Heart Rate`, usando
`mae_registry`, e envia NDJSON a 4455. Chamar só após validação e reconstrução.
Manter arrays JSON `variables`/`alarms`; não passar latentes. Desregistrar handler
de comandos no modo de pesquisa em quem o configura (`maeStart`).

### `.../src/scripts/alarm-care-pro/mae_frame.m` e `mae_registry.m`

Manter contrato `!#MDPRnnnn`/`!#MDHRnnnn`, nomes e escalas para o painel. Não
alterar suas tabelas para inserir latentes. O legado pode arredondar valores;
selecionar só inteiros representáveis neste estudo e registrar recusas.

### `.../src/scripts/alarm-care-pro/mae_handlers.m`

Referência dos campos HR/PR e parsers. Não precisa conhecer rede neural. A seleção
de sinal, framing completo e rejeição de sentinelas devem ocorrer no adaptador de
entrada, sem presumir que o parser legado sozinho valida qualidade do sensor.

### `.../src/main/model/utils/SignalUtils.m`

A sincronização atual usa xcorr e energia global, sem o limiar Pearson por janela
do piloto. Auditar e escolher explicitamente: portar a rotina validada como helper
isolado ou adicionar método opt-in; não sobrescrever globalmente o método usado
pelos outros testes do legado. Modelo conhecido não substitui qualidade de sync.

### `alarm-care-pro-backend/src/gateway_server.ts`

Processo correto para o caminho MATLAB → painel. Não recebe diretamente os
equipamentos, ao contrário de outros entrypoints. Sem mudança obrigatória do
codec. Inicializar só no portão de integração, em ambiente de pesquisa.

### `alarm-care-pro-backend/src/services/TcpGateway.ts` e `SocketServer.ts`

Recebem NDJSON e emitem `monitor_message`. Manter contrato e testar com payload
reconstruído. Há caminho de comandos a bombas: manter desativado no MATLAB e
demais equipamentos desligados. Não confundir canal de retorno TCP com VLC.
Diagnóstico neural pelo WebSocket só em extensão contratual separada.

### `alarm-care-pro-frontend/src/pages/Home.tsx` e `utils/monitorVariables.ts`

Já há campos distintos HR/PR e detecção de inatividade baseada em chegada de
mensagens (~5 s, ver intervalo configurado). Conferir que perda neural não
renova timestamp nem mantém valor como leitura nova. Sem mudança funcional mínima
se o contrato for preservado. Não usar replay atrasado como indicador de frescor.
O timeout é do monitor como um todo, não por variável: numa sessão somente PR,
começar com estado limpo e conferir que cards fora do escopo não exibem valores
antigos como atuais. Se isso não for garantido pelo modo de teste, será necessária
uma alteração de apresentação/validade no frontend antes da demonstração final.

### `alarm-care-pro-frontend/src/contexts/AlarmsContext.tsx`

Pode emitir comandos de silenciar/refresh mesmo sem intenção de usá-los. É
referência de risco de inicialização, não convite a alterar todo o frontend:
desativar rota de comandos no modo de pesquisa, verificar que nada é enviado aos
equipamentos e manter bombas/ventilador fora do ensaio.

### `alarm-care-pro-api/`

API de usuários/auth (porta 3333 no README); nenhum arquivo é alvo do codec.
Não foram copiados `.env`, credenciais ou bancos. Login não cria confidencialidade
no enlace nem autenticação do frame NC1.

## Novos módulos a implementar depois dos testes isolados

Preferir helpers com nomes próprios, por exemplo `NeuralTelemetryCodec.m`,
`NeuralPacketProtocol.m`, `MonitorMllpBuffer.m` e `NeuralDeliveryLog.m`. São
**especificações, ainda não arquivos implementados** neste pacote.

- Codec carregado uma vez: byte → 16 bits e inverso, quantização idêntica ao Python.
  Exportar pesos congelados para MATLAB ou usar bridge Python persistente; decidir
  após comparar conformidade/latência/versão suportada. Não iniciar Python por frame.
- Protocolo NC1 exatamente compatível com `codificacao_neural/packets.py`, sem
  inventar header extra; validar CRC/modelo/limites/ordem/completude.
- Buffer MLLP bounded para fragmentação/coalescência, sem salvar PID/HL7 bruto;
  seleção de PR/HR e política de ACK explícitas.
- Log com tentativas, IDs, hashes, falhas, descarte de fila e tempos por etapa;
  nenhuma mensagem original usada para “corrigir” RX ou substituir falhas.
