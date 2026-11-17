# Continuidade — codificação neural de telemetria

## Retomada — 17/11/2026

### Estado mais recente

- Primeiro ensaio ampliado: usuário confirmou HR/FC, SpO₂ e PR corretas no painel,
  mas não pressão, apesar de valor visível no aparelho. Resumo SYS:
  absent_messages=178, source_rejected=1,
  rejected_incomplete_or_duplicate_pressure_pair=1; DIA: absent_messages=177
  e mesmas duas rejeições. Não há evidência de um par aceito/transportado.
- Ainda não distinguir ausência na transmissão, identidade não reconhecida,
  duplicidade ou separação em envelopes. Mantida a regra de pareamento.
  Adicionado `--signal pressure_inspect` ao coletor: diagnóstico estrutural sem
  valores, PID, timestamp bruto ou HL7 persistido; não usa VLC/gateway, não gera
  frames nem envia comandos/ACK. Requer `monitor_signals.py` atualizado.
  Próxima ação: encerrar ponte/AFG OFF e observar estrutura de pressão na porta2222
  em uma pasta nova, preservando a tentativa multivariável.

- Após corrigir ausência de PR, usuário reportou 58 mensagens, 29 PRs aceitas,
  29 sem PR ignoradas, 29 tentativas/codec_ok/escritas gateway. Na tentativa 29,
  zero erros/392 bits, source_exact_match=1, idade 0,3647 s.
- Em nova rodada visual, usuário confirmou painel seguindo PR do aparelho,
  inatividade após parada e AFG OFF: demonstração online fim a fim PR-only
  relatada, artefatos ainda não auditados localmente.
- Usuário ampliou escopo para HR/FC do ECG, SpO₂ e PR, acrescentando pressão
  arterial. Implementados `monitor_signals.py`, fila round-robin/idade/validade
  por sinal e pareamento SYS/DIA: mesmo envelope e OBX-14 compatível, dois pacotes
  NC1 de 392 bits, publicação conjunta só após ambas as RXs válidas.
- Nenhum novo modelo: mesmo checkpoint e PHY. Parser antigo `parse_rates`/CLI
  HR/PR mantidos como wrapper compatível. Backend/frontend/API não alterados.
- A pedido do usuário, `run_neural_monitor` agora tem AFG contínuo como padrão:
  primeiro upload OFF, ON uma vez, uploads seguintes ON, desligamento ao terminar
  ou em erro fatal. `opts.afgMode='per_capture'` preserva o modo anterior.
  Novo `NeuralAfgController.m`, quatro testes MATLAB sem instrumentos escritos.
- 58 testes Python aprovados. Testes MATLAB novos não executados aqui; validação
  física multivariável/pressão/AFG contínuo pendente. Procedimento e arquivos para
  transferir em `neural_codification_changes/MONITOR_VARIABLES.md`.
- Próximo passo vigente: transferir fontes/testes novos, executar testes Python
  e MATLAB sem instrumentos, só depois nova sessão de ponte/token/saída e ensaio.
  Pressão no frontend é sticky (último par, não leitura continuamente atualizada);
  timestamps globais do monitor não indicam idade individual da pressão.

### Diagnóstico inicial desta retomada

- Usuário restaurou dados de `bench_20261116_152201.mat`, abriu VISA nova e
  reconferiu setup; horizontal/CH1/banda/amplitude tinham mudado. Ajustes aplicados
  com AFG OFF e preâmbulo atualizado após trigger forçado: 10 MS/s/10k conferidos.
- Sistema completo copiado ao PC da bancada; gateway 4455/4444 e painel 5173
  iniciados, conexão de frontend ao gateway confirmada. Handshake IPC externo
  já havia passado na campanha anterior, conforme usuário.
- Primeira tentativa foi iniciada sem LED/sensor preparados; orientada preservação,
  parada/AFG OFF e nova saída/token para repetição.
