--------------------------------------------------------------
-- DK Grip Tracker — 死亡之握充能冷却监控
-- 作者: DK-姜世离（燃烧之刃）
--------------------------------------------------------------
local addonName, ns = ...

-- ======== 常量 ========
local DEATH_GRIP_SPELL_ID = 49576      -- 死亡之握 spellId
local MAX_CHARGES         = 2          -- 最大充能层数
local CHARGE_COOLDOWN     = 25         -- 每层充能恢复时间（秒）
local ICON_SIZE           = 40         -- 图标尺寸（像素）
local ICON_TEXTURE        = 237532     -- Spell_DeathKnight_Strangulate 纹理ID

-- ======== 状态变量 ========
local charges       = MAX_CHARGES      -- 当前可用充能层数
local cdQueue       = {}               -- 冷却队列: { expirationTime1, expirationTime2, ... }
local isDragging    = false

-- ======== 保存变量 ========
local db -- SavedVariables reference

--------------------------------------------------------------
-- 工具函数
--------------------------------------------------------------
local function FormatTime(sec)
    if sec >= 10 then
        return string.format("%d", sec)
    elseif sec >= 1 then
        return string.format("%.1f", sec)
    else
        return string.format("%.1f", sec)
    end
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
icon:SetTexture(ICON_TEXTURE)

-- 冷却模型（转圈圈）
local cooldownModel = CreateFrame("Cooldown", "DKGripTrackerCooldown", frame, "CooldownFrameTemplate")
cooldownModel:SetAllPoints()
cooldownModel:SetDrawSwipe(true)
cooldownModel:SetDrawBling(true)
cooldownModel:SetSwipeColor(0, 0, 0, 0.7)
cooldownModel:SetHideCountdownNumbers(true) -- 我们自己显示文字

-- 冷却文字（中央大数字，显示剩余秒数）
local cdText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
cdText:SetPoint("CENTER", frame, "CENTER", 0, 0)
cdText:SetFont(STANDARD_TEXT_FONT, 18, "OUTLINE")
cdText:SetTextColor(1, 1, 0.2)
cdText:SetText("")

-- 充能次数文字（右下角小数字）
local chargeText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
chargeText:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -2, 2)
chargeText:SetFont(STANDARD_TEXT_FONT, 14, "OUTLINE")
chargeText:SetTextColor(1, 1, 1)

-- 变暗遮罩（充能为 0 时变暗图标）
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
    -- 保存位置
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
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("死亡之握追踪器", 1, 1, 1)
    GameTooltip:AddLine("Shift+左键拖动移动位置", 0.7, 0.7, 0.7)
    GameTooltip:AddLine("右键点击锁定/解锁", 0.7, 0.7, 0.7)
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
    GameTooltip:Show()
end)

frame:SetScript("OnLeave", function()
    GameTooltip:Hide()
end)

--------------------------------------------------------------
-- 充能 & 冷却 逻辑
--------------------------------------------------------------

--- 更新 UI 显示
local function UpdateDisplay()
    -- 更新充能文字
    chargeText:SetText(tostring(charges))

    if charges >= MAX_CHARGES then
        -- 满充能: 图标明亮，无冷却，白色数字
        chargeText:SetTextColor(1, 1, 1)
        dimOverlay:Hide()
        icon:SetDesaturated(false)
        cdText:SetText("")
        cooldownModel:Clear()
    elseif charges > 0 then
        -- 有充能但不满: 图标正常亮，显示冷却（恢复下一层）
        chargeText:SetTextColor(1, 1, 1)
        dimOverlay:Hide()
        icon:SetDesaturated(false)
    else
        -- 0 充能: 图标变暗
        chargeText:SetTextColor(1, 0.2, 0.2)
        dimOverlay:Show()
        icon:SetDesaturated(true)
    end
end

--- 处理冷却队列恢复
local function ProcessCooldownQueue()
    local now = GetTime()

    -- 检查队列中是否有已到期的冷却
    while #cdQueue > 0 do
        if now >= cdQueue[1] then
            table.remove(cdQueue, 1)
            charges = math.min(charges + 1, MAX_CHARGES)
        else
            break
        end
    end

    -- 更新冷却转圈显示（总是显示最近一层的恢复进度）
    if #cdQueue > 0 then
        local nextExpire = cdQueue[1]
        local remain = nextExpire - now
        if remain > 0 then
            -- 设置冷却模型
            cooldownModel:SetCooldown(nextExpire - CHARGE_COOLDOWN, CHARGE_COOLDOWN)
            -- 冷却文字
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

