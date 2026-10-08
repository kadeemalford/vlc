classdef QFactor
    properties (Access = private)
        mu1
        mu0
        sigma1
        sigma0
        q
    end

    methods
        % Construtor
        function obj = QFactor(mu1, mu0, sigma1, sigma0, q)
            obj.mu1 = mu1;
            obj.mu0 = mu0;
            obj.sigma1 = sigma1;
            obj.sigma0 = sigma0;
            obj.q = q;
        end

        % Getters
        function val = getMu1(obj)
            val = obj.mu1;
        end

        function val = getMu0(obj)
            val = obj.mu0;
        end

        function val = getSigma1(obj)
            val = obj.sigma1;
        end

        function val = getSigma0(obj)
            val = obj.sigma0;
        end
        
        function val = getQ(obj)
            val = obj.q;
        end

        % Setters
        function obj = setMu1(obj, val)
            obj.mu1 = val;
        end

        function obj = setMu0(obj, val)
            obj.mu0 = val;
        end

        function obj = setSigma1(obj, val)
            obj.sigma1 = val;
        end

        function obj = setSigma0(obj, val)
            obj.sigma0 = val;
        end
    end
end
