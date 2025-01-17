--
-- Licensed to the Apache Software Foundation (ASF) under one or more
-- contributor license agreements.  See the NOTICE file distributed with
-- this work for additional information regarding copyright ownership.
-- The ASF licenses this file to You under the Apache License, Version 2.0
-- (the "License"); you may not use this file except in compliance with
-- the License.  You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--

local core = require("apisix.core")
local timers = require("apisix.timers")
local plugin = require("apisix.plugin")
local process = require("ngx.process")
local signal = require("resty.signal")
local shell = require("resty.shell")
local ngx = ngx
local lfs = require("lfs")
local io = io
local os = os
local table = table
local string = string
local str_find = core.string.find
local local_conf


local plugin_name = "log-rotate"
local INTERVAL = 60 * 60    -- rotate interval (unit: second)
local MAX_KEPT = 24 * 7     -- max number of log files will be kept
local COMPRESSION_FILE_SUFFIX = ".tar.gz" -- compression file suffix
local enable_compression = false

local schema = {
    type = "object",
    properties = {},
}


local _M = {
    version = 0.1,
    priority = 100,
    name = plugin_name,
    schema = schema,
    scope = "global",
}


local function file_exists(path)
    local file = io.open(path, "r")
    if file then
        file:close()
    end
    return file ~= nil
end


local function get_last_index(str, key)
    local rev = string.reverse(str)
    local _, idx = str_find(rev, key)
    local n
    if idx then
        n = #rev - idx + 1
    end

    return n
end


local function get_log_path_info(file_type)
    local_conf = core.config.local_conf()
    local conf_path
    if file_type == "error.log" then
        conf_path = local_conf and local_conf.nginx_config and
        local_conf.nginx_config.error_log
    else
        conf_path = local_conf and local_conf.nginx_config and
        local_conf.nginx_config.http and
        local_conf.nginx_config.http.access_log
    end

    local prefix = ngx.config.prefix()

    if conf_path then
        local root = string.sub(conf_path, 1, 1)
        -- relative path
        if root ~= "/" then
            conf_path = prefix .. conf_path
        end
        local n = get_last_index(conf_path, "/")
        if n ~= nil and n ~= #conf_path then
            local dir = string.sub(conf_path, 1, n)
            local name = string.sub(conf_path, n + 1)
            return dir, name
        end
    end

    return prefix .. "logs/", file_type
end


local function rotate_file(date_str, file_type)
    local log_dir, filename = get_log_path_info(file_type)

    core.log.info("rotate log_dir:", log_dir)
    core.log.info("rotate filename:", filename)

    local new_filename = date_str .. "__" .. filename
    local file_path = log_dir .. new_filename
    if file_exists(file_path) then
        core.log.info("file exist: ", file_path)
        return false
    end

    local file_path_org = log_dir .. filename
    local ok, msg = os.rename(file_path_org, file_path)
    core.log.info("move file from ", file_path_org, " to ", file_path,
                  " res:", ok, " msg:", msg)

    if ok and enable_compression then
        local compression_filename = new_filename .. COMPRESSION_FILE_SUFFIX
        local cmd = string.format("cd %s && tar -zcf %s %s",
            log_dir, compression_filename, new_filename)
        core.log.info("log file compress command: " .. cmd)
        local ok, stdout, stderr, reason, status = shell.run(cmd)
        core.log.info("compress log file from ", new_filename, " to ", compression_filename,
            " res:", ok)

        if ok then
            ok = os.remove(file_path)
            core.log.warn("remove uncompressed log file: ", file_path, " ret: ", ok)
        else
            core.log.error("failed to compress log file: ", new_filename, " ret: ", ok,
                " stdout: ", stdout, " stderr: ", stderr, " reason: ", reason, " status: ", status)
        end
    end

    return true
end


local function tab_sort(a, b)
    return a > b
end

local function scan_log_folder()
    local t = {
        access = {},
        error = {},
    }

    local log_dir, access_name = get_log_path_info("access.log")
    local _, error_name = get_log_path_info("error.log")

    if enable_compression then
        access_name = access_name .. COMPRESSION_FILE_SUFFIX
        error_name = error_name .. COMPRESSION_FILE_SUFFIX
    end

    for file in lfs.dir(log_dir) do
        local n = get_last_index(file, "__")
        if n ~= nil then
            local log_type = file:sub(n + 2)
            if log_type == access_name then
                table.insert(t.access, file)
            elseif log_type == error_name then
                table.insert(t.error, file)
            end
        end
    end

    table.sort(t.access, tab_sort)
    table.sort(t.error, tab_sort)
    return t, log_dir
end


local function rotate()
    local interval = INTERVAL
    local max_kept = MAX_KEPT
    local attr = plugin.plugin_attr(plugin_name)
    if attr then
        interval = attr.interval or interval
        max_kept = attr.max_kept or max_kept
        enable_compression = attr.enable_compression or enable_compression
    end

    core.log.info("rotate interval:", interval)
    core.log.info("rotate max keep:", max_kept)

    local time = ngx.time()
    if time % interval == 0 then
        time = time - interval
    else
        time = time - time % interval
    end

    local date_str = os.date("%Y-%m-%d_%H-%M-%S", time)

    local ok1 = rotate_file(date_str, "access.log")
    local ok2 = rotate_file(date_str, "error.log")
    if not ok1 and not ok2 then
        return
    end

    core.log.warn("send USR1 signal to master process [",
                  process.get_master_pid(), "] for reopening log file")
    local ok, err = signal.kill(process.get_master_pid(), signal.signum("USR1"))
    if not ok then
        core.log.error("failed to send USR1 signal for reopening log file: ", err)
    end

    -- clean the oldest file
    local log_list, log_dir = scan_log_folder()
    for i = max_kept + 1, #log_list.error do
        local path = log_dir .. log_list.error[i]
        local ok = os.remove(path)
        core.log.warn("remove old error file: ", path, " ret: ", ok)
    end

    for i = max_kept + 1, #log_list.access do
        local path = log_dir .. log_list.access[i]
        local ok = os.remove(path)
        core.log.warn("remove old access file: ", path, " ret: ", ok)
    end
end


function _M.init()
    timers.register_timer("plugin#log-rotate", rotate, true)
end


function _M.destroy()
    timers.unregister_timer("plugin#log-rotate", true)
end


return _M
