-- ============================================================
--  Housing Tour Manager
--  A queue management addon for housing tour raid groups.
-- ============================================================

HousingTourManager = {}
local HTM = HousingTourManager

-- Addon communication prefix (max 16 chars)
local ADDON_PREFIX = "HousingTourMgr"

-- Queue table: each entry = { name, house, plotNotes, status }
-- plotNotes: public notes announced to raid
-- status: "waiting" | "approved" | "done"
local queue = {}
local currentTab = "signup"

-- Raid Assist privilege settings (toggled by Raid Leader only)
local assistPrivileges = {
    canReorder  = false,
    canAnnounce = false,
    canRemove   = false,
}

-- ============================================================
--  UTILITY & PERMISSION HELPERS
--  (defined first so all functions below can call them)
-- ============================================================

local function GetPlayerRaidRank()
    if not IsInRaid() then
        return UnitIsGroupLeader("player") and 2 or 0
    end
    for i = 1, GetNumGroupMembers() do
        local name, rank = GetRaidRosterInfo(i)
        if name and UnitName("player") == name then
            return rank
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

local function CanManage()
    return IsRaidLeader()
end

local function CanReorder()
    if IsRaidLeader() then return true end
    return IsRaidAssist() and assistPrivileges.canReorder
end

local function CanAnnounce()
    if IsRaidLeader() then return true end
    return IsRaidAssist() and assistPrivileges.canAnnounce
end

local function CanRemove()
    if IsRaidLeader() then return true end
    return IsRaidAssist() and assistPrivileges.canRemove
end

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
    C_ChatInfo.RegisterAddonMessagePrefix(ADDON_PREFIX)

    SLASH_HOUSINGTOURMANAGER1 = "/htm"
    SLASH_HOUSINGTOURMANAGER2 = "/housingtour"
    SlashCmdList["HOUSINGTOURMANAGER"] = function(msg)
        HTM.ToggleWindow()
    end

    -- Initialise saved variables table if it doesn't exist yet
    if not HousingTourManagerSV then
        HousingTourManagerSV = {}
    end

    -- Restore previously saved field values into the Sign Up form
    if HousingTourManagerSV.savedHouse and HousingTourManagerSV.savedHouse ~= "" then
        HousingTourManagerFrameSignupTabHouseInput:SetText(HousingTourManagerSV.savedHouse)
    end
    if HousingTourManagerSV.savedPlotNotes and HousingTourManagerSV.savedPlotNotes ~= "" then
        HousingTourManagerFrameSignupTabPlotNotesInput:SetText(HousingTourManagerSV.savedPlotNotes)
    end

    local playerName = UnitName("player")
    HTM.UpdateSignupStatus("Welcome, " .. playerName .. "! Fill in your details and join the queue.")

    print("|cff00ccffHousing Tour Manager|r loaded! Type |cffff9900/htm|r to open.")
end

