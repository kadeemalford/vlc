# Propostas de ML para o sistema VLC de telemetria

## Contextualização e objetivo do repositório

O objetivo principal deste repositório é **selecionar, implementar e avaliar uma aplicação de machine learning (ML) ao sistema de comunicação por luz visível (VLC), produzindo evidências para publicar um artigo científico**. Não basta integrar uma rede neural: o trabalho precisa responder a uma pergunta mensurável, comparar referências fortes e demonstrar uma contribuição atribuível ao aprendizado. Preferem-se intervenções de software que aproveitem a bancada existente, sem alterações expressivas de hardware.

As propostas abaixo foram revistas considerando os scripts MATLAB, e não apenas seu README. Nenhuma apresenta ganho de ML já comprovado: a escolha deve depender de um piloto que avalie dados, limitações do baseline e viabilidade experimental.

### Aplicação e bancada

O sistema recebe dados de equipamentos médicos por TCP, incluindo mensagens HL7 de observação (`ORU`) e tráfego binário de bombas de infusão. Um parser extrai variáveis e alarmes reconhecidos e os converte em mensagens compactas legadas. Essas mensagens entram em uma FIFO e são agrupadas em quadros de até 58 caracteres.

**O HL7 completo não atravessa o enlace VLC.** Nomes e unidades já são substituídos por códigos abreviados; os valores são enviados em campos numéricos curtos. Portanto, retirar a verbosidade do HL7 não pode ser contabilizado como uma contribuição nova de ML.

O enlace usa Manchester-OOK a 1 Mbps, com 10 amostras por bit, geração e aquisição pelo Tektronix MDO3012. O AFG transforma a forma de onda digital em tensão analógica; o sinal atravessa amplificador, Bias-Tee, LED e canal óptico. O fotodetector/TIA converte a luz em sinal elétrico, adquirido e processado no MATLAB. A recepção usa normalização, reamostragem quando necessária, sincronização por correlação, correção de polaridade, integração por meia-fase Manchester e decisão pareada.

```text
Equipamentos → TCP → parser → mensagens compactas → FIFO/framing
  → Manchester → AFG → amplificador/Bias-Tee/LED → canal → fotodetector
  → aquisição → sincronização → decisão → interpretação → gateway → UI
```

A ponte MATLAB para um gateway Node está presente, mas o backend e a UI não estão nesta cópia. Comandos da UI para as bombas retornam diretamente por TCP, **sem passar pelo VLC**. O experimento atual não constitui um enlace óptico bidirecional.

O relatório `bibliography/FINEP_2026.md` caracteriza uma bancada correlata com LED azul CREE XLAMP XM-L2, amplificador Juntek, Bias-Tee e receptores PIN/Hyperion. A largura de banda observada é próxima de 2 MHz. O PIN com lentes apresentou maior alcance; distância, alinhamento, não linearidade e saturação influenciam os resultados. Os ensaios apresentados são **em ar**: a aplicação subaquática é uma etapa futura. Telemetria clínica e inspeção offshore são contextos de aplicação diferentes, embora possam compartilhar técnicas de comunicação.

### O que os códigos permitem afirmar

| Aspecto | Funcionamento atual e consequência para a pesquisa |
| --- | --- |
| Sincronização | Usa a forma de onda TX completa, inclusive para correção de polaridade. É uma recepção assistida por referência de bancada, não um receptor independente que desconhece o payload. |
| Integridade | Não há CRC, sequência, FEC, prioridade especial de alarmes ou recuperação de quadros perdidos. Um erro que preserve a sintaxe pode ser aceito; o aviso de divergência TX/RX não impede o encaminhamento ao backend. |
| Fidelidade da fonte | O legado arredonda valores segundo escalas predefinidas, não transmite timestamps originais/identificadores completos e representa dois canais de temperatura pela mesma abreviação. Essas perdas precisam ser separadas das introduzidas por uma nova proposta. |
| Cobertura clínica | O monitor fornece variáveis, mas seu handler não extrai alarmes. O ventilador trata variáveis e alarmes. As bombas fornecem um alarme selecionado pelo primeiro bit ativo encontrado, não séries de vazão/volume nem todos os alarmes simultâneos. |
| Métricas | BER é medida comparando bits TX/RX. Q é opcional e está desabilitado no fluxo em tempo real; o zero mostrado nesse fluxo não é uma medição de Q. EOP requer processamento adicional. |
| Tempo real | A pausa de 10 ms do laço não é a cadência efetiva: cada upload inclui espera de 50 ms, além de VISA, aquisição e processamento. Taxa física, throughput útil e latência devem ser distinguidos e medidos. |
| Coleta física | Já são retornados bits TX/RX, sinal TX, aquisição bruta e sinal sincronizado. Existe varredura de amplitude do AFG com salvamento de respostas MATLAB. Faltam dataset organizado, metadados e registro completo das falhas; os `.mat` referenciados pelos scripts não estão nesta cópia. |
| Controle | Há controle de amplitude do AFG e parametrização da taxa. Não foi encontrada interface pronta para corrente de polarização, temperatura ou ganho do fotodetector. |
| Simulação | Existe um canal com ruído, mas o filtro de limitação de banda nessa classe está desabilitado. Ele não representa sozinho o canal físico de aproximadamente 2 MHz, sua não linearidade ou saturação. |

