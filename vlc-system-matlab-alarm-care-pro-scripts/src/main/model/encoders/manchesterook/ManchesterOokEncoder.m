classdef ManchesterOokEncoder < AbstractEncoder
    
    properties (Access = private)
        parameters
    end
    
    methods
        function obj = ManchesterOokEncoder(parameters)
            obj.parameters = parameters;
        end
        
        function params = getParameters(obj)
            params = obj.parameters;
        end
        
        function outputSignal = generateBaseBandSignal(obj, bits)
            
            if(mod(obj.parameters.resampleFactor,2) ~= 0)
                ME = MException('ManchesterOokEncoder:generateBaseBandSignal', ...
                    "The factor to resample the signal shound be even because we will divide by 2 due the transition in the middle of the bit");
                throw(ME);
            end

            % Manchester encoding: 0 -> 01, 1 -> 10
            manchesterBits = zeros(1, 2 * length(bits));
            for i = 1:length(bits)
                if bits(i) == 0
                    manchesterBits(2*i-1:2*i) = [-1, 1];
                else
                    manchesterBits(2*i-1:2*i) = [1, -1];
                end
            end

            samples = rectpulse(manchesterBits, obj.parameters.resampleFactor/2);

            sampleRate = obj.parameters.txSampleRate;
            
            times = 0:1/sampleRate:(length(samples)-1)/sampleRate;
            outputSignal = Signal(samples, times, sampleRate);
        end
    end
end