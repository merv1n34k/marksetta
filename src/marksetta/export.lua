-- Export module: profile-based handler dispatch
-- nvim-style flat registration: profile() returns a handler setter
--
-- local tex = M.profile("tex", { preamble = ..., postamble = ... })
-- tex("text", function(chunk, ctx) ... end)
-- tex("math", function(chunk, ctx) ... end)
-- tex("*", function(chunk, ctx) ... end)  -- fallback

local M = {}

M._profiles = {}

-- Interpolate {content}, {url}, etc. from child data
local function interpolate(template, child)
    return template:gsub("{(%w+)}", function(key)
        if key == "content" then
            return child.content or ""
        end
        return child.captures and child.captures[key] or ""
    end)
end

-- Inline emitter driven by templates
local function emit_inline(children, templates)
    if not templates then
        return nil
    end
    local buf = {}
    for _, child in ipairs(children) do
        local tmpl = templates[child.flavor]
        if tmpl then
            if type(tmpl) == "table" then
                local level = child.captures and child.captures.level
                local n = level and #level or 1
                tmpl = tmpl[n] or tmpl[#tmpl]
            end
            buf[#buf + 1] = interpolate(tmpl, child)
        end
    end
    return table.concat(buf)
end

-- Context constructor
-- ctx:emit(line)           — append line to output buffer
-- ctx:inline(children)     — render inline children → string
-- ctx:lines(content, pfx)  — emit each line with optional prefix
-- ctx.config               — format-specific config table
local function make_ctx(buf, config, inline_templates)
    local ctx = {
        buf = buf,
        config = config or {},
    }

    function ctx:emit(line)
        self.buf[#self.buf + 1] = line
    end

    function ctx:inline(children)
        return emit_inline(children, inline_templates)
    end

    function ctx:lines(content, prefix)
        prefix = prefix or ""
        for line in content:gmatch("[^\n]+") do
            self.buf[#self.buf + 1] = prefix .. line
        end
    end

    return ctx
end

-- Find handler: exact → glob → fallback (*)
local function find_handler(handlers, flavor)
    if handlers[flavor] then
        return handlers[flavor]
    end
    for pattern, handler in pairs(handlers) do
        if pattern ~= "*" and pattern:sub(-1) == "*" then
            local prefix = pattern:sub(1, -2)
            if flavor:sub(1, #prefix) == prefix then
                return handler
            end
        end
    end
    return handlers["*"]
end

-- Emit preamble or postamble (string or function)
local function emit_bookend(bookend, ctx)
    if not bookend then
        return
    end
    if type(bookend) == "function" then
        bookend(ctx)
    else
        ctx:emit(bookend)
    end
end

-- Register a format profile, return handler setter
-- opts: { preamble = string|fn, postamble = string|fn }
function M.profile(format, opts)
    opts = opts or {}
    M._profiles[format] = {
        preamble = opts.preamble,
        postamble = opts.postamble,
        handlers = {},
    }

    -- Return registration function: tex("flavor", handler)
    return function(flavor, handler)
        M._profiles[format].handlers[flavor] = handler
    end
end

-- Generic emit: profile lookup → preamble → handlers → postamble
function M.emit(chunks, format, format_config, inline_emit)
    local profile = M._profiles[format]
    if not profile then
        error("unknown output format: " .. tostring(format))
    end

    local buf = {}
    local inline_templates = inline_emit and inline_emit[format]
    local ctx = make_ctx(buf, format_config, inline_templates)

    emit_bookend(profile.preamble, ctx)

    for _, chunk in ipairs(chunks) do
        local handler = find_handler(profile.handlers, chunk.flavor)
        if handler then
            handler(chunk, ctx)
        end
    end

    emit_bookend(profile.postamble, ctx)

    return table.concat(buf, "\n")
end

---------------------------------------------------------------------------
-- Default profiles
---------------------------------------------------------------------------

local tex = M.profile("tex", {
    preamble = function(ctx)
        local cfg = ctx.config
        if cfg.preamble then
            ctx:emit(cfg.preamble)
        else
            ctx:emit("\\documentclass{" .. (cfg.document_class or "article") .. "}")
            if cfg.packages then
                for _, pkg in ipairs(cfg.packages) do
                    ctx:emit("\\usepackage{" .. pkg .. "}")
                end
            end
            ctx:emit("\\begin{document}")
        end
    end,
    postamble = function(ctx)
        local cfg = ctx.config
        if cfg.postamble then
            ctx:emit(cfg.postamble)
        else
            ctx:emit("")
            ctx:emit("\\end{document}")
        end
    end,
})

tex("text", function(chunk, ctx)
    ctx:emit("")
    if chunk.children then
        ctx:emit(ctx:inline(chunk.children))
    else
        ctx:emit(chunk.content)
    end
end)

tex("math", function(chunk, ctx)
    ctx:emit("")
    ctx:emit("\\[")
    ctx:emit(chunk.content)
    ctx:emit("\\]")
end)

tex("code", function(chunk, ctx)
    local lang = chunk.captures and chunk.captures.language
    if lang and lang ~= "" then
        ctx:emit("")
        ctx:emit("% language: " .. lang)
    end
    ctx:emit("\\begin{verbatim}")
    ctx:emit(chunk.content)
    ctx:emit("\\end{verbatim}")
end)

tex("hr", function(chunk, ctx)
    ctx:emit("")
    ctx:emit("\\noindent\\rule{\\textwidth}{0.4pt}")
end)

tex("env:*", function(chunk, ctx)
    local env_name = chunk.flavor:sub(5)
    ctx:emit("")
    ctx:emit("\\begin{" .. env_name .. "}")
    ctx:emit(chunk.content)
    ctx:emit("\\end{" .. env_name .. "}")
end)

tex("yaml", function(chunk, ctx)
    ctx:emit("")
    ctx:emit("% --- yaml metadata ---")
    ctx:lines(chunk.content, "% ")
    ctx:emit("% --- end yaml ---")
end)

tex("table", function(chunk, ctx)
    local rows = {}
    for line in (chunk.content .. "\n"):gmatch("([^\n]*)\n") do
        if line ~= "" then
            rows[#rows + 1] = line
        end
    end
    if #rows < 2 then
        ctx:emit(chunk.content)
        return
    end

    -- Parse cells from a pipe-table row
    local function parse_row(row)
        local cells = {}
        -- Strip leading/trailing pipes and split
        row = row:match("^|?(.-)%s*|?$") or row
        for cell in row:gmatch("([^|]+)") do
            cells[#cells + 1] = cell:match("^%s*(.-)%s*$")
        end
        return cells
    end

    local header = parse_row(rows[1])
    local ncols = #header

    -- Detect separator row and alignment
    local aligns = {}
    local sep_row = rows[2]
    local sep_cells = parse_row(sep_row)
    local has_sep = true
    for _, cell in ipairs(sep_cells) do
        local trimmed = cell:match("^%s*(.-)%s*$")
        if not trimmed:match("^:?%-+:?$") then
            has_sep = false
            break
        end
        if trimmed:match("^:.*:$") then
            aligns[#aligns + 1] = "c"
        elseif trimmed:match(":$") then
            aligns[#aligns + 1] = "r"
        else
            aligns[#aligns + 1] = "l"
        end
    end
    if not has_sep then
        aligns = {}
        for _ = 1, ncols do
            aligns[#aligns + 1] = "l"
        end
    end

    local col_spec = table.concat(aligns, " ")

    ctx:emit("")
    ctx:emit("\\begin{tabular}{" .. col_spec .. "}")
    ctx:emit("\\hline")

    -- Header
    ctx:emit(table.concat(header, " & ") .. " \\\\ \\hline")

    -- Data rows (skip separator)
    local data_start = has_sep and 3 or 2
    for r = data_start, #rows do
        local cells = parse_row(rows[r])
        ctx:emit(table.concat(cells, " & ") .. " \\\\")
    end

    ctx:emit("\\hline")
    ctx:emit("\\end{tabular}")
end)

tex("figure", function(chunk, ctx)
    local cap = chunk.captures.caption or ""
    local path = chunk.captures.path or ""
    local opts_str = chunk.captures.opts or ""

    -- Parse {key=value} options or default to width=\textwidth
    local graphic_opts = "width=\\textwidth"
    local opt_inner = opts_str:match("{(.-)}")
    if opt_inner and opt_inner ~= "" then
        graphic_opts = opt_inner
    end

    ctx:emit("")
    ctx:emit("\\begin{figure}[htbp]")
    ctx:emit("\\centering")
    ctx:emit("\\includegraphics[" .. graphic_opts .. "]{" .. path .. "}")
    if cap ~= "" then
        ctx:emit("\\caption{" .. cap .. "}")
    end
    ctx:emit("\\end{figure}")
end)

tex("ulist", function(chunk, ctx)
    ctx:emit("")
    ctx:emit("\\begin{itemize}")
    local current_item = nil
    for line in (chunk.content .. "\n"):gmatch("([^\n]*)\n") do
        local item_text = line:match("^[%-%*]%s+(.+)$")
        if item_text then
            if current_item then
                ctx:emit("\\item " .. current_item)
            end
            current_item = item_text
        elseif current_item then
            -- Continuation line
            local cont = line:match("^%s+(.+)$")
            if cont then
                current_item = current_item .. " " .. cont
            end
        end
    end
    if current_item then
        ctx:emit("\\item " .. current_item)
    end
    ctx:emit("\\end{itemize}")
end)

tex("olist", function(chunk, ctx)
    ctx:emit("")
    ctx:emit("\\begin{enumerate}")
    local current_item = nil
    for line in (chunk.content .. "\n"):gmatch("([^\n]*)\n") do
        local item_text = line:match("^%d+[%.%)]%s+(.+)$")
        if item_text then
            if current_item then
                ctx:emit("\\item " .. current_item)
            end
            current_item = item_text
        elseif current_item then
            local cont = line:match("^%s+(.+)$")
            if cont then
                current_item = current_item .. " " .. cont
            end
        end
    end
    if current_item then
        ctx:emit("\\item " .. current_item)
    end
    ctx:emit("\\end{enumerate}")
end)

tex("latex_cmd", function(chunk, ctx)
    ctx:emit(chunk.content)
end)

---------------------------------------------------------------------------

local md = M.profile("md")

md("text", function(chunk, ctx)
    if chunk.children then
        ctx:emit(ctx:inline(chunk.children))
    else
        ctx:emit(chunk.content)
    end
    ctx:emit("")
end)

md("math", function(chunk, ctx)
    ctx:emit("$$")
    ctx:emit(chunk.content)
    ctx:emit("$$")
    ctx:emit("")
end)

md("code", function(chunk, ctx)
    local lang = chunk.captures and chunk.captures.language or ""
    ctx:emit("```" .. lang)
    ctx:emit(chunk.content)
    ctx:emit("```")
    ctx:emit("")
end)

md("hr", function(chunk, ctx)
    ctx:emit("---")
    ctx:emit("")
end)

md("yaml", function(chunk, ctx)
    ctx:emit("---")
    ctx:emit(chunk.content)
    ctx:emit("---")
    ctx:emit("")
end)

md("env:*", function(chunk, ctx)
    local env_name = chunk.flavor:sub(5)
    ctx:emit("\\begin{" .. env_name .. "}")
    ctx:emit(chunk.content)
    ctx:emit("\\end{" .. env_name .. "}")
    ctx:emit("")
end)

md("table", function(chunk, ctx)
    ctx:emit(chunk.content)
    ctx:emit("")
end)

md("figure", function(chunk, ctx)
    local cap = chunk.captures.caption or ""
    local path = chunk.captures.path or ""
    ctx:emit("![" .. cap .. "](" .. path .. ")")
    ctx:emit("")
end)

md("ulist", function(chunk, ctx)
    ctx:emit(chunk.content)
    ctx:emit("")
end)

md("olist", function(chunk, ctx)
    ctx:emit(chunk.content)
    ctx:emit("")
end)

md("latex_cmd", function(chunk, ctx)
    -- LaTeX commands are skipped in markdown output
end)

return M