Os PCAPs disponíveis cobrem aproximadamente **8,3 minutos de monitor e 6,6 minutos de bomba**. Esses tempos são duração de captura, não garantia de séries contínuas ou diversas. Ainda é necessário reconstruir o fluxo TCP, validar os parsers, verificar cadência/valores e desidentificar os dados. Os buffers atuais não devem ser presumidos como um mecanismo completo de delimitação de mensagens diante de fragmentação e coalescência TCP.

Normalização digital não garante linearidade elétrica/óptica, e acoplamento AC não elimina todo ruído ambiente. Também é essencial distinguir a **BER medida por contagem de erros** da **BER estimada a partir de Q sob hipóteses de ruído**, usada no relatório. Valores estimados extremamente baixos não comprovam taxas observadas experimentalmente.

### Pontos de inserção de ML

```text
Fonte → parser → codec/framing → Manchester → AFG/LED → canal → PD → receptor
                  ↑                         ↑                       ↑
           compressão temporal       controle adaptativo     equalização/detecção
```

## Resumo comparativo

| Critério | 1. Compressão temporal aprendida | 2. Equalização/detecção neural | 3. Controle adaptativo contextual |
| --- | --- | --- | --- |
| Objetivo | Reduzir carga além da compactação já existente | Reduzir erros e ampliar a região operacional | Selecionar configurações seguras conforme o enlace |
| Dados atuais | PCAPs curtos; séries ainda não reconstruídas | Sem dataset físico nesta cópia; coleta parcialmente implementada | Sem dataset de controle; varredura de amplitude parcialmente implementada |
| Principal risco | Codec clássico igualar ML; pouca diversidade clínica | Ganho desaparecer contra equalização clássica ou depender da referência TX | Melhor ponto fixo/heurística resolver o problema |
| Hardware | Dispensável no protótipo; necessário para validação física | Bancada existente para evidência experimental | Bancada existente se limitado ao AFG; outras ações exigem interfaces adicionais |
| Alteração expressiva de hardware | Não prevista | Não prevista para ensaios em ar | Evitável restringindo ações; possível no escopo ampliado |
| Baseline decisivo | Binário absoluto, delta e predição clássica | Integrador Manchester e equalizador clássico | Melhor configuração fixa e controlador por regras |
| Viabilidade de artigo | Condicionada a dados e ganho específico do preditor | Candidata principal com bancada disponível | Condicionada a variação de canal e automação segura |
| Recomendação | Não iniciar DL antes de medir compressibilidade | Priorizar piloto de coleta e baselines | Manter escopo inicial restrito; não começar com RL |

## 1. Compressão temporal aprendida com resíduos

### Ideia e pergunta de pesquisa

Um preditor causal estima a próxima medição a partir do histórico. O transmissor compara a previsão com o valor real e envia um resíduo, em vez de repetir o valor absoluto.

```text
Histórico de FC: 80, 80, 81, 81
Previsão: 81 bpm; medição: 82 bpm; resíduo: +1 bpm
Receptor: previsão local 81 + resíduo recebido 1 = 82 bpm
```

**Pergunta:** para o mesmo limite de erro e a mesma política de entrega de eventos, um preditor aprendido reduz bytes, quadros e idade da informação mais que codecs determinísticos?

