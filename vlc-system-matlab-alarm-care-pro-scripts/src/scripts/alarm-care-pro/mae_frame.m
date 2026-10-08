function fr = mae_frame()
%MAE_FRAME Encode/decode de mensagens VLC (formato legado !# <10 chars) com
%   empacotamento multi-mensagem separado por '|'.
%   fr = mae_frame() retorna struct de funcoes:
%     fr.encode(msg)     -> cell de chunks (1 por variavel/alarme) no formato
%                           legado !#EQKIND... (ate 10 chars cada), a partir de
%                           uma struct do message_handlers (monitor/ventilador/bombas)
%     fr.pack(chunks)    -> cell de frames VLC (ate 58 chars) empacotando
%                           varios chunks separados por '|'
%     fr.unpack(frame)   -> cell de chunks legados a partir de um frame
%                           (aceita frame simples ou empacotado)
%     fr.decode(frame)   -> struct com campos valid/err/eq/kind/abbr/data,
%                           valueNum/state/pri/pumpIndex (1 mensagem legada)
%     fr.decodeAll(frame)-> struct array: decode de cada chunk do frame
%
%   Formato legado de 1 mensagem: !#<EQ><KIND><ABBR><DATA>
%     EQ   = M | V | 1 | 2 | 3
%     KIND = D (dado, valor 4 chars) | A (alarme)
%     Dado:   !#MDHR0090   (Monitor, HR = 90)
%     Alarme: !#VAMX11     (Ventilador, Max Pressure, ATIVO, MED)
%             !#1A07       (Bomba 1, alarme indice 07)
%
%   Formato empacotado: chunks legados concatenados com '|'.
%     Ex.: !#MDHR0090|!#VAMX11|!#1A07

    fr = struct('encode', @encode, 'decode', @decode, 'pack', @pack, ...
        'unpack', @unpack, 'decodeAll', @decodeAll);
end

function frames = encode(msg)
    frames = {};
    if isempty(msg) || ~isfield(msg, 'type')
        return;
    end
    eq = eqFromType(msg.type);
    if isempty(eq)
        return;
    end
    reg = mae_registry();

    if isfield(msg, 'variables')
        for k = 1:numel(msg.variables)
            v = msg.variables(k);
            [abbr, ~, ~, scale] = reg.lookupVariableByCode(eq, v.code);
            if isempty(abbr)
                fprintf('mae_frame: variavel sem abrev (eq=%s code=%d) ignorada\n', eq, v.code);
                continue;
            end
            vn = str2double(v.value);
            if isnan(vn)
                continue;
            end
            valTxt = sprintf('%04d', round(vn * scale));
            frame = ['!#' eq 'D' abbr valTxt];
            if numel(frame) > 10
                fprintf('mae_frame: frame excede 10 chars, ignorado: %s\n', frame);
                continue;
            end
            frames{end + 1} = frame;
        end
    end

    if isfield(msg, 'alarms')
        if strcmp(msg.type, 'Ventilator')
            for k = 1:numel(msg.alarms)
                a = msg.alarms(k);
                abbr = reg.alarmAbbrById(a.id);
                if isempty(abbr)
                    abbr = '??';
                end
                if strcmp(a.state, 'ACTIVE')
                    st = '1';
                else
                    st = '0';
                end
                pri = priCodeToNum(a.priority);
                frame = ['!#' eq 'A' abbr st num2str(pri)];
                if numel(frame) > 10
                    continue;
                end
                frames{end + 1} = frame;
            end
        elseif isBombType(msg.type)
            for k = 1:numel(msg.alarms)
                a = msg.alarms(k);
                if a.id < 0
                    idx = 0;
                else
                    idx = a.id + 1;
                end
                frames{end + 1} = ['!#' eq 'A' sprintf('%02d', idx)];
            end
        end
    end
end

function out = decode(frame)
    out = struct('valid', false, 'err', '', 'eq', '', 'kind', '', ...
        'abbr', '', 'data', '', 'valueNum', NaN, 'state', '', 'pri', '', ...
        'pumpIndex', NaN);
    if numel(frame) < 6
        out.err = 'frame curto demais';
        return;
    end
    if ~strcmp(frame(1:2), '!#')
        out.err = 'preambulo ausente';
        return;
    end
    eq = frame(3);
    kind = frame(4);
    if ~any(strcmp(eq, {'M', 'V', '1', '2', '3'}))
        out.err = ['EQ invalido: ' eq];
        return;
    end
    if ~any(strcmp(kind, {'D', 'A'}))
        out.err = ['KIND invalido: ' kind];
        return;
    end
    out.eq = eq;
    out.kind = kind;
    out.abbr = frame(5:6);
    out.data = frame(7:end);

    if kind == 'D'
        if isempty(out.data)
            out.err = 'dado sem valor';
            return;
        end
        out.valueNum = str2double(out.data);
        if isnan(out.valueNum)
            out.err = 'valor nao numerico';
            return;
        end
    elseif kind == 'A'
        if eq == 'V'
            if numel(out.data) < 2
                out.err = 'alarme do ventilador malformado';
                return;
            end
            out.state = out.data(1);
            out.pri = out.data(2);
        else
            out.pumpIndex = str2double(out.abbr);
            if isnan(out.pumpIndex)
                out.err = 'indice de bomba invalido';
                return;
            end
        end
    end
    out.valid = true;
end

function eq = eqFromType(tipo)
    switch tipo
        case 'Monitor'
            eq = 'M';
        case 'Ventilator'
            eq = 'V';
        case 'Bomb1'
            eq = '1';
        case 'Bomb2'
            eq = '2';
        case 'Bomb3'
            eq = '3';
        otherwise
            eq = '';
    end
end

function tf = isBombType(tipo)
    tf = any(strcmp(tipo, {'Bomb1', 'Bomb2', 'Bomb3'}));
end

function n = priCodeToNum(pri)
    switch upper(pri)
        case 'MED'
            n = 1;
        case 'HI'
            n = 2;
        case 'LO'
            n = 3;
        otherwise
            n = 0;
    end
end

function packed = pack(chunks, maxLen)
%PACK Empacota chunks legados em frames VLC de ate maxLen caracteres,
%   separando com '|'. Empacotamento guloso: cabem quantos chunks couberem;
%   os que nao couberem vao para o proximo frame.
    if nargin < 2 || isempty(maxLen) || maxLen < 1
        maxLen = 58;
    end
    packed = cell(1, numel(chunks));
    nPacked = 0;
    cur = '';
    for i = 1:numel(chunks)
        chunk = chunks{i};
        if isempty(chunk)
            continue;
        end
        if isempty(cur)
            candidate = chunk;
        else
            candidate = [cur '|' chunk];
        end
        if numel(candidate) <= maxLen
            cur = candidate;
        else
            if ~isempty(cur)
                nPacked = nPacked + 1;
                packed{nPacked} = cur;
            end
            cur = chunk;
        end
    end
    if ~isempty(cur)
        nPacked = nPacked + 1;
        packed{nPacked} = cur;
    end
    if nPacked > 0
        packed = packed(1:nPacked);
    else
        packed = {};
    end
end

function chunks = unpack(frame)
%UNPACK Divide um frame VLC (simples ou empacotado) na lista de chunks legados.
    if ~ischar(frame) || isempty(frame)
        chunks = {};
        return;
    end
    chunks = strsplit(frame, '|', 'CollapseDelimiters', false);
    chunks = chunks(~cellfun(@isempty, chunks));
end

function out = decodeAll(frame)
%DECODEALL Decodifica cada chunk de um frame; retorna struct array (vazio se
%   nenhum chunk presente). Chunks invalidos entram com valid=false (o chamador
%   decide como tratar).
    chunks = unpack(frame);
    out = struct([]);
    for i = 1:numel(chunks)
        item = decode(chunks{i});
        if isempty(out)
            out = item;
        else
            out(end + 1) = item; %#ok<AGROW>
        end
    end
end