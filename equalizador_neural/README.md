# Proposta 2 — equalização/detecção neural Manchester-OOK 

Esta pasta é um **ponto de partida experimental**, não um receptor validado nem
um roteiro infalível. O objetivo é descobrir se aprendizado reduz erros frente
a métodos clássicos, nas mesmas aquisições e condições não vistas. Não há aqui
resultados físicos, dataset coletado ou ganho comprovado de ML.

## O que já está implementado

| Arquivo | Papel |
| --- | --- |
| `matlab/collect_capture.m` | Uma transmissão/aquisição por chamada; salva arrays simples e metadados, inclusive quando ocorre erro. Requer instrumentos já configurados. |
| `pipeline.py` | Treino e avaliação offline: integrador Manchester, detector linear regularizado e CNN 1D pequena. |
| `make_demo.py` | Dataset sintético para testar a instalação e o fluxo, **não** para demonstrar desempenho físico. |
| `tests/test_pipeline.py` | Testes de mapeamento, janelas, vazamento, falhas e execução completa. |

O protótipo é de **detecção de bits depois da sincronização**, não de equalização
de forma de onda ou aprendizado fim a fim. A rede recebe apenas amostras RX;
bits TX entram como rótulos e referência de avaliação. Entretanto, o alinhamento
e a polaridade ainda usam o TX inteiro: o resultado é explicitamente
`assisted_full_tx`. A correlação atual não tem limiar de confiança, portanto
`status=ok` significa que ela retornou uma janela válida, não que o sincronismo
está comprovadamente correto. Um falso alinhamento pode aparecer como erro de bits.

O baseline linear aprende uma decisão bipolar a partir da mesma janela da CNN
(mínimos quadrados/MMSE empírico com regularização ridge). É um baseline clássico
inicial, **não uma implementação completa de equalizador FIR de forma de onda,
MMSE com modelo de canal ou DFE**. Inclua esses concorrentes se os resultados e a
caracterização indicarem que são necessários antes de alegar superioridade de ML.

## 1. Antes de ligar ou alterar a bancada

O caminho esperado é AFG → amplificador → Bias-Tee/LED → ar → PD/TIA → MDO3012.
Use limites autorizados pelo responsável da bancada. O coletor não configura
amplitude, corrente, ganho, trigger ou saída do AFG e não desliga os instrumentos
automaticamente. Não faça varredura elétrica antes de conhecer limites seguros.
Prefira payloads aleatórios no início; não é necessário conectar equipamentos
médicos, pacientes, gateway ou UI para estudar o receptor.

### Perguntas que precisam de confirmação no setup real

