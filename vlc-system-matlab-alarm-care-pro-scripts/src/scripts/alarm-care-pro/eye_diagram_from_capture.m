clear;
clc;
%% eye_diagram_from_capture.m
% Diagrama de olho de cada waveform capturada pelo pipeline em tempo real.
%
% Le o .mat gravado por real_time_mae_vlc.m (config.SAVE_SIGNALS, ligado por
% padrao) e chama eye_diagram_exp uma vez por sinal, com 'Manchester', true e
% sps = amostras por chip gravado em capture.sps. Roda OFFLINE: nao precisa do
% MDO3012, do AFG nem do enlace optico.
%
% O que real_time_mae_vlc.m salva por frame em capture:
%   capture.signals{k}  amostras de response.synchSignal, ou seja, o RX
%                       normalizado pelo pico, reamostrado para a taxa do TX
%                       (10 MSps) e alinhado com o TX. Ja esta na grade de
%                       chips, que e o que o diagrama de olho precisa.
%   capture.sps(k)      amostras por chip = resampleFactor/2 = 5
%   capture.meta(k)     frame enviado, frame recebido, BER, Q, nSamples, ...
%
% Como executar a partir da raiz do repositorio:
%   eye_diagram_from_capture
%
% Para apontar para outra captura ou mudar os defaults:
%   cfg = struct('MAT_FILE', 'C:\...\outro.mat', 'MAX_SIGNALS', 3);
%   eye_diagram_from_capture
% (so os campos passados mudam; o resto fica no default. Os defaults
%  fixados no bloco "cfg desta execucao" abaixo so sao aplicados aos campos
%  AUSENTES de cfg, entao um cfg definido no workspace tem prioridade.)
%
% Também le .mat gerados por store_received_signal.m (bits aleatorios, RX
% CRU do MDO, sem sincronizacao). Nesses casos:
%   - nao ha frame clinico: a contagem de bits do titulo vem de
%     capture.txBits / capture.info.nBits (500), nao de 8 + 8*numel(frame);
%   - a amplitude crua esta em contagens int8 do MDO (~-60 a 60) e e
%     normalizada pela amplitude PLENA pico a pico (entre os patamares
%     globais) na hora de desenhar (cfg.NORMALIZE = true; as capturas do
%     real_time_mae_vlc.m ja vem em +-1, entao la e so reescalada);
%   - cfg.OVERSAMPLING (padrao []) permite FORCAR o oversampling por BIT do
%     sinal gravado (ex.: 10 = resampleFactor -> 5 amostras por chip), em vez
%     de usar capture.sps (que vem de fs/(2*bitRate) e pode nao ser exato).
%
% Saidas em data/figures/mae_eye/:
%   mae_eye_<iter>.png / .pdf     um diagrama de olho por sinal
%   mae_eye_grid.png/.pdf/.fig    todos os olhos numa grade (PER_FIGURE = false)
%   mae_eye_summary.csv/.mat      Q, BER, nSym e bitConf de cada sinal
%
% Observacoes que valem para interpretar os resultados:
%   - O sinal e Manchester-OOK a 1 Mbps: 2 chips por bit. O eixo horizontal
%     default (XLIM = [0 2]) mostra 2 periodos de bit alinhados nas fronteiras
%     de bit. Use XLIM = [-0.5 1.5] para uma janela de 2 bits comecando numa
%     transicao de meio de bit.
%   - Q e BER sao estimados no nivel de CHIP (eye_diagram_exp mantem Q/BER por
%     chip no modo Manchester). bitConf ~ 1 confirma que o sinal e Manchester
%     de verdade; abaixo de 0.9 a captura nao presta para o diagrama.
%   - Um frame de ate 58 caracteres vira 472 bits = 944 chips. Abaixo de 1000
%     simbolos a estimativa de Q/BER e ruidosa; por isso o script silencia o
%     aviso 'fewSymbols' e reporta nSym na tabela resumo.

%% ------------------------------------------------------------------ config
root = fileparts(fileparts(fileparts(fileparts(mfilename('fullpath')))));
addpath(fullfile(root, 'src', 'scripts', 'alarm-care-pro'));
addpath(genpath(fullfile(root, 'src', 'main')));

if ~exist('cfg', 'var') || ~isstruct(cfg)
    cfg = struct();
end

% cfg desta execucao: edite os caminhos aqui para trocar de captura. Campos
% ja presentes em cfg (ex.: definidos no workspace antes de rodar) NAO sao
% sobrescritos, entao `cfg = struct('MAX_SIGNALS', 3); eye_diagram_from_capture`
% continua funcionando.
hardcodedCfg = struct( ...
    'MAT_FILE', fullfile(root, 'data', 'figures', 'received_signal_capture_1.0m.mat'), ...
    'OUT_DIR', fullfile(root, 'data', 'figures', 'eye_diagram_received_signal_capture_1.0m'), ...
    'IS_B2B', false ...
    );
