function i2nUpdateSource(pp)

if (exist([pp.SCRATCH '\i2n_sourceupdater.bat'],'file'))
    delete([pp.SCRATCH '\i2n_sourceupdater.bat']);
end

% Cleanup
workers = feature('numcores');
fid = fopen([pp.SCRATCH '\i2n_sourceupdater.bat'], 'w');

% RAW DATA
fprintf(fid, '%s\n', ...
    ['robocopy ' ...
    pp.DATA_DEST '_1_CAT_DATA' ...
    ' ' ...
    pp.DATA_SOURCE '_1_CAT_DATA' ...
    ' /e /j /mt:' ...
    num2str(workers) ' &']);

% RAW DATA
fprintf(fid, '%s\n', ...
    ['robocopy ' ...
    pp.DATA_DEST '_2_BIN_DATA' ...
    ' ' ...
    pp.DATA_SOURCE '_2_BIN_DATA' ...
    ' /e /j /mt:' ...
    num2str(workers)] ' &');

% RAW DATA
fprintf(fid, '%s\n', ...
    ['robocopy ' ...
    pp.DATA_DEST '_3_SPK_DATA' ...
    ' ' ...
    pp.DATA_SOURCE '_3_SPK_DATA' ...
    ' /e /j /mt:' ...
    num2str(workers)] ' &');

% RAW DATA
fprintf(fid, '%s\n', ...
    ['robocopy ' ...
    pp.DATA_DEST '_4_SSC_DATA' ...
    ' ' ...
    pp.DATA_SOURCE '_4_SSC_DATA' ...
    ' /e /j /mt:' ...
    num2str(workers)] ' &');

% RAW DATA
fprintf(fid, '%s\n', ...
    ['robocopy ' ...
    pp.DATA_DEST '_5_CNX_DATA' ...
    ' ' ...
    pp.DATA_SOURCE '_5_CNX_DATA' ...
    ' /e /j /mt:' ...
    num2str(workers)] ' &');

% NWB DATA
fprintf(fid, '%s\n', ...
    ['robocopy ' ...
    pp.DATA_DEST '_6_NWB_DATA' ...
    ' ' ...
    pp.DATA_SOURCE '_6_NWB_DATA' ...
    ' /e /j /mt:' ...
    num2str(workers) ' &']);

fclose('all');

system([pp.SCRATCH '\i2n_sourceupdater.bat']);
delete([pp.SCRATCH '\i2n_sourceupdater.bat']);

end