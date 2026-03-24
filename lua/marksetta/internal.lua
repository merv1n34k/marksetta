-- Internal state container and profile filtering
-- Holds content chunks (internal types excluded), settings, and provides filtering

local M = {}

function M.new(chunks, settings)
    return {
        chunks = chunks,
        settings = settings or {},
    }
end

local function flavor_matches(flavor, pattern)
    if pattern == "*" then
        return true
    end
    -- Exact match
    if flavor == pattern then
        return true
    end
    -- Glob: "env:*" matches "env:tikz", "env:listing", etc.
    if pattern:sub(-1) == "*" then
        local prefix = pattern:sub(1, -2)
        if flavor:sub(1, #prefix) == prefix then
            return true
        end
    end
    return false
end

local function matches_any(flavor, list)
    if not list or #list == 0 then
        return false
    end
    for _, pat in ipairs(list) do
        if flavor_matches(flavor, pat) then
            return true
        end
    end
    return false
end

function M.filter(state, profile)
    local include = profile.include
    local exclude = profile.exclude

    if not include or #include == 0 then
        return {}
    end

    local result = {}
    for _, chunk in ipairs(state.chunks) do
        local dominated = matches_any(chunk.flavor, include)
        if dominated then
            if not exclude or not matches_any(chunk.flavor, exclude) then
                result[#result + 1] = chunk
            end
        end
    end
    return result
end

return M
