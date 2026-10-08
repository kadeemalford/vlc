classdef System1tx1rxController < handle
    
    properties (Access = private)
        system1tx1rx System1tx1rx
        app
        txRxAnalyzer(1,1) AbstractLogicAnalyzer = BackToBackAnalyzer();
        parameters
        signalEncoder
        signalDecoder
    end
    
    methods
        function obj = System1tx1rxController(app)
            %txRxAnalyzer = BackToBackAnalyzer();
            obj.app = app;
            obj.parameters = ManchesterOokParameters();
            obj.signalEncoder = ManchesterOokEncoder(obj.parameters);
            obj.signalDecoder = ManchesterOokDecoder(obj.parameters);

            try
                obj.txRxAnalyzer =  Mdo3012Analyzer("USB::0x0699::0x0408::C024549::INSTR");
                obj.txRxAnalyzer.initiateDefaultConnection();
                obj.app.Mdo3012Lamp.Color = 'green';
                honScale = 10000/10/obj.parameters.rxSampleRate;
                obj.txRxAnalyzer.setMdoHorizontalScale(honScale);
            catch
                text = "Erro ao se conectar com o MDO3012 ... Habilitando Simulação";
                obj.app.setErrorMassage(text);
                obj.txRxAnalyzer = BackToBackChannelAnalyzer(20, 1e6);
                obj.app.SimulationSwitch.Value = "On";
                app.Mdo3012Lamp.Color = 'red';
            end
            
            obj.system1tx1rx = System1tx1rx(obj.signalEncoder, obj.signalDecoder, obj.txRxAnalyzer, obj.txRxAnalyzer);
        end

        function response = communicate(obj)
            bits = randi([0 1], 1, obj.parameters.recommendedBitNumber);
            response = obj.system1tx1rx.communicate(bits);
        end
        
        function switchToSimulation(obj)
            %obj.txRxAnalyzer.disconnect();
            obj.txRxAnalyzer = BackToBackChannelAnalyzer(20, 1e6);
        end
        
        function switchToMdo(obj)
            try
                obj.txRxAnalyzer =  Mdo3012Analyzer("USB::0x0699::0x0408::C024645::INSTR");
                obj.txRxAnalyzer.initiateDefaultConnection();
                obj.app.Mdo3012Lamp.Color = 'green';
            catch
                text = "Erro ao se conectar com o MDO3012 ... Habilitando Simulação";
                obj.app.setErrorMassage(text);
                obj.txRxAnalyzer = BackToBackChannelAnalyzer(20, 1e6);
                obj.app.SimulationSwitch.Value = "On";
                obj.app.Mdo3012Lamp.Color = 'red';
            end
        end
        
        function disconnectAnalizer(obj)
            obj.txRxAnalyzer.disconnect();
        end
        
        function parameters = getOokParameters(obj)
            parameters = obj.parameters; 
        end
    end
end

