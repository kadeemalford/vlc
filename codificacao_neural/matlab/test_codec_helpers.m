function tests = test_codec_helpers
tests = functiontests(localfunctions);
end

function testExportExactBytesAndRefuseOverwrite(testCase)
folder = tempname;
mkdir(folder);
cleanup = onCleanup(@() rmdir(folder, 's')); %#ok<NASGU>
frame = '!#MDHR0080';
filename = export_compact_frame(frame, folder, 'synthetic_001');
fid = fopen(filename, 'rb');
closer = onCleanup(@() fclose(fid)); %#ok<NASGU>
bytes = fread(fid, Inf, 'uint8=>uint8')';
clear closer
verifyEqual(testCase, bytes, uint8(frame));
verifyError(testCase, @() export_compact_frame(frame, folder, 'synthetic_001'), ...
    'VLC:NeuralCodec:Exists');
end

function testRejectEmptyFrame(testCase)
verifyError(testCase, @() export_compact_frame('', tempdir, 'synthetic'), ...
    'VLC:NeuralCodec:InvalidFrame');
end

function testNoInstrumentAccessWithoutConfirmation(testCase)
verifyError(testCase, @() collect_encoded_packet([], [], '', '', struct(), ''), ...
    'VLC:NeuralCodec:Confirmation');
end
