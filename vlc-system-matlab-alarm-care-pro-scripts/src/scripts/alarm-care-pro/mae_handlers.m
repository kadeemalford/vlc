function mh = mae_handlers()
%MAE_HANDLERS Parse HL7/binario -> struct (monitor, ventilador, bombas).
%   Porte local do message_handlers.m (vlc-app-matlab), sem dependencias
%   externas ao projeto src. Mantem o mesmo comportamento/registries.
%     mh.handleMonitorData(rawHl7)    -> struct (variaveis)
%     mh.handleVentilatorData(rawHl7) -> struct (variaveis + alarmes)
%     mh.handleBombData(rawBin[,tipo])-> struct (alarme unico)

    mh = struct( ...
        'handleMonitorData', @handleMonitorData, ...
        'handleVentilatorData', @handleVentilatorData, ...
        'handleBombData', @handleBombData);
end

function msg = handleMonitorData(data)
    msg = emptyMessage('Monitor');
    try
        clean = cleanHl7(data);
        [msg.deviceId, msg.timestamp] = headerFields(clean);

        obxChunks = strsplit(clean, 'OBX', 'CollapseDelimiters', false);
        for i = 2:numel(obxChunks)
            vline = regexprep(obxChunks{i}, '[\r\n]+$', '');
            if isempty(vline)
                continue;
            end
            caretParts = strsplit(vline, '^', 'CollapseDelimiters', false);
            if numel(caretParts) < 4
                continue;
            end
            varName = mapMonitorName(caretParts{2});
            pipeParts = strsplit(caretParts{3}, '|', 'CollapseDelimiters', false);
            if numel(pipeParts) < 3
                continue;
            end
            code = codeFromSubId(pipeParts{2});
            if code < 0
                continue;
            end
            if ~isempty(msg.variables) && any([msg.variables.code] == code)
                continue;
            end
            value = pipeParts{3};
            unit = normalizeUnit(caretParts{4});
            if isempty(unit)
                unit = '{unitless}';
            end
            msg.variables(end + 1) = struct( ...
                'name', varName, 'value', value, 'unit', unit, 'scale', 1, 'code', code);
        end
    catch
    end
end

function msg = handleVentilatorData(data)
    msg = emptyMessage('Ventilator');
    try
        clean = cleanHl7(data);
        [msg.deviceId, msg.timestamp] = headerFields(clean);

        obrChunks = strsplit(clean, 'OBR', 'CollapseDelimiters', false);
        for c = 2:numel(obrChunks)
            chunk = obrChunks{c};
            obrType = '';
            firstLine = extractFirstLine(chunk);
            if ~isempty(firstLine)
                cp = strsplit(firstLine, '^', 'CollapseDelimiters', false);
                if numel(cp) >= 2
                    obrType = cp{2};
                end
            end
            isAlarmGroup = strcmp(obrType, 'Ventilator Alarms');

            alarmId = '';
            alarmState = '';
            alarmPriority = '';
            alarmDesc = '';

            obxChunks = strsplit(chunk, 'OBX', 'CollapseDelimiters', false);
            for o = 2:numel(obxChunks)
                oline = regexprep(obxChunks{o}, '[\r\n]+$', '');
                if isempty(oline)
                    continue;
                end
                caretParts = strsplit(oline, '^', 'CollapseDelimiters', false);
                if numel(caretParts) < 3
                    continue;
                end
                varName = caretParts{2};
                pipeParts = strsplit(caretParts{3}, '|', 'CollapseDelimiters', false);
                if numel(pipeParts) < 3
                    continue;
                end
                valueField = pipeParts{3};

                if isAlarmGroup
                    comps = strsplit(valueField, '^', 'CollapseDelimiters', false);
                    if strcmp(varName, 'ALARM ID')
                        alarmId = comps{1};
                        if numel(comps) >= 2
                            alarmDesc = comps{2};
                        end
                    elseif strcmp(varName, 'ALARM STATE')
                        alarmState = alarmComponent(caretParts, comps);
                    elseif strcmp(varName, 'ALARM PRIORITY')
                        alarmPriority = alarmComponent(caretParts, comps);
                    end
                else
                    unit = '';
                    if numel(pipeParts) >= 4
                        unit = normalizeUnit(pipeParts{4});
                    end
                    if isempty(unit)
                        unit = '{unitless}';
                    end
                    codeStr = lastPipeField(caretParts{1});
                    code = str2double(codeStr);
                    if isnan(code)
                        continue;
                    end
                    msg.variables(end + 1) = struct( ...
                        'name', varName, 'value', valueField, 'unit', unit, ...
                        'scale', ventScale(code), 'code', code);
                end
            end

            if isAlarmGroup && ~isempty(alarmId) && ~isempty(alarmState) && ~isempty(alarmPriority)
                idNum = str2double(alarmId);
                if ~isnan(idNum)
                    msg.alarms(end + 1) = struct( ...
                        'id', idNum, 'desc', alarmDesc, ...
                        'state', alarmState, 'priority', alarmPriority);
                end
            end
        end
    catch
    end
