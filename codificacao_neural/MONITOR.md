# Monitor somente — captura de frequência cardíaca/pulso

## Escopo e origem dos campos

Apenas o monitor de pesquisa, sem pacientes e sem controle de dispositivos.
O legado recebe o monitor como cliente TCP na porta **2222**. `mae_registry.m`
e `mae_handlers.m` distinguem:

| Campo | Identificador OBX-3 | OBX-4 | Frame compacto |
| --- | --- | --- | --- |
| HR, frequência cardíaca do ECG | `147842^MDC_ECG_HEART_RATE^MDC` | `1.7.4.147842` | `!#MDHR0080` |
| PR, taxa de pulso da oximetria | `149530^MDC_PULS_OXIM_PULS_RATE^MDC` | `1.3.1.149530` | `!#MDPR0080` |

Com dedo no sensor óptico, não presumir que o dado seja HR. Não converter PR
em HR nem preencher HR ausente com PR. Saturação de O2 e demais campos são ignorados.
Não é necessário produzir alterações deliberadas na frequência; usar leitura
voluntária estável, sem finalidade diagnóstica, conforme procedimentos institucionais.

A captura histórica `data_examples/capture_prolife_pro_12_filtered.pcapng` foi
inspecionada localmente apenas para estrutura do protocolo: 996 mensagens MSH,
996 envelopes `VT ... FS CR`, com mensagens dos dois campos. Esses números
não são uma coleta nova nem 996 leituras válidas da taxa selecionada. Não foram
copiados HL7, identificadores ou valores pessoais para documentação. Os códigos
do legado são referência para este monitor, não parser HL7 genérico universal.

## Antes de abrir o servidor

- Manter AFG desligado; esta etapa não usa o enlace óptico.
- Monitor e PC na rede de laboratório autorizada. Conferir o IPv4 do PC e o
  destino de envio configurado no monitor (IP do PC, porta 2222).
- Não iniciar `real_time_mae*`, gateway/UI, outro receptor ou servidor MATLAB
  na mesma porta. O coletor não fecha processos nem altera firewall/rede.
- Não enviar capturas de tela contendo nome/ID. O coletor salva só observações
  numéricas HR/PR e metadados mínimos, mas esses dados ainda podem ser pessoais.

## Primeira inspeção — sem exportar mensagem VLC

Após atualizar os arquivos no PC da bancada, abrir PowerShell em
`C:\Users\DELL\Documents\murilobarroso\vlc\codificacao_neural`.
Substituir `<IP_DO_PC>` pelo IPv4 da interface de laboratório, sem os sinais `< >`:

```text
.\.venv\Scripts\python.exe monitor_capture.py --listen --host <IP_DO_PC> --port 2222 --seconds 60 --signal inspect --out data/monitor_inspect_01
```

Use pasta nova. O script escuta por até 60 segundos e imprime somente HR/PR,
valor numérico ou motivo de rejeição; `inspect` não gera arquivos `.bin`.
Se ficar sem conexões, conferir configuração de destino do monitor, interface,
porta e regra autorizada de firewall. Não aumentar a duração para disfarçar
ausência de dados nem habilitar outros equipamentos. Ctrl+C registra interrupção.

Manifesto: estado, conexões, bytes recebidos, mensagens completas, sinais vistos,
rejeições, fragmentos TCP incompletos e frames exportados. `observations.jsonl`
não contém MSH/PID, timestamp do dispositivo, endereço remoto, nomes ou IDs.
Valores inválidos em texto também não são registrados em bruto.

## Exportar uma leitura real selecionada

Somente após confirmar o sinal na inspeção. Exemplo para PR do sensor de dedo:

```text
.\.venv\Scripts\python.exe monitor_capture.py --listen --host <IP_DO_PC> --port 2222 --seconds 60 --signal pulse_rate --max-samples 1 --out data/monitor_pulse_01
```

Para HR genuíno de ECG, usar `--signal heart_rate`. A exportação para após uma
observação selecionada elegível, gerando `monitor_000001.bin` (10 bytes ASCII)
e manifesto. Nenhum encoder ou instrumento é executado automaticamente.
Não repetir leituras até escolher um resultado conveniente; preservar tentativas
sem dados e valores rejeitados. Selecione apenas a taxa realmente disponível.

Exemplo de preparação posterior, para PR:

```powershell
.\.venv\Scripts\python.exe workflow.py encode --model runs/codec_seed42/model.pt --input data/monitor_pulse_01/monitor_000001.bin --out data/tx_monitor_pulse_01 --message-id 1001
```

O quadro de 10 bytes resulta em um pacote NC1 de **392 bits**, a confirmar na
saída. Usar outro ID/pasta para cada mensagem. Não enviar simultaneamente HR/PR
ou misturar origens: o estudo inicial usa uma única taxa selecionada.

## Critérios de aceitação e limites

- Framing obrigatório MLLP: VT + mensagem + FS CR. Segmentação/coalescência TCP
  são tratadas; mensagens incompletas nunca viram leituras completas. Reconexão
  inicia um buffer novo. Envelope malformado fecha só aquela conexão e é contado.
- Extrai somente IDs HR/PR conhecidos, tipo NM, unidade MDC de batimentos/minuto,
  status F ou C e sub-ID correspondente. Duplicidade da mesma taxa na mensagem
  é ambígua e não exportada.
- Exporta apenas inteiros de 1 a 9999 para não arredondar nem extrapolar o formato
  legado. Isso é **limite de representação, não faixa fisiológica nem validação
  clínica**. Decimais, zero, negativos e ausência são recusados e contabilizados;
  não convertidos para um valor fictício. Sentinelas específicas do monitor ainda
  precisam de conferência com o display/manual: elegibilidade sintática não prova
  contato do sensor ou qualidade da medição.
- Não envia bytes de aplicação, comandos, solicitação de medição ou ACK HL7.
  TCP ainda faz seus ACKs de transporte normalmente. Se o monitor exigir ACK HL7,
  poderá parar/retransmitir: não inventar respostas sem conferir o protocolo.
- Não deduplica retransmissões HL7 por ID porque não persiste tais IDs. Leituras
  repetidas não são prova de diversidade/independência; registrar essa limitação.
- Ainda não é fluxo online monitor → VLC. Capturar, preparar pacote e fazer replay
  físico são etapas separadas, com consentimento e backup dos dados locais.
- Tests de parser/framing aprovados offline; compatibilidade com o monitor ao vivo
  e regra de ACK ainda não validadas nesta versão.
