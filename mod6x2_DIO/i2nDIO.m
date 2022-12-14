function nwb = i2nDIO(pp, nwb, recdev)

for mm = 1 : numel(recdev.dio_map)
    if strcmp(recdev.dio_map{mm}.description, 'EVT')

        if size(recdev.board_dig_in_data,1) < 16

            digital_ordered = recdev.board_dig_in_data;

            intan_code_times_unprocessed = find(sum(digital_ordered) > 0);
            intan_code_times = nan(length(intan_code_times_unprocessed),1);
            intan_code_values = nan(numel(recdev.dio_map{mm}.map),length(intan_code_times_unprocessed));

            temp_ctr = 1;
            intan_code_times(temp_ctr) = intan_code_times_unprocessed(temp_ctr);
            intan_code_values(:,temp_ctr) = digital_ordered(:,intan_code_times(temp_ctr));
            previous_value = intan_code_times(temp_ctr);
            temp_ctr = temp_ctr + 1;
            for jj = 2:length(intan_code_times_unprocessed)
                if ~(intan_code_times_unprocessed(jj) == previous_value + 1)
                    intan_code_times(temp_ctr) = intan_code_times_unprocessed(jj);
                    intan_code_values(:,temp_ctr) = digital_ordered(:,intan_code_times(temp_ctr)+1);
                    temp_ctr = temp_ctr + 1;
                end
                previous_value = intan_code_times_unprocessed(jj);
            end

            intan_code_times = intan_code_times(1:temp_ctr-1) ./ recdev.sampling_rate;
            intan_code_values = intan_code_values(:,1:temp_ctr-1);
            intan_code_values = bit2int(flip(intan_code_values),numel(recdev.dio_map{mm}.map))';

        else

            digital_ordered = recdev.board_dig_in_data(recdev.dio_map{mm}.map,:);

            raw_event_locations = find(recdev.board_dig_in_data(1,:));
            first_location = find(sum(recdev.board_dig_in_data)>1);
            first_location = first_location(1);

            %So, this code just reads down the list of "raw values", and only keeps the
            %location of the first non duplicated value, and throws away the rest
            counter = 1;
            intan_code_times = nan(length(raw_event_locations),1);
            intan_code_times(counter) = first_location;
            previous_value = intan_code_times(counter);
            counter = counter + 1;
            count_rep = 0;
            for ii = 2:length(raw_event_locations)
                if (raw_event_locations(ii) > first_location)
                    if(raw_event_locations(ii) == previous_value + 1)
                        count_rep = count_rep + 1;
                    else
                        intan_code_times(counter) = raw_event_locations(ii)+1;
                        counter = counter + 1;
                        count_rep = 0;
                    end
                    previous_value = raw_event_locations(ii);
                end
            end

            intan_code_times = rmmissing(intan_code_times);
            intan_code_values = bit2int(flip(digital_ordered(:,intan_code_times)),numel(recdev.dio_map{mm}.map))';
        end

        intan_code_times = intan_code_times / recdev.sampling_rate;
        % Dientangle event codes...
        event_data = identEvents(intan_code_values, intan_code_times);

        for jj = 1 : numel(event_data)
            temp_fields = fields(event_data{jj});
            temp_fields = temp_fields(~strcmp(temp_fields, 'task'));

            eval_str = [];
            for kk = 1 : numel(temp_fields)
                eval_str = ...
                    [ eval_str ...
                    ',convertStringsToChars("' temp_fields{kk} ...
                    '"), types.hdmf_common.VectorData(convertStringsToChars("data"), ' ...
                    'event_data{jj}.' temp_fields{kk} ...
                    ', convertStringsToChars("description"), ' ...
                    'convertStringsToChars("placeholder"))'];
            end
            eval_str = [
                'trials=types.core.TimeIntervals(convertStringsToChars("description"), ' ...
                'convertStringsToChars("events"), ' ...
                'convertStringsToChars("colnames"), ' ...
                'temp_fields' ...
                eval_str ');'];

            eval(eval_str); clear eval_str
            nwb.intervals.set(event_data{jj}.task{1}, trials); clear trials
        end

    end
end
end