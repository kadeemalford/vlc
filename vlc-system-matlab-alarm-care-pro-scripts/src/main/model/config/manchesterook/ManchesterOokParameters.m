classdef ManchesterOokParameters < handle
    properties
        resampleFactor
        bitRate
        bitTime
        symbolTime
        bandwidth
        rxSampleRate
        rxSampleTime
        txSampleRate
        txSampleTime
        bufferSize
        recommendedBitNumber
    end
    
    methods
        function obj = ManchesterOokParameters()
            obj.bitRate = 1000e3; %bps
            obj.setBitRate(obj.bitRate);
        end
        
        function setBitRate(obj, bitRate)
            obj.bitRate = bitRate; %bps
            obj.bitTime = 1/obj.bitRate; 
            obj.symbolTime = obj.bitTime; 
            obj.bandwidth = 2*bitRate; %bandwidth in Hz
            
            % the system will work better if txSampleRate is equal to rxSampleTime
            obj.resampleFactor = 10; % factor to reamostrate the signal. It shound be even because we will divide by 2 due the transition in the middle of the bit 
            
            obj.txSampleTime = obj.symbolTime/(obj.resampleFactor);
            obj.txSampleRate = 1/(obj.txSampleTime); %sps
           
            obj.rxSampleRate = 5*obj.bandwidth; %sps
            obj.rxSampleTime = 1/obj.rxSampleRate; 
            
            obj.bufferSize = 10000; % mdo points in the buffer
            obj.recommendedBitNumber = round(obj.bufferSize/(obj.resampleFactor)/2); % consedering 50% of the buffer size
        
            if(mod(obj.resampleFactor,2) ~= 0)
                ME = MException('ManchesterOokParameters:setBitRate', ...
                    "The factor to reamostrate the signal shound be even because we will divide by 2 due the transition in the middle of the bit");
                throw(ME);
            end
        end
    end
end