| Preciso saber | Por que importa / caminho provisório | Resposta fornecida / situação atual |
| --- | --- | --- |
| Qual LED, amplificador, PD/TIA e ganho? Qual corrente de polarização e limites térmicos/elétricos? | Não consigo recomendar uma faixa segura de amplitude sem isso. Registre as configurações e consulte o responsável. Amplitude AFG não é potência óptica. | Por orientação do usuário, adotar os componentes do cap. 4 de Camporez: LED CREE CXA1507 5000K, amplificador Juntek DPA-2698 (6 dB), Bias-Tee Picosecond Pulse Labs 5575A e receptor Hyperion. A faixa de 100–300 mA é histórica dos ensaios da tese, não corrente atual confirmada nem autorização de operação. Permanecem pendentes corrente efetiva, ganho/configuração do receptor e limites seguros atuais. Conferir o limite do Bias-Tee; Klaas informa 500 mA para o 5575A. |
| Qual versão de MATLAB, toolboxes e driver VISA estão instalados? | O legado usa VISA e funções como `rectpulse`, `alignsignals`, `resample` e `rms`; o coletor depende desse ambiente funcional. Não instala nem corrige drivers. | Confirmado por saída do PC: MATLAB R2021a (9.10.0.1602886), Windows 11 Pro; Communications Toolbox 7.5, Signal Processing Toolbox 8.6 e Instrument Control Toolbox 4.4 instalados. `rectpulse`, `alignsignals`, `resample`, `rms`, `visa` e `visadev` localizados. `instrhwinfo('visa')` informa adaptador `ni`; `JarFileVersion = Version 4.4` não identifica a versão do driver NI-VISA. Versão do driver e compatibilidade do novo diagnóstico ainda não verificadas. |
| É o mesmo MDO para TX/RX? Em qual canal está o PD? | A chamada permite dois objetos distintos ou o mesmo objeto; o canal é argumento explícito. O legado costuma usar CH1. Confirme fisicamente. | Confirmado pelo usuário: mesmo MDO para TX/RX; fotodetector no canal 1 (CH1). |
| A aquisição entrega códigos ADC ou volts calibrados? | Nesta cópia, `readSamples()` retorna códigos `int8` convertidos para double. Não chame isso de volts. Para converter, é necessário conhecer/registrar o preâmbulo vertical, como YMULT, YOFF e YZERO, validando a fórmula com o instrumento. | Confirmado pelo método fornecido pelo usuário: `RIBinary`, largura de 1 byte, conversão `int8`→`double`, sem aplicar calibração vertical. RX bruto está em códigos ADC, não volts; taxa de amostragem é obtida de `XINcr`, com fallback estimado quando inválido. |
| Taxa real, tamanho do registro, trigger e escala vertical? | Defaults: 1 Mbps, 10 amostras/bit, registro de 10.000 pontos. Confirme no instrumento e no código executado, não apenas no README. | Adotar provisoriamente 1 Mbps, **não verificado na prática**. Usuário enviará fotos do osciloscópio. `matlab/diagnose_capture.m` também registra consultas de configuração, sem substituir a verificação visual; taxa RX e número de amostras ficam salvos por leitura. |
| O AFG repete continuamente o quadro? O registro inclui uma cópia completa? | A sincronização atual exige uma janela completa sem wrap-around. Se cruza o limite do registro, ajuste aquisição/tamanho de quadro ou implemente enquadramento próprio. Não recorte manualmente só os casos bons. | Pendente de teste: criado `matlab/diagnose_capture.m`, usando o MDO já inicializado, CH1 e payloads aleatórios conhecidos. Salva RX bruto e procura correspondências completas não sobrepostas; duas ou mais sugerem repetição dentro do registro, não provam emissão contínua. Limiares são exploratórios; ausência de correspondência não prova ausência física do quadro. Não executado na bancada. |
| `CURVe?` retorna a forma de onda nova? | O upload atual espera 50 ms. Isso reduz um problema conhecido de captura antiga, mas não garante novidade em todos os setups. Use payloads distintos por chamada e verifique atualização/trigger; aumente a espera apenas com evidência. | Pendente de teste: o diagnóstico faz seis uploads com payloads distintos e duas leituras após cada upload, sem reenviar entre elas; compara cada RX com o payload atual e o anterior, salvando scores, BER assistida e resultado inconclusivo quando necessário. A segunda leitura tem espera adicional de 200 ms; não é uma medição precisa do instante de atualização do instrumento. Não executado na bancada. |
| Há canal de retorno? O receptor operacional conhecerá o payload? | Para esta fase não há feedback operacional nem receptor independente; há apenas comparação offline assistida. Não use BER contra TX como observação online de um receptor independente. | Confirmado pelo usuário: TX/RX centralizados no mesmo PC e MDO, com acesso à entrada/saída e comparação de qualidade; manter escopo assistido por TX completo. Isso não confirma protocolo ACK/retransmissão. O script adicional de olho possui métricas estimadas do olho (`berEye`) distintas de BER por comparação de bits (`berLink`); sua figura não comprova contagem de erros nem atualização da aquisição. |
| Como registrar distância, ângulo/desalinhamento e iluminação? | Escolha medidas reproduzíveis, unidades e uma convenção; se não há luxímetro, registre fonte/posição/estado da iluminação e explicite a limitação. | Usuário define distância fixa nominal de 2,4 m e alinhamento aproximadamente axial (0° nominal), com receptor quase diretamente abaixo do LED; geometria aproximada, não medida exata. Não haverá medição de iluminância. Montagem mantida fixa, com iluminação externa dependente do horário do dia; não equivale a iluminação constante entre sessões. Registrar horário e descrição das condições. |

Se o software real difere desta cópia, mantenha o **contrato de dados** abaixo e
adapte o coletor. Não precisa forçar uso do MATLAB se outro software captura
arrays equivalentes. Se só houver `.mat` contendo objetos `System1tx1rxResponse`,
abra-os no MATLAB com as classes no path e exporte campos numéricos; `scipy`
não é um leitor confiável desses objetos. Não use `.mat -v7.3` diretamente neste
pipeline: ele exige o formato `-v7`, não HDF5.

