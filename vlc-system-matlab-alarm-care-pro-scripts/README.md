# Documentação de Parâmetros e Especificações VLC: `real_time_mae_vlc.m`

Este documento fornece uma parametrização detalhada e completa da camada física e de enlace do sistema de comunicação por luz visível (**VLC - Visible Light Communication**) integrado ao ecossistema de monitoramento clínico **Alarm Care Pro**.

O script principal analisado é [real_time_mae_vlc.m](src/scripts/alarm-care-pro/real_time_mae_vlc.m), apoiado pela infraestrutura da pasta [`src/main/`](src/main/).

---

## 🏗️ Visão Geral da Arquitetura do Sistema

O sistema opera em tempo real capturando telemetria de equipamentos médicos (monitores multiparamétricos, ventiladores pulmonares e bombas de infusão), empacotando os dados em quadros compactos e transmitindo-os por um enlace óptico sem fio (VLC) utilizando o osciloscópio/gerador **Tektronix MDO3012**.

```
+-----------------------------------------------------------------------------------+
|                              FLUXO DE DADOS EM TEMPO REAL                         |
+-----------------------------------------------------------------------------------+
|  [ Dispositivos Médicos / TCP ] (Portas 2222, 23000, 22001-22003)                 |
|                               ↓                                                   |
|  [ Parsers HL7 & Binários ]  (mae_handlers.m -> mae_frame.m)                      |
|                               ↓                                                   |
|  [ Fila FIFO de Mensagens ]   (fifoPush / fifoPopBatch - máx 58 chars)            |
|                               ↓                                                   |
|  [ Codificador Manchester ]   (ManchesterOokEncoder.m - 1 Mbps, 10 MSps)          |
|                               ↓                                                   |
|  [ AFG do Tektronix MDO3012 ] (Upload ASCII via VISA/SCPI - 1.0 Vpp High-Z)       |
|                               ↓                                                   |
|  [ Circuito Bias-Tee + LED ]  (Sinal Óptico Modulado em Luz Visível)             |
|                               ↓                                                   |
|                       === CANAL ÓPTICO (LOS) ===                                  |
|                               ↓                                                   |
|  [ Fotodetector (PD) ]        (Recepção Óptica com Acoplamento AC)                |
|                               ↓                                                   |
|  [ Canal CH1/CH2 MDO3012 ]    (Aquisição 10 MSps, 10k pontos int8 RIBinary)       |
|                               ↓                                                   |
|  [ Processamento MATLAB ]     (Reamostragem, Sincronização xcorr, Inversão RMS)   |
|                               ↓                                                   |
|  [ Decodificador Manchester ] (Integrador intdump, Comparação Pareada)            |
|                               ↓                                                   |
|  [ Frontend / Dashboard ]     (mae_frontend.m -> Exibição Clínica & Métricas)     |
+-----------------------------------------------------------------------------------+
```

---

## 1. 📡 Transmissor (Geração do Sinal)

### 1.1 Esquema de Modulação
* **Modulação de Banda Base:** **Manchester OOK** (*On-Off Keying* com Codificação Manchester).
* **Mapeamento de Bits** ([ManchesterOokEncoder.m](src/main/model/encoders/manchesterook/ManchesterOokEncoder.m)):
  * Bit `0` $\rightarrow$ Níveis `[-1, 1]` (transição ascendente no meio do símbolo).
  * Bit `1` $\rightarrow$ Níveis `[1, -1]` (transição descendente no meio do símbolo).
* **Vantagens no VLC:** Elimina componente DC variante conforme o conteúdo da mensagem e garante constante transição de relógio (*clock recovery* simplificado e prevenção de cintilação visível / *flicker*).

### 1.2 Taxas de Bits, Símbolos e Amostragem
* **Taxa de Bits ($R_b$):** $1\,\text{Mbps}$ ($1000 \times 10^3\,\text{bps}$) ([ManchesterOokParameters.m](src/main/model/config/manchesterook/ManchesterOokParameters.m)).
* **Tempo de Bit ($T_b$):** $1 / R_b = 1,0\,\mu\text{s}$.
* **Tempo de Símbolo ($T_s$):** $1,0\,\mu\text{s}$ (1 bit por símbolo).
* **Eficiência Espectral / Bits por Símbolo:** $1\,\text{bit/símbolo}$.
* **Largura de Banda Teórica ($B$):** $2 \times R_b = 2,0\,\text{MHz}$ (devido às transições na metade do símbolo Manchester).
* **Amostras por Símbolo (`resampleFactor` / $sps$):** $10$ amostras/bit ($5$ amostras por meia-fase de $0,5\,\mu\text{s}$).
* **Taxa de Amostragem do Transmissor ($f_{txSample}$):** $10\,\text{MSps}$ ($10\,\text{MHz}$), com tempo de amostragem $T_{txSample} = 100\,\text{ns}$.

