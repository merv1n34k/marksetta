-- Minimal pure-Lua JSON decoder (no dependencies)
-- Only decode() is provided — encode is not needed.

local M = {}

local function skip_ws(s, pos)
    return s:match("^%s*()", pos)
end

local function decode_string(s, pos)
    assert(s:sub(pos, pos) == '"', "expected '\"'")
    pos = pos + 1
    local buf = {}
    while pos <= #s do
        local c = s:sub(pos, pos)
        if c == '"' then
            return table.concat(buf), pos + 1
        elseif c == "\\" then
            pos = pos + 1
            local esc = s:sub(pos, pos)
            local map = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
            if map[esc] then
                buf[#buf + 1] = map[esc]
            elseif esc == "u" then
                local hex = s:sub(pos + 1, pos + 4)
                buf[#buf + 1] = string.char(tonumber(hex, 16))
                pos = pos + 4
            end
        else
            buf[#buf + 1] = c
        end
        pos = pos + 1
    end
    error("unterminated string")
end

local decode_value -- forward declaration

local function decode_array(s, pos)
    assert(s:sub(pos, pos) == "[")
    pos = skip_ws(s, pos + 1)
    local arr = {}
    if s:sub(pos, pos) == "]" then
        return arr, pos + 1
    end
    while true do
        local val
        val, pos = decode_value(s, pos)
        arr[#arr + 1] = val
        pos = skip_ws(s, pos)
        local c = s:sub(pos, pos)
        if c == "]" then
            return arr, pos + 1
        elseif c == "," then
            pos = skip_ws(s, pos + 1)
        else
            error("expected ',' or ']' in array at position " .. pos)
        end
    end
end

local function decode_object(s, pos)
    assert(s:sub(pos, pos) == "{")
    pos = skip_ws(s, pos + 1)
    local obj = {}
    if s:sub(pos, pos) == "}" then
        return obj, pos + 1
    end
    while true do
        local key
        key, pos = decode_string(s, pos)
        pos = skip_ws(s, pos)
        assert(s:sub(pos, pos) == ":", "expected ':' at position " .. pos)
        pos = skip_ws(s, pos + 1)
        local val
        val, pos = decode_value(s, pos)
        obj[key] = val
        pos = skip_ws(s, pos)
        local c = s:sub(pos, pos)
        if c == "}" then
            return obj, pos + 1
        elseif c == "," then
            pos = skip_ws(s, pos + 1)
        else
            error("expected ',' or '}' in object at position " .. pos)
        end
    end
end

function decode_value(s, pos)
    pos = skip_ws(s, pos)
    local c = s:sub(pos, pos)
    if c == '"' then
        return decode_string(s, pos)
    elseif c == "{" then
        return decode_object(s, pos)
    elseif c == "[" then
        return decode_array(s, pos)
    elseif s:sub(pos, pos + 3) == "true" then
        return true, pos + 4
    elseif s:sub(pos, pos + 4) == "false" then
        return false, pos + 5
    elseif s:sub(pos, pos + 3) == "null" then
        return nil, pos + 4
    elseif c == "-" or c:match("%d") then
        local num_str = s:match("^%-?%d+%.?%d*[eE]?[+-]?%d*", pos)
        return tonumber(num_str), pos + #num_str
    else
        error("unexpected character '" .. c .. "' at position " .. pos)
    end
end

function M.decode(s)
    if type(s) ~= "string" then
        error("json.decode expects a string")
    end
    local val, pos = decode_value(s, 1)
    pos = skip_ws(s, pos)
    if pos <= #s then
        error("trailing content at position " .. pos)
    end
    return val
end

return M
