classdef OokParameters < handle
    properties
        resampleFactor
        bitRate
        bitTime
        bandwidth
        rxSampleRate
        txSampleRate
        txSampleTime
        recommendedBitNumber
    end
    
    methods
        function obj = OokParameters()
            obj.bitRate = 1000e3; %bps
            obj.setBitRate(obj.bitRate);
        end
        
        function setBitRate(obj, bitRate)
            obj.bitRate = bitRate; %bps
            obj.bitTime = 1/obj.bitRate;
            obj.bandwidth = obj.bitRate; %Hz
            obj.txSampleRate = 10*obj.bandwidth; %sps
            obj.txSampleTime = 1/obj.txSampleRate;
            obj.resampleFactor = round(obj.bitTime/obj.txSampleTime);
            obj.rxSampleRate = obj.txSampleRate; %sps
            obj.recommendedBitNumber = round(10000/obj.resampleFactor/2); %considerando um buffer com 10k amostras
        end
    end
end

