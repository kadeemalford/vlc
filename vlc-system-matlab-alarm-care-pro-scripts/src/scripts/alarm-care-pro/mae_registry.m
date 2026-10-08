function reg = mae_registry()
%MAE_REGISTRY Abreviacoes de variaveis e alarmes para frames VLC de ate 10 chars.
%   reg = mae_registry() retorna struct de funcoes:
%     reg.lookupVariableByCode(eq, code)  -> abbr, name, unit, scale
%     reg.lookupVariableByAbbr(eq, abbr)  -> name, unit, scale
%     reg.alarmAbbrById(id)               -> abbr (ventilador)
%     reg.alarmAbbrToDesc(abbr)           -> descricao (ventilador)
%     reg.pumpDesc(index)                 -> descricao (bomba, 1..32)
%     reg.eqName(eq)                      -> nome do equipamento ('M' -> 'Monitor')

    reg = struct( ...
        'lookupVariableByCode', @lookupVariableByCode, ...
        'lookupVariableByAbbr', @lookupVariableByAbbr, ...
        'alarmAbbrById', @alarmAbbrById, ...
        'alarmAbbrToDesc', @alarmAbbrToDesc, ...
        'pumpDesc', @pumpDesc, ...
        'eqName', @eqName);
end

function [abbr, name, unit, scale] = lookupVariableByCode(eq, code)
    abbr = '';
    name = '';
    unit = '';
    scale = 1;
    if eq == 'M'
        tab = monTab();
    elseif eq == 'V'
        tab = ventTab();
    else
        return;
    end
    for i = 1:size(tab, 1)
        if tab{i, 1} == code
            abbr = tab{i, 2};
            name = tab{i, 3};
            unit = tab{i, 4};
            scale = tab{i, 5};
            return;
        end
    end
end

function [name, unit, scale] = lookupVariableByAbbr(eq, abbr)
    name = '';
    unit = '';
    scale = 1;
    if eq == 'M'
        tab = monTab();
    elseif eq == 'V'
        tab = ventTab();
    else
        return;
    end
    for i = 1:size(tab, 1)
        if strcmp(tab{i, 2}, abbr)
            name = tab{i, 3};
            unit = tab{i, 4};
            scale = tab{i, 5};
            return;
        end
    end
end

function abbr = alarmAbbrById(id)
    tab = ventAlarmTab();
    abbr = '';
    for i = 1:size(tab, 1)
        if tab{i, 1} == id
            abbr = tab{i, 2};
            return;
        end
    end
end

function desc = alarmAbbrToDesc(abbr)
    tab = ventAlarmTab();
    desc = '';
    for i = 1:size(tab, 1)
        if strcmp(tab{i, 2}, abbr)
            desc = tab{i, 3};
            return;
        end
    end
end

function desc = pumpDesc(index)
    dict = pumpTab();
    if index >= 1 && index <= numel(dict)
        desc = dict{index};
    else
        desc = ['Alarme desconhecido ' num2str(index)];
    end
end

function nome = eqName(eq)
    switch eq
        case 'M'
            nome = 'Monitor';
        case 'V'
            nome = 'Ventilador';
        case '1'
            nome = 'Bomba 1';
        case '2'
            nome = 'Bomba 2';
        case '3'
            nome = 'Bomba 3';
        otherwise
            nome = eq;
    end
end

function tab = monTab()
    deg = char(186);
    tab = { ...
        174147842, 'HR', 'Ecg Heart Rate', '1/min', 1; ...
        131150456, 'SP', 'Puls Oxim Sat O2', '%', 1; ...
        131149530, 'PR', 'Puls Oxim Puls Rate', '1/min', 1; ...
        171151578, 'RR', 'Tthor Resp Rate', '1/min', 1; ...
        121150344, 'TP', 'Temp', [deg 'C'], 1; ...
        122150344, 'TP', 'Temp', [deg 'C'], 1; ...
        119150301, 'BS', 'Systolic Pressure', 'mmHg', 1; ...
        119150302, 'BD', 'Diastolic Pressure', 'mmHg', 1};
end

function tab = ventTab()
    tab = { ...
        20488, 'RR', 'Resp Rate', '1/min', 1; ...
        20490, 'MV', 'Minute Volume', 'L/min', 100; ...
        20489, 'TV', 'Tidal Volume', 'mL', 1; ...
        20483, 'PE', 'PEEP', 'cm[H2O]', 100; ...
        20491, 'O2', 'O2 Percent', '%', 1; ...
        20480, 'PK', 'P Peak', 'cm[H2O]', 1; ...
        20481, 'PL', 'P Plateau', 'cm[H2O]', 1; ...
        20482, 'PM', 'P Mean', 'cm[H2O]', 1; ...
        20484, 'PF', 'Peak Flow', 'L/min', 1; ...
        20485, 'TI', 'Ti', 's', 100; ...
        20487, 'TE', 'Te', 's', 100; ...
        20495, 'MM', 'Mandatory Minute Volume', 'L/min', 100; ...
        20498, 'SR', 'Spontaneous Resp Rate', '1/min', 1; ...
        20493, 'TC', 'Expiratory Time Constant', 's', 100; ...
        20492, 'DC', 'Dynamic Compliance', 'mL/cm[H2O]', 1};
end

function tab = ventAlarmTab()
    tab = { ...
        37889, 'MX', 'Maximum Pressure Alarm'; ...
        37896, 'DI', 'Disconnection Alarm'; ...
        37897, 'MN', 'Minimum Pressure Alarm'};
end

function dict = pumpTab()
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