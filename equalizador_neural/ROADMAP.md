# Roadmap de continuidade — proposta 2 (para agentes de IA)

## 0. Leia isto antes de agir

Este arquivo é um **handoff técnico e experimental** para continuar o trabalho sem
depender do histórico da conversa. Os ensaios descritos foram registrados pelo
usuário em **15/10/2026**. Não confunda resultados observados, código implementado
e atividades planejadas.

**Estado resumido (atualizado em 18/10/2026):** etapas A e B executadas no piloto,
incluindo reprocessamento auditável, AWGN pós-alinhamento e pré-sincronização,
verificação analítica e repetição com outra seed. Benchmark com integrador,
template de médias de classe, ridge e CNN implementado/testado com sessões
sintéticas; guardas recusam treinar o piloto físico de uma sessão. Ambiente CPU
local preparado e suíte Python ampliada para 47 testes.

**Próximo bloqueio real:** obter sessões físicas independentes de treino,
validação e teste, conforme [CAMPANHA_BANCADA.md](CAMPANHA_BANCADA.md). Não fabricar
splits renomeando o piloto e não multiplicar capturas virtuais como novas sessões.
Nenhum ganho neural real foi demonstrado; não há treino neural com o piloto físico.

Regras para o agente:

- Leia o código atual e verifique o estado do Git antes de editar; pode haver
  trabalho do usuário não versionado. Este documento não autoriza apagar dados.
- Preserve capturas originais, erros e resultados anteriores; gere derivados em
  diretórios novos. Não transforme retroativamente uma falha em sucesso no original.
- Não trate resultados planejados como já executados. Registre testes realmente
  rodados, ambiente, parâmetros e limitações em cada avanço deste roadmap.
- Não opere instrumentos remotamente nem recomende mudanças elétricas sem limites
  e autorização explícitos. A bancada exige ações presenciais do usuário.
- Comece pelo trabalho offline. Não suponha que o MATLAB continua aberto ou que
  variáveis/conexões da sessão anterior ainda existem.
- Não crie novas sessões artificiais ou splits aleatórios para fazer o pipeline
  treinar: o piloto inteiro pertence a uma única sessão.

## 1. Objetivo e hipótese científica atual

Publicar um artigo baseado em ML aplicado à comunicação VLC real, preferindo
alterações de software. A linha escolhida para o protótipo é a proposta 2 de
[`../PROPOSTA_ML_VLC_TELEMETRIA.md`](../PROPOSTA_ML_VLC_TELEMETRIA.md).

O enlace nominal apresentou poucos/nenhum erro no piloto. Por sugestão do professor,
a pergunta foi reformulada para **robustez sob ruído branco gaussiano controlado
adicionado digitalmente a capturas reais**. É um estudo híbrido experimental-numérico,
não uma demonstração de ruído fisicamente injetado na bancada.

O protótipo atual é um **detector de bits após sincronização**, não uma rede que
reconstrói waveform limpa. Todos os métodos usam sincronização assistida pelo TX
completo (`assisted_full_tx`). Não há receptor independente de payload validado.

Em Manchester ideal com AWGN, pulsos conhecidos e sincronização perfeita, a decisão
por filtro casado já é ótima nas hipóteses usuais. Não prometer vantagem de CNN
apenas por adicionar ruído. A hipótese de vantagem está nas características do
canal medido; precisa superar referências clássicas adequadas, não só um integrador
retangular possivelmente inadequado ao pulso distorcido.

A BER `8,78e-12` da figura de olho discutida pelo usuário é **estimada pelo olho/Q**,
não medida por contagem em cerca de 10 mil bits. BER medida, estimada, falhas de
sincronismo e erro por quadro devem permanecer separados.

## 2. Mapa dos arquivos relevantes

