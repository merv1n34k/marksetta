#!/usr/bin/env lua

-- Marksetta: real-time embedded preprocessor for .mx files
-- Pipeline: config → import → internal state → filter → export → write

local config = require("config")
local import = require("import")
local internal = require("internal")
local export = require("export")

local function log(lvl, msg)
    io.stderr:write("[" .. lvl .. "] " .. msg .. "\n")
end

local function parse_args(args)
    local opts = {
        input = nil,
        outputs = {},
        verbose = false,
    }

    local i = 1
    while i <= #args do
        local a = args[i]
        if a == "-o" then
            i = i + 1
            local spec = args[i]
            if not spec then
                log("error", "-o requires format:path argument")
                os.exit(1)
            end
            -- Parse "tex:out.tex" or "md:out.md"
            local fmt, path = spec:match("^(%w+):(.+)$")
            if fmt and path then
                opts.outputs[path] = { format = fmt }
            else
                log("error", "invalid -o format, expected format:path (e.g. tex:out.tex)")
                os.exit(1)
            end
        elseif a == "-v" or a == "--verbose" then
            opts.verbose = true
        elseif a:sub(1, 1) ~= "-" then
            opts.input = a
        else
            log("error", "unknown option: " .. a)
            os.exit(1)
        end
        i = i + 1
    end

    return opts
end

local function parse_output_spec(spec)
    -- Parse shorthand: "tex{text,math,env:*}" → { format = "tex", include = {"text","math","env:*"} }
    local fmt, flavors_str = spec:match("^(%w+){(.+)}$")
    if fmt and flavors_str then
        local include = {}
        for flav in flavors_str:gmatch("[^,]+") do
            include[#include + 1] = flav:match("^%s*(.-)%s*$")
        end
        return { format = fmt, include = include }
    end
    -- Plain format name → include all
    return { format = spec, include = { "*" } }
end

local function atomic_write(path, content)
    local tmp = path .. ".tmp." .. os.time()
    local f = assert(io.open(tmp, "w"))
    f:write(content)
    f:close()
    os.rename(tmp, path)
end

local function main()
    local cli = parse_args(arg or {})

    if not cli.input then
        log("error", "usage: marksetta <input.mx> [-o format:path] [-v]")
        os.exit(1)
    end

    -- 1. Load config
    local cfg = config.load({ no_file = false })

    -- 2. Build output table: CLI overrides > config > defaults
    local outputs = {}
    if next(cli.outputs) then
        -- CLI -o flags take precedence
        for path, out in pairs(cli.outputs) do
            outputs[path] = { format = out.format, include = { "*" } }
        end
    else
        -- From config
        for path, spec in pairs(cfg.outputs) do
            if type(spec) == "string" then
                outputs[path] = parse_output_spec(spec)
            elseif type(spec) == "table" then
                outputs[path] = spec
            end
        end
    end

    -- If no outputs defined at all, default to tex on stdout
    if not next(outputs) then
        outputs["stdout"] = { format = "tex", include = { "*" } }
    end

    -- 3. Import: read + parse
    if cli.verbose then
        log("info", "reading " .. cli.input)
    end
    local result = import.process(cli.input, cfg)

    if cli.verbose then
        log("info", "parsed " .. #result.chunks .. " chunks")
        for _, c in ipairs(result.chunks) do
            log(
                "debug",
                string.format(
                    "  chunk #%d [%s] lines %d-%d (%d chars)",
                    c.id,
                    c.flavor,
                    c.start_line,
                    c.end_line,
                    #c.content
                )
            )
        end
        if next(result.settings) then
            log("info", "settings:")
            for k, v in pairs(result.settings) do
                log("debug", "  " .. k .. " = " .. v)
            end
        end
    end

    -- 4. Create internal state
    local state = internal.new(result.chunks, result.settings)

    -- 5. For each output: filter + export + write
    for path, profile in pairs(outputs) do
        local filtered = internal.filter(state, profile)
        local format_config = cfg[profile.format] or {}

        if cli.verbose then
            log("info", string.format("export %s → %s (%d chunks)", profile.format, path, #filtered))
        end

        local output = export.emit(filtered, profile.format, format_config)

        if path == "stdout" then
            print(output)
        else
            atomic_write(path, output)
            if cli.verbose then
                log("info", "wrote " .. path)
            end
        end
    end
end

main()
