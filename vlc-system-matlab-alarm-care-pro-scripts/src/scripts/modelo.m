% getting the path of this script and going two folder back (../../)
srcPath = fileparts(fileparts(mfilename('fullpath')));

%add scripts path
addpath(genpath(srcPath));

dataPath = fileparts(fileparts(fileparts(mfilename('fullpath'))));

load(dataPath + "\data\teste_07_07\ibias_100mA\afg_0p5.mat");
load(dataPath + "\data\teste_07_07\ibias_100mA\afg_1.mat");
load(dataPath + "\data\teste_07_07\ibias_100mA\afg_1p5.mat");
load(dataPath + "\data\teste_07_07\ibias_100mA\afg_2.mat");
load(dataPath + "\data\teste_07_07\ibias_100mA\afg_2p5.mat");
load(dataPath + "\data\teste_07_07\ibias_100mA\afg_3.mat");