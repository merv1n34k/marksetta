-- Config loader: defaults, JSON user config, merge, freeze
-- Follows F.A.C.E.: E-layer loaded once, cached aggressively

local json = require("json")

local M = {}

M.defaults = {
    rules = {
        {
            patterns = { "^#@" },
            flavor = "settings",
            internal = true,
        },
        {
            flavor = "yaml",
            start = "^---$",
            ["end"] = "^---$",
            context = { position = "start", max_line = 10 },
            max_size = 50,
        },
        {
            patterns = { "^%-%-%s", "^%-%-$" },
            flavor = "comments",
            internal = true,
        },
        {
            flavor = "code",
            start = "^```(%w*)",
            ["end"] = "^```$",
            capture = { language = 1 },
            max_size = 200,
        },
        {
            flavor = "math",
            start = "^%$%$$",
            ["end"] = "^%$%$$",
            max_size = 40,
        },
        {
            flavor = "env",
            start = "\\begin{(%w+)}",
            ["end"] = "\\end{({1})}",
            capture = { name = 1 },
            max_size = 100,
        },
        {
            flavor = "hr",
            patterns = { "^---$", "^%*%*%*$", "^___$" },
            context = { not_at = "start" },
            self_contained = true,
        },
        {
            flavor = "text",
            fallback = true,
        },
    },
    inline_rules = {
        {
            flavor = "heading",
            patterns = { "^(#+)%s+(.+)$" },
            self_contained = true,
            capture = { level = 1, text = 2 },
        },
        { flavor = "link", pattern = "%[(.-)%]%((.-)%)", capture = { text = 1, url = 2 } },
        { flavor = "code_inline", start = "`", ["end"] = "`", verbatim = true },
        { flavor = "bold", start = "**", ["end"] = "**" },
        { flavor = "italic", start = "*", ["end"] = "*" },
        { flavor = "math_inline", start = "$", ["end"] = "$" },
        { flavor = "text", fallback = true },
    },
    inline_emit = {
        tex = {
            text = "{content}",
            bold = "\\textbf{{content}}",
            italic = "\\emph{{content}}",
            math_inline = "${content}$",
            code_inline = "\\texttt{{content}}",
            link = "\\href{{url}}{{content}}",
            heading = {
                "\\section{{content}}",
                "\\subsection{{content}}",
                "\\subsubsection{{content}}",
                "\\paragraph{{content}}",
            },
        },
        md = {
            text = "{content}",
            bold = "**{content}**",
            italic = "*{content}*",
            math_inline = "${content}$",
            code_inline = "`{content}`",
            link = "[{content}]({url})",
            heading = { "# {content}", "## {content}", "### {content}", "#### {content}" },
        },
    },
    outputs = {},
    watch = { debounce_ms = 50, neighbors = 1 },
    internal = { include = {} },
}

local function find_config()
    local paths = {
        ".marksetta.json",
        os.getenv("HOME") .. "/.config/marksetta/config.json",
    }
    for _, path in ipairs(paths) do
        local f = io.open(path, "r")
        if f then
            f:close()
            return path
        end
    end
    return nil
end

local function load_json(path)
    local f = assert(io.open(path, "r"))
    local content = f:read("*a")
    f:close()
    return json.decode(content)
end

local function deep_merge(base, override)
    local result = {}
    for k, v in pairs(base) do
        result[k] = v
    end
    for k, v in pairs(override) do
        if type(v) == "table" and type(result[k]) == "table" then
            result[k] = deep_merge(result[k], v)
        else
            result[k] = v
        end
    end
    return result
end

local function assign_priorities(rules)
    local counter = 0
    for _, rule in ipairs(rules) do
        if not rule.priority then
            counter = counter + 1
            rule.priority = counter
        else
            counter = rule.priority
        end
    end
    -- Stable sort by priority
    local indexed = {}
    for i, rule in ipairs(rules) do
        indexed[i] = { idx = i, rule = rule }
    end
    table.sort(indexed, function(a, b)
        if a.rule.priority == b.rule.priority then
            return a.idx < b.idx
        end
        return a.rule.priority < b.rule.priority
    end)
    local sorted = {}
    for i, entry in ipairs(indexed) do
        sorted[i] = entry.rule
    end
    return sorted
end

local function compile_rules(rules)
    rules = assign_priorities(rules)
    for _, rule in ipairs(rules) do
        if rule.patterns then
            rule._matchers = {}
            for _, pat in ipairs(rule.patterns) do
                rule._matchers[#rule._matchers + 1] = pat
            end
        end
        if rule.start then
            rule._start = rule.start
        end
        if rule["end"] then
            rule._end = rule["end"]
        end
    end
    return rules
end

local function compile_inline_rules(rules)
    rules = assign_priorities(rules)
    for _, rule in ipairs(rules) do
        if rule.start then
            rule._start_len = #rule.start
        end
        if rule["end"] then
            rule._end_len = #rule["end"]
        end
        if rule.patterns then
            rule._matchers = {}
            for _, pat in ipairs(rule.patterns) do
                rule._matchers[#rule._matchers + 1] = pat
            end
        end
    end
    return rules
end

local function freeze(t)
    local proxy = {}
    local mt = {
        __index = t,
        __newindex = function()
            error("attempt to modify frozen config")
        end,
        __pairs = function()
            return next, t, nil
        end,
        __len = function()
            return #t
        end,
    }
    setmetatable(proxy, mt)
    return proxy
end

function M.load(opts)
    opts = opts or {}
    local cfg = M.defaults

    if not opts.no_file then
        local path = opts.config_path or find_config()
        if path then
            local user_cfg = load_json(path)
            cfg = deep_merge(cfg, user_cfg)
        end
    end

    if opts.outputs then
        cfg.outputs = opts.outputs
    end

    cfg.rules = compile_rules(cfg.rules)
    cfg.inline_rules = compile_inline_rules(cfg.inline_rules)

    return freeze(cfg)
end

return M
