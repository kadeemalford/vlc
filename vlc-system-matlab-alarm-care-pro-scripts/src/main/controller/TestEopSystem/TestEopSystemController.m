classdef TestEopSystemController < handle
    
    properties (Access = private)
        system1tx1rx System1tx1rx
        app
        txAnalyzer(1,1) AbstractLogicAnalyzer = BackToBackAnalyzer();
        rxAnalyzer(1,1) AbstractLogicAnalyzer = BackToBackAnalyzer();
        parameters
        signalEncoder
        signalDecoder
        enableSameTxRxMdo
        mdoTxName
        mdoRxName
    end
    
    methods
        function obj = TestEopSystemController(app)
            %txRxAnalyzer = BackToBackAnalyzer();
            obj.app = app;
            obj.parameters = ManchesterOokParameters(); 
            obj.signalEncoder = ManchesterOokEncoder(obj.parameters);
            obj.signalDecoder = ManchesterOokDecoder(obj.parameters);
            obj.enableSameTxRxMdo = false;
            % se enableSameTxRxMdo = true, o mdoTxName é o principal e será
            % "repetido" para o receptor
            obj.mdoTxName = "USB::0x0699::0x0408::C024549::INSTR";
            obj.mdoRxName = "TCPIP::172.20.25.181::INSTR"; % exemplo para conexão ip strcat('TCPIP::',mdo2.ip,'::INSTR');
            
            obj.connectToMdo()
            
            obj.system1tx1rx = System1tx1rx(obj.signalEncoder, obj.signalDecoder, obj.txAnalyzer, obj.rxAnalyzer);
        end

        function communicate(obj, nIteration, afgVoltageList)
            qFactorList = [];
            afgList = [];
            path = obj.createDataFolder();
            for afgVoltage = afgVoltageList
                responses = [];
                obj.app.setInfoMassage("Processing AFG voltage equal to " + string(afgVoltage))
                for n = 1:nIteration
                    obj.app.setInfoMassage(sprintf("Processing AFG = %.2f | Iteration %d/%d ", afgVoltage, n, nIteration));
                    obj.txAnalyzer.setAfgAmplitude(afgVoltage)
                    bits = randi([0 1], 1, obj.parameters.recommendedBitNumber);
                    response = obj.system1tx1rx.communicate(bits);
                    responses = [responses response];
                    if(n == 1 || mod(n,10) == 0)
                        obj.updateViews(response);
                    end
                end
                if(response.synchSuccessful)
                    qFactorList = [qFactorList response.qFactor.getQ()];
                    afgList = [afgList afgVoltage];
                    obj.app.updateQFactorAxes(afgList, qFactorList)
                end
                
                obj.save(path, afgVoltage, responses)
                answer = questdlg('deseja executar próximo afg?', ...
                  'Confirmação', ...
                  'Sim', 'Não', 'Sim');   
                if strcmp(answer, 'Não')
                    break
                end
            end
        end
    
        function updateViews(obj, response)
            if(response.synchSuccessful)
                obj.app.updateSignalAxes(response);
                obj.app.updateEyeDiagramAxes(response);
                obj.app.updateProbAxes(response);
            else
                obj.app.setErrorMassage("Error during sychronization")
            end
        end
        
        function dataFolderPath = createDataFolder(obj)
            projectPath = fileparts(fileparts(fileparts(fileparts(fileparts(mfilename('fullpath'))))));
            folderName = datestr(datetime('now'), 'yyyy_mm_dd_HH_MM_SS');
            dataFolderPath = fullfile(projectPath, "data/"+folderName);
            mkdir(dataFolderPath);
        end
        
        function save(obj, path, afg, responses)
            if(~isempty(responses))
                fileName = "afg_" + strrep(string(afg), ".", "p");
                dataFolderPath = fullfile(path, fileName);
                save(dataFolderPath, 'responses');
                obj.app.setInfoMassage("The data was saved at " + dataFolderPath)
            else
                obj.app.setErrorMassage("Run a transmission first")
            end
        end
        
        function switchToSimulation(obj)
            obj.txAnalyzer = BackToBackChannelAnalyzer(20, 1e6);
            obj.rxAnalyzer = obj.txAnalyzer;
        end

        function connectToMdo(obj)
            try
                obj.txAnalyzer =  Mdo3012Analyzer(obj.mdoTxName);
                obj.txAnalyzer.initiateDefaultConnection();
                honScale = 10000/10/obj.parameters.rxSampleRate;
                obj.txAnalyzer.setMdoHorizontalScale(honScale);
                if(obj.enableSameTxRxMdo)
                    obj.rxAnalyzer = obj.txAnalyzer;
                else
                    obj.rxAnalyzer =  Mdo3012Analyzer(obj.mdoRxName);
                    obj.rxAnalyzer.initiateDefaultConnection();
                    obj.rxAnalyzer.setMdoHorizontalScale(honScale);
                end

                obj.app.Mdo3012Lamp.Color = 'green';
                
            catch
                text = "Erro ao se conectar com o MDO3012 ... Habilitando Simulação";
                obj.app.setErrorMassage(text);
                obj.txAnalyzer = BackToBackChannelAnalyzer(20, 1e6);
                obj.rxAnalyzer = obj.txAnalyzer;
                obj.app.SimulationSwitch.Value = "On";
                app.Mdo3012Lamp.Color = 'red';
            end
        end

        function switchToMdo(obj)
            connectToMdo(obj);
        end
        
        function disconnectAnalizer(obj)
            obj.txAnalyzer.disconnect();
            if(~obj.enableSameTxRxMdo)
                obj.rxAnalyzer.disconnect();
            end
        end
        
        function parameters = getOokParameters(obj)
            parameters = obj.parameters; 
        end
    end
end

