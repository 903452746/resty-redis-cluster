--
-- Created by IntelliJ IDEA.
-- User: stevexu
-- Date: 8/25/17
-- Time: 10:39 AM
-- To change this template use File | Settings | File Templates.
--

local ffi = require 'ffi'

local cjson = require "cjson"

local setmetatable = setmetatable
local tostring = tostring
local MAGIC_TRY = 5

local DEFUALT_KEEPALIVE_TIMEOUT = 55000
local DEFAULT_KEEPALIVE_CONS = 1000
local DEFAULT_CONNECTION_TIMEOUT = 1000

ffi.cdef [[
int lua_redis_crc16(char *key, int keylen);
]]

--load from path, otherwise we should load from LD_LIBRARY_PATH by
--export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:your_lib_path
local function load_shared_lib(so_name)
    local string_gmatch = string.gmatch
    local string_match = string.match
    local io_open = io.open
    local io_close = io.close

    local cpath = package.cpath

    for k, _ in string_gmatch(cpath, "[^;]+") do
        local fpath = string_match(k, "(.*/)")
        fpath = fpath .. so_name

        local f = io_open(fpath)
        if f ~= nil then
            io_close(f)
            return ffi.load(fpath)
        end
    end
end

local clib = load_shared_lib("redis_slot.so")
if not clib then
    ngx.log(ngx.ERR, "can not load redis_slot library")
end

local function parseKey(keyStr)
    local leftTagSingalIndex = string.find(keyStr, "{", 0)
    local rightTagSingalIndex = string.find(keyStr, "}", 0)
    if leftTagSingalIndex and rightTagSingalIndex then
        --parse hashtag
        return keyStr.sub(keyStr, leftTagSingalIndex+1, rightTagSingalIndex-1)
    else
        return keyStr
    end
end

