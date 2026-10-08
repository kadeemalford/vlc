classdef Mdo3012Analyzer < AbstractLogicAnalyzer
    properties (Access = private)
        visaObj
        icDeviceObj
        icWaveFormObj
        connectionType
        resourceName
        inputBufferSize
        outputBufferSize
        offset
        signalAmplitude
        timeHorizontalScale
        vendorName
        % https://naic.nrao.edu/arecibo/phil/hardware/oscilloscopes/MDO4000-B-MSO-DPO4000B-and-MDO3000-Oscilloscope-Programmer-Manual-Rev-A.pdf
    end
    
    methods (Access = private)
    end
    
    methods (Static)
        % Seleciona o adaptador VISA instalado. O MATLAB cria o objeto com
        % visa(vendor, resource); se o vendor não estiver instalado (ex.:
        % "TEK" sem TekVISA) a criação falha com "Unable to create VISA
        % object", mesmo estando tudo OK via Python/NI-VISA.
        function vendor = detectVendor()
            vendor = "NI";
            try
                info = instrhwinfo('visa');
                installed = lower(string(info.InstalledAdaptors));
                if ismember("tek", installed)
                    vendor = "TEK";
                elseif ismember("ni", installed)
                    vendor = "NI";
                end
            catch
            end
        end
    end
    
    methods
        function obj = Mdo3012Analyzer(varargin)
            if(nargin >= 1)
                obj.resourceName = varargin{1};
            else
                obj.resourceName = "mdo3012u";
            end
            obj.offset = 0;
            if(nargin >= 2)
                obj.vendorName = varargin{2};
            else
                obj.vendorName = Mdo3012Analyzer.detectVendor();
            end
            obj.signalAmplitude = 1;
            %[1 2.5 5 10 25 50 100 250]MHz
            %[1m 400u 200u  100u 40u 20u 10u 4u]s
            obj.timeHorizontalScale = 10000/10/10e6; % a/b/c 10k (a) points em 10 (b) divisões visando tx de amostragem de 10MHz (c) 
        end
        
        function initiateDefaultConnection(obj)
            
            obj.visaObj = visa(obj.vendorName, obj.resourceName);

            % Define the buffers size
            set(obj.visaObj, 'InputBufferSize',  1048576);
            set(obj.visaObj, 'OutputBufferSize', 1048576);
            
            % receiver definitions
            obj.icDeviceObj = icdevice('DPO4034.mdd', obj.visaObj);
            obj.icWaveFormObj = get(obj.icDeviceObj, 'Waveform');
            if(isempty(obj.icWaveFormObj))
                ME = MException('Mdo3012:initiateConnection', ...
                    "icWaveFormObj is empty. The icDeviceObj does not have the Waveform propety");
                throw(ME);
            end
            
            % start connection
            obj.connect();

            % Clean and turn the AFG on
            obj.flush()
            obj.setMdoAfgOutputState(MdoStateEnum.ON);

            % set the AFG inpedance
            obj.setMdoAfgImpedance(MdoAfgImpedanceEnum.HIGHZ);
            
            % Set the AFG to arbitrary signals
            obj.setMdoAfgFunction(MdoAfgFunctionEnum.ARBITRARY);

            % set a voltage offset
            obj.setMdoAfgOffset(obj.offset)

            % Defines the signal amplitude range
            obj.setAfgAmplitude(obj.signalAmplitude);

            % Configure the channels
            obj.setMdoTermination(1, MdoTerminationEnum.MEG);
            obj.setMdoTermination(2, MdoTerminationEnum.MEG);
            obj.setMdoCoupling(1, MdoCouplingEnum.AC);
            obj.setMdoCoupling(2, MdoCouplingEnum.AC);

            % Configuracao de aquisicao deterministica: registro completo de
            % 10k pontos (janela de 1 ms a 10 MS/s) com o timebase delay
            % desligado. Sem isso o scope herda estado anterior (ex.: delay
            % timebase ligado, fast acquisition e/ou record 1k) e o CURVe?
            % retorna poucos pontos, limitando os bits transmitidos por frame.
            obj.write("HORizontal:DELay:MODe OFF");
            obj.write("HORizontal:RECOrdlength 10000");
            obj.write("HORizontal:FAST:ACQuire OFF");
            obj.write("HORizontal:SCAle " + obj.timeHorizontalScale);
            obj.write("ACQuire:STOPAfter RUN");
            obj.write("ACQuire:STATE 1");
        end

        function writeSamples(obj, signal)
            ti = tic;
            normSignal = SignalUtils.normalizeSignal(signal);
            BasicLogger.log(LogLevelEnum.ELAPSED_TIME, sprintf("Samples mdo writing signal normalization elapsed time %fs", toc(ti)));
            samples = normSignal.getSamples();
            t = signal.getTimes();
            
            % setting mdo period
            ti = tic;
            tempo = strcat('AFG:PERIOD', {' '}, num2str(t(end)+(t(2)-t(1))));
            obj.write(tempo{1});
            BasicLogger.log(LogLevelEnum.ELAPSED_TIME, sprintf("Period mdo writing elapsed time %fs", toc(ti)));
                        
            ti = tic;
            % Upload ASCII dos pontos: upload binario (IEEE 488.2 block)
            % foi testado (float32/64, little/big-endian, int16), mas o AFG
            % deste MDO nao produz saida valida a partir do bloco (EMEM fica
            % correta no readback, porem o sinal analogico sai errado/ausente).
            strCells = arrayfun(@(x) sprintf('%.4f', x), samples, 'UniformOutput', false);
            ascSig = strjoin(strCells, ',');
            formattedString = strcat("AFG:ARBitrary:EMEM:POINTS ", ascSig);
            BasicLogger.log(LogLevelEnum.ELAPSED_TIME, sprintf("Samples mdo writing string convertion elapsed time %fs", toc(ti)));
            
            %{
            ti = tic;
            %bytesIeee488 = typecast(single(samples), 'uint32');
            bytesIeee488 = doubleToIEEE488_2_Block(samples);
            formattedString = ['AFG:ARBitrary:EMEM:POINTS ', bytesIeee488];
            BasicLogger.log(LogLevelEnum.ELAPSED_TIME, sprintf("Samples mdo ieee bytes convertion elapsed time %fs", toc(ti)));
            %}
            %obj.flush();
            ti = tic;
            obj.write(formattedString);
            BasicLogger.log(LogLevelEnum.ELAPSED_TIME, sprintf("Samples mdo writing transmission elapsed time %fs", toc(ti)));
            % Aguarda o osciloscopio capturar ao menos uma janela (1 ms) com a
            % nova forma de onda antes do readSamples: com a leitura binaria
            % rapida, sem esse respiro o CURVe? retornava a janela anterior
            % (antiga), corrompendo a decodificacao.
            pause(0.05);
        end

        function signal = readSamples(obj, channelNumber)
            % Leitura binaria (RIBinary) via SCPI bruto, mais rapida que o
            % readwaveform do driver .mdd (que transfere/parsa ASCII).
            obj.flush();
            obj.write("DATa:SOUrce CH" + num2str(channelNumber));
            obj.write("DATa:ENCdg RIBinary");
            obj.write("DATa:WIDth 1");
            % Transfere o registro inteiro, qualquer que seja a configuracao
            % previa de DATa:STARt/STOP deixada por outra sessao.
            obj.write("WFMPre:NR_Pt?");
            recordLength = str2double(fscanf(obj.visaObj));
            obj.write("DATa:STARt 1");
            if ~isempty(recordLength) && isfinite(recordLength) && recordLength >= 1
                obj.write("DATa:STOP " + num2str(recordLength));
            end
            obj.write("CURVe?");
            data = obj.readBinBlock();
            levels = double(typecast(uint8(data), 'int8'));
            obj.write("WFMPre:XINcr?");
            xin = str2double(fscanf(obj.visaObj));
            if isempty(xin) || ~isfinite(xin) || xin <= 0
                n = max(numel(data), 2);
                xin = (obj.timeHorizontalScale * 10) / (n - 1);
            end
            fs = round(1 / xin);
            t = (0:numel(data) - 1) * xin;
            signal = Signal(levels, t, fs);
        end

        function data = readBinBlock(obj)
            % Le um binblock IEEE 488.2 (#<n><comprimento><dados>) do
            % osciloscopio, descartando bytes nao-'#' anteriores ao header.
            while true
                c = fread(obj.visaObj, 1, 'uint8');
                if isempty(c)
                    error('Mdo3012:binblock', 'Fim de stream inesperado na busca do header binblock');
                end
                if c == 35 % '#'
                    break;
                end
            end
            dn = fread(obj.visaObj, 1, 'uint8');
            if isempty(dn)
                error('Mdo3012:binblock', 'Fim de stream inesperado no numero de digitos');
            end
            ndigits = double(dn) - 48;
            if ndigits < 1 || ndigits > 9
                error('Mdo3012:binblock', 'Numero de digitos do comprimento invalido (%d)', double(dn));
            end
            lenBytes = fread(obj.visaObj, ndigits, 'uint8');
            byteCount = str2double(char(lenBytes.'));
            if isnan(byteCount) || byteCount < 0
                error('Mdo3012:binblock', 'Comprimento de binblock invalido');
            end
            data = fread(obj.visaObj, byteCount, 'uint8').';
            if numel(data) ~= byteCount
                error('Mdo3012:binblock', 'Bloco incompleto: %d/%d bytes', numel(data), byteCount);
            end
        end
        
        function status = isConnected(obj)
            if obj.visaObj.Status == "open" 
                status = true;
            else
                status = false;
            end
        end

        function connect(obj)
            if ~obj.isConnected()
                fopen(obj.visaObj);
            end
        end

        function disconnect(obj)
            fclose(obj.visaObj);
        end
        
        % This command specifies the time base horizontal scale.
        % 'timeHorizontalScale' is a floating point number that specifies the range from 400 ps to 1000 s,
        % depending on the record length.
        % 'timeHorizontalScale' represents the time for each squared.
        % Example: 'timeHorizontalScale' = 2E-6 sets the main scale to 2µs per division.
        function setMdoHorizontalScale(obj, timeHorizontalScale)
            obj.timeHorizontalScale = timeHorizontalScale;
            obj.write("HORizontal:SCAle " + obj.timeHorizontalScale);
        end

        function setMdoTermination(obj, channelNumber, termination)
            if(~isa(termination, 'MdoTerminationEnum'))
                me = MException('Mdo3012:setMdoTermination', ...
                    "Termination input should be a type of MdoTerminationEnum");
                throw(me);
            end
            command = sprintf("CH%d:TERmination %s", channelNumber, termination);
            obj.write(command);
        end

        % This command specifies the input attenuator coupling setting for channel <x>
        function setMdoCoupling(obj, channelNumber, coupling)
            arguments
                obj 
                channelNumber (1,1) {mustBeInteger}
                coupling MdoCouplingEnum {mustBeMdoCouplingEnum}
            end

            command = sprintf("CH%d:COUPling %s", channelNumber, coupling);
            obj.write(command);
        end

        % This command specifies channel input termination
        function setMdoAfgOutputState(obj, state)
            arguments
                obj 
                state MdoStateEnum {mustBeMdoStateEnum}
            end
            command = sprintf("AFG:OUTPut:STATE %s", state);
            obj.write(command);
        end

        function setMdoAfgFunction(obj, func)
            arguments
                obj 
                func MdoAfgFunctionEnum {mustBeMdoAfgFunctionEnum}
            end
            command = sprintf("AFG:FUNC %s", func);
            obj.write(command);
        end

        function setMdoAfgOffset(obj, offset)
            arguments
                obj 
                offset (1,1) {mustBeNumeric}
            end
            command = sprintf("AFG:OFFSet %f", offset);
            obj.write(command);
        end

        function setMdoAfgImpedance(obj, impedance)
            arguments
                obj 
                impedance MdoAfgImpedanceEnum {mustBeMdoAfgImpedanceEnum}
            end
            command = sprintf("AFG:OUTPut:LOAd:IMPEDance %s", impedance);
            obj.write(command);
        end

        % Sets (or queries) the AFG amplitude in volts, peak to peak
        function setAfgAmplitude(obj, amplitude)
            arguments
                obj 
                amplitude (1,1) {mustBeNumeric}
            end
            obj.signalAmplitude = amplitude;
            command = sprintf("AFG:AMPLitude %f", amplitude);
            obj.write(command);
        end

        % Clears the following:
        % Event Queue
        % Standard Event Status Register
        % Status Byte Register (except the MAV bit)
        function flush(obj)
            obj.write("*CLS");
        end

        function timeHorizontalScale = getHorizontalScale(obj)
            timeHorizontalScale = obj.timeHorizontalScale;
        end

        function write(obj, command)
            fwrite(obj.visaObj, command);
        end

        % Envia um comando de consulta e retorna a resposta em texto.
        function resp = queryText(obj, command)
            obj.write(command);
            resp = fscanf(obj.visaObj);
        end
    end
end