| Arquivo/diretório | Uso e ressalva |
| --- | --- |
| [`README.md`](README.md) | Instruções, contrato `.mat`, perguntas da bancada, reprocessamento, treino e avaliação. Confronte instruções com os resultados e limites datados deste roadmap. |
| [`matlab/collect_capture.m`](matlab/collect_capture.m) | Uma transmissão/leitura por chamada, sem retry oculto; salva inclusive falhas. Aceita limiar de sincronização como oitavo argumento opcional. |
| [`matlab/synchronize_capture_samples.m`](matlab/synchronize_capture_samples.m) | Novo sincronizador assistido, `valid_window_pearson_v1`. |
| [`matlab/test_synchronize_capture_samples.m`](matlab/test_synchronize_capture_samples.m) | Sete testes sem hardware, aprovados no MATLAB da bancada. |
| [`matlab/diagnose_capture.m`](matlab/diagnose_capture.m) | Diagnóstico ativo de seis uploads × duas leituras, usando MDO já inicializado; substitui waveform/período. Não é dataset de treino. |
| [`matlab/match_diagnostic_payload.m`](matlab/match_diagnostic_payload.m) | Busca diagnóstica de cópias completas; limiar exploratório distinto do coletor. Não usa BER para escolher a posição. |
| [`matlab/test_match_diagnostic_payload.m`](matlab/test_match_diagnostic_payload.m) | Três testes aprovados no MATLAB da bancada. |
| [`pipeline.py`](pipeline.py) | Protótipo original de treino/avaliação e funções reutilizadas pelo benchmark novo; smoke tests sintéticos aprovados. |
| [`capture_sync.py`](capture_sync.py) | Busca offline equivalente ao algoritmo MATLAB para amostras na mesma taxa; integrador sem dependência de PyTorch. |
| [`reprocess_captures.py`](reprocess_captures.py) | CLI auditável do ZIP, sem extração, preservando fonte e histórico em diretório novo. |
| [`offline_dataset.py`](offline_dataset.py) | Leitor de artefatos completos com checksums, protocolo consistente e guardas de origem/sessões/splits. |
| [`awgn.py`](awgn.py), [`awgn_sweep.py`](awgn_sweep.py) | AWGN determinístico, varreduras pós-alinhamento e pré-sincronização e previsão condicional do integrador. |
| [`benchmark_detectors.py`](benchmark_detectors.py) | Benchmark com treino, augmentation opcional, seleção em validação e teste pareado; exige sessões independentes antes de criar modelos. |
| [`export_results.py`](export_results.py) | Exporta agregados/gráficos e proveniência após verificar hashes, sem replicar dados brutos. |
| [`tests/test_awgn.py`](tests/test_awgn.py), [`tests/test_benchmark_detectors.py`](tests/test_benchmark_detectors.py) | Testes de ruído, auditoria, indisponibilidade, guardas, benchmark e repetibilidade sintéticos. |
| [`tests/test_reprocess_captures.py`](tests/test_reprocess_captures.py) | 20 testes de sincronização/reprocessamento, incluindo regressão opcional no ZIP real. |
| [`tests/test_pipeline.py`](tests/test_pipeline.py), [`make_demo.py`](make_demo.py) | Testes e dados sintéticos funcionais; suíte executada offline. Demo não valida desempenho físico. |
| [`requirements.txt`](requirements.txt) | NumPy, SciPy e PyTorch; avaliar instalação CPU. |
| [`requirements-cpu.lock.txt`](requirements-cpu.lock.txt) | Snapshot do ambiente CPU Linux/Python 3.13.9 usado em 18/10/2026; `.venv/` já criada nesta máquina. |
| [`reports/awgn_pilot_20261018/README.md`](reports/awgn_pilot_20261018/README.md) | Relatório e agregados versionáveis das quatro varreduras finais do piloto. |
| [`CAMPANHA_BANCADA.md`](CAMPANHA_BANCADA.md) | Próxima coleta necessária, protocolo de sessões, segurança e transferência para o benchmark. |
| [`../baseline_20261015_175101.zip`](../baseline_20261015_175101.zip) | Fonte original do piloto de 100 tentativas; verificar disponibilidade e checksum abaixo. |
| `../vlc-system-matlab-alarm-care-pro-scripts/` | Cópia do legado. A melhoria de sincronização foi feita no protótipo, **não** no `SignalUtils` legado. |
| `../bibliography/Camporez__2025___Thesis (40).pdf`, cap. 4 | Componentes adotados pelo usuário como setup correto. Não confundir com o LED azul do FINEP. |
| `../sinal_osciloscopio/` | Fotos disponíveis no repositório; confirmar data/configuração antes de usá-las como evidência de um ensaio específico. |
| `parametros bancada.txt`, `respostas para perguntas do equalizador.md` | Notas do usuário. A nota de fonte “18 V, 200 mA (canal 1 e 2)” não identifica inequivocamente corrente do LED; não inferir polarização a partir dela. |

