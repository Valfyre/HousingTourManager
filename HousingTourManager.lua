-- ============================================================
--  Housing Tour Manager
--  A queue management addon for housing tour raid groups.
-- ============================================================

HousingTourManager = {}
local HTM = HousingTourManager

-- Addon communication prefix (max 16 chars)
local ADDON_PREFIX = "HousingTourMgr"

-- Queue table: each entry = { name, house, notes, status }
-- status: "waiting" | "approved" | "done"
local queue = {}
local currentTab = "signup"

-- Raid Assist privilege settings (toggled by Raid Leader only)
local assistPrivileges = {
    canReorder  = false,  -- Raid Assists may reorder the queue
    canAnnounce = false,  -- Raid Assists may announce queue to raid chat
}

-- ============================================================
--  INITIALISATION
-- ============================================================

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("CHAT_MSG_ADDON")
eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local addonName = ...
        if addonName == "HousingTourManager" then
            HTM.Init()
        end
    elseif event == "CHAT_MSG_ADDON" then
        HTM.OnAddonMessage(...)
    elseif event == "GROUP_ROSTER_UPDATE" then
        HTM.RefreshQueueDisplay()
        HTM.RefreshManageDisplay()
    end
end)

function HTM.Init()
    -- Register addon comm prefix
    C_ChatInfo.RegisterAddonMessagePrefix(ADDON_PREFIX)

    -- Slash commands
    SLASH_HOUSINGTOURMANAGER1 = "/htm"
    SLASH_HOUSINGTOURMANAGER2 = "/housingtour"
    SlashCmdList["HOUSINGTOURMANAGER"] = function(msg)
        HTM.ToggleWindow()
    end

    -- Pre-fill player name in signup
    local playerName = UnitName("player")
    HTM.UpdateSignupStatus("Welcome, " .. playerName .. "! Fill in your details and join the queue.")

    print("|cff00ccffHousing Tour Manager|r loaded! Type |cffff9900/htm|r to open.")
end

-- ============================================================
--  WINDOW / TAB MANAGEMENT
-- ============================================================

function HTM.ToggleWindow()
    local f = HousingTourManagerFrame
    if f:IsShown() then
        f:Hide()
    else
        f:Show()
        HTM.ShowTab(currentTab)
    end
end

function HTM.ShowTab(tab)
    currentTab = tab

    HousingTourManagerFrameSignupTab:Hide()
    HousingTourManagerFrameQueueTab:Hide()
    HousingTourManagerFrameManageTab:Hide()

    if tab == "signup" then
        HousingTourManagerFrameSignupTab:Show()
    elseif tab == "queue" then
        HousingTourManagerFrameQueueTab:Show()
        HTM.RefreshQueueDisplay()
    elseif tab == "manage" then
        HousingTourManagerFrameManageTab:Show()
        HTM.RefreshManageDisplay()
    end
end

-- ============================================================
--  PLAYER ACTIONS
-- ============================================================

