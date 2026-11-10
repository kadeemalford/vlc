# Codificação neural experimental de telemetria médica por VLC

**Proposta 6, prioridade desde 09/11/2026.** Encoder e decoder neural para
transportar a representação de mensagens compactas dos aparelhos no setup VLC
existente. Não exige compressão, alta taxa, vantagem sobre clássicos ou estudo
de interceptadores na primeira etapa.

**Escopo vigente desde 10/11/2026:** somente taxa cardíaca/pulso do monitor em
bancada de pesquisa. Ventilador, bombas, alarmes e demais variáveis não integram
a proposta ativa. No sensor de dedo, confirmar **PR**, sem confundi-la com **HR
do ECG**. Ver [MONITOR.md](MONITOR.md) para a captura TCP isolada.

**Não é criptografia comprovada.** Não há chave, autenticação ou adversário neste
protótipo. O controle sem decoder demonstra incompatibilidade de representação,
não impossibilidade de recuperação por terceiros. Pesos, arquitetura e formato
podem ser públicos. Um mapeamento por byte, em especial, pode ser caracterizado
por um pequeno dicionário de pares conhecidos. Não usar para proteger dados reais.

Formalização: proposta 6 em [`../PROPOSTA_ML_VLC_TELEMETRIA.md`](../PROPOSTA_ML_VLC_TELEMETRIA.md).
Continuidade: [ROADMAP.md](ROADMAP.md). Procedimento: [BANCADA.md](BANCADA.md).
Os equalizadores e o legado não são alterados por estes scripts.
Resultados efetivamente executados: [demo offline](reports/offline_demo_20261109.md).

## Implementado versus pendente

| Item | Estado |
| --- | --- |
| Autoencoder MLP com latentes binários e serialização | Implementado e testado em Python |
| Reconstrução exata do alfabeto de 256 bytes | Verificada offline, seeds 42/43/44 |
| Framing, CRC, fragmentação, identificação de modelo | Implementados e testados |
| Decoder de capturas MATLAB alinhadas e aceitas | Testado offline; usuário relatou dois roundtrips físicos exatos, artefatos ainda não conferidos aqui |
| Controle sem decoder | Implementado; não é teste de segurança |
| Exportação MATLAB da mensagem compacta | Implementada; usuário relatou testes MATLAB aprovados |
| Replay MATLAB de um pacote pelos instrumentos abertos | Usuário relatou sucesso em 09 e 10/11/2026 com mensagem sintética |
| Coletor TCP isolado do monitor | Implementado; testes de framing/parser aprovados; validação presencial pendente |
| Integração monitor → VLC online | Não implementada; captura e replay continuam separados |
| Preâmbulo/receptor independente de TX | Não implementados; replay usa alinhamento assistido |
| Segurança de camada física/criptografia | Não demonstradas, fora do ensaio mínimo |

## Arquitetura mínima

```text
Mensagem ASCII compacta → bytes → MLP encoder → 16 bits latentes por byte
  → fragmentos com cabeçalho/CRC → bits → Manchester-OOK → VLC
  → integrador Manchester → validação do pacote → MLP decoder → bytes
```

Encoder: 8 entradas → 32 tanh → 16 logits. Gargalo binário com straight-through
estimator no treino; transmissão usa decisões duras. Decoder: 16 entradas → 32
tanh → 8 logits. Sem canal/ruído na função de treino inicial. Não é um autoencoder
físico end-to-end, um compressor temporal ou um código wiretap. Não foi otimizado
para corrigir erros de canal: erros residuais provocam rejeição, não reparo garantido.

Treino exaustivo dos 256 símbolos: prova de conformidade do codec, não teste
independente de generalização clínica. O mesmo alfabeto está no treino e no teste
de conformidade, explicitamente. Mensagens/sessões reais terão avaliação experimental
própria; nenhum byte precisa ser inferido a partir de uma distribuição clínica.

### Formato NC1, público e sem segredo

Cabeçalho big-endian de 25 bytes: magic `NC1` (3), prefixo SHA-256 do modelo (8),
ID da mensagem (4), índice de fragmento base zero (2), total (2), tamanho original
do fragmento (2), CRC32 dos bytes originais (4). Seguem 2 bytes latentes por byte
original e CRC32 de cabeçalho+latentes (4). O CRC original valida reconstrução,
não é entrada do decoder. CRCs e fingerprint **não são autenticação**.

Até 16 bytes de origem por fragmento → até 61 bytes/488 bits físicos antes da
expansão Manchester. Isso cabe no orçamento inicial de 10k amostras/10 MS/s com
sps=10 e duas durações de quadro. Um quadro legado de 58 bytes exige 4 fragmentos.
Há expansão de 2× nos latentes, mais overhead; contabilizar tudo, não chamar de
compressão. `transmitted_bits` não inclui duração de upload, repetição AFG nem
futuros preâmbulos/FEC. Repetir waveform no AFG não aumenta mensagens entregues.

## Instalação e testes sem instrumentos

Manter o clone completo, incluindo `equalizador_neural/`, `equalizador_neural_2/`
e o legado. Python 3.10+ com NumPy, SciPy e PyTorch CPU. No PowerShell, a partir
desta pasta, criar a venv uma vez:

```powershell
py -3 -m venv .venv
.\.venv\Scripts\python.exe -m pip install "numpy>=1.24,<3" "scipy>=1.10,<2"
.\.venv\Scripts\python.exe -m pip install "torch>=2.2,<3" --index-url https://download.pytorch.org/whl/cpu
.\.venv\Scripts\python.exe -m unittest discover -s tests -v
```

Os comandos abaixo usam `python` do ambiente preparado; substituir pelo caminho
da venv quando necessário. No Linux pode-se reutilizar
`../equalizador_neural/.venv/bin/python`. Não copiar a venv Linux para Windows.

```bash
python make_demo.py --out data/synthetic
python workflow.py train --out runs/codec_seed42 --seed 42
python workflow.py encode --model runs/codec_seed42/model.pt --input data/synthetic/synthetic_002.bin --out data/tx_synthetic_002 --message-id 2
python workflow.py decode --model runs/codec_seed42/model.pt --packets data/tx_synthetic_002/packet_0001.mat data/tx_synthetic_002/packet_0002.mat --out runs/ideal_002 --ideal --reference data/synthetic/synthetic_002.bin
python workflow.py decode --model runs/codec_seed42/model.pt --packets data/tx_synthetic_002/packet_0001.mat data/tx_synthetic_002/packet_0002.mat --out runs/bypass_002 --ideal --bypass-decoder --reference data/synthetic/synthetic_002.bin
```

Todas as saídas devem ser novas, sem sobrescrita. O modo `--ideal` usa bits TX,
**somente loopback de software**. Não misturar seu resultado com transmissão óptica.
Treinos não conformantes são registrados e recusados pelo encoder/decoder ao carregar.

O decode normal usa somente `rx_aligned` de capturas `status=ok`; nunca substitui
RX por `tx_bits`. O arquivo de referência passado com `--reference` é lido apenas
depois da reconstrução para calcular igualdade, não fornece dados ao decoder.

## Monitor de frequência cardíaca/pulso: ponto de integração

Referência de campos e framing compacto: `mae_handlers.m`, `mae_registry.m`,
`mae_frame.m` e a lógica TCP em
`../vlc-system-matlab-alarm-care-pro-scripts/src/scripts/alarm-care-pro/`.
Esses scripts incluem outros equipamentos e não são executados pelo coletor novo.
`monitor_capture.py` implementa somente recepção MLLP na porta 2222, extração
explícita de HR/PR e exportação de uma única taxa selecionada. O objeto de estudo
é o **frame compacto**, não o HL7 completo. Não se salva HL7 bruto ou identificadores.
O coletor preserva a distinção HR/PR e recusa arredondamento silencioso de decimais.

`matlab/export_compact_frame.m` permite exportar um frame já obtido no workspace:

```matlab
% Research recording only, after de-identification and local authorization.
export_compact_frame(frame, sourceDir, 'session01_message0001');
```

Não executar `real_time_mae_vlc(false)` apenas para capturar: ele inicializa AFG,
abre servidores e configura callback de comandos aos aparelhos. Usar o coletor
isolado conforme MONITOR.md; ele não transmite dados de aplicação, não importa
VISA nem acessa gateway/UI. Primeiro inspecionar HR/PR, depois exportar uma leitura
e usar `workflow.py encode`. Captura TCP não equivale a integração VLC online.

Dados médicos e identificadores não devem ir ao Git, snapshots ou logs públicos.
Observar autorização/ética local. Exemplos `synthetic_*.bin` não são medidas clínicas.

## Resultado e controles

`result.json` informa modo, decoder, tentativas, fragmentos aceitos, mensagem completa
e, havendo referência, igualdade/erros de bytes. Não emite mensagem reconstruída
se faltar/rejeitar/duplicar qualquer fragmento. Não há retransmissão automática,
FEC ou deduplicação de tentativas. Processar cada mensagem lógica separadamente;
IDs devem ser únicos na sessão e arquivos passados explicitamente.

No bypass, valida-se framing e descarregam-se os bytes latentes sem reconstrução.
O arquivo se chama `latent_bytes.bin`, não é telemetria válida nem saída clínica;
não aplica o CRC de origem, pois propositalmente não decodifica. Diferença frente
ao original não comprova confidencialidade. Não esconder esse controle como se
fosse um ataque criptanalítico malsucedido.

Para o artigo, agregar tentativas de todas as mensagens/sessões, contagens exatas
e perdas. Nenhum script atual certifica BER zero, calcula intervalos científicos
de campanha ou gera conclusão clínica. O objetivo mínimo é transporte/reconstrução;
sem comparações não há superioridade, sem ataques/modelo de segurança não há sigilo.

## Preservação e limites

`data/`, `runs/`, `.venv/` e `*.local.json` são ignorados: backup separado e transferência
manual ao PC da bancada. Checkpoints PyTorch devem vir de origem confiável; loader
usa `weights_only=True`, não pickle arbitrário de objetos completos.

`workflow.py` e o demo não acessam rede ou instrumentos. Somente
`monitor_capture.py --listen` abre o listener TCP explicitamente autorizado;
não escreve mensagens de aplicação ao monitor. Nenhum script acessa gateway/UI.
Helpers MATLAB não inicializam nem desligam automaticamente saídas; uploads
requerem confirmação presencial. Esta implementação não é um dispositivo médico
nem proteção de dados adequada para uso operacional.