`data/`, `runs/` e `.venv/` são ignorados pelo Git desta pasta. Isso não é backup.
O ZIP e notas/fotos podem estar não versionados. Não presumir sua distribuição
num clone novo nem incluí-los em commit sem verificar a intenção do usuário.

## 3. Bancada e ambiente conhecidos

### Configuração usada no piloto ativo

| Item | Estado observado ou informado |
| --- | --- |
| Componentes adotados | CREE CXA1507 5000K, amplificador Juntek DPA-2698 (6 dB), Bias-Tee 5575A, receptor Hyperion; conforme cap. 4 de Camporez e orientação do usuário. |
| Geometria | Distância nominal fixa de 2,4 m, alinhamento aproximadamente axial, receptor quase abaixo do LED. Não é metrologia angular exata. |
| Iluminação | Sem medição de lux; luz externa varia com horário. Montagem fixa não significa iluminação constante. |
| Computador | Mesmo PC centraliza TX/RX; aparelhos médicos não são necessários aos testes com bits gerados pelo MATLAB. |
| Instrumento | Mesmo Tektronix MDO3012 em TX/RX, série C024549; PD/TIA no CH1. |
| MATLAB | R2021a, 9.10.0.1602886, Windows 11 Pro. Communications 7.5, Signal Processing 8.6, Instrument Control 4.4 disponíveis. |
| VISA | Adaptador `ni` disponível e comunicação física funcionando; versão exata do driver NI-VISA ainda desconhecida. |
| TX | Manchester-OOK, nominal 1 Mbps, 10 amostras/bit; `0→[-1,+1]`, `1→[+1,-1]`, cinco amostras por meia-fase. |
| Quadros piloto | 400 bits aleatórios, 4.000 amostras TX, período AFG 400 µs (2,5 kHz). |
| AFG | Arbitrário, 1 Vpp, saída ligada no diagnóstico; inicialização legada configura offset zero e High-Z. Não tratar isso como autorização para qualquer montagem futura. |
| RX | Registro 10.000 pontos a 10 MS/s, janela aproximada de 1 ms, horizontal 100 µs/div. |
| CH1 | 500 mV/div, AC, 1 MΩ. |
| Aquisição | Sample, em execução; trigger Edge/Auto. Fonte, nível e borda ainda precisam ser documentados. |
| Unidade RX | Códigos ADC `int8` convertidos a `double`, **não volts**. Fatores verticais não são aplicados por `readSamples`. |

Pendências: corrente de polarização efetiva, ganho/configuração do Hyperion,
limites elétricos/térmicos autorizados, calibração vertical/relógio e detalhes do
trigger. A faixa 100–300 mA na tese é histórica, não autorização; conferir também
o limite do Bias-Tee (Klaas informa 500 mA para o 5575A).

### Segurança e estado da sessão MATLAB

O legado principal é `src/scripts/alarm-care-pro/real_time_mae_vlc.m`, dentro da
cópia MATLAB. O usuário o iniciou com breakpoint **antes de `if config.DEMO_MODE`**
(linha 39 na versão então usada), após criar `txRxAnalyzer` e o `onCleanup`.

```matlab
dbstop in real_time_mae_vlc at 39
real_time_mae_vlc(false)
```

Esses comandos descrevem como a sessão foi aberta, **não uma instrução para
reexecutá-los automaticamente**. A inicialização liga/configura o AFG, aplica
1 Vpp e tenta fechar sessões de instrumentos anteriores. Confira o código e
autorização antes de qualquer reinicialização. Não abrir outra sessão VISA em paralelo.

No prompt `K>>`, o objeto local era `txRxAnalyzer`; `diagEncoder` era um
`ManchesterOokEncoder`. O workspace base não contém necessariamente esses objetos.
`repo` definido no workspace base não deve ser presumido disponível na função pausada.

Não executar `dbcont` inadvertidamente: ele inicia o restante da pipeline, TCP e
encaminhamento ao backend. Não usar `clear all`/`clear functions` para atualizar
os auxiliares enquanto depende da sessão pausada. Ao sair com `dbquit`, o cleanup
tenta fechar a conexão; **não garante desligar AFG, LED ou fontes**. Encerramento
elétrico deve seguir o procedimento presencial autorizado. Nenhum teste é uso clínico.