hardcodedNames = fieldnames(hardcodedCfg);
for hc = 1:numel(hardcodedNames)
    if ~isfield(cfg, hardcodedNames{hc}) || isempty(cfg.(hardcodedNames{hc}))
        cfg.(hardcodedNames{hc}) = hardcodedCfg.(hardcodedNames{hc});
    end
end

cfg = applyDefaults(cfg, root);

% Os avisos do eye_diagram_exp viram colunas da tabela resumo (nSym e
% bitConf), que dizem o mesmo sem repetir a mesma frase 20 vezes.
savedWarnings = warning('off', 'eye_diagram_exp:fewSymbols');
savedWarnings(2) = warning('off', 'eye_diagram_exp:notManchester');
warningCleanup = onCleanup(@() restoreWarningState(savedWarnings));

%% ------------------------------------------------------------------ captura
if ~isfile(cfg.MAT_FILE)
    error(['Captura nao encontrada: %s\nRode real_time_mae_vlc antes, ou ' ...
        'ajuste cfg.MAT_FILE.'], cfg.MAT_FILE);
end
loaded = load(cfg.MAT_FILE);
if ~isfield(loaded, 'capture')
    error('%s nao contem a variavel ''capture''.', cfg.MAT_FILE);
end
capture = loaded.capture;
nTotal = numel(capture.signals);

% Numero de bits transmitidos por sinal. Capturas do store_received_signal.m
% guardam os bits em capture.txBits (ou capture.info.nBits) e nao tem frame
% clinico; nas capturas do real_time_mae_vlc.m o payload continua sendo o
% frame ASCII (8 bits de comprimento + 8 por caractere).
nBitsFixed = NaN;
if isfield(capture, 'txBits') && ~isempty(capture.txBits)
    nBitsFixed = numel(capture.txBits);
elseif isstruct(capture.info) && isfield(capture.info, 'nBits') ...
        && ~isempty(capture.info.nBits)
    nBitsFixed = double(capture.info.nBits);
end

fprintf('Captura: %s\n', cfg.MAT_FILE);
fprintf('  %d waveform(s) | %d sem sync | gravado em %s\n', nTotal, ...
    fieldOr(capture.info, 'nFailedSync', NaN), ...
    fieldOr(capture.info, 'savedAt', fieldOr(capture.info, 'createdAt', '?')));
fprintf('  Rb = %.3f Mbps | fs = %s | amostras por chip = %s\n', ...
    fieldOr(capture.info, 'bitRate', NaN) / 1e6, ...
    fmtHz(unique(capture.fs(capture.fs > 0))), ...
    mat2str(unique(capture.sps(isfinite(capture.sps)))));
if ~isnan(nBitsFixed)
    fprintf('  bits por sinal = %d (capture.txBits/info.nBits)\n', nBitsFixed);
else
    fprintf('  bits por sinal = 8 + 8*numel(frame) (payload ASCII do frame)\n');
end
if ~isempty(cfg.OVERSAMPLING)
    fprintf('  oversampling forcado = %g amostras/bit -> %g amostras por chip (cfg.OVERSAMPLING)\n', ...
        cfg.OVERSAMPLING, cfg.OVERSAMPLING / 2);
end
if cfg.NORMALIZE
    fprintf('  amplitude: normalizada pela amplitude plena pico a pico (patamares globais) (cfg.NORMALIZE = true)\n');
else
    fprintf('  amplitude: bruta, como gravada no .mat (cfg.NORMALIZE = false)\n');
end

%% ---------------------------------------------------------------- selecao
% Um sinal so serve para o diagrama de olho se tem amostras finitas e pelo
% menos MIN_CHIPS chips. eye_diagram_exp exige nSym >= 2 e avisa abaixo de
% 1000; abaixo de MIN_CHIPS o olho nao tem amostra suficiente para virar nada.
usable = false(1, nTotal);
for k = 1:nTotal
    x = capture.signals{k};
    spsK = effectiveSps(capture.sps(k), cfg);
    usable(k) = ~isempty(x) && all(isfinite(x(:))) && numel(x) >= cfg.MIN_CHIPS * spsK;
end
idx = find(usable);
nUsable = numel(idx);

if ~isempty(cfg.FRAME_FILTER)
    keep = false(1, numel(idx));
    for a = 1:numel(idx)
        keep(a) = contains(capture.meta(idx(a)).frame, cfg.FRAME_FILTER);
    end
    idx = idx(keep);
end

