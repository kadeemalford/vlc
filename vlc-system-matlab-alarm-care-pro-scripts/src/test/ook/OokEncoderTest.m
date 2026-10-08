addpath(genpath("../../main/model"));

% OfdmEncoder(parameters)
parameters = OokParameters();
ookEncoder = OokEncoder(parameters);

bits = randi([0 1], 1, 100);

signal = ookEncoder.generateBaseBandSignal(bits);

signal.plotTimeDomain()