O baseline real já é compacto. Trocar ASCII por um protocolo binário pode gerar grande ganho sem ML, e deve ser uma experiência separada. O novo quadro pode incluir identificação de sessão/canal, máscara de variáveis, sequência, tempo ou cadência definida, resíduo, flags e CRC. A economia deve contabilizar esses campos e as referências periódicas.

Começar por reconstrução exata dos valores na resolução escolhida, com resíduos inteiros e uma GRU/TCN pequena apenas se os baselines justificarem seu uso. Quantização vetorial (VQ) com perdas é uma extensão, não um requisito. Transmissor e receptor devem atualizar o preditor com **o mesmo histórico reconstruído**, evitando divergência entre valores originais no TX e quantizados no RX.

A inspiração em `vq-gan_vlc.pdf` é conceitual: o artigo trabalha com imagens, não com telemetria clínica. Apenas prever e comprimir valores caracteriza compressão preditiva aprendida; a denominação “semântica” exige definir e avaliar uma tarefa ou relevância de eventos que vá além do erro médio numérico.

### Segurança e recuperação

O dado original continua chegando ao transmissor. Usar referência absoluta quando houver erro excessivo, mudança abrupta, ausência de dado, troca de sessão/canal, incerteza elevada ou evento reconhecido. Alarmes devem ser explícitos, protegidos e tratados separadamente da compressão.

Essas proteções não estão prontas no sistema atual. A ausência de alarmes no parser do monitor não significa ausência de evento no equipamento; a seleção de apenas um alarme da bomba também limita a avaliação. Corrigir essa cobertura ou delimitar explicitamente o escopo antes de alegar preservação clínica.

CRC e sequência permitem detectar problemas no receptor, mas solicitar retransmissão exige um canal de retorno definido. Sem retorno, usar referências periódicas e sinalizar reconstrução indisponível até a recuperação. A ponte ao backend deve conservar validade e tempo de origem; a UI externa precisa distinguir valores reconstruídos, medidos e desatualizados.

Uma primeira versão lossless reduz o risco de acrescentar distorção, mas não resolve perdas, atraso ou erros de interpretação. Qualquer estudo com perdas exige limites definidos com responsável clínico, avaliação de eventos e aprovação ética quando aplicável. A implementação é de pesquisa, não destinada a decisões clínicas sem validação apropriada.

### Dados e plano experimental

1. Reconstruir TCP e validar mensagens completas, fragmentação, coalescência, unidades, timestamps e canais. Desidentificar antes de versionar dados derivados.
2. Medir atualização, repetição, autocorrelação e compressibilidade das variáveis realmente extraídas. Não presumir séries de infusão inexistentes no parser atual.
3. Implementar baselines: legado, binário absoluto, delta coding, persistência e preditor linear, com a mesma proteção e política de referência. HL7 serve apenas como referência de volume na origem.
4. Obter sessões adicionais e separar treino/teste por sessão, equipamento e tempo, sem misturar amostras vizinhas. Ajustar janelas à cadência real, incluindo máscaras de ausência.
5. Treinar um modelo pequeno somente após identificar margem sobre os codecs clássicos. Avaliar VQ separadamente do ganho preditivo e do framing binário.
6. Testar perdas/erros em sequência, recuperação do estado e fallback. Simulação não substitui a validação do canal físico.
7. Integrar codec e framing opcionais com decodificação correspondente. Medir bytes totais, quadros, latência, idade da informação, entrega de eventos e fidelidade à fonte.

### Critérios de sucesso e contribuição

- Superar o melhor codec determinístico no mesmo orçamento de erro e proteção, incluindo overhead de referências e fallback.
- Preservar eventos dentro do escopo e detectar estado inválido/desatualizado após perdas.
- Demonstrar redução de quadros ou melhoria de entrega/idade da informação sob carga realista. Menos bytes não implica automaticamente menor BER ou maior margem óptica.
- Separar o benefício do ML dos ganhos de binarização, correções do parser e protocolo de segurança.

Redução de 50% contra o legado pode ser uma meta exploratória, mas não comprova contribuição de ML. Se persistência/delta alcançar desempenho equivalente, ou faltarem sessões variadas, esta linha deve ser suspensa como foco principal do artigo.

**Potencial científico:** compressão causal com recuperação de estado e avaliação conjunta fonte-enlace pode ser publicável; “usar GRU em sinais vitais” ou comparar apenas com HL7 não é uma contribuição suficiente. O principal obstáculo continua sendo diversidade de dados e ganho sobre métodos simples.