idx = idx(1:cfg.STRIDE:end);
nAfterFilter = numel(idx);
if ~cfg.CONCATENATE && isfinite(cfg.MAX_SIGNALS) && numel(idx) > cfg.MAX_SIGNALS
    idx = idx(1:cfg.MAX_SIGNALS);
end
nAfterMax = numel(idx);

if ~cfg.CONCATENATE && cfg.PLOT && ~cfg.PER_FIGURE && numel(idx) > cfg.GRID_MAX
    idx = idx(1:cfg.GRID_MAX);
end

fprintf('\n%d de %d waveform(s) utilizavel(is)', nUsable, nTotal);
if nAfterFilter < nUsable
    fprintf(', %d apos FRAME_FILTER', nAfterFilter);
end
if nAfterMax < nAfterFilter && ~cfg.CONCATENATE
    fprintf(', %d apos MAX_SIGNALS/STRIDE', nAfterMax);
end
fprintf('.\n');
if isempty(idx)
    fprintf('Nada a desenhar.\n');
    return;
end

%% ---------------------------------------------------------------- B2B Reference
% Carrega EOref se nao estiver no modo IS_B2B
EOref = NaN;
if cfg.IS_B2B
    fprintf('Modo B2B ativado: calculando e gravando EOref de referencia...\n');
else
    if isfile(cfg.B2B_REF_FILE)
        refData = load(cfg.B2B_REF_FILE);
        if isfield(refData, 'EOref') && isfinite(refData.EOref) && refData.EOref > 0
            EOref = refData.EOref;
            fprintf('Referencia B2B carregada: EOref = %.4f (de %s)\n', EOref, cfg.B2B_REF_FILE);
        else
            warning('Arquivo B2B de referencia nao possui variavel EOref valida.');
        end
    else
        fprintf('Aviso: Arquivo de referencia B2B nao encontrado (%s). EOP ficara como NaN.\n', cfg.B2B_REF_FILE);
    end
end

%% ----------------------------------------------------------------- figuras
if ~cfg.CONCATENATE && cfg.PLOT && ~cfg.PER_FIGURE
    gridFig = newGridFigure(numel(idx), cfg.VISIBLE);
    gridAxes = newGridAxes(gridFig, numel(idx));
    gridPos = 0;
end

%% -------------------------------------------------------------------- execucao
rows = emptyRows();

% Se habilitado, sintetiza o sinal TX para realizar a sincronizacao exata
txSignalObj = [];
params = [];
if cfg.SYNC_WITH_TX
    try
        params = ManchesterOokParameters();
        if isfield(capture, 'info') && isstruct(capture.info)
            if isfield(capture.info, 'bitRate') && isfinite(capture.info.bitRate)
                params.setBitRate(double(capture.info.bitRate));
            end
        end
        encoder = ManchesterOokEncoder(params);

        % Identifica os bits transmitidos
        bitsTx = [];
        if isfield(capture, 'txBits') && ~isempty(capture.txBits)
            bitsTx = capture.txBits;
        elseif isfield(capture, 'info') && isfield(capture.info, 'seed') && isfield(capture.info, 'nBits')
            rng(capture.info.seed, 'twister');
            bitsTx = randi([0 1], 1, capture.info.nBits);
        end

        if ~isempty(bitsTx)
            txSignalObj = encoder.generateBaseBandSignal(bitsTx);
            fprintf('Sincronizacao ativada: TX de referencia sintetizado (%d bits, %d amostras @ %.2e Hz)\n', ...
                numel(bitsTx), txSignalObj.getLength(), txSignalObj.getSampleRate());
        else
            fprintf('Aviso: Bits do TX nao identificados no .mat. Sincronizacao sera ignorada.\n');
        end
    catch ME
        fprintf('Aviso: Falha ao preparar TX de referencia (%s). Sincronizacao ignorada.\n', ME.message);
    end
end

