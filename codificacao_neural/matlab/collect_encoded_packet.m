function filename = collect_encoded_packet(txAnalyzer, rxAnalyzer, packetFile, outDir, meta, confirmation)
% Replay ONE prepared neural packet through already-configured, open analyzers.
% Does not initialize or enable hardware, retry, disable output, or command equipment.
assert(strcmp(confirmation, 'CONFIRM_SAFE_SETUP_AND_WAVEFORM_UPLOAD'), ...
    'VLC:NeuralCodec:Confirmation', 'Explicit local setup and waveform upload confirmation required');
repo = fileparts(fileparts(fileparts(mfilename('fullpath'))));
addpath(fullfile(repo, 'equalizador_neural', 'matlab'));
addpath(fullfile(repo, 'equalizador_neural_2', 'matlab'));
data = load(packetFile, 'tx_bits', 'model_sha256', 'message_id', ...
    'fragment_index', 'fragment_total', 'source_sha256');
required = {'capture_id', 'session_id', 'split', 'condition_id', 'physical_metadata'};
for k = 1:numel(required)
    assert(isfield(meta, required{k}), 'VLC:NeuralCodec:Metadata', 'Missing metadata: %s', required{k});
end
assert(~isempty(regexp(meta.capture_id, '^[A-Za-z0-9_-]+$', 'once')), ...
    'VLC:NeuralCodec:UnsafeId', 'Unsafe capture ID');
assert(any(strcmp(meta.split, {'train', 'val', 'test'})), ...
    'VLC:NeuralCodec:Split', 'Invalid split');
bits = double(data.tx_bits(:)');
assert(~isempty(bits) && mod(numel(bits), 8) == 0 && all(bits == 0 | bits == 1), ...
    'VLC:NeuralCodec:Bits', 'Expected whole bytes of binary packet bits');
assert(numel(bits) <= 500, 'VLC:NeuralCodec:RecordBudget', ...
    'Packet exceeds initial 10k-point acquisition budget; do not truncate');
assert(strcmpi(strtrim(rxAnalyzer.queryText('DATa:SOUrce?')), 'CH1'), ...
    'VLC:NeuralCodec:Channel', 'Configure transfer source CH1 before collecting');
interval = str2double(rxAnalyzer.queryText('WFMPre:XINcr?'));
points = str2double(rxAnalyzer.queryText('WFMPre:NR_Pt?'));
assert(isfinite(interval) && abs(interval-1e-7) < 1e-15 && points == 10000, ...
    'VLC:NeuralCodec:Acquisition', 'Initial replay requires 10 MS/s and 10k points');
before = str2double(txAnalyzer.queryText('AFG:OUTPut:STATE?'));
assert(before == 1, 'VLC:NeuralCodec:OutputOff', 'Operator must explicitly enable the safe AFG setup');
params = ManchesterOokParameters();
params.setBitRate(1e6);
encoder = ManchesterOokEncoder(params);
meta.proposal = '6_neural_telemetry_coding';
meta.payload_type = 'neural_encoded_compact_telemetry';
meta.model_sha256 = data.model_sha256;
meta.message_id = data.message_id;
meta.fragment_index = data.fragment_index;
meta.fragment_total = data.fragment_total;
meta.source_sha256 = data.source_sha256;
meta.afg_state_before = before;
meta.warning = 'Assisted full-TX synchronization; no security or online delivery claim';
if ~exist(outDir, 'dir'), mkdir(outDir); end
assert(~exist(fullfile(outDir, [meta.capture_id '.mat']), 'file'), ...
    'VLC:NeuralCodec:Exists', 'Capture already exists');
codeDir = fullfile(outDir, [meta.capture_id '_code']);
assert(~exist(codeDir, 'dir'), 'VLC:NeuralCodec:Exists', 'Code snapshot already exists');
mkdir(codeDir);
for name = {'collect_encoded_packet', 'collect_capture', 'synchronize_capture_samples', ...
        'ExistingVisaMdo3012Analyzer', 'Mdo3012Analyzer', 'SignalUtils', ...
        'ManchesterOokParameters', 'ManchesterOokEncoder'}
    source = which(name{1});
    assert(~isempty(source), 'VLC:NeuralCodec:MissingSource', 'Missing source: %s', name{1});
    copyfile(source, fullfile(codeDir, [name{1} '.m']));
end
filename = collect_capture(txAnalyzer, rxAnalyzer, encoder, bits, 1, outDir, meta, .5);
afg_state_after = str2double(txAnalyzer.queryText('AFG:OUTPut:STATE?')); %#ok<NASGU>
save(filename, 'afg_state_after', '-append');
assert(afg_state_after == 1, 'VLC:NeuralCodec:OutputChanged', ...
    'AFG output changed during capture; source saved, investigate before retrying');
end
