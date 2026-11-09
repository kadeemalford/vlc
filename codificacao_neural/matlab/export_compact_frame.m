function filename = export_compact_frame(frame, outDir, captureId)
% Export ONE de-identified legacy frame before neural coding. No instrument/TCP access.
% Caller must authorize research recording and remove patient identifiers first.
assert(ischar(frame) && isrow(frame) && ~isempty(frame) && all(double(frame) <= 127), ...
    'VLC:NeuralCodec:InvalidFrame', 'Expected a nonempty compact ASCII frame');
assert(~isempty(regexp(captureId, '^[A-Za-z0-9_-]+$', 'once')), ...
    'VLC:NeuralCodec:UnsafeId', 'Unsafe capture ID');
if ~exist(outDir, 'dir'), mkdir(outDir); end
filename = fullfile(outDir, [captureId '.bin']);
assert(~exist(filename, 'file'), 'VLC:NeuralCodec:Exists', 'Refusing to overwrite a source frame');
fid = fopen(filename, 'wb');
assert(fid >= 0, 'VLC:NeuralCodec:OpenFailed', 'Cannot create source frame');
cleanup = onCleanup(@() fclose(fid));
count = fwrite(fid, uint8(frame), 'uint8');
assert(count == numel(frame), 'VLC:NeuralCodec:ShortWrite', 'Incomplete source frame export');
end
