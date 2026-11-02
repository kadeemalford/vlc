# Proposta 4 — equalização/detecção em VLC limitado por banda

**Estado em 02/11/2026:** software preparado e testado offline; nenhuma aquisição
nova, taxa máxima física ou vantagem neural demonstrada. O piloto antigo de
1 Mbps não é validação desta nova hipótese. A proposta 2 em
[`../equalizador_neural/`](../equalizador_neural/README.md) permanece intacta.

**Comece por [BANCADA.md](BANCADA.md) no PC da bancada.** Não execute inicialização
ou uploads automaticamente ao atualizar o Git. Ver [ROADMAP.md](ROADMAP.md) para
estado e limites. Formalização científica: proposta 4 em
[`../PROPOSTA_ML_VLC_TELEMETRIA.md`](../PROPOSTA_ML_VLC_TELEMETRIA.md).

## O que este software faz

1. Planeja blocos Manchester por taxa, com metadados e seeds explícitos.
2. Reutiliza o coletor da proposta 2 com instrumentos **já abertos e configurados**.
3. Verifica canal, registro e taxa de aquisição antes de autorizar um upload.
4. Agrupa arquivos brutos por taxa, reprocessa sem alterar originais e gera
   diagnóstico do integrador, falhas, margens e espectro relativo.
5. Com sessões independentes: compara integrador, template de médias de classe,
   ridge contextual, CNN e DFE, sem adicionar AWGN por padrão.
6. Exporta curvas BER/taxa de runs completos sem escolher seed vencedora ou
   converter taxa física em goodput.

Todos os métodos mantêm **sincronização assistida pelo TX completo**. O alvo é o
bit, não a waveform limpa. Contexto simétrico inclui lookahead: não alegar operação
causal/streaming. Um modelo é treinado por taxa; não há generalização multitaxa
validada. Imagens, OFDM, NRZ/PAM, CRC/FEC e comunicação independente de payload
não foram implementados nesta pasta.

## Dependências e instalação

Manter as pastas irmãs no mesmo clone. `shared.py` aponta explicitamente para a
proposta 2; a reutilização evita duas cópias divergentes do sincronizador/leitor.
Nenhum arquivo antigo foi modificado. Os manifestos incluem snapshots/hashes das
fontes Python novas e das reutilizadas. MATLAB deve usar as fontes do mesmo clone.

Recomendado Python 3.10+ e PyTorch CPU. Comandos **PowerShell no Windows**, a partir
de `equalizador_neural_2/` (criar venv somente se ela ainda não existir):

```powershell
py -3 -m venv .venv
.\.venv\Scripts\python.exe -m pip install --upgrade pip
.\.venv\Scripts\python.exe -m pip install "numpy>=1.24,<3" "scipy>=1.10,<2" "matplotlib>=3.7,<4"
.\.venv\Scripts\python.exe -m pip install "torch>=2.2,<3" --index-url https://download.pytorch.org/whl/cpu
.\.venv\Scripts\python.exe check_environment.py
.\.venv\Scripts\python.exe -m unittest discover -s tests -v
```

`requirements.txt` reutiliza as faixas da proposta 2; uma instalação direta pode
baixar CUDA dependendo da plataforma. A sequência acima prefere CPU. Compatibilidade
da versão escolhida com o Python local deve ser confirmada na instalação, não foi
testada no PC Windows nesta etapa. Não é preciso integrar Python ao MATLAB.

No Linux, pode-se usar a venv existente da proposta 2:

```bash
../equalizador_neural/.venv/bin/python check_environment.py
../equalizador_neural/.venv/bin/python -m unittest discover -s tests -v
```

## Exercitar tudo sem instrumentos

Os exemplos seguintes usam `python` do ambiente preparado; no Windows substitua
por `.\.venv\Scripts\python.exe` se a venv não estiver ativada. Use sempre saídas
novas: scripts recusam sobrescrever diretórios existentes.

```bash
python make_demo.py --out data/demo_raw
python campaign.py --source data/demo_raw --out data/demo_audited
python benchmark.py --data data/demo_audited/rate_1000000_sps_10 --out runs/demo_1m --epochs 2
python benchmark.py --data data/demo_audited/rate_2000000_sps_10 --out runs/demo_2m --epochs 2
python compare_rates.py --runs runs/demo_1m runs/demo_2m --out runs/demo_curves
```

O demo usa filtro passa-baixas sintético de corte fixo e ruído pequeno, com taxa
crescente e amostras de três sessões artificiais. São **fixtures funcionais**, não
um modelo calibrado, proposta de taxas autorizadas ou evidência de generalização
física. Seus resultados não devem integrar as conclusões experimentais do artigo.

## Depois de coletar: preparação e caracterização

Passe raízes de **capturas brutas**, não raízes auditadas nem diagnósticos/objetos
MATLAB. JSON e diário CSV são ignorados pelo leitor de MATs. Cada sessão física
pode ter vários subdiretórios de taxa:

