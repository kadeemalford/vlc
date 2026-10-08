classdef (Abstract) AbstractDecoder < handle
    methods(Abstract)
        bits = decodeBaseBandSignal(inputSignal);
    end
end