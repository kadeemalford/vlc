# Relatório FINEP 2026: prova de conceito e resultados obtidos

**Autores:** Breno Viana, Higor Camporez, Jair Silva e João Pesente  
**Data:** 7 de julho de 2026  
**Fonte:** transcrição normalizada de `FINEP_2026.pdf`. Figuras são mantidas como referências textuais; o PDF original permanece como fonte para sua representação visual.

## 1. Introdução

A indústria offshore de petróleo e gás necessita de tecnologias robustas para monitoramento, automação e segurança em ambiente submarino. Métodos convencionais de comunicação por radiofrequência sofrem forte atenuação devido à salinidade e à pressão. A comunicação por luz visível (VLC), particularmente a comunicação óptica sem fio subaquática (UVLC), é uma alternativa para transmitir dados de sensores instalados em equipamentos críticos, como risers e árvores de natal, para ROVs durante inspeções.

VLC pode reduzir conexões físicas, recuperação de equipamentos à superfície, tempo de inspeção e operações com mergulhadores. A tecnologia é compacta, integrável a sensores e aplicável em ambientes classificados.

## 2. Revisão do estado da arte

VLC utiliza LEDs ou diodos laser para transmissão sem fio em luz visível, aproximadamente entre 380 nm e 780 nm. Oferece baixo custo, baixo consumo e potencial de alta taxa de dados, complementando comunicações por RF e acústicas em ambiente subaquático.

Para UVLC, LEDs azul-esverdeados ou azul royal entre 450 nm e 500 nm apresentam menor atenuação e boa dispersão. A Figura 1 do relatório compara a dispersão de LEDs azul e branco e indica melhor adequação do azul ao cenário considerado.

Experimentos publicados apresentam o compromisso entre distância, taxa e confiabilidade. Em água controlada e distâncias de 1 a 10 m, há resultados de Mbps até Gbps. Em água com impurezas ou cenários de porto, a taxa tende a dezenas de Mbps e a BER fica tipicamente entre `10^-3` e `10^-4`. Em enlaces acima de 25 m, taxas reportadas são em geral inferiores a 20 Mbps.

| Distância | Taxa | BER | Fonte | Comprimento de onda | Detector | Canal |
| --- | --- | --- | --- | --- | --- | --- |
| 50 m | 2,28 Mbps | - | LED azul, 10 W ópticos | 470 nm | APD | Piscina olímpica |
| 2,5 m | 58 Mbps | 0 | LED azul, 10,5 W elétricos | 470 nm | APD | Água muito pura |
| 10 m | 25 Mbps | `1,0 x 10^-4` | LED azul | 448 nm | APD | Água de torneira |
| 1,2 m | 3 Gbps | `3,8 x 10^-3` | LED azul, 120 mW ópticos | 446,4 nm | PIN | Água de torneira |
| 10 m | 1 Mbps | `2,9 x 10^-3` | LED azul, 10,07 mW ópticos | 445 nm | APD | Água de torneira |
| 28 m | 20 Mbps | `10^-4` | LED azul, 600 mW ópticos | 470 nm | SiPM | Água clara |
| 10 m | 140 Mbps | 0 | LED azul, 1,9 W ópticos | 451 nm | APD | Água para gramado |

### 2.1 Modelagem de canal

Para ar, a potência recebida é modelada por:

```math
P_r = \frac{m+1}{2\pi}\frac{A\cos\psi}{d^2}\cos^m\phi\,T_s(\psi)g(\psi)P_t
```

onde `m` é a ordem Lambertiana, `A` é a área do fotodetector, `d` a distância, `psi` o ângulo de incidência, `phi` o ângulo de emissão, `T_s` a transmissão do filtro e `g` o ganho do concentrador óptico.

No meio subaquático, o coeficiente de atenuação da água é estimado pela razão entre as alturas de olho em ar (`H_a`) e água (`H_w`):

```math
\frac{H_a}{H_w}=\exp(c_wd), \qquad c_w=\frac{1}{d}\ln\left(\frac{H_a}{H_w}\right)
```

As alturas de olho são modeladas como:

```math
H_w=K_gK_o\exp(-c_wd)\mathcal{R}MR(P_{t1}-P_{t0})
```