### 1.3 Pulse Shaping
* **Filtro Forma de Pulso:** Pulso **Retangular** gerado por `rectpulse(manchesterBits, resampleFactor/2)`.
* Não são utilizados filtros SRRC (*Square Root Raised Cosine*) ou `rcosdesign` no transmissor base.

### 1.4 Estrutura da Trama (Framing & Payload)
1. **Cabeçalho de Nível Físico** (em `stringToBits` no [real_time_mae_vlc.m](src/scripts/alarm-care-pro/real_time_mae_vlc.m)):
   * **Campo de Comprimento:** 8 bits (1 byte) transmitido MSB-first indicando a quantidade $N$ de caracteres ASCII no quadro.
   * **Carga Útil ASCII:** $N \times 8$ bits (cada caractere em 8 bits MSB-first).
2. **Formato do Chunk Legado** (`!#<EQ><KIND><ABBR><DATA>`, máx 10 chars, [mae_frame.m](src/scripts/alarm-care-pro/mae_frame.m)):
   * `Preâmbulo`: `!#` (2 caracteres).
   * `EQ`: Identificador do equipamento (`M` = Monitor, `V` = Ventilador, `1`/`2`/`3` = Bombas 1/2/3).
   * `KIND`: `D` (Dado numérico de variável clínica) ou `A` (Alarme clínico).
   * Exemplo de Dado: `!#MDHR0090` (Monitor, Heart Rate = 90 bpm).
   * Exemplo de Alarme: `!#VAMX11` (Ventilador, Pressão Máxima Ativa).
3. **Empacotamento Multi-Chunk (Multiplexação)**:
   * Vários chunks são concatenados com o caractere delimitador `'|'` (ex.: `!#MDHR0090|!#VAMX11|!#1A07`).
   * Tamanho máximo configurado: `MAX_FRAME_CHARS = 58` caracteres por transmissão VLC.
4. **Codificação de Canal / CRC:** Não há inserção de bits de paridade, CRC ou FEC na camada física; a integridade é avaliada por casamento estrito do formato de quadro (`!#`) e decodificação sintática.

### 1.5 Níveis de Tensão na Geração
* **Amplitude Pico a Pico do AFG:** $1,0\,\text{V}_{pp}$ (`obj.setAfgAmplitude(1)`).
* **Offset DC do AFG:** $0,0\,\text{V}$ (`obj.setMdoAfgOffset(0)`).
* **Normalização Digital:** A função `SignalUtils.normalizeSignal` divide todos os pontos pelo valor máximo absoluto do vetor ($\max(|x[n]|)$), garantindo amplitude unitária $[-1, +1]$ antes do envio ao gerador.

---

## 2. 🎛️ Osciloscópio / Gerador (Tektronix MDO3012)

A interface física com o hardware é implementada na classe [Mdo3012Analyzer.m](src/main/model/logicanalizers/Mdo3012/Mdo3012Analyzer.m).

### 2.1 Taxa de Amostragem e Janela de Aquisição
* **Geração (AFG):** $10\,\text{MSps}$ ($10\,\text{MHz}$), ajustado dinamicamente via comando `AFG:PERIOD`.
* **Aquisição (Osciloscópio):** $10\,\text{MSps}$ ($10\,\text{MHz}$).
* **Comprimento do Registo (Record Length):** $10.000$ pontos (10k) (`HORizontal:RECOrdlength 10000`).
* **Escala Horizontal de Tempo:** `timeHorizontalScale = 10000 / 10 / 10e6 = 100 µs/div` (10 divisões visuais = 1,0 ms de janela total de captura).
* **Capacidade de Bits por Registro:** $\approx 500$ bits recomendados por janela (`bufferSize / resampleFactor / 2`).

### 2.2 Escalas Verticais, Resolução e Impedância
* **Resolução Vertical de Aquisição:** 8 bits (`DATa:WIDth 1`, formato binário com sinal `int8` retornado pelo comando `CURVe?`).
* **Impedância de Saída do AFG:** High-Z (`AFG:OUTPut:LOAd:IMPEDance HIGHZ`).
* **Impedância de Entrada dos Canais (CH1 / CH2):** $1\,\text{M}\Omega$ (`CHx:TERmination MEG`).
* **Acoplamento dos Canais:** **AC** (`CHx:COUPling AC`), eliminando ruído contínuo e luz ambiente.

