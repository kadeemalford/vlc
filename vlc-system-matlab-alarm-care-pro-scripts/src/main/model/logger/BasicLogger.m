classdef BasicLogger
    properties(Constant)
        logLevel = [LogLevelEnum.DEBUG, LogLevelEnum.INFO, LogLevelEnum.ELAPSED_TIME];
        %logLevel = [LogLevelEnum.DEBUG, LogLevelEnum.INFO];
    end

    methods(Static)
        function log(level, string)
            if(find(BasicLogger.logLevel == level))
                fprintf("%s: %s\n", level, string);
            end
        end
    end
end