- Repetição reportada: 58 mensagens, 29 aceitas/29 rejeitadas, 28 descartes de fila,
  uma tentativa física. `codec_ok=1`, `source_exact_match=1`, zero erros/392 bits,
  idade 0,6472 s; gateway bloqueado por `source_invalidated_during_phy`.
  Não houve entrega confirmada ao gateway/painel; artefatos não auditados aqui.
- Encontrado bug: ausência de PR em uma mensagem era tratada como PR inválida e
  cancelava fila/in-flight. Corrigido para ignorar/contar `messages_without_pr`,
  sem renovar idade. PR explicitamente inválida/ambígua continua bloqueante.
  Novos contadores `pr_rejected_<motivo>` e `source_invalid_reason` permitem
  distinguir as causas; os contadores antigos não provam a origem das rejeições.
- Próximo passo: transferir `live_bridge.py` atualizado, encerrar processo anterior,
  AFG OFF, reiniciar ponte com novo token/saída e observar diagnósticos e painel.

## Decisão em 09/11/2026

Usuário/orientador suspenderam equalização como foco e escolheram demonstração
simples de encoder/decoder neural no enlace VLC com retorno dos aparelhos médicos
como fonte. Sem requisito inicial de compressão, vantagem sobre clássicos ou ensaio
de interceptação. Proposta 6 no documento principal, mantendo proposta 1 original
e demais linhas como histórico. Não foi autorizada exclusão de artefatos antigos.

O termo “criptografia” é motivação/extensão, não conclusão: falta chave/modelo de
ameaça/avaliação de segurança. Bypass do decoder mede representação, não sigilo.
Não chamar o protótipo mínimo de código wiretap ou autoencoder de camada física.

## Atualização vigente — 16/11/2026

### Após retomada presencial e autorização para integrar

- Usuário relatou roundtrip sintético de 19 bytes e replay PR=59 exatos na sessão
  `neural_20261116_141350`; nova PR=70 coincidiu com o display e foi registrada em
  `data/monitor_pr_20261116_143727/`, fonte SHA-256
  `b3a04d3de1ca3e3a35be83643a0c1a55de1c2a04a8814694e1543b5eeb05b1d3`.
  Pacote ID 1002/392 bits, replay físico também exato conforme usuário.
- Scores dos sintéticos: 0,9179/0,9241; PR antiga 0,9231; PR nova 0,8998.
  AFG OFF confirmado ao final de cada captura; artefatos ainda não auditados aqui.
- Bancada reconferida: 10 MS/s, 10k, CH1 AC/1 MΩ/500 mV/div; banda foi ajustada
  de 100 para 20 MHz; AFG Arbitrary/Hi-Z/1 Vpp/offset zero.
- Classe antiga de `matosgabriel` estava em memória apesar do `which` correto;
  usuário removeu path/adaptador e descarregou classes pontuais preservando VISA.
- Usuário pediu iniciar integração sem prolongar a série isolada. Implementados
  `live_bridge.py` e entrypoint `neural_codification_changes/matlab/run_neural_monitor.m`:
  PR-only, Python persistente, PHY do protótipo, NC1/CRC, latest-only/idade, NDJSON
  para gateway local. Não altera nem inicia UI/orquestrador legado.
- 26 testes Python codec/coletor/bridge aprovados (11 novos). Sockets sintéticos
  em loopback; não equivalem a MATLAB, gateway Node/React ou integração física.
  Procedimento em `neural_codification_changes/LIVE_INTEGRATION.md`.
- Próximo passo vigente: transferir fontes novos ao PC e conferir `version`/`pyenv`;
  validar conversões MATLAB↔Python antes da ativação manual de gateway e transmissão.
- Compatibilidade recebida: MATLAB R2021a e venv Python 3.13.0/PyTorch 2.15.0+cpu.
  API `pyenv` não suporta essa combinação. Adaptados runner e ponte para IPC JSON
  loopback com processo externo persistente (`live_bridge_server.py` +
  `NeuralBridgeClient.m`), mantendo venv/modelo. Próxima ação: transferir arquivos
  e executar somente handshake IPC, AFG OFF, sem monitor/gateway/VISA no teste.

### Preparação anterior da integração (histórico desta data)

