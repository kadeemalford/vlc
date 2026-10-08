clear all; close all; clc;

% --- Configuração de Caminhos ---
srcPath = fileparts(fileparts(mfilename('fullpath')));
addpath(genpath(srcPath));
dataPath = fileparts(fileparts(fileparts(mfilename('fullpath'))));
dataPath = dataPath + "\data";

% --- Definição das variáveis para os loops ---
ibias = [100 200 300 400 500 600 700 800]; 
afgs = ["0p5" "1" "1p5" "2" "2p5" "3"]; 

% --- Inicialização da Matriz de Resultados ---
eopsEsqMatrix = zeros(length(ibias), length(afgs));

% --- 1. Análise Completa para Coletar os Dados ---
disp("Iniciando análise de todos os arquivos...");
for idx_ibias = 1:length(ibias)
    current_ibias = ibias(idx_ibias); 
    folderName = "ibias_" + current_ibias + "mA";
    disp("Processando pasta: " + folderName);
    
    for idx_afg = 1:length(afgs)
        afg = afgs(idx_afg);
        filePath = dataPath + "\" + folderName + "\afg_" + afg + ".mat";
        
        if isfile(filePath)
            load(filePath);

            if(responses(1).synchSuccessful)
                response = responses(1);
                samplesEsquerda = response.eyeDiagramSegments(:,3); 
                onesIdx = samplesEsquerda >= 0;
                zerosIdx = samplesEsquerda < 0;
                bit1Samples = samplesEsquerda(onesIdx);
                bit0Samples = samplesEsquerda(zerosIdx);
                eopEsq = min(bit1Samples) - max(bit0Samples);
                
                if eopEsq <= 0, eopEsq = NaN; end
                
                eopsEsqMatrix(idx_ibias, idx_afg) = eopEsq;
            else
                eopsEsqMatrix(idx_ibias, idx_afg) = NaN;
            end
        else
            eopsEsqMatrix(idx_ibias, idx_afg) = NaN; 
        end
    end
end
disp("Análise concluída.");
eopsEsqMatrix

% =========================================================================
%% 2. GERAÇÃO DOS GRÁFICOS DE RESUMO
% =========================================================================
afgs_numeric = 0.5:0.5:3;
legendas = "Ibias = " + string(ibias') + " mA";

% Gráfico "linear"
figure('Name', 'Resultados: Abertura do Olho (EOP)'); 
hold on;
for idx = 1:length(ibias)
    plot(afgs_numeric, eopsEsqMatrix(idx, :), 'o-', 'LineWidth', 2);
end
hold off;
title("linear"); xlabel('Valor de AFG'); ylabel('Abertura do Olho (EOP)');
legend(legendas, 'Location', 'best'); grid on;

% Gráfico "log"
figure('Name', 'Resultados: Penalidade em dB');
hold on;
for idx = 1:length(ibias)
    penalidade_dB = 10 * log10(2 ./ eopsEsqMatrix(idx, :));
    plot(afgs_numeric, penalidade_dB, 's--', 'LineWidth', 2);
end
hold off;
title("log"); xlabel('Valor de AFG'); ylabel('Penalidade (dB)');
legend(legendas, 'Location', 'best'); grid on;


% =========================================================================
%% 3. ENCONTRAR E PLOTAR O DIAGRAMA DE OLHO DOS MELHORES RESULTADOS
% =========================================================================
disp("Gerando diagramas de olho para os melhores resultados...");
for idx_ibias = 1:length(ibias)
    
    [max_eop, idx_best_afg] = max(eopsEsqMatrix(idx_ibias, :));
    
    if ~isnan(max_eop)
        current_ibias = ibias(idx_ibias);
        best_afg_value = afgs(idx_best_afg);
        
        folderName = "ibias_" + current_ibias + "mA";
        filePath = dataPath + "\" + folderName + "\afg_" + best_afg_value + ".mat";
        
        load(filePath);
        
        figure('Name', "Melhor Olho para Ibias = " + current_ibias + "mA");
        plot(responses(1).eyeDiagramSegments');
        grid on;
        xlabel('Amostras de Tempo');
        ylabel('Amplitude');
        title("Diagrama de Olho (Melhor Resultado): Ibias=" + current_ibias + "mA, AFG=" + best_afg_value);
        
        disp("  - Para Ibias = " + current_ibias + "mA, o melhor AFG é " + best_afg_value + " (EOP = " + max_eop + ")");
    end
end