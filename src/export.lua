-- Export module: format dispatch + emitters
-- Uses string buffer (table.concat) for performance

local M = {}

-- Interpolate {content}, {url}, etc. from child data
local function interpolate(template, child)
    return template:gsub("{(%w+)}", function(key)
        if key == "content" then
            return child.content or ""
        end
        return child.captures and child.captures[key] or ""
    end)
end

-- Generic inline emitter driven by templates
local function emit_inline(children, templates)
    if not templates then
        return nil
    end
    local buf = {}
    for _, child in ipairs(children) do
        local tmpl = templates[child.flavor]
        if tmpl then
            if type(tmpl) == "table" then
                -- Array indexed by level (headings)
                local level = child.captures and child.captures.level
                local n = level and #level or 1
                tmpl = tmpl[n] or tmpl[#tmpl]
            end
            buf[#buf + 1] = interpolate(tmpl, child)
        end
    end
    return table.concat(buf)
end

-- Tex emitter
function M.emit_tex(chunks, config)
    config = config or {}
    local buf = {}

    -- Preamble
    local doc_class = config.document_class or "article"
    local preamble = config.preamble
    if preamble then
        buf[#buf + 1] = preamble
    else
        buf[#buf + 1] = "\\documentclass{" .. doc_class .. "}"
        if config.packages then
            for _, pkg in ipairs(config.packages) do
                buf[#buf + 1] = "\\usepackage{" .. pkg .. "}"
            end
        end
        buf[#buf + 1] = "\\begin{document}"
    end

    -- Chunks
    for _, chunk in ipairs(chunks) do
        local flavor = chunk.flavor
        local content = chunk.content

        if flavor == "text" then
            buf[#buf + 1] = ""
            if chunk.children then
                buf[#buf + 1] = emit_inline(chunk.children, config.inline_templates)
            else
                buf[#buf + 1] = content
            end
        elseif flavor == "math" then
            buf[#buf + 1] = ""
            buf[#buf + 1] = "\\["
            buf[#buf + 1] = content
            buf[#buf + 1] = "\\]"
        elseif flavor == "code" then
            local lang = chunk.captures and chunk.captures.language
            if lang and lang ~= "" then
                buf[#buf + 1] = ""
                buf[#buf + 1] = "% language: " .. lang
            end
            buf[#buf + 1] = "\\begin{verbatim}"
            buf[#buf + 1] = content
            buf[#buf + 1] = "\\end{verbatim}"
        elseif flavor == "hr" then
            buf[#buf + 1] = ""
            buf[#buf + 1] = "\\noindent\\rule{\\textwidth}{0.4pt}"
        elseif flavor:sub(1, 4) == "env:" then
            local env_name = flavor:sub(5)
            buf[#buf + 1] = ""
            buf[#buf + 1] = "\\begin{" .. env_name .. "}"
            buf[#buf + 1] = content
            buf[#buf + 1] = "\\end{" .. env_name .. "}"
        elseif flavor == "yaml" then
            buf[#buf + 1] = ""
            buf[#buf + 1] = "% --- yaml metadata ---"
            for line in content:gmatch("[^\n]+") do
                buf[#buf + 1] = "% " .. line
            end
            buf[#buf + 1] = "% --- end yaml ---"
        end
    end

    -- Postamble
    local postamble = config.postamble
    if postamble then
        buf[#buf + 1] = postamble
    else
        buf[#buf + 1] = ""
        buf[#buf + 1] = "\\end{document}"
    end

    return table.concat(buf, "\n")
end

-- Markdown emitter (placeholder — pass-through for now)
function M.emit_md(chunks, config)
    local buf = {}
    for _, chunk in ipairs(chunks) do
        local flavor = chunk.flavor
        local content = chunk.content

        if flavor == "text" then
            if chunk.children then
                buf[#buf + 1] = emit_inline(chunk.children, config.inline_templates)
            else
                buf[#buf + 1] = content
            end
            buf[#buf + 1] = ""
        elseif flavor == "math" then
            buf[#buf + 1] = "$$"
            buf[#buf + 1] = content
            buf[#buf + 1] = "$$"
            buf[#buf + 1] = ""
        elseif flavor == "code" then
            local lang = chunk.captures and chunk.captures.language or ""
            buf[#buf + 1] = "```" .. lang
            buf[#buf + 1] = content
            buf[#buf + 1] = "```"
            buf[#buf + 1] = ""
        elseif flavor == "hr" then
            buf[#buf + 1] = "---"
            buf[#buf + 1] = ""
        elseif flavor == "yaml" then
            buf[#buf + 1] = "---"
            buf[#buf + 1] = content
            buf[#buf + 1] = "---"
            buf[#buf + 1] = ""
        elseif flavor:sub(1, 4) == "env:" then
            -- Pass through as-is for md
            local env_name = flavor:sub(5)
            buf[#buf + 1] = "\\begin{" .. env_name .. "}"
            buf[#buf + 1] = content
            buf[#buf + 1] = "\\end{" .. env_name .. "}"
            buf[#buf + 1] = ""
        end
    end
    return table.concat(buf, "\n")
end

M.emitters = {
    tex = M.emit_tex,
    md = M.emit_md,
}

function M.emit(chunks, format, format_config, inline_emit)
    local emitter = M.emitters[format]
    if not emitter then
        error("unknown output format: " .. tostring(format))
    end
    -- Inject inline templates for this format into config
    if inline_emit and inline_emit[format] then
        format_config = format_config or {}
        format_config.inline_templates = inline_emit[format]
    end
    return emitter(chunks, format_config)
end

return M