### 2.3 Modo de Controle e Trigger
* **Modo de Aquisição:** Execução contínua (`ACQuire:STOPAfter RUN`, `ACQuire:STATE 1`).
* **Atraso de Tempo Desativado:** `HORizontal:DELay:MODe OFF` e `HORizontal:FAST:ACQuire OFF` garantem capturas determinísticas sem congelamento de quadros anteriores.
* **Sincronização de Bloco:** A sincronização da trama não depende de trigger de hardware do osciloscópio, sendo realizada via software por correlação cruzada no MATLAB.

### 2.4 Comandos SCPI / VISA Utilizados no Código

| Função no Código | Comando SCPI / VISA | Descrição |
| :--- | :--- | :--- |
| `initiateDefaultConnection` | `visa('NI'/'TEK', resourceName)` | Inicializa a sessão VISA (buffer 1 MB). |
| `setMdoAfgOutputState` | `AFG:OUTPut:STATE ON` | Habilita a saída do gerador de funções. |
| `setMdoAfgImpedance` | `AFG:OUTPut:LOAd:IMPEDance HIGHZ` | Configura impedância do AFG para Alta Impedância. |
| `setMdoAfgFunction` | `AFG:FUNC ARBITRARY` | Define modo de forma de onda arbitrária. |
| `setAfgAmplitude` | `AFG:AMPLitude 1.0` | Define amplitude do AFG em $1,0\,\text{V}_{pp}$. |
| `writeSamples` | `AFG:PERIOD <val>` | Ajusta o período total do sinal arbitrário enviado. |
| `writeSamples` | `AFG:ARBitrary:EMEM:POINTS <csv>` | Faz upload dos pontos normalizados em formato ASCII CSV. |
| `readSamples` | `DATa:SOUrce CH1` / `DATa:ENCdg RIBinary` | Seleciona o canal e define codificação binária `int8`. |
| `readSamples` | `WFMPre:NR_Pt?` / `WFMPre:XINcr?` | Consulta tamanho da onda e intervalo de amostragem $\Delta t$. |
| `readSamples` | `CURVe?` $\rightarrow$ `readBinBlock()` | Solicita e lê o bloco de dados binários (IEEE 488.2). |

---

## 3. 💡 Bias-Tee e LED (Frente Transmissora Óptica)

Os parâmetros do circuito elétrico e óptico de transmissão condicionam o sinal elétrico antes da emissão de luz:

* **Tensão / Corrente DC de Polarização ($V_{DC}, I_{DC}$):** Aplicada externamente pela fonte de alimentação conectada à porta DC do Bias-Tee. Determina o ponto de operação (*Q-point*) no centro da região linear da curva característica I-V / L-I do LED.
* **Amplitude AC ($V_{AC}$):** O sinal proveniente do AFG do MDO3012 é injetado na porta AC do Bias-Tee com $1,0\,\text{V}_{pp}$.
* **Índice de Modulação ($m$):** Definido pela razão entre a excursão AC e o nível DC ($m = V_{AC} / V_{DC}$). Deve ser ajustado para $m < 1,0$ para evitar que o LED entre na região de corte (desligamento) ou saturação.
* **Garantia de Linearidade no Código:** A função `SignalUtils.normalizeSignal` impede que picos matemáticos ultrapassem $\pm 1,0$, prevenindo distorção por saturação digital antes do LED.

---

## 4. ☀️ Canal Óptico (VLC)

Embora as condições do canal óptico dependam do ambiente físico de bancada, a arquitetura do código prevê a mitigação das seguintes variáveis:

* **Geometria do Enlace:** Enlace óptico direto (*Line-of-Sight* - LOS).
* **Distância e Alinhamento:** Distância típica de teste de $20\,\text{cm}$ a $1,5\,\text{m}$ alinhada no eixo óptico emissor-receptor.
* **Luz Ambiente:** Iluminação fluorescente ou solar do laboratório gera um componente DC de alta intensidade, o qual é totalmente filtrado na recepção pelo acoplamento **AC** (`MdoCouplingEnum.AC`) do osciloscópio.

---

## 5. 🔌 Receptor (Fotodetector)

