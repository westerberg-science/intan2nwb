%% Header
% Jake Westerberg, PhD (westerberg-science)
% Vanderbilt University
% jakewesterberg@gmail.com
% Code contributions from Patrick Meng (VU)

% Description
% Written as a pipeline for data collected in the Bastos Lab (or similar
% setup using the intan system) to be transformed from raw to the nwb
% format.

% Requirements
% Certain aspects of the data processing require toolboxes found in other
% github repos. Original or forked versions of all required can be found on
% Jake's github page (westerberg-science). Kilosort (2 is used here) is
% required for spike sorting, extended-GLM-for-synapse-detection (a modified
% version found on Jake's github) is required to estimate connectivity
% between units. Also, this of course requires the matnwb toolbox.

% Notes
% 1. This version of the code requires having a google sheet with some
% information pertaining to the recordings.


function intan2nwb(varargin)
%% Defaults
workers                         = 0; % use parallel computing where possible

skip_completed                  = true;
reprocess_bin                   = false;

this_subject                    = []; % used to specify processing for only certain subjects
this_ident                      = []; % used to specify specific session(s) with their ident

params.downsample_fs            = 1000;

params.interpret_events         = true;
params.car_bin                  = false;
params.trigger_PRO              = false; % not useable now.

%% pathing...can change to varargin or change function defaults for own machine
pp = pipelinePaths();

%% in case of missing data...
default_adc_mapping = {'eye_x', 'eye_y', 'eye_pupil'};

%% Varargin
varStrInd = find(cellfun(@ischar,varargin));
for iv = 1:length(varStrInd)
    switch varargin{varStrInd(iv)}
        case {'skip'}
            skip_completed = varargin{varStrInd(iv)+1};
        case {'this_subject'}
            this_subject = varargin{varStrInd(iv)+1};
        case {'this_ident'}
            this_ident = varargin{varStrInd(iv)+1};
        case {'params'}
            params = varargin{varStrInd(iv)+1};
        case {'ID'}
            ID = varargin{varStrInd(iv)+1};
    end
end

%% Use UI if desired
if ~exist('ID', 'var')
    ID = load(uigetfile(pwd, 'SELECT RECORDING ID FILE'));
end

%% Read recording session information
url_name = sprintf('https://docs.google.com/spreadsheets/d/%s/gviz/tq?tqx=out:csv&sheet=%s', ID);
recording_info = webread(url_name);

% Create default processing list
n_idents = length(recording_info.Identifier);
to_proc = 1:n_idents;

% Limit to sessions within subject (if applicable)
if ~isempty(this_subject)
    to_proc = find(strcmp(recording_info.Subject, this_subject));
end

% Limit to a specific session in a specific subject
if ~isempty(this_ident)
    to_proc = nan(1, numel(this_ident));
    for ii = 1 : numel(this_ident)
        to_proc(ii) = find(strcmp(recording_info.Identifier, this_ident{ii}));
    end
end

n_procd = 0;
%% Loop through sessions
for ii = to_proc

    % Find the correct subpath
    in_file_path_1 = findDir(pp.RAW_DATA, datestr(recording_info.Session(ii), 'yymmdd'));
    in_file_path_2 = findDir(pp.RAW_DATA, recording_info.Subject{ii});

    match_dir = ismember(in_file_path_2, in_file_path_1);
    if isempty(match_dir)
        in_file_path_2 = findDir(pp.RAW_DATA, recording_info.Subject_Nickname{ii});
        match_dir = ismember(in_file_path_2, in_file_path_1);
        if isempty(match_dir)
            warning(['COULD NOT FIND DIR FOR ' recording_info.Subject{ii} '-' ...
                datestr(recording_info.Session(ii), 'yymmdd') ' MOVING ON.'])
            continue
        end
    end

    in_file_path_itt = [in_file_path_2{match_dir} filesep];
    clear in_file_path_1 in_file_path_2 match_dir

    % Create file identifier
    file_ident = ['sub-' recording_info.Subject{ii} '_ses-' datestr(recording_info.Session(ii), 'yymmdd')];

    % Skip files already processed if desired
    if exist([pp.NWB_DATA file_ident '.nwb'], 'file') & ...
            skip_completed
        continue;
    end

    % Read settings
    intan_header = readIntanHeader(in_file_path_itt);

    % Determine number of samples in datafiles
    n_samples = length(intan_header.time_stamp);

    % Determine the downsampling
    params.downsample_factor = intan_header.sampling_rate/params.downsample_fs;
    time_stamps_s = intan_header.time_stamp / intan_header.sampling_rate;
    time_stamps_s_ds = downsample(time_stamps_s, params.downsample_factor);
    downsample_size = length(time_stamps_s_ds);

    % Initialize nwb file
    nwb                                 = NwbFile;
    nwb.identifier                      = recording_info.Identifier{ii};
    nwb.session_start_time              = datetime(recording_info.Session(ii));
    nwb.general_experimenter            = recording_info.Investigator{ii};
    nwb.general_institution             = recording_info.Institution{ii};
    nwb.general_lab                     = recording_info.Lab{ii};
    nwb.general_session_id              = recording_info.Identifier{ii};
    nwb.general_experiment_description  = recording_info.Experiment_Description{ii};

    % Determine which probes are present
    probes = strtrim(split(recording_info.Probe_Ident{ii}, ','));

    % Loop through probes to setup nwb tables
    for jj = 1 : recording_info.Probe_Count

        % Initialize probe table
        variables = {'x', 'y', 'z', 'imp', 'location', 'filtering', 'group', 'label'};
        e_table = cell2table(cell(0, length(variables)), 'VariableNames', variables);

        % Determine number of channels that should be present for probe
        n_channels = returnGSNum(recording_info.Probe_Channels, ii, jj);

        % Load the correct channel map file
        load([probes{jj} '.mat'], 'channel_map', 'x', 'y', 'z')

        % Create device
        device = types.core.Device(...
            'description', paren(strtrim(split(recording_info.Probe_Ident{ii}, ',')), jj), ...
            'manufacturer', paren(strtrim(split(recording_info.Probe_Manufacturer{ii}, ',')), jj), ...
            'probe_id', jj-1, ...
            'sampling_rate', intan_header.sampling_rate ...
            );

        % Input device information
        nwb.general_devices.set(['probe' alphabet(jj)], device);

        electrode_group = types.core.ElectrodeGroup( ...
            'has_lfp_data', true, ...
            'lfp_sampling_rate', params.downsample_fs, ...
            'probe_id', jj-1, ...
            'description', ['electrode group for probe' alphabet(jj)], ...
            'location', paren(strtrim(split(recording_info.Area{ii}, ',')), jj), ...
            'device', types.untyped.SoftLink(device) ...
            );

        nwb.general_extracellular_ephys.set(['probe' alphabet(jj)], electrode_group);
        group_object_view = types.untyped.ObjectView(electrode_group);

        % Grab X, Y, Z position
        X = returnGSNum(recording_info.X, ii, jj);
        Y = returnGSNum(recording_info.Y, ii, jj);
        Z = returnGSNum(recording_info.Z, ii, jj);

        temp_imp = NaN; % Can we add in impedance data, day-to-day from intan file?

        temp_loc = paren(strtrim(split(recording_info.Area{ii}, ',')), jj);

        temp_filt = NaN; % Can probably grab this from the settings file eventually.

        for ielec = 1:n_channels
            electrode_label = ['probe' alphabet(jj) '_e' num2str(ielec)];

            temp_X = X + x(ielec);
            temp_Y = Y + y(ielec);
            temp_Z = Z - (max(abs(y)) - y(ielec));

            e_table = [e_table; {temp_X, temp_Y, temp_Z, temp_imp, temp_loc, temp_filt, group_object_view, electrode_label}];
        end

        % Record electrode table
        electrode_table = util.table2nwb(e_table, ['probe' alphabet(jj)]);
        nwb.general_extracellular_ephys_electrodes = electrode_table;

        % Initialize electrode table region
        electrode_table_region = types.hdmf_common.DynamicTableRegion( ...
            'table', types.untyped.ObjectView(electrode_table), ...
            'description', ['probe' alphabet(jj)], ...
            'data', (0:height(e_table)-1)');

        % Initialize DC offset filter
        [DC_offset_bwb, DC_offset_bwa] = butter(1, 0.1/(intan_header.sampling_rate/2), 'high');

        % Initialize filter information
        [muae_bwb, muae_bwa] = butter(2, [500 5000]/(intan_header.sampling_rate/2), 'bandpass');
        [muae_power_bwb, muae_power_bwa] = butter(4, 250/(intan_header.sampling_rate/2), 'low');
        [lfp_bwb, lfp_bwa] = butter(2, [1 250]/(intan_header.sampling_rate/2), 'bandpass');

        % Load the correct channel map file
        load([probes{jj} '.mat'], 'channel_map', 'x', 'y', 'z')

        % Initialize data matrices. Need to fix for multiprobe
        lfp = zeros(n_channels, downsample_size);
        muae = zeros(n_channels, downsample_size);

        % Set computations to CPU, you are limited by RAM/VRAM at this
        % point. might as well use whatever you have more of...
        if workers == 0
            test_fid = fopen(in_file_path_itt + "\amp-" + intan_header.amplifier_channels(1).native_channel_name + ".dat");
            test_size = byteSize(double(fread(test_fid, n_samples, 'int16')) * 0.195);
            %workers = floor((gpuDevice().AvailableMemory) / (6*test_size));
            mem = memory;
            workers = floor((mem.MemAvailableAllArrays) / (6*test_size));
            if workers > feature('numcores')
                workers = feature('numcores');
            elseif workers == 0
                workers = 1;
            end
            fclose(test_fid);
            clear test_size
        end

        pvar_amp_ch = cat(1,{intan_header.amplifier_channels.native_channel_name});
        pvar_ds_factor = params.downsample_factor;

        if ~isempty(gcp('nocreate'))
            delete(gcp);
        end
        pool1 = parpool(workers);
        parfor kk = 1:n_channels
            % Open file and init data
            current_fid             = fopen(in_file_path_itt + "\amp-" + pvar_amp_ch{kk} + ".dat");

            % Setup array on GPU or in mem depending on run parameters
            %current_data            = gpuArray(double(fread(current_fid, n_samples, 'int16')) * 0.195);
            current_data            = double(fread(current_fid, n_samples, 'int16')) * 0.195;

            % Do data type specific filtering
%             muae(kk,:)  = gather(downsample(filtfilt(muae_power_bwb, muae_power_bwa, ...
%                 abs(filtfilt(muae_bwb, muae_bwa, ...
%                 filtfilt(DC_offset_bwb, DC_offset_bwa, ...
%                 current_data)))), pvar_ds_factor));
%             lfp(kk,:)   = gather(downsample(filtfilt(lfp_bwb, lfp_bwa, ...
%                 filtfilt(DC_offset_bwb, DC_offset_bwa, ...
%                 current_data)), pvar_ds_factor));
%             reset(gpuDevice)
            muae(kk,:)  = downsample(filtfilt(muae_power_bwb, muae_power_bwa, ...
                abs(filtfilt(muae_bwb, muae_bwa, ...
                filtfilt(DC_offset_bwb, DC_offset_bwa, ...
                current_data)))), pvar_ds_factor);
            lfp(kk,:)   = downsample(filtfilt(lfp_bwb, lfp_bwa, ...
                filtfilt(DC_offset_bwb, DC_offset_bwa, ...
                current_data)), pvar_ds_factor);
%            reset(gpuDevice)

            % Close file
            fclose(current_fid);
            disp([num2str(kk) '/' num2str(n_channels) ' COMPLETED.'])
        end
        delete(pool1)
        clear pvar_*

        %Rearrange the channels to the order on the probe (starts at 0, +1 so it
        %matches matlab indexing)
        muae = muae(channel_map+1,:);
        lfp = lfp(channel_map+1,:);

        lfp_electrical_series = types.core.ElectricalSeries( ...
            'electrodes', electrode_table_region,...
            'starting_time', 0.0, ... % seconds
            'starting_time_rate', params.downsample_fs, ... % Hz
            'data', lfp, ...
            'data_unit', 'uV', ...
            'filtering', '4th order Butterworth 1-250 Hz (DC offset high-pass 1st order Butterworth 0.1 Hz)', ...
            'timestamps', time_stamps_s_ds);

        lfp_series = types.core.LFP(['probe_' num2str(jj-1) '_lfp_data'], lfp_electrical_series);
        nwb.acquisition.set(['probe_' num2str(jj-1) '_lfp'], lfp_series);
        clear lfp

        muae_electrical_series = types.core.ElectricalSeries( ...
            'electrodes', electrode_table_region,...
            'starting_time', 0.0, ... % seconds
            'starting_time_rate', params.downsample_fs, ... % Hz
            'data', muae, ...
            'data_unit', 'uV', ...
            'filtering', '4th order Butterworth 500-500 Hz, full-wave rectified, then low pass 4th order Butterworth 250 Hz (DC offset high-pass 1st order Butterworth 0.1 Hz)', ...
            'timestamps', time_stamps_s_ds);

        muae_series = types.core.LFP('ElectricalSeries', muae_electrical_series);
        nwb.acquisition.set(['probe_' num2str(jj-1) '_muae'], muae_series);
        clear muae

        reset(gpuDevice)

        if ~exist([pp.BIN_DATA file_ident filesep], 'dir')
            mkdir([pp.BIN_DATA file_ident filesep])
        end
        % Create Spiking bin file
        if ~exist([pp.BIN_DATA file_ident filesep file_ident '_probe-' num2str(jj-1) '.bin'], 'file') | reprocess_bin
            intan2bin(in_file_path_itt, [pp.BIN_DATA file_ident filesep], [file_ident '_probe-' num2str(jj-1) '.bin'], ...
                intan_header, paren(recording_info.Probe_Port{ii}, jj))
        end

        if params.car_bin; applyCAR2Dat([pp.BIN_DATA file_ident filesep file_ident '_probe-' num2str(jj-1) '.bin'], n_channels); end

        %Setup kilosort dirs
        spk_file_path_itt = [pp.SPK_DATA file_ident filesep 'probe-' num2str(jj-1) filesep]; % the raw data binary file is in this folder
        if ~exist(spk_file_path_itt, 'dir')
            mkdir(spk_file_path_itt)
        end

        p_type = paren(strtrim(split(recording_info.Probe_Ident{ii}, ',')), jj);
        ops.chanMap = which([p_type{1}, '_kilosortChanMap.mat']);
        run(which([p_type{1} '_config.m']))

        ops.trange      = [0 Inf]; % time range to sort
        ops.NchanTOT    = n_channels; % total number of channels in your recording

        ops.fig = 0;
        ops.fs = intan_header.sampling_rate;

        if ~exist(pp.SCRATCH, 'dir')
            mkdir(pp.SCRATCH)
        end
        ops.fproc       = fullfile(pp.SCRATCH, 'temp_wh.dat'); % proc file on a fast SSD

        % find the binary file
        if params.car_bin; ops.fbinary = [pp.BIN_DATA file_ident filesep file_ident '_probe-' num2str(jj-1) '_CAR.bin'];
        else; ops.fbinary = [pp.BIN_DATA file_ident filesep file_ident '_probe-' num2str(jj-1) '.bin']; end

        % preprocess data to create temp_wh.dat
        rez = preprocessDataSub(ops);

        % time-reordering as a function of drift
        rez = clusterSingleBatches(rez);

        % saving here is a good idea, because the rest can be resumed after loading rez
        save(fullfile(spk_file_path_itt, 'rez.mat'), 'rez', '-v7.3', '-nocompression');

        % main tracking and template matching algorithm
        rez = learnAndSolve8b(rez);

        % final merges
        rez = find_merges(rez, 1);

        % final splits by SVD
        rez = splitAllClusters(rez, 1);

        % final splits by amplitudes
        rez = splitAllClusters(rez, 0);

        % decide on cutoff
        rez = set_cutoff(rez);

        % write to Phy
        fprintf('Saving results to Phy  \n')
        rezToPhy(rez, spk_file_path_itt);

        % discard features in final rez file (too slow to save)
        rez.cProj = [];
        rez.cProjPC = [];

        % final time sorting of spikes, for apps that use st3 directly
        [~, isort]   = sortrows(rez.st3);
        rez.st3      = rez.st3(isort, :);

        % Ensure all GPU arrays are transferred to CPU side before saving to .mat
        rez_fields = fieldnames(rez);
        for i = 1:numel(rez_fields)
            field_name = rez_fields{i};
            if(isa(rez.(field_name), 'gpuArray'))
                rez.(field_name) = gather(rez.(field_name));
            end
        end

        % save final results as rez2
        fprintf('Saving final results in rez2  \n')
        fname = fullfile(spk_file_path_itt, 'rez2.mat');
        save(fname, 'rez', '-v7.3', '-nocompression');

        reset(gpuDevice)

        % ecephys_spike_sort trigger
        % create json
        json_struct = struct();

        json_struct.directories.kilosort_output_directory = ...
            strrep(spk_file_path_itt, filesep, [filesep filesep]);

        json_struct.waveform_metrics.waveform_metrics_file = ...
            strrep([spk_file_path_itt 'waveform_metrics.csv'], filesep, [filesep filesep]);

        json_struct.ephys_params.sample_rate = intan_header.sampling_rate;
        json_struct.ephys_params.bit_volts = 0.195;
        json_struct.ephys_params.num_channels = n_channels;
        json_struct.ephys_params.reference_channels = []; %n_channels/2;
        json_struct.ephys_params.vertical_site_spacing = mean(diff(z));
        json_struct.ephys_params.ap_band_file = ...
            strrep([pp.BIN_DATA file_ident filesep file_ident '_probe-' num2str(jj-1) '.bin'], filesep, [filesep filesep]);
        json_struct.ephys_params.cluster_group_file_name = 'cluster_group.tsv.v2';
        json_struct.ephys_params.reorder_lfp_channels = true;
        json_struct.ephys_params.lfp_sample_rate = params.downsample_fs;
        json_struct.ephys_params.probe_type = probes{jj};

        json_struct.ks_postprocessing_params.within_unit_overlap_window = 0.000166;
        json_struct.ks_postprocessing_params.between_unit_overlap_window = 0.000166;
        json_struct.ks_postprocessing_params.between_unit_overlap_distance = 5;

        json_struct.mean_waveform_params.mean_waveforms_file = ...
            strrep([spk_file_path_itt 'mean_waveforms.npy'], filesep, [filesep filesep]);
        json_struct.mean_waveform_params.samples_per_spike = 82;
        json_struct.mean_waveform_params.pre_samples = 20;
        json_struct.mean_waveform_params.num_epochs = 1;
        json_struct.mean_waveform_params.spikes_per_epoch = 1000;
        json_struct.mean_waveform_params.spread_threshold = 0.12;
        json_struct.mean_waveform_params.site_range = 16;

        json_struct.noise_waveform_params.classifier_path = ...
            strrep([pp.REPO 'forked_toolboxes\ecephys_spike_sorting\modules\noise_templates\rf_classifier.pkl'], filesep, [filesep filesep]);
        json_struct.noise_waveform_params.multiprocessing_worker_count = 10;

        json_struct.quality_metrics_params.isi_threshold = 0.0015;
        json_struct.quality_metrics_params.min_isi = 0.000166;
        json_struct.quality_metrics_params.num_channels_to_compare = 7;
        json_struct.quality_metrics_params.max_spikes_for_unit = 500;
        json_struct.quality_metrics_params.max_spikes_for_nn = 10000;
        json_struct.quality_metrics_params.n_neighbors = 4;
        json_struct.quality_metrics_params.n_silhouette = 10000;
        json_struct.quality_metrics_params.quality_metrics_output_file = ...
            strrep([spk_file_path_itt 'metrics_test.csv'], filesep, [filesep filesep]);
        json_struct.quality_metrics_params.drift_metrics_interval_s = 51;
        json_struct.quality_metrics_params.drift_metrics_min_spikes_per_interval = 10;
        json_struct.quality_metrics_params.include_pc_metrics = true;

        encodedJSON = jsonencode(json_struct);

        fid = fopen([spk_file_path_itt 'ecephys_spike_sorting_input.json'], 'w');
        fprintf(fid, encodedJSON);
        fclose('all');
        
        clear encodedJSON json_struct

        fid = fopen([spk_file_path_itt 'ecephys_spike_sorting_adapter.bat'], 'w');
        fprintf(fid, '%s\n', '@echo OFF');
        fprintf(fid, '%s\n', ['set CONDAPATH=' pp.CONDA]);
        fprintf(fid, '%s\n', 'set ENVNAME=ecephys');
        fprintf(fid, '%s\n', 'if %ENVNAME%==base (set ENVPATH=%CONDAPATH%) else (set ENVPATH=%CONDAPATH%\envs\%ENVNAME%)');
        fprintf(fid, '%s\n', 'call %CONDAPATH%\Scripts\activate.bat %ENVPATH%');
        fprintf(fid, '%s\n', 'set GIT_PYTHON_REFRESH=quiet');
        fprintf(fid, '%s\n', 'set PYTHONIOENCODING=utf-8');
        fprintf(fid, '%s\n', ['cd ' pp.REPO 'forked_toolboxes\ecephys_spike_sorting']);
        fprintf(fid, '%s\n', ['python -m ecephys_spike_sorting.modules.kilosort_postprocessing --input_json ' ...
            spk_file_path_itt 'ecephys_spike_sorting_input.json --output_json ' spk_file_path_itt 'ecephys_spike_sorting_kspp_output.json']);
        fprintf(fid, '%s\n', ['python -m ecephys_spike_sorting.modules.mean_waveforms --input_json ' ...
            spk_file_path_itt 'ecephys_spike_sorting_input.json --output_json ' spk_file_path_itt 'ecephys_spike_sorting_waveforms_output.json']);
        fprintf(fid, '%s\n', ['python -m ecephys_spike_sorting.modules.noise_templates --input_json ' ...
            spk_file_path_itt 'ecephys_spike_sorting_input.json --output_json ' spk_file_path_itt 'ecephys_spike_sorting_noise_output.json']);
        fprintf(fid, '%s\n', ['python -m ecephys_spike_sorting.modules.quality_metrics --input_json '...
            spk_file_path_itt 'ecephys_spike_sorting_input.json --output_json ' spk_file_path_itt 'ecephys_spike_sorting_quality_output.json']);
        fprintf(fid, '%s\n', 'call conda deactivate');
        fclose('all');

        system([spk_file_path_itt 'ecephys_spike_sorting_adapter.bat']);
        
        unit_idents = unique(rez.st3(:,2))';
        spike_times = cell(1, numel(unit_idents));
        ctr_i=0;
        for kk = unit_idents
            ctr_i = ctr_i + 1;
            spike_times{ctr_i} = (rez.st3(rez.st3(:,2)==kk,1)./intan_header.sampling_rate).';

            % isi measures
            temp_isi = diff(spike_times{ctr_i});
            isi_mean(ctr_i) = mean(temp_isi);
            isi_cv(ctr_i) = std(temp_isi) / isi_mean(ctr_i);
            isi_0 = temp_isi(1:end-1);
            isi_1 = temp_isi(2:end);
            isi_lv(ctr_i) = (3/(numel(temp_isi)-1)) * sum(((isi_0-isi_1)./(isi_0+isi_1)).^2);

            clear isi_0 isi_1 temp_isi
        end
        
        % grab spike times and indices
        [spike_times_vector, spike_times_index] = util.create_indexed_column(spike_times);

        % grab the waveforms
        mean_wave = readNPY([spk_file_path_itt 'mean_waveforms.npy']);
        mean_wave_reshape = [];
        for kk = 1 : numel(unit_idents)
            mean_wave_reshape = [mean_wave_reshape, squeeze(mean_wave(kk,:,:)).'];
        end
        clear mean_wave

        % grab spike templates/amps
        spike_amplitudes = readNPY([spk_file_path_itt 'amplitudes.npy']);
        spike_amplitudes_index = spike_times_index.data(:);

        % grab the metrics
        fid = fopen([spk_file_path_itt 'metrics_test.csv'],'rt');
        C = textscan(fid, '%f %f %f %f %f %f %f %f %f %f %f %f %f %f %s %s %f %f %f %f %f %f %f %f %f %f %f', ...
            'Delimiter', ',', 'HeaderLines', 1, 'EmptyValue', NaN);
        fclose(fid);
        [col_id, cluster_id, firing_rate, presence_ratio, isi_violations, amplitude_cutoff, isolation_distance, l_ratio, ...
            d_prime, nn_hit_rate, nn_miss_rate, silhouette_score, max_drift, cumulative_drift, epoch_name_quality_metrics, ...
            epoch_name_waveform_metrics, peak_channel_id, snr, waveform_duration, waveform_halfwidth, PT_ratio, repolarization_slope, ...
            recovery_slope, amplitude, spread, velocity_above, velocity_below] = deal(C{:}); 
        
        clear C

        % generate other indices
        waveform_mean_index = n_channels:n_channels:n_channels*numel(unit_idents);
        local_index = 0:numel(unit_idents)-1; local_index = local_index';

        % grab noise units
        fid = fopen([spk_file_path_itt 'cluster_group.tsv.v2'],'rt');
        C = textscan(fid, '%f %s', 'Delimiter', ',', 'HeaderLines', 1);
        fclose(fid);
        [quality_cluster_id, quality] = deal(C{:});
        quality = quality(quality_cluster_id == cluster_id);
        clear quality_cluster_id C

        % gen colnames
        colnames = {'snr';'cumulative_drift';'peak_channel_id';'quality';'local_index';'spread';'max_drift';'waveform_duration';'amplitude'; ...
            'amplitude_cutoff';'firing_rate';'nn_hit_rate';'nn_miss_rate';'silhouette_score';'isi_violations';'isolation_distance';'cluster_id'; ...
            'velocity_below';'repolarization_slope';'velocity_above';'l_ratio';'waveform_halfwidth';'presence_ratio';'PT_ratio';'recovery_slope';'d_prime'; ...
            'isi_mean';'isi_cv';'isi_lv';'waveform_mean_index';'spike_amplitudes_index'};

        nwb.units = types.core.Units( ...
            'description', 'kilosorted and AllenSDK ecephys processed units. Spike amplitudes are stored in waveforms field', ...
            'colnames', colnames, ...
            'id', types.hdmf_common.ElementIdentifiers( ...
            'data', int64(0:numel(unit_idents) - 1)), ...
            'spike_times', spike_times_vector, ...
            'spike_times_index', spike_times_index, ...
            'waveforms', types.hdmf_common.VectorData('data', spike_amplitudes, 'description', 'placeholder'), ...
            'waveform_mean', types.hdmf_common.VectorData('data', mean_wave_reshape, 'description', '2D Waveform'), ...
            'waveform_mean_index', types.hdmf_common.VectorData('data', waveform_mean_index, 'description', 'placeholder'), ...
            'PT_ratio', types.hdmf_common.VectorData('data', PT_ratio, 'description', 'placeholder'), ...
            'amplitude', types.hdmf_common.VectorData('data', amplitude, 'description', 'placeholder'), ...
            'amplitude_cutoff', types.hdmf_common.VectorData('data', amplitude_cutoff, 'description', 'placeholder'), ...
            'cluster_id', types.hdmf_common.VectorData('data', cluster_id, 'description', 'placeholder'), ...
            'cumulative_drift', types.hdmf_common.VectorData('data', cumulative_drift, 'description', 'placeholder'), ...
            'd_prime', types.hdmf_common.VectorData('data', d_prime, 'description', 'placeholder'), ...
            'firing_rate', types.hdmf_common.VectorData('data', firing_rate, 'description', 'placeholder'), ...
            'isi_violations', types.hdmf_common.VectorData('data', isi_violations, 'description', 'placeholder'), ...
            'isolation_distance', types.hdmf_common.VectorData('data', isolation_distance, 'description', 'placeholder'), ...
            'l_ratio', types.hdmf_common.VectorData('data', l_ratio, 'description', 'placeholder'), ...
            'local_index', types.hdmf_common.VectorData('data', local_index, 'description', 'placeholder'), ...
            'max_drift', types.hdmf_common.VectorData('data', max_drift, 'description', 'placeholder'), ...
            'nn_hit_rate', types.hdmf_common.VectorData('data', nn_hit_rate, 'description', 'placeholder'), ...
            'nn_miss_rate', types.hdmf_common.VectorData('data', nn_miss_rate, 'description', 'placeholder'), ...
            'peak_channel_id', types.hdmf_common.VectorData('data', peak_channel_id, 'description', 'placeholder'), ...
            'presence_ratio', types.hdmf_common.VectorData('data', presence_ratio, 'description', 'placeholder'), ...
            'quality', types.hdmf_common.VectorData('data', quality, 'description', 'placeholder'), ...
            'recovery_slope', types.hdmf_common.VectorData('data', recovery_slope, 'description', 'placeholder'), ...
            'repolarization_slope', types.hdmf_common.VectorData('data', repolarization_slope, 'description', 'placeholder'), ...
            'silhouette_score', types.hdmf_common.VectorData('data', silhouette_score, 'description', 'placeholder'), ...
            'snr', types.hdmf_common.VectorData('data', snr, 'description', 'placeholder'), ...
            'spike_amplitudes_index', types.hdmf_common.VectorData('data', spike_amplitudes_index, 'description', 'placeholder'), ...
            'spread', types.hdmf_common.VectorData('data', spread, 'description', 'placeholder'), ...
            'velocity_above', types.hdmf_common.VectorData('data', velocity_above, 'description', 'placeholder'), ...
            'velocity_below', types.hdmf_common.VectorData('data', velocity_below, 'description', 'placeholder'), ...
            'waveform_duration', types.hdmf_common.VectorData('data', waveform_duration, 'description', 'placeholder'), ...
            'waveform_halfwidth', types.hdmf_common.VectorData('data', waveform_halfwidth, 'description', 'placeholder'), ...
            'isi_mean', types.hdmf_common.VectorData('data', isi_mean, 'description', 'placeholder'), ...
            'isi_cv', types.hdmf_common.VectorData('data', isi_cv, 'description', 'placeholder'), ...
            'isi_lv', types.hdmf_common.VectorData('data', isi_lv, 'description', 'placeholder') ...
            );

        clear isi_lv isi_cv isi_mean waveform_halfwidth waveform_duration velocity_below velocity_above spread spike_amplitdues_index
        clear snr silhouette_score repolarization_slope recovery_slope quality presence_ratio peak_channel_id nn_miss_rate nn_hit_rate
        clear max_drift local_index l_ratio isolation_distance isi_violations firing_rate d_prime cumulative_drift cluster_id amplitude_cutoff
        clear amplitude PT_ratio waveform_mean_index mean_wave_reshape spike_times spike_times_index col_id epoch_name_quality_metrics
        clear epoch_name_waveform_metrics spike_amplitudes unit_idents

        nwbExport(nwb, [pp.NWB_DATA 'sub-' recording_info.Subject{ii} '_ses-' datestr(recording_info.Session(ii), 'yymmdd') '.nwb']);

        nwb.units.vectordata.set('spike_amplitudes', types.hdmf_common.VectorData('description', 'placeholder', ...
            'data', spike_amplitudes)); 
        clear spike_amplitudes

        nwbExport(nwb, [pp.NWB_DATA 'sub-' recording_info.Subject{ii} '_ses-' datestr(recording_info.Session(ii), 'yymmdd') '.nwb']);

    end

    % Record adc traces
    if strcmp(intan_header.board_adc_channels(1).custom_channel_name, "ANALOG-IN-1")
        adc_map = convertCharsToStrings(default_adc_mapping);
        adc_map = adc_map(1:size(intan_header.board_adc_data,1));
    else
        for jj = 1 : numel(intan_header.board_adc_channels)
            adc_map(jj) = convertCharsToStrings(intan_header.board_adc_channels(jj).custom_channel_name);
        end
    end
 
    for jj = 1 : numel(adc_map)

        temp_dat = [];
        temp_dat(1,:) = downsample(intan_header.board_adc_data(jj, :), params.downsample_factor);

        if strcmp(lower(adc_map(jj)), 'eye_x')

            find_y = find(ismember(lower(adc_map), "eye_y"));
            temp_dat(2,:) = downsample(intan_header.board_adc_data(find_y, :), params.downsample_factor);

            find_p = find(ismember(lower(adc_map), "eye_pupil"));
            temp_pdat(1,:) = downsample(intan_header.board_adc_data(find_p, :), params.downsample_factor);

            eye_position = types.core.SpatialSeries( ...
                'description', 'The position of the eye. Actual sampling rate = 500 Hz (Reported=1kHz)', ...
                'data', temp_dat, ...
                'starting_time_rate', params.downsample_fs, ... % Hz
                'timestamps', time_stamps_s_ds, ...
                'timestamps_unit', 'seconds' ...
                );

            eye_tracking = types.core.EyeTracking();
            eye_tracking.spatialseries.set('eye_tracking', eye_position);

            pupil_diameter = types.core.TimeSeries( ...
                'description', 'Pupil diameter.', ...
                'data', temp_pdat, ...
                'starting_time_rate', params.downsample_fs, ... % Hz
                'data_unit', 'arbitrary units', ...
                'timestamps', time_stamps_s_ds, ...
                'timestamps_unit', 'seconds' ...
                );

            pupil_tracking = types.core.PupilTracking();
            pupil_tracking.timeseries.set('pupil_diameter', pupil_diameter);
            
            nwb.acquisition.set('EyeTracking', eye_tracking);
            nwb.acquisition.set('PupilTracking', pupil_tracking);

            clear temp_* find_*
        end
    end

    % Digital event codes
    digital_data = intan_header.board_dig_in_data(end-7:end,:);
    intan_code_times_unprocessed = find(sum(digital_data) > 0);
    intan_code_times = nan(length(intan_code_times_unprocessed),1);
    intan_code_values = nan(8,length(intan_code_times_unprocessed));

    temp_ctr = 1;
    intan_code_times(temp_ctr) = intan_code_times_unprocessed(temp_ctr);
    intan_code_values(:,temp_ctr) = digital_data(:,intan_code_times(temp_ctr));
    previous_value = intan_code_times(temp_ctr);
    temp_ctr = temp_ctr + 1;
    for jj = 2:length(intan_code_times_unprocessed)
        if(intan_code_times_unprocessed(jj) == previous_value + 1)
            %Do nothing
        else
            intan_code_times(temp_ctr) = intan_code_times_unprocessed(jj);
            intan_code_values(:,temp_ctr) = digital_data(:,intan_code_times(temp_ctr)+1);
            temp_ctr = temp_ctr + 1;
        end
        previous_value = intan_code_times_unprocessed(jj);
    end

    intan_code_times = intan_code_times(1:temp_ctr-1) ./ intan_header.sampling_rate;
    intan_code_values = intan_code_values(:,1:temp_ctr-1);
    intan_code_values = bit2int(flip(intan_code_values),8)';

    % Dientangle event codes...
    if params.interpret_events
        event_data = identEvents(intan_code_values, intan_code_times);
    else
    end

    for jj = 1 : numel(event_data)
        temp_fields = fields(event_data{jj});
        temp_fields = temp_fields(~strcmp(temp_fields, 'task'));

        eval_str = [];
        for kk = 1 : numel(temp_fields)
                eval_str = ...
                    [ eval_str ...
                    ',convertStringsToChars("' ...
                    temp_fields{kk} ...
                    '"), types.hdmf_common.VectorData(convertStringsToChars("data"), event_data{jj}.' ...
                    temp_fields{kk} ', convertStringsToChars("description"), convertStringsToChars("placeholder"))'];
        end
        eval_str = [ 
            'trials=types.core.TimeIntervals(convertStringsToChars("description"), convertStringsToChars("events"), convertStringsToChars("colnames"),temp_fields' ...
            eval_str ');']; ...

        eval(eval_str); clear eval_str
        nwb.intervals.set(event_data{jj}.task, trials); clear trials
    end

    % Save to NWB
    nwbExport(nwb, [pp.NWB_DATA 'sub-' recording_info.Subject{ii} '_ses-' datestr(recording_info.Session(ii), 'yymmdd') '.nwb']);
    disp(['SUCCESSFULLY SAVED: ' pp.NWB_DATA 'sub-' recording_info.Subject{ii} '_ses-' datestr(recording_info.Session(ii), 'yymmdd') '.nwb'])

    % Increment counter
    n_procd = n_procd + 1;

end

disp(['SUCCESSFULLY PROCESSED ' n_procd ' FILES.'])

end