%function []=a_MAN_EOP_Simulation_V8_Function(LoadFilename,max_loop)
%%%%%%%%%%%%%%%% TX and RX with VLC LOS system analysis %%%%%%%%%%%%%%%%%%%
% Manchester coding
% VLC LOS
% Klaas van der Zwaag, Student of PPGEE
% UFES - LabTel
% Date: 14-03-2020
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%https://sci-hub.tw/10.1002/mop.26621

clc, clear, close all;

%%  Create and Load basefile
[~,Load_Filename2,~]=fileparts(pwd);%Filename to Load

Save_Filename2 = strcat(Load_Filename2, '_EOP_Results', date ,'.mat');        %Filename to Save
load (strcat(Load_Filename2,'.mat'));  
Load_Filename2 = Load_Filename2;%Load the base .Mat-File with all parameters
[~,Load_Filename2,~]=fileparts(pwd);%Filename to Load

%% Options
Eye_TX = 1;                                                                 %Enable calculation TX Eye
Eye_RX = 1;                                                                 %Enable calculation RX Eye
                                                                            %If both are enabled the Eye Opening Penalty is calculated
Eye_TX_plotting = 1;                                                        %Enable plotting TX Eye
Eye_RX_plotting = 1;                                                        %Enable plotting RX Eye
Hist_plotting = 0;

Eye_TX_Fixed_Sample = 1;

%% Parameters
% Archive parameters
Qty_archives = max_loop;%50;                                                          %Quantity of saved experimental archives to load starting with 1

% Sampling and loop parameters
Upsamp_Factor = 50;                                                         %Upsampling factor of the data received from the oscilloscope
Nsamp_DPO = 6.25;                                                           %Given internal upsamling factor of the DPO oscilloscope module
N_samp_p_sim = Nsamp * Nsamp_DPO * Upsamp_Factor;                           %Total samples per symbol after multiplying all upsample factors

% TX B2B Normalization Correction
TX_normalization_window = 10/2;                                             %Window used to cancel the effect of overshoot during normalization of the B2B signal in % of a complete! symbol duration
% RX Normalization Correction
RX_normalization_window = 5/2;                                             %Window used to cancel the effect of overshoot or other effects during normalization of the B2B signal in % of a complete! symbol duration


% Eye parameters
Eye1_mid = 1/4;                                                             %Theoretical mid point of eye1 without deformation
Eye2_mid = 3/4;                                                             %Theoretical mid point of eye2 without deformation
%Eye_window = 10/2;                                                         %Window used to implement a stable Eye Opening measurement in % of symbol duration
Eye1_TX_Fixed_Sample = round(N_samp_p_sim * Eye1_mid);
Eye2_TX_Fixed_Sample = round(N_samp_p_sim * Eye2_mid);