## 4. Histórico verificado e lições do piloto

### 4.1 Diagnósticos iniciais e cadeia óptica

- [x] Três testes de `test_match_diagnostic_payload` passaram no R2021a.
- [x] Comunicação VISA e leitura binária confirmadas.
- [x] Detectado posteriormente pelo usuário: **LED estava desligado nos primeiros
  ensaios**. Arquivos como `probe_zeros_manchester.mat`, `check_after_timebase.mat`
  e os primeiros `upload_*` de baixa correlação não validam o enlace ativo.
- [x] Após ativar a cadeia óptica, zeros Manchester produziram pico espectral de
  1 MHz, compatível com a taxa nominal. Não é calibração independente do relógio.
- [x] Em 100 mV/div houve clipping: 26,35% das amostras em +127. Alterou-se apenas
  a escala de aquisição para 500 mV/div; o teste passou a −36…+39, sem limites ADC.
  Isso não prova ausência de saturação no LED/amplificador/PD.
- [x] Rodada `diagnostico_led_ligado_20261015_173013`: seis payloads distintos,
  duas leituras por upload, scores atuais 0,883–0,923, zero erros em 4.800 decisões.
  Cinco registros continham duas correspondências completas. Sem indício de payload
  anterior nas leituras testadas; não é garantia universal de atualização/continuidade.

### 4.2 Coletor e falha do sincronizador legado

- [x] `funcional_20261015_174220.mat`: uma captura com coletor ainda legado,
  400 bits, 4.000 amostras alinhadas, correlação 0,909 e zero erros.
- [x] Bloco `baseline_20261015_175101`: **100 tentativas, 99 alinhadas, zero erros
  em 39.600 bits avaliados**, uma falha de sincronização na captura `0042`.
- [x] Causa da falha confirmada também pelo usuário no MATLAB: `alignsignals`
  escolheu deslocamento 6.005; quadro de 4.000 pontos terminaria em 10.005,
  cinco pontos além do registro. Outra cópia completa existe a partir da amostra
  2.006 (deslocamento 2.005), correlação 0,9085 e zero erros.

### 4.3 Melhoria implementada e validada

- [x] Criado `synchronize_capture_samples.m`, método `valid_window_pearson_v1`.
- [x] Busca Pearson absoluto apenas nas janelas completas, sem wrap-around.
  Polaridade vem do sinal da correlação; **BER não escolhe nem aceita a janela**.
- [x] Limiar padrão 0,5, configurável e **exploratório, não calibrado**. Rejeições
  preservam motivo e score quando disponíveis. `accepted=true` não prova sincronismo.
- [x] Coletor passou a salvar `sync_method`, `sync_threshold` e `sync_info`.
  Assinatura de sete argumentos continua válida; oitavo permite outro limiar.
- [x] **Sete testes MATLAB aprovados pelo usuário**: cópia truncada com pico mais
  forte, inversão/DC, última janela completa, registro curto, sinal constante,
  baixa correlação e limiar inválido.
- [x] Nova captura `sync_v1_20261015_181637.mat`: aceitação real pelo novo coletor,
  score 0,8939, início 456, zero erros em 400 bits, RX −51…+44.
  Metadado `payload_index=100` foi herdado indevidamente do bloco anterior;
  não regenerar esse payload a partir do índice. Os `tx_bits` salvos são a referência.

### 4.4 Auditoria do ZIP já realizada

Fonte: `../baseline_20261015_175101.zip`, **1.831.846 bytes**.

SHA-256:

```text
e0653b423bfb800903f75f5b13b66db7aa32ac848e91ef4d8b3e04f925a339cf
```

A análise foi executada pelo agente em Python/NumPy/SciPy, lendo o ZIP em memória,
sem sobrescrever nem extrair por cima dos originais. Resultado:

