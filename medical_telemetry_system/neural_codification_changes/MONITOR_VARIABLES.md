# Monitor: HR/FC, SpO₂, PR e pressão arterial — 17/11/2026

Extensão implementada em software; **ensaio físico multivariável e modo AFG
contínuo ainda pendentes**. A demonstração PR-only anterior foi confirmada pelo
usuário no painel, inclusive inatividade após parada e AFG OFF. Artefatos ainda
não auditados aqui. O artigo-base inclui outros equipamentos; continuam excluídos
ventilador, bombas, alarmes, temperatura, respiração e pressão média.

## Campos selecionados

| `opts.signals` | OBX-3 / OBX-4 | Frame sintético | Painel / unidade |
|---|---|---|---|
| `heart_rate` | `147842^MDC_ECG_HEART_RATE` / `1.7.4.147842` | `!#MDHR0073` | `Ecg Heart Rate` / `1/min` |
| `oxygen_saturation` | `150456^MDC_PULS_OXIM_SAT_O2` / `1.3.1.150456` | `!#MDSP0097` | `Puls Oxim Sat O2` / `%` |
| `pulse_rate` | `149530^MDC_PULS_OXIM_PULS_RATE` / `1.3.1.149530` | `!#MDPR0074` | `Puls Oxim Puls Rate` / `1/min` |
| `systolic_pressure` | `150301^MDC_PRESS_CUFF_SYS` / `1.1.9.150301` | `!#MDBS0120` | `Systolic Pressure` / `mmHg` |
| `diastolic_pressure` | `150302^MDC_PRESS_CUFF_DIA` / `1.1.9.150302` | `!#MDBD0080` | `Diastolic Pressure` / `mmHg` |

Exigem-se NM, status F/C, sub-ID e unidade exatos: `MDC_DIM_BEAT_PER_MIN`,
`MDC_DIM_PERCENT` ou `MDC_DIM_MMHG`. Valores inteiros 1–9999, exceto SpO₂ 1–100.
Zero/missing/sentinelas são recusados neste modo, sem arredondamento; essas regras
não validam fisiologia, contato ou qualidade do sensor. HR/FC do ECG nunca é
preenchida com PR do dedo. Confirmar o campo e a origem no aparelho.

## Transporte e pareamento da pressão

- Modelo congelado/NC1/Manchester/10 MS/s/10k permanecem iguais, sem retreino.
- Cada campo de 10 bytes ocupa **392 bits** antes de Manchester; nenhum upload
  excede esse tamanho. As três variáveis HR/SP/PR são mensagens independentes.
- Pressão é uma unidade lógica com dois fragmentos NC1 de 392 bits, mesmo
  `message_id`, índices 0/1 e `total=2`. Os bytes de origem reconstituídos são os
  dois chunks de 10 bytes concatenados, sem separador. SYS e DIA são enviados
  **juntos ao gateway somente depois de ambas as RXs válidas**.
- Ambos os campos devem estar no mesmo envelope HL7, únicos e elegíveis. OBX-14
  deve coincidir quando informado; uma metade com timestamp e outra sem é recusada.
  Os timestamps são comparados transitoriamente e não persistidos.
  Se o firmware emitir metades separadas, este modo as recusa e contabiliza
  `incomplete_or_duplicate_pressure_pair`: não adivinhar o pareamento.
- Nova medição não substitui metade da pressão em voo. Falha, perda, expiração
  ou invalidação de qualquer metade descarta o par. Sem fragmentos de outra medição.
- Um conjunto completo dos cinco campos requer cinco aquisições/1960 bits,
  não uma waveform única de 1960 bits. A pressão requer duas aquisições consecutivas.
- Fila limitada a quatro unidades: última HR, última SpO₂, última PR e último
  par de pressão. Round-robin evita monopolização. Uma unidade lógica em voo.
- Ausência de um campo não invalida nem renova outro. Idade/validade são individuais,
  exceto SYS/DIA tratados em par. Limite padrão de 2 s é da recepção no PC até
  escrita TCP, não da medição do aparelho e não uma garantia clínica.
- A cadência efetiva precisa ser medida. Não assumir os 10 ms do artigo nem uma
  amostra simultânea/atômica dos cinco sinais.

## Painel e métricas

Sem modificar backend/frontend/API:

- Cada envio contém somente números reconstruídos da RX da unidade corrente.
- Para HR/SpO₂/PR, outros campos selecionados desconhecidos/inválidos/expirados
  recebem marcador legado `-?-`. São estado de ausência, não medições codificadas
  ou entregas ópticas de outro sinal; aparecem em `cleared_signals`.
  Nenhum valor numérico em cache é retransmitido como leitura nova.
- Pressão mantém a regra **sticky** do frontend: conserva o último par completo,
  inclusive quando o monitor fica inativo. Isso é última medição, não confirmação
  de pressão atual. A UI original não mostra idade individual da pressão; o
  timestamp global do monitor não deve ser interpretado como horário do manguito.
  Se for necessário rotular idade por variável, será uma alteração futura da UI.
- Quando todos os sinais param, o timeout global existente (~5 s) torna o monitor
  inativo, mas preserva pressão conforme acima. Recarregar a página antes do ensaio
  para limpar cards antigos e estado pendente de pressão.