if cfg.CONCATENATE
    fprintf('\n[CONCATENATE = true] Processando %d waveform(s)...\n', numel(idx));
    xConcat = [];
    spsRef = effectiveSps(capture.sps(idx(1)), cfg);
    totalBits = 0;
    nSynched = 0;

    for a = 1:numel(idx)
        k = idx(a);
        xk = double(capture.signals{k}(:));
        fsK = capture.fs(k);
        if ~isfinite(fsK) || fsK <= 0
            if ~isempty(params)
                fsK = params.txSampleRate;
            else
                fsK = 10e6;
            end
        end

        % Se possivel, sincroniza com precisao de amostra via correlacao cruzada
        if ~isempty(txSignalObj)
            try
                rxTimes = 0 : 1/fsK : ((numel(xk)-1)/fsK);
                rxSig = Signal(xk, rxTimes, fsK);
                % Reamostra se necessario
                if txSignalObj.getSampleRate() ~= rxSig.getSampleRate()
                    rxSig = SignalUtils.resampleSignalToMatchSampleRate(txSignalObj, rxSig);
                end
                rxSigNorm = SignalUtils.normalizeSignal(rxSig);
                syncSig = SignalUtils.synchronizeSignals(txSignalObj, rxSigNorm);
                xk = syncSig.getSamples();
                xk = xk(:);
                spsRef = round(txSignalObj.getSampleRate() / (2 * params.bitRate));
                
                % Normalizacao pela amplitude plena pico a pico entre os
                % patamares globais (Secao 5.1 da dissertacao): mede os
                % patamares nos pulsos mais largos/estaveis, sem ser
                % influenciada por overshoot nem pela media dos chips.
                if cfg.NORMALIZE
                    xk = normalizePlateauP2P(xk, spsRef);
                end
                nSynched = nSynched + 1;
            catch ME
                % Se falhar o alignsignals, mantem sinal com normalizacao por patamares
                if cfg.NORMALIZE
                    xk = normalizePlateauP2P(xk, spsRef);
                end
            end
        else
            if cfg.NORMALIZE
                xk = normalizePlateauP2P(xk, spsRef);
            end
        end

        xConcat = [xConcat; xk]; %#ok<AGROW>
        totalBits = totalBits + bitsOf(capture.meta(k), nBitsFixed);
    end

    if nSynched > 0
        fprintf('  %d/%d waveforms alinhadas e sincronizadas com sucesso ao TX!\n', nSynched, numel(idx));
    end

    fig = [];
    ax = [];
    if cfg.PLOT
        fig = figure('Name', 'Diagrama de Olho Concatenado (Sincronizado)', ...
            'Color', 'w', 'Position', [100 100 900 620], 'Visible', cfg.VISIBLE);
        ax = axes(fig);
    end

    % Quando sincronizado ao TX, os bits comecam exatamente no inicio
    isSynced = (nSynched == numel(idx));
    [BER, Q, info] = eye_diagram_exp(xConcat, spsRef, 'Manchester', true, ...
        'Density', cfg.DENSITY, 'XLim', cfg.XLIM, 'Plot', cfg.PLOT, 'Axes', ax, ...
        'SyncedTx', isSynced, 'FixedBitStart', 1);

    % Calculo de EOP (Equacao 3.12 da dissertacao)
    EOrec = info.EO;
    if cfg.IS_B2B
        EOref = EOrec;
        EOP = 0; % Na propria calibracao B2B
        b2bDir = fileparts(cfg.B2B_REF_FILE);
        if ~isempty(b2bDir) && ~isfolder(b2bDir)
            mkdir(b2bDir);
        end
        save(cfg.B2B_REF_FILE, 'EOref', 'info', 'cfg');
        fprintf('>>> EOref = %.4f salvo com sucesso em: %s\n', EOref, cfg.B2B_REF_FILE);
    else
        if isfinite(EOref) && EOref > 0 && isfinite(EOrec) && EOrec > 0
            EOP = 10 * log10(EOref / EOrec);
        else
            EOP = NaN;
        end
    end

    if cfg.PLOT
        titleStr = sprintf('Diagrama Acumulado (%d sinais, ~%d bits) | Q = %.2f (%.2f dB) | BER = %.2e', ...
            numel(idx), totalBits, Q, qDb(Q), BER);
        if isfinite(EOP)
            titleStr = sprintf('%s | EOP = %.2f dB', titleStr, EOP);
        end
        title(ax, {titleStr, ...
            sprintf('EO = %.4f (EO_{ref} = %.4f) | sps = %d | %d chips (2º chip)', ...
                EOrec, EOref, round(spsRef), info.nSym)});
    end

    if cfg.PLOT && cfg.SAVE_OUTPUTS
        baseName = fullfile(cfg.OUT_DIR, 'mae_eye_concatenated');
        exportgraphics(fig, [baseName '.png'], 'Resolution', 300);
        exportgraphics(fig, [baseName '.pdf'], 'ContentType', 'vector');
    end

    fprintf('\n%-9s %-8s %-8s %-9s %-8s %-8s %-7s %-7s\n', ...
        'Qeye', 'Qeye_dB', 'berEye', 'EO', 'EO_ref', 'EOP_dB', 'nSym', 'bitConf');
    fprintf('%s\n', repmat('-', 1, 80));
    fprintf('%-9.2f %-8.2f %-9.2e %-8.4f %-8.4f %-8.2f %-7d %-7.2f\n', ...
        Q, qDb(Q), BER, EOrec, EOref, EOP, info.nSym, info.bitConf);

    r = struct();
    r.idx = 1;
    r.iteration = 1;
    r.stamp = datestr(now, 'HH:MM:SS');
    r.frame = 'concatenated';
    r.nBits = totalBits;
    r.nSamples = numel(xConcat);
    r.berLink = NaN;
    r.qLink = NaN;
    r.Qeye = Q;
    r.QeyeDb = qDb(Q);
    r.berEye = BER;
    r.EO = EOrec;
    r.EOref = EOref;
    r.EOP = EOP;
    r.nSym = info.nSym;
    r.phase = info.phase;
    r.bitStart = info.bitStart;
    r.bitConf = info.bitConf;
    r.corrupted = false;
    r.status = 'ok';
    rows = r;

