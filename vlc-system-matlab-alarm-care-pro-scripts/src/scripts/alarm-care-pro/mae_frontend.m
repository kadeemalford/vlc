function mf = mae_frontend()
%MAE_FRONTEND Ponte entre a pipeline VLC e o backend Node (socket.io/gateway).
%   mf = mae_frontend() retorna struct de funcoes:
%     mf.sendDecodedPayload(parsed) -> traduz o frame decodificado (struct de
%                                      mae_frame.decode, validada) em um payload
%                                      JSON e o envia (NDJSON) ao gateway TCP
%                                      do backend Node (porta 4455).
%     mf.setPumpSerial(eq, serial)  -> memoriza o numero de serie da bomba
%                                      ('1'|'2'|'3') lido do pacote cru, para
%                                      incluir no payload. O frame VLC nao tem
%                                      espaco para o serial, entao ele e
%                                      recuperado aqui.
%     mf.setCommandHandler(fh)     -> registra fh(target, bytes) para receber os
%                                      comandos do frontend. Para desregistrar,
%                                      passe [].
%     mf.close()                    -> fecha a conexao com o gateway.
%
%   Fluxo bidirecional na MESMA conexao TCP (porta 4455):
%     dados:    MATLAB -> gateway -> socket.io (4444) -> React
%     comandos: React  -> socket.io -> gateway -> MATLAB
%   Os comandos do gateway sao linhas NDJSON {"target":"bomb1","command":"<base64>"};
%   o bytes decodificado e entregue ao handler como vetor uint8 linha. O handler
%   decide o que fazer com eles (o real_time_mae_vlc escreve direto no socket do
%   equipamento, sem passar pelo VLC).
%
%   Falhas de conexao sao toleradas: a pipeline VLC segue rodando normalmente
%   mesmo que o gateway esteja fora do ar. Um novo envio tenta reconectar, mas
%   apenas se a ultima falha ocorreu ha mais de 5 s.
%
%   OBS (importante): o JSON e montado manualmente (sprintf) em vez de um
%   struct + jsonencode, porque o jsonencode do MATLAB converte struct 1x1 em
%   OBJETO JSON (e cell 1x1 aninhado como campo de struct e desenrolado), o que
%   quebraria os arrays "variables"/"alarms" que o front-end React espera.

    mf = struct( ...
        'sendDecodedPayload', @sendDecodedPayload, ...
        'setPumpSerial', @setPumpSerial, ...
        'setCommandHandler', @setCommandHandler, ...
        'close', @close);
end

% ---------------------------------------------------------------------------
% Numero de serie das bombas (nao cabe no frame VLC)
% ---------------------------------------------------------------------------

function setPumpSerial(eq, serial)
%SETPUMPSERIAL Memoriza o numero de serie de uma bomba, por codigo de equipamento.
    if isempty(eq) || isempty(serial)
        return;
    end
    cache = getappdata(0, 'maePumpSerials');
    if isempty(cache) || ~isstruct(cache)
        cache = struct();
    end
    cache.(matlab.lang.makeValidName(eq)) = serial;
    setappdata(0, 'maePumpSerials', cache);
end

function s = pumpSerialFor(eq)
%PUMPSERIALFOR Numero de serie memorizado da bomba, ou '' se ainda nao chegou.
    s = '';
    cache = getappdata(0, 'maePumpSerials');
    if isempty(cache) || ~isstruct(cache)
        return;
    end
    key = matlab.lang.makeValidName(eq);
    if isfield(cache, key)
        s = cache.(key);
    end
end

% ---------------------------------------------------------------------------
% Envio de um frame ja decodificado e validado
% ---------------------------------------------------------------------------

function sendDecodedPayload(parsed)
    if isempty(parsed) || ~isfield(parsed, 'valid') || ~parsed.valid
        return;
    end
    source = sourceFromEq(parsed.eq);
    if isempty(source)
        return;
    end
    payload = payloadFromParsed(parsed);
    if isempty(payload)
        return;
    end
    txt = sprintf('{"source":"%s","payload":%s}', source, payload);
    sendRaw([txt char(10)]);