- `stats.signals` traz contadores por variável; `attempted`/`codec_ok` agregados
  contam pacotes físicos. `gateway_write_ok` agregado conta escritas NDJSON:
  um par de pressão são dois pacotes e uma escrita, com entrega contabilizada
  para ambos os campos no detalhamento.
- `awaiting_pressure_pair` após SYS é esperado: `codec_ok=true`,
  `message_complete=false` e nenhum envio. Depois de DIA válida o par pode sair.
  `gateway_write_ok` não é ACK do painel; conferir visualmente.

## AFG contínuo

`run_neural_monitor` agora usa `opts.afgMode='continuous'` por padrão:

1. Começar com AFG OFF e hardware conferido.
2. Carregar a primeira waveform com saída OFF.
3. Ligar uma vez, na primeira aquisição.
4. Manter ON durante aquisições, espera de dados e uploads subsequentes.
5. Desligar no fim normal, erro fatal ou saída via `onCleanup`.

Sem dados, a saída repete a última waveform; isso **não** gera entregas adicionais
ao painel. Uploads ao EMEM com saída ON podem gerar transientes; este modo elimina
comandos ON/OFF por pacote, não comprova continuidade analógica/glitch-free.
Amplitude e offset não são alterados dinamicamente.

Uma exceção MATLAB no modo contínuo salva a tentativa quando possível e encerra
o ensaio, desligando a saída. Rejeição de CRC/validade retornada normalmente pela
ponte é registrada e não exige interromper. Crash/desconexão USB não são cobertos
por garantia de software: sempre conferir o botão AFG presencialmente.
Para restaurar o comportamento anterior, usar `opts.afgMode='per_capture'`.

## Arquivos a transferir ao PC

Em `codificacao_neural/`:

- `monitor_signals.py` (novo).
- `monitor_capture.py` (parser compartilhado; CLI histórico continua HR/PR).
- `live_bridge.py`.
- `live_bridge_server.py`.
- Testes Python novos/atualizados em `tests/`.

Em `medical_telemetry_system/neural_codification_changes/matlab/`:

- `NeuralBridgeClient.m`.
- `run_neural_monitor.m`.
- `NeuralAfgController.m` (novo).
- `test_afg_controller.m` (novo, testes sem instrumentos).

Não sobrescrever checkpoint do modelo, dados, resultados ou configurações locais.
Não copiar venv Linux para Windows, nem aplicar snapshots `.reference`.
Não misturar `src/main` das duas versões MATLAB.

## Pré-validação e ensaio

Parar runner/ponte anteriores, AFG OFF, transferir arquivos. No **PowerShell**
em `codificacao_neural`:

```powershell
.\.venv\Scripts\python.exe -m unittest discover -s tests -v
```

No **MATLAB**, após adicionar a pasta `neural_codification_changes/matlab`:

```matlab
results = runtests(fullfile(repo, 'medical_telemetry_system', ...
    'neural_codification_changes', 'matlab', 'test_afg_controller.m'));
table(results)
```

Esses testes MATLAB usam um log de comandos em memória, sem VISA ou saídas.
Depois, com gateway/painel como no ensaio anterior e página recarregada, iniciar
a ponte no **PowerShell**:

```powershell
.\.venv\Scripts\python.exe live_bridge_server.py --serve `
  --model runs/codec_seed42/model.pt `
  --model-sha256 f83712964339612bbc4011590062fd05445e1cd9d0380e1e09ee00ed9c7ff0bf
```

No **MATLAB**, com `repo`, paths e sessão VISA já conferidos:

```matlab
opts.signals = {'heart_rate', 'oxygen_saturation', 'pulse_rate', ...
    'systolic_pressure', 'diastolic_pressure'};
opts.afgMode = 'continuous';
opts.confirmation = 'CONFIRM_RESEARCH_MONITOR_VLC_AND_GATEWAY';
opts.controlToken = 'PASTE_THE_NEW_TOKEN';
opts.seconds = 60;
opts.outDir = fullfile(repo, 'codificacao_neural', 'data', 'live', ...
    ['live_monitor_' datestr(now, 'yyyymmdd_HHMMSS')]);
run_neural_monitor(scopeVisa, repo, opts);
```

**O último comando inicia o ensaio físico e mantém o AFG ligado após o primeiro
upload até encerrar.** Operador presente, montagem segura e sinais reais
disponíveis; não provocar variações fisiológicas nem iniciar medições por software.
Nenhum comando de manguito, bomba ou silenciamento é enviado pela ponte.
Se não houver leitura nova de pressão, não inventar nem repetir uma medição
apenas para preencher o card. Conferir o fluxo previsto no procedimento de pesquisa.

Para só as três primeiras variáveis, remover ambas as pressões da lista.
Para PR-only, `opts.signals={'pulse_rate'}`. Sempre nova saída/token/sessão de ponte.

## Evidência de software

58 testes Python aprovados, incluindo regressões PR-only, três sinais, unidades,
round-robin, staleness, CRC, roteamento, pressão parcial/trocada/corrompida/expirada
e timestamps distintos. Quatro testes MATLAB de ciclo AFG foram escritos, mas
**não executados neste ambiente sem MATLAB**. Não equivalem a validação física
das novas variáveis, do EMEM com saída ON ou a garantia clínica/criptográfica.
