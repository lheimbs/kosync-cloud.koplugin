--- WireGuard integration module for kosync-cloud.koplugin.
-- Manages wireproxy lifecycle to provide a SOCKS5 proxy for WebDAV
-- sync via a WireGuard VPN tunnel.
--
-- The user must compile wireproxy themselves (see README.md) and
-- select the binary path from the plugin settings. At sync time the
-- module copies the user-supplied WireGuard .conf, appends a [Socks5]
-- section binding on 127.0.0.1:1080, starts wireproxy as a subprocess,
-- sets proxy environment variables, runs the sync, then tears everything
-- down.
--
-- @module wireguard

local DataStorage = require("datastorage")
local logger = require("logger")

--- @table WireGuard
local WireGuard = {}

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

--- SOCKS5 proxy host that wireproxy binds to.
local SOCKS5_HOST = "127.0.0.1"

--- SOCKS5 proxy port that wireproxy binds to.
local SOCKS5_PORT = 1080

--- Maximum seconds to wait for the SOCKS5 proxy to become reachable.
local TUNNEL_WAIT_TIMEOUT = 10

-- ---------------------------------------------------------------------------
-- Module state
-- ---------------------------------------------------------------------------

--- PID of the currently running wireproxy process, or nil if not running.
local wireproxy_pid = nil

--- Path to the temporary wireproxy config file, or nil if none.
local temp_config_path = nil

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Declare POSIX setenv/unsetenv/chmod via FFI, tolerating duplicate declarations.
-- @return ffi LuaJIT FFI namespace with C library
local function get_ffi()
    local ok, ffi = pcall(require, "ffi")
    if not ok then return nil end
    -- pcall guards against "already declared" errors on repeated calls
    pcall(ffi.cdef, [[
        int setenv(const char *name, const char *value, int overwrite);
        int unsetenv(const char *name);
        int chmod(const char *path, unsigned int mode);
    ]])
    return ffi
end

--- Wrap a filesystem path in single-quotes for safe use in POSIX shell commands.
-- Any embedded single-quote characters are escaped as '\''.
-- @tparam  string path  filesystem path to quote
-- @treturn string POSIX-shell-safe quoted string
local function sh_quote(path)
    return "'" .. path:gsub("'", "'\\''") .. "'"
end

--- Wait until the SOCKS5 proxy port accepts a TCP connection.
-- Polls every 0.5 s until @p timeout_s seconds have elapsed.
-- When luasocket is unavailable the function falls back to a 2-second
-- sleep and returns nil to signal that reachability could not be verified.
-- @tparam  number   timeout_s maximum seconds to wait
-- @treturn boolean|nil true if reachable, false on timeout, nil if unknown
local function waitForProxy(timeout_s)
    local ok, socket = pcall(require, "socket")
    if not ok or not socket then
        -- luasocket unavailable; sleep and return nil (unknown state)
        os.execute("sleep 2")
        return nil
    end

    local deadline = os.time() + timeout_s
    while os.time() < deadline do
        local conn, _ = socket.connect(SOCKS5_HOST, SOCKS5_PORT)
        if conn then
            conn:close()
            logger.dbg("WireGuard: SOCKS5 proxy is reachable")
            return true
        end
        socket.sleep(0.5)
    end
    logger.warn("WireGuard: SOCKS5 proxy did not become reachable within", timeout_s, "s")
    return false
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Check whether a wireproxy binary exists at the given path.
-- @tparam  string binary_path  path to the wireproxy binary
-- @treturn boolean true if the file exists
function WireGuard.isAvailable(binary_path)
    if not binary_path then return false end
    local ok, lfs = pcall(require, "lfs")
    if not ok then
        local f = io.open(binary_path, "rb")
        if f then f:close(); return true end
        return false
    end
    local attr = lfs.attributes(binary_path)
    return attr ~= nil and attr.mode == "file"
end

--- Return the SOCKS5 proxy URL that wireproxy binds to.
-- @treturn string proxy URL, e.g. "socks5://127.0.0.1:1080"
function WireGuard.getProxyURL()
    return string.format("socks5://%s:%d", SOCKS5_HOST, SOCKS5_PORT)
end