```math
H_a=K_gK_o\mathcal{R}MR(P_{t1}-P_{t0})
```

`K_g` e `K_o` representam atenuações geométrica e óptica; `mathcal{R}` é a responsividade; `M`, o ganho de avalanche; e `R`, o ganho de transimpedância.

## 3. Caracterização do LED

Foi selecionado o LED azul CREE XLAMP XM-L2, de 9 W, com pico espectral próximo de 450 nm. A escolha segue a faixa de menor absorção e espalhamento considerada adequada para UVLC.

| Característica | Unidade | Típico ou máximo |
| --- | --- | --- |
| Resistência térmica junção-solda | °C/W | 0,75 |
| Ângulo de visão (FWHM) | graus | 120 |
| Coeficiente térmico de tensão | mV/°C | -1,3 |
| Corrente direta DC | mA | 3000 |
| Tensão reversa | V | 1 |
| Tensão direta a 700 mA e 85 °C | V | 2,72 a 3,15 |
| Temperatura de junção | °C | 150 |

A distribuição espacial indica redução de 50% da potência aproximadamente a 60°. A elevação de temperatura reduz o fluxo luminoso relativo.

Os dados experimentais de iluminância versus corrente revelaram não linearidade a partir de 500 mA. O modelo adotado foi:

```math
P_{led}=\frac{I_{led}}{\left[\zeta+\left(\frac{I_{led}}{P_{max}}\right)^{2k}\right]^{1/(2k)}}
```

Para a distância de 0,2 m, o ajuste MATLAB estimou `zeta = 0,4222`, `k = 0,4045` e `Pmax = 3979`, com RMSE de 16,7 lux, ou 0,9% da iluminância máxima medida.

## 4. Setup experimental

O setup inicial opera em espaço livre, usando ar como canal, e compara dois receptores. O processamento é:

```text
Dados -> Manchester -> superamostragem/formatação de pulso -> AFG
      -> amplificador -> Bias-Tee -> LED -> canal AWGN
      -> fotodiodo/TIA -> subamostragem -> decisão -> decodificador Manchester
```

### 4.1 Modulação e processamento

Os bits de entrada são codificados em Manchester para garantir transições e sincronização. O sinal é superamostrado, gerado no MATLAB e convertido para analógico pelo AFG do osciloscópio. O Bias-Tee soma uma corrente DC para manter o LED em uma região operacional útil. No receptor, o fotodiodo e o amplificador de transimpedância geram o sinal elétrico; subamostragem, decisão por limiar e decodificação Manchester recuperam os dados.

### 4.2 Transmissor

O transmissor usa amplificador Juntek DPA-2698, faixa de 0 a 10 MHz, ganho de amplitude de 2x e 5 W por canal. O Bias-Tee Picosecond Pulse Labs 5575A acopla RF e polarização DC. O emissor é composto por dissipador térmico, resistor limitador e LED azul.

### 4.3 Canal

Foram variadas distância e corrente DC. Para o PIN OSRAM SFH2400-Z, a distância foi de 1 a 7 m; para o receptor Hyperion, de 1 a 5 m. A corrente DC variou de 100 a 800 mA.

### 4.4 Receptores

O receptor PIN OSRAM SFH2400-Z possui área fotossensível reduzida e usa lentes biconvexas no transmissor e no receptor para aumentar o alcance, ao custo de maior necessidade de alinhamento. O receptor Hyperion possui fotodiodo de área maior, dispensa lentes externas e oferece maior ângulo de visão, porém maior capacitância e menor largura de banda. Ambos incluem amplificador de transimpedância.

### 4.5 Resposta em frequência

Com ambos os receptores, a largura de banda observada a -3 dB é aproximadamente 2 MHz, limitada principalmente pelo LED.

## 5. Resultados

### 5.1 Parametrização

A penalidade de abertura do olho (EOP) é:

```math
EOP_{dB}=10\log_{10}\left(\frac{A_{ideal}}{A_{eye}}\right)
```

Foram testadas amplitudes do AFG de 0,5 a 3 V e correntes de polarização de 100 a 800 mA. Para o Hyperion, a melhor condição foi AFG de 3 V e `I_bias` de 500 mA, com EOP aproximada de 1,9 dB. Para o PIN, foi AFG de 3 V e `I_bias` de 400 mA, com EOP aproximada de 2,3 dB.