* **Dispositivo Receptor:** Módulo Fotodetector (ex.: Thorlabs PDA series / Si PIN Photodiode).
* **Acoplamento na Aquisição:** **AC** (`MdoCouplingEnum.AC`), eliminando o valor médio do sinal óptico e mantendo apenas a variação modulada.
* **Impedância de Carga na Aquisição:** $1\,\text{M}\Omega$ (`MdoTerminationEnum.MEG`), maximizando a sensibilidade de tensão na entrada do MDO.
* **Prevenção de Saturação:** O ganho do fotodetector (V/A) e a escala vertical (V/div) do osciloscópio devem ser ajustados para que o sinal recebido ocupe entre 50% e 80% da escala total dos 8 bits do MDO (prevenindo o corte / *clipping* das cristas do sinal).

---

## 6. 💻 Processamento de Sinal no MATLAB

O fluxo de processamento de recepção é executado iterativamente pela classe [System1tx1rx.m](src/main/model/system/system1tx1rx/System1tx1rx.m) e utilitários em [SignalUtils.m](src/main/model/utils/SignalUtils.m):

```
[ Sinal Bruto int8 do Osciloscópio ]
               │
               ▼
[ 1. Normalização de Pico: x / max(|x|) ]
               │
               ▼
[ 2. Reamostragem (resample) para 10 MSps caso fs_rx ≠ fs_tx ]
               │
               ▼
[ 3. Sincronização por Correlação Cruzada: alignsignals(tx, rx) ]
               │
               ▼
[ 4. Verificação de Inversão de Fase RMS: RMS(tx - rx) vs RMS(tx + rx) ]
               │
               ▼
[ 5. Filtro Adaptado / Integrador: intdump(samples, resampleFactor/2) ]
               │
               ▼
[ 6. Decisão Pareada Manchester: reshaped(1,:) > reshaped(2,:) ]
               │
               ▼
[ 7. Conversão de Bits para String & Parse de Frames HL7 / Alarmes ]
```

### 6.1 Pré-processamento e Reamostragem
1. **Normalização:** O sinal recebido `rxSignal` é normalizado pela amplitude máxima: $x_{norm}[n] = x[n] / \max(|x[n]|)$.
2. **Reamostragem (`resampleSignalToMatchSampleRate`):** Caso a taxa de amostragem lida do osciloscópio difira da taxa do transmissor ($10\,\text{MSps}$), é aplicada a função `resample` do MATLAB utilizando aproximação racional por `rat`.

### 6.2 Sincronização e Inversão de Polaridade (`synchronizeSignals`)
1. **Estimativa de Atraso (*Lag*):** Utiliza a função `alignsignals(tx, rx)` baseada em correlação cruzada ($R_{xy}[\tau]$) para determinar o deslocamento exato da trama no tempo.
2. **Recorte da Janela Util:** Extrai o segmento `shiftedSamples` de comprimento exato igual ao sinal transmitido.
3. **Correção de Inversão de Fase (Polaridade):**
   $$\text{Se } \text{RMS}(x_{tx} - x_{rx}) > \text{RMS}(x_{tx} + x_{rx}) \implies x_{rx\_corr} = -x_{rx}$$
   Isso garante que inversões de fase causadas por estágios amplificadores do fotodetector não corrompam a decodificação lógica.

### 6.3 Filtro Adaptado e Demapeamento Manchester ([ManchesterOokDecoder.m](src/main/model/decoders/manchesterook/ManchesterOokDecoder.m))
1. **Filtro Integrador (`intdump`):**
   ```matlab
   integratedSamples = intdump(samples, resampleFactor / 2);
   ```
   Integra $5$ amostras para cada meia-fase do bit Manchester, atuando como filtro adaptado para pulso retangular.
2. **Decisão Pareada de Limiar:**
   ```matlab
   reshapedSamples = reshape(integratedSamples, 2, length(integratedSamples)/2);
   bits = double(reshapedSamples(1, :) > reshapedSamples(2, :));
   ```
   * Se a integração do $1^o$ meio-símbolo for maior que a do $2^o$, decide Bit `1` (padrão `10`).
   * Se for menor, decide Bit `0` (padrão `01`).
   * **Vantagem:** Limiar adaptativo diferencial inerente, sem necessidade de calcular limiar fixo de tensão.

---

## 7. 📊 Métricas de Caracterização e Desempenho

O sistema calcula continuamente métricas físicas e de enlace para garantir a qualidade do link óptico:

### 7.1 Bit Error Rate (BER)
* Calculado em `System1tx1rx.m` utilizando a função nativa `biterr(txBits, rxBits)`.
* Avalia a razão entre bits incorretos e o total de bits transmitidos no frame.

