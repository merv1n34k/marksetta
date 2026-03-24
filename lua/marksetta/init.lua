-- Marksetta: public API
-- require("marksetta").compile(lines, opts)  — programmatic use

local config = require("marksetta.config")
local import = require("marksetta.import")
local internal = require("marksetta.internal")
local export = require("marksetta.export")

local M = {}

-- Expose submodules for external consumers (e.g., marksetta.nvim)
M.config = config
M.import = import
M.internal = internal
M.export = export

-- One-shot compile: lines → output string per format
-- Returns { ["tex"] = "...", ["md"] = "..." }
-- With opts.source_map = true, each value is { output = "...", source_map = {...} }
function M.compile(lines, opts)
    opts = opts or {}
    local cfg = opts.cfg or config.load({ no_file = true })
    local chunks, settings = import.parse(lines, cfg.rules, cfg.inline_rules)
    local state = internal.new(chunks, settings)

    local emit_opts = opts.source_map and { source_map = true } or nil
    local results = {}
    local outputs = opts.outputs or { tex = { format = "tex", include = { "*" } } }
    for key, profile in pairs(outputs) do
        local filtered = internal.filter(state, profile)
        local format_config = cfg[profile.format] or {}
        results[key] = export.emit(filtered, profile.format, format_config, cfg.inline_emit, emit_opts)
    end
    return results
end

return M