```bash
python campaign.py --source data/raw/session_a data/raw/session_b --out data/campaign_v1
```

Funciona também com **uma única sessão piloto**, sem treinar modelos. Saídas:

- `manifest.json`: estado, entradas/hashes, grupos, snapshots e hashes das saídas;
- `characterization.csv`: resultado do integrador por taxa/sessão/split;
- `rate_<bps>_sps_<n>/`: raiz auditada por taxa, incluindo originais preservados
  nos campos de histórico dos derivados e seu próprio manifesto;
- `rate_.../characterization/frames.csv`: bits/erros, score, rails ADC e margens;
- `rate_.../characterization/spectra.csv`: estimativa `Sxy/Sxx`, coerência e máscara
  de suporte TX por captura; ganho normalizado pelo maior módulo estimado;
- `rate_.../characterization/summary.json`: contagens por sessão e limitações.

**Interpretação:** espectro estimado em quadros curtos, após alinhamento e escala
de pico, não é resposta calibrada nem medida definitiva de banda. Manchester não
excita todas as frequências igualmente; bins sem suporte não têm ganho definido.
Não se calcula automaticamente uma banda de −3 dB. Valores de coerência e margens
são diagnósticos, não provas de não linearidade ou SNR física. A ausência de rails
ADC não exclui saturação analógica. BER de falhas é desconhecida, não zero.

Limites herdados: MATLAB numérico `-v7`, Manchester com sps par, taxas TX/RX iguais,
`assisted_full_tx`, limites de arquivo/ZIP do reprocessador (32 MiB/membro,
256 MiB/grupo); não carregar campanhas arbitrariamente grandes em RAM. Não se
reamostram offline taxas diferentes sem validação separada. A preparação registra
fontes brutas e nunca as altera; um run incompleto é mantido para inspeção.

## Comparação científica — somente após sessões independentes

Se a raiz auditada de uma taxa contiver treino, validação e teste independentes:

```bash
python benchmark.py --data data/campaign_v1/rate_1000000_sps_10 --out runs/real_1m_seed42 --epochs 20 --context 2 --feedback 3 --seed 42
```

Pode passar várias raízes auditadas da **mesma taxa** após `--data`. A guarda
recusa mistura de taxas/protocolos, origens/payloads idênticos entre splits e piloto
de uma sessão. Não criar sessões artificiais para contornar esse bloqueio. Uma
sessão por split é apenas guarda mínima; recomenda-se mais sessões independentes.

Repetir por taxa e seeds predefinidas, por exemplo 42, 43 e 44. Ajustes de contexto,
feedback, regularização, época e arquitetura devem usar treino/validação, não teste.
Ruído numérico permanece disponível na proposta 2 como estudo complementar separado.

### Referências e igualdade de informação

- Integrador Manchester: sem treino.
- Template de médias de classe: treino limpo, contexto de um bit.
- Ridge: decisão linear regularizada em amostras fracionariamente espaçadas, mesma
  janela/normalização da CNN; concorrente FFE contextual, não toda forma de MMSE.
- CNN: duas convoluções pequenas e classificador binário reutilizados da proposta 2.
- DFE: mesma janela feedforward mais `feedback` decisões passadas; ajuste com histórico
  TX **somente no treino**, seleção por BER recursiva na validação, teste totalmente
  recursivo. Estado zerado nas bordas do quadro; não usa TX desconhecido no feedback.

O DFE tem informações passadas e estrutura adicionais; declarar isso, não chamar
os modelos de idênticos em complexidade. A CNN/ridge usam lookahead conforme contexto.
Se os resultados indicarem não linearidade, acrescentar Volterra e/ou outros clássicos
antes de atribuir vantagem à rede. O algoritmo DFE em Python é sequencial e não
otimizado; tempo medido não é uma comparação de implementações de produção.

`reference/` guarda o benchmark comum e os pesos CNN/ridge. Arquivos superiores
incluem DFE e métricas dos cinco métodos, bootstrap pareado por sessão e snapshots.
Sem duas sessões de teste não há intervalo bootstrap; mesmo com poucas sessões ele
é frágil. Contagens de falhas permanecem separadas, sem BER imputada.

```bash
python compare_rates.py --runs runs/real_1m_seed42 runs/real_2m_seed42 --out runs/rates_seed42
```

Esse comando verifica hashes, exporta CSV/gráficos e exige protocolo de treino
compatível; não agrega bits, escolhe seed, calcula taxa máxima certificada ou
throughput. Diferenças de sessões, ambiente e taxas requerem interpretação própria.

## Dados, backup e preservação

`data/`, `runs/`, `.venv/` e configs `*.local.json` são ignorados pelo Git. Atualizar
o clone não transfere capturas nem dependências. Faça backup fora do repositório.
Não copie a venv Linux para Windows: recrie o ambiente. Nenhum script desta pasta
faz commit, push ou alteração da proposta 2 automaticamente.
