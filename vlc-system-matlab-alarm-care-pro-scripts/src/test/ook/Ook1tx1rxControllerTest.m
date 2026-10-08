addpath(genpath("../../main"));
currentFile = mfilename('fullpath')
[currentPath, ~, ~] = fileparts(currentFile)

system1tx1rxController = System1tx1rxController();

response = system1tx1rxController.communicate();

eyediagram(response.synchSignal.getSamples(), 10)


% custom eye segments
segments = EyeDiagramUtils.getSegments(response.synchSignal, 10, 2); % 2 symbols per segment

% Plot eye diagram
figure;
plot(segments', 'b');
xlabel('Time (samples)');
ylabel('Amplitude');
title('Eye Diagram');

assert(isequal(response.txBits, response.rxBits), 'Os bits não são iguais.');
fprintf("Teste executando com sucesso\n")