end

function payload = payloadFromParsed(parsed)
    payload = [];
    reg = mae_registry();
    if parsed.kind == 'D'
        if ~any(strcmp(parsed.eq, {'M', 'V'}))
            return;
        end
        [name, unit, scale] = reg.lookupVariableByAbbr(parsed.eq, parsed.abbr);
        if isempty(name)
            return;
        end
        if parsed.eq == 'M'
            tipo = 'Monitor Measurements';
        else
            tipo = 'Ventilator Measurements';
        end
        vObj = struct('name', name, 'value', formatValue(parsed.valueNum, scale), ...
            'unit', safeUnit(unit));
        payload = sprintf('{"type":"%s","variables":%s,"alarms":[]}', ...
            tipo, jsonArray({vObj}));
    elseif parsed.eq == 'V'
        desc = reg.alarmAbbrToDesc(parsed.abbr);
        if isempty(desc)
            return;
        end
        if parsed.state == '1'
            st = 'ACTIVE';
        else
            st = 'INACTIVE';
        end
        aObj = struct('id', desc, 'state', st, ...
            'priority', priNumToText(str2double(parsed.pri)));
        payload = sprintf('{"type":"Ventilator Alarms","variables":[],"alarms":%s}', ...
            jsonArray({aObj}));
    else
        if parsed.pumpIndex == 0
            cod = -1;
            message = 'NAO HA ALARMES ATIVOS';
        else
            cod = parsed.pumpIndex - 1;
            message = ['ALARME ATIVO: ' reg.pumpDesc(parsed.pumpIndex)];
        end
        % O front-end devolve este serial no comando silenciar/refresh, e o
        % backend monta o frame com ele. Vazio = bomba nao reconhece o pacote.
        serial = pumpSerialFor(parsed.eq);
        if isempty(serial)
            fprintf('mae_frontend: bomba %s ainda sem numero de serie conhecido.\n', parsed.eq);
        end
        payload = sprintf( ...
            '{"pumpSerialNumber":"%s","cod":%d,"state":"ACTIVE","message":"%s","updatedAt":"%s"}', ...
            jsonEsc(serial), cod, jsonEsc(message), datestr(now, 'yyyy-mm-ddTHH:MM:SS'));
    end
end

function str = jsonArray(objs)
    n = numel(objs);
    if n == 0
        str = '[]';
        return;
    end
    parts = cell(1, n);
    for i = 1:n
        parts{i} = jsonencode(objs{i});
    end
    str = ['[' strjoin(parts, ',') ']'];
end

function out = jsonEsc(s)
    out = regexprep(s, '([\\"])', '\\$1');
end

function out = safeUnit(unit)
    out = strrep(unit, char(186), [char(194) char(176)]);
end

function source = sourceFromEq(eq)
    switch eq
        case 'M'
            source = 'monitor_message';
        case 'V'
            source = 'ventilator_message';
        case '1'
            source = 'bomb1_message';
        case '2'
            source = 'bomb2_message';
        case '3'
            source = 'bomb3_message';
        otherwise
            source = '';
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

% ---------------------------------------------------------------------------
% Recepcao de comandos vindos do gateway (Frontend -> MATLAB)
% ---------------------------------------------------------------------------

function setCommandHandler(fh)
%SETCOMMANDHANDLER Registra (ou remove com []) o handler dos comandos do gateway.
    setappdata(0, 'maeFrontendCommandHandler', fh);
    if ~isempty(fh)
        % Garante o socket mesmo antes do primeiro frame de dados subir.
        connectIfNeeded();
    end
end

