classdef System1tx1rxResponse < handle
    properties
        synchSuccessful
        txBits
        txSignal
        rxBits
        rxSignal
        synchSignal
        ber
        numBitErrors
        parameters
        
        %ook params
        eyeDiagramSegments
        qFactor
        bit1Samples
        bit0Samples
    end
    
    methods
        function obj = System1tx1rxResponse()
        end
    end
end

