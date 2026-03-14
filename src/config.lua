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

local function compile_rules(rules)
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

    compile_rules(cfg.rules)

    return freeze(cfg)
end

return M
