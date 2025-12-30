mp.msg.info("MPV-CUT LOADED")

utils = require "mp.utils"

local function print(s)
	mp.msg.info(s)
	mp.osd_message(s)
end

local function extract_filename_from_path(path)
    -- Match everything after the last '/' (this works for both URLs and file paths)
    local filename = path:match("([^/]+)$")
    return filename
end

local function table_to_str(o)
	if type(o) == 'table' then
		local s = ''
		for k,v in pairs(o) do
			if type(k) ~= 'number' then k = '"'..k..'"' end
			s = s .. '['..k..'] = ' .. table_to_str(v) .. '\n'
		end
		return s
	else
		return tostring(o)
	end
end

local function to_hms(seconds)
	local ms = math.floor((seconds - math.floor(seconds)) * 1000)
	local secs = math.floor(seconds)
	local mins = math.floor(secs / 60)
	secs = secs % 60
	local hours = math.floor(mins / 60)
	mins = mins % 60
	return string.format("%02d-%02d-%02d-%03d", hours, mins, secs, ms)
end

local function next_table_key(t, current)
	local keys = {}
	for k in pairs(t) do
		keys[#keys + 1] = k
	end
	table.sort(keys)
	for i = 1, #keys do
		if keys[i] == current then
			return keys[(i % #keys) + 1]
		end
	end
	return keys[1]
end

ACTIONS = {}

ACTIONS.COPY = function(d)
	function dump(o)
	   if type(o) == 'table' then
		  local s = '{ '
		  for k,v in pairs(o) do
			 if type(k) ~= 'number' then k = '"'..k..'"' end
			 s = s .. '['..k..'] = ' .. dump(v) .. ','
		  end
		  return s .. '} '
	   else
		  return tostring(o)
	   end
	end

	local args = {
		"ffmpeg",												-- The following overwrite security settings introduced by ffmpeg!
        "-protocol_whitelist", "file,http,https,tcp,tls,crypto",-- Whitelist the protocols
		"-extension_picky", "0",            					-- Standalone flag for FFmpeg 8.0+
        "-allowed_extensions", "ALL",                           -- Allow manifest types
        "-allowed_segment_extensions", "ALL",                   -- Allow .gif segments (FFmpeg 8.0+)
		"-fflags", "+igndts",               					-- Ignore corrupt timestamps often found in .gif chunks
		"-nostdin", "-y",
		"-loglevel", "error",
		"-ss", d.start_time, 
		"-i", d.inpath, 
		"-map", "0",
		"-c", "copy",
		"-t", d.duration,
		"-c", "copy",
		"-map", "0",
		"-dn",
		"-avoid_negative_ts", "make_zero",
		utils.join_path(d.indir, "COPY_" .. d.channel .. "_" .. d.infile_noext .. "_FROM_" .. d.start_time_hms .. "_TO_" .. d.end_time_hms .. d.ext)
	}
	--file = io.open("C:/Users/<user>/Downloads/a.txt", "w")
	--file:write(dump(args))
	--file:close()
	mp.command_native_async({
		name = "subprocess",
		args = args,
		playback_only = false,
	}, function() print("Done") end)
end

ACTIONS.ENCODE = function(d)
	local args = {
		"ffmpeg",												-- The following overwrite security settings introduced by ffmpeg!
        "-protocol_whitelist", "file,http,https,tcp,tls,crypto",-- Whitelist the protocols
		"-extension_picky", "0",            					-- Standalone flag for FFmpeg 8.0+
        "-allowed_extensions", "ALL",                           -- Allow manifest types
        "-allowed_segment_extensions", "ALL",                   -- Allow .gif segments (FFmpeg 8.0+)
		"-fflags", "+igndts",               					-- Ignore corrupt timestamps often found in .gif chunks
		"-nostdin", "-y",
		"-loglevel", "error",
		"-ss", d.start_time,
		"-i", d.inpath,
		"-t", d.duration,
		"-pix_fmt", "yuv420p",
		"-crf", "16",
		"-preset", "superfast",
		utils.join_path(d.indir, "ENCODE_" .. d.channel .. "_" .. d.infile_noext .. "_FROM_" .. d.start_time_hms .. "_TO_" .. d.end_time_hms .. d.ext)
	}
	mp.command_native_async({
		name = "subprocess",
		args = args,
		playback_only = false,
	}, function() print("Done") end)
end

ACTIONS.LIST = function(d)
	local inpath = mp.get_property("path")
	local outpath = inpath .. ".list"
	local file = io.open(outpath, "a")
	if not file then print("Error writing to cut list") return end
	local filesize = file:seek("end")
	local s = "\n" .. d.channel
		.. ":" .. d.start_time
		.. ":" .. d.end_time
	file:write(s)
	local delta = file:seek("end") - filesize
	io.close(file)
	print("Δ " .. delta)
end

ACTION = "COPY"

CHANNEL = 1

CHANNEL_NAMES = {}

KEY_CUT = "c"
KEY_CANCEL_CUT = "C"
KEY_CYCLE_ACTION = "a"
KEY_BOOKMARK_ADD = "i"
KEY_CHANNEL_INC = "="
KEY_CHANNEL_DEC = "-"

home_config = mp.command_native({"expand-path", "~/.config/mpv-cut/config.lua"})
if pcall(require, "config") then
    mp.msg.info("Loaded config file from script dir")
elseif pcall(dofile, home_config) then
    mp.msg.info("Loaded config file from " .. home_config)
else
    mp.msg.info("No config loaded")
end

for i, v in ipairs(CHANNEL_NAMES) do
    CHANNEL_NAMES[i] = string.gsub(v, ":", "-")
end

if not ACTIONS[ACTION] then ACTION = next_table_key(ACTIONS, nil) end

START_TIME = nil

local function get_current_channel_name()
	return CHANNEL_NAMES[CHANNEL] or tostring(CHANNEL)
end

local function get_data()
	local function getDownloadFolder()
		-- Windows or Linux path logic
		return (package.config:sub(1, 1) == '\\') 
            and (os.getenv("USERPROFILE") .. "\\Downloads") 
            or (os.getenv("HOME") .. "/Downloads")
	end

	local d = {}
	local path = mp.get_property("path") or ""
	local media_title = title or mp.get_property("media-title") or "fallback_default_filename"
	local url = media_title:match("(https?://[%w%.%-_/=?&;:,%+]+)")

	if url then
		d.inpath = url
	else
		d.inpath = path
	end
    
    -- CRITICAL: Strip all invalid characters that accumulate from mpv properties
    if d.inpath then
        d.inpath = d.inpath:gsub('"', ''):gsub('\\', ''):gsub('^%s*', ''):gsub('%s*$', '')
    end

    -- If inpath is still empty (nil-guard), return a dummy table to prevent crashes
    if not d.inpath or d.inpath == "" or d.inpath == "unknown" then
        return { inpath = "unknown", indir = getDownloadFolder(), infile_noext = "error", channel = "1", ext = ".mp4" }
    end

	

	-- 2. Determine Directory and Filename
	if d.inpath:find("^http") then
		-- It's a URL, use the Downloads folder
		d.indir = getDownloadFolder()
		d.infile_noext = extract_filename_from_path(media_title):gsub('[%p%s]+', '_') -- Clean special characters
		d.ext = ".mp4"
	else
		-- It's a local file, use the directory where the file is located
        -- DO NOT USE split_path() on a URL
		d.indir = utils.split_path(d.inpath) or "."
		d.infile_noext = mp.get_property("filename/no-ext") or "unknown"
		d.ext = d.inpath:match("^.+(%..+)$") or ".mp4"
	end

	d.channel = tostring(get_current_channel_name() or "1")
	return d
end


local function get_times(start_time, end_time)
	local d = {}
	d.start_time = tostring(start_time)
	d.end_time = tostring(end_time)
	d.duration = tostring(end_time - start_time)
	d.start_time_hms = tostring(to_hms(start_time))
	d.end_time_hms = tostring(to_hms(end_time))
	d.duration_hms = tostring(to_hms(end_time - start_time))
	return d
end

text_overlay = mp.create_osd_overlay("ass-events")
text_overlay.hidden = true
text_overlay:update()

local function text_overlay_off()
	-- https://github.com/mpv-player/mpv/issues/10227
	text_overlay:update()
	text_overlay.hidden = true
	text_overlay:update()
end

local function text_overlay_on()
	local channel = get_current_channel_name()
	text_overlay.data = string.format("%s in %s from %s", ACTION, channel, START_TIME)
	text_overlay.hidden = false
	text_overlay:update()
end

local function print_or_update_text_overlay(content)
	if START_TIME then text_overlay_on() else print(content) end
end

local function cycle_action()
	ACTION = next_table_key(ACTIONS, ACTION)
	print_or_update_text_overlay("ACTION: " .. ACTION)
end

local function cut(start_time, end_time)
	local d = get_data()
	local t = get_times(start_time, end_time)
	for k, v in pairs(t) do d[k] = v end
	mp.msg.info(ACTION)
	mp.msg.info(table_to_str(d))
	ACTIONS[ACTION](d)
end

local function put_time()
    local time = mp.get_property_number("time-pos")
    if not START_TIME then
        START_TIME = time
        text_overlay_on()
        return
    end
    text_overlay_off()
    if time > START_TIME then
        local end_time = time
		cut(START_TIME, end_time)
		START_TIME = nil
    else
        print("INVALID")
        START_TIME = nil
    end
end

local function cancel_cut()
	text_overlay_off()
	START_TIME = nil
	print("CANCELLED CUT")
end

local function get_bookmark_file_path()
	local d = get_data()
	if d.inpath == "unknown" or d.inpath == "" then return nil end
	mp.msg.info(table_to_str(d))
	local outfile = string.format("%s_%s.book", d.channel, d.infile)
	return utils.join_path(d.indir, outfile)
end

local function bookmarks_load()
	local inpath = get_bookmark_file_path()
	if not inpath then return end

	local file = io.open(inpath, "r")
	if not file then return end
	local arr = {}
	for line in file:lines() do
		if tonumber(line) then
			table.insert(arr, {
				time = tonumber(line),
				title = "chapter_" .. line
			})
		end
	end
	file:close()
	table.sort(arr, function(a, b) return a.time < b.time end)
	mp.set_property_native("chapter-list", arr)
end

local function bookmark_add()
	local d = get_data()
	local outpath = get_bookmark_file_path()
	local file = io.open(outpath, "a")
	if not file then print("Failed to open bookmark file for writing") return end
	local out_string = mp.get_property_number("time-pos") .. "\n"
	local filesize = file:seek("end")
	file:write(out_string)
	local delta = file:seek("end") - filesize
	io.close(file)
	bookmarks_load()
	print(string.format("Δ %s, %s", delta, d.channel))
end

local function channel_inc()
	CHANNEL = CHANNEL + 1
	bookmarks_load()
	print_or_update_text_overlay(get_current_channel_name())
end

local function channel_dec()
	if CHANNEL >= 2 then CHANNEL = CHANNEL - 1 end
	bookmarks_load()
	print_or_update_text_overlay(get_current_channel_name())
end

local initial_load = true
local function delay_bookmark_load()
	mp.add_timeout(3, function()
		bookmarks_load()
   	end)
end

mp.add_key_binding(KEY_CUT, "cut", put_time)
mp.add_key_binding(KEY_CANCEL_CUT, "cancel_cut", cancel_cut)
mp.add_key_binding(KEY_BOOKMARK_ADD, "bookmark_add", bookmark_add)
mp.add_key_binding(KEY_CHANNEL_INC, "channel_inc", channel_inc)
mp.add_key_binding(KEY_CHANNEL_DEC, "channel_dec", channel_dec)
mp.add_key_binding(KEY_CYCLE_ACTION, "cycle_action", cycle_action)

mp.register_event('file-loaded', delay_bookmark_load)
