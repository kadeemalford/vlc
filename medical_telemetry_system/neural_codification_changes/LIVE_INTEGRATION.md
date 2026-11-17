# Integração online PR → VLC → gateway → painel

**Configuração vigente:** ver [MONITOR_VARIABLES.md](MONITOR_VARIABLES.md) para
HR/FC, SpO₂, PR e AFG contínuo; pressão foi retirada. PR-only foi confirmado
visualmente pelo usuário em 17/11; extensões ainda pendentes de ensaio físico.
Este documento preserva o procedimento PR-only inicial. O runner atualizado usa
AFG contínuo por padrão; para reproduzir exatamente o modo inicial, definir
`opts.afgMode='per_capture'`.

## Estado em 16/11/2026

Primeira implementação de pesquisa, **ainda não validada no MATLAB/Windows ou no
painel ao vivo**. Não é apenas o pacote de snapshots: há agora código opt-in.
Nenhum fonte original importado foi sobrescrito e nenhum serviço/instrumento foi
iniciado durante a implementação.

**Compatibilidade confirmada na bancada:** MATLAB R2021a, Python 3.13.0,
PyTorch 2.15.0+cpu. Não usar `pyenv` com esse Python. A implementação foi adaptada
para um processo Python persistente **externo**, com IPC JSON em TCP loopback.
`pyenv(..., 'ExecutionMode', 'OutOfProcess')` não contorna a restrição de versões
da API Python do MATLAB. A venv/modelo atuais não precisam ser substituídos.

- `../../codificacao_neural/live_bridge.py`: Python persistente, modelo carregado
  uma vez; listener MLLP 2222, somente PR, fila latest-only de uma observação,
  protocolo NC1 e gateway NDJSON local 4455.
- `matlab/run_neural_monitor.m`: entrypoint MATLAB alternativo de pesquisa,
  compartilha o **PHY do protótipo já conferido**, sincronizador Pearson assistido
  e conexão VISA aberta. Não chamar o inicializador do legado.
- `../../codificacao_neural/live_bridge_server.py` e
  `matlab/NeuralBridgeClient.m`: IPC persistente `127.0.0.1:47651`, independente
  de `pyenv`. Token aleatório por processo previne conexão acidental de outro
  cliente local; não é criptografia/autenticação da telemetria. Sem TLS.
- O gateway/backend, painel e API permanecem originais. A ponte publica o mesmo
  envelope que `mae_frontend` publicaria, **não chama `mae_frontend` nem a UI MATLAB
  antiga**. O caminho é compatível com o sistema completo na fronteira de aplicação;
  portar para o `start/tick/stop` e PHY da UI antiga continua sendo uma etapa futura.

Não carregar os dois `src/main` juntos. O entrypoint novo é deliberadamente separado
para evitar os efeitos colaterais de inicialização, comandos e classes antigas em
memória observados na bancada.

## Comportamento e limites

1. Recebe envelopes MLLP completos e seleciona apenas PR elegível; não persiste HL7
   bruto, PID, HR ou outros sinais. Não envia comandos ou ACK HL7 ao monitor.
2. Uma observação em voo; uma pendente latest-only. Substituições são contadas.
   Leitura PR explicitamente inválida limpa a fila e invalida a observação em voo.
   Mensagem sem observação PR é ignorada e contada em `messages_without_pr`, sem
   cancelar PR válida ou renovar sua idade. Rejeições PR têm contadores
   `pr_rejected_<motivo>`; invalidação informa `source_invalid_reason`.
   Duplicatas HL7 não
   são deduplicadas por identificador; valores iguais podem ser observações novas.
3. Codifica em memória (um frame de 10 bytes, um NC1/392 bits). Não usa MATs como
   IPC nem inicia Python por mensagem. O checkpoint Windows é exigido por SHA-256.
4. MATLAB prepara waveform com AFG OFF; só liga durante aquisição e desliga em
   seguida. Confere 10 MS/s/10k, CH1 e perfil elétrico antes de abrir o listener.
   A saída real e a segurança da montagem continuam sob responsabilidade presencial.
