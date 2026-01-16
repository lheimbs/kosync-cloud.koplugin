local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local Math = require("optmath")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local SyncService = require("frontend/apps/cloudstorage/syncservice")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local md5 = require("ffi/sha2").md5
local random = require("random")
local time = require("ui/time")
local util = require("util")
local T = require("ffi/util").template
local ProgressDB = require("progressdb")
local _ = require("gettext")

if G_reader_settings:hasNot("device_id") then
    G_reader_settings:saveSetting("device_id", random.uuid())
end

local KOSyncCloud = WidgetContainer:extend{
    name = "kosync_cloud",
    is_doc_only = true,
    title = _("Configure cloud progress sync"),

    push_timestamp = nil,
    pull_timestamp = nil,
    page_update_counter = nil,
    last_page = nil,
    last_page_turn_timestamp = nil,
    periodic_push_task = nil,
    periodic_push_scheduled = nil,

    settings = nil,
}

local SYNC_STRATEGY = {
    PROMPT  = 1,
    SILENT  = 2,
    DISABLE = 3,
}

local CHECKSUM_METHOD = {
    BINARY = 0,
    FILENAME = 1
}

-- Debounce push/pull attempts
local API_CALL_DEBOUNCE_DELAY = time.s(25)

KOSyncCloud.default_settings = {
    sync_server = nil,
    auto_sync = false,
    pages_before_update = nil,
    sync_forward = SYNC_STRATEGY.PROMPT,
    sync_backward = SYNC_STRATEGY.DISABLE,
    checksum_method = CHECKSUM_METHOD.BINARY,
}

function KOSyncCloud:init()
    logger.dbg("KOSyncCloud: init")
    self.push_timestamp = 0
    self.pull_timestamp = 0
    self.page_update_counter = 0
    self.last_page = -1
    self.last_page_turn_timestamp = 0
    self.periodic_push_scheduled = false

    self.periodic_push_task = function()
        self.periodic_push_scheduled = false
        self.page_update_counter = 0
        self:updateProgress(false, false)
    end

    self.settings = G_reader_settings:readSetting("kosync_cloud", self.default_settings)
    self.device_id = G_reader_settings:readSetting("device_id")
    logger.dbg("KOSyncCloud: settings loaded", self.settings)
    logger.dbg("KOSyncCloud: device_id", self.device_id)

    ProgressDB.ensureDB()

    if self.settings.auto_sync and Device:hasSeamlessWifiToggle() and G_reader_settings:readSetting("wifi_enable_action") ~= "turn_on" then
        self.settings.auto_sync = false
        logger.warn("KOSyncCloud: Automatic sync disabled because wifi_enable_action is not turn_on")
    end

    self.ui.menu:registerToMainMenu(self)
end

function KOSyncCloud:getSyncPeriod()
    if not self.settings.auto_sync then
        return _("Not available")
    end

    local period = self.settings.pages_before_update
    if period and period > 0 then
        return period
    else
        return _("Never")
    end
end

local function getNameStrategy(type)
    if type == 1 then
        return _("Prompt")
    elseif type == 2 then
        return _("Auto")
    else
        return _("Disable")
    end
end

local function showSyncedMessage()
    UIManager:show(InfoMessage:new{
        text = _("Progress has been synchronized."),
        timeout = 3,
    })
end

local function showSyncError()
    UIManager:show(InfoMessage:new{
        text = _("Something went wrong when syncing progress, please check your network connection and try again later."),
        timeout = 3,
    })
end

local function promptSetup()
    UIManager:show(InfoMessage:new{
        text = _("Please configure a cloud sync service before using progress synchronization."),
        timeout = 3,
    })
end

local function runWithSyncModal(interactive, fn, message)
    if not interactive then
        logger.dbg("KOSyncCloud: sync (non-interactive)")
        return fn()
    end

    local modal = InfoMessage:new{
        text = message or _("Syncing progress. Please wait…"),
        timeout = nil,
        dismissable = false,
    }
    logger.dbg("KOSyncCloud: sync modal show")
    UIManager:show(modal)

    local ok, err = pcall(fn)
    UIManager:close(modal)
    logger.dbg("KOSyncCloud: sync modal close")
    if not ok then
        logger.err("KOSyncCloud: sync failed", err)
        showSyncError()
    end
