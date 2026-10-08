classdef System1tx1rx < handle
    properties (Access = private)
        signalEncoder(1,1) AbstractEncoder = OokEncoder(OokParameters());
        signalDecoder(1,1) AbstractDecoder = OokDecoder(OokParameters());
        txAnalyzer(1,1) AbstractLogicAnalyzer = BackToBackAnalyzer();
        rxAnalyzer(1,1) AbstractLogicAnalyzer = BackToBackAnalyzer();
        rxAnalyzerChannel
        MAX_RETRIES 
    end
    
    methods
        function obj = System1tx1rx(signalEncoder, signalDecoder, ...
                txAnalyzer, rxAnalyzer)
            obj.signalEncoder = signalEncoder;
            obj.signalDecoder = signalDecoder;
            obj.txAnalyzer = txAnalyzer;
            obj.rxAnalyzer = rxAnalyzer;
            obj.rxAnalyzerChannel = 1;
            obj.MAX_RETRIES = 3;
        end
        
        function response = communicate(obj, bits, doEvaluation)
            if nargin < 3 || isempty(doEvaluation)
                doEvaluation = true;
            end
            response = System1tx1rxResponse();
            %% transmitter
            % encode bits
            txSignal = obj.signalEncoder.generateBaseBandSignal(bits);
            
            % modulation (not implemented)
            
            % send signal
            obj.txAnalyzer.writeSamples(txSignal);
            
            %% receiver (with retry)
            retryCounter = 0; % Inicializa o contador de tentativas
            synchSuccessful = false; % Flag para indicar se a sincronização foi bem-sucedida

            while retryCounter < obj.MAX_RETRIES && ~synchSuccessful
                % receive signal
                rxSignal = obj.rxAnalyzer.readSamples(obj.rxAnalyzerChannel);

                % normalization
                normRxSignal = SignalUtils.normalizeSignal(rxSignal);

                % resampling rx signal to match with the tx sample rate
                if(txSignal.getSampleRate() ~= normRxSignal.getSampleRate())
                    normRxSignal = SignalUtils.resampleSignalToMatchSampleRate(txSignal, normRxSignal);
                end

                % synchronizing
                try
                    synchSignal = SignalUtils.synchronizeSignals(txSignal, normRxSignal);
                    synchSuccessful = true;
                catch ME
                    retryCounter = retryCounter + 1;
                    warning('Erro na sincronização dos sinais. Tentativa %d de %d. Erro: %s', retryCounter, obj.MAX_RETRIES, ME.message);
                end
            end
            
            response.synchSuccessful = synchSuccessful;
            
            if synchSuccessful
                response.synchSignal = synchSignal;
            else
                warning('Falha ao sincronizar os sinais após %d tentativas.', obj.MAX_RETRIES);
                return 
            end
           
            %% decode signal 
            rxBits = obj.signalDecoder.decodeBaseBandSignal(synchSignal);
            
            %% evaluation
            [numBitErrors, ber] = biterr(bits, rxBits);
            
            %% create the response
            response.txSignal = txSignal;
            response.txBits = bits;
            response.rxSignal = rxSignal;
            response.synchSignal = synchSignal;
            response.rxBits = rxBits;
            response.ber = ber;
            response.numBitErrors = numBitErrors;
            response.parameters = obj.signalEncoder.getParameters();
            % ook (manchester) parameters
            % Eye diagram/Q-factor/bit samples servem apenas para visualizacao.
            % A pipeline em tempo real os ignora (communicate(bits, false)).
            if doEvaluation
                response.eyeDiagramSegments = EyeDiagramUtils.getSegments(synchSignal, response.parameters.resampleFactor/2, 2); % 2 symbols per segment
                response.qFactor = EyeDiagramUtils.calculateQfactor(synchSignal, response.parameters.resampleFactor);
                obj.setBitSamples(synchSignal, response.parameters.resampleFactor, response);
            end
        end
        
        function setBitSamples(obj, synchSignal, samplesPerSymbol, response)
            samples = intdump(synchSignal.getSamples(), samplesPerSymbol/2);

            %% separating zeros and one
            onesIdx = samples >= 0;
            zerosIdx = samples < 0;
            
            % Separação dos níveis 0 e 1
            bit1Samples = samples(onesIdx);
            bit0Samples = samples(zerosIdx);
            
            response.bit1Samples = bit1Samples;
            response.bit0Samples = bit0Samples;
        end
    end
end