disp(sprintf('Load TX data'));
f = waitbar(0,'Please wait...');
%% TX Eye Diagram
if Eye_TX == 1                                                              %Enter here if this value is 1
    % Create an eye diagram scope object
    T = commscope.eyediagram('SamplingFrequency', Fs_DPO, ...
                             'SamplesPerSymbol', N_samp_p_sim, ...
                             'SymbolsPerTrace', 2, ...
                             'MinimumAmplitude', -1.2, ...
                             'MaximumAmplitude', 1.2, ...
                             'AmplitudeResolution', 0.01, ...
                             'MeasurementDelay', 0, ...
                             'PlotType', '2D Color', ...                    %2D Line 2D Color or 3D Color
                             'PlotTimeOffset', 0, ...
                             'PlotPDFRange', [0 1], ...
                             'ColorScale', 'log', ...                       %log linear
                             'RefreshPlot', 'on');

    %Define the beginning of the symbol with help of the mean of the eye matrix
    Offset = zeros(Qty_archives,1);                                                 %prepare the offset vector 
    Old_vect = (0:length(y_recebido_normalizado2)-1);                               %calculate the old vector size
    New_vect = (0:1/Upsamp_Factor:length(y_recebido_normalizado2)-1/Upsamp_Factor); %calculate the new vector size used for upsampling of the received signal
    
    for l= 1:Qty_archives                                                           %Amount of saved experimental archives have to be loaded
        load (strcat(Load_Filename2,'_',num2str(l),'.mat'));                         %Loading of the archive with experimental data
        TX_resample = interp1(Old_vect,y_recebido_normalizado2,New_vect);           %Upsampling of the received data
        TX_mat = reshape(TX_resample,[N_samp_p_sim,length(TX_resample)/N_samp_p_sim]); %Creation of a matrix with the amount of columns related to the samples per symbol
        TX_mat = TX_mat.';                                                          %Transpose of the matrix
        TX_mat_mean = nanmean(abs(TX_mat));                                         %Vector with absolute mean taken of all columns excluding 'NaN' cells which affect the result
        [y_low,Offset(l)] = min(TX_mat_mean);                                       %Determination of the symbol begin-sample
        
        TX_temp = TX_resample((Offset(l):(10000*Upsamp_Factor)-(N_samp_p_sim-Offset(l)+1))); %Organize the vector and delete unfinished symbols at the end
        % Normalization Correction of the B2B signal affected by overshoot
        TX_mat2 = reshape(TX_temp,[N_samp_p_sim,length(TX_temp)/N_samp_p_sim]);               %Create a temporary matrix for min and max calculation
        TX_mat2 = TX_mat2.';                                                        %Transpose the matrix
        TX_mat_pos = TX_mat2;
        TX_mat_neg = TX_mat2;
        TX_mat_pos(TX_mat2 < 0) = nan;
        TX_mat_neg(TX_mat2 >= 0) = nan;
        TX_mean_pos1 = nanmean(nanmean(TX_mat_pos(:,round(N_samp_p_sim*(Eye1_mid-(TX_normalization_window/100))):round(N_samp_p_sim*(Eye1_mid+(TX_normalization_window/100))))));  %Calculate the maximum value in the given time window
        TX_mean_neg1 = nanmean(nanmean(TX_mat_neg(:,round(N_samp_p_sim*(Eye1_mid-(TX_normalization_window/100))):round(N_samp_p_sim*(Eye1_mid+(TX_normalization_window/100))))));  %Calculate the maximum value in the given time window
        TX_mean_pos2 = nanmean(nanmean(TX_mat_pos(:,round(N_samp_p_sim*(Eye2_mid-(TX_normalization_window/100))):round(N_samp_p_sim*(Eye2_mid+(TX_normalization_window/100))))));  %Calculate the maximum value in the given time window
        TX_mean_neg2 = nanmean(nanmean(TX_mat_neg(:,round(N_samp_p_sim*(Eye2_mid-(TX_normalization_window/100))):round(N_samp_p_sim*(Eye2_mid+(TX_normalization_window/100))))));  %Calculate the maximum value in the given time window

        TX_max = max(TX_mean_pos1,TX_mean_pos2);
        TX_min = min(TX_mean_neg1,TX_mean_neg2);
        if TX_max > -TX_min
            TX_normalized=TX_temp/TX_max;                                                %Normalize the TX vector based on the maximum value
        else
            TX_normalized=TX_temp/-TX_min;                                               %Normalize the TX vector based on the minimum value
        end
        if l == 1
            TX_tot_normalized = TX_normalized;                                      %Start a total vector
        else
            TX_tot_normalized = [TX_tot_normalized TX_normalized];                  %#ok<*AGROW> %Extend the vector with a new string of data and delete unfinished symbols at the end
        end
        waitbar(l/Qty_archives,f,strcat('Please wait, loading TX files...   ',num2str((l/Qty_archives)*100), '%'));
    end

    TX = single(TX_tot_normalized);                                                 %Limit used disk space
    if Eye_TX_plotting == 1
        warning('off','all')
        waitbar(l/Qty_archives,f,strcat('Please wait, plotting TX files...'));
        update(T, TX(1:N_samp_p_sim*50));                                                              %Plot the TX Eye diagram
        set(figure(1),'units','normalized','outerposition',[0 0.5 0.5 0.5])
        warning('on','all')
    end
    delete(f);
end


