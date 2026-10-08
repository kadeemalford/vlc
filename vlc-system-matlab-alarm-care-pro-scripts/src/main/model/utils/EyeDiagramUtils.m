classdef EyeDiagramUtils
    methods(Static)
        %GET_EYE_SEGMENTS Extracts segments for plotting an eye diagram.
        %
        %   segments = GET_EYE_SEGMENTS(signal, samplesPerSymbol, numSymbolsPerSegment)
        %   returns a matrix where each row corresponds to a segment of the signal
        %   suitable for plotting an eye diagram.
        %
        %   INPUTS:
        %       signal               - Input signal (signal object)
        %       samplesPerSymbol     - Number of samples per symbol
        %       numSymbolsPerSegment - Number of symbols to include per eye segment
        %
        %   OUTPUT:
        %       segments - Matrix of size [numSegments x segmentLength] where each
        %                 row is one eye diagram segment
        function segments = getSegments(signal, samplesPerSymbol, numSymbolsPerSegment)
                signalSamples = signal.getSamples();
                
                % Total number of samples per segment
                segmentLength = samplesPerSymbol * numSymbolsPerSegment;

                % Number of complete segments that can be extracted
                numSegments = floor((length(signalSamples) - segmentLength) / samplesPerSymbol) + 1;

                % Preallocate matrix for speed
                segments = zeros(numSegments, segmentLength);

                % Extract segments
                for k = 1:numSegments
                    startIdx = (k - 1) * samplesPerSymbol + 1;
                    endIdx = startIdx + segmentLength - 1;
                    segments(k, :) = signalSamples(startIdx:endIdx);
                end
        end
        
        function qFactor = calculateQfactor(signal, samplesPerSymbol)
            sampledValues = intdump(signal.getSamples(), samplesPerSymbol/2);
            
            onesIdx = sampledValues >= 0;
            zerosIdx = sampledValues < 0;
            
            % Separação dos níveis 0 e 1
            bit1Samples = sampledValues(onesIdx);
            bit0Samples = sampledValues(zerosIdx);

            % Cálculo do fator Q
            mu1 = mean(bit1Samples);
            mu0 = mean(bit0Samples);
            sigma1 = std(bit1Samples);
            sigma0 = std(bit0Samples);

            q = (mu1 - mu0) / (sigma1 + sigma0);
            
            qFactor = QFactor(mu1, mu0, sigma1, sigma0, q);
        end
    end
end

