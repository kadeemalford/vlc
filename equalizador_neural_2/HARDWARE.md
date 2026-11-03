# Referências de hardware e confirmação presencial

Consultadas em 03/11/2026. Valores de publicações/código não são leituras da
montagem atual nem autorização para alterar corrente ou amplitude.

## Fonte principal: Camporez (2025), capítulo 4

Arquivo local: `../bibliography/Camporez__2025___Thesis (40).pdf`.
Páginas abaixo são as impressas na tese, não os índices do leitor PDF.

- Seção 4.2, pp. 39–41: LED CoB CREE CXA1507, 5000 K, potência citada de até
  13,5 W, montado com dissipador. Caracterização de corrente entre 50 e 450 mA;
  isso não define uma faixa segura para a montagem atual.
- Seção 4.3, pp. 40–42: Tektronix MDO3012 → Juntek DPA-2698 (ganho citado de
  6 dB) → Bias-Tee Picosecond Pulse Labs 5575A → LED → receptor comercial
  Hyperion VLC → MDO3012. A tese não fornece ali um ganho transimpedância
  selecionado ou modelo detalhado do Hyperion suficiente para preencher a sessão.
- P. 41: ensaios com polarização de 100–300 mA e saída AFG de 0,5–4 Vpp;
  são condições daqueles ensaios, não valores recomendados para este piloto.
- Figura 4.4(b), p. 42: resposta de frequência do enlace da tese. Não substitui
  uma medição do enlace atual. O experimento usa sinal NR de aproximadamente
  1 MHz centrado em 0,75 MHz, diferente do Manchester desta iniciativa.

## README legado

`../vlc-system-matlab-alarm-care-pro-scripts/README.md`, seções 1.5 e 2:
documenta configuração de código com AFG 1 Vpp, offset zero, carga declarada Hi-Z,
RX AC/1 MΩ, registro de 10.000 pontos e alvo 10 MS/s a 1 Mbps.

O receptor “ex.: Thorlabs PDA” da seção 5 é genérico, não identificação da bancada.
Normalização digital não garante linearidade do LED, e acoplamento AC não elimina
ruído de luz ambiente nem impede saturação anterior ao osciloscópio. Não usar essas
afirmações do README como evidência de caracterização física.

## Capacidade do AFG: fonte oficial Tektronix

[Guia oficial da série MDO3000, p. 17](https://download.tek.com/document/48W_30076_0_HR.pdf):
AFG opcional, taxa arbitrária de 250 MS/s, memória de 128 kpoints; até 50 MHz
para seno e 25 MHz para quadrada/pulso. Faixas de amplitude citadas de 10 mV–2,5 Vpp
em 50 Ω e 20 mV–5 Vpp em Hi-Z, com ressalva de variação por modelo.

Esses limites não demonstram banda útil do VLC nem fidelidade de qualquer arquivo
arbitrário. `10*bit_rate` no nosso código é a grade temporal desejada das amostras
enviadas, não uma consulta ao clock interno do DAC. A configuração de carga Hi-Z
não significa impedância física de saída infinita; tensão efetiva depende da carga.

## Antes da primeira transmissão

Confirmar localmente: corrente efetiva da fonte, amplitude/offset/carga declarada
do AFG, presença/configuração do amplificador, identificação/configuração do Hyperion,
distância, canal, escala vertical, trigger e ausência de clipping. Não preencher
esses campos copiando faixas da tese. Primeiro identificar a sessão MATLAB aberta;
não inicializar instrumentos apenas para descobrir se já estão conectados.
