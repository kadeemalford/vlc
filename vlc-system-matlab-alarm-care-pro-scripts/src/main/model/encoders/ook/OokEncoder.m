classdef OokEncoder < AbstractEncoder
    
    properties (Access = private)
        parameters
    end
    
    methods
        function obj = OokEncoder(parameters)
            obj.parameters = parameters;
        end
        
        function params = getParameters(obj)
            params = obj.parameters;
        end
        
        function outputSignal = generateBaseBandSignal(obj, bits)
            samples = rectpulse(bits, obj.parameters.resampleFactor) - 0.5;
            sampleRate = obj.parameters.txSampleRate;
            
            times = 0:1/sampleRate:(length(samples)-1)/sampleRate;
            outputSignal = Signal(samples, times, sampleRate);
            
        end
    end
end

