--------------------------------------------------------------
-- DK Grip Tracker — 职业核心技能充能冷却监控
-- 死亡骑士: 死亡之握 (25s / 2 充能)
-- 法师:     闪现     (15s / 2 充能)
-- 作者: DK-姜世离（燃烧之刃）
--------------------------------------------------------------
local addonName, ns = ...

-- ======== 职业配置 ========
-- classID: 6=死亡骑士, 8=法师
local CLASS_CONFIG = {
    [6] = {
        spellID       = 49576,                                    -- 死亡之握
        spellName     = "死亡之握",
        maxCharges    = 2,
        chargeCD      = 25,
        iconTextureID = 237532,                                   -- Spell_DeathKnight_Strangulate
        colorPrint    = "FF00FF00",                               -- 绿色
    },
    [8] = {
        spellID       = 1953,                                     -- 闪现 Blink
        spellName     = "闪现",
        maxCharges    = 2,
        chargeCD      = 15,
        iconTextureID = 135736,                                   -- Spell_Arcane_Blink
        colorPrint    = "FF40C0FF",                               -- 法师蓝
    },
}

-- ======== 常量 ========
local ICON_SIZE = 40

-- ======== 运行时配置（PLAYER_LOGIN 后赋值） ========
local cfg              -- 当前职业的配置（CLASS_CONFIG[classID]）
local TRACKED_SPELL_ID -- 当前追踪的技能 ID
local MAX_CHARGES      -- 当前最大充能
local CHARGE_COOLDOWN  -- 当前充能恢复时间

-- ======== 状态变量 ========
local charges    = 0
local cdQueue    = {}     -- 冷却队列: { expirationTime1, expirationTime2, ... }
local isDragging = false

-- ======== 保存变量 ========
local db -- SavedVariables reference

--------------------------------------------------------------
-- 工具函数
--------------------------------------------------------------
local function FormatTime(sec)
    if sec >= 10 then
        return string.format("%d", sec)
    else
        return string.format("%.1f", sec)
    end
end

local function PrintMsg(msg)
    local color = (cfg and cfg.colorPrint) or "FF00FF00"
    print("|c" .. color .. "[Grip Tracker]|r " .. msg)
end

--------------------------------------------------------------
-- UI 创建
--------------------------------------------------------------
local frame = CreateFrame("Button", "DKGripTrackerFrame", UIParent)
frame:SetSize(ICON_SIZE, ICON_SIZE)
frame:SetPoint("CENTER", UIParent, "CENTER", 0, -200)
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:SetClampedToScreen(true)

-- 图标纹理
local icon = frame:CreateTexture(nil, "ARTWORK")
icon:SetAllPoints()

-- 冷却模型（转圈圈）
local cooldownModel = CreateFrame("Cooldown", "DKGripTrackerCooldown", frame, "CooldownFrameTemplate")
cooldownModel:SetAllPoints()
cooldownModel:SetDrawSwipe(true)
cooldownModel:SetDrawBling(true)
cooldownModel:SetSwipeColor(0, 0, 0, 0.7)
cooldownModel:SetHideCountdownNumbers(true)

-- 冷却文字（中央大数字）
local cdText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
cdText:SetPoint("CENTER", frame, "CENTER", 0, 0)
cdText:SetFont(STANDARD_TEXT_FONT, 18, "OUTLINE")
cdText:SetTextColor(1, 1, 0.2)
cdText:SetText("")

-- 充能次数文字（右下角）
local chargeText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
chargeText:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -2, 2)
chargeText:SetFont(STANDARD_TEXT_FONT, 14, "OUTLINE")
chargeText:SetTextColor(1, 1, 1)

-- 变暗遮罩
local dimOverlay = frame:CreateTexture(nil, "OVERLAY")
dimOverlay:SetAllPoints()
dimOverlay:SetColorTexture(0, 0, 0, 0.55)
dimOverlay:Hide()

-- 边框
local border = frame:CreateTexture(nil, "OVERLAY", nil, 1)
border:SetPoint("TOPLEFT", frame, "TOPLEFT", -1, 1)
border:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 1, -1)
border:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
border:SetBlendMode("ADD")
border:SetAlpha(0.4)

-- 默认隐藏，等 PLAYER_LOGIN 确认职业后再显示
frame:Hide()

--------------------------------------------------------------
-- 拖拽支持
--------------------------------------------------------------
frame:SetScript("OnDragStart", function(self)
    if IsShiftKeyDown() then
        isDragging = true
        self:StartMoving()
    end
end)

frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    isDragging = false
    local point, _, relPoint, x, y = self:GetPoint()
    if db then
        db.point    = point
        db.relPoint = relPoint
        db.x        = x
        db.y        = y
    end
end)

