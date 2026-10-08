addpath(genpath("../../main/model"));

% OfdmEncoder(parameters)
parameters = OokParameters();
ookEncoder = OokEncoder(parameters);
ookDecoder = OokDecoder(parameters);

bits = randi([0 1], 1, 100);

signal = ookEncoder.generateBaseBandSignal(bits);

receivedBits = ookDecoder.decodeBaseBandSignal(signal);

assert(isequal(bits, receivedBits), 'Os bits não são iguais.');
fprintf("Teste executando com sucesso\n")
