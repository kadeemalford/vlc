# Verificação offline — 09/11/2026

Sem instrumentos ou dados de pacientes. Ambiente Python da proposta anterior,
PyTorch 2.14.1+cpu. Resultados não são evidência de transmissão VLC física.

## Testes

- `codificacao_neural`: 7 testes aprovados.
- Regressão `equalizador_neural`: 47 testes aprovados.
- Regressão `equalizador_neural_2`: 6 testes aprovados.
- Ruff (`E9,F63,F7,F82,F401,F841`) e `git diff --check`: sem erros.
- Testes/helpers MATLAB novos: não executados neste ambiente.

## Treino e conformidade

`fit(seed=42/43/44)` atingiu zero erros no alfabeto de 256 bytes em 100 passos
para cada seed. São símbolos do próprio treino, não avaliação de generalização.
Todos produziram 256 palavras binárias distintas de 16 bits.

Execução CLI persistida em `runs/demo_model_20261109/`:

- Seed 42, 100 passos, loss BCE final 0,01872210204601288.
- Modelo SHA-256:
  `40be481bae964f9d52bd192d846a5eb29ad28f5a930da66f17da10c918204b0e`.
- Fontes e hashes preservados com o treino. Artefato local ignorado no Git;
  recriar com os comandos abaixo ou transferir separadamente.

## Roundtrip serializado e controle de representação

Mensagem sintética de 19 bytes `!#MDHR0081|!#VAMX11` (não é observação clínica).

| Item | Resultado |
| --- | --- |
| Bits de origem | 152 |
| Bits latentes, sem framing | 304 |
| Pacotes completos | 2, com 488 e 280 bits |
| Total transmitível, com framing | 768 bits |
| Expansão, com framing | 5,0526× |
| Decoder no loopback ideal | 19 bytes idênticos, zero erros observados |
| Bypass do decoder | 38 bytes latentes, diferentes do original |

SHA-256 da origem e reconstrução:
`dc94c57f4b254ac5604d0b37339c997a9379d562a5b28691b80cb6e86e00b18a`.

O bypass não é tentativa criptanalítica e não comprova segurança. Os pacotes
usados aqui vieram dos próprios bits TX, com `--ideal`; nenhum resultado foi
rotulado como recepção física. O teste sintético do leitor RX, separado, verifica
que ele ignora os bits TX presentes em capturas e usa a waveform alinhada.

## Comandos executados

A partir de `codificacao_neural/`, usando o Python da venv antiga:

```bash
../equalizador_neural/.venv/bin/python make_demo.py --out data/demo_20261109
../equalizador_neural/.venv/bin/python workflow.py train --out runs/demo_model_20261109 --seed 42
../equalizador_neural/.venv/bin/python workflow.py encode --model runs/demo_model_20261109/model.pt --input data/demo_20261109/synthetic_002.bin --out data/tx_demo_20261109 --message-id 2
../equalizador_neural/.venv/bin/python workflow.py decode --model runs/demo_model_20261109/model.pt --packets data/tx_demo_20261109/packet_0001.mat data/tx_demo_20261109/packet_0002.mat --out runs/demo_ideal_20261109 --ideal --reference data/demo_20261109/synthetic_002.bin
../equalizador_neural/.venv/bin/python workflow.py decode --model runs/demo_model_20261109/model.pt --packets data/tx_demo_20261109/packet_0001.mat data/tx_demo_20261109/packet_0002.mat --out runs/demo_bypass_20261109 --ideal --bypass-decoder --reference data/demo_20261109/synthetic_002.bin
```

Para repetir, usar saídas novas: diretórios existentes são recusados. A identidade
binária do arquivo `.pt` não é garantida entre versões/plataformas; transferir o
mesmo checkpoint para encoder/decoder e conferir seu hash. Conformidade numérica
do código é verificada ao carregar o modelo, independentemente do nome do arquivo.
