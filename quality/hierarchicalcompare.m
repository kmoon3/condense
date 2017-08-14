function [assigments] = hierarchicalcompare(matrix, partitions)
    assigments = arrayfun(@(k) clusterdata(matrix, 'maxclust', k), ...
        1:max(max(partitions)), ...
        'UniformOutput', false);
    assigments = cell2mat(assigments)';
end