### 7.2 Fator Q (Q-Factor)
Calculado na classe [EyeDiagramUtils.m](src/main/model/utils/EyeDiagramUtils.m) e encapsulado em [QFactor.m](src/main/model/utils/eyeDiagram/QFactor.m):
$$Q = \frac{\mu_1 - \mu_0}{\sigma_1 + \sigma_0}$$
Onde:
* $\mu_1, \mu_0$: Médias das amplitudes integradas correspondentes aos níveis lógicos `1` e `0`.
* $\sigma_1, \sigma_0$: Desvios padrão das amplitudes dos níveis lógicos `1` e `0`.

### 7.3 Diagrama de Olho (Eye Diagram)
* A função `EyeDiagramUtils.getSegments(signal, samplesPerSymbol, numSymbolsPerSegment)` fatiará a forma de onda em segmentos sobrepostos de 2 símbolos ($20$ amostras).
* Permite visualizar jitter temporal, ruído de amplitude e abertura vertical do olho.

### 7.4 Débito Útil (Throughput) e Latência
* **Intervalo de Envio:** `TX_INTERVAL_SEC = 0.01` s ($10\,\text{ms}$).
* **Carga Máxima por Frame:** $58$ caracteres ASCII ($\approx 472$ bits físicos transmitidos a $1\,\text{Mbps}$).
* **Tempo de Transmissão Física:** $< 0,5\,\text{ms}$ por quadro.
* **Latência Total Fim a Fim:** $< 100\,\text{ms}$ (incluindo empacotamento TCP, fila FIFO, transmissão VISA e renderização na interface).

---

## 📋 Tabela Resumo de Parâmetros Globais do Código

| Parâmetro | Valor no Código | Arquivo de Origem / Referência |
| :--- | :--- | :--- |
| **Esquema de Modulação** | Manchester OOK | `ManchesterOokEncoder.m` |
| **Taxa de Bits ($R_b$)** | $1,0\,\text{Mbps}$ ($1 \times 10^6\,\text{bps}$) | `ManchesterOokParameters.m` |
| **Tempo de Bit ($T_b$)** | $1,0\,\mu\text{s}$ | `ManchesterOokParameters.m` |
| **Largura de Banda ($B$)** | $2,0\,\text{MHz}$ | `ManchesterOokParameters.m` |
| **Amostras / Bit ($sps$)** | 10 amostras | `ManchesterOokParameters.m` |
| **Taxa Amostragem TX ($f_{tx}$)** | $10,0\,\text{MSps}$ | `ManchesterOokParameters.m` |
| **Taxa Amostragem RX ($f_{rx}$)** | $10,0\,\text{MSps}$ | `Mdo3012Analyzer.m` |
| **Tamanho do Registo (Record Length)** | $10.000$ pontos | `Mdo3012Analyzer.m` |
| **Escala Horizontal** | $100\,\mu\text{s/div}$ | `Mdo3012Analyzer.m` |
| **Amplitude do AFG** | $1,0\,\text{V}_{pp}$ | `real_time_mae_vlc.m` / `Mdo3012Analyzer.m` |
| **Impedância AFG / Scope** | High-Z / $1\,\text{M}\Omega$ | `Mdo3012Analyzer.m` |
| **Acoplamento no Osciloscópio** | **AC** | `Mdo3012Analyzer.m` |
| **Máximo de Chars por Frame** | 58 caracteres | `real_time_mae_vlc.m` |
| **Intervalo de Transmissão** | $0,01\,\text{s}$ ($10\,\text{ms}$) | `real_time_mae_vlc.m` |
| **Portas TCP Servidor** | 2222, 23000, 22001-22003 | `real_time_mae_vlc.m` |

---

## 🚀 Como Executar o Sistema VLC Real

1. Conecte o osciloscópio **Tektronix MDO3012** via cabo USB ao computador.
2. Certifique-se de que o driver **TekVISA** ou **NI-VISA** está instalado no sistema operacional.
3. Abra o MATLAB a partir da raiz do repositório.
4. Execute o script principal em modo físico ou demo:
   ```matlab
   % Execução em tempo real com canal físico e servidores TCP ativos:
   real_time_mae_vlc(false);

   % Execução em modo demonstração (utilizando arquivos de exemplo):
   real_time_mae_vlc(true, 30); % Executa por 30 segundos
   ```
5. Para encerrar a execução, pressione `CTRL+C` no console do MATLAB (os recursos VISA e servidores TCP serão liberados automaticamente pelos manipuladores `onCleanup`).
