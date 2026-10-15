function result = match_diagnostic_payload(rx, reference, bits, sps, threshold)
%MATCH_DIAGNOSTIC_PAYLOAD Busca somente copias completas, sem wrap-around.
% Correlacao de Pearson por janela; aceita polaridade invertida.
% Diagnostico exploratorio com TX conhecido, nao sincronizador operacional.
rx = double(rx(:)); reference = double(reference(:)); bits = double(bits(:));
assert(sps >= 2 && mod(sps, 2) == 0 && sps == floor(sps), 'sps invalido');
assert(numel(reference) == numel(bits)*sps, 'Referencia com tamanho invalido');
assert(all(isfinite(rx)) && all(isfinite(reference)), 'Amostras nao finitas');
result = struct('score', NaN, 'start_sample', NaN, 'polarity', NaN, ...
    'ber', NaN, 'n_complete_matches', 0, 'match_starts', [], 'scores', []);
n = numel(reference);
if numel(rx) < n, return; end
reference = reference - mean(reference);
assert(sum(reference.^2) > 0, 'Referencia constante');
% Remover DC global melhora estabilidade numerica; cada janela e centralizada
% novamente no denominador, sem usar informacao do payload para sua media.
rx = rx - mean(rx);
cs = [0; cumsum(rx)]; cs2 = [0; cumsum(rx.^2)];
sums = cs(n+1:end) - cs(1:end-n);
energy = max(0, cs2(n+1:end) - cs2(1:end-n) - sums.^2/n);
denom = sqrt(energy * sum(reference.^2));
scores = zeros(size(energy));
valid = denom > 0;
numerator = conv(rx, flipud(reference), 'valid');
scores(valid) = numerator(valid)./denom(valid);
scores = max(-1, min(1, scores));
[result.score, start] = max(abs(scores));
result.start_sample = start;
result.polarity = 1;
if scores(start) < 0, result.polarity = -1; end
window = rx(start:start+n-1)*result.polarity;
halves = sum(reshape(window, sps/2, []), 1);
pairs = reshape(halves, 2, []);
decoded = (pairs(1,:) > pairs(2,:)).';
result.ber = mean(decoded ~= bits);
result.scores = scores;
% Busca gulosa de correspondencias nao sobrepostas acima do limiar.
remaining = abs(scores);
starts = [];
while true
    [peak, idx] = max(remaining);
    if peak < threshold || peak == 0, break; end
    starts(end+1) = idx; %#ok<AGROW>
    remaining(max(1, idx-n+1):min(numel(remaining), idx+n-1)) = 0;
end
result.match_starts = sort(starts);
result.n_complete_matches = numel(starts);
end
