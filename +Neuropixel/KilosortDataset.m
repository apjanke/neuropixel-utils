classdef KilosortDataset < handle
    % wrapper around a Kilosort dataset
    % todo - load cluster ratings from cluster_groups.tsv
    % Note 1: in the context of this file, time refers to samples, 1-indexed
    % Note 2: this file will differ from raw_dataset in nChannelsSorted. Here, nChannelsSorted means the number of channels
    %   in .channel_ids (which will match the other properties)

    properties
        path(1, :) char

        raw_dataset % Neuropixel.ImecDataset instance
        
        channelMap % Neuropixel.ChannelMap
        
        fsAP % sampling rate pass thru to raw_dataset or specified during construction
        
        apGain 
        apScaleToUv % multiply raw samples by this to get uV
        
        meta % ap metadata loaded
        
        concatenationInfo
        
        isLoaded logical = false;
    end
    
    % Computed properties
    properties(Hidden)
        metrics
    end

    properties(Dependent)
        pathLeaf
        hasRawDataset
        nChannelsSorted
        nSpikes
        nClusters
        nTemplates
        nTemplateRank
        nPCFeatures
        nFeaturesPerChannel
        nTemplateTimepoints
        templateTimeRelative
        
        nBatches
        nInvalidSpikes
    end
    
    properties(SetAccess=protected)
        syncBitNames(:, 1) string
    end

    properties % Primary data properties
        % dat_path - location of raw data file as specified in params.py
        dat_path(1, :) char

        % n_channels_dat - total number of rows in the data file (not just those that have your neural data on them. This is for loading the file)
        n_channels_dat(1, 1) uint64

        % dtype - data type to read, e.g. 'int16'
        dtype(1, :) char

        % offset - number of bytes at the beginning of the file to skip
        offset uint64

        % sample_rate - in Hz
        sample_rate double

        % hp_filtered - True/False, whether the data have already been filtered
        hp_filtered(1,1) logical

        % amplitudes.npy - [nSpikes, ] double vector with the amplitude scaling factor that was applied to the template when extracting that spike
        amplitudes(:,1) double;

        % channel_map.npy - [nChannelsSorted, ] uint32 vector with the channel map, i.e. which row of the data file to look in for the channel in question
        channel_ids(:, 1) uint32

        % channel_positions.npy - [nChannelsSorted, 2] double matrix with each row giving the x and y coordinates of that channel. Together with the channel map, this determines how waveforms will be plotted in WaveformView (see below).
        channel_positions(:, 2) double

        % pc_features.npy - [nSpikes, nFeaturesPerChannel, nPCFeatures] single matrix giving the PC values for each spike.
        % The channels that those features came from are specified in pc_features_ind.npy. E.g. the value at pc_features[123, 1, 5]
        % is the projection of the 123rd spike onto the 1st PC on the channel given by pc_feature_ind[5].
        pc_features(:, :, :) single

        % pc_feature_ind.npy - [nTemplates, nPCFeatures] uint32 matrix specifying which channels contribute to each entry in dim 3 of the pc_features matrix
        % e.g. if pc_feature(iT
        pc_feature_ind(:, :) uint32

        % similar_templates.npy - [nTemplates, nTemplates] single matrix giving the similarity score (larger is more similar) between each pair of templates
        similar_templates(:, :) single

        % spike_templates.npy - [nSpikes, ] uint32 vector specifying the identity of the template that was used to extract each spike
        spike_templates(:, 1) uint32

        % spike_times.npy - [nSpikes, ] uint64 vector giving the spike time of each spike in samples. To convert to seconds, divide by sample_rate from params.py.
        spike_times(:, 1) uint64

        % template_features.npy - [nSpikes, nTemplateRank] single matrix giving the magnitude of the projection of each spike onto nTemplateRank other features.
        % Which other features is specified in template_feature_ind.npy
        template_features(:, :) single

        % template_feature_ind.npy - [nTemplates, nTemplateRank] uint32 matrix specifying which templateFeatures are included in the template_features matrix.
        template_feature_ind(:, :) uint32
        
        template_sample_offset (1,1) uint64 % scalar value indicating what index into templates (time dim 2) the spike time occurs at

        % templates.npy - [nTemplates, nTemplateTimepoints, nTemplateChannels] single matrix giving the template shapes on the channels given in templates_ind.npy
        templates(:, :, :) single

        % templates_ind.npy - [nTemplates, nTempChannels] double matrix specifying the channels on which each template is defined.
        % In the case of Kilosort templates_ind is just the integers from 0 to nChannelsSorted-1, since templates are defined on all channels.
        templates_ind(:, :) double

        % whitening_mat.npy - [nChannelsSorted, nChannelsSorted] double whitening matrix applied to the data during automatic spike sorting
        whitening_mat(:, :) double

        % whitening_mat_inv.npy - [nChannelsSorted, nChannelsSorted] double, the inverse of the whitening matrix.
        whitening_mat_inv(:, :) double

        % spike_clusters.npy - [nSpikes, ] uint32 vector giving the cluster identity of each spike. This file is optional and
        % if not provided will be automatically created the first time you run the template gui, taking the same values as
        % spike_templates.npy until you do any merging or splitting.
        spike_clusters(:, 1) uint32

        % cluster_groups - "cluster group" of each cluster as set in Phy, defaulting to cluster_ks_label (noise, mua, good, unsorted)
        cluster_groups(:, 1) categorical
        
        % unique clusters in spike_clusters [nClusters]
        cluster_ids (:, 1) uint32
    end
    
    properties % Secondary data, loaded from rez.mat for Kilosort2 only
        ops struct % options used by Kilosort
        
        kilosort_version (1, :) uint32 % scalar or vector (leading digit is 1 or 2 for Kilosort1 or Kilosort2)
        
        % low-rank decomposition of templates into spatial and temporal components
        W (:, :, :) double % [nTemplateTimepoints, nTemplates, nTemplateRank] - temporal decomposition of templates
        
        U (:, :, :) double % [nChannelsSorted, nTemplates, nTemplateRank] - spatial decomposition of templates

        % batch information used in drift correction
        batch_starts (:, 1) uint64 % [nBatches] timesteps where each batch begins (unsorted)
        
        batchwise_cc (:, :) single % (rez.ccb) [nBatches, nBatches] batch-wise cross-correlation in original data ordering
        
        batch_sort_order (:, 1) uint32 % (rez.iorig) [nBatches] sorted batch indices used in KS2
        
        % batchwise template data
        W_batch (:, :, :, :) single % [nTemplateTimepoints, nTemplates, nTemplateRank, nBatches] - full spatial templates by batch
        
        % per-template svd of W_batch U*S --> W_batch_a, V --> W_batch_b
        W_batch_US (:, :, :, :) single % [nTemplateTimepoints, nTemplateRank, nTemplatePCs, nTemplates] - reshaped from rez.W_a
        W_batch_V (:, :, :) single % [nBatches, nTemplatePCs, nTemplates] % rez.W_b
        
        U_batch (:, :, :, :) single  % [nChannelsSorted, nTemplates, nTemplateRank, nBatches] - full temporal templates
        
        % per-template svd of U_batch U*S --> U_batch_a, V --> U_batch_b
        U_batch_US (:, :, :, :) single % [nChannelsSorted, nTemplateRank, nTemplatePCs, nTemplates]
        U_batch_V (:, :, :) single % [nBatches, nTemplatePCs, nTemplates]
        
        % good vs. mua label as assigned by Kilosort2 in cluster_KSLabel.tsv (good, mua)
        cluster_ks_label(:, 1) categorical % [nClusters]
        
        cluster_est_contam_rate (:, 1) double % [nClusters]
        
        % optional split and merge meta information (only on djoshea branch of Kilosort2)
        cluster_merge_count (:, 1) uint32        
        cluster_split_src (:, 1) uint32
        cluster_split_dst (:, 1) uint32
        cluster_split_auc (:, 1) double
        cluster_split_candidate (:, 1) logical
        cluster_orig_template (:, 1) uint32

        % [nSpikesInvalid, ] uint64 vector giving the spike time of each spike in samples. To convert to seconds, divide by sample_rate from params.py.
        invalid_spike_times(:, 1) uint64
        
        % [nSpikesInvalid, ] uint32 vector specifying the identity of the template that was used to extract each spike
        invalid_spike_templates(:, 1) uint32
        invalid_spike_clusters(:, 1) uint32
    end
    
    properties(Dependent)
        clusters_good
        clusters_mua
        clusters_noise
        clusters_unsorted
    end

    methods % Dependent properties
        function leaf = get.pathLeaf(ds)
            [~, leaf] = fileparts(ds.path);
        end
        
        function tf = get.hasRawDataset(ds)
            tf = ~isempty(ds.raw_dataset);
        end
        
        function n = get.nSpikes(ds)
            if isempty(ds.spike_times)
                n = NaN;
            else
                n = size(ds.spike_times, 1);
            end
        end
        
        function n = get.nInvalidSpikes(ds)
            if isempty(ds.invalid_spike_times)
                n = NaN;
            else
                n = size(ds.invalid_spike_times, 1);
            end
        end

        function n = get.nClusters(ds)
            if isempty(ds.cluster_ids)
                n = NaN;
            else
                n = numel(ds.cluster_ids);
            end
        end

        function n = get.nTemplates(ds)
            if isempty(ds.pc_feature_ind)
                n = NaN;
            else
                n = size(ds.pc_feature_ind, 1);
            end
        end
        
        function n = get.nTemplateRank(ds)
            if isempty(ds.template_features)
                n = NaN;
            else
                n = size(ds.template_features, 2);
            end
        end

        function n = get.nPCFeatures(ds)
            if isempty(ds.pc_features)
                n = NaN;
            else
                n = size(ds.pc_features, 3);
            end
        end

        function n = get.nFeaturesPerChannel(ds)
            if isempty(ds.pc_features)
                n = NaN;
            else
                n = size(ds.pc_features, 2);
            end
        end
        
        function n = get.nTemplateTimepoints(ds)
            if isempty(ds.templates)
                n = NaN;
            else
                n = size(ds.templates, 2);
            end
        end
        
        function tvec = get.templateTimeRelative(ds)
            T = int64(ds.nTemplateTimepoints);
            off = int64(ds.template_sample_offset);
            start = -off + int64(1);
            stop = start + T - int64(1);
            tvec = (start:stop)';
        end
        
        function n = get.nChannelsSorted(ds)
            if isempty(ds.channel_ids)
                n = NaN;
            else
                n = numel(ds.channel_ids);
            end
        end
        
        function map = get.channelMap(ds)
            if ~isempty(ds.raw_dataset) && ~isempty(ds.raw_dataset.channelMap)
                % pass thru to raw dataset
                map = ds.raw_dataset.channelMap;
            else
                map = ds.channelMap;
            end
        end
        
        function nBatches = get.nBatches(ds)
            nBatches = numel(ds.batch_starts);
        end
        
        function fsAP = get.fsAP(ds)
            if isempty(ds.fsAP)
                if isempty(ds.raw_dataset)
                    fsAP = NaN;
                else
                    fsAP = ds.raw_dataset.fsAP;
                end
            else
                fsAP = ds.fsAP;
            end
        end
        
        function apGain = get.apGain(ds)
            if isempty(ds.apGain)
                if isempty(ds.raw_dataset)
                    apGain = NaN;
                else
                    apGain = ds.raw_dataset.apGain;
                end
            else
                apGain = ds.apGain;
            end
        end
        
        function apScaleToUv = get.apScaleToUv(ds)
            if isempty(ds.apScaleToUv)
                if isempty(ds.raw_dataset)
                    apScaleToUv = NaN;
                else
                    apScaleToUv = ds.raw_dataset.apScaleToUv;
                end
            else
                apScaleToUv = ds.apScaleToUv;k
            end
        end
        
        function syncBitNames = get.syncBitNames(ds)
            if isempty(ds.raw_dataset)
                if isempty(ds.syncBitNames)
                    syncBitNames = strings(16, 1);
                else
                    syncBitNames = string(ds.syncBitNames);
                end
            else
                syncBitNames = string(ds.raw_dataset.syncBitNames);
            end
        end
        
        function c = get.clusters_good(ds)
            c = ds.cluster_ids(ds.cluster_groups == "good");
        end
        
        function c = get.clusters_mua(ds)
            c = ds.cluster_ids(ds.cluster_groups == "mua");
        end
        
        function c = get.clusters_noise(ds)
            c = ds.cluster_ids(ds.cluster_groups == "noise");
        end
        
        function c = get.clusters_unsorted(ds)
            c = ds.cluster_ids(ds.cluster_groups == "unsorted");
        end
    end
   
    methods
        function ds = KilosortDataset(path, varargin)
            if nargin == 0
                return;
            end
            
            p = inputParser();
            p.addParameter('channelMap', [], @(x) true);
            p.addParameter('imecDataset', [], @(x) true);
            p.addParameter('fsAP', [], @(x) isempty(x) || isscalar(x));
            p.addParameter('apScaleToUv', [], @(x) isempty(x) || isscalar(x));
            p.parse(varargin{:});
            
            if isa(path, 'Neuropixel.ImecDataset')
                ds.raw_dataset = path;
                path = ds.raw_dataset.pathRoot;
            end
            
            assert(exist(path, 'dir') == 7, 'Path %s not found', path);
            ds.path = path;
            
            if isempty(ds.raw_dataset)
                if isa(p.Results.imecDataset, 'Neuropixel.ImecDataset')
                    ds.raw_dataset = p.Results.imecDataset;
                elseif ischar(p.Results.imecDataset) || isempty(p.Results.imecDataset)
                    raw_path = p.Results.imecDataset;
                    if isempty(raw_path), raw_path = path; end
                    if Neuropixel.ImecDataset.folderContainsDataset(raw_path)
                        ds.raw_dataset = Neuropixel.ImecDataset(raw_path, 'channelMap', p.Results.channelMap);
                    end
                end
            end
            
            if isempty(ds.raw_dataset)
                warning('No ImecDataset found in Kilosort path, specify imecDataset parameter directly');
            end
           
            % these will pass thru to raw_dataset if provided
            ds.fsAP = p.Results.fsAP;
            ds.apScaleToUv = p.Results.apScaleToUv;
            
            % manually specify some additional props
            channelMap = p.Results.channelMap;
            if isempty(channelMap)
                if ~isempty(ds.raw_dataset)
                    channelMap = ds.raw_dataset.channelMap;
                end
                if isempty(channelMap)
                    channelMap = Neuropixel.Utils.getDefaultChannelMapFile(true);
                end
            end

            if ischar(channelMap)
                channelMap = Neuropixel.ChannelMap(channelMap);
            end
            ds.channelMap = channelMap;
            
            if ~isempty(ds.raw_dataset)
                ds.meta = ds.raw_dataset.readAPMeta();
                ds.concatenationInfo = ds.raw_dataset.concatenationInfoAP;
            end
        end
        
        function s = computeBasicStats(ds, varargin)
            % a way of computing basic statistics without fully loading
            % from disk. see printBasicStats
            
            p = inputParser();
            p.addParameter('frThresholdHz', 3, @isscalar);
            p.parse(varargin{:});

            % can work without loading raw data, much faster
            if ds.isLoaded
                s.spike_clusters = ds.spike_clusters; %#ok<*PROP>
                s.cluster_ids = ds.cluster_ids; 
                s.offset = ds.offset;
                s.sample_rate = ds.sample_rate;
                s.spike_times = ds.spike_times;
            else
                % partial load
                s.spike_clusters = read('spike_clusters');
                s.cluster_ids = unique(s.spike_clusters);
                params = Neuropixel.readINI(fullfile(ds.path, 'params.py'));
                s.sample_rate = params.sample_rate;
                s.offset = params.offset;
                s.spike_times = read('spike_times');
            end
            
            s.nSpikes = numel(s.spike_clusters);
            s.nClusters = numel(s.cluster_ids);
            s.nSec = double(max(s.spike_times) - s.offset) / double(s.sample_rate);
            
            counts = histcounts(s.spike_clusters, sort(s.cluster_ids));
            s.fr = counts / double(s.nSec);
            s.thresh = p.Results.frThresholdHz;
            
            s.clusterMask = s.fr > s.thresh;
            s.nClustersAboveThresh = nnz(s.clusterMask);
            s.nSpikesAboveThresh = nnz(ismember(s.spike_clusters, s.cluster_ids(s.clusterMask)));
            
            function out = read(file)
                out = Neuropixel.readNPY(fullfile(ds.path, [file '.npy']));
            end
        end
        
        function s = printBasicStats(ds, varargin)
            s = ds.computeBasicStats(varargin{:});
            
            fprintf('%s: %.1f sec, %d (%d) spikes, %d (%d) clusters (with fr > %g Hz)\n', ds.pathLeaf, s.nSec, ...
                s.nSpikes, s.nSpikesAboveThresh, ...
                s.nClusters, s.nClustersAboveThresh, s.thresh);
            
            plot(sort(s.fr, 'descend'), 'k-')
            xlabel('Cluster');
            ylabel('# spikes');
            hold on
            yline(s.thresh, 'Color', 'r');
            hold off;
            box off;
            grid on;
        end

        function load(ds, reload)
            if nargin < 2
                reload = false;
            end
            if ds.isLoaded && ~reload
                return;
            end
            ks.isLoaded = false;
                
            params = Neuropixel.readINI(fullfile(ds.path, 'params.py'));
            ds.dat_path = params.dat_path;
            ds.n_channels_dat = params.n_channels_dat;
            ds.dtype = params.dtype;
            ds.offset = params.offset;
            ds.sample_rate = params.sample_rate;
            ds.hp_filtered = params.hp_filtered;

            p = ds.path;
            existp = @(file) exist(fullfile(p, file), 'file') > 0;
            
            hasRez = existp('rez.mat');
            
            nProg = 15;
            if hasRez
                nProg = nProg + 1;
            end
            prog = Neuropixel.Utils.ProgressBar(nProg, 'Loading Kilosort dataset: ');

            ds.amplitudes = read('amplitudes');
            ds.channel_ids = read('channel_map');
            ds.channel_ids = ds.channel_ids + ones(1, 'like', ds.channel_ids); % make channel map 1 indexed
            ds.channel_positions = read('channel_positions');
            ds.pc_features = read('pc_features');
            ds.pc_feature_ind = read('pc_feature_ind');
            ds.pc_feature_ind = ds.pc_feature_ind + ones(1, 'like', ds.pc_feature_ind); % convert plus zero indexed to 1 indexed channels
            ds.similar_templates = read('similar_templates');
            ds.spike_templates = read('spike_templates');
            ds.spike_templates = ds.spike_templates + ones(1, 'like', ds.spike_templates);
            ds.spike_times = read('spike_times');
            ds.template_features = read('template_features');
            ds.template_feature_ind = read('template_feature_ind');
            ds.template_feature_ind = ds.template_feature_ind + ones(1, 'like', ds.template_feature_ind); % 0 indexed templates to 1 indexed templates
            
            ds.templates = read('templates');
            T = size(ds.templates, 2);
            ds.template_sample_offset = uint64(ceil(T/2)); % phy templates are centered on the spike time, with one extra sample post (e.g. -41 : 41)

            ds.templates_ind = read('templates_ind');
            ds.templates_ind = ds.templates_ind + ones(1, 'like', ds.templates_ind); % convert plus zero indexed to 1 indexed channels

            ds.whitening_mat = read('whitening_mat');
            ds.whitening_mat_inv = read('whitening_mat_inv');
            ds.spike_clusters = read('spike_clusters');
            
            ds.cluster_ids = unique(ds.spike_clusters);
            %ds.cluster_ids = (0:max(ds.spike_clusters))'; % this is important, since removed clusters still occupy a slice in several of the cluster rating matrices
            
            % load KS cluster labels
            ds.cluster_ks_label = repmat(categorical("unsorted"), numel(ds.cluster_ids), 1);
            if existp('cluster_KSLabel.tsv')
                tbl = readClusterMetaTSV('cluster_KSLabel.tsv', 'KSLabel', 'categorical');
                [tf, ind] = ismember(tbl.cluster_id, ds.cluster_ids);
                ds.cluster_ks_label(ind(tf)) = tbl{tf, 2};
            end
            
            % load cluster groups (mapping from cluster_ids to {good, mua, noise, unsorted})
            % important to lookup the cluster inds since we've uniquified spike_clusters
            fnameSearch = {'cluster_groups.csv', 'cluster_group.tsv'};
            found = false;
            for iF = 1:numel(fnameSearch)
                file = fnameSearch{iF};
                if existp(file)
                    tbl = readClusterMetaTSV(file, 'group', 'categorical');
                    found = true;
                    
                    ds.cluster_groups = repmat(categorical("unsorted"), numel(ds.cluster_ids), 1);
                    [tf, ind] = ismember(tbl.cluster_id, ds.cluster_ids);
                    ds.cluster_groups(ind(tf)) = tbl{tf, 2};
                end
            end
            if ~found
                % default to everything unsorted
                warning('Could not find cluster group file, defaulting to KS labels');
                ds.cluster_groups = ds.cluster_ks_label;
            end
            
            % 15 prog items to this point
            
            % load rez.mat
            if hasRez
                prog.increment('Loading rez.mat');
                d = load(fullfile(p, 'rez.mat'));
                rez = d.rez;

                if isfield(rez, 'est_contam_rate')
                    ds.kilosort_version = 2;
                else
                    ds.kilosort_version = 1;
                end

                if ds.kilosort_version == 2
                    ops = rez.ops;
                    ds.W = rez.W;
                    ds.U = rez.U;

                    % strip leading zeros off of ds.templates based on size of W
                    nTimeTempW = size(ds.W, 1);
                    nStrip = size(ds.templates, 2) - nTimeTempW;
                    if nStrip > 0
                        ds.templates = ds.templates(:, nStrip+1:end, :);
                        ds.template_sample_offset = ds.template_sample_offset - uint64(nStrip);
                    end

                    nBatches  = ops.Nbatch;
                    NT  	= uint64(ops.NT);
                    ds.batch_starts = (uint64(1) : NT : (NT*uint64(nBatches) + uint64(1)))';
                    ds.batchwise_cc = rez.ccb;
                    ds.batch_sort_order = rez.iorig;

                    % avoiding referencing the dependent properties in the constructor
                    % so we don't need to worry about what properties they reference
                    % that might not have been set yet
                    nTemplateRank = size(rez.WA, 3);
                    nTemplatePCs = size(rez.W_a, 2);
                    nTemplates = size(ds.templates, 1);
                    nTemplateTimepoints = size(ds.templates, 2);
                    nChannelsSorted = numel(ds.channel_ids);

                    ds.W_batch = single(rez.WA); % [nTemplateTimepoints, nTemplates, nTemplateRank, nBatches]
                    ds.W_batch_US = reshape(single(rez.W_a), [nTemplateTimepoints, nTemplateRank, nTemplatePCs, nTemplates]);
                    ds.W_batch_V = single(rez.W_b);

                    ds.U_batch = single(rez.UA);
                    ds.U_batch_US = reshape(single(rez.U_a), [nChannelsSorted, nTemplateRank, nTemplatePCs, nTemplates]);
                    ds.U_batch_V = single(rez.U_b);

                    ds.cluster_est_contam_rate = getOr(rez, 'est_contam_rate');
                    ds.cluster_merge_count = getOr(rez, 'mergecount');
                    ds.cluster_split_src = getOr(rez, 'splitsrc');                
                    ds.cluster_split_dst = getOr(rez, 'splitdst');
                    ds.cluster_split_auc = getOr(rez, 'splitauc');
                    ds.cluster_split_candidate = getOr(rez, 'split_candidate');
                    ds.cluster_orig_template = getOr(rez, 'cluster_split_orig_template');
                    
                    if isfield(rez, 'st3_cutoff_invalid')
                        % include invalid spikeas
                        ds.invalid_spike_times = rez.st3_cutoff_invalid(:, 1);
                        cols = size(rez.st3_cutoff_invalid, 2);
                        if cols > 5
                            col = cols;
                        else
                            col = 2;
                        end
                        ds.invalid_spike_templates = rez.st3_cutoff_invalid(:, 2);
                        ds.invalid_spike_clusters = rez.st3_cutoff_invalid(:, col);
                    end
                else
                    % TODO need to decide what to load for KS1
                end
            end
            
            prog.finish();
            ds.isLoaded = true;
            
            function v = getOr(s, fld, def)
                if isfield(s, fld)
                    v = s.(fld);
                elseif nargin > 2
                    v = def;
                else
                    v = [];
                end
            end
            
            function out = read(file)
                prog.increment('Loading Kilosort dataset: %s', file);
                out = Neuropixel.readNPY(fullfile(p, [file '.npy']));
            end
            
            function tbl = readClusterMetaTSV(file, field, type)
                opts = delimitedTextImportOptions("NumVariables", 2);
                    % Specify range and delimiter
                    opts.DataLines = [2, Inf];
                    opts.Delimiter = "\t";

                    % Specify column names and types
                    opts.VariableNames = ["cluster_id", string(field)];
                    opts.VariableTypes = ["uint32", string(type)];
                    opts = setvaropts(opts, 2, "EmptyFieldRule", "auto");
                    opts.ExtraColumnsRule = "ignore";
                    opts.EmptyLineRule = "read";

                    % Import the data
                    tbl = readtable(fullfile(p,file), opts);
            end
        end

        function checkLoaded(ds)
            if isempty(ds.amplitudes)
                ds.load();
            end
        end
        
        function sync = readSync(ds)
            if isempty(ds.raw_dataset)
                sync = zeros(0, 1, 'uint16');
            else
                sync = ds.raw_dataset.readSync();
            end
        end
        
        function sync = loadSync(ds, varargin)
            if isempty(ds.raw_dataset)
                sync = zeros(0, 1, 'uint16');
            else
                sync = ds.raw_dataset.readSync(varargin{:});
            end
        end
        
        function setSyncBitNames(ds, idx, names)
            if ~isempty(ds.raw_dataset)
                ds.raw_dataset.setSyncBitNames(idx, names);
            else
                if isscalar(idx) && ischar(names)
                    ds.syncBitNames{idx} = names;
                else
                    assert(iscellstr(names)) %#ok<ISCLSTR>
                    ds.syncBitNames(idx) = names;
                end
            end
        end
        
        function idx = lookupSyncBitByName(ds, names)
            if ischar(names)
                names = {names};
            end
            assert(iscellstr(names));

            [tf, idx] = ismember(names, ds.syncBitNames);
            idx(~tf) = NaN;
        end

        function seg = segmentIntoClusters(ds)
            % generates a KilosortTrialSegmentedDataset with only 1 trial.
            % Segments as though there is one all-inclusive trials, so that
            % clusters are split but not trials
            tsi = Neuropixel.TrialSegmentationInfo(1);

            tsi.trialId = 0;
            tsi.conditionId = 0;
            tsi.idxStart = 1;
            
            if ds.hasRawDataset
                tsi.idxStop = ds.raw_dataset.nSamplesAP;
            else
                tsi.idxStop = max(ds.spike_times) + 1;
            end

            seg = ds.segmentIntoTrials(tsi, 0);
        end

        function seg = segmentIntoTrials(ds, tsi, trial_ids)

            % trialInfo hs fields:
            %   trialId
            %   conditionId
            %   idxStart
            %   idxStop

            seg = Neuropixel.KilosortTrialSegmentedDataset(ds, tsi, trial_ids);
        end
        
        function channel_inds = channelNumsToChannelInds(ds, channels)
            [~, channel_inds] = ismember(channels, ds.channel_ids);
        end
        
        function m = computeMetrics(ds, recompute)
            if isempty(ds.metrics) || ~isvalid(ds.metrics) || (nargin >= 2 && recompute)
                ds.load();
                ds.metrics = Neuropixel.KilosortMetrics(ds);
            end
            m = ds.metrics;
        end
        
        function [clusterInds, cluster_ids] = lookup_clusterIds(ds, cluster_ids)
            if islogical(cluster_ids)
                cluster_ids = ds.cluster_ids(cluster_ids);
             end
            [tf, clusterInds] = ismember(cluster_ids, ds.cluster_ids);
            assert(all(tf), 'Some cluster ids were not found in ds.clusterids');
        end
        
        function [channelInds, channelIds] = lookup_channelIds(ds, channelIds)
             if islogical(channelIds)
                channelIds = ds.channel_ids(channelIds);
             end
            [tf, channelInds] = ismember(channelIds, ds.channel_ids);
            assert(all(tf), 'Some channel ids not found');
        end
        
        function [fileInds, origSampleInds] = lookup_sampleIndexInConcatenatedFile(ds, inds)
           [fileInds, origSampleInds] = ds.concatenationInfo.lookup_sampleIndexInSourceFiles(inds);
        end
    end
    
    methods % Computed data  
        function [snippetSet, reconstructionFromOtherClusters] = getWaveformsFromRawData(ds, varargin)
             % Extracts individual spike waveforms from the raw datafile, for multiple
             % clusters. Returns the waveforms and their means within clusters.
             %
             % Based on original getWaveForms function by C. Schoonover and A. Fink
             %
             % OUTPUT
             % wf.unitIDs                               % [nClu,1]            List of cluster IDs; defines order used in all wf.* variables
             % wf.spikeTimeKeeps                        % [nClu,nWf]          Which spike times were used for the waveforms
             % wf.waveForms                             % [nClu,nWf,nCh,nSWf] Individual waveforms
             % wf.waveFormsMean                         % [nClu,nCh,nSWf]     Average of all waveforms (per channel)
             %                                          % nClu: number of different clusters in .spikeClusters
             %                                          % nSWf: number of samples per waveform
             %
             % % USAGE
             % wf = getWaveForms(gwfparams);

             % Load .dat and Kilosort/Phy output

             p = inputParser();
             % specify (spike_idx or spike_times) and/or cluster_ids
             % if both are specified, spikes in the list of times with belonging to those cluster_ids will be kept
             p.addParameter('spike_idx', [], @isvector); % manually specify which idx into spike_times
             p.addParameter('spike_times', [], @isvector); % manually specify which times directly to extract
             p.addParameter('cluster_ids', [], @isvector); % manually specify all spikes from specific cluster_ids

             % and ONE OR NONE of these to pick channels (or channels for each cluster)
             p.addParameter('channel_ids_by_cluster', [], @(x) isempty(x) || ismatrix(x));
             p.addParameter('best_n_channels', NaN, @isscalar); % or take the best n channels based on this clusters template when cluster_id is scalar

             % if specified, spikes times will be filtered within this window
             p.addParameter('filter_window', [], @(x) isempty(x) || isvector(x));
             
             % other params:
             p.addParameter('num_waveforms', Inf, @isscalar); % caution: Inf will request ALL waveforms in order (typically useful if spike_times directly specified)
             p.addParameter('window', [-40 41], @isvector); % Number of samples before and after spiketime to include in waveform
             p.addParameter('car', false, @islogical);
             p.addParameter('centerUsingFirstSamples', 20, @(x) isscalar(x) || islogical(x)); % subtract mean of each waveform's first n samples, don't do if false

             p.addParameter('subtractOtherClusters', false, @islogical); % time consuming step to remove the contribution of the other clusters to a given snippet
             
             p.addParameter('raw_dataset', ds.raw_dataset, @(x) true);

             % other metadata set in snippetSet
             p.addParameter('trial_idx', [], @isvector);
             
             p.parse(varargin{:});

             assert(ds.hasRawDataset, 'KilosortDataset has no raw ImecDataset');
             
             ds.checkLoaded();
               
             if ~isempty(p.Results.spike_times)
                 spike_times = p.Results.spike_times; %#ok<*PROPLC>
                 [tf, spike_idx] = ismember(spike_times, ds.spike_times);
                 if any(~tf)
                     error('Not all spike times were found in KilosortDataset');
                 end


             elseif ~isempty(p.Results.spike_idx)
                 spike_idx = p.Results.spike_idx;
                 spike_times = ds.spike_times(spike_idx);
                 
             elseif ~isempty(p.Results.cluster_ids)
                 clu = p.Results.cluster_ids;

                 if isscalar(clu)
                     spike_idx = find(ds.spike_clusters == clu);
                     spike_times = ds.spike_times(spike_idx);
                 else
                     mask = ismember(ds.spike_cluster, clu);
                     spike_times = ds.spike_times(mask);
                 end
             else
                 error('Must specify one of spike_times, spike_idx, or cluster_id');
             end
             
             mask = true(numel(spike_idx), 1);
             
             % filter by cluster_ids if specified
             unique_cluster_ids = p.Results.cluster_ids; % allow caller to specify directly

             if ~isempty(unique_cluster_ids)
                 mask = mask & ismember(ds.spike_clusters(spike_idx), unique_cluster_ids);
             end
             
             % filter by sample_window range
             filter_window = p.Results.filter_window;
             if ~isempty(filter_window)
                 mask = mask & spike_times >= uint64(filter_window(1)) & spike_times <= uint64(filter_window(2));
             end
             
             % apply mask
             spike_idx = spike_idx(mask);
             spike_times = spike_times(mask);
             
             % fetch other info
             cluster_ids = ds.spike_clusters(spike_idx);
             if isempty(unique_cluster_ids)
                 unique_cluster_ids = unique(cluster_ids);
             end
             
             trial_idx = p.Results.trial_idx;
             if ~isempty(trial_idx)
                 trial_idx = trial_idx(mask);
                 assert(numel(trial_idx) == numel(spike_idx));
             end

             % take max of num_waveforms from each cluster
             if isfinite(p.Results.num_waveforms)             
                 mask = false(numel(spike_idx), 1);
                 nSample = p.Results.num_waveforms;
                 [~, uclust_ind] = ismember(cluster_ids, unique_cluster_ids);
                 nClu = numel(unique_cluster_ids);
                 for iC = 1:nClu
                     thisC = find(uclust_ind == iC);
                     if numel(thisC) <= nSample
                         mask(thisC) = true;
                     else
                         mask(thisC(randsample(numel(thisC), nSample, false))) = true;
                     end
                 end
                 
                 spike_idx = spike_idx(mask); %#ok<NASGU>
                 spike_times = spike_times(mask);
                 cluster_ids = cluster_ids(mask);
                 if ~isempty(trial_idx)
                     trial_idx = trial_idx(mask);
                 end
             end
             
                          
             % figure out channels requested, one set for each cluster
             if ~isnan(p.Results.best_n_channels)
                 metrics = ds.computeMetrics();
                 cluster_best_template_channels = metrics.cluster_best_channels;
                 
                 % okay to have multiple clusters
                 [~, cluster_ind] = ismember(unique_cluster_ids, ds.cluster_ids);
                 if any(cluster_ind == 0)
                     error('Some cluster idx not found in cluster_ids');
                 end
                 channel_ids_by_cluster = cluster_best_template_channels(cluster_ind, 1:p.Results.best_n_channels)';
             elseif ~isempty(p.Results.channel_ids_by_cluster)
                 channel_ids_by_cluster = p.Results.channel_ids_by_cluster;
             else
                 channel_ids_by_cluster = ds.channel_ids;
             end

             % channel_ids is provided since raw data often has additional channels that we're not interested in
             window = p.Results.window;
             snippetSet = p.Results.raw_dataset.readAPSnippetSet(spike_times, ...
                 window, 'channel_ids_by_cluster', channel_ids_by_cluster, ...
                 'cluster_ids', cluster_ids, ...
                 'car', p.Results.car);
             snippetSet.trial_idx = trial_idx;
             snippetSet.ks = ds;
             
             if p.Results.subtractOtherClusters
                 reconstructionFromOtherClusters = ds.reconstructSnippetSetFromTemplates(snippetSet, ...
                     'excludeClusterFromOwnReconstruction', true);
                 snippetSet.data = snippetSet.data - reconstructionFromOtherClusters.data;
             end

             if p.Results.centerUsingFirstSamples
                 snippetSet.data = snippetSet.data - mean(snippetSet.data(:, 1:p.Results.centerUsingFirstSamples, :), 2, 'native');
             end
             
        end
         
        function snippetSet = readAPSnippetSet(ds, times, window, varargin)
            snippetSet = ds.raw_dataset.readAPSnippetSet(times, window, ...
                'channel_ids', ds.channel_ids, varargin{:});
            snippetSet.ks = ds;
        end
        
        function [spike_inds, template_start_ind, scaled_templates] = findSpikesOverlappingWithWindow(ds, sample_window, varargin)
            % spike_inds is nSpikes x 1 index into ks.spike_times indicating which spikes overlap with this window
            % template_start_ind indicates where each spike would begin wihtin sample_window
            % templates is nCh x nTemplateTimepoints x nSpikes
            p = inputParser();
            p.addParameter('cluster_ids', ds.cluster_ids, @(x) isempty(x) || isvector(x));
            p.addParameter('channel_ids', ds.channel_ids, @(x) isempty(x) || isvector(x)); % which channel_ids to construct templates into
            p.parse(varargin{:});
                 
             % find spikes that would lie within this window (with padding), 
            relTvec_template = ds.templateTimeRelative;   
            minT = sample_window(1) - int64(relTvec_template(end));
            maxT = sample_window(2) - int64(relTvec_template(1));
            spike_inds = find(ds.spike_times >= minT & ds.spike_times <= maxT);      
            
            % only those from clusters we wish to include
            cluster_ids = p.Results.cluster_ids;
            spike_inds(~ismember(ds.spike_clusters(spike_inds), cluster_ids)) = [];
            
            template_offset = find(relTvec_template == 0);
            % spike time - template_offset + int64(1) is sample index where start of template belongs
            % this above - sample_window(1) + 1 gives the index where the template should start in the sample_window
            template_start_ind = int64(ds.spike_times(spike_inds)) - int64(template_offset) + int64(1) - int64(sample_window(1)) + int64(1);
            
            channel_ids = p.Results.channel_ids;
            nChannels = numel(channel_ids);
            [tf, channel_inds] = ismember(channel_ids, ds.channel_ids);
            assert(all(tf), 'Some requestedchannels not found in channel_ids');
            scaled_templates = nan(nChannels, ds.nTemplateTimepoints, numel(spike_inds));
            
            metrics = ds.computeMetrics();
            templates_unw =  metrics.template_unw; % unwhitened templates, but not scaled and still in quantized units (not uV)
            
            for iS = 1:numel(spike_inds)
                ind = spike_inds(iS);
                amp = ds.amplitudes(ind) * ds.apScaleToUv;

                % figure out time overlap and add to reconstruction
                scaled_templates(:, :, iS)  = amp .* permute(templates_unw(ds.spike_templates(ind), :, channel_inds), [3 2 1]); % 1 x T x C --> C x T x 1
            end
        end
        
        function [reconstruction, reconstructionMode] = reconstructRawSnippetsFromTemplates(ds, times, window, varargin)
            % generate the best reconstruction of each snippet using the amplitude-scaled templates 
            % this is the internal workhorse for reconstructSnippetSetFromTemplates
            
            p = inputParser();
            % these define the lookup table of channels for each cluster
            p.addParameter('channel_ids_by_snippet', [], @(x) isempty(x) || ismatrix(x));
            p.addParameter('unique_cluster_ids', 1, @isvector);
            % and this defines the cluster corresponding to each spike
            p.addParameter('cluster_ids', ones(numel(times), 1), @isvector);
            
            p.addParameter('exclude_cluster_ids_each_snippet', [], @(x) isempty(x) || isvector(x) || iscell(x));
            p.addParameter('exclude_cluster_ids_all_snippets', [], @(x) isempty(x) || isvector(x));
            p.addParameter('showPlots', false, @islogical);
            p.addParameter('rawData', [], @isnumeric); % for plotting only
            p.parse(varargin{:});
            showPlots = p.Results.showPlots;
            
            % check sizes of everything
            nTimes = numel(times);
            channel_ids_by_snippet = p.Results.channel_ids_by_snippet;
            assert(~isempty(channel_ids_by_snippet));
            if size(channel_ids_by_snippet, 2) == 1
                channel_ids_by_snippet = repmat(channel_ids_by_snippet, 1, numel(times));
            end
            assert(numel(times) == size(channel_ids_by_snippet, 2));
            
            nChannelsSorted = size(channel_ids_by_snippet, 1);
            unique_cluster_ids = p.Results.unique_cluster_ids;
            
            cluster_ids = p.Results.cluster_ids;
            assert(numel(cluster_ids) == nTimes);
            
            exclude_cluster_ids_each_snippet = p.Results.exclude_cluster_ids_each_snippet;
            exclude_cluster_ids_all_snippets = p.Results.exclude_cluster_ids_all_snippets;
            
            % templates post-whitening is nTemplates x nTimepoints x nChannelsFull
            metrics = ds.computeMetrics();
            templates =  metrics.template_unw; % unwhitened templates, but not scaled and still in quantized units (not uV)
              
%             nTimeTemplates = size(templates, 2);
              
            relTvec_template = ds.templateTimeRelative;
            relTvec_snippet = int64(window(1):window(2));
            reconstruction = zeros(nChannelsSorted, numel(relTvec_snippet), nTimes, 'single');
            
            prog = Neuropixel.Utils.ProgressBar(nTimes, 'Reconstructing templates around snippet times');
            
%             function template = getTemplate(template_ind, batch_ind, time_inds, ch_inds)
%                 switch reconstructionMode
%                     case 'batch_full'
%                         Wi = ks.W_batch(time_inds, template_ind, :, batch_ind);
%                         Ui = ks.U_batch(:, template_ind, :, batch_ind);
% %                         Ui_unw = 
%                         % whiten U
%                         wmi = single(ks.whitening_mat_inv);
%                         whichChannels = ks.templates_ind(iT, :);
%                         template_unw(iT, :, whichChannels) = templates(iT, :, :);
%             end
%                         Ui = Neuropixel.Utils.TensorUtils.linearCombinationAlongDimension(Ui, 1, ks.whitening_mat_inv);
% %                         Ui = Ui(
%                     case 'templates'
%                         tempplate = metrics.template_unw(template_ind, time_inds, ch_inds);
%                 end
%             end
            
            for iT = 1:nTimes
                prog.update(iT);
                
                % find spikes that would lie within this window (with padding), 
                % excluding those from clusters we wish to exclude
                t = int64(times(iT));
                minT = t + window(1) - int64(relTvec_template(end));
                maxT = t + window(2) - int64(relTvec_template(1));
                if iscell(exclude_cluster_ids_each_snippet)
                    exclude_this = exclude_cluster_ids_each_snippet{iT};
                elseif ~isempty(exclude_cluster_ids_each_snippet)
                    exclude_this = exclude_cluster_ids_each_snippet(iT);
                else
                    exclude_this = [];
                end
                exclude_this = union(exclude_this, exclude_cluster_ids_all_snippets);
                
                nearby_spike_inds = find(ds.spike_times >= minT & ds.spike_times <= maxT);      
                %nearby_spike_inds = find(ds.spike_times == t);
                
                nearby_spike_inds(ismember(ds.spike_clusters(nearby_spike_inds), exclude_this)) = [];

                % figure out what channels we need to reconstruct onto
                cluster_ids_this = cluster_ids(iT);
                [~, cluster_ind_this] = ismember(cluster_ids_this, unique_cluster_ids);
                assert(cluster_ind_this > 0, 'Cluster for times(%d) not found in unique_cluster_ids', iT);
                channels_idx_this = channel_ids_by_snippet(:, iT);
                [~, channel_ind_this] = ismember(channels_idx_this, ds.channel_ids);
                assert(all(channel_ind_this) > 0, 'Some channels in channel_ids_by_cluster not found in channel_ids');
                
                if showPlots
                    clf;
                    plot(relTvec_snippet, p.Results.rawData(1, :, iT), 'k-', 'LineWidth', 2);
                    hold on;
                end
                
                % loop over the enarby sp
                for iS = 1:numel(nearby_spike_inds)
                    ind = nearby_spike_inds(iS);
                    amp = ds.amplitudes(ind);
                    
                    % figure out time overlap and add to reconstruction
                    tprime = int64(ds.spike_times(ind));
                    indFromTemplate = relTvec_template + tprime >= t + relTvec_snippet(1) & relTvec_template + tprime <= t + relTvec_snippet(end);
                    indInsert = relTvec_snippet + t >= relTvec_template(1) + tprime & relTvec_snippet + t <= relTvec_template(end) + tprime;
                    insert = amp .* permute(templates(ds.spike_templates(ind), indFromTemplate, channel_ind_this), [3 2 1]);
                    reconstruction(:, indInsert, iT) = reconstruction(:, indInsert, iT) + insert;
                    
                    if showPlots
                        if tprime == t
                            args = {'LineWidth', 1, 'Color', 'g'};
                        else
                            args = {};
                        end
                        plot(relTvec_template + tprime-t, amp .* templates(ds.spike_templates(ind), :, channel_ind_this(1)), 'Color', [0.7 0.7 0.7], args{:});
                    end
                end
                
                if showPlots
                    plot(relTvec_snippet, reconstruction(1, :, iT), 'r--', 'LineWidth', 2);
                    plot(relTvec_snippet, p.Results.rawData(1, :, iT) - int16(reconstruction(1, :, iT)), 'b--');
                    pause;
                end
            end
            prog.finish();
        end
            
        function ssReconstruct = reconstructSnippetSetFromTemplates(ds, ss, varargin)
            % used to build a snippet set consisting of all the templates inserted at all of the spike times
            % that overlap with the time windows present in ss (the source snippet set)
            % this is typically used to clean the snippet set by subtracting the inferred spike templates for a subset 
            % of clusters (those not of interest)
            p = inputParser();
            p.addParameter('excludeClusterFromOwnReconstruction', false, @islogical);
            p.addParameter('exclude_cluster_ids', [], @(x) isempty(x) || isvector(x));
            p.addParameter('showPlots', false, @islogical);
            p.parse(varargin{:});
            
            if p.Results.excludeClusterFromOwnReconstruction
                exclude_cluster_ids_each_snippet = ss.cluster_ids;
            else
                exclude_cluster_ids_each_snippet = [];
            end
            
            reconstruction = ds.reconstructRawSnippetsFromTemplates(ss.sample_idx, ss.window, ...
                'channel_ids_by_snippet', ss.channel_ids_by_snippet, 'unique_cluster_ids', ss.unique_cluster_ids, ...
                'cluster_ids', ss.cluster_ids, 'exclude_cluster_ids_each_snippet', exclude_cluster_ids_each_snippet, ...
                'exclude_cluster_ids_all_snippets', p.Results.exclude_cluster_ids, ...
                'showPlots', p.Results.showPlots, 'rawData', ss.data);
            
            ssReconstruct = Neuropixel.SnippetSet(ds);
            ssReconstruct.data = int16(reconstruction);
            ssReconstruct.sample_idx = ss.sample_idx;
            ssReconstruct.channel_ids_by_snippet = ss.channel_ids_by_snippet;
            ssReconstruct.cluster_ids = ss.cluster_ids;
            ssReconstruct.window = ss.window;
        end
        
        function snippetSet = readAPSnippsetSet_clusterIdSubset(ds, times, window, cluster_ids, varargin) 
            % a utility used by several methods in KilosortMetrics. Extracts snippets at times in times, but sets the snippet set to 
            % overlay waveforms for specific cluster_ids of interest, and also selects only the channels for those clusters
             p = inputParser();
             
             % and ONE OR NONE of these to pick channels (or channels for each cluster) that will be highlighted
             p.addParameter('channel_ids', [], @(x) isempty(x) || ismatrix(x));
             p.addParameter('best_n_channels', [], @(x) isempty(x) || isscalar(x)); % if specified, the best n channels for each cluster will be chosen
             
             p.addParameter('car', false, @islogical);
             p.addParameter('centerUsingFirstSamples', 20, @(x) isscalar(x) || islogical(x)); % subtract mean of each waveform's first n samples, don't do if false
             
             p.addParameter('subtractOtherClusters', false, @islogical); % time consuming step to remove the contribution of the other clusters (those not in cluster_ids) to a given snippet
             p.addParameter('raw_dataset', ds.raw_dataset, @(x) true);

             p.parse(varargin{:});
             
             raw_dataset = p.Results.raw_dataset;
             channel_ids = p.Results.channel_ids;
             
             
             % automatically pick clusters 
             if isempty(p.Results.channel_ids)
                 if isempty(p.Results.best_n_channels)
                    channel_ids = raw_dataset.goodChannels;
                 else
                     m = ds.computeMetrics();
                     channel_ids = m.gather_best_channels_multiple_clusters(cluster_ids, p.Results.best_n_channels);
                 end
             end
             
             snippetSet = raw_dataset.readAPSnippetSet(times, window, 'channel_ids', channel_ids, 'car', p.Results.car);
             snippetSet.ks = ds;
             
             if p.Results.subtractOtherClusters
                 reconstructionFromOtherClusters = ds.reconstructSnippetSetFromTemplates(snippetSet, ...
                     'exclude_cluster_ids', cluster_ids, ...
                     'excludeClusterFromOwnReconstruction', false);
                 snippetSet.data = snippetSet.data - reconstructionFromOtherClusters.data;
             end

             if p.Results.centerUsingFirstSamples
                 snippetSet.data = snippetSet.data - mean(snippetSet.data(:, 1:p.Results.centerUsingFirstSamples, :), 2, 'native');
             end

             % specify these cluster_ids for overlaying waveforms
             snippetSet.overlay_cluster_ids = cluster_ids;
             
        end
    end
end