## 2. Equalização/detecção neural no receptor

### Ideia e pergunta de pesquisa

Uma rede pequena processa janelas de amostras recebidas e estima bits, símbolos Manchester ou um sinal equalizado. Pode complementar ou substituir a integração e decisão pareada, aprendendo ISI, distorção não linear e variação do canal.

```text
PD/TIA → aquisição → sincronização → equalizador/detector → bits → integridade/parser
```

**Pergunta:** sob o mesmo orçamento de sincronização, uma rede melhora BER medida, erro por quadro e disponibilidade frente ao integrador Manchester e a equalizadores clássicos, inclusive em condições físicas não vistas?

É a candidata principal quando a bancada está acessível: rótulos vêm dos bits enviados, não exigem anotação clínica e a intervenção pode permanecer no software. Os pares TX/RX já são parcialmente disponibilizados e há salvamento de respostas; falta transformar isso em campanha reprodutível. PCAPs fornecem payloads de teste, não sinais ópticos de treino.

### Sincronização: condição indispensável de validade

O sistema atual alinha e corrige polaridade usando todo o sinal TX. Há dois escopos possíveis:

- **Equalização com sincronização assistida:** todos os métodos recebem exatamente o mesmo alinhamento por referência. O artigo deve declarar essa assistência e limitar suas conclusões à detecção após sincronização.
- **Receptor independente de payload:** introduzir um preâmbulo conhecido e usar somente ele para sincronização/polaridade. Isso muda o framing por software, sem exigir novo hardware. Todos os métodos devem ter o mesmo preâmbulo e contabilizar seu overhead.

A segunda opção produz uma demonstração mais próxima de comunicação real, mas não comprova novidade de ML por si só. Não alimentar a rede com os bits desconhecidos de teste nem usar o payload TX como informação privilegiada apenas para um concorrente. O TX completo pode ser usado para rotular e medir erros offline, não como entrada operacional de um receptor declarado independente.

### Coleta e plano experimental

1. Aproveitar a infraestrutura existente e salvar bits TX, sinal TX ideal, aquisição bruta, taxa, parâmetros de aquisição e todas as tentativas/falhas de sincronismo. O retorno atual privilegia a aquisição bem-sucedida e precisa de extensão para rastrear falhas.
2. Registrar sessão/dia, receptor, distância, alinhamento, iluminação, amplitude AFG, polarização e ganho quando conhecidos. Preservar escala/calibração vertical: a leitura atual retorna códigos do ADC, não tensão calibrada.
3. Executar um piloto em ar, começando por um receptor e condições boas/degradadas. Variar distância, alinhamento e amplitude dentro de limites seguros; ampliar para outro receptor conforme disponibilidade.
4. Construir baselines: integrador Manchester atual, filtro/equalizador linear treinado com orçamento comparável e, quando aplicável, MMSE/DFE. Avaliar a sincronização separadamente.
5. Treinar primeiro MLP/CNN 1D pequena; aumentar complexidade apenas com ganho demonstrado. Janelas da mesma captura não podem ficar em treino e teste. Separar sessões/dias e reservar condições inteiras para generalização.
6. Testar bits aleatórios e payloads clínicos não vistos, para evitar memorização de padrões. Registrar erro por quadro, BER, falhas de sincronismo, número de bits/erros, intervalos de confiança e custo de inferência.
7. Comparar métodos sobre as mesmas aquisições offline e depois integrar a inferência à bancada. Medir throughput útil e latência incluindo upload/aquisição, não apenas execução da rede.

Q e EOP são métricas auxiliares do sinal, não substitutos de BER medida ou provas automáticas do ganho do detector. A estimativa atual de Q separa níveis pelo sinal das amostras integradas; sua relação com erros deve ser verificada em condições degradadas. Não excluir falhas de sincronismo da avaliação de disponibilidade para apresentar uma BER artificialmente favorável.

### Critérios de sucesso e contribuição

- Reduzir erros de maneira estatisticamente sustentada frente ao melhor baseline clássico, não somente ao integrador sem equalização.
- Ampliar a região operacional para uma BER/erro por quadro alvo: distância, desalinhamento ou menor amplitude, com comparação controlada.
- Generalizar para sessões e condições não vistas, sem degradar significativamente condições boas.
- Manter custo de inferência compatível com o ciclo medido do sistema.

