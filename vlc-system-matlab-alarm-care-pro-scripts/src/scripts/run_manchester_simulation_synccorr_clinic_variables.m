%% run_manchester_simulation_synccorr_clinic_variables.m
% Script: simulação Manchester OOK exibindo em console a string recebida em tempo real.
% Execute a partir da raiz do repositório.

clear; clc; close all;

% Path do código principal (sobe um nível de src/scripts)
srcPath = fileparts(fileparts(mfilename('fullpath')));
addpath(genpath(srcPath));

% Estado compartilhado
state = struct('heartRate', '', 'spo2', '', 'bp', '', ...
               'rawMessage', '', 'ber', 0.0, 'q', 0.0, 'iteration', 0);

% Configuração: Manchester OOK + MDO
parameters = ManchesterOokParameters();
encoder = ManchesterOokEncoder(parameters);
decoder = ManchesterOokDecoder(parameters);

fprintf('VLC Manchester - Variáveis clínicas\n');
fprintf('Pressione Ctrl+C para encerrar.\n\n');

% Conexão única com o MDO.
% Recriar o objeto VISA a cada iteração sobrecarrega os drivers e acaba
% travando a comunicação (ex.: "Unable to create VISA object"). Mantemos
% uma única sessão aberta durante todo o loop.

% Limpa sessões VISA órfãs de execuções anteriores. O MATLAB mantém, na
% memória e no driver, todos os objetos de instrumento criados até que
% sejam fechados/deletados; execuções abortadas (Ctrl+C/erros) acumulam
% sessões e geram "Unable to create VISA object" logo na primeira conexão.
cleanupOrphanInstruments();

txRxAnalyzer = Mdo3012Analyzer("USB::0x0699::0x0408::C024549::INSTR");

% Tenta a conexão inicial com retry, liberando sessões remanescentes entre
% tentativas e dando um respiro ao driver VISA.
maxConnectionAttempts = 5;
connectionDelay = 2.0;
for attempt = 1:maxConnectionAttempts
    try
        txRxAnalyzer.initiateDefaultConnection();
        break;
    catch ME
        if attempt == maxConnectionAttempts
            cleanupAnalyzer(txRxAnalyzer);
            error(['Falha ao conectar no MDO após %d tentativas:\n%s\n\n', ...
                'Se o erro persistir, feche o MATLAB, reinicie o serviço '...
                'VISA (TekVISA/NI-VISA) e recoloque o cabo USB do '...
                'osciloscópio.'], maxConnectionAttempts, ME.message);
        end
        fprintf('[conexão] Tentativa %d/%d falhou (%s). Tentando novamente em %ds...\n', ...
            attempt, maxConnectionAttempts, ME.message, connectionDelay);
        cleanupOrphanInstruments();
        pause(connectionDelay);
    end
end
cleanupObj = onCleanup(@() cleanupAnalyzer(txRxAnalyzer));

system1tx1rx = System1tx1rx(encoder, decoder, txRxAnalyzer, txRxAnalyzer);

iteration = 0;
lastValidTime = 0.0;
simTimer = tic();

while true
    iteration = iteration + 1;
    try
        % reconecta automaticamente (sem recriar os objetos VISA) se a
        % sessão caiu entre as transmissões
        if ~isAnalyzerConnected(txRxAnalyzer)
            setupAnalyzer(txRxAnalyzer);
        end

        % hon_scale = 10000.0 / 10 / parameters.rxSampleRate;
        % txRxAnalyzer.setMdoHorizontalScale(hon_scale);

        cycle = mod(iteration - 1, 3);
        message = buildMessage(cycle);
        bits = stringToBits(message);

        response = system1tx1rx.communicate(bits);

        if toc(simTimer) - lastValidTime > 3.0
            state.heartRate = '';
            state.spo2 = '';
            state.bp = '';
            state.rawMessage = '';
            state.ber = 0.0;
            state.q = 0.0;
        end

        if response.synchSuccessful
            n = min(numel(response.rxBits), numel(bits));
            rxMessage = bitsToString(response.rxBits(1:n));
            qVal = 0.0;
            if ~isempty(response.qFactor)
                qVal = response.qFactor.getQ();
            end
            [ok, state] = parseAndUpdate(rxMessage, state);
            if ok
                lastValidTime = toc(simTimer);
                state.rawMessage = rxMessage;
                fprintf('[%03d] Tx: %s  |  Rx: %s  |  BER: %.2e  |  Q: %.4f\n', ...
                    iteration, message, rxMessage, response.ber, qVal);
            else
                state.rawMessage = 'Corrupted message.';
                fprintf('[%03d] Tx: %s  |  Rx: %s (CORROMPIDA)  |  BER: %.2e  |  Q: %.4f\n', ...
                    iteration, message, rxMessage, response.ber, qVal);
            end
            state.ber = response.ber;
            state.q = qVal;
            state.iteration = iteration;
        else
            state.rawMessage = 'Corrupted message.';
            fprintf('[%03d] Falha na sincronização.\n', iteration);
        end
    catch ME
        fprintf('[%03d] Erro: %s\n', iteration, ME.message);
    end

    pause(0.1);