| Verificação | Resultado |
| --- | --- |
| Arquivos `.mat` | 100 |
| Bits/registro | 400 bits, 4.000 pontos TX, 10.000 pontos RX; TX/RX a 10 MS/s |
| Integridade básica | Bits binários, TX corresponde ao Manchester esperado, arrays finitos |
| Estado original | 99 `ok`, 1 `error` |
| Reprocessamento numérico equivalente ao novo método | 100 aceitos, zero erros em 40.000 bits |
| Score do reprocessamento | 0,8792–0,9225 |
| Faixa ADC no bloco | −55…+52; nenhum ponto nos extremos |
| Duplicações exatas | Nenhuma entre os 100 payloads, RX brutos ou IDs |
| Sessão | Todos `piloto_funcional_20261015` |
| Split | Todos `train` |
| Tempo total registrado original | Mediana ≈0,225 s; p95 ≈0,241 s; não inclui disco nem mede inferência neural |

**Atualização de 18/10/2026:** a auditoria acima foi materializada por um comando
persistente, com os mesmos resultados. Veja §4.5 para os artefatos. Ausência de
duplicações exatas não torna capturas da mesma sessão independentes.

Arquivos individuais foram enviados pelo usuário a `/home/murilo/Downloads/`;
não depender dessa pasta para continuidade ou backup. O PC da bancada guardou o
bloco em `C:\Users\DELL\Documents\murilobarroso\vlc\equalizador_neural\data\baseline_20261015_175101`.

### 4.5 Reprocessamento persistente executado em 18/10/2026

- [x] Implementados `capture_sync.py`, `reprocess_captures.py` e 20 testes novos.
- [x] Suíte completa: **27 testes Python aprovados**, incluindo os sete testes
  anteriores do pipeline. O treino/CNN desse teste usa apenas o demo sintético;
  não confundir com treinamento sobre o piloto físico.
- [x] Regressão real: 100 aceitos, zero erros em 40.000 bits, 0042 recuperada na
  amostra 2.006 com score 0,9085. Originais permanecem 99 `ok`/1 `error`.
- [x] Leitor original de `pipeline.py` carregou os 100 derivados e seu integrador
  confirmou zero erros. Hash do ZIP, dos 100 derivados e dos dois scripts foi
  conferido contra o manifesto.

Comando executado a partir de `equalizador_neural/`:

```bash
uv run --with numpy --with scipy python reprocess_captures.py \
  --source ../baseline_20261015_175101.zip \
  --out data/baseline_20261015_175101_sync_v1_audited \
  --expected-sha256 e0653b423bfb800903f75f5b13b66db7aa32ac848e91ef4d8b3e04f925a339cf
```

Artefato principal local:
`data/baseline_20261015_175101_sync_v1_audited/`, com:

- `captures/`: os 100 `.mat` derivados; **somente essa subpasta** é dataset de entrada.
- `frames.csv`: auditoria por captura, originais/derivados, métricas e hashes.
- `summary.json`: métricas agregadas; continua uma sessão, split `train`.
- `manifest.json`: `state=complete`, versão 1.0, limiar 0,5, versões de Python/
  NumPy/SciPy, commit/estado Git, hashes do código e de fonte/membros/derivados.
  O commit-base pode não conter os scripts novos: nessa execução `git_dirty=true`;
  os hashes dos scripts identificam a implementação efetivamente executada.

Também existe `data/baseline_20261015_175101_sync_v1/`, primeira execução durante
o desenvolvimento. Não sobrescrevê-la; preferir a saída `_audited` acima.
Artefatos em `data/` são ignorados pelo Git: preservar backup ou regenerar em
**outro nome de saída**, pois a ferramenta recusa diretório já existente.

Validação executada:

```bash
uv run --with numpy --with scipy --with 'torch>=2.2,<3' \
  --index https://download.pytorch.org/whl/cpu \
  python -m unittest discover -s tests -v
```

Sem PyTorch, rodar somente os 20 testes novos com NumPy/SciPy e
`python -m unittest discover -s tests -p test_reprocess_captures.py -v`.
O teste do piloto pula se o ZIP não estiver disponível; verificar skips antes
de alegar regressão real. MATLAB não foi reexecutado nesta etapa offline.

Limites explícitos: taxas TX/RX diferentes são **recusadas**; não há reamostragem
Python silenciosamente tratada como equivalente ao MATLAB. Arquivos são validados
e mantidos em RAM, com limites ZIP de 32 MiB por membro e 256 MiB no total.
Falhas sem sinais recuperáveis continuam indisponíveis, sem BER imputada.
Tempos originais foram preservados como tempos da tentativa de origem; campos
`reprocess_seconds`/`reprocess_sync_seconds` são apenas computação offline, sem IO.
Não usar o tempo total antigo como benchmark do método novo.

