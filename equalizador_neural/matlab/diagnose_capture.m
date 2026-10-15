function outDir = diagnose_capture(analyzer, encoder, outDir, confirmSafe)
%DIAGNOSE_CAPTURE Diagnostico ativo de repeticao e captura antiga, CH1.
% Requer o MESMO MDO TX/RX ja conectado/configurado e bancada autorizada.
% Nao chamar initiateDefaultConnection aqui: ela altera configuracoes.
% Pare outros scripts/timers que usem o MDO e suspenda dados/comandos clinicos.
% Uso: diagnose_capture(analyzer, encoder, 'C:\dados\diagnostico01', true)
%
% ATENCAO: substitui a waveform e seu periodo, via writeSamples do legado.
% Nao altera amplitude, offset, polarizacao, ganho, trigger ou estado da saida.
% Nao restaura a waveform anterior nem desliga a saida: ao terminar/falhar,
% o ultimo payload pode continuar sendo emitido. Retome o software original
% conforme o procedimento da bancada. Nao e coleta de treino nem teste clinico.
% Compativel por projeto com R2021a; ainda requer validacao no MATLAB/bancada.

if nargin < 4 || ~isequal(confirmSafe, true)
    error('diagnose_capture:consent', ...
        'Leia os avisos e passe true somente com bancada segura e exclusiva.');
end
assert(~exist(outDir, 'file') && ~exist(outDir, 'dir'), ...
    'Use uma pasta de saida nova; nao sobrescrevemos diagnosticos.');
assert(analyzer.isConnected(), 'Use o objeto do MDO ja conectado.');
params = encoder.getParameters();
assert(params.resampleFactor >= 2 && mod(params.resampleFactor, 2) == 0, ...
    'Amostras por bit devem ser inteiras e pares.');
mkdir(outDir);
oldRng = rng;
rngCleanup = onCleanup(@() rng(oldRng)); %#ok<NASGU>
rng(20261013, 'twister');

config = struct('channel', 1, 'n_bits', 400, 'n_uploads', 6, ...
    'read_waits_seconds', [0 0.20], 'seed', 20261013, ...
    'match_threshold', 0.80, 'score_margin', 0.10, ...
    'distance_m_nominal', 2.4, 'alignment_note', 'aproximadamente axial', ...
    'bit_rate', params.bitRate, 'sps', params.resampleFactor);
% Esperas sao incrementais, ANTES de cada leitura, apos writeSamples retornar.
% writeSamples ja contem a espera de 50 ms nesta copia do legado.
% Thresholds sao heuristicas exploratorias, nao criterios validados.
environment = struct('matlab', version, 'products', ver, ...
    'analyzer_path', which(class(analyzer)), 'encoder_path', which(class(encoder)));