--- Prepare a temporary wireproxy config from a WireGuard .conf file.
-- Reads @p config_path, strips any existing [Socks5] section, then
-- appends a fresh [Socks5] section binding to 127.0.0.1:1080.
-- The resulting file is written with mode 0600.
-- @tparam  string  config_path path to the source WireGuard .conf file
-- @treturn string|nil  path to the temporary config, or nil on error
-- @treturn nil|string  error message when the first return value is nil
function WireGuard.prepareTempConfig(config_path)
    logger.dbg("WireGuard: prepareTempConfig", config_path)

    local f, open_err = io.open(config_path, "r")
    if not f then
        return nil, "Cannot read WireGuard config: " .. (open_err or "unknown error")
    end
    local content = f:read("*a")
    f:close()

    -- Remove any existing [Socks5] section (extends to the next section header
    -- or end-of-file so that stale bind addresses are not left behind).
    content = content:gsub("%[Socks5%][^%[]*", "")
    -- Trim trailing blank lines for a clean file
    content = content:match("^(.-)%s*$") or content

    -- Append the required [Socks5] section
    content = content
        .. string.format("\n\n[Socks5]\nBindAddress = %s:%d\n", SOCKS5_HOST, SOCKS5_PORT)

    -- Write to a private temp file inside KOReader's data directory.
    -- Include timestamp and a random suffix to avoid collisions.
    local out_path = string.format("%s/kosync_cloud_wg_%d_%d.conf",
        DataStorage:getDataDir(), os.time(), math.random(100000, 999999))
    local fw, write_err = io.open(out_path, "w")
    if not fw then
        return nil, "Cannot write temp config: " .. (write_err or "unknown error")
    end
    fw:write(content)
    fw:close()

    -- Restrict to owner-read/write only to protect the private key.
    -- Use FFI chmod when available to avoid shell command injection risks.
    local ffi = get_ffi()
    if ffi then
        ffi.C.chmod(out_path, 0x180) -- 0600 octal
    else
        os.execute("chmod 600 " .. sh_quote(out_path))
    end

    logger.dbg("WireGuard: temp config written to", out_path)
    temp_config_path = out_path
    return out_path
end

--- Start the wireproxy subprocess using the given settings.
-- Prepares a temporary config (adding [Socks5]), launches wireproxy in
-- the background, and waits up to TUNNEL_WAIT_TIMEOUT seconds for the
-- SOCKS5 proxy to become reachable.
-- @tparam  string  binary_path path to the wireproxy binary
-- @tparam  string  config_path path to the source WireGuard .conf file
-- @treturn boolean true on success
-- @treturn nil|string  error message on failure
function WireGuard.start(binary_path, config_path)
    logger.dbg("WireGuard: start", binary_path, config_path)

    if wireproxy_pid then
        logger.warn("WireGuard: already running with PID", wireproxy_pid)
        return true
    end

    if not WireGuard.isAvailable(binary_path) then
        return false, "wireproxy binary not found at " .. tostring(binary_path)
    end

    -- Ensure the binary is executable.
    -- Use FFI chmod when available to avoid shell command injection risks.
    local ffi = get_ffi()
    if ffi then
        ffi.C.chmod(binary_path, 0x1ED) -- 0755 octal
    else
        os.execute("chmod +x " .. sh_quote(binary_path))
    end

    local tconfig, prep_err = WireGuard.prepareTempConfig(config_path)
    if not tconfig then
        return false, prep_err
    end

    -- Start wireproxy in the background; capture its PID via `echo $!`
    local cmd = string.format('%s -c %s & echo $!',
        sh_quote(binary_path), sh_quote(tconfig))
    local pipe = io.popen(cmd)
    if not pipe then
        return false, "Failed to start wireproxy subprocess"
    end
    local pid_str = pipe:read("*l")
    pipe:close()

    wireproxy_pid = tonumber(pid_str)
    if not wireproxy_pid or wireproxy_pid == 0 then
        return false, "Failed to obtain wireproxy PID"
    end
    logger.dbg("WireGuard: wireproxy started, PID =", wireproxy_pid)

    -- Wait for the tunnel to come up
    local ready = waitForProxy(TUNNEL_WAIT_TIMEOUT)
    if not ready then
        logger.warn("WireGuard: proceeding even though proxy may not be fully up")
    end

    return true
end