### 4.6 AWGN e software de comparação executados offline em 18/10/2026

- [x] Gerador `gaussian_iid_expected_variance_v1`, PCG64 com chave SHA-256 de
  identidade/seed/checksum/nível/realização/fluxo. Sem reescalar o RMS dos draws.
- [x] Potência AC de referência por captura, ponto flutuante sem clipping/requantização,
  condição sem ruído preservada e manifestos com hashes/snapshots do código.
- [x] Pós-alinhamento: grid −10, −8, −6, −4, −2, 0, 2, 4, 5, 6, 8, 10 dB; seed 42,
  30 realizações por nível. BER 0,003695 em 0 dB, 0,0005175 em 2 dB e oito erros
  em 1.200.000 decisões em 5 dB; em 6/8/10 dB, zero erros observados nessa amostra.
- [x] Comparação com previsão analítica exata condicional às waveforms fixas e ao
  AWGN: maior desvio de Monte Carlo ≈1,74 desvios padrão condicionais.
- [x] Réplica com seed 2026 e dez realizações no mesmo grid; não é nova sessão física.
- [x] Pré-sincronização numérica: reexecutada normalização e busca assistida,
  mantendo limiar exploratório 0,5. Na varredura refinada com dez realizações,
  −5 dB teve 0/1.000 aceitas; −4 dB teve 151/1.000; −3 dB teve 989/1.000.
  BER só nas aceitas; indisponibilidade registrada separadamente. Não tratar
  esse ruído pós-ADC como injeção física nem usar a previsão de alinhamento fixo.
- [x] Benchmark com integrador, template de médias de classe, ridge e CNN;
  augmentation opcional, estatísticas só do treino, seleção só em validação,
  mesmos ruídos de teste para todos e bootstrap pareado por sessão. Template não
  é FIR/MMSE/DFE completo. Sementes de modelo/noise e snapshots são registrados.
- [x] Fluxo completo e repetibilidade numérica exercitados em sessões **sintéticas**.
  Piloto físico recusado para treino antes de criar qualquer modelo. Nenhum
  split fictício, CNN treinada em dados reais ou alegação de ganho neural.
- [x] Suíte ampliada a 47 testes; fontes preservadas e exportações auditadas.

Artefatos completos locais (ignorados pelo Git):

| Run em `runs/` | Tipo |
| --- | --- |
| `awgn_pilot_refined_seed42` | Pós-alinhamento, 30 realizações |
| `awgn_pilot_replication_seed2026` | Réplica pós-alinhamento, dez realizações |
| `awgn_pilot_pre_sync_seed42` | Primeira varredura pré-sincronização, cinco realizações |
| `awgn_pilot_pre_sync_transition_seed42` | Refinamento pré-sincronização, dez realizações |

`awgn_pilot_coarse_seed42` é a primeira exploração, com namespace anterior do
gerador e sem snapshots; preservada, mas não usada no relatório final. Não misturar
suas receitas aleatórias com as da versão final.

Os agregados/gráficos/proveniência estão em `reports/awgn_pilot_20261018/`; CSVs
por realização e snapshots do código estão nas runs completas. Exportação compacta
não substitui backup das runs/dados.

Comandos de reprodução (a partir desta pasta; usar nomes novos se já existirem):

```bash
.venv/bin/python awgn_sweep.py \
  --data data/baseline_20261015_175101_sync_v1_audited \
  --out runs/awgn_pilot_refined_seed42 \
  --ratios-db -10 -8 -6 -4 -2 0 2 4 5 6 8 10 --realizations 30 --seed 42

.venv/bin/python awgn_sweep.py \
  --data data/baseline_20261015_175101_sync_v1_audited \
  --out runs/awgn_pilot_pre_sync_transition_seed42 \
  --ratios-db -5 -4 -3 -2 0 2 5 --realizations 10 --seed 42 \
  --point pre-synchronization

.venv/bin/python -m unittest discover -s tests -v
```

