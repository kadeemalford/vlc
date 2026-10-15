function [aligned, info] = synchronize_capture_samples(tx, rx, minCorrelation)
%SYNCHRONIZE_CAPTURE_SAMPLES Sincronizacao assistida por TX, sem wrap-around.
% Busca Pearson absoluto apenas em janelas RX que contenham o TX inteiro.
% TX/RX devem estar na mesma taxa; nao utiliza BER para escolher/aceitar janela.
% Retorna aligned=[] e info.accepted=false se nao houver alinhamento aceito.
% minCorrelation=0.5 e exploratorio, NAO um limiar de confianca calibrado.
% A polaridade e estimada pela correlacao; a amplitude RX nao e reescalada.
if nargin < 3, minCorrelation = 0.5; end
validateattributes(minCorrelation, {'numeric'}, ...
    {'real', 'scalar', 'finite', '>', 0, '<=', 1});
assert(isvector(tx) && numel(tx) >= 2 && isreal(tx) && all(isfinite(tx(:))), ...
    'TX deve ser vetor real finito com pelo menos duas amostras.');
assert((isempty(rx) || isvector(rx)) && isreal(rx) && all(isfinite(rx(:))), ...
    'RX deve ser vetor real finito.');
tx = double(tx(:)); rx = double(rx(:));
aligned = [];
info = struct('method', 'valid_window_pearson_v1', 'accepted', false, ...
    'threshold', double(minCorrelation), 'score', NaN, ...
    'start_sample', NaN, 'lag_samples', NaN, 'polarity', NaN, ...
    'candidate_count', max(0, numel(rx)-numel(tx)+1), 'reason', '');
n = numel(tx);
if numel(rx) < n
    info.reason = 'record_shorter_than_frame';
    return;
end
reference = tx - mean(tx);
referenceEnergy = sum(reference.^2);
assert(referenceEnergy > 0, 'TX constante nao permite sincronizacao Pearson.');
% Centralizacao global reduz cancelamento numerico. Energia de cada janela
% desconta tambem sua propria media; o recorte retornado preserva o RX original.
centered = rx - mean(rx);
cs = [0; cumsum(centered)]; cs2 = [0; cumsum(centered.^2)];
sums = cs(n+1:end) - cs(1:end-n);
energy = max(0, cs2(n+1:end) - cs2(1:end-n) - sums.^2/n);
energyFloor = 64*eps(max(1, sum(centered.^2)));
valid = energy > energyFloor;
if ~any(valid)
    info.reason = 'no_nonconstant_window';
    return;
end
numerator = conv(centered, flipud(reference), 'valid');
scores = zeros(size(energy));
scores(valid) = numerator(valid)./sqrt(energy(valid)*referenceEnergy);
scores = max(-1, min(1, scores));
[info.score, start] = max(abs(scores));
info.start_sample = start;
info.lag_samples = start-1;
info.polarity = 1;
if scores(start) < 0, info.polarity = -1; end
if info.score < minCorrelation
    info.reason = 'correlation_below_threshold';
    return;
end
aligned = (rx(start:start+n-1)*info.polarity).';
info.accepted = true;
info.reason = 'accepted';
end
