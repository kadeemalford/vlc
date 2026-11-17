classdef NeuralAfgController < handle
    % Command lifecycle only; the runner verifies hardware before construction.
    % The injected writer allows tests without instruments or VISA.
    properties (Access = private)
        writer
        mode
        enabled = false
        closed = false
    end
    methods
        function obj = NeuralAfgController(writer, mode)
            assert(isa(writer, 'function_handle'), 'A command writer is required');
            obj.mode = validatestring(mode, {'continuous', 'per_capture'});
            obj.writer = writer;
        end

        function enable(obj)
            assert(~obj.closed, 'AFG controller is closed');
            if ~obj.enabled
                obj.writer('AFG:OUTPUT:STATE ON');
                obj.enabled = true;
            end
        end

        function afterAcquire(obj)
            if strcmp(obj.mode, 'per_capture')
                obj.writer('AFG:OUTPUT:STATE OFF');
                obj.enabled = false;
            end
        end

        function close(obj)
            if ~obj.closed
                % Always request OFF, even after an unsuccessful enable command.
                obj.writer('AFG:OUTPUT:STATE OFF');
                obj.enabled = false;
                obj.closed = true;
            end
        end
    end
end