end

function KOSyncCloud:onDispatcherRegisterActions()
    Dispatcher:registerAction("kosync_cloud_set_autosync",
        { category="string", event="KOSyncCloudToggleAutoSync", title=_("Set auto progress sync (cloud)"), reader=true,
        args={true, false}, toggle={_("on"), _("off")},})
    Dispatcher:registerAction("kosync_cloud_toggle_autosync",
        { category="none", event="KOSyncCloudToggleAutoSync", title=_("Toggle auto progress sync (cloud)"), reader=true,})
    Dispatcher:registerAction("kosync_cloud_push_progress",
        { category="none", event="KOSyncCloudPushProgress", title=_("Push progress (cloud)"), reader=true,})
    Dispatcher:registerAction("kosync_cloud_pull_progress",
        { category="none", event="KOSyncCloudPullProgress", title=_("Pull progress (cloud)"), reader=true, separator=true,})
end

function KOSyncCloud:onReaderReady()
    logger.dbg("KOSyncCloud: onReaderReady")
    if self.settings.auto_sync then
        UIManager:nextTick(function()
            self:getProgress(true, false)
        end)
    end
    self:registerEvents()
    self:onDispatcherRegisterActions()

    self.last_page = self.ui:getCurrentPage()
end

function KOSyncCloud:addToMainMenu(menu_items)
    logger.dbg("KOSyncCloud: addToMainMenu")
    menu_items.progress_sync_cloud = {
        text = _("Progress sync (cloud)"),
        sub_item_table = {
            {
                text = _("Cloud sync"),
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    logger.dbg("KOSyncCloud: open cloud sync menu")
                    local server = self.settings.sync_server
                    local edit_cb = function()
                        local sync_settings = SyncService:new{}
                        sync_settings.onClose = function(this)
                            UIManager:close(this)
                        end
                        sync_settings.onConfirm = function(sv)
                            logger.dbg("KOSyncCloud: cloud sync selected", sv and sv.type, sv and sv.url)
                            if server and (server.type ~= sv.type or server.url ~= sv.url or server.address ~= sv.address) then
                                SyncService.removeLastSyncDB(ProgressDB.getPath())
                            end
                            self.settings.sync_server = sv
                            touchmenu_instance:updateItems()
                        end
                        UIManager:show(sync_settings)
                    end
                    if not server then
                        edit_cb()
                        return
                    end
                    local dialogue
                    local delete_button = {
                        text = _("Delete"),
                        callback = function()
                            UIManager:close(dialogue)
                            UIManager:show(ConfirmBox:new{
                                text = _("Delete server info?"),
                                cancel_text = _("Cancel"),
                                cancel_callback = function() return end,
                                ok_text = _("Delete"),
                                ok_callback = function()
                                    self.settings.sync_server = nil
                                    SyncService.removeLastSyncDB(ProgressDB.getPath())
                                    touchmenu_instance:updateItems()
                                end,
                            })
                        end,
                    }
                    local edit_button = {
                        text = _("Edit"),
                        callback = function()
                            UIManager:close(dialogue)
                            edit_cb()
                        end
                    }
                    local close_button = {
                        text = _("Close"),
                        callback = function()
                            UIManager:close(dialogue)
                        end
                    }
                    local type = server.type == "dropbox" and " (Dropbox)" or " (WebDAV)"
                    dialogue = ButtonDialog:new{
                        title = T(_("Cloud storage:\n%1\n\nFolder path:\n%2\n\nSet up the same cloud folder on each device to sync across your devices."),
                                     server.name .. type, SyncService.getReadablePath(server)),
                        buttons = {
                            {delete_button, edit_button, close_button}
                        },
                    }
                    UIManager:show(dialogue)
                end,
            },
            {
                text = _("Automatically keep documents in sync"),
                checked_func = function() return self.settings.auto_sync end,
                help_text = _([[This may lead to nagging about toggling WiFi on document close and suspend/resume, depending on the device's connectivity.]]),
                callback = function()
                    self:onKOSyncCloudToggleAutoSync(nil, true)
                end,
            },
            {
                text_func = function()
                    return T(_("Periodically sync every # pages (%1)"), self:getSyncPeriod())
                end,
                enabled_func = function() return self.settings.auto_sync end,
                help_text = NetworkMgr:getNetworkInterfaceName() and _([[Unlike the automatic sync above, this will *not* attempt to setup a network connection, but instead relies on it being already up, and may trigger enough network activity to passively keep WiFi enabled!]]),
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local SpinWidget = require("ui/widget/spinwidget")
                    local items = SpinWidget:new{
                        text = _([[This value determines how many page turns it takes to update book progress.
If set to 0, updating progress based on page turns will be disabled.]]),
                        value = self.settings.pages_before_update or 0,
                        value_min = 0,
                        value_max = 999,
                        value_step = 1,
                        value_hold_step = 10,
                        ok_text = _("Set"),
                        title_text = _("Number of pages before update"),
                        default_value = 0,
                        callback = function(spin)
                            self:setPagesBeforeUpdate(spin.value)
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end
                    }
                    UIManager:show(items)
                end,
                separator = true,
            },
            {
                text = _("Sync behavior"),
                sub_item_table = {
                    {
                        text_func = function()
                            return T(_("Sync to a newer state (%1)"), getNameStrategy(self.settings.sync_forward))
                        end,
                        sub_item_table = {
                            {
                                text = _("Silently"),
                                checked_func = function()
                                    return self.settings.sync_forward == SYNC_STRATEGY.SILENT
                                end,
                                callback = function()
                                    self:setSyncForward(SYNC_STRATEGY.SILENT)
                                end,
                            },
                            {
                                text = _("Prompt"),
                                checked_func = function()
                                    return self.settings.sync_forward == SYNC_STRATEGY.PROMPT
                                end,
                                callback = function()
                                    self:setSyncForward(SYNC_STRATEGY.PROMPT)
                                end,
                            },
                            {
                                text = _("Never"),
                                checked_func = function()
                                    return self.settings.sync_forward == SYNC_STRATEGY.DISABLE
                                end,
                                callback = function()
                                    self:setSyncForward(SYNC_STRATEGY.DISABLE)
                                end,
                            },
                        }
                    },
                    {
                        text_func = function()
                            return T(_("Sync to an older state (%1)"), getNameStrategy(self.settings.sync_backward))
                        end,
                        sub_item_table = {
                            {
                                text = _("Silently"),
                                checked_func = function()
                                    return self.settings.sync_backward == SYNC_STRATEGY.SILENT
                                end,
                                callback = function()
                                    self:setSyncBackward(SYNC_STRATEGY.SILENT)
                                end,
                            },
                            {
                                text = _("Prompt"),
                                checked_func = function()
                                    return self.settings.sync_backward == SYNC_STRATEGY.PROMPT
                                end,
                                callback = function()
                                    self:setSyncBackward(SYNC_STRATEGY.PROMPT)
                                end,
                            },
                            {
                                text = _("Never"),
                                checked_func = function()
                                    return self.settings.sync_backward == SYNC_STRATEGY.DISABLE
                                end,
                                callback = function()
                                    self:setSyncBackward(SYNC_STRATEGY.DISABLE)
                                end,
                            },
                        }
                    },
                },
                separator = true,
            },
            {
                text = _("Push progress from this device now"),
                enabled_func = function()
                    return self:canSync()
                end,
                callback = function()
                    self:updateProgress(true, true)
                end,
            },
            {
                text = _("Pull progress from other devices now"),
                enabled_func = function()
                    return self:canSync()
                end,
                callback = function()
                    self:getProgress(true, true)
                end,
                separator = true,
            },
            {
                text = _("Document matching method"),
                sub_item_table = {
                    {
                        text = _("Binary. Only identical files will be kept in sync."),
                        checked_func = function()
                            return self.settings.checksum_method == CHECKSUM_METHOD.BINARY
                        end,
                        callback = function()
                            self:setChecksumMethod(CHECKSUM_METHOD.BINARY)
                        end,
                    },
                    {
                        text = _("Filename. Files with matching names will be kept in sync."),
                        checked_func = function()
                            return self.settings.checksum_method == CHECKSUM_METHOD.FILENAME
                        end,
                        callback = function()
                            self:setChecksumMethod(CHECKSUM_METHOD.FILENAME)
                        end,
                    },
                }
            },
        }
    }
end

function KOSyncCloud:setPagesBeforeUpdate(pages_before_update)
    logger.dbg("KOSyncCloud: setPagesBeforeUpdate", pages_before_update)
    self.settings.pages_before_update = pages_before_update > 0 and pages_before_update or nil
end

function KOSyncCloud:setSyncForward(strategy)
    logger.dbg("KOSyncCloud: setSyncForward", strategy)
    self.settings.sync_forward = strategy
end

function KOSyncCloud:setSyncBackward(strategy)
    logger.dbg("KOSyncCloud: setSyncBackward", strategy)
    self.settings.sync_backward = strategy
end

function KOSyncCloud:setChecksumMethod(method)
    logger.dbg("KOSyncCloud: setChecksumMethod", method)
    self.settings.checksum_method = method
end

function KOSyncCloud:canSync()
    logger.dbg("KOSyncCloud: canSync", self.settings.sync_server ~= nil)
    return self.settings.sync_server ~= nil
end

function KOSyncCloud:getLastPercent()
    if self.ui.document.info.has_pages then
        return Math.roundPercent(self.ui.paging:getLastPercent())
    else
        return Math.roundPercent(self.ui.rolling:getLastPercent())
    end
end

function KOSyncCloud:getLastProgress()
    if self.ui.document.info.has_pages then
        return self.ui.paging:getLastProgress()
    else
        return self.ui.rolling:getLastProgress()
    end
end

function KOSyncCloud:getDocumentDigest()
    logger.dbg("KOSyncCloud: getDocumentDigest", self.settings.checksum_method)
    if self.settings.checksum_method == CHECKSUM_METHOD.FILENAME then
        return self:getFileNameDigest()
    else
        return self:getFileDigest()
    end
end

function KOSyncCloud:getFileDigest()
    logger.dbg("KOSyncCloud: getFileDigest")
    return self.ui.doc_settings:readSetting("partial_md5_checksum")
end

function KOSyncCloud:getFileNameDigest()
    logger.dbg("KOSyncCloud: getFileNameDigest")
    local file = self.ui.document.file
    if not file then return end

    local file_path, file_name = util.splitFilePathName(file) -- luacheck: no unused
    if not file_name then return end

    return md5(file_name)
end

function KOSyncCloud:syncToProgress(progress)
    logger.dbg("KOSyncCloud: syncToProgress", progress)
    logger.dbg("KOSyncCloud: [Sync] progress to", progress)
    if self.ui.document.info.has_pages then
        self.ui:handleEvent(Event:new("GotoPage", tonumber(progress)))
    else
        self.ui:handleEvent(Event:new("GotoXPointer", progress))
    end
end

local function willRerunForServer(server, cb)
    if not server then return false end
    if server.type == "dropbox" then
        return NetworkMgr:willRerunWhenOnline(cb)
    end
    return NetworkMgr:willRerunWhenConnected(cb)
end

function KOSyncCloud:updateProgress(ensure_networking, interactive, on_suspend)
    logger.dbg("KOSyncCloud: updateProgress", ensure_networking, interactive, on_suspend)
    if not self:canSync() then
        if interactive then
            promptSetup()
        end
        return
    end

    local now = UIManager:getElapsedTimeSinceBoot()
    if not interactive and now - self.push_timestamp <= API_CALL_DEBOUNCE_DELAY then
        logger.dbg("KOSyncCloud: We've already pushed progress less than 25s ago!")
        return
    end

    if ensure_networking and willRerunForServer(self.settings.sync_server, function()
        self:updateProgress(ensure_networking, interactive, on_suspend)
    end) then
        return
    end

    local doc_digest = self:getDocumentDigest()
    if not doc_digest then
        logger.dbg("KOSyncCloud: updateProgress missing doc_digest")
        if interactive then showSyncError() end
        return
    end
    logger.dbg("KOSyncCloud: updateProgress doc_digest", doc_digest)
    local progress = self:getLastProgress()
    local percentage = self:getLastPercent()
    local timestamp = (self.last_page_turn_timestamp and self.last_page_turn_timestamp > 0)
        and self.last_page_turn_timestamp or os.time()

    UIManager:nextTick(function()
        runWithSyncModal(interactive, function()
            ProgressDB.writeProgress(doc_digest, progress, percentage, timestamp, Device.model, self.device_id)
            SyncService.sync(self.settings.sync_server, ProgressDB.getPath(), ProgressDB.onSync, not interactive)
        end)

        if on_suspend and Device:hasWifiManager() then
            NetworkMgr:disableWifi()
        end
    end)

    self.push_timestamp = now
end

function KOSyncCloud:getProgress(ensure_networking, interactive)
    logger.dbg("KOSyncCloud: getProgress", ensure_networking, interactive)
    if not self:canSync() then
        if interactive then
            promptSetup()
        end
        return
    end

    local now = UIManager:getElapsedTimeSinceBoot()
    if not interactive and now - self.pull_timestamp <= API_CALL_DEBOUNCE_DELAY then
        logger.dbg("KOSyncCloud: We've already pulled progress less than 25s ago!")
        return
    end

    if ensure_networking and willRerunForServer(self.settings.sync_server, function()
        self:getProgress(ensure_networking, interactive)
    end) then
        return
    end

    local doc_digest = self:getDocumentDigest()
    if not doc_digest then
        logger.dbg("KOSyncCloud: getProgress missing doc_digest")
        if interactive then showSyncError() end
        return
    end
    logger.dbg("KOSyncCloud: getProgress doc_digest", doc_digest)

    UIManager:nextTick(function()
        runWithSyncModal(interactive, function()
            SyncService.sync(self.settings.sync_server, ProgressDB.getPath(), ProgressDB.onSync, not interactive)
        end)

        local body = ProgressDB.readProgress(doc_digest)
        logger.dbg("KOSyncCloud: [Pull] progress for", self.view.document.file)
        logger.dbg("KOSyncCloud: body:", body)
        if not body or not body.percentage then
            logger.dbg("KOSyncCloud: no progress in DB")
            if interactive then
                UIManager:show(InfoMessage:new{
                    text = _("No progress found for this document."),
                    timeout = 3,
                })
            end
            return
        end

        if body.device == Device.model and body.device_id == self.device_id then
            logger.dbg("KOSyncCloud: progress already from this device")
            if interactive then
                UIManager:show(InfoMessage:new{
                    text = _("Latest progress is coming from this device."),
                    timeout = 3,
                })
            end
            return
        end

        body.percentage = Math.roundPercent(body.percentage)
        local progress = self:getLastProgress()
        local percentage = self:getLastPercent()
        logger.dbg("KOSyncCloud: Current progress:", percentage * 100, "% =>", progress)

        if percentage == body.percentage or body.progress == progress then
            logger.dbg("KOSyncCloud: progress already synced")
            if interactive then
                UIManager:show(InfoMessage:new{
                    text = _("The progress has already been synchronized."),
                    timeout = 3,
                })
            end
            return
        end

        if interactive then
            logger.dbg("KOSyncCloud: interactive pull apply")
            self:syncToProgress(body.progress)
            showSyncedMessage()
            return
        end

        local self_older
        if body.timestamp ~= nil then
            self_older = (body.timestamp > self.last_page_turn_timestamp)
        else
            self_older = (body.percentage > percentage)
        end
        logger.dbg("KOSyncCloud: compare progress", self_older, body.timestamp, self.last_page_turn_timestamp)
        if self_older then
            if self.settings.sync_forward == SYNC_STRATEGY.SILENT then
                logger.dbg("KOSyncCloud: sync forward silently")
                self:syncToProgress(body.progress)
                showSyncedMessage()
            elseif self.settings.sync_forward == SYNC_STRATEGY.PROMPT then
                logger.dbg("KOSyncCloud: sync forward prompt")
                UIManager:show(ConfirmBox:new{
                    text = T(_("Sync to latest location %1% from device '%2'?"),
                             Math.round(body.percentage * 100),
                             body.device),
                    ok_callback = function()
                        self:syncToProgress(body.progress)
                    end,
                })
            end
        else
            if self.settings.sync_backward == SYNC_STRATEGY.SILENT then
                logger.dbg("KOSyncCloud: sync backward silently")
                self:syncToProgress(body.progress)
                showSyncedMessage()
            elseif self.settings.sync_backward == SYNC_STRATEGY.PROMPT then
                logger.dbg("KOSyncCloud: sync backward prompt")
                UIManager:show(ConfirmBox:new{
                    text = T(_("Sync to previous location %1% from device '%2'?"),
                             Math.round(body.percentage * 100),
                             body.device),
                    ok_callback = function()
                        self:syncToProgress(body.progress)
                    end,
                })
            end
        end
    end)

    self.pull_timestamp = now
end

function KOSyncCloud:_onCloseDocument()
    logger.dbg("KOSyncCloud: onCloseDocument")
    self.onResume = nil
    self.onSuspend = nil
    NetworkMgr:goOnlineToRun(function()
        self:updateProgress(false, false)
    end)
end

function KOSyncCloud:schedulePeriodicPush()
    UIManager:unschedule(self.periodic_push_task)
    UIManager:scheduleIn(10, self.periodic_push_task)
    self.periodic_push_scheduled = true
end

function KOSyncCloud:_onPageUpdate(page)
    if page == nil then
        return
    end

    if self.last_page ~= page then
        self.last_page = page
        self.last_page_turn_timestamp = os.time()
        self.page_update_counter = self.page_update_counter + 1
        if self.periodic_push_scheduled or self.settings.pages_before_update
            and self.page_update_counter >= self.settings.pages_before_update then
            self:schedulePeriodicPush()
        end
    end
end

function KOSyncCloud:_onResume()
    logger.dbg("KOSyncCloud: onResume")
    if Device:hasWifiRestore() and NetworkMgr.wifi_was_on and G_reader_settings:isTrue("auto_restore_wifi") then
        return
    end

    UIManager:scheduleIn(1, function()
        self:getProgress(true, false)
    end)
end

function KOSyncCloud:_onSuspend()
    logger.dbg("KOSyncCloud: onSuspend")
    self:updateProgress(true, false, true)
end

function KOSyncCloud:_onNetworkConnected()
    logger.dbg("KOSyncCloud: onNetworkConnected")
    UIManager:scheduleIn(0.5, function()
        self:getProgress(false, false)
    end)
end

function KOSyncCloud:_onNetworkDisconnecting()
    logger.dbg("KOSyncCloud: onNetworkDisconnecting")
    self:updateProgress(false, false)
end

function KOSyncCloud:onKOSyncCloudPushProgress()
    logger.dbg("KOSyncCloud: onKOSyncCloudPushProgress")
    self:updateProgress(true, true)
end

function KOSyncCloud:onKOSyncCloudPullProgress()
    logger.dbg("KOSyncCloud: onKOSyncCloudPullProgress")
    self:getProgress(true, true)
end

function KOSyncCloud:onKOSyncCloudToggleAutoSync(toggle, from_menu)
    logger.dbg("KOSyncCloud: onKOSyncCloudToggleAutoSync", toggle, from_menu)
    if toggle == self.settings.auto_sync then
        return true
    end
    if not self.settings.auto_sync
            and Device:hasSeamlessWifiToggle()
            and G_reader_settings:readSetting("wifi_enable_action") ~= "turn_on" then
        UIManager:show(InfoMessage:new{
            text = _("You will have to switch the 'Action when Wi-Fi is off' Network setting to 'turn on' to be able to enable this feature!")
        })
        return true
    end
    self.settings.auto_sync = not self.settings.auto_sync
    self:registerEvents()

    if self.settings.auto_sync then
        self:getProgress(true, true)
    elseif from_menu then
        self:updateProgress(true, true)
    end

    if not from_menu then
        Notification:notify(self.settings.auto_sync and _("Auto progress sync: on") or _("Auto progress sync: off"))
    end
    return true
end

function KOSyncCloud:registerEvents()
    logger.dbg("KOSyncCloud: registerEvents", self.settings.auto_sync)
    if self.settings.auto_sync then
        self.onCloseDocument = self._onCloseDocument
        self.onPageUpdate = self._onPageUpdate
        self.onResume = self._onResume
        self.onSuspend = self._onSuspend
        self.onNetworkConnected = self._onNetworkConnected
        self.onNetworkDisconnecting = self._onNetworkDisconnecting
    else
        self.onCloseDocument = nil
        self.onPageUpdate = nil
        self.onResume = nil
        self.onSuspend = nil
        self.onNetworkConnected = nil
        self.onNetworkDisconnecting = nil
    end
end

function KOSyncCloud:onCloseWidget()
    UIManager:unschedule(self.periodic_push_task)
    self.periodic_push_task = nil
end

return KOSyncCloud