- Objetivo final: integrar encoder/decoder ao sistema completo em
  `medical_telemetry_system/`, preservando NDJSON/gateway/painel. A primeira fonte
  continua sendo somente uma taxa HR/PR do monitor. Não ativar controle médico.
- Criada área de preparação `medical_telemetry_system/neural_codification_changes/`:
  17 snapshots de fontes com hashes, mapa por arquivo, contrato e validação.
  Fontes ativos não alterados; não é integração pronta para instalar.
- Descobertas: versão completa tem `start/tick/stop`, UIs MATLAB, batching, fila
  limitada, retries e sync diferente do piloto. Precisam de auditoria/adaptação.
  Não adicionar paths das duas versões ao mesmo tempo: classes/funções homônimas.
- Snapshots conferidos contra os fontes originais: 17/17. Testes offline nesta
  atualização: 5 do pacote + 15 do codec/coletor + 47/6 dos equalizadores aprovados.
  Nenhum app/gateway/UI, equipamento médico ou instrumento iniciado nesta etapa.
- Usuário relatou validação ao vivo do coletor MLLP: 118 mensagens em 60 s,
  59 observações HR e 59 PR, sem erros de framing ou rejeição sintática.
- Capturou PR=59 bpm, coincidente com o display, em
  `data/monitor_pulse_01/monitor_000001.bin` (`!#MDPR0059`, 10 bytes).
  Fonte SHA-256 `047a8d376f2497bd24b7379559a6c774ed330d669cb727859ff47c8631729155`.
- Modelo Windows congelado SHA-256
  `f83712964339612bbc4011590062fd05445e1cd9d0380e1e09ee00ed9c7ff0bf`,
  diferente do arquivo de modelo Linux do demo. Não substituir/retreinar.
- Pacote real message_id=1001, 392 bits; captura
  `data/physical/neural_20261110_161357/neural_20261110_161357_monitor_pr_1001.mat`,
  sync Pearson 0,9170. Usuário confirmou reconstrução física completa, 10 bytes
  idênticos, zero erros de bytes observados, em `runs/physical_monitor_pr_1001/`.
  Artefatos ainda não recebidos/auditados localmente. Não inferir BER dos bits,
  generalização, sigilo ou integração online deste único resultado.
- Sugerido backup e `checkpoint_real_monitor.mat`, não confirmados por inspeção
  de arquivos. Na retomada, verificar presença/modelo/sessão sem presumir backup.
- Próxima etapa: conferir setup do osciloscópio com AFG OFF, repetir referência
  sintética e depois ampliar teste isolado de PR. Integração fica posterior aos
  portões definidos no pacote de revisão.

## Atualização — 10/11/2026 (histórico anterior ao teste real)

- Usuário restringiu a fonte ao monitor de frequência cardíaca/pulso de pesquisa;
  demais equipamentos, variáveis e alarmes estão fora da proposta ativa.
- Sensor de dedo pode fornecer PR de oximetria; HR de ECG é outra observação.
  Não renomear ou substituir uma pela outra. Conferir o campo realmente disponível.
- Usuário relatou 7 testes Python e 3 testes MATLAB aprovados no Windows, demo
  ideal exato e dois roundtrips físicos da mesma mensagem sintética de 19 bytes:
  `neural_20261109_121857` e `neural_20261110_161357`.
- Scores relatados de sincronização: 0,9183/0,8942 no primeiro dia e
  0,8977/0,8946 no segundo. Decoder físico: ambos completos, 2 fragmentos aceitos,
  igualdade exata e zero erros de bytes observados, segundo saídas confirmadas
  pelo usuário. Bypass físico no segundo dia: 38 bytes latentes, 38 diferenças.
  **Artefatos ainda não conferidos localmente**; BER dos bits não calculada aqui.
- Implementado `monitor_capture.py`: listener MLLP/TCP isolado, sem VISA/gateway,
  sem escritas de aplicação/ACK HL7, sem HL7 bruto/PID persistidos. Primeiro
  `--signal inspect`, depois selecionar explicitamente `pulse_rate` ou `heart_rate`.
