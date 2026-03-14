-- State machine parser: SEEKING <-> IN_BLOCK
-- Produces atomic chunks with flavor tags, delimiter-stripped content

local M = {}

local function read_lines(filepath)
    local lines = {}
    local f = assert(io.open(filepath, "r"))
    for line in f:lines() do
        lines[#lines + 1] = line
    end
    f:close()
    return lines
end

local function check_context(rule, line_num, total_lines)
    local ctx = rule.context
    if not ctx then
        return true
    end
    if ctx.position == "start" and line_num ~= 1 then
        return false
    end
    if ctx.max_line and line_num > ctx.max_line then
        return false
    end
    if ctx.not_at == "start" and line_num == 1 then
        return false
    end
    return true
end

local function match_patterns(line, rule)
    if rule._matchers then
        for _, pat in ipairs(rule._matchers) do
            if line:match(pat) then
                return true
            end
        end
    elseif rule.patterns then
        for _, pat in ipairs(rule.patterns) do
            if line:match(pat) then
                return true
            end
        end
    end
    return false
end

local function match_start(line, rule)
    local pat = rule._start or rule.start
    if not pat then
        return nil
    end
    return { line:match(pat) }
end

local function build_end_pattern(rule, start_captures)
    local pat = rule._end or rule["end"]
    if not pat or not start_captures then
        return pat
    end
    -- Replace {N} references with captured values
    return pat:gsub("{(%d+)}", function(n)
        return start_captures[tonumber(n)] or ""
    end)
end

local function extract_captures(rule, start_captures)
    if not rule.capture or not start_captures then
        return {}
    end
    local result = {}
    for name, idx in pairs(rule.capture) do
        local val = start_captures[idx]
        if val and val ~= "" then
            result[name] = val
        end
    end
    return result
end

local function parse_setting(line)
    local k, v = line:match("^#@%s*([%w_.]+)%s*=%s*(.+)%s*$")
    if k then
        -- Strip trailing comments
        v = v:match("^(.-)%s*%-%-") or v
        v = v:match("^(.-)%s*$")
        return k, v
    end
    return nil
end

function M.parse(lines, rules)
    local chunks = {}
    local settings = {}
    local chunk_id = 0

    local state = "SEEKING"
    local text_buf = {}
    local text_start = nil
    local block_buf = {}
    local block_start = nil
    local block_rule = nil
    local block_end_pat = nil
    local block_captures = nil
    local block_line_count = 0

    local function flush_text(before_line)
        if #text_buf > 0 then
            chunk_id = chunk_id + 1
            chunks[#chunks + 1] = {
                id = chunk_id,
                flavor = "text",
                content = table.concat(text_buf, "\n"),
                start_line = text_start,
                end_line = before_line - 1,
                captures = {},
            }
            text_buf = {}
            text_start = nil
        end
    end

    local function flush_block(end_line)
        chunk_id = chunk_id + 1
        local flavor = block_rule.flavor
        if flavor == "env" and block_captures and block_captures.name then
            flavor = "env:" .. block_captures.name
        end
        chunks[#chunks + 1] = {
            id = chunk_id,
            flavor = flavor,
            content = table.concat(block_buf, "\n"),
            start_line = block_start,
            end_line = end_line,
            captures = block_captures or {},
        }
        block_buf = {}
        block_start = nil
        block_rule = nil
        block_end_pat = nil
        block_captures = nil
        block_line_count = 0
    end

    local function abort_block_as_text(current_line)
        -- Treat the opener + accumulated content as text lines
        if not text_start then
            text_start = block_start
        end
        -- We don't have the original opener line stored separately,
        -- but the block content was accumulated without delimiters.
        -- For abort, push block content into text buffer.
        for _, bline in ipairs(block_buf) do
            text_buf[#text_buf + 1] = bline
        end
        block_buf = {}
        block_start = nil
        block_rule = nil
        block_end_pat = nil
        block_captures = nil
        block_line_count = 0
    end

    for i, line in ipairs(lines) do
        if state == "IN_BLOCK" then
            block_line_count = block_line_count + 1

            -- Check max_size safeguard
            if block_rule.max_size and block_line_count > block_rule.max_size then
                abort_block_as_text(i)
                state = "SEEKING"
                -- Fall through to reprocess this line in SEEKING mode
            elseif line:match(block_end_pat) then
                -- End delimiter matched — flush block WITHOUT this line
                flush_block(i)
                state = "SEEKING"
                goto continue -- delimiter consumed, do not reprocess
            else
                block_buf[#block_buf + 1] = line
                goto continue
            end
        end

        -- SEEKING mode
        if state == "SEEKING" then
            local matched = false

            for _, rule in ipairs(rules) do
                if rule.fallback then
                    break -- fallback is always last, handled below
                end

                if not check_context(rule, i, #lines) then
                    goto next_rule
                end

                -- Internal rules (settings, comments)
                if rule.internal then
                    if match_patterns(line, rule) then
                        flush_text(i)
                        if rule.flavor == "settings" then
                            local k, v = parse_setting(line)
                            if k then
                                settings[k] = v
                            end
                        end
                        -- Internal lines are consumed, not stored
                        matched = true
                        break
                    end
                    goto next_rule
                end

                -- Self-contained rules (hr, etc.)
                if rule.self_contained then
                    if match_patterns(line, rule) then
                        flush_text(i)
                        chunk_id = chunk_id + 1
                        chunks[#chunks + 1] = {
                            id = chunk_id,
                            flavor = rule.flavor,
                            content = line,
                            start_line = i,
                            end_line = i,
                            captures = {},
                        }
                        matched = true
                        break
                    end
                    goto next_rule
                end

                -- Block rules (have start/end)
                if rule.start then
                    local caps = match_start(line, rule)
                    if caps and #caps > 0 then
                        flush_text(i)
                        block_start = i
                        block_rule = rule
                        block_captures = extract_captures(rule, caps)
                        block_end_pat = build_end_pattern(rule, caps)
                        block_buf = {}
                        block_line_count = 0
                        state = "IN_BLOCK"
                        matched = true
                        break
                    elseif caps then
                        -- match_start returned empty table for a pattern with no captures
                        -- Check if the pattern itself matched
                        goto next_rule
                    end
                    goto next_rule
                end

                -- Pattern-only rules (non-internal, non-self-contained, non-block)
                if rule.patterns then
                    if match_patterns(line, rule) then
                        flush_text(i)
                        chunk_id = chunk_id + 1
                        chunks[#chunks + 1] = {
                            id = chunk_id,
                            flavor = rule.flavor,
                            content = line,
                            start_line = i,
                            end_line = i,
                            captures = {},
                        }
                        matched = true
                        break
                    end
                end

                ::next_rule::
            end

            -- Fallback: accumulate as text
            if not matched then
                if not text_start then
                    text_start = i
                end
                text_buf[#text_buf + 1] = line
            end
        end

        ::continue::
    end

    -- EOF handling
    if state == "IN_BLOCK" then
        -- Unclosed block → treat as text
        abort_block_as_text(#lines + 1)
    end
    flush_text(#lines + 1)

    return chunks, settings
end

function M.process(filepath, cfg)
    local lines = read_lines(filepath)
    local chunks, settings = M.parse(lines, cfg.rules)
    return { chunks = chunks, settings = settings }
end

return M
