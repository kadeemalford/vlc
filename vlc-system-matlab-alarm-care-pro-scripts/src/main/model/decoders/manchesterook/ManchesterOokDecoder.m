classdef ManchesterOokDecoder < AbstractDecoder
    
    properties (Access = private)
        parameters
    end
    
    methods
        function obj = ManchesterOokDecoder(parameters)
            obj.parameters = parameters;
        end
        
        function bits = decodeBaseBandSignal(obj, signalInput)
            
            if(mod(obj.parameters.resampleFactor,2) ~= 0)
                ME = MException('ManchesterOokDecoder:decodeBaseBandSignal', ...
                    "The factor to resample the signal shound be even because we will divide by 2 due the transition in the middle of the bit");
                throw(ME);
            end

            % Manchester decoding: 01 -> 0, 10 -> 1
            samples = signalInput.getSamples();

            % calculating the resample factor
            resampleFactor = obj.parameters.resampleFactor/2;
            
            % Integrate over each symbol period (resampleFactor)
            integratedSamples = intdump(samples, resampleFactor);
            
            % Reshape to process pairs of symbols
            reshapedSamples = reshape(integratedSamples, 2, length(integratedSamples)/2);
            
            % Decision making: if the first sample of the pair is higher, it's a 1 (10), otherwise it's a 0 (01)
            bits = double(reshapedSamples(1,:) > reshapedSamples(2,:));
        end
    end
end