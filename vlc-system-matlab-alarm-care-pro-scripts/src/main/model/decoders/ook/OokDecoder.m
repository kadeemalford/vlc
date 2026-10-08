classdef OokDecoder < AbstractDecoder
    
    properties (Access = private)
        parameters
    end
    
    methods
        function obj = OokDecoder(parameters)
            obj.parameters = parameters;
        end
        
        function bits = decodeBaseBandSignal(obj, signalInput)
            sig = intdump(signalInput.getSamples(), obj.parameters.resampleFactor);
            %Decision making if 1 or 0
            bits = double(sig >= 0);
        end
    end
end