-- 提示
frame:SetScript("OnEnter", function(self)
    if not cfg then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(cfg.spellName .. "追踪器", 1, 1, 1)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("操作说明:", 1, 0.82, 0)
    GameTooltip:AddLine("Shift+左键拖动移动位置", 0.7, 0.7, 0.7)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("设置命令:", 1, 0.82, 0)
    GameTooltip:AddLine("/dkgrip 或 /grip - 查看帮助", 0.7, 0.7, 0.7)
    GameTooltip:AddLine("/dkgrip reset - 重置位置", 0.7, 0.7, 0.7)
    GameTooltip:AddLine("/dkgrip sync - 同步游戏充能状态", 0.7, 0.7, 0.7)
    GameTooltip:AddLine("/dkgrip 50 - 设置图标大小(20-100)", 0.7, 0.7, 0.7)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("当前状态:", 1, 0.82, 0)
    GameTooltip:AddLine(string.format("充能: %d/%d", charges, MAX_CHARGES), 0.2, 1, 0.2)
    if #cdQueue > 0 then
        local now = GetTime()
        for i, expTime in ipairs(cdQueue) do
            local remain = expTime - now
            if remain > 0 then
                GameTooltip:AddLine(string.format("第%d层恢复: %.1f秒", i, remain), 1, 1, 0.2)
            end
        end
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddDoubleLine("作者:", "DK-姜世离（燃烧之刃）", 0.5, 0.5, 0.5, 0.5, 0.5, 0.5)
    GameTooltip:Show()
end)

frame:SetScript("OnLeave", function()
    GameTooltip:Hide()
end)

--------------------------------------------------------------
-- 充能 & 冷却 逻辑
--------------------------------------------------------------
local function UpdateDisplay()
    chargeText:SetText(tostring(charges))

    if charges >= MAX_CHARGES then
        chargeText:SetTextColor(1, 1, 1)
        dimOverlay:Hide()
        icon:SetDesaturated(false)
        cdText:SetText("")
        cooldownModel:Clear()
    elseif charges > 0 then
        chargeText:SetTextColor(1, 1, 1)
        dimOverlay:Hide()
        icon:SetDesaturated(false)
    else
        chargeText:SetTextColor(1, 0.2, 0.2)
        dimOverlay:Show()
        icon:SetDesaturated(true)
    end
end

local function ProcessCooldownQueue()
    local now = GetTime()

    while #cdQueue > 0 do
        if now >= cdQueue[1] then
            table.remove(cdQueue, 1)
            charges = math.min(charges + 1, MAX_CHARGES)
        else
            break
        end
    end

    if #cdQueue > 0 then
        local nextExpire = cdQueue[1]
        local remain = nextExpire - now
        if remain > 0 then
            cooldownModel:SetCooldown(nextExpire - CHARGE_COOLDOWN, CHARGE_COOLDOWN)
            cdText:SetText(FormatTime(remain))
            if charges == 0 then
                cdText:SetTextColor(1, 0.2, 0.2)
            else
                cdText:SetTextColor(1, 1, 0.2)
            end
        end
    else
        cdText:SetText("")
        cooldownModel:Clear()
    end

    UpdateDisplay()
end

