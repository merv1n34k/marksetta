#!/usr/bin/env lua

-- Marksetta: real-time embedded preprocessor for .mx files
-- Pipeline: config → import → internal state → filter → export → write

local config = require("marksetta.config")
local import = require("marksetta.import")
local internal = require("marksetta.internal")
local export = require("marksetta.export")

local function log(lvl, msg)
    io.stderr:write("[" .. lvl .. "] " .. msg .. "\n")
end

local function parse_args(args)
    local opts = {
        input = nil,
        outputs = {},
        verbose = false,
        watch = false,
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
        elseif a == "-w" or a == "--watch" then
            opts.watch = true
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

    -- Run pipeline once
    local function run_pipeline()
        local t0 = os.clock()

        -- Import: read + parse
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
                if c.children then
                    for j, child in ipairs(c.children) do
                        log("debug", string.format("    child #%d [%s] %q", j, child.flavor, child.content))
                    end
                end
            end
        end

        -- Internal state + export
        local state = internal.new(result.chunks, result.settings)

        for path, profile in pairs(outputs) do
            local filtered = internal.filter(state, profile)
            local format_config = cfg[profile.format] or {}
            local output = export.emit(filtered, profile.format, format_config, cfg.inline_emit)

            if path == "stdout" then
                print(output)
            else
                atomic_write(path, output)
            end
        end

        local elapsed = (os.clock() - t0) * 1000
        return elapsed, #result.chunks
    end

    if not cli.watch then
        -- One-shot mode
        if cli.verbose then
            log("info", "reading " .. cli.input)
        end
        local elapsed, n = run_pipeline()
        if cli.verbose then
            log("info", string.format("done in %.1fms (%d chunks)", elapsed, n))
        end
    else
        -- Watch mode: poll mtime, rerun on change
        local debounce = (cfg.watch and cfg.watch.debounce_ms or 50) / 1000
        local poll_interval = debounce

        local function read_file(path)
            local f = io.open(path, "r")
            if not f then
                return nil
            end
            local content = f:read("*a")
            f:close()
            return content
        end

        log("info", "watching " .. cli.input .. " (poll " .. math.floor(debounce * 1000) .. "ms)")
        local out_list = {}
        for path, profile in pairs(outputs) do
            out_list[#out_list + 1] = profile.format .. ":" .. path
        end
        log("info", "outputs: " .. table.concat(out_list, ", "))

        -- Initial run
        local elapsed, n = run_pipeline()
        log("info", string.format("ready — %d chunks in %.1fms", n, elapsed))

        local last_content = read_file(cli.input)

        -- Set up sleep: prefer ffi usleep, fallback to os.execute
        local sleep
        local ffi_ok, ffi = pcall(require, "ffi")
        if ffi_ok then
            pcall(ffi.cdef, "int usleep(unsigned int usec);")
            sleep = function(sec)
                ffi.C.usleep(math.floor(sec * 1000000))
            end
        else
            sleep = function(sec)
                os.execute("sleep " .. sec)
            end
        end

        while true do
            sleep(poll_interval)

            local content = read_file(cli.input)
            if content and content ~= last_content then
                last_content = content
                local run_ok, err = pcall(function()
                    elapsed, n = run_pipeline()
                end)
                if run_ok then
                    log("info", string.format("rebuilt — %d chunks in %.1fms", n, elapsed))
                else
                    log("error", tostring(err))
                end
            end
        end
    end
end

main()