Em alguns pontos, ocorreu saturação do transmissor ou receptor. Embora tenha produzido abertura de olho visualmente maior em determinadas condições, não representa o regime físico desejável. Com o PIN, correntes de 500 a 800 mA em condições saturadas não permitiram recuperar sinal.

| `I_bias` (mA) | Hyperion saturado: AFG/EOP dB | Hyperion não saturado: AFG/EOP dB | PIN saturado: AFG/EOP dB | PIN não saturado: AFG/EOP dB |
| --- | --- | --- | --- | --- |
| 100 | 1,5 / 2,61 | 0,5 / 4,01 | 1,0 / 2,60 | 0,5 / 2,84 |
| 200 | 2,0 / 2,50 | 1,0 / 3,76 | 2,0 / 2,61 | 1,0 / 2,92 |
| 300 | 2,5 / 2,46 | 1,0 / 4,28 | 2,5 / 2,70 | 1,5 / 2,95 |
| 400 | 3,0 / 2,10 | 1,0 / 4,14 | 3,0 / 2,31 | 2,0 / 2,92 |
| 500 | 3,0 / 1,87 | 1,0 / 4,55 | - | 2,5 / 2,98 |

### 5.2 Impacto da distância

O relatório correlaciona EOP, fator Q e BER. EOP até 6 dB corresponde a enlace de alta confiabilidade, com BER da ordem de `10^-6`; de 6 a 15 dB é zona de transição; de 15 a 20 dB aproxima o limiar de BER `10^-3` para FEC; acima de 20 dB o enlace é considerado inviável.

Com Hyperion saturado, a transmissão foi robusta até aproximadamente 2 m e alguns pontos permaneceram abaixo do limiar de BER `10^-3` a 4 m. Sem saturação, o enlace se tornou inviável a 3 m. Com o PIN e lentes, tanto com quanto sem saturação, o sistema manteve EOP baixa até 7 m. O pior caso saturado, 100 mA em 7 m, apresentou EOP de 3,26 dB e BER estimada de `1,69 x 10^-17`; sem saturação, o pior caso teve EOP de 4,15 dB e BER de `1,02 x 10^-8`.

## 6. Conclusão

O estudo validou, em ar, o uso de VLC como base para futura UVLC. O LED CREE XLAMP XM-L2 apresentou adequação à aplicação, e o receptor PIN com lentes teve desempenho superior ao Hyperion: comunicação confiável até 7 m, contra aproximadamente 4 m. Os próximos testes devem introduzir meio aquático, turbidez e sedimentos.

## Apêndice A: métricas de qualidade

O fator Q é calculado a partir das médias e desvios padrão dos níveis lógicos:

```math
Q=\frac{\mu_1-\mu_0}{\sigma_1+\sigma_0}
```

A BER estimada sob AWGN é:

```math
BER=\frac{1}{2}\operatorname{erfc}\left(\frac{Q}{\sqrt{2}}\right)
```

Para SNR de 10 dB, o relatório indica BER entre `10^-5` e `10^-6` no sistema Manchester analisado.

## Referências principais

1. Ghassemlooy, Popoola e Rajbhandari. *Optical Wireless Communications System and Channel Modelling with MATLAB*. CRC Press, 2019.
2. Camporez. *AI-Based Strategies for Handover Enhancement in Visible Light Communication Systems*. Tese de doutorado, UFES, 2025.
3. Elgala, Mesleh e Haas. “An LED model for intensity-modulated optical communication systems.” *IEEE Photonics Technology Letters*, 2010.
4. van der Zwaag et al. “A Manchester-OOK visible light communication system for patient monitoring in intensive care units.” *IEEE Access*, 2021.
5. Kong et al. “Real-time optical-wireless video surveillance system for high visual-fidelity underwater monitoring.” *IEEE Photonics Journal*, 2022.
6. Zhang et al. “Real-time underwater wireless optical communication and positioning an integrated system based on angular diversity SiPMs.” *Optics Letters*, 2024.
7. Li et al. “Demonstration of a real-time UWOC system using a bandwidth limited LED based on hardware and software equalization.” *Journal of Lightwave Technology*, 2023.
