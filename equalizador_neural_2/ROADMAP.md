# Continuidade — proposta 4, criada em 02/11/2026

## Estado verificável

- Propostas 4 e 5 formalizadas em `../PROPOSTA_ML_VLC_TELEMETRIA.md`.
- Proposta 2 e arquivos em `../equalizador_neural/` preservados, sem edição.
- Implementados: validação de plano MATLAB, coleta por bloco/taxa com confirmação
  explícita e checagens antes do upload, diário de tentativas e metadados.
- Implementados: preparação auditável por taxa, diagnóstico do integrador e espectro
  relativo, benchmark sem AWGN adicional e DFE recursivo, exportação de curvas por taxa.
- Reutilização por imports explícitos via `shared.py`, não cópias independentes das
  fontes antigas. Manter o clone completo ao transferir ao PC Windows.
- Executados no Linux: **6 testes novos aprovados**, incluindo duas taxas sintéticas,
  fluxo CNN/DFE, hashes, rejeição de piloto, taxas incompatíveis e origens duplicadas.
- Regressão de compatibilidade no ZIP físico antigo: 100 alinhamentos, zero erros
  em 40.000 bits no diagnóstico novo, hash original preservado e treino recusado.
  É reutilização do piloto antigo, não nova coleta ou validação do regime de alta taxa.
- Reexecutados: **47 testes da proposta 2 aprovados**, incluindo regressão do ZIP real.
- Nenhum instrumento acessado. **MATLAB/Windows não testados nesta etapa.**
- Não há dado físico novo, vantagem neural, OFDM ou compressor de imagens implementado.

## Próxima ação concreta

No PC da bancada, seguir `BANCADA.md`: preparar ambiente e testar validadores sem
instrumentos, preencher metadados reais e obter autorização local; depois coletar
um bloco de referência a 1 Mbps. Validar aquisição e diagnóstico antes de aumentar
taxa. Não executar inicialização legada ou uploads apenas por atualizar o repo.

## Depois do piloto

1. Verificar taxas, clipping, sincronismo, margens e suporte espectral; estimativas
   normalizadas de quadros curtos não substituem caracterização calibrada.
2. Definir taxas úteis a investigar, respeitando limites do AFG/cadeia/aquisição.
3. Coletar treino/validação/teste em sessões independentes, sem mudar split entre
   taxas de uma mesma sessão nem renomear quadros para contornar as guardas.
4. Preparar por taxa e executar benchmark nas mesmas fontes para todos os métodos.
   O benchmark exige taxas iguais dentro de cada execução e não adiciona AWGN.
5. Congelar arquitetura/contexto/feedback em validação, repetir seeds predefinidas;
   avaliar falhas, BER/FER e diferenças por sessão, não só uma curva agregada.
6. Se o clássico resolver tudo, não alegar necessidade de ML. Se houver não linearidade,
   acrescentar Volterra/outros clássicos antes de concluir ganho neural.

## Limites que não devem desaparecer no artigo

- `assisted_full_tx`, mesma informação para todos. Sem receptor independente validado.
- CNN/ridge contextuais com lookahead; DFE realimenta decisões e reinicia por quadro.
- DFE treinado com histórico conhecido, validado/testado em loop fechado.
- Um modelo por taxa; não significa generalização para taxa inédita.
- BER em falhas desconhecida. Zero erros observado não comprova BER nula.
- `bit_rate` nominal não é throughput de arquivo; latência Python não inclui instrumentos.
- Dados/runs/venv/configs locais ignorados no Git precisam de backup separado.
- Não usar taxas do demo sintético como autorização para hardware real.
- Não está implementada taxa máxima certificada, CRC/FEC, sincronização por preâmbulo,
  FIR de reconstrução de waveform, Volterra, reamostragem offline ou streaming online.

Atualizar este arquivo somente com comandos/resultados realmente executados e
datas, sem converter planejamento em evidência experimental.