local function redis_slot(str)
    local str = parseKey(str)
    return clib.lua_redis_crc16(ffi.cast("char *", str), #str)
end

local _M = {}
local mt = { __index = _M }

local redis = require "redis"

local resty_lock = require "resty.lock"

redis.add_commands("cluster")
local common_cmds = {
    "append", --[["auth",]] --[["bgrewriteaof",]]
    --[["bgsave",]] --[["blpop",]] --[["brpop",]]
    --[["brpoplpush",]] --[["config", ]] --[["dbsize",]]
    --[["debug", ]] "decr", "decrby",
    --[["del",]] --[["discard",           "echo",]]
    --[["eval",]] "exec", "exists",
    --[["expire",            "expireat",          "flushall",
    "flushdb",]] "get", "getbit",
    "getrange", "getset", "hdel",
    "hexists", "hget", "hgetall",
    "hincrby", "hkeys", "hlen",
    "hmget", "hmset", "hset",
    "hsetnx", "hvals", "incr",
    "incrby", --[["info",]] --[["keys",]]
    --[["lastsave", ]] "lindex", "linsert",
    "llen", "lpop", "lpush",
    "lpushx", "lrange", "lrem",
    "lset", "ltrim", --[["mget"]]
    --[["monitor", "move", "mset"]]
    --[[["msetnx", "multi",]] --[["object",]]
    --[["persist",]] --[["ping",]] --[["psubscribe",]]
    --[[ "publish",           "punsubscribe",      "quit",]]
    --[["randomkey",         "rename",            "renamenx",]]
    "rpop", --[["rpoplpush",]] "rpush",
    "rpushx", "sadd", --[["save",]]
    "scard", --[["script",]]
    --[["sdiff",             "sdiffstore",]]
    --[["select",]] "set", "setbit",
    "setex", "setnx", "setrange",
    --[["shutdown",          "sinter",            "sinterstore",
    "sismember",         "slaveof",           "slowlog",]]
    "smembers", "smove", "sort",
    "spop", "srandmember", "srem",
    "strlen", --[["subscribe",]] "sunion",
    "sunionstore", --[["sync",]] "ttl",
    "type", --[["unsubscribe",]] --[["unwatch",
    "watch",]] "zadd", "zcard",
    "zcount", "zincrby", "zinterstore",
    "zrange", "zrangebyscore", "zrank",
    "zrem", "zremrangebyrank", "zremrangebyscore",
    "zrevrange", "zrevrangebyscore", "zrevrank",
    "zscore", --[["zunionstore",    "evalsha"]]
}

local slot_cache = {}

local function try_hosts_slots(self, serv_list)
    local errors = {}
    local config = self.config
    for i = 1, #serv_list do
        local ip = serv_list[i].ip
        local port = serv_list[i].port
        local redis_client = redis:new()
        local ok, err = redis_client:connect(ip, port)
        redis_client:set_timeout(config.connection_timout or DEFAULT_CONNECTION_TIMEOUT)
        if ok then
            local slot_info, err = redis_client:cluster("slots")
            redis_client:set_keepalive(config.keepalive_timeout or DEFUALT_KEEPALIVE_TIMEOUT,
                config.keepalive_cons or DEFAULT_KEEPALIVE_CONS)
            if slot_info then
                local slots = {}
                for i = 1, #slot_info do
                    local item = slot_info[i]
                    for slot = item[1], item[2] do
                        local list = { serv_list = {} }
                        for j = 3, #item do
                            list.serv_list[#list.serv_list + 1] = { ip = item[j][1], port = item[j][2] }
                            slots[slot] = list
                        end
                    end
                end
                ngx.log(ngx.NOTICE, "finished initializing slotcache...")
                slot_cache[self.config.name] = slots
                return true, nil
            else
                table.insert(errors, err)
            end
        else
            table.insert(errors, err)
        end
    end
    return nil, errors
end

function _M.fetch_slots(self)
    local serv_list = self.config.serv_list
    local ok, errors = try_hosts_slots(self, serv_list)
    if errors then
        ngx.log(ngx.ERR, "failed to fetch slots: ", table.concat(errors, ";"))
    end
end


function _M.init_slots(self)
    if slot_cache[self.config.name] then
        return
    end
    local lock, err = resty_lock:new("redis_cluster_slot_locks")
    if not lock then
        ngx.log(ngx.ERR, "failed to create lock in initialization slot cache: ", err)
        return
    end

    local elapsed, err = lock:lock("redis_cluster_slot")
    if not elapsed then
        ngx.log(ngx.ERR, "failed to acquire the lock in initialization slot cache: ", err)
        return
    end

    if slot_cache[self.config.name] then
        local ok, err = lock:unlock()
        if not ok then
            ngx.log(ngx.ERR, "failed to unlock in initialization slot cache: ", err)
        end
        return
    end

    self:fetch_slots()
    local ok, err = lock:unlock()
    if not ok then
        ngx.log(ngx.ERR, "failed to unlock in initialization slot cache:", err)
    end
end

function _M.new(self, config)
    local inst = { config = config }
    inst = setmetatable(inst, mt)
    inst:init_slots()
    return inst
end

math.randomseed(os.time())


local function pick_node(self, serv_list, slot, magicRadomSeed)
    local host
    local port
    local slave
    local err
    local index
    if #serv_list < 1 then
        err = "serv_list for slot " .. slot .. " is empty"
        return host, port, slave, err
    end
    if self.config.enableSlaveRead then
        if magicRadomSeed then
            index = magicRadomSeed % #serv_list + 1
        else
            index = math.random(#serv_list)
        end
        host = serv_list[index].ip
        port = serv_list[index].port
        --cluster slots will always put the master node as first
        if index > 1 then
            slave = true
        else
            slave = false
        end
        --ngx.log(ngx.NOTICE, "pickup node: ", cjson.encode(serv_list[index]))
    else
        host = serv_list[1].ip
        port = serv_list[1].port
        slave = false
        --ngx.log(ngx.NOTICE, "pickup node: ", cjson.encode(serv_list[1]))
    end
    return host, port, slave, err
end

local function split(str, separator)
    local splitArray = {}
    if (string.len(str) < 1) then
        return splitArray
    end
    local startIndex = 1
    local splitIndex = 1
    while true do
        local lastIndex = string.find(str, separator, startIndex)
        if not lastIndex then
            splitArray[splitIndex] = string.sub(str, startIndex, string.len(str))
            break
        end
        splitArray[splitIndex] = string.sub(str, startIndex, lastIndex - 1)
        startIndex = lastIndex + string.len(separator)
        splitIndex = splitIndex + 1
    end
    return splitArray
end

local function parseAskSignal(res)
    --ask signal sample:ASK 12191 127.0.0.1:7008, so we need to parse and get 127.0.0.1, 7008
    if res ~= ngx.null then
        if type(res) == "string" and string.sub(res, 1, 3) == "ASK" then
            local askStr = split(res, " ")
            local hostAndPort = split(askStr[3], ":")
            return hostAndPort[1], hostAndPort[2]
        else
            for i = 1, #res do
                if type(res[i]) == "string" and string.sub(res[i], 1, 3) == "ASK" then
                    local askStr = split(res[i], " ")
                    local hostAndPort = split(askStr[3], ":")
                    return hostAndPort[1], hostAndPort[2]
                end
            end
        end
    end
    return nil, nil
end

local function hasMovedSignal(res)
    if res ~= ngx.null then
        if type(res) == "string" and string.sub(res, 1, 5) == "MOVED" then
            return true
        else
            for i = 1, #res do
                if type(res[i]) == "string" and string.sub(res[i], 1, 5) == "MOVED" then
                    return true
                end
            end
        end
    end
    return false
end

local function handleCommandWithRetry(self, targetIp, targetPort, asking, cmd, key, ...)
    local config = self.config

    key = tostring(key)
    local slot = redis_slot(key)

    for k = 1, MAGIC_TRY do

        if k > 1 then
            --ngx.log(ngx.NOTICE, "handle retry attempts:" .. k .. " for cmd:" .. cmd .. " key:" .. key)
        end

        local slots = slot_cache[self.config.name]
        local serv_list = slots[slot].serv_list

        -- We must empty local reference to slots cache, otherwise there will be memory issue while
        -- coroutine swich happens(eg. ngx.sleep, cosocket), very important!
        slots = nil

        local ip, port, slave, err

        if targetIp ~= nil and targetPort ~= nil then
            --asking redirection should only happens at master nodes, if exception,
            --the worst case is maximum retry with everytime return moved signal
            ip, port, slave = targetIp, targetPort, false
        else
            ip, port, slave, err = pick_node(self, serv_list, slot)
            if err then
                ngx.log(ngx.ERR, "pickup node failed, will return failed for this request, meanwhile refereshing slotcache " .. err)
                self:fetch_slots()
                return nil, err
            end
        end

        local redis_client = redis:new()
        redis_client:set_timeout(config.connection_timout or DEFAULT_CONNECTION_TIMEOUT)
        local ok, connerr = redis_client:connect(ip, port)

        if ok then
            if slave then
                --set readonly
                local ok, err = redis_client:readonly()
                if not ok then
                    self:fetch_slots()
                    return nil, err
                end
            end

            if asking then
                --executing asking
                local ok, err = redis_client:asking()
                if not ok then
                    self:fetch_slots()
                    return nil, err
                end
            end

            local needToRetry = false

            local res, err = redis_client[cmd](redis_client, key, ...)
            redis_client:set_keepalive(config.keepalive_timeout or DEFUALT_KEEPALIVE_TIMEOUT,
                config.keepalive_cons or DEFAULT_KEEPALIVE_CONS)
            if err then
                if string.sub(err, 1, 5) == "MOVED" then
                    --ngx.log(ngx.NOTICE, "find MOVED signal, trigger retry for normal commands, cmd:" .. cmd .. " key:" .. key)
                    --if retry with moved, we will not asking to specific ip,port anymore
                    targetIp = nil
                    targetPort = nil
                    self:fetch_slots()
                    needToRetry = true

                elseif string.sub(err, 1, 3) == "ASK" then
                    --ngx.log(ngx.NOTICE, "handle asking for normal commands, cmd:" .. cmd .. " key:" .. key)
                    if asking then
                        --Should not happen after asking target ip,port and still return ask, if so, return error.
                        return nil, "nested asking redirection occurred, client cannot retry "
                    else
                        local askHost, askPort = parseAskSignal(err)

                        if askHost ~= nil and askPort ~= nil then
                            return handleCommandWithRetry(self, askHost, askPort, true, cmd, key, ...)
                        else
                            return nil, " cannot parse ask redirection host and port: msg is " .. err
                        end
                    end

                elseif string.sub(err, 1, 11) == "CLUSTERDOWN" then
                    return nil, "Cannot executing command, cluster status is failed!"

                else
                    --There might be node fail, we should also refresh slot cache
                    self:fetch_slots()
                    return nil, err
                end
            end
            if not needToRetry then
                --ngx.log(ngx.NOTICE, "res:" .. cjson.encode(res))
                return res, err
            end
        else
            --There might be node fail, we should also refresh slot cache
            self:fetch_slots()
            return nil, connerr
        end
    end
    return nil, "failed to execute command, reaches maximum retry attempts"
end

local function _do_cmd(self, cmd, key, ...)
    if self._reqs then
        local args = { ... }
        local t = { cmd = cmd, key = key, args = args }
        table.insert(self._reqs, t)
        return
    end

    local res, err = handleCommandWithRetry(self, nil, nil, false, cmd, key, ...)
    return res, err
end


local function constructFinalPipelineRes(self, map_ret, map)
    --construct final result with origin index
    local ret = {}
    for k, v in pairs(map_ret) do
        local ins_reqs = map[k].reqs
        local res = v
        local needToFetchSlots = true
        for i = 1, #ins_reqs do
            --deal with redis cluster ask redirection
            local askHost, askPort = parseAskSignal(res[i])
            if askHost ~= nil and askPort ~= nil then
                --ngx.log(ngx.NOTICE, "handle ask signal for cmd:" .. ins_reqs[i]["cmd"] .. " key:" .. ins_reqs[i]["key"])
                local askres, err = handleCommandWithRetry(self, askHost, askPort, true, ins_reqs[i]["cmd"], ins_reqs[i]["key"], unpack(ins_reqs[i]["args"]))
                if err then
                    return nil, err
                else
                    ret[ins_reqs[i].origin_index] = askres
                end
            elseif hasMovedSignal(res[i]) then
                --ngx.log(ngx.NOTICE, "handle moved signal for cmd:" .. ins_reqs[i]["cmd"] .. " key:" .. ins_reqs[i]["key"])
                if needToFetchSlots then
                    -- if there is multiple signal for moved, we just need to fetch slot cache once, and do retry.
                    self:fetch_slots()
                    needToFetchSlots =false
                end
                local movedres, err = handleCommandWithRetry(self, nil, nil, false, ins_reqs[i]["cmd"], ins_reqs[i]["key"], unpack(ins_reqs[i]["args"]))
                if err then
                    return nil, err
                else
                    ret[ins_reqs[i].origin_index] = movedres
                end
            else
                ret[ins_reqs[i].origin_index] = res[i]
            end
        end
    end
    return ret
end

local function hasClusterFailSignalInPipeline(res)
    for i = 1, #res do
        if res[i] ~= ngx.null then
            for j = 1, #res[i] do
                if type(res[i][j]) == "string" and string.sub(res[i][j], 1, 11) == "CLUSTERDOWN" then
                    return true
                end
            end
        end
    end
    return false
end

local function generateMagicSeed(self)
    --We don't want req will be divided to all channels, eg. if we have 3*3 cluster(3 master 2 replicas) we want pick up specific 3 for 1 requests
    --given a seed far more than the number of cluster nodes
    if self.config.enableSlaveRead then
        return math.random(1000, 10000)
    else
        return nil
    end
end

function _M.init_pipeline(self)
    self._reqs = {}
end


function _M.commit_pipeline(self)
    if not self._reqs or #self._reqs == 0 then return
    end
    local reqs = self._reqs
    self._reqs = nil
    local config = self.config
    local needToRetry = false

    local slots = slot_cache[config.name]

    local map_ret = {}
    local map = {}
    local magicRandomPickupSeed = generateMagicSeed(self)

    --construct req to real node mapping
    for i = 1, #reqs do
        -- Because we will forward req to different nodes, so the result will not be the origin order,
        -- we need to record the original index and finally we can construct the result with origin order
        reqs[i].origin_index = i
        local key = reqs[i].key
        local slot = redis_slot(tostring(key))
        local slot_item = slots[slot]

        local ip, port, slave, err = pick_node(self, slot_item.serv_list, slot, magicRandomPickupSeed)
        if err then
            ngx.log(ngx.ERR, "pickup node failed, will return failed for this request, meanwhile refereshing slotcache " .. err)
            -- We must empty local reference to slots cache, otherwise there will be memory issue while
            -- coroutine swich happens(eg. ngx.sleep, cosocket), very important!
            slots = nil
            self:fetch_slots()
            return nil, err
        end

        local inst_key = ip .. tostring(port)
        if not map[inst_key] then
            map[inst_key] = { ip = ip, port = port, slave = slave, reqs = {} }
            map_ret[inst_key] = {}
        end
        local ins_req = map[inst_key].reqs
        ins_req[#ins_req + 1] = reqs[i]
    end

    -- We must empty local reference to slots cache, otherwise there will be memory issue while
    -- coroutine swich happens(eg. ngx.sleep, cosocket), very important!
    slots = nil

    for k, v in pairs(map) do
        local ip = v.ip
        local port = v.port
        local ins_reqs = v.reqs
        local slave = v.slave
        local ins = redis:new()
        ins:set_timeout(config.connection_timout or DEFAULT_CONNECTION_TIMEOUT)
        local ok, err = ins:connect(ip, port)
        if slave then
            --set readonly
            local ok, err = ins:readonly()
            if not ok then
                self:fetch_slots()
                return nil, err
            end
        end
        if ok then
            ins:init_pipeline()
            for i = 1, #ins_reqs do
                local req = ins_reqs[i]
                if #req.args > 0 then
                    ins[req.cmd](ins, req.key, unpack(req.args))
                else
                    ins[req.cmd](ins, req.key)
                end
            end
            local res, err = ins:commit_pipeline()
            ins:set_keepalive(config.keepalive_timeout or DEFUALT_KEEPALIVE_TIMEOUT,
                config.keepalive_cons or DEFAULT_KEEPALIVE_CONS)
            if err then
                --There might be node fail, we should also refresh slot cache
                self:fetch_slots()
                return nil, err .. " return from " .. tostring(ip) .. ":" .. tostring(port)
            end

            if hasClusterFailSignalInPipeline(res) then
                return nil, "Cannot executing pipeline command, cluster status is failed!"
            end

            map_ret[k] = res
        else
            --There might be node fail, we should also refresh slot cache
            self:fetch_slots()
            return nil, err .. "pipeline commit failed while connecting to " .. tostring(ip) .. ":" .. tostring(port)
        end
    end

    --construct final result with origin index
    local finalres, err = constructFinalPipelineRes(self, map_ret, map)
    if not err then
        return finalres
    else
        return nil, err .. " failed to construct final pipeline result "
    end
    return nil, " failed to execute pipeline command, reach maximum retry attempts "
end


function _M.cancel_pipeline(self)
    self._reqs = nil
end


for i = 1, #common_cmds do
    local cmd = common_cmds[i]

    _M[cmd] =
    function(self, ...)
        return _do_cmd(self, cmd, ...)
    end
end

return _M