--- Stop the running wireproxy subprocess and remove the temporary config.
function WireGuard.stop()
    logger.dbg("WireGuard: stop, PID =", wireproxy_pid)
    if wireproxy_pid then
        -- Validate that PID is a positive integer before using it in a shell command
        if type(wireproxy_pid) == "number" and wireproxy_pid > 0
                and math.floor(wireproxy_pid) == wireproxy_pid then
            os.execute("kill " .. wireproxy_pid .. " 2>/dev/null")
        end
        wireproxy_pid = nil
    end
    if temp_config_path then
        os.remove(temp_config_path)
        temp_config_path = nil
    end
end

--- Set proxy environment variables so that HTTP clients route through
-- the SOCKS5 proxy.  All common proxy variable names are set so that
-- both curl-based and pure-Lua clients pick them up.
-- @treturn table snapshot of the previous values, pass to clearProxyEnv()
function WireGuard.setProxyEnv()
    local proxy_url = WireGuard.getProxyURL()
    -- Snapshot originals for later restoration
    local originals = {
        ALL_PROXY   = os.getenv("ALL_PROXY"),
        all_proxy   = os.getenv("all_proxy"),
        http_proxy  = os.getenv("http_proxy"),
        HTTP_PROXY  = os.getenv("HTTP_PROXY"),
        https_proxy = os.getenv("https_proxy"),
        HTTPS_PROXY = os.getenv("HTTPS_PROXY"),
    }
    local ffi = get_ffi()
    if ffi then
        for _, name in ipairs({ "ALL_PROXY", "all_proxy",
                                 "http_proxy", "HTTP_PROXY",
                                 "https_proxy", "HTTPS_PROXY" }) do
            ffi.C.setenv(name, proxy_url, 1)
        end
    end
    logger.dbg("WireGuard: proxy env set to", proxy_url)
    return originals
end

--- Restore proxy environment variables to their pre-WireGuard values.
-- @tparam table originals snapshot returned by setProxyEnv()
function WireGuard.clearProxyEnv(originals)
    local ffi = get_ffi()
    if not ffi then return end
    for name, val in pairs(originals or {}) do
        if val then
            ffi.C.setenv(name, val, 1)
        else
            ffi.C.unsetenv(name)
        end
    end
    logger.dbg("WireGuard: proxy env restored")
end

--- Test the WireGuard connection by starting wireproxy, verifying
-- that the SOCKS5 proxy becomes reachable, and then tearing it down.
-- @tparam  string  binary_path path to the wireproxy binary
-- @tparam  string  config_path path to the WireGuard .conf file
-- @treturn boolean true if the SOCKS5 proxy was reachable
-- @treturn string  human-readable status message
function WireGuard.testConnection(binary_path, config_path)
    logger.dbg("WireGuard: testConnection", binary_path, config_path)

    if not binary_path then
        return false, "No wireproxy binary configured."
    end
    if not config_path then
        return false, "No WireGuard config selected."
    end
    if not WireGuard.isAvailable(binary_path) then
        return false, "wireproxy binary not found at:\n" .. binary_path
    end

    local started, start_err = WireGuard.start(binary_path, config_path)
    if not started then
        return false, "Failed to start wireproxy:\n" .. (start_err or "unknown error")
    end

    -- Proxy is up if we got here (start already waited for it)
    WireGuard.stop()
    return true, "SOCKS5 proxy came up successfully on " .. WireGuard.getProxyURL()
end

--- Execute a function with the WireGuard SOCKS5 proxy active.
-- If @p binary_path or @p config_path is nil, @p fn is called directly
-- without any proxy.  Otherwise wireproxy is started, proxy environment
-- variables are set, @p fn is called, and then everything is cleaned up.
-- Any error raised by @p fn is re-raised after cleanup.
-- @tparam  string|nil  binary_path wireproxy binary path, or nil to skip
-- @tparam  string|nil  config_path WireGuard .conf path, or nil to skip
-- @tparam  function    fn          function to execute
-- @return any value(s) returned by @p fn
function WireGuard.runWithProxy(binary_path, config_path, fn)
    if not binary_path or not config_path then
        return fn()
    end

    logger.dbg("WireGuard: runWithProxy with config", config_path)
    local started, start_err = WireGuard.start(binary_path, config_path)
    if not started then
        logger.err("WireGuard: could not start proxy:", start_err)
        -- Proceed without proxy rather than silently blocking the sync
        return fn()
    end

    local originals = WireGuard.setProxyEnv()
    local ok, result = pcall(fn)
    WireGuard.clearProxyEnv(originals)
    WireGuard.stop()

    if not ok then
        error(result, 2)
    end
    return result
end

return WireGuard