else
    % Modo sinal a sinal (individual)
    fprintf('\n%-5s %-6s %-9s %-8s %-8s %-9s %-8s %-8s %-7s %-7s %s\n', ...
        'idx', 'iter', 'berLink', 'Qeye', 'Qeye_dB', 'berEye', 'EO', 'EOP_dB', 'nSym', 'bitConf', 'frame');
    fprintf('%s\n', repmat('-', 1, 110));

    for a = 1:numel(idx)
        k = idx(a);
        meta = capture.meta(k);
        x = double(capture.signals{k});
        sps = effectiveSps(capture.sps(k), cfg);
        if sps < 2
            fprintf('%-5d %-6d sps invalido (%g): ignorado\n', k, meta.iteration, sps);
            continue;
        end

        if cfg.NORMALIZE
            x = normalizePlateauP2P(x, sps);
        end
        nBits = bitsOf(meta, nBitsFixed);

        fig = [];
        ax = [];
        if cfg.PLOT
            if cfg.PER_FIGURE
                fig = figure('Name', sprintf('Olho %04d', meta.iteration), ...
                    'Color', 'w', 'Position', [100 100 900 620], 'Visible', cfg.VISIBLE);
                ax = axes(fig);
            else
                gridPos = gridPos + 1;
                ax = gridAxes(gridPos);
            end
        end

        try
            [BER, Q, info] = eye_diagram_exp(x, sps, 'Manchester', true, ...
                'Density', cfg.DENSITY, 'XLim', cfg.XLIM, 'Plot', cfg.PLOT, 'Axes', ax);
        catch err
            fprintf('%-5d %-6d eye_diagram_exp falhou: %s\n', k, meta.iteration, err.message);
            if ~isempty(fig)
                close(fig);
            end
            continue;
        end

        EOrec = info.EO;
        if isfinite(EOref) && EOref > 0 && isfinite(EOrec) && EOrec > 0
            EOP = 10 * log10(EOref / EOrec);
        else
            EOP = NaN;
        end

        corrupted = ~strcmp(meta.frameRx, meta.frame);
        status = 'ok';
        if info.bitConf < 0.9
            status = sprintf('bitConf %.2f: sinal nao parece Manchester', info.bitConf);
        end
        if corrupted
            status = [status ' + frame corrompido no canal'];
        end

        if cfg.PLOT
            subTitle = sprintf('Q = %.2f (%.2f dB) | BER = %.2e | sps = %d | %d chips', ...
                Q, qDb(Q), BER, round(sps), info.nSym);
            if isfinite(EOP)
                subTitle = sprintf('%s | EOP = %.2f dB', subTitle, EOP);
            end
            title(ax, {eyeTitle(meta, cfg.TRUNC_FRAME, nBits), subTitle});
        end

        if cfg.PLOT && cfg.PER_FIGURE && cfg.SAVE_OUTPUTS
            baseName = fullfile(cfg.OUT_DIR, sprintf('mae_eye_%04d', meta.iteration));
            exportgraphics(fig, [baseName '.png'], 'Resolution', 300);
            exportgraphics(fig, [baseName '.pdf'], 'ContentType', 'vector');
        end

        fprintf('%-5d %-6d %-9.2e %-8.2f %-8.2f %-9.2e %-8.4f %-8.2f %-7d %-7.2f %s\n', ...
            k, meta.iteration, meta.ber, Q, qDb(Q), BER, EOrec, EOP, info.nSym, info.bitConf, ...
            truncateLabel(meta.frame, 24));
        if ~strcmp(status, 'ok')
            fprintf('      ^ %s\n', status);
        end

        r = struct();
        r.idx = k;
        r.iteration = meta.iteration;
        r.stamp = meta.stamp;
        r.frame = meta.frame;
        r.nBits = nBits;
        r.nSamples = numel(x);
        r.berLink = meta.ber;
        r.qLink = meta.q;
        r.Qeye = Q;
        r.QeyeDb = qDb(Q);
        r.berEye = BER;
        r.EO = EOrec;
        r.EOref = EOref;
        r.EOP = EOP;
        r.nSym = info.nSym;
        r.phase = info.phase;
        r.bitStart = info.bitStart;
        r.bitConf = info.bitConf;
        r.corrupted = corrupted;
        r.status = status;
        rows(end + 1) = r; %#ok<SAGROW>
    end

    if cfg.PLOT && ~cfg.PER_FIGURE
        sgtitle(gridFig, sprintf('Diagramas de olho | %s', captureName(cfg.MAT_FILE)), ...
            'FontWeight', 'normal');
        if cfg.SAVE_OUTPUTS
            baseName = fullfile(cfg.OUT_DIR, 'mae_eye_grid');
            exportgraphics(gridFig, [baseName '.png'], 'Resolution', 300);
            exportgraphics(gridFig, [baseName '.pdf'], 'ContentType', 'vector');
            savefig(gridFig, [baseName '.fig']);
        end
    end