end

function msg = handleBombData(data, tipo)
    if nargin < 2
        tipo = 'Bomb1';
    end
    data = double(data(:)).';
    msg = emptyMessage(tipo);
    try
        pumpSerialNumber = char(uint8(data(1:7)));
        tsSec = uint32(0);
        for k = 1:4
            tsSec = tsSec + uint32(data(8 + k)) * uint32(2 ^ (8 * (4 - k)));
        end
        infusionId = data(13) + data(14);
        qtdParams = data(15);

        cod = -1;
        currentByte = 16;
        for i = 1:qtdParams
            if currentByte > numel(data) - 4
                break;
            end
            if data(currentByte) == hex2dec('6f')
                word = uint32(0);
                for k = 1:4
                    word = word + uint32(data(currentByte + k)) * uint32(2 ^ (8 * (k - 1)));
                end
                currentByte = currentByte + 5;
                for b = 0:31
                    wordBit = 8 * (3 - floor(b / 8)) + mod(b, 8);
                    if bitand(bitshift(word, -wordBit), uint32(1)) ~= 0
                        cod = b;
                        break;
                    end
                end
                if cod >= 0
                    break;
                end
            end
        end

        alarms = pumpAlarms();
        if cod >= 0
            desc = alarms{cod + 1};
            message = ['ALARME ATIVO: ' desc];
        else
            desc = '';
            message = 'NAO HA ALARMES ATIVOS';
        end
        msg.deviceId = pumpSerialNumber;
        msg.timestamp = isoEpoch(tsSec);
        msg.alarms(1) = struct('id', cod, 'desc', desc, 'state', 'ACTIVE', ...
            'priority', '', 'message', message);
        msg.infusionId = infusionId;
    catch
    end
end

function msg = emptyMessage(tipo)
    msg = struct('type', tipo, 'deviceId', '', 'timestamp', '', ...
        'variables', struct('name', {}, 'value', {}, 'unit', {}, 'scale', {}, 'code', {}), ...
        'alarms', struct('id', {}, 'desc', {}, 'state', {}, 'priority', {}));
    if strcmp(tipo, 'Bomb1') || strcmp(tipo, 'Bomb2') || strcmp(tipo, 'Bomb3')
        msg.alarms = struct('id', {}, 'desc', {}, 'state', {}, 'priority', {}, 'message', {});
    end
end

function out = cleanHl7(data)
    data = char(data);
    out = regexprep(data, '[\x0B\x1A]', '');
    out = regexprep(out, '\r\n?', char(10));
end

function [deviceId, timestamp] = headerFields(clean)
    deviceId = '';
    timestamp = '';
    lines = strsplit(clean, char(10), 'CollapseDelimiters', false);
    for i = 1:numel(lines)
        line = lines{i};
        if numel(line) >= 3 && strcmp(line(1:3), 'PID')
            f = strsplit(line, '|', 'CollapseDelimiters', false);
            if numel(f) >= 4
                deviceId = f{4};
            end
        elseif numel(line) >= 3 && strcmp(line(1:3), 'MSH')
            f = strsplit(line, '|', 'CollapseDelimiters', false);
            if numel(f) >= 7
                timestamp = isoTs(f{7});
            end
        end
    end
end

function line = extractFirstLine(chunk)
    idx = strfind(chunk, char(10));
    if isempty(idx)
        line = chunk;
    else
        line = chunk(1:idx(1) - 1);
    end
end

function s = lastPipeField(str)
    pp = strsplit(str, '|', 'CollapseDelimiters', false);
    s = pp{end};
end

function code = codeFromSubId(subId)
    parts = strsplit(subId, '.');
    n = min(4, numel(parts));
    code = str2double(strjoin(parts(1:n), ''));
    if isnan(code)
        code = -1;
    end
end