disp(sprintf('Load RX data'));
f = waitbar(0,'Please wait...');
%% RX Eye Diagram
if Eye_RX == 1
    % Create an eye diagram scope object
    R = commscope.eyediagram('SamplingFrequency', Fs_DPO, ...
                             'SamplesPerSymbol', N_samp_p_sim, ...
                             'SymbolsPerTrace', 2, ...
                             'MinimumAmplitude', -1.2, ...
                             'MaximumAmplitude', 1.2, ...
                             'AmplitudeResolution', 0.005, ...
                             'MeasurementDelay', 0, ...
                             'PlotType', '2D Color', ...                    %2D Line 2D Color or 3D Color
                             'PlotTimeOffset', 0, ...
                             'PlotPDFRange', [0 1], ...
                             'ColorScale', 'log', ...                       %log linear
                             'RefreshPlot', 'on');
                         
    %Define the beginning of the symbol with help of the mean of the eye matrix
    Offset = zeros(Qty_archives,1);
    RX_resample = zeros(Qty_archives,10000*Upsamp_Factor);%prepare the offset vector 
    Old_vect = (0:length(y_recebido_normalizado)-1);                        %calculate the old vector size
    New_vect = (0:1/Upsamp_Factor:length(y_recebido_normalizado)-1/Upsamp_Factor); %calculate the new vector size used for upsampling of the received signal
    
    for l= 1:Qty_archives                                                   %Amount of saved experimental archives have to be loaded
        load (strcat(Load_Filename2,'_',num2str(l),'.mat'))                 %Loading of the archive with experimental data
        RX_resample(l,:) = interp1(Old_vect,y_recebido_normalizado,New_vect);    %Upsampling of the received data
        RX_mat = reshape(RX_resample(l,:),[N_samp_p_sim,length(RX_resample(l,:))/N_samp_p_sim]); %Creation of a matrix with the amount of columns related to the samples per symbol
        RX_mat = RX_mat.';                                                  %Transpose of the matrix
        RX_mat_mean = nanmean(abs(RX_mat));                                 %Vector with absolute mean taken of all columns excluding 'NaN' cells which affect the result
        [y_low,Offset(l)] = min(RX_mat_mean);                               %Determination of the symbol begin-sample
        waitbar(l/Qty_archives,f,strcat('Please wait, loading RX files...   ',num2str((l/Qty_archives)*100), '%'));
    end
    
    [BinQty,BinCenter] = hist(Offset,Upsamp_Factor);                        %Create a histogram to be as sure as possible the eye diagram begins at 0
    [~,BinPos] = max(BinQty);
    Offset1 = round(BinCenter(BinPos));
    if ((Offset1+0.25*N_samp_p_sim) > N_samp_p_sim);
        Offset((Offset > Offset1-(0.25*N_samp_p_sim)) & (Offset <= N_samp_p_sim)) = Offset1;    %overwrite the values with the highest bin sample
        Offset((Offset >= 0) & (Offset < (Offset1+0.25*N_samp_p_sim)-N_samp_p_sim)) = Offset1;
    elseif ((Offset1-0.25*N_samp_p_sim) < 0);
        Offset((Offset >= 0) & (Offset < Offset1+(0.25*N_samp_p_sim))) = Offset1;               %overwrite the values with the highest bin sample
        Offset((Offset <= N_samp_p_sim) & (Offset > N_samp_p_sim+(Offset1-0.25*N_samp_p_sim))) = Offset1;
    else Offset((Offset > (Offset1-0.25*N_samp_p_sim)) & (Offset > (Offset1+0.25*N_samp_p_sim)));
        Offset((Offset > (Offset1-0.25*N_samp_p_sim)) & (Offset < (Offset1+0.25*N_samp_p_sim))) = Offset1; %overwrite the values with the highest bin sample
    end
    if ((Offset1 + N_samp_p_sim/2) <= N_samp_p_sim);            %Place automatically the rest of the offset values to beginning of the next eye
        Offset(Offset ~= Offset1) = Offset1+N_samp_p_sim/2;
    else
        Offset(Offset ~= Offset1) = Offset1-N_samp_p_sim/2;
    end
    
    for l= 1:Qty_archives
        if l == 1
            RX = RX_resample(l,(Offset(l):(10000*Upsamp_Factor)-(N_samp_p_sim-Offset(l)+1))); %Organize the vector and deleting unfinished symbols at the end
        else
            RX = [RX RX_resample(l,(Offset(l):(10000*Upsamp_Factor)-(N_samp_p_sim-Offset(l)+1)))]; %Extend the vector with a new string of data and delete unfinished symbols at the end
        end
    end       
    RX = single(RX);                                                        %Limit used disk space
end

    %Normalize the whole vector
    % Normalization Correction of the RX signal subtracting the mean of
    % the high end low eye levels and take the highest eyemean to normalize the signal
    waitbar(0,f,strcat('Please wait, normalizing the RX data...'));
    Eye_mat_RX = reshape(RX,[N_samp_p_sim,length(RX)/N_samp_p_sim]);        %Transform RX vector to eye matrix
    Eye_mat_RX = Eye_mat_RX.';                                              %Transpose the eye matrix
    Eye_n_symbols = size(Eye_mat_RX,1);                                     %Take number of rows in the matrix
    RX_mat2 = Eye_mat_RX;                                                        %Transpose the matrix
    Eye_mat_RX_pos = RX_mat2;
    Eye_mat_RX_neg = RX_mat2;
    Eye_mat_RX_pos(RX_mat2 < 0) = nan;
    Eye_mat_RX_neg(RX_mat2 >= 0) = nan;
    
    Eye_RX_max_pos = min(Eye_mat_RX_pos);                                   %Take the RX min of max for vector
    Eye_RX_max_neg = max(Eye_mat_RX_neg);                                   %Take the RX max of min for vector
    Eye_RX_max_vect = Eye_RX_max_pos-Eye_RX_max_neg;                        %Take the RX max Eye opening profile
    %Search maximum RX Eye1 and Eye2 Opening
    Eyespace = 5/100;                                                           %Space which can't be used between the eyes to avoid fault results
    [a,Eye1_RX_sample_Column] = max(Eye_RX_max_vect(1:(N_samp_p_sim/2)-round(N_samp_p_sim*Eyespace)));        %Calculate the maximum Eye1 Opening sample
    [a,Eye2_RX_sample_Column] = max(Eye_RX_max_vect(N_samp_p_sim/2+round(N_samp_p_sim*Eyespace):end));    
    Eye2_RX_sample_Column = Eye2_RX_sample_Column+N_samp_p_sim/2+round(N_samp_p_sim*Eyespace);                 %Calculate the maximum Eye2 Opening sample


