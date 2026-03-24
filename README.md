
# Marksetta

**Marksetta** is a real-time embedded preprocessor for ambiguous markup. Mix Markdown, LaTeX, YAML, and more in a single `.mx` file, then convert to multiple standard formats simultaneously.

## Why Marksetta?

Write once in `.mx`, get `.tex`, `.md`, and `.yaml` outputs in real-time. Marksetta sits as a hidden layer between your editor and render engine — no context switching, no manual conversion.


- Automatic flavor detection (markdown, math, code, YAML, LaTeX environments)
- Inline markup: **bold**, *italic*, `code`, $math$, [links](https://example.com)
- LaTeX special character escaping handled at import, not export
- Profile-based output filtering — choose which chunks go where
- Source maps for editor integration
- Watch mode with configurable debounce


## Quick Start

### Requirements


- LuaJIT or Lua 5.1+
- [Lux](https://github.com/nvim-neorocks/lux) package manager
- Nix (optional, for reproducible dev shell)


### Install


```bash
git clone https://github.com/merv1n34k/marksetta.git
cd marksetta
lux build
```


### Usage


```bash
# One-shot compile to stdout
lux run src/main.lua input.mx

# Compile to specific outputs
lux run src/main.lua input.mx -o tex:out.tex -o md:out.md

# Watch mode — recompile on file changes
lux run src/main.lua input.mx -o tex:out.tex -w
```


## The .mx Format

An `.mx` file is plain text where chunks are auto-detected by their syntax:


```text
---
title: My Document
author: Me
---

# Introduction

This is **bold** and *italic* with $x^2$ math.

$$
E = mc^2
$$

| Column A | Column B |
|----------|----------|
| data 1   | data 2   |
```


## Architecture

Marksetta follows the **F.A.C.E.** stability hierarchy:


| Layer | Component | Change Rate |
|-------|-----------|-------------|
| E | Environment (config) | Rarely |
| C | Content (text) | Regularly |
| A | Appearance (format) | Frequently |
| F | Focus (style) | Rapidly |


The pipeline flows: **import** (chunking and flavor detection) then **internal state** (format-agnostic) then **export** (profile-based rendering).

## Library Usage


```lua
local marksetta = require("marksetta")

local lines = { "# Hello", "", "Some **bold** text." }
local results = marksetta.compile(lines, {
    outputs = {
        tex = { format = "tex", include = { "*" } },
        md  = { format = "md",  include = { "*" } },
    },
})

print(results.tex)
print(results.md)
```


### Source Maps

Pass `source_map = true` to get chunk-to-output-line mappings:


```lua
local results = marksetta.compile(lines, {
    source_map = true,
    outputs = { tex = { format = "tex", include = { "*" } } },
})
-- results.tex.output     = compiled string
-- results.tex.source_map = { { chunk_id, flavor, src_start, src_end, out_start, out_end }, ... }
```


## Neovim Integration

See [marksetta.nvim](https://github.com/merv1n34k/marksetta.nvim) for real-time compilation with TeXpresso support.

## License

Distributed under the MIT License. See `LICENSE` for more information.