end


%% Conexão com o MDO
function cleanupOrphanInstruments()
    % Fecha e remove todos os objetos de instrumento registrados no MATLAB,
    % liberando as sessões VISA presas por execuções anteriores abortadas.
    try
        orphanObjects = instrfind;
        if ~isempty(orphanObjects)
            try
                fclose(orphanObjects);
            catch
            end
            try
                delete(orphanObjects);
            catch
            end
        end
    catch
    end
end

function connected = isAnalyzerConnected(analyzer)
    connected = false;
    try
        connected = analyzer.isConnected();
    catch
    end
end

function setupAnalyzer(analyzer)
    if ~isAnalyzerConnected(analyzer)
        analyzer.connect();
    end
    analyzer.flush();
    analyzer.setMdoAfgOutputState(MdoStateEnum.ON);
    analyzer.setMdoAfgImpedance(MdoAfgImpedanceEnum.HIGHZ);
    analyzer.setMdoAfgFunction(MdoAfgFunctionEnum.ARBITRARY);
    analyzer.setMdoAfgOffset(0);
    analyzer.setAfgAmplitude(1);
    analyzer.setMdoTermination(1, MdoTerminationEnum.MEG);
    analyzer.setMdoTermination(2, MdoTerminationEnum.MEG);
    analyzer.setMdoCoupling(1, MdoCouplingEnum.AC);
    analyzer.setMdoCoupling(2, MdoCouplingEnum.AC);
    analyzer.setMdoHorizontalScale(analyzer.getHorizontalScale());
end

function cleanupAnalyzer(analyzer)
    try
        if isAnalyzerConnected(analyzer)
            analyzer.disconnect();
        end
    catch
    end
end

%% Helpers caractere <-> bits
function bits = stringToBits(message)
    lengthVal = numel(message);
    bits = zeros(1, 8 + 8 * lengthVal);
    idx = 1;
    for i = 7:-1:0
        bits(idx) = bitand(bitshift(lengthVal, -i), 1);
        idx = idx + 1;
    end
    for k = 1:lengthVal
        byte = double(message(k));
        for i = 7:-1:0
            bits(idx) = bitand(bitshift(byte, -i), 1);
            idx = idx + 1;
        end
    end
end

function message = bitsToString(bits)
    bits = bits(:).';
    if numel(bits) < 8
        message = '';
        return;
    end
    lengthVal = 0;
    for i = 1:8
        lengthVal = bitshift(lengthVal, 1) + bits(i);
    end
    charsOut = char(zeros(1, 0));
    for i = 0:lengthVal - 1
        if (i + 1) * 8 > numel(bits) - 8
            break;
        end
        byte = 0;
        for j = 1:8
            byte = bitshift(byte, 1) + bits(8 + i * 8 + j);
        end
        charsOut(end + 1) = char(byte); %#ok<AGROW>
    end
    message = charsOut;
end

%% Mensagens clínicas
function message = buildMessage(cycle)
    switch cycle
        case 0
            hr = randi([60 100]);
            message = sprintf('Heart rate: %d bpm', hr);
        case 1
            spo2 = randi([95 100]);
            message = sprintf('SpO2: %d%%', spo2);
        otherwise
            sysBP = randi([100 140]);
            dia = randi([60 90]);
            message = sprintf('BP: %d/%d mmHg', sysBP, dia);
    end
end

function [ok, state] = parseAndUpdate(rxStr, state)
    s = strtrim(rxStr);
    if contains(s, "Heart rate")
        state.heartRate = strrep(s, 'Heart rate: ', '');
    elseif contains(s, "SpO2")
        state.spo2 = strrep(s, 'SpO2: ', '');
    elseif contains(s, 'BP:')
        state.bp = strrep(s, 'BP: ', '');
    else
        ok = false;
        return;
    end
    ok = true;
end