% %         RX_temp = RX_resample(l,(Offset(l):(10000*Upsamp_Factor)-(N_samp_p_sim-Offset(l)+1)));
% %         RX_mat2 = reshape(RX_temp,[N_samp_p_sim,length(RX_temp)/N_samp_p_sim]);               %Create a temporary matrix for mean normalization correction
        Eye1_RX_mid_perc = Eye1_RX_sample_Column/ N_samp_p_sim;
        Eye2_RX_mid_perc = Eye2_RX_sample_Column/ N_samp_p_sim;
        RX_mat_mean_pos1 = nanmean(nanmean(Eye_mat_RX_pos(:,round(N_samp_p_sim*(Eye1_RX_mid_perc-(RX_normalization_window/100))):round(N_samp_p_sim*(Eye1_RX_mid_perc+(RX_normalization_window/100))))));  %Calculate the maximum value in the given time window
        RX_mat_mean_neg1 = nanmean(nanmean(Eye_mat_RX_neg(:,round(N_samp_p_sim*(Eye1_RX_mid_perc-(RX_normalization_window/100))):round(N_samp_p_sim*(Eye1_RX_mid_perc+(RX_normalization_window/100))))));  %Calculate the maximum value in the given time window
        RX_mat_mean_pos2 = nanmean(nanmean(Eye_mat_RX_pos(:,round(N_samp_p_sim*(Eye2_RX_mid_perc-(RX_normalization_window/100))):round(N_samp_p_sim*(Eye2_RX_mid_perc+(RX_normalization_window/100))))));  %Calculate the maximum value in the given time window
        RX_mat_mean_neg2 = nanmean(nanmean(Eye_mat_RX_neg(:,round(N_samp_p_sim*(Eye2_RX_mid_perc-(RX_normalization_window/100))):round(N_samp_p_sim*(Eye2_RX_mid_perc+(RX_normalization_window/100))))));  %Calculate the maximum value in the given time window

        RX_mat_max = max(RX_mat_mean_pos1,RX_mat_mean_pos2);
        RX_mat_min = min(RX_mat_mean_neg1,RX_mat_mean_neg2);
        if RX_mat_max > -RX_mat_min
            RX = RX/RX_mat_max;                                                %Normalize the RX vector based on the maximum value
        else
            RX = RX/-RX_mat_min;                                               %Normalize the RX vector based on the minimum value
        end
    % plot the RX eye. earlier is not possible because the maximum eye have
    %to be firstly detected.  
    if Eye_RX_plotting == 1
        warning('off','all')
        waitbar(l/Qty_archives,f,strcat('Please wait, plotting RX files...'));
        update(R, RX(1:N_samp_p_sim*1000));                                                          %Plot the RX Eye diagram
        set(figure(2),'units','normalized','outerposition',[0.5 0.5 0.5 0.5])
        warning('on','all')
    end
    delete(f);
    %analyze(h) 