## 2. Preparar a bancada e validar o primeiro quadro

1. Faça o script legado funcionar numa condição boa, antes de incluir ML.
2. Verifique forma de onda no AFG, saída elétrica/óptica e entrada do MDO. Observe
   saturação no amplificador/LED/PD e clipping no ADC. Pico normalizado não prova
   linearidade; acoplamento AC não remove todo ruído ambiente.
3. Adicione ao MATLAB `src/main` do legado e `matlab` desta pasta:

   ```matlab
   repo = '/caminho/para/vlc';
   addpath(genpath(fullfile(repo, 'vlc-system-matlab-alarm-care-pro-scripts', 'src', 'main')));
   addpath(fullfile(repo, 'equalizador_neural', 'matlab'));
   params = ManchesterOokParameters();
   encoder = ManchesterOokEncoder(params);
   ```

4. Obtenha `txAnalyzer`/`rxAnalyzer` a partir da inicialização que **já funciona**
   na bancada. Se há apenas um MDO: `txAnalyzer = analyzer; rxAnalyzer = analyzer;`.
   A função `setupAnalyzer` do script `real_time_mae_vlc.m` é local ao script e não
   necessariamente chamável do workspace. Use-a como referência, não como API.
   Confirme VISA, High-Z, offset, amplitude, acoplamento, canais, horizontal e
   vertical. **Não copie a amplitude de 1 Vpp sem confirmar segurança.**
5. Transmita um quadro aleatório e confira bits e amostras. O mapeamento é
   `1 → [+1,-1]`, `0 → [-1,+1]`; o integrador decide 1 quando a primeira meia-fase
   soma mais que a segunda. O primeiro ponto de `rx_aligned` deve corresponder
   ao início do primeiro bit e sua extensão ser `n_bits * sps`.

Exemplo de uma captura, com os instrumentos já configurados:

```matlab
rng(101); % Registre a semente; nao reinicie com a mesma em cada quadro.
bits = randi([0 1], 1, 400); % Provisorio: confirmar que cabe numa copia completa.
meta = struct('capture_id', 'dia01_c01_000001', ...
    'session_id', 'dia01_montagem01', 'condition_id', 'boa_d050', ...
    'split', 'train', 'payload_type', 'random', 'payload_seed', 101, ...
    'distance_m', 0.50, 'alignment_note', 'eixo alinhado', ...
    'receiver', 'PREENCHER', 'afg_vpp', NaN, 'bias_current_a', NaN, ...
    'pd_gain', 'PREENCHER', 'vertical_scale_v_div', NaN, ...
    'illumination_note', 'PREENCHER', 'operator_note', 'piloto');
file = collect_capture(txAnalyzer, rxAnalyzer, encoder, bits, 1, ...
    fullfile(repo, 'equalizador_neural', 'data', 'pilot'), meta);
```

Os valores físicos no exemplo são ilustrativos; `NaN`/`PREENCHER` são campos
pendentes, não medições. Troque o canal e preencha os valores conhecidos.
O coletor salva horário UTC, bits, TX ideal, RX bruto, RX alinhado, taxas e tempos
de upload/aquisição/sincronização. O erro é salvo com o estágio correspondente.
Erros de upload ou leitura não devem ser chamados de falhas de sincronização.

Para vários quadros, faça um laço **sem mexer automaticamente na amplitude**:

```matlab
for i = 1:100 % Apenas teste funcional; nao e tamanho suficiente para um artigo.
    meta.capture_id = sprintf('dia01_c01_%06d', i + 1);
    bits = randi([0 1], 1, 400);
    collect_capture(txAnalyzer, rxAnalyzer, encoder, bits, 1, ...
        fullfile(repo, 'equalizador_neural', 'data', 'pilot'), meta);
end
```

O coletor faz **uma tentativa por chamada**, sem usar `System1tx1rx.communicate()`.
No legado, até três leituras podem ocorrer e o retorno antecipado de falha perde
informações relevantes. Aqui toda chamada concluída tenta salvar um arquivo,
inclusive com erro. Interrupção/crash antes do `save` ainda pode perder a tentativa:
para campanhas longas, mantenha um log externo de tentativas iniciadas e faça
backup. Não confunda repetição do AFG com quadros independentes de uma fonte real.

## 3. Desenhar a campanha e obter os dados de treinamento

### Piloto recomendado