**Potencial científico:** a contribuição deve estar na recepção Manchester-OOK experimental robusta sob banda limitada/distorção e transferência entre condições, não no uso isolado de CNN. A comparação entre sincronização assistida e por preâmbulo pode esclarecer quanto do desempenho depende da referência de bancada.

Os riscos são ausência de erros suficientes no piloto, vantagem desaparecer contra equalização clássica e sobreajuste ao hardware. Saturação severa pode destruir informação; uma rede não recupera sinais inexistentes. O simulador atual precisa de validação/calibração antes de sustentar resultados físicos. Testes em água não são necessários para a primeira contribuição e só devem ser acrescentados se houver infraestrutura e escopo claros.

## 3. Controle adaptativo contextual de configurações seguras

### Ideia e pergunta de pesquisa

Um controlador seleciona configurações a partir de observações recentes do enlace, tentando melhorar entrega útil sem operar fora de limites seguros.

**Pergunta:** diante de mudanças de distância, alinhamento ou iluminação, um seletor aprendido melhora entrega ou custo operacional frente ao melhor ponto fixo e a regras simples, descontando medição e exploração?

O escopo inicial deve usar **amplitudes discretas seguras do AFG**, já controláveis por software. Taxa e tamanho do quadro podem ser extensões, mas sua mudança exige coordenar geração, aquisição, framing e receptor. Corrente de polarização, temperatura e ganho do fotodetector não devem ser tratados como ações prontas: não há interfaces de controle disponíveis nesta cópia.

O Bias-Tee é um componente de acoplamento, não um atuador que, por si só, regula corrente. Controlar polarização exige interface com a fonte correspondente. Uma proposta restrita ao AFG evita alteração expressiva de hardware; ampliar o controle pode exigir instrumentação adicional.

### Observações e dados

Possíveis entradas incluem clipping, RMS, qualidade de sincronização, Q validado, histórico de entrega e carga da fila. BER medida contra TX completo pode orientar caracterização offline, mas não é feedback disponível automaticamente a um receptor independente. Para uso online, definir observações obtidas por preâmbulo/CRC e um caminho explícito de feedback, ou assumir e declarar controle centralizado de bancada.

Não usar o Q igual a zero do fluxo atual como medição. Também não equiparar amplitude AFG a potência óptica ou energia consumida: alegações energéticas exigem medição/calibração adequada.

### Plano experimental

1. Definir ações discretas, limites elétricos/térmicos e ponto de retorno seguro. Nenhuma exploração fora da faixa autorizada da bancada.
2. Reaproveitar a varredura de amplitude e registrar estado, ação, qualidade resultante, sessão e custo de aquisição. Variar condições de canal para evitar memorizar um ponto estático.
3. Comparar melhor configuração fixa, regras de clipping/qualidade, busca simples e regressão/árvores supervisionadas. Começar por seleção contextual supervisionada ou otimização bayesiana, não RL online.
4. Avaliar em sessões e trajetórias de mudança não vistas, primeiro offline e em modo de recomendação sem atuação.
5. Integrar controle conservador com rollback e limites de frequência de mudança. Contabilizar probes, uploads, espera do instrumento e interrupções durante adaptação.
6. Medir throughput útil, erro por quadro, disponibilidade, tempo de recuperação e estabilidade. Medir energia por bit apenas se houver medição de consumo.

### Critérios de sucesso e contribuição

- Superar ponto fixo e heurísticas após incluir o custo de adaptação.
- Demonstrar adaptação a mudanças reais, e não apenas escolha do ótimo de uma tabela estática.
- Evitar clipping persistente e configurações inseguras; explicitar os limites que o software não consegue observar.

**Potencial científico:** controle contextual fechado no enlace experimental pode ser relevante, mas o cenário precisa exigir adaptação. Se uma amplitude fixa segura resolver todas as condições, ML não se justifica. Esta linha é secundária até existir caracterização diversificada e feedback confiável. RL acrescenta risco e complexidade sem garantia de contribuição e não é recomendado como ponto de partida.

## Recomendação de trajetória e decisão

### Prioridade com a bancada disponível

**Priorizar a proposta 2 como hipótese de trabalho, não como resultado garantido.** Ela atua diretamente no enlace, aproveita pares TX/RX já retornados pelo MATLAB, permite rótulos automáticos e não requer alteração expressiva de hardware para ensaios em ar.