Não interpretar esse eixo como SNR física/EbN0, e não tratar os 1.200.000 bits
avaliados por nível como bits novos transmitidos: são 30 ruídos dos mesmos 40.000.
Os experimentos pré/pós usam potências e seleção de janelas diferentes; diferenças
de BER não demonstram ganho de algoritmo. O próximo dado necessário é multissessão.

## 5. Etapas concluídas e pendentes

### A. Materializar dados derivados e auditoria — concluída para taxas iguais

- [x] Verificar ZIP/checksum; ler nomes com segurança, sem extração com path traversal.
- [x] Criar ferramenta offline reproduzível de reprocessamento (Python ou MATLAB),
  em pasta nova sob `data/`, preservando bytes dos originais.
- [x] Reproduzir normalização de pico e novo sincronizador com taxas iguais;
  conferir resultados MATLAB de 0042 e testes de borda. Taxas diferentes recusadas.
- [x] Registrar fonte, checksum, status/erro originais, método/limiar derivados,
  score, posição, polaridade e versão/commit da ferramenta. Não inventar tempo
  de aquisição ou transformar tempo de reprocessamento em tempo da bancada.
- [x] Gerar CSV/JSON por captura e resumo: aceitação, erros, limites ADC e duplicações.
- [x] Manter `session_id` e split originais. Capturas derivadas não são novas sessões.
- [ ] Se outra campanha exigir taxas diferentes, implementar e validar separadamente
  a reamostragem equivalente ao MATLAB. Não é bloqueio para este piloto.

**Aceitação:** reproduzir 100 aceitos/40.000 bits/zero erros neste piloto, preservar
a falha original de 0042 e explicar qualquer divergência. Não escolher alinhamento
por BER nem ajustar limiar para obter esse resultado.

### B. AWGN exploratório pós-alinhamento — concluída no piloto, sem CNN real

- [x] Implementar gerador separado de AWGN com sementes explícitas e várias
  realizações. Preservar versões sem ruído adicional; nunca modificar fonte.
- [x] Começar depois do alinhamento: avalia **detecção assistida**, não robustez
  da sincronização ao ruído. Não reescolher janela/polaridade olhando o ruído ou BER.
- [x] Definir potência de referência AC por captura e `y=x+sigma*z`, `z~N(0,1)`.
  Registrar se `sigma` vem de variância esperada ou de normalização da realização.
  Não impor recorte/quantização ADC implicitamente após ruído numérico.
- [x] Nomear o eixo como razão da potência da captura para a do ruído adicionado;
  não tratá-lo como SNR física total nem `Eb/N0` sem definição/conversão apropriada.
  A captura original já contém ruído, e não é um alvo perfeitamente limpo.
- [x] Fazer varredura inicial ampla, refinada no piloto, para localizar região de
  transição do integrador. Não fixar uma faixa arbitrária como requisito científico.
- [x] Reportar erros/bits, erro por quadro e curvas por nível/realização; usar as
  mesmas entradas ruidosas para todos os futuros detectores.
- [x] Adicionar testes de determinismo, potência esperada, condição sem ruído,
  preservação de fonte e associação inequívoca captura/seed/nível.

**Aceitação:** curvas reproduzíveis, com condição sem ruído adicional recuperando
o baseline. Este bloco de uma sessão é exploratório, não avaliação neural final.

### C. Preparar protocolo e dados para treino/generalização

- [x] Documentar plano de sessões independentes em `CAMPANHA_BANCADA.md`, com alvo
  logístico inicial de duas de treino, duas de validação e três de teste, não
  suficiência estatística garantida.
- [ ] Obter essas sessões físicas independentes e confirmar metadados e limites.
  Não renomear cada quadro como sessão nem dividir o piloto em splits aleatórios.
- [ ] Registrar limites e pendências da bancada; ajustar índices/seeds por captura
  sem reiniciar o RNG com a mesma semente a cada quadro.
- [x] Implementar variantes pós-atribuição de splits e guardas de linhagem;
  testar em sessões sintéticas. Todas as variantes/janelas permanecem na origem.
- [ ] Reservar sessões e níveis para teste; congelar escolhas usando treino/validação.
  Mais realizações de AWGN não substituem mais sessões físicas.
- [x] Validar ambiente Python/CPU e rodar os testes existentes offline em Linux
  em 18/10/2026. Isso não verifica instalação Python no PC da bancada nem treino real.

