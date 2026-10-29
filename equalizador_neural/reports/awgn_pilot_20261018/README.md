# Piloto offline — AWGN sobre capturas VLC reais

**Data:** 18/10/2026. **Escopo:** uma sessão física, 100 capturas, 40.000 bits
distintos, Manchester a 1 Mbps. Não houve novo ensaio na bancada nem treino
neural sobre dados reais nesta etapa.

## Fonte e integridade

- ZIP original: `baseline_20261015_175101.zip`, SHA-256
  `e0653b423bfb800903f75f5b13b66db7aa32ac848e91ef4d8b3e04f925a339cf`.
- Fonte derivada: `data/baseline_20261015_175101_sync_v1_audited/`, relativamente
  a `equalizador_neural/`. Busca `valid_window_pearson_v1`, limiar exploratório 0,5.
- Original: 99 capturas alinhadas, uma falha; derivado: 100 alinhadas, zero erros
  em 40.000 bits. A recuperação de 0042 não altera seu histórico original.
- Checksums das entradas foram conferidos antes/depois das varreduras. Os
  diretórios abaixo exportam somente agregados/gráficos/proveniência; os CSVs
  por tentativa e snapshots do código ficam nas pastas `runs/` correspondentes.
- Cada `provenance.json` contém o manifesto original e hashes dos arquivos
  exportados. **Não é um pacote completo de execução nem um dataset de capturas.**

## Protocolo de ruído

Gerador `gaussian_iid_expected_variance_v1`, PCG64 com chave SHA-256 de versão,
seed, ID, checksum da fonte, nível, realização e fluxo. Sem clipping,
requantização, recentralização ou ajuste do RMS de cada realização gaussiana.

Para a waveform de referência `x`, define-se `P = mean((x-mean(x))²)` e
`sigma² = P * 10^(-R/10)`. Soma-se `sigma*z`, com `z ~ N(0,1)` independente.
**R é a razão potência AC capturada/variância do ruído adicional, não SNR física
total nem Eb/N0.** A captura já tem ruído. Cada captura define sua própria potência;
isso também não demonstra ganho de distância/potência óptica.

As realizações adicionais são avaliações virtuais das mesmas fontes, não novas
capturas ou sessões independentes. Não foram usados como splits de ML.

## 1. Ruído após alinhamento fixo

Em [`post_alignment_seed42/`](post_alignment_seed42/summary.json), usaram-se 30
realizações por nível: **1.200.000 decisões de bits e 3.000 quadros virtuais por
nível**, a partir dos mesmos 40.000 bits físicos. A condição sem ruído adicional
foi avaliada uma vez. Não houve nova sincronização ou normalização após o ruído.

| R (dB) | Erros / decisões | BER observada | Erro por quadro |
| --- | --- | --- | --- |
| Sem ruído adicional | 0 / 40.000 | 0 observado | 0 |
| −10 | 221.296 / 1.200.000 | 0,184413 | 1 |
| −6 | 95.216 / 1.200.000 | 0,079347 | 1 |
| −2 | 17.978 / 1.200.000 | 0,014982 | 0,994333 |
| 0 | 4.434 / 1.200.000 | 0,003695 | 0,774333 |
| 2 | 621 / 1.200.000 | 0,0005175 | 0,184 |
| 4 | 39 / 1.200.000 | 0,0000325 | 0,013 |
| 5 | 8 / 1.200.000 | 0,000006667 | 0,002667 |
| 6, 8 e 10 | 0 / 1.200.000 em cada nível | 0 observado | 0 |

Todos os níveis e valores completos estão em
[`post_alignment_seed42/curves.csv`](post_alignment_seed42/curves.csv).
Zero observado não significa BER verdadeira nula.

![BER do integrador](post_alignment_seed42/ber.svg)

### Verificação analítica do simulador

Para cada bit da waveform fixa, `D` é a soma da primeira metade menos a segunda.
Seu ruído tem variância `sps*sigma²`. A probabilidade condicional de erro é
`Q((2b−1)*D / (sigma*sqrt(sps)))`. Como os ruídos dos bits não se sobrepõem,
o erro por quadro esperado é `1−produto(1−p_bit)`.

Essa é uma previsão **condicional ao sinal capturado**, usando TX somente como
rótulo de avaliação, não uma medição da BER física nem um detector com informação
privilegiada. Não se aplica à seleção/rejeição de alinhamento do experimento 2.