end

%% ------------------------------------------------------------------ resumo
if isempty(rows)
    fprintf('\nNenhum diagrama de olho foi produzido.\n');
    return;
end
% 'AsArray' obriga uma linha por elemento tambem no caso de UMA captura
% util: sem ele struct2table falha num struct escalar com campos de tamanhos
% diferentes (ex.: frame '' x stamp 'HH:MM:SS').
eyeTable = struct2table(rows, 'AsArray', true);
validEop = eyeTable.EOP(isfinite(eyeTable.EOP));
eopMsg = '';
if ~isempty(validEop)
    eopMsg = sprintf(' | EOP medio = %.2f dB', mean(validEop));
end
fprintf(['\nQ medio = %.2f (%.2f dB) | BER medio = %.2e | EO medio = %.4f%s ' ...
         '| pior Q = %.2f | %d/%d sinais com Q > 0\n'], ...
    mean(eyeTable.Qeye), mean(eyeTable.QeyeDb), mean(eyeTable.berEye), ...
    mean(eyeTable.EO), eopMsg, min(eyeTable.Qeye), sum(eyeTable.Qeye > 0), height(eyeTable));

if cfg.SAVE_OUTPUTS
    save(fullfile(cfg.OUT_DIR, 'mae_eye_summary.mat'), 'eyeTable', 'cfg');
    writetable(eyeTable, fullfile(cfg.OUT_DIR, 'mae_eye_summary.csv'));
    fprintf('Resumo salvo em %s\n', fullfile(cfg.OUT_DIR, 'mae_eye_summary.csv'));
end

%% ======================================================================
%                            FUNCOES LOCAIS
% ======================================================================

function cfg = applyDefaults(cfg, root)
%APPLYDEFAULTS Preenche os campos ausentes de cfg com o default e cria a pasta
%   de saida. Permite passar um cfg parcial sem perder o resto:
%     cfg = struct('MAX_SIGNALS', 3); eye_diagram_from_capture
    defaults = struct( ...
        'MAT_FILE',     fullfile(root, 'data', 'figures', 'received_signal_capture.mat'), ...
        'OUT_DIR',      fullfile(root, 'data', 'figures', 'mae_eye'), ...
        'FRAME_FILTER', '', ...
        'STRIDE',       1, ...
        'MAX_SIGNALS',  20, ...
        'MIN_CHIPS',    50, ...
        'PER_FIGURE',   true, ...
        'GRID_MAX',     12, ...
        'DENSITY',      true, ...
        'XLIM',         [0 2], ...
        'PLOT',         true, ...
        'VISIBLE',      true, ...
        'SAVE_OUTPUTS', true, ...
        'TRUNC_FRAME',  34, ...
        'NORMALIZE',    true, ...
        'OVERSAMPLING', [], ...
        'CONCATENATE',  true, ...
        'SYNC_WITH_TX', true, ...
        'IS_B2B',       false, ...
        'B2B_REF_FILE', fullfile(root, 'data', 'figures', 'b2b_reference.mat'));
    names = fieldnames(defaults);
    for i = 1:numel(names)
        name = names{i};
        if ~isfield(cfg, name) || isempty(cfg.(name))
            cfg.(name) = defaults.(name);
        end
    end
    cfg.STRIDE = max(round(cfg.STRIDE), 1);
    cfg.MAT_FILE = char(cfg.MAT_FILE);
    cfg.OUT_DIR = char(cfg.OUT_DIR);
    cfg.NORMALIZE = logical(cfg.NORMALIZE);
    cfg.CONCATENATE = logical(cfg.CONCATENATE);
    cfg.SYNC_WITH_TX = logical(cfg.SYNC_WITH_TX);
    cfg.IS_B2B = logical(cfg.IS_B2B);
    if ~isempty(cfg.OVERSAMPLING)
        if ~isnumeric(cfg.OVERSAMPLING) || ~isscalar(cfg.OVERSAMPLING) ...
                || ~isfinite(cfg.OVERSAMPLING) || cfg.OVERSAMPLING <= 0
            error(['cfg.OVERSAMPLING deve ser um escalar positivo com o ' ...
                'oversampling POR BIT (ex.: 10 = resampleFactor -> 5 amostras ' ...
                'por chip). Use [] para usar capture.sps.']);
        end
        if cfg.OVERSAMPLING / 2 < 2
            error(['cfg.OVERSAMPLING = %g implica %g amostras por chip, mas ' ...
                'eye_diagram_exp exige sps >= 2 (oversampling por bit minimo 4).'], ...
                cfg.OVERSAMPLING, cfg.OVERSAMPLING / 2);
        end
    end
    if cfg.SAVE_OUTPUTS && ~isfolder(cfg.OUT_DIR)
        mkdir(cfg.OUT_DIR);
    end