- **15 testes Python aprovados** após a inclusão de 8 testes do coletor.
  Smoke TCP local (127.0.0.1) com envelope sintético fragmentado: um frame PR
  exato, zero bytes de aplicação retornados e manifesto `finished`.
- Compatibilidade offline com o PCAP histórico do monitor: 996 envelopes MLLP
  completos; para cada uma de HR/PR, 272 observações numéricas elegíveis e 226
  ausentes/fora da representação. Fonte original preservada, sem logs de valores/IDs.
  Ver `reports/monitor_receiver_20261110.md`.
- **Monitor ao vivo ainda não testado com este coletor.** Próxima ação: atualizar
  PC, confirmar IP de destino/porta 2222 e inspecionar o sinal com AFG OFF.

## Estado inicial em 09/11/2026 — histórico

- MLP de byte para 16 bits binários e decoder para byte. Expansão intencional;
  sem aprendizado do canal e sem correção de erros garantida.
- Treino sobre todos os 256 bytes. Seeds 42/43/44: 100 passos, zero erros no
  alfabeto e 256 codewords distintos. Isso é conformidade, não teste clínico independente.
- Serialização real, framing público NC1, fragmentos de até 16 bytes, CRCs,
  identificação de modelo/mensagem, rejeição de incompletos/duplicados/corrompidos.
- Loopback ideal e decoder offline de capturas físicas assistidas. O segundo
  foi testado SOMENTE com waveforms sintéticas; não há transmissão física nova.
- Bypass gera latentes, explicitamente sem interpretar isso como prova de segurança.
- **7 testes Python aprovados**, incluindo seeds, alfabeto, roundtrip fragmentado,
  bypass, corrupção, rejeições e garantia de não usar TX no modo físico.
- Regressões anteriores reexecutadas: 47 + 6 testes aprovados. Demo CLI completo
  persistido: 19 bytes sintéticos reconstruídos exatamente em loopback ideal,
  768 bits com framing (expansão 5,0526×). Ver `reports/offline_demo_20261109.md`.
- Helpers MATLAB de exportação de frame compacto e replay de pacote, com reutilização
  das fontes anteriores sem editá-las. **Não executados no MATLAB nesta etapa.**

Comando verificado a partir desta pasta:

```bash
../equalizador_neural/.venv/bin/python -m unittest discover -s tests -v
```

## Próxima ação

1. Conferir fonte/modelo/capturas/backups e sessão VISA existente antes de reabrir.
2. Conferir setup atual com AFG OFF; registrar divergências em vez de pressupor
   os 100 ns, 10k e 500 mV/div históricos.
3. Repetir referência sintética em ID de sessão novo. Depois ampliar piloto de
   PR/HR de origem real, preservando toda tentativa e a distinção replay/online.
4. Receber e auditar MATs/manifests/modelo/resultados; calcular BER dos bits e
   contagens de entrega, não apenas igualdade entre fontes reconstruídas aceitas.
5. Seguir os portões do pacote de integração: adaptador offline, contrato com
   gateway/painel em teste, depois monitor → VLC → painel online. Nada aplicado ainda.

## Pendências explícitas

- Coletor TCP e replay de leitura real validados ao vivo segundo usuário; falta
  auditoria local dos artefatos e integração monitor → codec → VLC → painel online.
  Autenticação, FEC/retransmissão, preâmbulo público/receptor
  sem TX, UI e métricas agregadas de campanha não prontos.
- Nenhum ganho de compressão/superioridade ou segurança demonstrados.
- Roundtrips físicos sintéticos e um PR real relatados pelo usuário, ainda sem
  auditoria local dos arquivos; não confundir relato operacional com campanha auditada.
- Latentes binários não são ciphertext criptograficamente seguro.
- CRC/fingerprint não provam autenticidade. Bit erros podem causar perda do quadro inteiro.
- Fidelidade é contra a mensagem compacta; lacunas/arredondamentos do parser permanecem.
- `data/`, `runs/`, `.venv/`, configs locais e dados médicos exigem backup separado;
  dados sensíveis não devem ser versionados.