```bash
# A partir de equalizador_neural/, em ambiente com requirements.txt instalado:
python -m unittest discover -s tests -v
```

### D. Comparar referências e modelo neural

- [x] Preparar e testar software de comparação com augmentation opcional,
  guardas, pareamento de ruídos, métricas e bootstrap por sessão.
- [ ] Integrador, ridge e filtro/detector adequado ao pulso/canal medido; avaliar
  em sessões físicas independentes, incluindo FIR/MMSE/DFE se pertinentes.
  Template de médias de classe já implementado não é um equalizador completo.
- [ ] Estimar pulso/canal e ajustar hiperparâmetros apenas com dados autorizados
  de treino/pilotos. Equalizar contexto, orçamento de treino e informação disponível.
- [ ] Treinar CNN pequena; comparar com/sem augmentation e várias seeds predefinidas.
  Não escolher a melhor seed no teste.
- [ ] Usar avaliação pareada por captura/realização; incerteza por sessão/bloco,
  sem tratar ruídos da mesma captura como novas observações físicas independentes.
- [ ] Medir custo de features/inferência separadamente de upload/aquisição/disco.
- [ ] Prosseguir só se houver ganho frente ao melhor clássico, também fora do
  ajuste, sem degradação relevante no caso sem ruído adicional.

### E. Extensões condicionais e artigo

- [x] Ruído no RX bruto **antes** da normalização/sincronização (taxas iguais):
  reexecutar todo o processamento, registrar rejeições e avaliar disponibilidade.
  Não confundir com o experimento B de alinhamento fixo.
- [ ] Só depois: preâmbulo independente de payload, outros canais/receptores,
  integração em modo sombra e eventual inferência MATLAB/Python/ONNX.
- [ ] Ruído físico, mudanças elétricas e UVLC são escopos adicionais, não necessários
  agora e não autorizados implicitamente pelo roadmap.
- [ ] Revisão bibliográfica específica, ablações, critérios estatísticos, dataset
  rastreável e redação. Não alegar entrega clínica, distância ou margem óptica não medidas.

## 6. Limitações do software que o próximo agente deve conhecer

- O leitor de `pipeline.py` percorre `.mat` recursivamente esperando o contrato de
  captura. Não colocar `settings.mat`, relatórios ou arquivos diagnósticos na pasta
  que ele usa como dataset. O ZIP original contém capturas; diagnósticos têm outro schema.
- O leitor verifica sessão entre splits, mas não impede todas as formas de origem
  duplicada nem mistura de métodos de sincronização. Acrescentar validações para
  variantes/derivados e metadados novos conforme necessário.
- `pipeline.py train` exige treino e validação; o piloto é todo `train`. Não
  contornar essa exigência criando validação vazada apenas para executar a CNN.
- Contexto padrão 2 significa cinco bits de janela e dois de lookahead; detector
  não causal. Linear/CNN compartilham janela; janelas não cruzam quadros.
- `exact_frame_delivery` é comparação offline contra TX, não aceitação clínica
  por CRC. A pipeline original não fornece CRC/ACK/retransmissão validados.
- `sync_mode` permanece `assisted_full_tx`, inclusive com o novo método. Arquivos
  antigos sem `sync_method` não devem receber silenciosamente a versão nova.
- BER nas falhas é desconhecida, não zero. Wilson IID é apenas referência; erros
  correlacionados e poucas sessões exigem cautela. Zero erros não demonstra BER nula.
- O coletor guarda `stage='synchronization'` também quando `status='ok'`; usar
  `status`/`sync_info.accepted` para classificar, não inferir falha pelo estágio.
- `readSamples` tem fallback para taxa quando `XINcr` é inválido; não tratá-lo como
  taxa calibrada sem conferir instrumento e dados. Os ensaios válidos foram a 10 MS/s.

## 7. Como atualizar este documento

A cada etapa, acrescente data, ferramenta/commit, dados/checksums usados, comandos,
resultados e limitações. Marque checkboxes apenas após execução comprovada.
Identifique mudanças de protocolo ou setup e o que foi apenas implementado versus
testado. Mantenha uma próxima tarefa concreta e registre onde estão os artefatos.

**Há curvas de AWGN numérico sobre capturas reais; não há até este ponto
superioridade neural, injeção física de ruído, dataset físico multissessão
validado ou artigo concluído.**