function name = mapMonitorName(name)
    switch name
        case 'MDC_ECG_HEART_RATE', name = 'Ecg Heart Rate';
        case 'MDC_PULS_OXIM_SAT_O2', name = 'Puls Oxim Sat O2';
        case 'MDC_PULS_OXIM_PULS_RATE', name = 'Puls Oxim Puls Rate';
        case 'MDC_TTHOR_RESP_RATE', name = 'Tthor Resp Rate';
        case 'MDC_TEMP', name = 'Temp';
        case 'MDC_PRESS_CUFF_SYS', name = 'Systolic Pressure';
        case 'MDC_PRESS_CUFF_DIA', name = 'Diastolic Pressure';
    end
end

function unit = normalizeUnit(unit)
    switch unit
        case 'MDC_DIM_BEAT_PER_MIN', unit = '1/min';
        case 'MDC_DIM_PERCENT', unit = '%';
        case 'MDC_DIM_RESP_PER_MIN', unit = '1/min';
        case 'MDC_DIM_DEGC', unit = [char(186) 'C'];
        case 'MDC_DIM_MMHG', unit = 'mmHg';
        case '{breath}/min', unit = '1/min';
    end
end

function out = alarmComponent(caretParts, comps)
    if numel(caretParts) >= 4 && ~isempty(caretParts{4})
        out = caretParts{4};
    else
        out = comps{1};
    end
end

function scale = ventScale(code)
    reg = ventilatorCodes();
    for i = 1:size(reg, 1)
        if reg{i, 1} == code
            scale = reg{i, 4};
            return;
        end
    end
    scale = 1;
end

function ts = isoTs(compact)
    ts = '';
    if numel(compact) ~= 14
        return;
    end
    ts = sprintf('%s-%s-%sT%s:%s:%s', compact(1:4), compact(5:6), compact(7:8), ...
        compact(9:10), compact(11:12), compact(13:14));
end

function ts = isoEpoch(sec)
    dt = datetime(double(sec), 'ConvertFrom', 'posixtime', 'TimeZone', 'UTC');
    ts = char(dt, 'yyyy-MM-dd''T''HH:mm:ss');
end

function reg = monitorCodes()
    reg = { ...
        174147842, 'Ecg Heart Rate', '1/min', '1.7.4.147842'; ...
        131150456, 'Puls Oxim Sat O2', '%', '1.3.1.150456'; ...
        131149530, 'Puls Oxim Puls Rate', '1/min', '1.3.1.149530'; ...
        171151578, 'Tthor Resp Rate', '1/min', '1.7.1.151578'; ...
        121150344, 'Temp', [char(186) 'C'], '1.2.1.150344'; ...
        122150344, 'Temp', [char(186) 'C'], '1.2.2.150344'; ...
        119150301, 'Systolic Pressure', 'mmHg', '1.1.9.150301'; ...
        119150302, 'Diastolic Pressure', 'mmHg', '1.1.9.150302'};
end

function reg = ventilatorCodes()
    reg = { ...
        20488, 'Resp Rate', '1/min', 1; ...
        20491, 'O2 Percent', '%', 1; ...
        20490, 'Minute Volume', 'L/min', 100; ...
        20489, 'Tidal Volume', 'mL', 1; ...
        20483, 'PEEP', 'cm[H2O]', 100};
end

function reg = ventilatorAlarms()
    reg = { ...
        37889, 'Maximum Pressure Alarm'; ...
        37896, 'Disconnection Alarm'; ...
        37897, 'Minimum Pressure Alarm'};
end

function dict = pumpAlarms()
    dict = {'Oclusao', 'Vazao Livre', 'Bateria critica', 'Infusao concluida', ...
        'Porta Aberta', 'Erro no mecanismo', 'Ar na linha', 'Frasco Vazio', ...
        'Erro Sens. De Gotas', 'Erro Corta-Fluxo', 'Sistema Reiniciado', ...
        'Oclusao Superior', 'Erro no Acionador PCA', 'Solucao Concluida', ...
        'Undefined', 'Termino da PAUSA', 'Deslocar Equipo', 'Trocar Equipo', ...
        'Desconecte o Paciente', 'Registrar Balanco Hidrico', ...
        'Fim do volume do frasco', 'Remover sens. Gotas', 'Em KTO', ...
        'Alerta Corta-Fluxo', 'Alerta Vol. Max. atingido', 'Modo Transporte', ...
        'Bateria baixa', 'Em Espera', 'Pre-alarme fim de infusao', ...
        'Pre-alarme fim do volume do frasco', 'Em KVO', 'Infusao interrompida'};
end