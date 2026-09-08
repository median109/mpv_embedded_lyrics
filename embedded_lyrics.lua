-- embedded_lyrics.lua
-- 支持逐字歌词 (Enhanced LRC) 转换与多语种渲染

local utils = require 'mp.utils'
local msg = require 'mp.msg'

local is_windows = os.getenv("WINDIR") ~= nil
local temp_dir = is_windows and os.getenv("TEMP") or "/tmp"
local temp_ass = utils.join_path(temp_dir, "mpv_embedded_temp.ass")

local function remove_temp_file()
    os.remove(temp_ass)
end

-- 时间戳 [mm:ss.xxx] 转毫秒
local function time_to_ms(min, sec, ms)
    min = tonumber(min) or 0
    sec = tonumber(sec) or 0
    ms = tonumber(ms) or 0
    if #tostring(ms) == 2 then ms = ms * 10 end -- 处理两位毫秒
    return (min * 60 + sec) * 1000 + ms
end

-- 检查字符串是否为合法的 UTF-8 编码
local function is_valid_utf8(str)
    local i, len = 1, #str
    while i <= len do
        local b = str:byte(i)
        if b < 128 then
            i = i + 1
        elseif b >= 192 and b <= 223 then
            if i + 1 > len or str:byte(i + 1) < 128 or str:byte(i + 1) > 191 then return false end
            i = i + 2
        elseif b >= 224 and b <= 239 then
            if i + 2 > len or str:byte(i + 1) < 128 or str:byte(i + 1) > 191 or str:byte(i + 2) < 128 or str:byte(i + 2) > 191 then return false end
            i = i + 3
        elseif b >= 240 and b <= 247 then
            if i + 3 > len or str:byte(i + 1) < 128 or str:byte(i + 1) > 191 or str:byte(i + 2) < 128 or str:byte(i + 2) > 191 or str:byte(i + 3) < 128 or str:byte(i + 3) > 191 then return false end
            i = i + 4
        else
            return false
        end
    end
    return true
end

-- 毫秒转 ASS 时间格式 h:mm:ss.cs
local function ms_to_ass_time(total_ms)
    local h = math.floor(total_ms / 3600000)
    total_ms = total_ms % 3600000
    local m = math.floor(total_ms / 60000)
    total_ms = total_ms % 60000
    local s = math.floor(total_ms / 1000)
    local cs = math.floor((total_ms % 1000) / 10)
    return string.format("%d:%02d:%02d.%02d", h, m, s, cs)
end

-- 将包含行内/尾部时间戳的 Enhanced LRC 转化为原生支持逐字的 ASS 格式
local function convert_lrc_to_ass(lrc_text)
    local header = [=[
[Script Info]
ScriptType: v4.00+
PlayResX: 384
PlayResY: 288
ScaledBorderAndShadow: yes

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,PingFang SC,18,&H00FFFFFF,&H000088FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,1,0,2,10,10,10,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
]=]

    local events = {}

    for line in lrc_text:gmatch("[^\r\n]+") do
        -- 匹配每行开头的 Start Time
        local s_m, s_s, s_ms, rest = line:match("^%[(%d+):(%d+)%.(%d+)%](.*)")
        if s_m then
            local start_ms = time_to_ms(s_m, s_s, s_ms)
            
            -- 检查行尾是否有结束时间戳，形如 [00:27.990]
            local end_m, end_s, end_ms = rest:match("%[(%d+):(%d+)%.(%d+)%]$")
            local end_ms_val = nil
            if end_m then
                end_ms_val = time_to_ms(end_m, end_s, end_ms)
                -- 裁剪掉末尾的时间戳文本
                rest = rest:gsub("%[(%d+):(%d+)%.(%d+)%]$", "")
            else
                end_ms_val = start_ms + 4000 -- 默认单行持续 4 秒
            end

            -- 处理逐字时间戳 (例如: Gee [00:28.247]gee [00:28.537]...)
            local current_time = start_ms
            local ass_text = ""
            
            -- 提取行内所有标记组
            local last_pos = 1
            for word, n_m, n_s, n_ms in rest:gmatch("(.-)%[(%d+):(%d+)%.(%d+)%]") do
                local next_time = time_to_ms(n_m, n_s, n_ms)
                local duration_cs = math.max(0, math.floor((next_time - current_time) / 10))
                ass_text = ass_text .. string.format("{\\kf%d}%s", duration_cs, word)
                current_time = next_time
                last_pos = last_pos + #word + #string.format("[%s:%s.%s]", n_m, n_s, n_ms)
            end

            -- 拼接行尾剩余文本
            local tail_word = rest:sub(last_pos)
            if #tail_word > 0 then
                local remaining_cs = math.max(0, math.floor((end_ms_val - current_time) / 10))
                ass_text = ass_text .. string.format("{\\kf%d}%s", remaining_cs, tail_word)
            end

            -- 如果没有任何逐字标签，生成标准行字幕
            if ass_text == "" then
                ass_text = rest
            end

            local start_str = ms_to_ass_time(start_ms)
            local end_str = ms_to_ass_time(end_ms_val)
            table.insert(events, string.format("Dialogue: 0,%s,%s,Default,,0,0,0,,%s", start_str, end_str, ass_text))
        end
    end

    return header .. table.concat(events, "\n")
end

local function extract_and_load_lyrics()
    local path = mp.get_property("path")
    if not path or path:find("^https?://") or path:find("^bd://") then return end

    remove_temp_file()

    local metadata = mp.get_property_native("metadata")
    local filtered_lyrics = nil
    local target_keys = {"lyrics", "unsyncedlyrics", "syncedlyrics", "uslt", "sylt", "comment"}

    if metadata then
        for k, v in pairs(metadata) do
            local lower_k = k:lower()
            for _, target in ipairs(target_keys) do
                if lower_k == target or lower_k:find("lyrics") then
                    if type(v) == "string" and #v > 0 then
                        filtered_lyrics = v
                        break
                    end
                end
            end
            if filtered_lyrics then break end
        end
    end

    if filtered_lyrics and #filtered_lyrics > 0 then
        filtered_lyrics = filtered_lyrics:gsub("\r\n", "\n"):gsub("\r", "\n")
        
        -- 实时转换为包含 {\kf} 变色标记的 ASS 格式
        local ass_content = convert_lrc_to_ass(filtered_lyrics)

        local f = io.open(temp_ass, "w+")
        if f then
            f:write(ass_content)
            f:close()

            mp.commandv("sub-add", temp_ass, "select", "Embedded Lyrics")
            msg.info("成功加载并解析逐字歌词！")
        end
    end
end

mp.register_event("file-loaded", extract_and_load_lyrics)
mp.register_event("shutdown", remove_temp_file)