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

local function match_continue(line, rule)
    if not rule._continue then
        return false
    end
    for _, pat in ipairs(rule._continue) do
        if line:match(pat) then
            return true
        end
    end
    return false
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

-- Scan forward from `start` for literal `close_delim`
-- Skips escaped chars (\*) unless `verbatim` is true
-- Non-verbatim delimiters cannot match across line boundaries
-- Returns position of closing delimiter, or nil if not found
local function scan_for_close(content, start, close_delim, verbatim)
    local len = #content
    local dlen = #close_delim
    local pos = start
    while pos <= len - dlen + 1 do
        if not verbatim and content:sub(pos, pos) == "\\" then
            pos = pos + 2 -- skip escaped char
        elseif not verbatim and content:sub(pos, pos) == "\n" then
            return nil -- non-verbatim delimiters don't cross lines
        elseif content:sub(pos, pos + dlen - 1) == close_delim then
            return pos
        else
            pos = pos + 1
        end
    end
    return nil
end

-- Pass 2: character-level scanner for a text segment
local function scan_inline(content, inline_rules)
    local children = {}
    local len = #content
    local pos = 1
    local text_start = 1

    local function flush_text(before)
        if before > text_start then
            children[#children + 1] = { flavor = "text", content = content:sub(text_start, before - 1) }
        end
    end

    while pos <= len do
        -- Skip escaped characters
        if content:sub(pos, pos) == "\\" and pos < len then
            pos = pos + 2
            goto continue
        end

        local matched = false
        for _, rule in ipairs(inline_rules) do
            if rule.fallback or rule.self_contained then
                goto next_rule
            end

            -- Pattern rule (links, etc.)
            if rule.pattern then
                local s, e, c1, c2, c3, c4 = content:find(rule.pattern, pos)
                if s == pos then
                    flush_text(pos)
                    local caps = { c1, c2, c3, c4 }
                    local child = { flavor = rule.flavor, content = c1 or "", captures = {} }
                    if rule.capture then
                        for name, idx in pairs(rule.capture) do
                            if caps[idx] then
                                child.captures[name] = caps[idx]
                            end
                        end
                        -- Use "text" capture as content if available
                        if child.captures.text then
                            child.content = child.captures.text
                        end
                    end
                    children[#children + 1] = child
                    pos = e + 1
                    text_start = pos
                    matched = true
                    break
                end
            end

            -- Start/end delimiter rule
            if rule.start then
                local slen = rule._start_len or #rule.start
                if content:sub(pos, pos + slen - 1) == rule.start then
                    local inner_start = pos + slen
                    local close_pos = scan_for_close(content, inner_start, rule["end"], rule.verbatim)
                    if close_pos then
                        flush_text(pos)
                        local elen = rule._end_len or #rule["end"]
                        local inner = content:sub(inner_start, close_pos - 1)
                        local child = {
                            flavor = rule.flavor,
                            content = inner,
                            captures = {},
                        }
                        -- Recursively scan inner content for non-verbatim rules
                        if not rule.verbatim and #inner > 0 then
                            local inner_children = scan_inline(inner, inline_rules)
                            -- Only attach if refinement found something beyond plain text
                            if #inner_children > 1
                                or (#inner_children == 1 and inner_children[1].flavor ~= "text")
                            then
                                child.children = inner_children
                            end
                        end
                        children[#children + 1] = child
                        pos = close_pos + elen
                        text_start = pos
                        matched = true
                        break
                    end
                end
            end

            ::next_rule::
        end

        if not matched then
            pos = pos + 1
        end

        ::continue::
    end

    -- Flush trailing text
    flush_text(len + 1)
    return children
end

-- Two-pass inline refinement for a text chunk
local function refine_inline(content, inline_rules)
    -- Collect self_contained line-level rules and character-level rules
    local line_rules = {}
    local char_rules = {}
    for _, rule in ipairs(inline_rules) do
        if rule.self_contained and rule.patterns then
            line_rules[#line_rules + 1] = rule
        else
            char_rules[#char_rules + 1] = rule
        end
    end

    local children = {}
    local text_lines = {}

    local function flush_text_lines()
        if #text_lines > 0 then
            local segment = table.concat(text_lines, "\n")
            if #char_rules > 0 then
                local inline_children = scan_inline(segment, char_rules)
                for _, child in ipairs(inline_children) do
                    children[#children + 1] = child
                end
            else
                children[#children + 1] = { flavor = "text", content = segment }
            end
            text_lines = {}
        end
    end

    -- Pass 1: line-level rules (headings)
    local lines = {}
    for line in (content .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = line
    end

    for _, line in ipairs(lines) do
        local matched = false
        for _, rule in ipairs(line_rules) do
            for _, pat in ipairs(rule._matchers or rule.patterns) do
                local caps = { line:match(pat) }
                if #caps > 0 then
                    flush_text_lines()
                    local child = { flavor = rule.flavor, content = line, captures = {} }
                    if rule.capture then
                        for name, idx in pairs(rule.capture) do
                            if caps[idx] then
                                child.captures[name] = caps[idx]
                            end
                        end
                        if child.captures.text then
                            child.content = child.captures.text
                        end
                    end
                    children[#children + 1] = child
                    matched = true
                    break
                end
            end
            if matched then
                break
            end
        end
        if not matched then
            text_lines[#text_lines + 1] = line
        end
    end
    flush_text_lines()

    -- If refinement produced nothing useful, return nil
    if #children == 0 then
        return nil
    end
    -- If only one text child covering everything, no point wrapping
    if #children == 1 and children[1].flavor == "text" and children[1].content == content then
        return nil
    end

    return children
end

function M.parse(lines, rules, inline_rules)
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
            elseif block_end_pat and line:match(block_end_pat) then
                -- End delimiter matched — flush block WITHOUT this line
                flush_block(i)
                state = "SEEKING"
                goto continue -- delimiter consumed, do not reprocess
            elseif block_rule._continue then
                if match_continue(line, block_rule) then
                    block_buf[#block_buf + 1] = line
                    goto continue
                else
                    -- Line doesn't match continue — flush block, reprocess line
                    flush_block(i - 1)
                    state = "SEEKING"
                    -- Fall through to SEEKING to reprocess this line
                end
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

                -- Self-contained rules (hr, figure, latex_cmd, etc.)
                if rule.self_contained then
                    local matchers = rule._matchers or rule.patterns
                    if matchers then
                        for _, pat in ipairs(matchers) do
                            local caps = { line:match(pat) }
                            if #caps > 0 then
                                flush_text(i)
                                chunk_id = chunk_id + 1
                                chunks[#chunks + 1] = {
                                    id = chunk_id,
                                    flavor = rule.flavor,
                                    content = line,
                                    start_line = i,
                                    end_line = i,
                                    captures = rule.capture and extract_captures(rule, caps) or {},
                                }
                                matched = true
                                break
                            end
                        end
                    end
                    if matched then
                        break
                    end
                    goto next_rule
                end

                -- Block rules (have start/end)
                if rule.start then
                    local caps = match_start(line, rule)
                    if caps and #caps > 0 then
                        -- Verify: peek forward to confirm end delimiter exists
                        if rule.verify and rule._end then
                            local end_pat = build_end_pattern(rule, caps)
                            local limit = rule.max_size and math.min(i + rule.max_size, #lines) or #lines
                            local found = false
                            for j = i + 1, limit do
                                if lines[j]:match(end_pat) then
                                    found = true
                                    break
                                end
                            end
                            if not found then
                                goto next_rule
                            end
                        end

                        flush_text(i)
                        block_start = i
                        block_rule = rule
                        block_captures = extract_captures(rule, caps)
                        block_end_pat = rule._end and build_end_pattern(rule, caps) or nil
                        block_line_count = 0
                        if rule._continue then
                            -- Continue-based blocks include start line in content
                            block_buf = { line }
                        else
                            block_buf = {}
                        end
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

    -- Inline refinement pass
    if inline_rules and #inline_rules > 0 then
        local refine_flavors = { text = true, ulist = true, olist = true, table = true }
        for _, chunk in ipairs(chunks) do
            if refine_flavors[chunk.flavor] then
                chunk.children = refine_inline(chunk.content, inline_rules)
            end
        end
    end

    return chunks, settings
end

function M.process(filepath, cfg)
    local lines = read_lines(filepath)
    local chunks, settings = M.parse(lines, cfg.rules, cfg.inline_rules)
    return { chunks = chunks, settings = settings }
end

return M
