% getting the path of this script and going two folder back (../../)
srcPath = fileparts(fileparts(fileparts(mfilename('fullpath'))));

%add scripts path
addpath(genpath(srcPath));
            
% Generate a random BPSK signal
data = randi([0 1], 1, 1000) * 2 - 1;
samplesPerSymbol = 10;
upsampled = upsample(data, samplesPerSymbol);
filtSignal = conv(upsampled, ones(1, samplesPerSymbol), 'same');

% Extract eye segments
segments = EyeDiagramUtils.getSegments(filtSignal, samplesPerSymbol, 2); % 2 symbols per segment

% Plot eye diagram
figure;
plot(segments', 'b');
xlabel('Time (samples)');
ylabel('Amplitude');
title('Eye Diagram');