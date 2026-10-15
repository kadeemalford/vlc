function filename = collect_capture(txAnalyzer, rxAnalyzer, encoder, bits, channel, outDir, meta, syncThreshold)
% Uma tentativa, sem retry oculto. Instrumentos devem estar configurados.
% NAO configura amplitude, polarizacao, trigger nem liga/desliga a bancada.
% meta: capture_id, session_id, condition_id, split (train/val/test), demais notas.
% syncThreshold opcional: Pearson absoluto minimo (default exploratorio 0.5).
% Busca apenas copias completas; nao usa a BER para aceitar/rejeitar a janela.
if nargin < 8, syncThreshold = 0.5; end
validateattributes(syncThreshold, {'numeric'}, ...
    {'real', 'scalar', 'finite', '>', 0, '<=', 1});
required = {'capture_id', 'session_id', 'condition_id', 'split'};
for k = 1:numel(required)
    assert(isfield(meta, required{k}), 'Falta meta.%s', required{k});
end
assert(any(strcmp(meta.split, {'train', 'val', 'test'})), 'Split invalido');
assert(~isempty(regexp(char(meta.capture_id), '^[A-Za-z0-9_-]+$', 'once')), 'ID inseguro');
if ~exist(outDir, 'dir'), mkdir(outDir); end
filename = fullfile(outDir, [char(meta.capture_id) '.mat']);
assert(~exist(filename, 'file'), 'Captura ja existe; use outro ID');
tx_bits = double(bits(:));
assert(~isempty(tx_bits) && all(tx_bits == 0 | tx_bits == 1), 'Bits invalidos');
params = encoder.getParameters();
sps = params.resampleFactor;
bit_rate = params.bitRate;
sync_mode = 'assisted_full_tx';
sync_method = 'valid_window_pearson_v1';
sync_threshold = double(syncThreshold);
sync_info = struct('method', sync_method, 'accepted', false, ...
    'threshold', sync_threshold, 'reason', 'not_attempted');
status = 'error';
error_message = '';
stage = 'encode';
rx_raw = []; rx_aligned = []; tx_samples = []; rx_sample_rate = NaN;
tx_sample_rate = params.txSampleRate;
upload_seconds = NaN; acquisition_seconds = NaN; sync_seconds = NaN;
started_at_utc = char(datetime('now', 'TimeZone', 'UTC', 'Format', 'yyyy-MM-dd''T''HH:mm:ss.SSSXXX'));
totalTimer = tic;
try
    tx = encoder.generateBaseBandSignal(tx_bits');
    tx_samples = double(tx.getSamples());
    stage = 'upload'; timer = tic;
    txAnalyzer.writeSamples(tx);
    upload_seconds = toc(timer);
    stage = 'acquisition'; timer = tic;
    rx = rxAnalyzer.readSamples(channel);
    acquisition_seconds = toc(timer);
    rx_raw = double(rx.getSamples());
    rx_sample_rate = rx.getSampleRate();
    stage = 'synchronization'; timer = tic;
    assert(~isempty(rx_raw) && all(isfinite(rx_raw)) && max(abs(rx_raw)) > 0, 'RX vazio/nao finito/nulo');
    normalized = SignalUtils.normalizeSignal(rx);
    if tx.getSampleRate() ~= normalized.getSampleRate()
        normalized = SignalUtils.resampleSignalToMatchSampleRate(tx, normalized);
    end
    [candidate, sync_info] = synchronize_capture_samples( ...
        tx_samples, normalized.getSamples(), sync_threshold);
    if ~sync_info.accepted
        error('collect_capture:syncRejected', ...
            'Sincronizacao rejeitada: %s (score=%.4g, limiar=%.4g)', ...
            sync_info.reason, sync_info.score, sync_threshold);
    end
    rx_aligned = double(candidate);
    assert(numel(rx_aligned) == numel(tx_bits)*sps && all(isfinite(rx_aligned)), 'Alinhamento invalido');
    sync_seconds = toc(timer);
    status = 'ok';
catch ME
    if strcmp(stage, 'synchronization'), sync_seconds = toc(timer); end
    error_message = [ME.identifier ': ' ME.message];
    warning('collect_capture:failed', '%s: %s', stage, error_message);
end
total_seconds = toc(totalTimer); % Nao inclui escrita em disco.
metadata_json = jsonencode(meta);
% -v7: tipos numericos/strings simples, legiveis por scipy.io.loadmat.
save(filename, 'tx_bits', 'tx_samples', 'rx_raw', 'rx_aligned', ...
    'rx_sample_rate', 'tx_sample_rate', 'sps', 'bit_rate', 'sync_mode', ...
    'sync_method', 'sync_threshold', 'sync_info', ...
    'status', 'stage', 'error_message', 'metadata_json', 'started_at_utc', ...
    'upload_seconds', 'acquisition_seconds', 'sync_seconds', 'total_seconds', '-v7');
end
