classdef (Abstract) AbstractEncoder < handle
    methods(Abstract)
        [signal] = generateBaseBandSignal(bits)
    end
end