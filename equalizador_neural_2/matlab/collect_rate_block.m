function files = collect_rate_block(txAnalyzer, rxAnalyzer, configFile, rateIndex, confirmation)
% Uses already-open analyzers. No initialization, amplitude/bias/gain/timebase changes.
% writeSamples DOES replace AFG waveform/period; authorized only by confirmation.
assert(strcmp(confirmation, 'CONFIRM_SAFE_SETUP_AND_WAVEFORM_UPLOAD'), ...
    'Explicit local setup/upload confirmation required');
plan = validate_rate_plan(configFile, rateIndex);
assert(~exist(plan.rate_dir, 'dir'), 'Rate output exists; use a new session/output, no silent resume');
% Query acquisition BEFORE any upload. Matching sample rates avoids unvalidated resampling.
xin = str2double(rxAnalyzer.queryText('WFMPre:XINcr?'));
points = str2double(rxAnalyzer.queryText('WFMPre:NR_Pt?'));
assert(isfinite(xin) && xin > 0, 'Invalid measured acquisition interval');
assert(abs(1/xin-plan.expected_sample_rate)/plan.expected_sample_rate < 1e-8, ...
    'RX rate mismatch: configure acquisition manually, then revalidate');
assert(points == plan.record_points, 'RX record length differs from plan');
% readSamples selects the requested channel; select it before trusting its preamble.
source = strtrim(rxAnalyzer.queryText('DATa:SOUrce?'));
assert(strcmpi(source, sprintf('CH%d', plan.channel)), ...
    'Select DATa:SOUrce for the planned channel manually before collecting');
params = ManchesterOokParameters();
params.setBitRate(plan.rate_bps);
encoder = ManchesterOokEncoder(params);
mkdir(plan.rate_dir);
copyfile(configFile, fullfile(plan.rate_dir, 'session_config.json'));
codeDir = fullfile(plan.rate_dir, 'code');
mkdir(codeDir);
for name = {'collect_rate_block', 'validate_rate_plan', 'collect_capture', ...
        'synchronize_capture_samples', 'ManchesterOokParameters', ...
        'ManchesterOokEncoder', 'Mdo3012Analyzer', 'SignalUtils'}
    sourceFile = which(name{1});
    assert(~isempty(sourceFile), 'Cannot snapshot source: %s', name{1});
    copyfile(sourceFile, fullfile(codeDir, [name{1} '.m']));
end
stream = RandStream('mt19937ar', 'Seed', plan.block_seed);
files = cell(plan.frames_per_rate, 1);
for i = 1:plan.frames_per_rate
    meta = plan.physical_metadata;
    meta.capture_id = sprintf('%s_r%d_%06d', plan.session_id, plan.rate_bps, i);
    meta.session_id = plan.session_id;
    meta.condition_id = plan.condition_id;
    meta.split = plan.split;
    meta.payload_type = 'random';
    meta.payload_seed = plan.block_seed;
    meta.payload_index = i;
    meta.proposal = '4_bandwidth_limited_manchester';
    meta.acquisition_sample_rate_checked = 1/xin;
    meta.record_points_checked = points;
    bits = randi(stream, [0 1], 1, plan.bits_per_frame);
    append_attempt(plan.rate_dir, meta.capture_id, 'started');
    files{i} = collect_capture(txAnalyzer, rxAnalyzer, encoder, bits, plan.channel, ...
        plan.rate_dir, meta, plan.sync_threshold);
    saved = load(files{i}, 'rx_sample_rate', 'status');
    append_attempt(plan.rate_dir, meta.capture_id, saved.status);
    if isfinite(saved.rx_sample_rate)
        assert(abs(saved.rx_sample_rate-plan.expected_sample_rate)/plan.expected_sample_rate < 1e-8, ...
            'Acquisition rate changed during block; saved source preserved, stop and investigate');
    end
end
end

function append_attempt(folder, captureId, state)
fid = fopen(fullfile(folder, 'attempts.csv'), 'a');
assert(fid >= 0, 'Cannot open attempt journal');
closer = onCleanup(@() fclose(fid));
stamp = char(datetime('now', 'TimeZone', 'UTC', 'Format', 'yyyy-MM-dd''T''HH:mm:ss.SSSXXX'));
fprintf(fid, '%s,%s,%s\n', stamp, captureId, state);
end
