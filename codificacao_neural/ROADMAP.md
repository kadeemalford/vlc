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

## Implementado e verificado offline

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

1. Conferir README e BANCADA, transferir/versionar fontes e recriar ambiente no Windows.
2. Executar demo Python e os testes MATLAB sem instrumentos.
3. Validar captura/exportação desidentificada de um frame real dos aparelhos;
   ainda falta um coletor TCP separado, somente de leitura, com framing validado.
4. Confirmar sessão VISA e montagem completa, incluindo amplificador; fazer replay
   físico de uma mensagem e reconstruir sem `--ideal`.
5. Só depois organizar campanha com mensagens/aparelhos/sessões reais e métricas
   completas. Não alegar online porque a origem foi um aparelho.

## Pendências explícitas

- Integração automática dos aparelhos via TCP, autenticação, FEC/retransmissão,
  preâmbulo público/receptor sem TX, UI e métricas agregadas de campanha não prontos.
- Nenhum ganho de compressão/superioridade ou segurança demonstrados.
- Nenhuma nova medição física executada por estes scripts.
- Latentes binários não são ciphertext criptograficamente seguro.
- CRC/fingerprint não provam autenticidade. Bit erros podem causar perda do quadro inteiro.
- Fidelidade é contra a mensagem compacta; lacunas/arredondamentos do parser permanecem.
- `data/`, `runs/`, `.venv/`, configs locais e dados médicos exigem backup separado;
  dados sensíveis não devem ser versionados.