- Primeiro um receptor, taxa fixa e aquisição fixa. Condição boa e duas ou três
  condições degradadas **seguras**, alterando distância/alinhamento e só depois
  amplitude dentro de limites autorizados. Faça uma variável por vez inicialmente.
- Inspecione bits aleatórios novos por quadro, BER do integrador e RX bruto.
  Se tudo tem BER zero, não comece uma rede grande: aumente volume ou degradação
  segura. Se tudo está saturado e ilegível, volte a uma região recuperável.
- Em cada condição, colete vários blocos em sessões independentes; alterne a ordem
  das condições para não confundir deriva temporal com distância/amplitude.
- Sessão é um grupo com canal/configuração correlacionados, por exemplo montagem
  e dia. Não crie um `session_id` novo a cada quadro para burlar a separação.
  Capturas próximas do mesmo experimento devem ficar no mesmo split.

### Treino, validação e teste

Defina as sessões antes da campanha, por exemplo duas sessões de treino, uma de
validação e duas de teste como **mínimo logístico ilustrativo**, não suficiência
estatística. Mais sessões/dias independentes são desejáveis. Treino e validação
devem conter uma faixa útil de canais. Reserve também condições físicas inteiras
para teste de extrapolação (distância, iluminação, outro receptor etc.).

O campo `split` de cada captura é `train`, `val` ou `test`. O pipeline recusa uma
mesma sessão em splits diferentes, mas **não detecta IDs artificiais, duplicação
de waveform ou payloads repetidos**. Mantenha IDs globais únicos, seeds distintas
e trilha da origem. Não divida janelas da mesma captura aleatoriamente.

Use aleatórios/PRBS com períodos e seeds adequados; o coletor recebe bits arbitrários
e o exemplo usa `randi`. Não repita a mesma PRBS curta em todos os splits.
Depois, avalie separadamente payloads compactos representativos de telemetria,
de preferência sintéticos/desidentificados e não vistos. PCAPs são fonte de
payload, **não sinais ópticos RX nem dados físicos para treinar o detector**.

O pipeline trata todos os bits de cada array como avaliáveis, incluindo qualquer
cabeçalho que você acrescente. Na fase assistida, um quadro aleatório não precisa
passar pelo parser clínico. Ao migrar para preâmbulo, separe índices de treino,
preâmbulo, cabeçalho e payload e declare quais entram nas métricas.

### Quanto coletar?

Comece com centenas de capturas por condição para verificar instrumentação e
ordens de grandeza; isso não é uma recomendação universal de tamanho amostral.
Registre sempre número de bits e erros. Sob uma aproximação de erros independentes,
zero erros em N bits dá limite superior de 95% próximo de `3/N`, não BER nula
garantida. Demonstrar BER abaixo de `1e-5` sem erros exige aproximadamente 300 mil
bits **nessa hipótese**; comparação entre métodos pode exigir muito mais, e
correlação/rajadas invalidam a interpretação ingênua. Planeje sessões suficientes,
não apenas milhões de janelas de uma única aquisição.

### Contrato do `.mat` por tentativa

Obrigatórios para o leitor Python:

| Campo | Conteúdo |
| --- | --- |
| `metadata_json` | JSON string com `capture_id`, `session_id`, `condition_id`, `split`; metadados físicos adicionais são livres. |
| `tx_bits` | Vetor não vazio de 0/1, na ordem transmitida. |
| `rx_aligned` | Para `ok`, vetor finito de comprimento `len(tx_bits)*sps`, já normalizado, reamostrado e com polaridade corrigida. Para `error`, pode estar vazio. |
| `sps`, `bit_rate` | Amostras por bit (inteiro positivo par) e taxa. Uma execução aceita uma única combinação. |
| `status` | `ok` ou `error`. Falhas não entram no treino de bits, mas ficam na avaliação de disponibilidade. |
| `sync_mode` | Nesta versão, apenas `assisted_full_tx`. |

Preserve também `rx_raw`, `tx_samples`, taxas de amostragem, estágio, mensagem de
erro e tempos, como faz o coletor. São fundamentais para reprocessamento e auditoria.
O leitor mínimo não exige todos esses campos extras, mas sua ausência limita
conclusões. Salve arrays, não objetos MATLAB. Dados e runs são ignorados pelo Git:
isso evita commits acidentais, **não substitui armazenamento e backup**.

