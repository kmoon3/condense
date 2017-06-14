classdef ContractionClustering
    properties
        options = [];
        % This holds the data point positions at each point of the sequence.
        contractionSequence = [];
        % This holds the data point positions at the current contraction step with
        % epsilon clusters being represented by a single point been merged.
        dataContracted = [];
        eigenvalueSequence = [];
        clusterStats = {};
        currentEigenvectors = [];
        currentEigenvalues = [];
        clusterAssignments = [];
        currentSigma = Inf;
        sampleIndices = [];
        normalizedAffinityMatrix = [];
        normalizedAffinityMatrixInitialSigma = [];
        weights = [];
        runtimes;
        iteration = 0;
        epsilon;
        sampleSize;
        channels = []
    end
    methods
        function obj = ContractionClustering(data, channels, options)
            obj.options = options;
            obj.channels = channels;
            obj.sampleSize = size(data,1);
            obj.dataContracted = data;
            obj.currentSigma = obj.options.initialSigma;
            if (obj.currentSigma == Inf)
                [distanceMatrix, ~] = calcDistanceMatrix(data);
                obj.currentSigma = mean2(distanceMatrix) - std2(distanceMatrix);
            end

            % Make sure the expert labels are properly populated.
            if (isempty(obj.options.expertLabels))
                obj.options.expertLabels = ones(size(obj.dataContracted, 1), 1);
            end
            assert(isequal(length(obj.options.expertLabels), size(obj.dataContracted, 1)));

            % Populate sample indices.
            obj.sampleIndices = num2cell(1:size(obj.dataContracted, 1));

            % Calculate epsilon
            obj.epsilon = max(max(obj.dataContracted)-min(obj.dataContracted))/10000;

            obj.runtimes = containers.Map({'aff', 'spd', 'clas', 'vis', 'contr', 'rest'}, zeros(1, 6));
        end
        function obj = contract(obj)
            obj = obj.steps(obj.options.maxNumContractionSteps);
            obj.emitRuntimeBreakdown();
            obj.emitCondensationSequence();
        end
        function obj = steps(obj, varargin)
            switch nargin
                case 1
                    nsteps = 1;
                case 2
                    nsteps = varargin{end};
            end
            terminated = false;
            for step = 0:nsteps
                for iteration = obj.iteration+1:obj.options.maxNumContractionSteps
                    obj.iteration = iteration;
                    obj.contractionSequence(:, :, obj.iteration) = inflateClusters(obj.dataContracted, obj.sampleIndices);
                    obj = obj.calcAffinities();
                    obj = obj.spectralDecompose();
                    obj = obj.performContractionMove();
                    obj = obj.mergeEpsilonClusters();
                    obj = obj.assignClusters();
                    obj = obj.controlSigma();
                    obj = obj.plotAlgorithmState();
                    obj.printProgress(false);
                    if (obj.checkTerminationCondition())
                        terminated = true;
                        break;
                    end
                    if (obj.isMetastable())
                        break;
                    end
                end
                if (terminated)
                    break
                end
            end
        end
        function obj = calcAffinities(obj)
            tic;
            obj.weights = cellfun(@length, obj.sampleIndices);
            [D, Z] = calcDistanceMatrix(obj.dataContracted, ...
                                        'k_knn', obj.options.kKNN, ...
                                        'type_k_knn', 'normal', ...
                                        'distfun', 'euclidean', ...
                                        'lengthPartitions', 2*obj.currentSigma, ...
                                        'mode', obj.options.modeCalcDistances, ...
                                        'n_pca', obj.options.numPrincipalComponents, ...
                                        'indentationLevel', obj.options.indentationLevel + 1, ...
                                        'verbosityLevel', obj.options.verbosityLevel - 1);
            if (obj.requireSpectralDecomposition())
                 obj.normalizedAffinityMatrixInitialSigma = calcNormalizedAffinityMatrix(D, Z, ...
                                                                                     'sigma', obj.options.initialSigma, ...
                                                                                     'exponent', 2, ...
                                                                                     'weights', obj.weights);
            end
            obj.normalizedAffinityMatrix = calcNormalizedAffinityMatrix(D, Z, ...
                                                                    'sigma', obj.currentSigma, ...
                                                                    'exponent', 2, ...
                                                                    'weights', obj.weights);
            obj.runtimes('aff') = obj.runtimes('aff') + toc;
        end
        function obj = spectralDecompose(obj)
            if (obj.requireSpectralDecomposition())
                tic
                [obj.currentEigenvectors, obj.currentEigenvalues] = ...
                    eig(obj.normalizedAffinityMatrixInitialSigma*diag(obj.weights)+0.00000001);
                [obj.currentEigenvalues, indicesSort] = sort(abs(diag(obj.currentEigenvalues)));
                obj.eigenvalueSequence(obj.iteration, :) = ...
                    [min(min(obj.eigenvalueSequence))*ones(size(obj.contractionSequence, 1)-length(obj.currentEigenvalues), 1) ; obj.currentEigenvalues];
                obj.currentEigenvectors = obj.currentEigenvectors(:, indicesSort);
                obj.currentEigenvectors = abs(obj.currentEigenvectors(:, obj.currentEigenvalues > 0.99));
                obj.runtimes('spd') = obj.runtimes('spd') + toc;
            end
        end
        function obj = assignClusters(obj)
            tic;
            switch (obj.options.clusterAssignmentMethod)
                case 'none'
                    clusterAssignment = (1:size(obj.dataContracted, 1))';
                case 'spectral'
                    %% Runs spectral clustering. Note that this means that k-means
                    %% is run on the eigenvectors corresponding to the eigenvalues
                    %% close to one. I doubt that it is technically spectral clustering
                    %% because this would require that we did take the eigenvectors
                    %% of the laplacian and we do not really use the laplacian here.
                    if (size(obj.currentEigenvectors, 2) > 20)
                        obj.currentEigenvectors = pcaMaaten(obj.currentEigenvectors, 20);
                    end
                    clusterAssignment = kmeans(obj.currentEigenvectors, sum(obj.currentEigenvalues>0.99));
                otherwise
                    error(['Unknown cluster assignment method: ' obj.options.clusterAssignmentMethod]);
            end
            obj.clusterAssignments(obj.iteration, :) = inflateClusters(clusterAssignment, ...
                                                                       obj.sampleIndices);
            obj.runtimes('clas') = obj.runtimes('clas') + toc;
        end
        function obj = plotAlgorithmState(obj)
            persistent myTextObj;
            persistent lastSigma;
            persistent sigmaBumps;
            persistent currentLengthIterations;
            if (obj.options.plotAnimation)
                tic
                if obj.iteration == 1
                    sigmaBumps = [];
                    lastSigma = obj.currentSigma;
                    set(gcf, 'Position', [2068 1 1200 800]);
                    currentLengthIterations = 50;
                    relativeMovement = [];
                    previousDataContracted = obj.dataContracted;
                else
                    if (obj.currentSigma ~= lastSigma)
                        lastSigma = obj.currentSigma;
                        sigmaBumps = [sigmaBumps obj.iteration];
                    end
                    if (obj.iteration > currentLengthIterations)
                        currentLengthIterations = 2*currentLengthIterations;
                    end
                end
                if (obj.options.phateEmbedding)
                    % Plotting samples at original position.
                    ax1 = subplot('Position', [0.05, 0.125, 0.425, 0.8]);
                    [~, npca] = size(obj.contractionSequence(:, :, 1));
                    embedding = phate(obj.contractionSequence(:, :, 1), 'npca', npca, 'mds_method', 'cmds');
                    scatterX(embedding, 'colorAssignment', obj.clusterAssignments(obj.iteration, :));
                    colormap(ax1, distinguishable_colors(length(unique(obj.clusterAssignments(obj.iteration, :)))));
                    % Plotting samples at contracted position.
                    ax2 = subplot('Position', [0.525, 0.125, 0.425, 0.8]);
                    scatterX(embedding);
                    colormap(ax2, 'gray');
                    hold on;
                    [centroids, sizes] = stats(embedding, obj.clusterAssignments(obj.iteration, :));
                    scatter(centroids(:, 1), centroids(:, 2), sizes, distinguishable_colors(max(obj.clusterAssignments(obj.iteration, :))), 'o', 'filled');
                    hold off;
                else
                    % Plotting samples at original position.
                    ax1 = subplot('Position', [0.05, 0.125, 0.425, 0.8]);
                    scatterX(obj.contractionSequence(:, :, 1), 'colorAssignment', obj.clusterAssignments(obj.iteration, :),...
                                'dimensionalityReductionMethod', 'tsne', ...
                                'sizeAssignment', obj.options.sizefn(obj.clusterAssignments(obj.iteration, :), obj.channels), ...
                                'labels', obj.options.labelfn(obj.clusterAssignments(obj.iteration, :), obj.channels));
                    colormap(ax1, distinguishable_colors(length(unique(obj.clusterAssignments(obj.iteration, :)))));
                    lims = axis;
                    % Plotting samples at contracted position.
                    ax2 = subplot('Position', [0.525, 0.125, 0.425, 0.8]);
                    sizeAssignment = sqrt(cellfun(@size, obj.sampleIndices, repmat({2}, 1, length(obj.sampleIndices))));
                    scatterX(obj.dataContracted, ...
                         'colorAssignment', 1:max(obj.clusterAssignments(obj.iteration, :)), ...
                         'sizeAssignment', sizeAssignment');
                    colormap(ax2, distinguishable_colors(max(obj.clusterAssignments(obj.iteration, :))));
                end
                bar = subplot('Position', [0.05, 0.05, 0.9, 0.05]);
                data = obj.clusterAssignments(end,:);
                branches = max(obj.clusterAssignments(end,:));
                cbranch=[1*ones(length(obj.clusterAssignments(end, obj.clusterAssignments(end,:) == 1)),1)];  
            
                for cluster = 2:branches
                   group = obj.clusterAssignments(end, obj.clusterAssignments(end,:) == cluster);
                   cbranch=[cbranch; cluster*ones(length(group),1)];
                end
                imagesc(bar, cbranch');
                colormap(bar, distinguishable_colors(max(obj.clusterAssignments(obj.iteration, :))));
                set(bar,'xtick', []);
                set(bar,'ytick', []);
                % Plotting Header Line
                subplot('Position', [0.05, 0.925, 0.935, 0.125], 'Visible', 'off')
                toWrite = ['Iteration ' num2str(obj.iteration) ...
                           ', \sigma = ' num2str(obj.currentSigma) ...
                           ', #Clusters = ' num2str(length(unique(obj.clusterAssignments(obj.iteration, :)))) ...
                           ', #Samples = ' num2str(size(obj.dataContracted, 1))];
                if obj.iteration == 1
                    myTextObj = text(0, 0.5, toWrite, 'FontSize', 20);
                else
                    set(myTextObj, 'String', toWrite);
                end
                obj.saveFigureAsAnimationFrame();
                obj.runtimes('vis') = obj.runtimes('vis') + toc;
            end
        end
        function rsl = checkTerminationCondition(obj)
            tic
            rsl = false;
            numClusters = length(unique(obj.clusterAssignments(obj.iteration, :)));
            if (numClusters == 1 && obj.iteration > 5)
                rsl = true;
            elseif (obj.options.fastStop && obj.sampleSize ~= numClusters && numClusters <= obj.options.maxClusters)
                rsl = true;
            end
            obj.runtimes('rest') = obj.runtimes('rest') + toc;
        end
        function obj = performContractionMove(obj)
            tic
            diffusedNormalizedAffinityMatrix = diffuse(obj.normalizedAffinityMatrix, 'numDiffusionSteps', obj.options.numDiffusionSteps, 'weights', obj.weights); 
            obj.dataContracted =   (1-obj.options.inertia) * weightedMultiply(diffusedNormalizedAffinityMatrix, obj.dataContracted, obj.weights) ...
                                 +  obj.options.inertia    * obj.dataContracted;
            obj.runtimes('contr') = obj.runtimes('contr') + toc;
        end
        function stable = isMetastable(obj)
            stable = false;
            if (obj.iteration == 1)
                stable = false;
            else
                switch (obj.options.controlSigmaMethod)
                    case 'nuclearNormStabilization'
                        %% The idea of this mode is to keep the sigma constant until the sum of eigenvalues
                        %% stabilizes. The sum of eigenvalues is considered stablized if
                        %% the sum of ten consecutive decreases is less than 5% of the
                        %% total sum of eigenvalues. After the sum of eigenvalues stabilized,
                        %% the sigma is increased by 20%.
                        if (   (obj.iteration > 10) ...
                            && (  sum(sum(obj.eigenvalueSequence(:, obj.iteration-10:obj.iteration-1))-sum(obj.eigenvalueSequence(:, obj.iteration-9:obj.iteration))) ...
                                < 0.05 * sum(obj.eigenvalueSequence(:, obj.iteration-10))))
                           stable = true;
                        end
                    case 'movementStabilization'
                        if (isequal(size(obj.dataContracted), size(previousDataContracted)))
                            thisRelativeMovement = max(sum(abs(obj.dataContracted-previousDataContracted)))/max(max(obj.dataContracted)-min(obj.dataContracted))+eps;
                            if (thisRelativeMovement < obj.options.thresholdControlSigma)
                                stable = true;
                            end
                        end
                end
            end
        end
        function obj = controlSigma(obj)
            tic
            persistent iterationLastIncrease;
            persistent previousDataContracted;
            if (obj.iteration == 1)
                iterationLastIncrease = 1;
                previousDataContracted = obj.dataContracted;
            else
                switch (obj.options.controlSigmaMethod)
                    case 'nuclearNormStabilization'
                        %% The idea of this mode is to keep the sigma constant until the sum of eigenvalues
                        %% stabilizes. The sum of eigenvalues is considered stablized if
                        %% the sum of ten consecutive decreases is less than 5% of the
                        %% total sum of eigenvalues. After the sum of eigenvalues stabilized,
                        %% the sigma is increased by 20%.
                        if (   (obj.iteration > 10) ...
                            && (  sum(sum(obj.eigenvalueSequence(:, obj.iteration-10:obj.iteration-1))-sum(obj.eigenvalueSequence(:, obj.iteration-9:obj.iteration))) ...
                                < 0.05 * sum(obj.eigenvalueSequence(:, obj.iteration-10))))
                            obj.currentSigma = 1.1*obj.currentSigma;
                            disp(['Bumped sigma in iteration ' num2str(obj.iteration)]);
                        end
                    case 'movementStabilization'
                        if (isequal(size(obj.dataContracted), size(previousDataContracted)))
                            thisRelativeMovement = max(sum(abs(obj.dataContracted-previousDataContracted)))/max(max(obj.dataContracted)-min(obj.dataContracted))+eps;
                            disp(['Did not contract, checking if should bump sigma on itration ' num2str(obj.iteration), ...
                                ' with relative movment of ', num2str(thisRelativeMovement), '<', num2str(obj.options.thresholdControlSigma) ]);
                            if (thisRelativeMovement < obj.options.thresholdControlSigma)
                                obj.currentSigma = 1.1*obj.currentSigma;
                                disp(['Bumped sigma to ', num2str(obj.currentSigma), 'in iteration ', num2str(obj.iteration), ... 
                                    ' previous bump was on ', num2str(iterationLastIncrease)]);
                                iterationLastIncrease = obj.iteration;
                            end
                        end
                        previousDataContracted = obj.dataContracted;
                end
            end
            obj.runtimes('rest') = obj.runtimes('rest') + toc;
        end
        function obj = mergeEpsilonClusters(obj)
            tic
            persistent previousSigma;
            if (obj.iteration == 1)
                previousSigma = obj.currentSigma;
            else
                mergeEpsilonClusters = false;
                switch (obj.options.frequencyMergingEpsilonClusters)
                    case 'uponMetastability'
                        mergeEpsilonClusters = (obj.currentSigma ~= previousSigma);
                        previousSigma = obj.currentSigma;
                    case 'always'
                        mergeEpsilonClusters = true;
                end
                if (mergeEpsilonClusters)
                    disp('Merging Clusters');
                    switch (obj.options.epsilonClusterIdentificationMethod)
                        case 'constantEpsilon'
                            epsilon = obj.epsilon;
                        case 'dynamicSigmaFraction'
                            epsilon = obj.currentSigma/4;
                    end
                    [obj.dataContracted, obj.sampleIndices] = ...
                        conflateClusters(obj.dataContracted, ...
                                         obj.sampleIndices, ...
                                         detectEpsilonClusters(obj.dataContracted, epsilon));
                end
            end
            obj.runtimes('rest') = obj.runtimes('rest') + toc;
        end
        function rsl = requireSpectralDecomposition(obj)
            rsl = (   strcmp(obj.options.clusterAssignmentMethod, 'spectral') ...
                   || strcmp(obj.options.controlSigmaMethod, 'nuclearNormStabilization'));
        end
        function heatmap(obj, fields)
            if (nargin < 2)
                fields = obj.channels;
            end
            obj.centroidHeatmap(fields);
            obj.clusterHeatmaps(fields);
        end
        function centroidHeatmap(obj, fields)
            fields = sort(fields);
            index = find(ismember(sort(obj.channels), fields));
            [centroids, sizes] = stats(obj.contractionSequence(:,index,1), obj.clusterAssignments(end,:)'); 
            data = [];
            for cluster = 1:length(sizes)
               row = centroids(cluster,:);
               if cluster == 1
                 data = [data; [0, sizes(cluster), row]];
               else
                 data = [data; [norm(row - data(1,3:end)), sizes(cluster), row]];
               end
            end
            data=sortrows(data);
            rows = data(:,2);
            data = zscore(data);
            frame = gcf;
            fig = subplot('Position', [0.1 0.1 0.8 0.8]);
            imagesc(fig, data(:,3:end));
            
            fig.XAxis.TickLabels = fields';
            set(fig,'xtick',1:length(fields));
            xlabel('channel');
            
            fig.YAxis.TickLabels = rows;
            set(fig,'ytick',1:size(rows));
            ylabel('size of cluster');

            colormap(fig, parula);
            colorbar(fig);
            saveas(fig, strcat(obj.options.destination, '_centroids.png'));
        end
        function clusterHeatmaps(obj, fields)
            fields = sort(fields);
            index = find(ismember(sort(obj.channels), fields));
            frame = gcf;
            set(frame, 'Position', [1 1 1500 1000]);
            set(frame,'Color','white');
            samples = obj.contractionSequence(:, index, 1);
            data = samples(obj.clusterAssignments(end,:) == 1,:);
            branches = max(obj.clusterAssignments(end,:));
            bins = zeros(branches,1);
            
            bins(1) = length(data);
            cbranch=[1*ones(length(data),1)];  
            
            for cluster = 2:branches
                
              group = samples(obj.clusterAssignments(end,:) == cluster,:);
              bins(cluster) = length(group);
              
              data = [data; group];
              cbranch=[cbranch; cluster*ones(length(group),1)];
            end
            
            fig = subplot('Position', [0.1, 0.1, .8, .8]);
            
            imagesc(fig, zscorep(data, .95)');
            colormap(fig, parula);
            fig.YAxis.TickLabels = fields';
            set(fig,'ytick',1:length(fields));
            set(fig,'xtick',[]);
            
            line([cumsum(bins) cumsum(bins)]', repmat(ylim, length(bins), 1)', 'color', 'k','Linewidth', 1);
            
            bar = subplot('Position', [0.1, 0.05, .8, .05]);
            imagesc(bar, cbranch');
            colormap(bar, distinguishable_colors(max(obj.clusterAssignments(obj.iteration, :))));
                      
            set(bar,'xtick', []);
            set(bar,'ytick', []);
            
            frame.InvertHardcopy = 'off';
            saveas(frame, strcat(obj.options.destination, '_heatmap.png'));
        end
        function printProgress(obj, forcePrint)
            persistent timeLastPrint;
            if (obj.iteration==1)
                timeLastPrint = 0;
            end
            overallTime = sum(cell2mat(obj.runtimes.values())) + eps;
            if (forcePrint || overallTime > timeLastPrint + 10)
                timeLastPrint = overallTime;
                if (obj.options.verbosityLevel > 0)
                    message = ['ContractionClustering: Iteration ' sprintf('%4u', obj.iteration) ...
                               ', runtime: ' sprintf('%7.2f', overallTime)];
                    for key = obj.runtimes.keys()
                        message = [message ' ' key{1} '=' num2str(obj.runtimes(key{1})/overallTime, '%.2f')];
                    end
                    disp([indent(obj.options.indentationLevel) message]);
                end
            end
        end
        function emitRuntimeBreakdown(obj)
            if (obj.options.emitRuntimeBreakdown)
                runtimeLabels = obj.runtimes.keys();
                runtimes = obj.runtimes.values(runtimeLabels);
                save([obj.options.prefixFileNames obj.options.asString() '_runtimeBreakdown.mat'], ...
                     'runtimes', 'runtimeLabels');
            end
        end
        function emitCondensationSequence(obj)
            if (obj.options.emitCondensationSequence)
                condensationSequence = obj.contractionSequence;
                save([obj.options.prefixFileNames obj.options.asString() '_condensationSequence.mat'], ...
                     'condensationSequence');
            end
        end
        function saveFigureAsAnimationFrame(obj)
            rez=1200; 
            f=gcf;
            figpos=getpixelposition(f);
            resolution=get(0,'ScreenPixelsPerInch'); 
            set(f,'paperunits','inches','papersize',figpos(3:4)/resolution,...
                        'paperposition',[0 0 figpos(3:4)/resolution]);
            im = print('-RGBImage');
            [imind,cm] = rgb2ind(im,256);
            snapshot = char(strcat(obj.options.destination, 'step-', string(obj.iteration), '-clusters.png'));
            saveas(gcf, snapshot);
            filename = char(strcat(obj.options.destination, 'animated.gif'));
            
            if obj.iteration == 1
                imwrite(imind,cm,filename,'gif','Loopcount',inf,'DelayTime',0);
            else
                imwrite(imind,cm,filename,'gif','WriteMode','append','DelayTime',1);
            end
        end
    end
end

function [ epsilonClusterAssignment ] = detectEpsilonClusters(M, epsilon)
    numSamples = size(M, 1);
    idx = knnsearch_fast(M, M, size(M, 1)-1);
    epsilonClusterAssignment = 1:numSamples;
    numClusters=1;
    for i=1:numSamples
        if (epsilonClusterAssignment(i) == i)
            epsilonClusterAssignment(i) = numClusters;
            for j=idx(i, :)
                if (norm(M(i, :)-M(j, :))<epsilon)
                    epsilonClusterAssignment(j) = numClusters;
                else
                    break;
                end
            end
            numClusters = numClusters+1;
        end
    end
end

function [ resultM, resultSampleIndices ] = conflateClusters(M, sampleIndices, clusterAssignment)
    resultM = [];
    resultSampleIndices = {};
    numClusters = max(clusterAssignment);
    for i = 1:numClusters
        rowIndicesInCluster = find(clusterAssignment==i);
        clusterMedian = median(M(rowIndicesInCluster, :), 1);
        resultM = [resultM; clusterMedian];
        resultSampleIndices{i} = sampleIndices{rowIndicesInCluster(1)};
        for j = 2:length(rowIndicesInCluster)
            resultSampleIndices{i} = union(resultSampleIndices{i}, ...
                                           sampleIndices{rowIndicesInCluster(j)});
        end
    end
end

function [diffusedNormalizedAffinityMatrix] = diffuse(normalizedAffinityMatrix, varargin)

    numDiffusionSteps = 50;
    mode = 'exact';
    nystroemN = 200;
    rsvd = 10;

    for i=1:length(varargin)-1
        if (strcmp(varargin{i}, 'numDiffusionSteps'))
            numDiffusionSteps = varargin{i+1};
        end
        if (strcmp(varargin{i}, 'mode'))
            mode = varargin{i+1};
            if ~ismember(mode, {'exact', 'nystroem', 'rsvd', 'svd', 'eig'})
                warning(['Diffuse: Invalid choice "' mode '" for argument ' ...
                         'mode. Using default value "exact"']);
                mode = 'exact';
            end
        end
        if (strcmp(varargin{i}, 'nystroemN'))
            nystroemN = varargin{i+1};
        end
        if (strcmp(varargin{i}, 'rsvdK'))
            rsvdK = varargin{i+1};
        end
        if (strcmp(varargin{i}, 'weights'))
            weights = varargin{i+1};
        end
    end

    normalizedAffinityMatrix = full(normalizedAffinityMatrix);
    
    assert(numDiffusionSteps >= 1);

    switch (mode)
        case 'exact'
            if (exist('weights', 'var'))
                y = diag(1./weights);
                while (numDiffusionSteps > 1)
                    if (mod(numDiffusionSteps, 2)) 
                        %odd
                        y = weightedMultiply(y, normalizedAffinityMatrix, weights);
                        normalizedAffinityMatrix = weightedMultiply(normalizedAffinityMatrix, normalizedAffinityMatrix, weights);
                        numDiffusionSteps = (numDiffusionSteps-1)/2;
                    else
                        %even
                        normalizedAffinityMatrix = weightedMultiply(normalizedAffinityMatrix, normalizedAffinityMatrix, weights);
                        numDiffusionSteps = (numDiffusionSteps-1)/2;
                    end
                end
                diffusedNormalizedAffinityMatrix = weightedMultiply(y, normalizedAffinityMatrix, weights);
            else
                diffusedNormalizedAffinityMatrix = normalizedAffinityMatrix^numDiffusionSteps;
            end
        case 'svd'
            assert(~exist('weights', 'var'));
            [U,S,V] = svd(normalizedAffinityMatrix);
            Sd = S^numDiffusionSteps;
            diffusedNormalizedAffinityMatrix = U*Sd*V';
        case 'eig'
            assert(~exist('weights', 'var'));
            [U,L] = eigenDecompose(normalizedAffinityMatrix, ...
                                   'mode', 'normal');
            Ld = L^numDiffusionSteps;
            diffusedNormalizedAffinityMatrix = U*Ld*inv(U);
        case 'rsvd'
            assert(~exist('weights', 'var'));
            [U,S,V] = rndsvd(normalizedAffinityMatrix, rsvdK);
            Sd = S^numDiffusionSteps;
            diffusedNormalizedAffinityMatrix = U*Sd*V';
        case 'nystroem'
            assert(~exist('weights', 'var'));
            [ eigenvectors, eigenvalues ] = eigenDecompose(normalizedAffinityMatrix, ...
                                                           'mode', 'nystroem', ...
                                                           'nystroemN', nystroemN);
            diffusedEigenvalues = eigenvalues^numDiffusionSteps;
            diffusedNormalizedAffinityMatrix = eigenvectors*diffusedEigenvalues*eigenvectors';
    end
end

function [inflatedM] = inflateClusters(M, sampleIndices)
    inflatedM = [];
    for i = 1:size(M, 1)
        currentSampleIndices = sampleIndices{i};
        inflatedM(currentSampleIndices, :) = repmat(M(i, :),length(currentSampleIndices),1);
    end
end
