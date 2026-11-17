function tests = test_afg_controller
% Pure command-log tests. Never opens VISA, sockets, or instruments.
tests = functiontests(localfunctions);
end

function testContinuousKeepsOutputOnBetweenCaptures(testCase)
commands = {};
afg = NeuralAfgController(@record, 'continuous');
for k = 1:5
    afg.enable();
    afg.afterAcquire();
end
verifyEqual(testCase, commands, {'AFG:OUTPUT:STATE ON'});
afg.close();
afg.close();
verifyEqual(testCase, commands, {'AFG:OUTPUT:STATE ON', 'AFG:OUTPUT:STATE OFF'});
    function record(command)
        commands{end+1} = command;
    end
end

function testPerCaptureModeRemainsAvailable(testCase)
commands = {};
afg = NeuralAfgController(@record, 'per_capture');
for k = 1:2
    afg.enable();
    afg.afterAcquire();
end
verifyEqual(testCase, commands, {'AFG:OUTPUT:STATE ON', 'AFG:OUTPUT:STATE OFF', ...
    'AFG:OUTPUT:STATE ON', 'AFG:OUTPUT:STATE OFF'});
afg.close();
    function record(command)
        commands{end+1} = command;
    end
end

function testCleanupTurnsOutputOffOnError(testCase)
commands = {};
afg = NeuralAfgController(@record, 'continuous');
verifyError(testCase, @failDuringRun, 'VLC:Test:ExpectedFailure');
verifyEqual(testCase, commands, {'AFG:OUTPUT:STATE ON', 'AFG:OUTPUT:STATE OFF'});
    function record(command)
        commands{end+1} = command;
    end
    function failDuringRun()
        cleanup = onCleanup(@() afg.close()); %#ok<NASGU>
        afg.enable();
        error('VLC:Test:ExpectedFailure', 'Synthetic failure');
    end
end

function testFailedEnableStillRequestsOff(testCase)
commands = {};
afg = NeuralAfgController(@record, 'continuous');
verifyError(testCase, @() afg.enable(), 'VLC:Test:WriteFailure');
afg.close();
verifyEqual(testCase, commands, {'AFG:OUTPUT:STATE ON', 'AFG:OUTPUT:STATE OFF'});
    function record(command)
        commands{end+1} = command;
        if strcmp(command, 'AFG:OUTPUT:STATE ON')
            error('VLC:Test:WriteFailure', 'Synthetic write failure');
        end
    end
end
