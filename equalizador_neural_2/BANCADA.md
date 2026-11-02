# Início presencial no PC da bancada

## 1. Após atualizar o repositório — ainda sem transmitir

1. Confirmar que o clone contém as pastas `equalizador_neural_2`,
   `equalizador_neural` e o legado MATLAB. Atualização Git não transfere dados
   ignorados; preservar capturas e configurações locais antes de qualquer atualização.
2. Preparar Python e executar `check_environment.py` e os testes conforme README.
3. No MATLAB R2021a, definir o caminho real do clone:

```matlab
repo = 'C:\Users\DELL\Documents\murilobarroso\vlc'; % Confirmar caminho local.
addpath(genpath(fullfile(repo, 'vlc-system-matlab-alarm-care-pro-scripts', 'src', 'main')));
addpath(fullfile(repo, 'equalizador_neural', 'matlab'));
addpath(fullfile(repo, 'equalizador_neural_2', 'matlab'));
which collect_capture -all
which collect_rate_block -all
results = runtests(fullfile(repo, 'equalizador_neural_2', 'matlab', 'test_validate_rate_plan.m'));
table(results)
```

Esses testes não transmitem. **Não foram executados neste ambiente Linux**, que
não tem MATLAB. Conferir também os testes antigos de sincronização se o clone ou
o MATLAB local tiverem mudado.

## 2. Preparar uma sessão — nenhum valor é autorização elétrica

Copiar `matlab/session.example.json` para um arquivo `*.local.json`, preencher
TODOS os `REPLACE` e campos `null`, e registrar os valores realmente conhecidos.
Não copiar a corrente ou o ganho da tese como se fossem medições atuais. A validação
recusa metadados físicos essenciais vazios. Conferir com o responsável os limites
elétricos/térmicos e de banda dos instrumentos antes de qualquer nova taxa.

- Primeiro piloto: somente `rates_bps: [1000000]`, 400 bits, 20 tentativas.
  Esses números são organização inicial baseada no piloto anterior, não suficiência
  estatística, taxa máxima ou autorização para a montagem atual.
- Um `session_id` representa um bloco/dia/montagem correlacionado, **não cada quadro
  nem cada taxa**. Taxas da mesma sessão mantêm o mesmo split.
- Planejar sessões futuras por split antes da coleta, por exemplo duas de treino,
  duas de validação e três de teste; alvo logístico, não garantia estatística.
- Semente base diferente em cada sessão e espaço suficiente entre sementes dos
  blocos. Cada taxa deriva `seed + rateIndex - 1`. Payloads salvos são a referência.
- `out_dir` deve ser caminho absoluto local novo de capturas, fora de pastas auditadas.
- Após cada bloco, conferir antes de autorizar a próxima taxa. Uma taxa de cada vez;
  listas maiores só após verificar limites e aquisição em todos os pontos pretendidos.

Validação offline do JSON, sem tocar instrumentos:

```matlab
configFile = fullfile(repo, 'equalizador_neural_2', 'matlab', 'session.local.json');
rateIndex = 1;
plan = validate_rate_plan(configFile, rateIndex);
```

Ela imprime a taxa de aquisição desejada e escala horizontal sugerida. Não sabe
se o AFG/LED/receptor suporta a taxa, nem se o instrumento a aplicará exatamente.

## 3. Configuração presencial e aquisição

Reutilizar os objetos `txAnalyzer` e `rxAnalyzer` da sessão **já inicializada e
validada pelo procedimento local**, ou o mesmo objeto para ambos. Não há script
novo de inicialização automática. A inicialização legada liga/configura AFG e
pode fechar conexões VISA: não a repetir enquanto outra rotina usa o instrumento.
No workspace pausado legado o objeto era `txRxAnalyzer`, não necessariamente está
disponível no workspace base. Não usar `dbcont` para iniciar TCP/UI inadvertidamente.

1. Conferir alimentação e polarização, ganho, distância/alinhamento, amplitude,
   trigger, acoplamento, escala vertical e ausência de clipping.
2. No instrumento, ajustar manualmente comprimento de registro e base de tempo
   apropriados à taxa selecionada. Para sps=10, alvo RX é `10*bit_rate`; consultar
   a taxa real. Não manter RX a 10 MS/s ao aumentar TX sem avaliar amostragem.
3. Selecionar também a fonte de transferência `DATa:SOUrce` para CH1 (ou o canal
   planejado); conferir com `rxAnalyzer.queryText('DATa:SOUrce?')`.
   Isso não equivale a selecionar a fonte do trigger.
4. Confirmar pessoalmente a operação segura e a substituição do waveform/período
   do AFG. Somente então chamar:

```matlab
files = collect_rate_block(txAnalyzer, rxAnalyzer, configFile, rateIndex, ...
    'CONFIRM_SAFE_SETUP_AND_WAVEFORM_UPLOAD');
```

Se o mesmo objeto se chama `txRxAnalyzer`, passá-lo nos dois primeiros argumentos.
A função **não altera amplitude, corrente, ganho, timebase ou estado de saída**,
mas a chamada herdada `writeSamples` substitui a waveform/período do AFG. Não é
uma operação passiva: a confirmação é necessária a cada chamada.

O coletor verifica canal de transferência, taxa e tamanho do registro **antes do
upload**, recusa a pasta existente e não faz retry oculto. Salva config, cópias das
fontes MATLAB resolvidas no path em `code/` e diário
de tentativas iniciadas/concluídas por bloco. Falha de processo pode deixar uma
tentativa somente como `started`; preservar isso e investigar. Uma falha de
sincronização permanece nos arquivos e não deve ser apagada para melhorar BER.

**Não existe resume automático.** Se interromper, investigar e usar outro ID/bloco
sem fingir uma nova sessão independente. Mudança de aquisição detectada durante
o bloco interrompe após preservar a captura; nada desliga automaticamente o AFG.

## 4. Conferir o primeiro bloco antes de aumentar taxa

- Há payload novo, RX bruto e taxas corretas em cada `.mat`?
- Integração e correlação são coerentes com a waveform observada?
- Há rail ADC, saturação anterior ou erro de trigger?
- O registro contém ao menos um quadro completo? Repetições do AFG não são dados novos.
- Registrar uma tentativa rejeitada e seu motivo; não escolher atraso pelo menor BER.
- Testar a preparação Python/diagnóstico já no piloto, sem treino de CNN.

Se tudo continuar sem erros, isso **não é um defeito**. Ampliar a taxa somente
com configuração validada e autorização presencial, não alterar corrente para
forçar falhas. A escala de tempo configurada em degraus pode não gerar exatamente
o alvo: o software recusa taxas diferentes. Resolver aquisição ou planejar uma
reamostragem validada, nunca editar metadados para fazer o leitor aceitar.

## 5. Transferir e encerrar

- Fazer backup dos MATs, JSON e diário CSV; usar `campaign.py` conforme README.
- Enviar o piloto novo para revisão antes da campanha extensa e antes de treino.
- Encerrar saídas/fontes pelo procedimento presencial autorizado. Fechar VISA,
  encerrar MATLAB ou sair do breakpoint não garante desligamento elétrico.
- Nenhum aparelho médico, paciente, gateway ou UI é necessário.
