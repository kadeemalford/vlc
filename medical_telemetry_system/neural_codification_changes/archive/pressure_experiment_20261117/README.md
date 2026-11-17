# Experimento de pressão retirado do caminho ativo

Snapshots `.reference` preservam sete fontes/testes anteriores à retirada da
pressão arterial solicitada em 17/11/2026. Não são código de execução e não devem
ser adicionados ao path. Não fazem parte dos 17 snapshots originais do legado.

Motivo de escopo: pressão não é uma variável continuamente medida nesta bancada
e o frontend mantém o último valor. O artigo ativo fica com HR/FC, SpO₂ e PR.
Isso não demonstra que ausência de transmissão tenha sido a única causa técnica
da rejeição do par observado. As capturas/resultados anteriores não foram apagados.

As regras de pressão/diagnóstico que permanecem no parser são somente auxiliares
históricos de inspeção; LiveBridge, IPC e runner ativo recusam pressão.
