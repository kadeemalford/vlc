classdef SignalUtils
    methods(Static)
        function normalizedSig = normalizeSignal(signal)
            maxAmp = (max(abs(signal.getSamples())));
            normalizedSig = Signal(signal.getSamples()/maxAmp, signal.getTimes(), signal.getSampleRate());
        end 

        function plot(signal)
            plot(signal.getTimes(), signal.getSamples());
        end

        function signal = sumSignals(signal1, signal2)
            if(signal1.getSampleRate() ~= signal2.getSampleRate())
                ME = MException('SignalUtils:sumSignals', ...
                    "The signals should have the same sample rate");
                throw(ME);
            end
            if(signal1.getLength() == 0)
                signal = Signal(signal2.getSamples(), signal2.getTimes(), signal2.getSampleRate());
            elseif(signal2.getLength() == 0)
                signal = Signal(signal1.getSamples(), signal1.getTimes(), signal1.getSampleRate());
            else
                samples = signal1.getSamples() + signal2.getSamples();
                signal = Signal(samples, signal1.getTimes(), signal1.getSampleRate());
            end
            
        end
        
        function times = generateTimes(signal)
            times = 0:1/signal.getSampleRate():((signal.getLength()-1)/signal.getSampleRate());
        end

        % this method create a new signal based in signal2 to match the sample rate of signal1
        function newSignal = resampleSignalToMatchSampleRate(signal1, signal2)
            [P1, Q1]    = rat(signal1.getSampleRate()/signal2.getSampleRate()); 
            newSamples = resample(signal2.getSamples(), P1, Q1); 
            newSampleRate = signal1.getSampleRate();
            times = 0:1/newSampleRate:((length(newSamples)-1)/newSampleRate);
            
            newSignal = Signal(newSamples, times, newSampleRate);
            
        end
        
        function syncSignal = synchronizeSignals(signal1, signal2)
            
            if(signal1.getSampleRate() ~= signal2.getSampleRate())
                ME = MException('SignalUtils:synchronizeSignals', ...
                    "The signals should have the same sample rate");
                throw(ME);
            end

            [~, ~, shift]  = alignsignals(signal1.getSamples(), signal2.getSamples());
            
            signal1Len = length(signal1.getSamples());
            signal2Len = length(signal2.getSamples());
            
            syncSignal = Signal();

            if (shift + signal1Len <= signal2Len) && (shift >= 0)
                sigSamples = signal2.getSamples();
                shiftedSamples = sigSamples(shift + 1:shift + signal1Len);
                
                syncSignal.setTimes(signal1.getTimes());
                syncSignal.setSampleRate(signal1.getSampleRate());
                
                % motivation of this condition should be evaluated in the future
                if rms(signal1.getSamples() - shiftedSamples)  ...
                    > rms(signal1.getSamples() + shiftedSamples)
                    syncSignal.setSamples(-shiftedSamples);
                else
                    syncSignal.setSamples(shiftedSamples);
                end
                
            else
                ME = MException('SignalUtils:synchronizeSignals', ...
                    "The signals could not be synchronized");
                throw(ME);
            end

        end
    end
end