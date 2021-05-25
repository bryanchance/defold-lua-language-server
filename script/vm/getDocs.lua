local files    = require 'files'
local util     = require 'utility'
local guide    = require 'parser.guide'
---@type vm
local vm       = require 'vm.vm'
local config   = require 'config'
local searcher = require 'core.searcher'

local typeMap = {
    ['doc.type.name']    = 'type',
    ['doc.class.name']   = 'class',
    ['doc.extends.name'] = 'extends',
    ['doc.alias.name']   = 'alias',
}

local function getNamesOfFile(uri)
    local names = {
        type    = {},
        class   = {},
        extends = {},
        alias   = {},
    }
    local ast = files.getAst(uri)
    if not ast or not ast.ast.docs then
        return names
    end
    guide.eachSource(ast.ast.docs, function (src)
        local type = typeMap[src.type]
        if not type then
            return
        end
        --if src.type == 'doc.type.name' then
        --    if guide.getParentDocTypeTable(src) then
        --        return
        --    end
        --end
        local name = src[1]
        if not name then
            return
        end
        local list = names[type]
        if not list[name] then
            list[name] = {}
        end
        list[name][#list[name]+1] = src
    end)
    return names
end

local function getDocNames(name, type)
    local results = {}
    if name == 'any'
    or name == 'nil' then
        return results
    end
    for uri in files.eachFile() do
        local cache = files.getCache(uri)
        cache = cache or getNamesOfFile(uri)
        if name == '*' then
            for _, sources in util.sortPairs(cache[type]) do
                for _, source in ipairs(sources) do
                    results[#results+1] = source
                end
            end
        else
            if cache[type][name] then
                for _, source in ipairs(cache[type][name]) do
                    results[#results+1] = source
                end
            end
        end
    end
    return results
end

function vm.getDocEnums(doc)
    if not doc then
        return nil
    end
    local defs = searcher.requestDefinition(doc)
    local results = {}

    for _, def in ipairs(defs) do
        if def.type == 'doc.type.enum'
        or def.type == 'doc.resume' then
            results[#results+1] = def
        end
    end

    return results
end

function vm.getDocTypeUnits(doc, mark, results)
    if not doc then
        return nil
    end
    mark = mark or {}
    if mark[doc] then
        return nil
    end
    mark[doc] = true
    results = results or {}
    for _, enum in ipairs(doc.enums) do
        results[#results+1] = enum
    end
    for _, resume in ipairs(doc.resumes) do
        results[#results+1] = resume
    end
    for _, unit in ipairs(doc.types) do
        if unit.type == 'doc.type.name' then
            for _, other in ipairs(vm.getDocTypes(unit[1])) do
                if other.type == 'doc.alias.name' then
                    vm.getDocTypeUnits(other.parent.extends, mark, results)
                elseif other.type == 'doc.class.name' then
                    results[#results+1] = other
                end
            end
        else
            results[#results+1] = unit
        end
    end
    return results
end

function vm.getDocNames(name, type)
    local cacheName = 'docNames:' .. type
    local cache = vm.getCache(cacheName)[name]
    if cache ~= nil then
        return cache
    end
    cache = getDocNames(name, type)
    vm.getCache(cacheName)[name] = cache
    return cache
end

function vm.isMetaFile(uri)
    local status = files.getAst(uri)
    if not status then
        return false
    end
    local cache = files.getCache(uri)
    if cache.isMeta ~= nil then
        return cache.isMeta
    end
    cache.isMeta = false
    if not status.ast.docs then
        return false
    end
    for _, doc in ipairs(status.ast.docs) do
        if doc.type == 'doc.meta' then
            cache.isMeta = true
            return true
        end
    end
    return false
end

function vm.getValidVersions(doc)
    if doc.type ~= 'doc.version' then
        return
    end
    local valids = {
        ['Lua 5.1'] = false,
        ['Lua 5.2'] = false,
        ['Lua 5.3'] = false,
        ['Lua 5.4'] = false,
        ['LuaJIT']  = false,
    }
    for _, version in ipairs(doc.versions) do
        if version.ge and type(version.version) == 'number' then
            for ver in pairs(valids) do
                local verNumber = tonumber(ver:sub(-3))
                if verNumber and verNumber >= version.version then
                    valids[ver] = true
                end
            end
        elseif version.le and type(version.version) == 'number' then
            for ver in pairs(valids) do
                local verNumber = tonumber(ver:sub(-3))
                if verNumber and verNumber <= version.version then
                    valids[ver] = true
                end
            end
        elseif type(version.version) == 'number' then
            valids[('Lua %.1f'):format(version.version)] = true
        elseif 'JIT' == version.version then
            valids['LuaJIT'] = true
        end
    end
    if valids['Lua 5.1'] then
        valids['LuaJIT'] = true
    end
    return valids
end

local function isDeprecated(value)
    if not value.bindDocs then
        return false
    end
    for _, doc in ipairs(value.bindDocs) do
        if doc.type == 'doc.deprecated' then
            return true
        elseif doc.type == 'doc.version' then
            local valids = vm.getValidVersions(doc)
            if not valids[config.config.runtime.version] then
                return true
            end
        end
    end
    return false
end

function vm.isDeprecated(value, deep)
    if deep then
        local defs = vm.getDefs(value)
        if #defs == 0 then
            return false
        end
        for _, def in ipairs(defs) do
            if not isDeprecated(def) then
                return false
            end
        end
        return true
    else
        return isDeprecated(value)
    end
end

local function makeDiagRange(uri, doc, results)
    local lines  = files.getLines(uri)
    local names
    if doc.names then
        names = {}
        for i, nameUnit in ipairs(doc.names) do
            local name = nameUnit[1]
            names[name] = true
        end
    end
    local row = guide.positionOf(lines, doc.start)
    if doc.mode == 'disable-next-line' then
        if lines[row+1] then
            results[#results+1] = {
                mode   = 'disable',
                names  = names,
                offset = lines[row+1].start,
                source = doc,
            }
            results[#results+1] = {
                mode   = 'enable',
                names  = names,
                offset = lines[row+1].finish,
                source = doc,
            }
        end
    elseif doc.mode == 'disable-line' then
        results[#results+1] = {
            mode   = 'disable',
            names  = names,
            offset = lines[row].start,
            source = doc,
        }
        results[#results+1] = {
            mode   = 'enable',
            names  = names,
            offset = lines[row].finish,
            source = doc,
        }
    elseif doc.mode == 'disable' then
        if lines[row+1] then
            results[#results+1] = {
                mode   = 'disable',
                names  = names,
                offset = lines[row+1].start,
                source = doc,
            }
        end
    elseif doc.mode == 'enable' then
        if lines[row+1] then
            results[#results+1] = {
                mode   = 'enable',
                names  = names,
                offset = lines[row+1].start,
                source = doc,
            }
        end
    end
end

function vm.isDiagDisabledAt(uri, offset, name)
    local status = files.getAst(uri)
    if not status then
        return false
    end
    if not status.ast.docs then
        return false
    end
    local cache = files.getCache(uri)
    if not cache.diagnosticRanges then
        cache.diagnosticRanges = {}
        for _, doc in ipairs(status.ast.docs) do
            if doc.type == 'doc.diagnostic' then
                makeDiagRange(uri, doc, cache.diagnosticRanges)
            end
        end
        table.sort(cache.diagnosticRanges, function (a, b)
            return a.offset < b.offset
        end)
    end
    if #cache.diagnosticRanges == 0 then
        return false
    end
    local stack = {}
    for _, range in ipairs(cache.diagnosticRanges) do
        if range.offset <= offset then
            if not range.names or range.names[name] then
                if range.mode == 'disable' then
                    stack[#stack+1] = range
                elseif range.mode == 'enable' then
                    stack[#stack] = nil
                end
            end
        else
            break
        end
    end
    local current = stack[#stack]
    if not current then
        return false
    end
    return true
end