-- Saves the current Sign Up field values to saved variables
function HTM.SaveSignupFields()
    if not HousingTourManagerSV then HousingTourManagerSV = {} end
    HousingTourManagerSV.savedHouse     = HousingTourManagerFrameSignupTabHouseInput:GetText()
    HousingTourManagerSV.savedPlotNotes = HousingTourManagerFrameSignupTabPlotNotesInput:GetText()
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
    local house      = HousingTourManagerFrameSignupTabHouseInput:GetText()
    local plotNotes  = HousingTourManagerFrameSignupTabPlotNotesInput:GetText()

    if not house or house == "" then
        HTM.UpdateSignupStatus("|cffff4444Please enter the plot you want to add to the queue.|r")
        return
    end

    for _, entry in ipairs(queue) do
        if entry.name == playerName then
            HTM.UpdateSignupStatus("|cffff4444You are already in the queue! Leave first to re-register.|r")
            return
        end
    end

    local entry = {
        name      = playerName,
        house     = house,
        plotNotes = plotNotes or "",
        status    = "waiting",
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
    HTM.UpdateSignupStatus("|cffaaaaaaYou are not currently in the queue.|r")
end

function HTM.UpdateSignupStatus(msg)
    HousingTourManagerFrameSignupTabStatusText:SetText(msg)
end

-- ============================================================
--  QUEUE DISPLAY (read-only view)
-- ============================================================

function HTM.RefreshQueueDisplay()
    local content = HousingTourManagerFrameQueueTabScrollFrameContent
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

        local bg = row:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        if i % 2 == 0 then
            bg:SetColorTexture(0.1, 0.1, 0.1, 0.4)
        else
            bg:SetColorTexture(0.15, 0.15, 0.15, 0.4)
        end

        local statusColor = "|cffaaaaaa"
        if entry.status == "approved" then statusColor = "|cff00ff00"
        elseif entry.status == "done" then statusColor = "|cff888888" end

        local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        nameText:SetPoint("TOPLEFT", 6, -6)
        nameText:SetText(i .. ". " .. statusColor .. entry.name .. "|r")

        local houseStr = "Plot: |cffffd700" .. entry.house .. "|r"
        if entry.plotNotes ~= "" then
            houseStr = houseStr .. "  — " .. entry.plotNotes
        end
        local houseText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        houseText:SetPoint("TOPLEFT", 6, -22)
        houseText:SetText(houseStr)

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

    if IsRaidLeader() then
        local sectionLbl = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        sectionLbl:SetPoint("TOPLEFT", 4, yOffset)
        sectionLbl:SetText("|cffffd700Raid Assist Privileges|r")
        yOffset = yOffset - 18

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

        local removePrivBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
        removePrivBtn:SetSize(200, 24)
        removePrivBtn:SetPoint("TOPLEFT", 4, yOffset)
        local function UpdateRemovePrivLabel()
            removePrivBtn:SetText("Remove: " .. (assistPrivileges.canRemove and "|cff00ff00ON|r" or "|cffff4444OFF|r"))
        end
        UpdateRemovePrivLabel()
        removePrivBtn:SetScript("OnClick", function()
            HTM.SetAssistPrivilege("canRemove", not assistPrivileges.canRemove)
            UpdateRemovePrivLabel()
        end)

        yOffset = yOffset - 30

        local divider = content:CreateTexture(nil, "ARTWORK")
        divider:SetSize(420, 1)
        divider:SetPoint("TOPLEFT", 0, yOffset)
        divider:SetColorTexture(0.4, 0.4, 0.4, 0.6)
        yOffset = yOffset - 10

    elseif IsRaidAssist() then
        local privText = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        privText:SetPoint("TOPLEFT", 4, yOffset)
        local reorderStr  = assistPrivileges.canReorder  and "|cff00ff00Reorder|r"  or "|cff888888Reorder|r"
        local announceStr = assistPrivileges.canAnnounce and "|cff00ff00Announce|r" or "|cff888888Announce|r"
        local removeStr   = assistPrivileges.canRemove   and "|cff00ff00Remove|r"   or "|cff888888Remove|r"
        privText:SetText("Your privileges: " .. reorderStr .. "  " .. announceStr .. "  " .. removeStr)
        yOffset = yOffset - 24
    end

    if #queue == 0 then
        local lbl = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        lbl:SetPoint("TOPLEFT", 4, yOffset)
        lbl:SetText("The queue is currently empty.")
        content:SetHeight(math.abs(yOffset) + 30)
        return
    end

    local playerCanReorder = CanReorder()
    local playerCanManage  = CanManage()
    local playerCanRemove  = CanRemove()

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

        local houseStr = "Plot: |cffffd700" .. entry.house .. "|r"
        if entry.plotNotes ~= "" then
            houseStr = houseStr .. "  — " .. entry.plotNotes
        end
        local houseText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        houseText:SetPoint("TOPLEFT", 6, -20)
        houseText:SetText(houseStr)

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
        end

        if playerCanRemove then
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

        if playerCanReorder then
            -- Offset arrows left to avoid overlapping Approve or Remove buttons
            local arrowOffset     = (playerCanManage and -84) or (playerCanRemove and -84) or -4
            local arrowOffsetDown = (playerCanManage and -50) or (playerCanRemove and -50) or 30

            if i > 1 then
                local upBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
                upBtn:SetSize(30, 22)
                upBtn:SetPoint("TOPRIGHT", arrowOffset, -28)
                upBtn:SetText("Up")
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
                downBtn:SetPoint("TOPRIGHT", arrowOffsetDown, -28)
                downBtn:SetText("Dn")
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
            local msg = i .. ". " .. entry.name .. " — Plot: " .. entry.house
            if entry.plotNotes ~= "" then msg = msg .. " - " .. entry.plotNotes end
            SendChatMessage(msg, channel)
        end
    end
end

function HTM.AnnounceNext()
    if not CanAnnounce() then
        print("|cffff4444Housing Tour Manager:|r You don't have permission to announce the queue.")
        return
    end

    if #queue == 0 then
        local channel = IsInRaid() and "RAID" or (IsInGroup() and "PARTY" or "SAY")
        SendChatMessage("The housing tour queue is currently empty.", channel)
        return
    end

    local entry = queue[1]
    local channel = IsInRaid() and "RAID" or (IsInGroup() and "PARTY" or "SAY")
    local msg = "Next up: " .. entry.name .. " — Plot: " .. entry.house
    if entry.plotNotes ~= "" then msg = msg .. " - " .. entry.plotNotes end
    SendChatMessage(msg, channel)
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
    HTM.UpdateSignupStatus("|cffaaaaaaThe queue has been cleared by the Raid Leader.|r")
    print("|cff00ccffHousing Tour Manager:|r Queue cleared.")
end

-- ============================================================
--  ADDON MESSAGING (sync queue to all addon users in group)
-- ============================================================

function HTM.BroadcastQueue()
    if not IsInGroup() then return end

    -- Serialization format: name|house|plotNotes|status
    local parts = {}
    for _, entry in ipairs(queue) do
        local safe_house     = entry.house:gsub("[|;]", "")
        local safe_plotNotes = entry.plotNotes:gsub("[|;]", "")
        table.insert(parts, entry.name
            .. "|" .. safe_house
            .. "|" .. safe_plotNotes
            .. "|" .. entry.status)
    end
    local payload = table.concat(parts, ";")

    local channel = IsInRaid() and "RAID" or "PARTY"
    C_ChatInfo.SendAddonMessage(ADDON_PREFIX, "QUEUE:" .. payload, channel)
end

function HTM.OnAddonMessage(prefix, message, channel, sender)
    if prefix ~= ADDON_PREFIX then return end

    local playerName = UnitName("player")
    if sender == playerName then return end

    if message:sub(1, 5) == "PRIV:" then
        local payload = message:sub(6)
        local r, a, rm = payload:match("^([01]),([01]),([01])$")
        if r then
            assistPrivileges.canReorder  = (r  == "1")
            assistPrivileges.canAnnounce = (a  == "1")
            assistPrivileges.canRemove   = (rm == "1")
            HTM.RefreshManageDisplay()
        end
        return
    end

    if message:sub(1, 6) == "QUEUE:" then
        local payload = message:sub(7)
        queue = {}

        if payload ~= "" then
            for part in payload:gmatch("[^;]+") do
                -- name|house|plotNotes|status
                local name, house, plotNotes, status =
                    part:match("^([^|]+)|([^|]*)|([^|]*)|([^|]+)$")
                if name then
                    table.insert(queue, {
                        name      = name,
                        house     = house     or "",
                        plotNotes = plotNotes or "",
                        status    = status    or "waiting",
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

        -- Player is no longer in the queue (e.g. RL cleared it) — reset status text
        HTM.UpdateSignupStatus("|cffaaaaaaThe queue has been cleared by the Raid Leader.|r")
    end
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
    local label = key == "canReorder" and "Reorder" or key == "canAnnounce" and "Announce" or "Remove"
    local state = value and "|cff00ff00enabled|r" or "|cffff4444disabled|r"
    print("|cff00ccffHousing Tour Manager:|r Raid Assist privilege [" .. label .. "] " .. state .. ".")
end

function HTM.BroadcastPrivileges()
    if not IsInGroup() then return end
    local payload = "PRIV:" .. (assistPrivileges.canReorder and "1" or "0")
                           .. "," .. (assistPrivileges.canAnnounce and "1" or "0")
                           .. "," .. (assistPrivileges.canRemove and "1" or "0")
    local channel = IsInRaid() and "RAID" or "PARTY"
    C_ChatInfo.SendAddonMessage(ADDON_PREFIX, payload, channel)
end
