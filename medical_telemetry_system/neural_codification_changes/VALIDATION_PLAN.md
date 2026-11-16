# Portões antes de aplicar a integração

**Atualização após autorização do usuário:** iniciada implementação de entrypoint
online separado, sem substituir fontes originais. 11 testes novos do bridge
passaram (26 no conjunto codec/coletor/bridge), incluindo sockets sintéticos locais.
Validação MATLAB/Windows e gateway/React reais pendente. Ver
[LIVE_INTEGRATION.md](LIVE_INTEGRATION.md); a série isolada ampliada não foi
concluída, não apresentá-la como portão experimental já cumprido.

## Verificação executada em 16/11/2026

- Snapshot/verify: 17 arquivos coincidem byte a byte com os fontes importados.
- 5 testes do empacotador, 15 do codec/coletor e 47 + 6 dos equalizadores aprovados
  (73 no total), sem executar o sistema legado, servidores médicos ou instrumentos.
- Ruff nos fontes Python novos/do codec aprovado. Isso valida software/preparação,
  não inferência MATLAB integrada, app Web ou uma nova transmissão física.

## A. Bancada isolada — agora

Sem executar apps de `medical_telemetry_system`. Usar fontes do protótipo
`codificacao_neural`/equalizadores já testadas, com paths sem classes homônimas.

1. AFG OFF; verificar se existe conexão VISA antes de abrir outra.
2. Identificar instrumento, fonte de transferência CH1, 10k pontos, XINcr=100 ns,
   CH1 AC/1 MΩ/500 mV/div, escala horizontal 100 µs/div, estado/limite de banda e
   aquisição/trigger. Corrigir apenas divergências confirmadas, com operador.
3. Conferir fonte/LED, amplificador e Hyperion; não copiar corrente/tensão da
   tabela do artigo como se fossem leituras atuais.
4. Conferir hash do checkpoint congelado, pacotes e referência original. Sem
   retreino ao mudar dia. Preparar waveform com saída OFF e verificar período,
   amplitude 1 Vpp, offset zero, função arbitrária e carga declarada Hi-Z.
5. Repetir mensagem sintética de referência em nova sessão física, depois uma
   leitura real PR/HR registrada do monitor. Não misturar replay com online.
6. Fazer série curta predefinida, por exemplo 20 mensagens lógicas, preservando
   todas as tentativas e falhas. Isso é piloto, não suficiência estatística.
7. Decodificar MATs físicos sem `--ideal`, comparar bytes, CRC, taxa de entrega,
   BER dos bits codificados e tempos. Rever origens e falhas antes de ampliar coleta.

Separar conteúdo e sessão: repetir a mesma mensagem mede repetibilidade do enlace,
não diversidade clínica. Ensaios com voluntário são pesquisa e seguem procedimentos
institucionais; não induzir alterações fisiológicas para variar dados.

## B. Adaptador offline — depois

- Conformidade exaustiva dos 256 bytes entre Python e a implementação escolhida
  para MATLAB; mesmo checkpoint, bit order, limiar e NC1.
- Frames HR/PR e sentinelas, fragmentação/coalescência MLLP, perda de conexão.
- Mensagens maiores, fragmentos faltantes/trocados/duplicados, CRC e modelo errados.
- Decoder recebe somente RX; fonte de referência reservada à avaliação.
- Injetar falha e verificar **zero chamadas ao gateway**, sem fallback em claro.
- Sem instrumentos, testar que novo modo não inicializa VISA/AFG ou comandos.

## C. Contrato backend/painel — sem VLC primeiro

Ambiente de teste, não operacional. Validar NDJSON do frame reconstruído com o
gateway, não com o servidor que recebe equipamentos diretamente.

- Evento `monitor_message`, PR/HR no campo correto e arrays JSON preservados.
- Rejeição não atualiza valor/time; timeout de inatividade do painel funciona.
- Só PR é fonte ativa: nenhum card fora do escopo mantém dado antigo como atual;
  o timeout global de monitor não substitui validade por variável.
- Não há duplicação por um caminho TCP direto monitor → backend.
- UI/contexts podem emitir comandos: garantir bloqueio no modo de pesquisa.
- API/login continuam inalterados e sem migrações para introduzir codec.

## D. Integração online fim a fim — somente após A/B/C

Entrada monitor → encoder → VLC → decoder → gateway → painel, sem arquivos
intermediários necessários por leitura. Medir timestamps/latência por etapa,
goodput, fila, indisponibilidade e entrega no painel; diferenciar de BER do PHY.
Modo neural explícito, reversível e desabilitado por padrão; rollback sem perda
de fontes/capturas/modelo. Modo legado permanece testável.

Nenhum desses portões prova confidencialidade ou uso clínico. Não descrever o
plano como integração implementada. Não executar build/deploy, servidores, banco,
UI ou controle médico automaticamente para “ver se funciona”.
