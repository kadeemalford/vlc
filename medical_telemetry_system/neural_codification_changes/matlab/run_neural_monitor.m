function run_neural_monitor(scopeVisa, repo, opts)
%RUN_NEURAL_MONITOR Opt-in monitor PHY -> legacy gateway research entrypoint.
% Uses the verified prototype PHY, not the full legacy hardware initializer.
% External Python IPC server must be started manually. No pyenv or training.
% Continuous AFG by default: first safe upload OFF, then ON until run termination.
arguments
    scopeVisa
    repo
    opts struct
end
required = {'host', 'modelSha256', 'outDir', 'confirmation', 'controlToken'};
for k = 1:numel(required)
    assert(isfield(opts, required{k}), 'Missing option: %s', required{k});
end
if ~isfield(opts, 'signals'), opts.signals = {'pulse_rate'}; end
allowedSignals = {'heart_rate', 'oxygen_saturation', 'pulse_rate', ...
    'systolic_pressure', 'diastolic_pressure'};
assert(iscellstr(opts.signals) && ~isempty(opts.signals) && ...
    all(ismember(opts.signals, allowedSignals)) && ...
    numel(unique(opts.signals)) == numel(opts.signals), 'Select distinct supported signals');
assert(ismember('systolic_pressure', opts.signals) == ...
    ismember('diastolic_pressure', opts.signals), 'Select both cuff pressure fields together');
if isequal(opts.signals, {'pulse_rate'})
    assert(any(strcmp(opts.confirmation, {'CONFIRM_RESEARCH_PR_VLC_AND_GATEWAY', ...
        'CONFIRM_RESEARCH_MONITOR_VLC_AND_GATEWAY'})), 'Explicit research authorization required');
else
    assert(strcmp(opts.confirmation, 'CONFIRM_RESEARCH_MONITOR_VLC_AND_GATEWAY'), ...
        'Explicit multi-signal research authorization required');
end
if ~isfield(opts, 'seconds'), opts.seconds = 60; end
if ~isfield(opts, 'maxAgeSeconds'), opts.maxAgeSeconds = 2; end
if ~isfield(opts, 'controlPort'), opts.controlPort = 47651; end
if ~isfield(opts, 'afgMode'), opts.afgMode = 'continuous'; end
opts.afgMode = validatestring(opts.afgMode, {'continuous', 'per_capture'});
validateattributes(opts.seconds, {'numeric'}, {'scalar', 'finite', 'positive', '<=', 3600});
assert(isa(scopeVisa, 'visa') && strcmpi(get(scopeVisa, 'Status'), 'open'), ...
    'An already-open VISA session is required');
assert(str2double(query(scopeVisa, 'AFG:OUTPUT:STATE?')) == 0, 'Start with AFG OFF');
safetyCleanup = onCleanup(@() turnOff(scopeVisa)); %#ok<NASGU>

% Reject stale class definitions rather than clearing the caller's workspace.
prototype = fullfile(repo, 'vlc-system-matlab-alarm-care-pro-scripts', 'src', 'main');
[loaded, ~] = inmem('-completenames');
for k = 1:numel(loaded)
    if contains(loaded{k}, 'Mdo3012Analyzer')
        assert(contains(loaded{k}, prototype) || ...
            contains(loaded{k}, fullfile(repo, 'equalizador_neural_2', 'matlab')), ...
            'Conflicting analyzer class loaded. Resolve paths before starting.');
    end
end
resolved = which('Mdo3012Analyzer');
assert(startsWith(resolved, [prototype filesep]), 'Expected verified prototype PHY on path');
assert(strcmpi(strtrim(query(scopeVisa, 'DATA:SOURCE?')), 'CH1'), 'CH1 required');
assert(str2double(query(scopeVisa, 'WFMOUTPRE:XINCR?')) == 1e-7, '10 MS/s required');
assert(str2double(query(scopeVisa, 'HORIZONTAL:RECORDLENGTH?')) == 10000, '10k points required');
assert(strcmpi(strtrim(query(scopeVisa, 'ACQUIRE:MODE?')), 'SAMPLE'), 'SAMPLE mode required');
assert(str2double(query(scopeVisa, 'ACQUIRE:STATE?')) == 1, 'Acquisition must be running');
assert(str2double(query(scopeVisa, 'CH1:BANDWIDTH?')) == 20e6, '20 MHz CH1 required');
assert(strcmpi(strtrim(query(scopeVisa, 'CH1:COUPLING?')), 'AC'), 'AC coupling required');
assert(str2double(query(scopeVisa, 'CH1:TERMINATION?')) == 1e6, '1 Mohm CH1 required');
assert(str2double(query(scopeVisa, 'CH1:SCALE?')) == .5, '500 mV/div CH1 required');
assert(strcmpi(strtrim(query(scopeVisa, 'AFG:FUNCTION?')), 'ARBITRARY'), 'Arbitrary AFG required');
assert(strcmpi(strtrim(query(scopeVisa, 'AFG:OUTPUT:LOAD:IMPEDANCE?')), 'HIGHZ'), 'Hi-Z required');
assert(str2double(query(scopeVisa, 'AFG:AMPLITUDE?')) == 1, '1 Vpp required');
assert(str2double(query(scopeVisa, 'AFG:OFFSET?')) == 0, 'Zero offset required');
assert(~isfolder(opts.outDir) && ~isfile(opts.outDir), 'Use a new output directory');
mkdir(opts.outDir);
codeDir = fullfile(opts.outDir, 'code');
mkdir(codeDir);
for name = {'run_neural_monitor', 'NeuralBridgeClient', 'NeuralAfgController', ...
        'ExistingVisaMdo3012Analyzer', ...
        'Mdo3012Analyzer', 'synchronize_capture_samples', 'SignalUtils', ...
        'ManchesterOokEncoder', 'ManchesterOokParameters'}
    source = which(name{1});
    assert(~isempty(source), 'Missing MATLAB helper: %s', name{1});
    copyfile(source, fullfile(codeDir, [name{1} '.m']));
