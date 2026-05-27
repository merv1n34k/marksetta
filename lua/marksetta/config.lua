-- Config loader: defaults, JSON user config, merge, freeze
-- Follows F.A.C.E.: E-layer loaded once, cached aggressively

local json = require("marksetta.json")

local M = {}

M.defaults = {
    rules = {
        {
            patterns = { "^#@" },
            flavor = "settings",
            internal = true,
        },
        {
            patterns = { "^%-%-%s", "^%-%-$", "^%s*%%" },
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
            patterns = { "^%*%*%*$", "^___$", "^%-%-%-$" },
            self_contained = true,
        },
        {
            flavor = "table",
            start = "^|",
            continue = "^|",
            max_size = 200,
        },
        {
            flavor = "figure",
            patterns = { "^!%[(.-)%]%((.-)%)(.*)$" },
            self_contained = true,
            capture = { caption = 1, path = 2, opts = 3 },
        },
        {
            flavor = "ulist",
            start = "^[%-%*]%s+",
            continue = { "^[%-%*]%s+", "^%s+%S" },
            max_size = 200,
        },
        {
            flavor = "olist",
            start = "^%d+[%.%)]%s+",
            continue = { "^%d+[%.%)]%s+", "^%s+%S" },
            max_size = 200,
        },
        {
            flavor = "latex_cmd",
            patterns = { "^\\%a[%a%*]*%s*$" },
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
            patterns = { "^(#+)(%*?)%s+(.+)$" },
            self_contained = true,
            capture = { level = 1, star = 2, text = 3 },
        },
        { flavor = "link", pattern = "%[(.-)%]%((.-)%)", capture = { text = 1, url = 2 } },
        { flavor = "code_inline", start = "`", ["end"] = "`", verbatim = true },
        { flavor = "bold_italic", start = "***", ["end"] = "***" },
        { flavor = "bold_italic", start = "___", ["end"] = "___" },
        { flavor = "bold", start = "**", ["end"] = "**" },
        { flavor = "bold", start = "__", ["end"] = "__" },
        { flavor = "italic", start = "*", ["end"] = "*" },
        { flavor = "italic", start = "_", ["end"] = "_" },
        { flavor = "currency", pattern = "(~?)%$(%d[%d,%.]*[%w/^]*)", capture = { prefix = 1, text = 2 } },
        { flavor = "math_inline", start = "$", ["end"] = "$", verbatim = true },
        -- Trailing comment: `\s%\s` to end-of-line. Markdown-aware: a literal
        -- ` % ` sequence (space-percent-space) and everything after it on
        -- the same line is stripped from both md and tex output. Line-level
        -- comments (lines whose first non-whitespace char is `%`) are
        -- consumed by the block-level `comments` rule above.
        { flavor = "comment_inline", pattern = "%s%%%s[^\n]*" },
        -- Inline LaTeX command: matches `\name*?[opt]*{arg}*` opaquely.
        -- No name validation, no arity check — purely syntactic recognition.
        -- Sub-flavor `latex_cmd:<name>` is set automatically from `name`.
        {
            flavor = "latex_cmd",
            sequence = {
                { pattern = "\\([%a@]+)", capture = "name" },
                { pattern = "(%*)", capture = "star", rep = "?" },
                { pattern = "(%b[])", capture = "opts", rep = "*" },
                { pattern = "(%b{})", capture = "args", rep = "*" },
            },
        },
        { flavor = "tex_special", pattern = "([%%&#%$_])" },
        { flavor = "text", fallback = true },
    },
    inline_emit = {
        tex = {
            text = "{content}",
            bold_italic = "\\textbf{\\emph{{content}}}",
            bold = "\\textbf{{content}}",
            italic = "\\emph{{content}}",
            math_inline = "${content}$",
            code_inline = "\\texttt{{content}}",
            link = "\\href{{url}}{{content}}",
            tex_special = "\\{content}",
            currency = "{prefix}\\${content}",
            ["latex_cmd:*"] = "\\{name}{star}{opts|join}{args|join}",
            heading = {
                "\n\\section{star}{{content}}\n",
                "\n\\subsection{star}{{content}}\n",
                "\n\\subsubsection{star}{{content}}\n",
                "\n\\paragraph{{content}}\n",
            },
        },
        md = {
            text = "{content}",
            bold_italic = "***{content}***",
            bold = "**{content}**",
            italic = "*{content}*",
            math_inline = "${content}$",
            code_inline = "`{content}`",
            link = "[{content}]({url})",
            tex_special = "{content}",
            currency = "{prefix}${content}",
            -- Verbatim passthrough for any LaTeX command marksetta doesn't
            -- know a markdown equivalent for. Specific names below override
            -- this via exact-match lookup priority.
            ["latex_cmd:*"] = "\\{name}{star}{opts|join}{args|join}",
            -- Canonical md translations for common commands.
            ["latex_cmd:textbf"] = "**{args.1|strip}**",
            ["latex_cmd:textsf"] = "**{args.1|strip}**",
            ["latex_cmd:emph"] = "*{args.1|strip}*",
            ["latex_cmd:textit"] = "*{args.1|strip}*",
            ["latex_cmd:textsl"] = "*{args.1|strip}*",
            ["latex_cmd:texttt"] = "`{args.1|strip}`",
            ["latex_cmd:verb"] = "`{args.1|strip}`",
            ["latex_cmd:underline"] = "<u>{args.1|strip}</u>",
            ["latex_cmd:section"] = "\n# {args.1|strip}\n",
            ["latex_cmd:subsection"] = "\n## {args.1|strip}\n",
            ["latex_cmd:subsubsection"] = "\n### {args.1|strip}\n",
            ["latex_cmd:paragraph"] = "\n**{args.1|strip}**\n",
            ["latex_cmd:subparagraph"] = "\n*{args.1|strip}*\n",
            ["latex_cmd:href"] = "[{args.2|strip}]({args.1|strip})",
            ["latex_cmd:url"] = "<{args.1|strip}>",
            heading = { "\n# {content}\n", "\n## {content}\n", "\n### {content}\n", "\n#### {content}\n" },
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
        if rule.continue then
            if type(rule.continue) == "string" then
                rule._continue = { rule.continue }
            else
                rule._continue = rule.continue
            end
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
