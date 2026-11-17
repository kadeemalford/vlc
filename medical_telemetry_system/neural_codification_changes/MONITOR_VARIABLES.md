# Monitor ativo: HR/FC, SpO₂ e PR — 17/11/2026

**Pressão arterial retirada por solicitação do usuário.** É uma medida intermitente
cujo último valor persiste no frontend, não o foco desta demonstração contínua.
O runner MATLAB e a ponte Python agora recusam seleção de pressão. A experiência
anterior está preservada em
[`archive/pressure_experiment_20261117/`](archive/pressure_experiment_20261117/README.md);
capturas/modelos/resultados não foram apagados.

## Escopo e campos

| `opts.signals` | Origem | Frame sintético | Painel / unidade |
|---|---|---|---|
| `heart_rate` | HR/FC do ECG, `147842^MDC_ECG_HEART_RATE`, sub-ID `1.7.4.147842` | `!#MDHR0073` | `Ecg Heart Rate` / `1/min` |
| `oxygen_saturation` | SpO₂, `150456^MDC_PULS_OXIM_SAT_O2`, sub-ID `1.3.1.150456` | `!#MDSP0097` | `Puls Oxim Sat O2` / `%` |
| `pulse_rate` | PR óptica, `149530^MDC_PULS_OXIM_PULS_RATE`, sub-ID `1.3.1.149530` | `!#MDPR0074` | `Puls Oxim Puls Rate` / `1/min` |

Usuário confirmou visualmente os três campos no painel seguindo o monitor.
Os artefatos ainda precisam de auditoria local e agregação para o artigo.
Sem ventilador, bombas, alarmes, pressão ou outras variáveis. Pesquisa, sem
diagnóstico/decisão clínica. Não preencher HR ausente com PR.

## Caminho e validade

- Mesmo modelo congelado, sem retreino; NC1/Manchester a 1 Mbps, 10 MS/s e 10k.
- Um frame de 10 bytes e pacote de **392 bits por observação**, três aquisições
  para transportar os três sinais (1176 bits antes da expansão Manchester).
  Não se trata de uma tripla simultânea/atômica.
- Fila latest-only de uma observação por sinal e seleção round-robin.
  Ausência de um campo não cancela nem renova outro; rejeição/duplicidade e idade
  são individuais. Exige NM, status F/C, sub-ID/unidade exatos e inteiros sem
  arredondar: HR/PR 1–9999, SpO₂ 1–100. Zero/sentinelas são recusados no modo
  experimental; elegibilidade não certifica qualidade do sensor.
- Somente RX com sync, protocolo/modelo/CRC e fonte reconstruída válidos chega ao
  gateway. Sem TX fallback, correção com original, heartbeat ou retry oculto.
- Idade máxima padrão de 2 s vai da recepção no PC à escrita TCP, não da medição
  no aparelho ao render do navegador. Logs não confirmam automaticamente render.
- JSON mantém o contrato legado. Só a RX corrente fornece um número; outros
  campos selecionados desconhecidos/invalidados/expirados recebem `-?-` e são
  identificados em `cleared_signals`, sem contar como entregas daquele sinal.
  Não se reenviam números em cache como leitura nova.
- Ao parar todas as mensagens válidas, o timeout global (~5 s) torna o monitor
  inativo. Recarregar a página para limpar valores antigos, inclusive pressão
  sticky, que não participa deste ensaio.

## AFG contínuo

`opts.afgMode='continuous'` é o padrão: primeiro upload OFF; liga uma vez na
primeira aquisição; mantém ON em espera/aquisições/uploads seguintes; OFF no
fim/erro fatal ou via `onCleanup`. Sem dados, repete a última waveform, mas isso
não gera entregas novas. Atualizar EMEM com saída ON pode gerar transientes;
eliminar ON/OFF por captura não prova continuidade analógica perfeita.
Conferir presencialmente OFF ao terminar/interromper, pois crash/USB não têm
garantia de desligamento. Modo anterior: `opts.afgMode='per_capture'`.

## Atualizar o PC

Transferir os fontes Python atualizados (`live_bridge.py`, `live_bridge_server.py`,
`monitor_signals.py`, `monitor_capture.py`) e os MATLAB (`run_neural_monitor.m`,
`NeuralBridgeClient.m`, `NeuralAfgController.m`), além dos testes atuais.
Não copiar venv Linux, não sobrescrever modelo/dados/resultados nem aplicar
`.reference`. A cópia de teste de pressão foi arquivada fora da descoberta ativa.

Python, no PowerShell em `codificacao_neural`:

```powershell
.\.venv\Scripts\python.exe -m unittest discover -s tests -v
```

Teste AFG no MATLAB, sem instrumentos:

```matlab
results = runtests(fullfile(repo, 'medical_telemetry_system', ...
    'neural_codification_changes', 'matlab', 'test_afg_controller.m'));
table(results)
```

Para a próxima execução, com gateway/painel abertos, AFG inicialmente OFF e
ponte anterior encerrada, iniciar Python como anteriormente. No MATLAB:

```matlab
opts.signals = {'heart_rate', 'oxygen_saturation', 'pulse_rate'};
opts.afgMode = 'continuous';
opts.confirmation = 'CONFIRM_RESEARCH_MONITOR_VLC_AND_GATEWAY';
opts.controlToken = 'PASTE_THE_NEW_TOKEN';
opts.seconds = 300;
opts.outDir = fullfile(repo, 'codificacao_neural', 'data', 'live', ...
    ['live_three_' datestr(now, 'yyyymmdd_HHMMSS')]);
run_neural_monitor(scopeVisa, repo, opts);
```

**O último comando inicia transmissão física e mantém o AFG ligado até encerrar.**
Não executar orquestrador antigo ou outro listener 2222 em paralelo. Identificar
cada sessão, preservar falhas/descartes, conferir sinais reais/display e AFG OFF.
Procedimento para artigo em [ARTICLE_VALIDATION.md](ARTICLE_VALIDATION.md).