--- 使用一次死亡之握（成功释放时调用）
local function OnGripUsed()
    if charges <= 0 then return end -- 防御性检查

    charges = charges - 1
    local now = GetTime()

    if #cdQueue == 0 then
        -- 队列为空，直接开始 25 秒冷却
        table.insert(cdQueue, now + CHARGE_COOLDOWN)
    else
        -- 队列中已有冷却，新的一层从上一层结束后开始
        local lastExpire = cdQueue[#cdQueue]
        table.insert(cdQueue, lastExpire + CHARGE_COOLDOWN)
    end

    ProcessCooldownQueue()
end

--------------------------------------------------------------
-- OnUpdate 定时刷新
--------------------------------------------------------------
local elapsed_acc = 0
frame:SetScript("OnUpdate", function(self, elapsed)
    elapsed_acc = elapsed_acc + elapsed
    if elapsed_acc < 0.05 then return end -- ~20fps 刷新
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
            -- 初始化 SavedVariables
            DKGripTrackerDB = DKGripTrackerDB or {}
            db = DKGripTrackerDB

            -- 恢复位置
            if db.point then
                frame:ClearAllPoints()
                frame:SetPoint(db.point, UIParent, db.relPoint, db.x, db.y)
            end

            -- 恢复图标大小
            if db.iconSize then
                frame:SetSize(db.iconSize, db.iconSize)
            end

            self:UnregisterEvent("ADDON_LOADED")
        end

    elseif event == "PLAYER_LOGIN" then
        -- 登录时同步游戏内真实充能状态
        local function SyncCharges()
            local currentCharges, maxCharges, cooldownStart, cooldownDuration, chargeModRate
            if C_Spell and C_Spell.GetSpellCharges then
                local info = C_Spell.GetSpellCharges(DEATH_GRIP_SPELL_ID)
                if info then
                    currentCharges    = info.currentCharges
                    maxCharges        = info.maxCharges
                    cooldownStart     = info.cooldownStartTime
                    cooldownDuration  = info.cooldownDuration
                    chargeModRate     = info.chargeModRate or 1
                end
            elseif GetSpellCharges then
                currentCharges, maxCharges, cooldownStart, cooldownDuration, chargeModRate = GetSpellCharges(DEATH_GRIP_SPELL_ID)
            end

            if currentCharges then
                charges = currentCharges
                cdQueue = {}

                if currentCharges < maxCharges and cooldownStart and cooldownStart > 0 and cooldownDuration and cooldownDuration > 0 then
                    -- 有正在恢复的层数
                    local expireTime = cooldownStart + cooldownDuration
                    table.insert(cdQueue, expireTime)

                    -- 如果缺少不止一层，后续层依次排列
                    local missing = maxCharges - currentCharges
                    for i = 2, missing do
                        table.insert(cdQueue, expireTime + (i - 1) * CHARGE_COOLDOWN)
                    end
                end

                ProcessCooldownQueue()
                print("|cFF00FF00[DK Grip Tracker]|r 已加载 — 当前充能: " .. charges .. "/" .. MAX_CHARGES)
            else
                -- 可能不是 DK 或者该技能不存在
                print("|cFFFF6600[DK Grip Tracker]|r 未检测到死亡之握技能（非DK或未学习该技能）")
            end
        end

        -- 延迟一点确保技能信息可用
        C_Timer.After(1, SyncCharges)

    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit, castGUID, spellID = ...
        if unit == "player" and spellID == DEATH_GRIP_SPELL_ID then
            OnGripUsed()
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
        -- 重置位置
        frame:ClearAllPoints()
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, -200)
        if db then
            db.point    = "CENTER"
            db.relPoint = "CENTER"
            db.x        = 0
            db.y        = -200
        end
        print("|cFF00FF00[DK Grip Tracker]|r 位置已重置")

    elseif msg == "sync" then
        -- 手动同步游戏状态
        local info
        if C_Spell and C_Spell.GetSpellCharges then
            info = C_Spell.GetSpellCharges(DEATH_GRIP_SPELL_ID)
        end
        if info then
            charges = info.currentCharges
            cdQueue = {}
            if info.currentCharges < info.maxCharges and info.cooldownStartTime > 0 then
                local expireTime = info.cooldownStartTime + info.cooldownDuration
                table.insert(cdQueue, expireTime)
                local missing = info.maxCharges - info.currentCharges
                for i = 2, missing do
                    table.insert(cdQueue, expireTime + (i - 1) * CHARGE_COOLDOWN)
                end
            end
            ProcessCooldownQueue()
            print("|cFF00FF00[DK Grip Tracker]|r 已同步 — 充能: " .. charges .. "/" .. MAX_CHARGES)
        else
            print("|cFFFF6600[DK Grip Tracker]|r 同步失败，未检测到死亡之握")
        end

    elseif tonumber(msg) then
        -- 设置图标大小
        local size = tonumber(msg)
        if size >= 20 and size <= 100 then
            frame:SetSize(size, size)
            if db then db.iconSize = size end
            print("|cFF00FF00[DK Grip Tracker]|r 图标大小设置为 " .. size)
        else
            print("|cFFFF6600[DK Grip Tracker]|r 大小范围: 20-100")
        end

    else
        print("|cFF00FF00[DK Grip Tracker]|r 命令:")
        print("  /dkgrip        — 显示帮助")
        print("  /dkgrip reset  — 重置位置到屏幕中央")
        print("  /dkgrip sync   — 同步游戏充能状态")
        print("  /dkgrip 50     — 设置图标大小(20-100)")
        print("  Shift+左键拖动 — 移动图标位置")
    end
end
