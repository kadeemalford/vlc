classdef NeuralBridgeClient < handle
    % Persistent loopback JSON IPC. Compatible with MATLAB R2021a tcpclient.
    % No pyenv, shell execution, instrument ownership, or medical commands.
    properties (Access = private)
        transport
        token
    end
    methods
        function obj = NeuralBridgeClient(port, token)
            validateattributes(port, {'numeric'}, {'scalar', 'integer', '>=', 1, '<=', 65535});
            assert(~isempty(regexp(token, '^[0-9a-f]{64}$', 'once')), 'Invalid control token');
            obj.token = token;
            obj.transport = tcpclient('127.0.0.1', port, 'Timeout', 15);
            configureTerminator(obj.transport, 'LF');
            hello = obj.call(struct('command', 'hello'));
            assert(strcmp(hello.protocol, 'vlc_neural_ipc_v1'), 'Wrong IPC protocol');
        end

        function initialize(obj, modelHash, outDir, maxAge)
            hello = obj.call(struct('command', 'hello'));
            assert(strcmp(hello.model_sha256, modelHash), 'Frozen model mismatch');
            obj.call(struct('command', 'init', 'model_sha256', modelHash, ...
                'out_dir', outDir, 'max_age_seconds', maxAge));
        end

        function value = info(obj)
            value = obj.call(struct('command', 'hello'));
        end

        function start(obj, host)
            obj.call(struct('command', 'start', 'host', host));
        end

        function value = next_json(obj)
            value = jsonencode(obj.call(struct('command', 'next')));
        end

        function value = receive_json(obj, alignedJson)
            data = obj.call(struct('command', 'receive', ...
                'rx_aligned', jsondecode(alignedJson)));
            value = jsonencode(data);
        end

        function reject(obj)
            obj.call(struct('command', 'reject'));
        end

        function value = stats_json(obj)
            value = jsonencode(obj.call(struct('command', 'stats')));
        end

        function close(obj)
            if ~isempty(obj.transport)
                try
                    obj.call(struct('command', 'close'));
                catch
                    % Dropping control connection also closes the Python bridge.
                end
                obj.transport = [];
            end
        end

        function delete(obj)
            obj.close();
        end
    end
    methods (Access = private)
        function data = call(obj, request)
            assert(~isempty(obj.transport), 'IPC disconnected; restart explicitly');
            request.token = obj.token;
            try
                writeline(obj.transport, jsonencode(request));
                response = jsondecode(char(readline(obj.transport)));
                assert(response.ok, 'Python bridge rejected command; see local server');
                data = response.data;
            catch ME
                % A timed-out response must never be reused for another command.
                obj.transport = [];
                rethrow(ME);
            end
        end
    end
end