disp(sprintf('TX and RX data treatment'));
f = waitbar(0,'Please wait...');
%% Eye Open Penalty calculation,  Q-fact -OK, SNR -OK, 20% window, save
%% create eye 1 eye 2 -OK, mean b2b patamar -OK, mean eye1 and 2 -OK, Max eye search -OK,
if Eye_TX == 1 && Eye_RX == 1                                               %Enter if both are 1
    %create the total matrix
    waitbar(0,f,strcat('Please wait, creating total Matrixes...'));
    Eye_mat_TX = reshape(TX,[N_samp_p_sim,length(TX)/N_samp_p_sim]);        %Transform TX vector to eye matrix
    Eye_mat_RX = reshape(RX,[N_samp_p_sim,length(RX)/N_samp_p_sim]);        %Transform RX vector to eye matrix
    Eye_mat_TX = Eye_mat_TX.';                                              %Transpose the eye matrix
    Eye_mat_RX = Eye_mat_RX.';                                              %Transpose the eye matrix
    Eye_n_symbols = size(Eye_mat_TX,1);                                     %Take number of rows in the matrix
    
    %Divide the matrix in the positive and negative part
    Eye_mat_TX_pos = zeros(Eye_n_symbols,N_samp_p_sim);                     %Positive TX matrix min of max
    Eye_mat_TX_neg = zeros(Eye_n_symbols,N_samp_p_sim);                     %Negative TX matrix max of min
    Eye_mat_RX_pos = zeros(Eye_n_symbols,N_samp_p_sim);                     %Positive RX matrix min of max
    Eye_mat_RX_neg = zeros(Eye_n_symbols,N_samp_p_sim);                     %Negative RX matrix max of min
    for w = 1:N_samp_p_sim
        Eye_mat_TX_sample = Eye_mat_TX(:,w);                                %Take the TX sample column
        Eye_mat_RX_sample = Eye_mat_RX(:,w);                                %Take the RX sample column
        Eye_mat_TX_pos(:,[w]) = [Eye_mat_TX_sample(Eye_mat_TX_sample >= 0);nan(Eye_n_symbols-size(Eye_mat_TX_sample(Eye_mat_TX_sample >= 0),1),1)];  %Take the TX positive part for matrix
        Eye_mat_TX_neg(:,[w]) = [Eye_mat_TX_sample(Eye_mat_TX_sample < 0);nan(Eye_n_symbols-size(Eye_mat_TX_sample(Eye_mat_TX_sample < 0),1),1)];    %Take the TX negative part for matrix
        Eye_mat_RX_pos(:,[w]) = [Eye_mat_RX_sample(Eye_mat_RX_sample >= 0);nan(Eye_n_symbols-size(Eye_mat_RX_sample(Eye_mat_RX_sample >= 0),1),1)];  %Take the RX positive part for matrix
        Eye_mat_RX_neg(:,[w]) = [Eye_mat_RX_sample(Eye_mat_RX_sample < 0);nan(Eye_n_symbols-size(Eye_mat_RX_sample(Eye_mat_RX_sample < 0),1),1)];    %Take the RX negative part for matrix
    end
    
    %Create max Eye Opening profiles
    waitbar(0.33,f,strcat('Please wait, creating profiles...'));
    Eye_TX_max_pos = min(Eye_mat_TX_pos);                                   %Take the TX min of max for vector
    Eye_TX_max_neg = max(Eye_mat_TX_neg);                                   %Take the TX max of min for vector
    Eye_RX_max_pos = min(Eye_mat_RX_pos);                                   %Take the RX min of max for vector
    Eye_RX_max_neg = max(Eye_mat_RX_neg);                                   %Take the RX max of min for vector
    
    Eye_TX_max_vect = Eye_TX_max_pos-Eye_TX_max_neg;                        %Take the TX max Eye opening profile
    Eye_RX_max_vect = Eye_RX_max_pos-Eye_RX_max_neg;                        %Take the RX max Eye opening profile
    
    %Create mean Eye Opening profiles
    Eye_TX_mean_pos = nanmean(Eye_mat_TX_pos);                              %Take the TX mean of max for vector
    Eye_TX_mean_neg = nanmean(Eye_mat_TX_neg);                              %Take the TX mean of min for vector
    Eye_RX_mean_pos = nanmean(Eye_mat_RX_pos);                              %Take the RX mean of max for vector
    Eye_RX_mean_neg = nanmean(Eye_mat_RX_neg);                              %Take the RX mean of min for vector
    
    Eye_TX_mean_vect = Eye_TX_mean_pos-Eye_TX_mean_neg;                     %Take the TX mean Eye opening profile
    Eye_RX_mean_vect = Eye_RX_mean_pos-Eye_RX_mean_neg;                     %Take the RX mean Eye opening profile
    
    %Create the Standard Deviation profiles
    Std_TX_pos = nanstd(Eye_mat_TX_pos);                                    %Take the TX standard deviation of max for vector
    Std_TX_neg = nanstd(Eye_mat_TX_neg);                                    %Take the TX standard deviation of min for vector
    Std_RX_pos = nanstd(Eye_mat_RX_pos);                                    %Take the RX standard deviation of max for vector
    Std_RX_neg = nanstd(Eye_mat_RX_neg);                                    %Take the RX standard deviation of min for vector
    
    %Create the Variance profiles
    var_TX_pos = nanvar(Eye_mat_TX_pos);                                    %Take the TX variance of max for vector
    var_TX_neg = nanvar(Eye_mat_TX_neg);                                    %Take the TX variance of min for vector
    var_RX_pos = nanvar(Eye_mat_RX_pos);                                    %Take the RX variance of max for vector
    var_RX_neg = nanvar(Eye_mat_RX_neg);                                    %Take the RX variance of min for vector

    %Search maximum RX Eye1 and Eye2 Opening
    Eyespace = 5/100;                                                           %Space which can't be used between the eyes to avoid fault results
    [a,Eye1_RX_sample_Column] = max(Eye_RX_max_vect(1:(N_samp_p_sim/2)-round(N_samp_p_sim*Eyespace)));        %Calculate the maximum Eye1 Opening sample
    [a,Eye2_RX_sample_Column] = max(Eye_RX_max_vect(N_samp_p_sim/2+round(N_samp_p_sim*Eyespace):end));    
    Eye2_RX_sample_Column = Eye2_RX_sample_Column+N_samp_p_sim/2+round(N_samp_p_sim*Eyespace);                 %Calculate the maximum Eye2 Opening sample

    if Eye_TX_Fixed_Sample == 1
       Eye1_TX_sample_Column = Eye1_TX_Fixed_Sample;
       Eye2_TX_sample_Column = Eye2_TX_Fixed_Sample;
    else
       Eye1_TX_sample_Column = Eye1_RX_sample_Column;
       Eye2_TX_sample_Column = Eye2_RX_sample_Column;
    end   
    
       
    %% window measurement y_min = min(min(y_mat2(:,round(n_samp_p_sim*(EYE1_mid-(Eye_TX_normalization_window/100))):round(n_samp_p_sim*(EYE1_mid+(Eye_TX_normalization_window/100))))));
    %TX Eye Opening 
    Eye1_TX_max = Eye_TX_max_vect(Eye1_TX_sample_Column);
    Eye1_TX_mean = Eye_TX_mean_vect(Eye1_TX_sample_Column);
    Eye2_TX_max = Eye_TX_max_vect(Eye2_TX_sample_Column);
    Eye2_TX_mean = Eye_TX_mean_vect(Eye2_TX_sample_Column);
    
    %RX Eye Opening
    Eye1_RX_max = Eye_RX_max_vect(Eye1_RX_sample_Column);
    Eye1_RX_mean = Eye_RX_mean_vect(Eye1_RX_sample_Column);
    Eye2_RX_max = Eye_RX_max_vect(Eye2_RX_sample_Column);
    Eye2_RX_mean = Eye_RX_mean_vect(Eye2_RX_sample_Column);
    
    %Eye Opening Penalty calculation
    Eye1_EOP_max = 10*log10(Eye1_TX_max/Eye1_RX_max);
    Eye2_EOP_max = 10*log10(Eye2_TX_max/Eye2_RX_max);
    Eye1_EOP_mean = 10*log10(Eye1_TX_mean/Eye1_RX_mean);
    Eye2_EOP_mean = 10*log10(Eye2_TX_mean/Eye2_RX_mean);
    
    %SNR Calculation
    Eye1_TX_snr = 20*log10((Eye_TX_max_pos(Eye1_TX_sample_Column)-Eye_TX_max_neg(Eye1_TX_sample_Column)) / (Std_TX_pos(Eye1_TX_sample_Column)+Std_TX_neg(Eye1_TX_sample_Column)));
    Eye2_TX_snr = 20*log10((Eye_TX_max_pos(Eye2_TX_sample_Column)-Eye_TX_max_neg(Eye2_TX_sample_Column)) / (Std_TX_pos(Eye2_TX_sample_Column)+Std_TX_neg(Eye2_TX_sample_Column)));
    Eye1_RX_snr = 20*log10((Eye_RX_max_pos(Eye1_RX_sample_Column)-Eye_RX_max_neg(Eye1_RX_sample_Column)) / (Std_RX_pos(Eye1_RX_sample_Column)+Std_RX_neg(Eye1_RX_sample_Column)));
    Eye2_RX_snr = 20*log10((Eye_RX_max_pos(Eye2_RX_sample_Column)-Eye_RX_max_neg(Eye2_RX_sample_Column)) / (Std_RX_pos(Eye2_RX_sample_Column)+Std_RX_neg(Eye2_RX_sample_Column)));

    %Digital optical communications book
    %BER calculation from PDF function
    Eye1_TX_mean_pos = Eye_TX_mean_pos(Eye1_TX_sample_Column);
    Eye1_TX_mean_neg = Eye_TX_mean_neg(Eye1_TX_sample_Column);
    Eye1_RX_mean_pos = Eye_RX_mean_pos(Eye1_RX_sample_Column);
    Eye1_RX_mean_neg = Eye_RX_mean_neg(Eye1_RX_sample_Column);
    
    Eye2_TX_mean_pos = Eye_TX_mean_pos(Eye2_TX_sample_Column);
    Eye2_TX_mean_neg = Eye_TX_mean_neg(Eye2_TX_sample_Column);
    Eye2_RX_mean_pos = Eye_RX_mean_pos(Eye2_RX_sample_Column);
    Eye2_RX_mean_neg = Eye_RX_mean_neg(Eye2_RX_sample_Column);
    
    %Variance calculation
    Eye1_TX_var_pos = var_TX_pos(Eye1_TX_sample_Column);                       %Take the TX Eye1 variance of max for sample
    Eye1_TX_var_neg = var_TX_neg(Eye1_TX_sample_Column);                       %Take the TX Eye1 variance of min for sample
    Eye1_RX_var_pos = var_RX_pos(Eye1_RX_sample_Column);                       %Take the RX Eye1 variance of max for sample
    Eye1_RX_var_neg = var_RX_neg(Eye1_RX_sample_Column);                       %Take the RX Eye1 variance of min for sample

    Eye2_TX_var_pos = var_TX_pos(Eye2_TX_sample_Column);                       %Take the TX Eye2 variance of max for sample
    Eye2_TX_var_neg = var_TX_neg(Eye2_TX_sample_Column);                       %Take the TX Eye2 variance of min for sample
    Eye2_RX_var_pos = var_RX_pos(Eye2_RX_sample_Column);                       %Take the RX Eye2 variance of max for sample
    Eye2_RX_var_neg = var_RX_neg(Eye2_RX_sample_Column);                       %Take the RX Eye2 variance of min for sample
    
    %BER calculation based on a PDF function of the Eye mean and the eye variances
    Vth = 0;
    Eye1_TX_BER1 = 0.5*(erfc(abs(Eye1_TX_mean_pos-Vth)/sqrt(2*Eye1_TX_var_pos))+erfc(abs(Eye1_TX_mean_neg-Vth)/sqrt(2*Eye1_TX_var_neg)));
    Eye2_TX_BER1 = 0.5*(erfc(abs(Eye2_TX_mean_pos-Vth)/sqrt(2*Eye2_TX_var_pos))+erfc(abs(Eye2_TX_mean_neg-Vth)/sqrt(2*Eye2_TX_var_neg)));
    Eye1_RX_BER1 = 0.5*(erfc(abs(Eye1_RX_mean_pos-Vth)/sqrt(2*Eye1_RX_var_pos))+erfc(abs(Eye1_RX_mean_neg-Vth)/sqrt(2*Eye1_RX_var_neg)));
    Eye2_RX_BER1 = 0.5*(erfc(abs(Eye2_RX_mean_pos-Vth)/sqrt(2*Eye2_RX_var_pos))+erfc(abs(Eye2_RX_mean_neg-Vth)/sqrt(2*Eye2_RX_var_neg)));

    %Q-factor calculation from PDF function
    Eye1_TX_QdB1 = 20*log10(sqrt(2)*erfcinv(2*Eye1_TX_BER1));
    Eye2_TX_QdB1 = 20*log10(sqrt(2)*erfcinv(2*Eye2_TX_BER1));
    Eye1_RX_QdB1 = 20*log10(sqrt(2)*erfcinv(2*Eye1_RX_BER1));
    Eye2_RX_QdB1 = 20*log10(sqrt(2)*erfcinv(2*Eye2_RX_BER1));
    
    %Q-factor calculation from Mean and Standard Deviation
    Eye1_TX_QdB2 = Eye_TX_mean_vect(Eye1_TX_sample_Column) / (Std_TX_pos(Eye1_TX_sample_Column)+abs(Std_TX_neg(Eye1_TX_sample_Column)));
    Eye2_TX_QdB2 = Eye_TX_mean_vect(Eye2_TX_sample_Column) / (Std_TX_pos(Eye2_TX_sample_Column)+abs(Std_TX_neg(Eye2_TX_sample_Column)));
    Eye1_RX_QdB2 = Eye_RX_mean_vect(Eye1_RX_sample_Column) / (Std_RX_pos(Eye1_RX_sample_Column)+abs(Std_RX_neg(Eye1_RX_sample_Column)));
    Eye2_RX_QdB2 = Eye_RX_mean_vect(Eye2_RX_sample_Column) / (Std_RX_pos(Eye2_RX_sample_Column)+abs(Std_RX_neg(Eye2_RX_sample_Column)));
    
    %BER calculation based on the Q-factor 
    Eye1_TX_BER2 = 0.5*(erfc(Eye1_TX_QdB2/sqrt(2)));
    Eye2_TX_BER2 = 0.5*(erfc(Eye2_TX_QdB2/sqrt(2)));
    Eye1_RX_BER2 = 0.5*(erfc(Eye1_RX_QdB2/sqrt(2)));
    Eye2_RX_BER2 = 0.5*(erfc(Eye2_RX_QdB2/sqrt(2)));
    
    %Q-factor calculation from Mean and Standard Deviation in Decibels 
    Eye1_TX_QdB2 = 20*log10(Eye1_TX_QdB2);
    Eye2_TX_QdB2 = 20*log10(Eye2_TX_QdB2);
    Eye1_RX_QdB2 = 20*log10(Eye1_RX_QdB2);
    Eye2_RX_QdB2 = 20*log10(Eye2_RX_QdB2);
    
    %Histogram plotting of Eye1 and Eye2 at maximum Eye opening Amplitude
    %figure()
    set(figure(),'units','normalized','outerposition',[0.5 0 0.5 0.5])
    subplot(2,2,1)
    title('Positive RX-Signal Eye 1')
    hold on
    Eye1_RX_hist_pos = histogram(Eye_mat_RX_pos(:,Eye1_RX_sample_Column),'Normalization','pdf');
    Eye1_RX_hist_bin_pos = min(Eye1_RX_hist_pos.BinEdges):0.001:max(Eye1_RX_hist_pos.BinEdges);
    Eye1_RX_hist_pdf_pos = exp(-(Eye1_RX_hist_bin_pos-Eye_RX_mean_pos(Eye1_RX_sample_Column)).^2./(2*Std_RX_pos(Eye1_RX_sample_Column)^2))./(Std_RX_pos(Eye1_RX_sample_Column)*sqrt(2*pi));
    plot(Eye1_RX_hist_bin_pos,Eye1_RX_hist_pdf_pos);
    camroll(90)

    subplot(2,2,2)
    title('Negative RX-Signal Eye 1')
    hold on
    Eye1_RX_hist_neg = histogram(Eye_mat_RX_neg(:,Eye1_RX_sample_Column),'Normalization','pdf');
    Eye1_RX_hist_bin_neg = min(Eye1_RX_hist_neg.BinEdges):0.001:max(Eye1_RX_hist_neg.BinEdges);
    Eye1_RX_hist_pdf_neg = exp(-(Eye1_RX_hist_bin_neg-Eye_RX_mean_neg(Eye1_RX_sample_Column)).^2./(2*Std_RX_neg(Eye1_RX_sample_Column)^2))./(Std_RX_neg(Eye1_RX_sample_Column)*sqrt(2*pi));
    plot(Eye1_RX_hist_bin_neg,Eye1_RX_hist_pdf_neg);
    camroll(90)

    subplot(2,2,3)
    title('Positive RX-Signal Eye 2')
    hold on
    Eye2_RX_hist_pos = histogram(Eye_mat_RX_pos(:,Eye2_RX_sample_Column),'Normalization','pdf');
    Eye2_RX_hist_bin_pos = min(Eye2_RX_hist_pos.BinEdges):0.001:max(Eye2_RX_hist_pos.BinEdges);
    Eye2_RX_hist_pdf_pos = exp(-(Eye2_RX_hist_bin_pos-Eye_RX_mean_pos(Eye2_RX_sample_Column)).^2./(2*Std_RX_pos(Eye2_RX_sample_Column)^2))./(Std_RX_pos(Eye2_RX_sample_Column)*sqrt(2*pi));
    plot(Eye2_RX_hist_bin_pos,Eye2_RX_hist_pdf_pos);
    camroll(90)

    subplot(2,2,4)
    title('Negative RX-Signal Eye 2')
    hold on
    Eye2_RX_hist_neg = histogram(Eye_mat_RX_neg(:,Eye2_RX_sample_Column),'Normalization','pdf');
    Eye2_RX_hist_bin_neg = min(Eye2_RX_hist_neg.BinEdges):0.001:max(Eye2_RX_hist_neg.BinEdges);
    Eye2_RX_hist_pdf_neg = exp(-(Eye2_RX_hist_bin_neg-Eye_RX_mean_neg(Eye2_RX_sample_Column)).^2./(2*Std_RX_neg(Eye2_RX_sample_Column)^2))./(Std_RX_neg(Eye2_RX_sample_Column)*sqrt(2*pi));
    plot(Eye2_RX_hist_bin_neg,Eye2_RX_hist_pdf_neg);
    camroll(90)

    suptitle('Experimental VLC Signal Results at maximum Eye Opening Amplitude')
    
    %% Save specific Parameters
    disp(sprintf('Saving Parameters'));
    waitbar(0.66,f,strcat('Please wait, Saving Parameters...'));
    save (Save_Filename2,'Qty_archives', 'Eye1_EOP_max', 'Eye1_EOP_mean', 'Eye2_EOP_max', 'Eye2_EOP_mean',...
        'Eye1_RX_BER1', 'Eye1_RX_BER2', 'Eye1_RX_max', 'Eye1_RX_mean', 'Eye1_RX_mean_neg', 'Eye1_RX_mean_pos',...
        'Eye1_RX_QdB1', 'Eye1_RX_QdB2', 'Eye1_RX_snr', 'Eye1_RX_var_neg', 'Eye1_RX_var_pos', 'Eye1_TX_sample_Column','Eye1_RX_sample_Column',...
        'Eye1_TX_BER1', 'Eye1_TX_BER2', 'Eye1_TX_max', 'Eye1_TX_mean', 'Eye1_TX_mean_neg', 'Eye1_TX_mean_pos',...
        'Eye1_TX_QdB1', 'Eye1_TX_QdB2', 'Eye1_TX_snr', 'Eye1_TX_var_neg', 'Eye1_TX_var_pos',...
        'Eye2_RX_BER1', 'Eye2_RX_BER2', 'Eye2_RX_max', 'Eye2_RX_mean', 'Eye2_RX_mean_neg', 'Eye2_RX_mean_pos',...
        'Eye2_RX_QdB1', 'Eye2_RX_QdB2', 'Eye2_RX_snr', 'Eye2_RX_var_neg', 'Eye2_RX_var_pos', 'Eye2_TX_sample_Column','Eye2_RX_sample_Column',...
        'Eye2_TX_BER1', 'Eye2_TX_BER2', 'Eye2_TX_max', 'Eye2_TX_mean', 'Eye2_TX_mean_neg', 'Eye2_TX_mean_pos',...
        'Eye2_TX_QdB1', 'Eye2_TX_QdB2', 'Eye2_TX_snr', 'Eye2_TX_var_neg', 'Eye2_TX_var_pos', 'Eye_n_symbols',...
        'Load_Filename2', 'N_samp_p_sim', 'Nsamp', 'Nsamp_DPO', 'Qty_archives',...
        'Rb', 'RX', 'TX', 'Upsamp_Factor', 'Vth',...
        'Eye1_RX_hist_pos', 'Eye1_RX_hist_bin_neg', 'Eye1_RX_hist_bin_pos', 'Eye1_RX_hist_neg', 'Eye1_RX_hist_pdf_neg', 'Eye1_RX_hist_pdf_pos',...
        'Eye2_RX_hist_pos', 'Eye2_RX_hist_bin_neg', 'Eye2_RX_hist_bin_pos', 'Eye2_RX_hist_neg', 'Eye2_RX_hist_pdf_neg', 'Eye2_RX_hist_pdf_pos'...
        ); %'Eye_window',
    
    disp(sprintf('Parameters Saved'));
    waitbar(1,f,strcat('Ready, Simulation Results will be displayed...'));
    pause(3);
    delete(f);
    clc
    pause(1);
    DisplaySimulationResults;
end
%end