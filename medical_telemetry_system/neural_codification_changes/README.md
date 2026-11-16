# Preparação da integração neural — NÃO aplicada

**16/11/2026.** Esta pasta prepara a inclusão do codec em
`../vlc-system-matlab/`, parte do sistema completo com backend, frontend e API.
Os fontes ativos **não foram alterados**. Não execute o legado ou acrescente
`reference/` ao path do MATLAB para testar estas cópias.

**Atualização após autorização para integrar:** primeira implementação opt-in em
[`matlab/run_neural_monitor.m`](matlab/run_neural_monitor.m) e
[`../../codificacao_neural/live_bridge.py`](../../codificacao_neural/live_bridge.py).
Ver [LIVE_INTEGRATION.md](LIVE_INTEGRATION.md). Ela conecta o PHY do protótipo ao
gateway/painel completo, sem sobrescrever fontes originais e sem usar a UI MATLAB
antiga. Testes Python aprovados; MATLAB/Windows e demonstração Web ainda pendentes.
As seções de snapshots abaixo descrevem a base de revisão, não esse código novo.

O artigo “Enabling Visible Light Technology for Alarm Management in Medical
Intensive Care Units” descreve o sistema-base. A integração proposta acrescenta
encoder/decoder digital antes/depois do enlace, preservando a mensagem compacta
e o contrato do painel. Não se transfere automaticamente ao novo codec a latência,
BER estimada, capacidade da fila ou desempenho relatados naquele artigo.

## Conteúdo

- `reference/`: cópias byte a byte dos 17 fontes revisados, com sufixo `.reference`
  para não sombrear funções/classes executáveis. Quatro arquivos são alvos diretos,
  duas UIs são alvos condicionais; os demais documentam contratos e dependências.
- `reference/source_manifest.json`: paths relativos, papéis, tamanhos e SHA-256.
- [FILE_MAP.md](FILE_MAP.md): mudança planejada em cada arquivo, inclusive os que
  não precisam de alteração funcional.
- [INTEGRATION_CONTRACT.md](INTEGRATION_CONTRACT.md): fluxo, falhas, framing, modelo
  e contrato JSON preservado.
- [VALIDATION_PLAN.md](VALIDATION_PLAN.md): portões antes de ativar o sistema completo.
- `prepare_bundle.py`: cria/verifica snapshots, sem patch, instalação, sockets,
  execução de MATLAB, inicialização VISA, banco de dados ou instrumentos.
- `tests/`: testes do empacotador, não testes de integração médica.

**Não há substitutos modificados dos fontes originais prontos para instalar.** As cópias são
uma base de revisão solicitada, não substitutos do legado. Novos módulos necessários
estão especificados no FILE_MAP; não há launcher que finja integração já funcional.
Uma futura alteração dos originais deve gerar diffs sobre estes hashes, ser revisada e passar
pelos portões abaixo antes de substituir arquivos ativos.

## Onde inserir a camada

```text
Monitor → HL7/MLLP → seleção HR ou PR → frame compacto → fila
  → encoder neural + NC1 → Manchester → VLC → Manchester RX
  → CRC/framing/modelo + decoder neural + reassembly
  → frame compacto válido → mae_frame → mae_frontend
  → NDJSON TCP 4455 → gateway → Socket.IO 4444 → painel React
```

Na primeira integração, somente **uma taxa HR/PR do monitor**, mantendo PR óptica
distinta de HR do ECG. Não reintroduzir ventilador/bombas/alarmes como fontes
porque o software completo os suporta. Não ativar comandos do painel aos aparelhos.
O ensaio é de pesquisa, sem uso clínico. Codec neural não é criptografia comprovada.

### Por que provavelmente não mudar backend, frontend e API

Depois do decoder e da validação, encaminhar a mesma mensagem e o mesmo NDJSON:
`source="monitor_message"` e payload `Monitor Measurements`, com arrays `variables`
e `alarms`. O gateway e o painel já distinguem `Puls Oxim Puls Rate` de
`Ecg Heart Rate`. Não enviar latentes, tensores ou NC1 para Node/React.

A API é de usuários/autenticação, não participa da codificação óptica. Não alterar
schema, banco ou login para inserir o codec. O processo backend a avaliar é o
**gateway** (`src/gateway_server.ts`), não o servidor que recebe diretamente os
equipamentos e poderia contornar o VLC ou disputar a porta 2222.

Essa transparência funcional é uma hipótese verificável, não dispensa testar
o painel: timeout/staleness e falhas precisam ser conferidos. Expor diagnóstico
neural na UI Web é extensão opcional que exigiria contrato novo. A primeira etapa
pode manter esse diagnóstico em logs locais e na UI MATLAB.

## Verificar as cópias

No PowerShell a partir desta pasta (Python padrão, sem dependências externas):

```powershell
py -3 prepare_bundle.py verify
py -3 prepare_bundle.py verify --system-root ..
py -3 -m unittest discover -s tests -v
```

O segundo comando requer os fontes completos no PC e verifica que ainda coincidem
com a revisão. Divergência não é autorização para sobrescrever: revisar a versão
local primeiro. `snapshot` só cria uma saída nova, nunca substitui uma existente.
Não há comando “apply”.

## Preservação e próximos passos

O diretório completo importado contém `node_modules`, repositórios aninhados e
configs locais. A regra do Git foi ajustada para versionar **somente esta pasta**,
mantendo os aplicativos originais ignorados. `.env`, bancos, dependências e dados
de pesquisa não foram copiados. Atualizar o Git não transfere o sistema completo,
modelos, capturas, Python venv ou configs: fazer backup separado.

O codec validado continua em [`../../codificacao_neural/`](../../codificacao_neural/README.md).
Primeiro repetir e ampliar os testes isolados na bancada. Só depois implementar
o adaptador em memória, validar offline e ligar ao gateway de teste. Não iniciar
`real_time_mae_vlc('start', ...)` nesta fase: há caminhos legados que habilitam AFG,
alteram amplitude, abrem todas as portas e registram comandos.
