classdef BackToBackChannelAnalyzer < AbstractLogicAnalyzer
    properties (Access = private)
        bufferSignal
        status
        bufferSize
        cutoffFreq
        snr
    end
        
    methods
        function obj = BackToBackChannelAnalyzer(snr, cutoffFreq)
            obj.status = true;
            obj.bufferSize = 10000;
            obj.bufferSignal = Signal(zeros(1, obj.bufferSize), zeros(1, obj.bufferSize), 0);
            obj.cutoffFreq = cutoffFreq;
            obj.snr = snr;
        end

        function writeSamples(obj, signal)
            if(obj.bufferSignal.getSampleRate() ~= 0 && obj.bufferSignal.getSampleRate() ~= signal.getSampleRate())
                ME = MException('BackToBackAnalyzer:writeSamples', ...
                    "The signals should have the same sample rate. Call flush() to clear the internal buffer");
                throw(ME);
            end
            
            obj.bufferSignal = Signal(zeros(1, obj.bufferSize), zeros(1, obj.bufferSize), 0);

            % filtering to simulate the channel
            %[b, a] = butter(4, obj.cutoffFreq/(signal.getSampleRate()/2));  % Filtro Butterworth de 4ª ordem
            %filtredSamples = filter(b, a, signal.getSamples());            % Aplica ao sinal
            filtredSamples = signal.getSamples();
            
            % add noise (TODO)
            samples = awgn(filtredSamples, obj.snr);
            
            % shift simulation buffer
            shift = 1000;
            obj.flush()
            bufferSamples = obj.bufferSignal.getSamples();

            bufferSamples(shift:signal.getLength()+shift-1) = samples;
            obj.bufferSignal.setSamples(bufferSamples);
            %obj.bufferSignal = signal;
            if(obj.bufferSignal.getSampleRate() == 0)
                obj.bufferSignal.setSampleRate(signal.getSampleRate());
                obj.bufferSignal.setTimes(SignalUtils.generateTimes(obj.bufferSignal))
            end
        end

        function signal = readSamples(obj, channelNumber)
            signal = copy(obj.bufferSignal);
            %obj.bufferSignal = Signal(zeros(1, obj.bufferSize), zeros(1, obj.bufferSize), 0);
        end

        function status = isConnected(obj)
            status = obj.status; 
        end

        function flush(obj)
            obj.bufferSignal = Signal(zeros(1, obj.bufferSize), zeros(1, obj.bufferSize), 0);
        end
        
        function setAfgAmplitude(obj, afg)
            %simulation from mdo
        end
        
        function disconnect(obj)
            obj.status = false;
        end
    end
end