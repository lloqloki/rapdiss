local ADDON, ns = ...

local PREFIX = "LumenDiss"
local PROTO = "1"
local BASE_CHANCE = 0.01     -- 1% всем
local RACE_BONUS = 0.005     -- +0.5%, если есть дисы под твою расу
local CLASS_BONUS = 0.005    -- +0.5%, если есть дисы под твой класс
local COOLDOWN = 30          -- секунд между своими дисами (кроме теста)
local DELAY = 0.8            -- пауза перед дисом после начала боя
local CHUNK = 200            -- байт текста в одном сообщении аддона
local MAX_SEEN = 400
local RANGE = 100            -- "рядом": до 100 м, как обычная речь моба

local DEFAULTS = { bubble = true, showOthers = true, mass = false, share = true }

local DB, CharDB
local testMode = false
local lastDiss = -1e9
local fightDissed = false    -- в одном бою может быть только один дис
local seen, seenCount = {}, 0
local nameByGUID = {}
local cachedTarget = { guid = nil, name = nil, n = 0 }
local pending, done = {}, {}
local msgCounter = 0

-- ---------------------------------------------------------------- helpers

local function secret(v)
    return issecretvalue ~= nil and issecretvalue(v) or false
end

local function safe(v)
    if secret(v) then return nil end
    return v
end

-- true / false / nil (неизвестно: скрыто игрой)
local function flag(f, ...)
    if not f then return nil end
    local ok, v = pcall(f, ...)
    if not ok or secret(v) then return nil end
    return v and true or false
end

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffff7a3dLumen Diss:|r " .. msg)
end
ns.Print = Print

local function MyName()
    return safe(UnitName("player")) or "?"
end

local function ShortName(n)
    if not n then return nil end
    if Ambiguate then
        local ok, s = pcall(Ambiguate, n, "short")
        if ok and s then return s end
    end
    return (n:gsub("%-.*$", ""))
end

function ns.PlayerInfo()
    local _, race = UnitRace("player")
    local _, class = UnitClass("player")
    race, class = safe(race), safe(class)
    if race == "Undead" then race = "Scourge" end
    return race, class
end

-- ---------------------------------------------------------------- disses

local function Has(list, v)
    if not list then return true end
    for _, x in ipairs(list) do
        if x == v then return true end
    end
    return false
end

