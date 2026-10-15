function tests = test_match_diagnostic_payload
% Executar: results = runtests('test_match_diagnostic_payload'); table(results)
tests = functiontests(localfunctions);
end

function testRepeatedInvertedPayload(testCase)
bits = [0 1 1 0 1 0 0 1 0 0 1 1];
chips = reshape([2*bits-1; 1-2*bits], 1, []);
tx = repelem(chips, 5);
rx = [zeros(1, 17), -3*tx, -3*tx, zeros(1, 11)] + 7;
r = match_diagnostic_payload(rx, tx, bits, 10, 0.8);
verifyEqual(testCase, r.score, 1, 'AbsTol', 1e-12);
verifyEqual(testCase, r.ber, 0);
verifyEqual(testCase, r.polarity, -1);
verifyEqual(testCase, r.n_complete_matches, 2);
end

function testIncompleteRecord(testCase)
r = match_diagnostic_payload(zeros(1, 10), repmat([-1 1], 1, 10), [0 1], 10, 0.8);
verifyTrue(testCase, isnan(r.ber));
verifyEqual(testCase, r.n_complete_matches, 0);
end

function testFlatRecord(testCase)
r = match_diagnostic_payload(ones(1, 100), repmat([-1 1], 1, 10), [0 1], 10, 0.8);
verifyEqual(testCase, r.score, 0);
verifyEqual(testCase, r.n_complete_matches, 0);
end
