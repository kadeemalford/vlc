function real_time_mae_vlc(demoMode, runSeconds)
%REAL_TIME_MAE_VLC Pipeline VLC em tempo real com canal fisico (MDO3012).
%   Equipamentos (clientes TCP) conectam em:
%     porta 2222  = monitor multiparametrico (HL7)
%     porta 23000 = ventilador (HL7)
%     portas 22001/22002/22003 = bombas de infusao 1/2/3 (frame binario)
%   Mensagens recebidas sao convertidas em chunks (1 por variavel/alarme, no
%   formato legado !#EQKIND..., ate 10 chars cada), empacotados em frames VLC
%   de ate MAX_FRAME_CHARS separados por '|' (ex.: !#MDHR0090|!#VAMX11|!#1A07)
%   e transmitidos por um canal VLC REAL (Manchester OOK, osciloscopio MDO3012 como DAC/ADC, usando
%   a biblioteca src/main). Apos o canal, o frame e decodificado e o dado
%   clinico/alarme e exibido no console e enviado ao backend (mae_frontend).
%   Os comandos do frontend (silenciar/refresh dos alarmes das bombas) chegam
%   pelo mesmo gateway TCP do backend e sao escritos DIRETO no socket do
%   equipamento alvo, sem passar pela FIFO nem pelo VLC.
%   CTRL+C encerra.

    root = projectRoot();
    addpath(fullfile(root, 'src', 'scripts', 'alarm-care-pro'));
    addpath(genpath(fullfile(root, 'src', 'main')));

    if nargin < 1 || isempty(demoMode)
        demoMode = false;
    end
    if nargin < 2 || isempty(runSeconds)
        runSeconds = Inf;
    end
    config = struct( ...
        'TX_INTERVAL_SEC', 0.01, ...
        'MAX_FRAME_CHARS', 58, ...
        'DEMO_MODE', demoMode, ...
        'DEMO_BASE', fullfile(root, 'example-files'));

    % Comunicacao VLC real: conexao unica com o MDO (evita o crash por
    % recriar objetos VISA repetidamente) e System de 1 TX / 1 RX.
    [txRxAnalyzer, vlcSystem] = setupVlcLink();
    vlcCleanup = onCleanup(@() cleanupAnalyzer(txRxAnalyzer));

    if config.DEMO_MODE
        setupDemo(config);
    else
        resetTcpState();
        ensureServers();
    end

    % Comandos do frontend (silenciar/refresh dos alarmes das bombas) chegam
    % pelo gateway TCP e sao escritos DIRETO no socket do equipamento alvo,
    % sem passar pela FIFO nem pelo canal VLC.
    mae_frontend().setCommandHandler(@commandToEquipment);

    tcpCleanup = onCleanup(@() stopTcpServers());
    fprintf('[%s] real_time_mae_vlc ativo (TX interval %.2f s). CTRL+C para encerrar.\n', ...
        stamp(), config.TX_INTERVAL_SEC);
    t0 = tic;
    iteration = 0;
    while true
        if isfinite(runSeconds) && toc(t0) > runSeconds
            fprintf('[%s] Encerrando apos %.1f s.\n', stamp(), runSeconds);
            break;
        end
        frame = fifoPopBatch(config.MAX_FRAME_CHARS);
        if ~isempty(frame)
            iteration = iteration + 1;
            transmitAndShow(frame, iteration, txRxAnalyzer, vlcSystem);
        end
        pause(config.TX_INTERVAL_SEC);
    end
end

% ---------------------------------------------------------------------------
% Comunicacao VLC real (adaptado de run_manchester_simulation_synccorr_clinic_variables.m)
% ---------------------------------------------------------------------------

function [txRxAnalyzer, vlcSystem] = setupVlcLink()
    parameters = ManchesterOokParameters();
    encoder = ManchesterOokEncoder(parameters);
    decoder = ManchesterOokDecoder(parameters);

    % Limpa sessoes VISA orfas de execucoes anteriores. O MATLAB mantem todos
    % os objetos de instrumento criados ate que sejam fechados/deletados;
    % execucoes abortadas acumulam sessoes e geram "Unable to create VISA object".
    cleanupOrphanInstruments();

    txRxAnalyzer = Mdo3012Analyzer("USB::0x0699::0x0408::C024549::INSTR");

    % Tenta a conexao inicial com retry, liberando sessoes remanescentes entre
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
                error(['Falha ao conectar no MDO apos %d tentativas:\n%s\n\n', ...
                    'Se o erro persistir, feche o MATLAB, reinicie o servico '...
                    'VISA (TekVISA/NI-VISA) e recoloque o cabo USB do '...
                    'osciloscopio.'], maxConnectionAttempts, ME.message);
            end
            fprintf('[conexao] Tentativa %d/%d falhou (%s). Tentando novamente em %ds...\n', ...
                attempt, maxConnectionAttempts, ME.message, connectionDelay);
            cleanupOrphanInstruments();
            pause(connectionDelay);
        end
    end

    vlcSystem = System1tx1rx(encoder, decoder, txRxAnalyzer, txRxAnalyzer);
end

function cleanupOrphanInstruments()
    % Fecha e remove todos os objetos de instrumento registrados no MATLAB,
    % liberando as sessoes VISA presas por execucoes anteriores abortadas.
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

% ---------------------------------------------------------------------------
% Modo demo (opcional): alimenta a FIFO a partir de example-files, sem TCP
% ---------------------------------------------------------------------------

function setupDemo(config)
    mh = mae_handlers();
    setappdata(0, 'maeTcpMh', mh);
    demoEnfileira(mh, fullfile(config.DEMO_BASE, 'monitor', 'file(1).hl7'), '');
    demoEnfileira(mh, fullfile(config.DEMO_BASE, 'ventilator', 'file141.hl7'), '');
    demoEnfileira(mh, fullfile(config.DEMO_BASE, 'ventilator', 'alarm1.hl7'), '');
    demoEnfileira(mh, fullfile(config.DEMO_BASE, 'bomb', 'file1.txt'), 'Bomb1');
end

function demoEnfileira(mh, arquivo, tipo)
    if ~isfile(arquivo)
        fprintf('demo: arquivo ausente: %s\n', arquivo);
        return;
    end
    [~, ~, ext] = fileparts(arquivo);
    if strcmp(ext, '.txt')
        fid = fopen(arquivo, 'rb');
        raw = fread(fid, Inf, 'uint8').';
        fclose(fid);
        msg = mh.handleBombData(raw, tipo);
    else
        raw = fileread(arquivo);
        raw = raw(raw ~= char(11) & raw ~= char(26));
        if contains(raw, 'Ventilator')
            msg = mh.handleVentilatorData(raw);
        else
            msg = mh.handleMonitorData(raw);
        end
    end
    enqueue(msg);
    fprintf('demo: %s carregado\n', arquivo);
end

% ---------------------------------------------------------------------------
% Servidores TCP (adaptado do real_time_reading_tcp.m)
% ---------------------------------------------------------------------------

function ensureServers()
    if isequal(getappdata(0, 'maeTcpStarted'), true)
        return;
    end
    setappdata(0, 'maeTcpStarted', true);

    mh = mae_handlers();
    setappdata(0, 'maeTcpMh', mh);

    localhostIp = getenv('SERVER_IP');
    if isempty(localhostIp)
        localhostIp = '0.0.0.0';
    end

    portas = {2222, 'monitor'; 23000, 'ventilador'; ...
        22001, 'bomb1'; 22002, 'bomb2'; 22003, 'bomb3'};
    servers = struct();
    for i = 1:size(portas, 1)
        porta = portas{i, 1};
        nome = portas{i, 2};
        try
            srv = tcpserver(localhostIp, porta);
            srv.ConnectionChangedFcn = @(src, evt) connectionCallback(src, evt);
            switch nome
                case 'monitor'
                    configureCallback(srv, 'byte', 1, @monitorCallback);
                case 'ventilador'
                    configureCallback(srv, 'byte', 1, @ventilatorCallback);
                otherwise
                    configureCallback(srv, 'byte', 1, @(src, ~) bombCallback(src, porta, ['Bomb' nome(end)]));
            end
            servers.(nome) = srv;
            fprintf('[%s] Servidor TCP pronto: %s na porta %d\n', stamp(), nome, porta);
        catch err
            fprintf('[%s] Aviso: nao foi possivel criar o servidor %s na porta %d: %s\n', ...
                stamp(), nome, porta, err.message);
        end
    end
    setappdata(0, 'maeTcpServers', servers);
end

function connectionCallback(src, evt)
    if evt.Connected
        fprintf('[%s] Nova conexao TCP na porta %d\n', stamp(), src.ServerPort);
    else
        fprintf('[%s] Conexao TCP encerrada (porta %d)\n', stamp(), src.ServerPort);
    end
end

function monitorCallback(src, ~)
    if src.NumBytesAvailable <= 0
        return;
    end
    try
        data = char(read(src, src.NumBytesAvailable));
        processHl7(2222, data, false);
    catch err
        fprintf('[%s] Erro no monitor: %s\n', stamp(), err.message);
    end
end

function ventilatorCallback(src, ~)
    if src.NumBytesAvailable <= 0
        return;
    end
    try
        data = char(read(src, src.NumBytesAvailable));
        processHl7(23000, data, true);
    catch err
        fprintf('[%s] Erro no ventilador: %s\n', stamp(), err.message);
    end
end

function bombCallback(src, porta, nome)
    if src.NumBytesAvailable <= 0
        return;
    end
    try
        data = uint8(read(src, src.NumBytesAvailable));
        processBomb(porta, data, nome);
    catch err
        fprintf('[%s] Erro na %s: %s\n', stamp(), nome, err.message);
    end
end

% ---------------------------------------------------------------------------
% Downlink: comando do frontend direto no socket do equipamento
% ---------------------------------------------------------------------------

function commandToEquipment(target, bytes)
%COMMANDTOEQUIPMENT Escreve o comando recebido do gateway direto no equipamento.
%   target = nome do equipamento em maeTcpServers ('bomb1'|'bomb2'|'bomb3')
%   bytes  = frame binario do protocolo SAM Manager, ja em uint8
%
%   O comando NAO entra na FIFO e NAO e transmitido pelo canal VLC: vai
%   direto para o socket TCP do equipamento conectado na porta correspondente
%   (22001/22002/22003), igual o DeviceServer fazia no caminho legado.
    servers = getappdata(0, 'maeTcpServers');
    if isempty(servers) || ~isstruct(servers) || ~isfield(servers, target)
        fprintf('[%s] Comando para "%s" descartado: equipamento sem servidor TCP.\n', ...
            stamp(), target);
        return;
    end
    srv = servers.(target);
    if ~isvalid(srv) || ~srv.Connected
        fprintf('[%s] Comando para "%s" descartado: equipamento desconectado.\n', ...
            stamp(), target);
        return;
    end
    try
        write(srv, bytes, 'uint8');
        fprintf('[%s] Comando direto para %s: %d bytes na porta %d.\n', ...
            stamp(), target, numel(bytes), srv.ServerPort);
    catch err
        fprintf('[%s] Falha ao escrever o comando em %s: %s\n', stamp(), target, err.message);
    end
end

% ---------------------------------------------------------------------------
% Buffer por porta + parse + enfileiramento na FIFO
% ---------------------------------------------------------------------------

function processHl7(porta, data, isVent)
    buf = getBuffer(porta);
    agora = now;
    if ~isempty(buf.data) && agora - buf.ts > 8 / 86400
        buf.data = '';
    end
    buf.data = appendIfNew(buf.data, data);
    if numel(buf.data) > 65536
        buf.data = buf.data(end - 32767:end);
    end
    mh = getappdata(0, 'maeTcpMh');
    if isVent
        msg = mh.handleVentilatorData(buf.data);
    else
        msg = mh.handleMonitorData(buf.data);
    end
    if isempty(msg.variables) && isempty(msg.alarms)
        buf.ts = agora;
        setBuffer(porta, buf);
        return;
    end
    setBuffer(porta, struct('data', '', 'ts', agora));
    enqueue(msg);
end

function processBomb(porta, data, nome)
    buf = getBuffer(porta);
    agora = now;
    if ~isempty(buf.data) && agora - buf.ts > 8 / 86400
        buf.data = uint8([]);
    end
    buf.data = appendIfNew(buf.data, data(:).');
    if numel(buf.data) > 256
        buf.data = buf.data(end - 127:end);
    end
    mh = getappdata(0, 'maeTcpMh');
    try
        msg = mh.handleBombData(buf.data, nome);
    catch
        buf.ts = agora;
        setBuffer(porta, buf);
        return;
    end
    % O numero de serie vem do pacote cru e NAO cabe no frame VLC (limite de
    % 10 chars). Memoriza-se aqui para o mae_frontend poder incluir no payload
    % que o front-end usa para montar o comando silenciar/refresh.
    if isfield(msg, 'deviceId') && ~isempty(msg.deviceId)
        mae_frontend().setPumpSerial(nome(end), msg.deviceId);
    end
    setBuffer(porta, struct('data', uint8([]), 'ts', agora));
    enqueue(msg);
end

function enqueue(msg)
    fr = mae_frame();
    frames = fr.encode(msg);
    for i = 1:numel(frames)
        fifoPush(frames{i});
    end
    fprintf('[%s] %s: enfileirados %d frames (fila=%d)\n', stamp(), msg.type, ...
        numel(frames), fifoSize());
end

function buf = getBuffer(porta)
    buf = getappdata(0, sprintf('maeTcpBuf%d', porta));
    if isempty(buf)
        buf = struct('data', '', 'ts', now);
    end
end

function setBuffer(porta, buf)
    setappdata(0, sprintf('maeTcpBuf%d', porta), buf);
end

function out = appendIfNew(bufData, data)
    n = numel(data);
    if isempty(bufData) || n == 0
        out = [bufData, data];
        return;
    end
    if numel(bufData) >= n
        tail = bufData(end - n + 1:end);
        if isequal(tail, data)
            out = bufData;
            return;
        end
    end
    out = [bufData, data];
end

% ---------------------------------------------------------------------------
% FIFO (via appdata) e transmissao pelo canal VLC real
% ---------------------------------------------------------------------------

function fifoPush(frame)
    q = getappdata(0, 'maeFifo');
    if isempty(q)
        q = {frame};
    else
        q{end + 1} = frame;
    end
    setappdata(0, 'maeFifo', q);
end

function n = fifoSize()
    q = getappdata(0, 'maeFifo');
    if isempty(q)
        n = 0;
    else
        n = numel(q);
    end
end

function frame = fifoPopBatch(maxLen)
%FIFOPOPBATCH Retira da fila quantos chunks couberem em um frame de ate maxLen
%   caracteres (guloso) e retorna o frame empacotado com '|'. Fila vazia -> ''.
    q = getappdata(0, 'maeFifo');
    if isempty(q)
        frame = '';
        return;
    end
    fr = mae_frame();
    take = {};
    curLen = 0;
    for i = 1:numel(q)
        added = numel(q{i});
        if i > 1
            added = added + 1; % separador '|'
        end
        if i > 1 && curLen + added > maxLen
            break;
        end
        take{end + 1} = q{i}; %#ok<AGROW>
        curLen = curLen + added;
    end
    if numel(take) < numel(q)
        q = q(numel(take) + 1:end);
    else
        q = {};
    end
    setappdata(0, 'maeFifo', q);
    packedCell = fr.pack(take, maxLen);
    if isempty(packedCell)
        frame = '';
    else
        frame = packedCell{1};
    end
end

function transmitAndShow(frame, iteration, txRxAnalyzer, vlcSystem)
    % Converte o frame em bits no padrao Manchester (header de 8 bits de
    % comprimento + 8 bits por caractere, MSB-first), identico ao
    % run_manchester_simulation_synccorr_clinic_variables.m: os bits da
    % mensagem sao transmitidos diretamente, SEM padding.
    bits = stringToBits(frame);

    % Reconecta automaticamente (sem recriar os objetos VISA) se a sessao caiu.
    if ~isAnalyzerConnected(txRxAnalyzer)
        setupAnalyzer(txRxAnalyzer);
    end

    try
        response = vlcSystem.communicate(bits, false);
    catch ME
        fprintf('[%s] [%04d] Erro na transmissao VLC do frame "%s": %s\n', ...
            stamp(), iteration, frame, ME.message);
        return;
    end

    if ~response.synchSuccessful
        fprintf('[%s] [%04d] SINC FALHOU no frame "%s".\n', stamp(), iteration, frame);
        return;
    end

    n = min(numel(response.rxBits), numel(bits));
    frameRx = bitsToString(response.rxBits(1:n));
    qVal = 0.0;
    if ~isempty(response.qFactor)
        qVal = response.qFactor.getQ();
    end
    fprintf('[%s] [%04d] Tx: %s  |  Rx: %s  |  BER: %.2e  |  Q: %.4f\n', ...
        stamp(), iteration, frame, frameRx, response.ber, qVal);
    if ~strcmp(frameRx, frame)
        fprintf('[%s] FRAME corrompido no canal: "%s" -> "%s"\n', stamp(), frame, frameRx);
    end
    show(frameRx);
end

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
    charsOut = '';
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

% ---------------------------------------------------------------------------
% Decodificacao e exibicao
% ---------------------------------------------------------------------------

function show(frame)
    fr = mae_frame();
    chunks = fr.unpack(frame);
    if isempty(chunks)
        fprintf('[%s] FRAME VAZIO: %s\n', stamp(), frame);
        return;
    end
    anyValid = false;
    for i = 1:numel(chunks)
        parsed = fr.decode(chunks{i});
        if ~parsed.valid
            fprintf('[%s] FRAME INVALIDO: %s (%s)\n', stamp(), chunks{i}, parsed.err);
            continue;
        end
        anyValid = true;
        showMessage(parsed);
    end
    if ~anyValid
        fprintf('[%s] Nenhuma mensagem valida no frame "%s".\n', stamp(), frame);
    end
end

function showMessage(parsed)
    mf = mae_frontend();
    mf.sendDecodedPayload(parsed);

    reg = mae_registry();
    eqName = reg.eqName(parsed.eq);
    if parsed.kind == 'D'
        [name, unit, scale] = reg.lookupVariableByAbbr(parsed.eq, parsed.abbr);
        if isempty(name)
            fprintf('[%s] %s variavel desconhecida <%s> valor=%d\n', stamp(), ...
                eqName, parsed.abbr, parsed.valueNum);
            return;
        end
        fprintf('[%s] %s %s = %s %s\n', stamp(), eqName, name, ...
            formatValue(parsed.valueNum, scale), strrep(unit, char(186), char(176)));
    else
        if parsed.eq == 'V'
            desc = reg.alarmAbbrToDesc(parsed.abbr);
            if isempty(desc)
                desc = ['Alarme desconhecido ' parsed.abbr];
            end
            if parsed.state == '1'
                st = 'ATIVO';
            else
                st = 'INATIVO';
            end
            fprintf('[%s] %s %s | %s | %s\n', stamp(), eqName, desc, st, ...
                priNumToText(str2double(parsed.pri)));
        else
            if parsed.pumpIndex == 0
                fprintf('[%s] %s NAO HA ALARMES ATIVOS\n', stamp(), eqName);
            else
                fprintf('[%s] %s %s | ATIVO\n', stamp(), eqName, reg.pumpDesc(parsed.pumpIndex));
            end
        end
    end
end

function out = formatValue(n, scale)
    if scale == 100
        out = stripZeros(sprintf('%.2f', n / 100));
    else
        out = num2str(n);
    end
end

function s = stripZeros(s)
    if any(s == '.')
        k = numel(s);
        while k > 1 && s(k) == '0'
            k = k - 1;
        end
        s = s(1:k);
        if s(end) == '.'
            s = s(1:end - 1);
        end
    end
end

function t = priNumToText(n)
    switch n
        case 1
            t = 'MED';
        case 2
            t = 'HI';
        case 3
            t = 'LO';
        otherwise
            t = '';
    end
end

function s = stamp()
    s = datestr(now, 'HH:MM:SS');
end

function root = projectRoot()
    root = fullfile(fileparts(fileparts(fileparts(fileparts(mfilename('fullpath'))))));
end

% ---------------------------------------------------------------------------
% Encerramento
% ---------------------------------------------------------------------------

function stopTcpServers()
    cleanupServerObjects();
    try
        rmappdata(0, 'maeTcpStarted');
    catch
    end
    for porta = [2222, 23000, 22001, 22002, 22003]
        try
            rmappdata(0, sprintf('maeTcpBuf%d', porta));
        catch
        end
    end
    setappdata(0, 'maeFifo', {});
    mf = mae_frontend();
    mf.setCommandHandler([]);
    mf.close();
    fprintf('[%s] Servidores TCP encerrados.\n', stamp());
end

function resetTcpState()
    cleanupServerObjects();
    mae_frontend().setCommandHandler([]);
    try
        rmappdata(0, 'maeTcpServers');
    catch
    end
    try
        rmappdata(0, 'maeTcpMh');
    catch
    end
    try
        rmappdata(0, 'maeTcpStarted');
    catch
    end
    try
        rmappdata(0, 'maePumpSerials');
    catch
    end
    for porta = [2222, 23000, 22001, 22002, 22003]
        try
            rmappdata(0, sprintf('maeTcpBuf%d', porta));
        catch
        end
    end
    setappdata(0, 'maeFifo', {});
end

function cleanupServerObjects()
    servers = getappdata(0, 'maeTcpServers');
    if ~isempty(servers) && isstruct(servers)
        nomes = fieldnames(servers);
        for i = 1:numel(nomes)
            obj = servers.(nomes{i});
            if isvalid(obj)
                try
                    delete(obj);
                catch
                end
            end
        end
    end
end