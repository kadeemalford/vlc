classdef ExistingVisaMdo3012Analyzer < Mdo3012Analyzer
    % Borrow an open VISA session without configuring hardware or owning it.
    % Reuse legacy writeSamples; route its writes to the borrowed transport.
    properties (Access = private)
        transport
    end

    methods
        function obj = ExistingVisaMdo3012Analyzer(session)
            obj@Mdo3012Analyzer('borrowed_session', 'NI');
            assert(isa(session, 'visa') && strcmpi(get(session, 'Status'), 'open'), ...
                'VLC:ExistingVisa:NotOpen', 'An already-open legacy VISA object is required');
            obj.transport = session;
        end

        function initiateDefaultConnection(~)
            error('VLC:ExistingVisa:NoInitialization', ...
                'Hardware initialization is disabled for a borrowed session');
        end

        function connect(obj)
            assert(obj.isConnected(), 'VLC:ExistingVisa:NotOpen', ...
                'Open the VISA session explicitly before using this adapter');
        end

        function disconnect(~)
            error('VLC:ExistingVisa:BorrowedSession', ...
                'The caller owns the VISA session; close it explicitly when appropriate');
        end

        function status = isConnected(obj)
            status = strcmpi(get(obj.transport, 'Status'), 'open');
        end

        function write(obj, command)
            fwrite(obj.transport, char(command));
        end

        function response = queryText(obj, command)
            obj.write(command);
            response = fscanf(obj.transport);
        end

        function signal = readSamples(obj, channelNumber)
            % Same signed-byte transfer as the legacy reader, with no timebase fallback.
            validateattributes(channelNumber, {'numeric'}, {'scalar', 'integer', '>=', 1, '<=', 2});
            obj.flush();
            obj.write(sprintf('DATa:SOUrce CH%d', channelNumber));
            obj.write('DATa:ENCdg RIBinary');
            obj.write('DATa:WIDth 1');
            points = str2double(obj.queryText('WFMPre:NR_Pt?'));
            assert(isfinite(points) && points >= 1 && points == fix(points), ...
                'VLC:ExistingVisa:InvalidRecord', 'Invalid record length');
            obj.write('DATa:STARt 1');
            obj.write(sprintf('DATa:STOP %d', points));
            obj.write('CURVe?');
            bytes = obj.readBinBlock();
            assert(numel(bytes) == points, 'VLC:ExistingVisa:RecordMismatch', ...
                'Transferred record length differs from preamble');
            levels = double(typecast(uint8(bytes), 'int8'));
            interval = str2double(obj.queryText('WFMPre:XINcr?'));
            assert(isfinite(interval) && interval > 0, ...
                'VLC:ExistingVisa:InvalidInterval', 'Invalid measured sample interval');
            signal = Signal(levels, (0:numel(levels)-1)*interval, round(1/interval));
        end

        function data = readBinBlock(obj)
            % Skip the terminator left by a previous binary transfer, as in legacy.
            while true
                value = fread(obj.transport, 1, 'uint8');
                assert(~isempty(value), 'VLC:ExistingVisa:MissingHeader', ...
                    'Unexpected end of stream while reading binary header');
                if value == 35, break; end
                assert(value == 10 || value == 13, 'VLC:ExistingVisa:InvalidHeader', ...
                    'Unexpected byte before binary header');
            end
            value = fread(obj.transport, 1, 'uint8');
            assert(~isempty(value) && value >= 49 && value <= 57, ...
                'VLC:ExistingVisa:InvalidHeader', 'Invalid binary length digit count');
            digits = double(value)-48;
            lengthBytes = fread(obj.transport, digits, 'uint8');
            assert(numel(lengthBytes) == digits && all(lengthBytes >= 48 & lengthBytes <= 57), ...
                'VLC:ExistingVisa:InvalidLength', 'Invalid binary length field');
            count = str2double(char(lengthBytes.'));
            assert(isfinite(count) && count >= 1 && count <= 1048576, ...
                'VLC:ExistingVisa:InvalidLength', 'Binary length exceeds adapter limit');
            data = fread(obj.transport, count, 'uint8').';
            assert(numel(data) == count, 'VLC:ExistingVisa:IncompleteBlock', ...
                'Incomplete binary transfer');
        end
    end
end
