classdef Signal < handle & matlab.mixin.Copyable
    properties (Access = private)
        samples
        times
        sampleRate
    end

    methods
        
        function obj = Signal(varargin)
            if nargin == 0 % constructor Signal()
                obj.samples = [];
                obj.times = [];
                obj.sampleRate = 0;
            elseif nargin == 3 % constructor Signal(samples, times, sampleRate)
                obj.samples = varargin{1};
                obj.times = varargin{2};
                obj.sampleRate = varargin{3};
            else
                ME = MException('Signal:Constructor', ...
                    "Invalid number of constructor parameters");
                throw(ME);
            end
        end

        function samples = getSamples(obj)
            samples = obj.samples;
        end
        
        function setSamples(obj, samples)
            obj.samples = samples;
        end

        function times = getTimes(obj)
            times = obj.times;
        end

        function setTimes(obj, times)
            obj.times = times;
        end

        function sampleRate = getSampleRate(obj)
            sampleRate = obj.sampleRate;
        end

        function setSampleRate(obj, sampleRate)
            obj.sampleRate = sampleRate;
        end

        function len = getLength(obj)
            len = length(obj.samples);
        end
        
        % inputs {1} -> title
        function plotTimeDomain(obj, varargin)
            plot(obj.getTimes(), obj.getSamples());
            xlabel("Time");
            ylabel("Amplitude");
            if nargin == 2
                title(varargin{1});
            end
        end

        % inputs {1} -> title
        function figObj = plotTimeDomainAsNewFigure(obj, varargin)
            figObj = figure();
            if nargin == 1
                obj.plotTimeDomain();
            elseif nargin == 2
                obj.plotTimeDomain(varargin{1});
            else
                ME = MException('Signal:Constructor', ...
                    "Invalid number of constructor parameters");
                throw(ME);
            end  
        end
        
        % inputs {1} -> title
        function figObj = plotFrequencyDomainAsNewFigure(obj, varargin)          
            figObj = figure();
            obj.plotFrequencyDomain(varargin);
        end

        function plotFrequencyDomain(obj, varargin)          
            signalLength = length(obj.samples());
            spectrum = fft(obj.samples, 2^(nextpow2(signalLength)));
            spectrum = spectrum/obj.sampleRate; % validar essa operação
            newLen = 2^(nextpow2(signalLength));
            deltaFreq = obj.sampleRate/newLen;
            frequencies =  deltaFreq*(0:newLen-1) - obj.sampleRate/2;

            plot(frequencies/1e6, 10*log10((fftshift(abs(spectrum)))));
            xlabel('Frequency [MHz]');
            ylabel('PSD [dB/Hz]');
            xlim([0 Inf]);
            if nargin == 2
                title(varargin{1});
            end
        end

        function plotFrequencyDomainView(obj, figObj)          
            signalLength = length(obj.samples());
            spectrum = fft(obj.samples, 2^(nextpow2(signalLength)));
            spectrum = spectrum/obj.sampleRate; % validar essa operação
            newLen = 2^(nextpow2(signalLength));
            deltaFreq = obj.sampleRate/newLen;
            frequencies =  deltaFreq*(0:newLen-1) - obj.sampleRate/2;

            plot(figObj, frequencies/1e6, 10*log10((fftshift(abs(spectrum)))));
            xlabel(figObj, 'Frequency [MHz]');
            ylabel(figObj, 'PSD [dB/Hz]');
            xlim(figObj, [0 Inf]);
        end
        
    end
end