local function OnSpellUsed()
    local now = GetTime()

    if charges > 0 then
        -- 正常情况：本地有充能，按原逻辑扣一层并入队
        charges = charges - 1
        if #cdQueue == 0 then
            table.insert(cdQueue, now + CHARGE_COOLDOWN)
        else
            local lastExpire = cdQueue[#cdQueue]
            table.insert(cdQueue, lastExpire + CHARGE_COOLDOWN)
        end
    else
        -- 矫正机制：本地 0 充能但技能竟然放成功了
        -- 说明被外部途径（操控时间/天赋/装备等）补充了充能
        -- 把队列首项重置为从现在重新计时，后续层依次跟随
        if #cdQueue == 0 then
            -- 极端兜底：连队列都空了，那就当作普通使用建一层 CD
            table.insert(cdQueue, now + CHARGE_COOLDOWN)
        else
            cdQueue[1] = now + CHARGE_COOLDOWN
            -- 后续层的起始 = 前一层的结束，连锁更新
            for i = 2, #cdQueue do
                cdQueue[i] = cdQueue[i - 1] + CHARGE_COOLDOWN
            end
        end
    end

    ProcessCooldownQueue()
end

--- 同步游戏内真实充能状态
local function SyncCharges(silent)
    local currentCharges, maxCharges, cooldownStart, cooldownDuration
    if C_Spell and C_Spell.GetSpellCharges then
        local info = C_Spell.GetSpellCharges(TRACKED_SPELL_ID)
        if info then
            currentCharges   = info.currentCharges
            maxCharges       = info.maxCharges
            cooldownStart    = info.cooldownStartTime
            cooldownDuration = info.cooldownDuration
        end
    elseif GetSpellCharges then
        currentCharges, maxCharges, cooldownStart, cooldownDuration = GetSpellCharges(TRACKED_SPELL_ID)
    end

    if currentCharges then
        charges = currentCharges
        cdQueue = {}

        if currentCharges < maxCharges and cooldownStart and cooldownStart > 0 and cooldownDuration and cooldownDuration > 0 then
            local expireTime = cooldownStart + cooldownDuration
            table.insert(cdQueue, expireTime)
            local missing = maxCharges - currentCharges
            for i = 2, missing do
                table.insert(cdQueue, expireTime + (i - 1) * CHARGE_COOLDOWN)
            end
        end

        ProcessCooldownQueue()
        if not silent then
            PrintMsg("已加载 — " .. cfg.spellName .. " 充能: " .. charges .. "/" .. MAX_CHARGES)
        end
        return true
    else
        if not silent then
            PrintMsg("|cFFFF6600未检测到 " .. cfg.spellName .. " 技能（可能尚未学习）|r")
        end
        return false
    end
end

--------------------------------------------------------------
-- OnUpdate 定时刷新
--------------------------------------------------------------
local elapsed_acc = 0
frame:SetScript("OnUpdate", function(self, elapsed)
    elapsed_acc = elapsed_acc + elapsed
    if elapsed_acc < 0.05 then return end
    elapsed_acc = 0
    if #cdQueue > 0 then
        ProcessCooldownQueue()
    end
end)

--------------------------------------------------------------
-- 事件处理
--------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local loadedAddon = ...
        if loadedAddon == addonName then
            DKGripTrackerDB = DKGripTrackerDB or {}
            db = DKGripTrackerDB

            if db.point then
                frame:ClearAllPoints()
                frame:SetPoint(db.point, UIParent, db.relPoint, db.x, db.y)
            end
            if db.iconSize then
                frame:SetSize(db.iconSize, db.iconSize)
            end

            self:UnregisterEvent("ADDON_LOADED")
        end

    elseif event == "PLAYER_LOGIN" then
        -- 职业检测：根据职业 ID 选择追踪的技能
        local _, _, classID = UnitClass("player")
        cfg = CLASS_CONFIG[classID]

        if not cfg then
            -- 不支持的职业：彻底隐藏，不再监听施法事件
            frame:Hide()
            self:UnregisterEvent("UNIT_SPELLCAST_SUCCEEDED")
            return
        end

        -- 应用当前职业配置
        TRACKED_SPELL_ID = cfg.spellID
        MAX_CHARGES      = cfg.maxCharges
        CHARGE_COOLDOWN  = cfg.chargeCD
        charges          = MAX_CHARGES

        icon:SetTexture(cfg.iconTextureID)
        frame:Show()

        -- 延迟同步，确保技能信息可用
        C_Timer.After(1, function() SyncCharges(false) end)

    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit, _, spellID = ...
        if unit == "player" and TRACKED_SPELL_ID and spellID == TRACKED_SPELL_ID then
            OnSpellUsed()
        end
    end
end)

--------------------------------------------------------------
-- 斜杠命令
--------------------------------------------------------------
SLASH_DKGRIP1 = "/dkgrip"
SLASH_DKGRIP2 = "/grip"
SlashCmdList["DKGRIP"] = function(msg)
    msg = string.lower(string.trim(msg or ""))

    if msg == "reset" then
        frame:ClearAllPoints()
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, -200)
        if db then
            db.point    = "CENTER"
            db.relPoint = "CENTER"
            db.x        = 0
            db.y        = -200
        end
        PrintMsg("位置已重置")

    elseif msg == "sync" then
        if not cfg then
            PrintMsg("|cFFFF6600当前职业不支持|r")
            return
        end
        if SyncCharges(true) then
            PrintMsg("已同步 — " .. cfg.spellName .. " 充能: " .. charges .. "/" .. MAX_CHARGES)
        else
            PrintMsg("|cFFFF6600同步失败，未检测到 " .. cfg.spellName .. "|r")
        end

    elseif tonumber(msg) then
        local size = tonumber(msg)
        if size >= 20 and size <= 100 then
            frame:SetSize(size, size)
            if db then db.iconSize = size end
            PrintMsg("图标大小设置为 " .. size)
        else
            PrintMsg("|cFFFF6600大小范围: 20-100|r")
        end

    else
        local skillLabel = cfg and cfg.spellName or "未启用（当前职业不支持）"
        PrintMsg("命令（当前追踪: " .. skillLabel .. "）:")
        print("  /dkgrip        — 显示帮助")
        print("  /dkgrip reset  — 重置位置到屏幕中央")
        print("  /dkgrip sync   — 同步游戏充能状态")
        print("  /dkgrip 50     — 设置图标大小(20-100)")
        print("  Shift+左键拖动 — 移动图标位置")
    end
end
