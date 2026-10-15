function tests = test_synchronize_capture_samples
% Sem instrumentos: runtests('test_synchronize_capture_samples')
tests = functiontests(localfunctions);
end

function testCompleteCopyInsteadOfStrongerTruncatedCopy(testCase)
oldRng = rng; cleanup = onCleanup(@() rng(oldRng)); %#ok<NASGU>
rng(42, 'twister');
tx = manchester(randi([0 1], 1, 60));
rx = [zeros(1,17), 0.8*tx, zeros(1,100), 1.1*tx(1:end-5)];
% O pico global prefere a copia final truncada por cinco amostras.
fullCorrelation = conv(rx, fliplr(tx));
[~, peak] = max(abs(fullCorrelation));
globalLag = peak-numel(tx);
verifyGreaterThan(testCase, globalLag+numel(tx), numel(rx));
[aligned, info] = synchronize_capture_samples(tx, rx);
verifyTrue(testCase, info.accepted);
verifyEqual(testCase, info.start_sample, 18);
verifyEqual(testCase, aligned, 0.8*tx, 'AbsTol', 1e-12);
verifyEqual(testCase, info.score, 1, 'AbsTol', 1e-12);
end

function testInversionAndOffset(testCase)
tx = manchester([0 1 1 0 1 0 0 1]);
rx = [zeros(1,9), -2*tx, zeros(1,13)] + 7;
[aligned, info] = synchronize_capture_samples(tx, rx, 0.8);
verifyTrue(testCase, info.accepted);
verifyEqual(testCase, info.lag_samples, 9);
verifyEqual(testCase, info.polarity, -1);
verifyEqual(testCase, aligned, 2*tx-7, 'AbsTol', 1e-12);
end

function testLastCompleteWindow(testCase)
tx = manchester([1 1 0 1 0 0 0 1]);
[aligned, info] = synchronize_capture_samples(tx, [zeros(1,11),tx]);
verifyTrue(testCase, info.accepted);
verifyEqual(testCase, info.start_sample, 12);
verifyEqual(testCase, aligned, tx);
end

function testShortRecord(testCase)
tx = manchester([0 1 0 0]);
[aligned, info] = synchronize_capture_samples(tx, tx(1:end-1));
verifyEmpty(testCase, aligned);
verifyFalse(testCase, info.accepted);
verifyEqual(testCase, info.reason, 'record_shorter_than_frame');
end

function testFlatRecord(testCase)
tx = manchester([0 1 0 0]);
[aligned, info] = synchronize_capture_samples(tx, ones(1,100));
verifyEmpty(testCase, aligned);
verifyFalse(testCase, info.accepted);
verifyEqual(testCase, info.reason, 'no_nonconstant_window');
end

function testLowCorrelationRejected(testCase)
tx = manchester([0 1 0 0 1 0 1 1]);
rx = tx;
rx(1:10) = -rx(1:10);
[aligned, info] = synchronize_capture_samples(tx, rx, 0.99);
verifyEmpty(testCase, aligned);
verifyFalse(testCase, info.accepted);
verifyEqual(testCase, info.reason, 'correlation_below_threshold');
verifyLessThan(testCase, info.score, 0.99);
end

function testThresholdMustBePositive(testCase)
tx = manchester([0 1]);
rejected = false;
try
    synchronize_capture_samples(tx, tx, 0);
catch
    rejected = true;
end
verifyTrue(testCase, rejected);
end

function tx = manchester(bits)
chips = reshape([2*bits-1; 1-2*bits], 1, []);
tx = repelem(chips, 5);
end