end

bridge = NeuralBridgeClient(opts.controlPort, opts.controlToken);
bridgeCleanup = onCleanup(@() bridge.close()); %#ok<NASGU>
bridge.initialize(opts.modelSha256, opts.outDir, opts.maxAgeSeconds, opts.signals);
bridge.start(opts.host);

analyzer = ExistingVisaMdo3012Analyzer(scopeVisa);
params = ManchesterOokParameters();
params.setBitRate(1e6);
encoder = ManchesterOokEncoder(params);
afg = NeuralAfgController(@(command) fprintf(scopeVisa, command), opts.afgMode);
afgCleanup = onCleanup(@() afg.close()); %#ok<NASGU>
fprintf('Research monitor live run: %s. No commands/HL7 ACK. Ctrl+C stops; verify AFG OFF.\n', ...
    strjoin(opts.signals, ', '));
fprintf('AFG mode: %s. Continuous mode uploads subsequent waveforms with output ON.\n', opts.afgMode);
timer = tic;
while toc(timer) < opts.seconds
    request = jsondecode(char(bridge.next_json()));
    if ~isfield(request, 'tx_bits')
        pause(0.02);
        drawnow;
        continue;
    end
    tx_bits = double(request.tx_bits(:));
    rx_raw = []; rx_aligned = []; tx_samples = [];
    sync_info = struct('accepted', false);
    result = struct();
    status = 'error'; error_message = ''; stage = 'encode';
    bit_rate = 1e6; sps = 10; tx_sample_rate = 10e6; rx_sample_rate = NaN;
    started_at_utc = char(datetime('now', 'TimeZone', 'UTC'));
    fatalError = [];
    try
        tx = encoder.generateBaseBandSignal(tx_bits');
        tx_samples = double(tx.getSamples());
        assert(tx.getSampleRate() == 10e6 && numel(tx_bits) == 392, 'Unexpected TX');
        stage = 'upload';
        % First upload is OFF; subsequent uploads remain ON in continuous mode.
        analyzer.writeSamples(tx);
        stage = 'acquisition';
        afg.enable();
        pause(0.05);
        rx = analyzer.readSamples(1);
        afg.afterAcquire();
        rx_raw = double(rx.getSamples());
        rx_sample_rate = rx.getSampleRate();
        assert(rx_sample_rate == tx_sample_rate, 'RX sample rate changed');
        assert(~isempty(rx_raw) && all(isfinite(rx_raw)) && max(abs(rx_raw)) > 0, 'Invalid RX');
        stage = 'synchronization';
        normalized = SignalUtils.normalizeSignal(rx);
        [candidate, sync_info] = synchronize_capture_samples( ...
            tx_samples, normalized.getSamples(), .5);
        assert(sync_info.accepted, 'PHY synchronization rejected');
        rx_aligned = double(candidate);
        assert(numel(rx_aligned) == numel(tx_bits)*sps, 'Invalid aligned length');
        stage = 'decode_and_gateway';
        result = jsondecode(char(bridge.receive_json(jsonencode(rx_aligned))));
        status = 'ok'; % PHY accepted; codec/gateway results remain separate.
    catch ME
        if strcmp(opts.afgMode, 'per_capture')
            afg.afterAcquire();
        else
            % Preserve the failed capture, then terminate with output OFF.
            fatalError = ME;
        end
        try
            bridge.reject();
        catch
            % Preserve this capture even if IPC has failed; next poll fails closed.
        end
        error_message = [ME.identifier ': ' ME.message];
        warning('VLC:NeuralAttempt', 'Attempt %d failed at %s', request.message_id, stage);
    end
    metadata_json = jsonencode(struct('message_id', request.message_id, 'signal', request.signal, ...
        'fragment_index', request.fragment_index, 'fragment_total', request.fragment_total, ...
        'model_sha256', opts.modelSha256, 'sync_mode', 'assisted_full_tx', ...
        'physical_profile', '1Mbps_10MSps_CH1_20MHz', 'afg_mode', opts.afgMode, 'delivery', result));
    filename = fullfile(opts.outDir, sprintf('message_%010d_p%02d.mat', ...
        request.message_id, request.fragment_index + 1));
    assert(~isfile(filename), 'Capture already exists');
    save(filename, 'tx_bits', 'tx_samples', 'rx_raw', 'rx_aligned', ...
        'rx_sample_rate', 'tx_sample_rate', 'sps', 'bit_rate', 'sync_info', ...
        'status', 'stage', 'error_message', 'metadata_json', 'started_at_utc', '-v7');
    disp(result);
    if ~isempty(fatalError)
        rethrow(fatalError);
    end
    drawnow;
end
afg.close();
disp(char(bridge.stats_json()));
end

function turnOff(session)
fprintf(session, 'AFG:OUTPUT:STATE OFF');
end
