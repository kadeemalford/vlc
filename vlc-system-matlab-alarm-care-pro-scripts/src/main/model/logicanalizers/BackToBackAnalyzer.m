classdef BackToBackAnalyzer < AbstractLogicAnalyzer
    properties (Access = private)
        bufferSignal
        status
        bufferSize
    end
        
    methods
        function obj = BackToBackAnalyzer()
            obj.status = true;
            obj.bufferSize = 10000;
            obj.bufferSignal = Signal(zeros(1, obj.bufferSize), zeros(1, obj.bufferSize), 0);
        end

        function writeSamples(obj, signal)
            if(obj.bufferSignal.getSampleRate() ~= 0 && obj.bufferSignal.getSampleRate() ~= signal.getSampleRate())
                ME = MException('BackToBackAnalyzer:writeSamples', ...
                    "The signals should have the same sample rate. Call flush() to clear the internal buffer");
                throw(ME);
            end
           
            shift = 1000;
            obj.flush()
            bufferSamples = obj.bufferSignal.getSamples();
            samples = rand(1)*signal.getSamples();
            
            bufferSamples(shift:signal.getLength()+shift-1) = bufferSamples(shift:signal.getLength()+shift-1) + samples;
            obj.bufferSignal.setSamples(bufferSamples);
            obj.bufferSignal = signal;
            if(obj.bufferSignal.getSampleRate() == 0)
                obj.bufferSignal.setSampleRate(signal.getSampleRate());
                obj.bufferSignal.setTimes(SignalUtils.generateTimes(obj.bufferSignal))
            end
        end

        function signal = readSamples(obj, channelNumber)
            signal = copy(obj.bufferSignal);
            obj.bufferSignal = Signal(zeros(1, obj.bufferSize), zeros(1, obj.bufferSize), 0);
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