5. Só RX alinhada aceita vai ao integrador Manchester e decoder. Protocolo, modelo,
   ID, tamanho e CRCs são bloqueantes; sem TX fallback, retry oculto ou substituição
   pela última leitura boa. TX serve apenas ao sync assistido e à avaliação de BER.
6. Limite padrão de idade de 2 s entre recepção **no PC** e escrita no gateway.
   Não é idade clínica nem timestamp do dispositivo; buffer/retransmissão a montante
   não são observáveis. Não renova o painel por falhas ou dados expirados.
7. Só mensagens válidas chegam a `127.0.0.1:4455`, com arrays `variables`/`alarms`.
   O bridge nunca interpreta retorno de comandos nem abre sockets de bombas.
   Conexão TCP não autentica o dado; CRC/modelo não demonstram confidencialidade.
8. `gateway_write_ok` significa escrita TCP sem erro, **não confirmação do painel**.
   Falha de envio não é retransmitida: entrega nesse caso pode ser indeterminada.
   `panel_delivery_confirmed` permanece falso; conferir visualmente a primeira vez.
9. Eventos JSONL e MAT por tentativa ficam em uma saída exclusiva. Não há gravação
   da fonte bruta HL7. MATs incluem TX/RX de pesquisa; backup separado do Git.
   Falhas normais são preservadas; interrupção/queda de energia pode deixar tentativa
   incompleta (não contabilizar como êxito).

## Pré-validação no PC — não liga saídas

Transferir `live_bridge.py`, `live_bridge_server.py`, `matlab/run_neural_monitor.m`,
`matlab/NeuralBridgeClient.m` e testes novos para os respectivos diretórios no
clone da bancada primeiro. Não substituir o checkpoint.
No PowerShell em `codificacao_neural`:

```powershell
.\.venv\Scripts\python.exe -m unittest discover -s tests -v
.\.venv\Scripts\python.exe -c "import sys; print(sys.executable)"
Get-NetTCPConnection -LocalPort 2222 -State Listen -ErrorAction SilentlyContinue
```

Não executar o coletor `monitor_capture.py` junto com a integração. A porta 2222
deve estar livre. Não encerrar listeners desconhecidos automaticamente.

No mesmo PowerShell, iniciar **somente o servidor IPC**:

```powershell
.\.venv\Scripts\python.exe live_bridge_server.py --serve `
  --model runs/codec_seed42/model.pt `
  --model-sha256 f83712964339612bbc4011590062fd05445e1cd9d0380e1e09ee00ed9c7ff0bf
```

Ele imprime um token e aguarda até 120 s pela conexão do MATLAB. Não abre a
porta do monitor, não conecta ao gateway e não acessa VISA. Deixar esse terminal
aberto; copiar o token localmente, sem publicá-lo.

No MATLAB, **sem usar instrumentos ou `pyenv`**, testar o transporte:

```matlab
addpath(fullfile(repo, 'medical_telemetry_system', ...
    'neural_codification_changes', 'matlab'));
controlToken = 'PASTE_THE_TOKEN_PRINTED_BY_THE_LOCAL_SERVER';
ipcCheck = NeuralBridgeClient(47651, controlToken);
disp(ipcCheck.info());
ipcCheck.close();
clear ipcCheck
```

Esperar protocolo `vlc_neural_ipc_v1`, hash correto e `monitor_started=false`.
O servidor encerra após `close`; reiniciá-lo para a ativação, usando o **novo**
token. Não manter o teste aberto enquanto aguarda outra etapa (timeout ocioso
de 120 s). Erro de IPC encerra a sessão, sem reaproveitar respostas atrasadas.

## Backend e painel — ativação manual separada

Usar o backend completo **no modo gateway**, não `npm start`, `dev` ou `new_server`
(outros modos podem abrir portas de dispositivos/contornar o VLC):

```powershell
Set-Location 'C:\Users\DELL\Documents\murilobarroso\vlc\medical_telemetry_system\alarm-care-pro-backend'
npm run gateway
```

