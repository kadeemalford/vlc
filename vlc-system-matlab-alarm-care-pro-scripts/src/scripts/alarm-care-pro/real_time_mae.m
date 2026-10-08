function real_time_mae(demoMode, runSeconds)
%REAL_TIME_MAE Pipeline VLC em tempo real.
%   Equipamentos (clientes TCP) conectam em:
%     porta 2222  = monitor multiparametrico (HL7)
%     porta 23000 = ventilador (HL7)
%     portas 22001/22002/22003 = bombas de infusao 1/2/3 (frame binario)
%   Mensagens recebidas sao convertidas em frames de ate 10 caracteres
%   (1 frame por variavel/alarme), enfileirados em FIFO e transmitidos por um
%   canal VLC simulado (identidade). Apos o canal, o frame e decodificado e o
%   dado clinico/alarme e exibido no console. CTRL+C encerra.

    root = projectRoot();
    addpath(fullfile(root, 'src', 'scripts', 'alarm-care-pro'));

    if nargin < 1 || isempty(demoMode)
        demoMode = false;
    end
    if nargin < 2 || isempty(runSeconds)
        runSeconds = Inf;
    end
    config = struct( ...
        'TX_INTERVAL_SEC', 0.1, ...
        'DEMO_MODE', demoMode, ...
        'DEMO_BASE', fullfile(root, 'example-files'));

    if config.DEMO_MODE
        setupDemo(config);
    else
        resetTcpState();
        ensureServers();
    end

    cleanup = onCleanup(@() stopTcpServers());
    fprintf('[%s] real_time_mae ativo (TX interval %.2f s). CTRL+C para encerrar.\n', ...
        stamp(), config.TX_INTERVAL_SEC);
    t0 = tic;
    while true
        if isfinite(runSeconds) && toc(t0) > runSeconds
            fprintf('[%s] Encerrando apos %.1f s.\n', stamp(), runSeconds);
            break;
        end
        frame = fifoPop();
        if ~isempty(frame)
            transmitAndShow(frame);
        end
        pause(config.TX_INTERVAL_SEC);
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
% FIFO (via appdata) e transmissao pelo canal VLC simulado (identidade)
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

function frame = fifoPop()
    q = getappdata(0, 'maeFifo');
    if isempty(q)
        frame = '';
        return;
    end
    frame = q{1};
    if numel(q) == 1
        q = {};
    else
        q = q(2:end);
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

function transmitAndShow(frame)
    bits = stringToBits(frame);
    bitsRx = channelVlc(bits);
    frameRx = bitsToString(bitsRx);
    if ~strcmp(frameRx, frame)
        fprintf('[%s] FRAME corrompido no canal: %s -> %s\n', stamp(), frame, frameRx);
    end
    show(frameRx);
end

function out = channelVlc(bits)
    out = bits;
end

function bits = stringToBits(str)
    bytes = uint8(str);
    nbits = 8 * numel(bytes);
    bits = zeros(1, nbits);
    for i = 1:numel(bytes)
        for k = 1:8
            bits((i - 1) * 8 + k) = bitand(bitshift(uint8(bytes(i)), -(k - 1)), uint8(1));
        end
    end
end

function str = bitsToString(bits)
    bits = double(bits(:).');
    nbytes = floor(numel(bits) / 8);
    bytes = zeros(1, nbytes, 'uint8');
    for i = 1:nbytes
        b = uint8(0);
        for k = 1:8
            b = b + uint8(bits((i - 1) * 8 + k)) * uint8(2 ^ (k - 1));
        end
        bytes(i) = b;
    end
    str = char(bytes);
end

% ---------------------------------------------------------------------------
% Decodificacao e exibicao
% ---------------------------------------------------------------------------

function show(frame)
    fr = mae_frame();
    parsed = fr.decode(frame);
    if ~parsed.valid
        fprintf('[%s] FRAME INVALIDO: %s (%s)\n', stamp(), frame, parsed.err);
        return;
    end
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
    mae_frontend().close();
    fprintf('[%s] Servidores TCP encerrados.\n', stamp());
end

function resetTcpState()
    cleanupServerObjects();
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