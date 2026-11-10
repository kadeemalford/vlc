# Receptor isolado do monitor — verificação em 10/11/2026

## Mudança de escopo

Somente monitor de pesquisa: frequência cardíaca ECG (HR) ou taxa de pulso óptica
(PR), conforme origem identificada. Sensor de dedo não é evidência de dado ECG.
Nenhum ventilador, bomba, outra variável ou alarme no novo coletor.

Código novo não modifica o legado. Mantém padrões dos identificadores e frames
de `mae_handlers.m`/`mae_registry.m`/`mae_frame.m`, mas usa framing MLLP completo
em vez do consumo oportunista do buffer TCP legado.

## Testes executados

```bash
../equalizador_neural/.venv/bin/python -m unittest discover -s tests -v
```

15 testes aprovados, incluindo os 7 do codec anterior. Os 8 novos verificam:
fragmentação/coalescência, mensagem incompleta, envelope inválido/oversized/nested,
distinção HR/PR, rejeição de ausência/decimais/unidades/status incorretos, duplicidade,
inspeção sem exportação de frames, exclusão de identificadores e exportação exata.

Smoke TCP executado com subprocesso local: servidor em 127.0.0.1, porta efêmera,
cliente sintético enviando envelope MLLP em dois pedaços. Frame obtido
`!#MDPR0082`; manifesto `finished`, uma mensagem, sem bytes de aplicação retornados
ao cliente. Teste não envolveu equipamento, rede externa ou instrumentos.

## Conferência do protocolo histórico

Fonte: `data_examples/capture_prolife_pro_12_filtered.pcapng`.
SHA-256 preservado:
`1b07f2a823ae8ed18a3cd2a82b80c51c50bce2e9c2ff92108afccd0f4d76912b`.

TCP de entrada na porta 2222 reconstruído em memória por sequência, com remoção
de sobreposições e verificação de ausência de lacunas no fluxo analisado.

- 996 envelopes MLLP `VT ... FS CR` completos; buffer residual vazio.
- Identificadores HR e PR distintos, conforme registro legado.
- Para cada sinal: 272 observações numéricas elegíveis, 226 ausentes/fora da faixa
  de representação do coletor (1..9999); não são limites de validade fisiológica.
- Nenhum HL7, PID, nome, ID ou valor pessoal foi copiado para artefatos públicos.
  Somente contagens/estrutura foram registradas; o arquivo fonte não foi alterado.

Essas contagens são do PCAP anterior, não novos dados reais do ensaio atual e
não validação do monitor ao vivo. Não provam regularidade de amostragem ou ausência
de retransmissões. A necessidade de ACK HL7 no setup atual permanece pendente.