function HTM.SubmitSignup()
    local playerName = UnitName("player")
    local house = HousingTourManagerFrameSignupTabHouseInput:GetText()
    local notes = HousingTourManagerFrameSignupTabNotesInput:GetText()

    if not house or house == "" then
        HTM.UpdateSignupStatus("|cffff4444Please enter the house you want to tour.|r")
        return
    end

    -- Check if already in queue
    for _, entry in ipairs(queue) do
        if entry.name == playerName then
            HTM.UpdateSignupStatus("|cffff4444You are already in the queue! Leave first to re-register.|r")
            return
        end
    end

    local entry = {
        name   = playerName,
        house  = house,
        notes  = notes or "",
        status = "waiting",
    }
    table.insert(queue, entry)

    HTM.UpdateSignupStatus("|cff00ff00You have been added to the queue! Position: " .. #queue .. "|r")
    HTM.BroadcastQueue()
end

function HTM.LeaveQueue()
    local playerName = UnitName("player")
    for i, entry in ipairs(queue) do
        if entry.name == playerName then
            table.remove(queue, i)
            HTM.UpdateSignupStatus("|cffff9900You have left the queue.|r")
            HTM.BroadcastQueue()
            return
        end
    end
    HTM.UpdateSignupStatus("|cffaaaaааYou are not currently in the queue.|r")
end

function HTM.UpdateSignupStatus(msg)
    HousingTourManagerFrameSignupTabStatusText:SetText(msg)
end

-- ============================================================
--  QUEUE DISPLAY (read-only view)
-- ============================================================

function HTM.RefreshQueueDisplay()
    local content = HousingTourManagerFrameQueueTabScrollFrameContent
    -- Clear old rows
    for i = content:GetNumChildren(), 1, -1 do
        local child = select(i, content:GetChildren())
        child:Hide()
        child:SetParent(nil)
    end

    if #queue == 0 then
        local lbl = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        lbl:SetPoint("TOPLEFT", 4, -4)
        lbl:SetText("The queue is currently empty.")
        return
    end

    local yOffset = -4
    for i, entry in ipairs(queue) do
        local row = CreateFrame("Frame", nil, content)
        row:SetSize(420, 50)
        row:SetPoint("TOPLEFT", 0, yOffset)

        -- Background highlight
        local bg = row:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        if i % 2 == 0 then
            bg:SetColorTexture(0.1, 0.1, 0.1, 0.4)
        else
            bg:SetColorTexture(0.15, 0.15, 0.15, 0.4)
        end

        local statusColor = "|cffaaaaaa"
        if entry.status == "approved" then statusColor = "|cff00ff00"
        elseif entry.status == "done"     then statusColor = "|cff888888" end

        local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        nameText:SetPoint("TOPLEFT", 6, -6)
        nameText:SetText(i .. ". " .. statusColor .. entry.name .. "|r")

        local houseText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        houseText:SetPoint("TOPLEFT", 6, -22)
        houseText:SetText("House: |cffffd700" .. entry.house .. "|r" ..
            (entry.notes ~= "" and "  — " .. entry.notes or ""))

        yOffset = yOffset - 54
    end

    content:SetHeight(math.abs(yOffset) + 10)
end

-- ============================================================
--  MANAGE DISPLAY (Raid Leader view)
-- ============================================================

function HTM.RefreshManageDisplay()
    local content = HousingTourManagerFrameManageTabScrollFrameContent
    for i = content:GetNumChildren(), 1, -1 do
        local child = select(i, content:GetChildren())
        child:Hide()
        child:SetParent(nil)
    end

    local yOffset = -4

    -- ── Raid Assist Privileges section (RL only) ──────────────────
    if IsRaidLeader() then
        local sectionLbl = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        sectionLbl:SetPoint("TOPLEFT", 4, yOffset)
        sectionLbl:SetText("|cffffd700Raid Assist Privileges|r")
        yOffset = yOffset - 18

        -- Reorder toggle
        local reorderBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
        reorderBtn:SetSize(200, 24)
        reorderBtn:SetPoint("TOPLEFT", 4, yOffset)
        local function UpdateReorderLabel()
            reorderBtn:SetText("Reorder: " .. (assistPrivileges.canReorder and "|cff00ff00ON|r" or "|cffff4444OFF|r"))
        end
        UpdateReorderLabel()
        reorderBtn:SetScript("OnClick", function()
            HTM.SetAssistPrivilege("canReorder", not assistPrivileges.canReorder)
            UpdateReorderLabel()
        end)

        -- Announce toggle
        local announceBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
        announceBtn:SetSize(200, 24)
        announceBtn:SetPoint("TOPLEFT", 210, yOffset)
        local function UpdateAnnounceLabel()
            announceBtn:SetText("Announce: " .. (assistPrivileges.canAnnounce and "|cff00ff00ON|r" or "|cffff4444OFF|r"))
        end
        UpdateAnnounceLabel()
        announceBtn:SetScript("OnClick", function()
            HTM.SetAssistPrivilege("canAnnounce", not assistPrivileges.canAnnounce)
            UpdateAnnounceLabel()
        end)

        yOffset = yOffset - 30

        -- Divider
        local divider = content:CreateTexture(nil, "ARTWORK")
        divider:SetSize(420, 1)
        divider:SetPoint("TOPLEFT", 0, yOffset)
        divider:SetColorTexture(0.4, 0.4, 0.4, 0.6)
        yOffset = yOffset - 10

    elseif IsRaidAssist() then
        -- Show Assists their current privilege level
        local privText = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        privText:SetPoint("TOPLEFT", 4, yOffset)
        local reorderStr  = assistPrivileges.canReorder  and "|cff00ff00Reorder|r"  or "|cff888888Reorder|r"
        local announceStr = assistPrivileges.canAnnounce and "|cff00ff00Announce|r" or "|cff888888Announce|r"
        privText:SetText("Your privileges: " .. reorderStr .. "  " .. announceStr)
        yOffset = yOffset - 24
    end
    -- ─────────────────────────────────────────────────────────────

    if #queue == 0 then
        local lbl = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        lbl:SetPoint("TOPLEFT", 4, yOffset)
        lbl:SetText("The queue is currently empty.")
        content:SetHeight(math.abs(yOffset) + 30)
        return
    end

    local playerCanReorder = CanReorder()
    local playerCanManage  = CanManage()

    for i, entry in ipairs(queue) do
        local idx = i
        local row = CreateFrame("Frame", nil, content)
        row:SetSize(420, 56)
        row:SetPoint("TOPLEFT", 0, yOffset)

        local bg = row:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        if i % 2 == 0 then
            bg:SetColorTexture(0.1, 0.1, 0.1, 0.5)
        else
            bg:SetColorTexture(0.15, 0.15, 0.15, 0.5)
        end

        local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        nameText:SetPoint("TOPLEFT", 6, -4)
        local statusTag = entry.status == "approved" and " |cff00ff00[Approved]|r" or
                          entry.status == "done"     and " |cff888888[Done]|r"     or ""
        nameText:SetText(i .. ". " .. entry.name .. statusTag)

        local houseText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        houseText:SetPoint("TOPLEFT", 6, -20)
        houseText:SetText("House: |cffffd700" .. entry.house .. "|r" ..
            (entry.notes ~= "" and "  — " .. entry.notes or ""))

        -- Approve / Remove (RL only)
        if playerCanManage then
            local approveBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            approveBtn:SetSize(80, 22)
            approveBtn:SetPoint("TOPRIGHT", -84, -4)
            approveBtn:SetText(entry.status == "approved" and "Unapprove" or "Approve")
            approveBtn:SetScript("OnClick", function()
                if queue[idx] then
                    queue[idx].status = (queue[idx].status == "approved") and "waiting" or "approved"
                    HTM.BroadcastQueue()
                    HTM.RefreshManageDisplay()
                    HTM.RefreshQueueDisplay()
                end
            end)

            local removeBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            removeBtn:SetSize(70, 22)
            removeBtn:SetPoint("TOPRIGHT", -4, -4)
            removeBtn:SetText("Remove")
            removeBtn:SetScript("OnClick", function()
                if queue[idx] then
                    table.remove(queue, idx)
                    HTM.BroadcastQueue()
                    HTM.RefreshManageDisplay()
                    HTM.RefreshQueueDisplay()
                end
            end)
        end

        -- Move Up / Down (RL or privileged Assist)
        if playerCanReorder then
            if i > 1 then
                local upBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
                upBtn:SetSize(30, 22)
                upBtn:SetPoint("TOPRIGHT", playerCanManage and -84 or -4, -28)
                upBtn:SetText("▲")
                upBtn:SetScript("OnClick", function()
                    queue[idx], queue[idx-1] = queue[idx-1], queue[idx]
                    HTM.BroadcastQueue()
                    HTM.RefreshManageDisplay()
                    HTM.RefreshQueueDisplay()
                end)
            end

            if i < #queue then
                local downBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
                downBtn:SetSize(30, 22)
                downBtn:SetPoint("TOPRIGHT", playerCanManage and -50 or 30, -28)
                downBtn:SetText("▼")
                downBtn:SetScript("OnClick", function()
                    queue[idx], queue[idx+1] = queue[idx+1], queue[idx]
                    HTM.BroadcastQueue()
                    HTM.RefreshManageDisplay()
                    HTM.RefreshQueueDisplay()
                end)
            end
        end

        yOffset = yOffset - 60
    end

    content:SetHeight(math.abs(yOffset) + 10)
end

-- ============================================================
--  RAID LEADER TOOLS
-- ============================================================

function HTM.AnnounceQueue()
    if not CanAnnounce() then
        print("|cffff4444Housing Tour Manager:|r You don't have permission to announce the queue.")
        return
    end

    local channel = IsInRaid() and "RAID" or (IsInGroup() and "PARTY" or "SAY")

    SendChatMessage("=== Housing Tour Queue ===", channel)
    if #queue == 0 then
        SendChatMessage("The queue is currently empty.", channel)
    else
        for i, entry in ipairs(queue) do
            local statusStr = entry.status == "approved" and " [Approved]" or
                              entry.status == "done"     and " [Done]"     or ""
            local msg = i .. ". " .. entry.name .. " — House: " .. entry.house
            if entry.notes ~= "" then msg = msg .. " (" .. entry.notes .. ")" end
            msg = msg .. statusStr
            SendChatMessage(msg, channel)
        end
    end
end

function HTM.ClearQueue()
    if not CanManage() then
        print("|cffff4444Housing Tour Manager:|r Only the Raid Leader can clear the queue.")
        return
    end
    queue = {}
    HTM.BroadcastQueue()
    HTM.RefreshManageDisplay()
    HTM.RefreshQueueDisplay()
    print("|cff00ccffHousing Tour Manager:|r Queue cleared.")
end

-- ============================================================
--  ADDON MESSAGING (sync queue to all addon users in group)
-- ============================================================

function HTM.BroadcastQueue()
    if not IsInGroup() then return end

    -- Serialize queue to a simple string: name|house|notes|status ; ...
    local parts = {}
    for _, entry in ipairs(queue) do
        local safe_notes = entry.notes:gsub("[|;]", "")
        local safe_house = entry.house:gsub("[|;]", "")
        table.insert(parts, entry.name .. "|" .. safe_house .. "|" .. safe_notes .. "|" .. entry.status)
    end
    local payload = table.concat(parts, ";")

    local channel = IsInRaid() and "RAID" or "PARTY"
    C_ChatInfo.SendAddonMessage(ADDON_PREFIX, "QUEUE:" .. payload, channel)
end

function HTM.OnAddonMessage(prefix, message, channel, sender)
    if prefix ~= ADDON_PREFIX then return end

    local playerName = UnitName("player")
    if sender == playerName then return end

    -- ── Privilege sync (from Raid Leader) ────────────────────────
    if message:sub(1, 5) == "PRIV:" then
        local payload = message:sub(6)
        local r, a = payload:match("^([01]),([01])$")
        if r then
            assistPrivileges.canReorder  = (r == "1")
            assistPrivileges.canAnnounce = (a == "1")
            HTM.RefreshManageDisplay()
        end
        return
    end

    -- ── Queue sync ───────────────────────────────────────────────
    if message:sub(1, 6) == "QUEUE:" then
        local payload = message:sub(7)
        queue = {}

        if payload ~= "" then
            for part in payload:gmatch("[^;]+") do
                local name, house, notes, status = part:match("^([^|]+)|([^|]*)|([^|]*)|([^|]+)$")
                if name then
                    table.insert(queue, {
                        name   = name,
                        house  = house  or "",
                        notes  = notes  or "",
                        status = status or "waiting",
                    })
                end
            end
        end

        HTM.RefreshQueueDisplay()
        HTM.RefreshManageDisplay()

        for i, entry in ipairs(queue) do
            if entry.name == playerName then
                HTM.UpdateSignupStatus("|cff00ff00You are in the queue at position " .. i .. ".|r")
                return
            end
        end
    end
end

-- ============================================================
--  UTILITY & PERMISSION HELPERS
-- ============================================================

-- Returns the raid rank of the local player: 2=Leader, 1=Assist, 0=Member
local function GetPlayerRaidRank()
    if not IsInRaid() then
        return UnitIsGroupLeader("player") and 2 or 0
    end
    for i = 1, GetNumGroupMembers() do
        local name, rank = GetRaidRosterInfo(i)
        if name and UnitName("player") == name then
            return rank  -- 2=Leader, 1=Assist, 0=Member
        end
    end
    return 0
end

local function IsRaidLeader()
    return UnitIsGroupLeader("player")
end

local function IsRaidAssist()
    return GetPlayerRaidRank() == 1
end

-- Full management access: approve/remove/clear/change settings
local function CanManage()
    return IsRaidLeader()
end

-- Reorder access: RL always; Assists if privilege granted
local function CanReorder()
    if IsRaidLeader() then return true end
    return IsRaidAssist() and assistPrivileges.canReorder
end

-- Announce access: RL always; Assists if privilege granted
local function CanAnnounce()
    if IsRaidLeader() then return true end
    return IsRaidAssist() and assistPrivileges.canAnnounce
end

-- ============================================================
--  ASSIST PRIVILEGE MANAGEMENT
-- ============================================================

function HTM.SetAssistPrivilege(key, value)
    if not IsRaidLeader() then
        print("|cffff4444Housing Tour Manager:|r Only the Raid Leader can change privileges.")
        return
    end
    assistPrivileges[key] = value
    HTM.BroadcastPrivileges()
    HTM.RefreshManageDisplay()
    local label = key == "canReorder" and "Reorder" or "Announce"
    local state  = value and "|cff00ff00enabled|r" or "|cffff4444disabled|r"
    print("|cff00ccffHousing Tour Manager:|r Raid Assist privilege [" .. label .. "] " .. state .. ".")
end

function HTM.BroadcastPrivileges()
    if not IsInGroup() then return end
    local payload = "PRIV:" .. (assistPrivileges.canReorder and "1" or "0")
                           .. "," .. (assistPrivileges.canAnnounce and "1" or "0")
    local channel = IsInRaid() and "RAID" or "PARTY"
    C_ChatInfo.SendAddonMessage(ADDON_PREFIX, payload, channel)
end