O maior desvio observado versus essa previsão foi aproximadamente **1,74 desvios
padrão de Monte Carlo condicionais**. Isso valida a implementação do ensaio,
não a generalização do sistema para outros canais.

Uma segunda seed, 2026, com dez realizações/nível, confirmou a faixa de transição:
BER 0,0037525 em 0 dB e 0,0005025 em 2 dB. Os agregados estão em
[`post_alignment_seed2026/`](post_alignment_seed2026/summary.json). Realizações
de ruído de uma mesma sessão não são evidência adicional de diversidade física.

## 2. Ruído no RX bruto, antes da sincronização

O ruído continua sendo **numérico após o ADC**, mas antes de normalização e busca
do quadro. Reaplicam-se normalização de pico e busca completa assistida pelo TX,
mantendo limiar 0,5. O detector não usa BER para aceitar alinhamento.

Na varredura refinada, dez realizações/nível produziram 1.000 tentativas virtuais
por nível. A potência de referência é a do registro bruto, não a do recorte do
experimento anterior; os fluxos de ruído também diferem.

| R (dB) | Alinhamentos aceitos / tentativas | BER nas aceitas | Quadros exatos / todas as tentativas |
| --- | --- | --- | --- |
| −5 | 0 / 1.000 | Desconhecida | 0 |
| −4 | 151 / 1.000 | 0,031192 | 0 |
| −3 | 989 / 1.000 | 0,024340 | 0 |
| −2 | 1.000 / 1.000 | 0,0138775 | 0,004 |
| 0 | 1.000 / 1.000 | 0,00338 | 0,271 |
| 2 | 1.000 / 1.000 | 0,0005325 | 0,805 |
| 5 | 1.000 / 1.000 | 0,0000025 | 0,999 |

Detalhes: [`pre_sync_transition_seed42/`](pre_sync_transition_seed42/summary.json).
A primeira varredura, com cinco realizações, está em
[`pre_sync_seed42/`](pre_sync_seed42/summary.json), incluindo −10 dB sem aceitação.

![Disponibilidade versus ruído](pre_sync_transition_seed42/availability.svg)

**Não interpretar BER baixa nas aceitas como alta disponibilidade.** A busca
seleciona uma janela entre possíveis repetições e rejeita por score; isso muda
a distribuição condicional. Não comparar diretamente as BERs dos experimentos
1 e 2 como ganho de um detector. O limiar não foi calibrado com teste independente.
Nenhuma dessas métricas representa entrega clínica por CRC.

## 3. Comparação neural: software pronto, evidência real pendente

`benchmark_detectors.py` foi implementado e exercitado com sessões sintéticas.
Inclui integrador, template casado de médias de classe, ridge contextual e CNN,
com treino opcional sob AWGN. Ridge/CNN compartilham janelas e realizações de
treino, ajuste só em validação e entradas de teste pareadas. O template usa as
médias de classe do treino sem ruído adicional; não é FIR/MMSE/DFE completo.

O benchmark **recusou corretamente treinar o piloto real**, antes de criar modelos,
porque não existem sessões físicas independentes de treino/validação/teste.
Não se repartiu o piloto nem se declarou ganho neural. Bootstrap pareado por
sessão está implementado, sem intervalo quando há menos de duas sessões de teste.

## 4. Conclusão e próximo bloqueio

O AWGN controlado produz uma faixa mensurável de degradação e o simulador foi
verificado contra a previsão do integrador. **Isso não comprova vantagem de ML.**

A faixa inicial útil para comparar detectores fica aproximadamente entre −6 e
5 dB desta razão de referência; é uma decisão exploratória feita no piloto,
não um resultado de desempenho de teste. A condição sem ruído deve continuar
incluída para verificar não degradação.

O próximo passo que exige bancada é coletar **sessões independentes sem ruído
adicional**, documentadas em [`../../CAMPANHA_BANCADA.md`](../../CAMPANHA_BANCADA.md).
Não é necessário introduzir ruído físico ou conectar dispositivos médicos.

Ambiente CPU e comandos de reprodução estão em [`../../README.md`](../../README.md)
e [`../../ROADMAP.md`](../../ROADMAP.md). Pastas completas em `runs/` e `data/`
são ignoradas pelo Git e precisam de backup. Este relatório compacto não as substitui.