function ns.Candidates(race, class)
    local out, total = {}, 0
    for i, d in ipairs(ns.DISSES) do
        if Has(d.race, race) and Has(d.class, class) then
            local w = 1
            if d.race and d.class then w = 6 elseif d.race or d.class then w = 3 end
            out[#out + 1] = { i = i, w = w }
            total = total + w
        end
    end
    return out, total
end

function ns.Chance(race, class)
    local c = BASE_CHANCE
    local byRace, byClass = false, false
    for _, x in ipairs((ns.Candidates(race, class))) do
        local d = ns.DISSES[x.i]
        if d.race then byRace = true end
        if d.class then byClass = true end
    end
    if byRace then c = c + RACE_BONUS end
    if byClass then c = c + CLASS_BONUS end
    return c
end

function ns.Format(i, name)
    local text = ns.DISSES[i].text
    local repl = (name or ""):gsub("%%", "%%%%")
    return (text:gsub("{name}", repl))
end

function ns.Pick(race, class, name, rnd)
    local list, total = ns.Candidates(race, class)
    if total == 0 then return nil end
    local r = (rnd or math.random)() * total
    for _, c in ipairs(list) do
        r = r - c.w
        if r < 0 then return ns.Format(c.i, name), c.i end
    end
    local last = list[#list]
    return ns.Format(last.i, name), last.i
end

-- ---------------------------------------------------------------- bubble

local bubble

local function PortraitAnchor()
    local tf = _G.TargetFrame
    if not tf or not tf:IsShown() then return nil end
    return (tf.TargetFrameContainer and tf.TargetFrameContainer.Portrait)
        or _G.TargetFramePortrait or tf.Portrait or tf.portrait or tf
end

local function CreateBubble()
    local f = CreateFrame("Frame", "LumenDissBubble", UIParent, "BackdropTemplate")
    f:SetFrameStrata("HIGH")
    f:SetClampedToScreen(true)
    f:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 14,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    f:SetBackdropColor(0, 0, 0, 0.8)
    f:SetBackdropBorderColor(0.9, 0.9, 0.9, 0.9)

    f.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.text:SetPoint("CENTER")
    f.text:SetJustifyH("CENTER")
    f.text:SetJustifyV("MIDDLE")
    f.text:SetWordWrap(true)

    f.tail = f:CreateTexture(nil, "OVERLAY")
    f.tail:SetTexture("Interface\\Tooltips\\ChatBubble-Tail")
    f.tail:SetSize(16, 16)
    f.tail:SetPoint("TOP", f, "BOTTOM", 0, 3)

    f:Hide()
    f:SetScript("OnUpdate", function(self, elapsed)
        self.left = (self.left or 0) - elapsed
        if self.left <= 0 then
            self:Hide()
        elseif self.left < 1 then
            self:SetAlpha(self.left)
        end
    end)
    return f
end

function ns.ShowBubble(text, guid)
    if not DB.settings.bubble then return false end
    local anchor = PortraitAnchor()
    if not anchor then return false end
    bubble = bubble or CreateBubble()
    local maxW = 260
    bubble.text:SetWidth(maxW)
    bubble.text:SetText(text)
    local w = maxW
    if bubble.text.GetUnboundedStringWidth then
        w = math.min(maxW, (bubble.text:GetUnboundedStringWidth() or maxW) + 2)
    end
    bubble.text:SetWidth(w)
    local h = bubble.text:GetStringHeight() or 14
    bubble:SetSize(w + 22, h + 18)
    bubble:ClearAllPoints()
    bubble:SetPoint("BOTTOM", anchor, "TOP", 0, 10)
    bubble.guid = guid
    bubble.left = math.min(12, 5 + #text / 40)
    bubble:SetAlpha(1)
    bubble:Show()
    return true
end

local function HideBubbleIfOtherTarget()
    if bubble and bubble:IsShown() and bubble.guid ~= cachedTarget.guid then
        bubble:Hide()
    end
end

-- ---------------------------------------------------------------- chat line

local function ChatColor()
    local c = ChatTypeInfo and ChatTypeInfo.MONSTER_SAY
    if c and c.r then return c.r, c.g, c.b end
    return 1, 1, 0.62
end

function ns.ChatLine(mob, victim, text, zone)
    local line = string.format("|cffff7a3d%s|r дисит |cff40c8ff%s|r%s: %s",
        mob, victim, zone and (" (" .. zone .. ")") or "", text)
    local r, g, b = ChatColor()
    DEFAULT_CHAT_FRAME:AddMessage(line, r, g, b)
    return line
end

local function CountSeen(victim)
    DB.guild[victim] = (DB.guild[victim] or 0) + 1
end

-- ---------------------------------------------------------------- sharing

local function Channels(isTest)
    local list = {}
    if IsInGroup and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) and not IsInGroup(LE_PARTY_CATEGORY_HOME) then
        list[#list + 1] = "INSTANCE_CHAT"
    elseif IsInRaid and IsInRaid() then
        list[#list + 1] = "RAID"
    elseif IsInGroup and IsInGroup() then
        list[#list + 1] = "PARTY"
    end
    if not isTest and IsInGuild and IsInGuild() then
        list[#list + 1] = "GUILD"
    end
    return list
end

function ns.SplitUTF8(s, max)
    local parts, i, n = {}, 1, #s
    while i <= n do
        local j = math.min(i + max - 1, n)
        while j < n and j > i do
            local b = s:byte(j + 1)
            if b >= 0x80 and b < 0xC0 then j = j - 1 else break end
        end
        parts[#parts + 1] = s:sub(i, j)
        i = j + 1
    end
    return parts
end

local function Clean(s)
    return ((s or ""):gsub("[\t\r\n]", " "))
end

-- Мировые координаты игрока в ярдах (в подземельях игра их не дает - тогда nil)
function ns.Position()
    if not UnitPosition then return nil end
    local ok, y, x, _, inst = pcall(UnitPosition, "player")
    y, x, inst = safe(y), safe(x), safe(inst)
    if not ok or not x or not y then return nil end
    return { x = math.floor(x + 0.5), y = math.floor(y + 0.5), inst = inst or 0 }
end

function ns.Encode(id, mob, guid, victim, mapID, text, pos)
    local parts = ns.SplitUTF8(text, CHUNK)
    local msgs = { table.concat({ PROTO, "H", id, #parts, Clean(mob), guid or "", Clean(victim), mapID or 0,
        pos and pos.x or "", pos and pos.y or "", pos and pos.inst or "" }, "\t") }
    for k, p in ipairs(parts) do
        msgs[#msgs + 1] = table.concat({ PROTO, "P", id, k, p }, "\t")
    end
    return msgs
end

local function Share(mob, guid, victim, text)
    if not DB.settings.share then return end
    if not (C_ChatInfo and C_ChatInfo.SendAddonMessage) then return end
    msgCounter = msgCounter + 1
    local id = string.format("%s%d%d", MyName(), math.floor(GetTime()), msgCounter)
    local mapID = C_Map and C_Map.GetBestMapForUnit and safe(C_Map.GetBestMapForUnit("player")) or 0
    local msgs = ns.Encode(id, mob, guid, victim, mapID, text, ns.Position())
    for _, ch in ipairs(Channels(testMode)) do
        for _, m in ipairs(msgs) do
            pcall(C_ChatInfo.SendAddonMessage, PREFIX, m, ch)
        end
    end
end

local function ZoneName(mapID)
    mapID = tonumber(mapID)
    if not mapID or mapID == 0 then return nil end
    local here = C_Map and C_Map.GetBestMapForUnit and safe(C_Map.GetBestMapForUnit("player"))
    if here == mapID then return nil end
    local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(mapID)
    return info and info.name or nil
end

-- Рядом ли отправитель: по координатам, а в подземельях (координат нет) - по карте
function ns.IsNear(m)
    local me = ns.Position()
    if m.x and me then
        if m.inst ~= me.inst then return false end
        local dx, dy = m.x - me.x, m.y - me.y
        return dx * dx + dy * dy <= RANGE * RANGE
    end
    if m.x or me then return false end
    local here = C_Map and C_Map.GetBestMapForUnit and safe(C_Map.GetBestMapForUnit("player"))
    return here ~= nil and tonumber(m.map) == here
end

local function ShowRemote(m)
    done[m.id] = true
    pending[m.id] = nil
    if not DB.settings.mass and not ns.IsNear(m) then return end
    CountSeen(m.victim)
    if not DB.settings.showOthers then return end
    local buf = {}
    for k = 1, m.n do buf[k] = m.parts[k] or "" end
    local text = table.concat(buf)
    ns.ChatLine(m.mob ~= "" and m.mob or "Моб", m.victim, text, ZoneName(m.map))
    if m.guid ~= "" and m.guid == cachedTarget.guid then
        ns.ShowBubble(text, m.guid)
    end
end

function ns.OnAddonMessage(prefix, msg, channel, sender)
    if prefix ~= PREFIX or type(msg) ~= "string" then return end
    local who = ShortName(sender)
    if who == MyName() then return end
    local f = {}
    for x in (msg .. "\t"):gmatch("(.-)\t") do f[#f + 1] = x end
    if f[1] ~= PROTO then return end
    local kind, id = f[2], f[3]
    if not id or done[id] then return end
    local m = pending[id]
    if not m then
        m = { id = id, parts = {}, got = 0, t = GetTime() }
        pending[id] = m
    end
    if kind == "H" then
        m.n = tonumber(f[4]) or 1
        m.mob, m.guid, m.victim, m.map = f[5] or "", f[6] or "", f[7] or who, f[8]
        if m.victim == "" then m.victim = who end
        m.x, m.y, m.inst = tonumber(f[9] or ""), tonumber(f[10] or ""), tonumber(f[11] or "") or 0
        if not m.y then m.x = nil end
    elseif kind == "P" then
        local k = tonumber(f[4])
        if k and not m.parts[k] then
            m.parts[k] = f[5] or ""
            m.got = m.got + 1
        end
    else
        return
    end
    if m.n and m.got >= m.n then ShowRemote(m) end
    -- выбросить зависшие
    for k, v in pairs(pending) do
        if GetTime() - v.t > 30 then pending[k] = nil end
    end
end

-- ---------------------------------------------------------------- combat

local function CacheTarget()
    cachedTarget.n = cachedTarget.n + 1
    local guid = safe(UnitGUID("target"))
    local name = safe(UnitName("target"))
    cachedTarget.guid = guid
    cachedTarget.name = name or (guid and nameByGUID[guid]) or nil
    if guid and name then nameByGUID[guid] = name end
end

local function FightingTarget()
    if flag(UnitExists, "target") ~= true then return false end
    if flag(UnitIsPlayer, "target") ~= false then return false end
    if flag(UnitPlayerControlled, "target") == true then return false end
    if flag(UnitIsDead, "target") == true then return false end
    if flag(UnitCanAttack, "player", "target") == false then return false end
    if flag(UnitAffectingCombat, "player") == false then return false end
    if flag(UnitAffectingCombat, "target") == false then return false end
    -- моб должен драться именно с нами
    local ok, th = pcall(UnitThreatSituation, "player", "target")
    if not ok or secret(th) or th ~= nil then return true end
    return flag(UnitIsUnit, "targettarget", "player") == true
end

local function TargetKey()
    if cachedTarget.guid then return cachedTarget.guid end
    if cachedTarget.name then
        return cachedTarget.name .. ":" .. tostring(safe(UnitLevel("target")) or "?") .. ":" .. cachedTarget.n
    end
    return "t" .. cachedTarget.n
end

local function Remember(key)
    if seenCount >= MAX_SEEN then
        seen, seenCount = {}, 0
    end
    seen[key] = true
    seenCount = seenCount + 1
end

function ns.Diss(mob, guid, onTarget)
    local race, class = ns.PlayerInfo()
    local me = MyName()
    local text = ns.Pick(race, class, me)
    if not text then return end
    mob = mob or "Моб"
    ns.ChatLine(mob, me, text)
    if onTarget then ns.ShowBubble(text, guid) end
    CharDB.count = CharDB.count + 1
    CharDB.byMob[mob] = (CharDB.byMob[mob] or 0) + 1
    CharDB.last = { t = time(), mob = mob, text = text }
    CountSeen(me)
    Share(mob, guid, me, text)
    return text
end

function ns.Check()
    if not DB then return end
    if flag(UnitAffectingCombat, "player") == false then fightDissed = false end
    if fightDissed then return end
    if not FightingTarget() then return end
    local key = TargetKey()
    if seen[key] then return end
    Remember(key)
    if not testMode and GetTime() - lastDiss < COOLDOWN then return end
    local race, class = ns.PlayerInfo()
    local chance = testMode and 1 or ns.Chance(race, class)
    if math.random() >= chance then return end
    lastDiss = GetTime()
    fightDissed = true
    local guid, mob, n = cachedTarget.guid, cachedTarget.name, cachedTarget.n
    C_Timer.After(DELAY, function()
        -- цель сменилась - моб всё равно дисит, но пузырь только над своей целью
        ns.Diss(mob, guid, cachedTarget.n == n)
    end)
end

-- ---------------------------------------------------------------- settings

local function RegisterSettings()
    if not (Settings and Settings.RegisterVerticalLayoutCategory and Settings.RegisterAddOnSetting) then return end
    local ok = pcall(function()
        local cat = Settings.RegisterVerticalLayoutCategory("Lumen Diss")
        local function box(key, name, tip)
            local s = Settings.RegisterAddOnSetting(cat, "LumenDiss_" .. key, key, DB.settings, "boolean", name, DEFAULTS[key])
            Settings.CreateCheckbox(cat, s, tip)
        end
        box("bubble", "Пузырь с дисом над портретом моба",
            "Показывать текст диса над портретом цели. Строка в чате будет в любом случае.")
        box("showOthers", "Показывать дисы согильдийцев",
            "Строки в чате, когда мобы дисят других игроков с аддоном.")
        box("mass", "Массовое отображение",
            "Показывать дисы всех согильдийцев с аддоном, где бы они ни были. Выключено: только тех, кто рядом с тобой (до 100 м).")
        box("share", "Делиться своими дисами",
            "Отправлять свои дисы гильдии и группе, чтобы их видели все с аддоном.")
        Settings.RegisterAddOnCategory(cat)
        ns.category = cat
    end)
    return ok
end

local function OpenSettings()
    if ns.category and Settings and Settings.OpenToCategory then
        Settings.OpenToCategory(ns.category:GetID())
    else
        Print("окно настроек недоступно, используй /rap бабл")
    end
end

-- ---------------------------------------------------------------- slash

local function Top(tbl, n)
    local list = {}
    for k, v in pairs(tbl) do list[#list + 1] = { k, v } end
    table.sort(list, function(a, b) if a[2] ~= b[2] then return a[2] > b[2] end return a[1] < b[1] end)
    local out = {}
    for i = 1, math.min(n, #list) do out[#out + 1] = list[i][1] .. " " .. list[i][2] end
    return table.concat(out, ", ")
end

function ns.Stats()
    local race, class = ns.PlayerInfo()
    local n = CharDB.count
    Print(string.format("тебя задисили |cffffd100%d|r раз.", n))
    if n > 0 then
        Print("чаще всех дисят: " .. Top(CharDB.byMob, 5))
        local last = CharDB.last
        if last then
            Print(string.format("последний дис: %s, %s: %s", date("%d.%m %H:%M", last.t), last.mob, last.text))
        end
    end
    if next(DB.guild) then
        Print("кого дисили при тебе: " .. Top(DB.guild, 5))
    end
    Print(string.format("шанс диса: %.1f%%%s;   пузырь: %s;   чужие дисы: %s.",
        (testMode and 1 or ns.Chance(race, class)) * 100, testMode and " (тест)" or "",
        DB.settings.bubble and "вкл" or "выкл",
        not DB.settings.showOthers and "выкл" or (DB.settings.mass and "вся гильдия" or "только рядом")))
end

local function RapCommand(msg)
    -- lower() только для латиницы: на кириллице он зависит от локали
    msg = (msg or ""):gsub("[A-Z]", string.lower):gsub("^%s+", ""):gsub("%s+$", "")
    if msg == "" then
        ns.Stats()
    elseif msg == "настройки" or msg == "options" or msg == "config" then
        OpenSettings()
    elseif msg:match("^бабл") or msg:match("^пузырь") or msg:match("^bubble") then
        local arg = msg:match("%s(%S+)$")
        if arg == "вкл" or arg == "on" then
            DB.settings.bubble = true
        elseif arg == "выкл" or arg == "off" then
            DB.settings.bubble = false
        else
            DB.settings.bubble = not DB.settings.bubble
        end
        Print("пузырь над портретом " .. (DB.settings.bubble and "включен." or "выключен."))
    elseif msg == "масс" or msg == "все" or msg == "mass" then
        DB.settings.mass = not DB.settings.mass
        Print(DB.settings.mass and "видишь дисы всей гильдии." or "видишь только дисы рядом с тобой.")
    else
        Print("/rap - сколько тебя задисили;   /rap бабл - вкл/выкл пузырь;   /rap масс - дисы всей гильдии или только рядом;   /rap настройки;   /diss - тест 100%")
    end
end

local function DissCommand()
    testMode = not testMode
    if testMode then
        seen, seenCount = {}, 0
        lastDiss = -1e9
        fightDissed = false
        Print("тест: каждый моб, с которым начинаешь бой, дисит (100%). Дисы уходят только группе, не гильдии. /diss еще раз - выключить.")
        ns.Check()
    else
        Print("тест выключен, шанс снова обычный.")
    end
end

SLASH_LUMENRAP1 = "/rap"
SLASH_LUMENRAP2 = "/реп"
SlashCmdList.LUMENRAP = RapCommand
SLASH_LUMENDISS1 = "/diss"
SLASH_LUMENDISS2 = "/дис"
SlashCmdList.LUMENDISS = DissCommand

-- ---------------------------------------------------------------- events

local ev = CreateFrame("Frame")
ns.events = ev

local function Init()
    LumenDissDB = LumenDissDB or {}
    LumenDissCharDB = LumenDissCharDB or {}
    DB, CharDB = LumenDissDB, LumenDissCharDB
    DB.settings = DB.settings or {}
    for k, v in pairs(DEFAULTS) do
        if DB.settings[k] == nil then DB.settings[k] = v end
    end
    DB.guild = DB.guild or {}
    CharDB.count = CharDB.count or 0
    CharDB.byMob = CharDB.byMob or {}
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        pcall(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX)
    end
    RegisterSettings()
end

local function Reg(e)
    pcall(ev.RegisterEvent, ev, e)
end

ev:SetScript("OnEvent", function(_, e, a1, a2, a3, a4)
    if e == "ADDON_LOADED" then
        if a1 == ADDON then Init() end
    elseif e == "CHAT_MSG_ADDON" then
        ns.OnAddonMessage(a1, a2, a3, a4)
    elseif e == "PLAYER_TARGET_CHANGED" then
        CacheTarget()
        HideBubbleIfOtherTarget()
        ns.Check()
    elseif e == "PLAYER_REGEN_DISABLED" then
        ns.Check()
    elseif e == "PLAYER_REGEN_ENABLED" then
        fightDissed = false
    elseif a1 == "target" then
        ns.Check()
    end
end)

Reg("ADDON_LOADED")
Reg("CHAT_MSG_ADDON")
Reg("PLAYER_TARGET_CHANGED")
Reg("PLAYER_REGEN_DISABLED")
Reg("PLAYER_REGEN_ENABLED")
Reg("UNIT_THREAT_LIST_UPDATE")
Reg("UNIT_FLAGS")
Reg("UNIT_TARGET")

ns.SetTestMode = function(v) testMode = v end