snapshot = readSettings(analyzer);
save(fullfile(outDir, 'settings.mat'), 'config', 'environment', 'snapshot', '-v7');
fprintf('Diagnostico: %s\n', outDir);
fprintf('Substitui waveform/periodo; ultimo payload permanece no AFG.\n');
previousBits = [];
rows = struct([]);
for upload = 1:config.n_uploads
    currentBits = randi([0 1], 1, config.n_bits);
    tx = encoder.generateBaseBandSignal(currentBits);
    started_at = char(datetime('now', 'TimeZone', 'UTC', ...
        'Format', 'yyyy-MM-dd''T''HH:mm:ss.SSSXXX'));
    stage = 'upload'; uploadError = ''; timer = tic;
    try
        analyzer.writeSamples(tx);
    catch ME
        uploadError = [ME.identifier ': ' ME.message];
    end
    upload_seconds = toc(timer);
    for readIndex = 1:numel(config.read_waits_seconds)
        raw = []; fs = NaN; analysis_rx = []; analysis_fs = NaN;
        current = struct(); previous = struct();
        error_message = uploadError; verdict = 'inconclusivo';
        stage = 'upload'; read_seconds = NaN;
        if isempty(uploadError)
            pause(config.read_waits_seconds(readIndex));
            stage = 'read'; timer = tic;
            try
                rx = analyzer.readSamples(config.channel);
                read_seconds = toc(timer);
                raw = double(rx.getSamples()); fs = rx.getSampleRate();
                stage = 'analysis';
                assert(~isempty(raw) && all(isfinite(raw)) && ...
                    isfinite(fs) && fs > 0, 'RX vazio, nao finito ou taxa invalida.');
                if fs ~= tx.getSampleRate()
                    rx = SignalUtils.resampleSignalToMatchSampleRate(tx, rx);
                end
                analysis_rx = double(rx.getSamples());
                analysis_fs = rx.getSampleRate();
                current = match_diagnostic_payload(analysis_rx, tx.getSamples(), ...
                    currentBits, config.sps, config.match_threshold);
                if ~isempty(previousBits)
                    previousTx = encoder.generateBaseBandSignal(previousBits);
                    previous = match_diagnostic_payload(analysis_rx, ...
                        previousTx.getSamples(), previousBits, config.sps, ...
                        config.match_threshold);
                end
                if ~isempty(previousBits) && previous.score >= config.match_threshold && ...
                        previous.score > current.score + config.score_margin
                    verdict = 'indicio_payload_anterior';
                elseif current.score >= config.match_threshold && ...
                        (isempty(previousBits) || ...
                         current.score > previous.score + config.score_margin)
                    verdict = 'indicio_payload_atual';
                end
                stage = 'complete';
            catch ME
                error_message = [ME.identifier ': ' ME.message];
            end
        end
        filename = sprintf('upload_%02d_read_%02d.mat', upload, readIndex);
        save(fullfile(outDir, filename), 'config', 'started_at', 'upload', ...
            'readIndex', 'currentBits', 'previousBits', 'raw', 'fs', ...
            'analysis_rx', 'analysis_fs', 'current', 'previous', ...
            'verdict', 'stage', 'error_message', 'upload_seconds', 'read_seconds', '-v7');
        r = struct('upload', upload, 'read_index', readIndex, ...
            'current_score', fieldValue(current, 'score'), ...
            'previous_score', fieldValue(previous, 'score'), ...
            'ber_current', fieldValue(current, 'ber'), ...
            'complete_matches', fieldValue(current, 'n_complete_matches'), ...
            'rx_samples', numel(raw), 'rx_fs', fs, 'verdict', verdict, ...
            'stage', stage, 'error_message', error_message);
        rows = [rows; r]; %#ok<AGROW>
        fprintf('Upload %d leitura %d: atual %.3f anterior %.3f BER %.3g copias %g | %s\n', ...
            upload, readIndex, r.current_score, r.previous_score, ...
            r.ber_current, r.complete_matches, verdict);
    end
    if ~isempty(uploadError)
        warning('diagnose_capture:upload', ...
            'Upload falhou; teste interrompido. Arquivos preservados.');
        break; % Estado do AFG pode ser desconhecido; nao continuar a trocar payloads.
    end
    previousBits = currentBits;
end
writetable(struct2table(rows), fullfile(outDir, 'summary.csv'));
fprintf(['Fim. Envie summary.csv e settings.mat; preserve os .mat por leitura.\n' ...
    'Correlacao/BER aqui sao assistidas pelo TX e nao provam sincronismo.\n' ...
    'Copias >=2 sugerem repeticao dentro do registro, nao emissao continua garantida.\n']);
end

function snapshot = readSettings(analyzer)
% Apenas consultas; falhas sao registradas sem tentar reconfigurar o instrumento.
commands = {'*IDN?', 'HORizontal:RECOrdlength?', 'HORizontal:SCAle?', ...
    'CH1:SCAle?', 'CH1:COUPling?', 'CH1:TERmination?', ...
    'TRIGger:A:MODe?', 'TRIGger:A:TYPe?', ...
    'ACQuire:STATE?', 'ACQuire:STOPAfter?', ...
    'AFG:PERiod?', 'AFG:AMPLitude?', 'AFG:OUTPut:STATE?'};
snapshot = struct('command', {}, 'response', {}, 'error', {});
for k = 1:numel(commands)
    response = ''; message = '';
    try
        response = char(analyzer.queryText(commands{k}));
    catch ME
        message = [ME.identifier ': ' ME.message];
    end
    snapshot(end+1) = struct('command', commands{k}, ...
        'response', response, 'error', message); %#ok<AGROW>
end
end

function value = fieldValue(s, name)
value = NaN;
if isfield(s, name), value = s.(name); end
end
