function tests = test_validate_rate_plan
tests = functiontests(localfunctions);
end

function testValidPlan(testCase)
[file, cleanup] = fixture(); %#ok<ASGLU>
plan = validate_rate_plan(file, 1);
verifyEqual(testCase, plan.expected_sample_rate, 1e7);
verifyEqual(testCase, plan.horizontal_seconds_per_div, 1e-4, 'AbsTol', 1e-12);
end

function testUnfilledTemplate(testCase)
file = fullfile(fileparts(mfilename('fullpath')), 'session.example.json');
verifyError(testCase, @() validate_rate_plan(file, 1), 'MATLAB:assertion:failed');
end

function testShortRecord(testCase)
[file, cleanup] = fixture(); %#ok<ASGLU>
plan = jsondecode(fileread(file));
plan.record_points = 1000;
fid = fopen(file, 'w'); fprintf(fid, '%s', jsonencode(plan)); fclose(fid);
verifyError(testCase, @() validate_rate_plan(file, 1), 'MATLAB:assertion:failed');
end

function [file, cleanup] = fixture()
file = [tempname '.json'];
cleanup = onCleanup(@() delete(file));
plan = struct('session_id', 'test_session', 'split', 'train', 'condition_id', 'fixed', ...
    'seed', 12001, 'rates_bps', 1e6, 'frames_per_rate', 2, 'bits_per_frame', 400, ...
    'channel', 1, 'sync_threshold', .5, 'record_points', 10000, 'out_dir', tempdir, ...
    'physical_metadata', struct('receiver', 'test', 'afg_vpp', 1, ...
    'bias_current_a', .1, 'distance_m', 2.4, 'vertical_scale_v_div', .5, ...
    'trigger_note', 'test', 'illumination_note', 'test'));
fid = fopen(file, 'w'); fprintf(fid, '%s', jsonencode(plan)); fclose(fid);
end
