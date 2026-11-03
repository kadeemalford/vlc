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

### Primeiro retorno do MATLAB da bancada — 03/11/2026

- `testValidPlan` passou. `testShortRecord` rejeitou corretamente o registro curto,
  mas o teste falhou por esperar um identificador de erro não retornado pelo MATLAB.
- `testUnfilledTemplate` encontrou arquivo ausente: o `.gitignore` da raiz ignora
  `*.json`, incluindo inadvertidamente `matlab/session.example.json`.
- Corrigidos os dois testes com identificadores explícitos `VLC:RatePlan:*` e
  adicionada exceção no `.gitignore` local para versionar o template. Configurações
  `*.local.json` continuam ignoradas. A repetição no MATLAB ainda está pendente.
- Nenhuma nova captura foi relatada neste retorno; conexão VISA ainda não confirmada.

### Conexão e plano do primeiro piloto — 03/11/2026

- Usuário confirmou conexão NI-VISA com MDO3012 C024549, firmware v1.20:
  AFG OFF, CH1, 10.000 pontos, intervalo 100 ns, AC e 500 mV/div.
  Aquisição ativa, STOPAfter RUNSTOP, trigger AUTO/EDGE/CH1/RISE/100 mV.
- Os três testes de validação MATLAB passaram após a correção.
- JSON `bench_20261103_161327.local.json` revisado a partir do arquivo recebido
  em Downloads: 1 Mbps, 20 quadros de 400 bits, distância aproximada de 2,1 m;
  receptor assumido Hyperion conforme tese, ganho não documentado.
- Fonte relatada: CH1 18 V/0,194 A em CV, CH2 17,38 V/0,199 A em CC, em série.
  Metadado de corrente usa indicação CH2 com ressalva explícita, não medição
  independente do LED. AFG relatado Arbitrary/Hi-Z/1 Vpp/offset zero;
  CH1 com limite de banda de 20 MHz. Não foi autorizada mudança elétrica.
- Adicionado `ExistingVisaMdo3012Analyzer`: toma emprestada a sessão VISA aberta,
  sem configuração no construtor; reutiliza upload legado e implementa leitura
  binária sem fallback de taxa. Não modifica fontes da proposta 2.
  **Adaptador ainda não executado no MATLAB**; próximo portão é leitura com AFG OFF.

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