end

function rows = emptyRows()
%EMPTYROWS Struct vazia com a ordem de campos que as linhas vai preencher
%   (struct2table usa essa ordem para nomear as colunas).
    rows = struct('idx', {}, 'iteration', {}, 'stamp', {}, 'frame', {}, ...
        'nBits', {}, 'nSamples', {}, 'berLink', {}, 'qLink', {}, 'Qeye', {}, ...
        'QeyeDb', {}, 'berEye', {}, 'EO', {}, 'EOref', {}, 'EOP', {}, ...
        'nSym', {}, 'phase', {}, 'bitStart', {}, ...
        'bitConf', {}, 'corrupted', {}, 'status', {});
end

function restoreWarningState(s)
    for i = 1:numel(s)
        warning(s(i).state, s(i).identifier);
    end
end

function sps = safeSps(sps)
    if isempty(sps) || ~isfinite(sps) || sps < 1
        sps = 1;
    end
end

function sps = effectiveSps(spsStored, cfg)
%EFFECTIVESPS Amostras por chip a usar para o sinal: cfg.OVERSAMPLING tem
%   prioridade e e informado POR BIT (ex.: 10 = resampleFactor -> 5 por chip,
%   ja que o Manchester tem 2 chips por bit); sem override, usa capture.sps.
    if ~isempty(cfg.OVERSAMPLING)
        sps = double(cfg.OVERSAMPLING) / 2;
    else
        sps = safeSps(spsStored);
    end
end

function n = bitsOf(meta, nBitsFixed)
%BITSOF Bits transmitidos do sinal: fixo quando o .mat guarda os bits
%   (store_received_signal.m -> capture.txBits/info.nBits); caso contrario
%   (real_time_mae_vlc.m) e o payload ASCII do frame: 8 de comprimento +
%   8 por caractere.
    if ~isnan(nBitsFixed)
        n = nBitsFixed;
    else
        n = 8 + 8 * numel(meta.frame);
    end
end

function value = fieldOr(s, name, fallback)
    if isstruct(s) && isfield(s, name)
        value = s.(name);
    else
        value = fallback;
    end
end

function db = qDb(q)
    if isempty(q) || ~isfinite(q) || q <= 0
        db = NaN;
    else
        db = 20 * log10(q);
    end
end

function s = fmtHz(fs)
    fs = unique(fs(isfinite(fs) & fs > 0));
    if isempty(fs)
        s = '?';
    else
        s = sprintf('%.3f MSps', fs / 1e6);
    end
end

function s = captureName(path)
    [~, s] = fileparts(path);
end

function s = eyeTitle(meta, nMax, nBits)
%EYETITLE Primeira linha do titulo: de qual frame veio o olho, e se o canal o
%   devolveu corrompido. nBits vem de bitsOf(): payload ASCII do frame clínico
%   ou os bits aleatorios de capture.txBits (store_received_signal.m).
    s = sprintf('Frame [%04d]  %s  (%d bits)', meta.iteration, ...
        truncateLabel(meta.frame, nMax), nBits);
    if ~strcmp(meta.frameRx, meta.frame)
        s = sprintf('%s   <- Rx difere', s);
    end
end

function s = truncateLabel(s, nMax)
    if numel(s) <= nMax
        return;
    end
    s = [s(1:max(nMax - 3, 1)) '...'];
end

function fig = newGridFigure(n, visible)
%NEWGRIDFIGURE Figura em grade para o modo PER_FIGURE = false. O numero de
%   eixos e fixado antes de qualquer plot, porque eye_diagram_exp escreve
%   XTick, YLim e colormap no axes que recebe via 'Axes'.
    n = max(min(n, 12), 1);
    nCols = ceil(sqrt(n));
    nRows = ceil(n / nCols);
    fig = figure('Name', 'Diagramas de olho', 'Color', 'w', ...
        'Position', [50 50 120 * nCols 130 * nRows], 'Visible', visible);