1. Consolidar uma coleta mínima reprodutível, com metadados e falhas, e medir o ciclo real de transmissão/aquisição.
2. Executar um piloto com integrador Manchester e equalizador clássico em condições de degradação controlada.
3. Definir sincronização assistida ou por preâmbulo e manter igualdade de informação entre métodos.
4. Testar uma rede pequena em condições reservadas. Só ampliar coleta/modelo após encontrar ganho específico de ML.

A proposta 1 pode avançar em paralelo como análise de compressibilidade, sem treinar DL de imediato. A proposta 3 pode reaproveitar a campanha física, mas só deve tornar-se foco se houver mudança de canal e vantagem sobre regras simples.

### Quando não avançar com uma proposta

| Resultado do piloto | Decisão |
| --- | --- |
| Predição clássica comprime tanto quanto ML | Não insistir na proposta 1 como artigo de ML; ampliar diversidade apenas se houver hipótese fundamentada. |
| Equalização clássica iguala a rede | Não atribuir ganho ao ML; investigar condições físicas relevantes ou encerrar a hipótese. |
| Enlace não apresenta erros na campanha | Não alegar redução de BER; ampliar condições seguras e volume ou mudar a pergunta. |
| Ponto fixo/heurística resolve a adaptação | Não iniciar RL para criar complexidade artificial; reconsiderar a proposta 3. |
| Bancada indisponível | Fazer parsers, codecs e protótipos em simulação, delimitando resultados; não apresentar validação experimental inexistente. |

### É necessário propor uma quarta linha agora?

Não há evidência suficiente para concluir que todas as propostas atuais são inviáveis. A equalização/detecção neural, reformulada com comparação clássica forte e sincronização explicitada, permanece uma hipótese verificável com mudanças predominantemente de software. Portanto, **não se acrescenta uma alternativa apenas para substituir uma contribuição ainda não testada por outra igualmente não comprovada**.

Uma reformulação útil dentro da proposta 2 é focar um **receptor independente de payload e robusto entre sessões**, combinando preâmbulo conhecido, equalização/detecção e avaliação de falhas. O preâmbulo é infraestrutura de baseline; a contribuição de ML ainda precisa vir de desempenho ou generalização superiores. Essa formulação é mais defensável que alegar um receptor fim a fim enquanto ele conhece toda a mensagem TX.

Correções de parser, CRC, sequência, coleta e sincronização podem ser essenciais à qualidade do trabalho, mas não são, isoladamente, contribuição de ML. O primeiro artigo deve ter um foco principal e ablações que separem infraestrutura, processamento clássico e aprendizado. Combinar as três linhas no primeiro trabalho tende a diluir a pergunta e multiplicar requisitos de dados.

## Referências e seu papel

- **Scripts MATLAB desta cópia e README:** base da arquitetura e dos limites operacionais. Afirmações de latência, segurança e métricas do README precisam de verificação experimental.
- **Relatório FINEP 2026:** caracteriza a bancada correlata em ar, banda, receptores, polarização e efeitos de saturação/distância; não fornece aqui um dataset bruto pronto para ML.
- **van der Zwaag (2020), `Dissertation_Klaas.pdf`:** contexto de VLC em ambientes de terapia intensiva e limitações do enlace.
- **van der Zwaag et al. (2021), “A Manchester-OOK visible light communication system for patient monitoring in intensive care units”, IEEE Access:** referência da aplicação clínica Manchester-OOK.
- **Chen et al. (2024), “Semantic-empowered visible light communication for image transmission based on deep convolutional generative adversarial network”, Optics Express, `vq-gan_vlc.pdf`:** comunicação semântica/VQ para imagens; seus ganhos não podem ser transferidos diretamente para telemetria compactada.
- **Ulkar et al. (2020), “VLCnet: Deep learning based end-to-end visible light communication system”, Journal of Lightwave Technology:** referência de DL para comunicação VLC.
- **Shi et al. (2023), “Optimal adaptive waveform design utilizing an end-to-end learning-based pre-equalization neural network in an UVLC system”, Journal of Lightwave Technology:** referência de adaptação/pré-equalização aprendida.
- **Camporez (2025), “AI-Based Strategies for Handover Enhancement in Visible Light Communication Systems”:** tese citada no relatório FINEP, contextualizando decisões adaptativas.

A alegação final de novidade requer revisão bibliográfica específica da linha escolhida; estas referências fundamentam a discussão, mas não demonstram ausência de trabalhos semelhantes.