function commandBytesCallback(src, ~)
%COMMANDBYTESCALLBACK Le os bytes que o gateway escreveu e fatia em linhas NDJSON.
    try
        if src.NumBytesAvailable <= 0
            return;
        end
        data = reshape(char(read(src, src.NumBytesAvailable, 'uint8')), 1, []);
    catch err
        % Conexao quebrada: derruba o cliente para que o proximo uso reconecte.
        fprintf('mae_frontend: falha ao ler comandos do gateway: %s\n', err.message);
        close();
        return;
    end

    pending = getappdata(0, 'maeFrontendRxBuffer');
    if isempty(pending)
        pending = '';
    end
    lines = strsplit([pending data], char(10));
    % strsplit devolve um ultimo elemento sem terminador: vira o resto do buffer.
    setappdata(0, 'maeFrontendRxBuffer', lines{end});
    for i = 1:numel(lines) - 1
        line = strtrim(lines{i});
        if ~isempty(line)
            dispatchCommand(line);
        end
    end
end

function dispatchCommand(line)
    try
        env = jsondecode(line);
    catch
        fprintf('mae_frontend: comando invalido ignorado: %s\n', line);
        return;
    end
    if ~isstruct(env) || ~isfield(env, 'target') || ~isfield(env, 'command')
        return;
    end
    target = char(env.target);
    fh = getappdata(0, 'maeFrontendCommandHandler');
    if isempty(fh)
        fprintf('mae_frontend: comando para "%s" sem handler registrado (ignorado).\n', target);
        return;
    end
    try
        bytes = matlab.net.base64decode(char(env.command));
        fh(target, bytes(:).');
    catch err
        fprintf('mae_frontend: falha ao despachar o comando para "%s": %s\n', target, err.message);
    end
end

% ---------------------------------------------------------------------------
% Conexao TCP com o gateway e envio NDJSON
% ---------------------------------------------------------------------------

function sendRaw(bytes)
    c = connectIfNeeded();
    if isempty(c)
        return;
    end
    try
        write(c, bytes);
    catch err
        fprintf('mae_frontend: falha ao enviar payload: %s\n', err.message);
        close();
    end
end

function c = connectIfNeeded()
    c = getappdata(0, 'maeFrontendClient');
    if ~isempty(c) && isvalid(c)
        return;
    end
    lastFail = getappdata(0, 'maeFrontendLastFail');
    if ~isempty(lastFail) && now - lastFail < 5 / 86400
        c = [];
        return;
    end
    c = [];
    try
        c = tcpclient('localhost', 4455, 'Timeout', 2);
        % Leitura-assincrona dos comandos do gateway na mesma conexao. O
        % protocolo e NDJSON, entao o callback dispara uma vez por linha
        % terminada em LF. ATENCAO: o gatilho "terminator" NAO aceita
        % contagem (apenas "byte" aceita) - passar o terminator aqui como
        % terceiro argumento levanta erro e derruba a conexao.
        configureCallback(c, 'terminator', @commandBytesCallback);
    catch err
        % Fecha o socket recem-criado: se ele vazar, o gateway ve uma conexao
        % que abre e fecha sem nunca enviar nada.
        setappdata(0, 'maeFrontendLastFail', now);
        destroyClient(c);
        fprintf('mae_frontend: falha ao conectar ao gateway TCP 4455: %s\n', err.message);
        c = [];
        return;
    end
    setappdata(0, 'maeFrontendClient', c);
    fprintf('mae_frontend: conectado ao gateway TCP 4455.\n');
end

function destroyClient(c)
    if isempty(c) || ~isvalid(c)
        return;
    end
    try
        configureCallback(c, 'off');
    catch
    end
    try
        delete(c);
    catch
    end
end

function close()
    c = getappdata(0, 'maeFrontendClient');
    % Remove as referencias antes de destruir o socket: se o delete falhar
    % (por exemplo chamado de dentro do proprio callback), o proximo uso
    % reconecta em vez de ficar preso num cliente morto.
    try
        rmappdata(0, 'maeFrontendClient');
    catch
    end
    try
        rmappdata(0, 'maeFrontendRxBuffer');
    catch
    end
    destroyClient(c);
end