end

function ax = newGridAxes(fig, n)
    n = max(min(n, 12), 1);
    nCols = ceil(sqrt(n));
    nRows = ceil(n / nCols);
    ax = gobjects(1, n);
    for i = 1:n
        ax(i) = subplot(nRows, nCols, i, 'Parent', fig);
    end
end

function [xNorm, levels] = normalizePlateauP2P(x, sps)
%NORMALIZEPLATEAUP2P Normaliza o sinal pela amplitude PLENA pico a pico,
%   medida entre os patamares globais (alto e baixo) dos pulsos mais largos e
%   estaveis, conforme Secao 5.1 da dissertacao (EO = mu1 - mu0).
%
%   Em vez de medir a media dos chips na janela central (que encolhe o olho
%   quando ha ruido/overshoot), os patamares sao estimados sobre as amostras
%   "estaveis" (inclinacao local <= 5% da escala) que pertencem a runs de pelo
%   menos ~1/3 de chip (os pulsos mais largos). Cada patamar e a mediana do
%   seu cluster (robusta a overshoot); sem suporte suficiente, cai para os
%   percentis 5/95 da amostra.
%
%   Saidas:
%     xNorm  sinal centralizado em 0 com patamar alto em +1 e baixo em -1
%            (Vpp = 2)
%     levels struct com U (patamar 1), L (patamar 0), vpp (U - L) e center
    if nargin < 2 || isempty(sps)
        sps = 5;
    end
    sps = max(round(sps), 1);

    x = double(x(:));
    N = numel(x);
    if isempty(x) || N < 2 * sps
        xNorm = x;
        levels = struct('U', 1, 'L', -1, 'vpp', 2, 'center', 0);
        return;
    end

    [L, U] = plateauLevels(x, sps);
    vpp = U - L;
    vCenter = (U + L) / 2;
    levels = struct('U', U, 'L', L, 'vpp', vpp, 'center', vCenter);

    if isfinite(vpp) && vpp > 0
        xNorm = (x - vCenter) / (vpp / 2);
    else
        xNorm = x;
    end
end

function [L, U] = plateauLevels(x, sps)
%PLATEAULEVELS Patamares globais alto (U) e baixo (L) do sinal.
%   Usa apenas amostras "estaveis" (derivada local <= 5% da escala) dentro de
%   runs de >= ~1/3 de chip (pulsos mais largos), agrupadas em cima/baixo pela
%   metade do range amostral; patamar = mediana do cluster. Fallback: se nao
%   houver suporte suficiente, percentis 5/95.
    x = x(isfinite(x));
    if isempty(x)
        L = -1;
        U = 1;
        return;
    end
    lo0 = min(x);
    hi0 = max(x);
    span = hi0 - lo0;
    if ~isfinite(span) || span <= 0
        L = lo0 - 1;
        U = hi0 + 1;
        return;
    end

    % Amostras "estaveis": inclinacao local (derivada de 1a ordem) <= 5% da
    % escala. Sem suporte minimo, considera tudo estavel.
    d = [0; abs(diff(x))];
    stable = d <= 0.05 * span;
    if nnz(stable) < max(round(numel(x) * 0.01), 16)
        stable(:) = true;
    end

    % Filtro de runs: so entram amostras estaveis que fazem parte de pulsos
    % largos, ou seja, runs consecutivos de estabilidade >= ~1/3 de chip.
    minRun = max(round(sps / 3), 2);
    stable = keepStableRuns(stable, minRun);
    if nnz(stable) < max(round(numel(x) * 0.005), 8)
        % Fallback: sem suporte, percentis 5/95 de tudo
        L = prctile(x, 5);
        U = prctile(x, 95);
        return;
    end

    xs = x(stable);
    mid = (hi0 + lo0) / 2;
    up = xs(xs >= mid);
    dn = xs(xs < mid);
    if ~isempty(up) && ~isempty(dn)
        U = median(up);
        L = median(dn);
    else
        L = prctile(xs, 5);
        U = prctile(xs, 95);
    end
end

function m = keepStableRuns(stable, minLen)
%KEEPSTABLERUNS Mantem apenas as amostras estaveis que pertencem a runs
%   consecutivos de comprimento >= minLen (os pulsos mais largos/estaveis).
    m = false(size(stable));
    i = 1;
    n = numel(stable);
    while i <= n
        if stable(i)
            j = i;
            while j + 1 <= n && stable(j + 1)
                j = j + 1;
            end
            if (j - i + 1) >= minLen
                m(i:j) = true;
            end
            i = j + 1;
        else
            i = i + 1;
        end
    end
end