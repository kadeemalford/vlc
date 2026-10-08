clear all; close all;
% getting the path of this script and going two folder back (../../)
srcPath = fileparts(fileparts(mfilename('fullpath')));

% add scripts path
addpath(genpath(srcPath));

dataPath = fileparts(fileparts(fileparts(mfilename('fullpath'))));
dataPath = dataPath + "\data\";

ibias = [100 200 300];

datas = [];
afgs = ["0p5" "1" "1p5" "2" "2p5" "3"];
afgData = [];
eopsEsq = [];
% afgs = "2p5";
for afg = afgs
    load(dataPath + "ibias_100mA\afg_" + afg + ".mat");
    
    % considerando apenas a primeira iteração
    if (responses(1).synchSuccessful)
        response = responses(1);
        
        % plot diagrama de olho em vermelho
        figure
        plot(response.eyeDiagramSegments', 'Color', [1 0 0]) % codigo para cor vermelha
        title(afg)
       
        % Diretório onde deseja salvar a figura
        diretorio = 'C:\Users\Higor Camporez\Desktop\projects\finep\vlc-system\figuras para o relatório - eyediagram';

    resposta = questdlg('Deseja salvar essa figura?', ...
    'Salvar Figuras', ...
    'Sim', 'Não', 'Não');

    if strcmp(resposta, 'Sim')
        figs = findall(0, 'Type', 'figure');   % pega todas as figuras abertas
        caminhos = cell(numel(figs),1);        % pré-aloca os nomes

        for i = 1:numel(figs)
            nomeArquivo = sprintf('diagrama_olho_%02d.png', i);
            caminhoCompleto = fullfile(diretorio, nomeArquivo);
            exportgraphics(figs(i), caminhoCompleto, 'Resolution', 150);
            caminhos{i} = caminhoCompleto;      % guarda o caminho
        end
        
    else
        disp('Figura não salva.');
 end

        %% análise da abertura esquerda (coluna 3)
        % separa bits zeros e uns
        samplesEsquerda = [response.eyeDiagramSegments(:,3); responses(1).eyeDiagramSegments(:,3)];
        onesIdx = samplesEsquerda >= 0;
        zerosIdx = samplesEsquerda < 0;
        bit1Samples = samplesEsquerda(onesIdx);
        bit0Samples = samplesEsquerda(zerosIdx);
        
        % calcular eop para pior caso de zeros e uns
        eopEsq = min(bit1Samples) - max(bit0Samples);
        eopsEsq = [eopsEsq eopEsq];
        
        %% análise da abertura direita (coluna 8)
        
    else
        error("não sincronizado");
    end
    
end

figure
plot(0.5:0.5:3, eopsEsq)
title("linear")

figure
plot(0.5:0.5:3, 10*log10(2./eopsEsq))
title("log")

