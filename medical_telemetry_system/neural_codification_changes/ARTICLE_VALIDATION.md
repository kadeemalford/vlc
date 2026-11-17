# Evidência para o artigo — prova de conceito neural no VLC

## Objetivo acordado em 17/11/2026

Demonstrar experimentalmente codificação/decodificação neural de HR/FC, SpO₂ e PR
no sistema VLC físico, com reconstrução e entrega ao painel legado.
**Sem comparação com métodos clássicos**, sem requisito de compressão, superioridade,
interceptação ou alegação de confidencialidade. Pressão arterial fora do escopo.

Resultados sustentam viabilidade funcional nas condições ensaiadas, não garantia
clínica ou desempenho probabilístico universal. Adequação editorial depende do
veículo; uma demonstração funcional não garante aceitação.

## Já observado segundo o usuário

- Roundtrips físicos sintéticos e replay de PR com reconstrução exata.
- Operação online monitor → encoder → Manchester/VLC → RX/decoder/CRC → gateway.
- PR-only com 29 observações aceitas, 29 codec_ok e 29 escritas gateway em uma
  rodada. Uma tentativa mostrada teve zero erros/392 bits e idade de 0,3647 s;
  não extrapolar essa tentativa às latências/BER de toda a rodada.
- Verificação visual de HR/FC, SpO₂ e PR no painel acompanhando o aparelho.
- Timeout do monitor após parada e AFG OFF ao encerrar.
- Artefatos físicos ainda não recebidos/auditados localmente. Testes de software
  não substituem campanha física; escrita TCP não confirma render.

## Coleta adicional recomendada, pequena e sem novos métodos

1. Auditar os MATs/events.jsonl já existentes: IDs, modelo congelado, hashes das
   fontes, RX real, resultados e tentativas completas/falhas.
2. Exemplo de repetibilidade: **três sessões de cinco minutos** na mesma condição,
   com novos identificadores/ponte entre sessões. Preservar todo evento, sem
   repetir seletivamente só falhas. É uma proposta operacional, não garantia
   de suficiência estatística para qualquer BER alvo.
3. Comparar visualmente os três campos com o monitor em instantes registrados;
   vídeo sem nomes/IDs é opcional, com autorização de pesquisa. Sem provocar
   alterações fisiológicas para obter variação.
4. Um controle de indisponibilidade: parar o fluxo e verificar inatividade,
   sem apresentar último valor como atualização nova. Falhas CRC/modelo podem
   continuar validadas offline, sem comandos médicos.
5. Registrar condição real: distância/alinhamento, alimentação/ganho, iluminação,
   AFG, canal, amostragem, banda e versões. Não copiar condições do artigo-base
   como se fossem medições atuais.

Não é necessário repetir toda a caracterização de distâncias/interferências do
artigo-base para esta prova de conceito. Limitar conclusões às condições testadas.

## Tabelas mínimas por sessão e variável

- Observações elegíveis, recusas, substituições de fila e expirações.
- Tentativas físicas, sync/CRC/codec aceitos e rejeitados.
- Reconstrução exata e erros de bytes quando verificáveis contra a origem.
- Erros/total de bits nos pacotes com RX alinhada avaliável.
- Escritas no gateway, falhas e verificação visual do painel.
- Idade recepção PC → escrita gateway: mediana, percentil 95 e máximo, com
  tamanho da amostra e descartes pelo limite de idade.

Ausência de RX alinhada não é BER zero; contabilizar indisponibilidade separada.
Zero erros observados não significa probabilidade de erro zero. Não tratar
mensagens repetidas/amostras da mesma sessão como experimentos independentes
sem justificar a análise.

`age_at_gateway_write_seconds` **não mede** latência aparelho→render. Para publicar
latência até o painel, instrumentar recebimento/render Web ou usar método
audiovisual com resolução/limitações declaradas. Até lá, relatar a idade medida
até escrita TCP e a confirmação visual de atualização como evidências distintas.

## Transparência da contribuição

Explicitar a arquitetura por byte e treino exaustivo dos 256 símbolos, sem chamar
isso de generalização clínica. A rede não aprende o canal nem substitui Manchester.
Latentes expandem 2×; NC1 leva um frame de 10 bytes a 49 bytes/392 bits (4,9× antes
de Manchester). Hash de modelo/CRC não são chave ou autenticação.
Sync continua assistida pelo TX completo; não alegar receptor independente.

Não há comparação clássica exigida neste plano. A contribuição alegada é a
implementação e demonstração experimental da camada neural integrada ao enlace
e à aplicação, com fidelidade e limitações documentadas.
