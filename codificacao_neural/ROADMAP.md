# Continuidade — codificação neural de telemetria

## Decisão em 09/11/2026

Usuário/orientador suspenderam equalização como foco e escolheram demonstração
simples de encoder/decoder neural no enlace VLC com retorno dos aparelhos médicos
como fonte. Sem requisito inicial de compressão, vantagem sobre clássicos ou ensaio
de interceptação. Proposta 6 no documento principal, mantendo proposta 1 original
e demais linhas como histórico. Não foi autorizada exclusão de artefatos antigos.

O termo “criptografia” é motivação/extensão, não conclusão: falta chave/modelo de
ameaça/avaliação de segurança. Bypass do decoder mede representação, não sigilo.
Não chamar o protótipo mínimo de código wiretap ou autoencoder de camada física.

## Atualização vigente — 10/11/2026

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

1. Transferir novos fontes/testes ao PC da bancada; não retreinar o codec já validado.
2. Conferir IPv4 da interface local e destino de envio do monitor (porta 2222).
3. Executar inspeção MLLP com AFG OFF, observar HR/PR e qualidade/contato no display.
4. Exportar uma observação inteira válida da taxa selecionada em pasta nova.
5. Codificar o `.bin` real com o modelo congelado; transmitir pacote(s) pelo VLC
   numa captura identificada como fonte real, separada da referência sintética.
6. Decodificar sem `--ideal`, conferir bytes e valor contra a origem e registrar
   todas as tentativas. Só depois ampliar sessões e eventualmente integrar online.

## Pendências explícitas

- Coletor TCP implementado mas não validado ao vivo; falta integração monitor →
  codec → VLC online. Autenticação, FEC/retransmissão, preâmbulo público/receptor
  sem TX, UI e métricas agregadas de campanha não prontos.
- Nenhum ganho de compressão/superioridade ou segurança demonstrados.
- Roundtrips físicos sintéticos relatados pelo usuário, ainda sem auditoria local
  dos arquivos; nenhuma transmissão de fonte real confirmada até esta atualização.
- Latentes binários não são ciphertext criptograficamente seguro.
- CRC/fingerprint não provam autenticidade. Bit erros podem causar perda do quadro inteiro.
- Fidelidade é contra a mensagem compacta; lacunas/arredondamentos do parser permanecem.
- `data/`, `runs/`, `.venv/`, configs locais e dados médicos exigem backup separado;
  dados sensíveis não devem ser versionados.
