function [channels] = channels(obj)
    markers = obj.markerNames';
    idx = find(arrayfun(@(x1) ischar(x1{1}) && ~isempty(strfind(x1{1}, '_')) && ...
                                    isempty(strfind(x1{1}, 'DNA')) && ...
                                    isempty(strfind(x1{1}, 'DEAD')), markers));
    channels = cell(numel(idx), 2);
    for i = 1:numel(idx)
       name = markers(idx(i));
       split = strsplit(name{:}, '_');
       channels(i,:) = [idx(i), {strjoin(split(2:end), '_')}];
    end
end