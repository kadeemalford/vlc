# Contrato de integração — proposta, ainda não aplicada

Implementação inicial opt-in e limitações atuais em
[LIVE_INTEGRATION.md](LIVE_INTEGRATION.md). Usa a fronteira NDJSON aqui descrita;
alterações na UI/orquestrador originais não foram aplicadas.

## Fronteiras

1. Entrada: quadro compacto ASCII de uma taxa do monitor, p.ex. `!#MDPR0059`.
2. Encoder: bytes → 16 bits latentes por byte, modelo congelado identificado por
   SHA-256. Decoder compatível recebe somente os latentes recebidos.
3. Protocolo: NC1 de `codificacao_neural/packets.py`; CRC detecta erros acidentais,
   não autentica. Prefixo de hash não é segredo/chave.
4. PHY: Manchester clássico a 1 Mbps inicialmente, sps=10, 10 MS/s, 10k pontos.
5. Saída: quadro compacto reconstruído e validado. Somente então chamar
   `mae_frame`/`mae_frontend`; não há caminho alternativo com fonte TX em claro.
6. Backend recebe exatamente o contrato anterior. Exemplo sintético de formato:

```json
{"source":"monitor_message","payload":{"type":"Monitor Measurements","variables":[{"name":"Puls Oxim Puls Rate","value":"59","unit":"1/min"}],"alarms":[]}}
```

É uma linha NDJSON terminada em LF para 4455. `SocketServer` a publica em
`monitor_message` na porta 4444. Manter PR distinta de HR; o campo do ECG seria
`Ecg Heart Rate`. Os valores deste exemplo não são nova observação clínica.

## Orçamento de aquisição

Para n bytes de origem em um fragmento NC1: 29 bytes de overhead + 2n bytes
latentes. Com n=10: 49 bytes/392 bits; com n=16: 61 bytes/488 bits.
O teto inicial é 500 bits por upload/registro, não 58 caracteres depois do codec.
Um frame legado agregado de 58 bytes passa a precisar de 4 fragmentos, com
4×29 + 2×58 = 232 bytes/1856 bits no total, antes de Manchester.

Logo, não aplicar o limite legado de 472 bits ao conteúdo já codificado, nem
adicionar seu prefixo ASCII de oito bits a NC1. Fragmentar ou limitar batching;
nunca truncar para caber. Taxa nominal não é goodput do fluxo.

## Estados mínimos

- `sourceAccepted`/rejected: sintaxe, sinal selecionado e leitura representável.
- `queued`/`queueDropped`: política de backlog explícita e contada.
- `packetPrepared`: bits reais, modelo e tamanhos conhecidos.
- `syncOk`: apenas sincronização do PHY; captura rejeitada tem BER desconhecida.
- `packetOk`: CRC, protocolo e identidade do modelo conferidos.
- `codecOk`: reconstrução passou no CRC de origem, sem usar fonte TX.
- `messageComplete`: todos os fragmentos corretos, uma mensagem lógica.
- `deliveryOk`: envio aceito pelo caminho MATLAB/gateway; atualização do painel
  é outra observação a verificar, não consequência automática de `codecOk`.

Qualquer falha anterior à entrega bloqueia `sendDecodedBatch`. Não reaproveitar
o valor original, a última leitura ou valores interpolados como se fossem RX.
Sem todos os fragmentos, rejeitar mensagem, preservar tentativa e motivo. Definir
timeout, reset, duplicatas e IDs antes de permitir mensagens em paralelo.

A comparação TX/RX completa pertence ao avaliador de pesquisa. O receptor atual
ainda pode usar TX para sincronização assistida, explicitamente; isso não lhe dá
permissão para usar TX como resultado do decoder ou corrigir fragmentos.

## Falhas e tempo

Desconexão VISA não deve ativar AFG ou mudar amplitude por reconexão automática.
Separar abrir conexão, configurar aquisição, carregar waveform e habilitar saída.
Início seguro deve falhar fechado se faltarem modelo, taxa, metadados ou autorização.

Não registrar BER desconhecida como 0, nem igualar Q/BER estimada a contagem de
erros. O artigo-base informa 10 ms de intervalo e BER estimada de Q; o software
inclui upload/espera/aquisição/filas. Medir latência efetiva, idade da observação
e perdas de fila depois de integrar.

Retorno de comandos do painel segue TCP e não faz parte do codec. Desabilitá-lo
na pesquisa, sem alterar silenciosamente o comportamento dos outros modos.
Dados fora de validade não devem renovar o timestamp do painel. O timestamp de
replay não é tempo de aquisição do monitor: registrar ambos e não alegar online.

## Escolhas ainda abertas

- Inferência MATLAB nativa com pesos exportados versus bridge Python persistente.
- Política de fila (FIFO limitada/backpressure/latest-only), contadores e cadência.
- Entrypoint da UI MATLAB usado no PC (.m ou .mlapp).
- Portar sync Pearson validado versus auditar/adaptar o sync legado.
- CRC/FEC/retry e timeout de fragmentos: sem inferir garantias não medidas.
- Preâmbulo público/receptor independente fica em etapa separada.
