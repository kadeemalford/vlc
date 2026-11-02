function plan = validate_rate_plan(configFile, rateIndex)
% Offline validation only: never communicates with instruments.
plan = jsondecode(fileread(configFile));
required = {'session_id', 'split', 'condition_id', 'seed', 'rates_bps', ...
    'frames_per_rate', 'bits_per_frame', 'channel', 'sync_threshold', ...
    'record_points', 'out_dir', 'physical_metadata'};
for k = 1:numel(required)
    assert(isfield(plan, required{k}), 'Missing field: %s', required{k});
end
assert(~contains(fileread(configFile), 'REPLACE'), 'Fill all REPLACE placeholders first');
assert(any(strcmp(plan.split, {'train', 'val', 'test'})), 'Invalid split');
assert(~isempty(regexp(plan.session_id, '^[A-Za-z0-9_-]+$', 'once')), 'Unsafe session ID');
assert(~isempty(plan.condition_id) && ~isempty(plan.out_dir), 'Empty condition/output');
validateattributes(plan.rates_bps, {'numeric'}, {'vector', 'positive', 'finite', 'integer'});
assert(numel(unique(plan.rates_bps)) == numel(plan.rates_bps), 'Duplicate rates');
validateattributes(rateIndex, {'numeric'}, {'scalar', 'integer', '>=', 1, '<=', numel(plan.rates_bps)});
validateattributes(plan.seed, {'numeric'}, {'scalar', 'integer', '>=', 0, '<', 2^32-numel(plan.rates_bps)});
validateattributes(plan.frames_per_rate, {'numeric'}, {'scalar', 'integer', 'positive'});
validateattributes(plan.bits_per_frame, {'numeric'}, {'scalar', 'integer', '>=', 2});
validateattributes(plan.channel, {'numeric'}, {'scalar', 'integer', '>=', 1, '<=', 2});
validateattributes(plan.record_points, {'numeric'}, {'scalar', 'integer', 'positive'});
validateattributes(plan.sync_threshold, {'numeric'}, {'scalar', '>', 0, '<=', 1, 'finite'});
assert(plan.record_points >= 2*plan.bits_per_frame*10, 'Record must cover at least two frame durations');
numericFields = {'afg_vpp', 'bias_current_a', 'distance_m', 'vertical_scale_v_div'};
for k = 1:numel(numericFields)
    name = numericFields{k};
    assert(isfield(plan.physical_metadata, name), 'Missing physical metadata: %s', name);
    validateattributes(plan.physical_metadata.(name), {'numeric'}, {'scalar', 'positive', 'finite'});
end
for name = {'receiver', 'trigger_note', 'illumination_note'}
    assert(isfield(plan.physical_metadata, name{1}) && ...
        ~isempty(plan.physical_metadata.(name{1})), 'Missing descriptive physical metadata');
end
plan.rate_bps = plan.rates_bps(rateIndex);
plan.expected_sample_rate = 10*plan.rate_bps;
plan.horizontal_seconds_per_div = plan.record_points/(10*plan.expected_sample_rate);
plan.block_seed = plan.seed+rateIndex-1;
plan.rate_dir = fullfile(plan.out_dir, sprintf('rate_%d', plan.rate_bps));
fprintf('Rate: %.0f bit/s; expected RX: %.0f Sa/s; horizontal suggestion: %.9g s/div\n', ...
    plan.rate_bps, plan.expected_sample_rate, plan.horizontal_seconds_per_div);
fprintf('Suggestion is not a measurement or automatic hardware configuration.\n');
end
