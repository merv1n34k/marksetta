-- read file and parse it line-wise

local M = {}

function M.import(filepath)
    local content = {}
    local f = assert(io.open(filepath, "r"))
    for line in f:lines() do
        table.insert(content, line)
    end
    f:close()
    return content
end

function M.get_by_pattern(content, pattern)
    local result = {}
    for _, line in ipairs(content) do
        if string.find(line, pattern) then
            table.insert(result, line)
        end
    end
    return result
end

function M.get_settings(content)
    local result = {}
    for _, setting in ipairs(M.get_by_pattern(content, "^#@%s*.")) do
        local k, v = string.match(setting, "^#@%s*(%a+)%s*=%s*(%w+)%s*")
        if type(k) == "string" then
            result[k] = v
        end
    end
    return result
end

-- each chunk has the following structure:
-- chunk_id = {content, type}
function M.chunk(content, dict)
    local chunks = {}
    local last = nil
    local chunk_id = 0
    for _, line in ipairs(content) do
        local matched_type = "text"
        for type, pattern in pairs(dict) do
            if type ~= "text" and string.find(line, pattern) then
                matched_type = type
                break
            end
        end
        if last ~= matched_type then
            chunk_id = chunk_id + 1
            chunks[chunk_id] = { content = {}, type = matched_type }
            last = matched_type
        end
        table.insert(chunks[chunk_id].content, line)
    end
    return chunks
end

return M