Usar instalação/configuração local existente; não substituir `.env`, reinstalar
dependências ou migrar bancos automaticamente. O processo usa 4455/4444; conferir
que não há outros processos ocupando-as antes de iniciar.

Abrir o painel existente apontado a esse backend, com login/API já configurados.
**Recarregar a página antes do ensaio**, para limpar cards antigos. Somente o card
“Taxa de pulso oxímetro” deve receber dados; HR não deve herdar PR. Bombas/ventilador
continuam fora do ensaio, sem usar controles da UI. O timeout de 5 s é global ao
monitor, não por variável; estado limpo é requisito desta primeira demonstração.

## Primeira ativação física — somente após pré-validação

**Este bloco abre o listener e habilita o AFG em cada captura por até 60 segundos.**
Requer operador presente, montagem segura e sessão VISA já aberta/conferida.
Não executar simultaneamente a UI/orquestrador MATLAB antigo.

```matlab
opts = struct();
opts.host = '192.168.1.2'; % Verify the current laboratory Ethernet IPv4 first.
opts.modelSha256 = 'f83712964339612bbc4011590062fd05445e1cd9d0380e1e09ee00ed9c7ff0bf';
opts.outDir = fullfile(repo, 'codificacao_neural', 'data', 'live', ...
    ['live_' datestr(now, 'yyyymmdd_HHMMSS')]);
opts.seconds = 60;
opts.maxAgeSeconds = 2;
opts.controlPort = 47651;
opts.controlToken = 'PASTE_THE_NEW_TOKEN_FROM_THE_RUNNING_LOCAL_SERVER';
opts.confirmation = 'CONFIRM_RESEARCH_PR_VLC_AND_GATEWAY';
run_neural_monitor(scopeVisa, repo, opts);
```

Antes do bloco, reiniciar o servidor IPC e copiar seu novo token em `opts`.
Ao terminar ou interromper, **conferir AFG desligado no instrumento**. `onCleanup`
é defesa de software, não proteção contra crash/desconexão VISA. O runner não fecha
a sessão VISA emprestada. Encerrar o gateway pelo procedimento local.

Critérios da primeira ativação: PR no campo correto, valores acompanhando a fonte,
`codec_ok`/`gateway_write_ok` registrados, nenhuma mensagem recebida por outro
caminho, nenhum card antigo como atual. Interromper/remover o sensor conforme o
procedimento autorizado: após cessarem mensagens válidas, o painel deve ficar
inativo, sem atualizar timestamp. Não enviar dados propositalmente errados ao monitor.
Avaliar falhas de CRC/modelo via testes offline, não por comandos médicos.

## Evidência local

Testes exercitam contrato JSON, CRC/modelo/ID, ausência de fallback, idade,
invalidação, latest-only, fechamento do listener e sockets TCP **sintéticos em
loopback**. Não executam MATLAB, gateway Node real, React, VISA ou monitor.
Ainda falta validar esses componentes no Windows e auditar artefatos físicos.

Em 17/11, usuário relatou uma primeira tentativa física online com `codec_ok=true`,
`source_exact_match=true`, zero erros em 392 bits e idade de 0,6472 s, mas
`gateway_write_ok=false` por `source_invalidated_during_phy`. Foram 58 mensagens,
29 aceitas e 29 rejeitadas na versão anterior. Esses contadores antigos não
distinguem ausência de PR de PR explicitamente inválida: não permitem afirmar
qual dessas situações ocorreu. Corrigido o tratamento de ausência de PR e
acrescentados diagnósticos/regressões, mantendo bloqueio de PR inválida/ambígua.
Atualizar `live_bridge.py`, reiniciar o processo Python e usar uma saída nova;
preservar a tentativa anterior, sem apresentá-la como entrega ao painel.
Seis testes adicionais exercitam dispatch/handshake, token incorreto, JSON
inválido, fragmentação e fechamento da sessão externa. O teste MATLAB acima
continua necessário: testes Python não executam `tcpclient`/`readline` do R2021a.
