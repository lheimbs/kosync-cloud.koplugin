local DataStorage = require("datastorage")
local Device = require("device")
local SQ3 = require("lua-ljsqlite3/init")
local logger = require("logger")

local ProgressDB = {}

local DB_SCHEMA_VERSION = 1
local DB_FILE = "kosync_cloud_progress.sqlite3"
local db_location = DataStorage:getSettingsDir() .. "/" .. DB_FILE

local function setJournalMode(conn)
    if Device:canUseWAL() then
        conn:exec("PRAGMA journal_mode=WAL;")
    else
        conn:exec("PRAGMA journal_mode=TRUNCATE;")
    end
end

local function createSchema(conn)
    setJournalMode(conn)
    conn:exec([[
        CREATE TABLE IF NOT EXISTS progress (
            doc_md5 TEXT PRIMARY KEY,
            progress TEXT,
            percentage REAL,
            timestamp INTEGER,
            device TEXT,
            device_id TEXT
        );
    ]])
    conn:exec(string.format("PRAGMA user_version=%d;", DB_SCHEMA_VERSION))
end

function ProgressDB.getPath()
    return db_location
end

function ProgressDB.ensureDB()
    local conn = SQ3.open(db_location)
    createSchema(conn)
    conn:close()
end

local function openDB()
    local conn = SQ3.open(db_location)
    createSchema(conn)
    return conn
end

function ProgressDB.writeProgress(doc_md5, progress, percentage, timestamp, device, device_id)
    local conn = openDB()
    local stmt = conn:prepare([[
        INSERT INTO progress (doc_md5, progress, percentage, timestamp, device, device_id)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(doc_md5) DO UPDATE SET
            progress = excluded.progress,
            percentage = excluded.percentage,
            timestamp = excluded.timestamp,
            device = excluded.device,
            device_id = excluded.device_id;
    ]])
    stmt:reset():bind(doc_md5, progress, percentage, timestamp, device, device_id):step()
    stmt:close()
    conn:close()
end

function ProgressDB.readProgress(doc_md5)
    local conn = openDB()
    local stmt = conn:prepare([[SELECT progress, percentage, timestamp, device, device_id FROM progress WHERE doc_md5 = ?;]])
    local row = stmt:reset():bind(doc_md5):step()
    stmt:close()
    conn:close()
    if not row or not row[1] then
        return nil
    end
    return {
        progress = row[1],
        percentage = tonumber(row[2]),
        timestamp = tonumber(row[3]),
        device = row[4],
        device_id = row[5],
    }
end

local function incomeHasTable(conn_income)
    local ok, res = pcall(conn_income.rowexec, conn_income,
        "SELECT name FROM sqlite_master WHERE type='table' AND name='progress';")
    return ok and res
end

function ProgressDB.onSync(local_path, cached_path, income_path)
    local conn_income = SQ3.open(income_path)
    local ok1, v1 = pcall(conn_income.rowexec, conn_income, "PRAGMA schema_version")
    if not ok1 or tonumber(v1) == 0 or not incomeHasTable(conn_income) then
        logger.warn("progress sync: income DB missing or invalid", v1)
        conn_income:close()
        return true
    end
    conn_income:close()

    local conn = SQ3.open(local_path)
    local ok3, v3 = pcall(conn.exec, conn, "PRAGMA schema_version")
    if not ok3 or tonumber(v3) == 0 then
        logger.err("progress sync: local DB missing or invalid", v3)
        conn:close()
        return false
    end

    local sql = "attach '" .. income_path:gsub("'", "''") .. "' as income_db;"
    sql = sql .. [[
        INSERT INTO progress (doc_md5, progress, percentage, timestamp, device, device_id)
            SELECT doc_md5, progress, percentage, timestamp, device, device_id
            FROM income_db.progress
            WHERE doc_md5 NOT IN (SELECT doc_md5 FROM progress);

        UPDATE progress AS p
        SET progress = i.progress,
            percentage = i.percentage,
            timestamp = i.timestamp,
            device = i.device,
            device_id = i.device_id
        FROM income_db.progress AS i
        WHERE p.doc_md5 = i.doc_md5
          AND i.timestamp > p.timestamp;
    ]]

    local ok_exec, err = pcall(conn.exec, conn, sql)
    if not ok_exec then
        logger.err("progress sync merge failed", err)
        conn:close()
        return false
    end
    pcall(conn.exec, conn, "DETACH income_db;")
    conn:close()
    return true
end

return ProgressDB
