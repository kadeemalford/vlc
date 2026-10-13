function filename = collect_capture(txAnalyzer, rxAnalyzer, encoder, bits, channel, outDir, meta)
% Uma tentativa, sem retry oculto. Instrumentos devem estar configurados.
% NAO configura amplitude, polarizacao, trigger nem liga/desliga a bancada.
% meta: capture_id, session_id, condition_id, split (train/val/test), demais notas.
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
    aligned = SignalUtils.synchronizeSignals(tx, normalized);
    rx_aligned = double(aligned.getSamples());
    assert(numel(rx_aligned) == numel(tx_bits)*sps && all(isfinite(rx_aligned)), 'Alinhamento invalido');
    sync_seconds = toc(timer);
    status = 'ok';
catch ME
    error_message = [ME.identifier ': ' ME.message];
    warning('collect_capture:failed', '%s: %s', stage, error_message);
end
total_seconds = toc(totalTimer); % Nao inclui escrita em disco.
metadata_json = jsonencode(meta);
% -v7: tipos numericos/strings simples, legiveis por scipy.io.loadmat.
save(filename, 'tx_bits', 'tx_samples', 'rx_raw', 'rx_aligned', ...
    'rx_sample_rate', 'tx_sample_rate', 'sps', 'bit_rate', 'sync_mode', ...
    'status', 'stage', 'error_message', 'metadata_json', 'started_at_utc', ...
    'upload_seconds', 'acquisition_seconds', 'sync_seconds', 'total_seconds', '-v7');
end
