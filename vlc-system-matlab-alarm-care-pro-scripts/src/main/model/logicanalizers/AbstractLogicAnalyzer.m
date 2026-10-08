classdef (Abstract) AbstractLogicAnalyzer < handle
    methods(Abstract)
        writeSamples(obj, signal);
        signal = readSamples(obj, channelNumber);
        status = isConnected(obj);
        disconnect(obj);
    end
end