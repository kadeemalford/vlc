# Etapas presenciais — proposta 6

**Ainda não executadas para esta proposta.** Não continuar automaticamente uma
sessão de novembro anterior: conferir montagem, alimentação, conexão e limites atuais.
Não reutilizar configurações históricas como medições presentes.

## 1. Sem instrumentos

1. Preparar Python, executar os 7 testes e o demo do README.
2. Conferir `training.json`: `state=conformant`, zero erros nos 256 bytes.
3. Conferir roundtrip ideal: `complete=true` e `exact_match=true`.
4. Executar o bypass como controle de representação, sem alegação de segurança.
5. No MATLAB, definir `repo` para o clone real e preparar paths:

```matlab
addpath(genpath(fullfile(repo, 'vlc-system-matlab-alarm-care-pro-scripts', 'src', 'main')));
addpath(fullfile(repo, 'equalizador_neural', 'matlab'));
addpath(fullfile(repo, 'equalizador_neural_2', 'matlab'));
addpath(fullfile(repo, 'codificacao_neural', 'matlab'));
results = runtests(fullfile(repo, 'codificacao_neural', 'matlab', 'test_codec_helpers.m'));
table(results)
```

Os testes não usam instrumentos. Não foram executados no ambiente Linux.

## 2. Fonte médica e telemetria

Obter mensagens compactas reais após parser, desidentificadas, com autorização.
Preservar ordem e registrar sessão/dispositivo/cadência, com cobertura de alarmes
explicitada. Não tratar limitações do parser como preservação integral do equipamento.

Primeiro replay de um frame real exportado com `export_compact_frame` e convertido
por `workflow.py encode`. Uma captura por pacote do manifesto; não truncar mensagens
para caber. Treino do alfabeto não precisa de dados de pacientes.

Ainda falta um coletor TCP isolado somente de leitura: não executar o sistema
legado completo apenas para obter mensagens, pois pode habilitar AFG e comandos
do gateway aos aparelhos. Nenhuma etapa deve interferir em assistência clínica.

## 3. Conferir bancada e adquirir um pacote

Fonte/LED, amplificador e receptor precisam estar operacionais. Antes houve um
bloco com amplificador desligado e sem sinal identificável; isso foi diagnóstico,
não validação desta proposta. Conferir amplificador explicitamente.

Reutilizar apenas sessão VISA realmente aberta e objetos já conferidos. Ver
`../equalizador_neural_2/BANCADA.md` para o adaptador `ExistingVisaMdo3012Analyzer`.
Não chamar `initiateDefaultConnection`, que modifica configuração e habilita AFG.

O helper inicial exige: 1 Mbps Manchester, sps=10, RX a 10 MS/s, registro de 10k,
transferência CH1, até 500 bits por pacote, AFG explicitamente ON pelo operador.
Amplitude, polarização, ganho e trigger são conferidos presencialmente, não alterados
pelo helper. Registrar valores reais em `meta.physical_metadata`.

Esqueleto de chamada, **não executar sem preencher metadados e confirmar setup**:

```matlab
% txRxAnalyzer must already refer to a verified open connection.
% meta needs capture_id, session_id, split, condition_id, physical_metadata.
filename = collect_encoded_packet(txRxAnalyzer, txRxAnalyzer, ...
    packetFile, captureDir, meta, 'CONFIRM_SAFE_SETUP_AND_WAVEFORM_UPLOAD');
```

O upload substitui waveform/período. Antes de habilitar saída, garantir que a
waveform previamente carregada também é segura; preferir preparar o primeiro
pacote com AFG OFF usando o mesmo encoder Manchester e bits do MAT. Não usar
estado desconhecido do AFG para o primeiro teste. Ao terminar **ou falhar**, desligar
a saída pelo procedimento local; o helper não desliga AFG/fontes automaticamente.

O helper reaproveita `collect_capture`, que salva fontes, TX e RX e usa sincronização
assistida pelo TX completo. Rejeições são preservadas. Não mudar limiar para melhorar
o resultado, não reutilizar captura antiga, não repetir na mesma pasta/ID. Snapshot
por captura inclui as fontes MATLAB resolvidas pelo path.

## 4. Reconstrução após captura

Em Python, passar todos os MATs físicos da mesma mensagem, **sem `--ideal`**:

```text
python workflow.py decode --model runs/codec_seed42/model.pt --packets <capture1.mat> <capture2.mat> --out runs/physical_message01 --reference <original.bin>
```

Arquivos de referência ficam no avaliador, não são necessários ao decoder. As
capturas brutas contêm TX por causa da assistência declarada; o decode nunca usa
esses bits no modo físico. Só a waveform `rx_aligned` aceita alimenta o integrador.

Inspecionar falhas, CRCs, igualdade exata, contagem de tentativas e tamanho total.
`complete=false` é falha de entrega, não zero erro. Manter tentativas anteriores
no inventário, sem misturá-las como fragmentos da tentativa seguinte.

## 5. Portões posteriores

- Confirmar primeiro roundtrip físico antes de registrar campanha de aparelhos.
- Várias mensagens e sessões independentes, sem alegar independência por fragmento.
- Integrar captura TCP somente de leitura, depois online se houver necessidade.
- Preâmbulo público/recepção sem TX antes de alegar receptor independente.
- Nunca encaminhar reconstrução experimental para decisão clínica ou controle de bomba.
