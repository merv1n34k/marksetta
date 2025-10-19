#!/usr/bin/env lua

-- main lua file, invokes two modules to convert files
--
-- First module: get the file and process it
-- to have a separated chunks with labels,
-- indicating what the chunk is about
--
-- Second module: take the chunks form the first module
-- and process them according to rules of conversion
--
-- For now it will work like this:
-- $ texetta mynote.md mynote.tex [-r rules.toml]
--

-- import required modules
local reader = require("import")

local function log(lvl, msg)
    print("- [" .. lvl .. "] - " .. msg)
end

-- define default required conditions

-- read file and check it to be healthy

local status, content = pcall(reader.import, arg[1])

if status then
    local settings = reader.get_settings(content)
    for k, v in pairs(settings) do
        print(k .. " is " .. v)
    end
    local dict = {
        comments = "%-%-",
        settings = "^#@%s*",
        env = "^%\\",
    }
    local chunks = reader.chunk(content, dict)
    for k, v in pairs(chunks) do
        print("for chunk " .. k .. " with " .. #v.content .. " lines with type " .. v.type)
    end
else
    log("error", "The file path was incorrect")
    os.exit(1)
end
--print(content)

-- parse settings (if present) and apply
-- them if they are healthy

-- check db health (according to settings)

-- chunk file and make chunk annotations
-- make subchunks annotations to sped up processing

-- process each chunk accordingly (to annotation)

-- -- -- -- -- --
-- Parse all file elements and record them to db
--

-- print them (debug)
--
-- convert them according to writer and reader values
