addpath(genpath("../../main/model"));

mdoRxName ="TCPIP::172.20.25.193::INSTR"; % exemplo para conexão ip strcat('TCPIP::',mdo2.ip,'::INSTR');
%honScale = 10000/10/obj.parameters.rxSampleRate;

rxAnalyzer =  Mdo3012Analyzer(mdoRxName);
rxAnalyzer.initiateDefaultConnection();

f = 60;
fs = 100*f;
t = 0:1/fs:0.1;
s = sin(2*pi*f*t);

sig = Signal(s,t,fs);

rxAnalyzer.writeSamples(sig)