## 4. Instalar e exercitar o pipeline

Comandos a partir desta pasta; Python 3.10+ recomendado (inicialmente CPU):

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
python make_demo.py --out data/demo
python -m unittest discover -s tests -v
python pipeline.py train --data data/demo --out runs/demo --epochs 3
python pipeline.py evaluate --data data/demo --run runs/demo --split test
```

Para usar a distribuição CPU de PyTorch e evitar downloads de CUDA, instale numpy
e scipy do índice usual e torch do índice CPU, respeitando `requirements.txt`.
O comando acima é a alternativa mais simples, mas pode baixar dependências GPU.
O demo testa o fluxo; seu canal é artificial, sincronizado por construção, sem
calibração na bancada. Qualquer ganho nele **não valida** a proposta científica.

Com dados reais:

```bash
python pipeline.py train --data data/pilot --out runs/pilot_seed42 --context 2 --epochs 20 --seed 42
python pipeline.py evaluate --data data/pilot --run runs/pilot_seed42 --split val
# Congele escolhas de modelo, contexto e pre-processamento antes desta chamada:
python pipeline.py evaluate --data data/pilot --run runs/pilot_seed42 --split test
```

Cada pasta de run deve ser nova; o programa não sobrescreve treino/avaliação.
Uma falha depois de criar a pasta pode deixar um run parcial: use outro nome ou
inspecione antes de limpar. O pipeline não é streaming: carrega capturas/janelas
em RAM. Comece pequeno; datasets maiores exigirão loader por captura e treino
incremental, mantendo a separação por sessões.

### O que é treinado e como evitar vantagem injusta

- **Integrador:** decisão diferencial entre as duas meias-fases, sem ajuste.
- **Linear ridge:** janela de RX com intercepto; escolhe regularização em validação.
- **CNN:** duas convoluções pequenas e saída binária; salva a época com menor
  BER de validação. Usa BCE, Adam, sem entrada TX.
- `--context 2` significa dois bits anteriores + bit atual + dois posteriores:
  com 10 amostras/bit, entrada de 50 amostras. É **não causal**, com lookahead de
  dois bits; linear e CNN têm a mesma janela. `--context 0` remove vizinhos, mas
  ainda exige aquisição de um bit inteiro.
- Janelas não cruzam quadros; padding zero nas bordas. Normalização adicional é
  global, ajustada somente no treino e compartilhada por linear/CNN. O integrador
  recebe o RX alinhado original. A normalização de pico da captura já feita no
  MATLAB usa o bloco inteiro: avalie seu impacto se o destino for streaming.
- Features não usam `tx_samples`, `rxBits` ou bits TX. Contudo, a assistência TX
  no sincronismo beneficia **todos** os métodos e deve constar no artigo.
- Ajuste contexto, regularização e arquitetura apenas em treino/validação. Se
  comparar vários contextos, permita a mesma busca ao linear. Rode várias seeds
  pré-definidas e reporte variabilidade, não só a melhor execução no teste.
- O checkpoint guarda pesos da CNN; `linear.npz` guarda coeficientes; `config.json`
  registra escala, janela, IDs/sessões, seeds, histórico e versões principais.
  Registre também commit do código, ambiente completo e parâmetros da bancada.

## 5. Ler os resultados e decidir se vale avançar

`evaluation_test.json` contém por método, condição e sessão:

- BER = erros / bits **somente das capturas alinhadas**, com contagens explícitas;
- FER condicional ao alinhamento: fração desses quadros com ao menos um bit errado;
- tentativas totais, falhas e entrega exata: quadros sem erros / todas as tentativas;
- Wilson 95% para BER sob hipótese IID (apenas uma referência descritiva);
- tempo de execução do detector CPU, separado do ciclo de captura.

`frames_test.csv` preserva a comparação pareada por captura, erros e tempo de
captura. Nas falhas, `errors=0` é um placeholder; **não significa ausência de erro**.
Use `status` para filtragem. A BER de falhas é desconhecida, não imputada como 0
ou 0,5; a indisponibilidade aparece separadamente. `exact_frame_delivery` é uma
métrica offline contra TX, **não entrega clínica nem aceitação validada por CRC**.

Wilson não prova significância do ganho em erros correlacionados. Para um artigo,
compare diferenças de BER/FER nas mesmas capturas e faça bootstrap pareado por
sessão (ou desenho hierárquico por sessão/bloco), preservando rajadas/correlação.
Poucas sessões tornam essa análise frágil. Esse bootstrap ainda não está
implementado. Não esconda condições ruins agregando tudo numa BER global.

O tempo do detector inclui decisão/batching, mas não construção das janelas,
normalização, sincronização, upload, aquisição ou disco. Não equivale a latência
fim a fim ou throughput útil. O coletor mede upload/aquisição/sincronização;
valide disponibilidade e tempo desde a entrada do quadro até a saída de bits na
integração. Sem sequência/CRC/tempo de origem não há avaliação de entrega clínica.

**Portões de decisão:**

1. Capturas e rótulos corretos? Integrador funciona na condição boa? Se não,
   corrija aquisição/mapeamento antes de treinar.
2. Existem erros recuperáveis em condições relevantes? Se não, aumente volume
   ou refine a pergunta, sem forçar operação insegura.
3. Linear já resolve tão bem quanto CNN? Não atribua ganho ao aprendizado neural;
   considere baselines adicionais e ablações antes de insistir.
4. CNN ganha em sessões/condições reservadas, sem piorar significativamente as
   boas? Repita com seeds/dias e avalie região operacional para BER/FER alvo.
5. Ganho permanece com custo de inferência e sincronização contabilizados? Só
   então planeje integração ao ciclo real.

## 6. Caminho para sincronização por preâmbulo e integração real

Esta etapa **não está implementada**: não basta trocar `sync_mode` no arquivo.

1. Defina um quadro com preâmbulo conhecido e comprimento delimitado; considere
   sequência/CRC para integridade. Escolha sequência e duração com base no canal,
   não um número arbitrário que eu ainda não consigo recomendar sem capturas.
2. Correlacione **somente** o preâmbulo para atraso/polaridade; estabeleça limiar,
   busca e tratamento de ambiguidades/frames repetidos usando treino/validação.
   Se há deriva de relógio ao longo do quadro, sincronizar só o início pode não
   bastar: investigar tracking ou reamostragem antes de atribuir erros ao detector.
3. Salve bruto e todas as falhas. RX operacional não pode escolher alinhamento ou
   polaridade olhando payload TX, nem usar sua BER para aceitar um quadro.
4. Atualize coletor, leitor e máscaras de payload; todos os concorrentes devem
   receber o mesmo orçamento de preâmbulo/pilotos e informações disponíveis.
   O ajuste supervisionado offline deste protótipo não consome pilotos online;
   se FIR/DFE adaptar por quadro, contabilize esse orçamento explicitamente.
5. Avalie sincronização separada da detecção e reexecute a comparação. Não compare
   CNN assistida com baseline independente como se fossem receptores equivalentes.
6. Integre inicialmente em modo sombra: decodificação neural em paralelo, sem
   encaminhar dados clínicos. Para MATLAB, escolha depois entre Python engine,
   ONNX compatível ou reimplementação da inferência; isso depende da versão e
   toolboxes disponíveis. Preserve janela, padding, escala e ordenação dos bits.
7. Valide equivalência numérica offline antes da bancada e meça custo completo.
   Não encaminhe automaticamente quadros incorretos só porque o parser aceita a
   sintaxe. CRC, sequência e tratamento de dados inválidos continuam necessários.

## Referências locais para adaptações

- `../PROPOSTA_ML_VLC_TELEMETRIA.md`, seção 2: hipótese e critérios científicos.
- `../vlc-system-matlab-alarm-care-pro-scripts/src/main/model/system/system1tx1rx/System1tx1rx.m`: fluxo legado e retries.
- `../vlc-system-matlab-alarm-care-pro-scripts/src/main/model/utils/SignalUtils.m`: normalização, resampling e alinhamento por TX.
- `../vlc-system-matlab-alarm-care-pro-scripts/src/main/model/logicanalizers/Mdo3012/Mdo3012Analyzer.m`: upload ASCII, espera e ADC bruto.
- `../vlc-system-matlab-alarm-care-pro-scripts/src/main/model/decoders/manchesterook/ManchesterOokDecoder.m`: decisão de referência.

Para refinarmos este roteiro, os próximos insumos mais úteis são: identificação
da bancada e limites seguros, versão do MATLAB/toolboxes, modo de aquisição e
um pequeno lote de `.mat` com RX bruto, TX, metadados e falhas. Não inclua dados
identificáveis de pacientes.
