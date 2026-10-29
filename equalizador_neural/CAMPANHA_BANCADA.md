# Próxima campanha: dados independentes para validar o detector

## Por que voltar à bancada

O piloto atual tem 100 capturas de **uma sessão**, com 40.000 bits distintos.
Já permite avaliar numericamente ruído e testar o software, mas não permite
demonstrar generalização de um detector aprendido. Reamostrar essas capturas ou
adicionar mais ruído não cria novas sessões físicas.

**O próximo bloqueio real é obter sessões independentes**, não injetar ruído
fisicamente, aumentar potência ou conectar os aparelhos médicos. O estudo inicial
continuará adicionando AWGN por software, sobre capturas preservadas.

## 1. Planejamento antes de transmitir

1. Consulte o responsável sobre alimentação, polarização, ganho do Hyperion,
   aquecimento e limites autorizados. Ainda não temos todos esses valores.
2. Defina sessões e splits **antes da coleta**. Como alvo logístico inicial,
   sugerimos duas sessões de treino, duas de validação e três de teste. Isso não
   é garantia de suficiência estatística; mais dias/sessões são desejáveis.
3. Uma sessão deve corresponder a um bloco fisicamente correlacionado (dia,
   montagem, condições de operação), não a cada arquivo. Prefira dias diferentes;
   se usar blocos no mesmo dia, documente a independência que de fato existe.
4. Não renomeie pedaços do piloto como sessões novas. Ele pode permanecer no treino
   exploratório, nunca virar validação/teste da mesma montagem por simples renomeação.
5. Use IDs globais únicos e sementes diferentes entre sessões. Não reinicie o RNG
   com a mesma seed a cada quadro e não repita payloads/PRBS curtas entre splits.
6. Comece com cerca de 200 capturas de 400 bits por sessão como referência de
   organização, não como tamanho amostral final. Se houver limitações práticas,
   registre o número real e preserve todas as tentativas/falhas.

## 2. Configuração e limites

A referência do piloto foi: TX Manchester a 1 Mbps, 10 amostras/bit, mesmo MDO3012
para TX/RX, CH1 para PD, registro de 10.000 pontos a 10 MS/s, 100 µs/div, CH1 em
500 mV/div/AC/1 MΩ. AFG em 1 Vpp, período 400 µs para 400 bits, e distância nominal
de 2,4 m com alinhamento aproximadamente axial.

Esses são **valores observados, não autorização para reconfigurar automaticamente**
uma bancada diferente. A fonte de polarização, amplificador e receptor precisam
estar alimentados conforme o procedimento local. Saída do AFG ligada não liga o LED.

- Não introduzir degradação elétrica ou mudar amplitude/corrente para esta campanha.
- Registrar corrente efetiva, ganho, componentes e detalhes do trigger, ainda
  pendentes. A nota de fonte 18 V/200 mA não identifica sozinha a corrente do LED.
- Conferir ausência de clipping de aquisição em RX bruto; isso não exclui saturação
  óptica/analógica. Não ajustar ganho ou corrente automaticamente para corrigir isso.
- Registrar horário, luzes, cortinas, condições externas e estabilidade da montagem;
  não alegar iluminância constante ou medida em lux se não houve medição.
- Não usar pacientes, gateway ou UI; payloads aleatórios gerados no MATLAB bastam.

## 3. Coleta e teste mínimo por sessão

Use `matlab/collect_capture.m` e `matlab/synchronize_capture_samples.m` atualizados.
O método é `valid_window_pearson_v1`, ainda assistido pelo TX completo. O limiar
0,5 é exploratório e não deve ser retocado em cada sessão para esconder falhas.

Antes de um bloco, faça uma captura e confira:

- `status`, `error_message` e `sync_info`;
- 400 bits/4.000 amostras alinhadas se aceito, 10.000 pontos brutos se a aquisição
  foi concluída, taxas TX/RX iguais a 10 MS/s;
- waveform coerente, escala adequada, score e decisão do integrador;
- metadados corretos e arquivos novos, sem reutilizar índice/seed do bloco anterior.

O coletor não configura instrumentos, não aplica retries ocultos nem desliga
saídas. A conexão tem de estar pronta e exclusiva; não reiniciar o legado por
tentativa se outra rotina controla o mesmo MDO. A inicialização legada modifica
saídas e fecha sessões de instrumentos. Verifique [`README.md`](README.md) e
[`ROADMAP.md`](ROADMAP.md) antes de iniciar/reusar a sessão MATLAB.

### Metadados por tentativa

Preservar os campos do contrato do README. Acrescentar, quando conhecidos:

- `capture_id`, `session_id`, `condition_id`, `split` planejado;
- tipo de payload, seed da sessão e índice real da geração;
- distância/ângulo nominais e notas sobre o que foi efetivamente medido;
- modelo/receptor/ganho, corrente de polarização e amplitude AFG;
- escala vertical, acoplamento, impedância, fonte/borda/nível do trigger;
- iluminação, horário e notas de operação. O coletor também salva UTC.

Campos desconhecidos devem permanecer explicitamente pendentes, não receber
valores copiados da tese como se fossem medidos.

## 4. Preserve falhas e prepare a transferência

- Guardar RX bruto, bits TX, TX ideal e metadados mesmo nas falhas; não recortar
  manualmente apenas os casos bons nem substituir o status original.
- Fazer backup em pelo menos outro local. `data/` e `runs/` são ignorados pelo Git.
- Compactar cada sessão ou campanha com arquivos numéricos `.mat -v7`, sem
  objetos MATLAB e sem `settings.mat` dentro do dataset de capturas.
- Arquivos diagnósticos/fotos/configurações podem ser enviados à parte, com
  identificação da sessão. Não incluir dados identificáveis de pacientes.
- Encerrar AFG, fontes e demais equipamentos pelo procedimento autorizado;
  fechar VISA ou usar `dbquit` não garante desligamento elétrico.

## 5. Retorno ao fluxo offline

1. Reprocessar cada ZIP em uma pasta nova com `reprocess_captures.py`, mantendo
   IDs, sessões, splits e histórico original.
2. Auditar hashes, duplicações, coerência de taxas/protocolo e metadados. Um arquivo
   de outra sessão com o mesmo payload não deve atravessar os splits inadvertidamente.
3. Executar `benchmark_detectors.py --data <raiz_auditada_1> <raiz_auditada_2> ...`.
   Ele exige treino/validação/teste por sessões distintas antes de ajustar modelos.
4. Rodar sem augmentation e com augmentation usando as mesmas seeds de avaliação;
   repetir seeds de modelo predefinidas. Escolhas de arquitetura/ruído/limiar só
   podem usar treino/validação, nunca teste.
5. Comparar integrador, template casado de médias de classe, ridge e CNN. Se a
   caracterização exigir FIR/MMSE/DFE, ampliar baselines antes de alegar novidade.
6. Interpretar bootstrap por sessão com cautela quando houver poucas sessões.
   Persistir todos os resultados, inclusive empates e casos desfavoráveis à rede.

**Não há ganho neural real demonstrado até agora.** A implementação do benchmark
foi testada com sessões sintéticas; o piloto físico foi corretamente recusado
para treino por ter apenas uma sessão.
