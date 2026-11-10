local ADDON, ns = ...

-- Аддон раньше назывался Lumen Diss. Имя для сообщений аддона прежнее, чтобы версии видели дисы друг друга.
local PREFIX = "LumenDiss"
local OLD_ADDON = "LumenDiss"
local PROTO = "1"
local BASE_CHANCE = 0.01     -- 1% всем
local RACE_BONUS = 0.005     -- +0.5%, если есть дисы под твою расу
local CLASS_BONUS = 0.005    -- +0.5%, если есть дисы под твой класс
local NAMED_FIRST = 0.05     -- именной дис: доля среди дисов, пока он ни разу не выпадал
local NAMED_AFTER = 0.01     -- и после того, как выпал
local BOSS_CHANCE = 0.25     -- первая встреча с боссом за BOSS_MEMORY
local BOSS_MEMORY = 2 * 3600 -- 2 часа
local COOLDOWN = 30          -- секунд между своими дисами (кроме теста и первой встречи с боссом)
local DELAY = 0.8            -- пауза перед дисом; за это время группа решает, кого дисят
local CHUNK = 200            -- байт текста в одном сообщении аддона
local MAX_SEEN = 400
local RANGE = 100            -- "рядом": до 100 м, как обычная речь моба
local TAKEN_FOR = 120        -- столько секунд моб считается занятым другим игроком группы

local BOOST = 2              -- "повышенные дисы": обычный шанс x2 (боссы не меняются)

local DEFAULTS = {
    bubble = true, bubbleStyle = "tooltip", bubbleScale = 100, bubbleTime = 0, bubbleOffset = 10,
    chat = true, boost = false,
    showOthers = true, mass = false, share = true, voice = false, voiceOthers = false,
}
-- границы чисел в настройках
local LIMITS = { bubbleScale = { 50, 200 }, bubbleTime = { 0, 15 }, bubbleOffset = { 0, 100 } }

-- дизайны пузыря
local WHITE = "Interface\\Buttons\\WHITE8X8"
local STYLES = {
    { key = "tooltip", label = "Подсказка",
      backdrop = { bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                   edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 } },
      bg = { 0, 0, 0, 0.8 }, border = { 0.9, 0.9, 0.9, 0.9 }, text = { 1, 1, 1 }, tail = true },
    { key = "dark", label = "Темный",
      backdrop = { bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 },
      bg = { 0.05, 0.05, 0.06, 0.88 }, border = { 0.35, 0.36, 0.4, 1 }, text = { 0.93, 0.93, 0.93 } },
    { key = "rap", label = "Рэп",
      backdrop = { bgFile = WHITE, edgeFile = WHITE, edgeSize = 2 },
      bg = { 0, 0, 0, 0.9 }, border = { 1, 0.48, 0.24, 1 }, text = { 1, 0.85, 0.6 } },
    { key = "scroll", label = "Свиток",
      backdrop = { bgFile = WHITE, edgeFile = WHITE, edgeSize = 2 },
      bg = { 0.93, 0.87, 0.72, 0.96 }, border = { 0.45, 0.3, 0.15, 1 }, text = { 0.25, 0.15, 0.05 }, noShadow = true },
    { key = "text", label = "Только текст", text = { 1, 0.82, 0.3 }, outline = true },
}
ns.STYLES = STYLES

local function StyleOf(key)
    for _, s in ipairs(STYLES) do if s.key == key then return s end end
    return STYLES[1]
end
local SOUND_DIR = "Interface\\AddOns\\" .. ADDON .. "\\Sounds\\"
local GROUP_CH = { PARTY = true, RAID = true, INSTANCE_CHAT = true }

local DB, CharDB
local testMode = false
local lastDiss = -1e9
local fightDissed = false    -- в одном бою может быть только один дис
local seen, seenCount = {}, 0
local nameByGUID = {}
local cachedTarget = { guid = nil, name = nil, n = 0 }
local pending, done = {}, {}
local mine = {}              -- номера своих сообщений: игра присылает их обратно
local myTag
local msgCounter = 0
local claims = {}            -- свои дисы, о которых сказали группе и ждем ответа
local taken = {}             -- мобы, которые уже дисят другого игрока группы

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
    DEFAULT_CHAT_FRAME:AddMessage("|cffff7a3dRapDiss:|r " .. msg)
end
ns.Print = Print

-- имя без фамилии: им подписаны дисы
local function MyName()
    return safe((UnitName("player"))) or "?"
end

-- В Forever у персонажа есть фамилия: "Имя", "Фамилия"
local function MyNames()
    local first, last = UnitName("player")
    return safe(first), safe(last)
end

-- нижний регистр для латиницы и кириллицы (lower() игры кириллицу не трогает), ё = е
function ns.Fold(s)
    s = (s or ""):gsub("[A-Z]", function(c) return string.char(c:byte() + 32) end)
    s = s:gsub("\208([\144-\175])", function(c)
        local b = c:byte()
        if b < 160 then return "\208" .. string.char(b + 32) end
        return "\209" .. string.char(b - 32)
    end)
    s = s:gsub("\208\129", "\208\181"):gsub("\209\145", "\208\181"):gsub("%s+", " ")
    return s
end

-- полное имя персонажа для именных дисов: "Имя Фамилия", без фамилии - просто имя
function ns.FullName()
    local first, last = MyNames()
    if not first then return nil end
    if last and last ~= "" then return first .. " " .. last end
    return first
end

-- Сообщение от меня самого? Имя приходит по-разному: "Имя", "Имя-Сервер", "Имя Фамилия"...
-- Главная защита - номера своих сообщений; это запасная, для полного совпадения имени.
function ns.IsMe(sender)
    if type(sender) ~= "string" then return false end
    local first, last = MyNames()
    if not first then return false end
    local s = ns.Fold(sender)
    local forms = {}
    if last and last ~= "" then
        forms[ns.Fold(first .. " " .. last)] = true
        forms[ns.Fold(first .. "-" .. last)] = true
    else
        forms[ns.Fold(first)] = true
    end
    if forms[s] then return true end
    local realm = GetRealmName and safe(GetRealmName())
    local base = s:match("^(.*)%-[^%-]*$")
    if realm and base and s == ns.Fold(base .. "-" .. realm) and forms[base] then return true end
    if not (last and last ~= "") and Ambiguate then
        local ok, short = pcall(Ambiguate, sender, "short")
        if ok and type(short) == "string" and forms[ns.Fold(short)] then return true end
    end
    return false
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

local function IsNamed(d, full)
    if not d.who then return true end
    if not full then return false end
    local f = ns.Fold(full)
    for _, n in ipairs(d.who) do
        if ns.Fold(n) == f then return true end
    end
    return false
end

-- обычные дисы для расы и класса (именные идут отдельно, см. ns.Named)
function ns.Candidates(race, class)
    local out, total = {}, 0
    for i, d in ipairs(ns.DISSES) do
        if not d.who and Has(d.race, race) and Has(d.class, class) then
            local w = 1
            if d.race and d.class then w = 6 elseif d.race or d.class then w = 3 end
            out[#out + 1] = { i = i, w = w }
            total = total + w
        end
    end
    return out, total
end

-- именные дисы этого персонажа (full - "Имя Фамилия")
function ns.Named(full)
    local out = {}
    for i, d in ipairs(ns.DISSES) do
        if d.who and IsNamed(d, full) then out[#out + 1] = i end
    end
    return out
end

-- доля именного диса: 5%, пока не выпадал, потом 1%
function ns.NamedShare(i, seenNamed)
    local text = ns.DISSES[i].text
    return (seenNamed and seenNamed[text]) and NAMED_AFTER or NAMED_FIRST
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

-- шанс обычного диса с учетом режима повышенных дисов (на боссов не влияет)
function ns.EffectiveChance(race, class)
    local c = ns.Chance(race, class)
    if DB and DB.settings.boost then c = c * BOOST end
    return c
end

function ns.Format(i, name)
    local text = ns.DISSES[i].text
    local repl = (name or ""):gsub("%%", "%%%%")
    return (text:gsub("{name}", repl))
end

-- full: полное имя для именных дисов; seenNamed: какие именные уже выпадали этому персонажу
function ns.Pick(race, class, name, rnd, full, seenNamed)
    rnd = rnd or math.random
    for _, i in ipairs(ns.Named(full)) do
        if rnd() < ns.NamedShare(i, seenNamed) then return ns.Format(i, name), i, true end
    end
    local list, total = ns.Candidates(race, class)
    if total == 0 then return nil end
    local r = rnd() * total
    for _, c in ipairs(list) do
        r = r - c.w
        if r < 0 then return ns.Format(c.i, name), c.i end
    end
    local last = list[#list]
    return ns.Format(last.i, name), last.i
end

-- ---------------------------------------------------------------- voice
-- Записей голоса пока нет: настройки озвучки спрятаны, код ждет файлов Sounds\NN.ogg.

local soundHandle

function ns.SoundPath(i)
    local d = i and ns.DISSES[i]
    if not d or not d.snd then return nil end
    return SOUND_DIR .. d.snd .. ".ogg"
end

-- Номер диса по тексту: в чужих сообщениях приходит только текст
function ns.FindDiss(text, victim)
    for i in ipairs(ns.DISSES) do
        if ns.Format(i, victim) == text then return i end
    end
    return nil
end

function ns.PlayDiss(i)
    local path = ns.SoundPath(i)
    if not path or not PlaySoundFile then return false end
    if soundHandle and StopSound then pcall(StopSound, soundHandle, 300) end
    local ok, willPlay, handle = pcall(PlaySoundFile, path, "Master")
    soundHandle = ok and willPlay and handle or nil
    return (ok and willPlay) and true or false
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
    local f = CreateFrame("Frame", "RapDissBubble", UIParent, "BackdropTemplate")
    f:SetFrameStrata("HIGH")
    f:SetClampedToScreen(true)

    f.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.text:SetPoint("CENTER")
    f.text:SetJustifyH("CENTER")
    f.text:SetJustifyV("MIDDLE")
    f.text:SetWordWrap(true)
    f.font, f.fontSize = f.text:GetFont()

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

-- дизайн и размер из настроек
local function ApplyStyle(f)
    local st = StyleOf(DB.settings.bubbleStyle)
    if st.backdrop then
        f:SetBackdrop(st.backdrop)
        f:SetBackdropColor(st.bg[1], st.bg[2], st.bg[3], st.bg[4])
        f:SetBackdropBorderColor(st.border[1], st.border[2], st.border[3], st.border[4])
    else
        f:SetBackdrop(nil)
    end
    f.text:SetTextColor(st.text[1], st.text[2], st.text[3])
    if f.font then f.text:SetFont(f.font, f.fontSize or 12, st.outline and "OUTLINE" or "") end
    if st.noShadow then f.text:SetShadowOffset(0, 0) else f.text:SetShadowOffset(1, -1) end
    f.tail:SetShown(st.tail and true or false)
    f:SetScale((DB.settings.bubbleScale or 100) / 100)
    f.style = st.key
end

-- preview: пример из настроек - виден и с выключенным пузырем, а без цели посреди экрана
function ns.ShowBubble(text, guid, preview)
    if not DB.settings.bubble and not preview then return false end
    local anchor = PortraitAnchor()
    if not anchor and not preview then return false end
    bubble = bubble or CreateBubble()
    ApplyStyle(bubble)
    local maxW = 260
    bubble.text:SetWidth(maxW)
    bubble.text:SetText(text)
    local w = maxW
    if bubble.text.GetUnboundedStringWidth then
        w = math.min(maxW, (bubble.text:GetUnboundedStringWidth() or maxW) + 2)
    end
    bubble.text:SetWidth(w)
    local h = bubble.text:GetStringHeight() or 14
    local bare = bubble.style == "text"
    bubble:SetSize(w + (bare and 4 or 22), h + (bare and 4 or 18))
    bubble:ClearAllPoints()
    if anchor then
        bubble:SetPoint("BOTTOM", anchor, "TOP", 0, DB.settings.bubbleOffset)
    else
        bubble:SetPoint("CENTER", UIParent, "CENTER", 0, 150)
    end
    bubble.guid, bubble.shownText, bubble.preview = guid, text, preview
    local t = DB.settings.bubbleTime
    bubble.left = (t and t > 0) and t or math.min(12, 5 + #text / 40)
    bubble:SetAlpha(1)
    bubble:Show()
    return true
end

-- настройки поменялись: показанный пузырь сразу в новом виде
function ns.RefreshBubble()
    if not (bubble and bubble:IsShown() and bubble.shownText) then return end
    if not ns.ShowBubble(bubble.shownText, bubble.guid, bubble.preview) then bubble:Hide() end
end

function ns.Preview()
    return ns.ShowBubble("Так выглядит дис: твой реп - это полный провал", cachedTarget.guid, true)
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

local function GroupChannel()
    if IsInGroup and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) and not IsInGroup(LE_PARTY_CATEGORY_HOME) then
        return "INSTANCE_CHAT"
    elseif IsInRaid and IsInRaid() then
        return "RAID"
    elseif IsInGroup and IsInGroup() then
        return "PARTY"
    end
end

local function Channels(isTest)
    local list = {}
    local g = GroupChannel()
    if g then list[#list + 1] = g end
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

-- номер нового своего сообщения; запоминается, чтобы не показать свой дис второй раз
local function NewID()
    if not myTag then
        myTag = string.format("%x%x", math.floor((GetTime() or 0) * 1000) % 0x1000000, math.floor(math.random() * 0x1000000))
    end
    msgCounter = msgCounter + 1
    local id = myTag .. "." .. msgCounter
    mine[id] = true
    return id
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
    local id = NewID()
    local mapID = C_Map and C_Map.GetBestMapForUnit and safe(C_Map.GetBestMapForUnit("player")) or 0
    local msgs = ns.Encode(id, mob, guid, victim, mapID, text, ns.Position())
    for _, ch in ipairs(Channels(testMode)) do
        for _, m in ipairs(msgs) do
            pcall(C_ChatInfo.SendAddonMessage, PREFIX, m, ch)
        end
    end
end

-- ---------------------------------------------------------------- one victim per mob in a group
-- Перед дисом аддон говорит группе "этот моб мой" с жребием. Кто вытянул меньший жребий,
-- того и дисят; остальным этот моб уже не дисит. Моб узнается по GUID, а если его не видно - по имени.

local function SameMob(g1, n1, g2, n2)
    if g1 and g1 ~= "" and g2 and g2 ~= "" then return g1 == g2 end
    return n1 ~= nil and n1 ~= "" and n1 == n2
end

local function Take(guid, name)
    taken[#taken + 1] = { guid = guid, name = name, t = GetTime() }
end

function ns.Taken(guid, name)
    local now, keep, hit = GetTime(), {}, false
    for _, x in ipairs(taken) do
        if now - x.t <= TAKEN_FOR then
            keep[#keep + 1] = x
            if SameMob(guid, name, x.guid, x.name) then hit = true end
        end
    end
    taken = keep
    return hit
end

-- сказать группе о своем дисе; nil, если группы нет
function ns.Claim(guid, name)
    local ch = GroupChannel()
    if not ch or not (C_ChatInfo and C_ChatInfo.SendAddonMessage) then return nil end
    local c = { guid = guid, name = name, token = math.random(1, 999999999) }
    local msg = table.concat({ PROTO, "C", NewID(), Clean(guid), Clean(name), c.token }, "\t")
    pcall(C_ChatInfo.SendAddonMessage, PREFIX, msg, ch)
    claims[c] = true
    return c
end

-- другой игрок группы проиграл бы мне - значит, моб мой; иначе моб его
local function OnClaim(f)
    local guid, name, token = f[4] or "", f[5] or "", tonumber(f[6]) or 0
    local mineWins = false
    for c in pairs(claims) do
        if not c.lost and SameMob(c.guid, c.name, guid, name) then
            if token < c.token then c.lost = true else mineWins = true end
        end
    end
    if not mineWins then Take(guid, name) end
end

-- моб уже дисит другого игрока группы: свои ожидающие дисы на него отменяются
local function LoseClaims(guid, name)
    for c in pairs(claims) do
        if SameMob(c.guid, c.name, guid, name) then c.lost = true end
    end
end

-- ---------------------------------------------------------------- receiving

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
    local near = ns.IsNear(m)
    if not DB.settings.mass and not near then return end
    CountSeen(m.victim)
    if not DB.settings.showOthers then return end
    local buf = {}
    for k = 1, m.n do buf[k] = m.parts[k] or "" end
    local text = table.concat(buf)
    if DB.settings.chat then ns.ChatLine(m.mob ~= "" and m.mob or "Моб", m.victim, text, ZoneName(m.map)) end
    if m.guid ~= "" and m.guid == cachedTarget.guid then
        ns.ShowBubble(text, m.guid)
    end
    -- голос слышно только рядом, даже при массовом отображении
    if DB.settings.voiceOthers and near then
        ns.PlayDiss(ns.FindDiss(text, m.victim))
    end
end

function ns.OnAddonMessage(prefix, msg, channel, sender)
    if prefix ~= PREFIX or type(msg) ~= "string" then return end
    local f = {}
    for x in (msg .. "\t"):gmatch("(.-)\t") do f[#f + 1] = x end
    if f[1] ~= PROTO then return end
    local kind, id = f[2], f[3]
    if not id or id == "" or mine[id] then return end   -- свое сообщение вернулось
    if ns.IsMe(sender) then return end
    if kind == "C" then
        if GROUP_CH[channel] then OnClaim(f) end
        return
    end
    -- моба из группы уже дисят: он мой больше не дисит (до проверки повторов - та же копия идет и гильдии)
    if kind == "H" and GROUP_CH[channel] then
        Take(f[6] or "", f[5] or "")
        LoseClaims(f[6] or "", f[5] or "")
    end
    if done[id] then return end
    local who = sender or "?"
    if Ambiguate then
        local ok, s = pcall(Ambiguate, who, "short")
        if ok and type(s) == "string" and s ~= "" then who = s end
    end
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
        pending[id] = nil
        return
    end
    if m.n and m.got >= m.n then ShowRemote(m) end
    -- выбросить зависшие
    for k, v in pairs(pending) do
        if GetTime() - v.t > 30 then pending[k] = nil end
    end
end

-- ---------------------------------------------------------------- bosses

local journalBosses
-- npcID боссов из ForeverDungeonJournal, если он стоит
local function JournalBosses()
    if journalBosses then return journalBosses end
    journalBosses = {}
    local FDJ = _G.ForeverDungeonJournal_NS
    if type(FDJ) == "table" and type(FDJ.DB) == "table" then
        for _, d in pairs(FDJ.DB) do
            for _, b in ipairs(type(d) == "table" and d.bosses or {}) do
                if tonumber(b.npcID) then journalBosses[tonumber(b.npcID)] = true end
            end
        end
    end
    return journalBosses
end

function ns.NpcID(guid)
    return guid and tonumber(guid:match("^%a+%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")) or nil
end

-- цель - босс? По признакам игры (рамки боссов, "босс", череп) и по списку боссов журнала
function ns.TargetIsBoss(guid)
    if flag(UnitIsBossMob, "target") == true then return true end
    local ok, cls = pcall(UnitClassification, "target")
    if ok and safe(cls) == "worldboss" then return true end
    if safe(UnitLevel("target")) == -1 then return true end
    for i = 1, 5 do
        if flag(UnitIsUnit, "target", "boss" .. i) == true then return true end
    end
    local npc = ns.NpcID(guid)
    return npc ~= nil and JournalBosses()[npc] == true
end

-- первая встреча с этим боссом за 2 часа? Встреча запоминается.
function ns.MeetBoss(key)
    if not key then return false end
    local now = time()
    local last = CharDB.bosses[key]
    CharDB.bosses[key] = now
    return not last or now - last >= BOSS_MEMORY
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
    local text, idx, named = ns.Pick(race, class, me, nil, ns.FullName(), CharDB.namedSeen)
    if not text then return end
    if named then CharDB.namedSeen[ns.DISSES[idx].text] = true end
    mob = mob or "Моб"
    if DB.settings.chat then ns.ChatLine(mob, me, text) end
    if onTarget then ns.ShowBubble(text, guid) end
    if DB.settings.voice then ns.PlayDiss(idx) end
    CharDB.count = CharDB.count + 1
    CharDB.byMob[mob] = (CharDB.byMob[mob] or 0) + 1
    CharDB.last = { t = time(), mob = mob, text = text }
    CountSeen(me)
    Share(mob, guid, me, text)
    return text
end

function ns.Check()
    if not DB or ns.passive then return end
    if flag(UnitAffectingCombat, "player") == false then fightDissed = false end
    if fightDissed then return end
    if not FightingTarget() then return end
    local key = TargetKey()
    if seen[key] then return end
    Remember(key)
    local guid, mob, n = cachedTarget.guid, cachedTarget.name, cachedTarget.n
    local firstBoss = ns.TargetIsBoss(guid) and ns.MeetBoss(ns.NpcID(guid) or mob)
    if not testMode and not firstBoss and GetTime() - lastDiss < COOLDOWN then return end
    local race, class = ns.PlayerInfo()
    local chance = testMode and 1 or (firstBoss and BOSS_CHANCE or ns.EffectiveChance(race, class))
    if math.random() >= chance then return end
    if ns.Taken(guid, mob) then return end          -- этот моб уже дисит другого из группы
    local before = lastDiss
    lastDiss = GetTime()
    fightDissed = true
    local c = ns.Claim(guid, mob)
    C_Timer.After(DELAY, function()
        if c then claims[c] = nil end
        if (c and c.lost) or ns.Taken(guid, mob) then
            -- дис достался другому игроку группы: этот бой и пауза не потрачены
            lastDiss = before
            fightDissed = false
            return
        end
        -- цель сменилась - моб все равно дисит, но пузырь только над своей целью
        ns.Diss(mob, guid, cachedTarget.n == n)
    end)
end

-- ---------------------------------------------------------------- settings

-- Окно "Настройки -> AddOns -> RapDiss". Каждый пункт ставится отдельно: если игра не знает
-- какого-то элемента, остальные все равно появятся. Все то же есть и командами /rap.
local function RegisterSettings()
    if not (Settings and Settings.RegisterVerticalLayoutCategory and Settings.RegisterAddOnSetting) then return end
    local ok = pcall(function()
        local cat, layout = Settings.RegisterVerticalLayoutCategory("RapDiss")
        local function setting(key, name)
            local s = Settings.RegisterAddOnSetting(cat, "RapDiss_" .. key, key, DB.settings, type(DEFAULTS[key]), name, DEFAULTS[key])
            if s and s.SetValueChangedCallback then
                pcall(s.SetValueChangedCallback, s, function() ns.RefreshBubble() end)
            end
            return s
        end
        local function header(text)
            if layout and CreateSettingsListSectionHeaderInitializer then
                layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(text))
            end
        end
        local function box(key, name, tip)
            Settings.CreateCheckbox(cat, setting(key, name), tip)
        end
        local function slider(key, name, tip, step, label)
            local s = setting(key, name)
            local lim = LIMITS[key]
            local o = Settings.CreateSliderOptions(lim[1], lim[2], step)
            if o.SetLabelFormatter and MinimalSliderWithSteppersMixin then
                o:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, label)
            end
            Settings.CreateSlider(cat, s, o, tip)
        end
        local function styles()
            local c = Settings.CreateControlTextContainer()
            for _, st in ipairs(STYLES) do c:Add(st.key, st.label) end
            return c:GetData()
        end
        local function try(fn, ...) pcall(fn, ...) end

        try(header, "Пузырь над портретом")
        try(box, "bubble", "Пузырь с дисом",
            "Показывать текст диса над портретом цели.")
        try(function()
            local s = setting("bubbleStyle", "Дизайн")
            local create = Settings.CreateDropdown or Settings.CreateDropDown
            create(cat, s, styles, "Как выглядит пузырь: подсказка, темный, рэп, свиток или только текст.")
        end)
        try(slider, "bubbleScale", "Размер", "Размер пузыря и текста в нем.", 10,
            function(v) return string.format("%d%%", v) end)
        try(slider, "bubbleTime", "Время на экране", "Сколько секунд держится пузырь. Авто - дольше для длинных дисов.", 1,
            function(v) return v == 0 and "авто" or string.format("%d с", v) end)
        try(slider, "bubbleOffset", "Высота над портретом", "На сколько выше портрета цели стоит пузырь.", 5,
            function(v) return tostring(v) end)
        try(function()
            if layout and CreateSettingsButtonInitializer then
                layout:AddInitializer(CreateSettingsButtonInitializer("Пример пузыря", "Показать",
                    function() ns.Preview() end, "Показать пузырь с текущими настройками.", true))
            end
        end)
        try(header, "Чат")
        try(box, "chat", "Строка с дисом в чате",
            "Писать дисы в чат. Выключено: дис виден только в пузыре.")
        try(header, "Дисы")
        try(box, "boost", "Повышенные дисы",
            "Обычный шанс диса x2. У боссов шанс прежний.")
        try(box, "showOthers", "Показывать дисы согильдийцев",
            "Когда мобы дисят других игроков с аддоном.")
        try(box, "mass", "Массовое отображение",
            "Показывать дисы всех согильдийцев с аддоном, где бы они ни были. Выключено: только тех, кто рядом с тобой (до 100 м).")
        try(box, "share", "Делиться своими дисами",
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
    Print(string.format("шанс диса: %.1f%%%s, босс при первой встрече за 2 часа: %d%%;   пузырь: %s;   чужие дисы: %s.",
        (testMode and 1 or ns.EffectiveChance(race, class)) * 100,
        testMode and " (тест)" or (DB.settings.boost and " (повышенные дисы)" or ""), BOSS_CHANCE * 100,
        DB.settings.bubble and (StyleOf(DB.settings.bubbleStyle).label .. ", " .. DB.settings.bubbleScale .. "%") or "выкл",
        not DB.settings.showOthers and "выкл" or (DB.settings.mass and "вся гильдия" or "только рядом")))
end

-- /rap стиль [название]: без названия - следующий дизайн
function ns.SetStyle(arg)
    arg = ns.Fold(arg or "")
    local pick
    if arg == "" then
        for i, st in ipairs(STYLES) do
            if st.key == DB.settings.bubbleStyle then pick = STYLES[i % #STYLES + 1] end
        end
        pick = pick or STYLES[1]
    else
        for _, st in ipairs(STYLES) do
            local label = ns.Fold(st.label)
            if st.key == arg or label:sub(1, #arg) == arg then pick = pick or st end
        end
    end
    if not pick then
        local names = {}
        for _, st in ipairs(STYLES) do names[#names + 1] = ns.Fold(st.label) end
        Print("нет такого дизайна. Есть: " .. table.concat(names, ", ") .. ".")
        return false
    end
    DB.settings.bubbleStyle = pick.key
    Print("дизайн пузыря: " .. pick.label .. ".")
    ns.Preview()
    return true
end

-- /rap размер 150
function ns.SetScale(arg)
    local n = tonumber(((arg or ""):gsub("%%", "")))
    local lim = LIMITS.bubbleScale
    if not n or n < lim[1] or n > lim[2] then
        Print(string.format("размер пузыря от %d до %d%%, сейчас %d%%. Пример: /rap размер 150", lim[1], lim[2], DB.settings.bubbleScale))
        return false
    end
    DB.settings.bubbleScale = math.floor(n + 0.5)
    Print(string.format("размер пузыря: %d%%.", DB.settings.bubbleScale))
    ns.Preview()
    return true
end

-- "вкл" / "выкл" в конце команды, иначе переключить
local function Toggle(key, msg)
    local arg = msg:match("%s(%S+)$")
    if arg == "вкл" or arg == "on" then
        DB.settings[key] = true
    elseif arg == "выкл" or arg == "off" then
        DB.settings[key] = false
    else
        DB.settings[key] = not DB.settings[key]
    end
    return DB.settings[key]
end

local function RapCommand(msg)
    if not DB then return end
    if ns.passive then Print("сначала сделай /reload: старый Lumen Diss еще работает до перезагрузки.") return end
    msg = ns.Fold(msg):gsub("^%s+", ""):gsub("%s+$", "")
    local cmd, arg = msg:match("^(%S*)%s*(.-)$")
    if msg == "" then
        ns.Stats()
    elseif cmd == "настройки" or cmd == "options" or cmd == "config" then
        OpenSettings()
    elseif cmd == "бабл" or cmd == "пузырь" or cmd == "bubble" then
        Print("пузырь над портретом " .. (Toggle("bubble", msg) and "включен." or "выключен."))
    elseif cmd == "пример" or cmd == "preview" then
        ns.Preview()
    elseif cmd == "стиль" or cmd == "дизайн" or cmd == "style" then
        ns.SetStyle(arg)
    elseif cmd == "размер" or cmd == "size" then
        ns.SetScale(arg)
    elseif cmd == "чат" or cmd == "chat" then
        Print("строка с дисом в чате " .. (Toggle("chat", msg) and "включена." or "выключена."))
    elseif cmd == "x2" or cmd == "х2" or cmd == "буст" or cmd == "boost" then
        Print(Toggle("boost", msg) and "повышенные дисы включены: обычный шанс x2, у боссов прежний."
            or "повышенные дисы выключены.")
    elseif cmd == "масс" or cmd == "все" or cmd == "mass" then
        DB.settings.mass = not DB.settings.mass
        Print(DB.settings.mass and "видишь дисы всей гильдии." or "видишь только дисы рядом с тобой.")
    else
        Print("/rap - статистика;   /rap настройки;   /rap x2 - повышенные дисы;   /rap бабл - пузырь вкл/выкл;   /rap стиль [название];   /rap размер 50-200;   /rap пример;   /rap чат;   /rap масс;   /diss - тест 100%")
    end
end

local function DissCommand()
    if not DB then return end
    if ns.passive then Print("сначала сделай /reload: старый Lumen Diss еще работает до перезагрузки.") return end
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

local function Copy(t)
    if type(t) ~= "table" then return t end
    local c = {}
    for k, v in pairs(t) do c[k] = Copy(v) end
    return c
end

local function OldLoaded()
    local isLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
    if isLoaded then
        local ok, v = pcall(isLoaded, OLD_ADDON)
        if ok and v then return true end
    end
    return type(_G.LumenDissDB) == "table"
end

-- Переезд с Lumen Diss: статистика и настройки переносятся один раз, старый аддон выключается.
-- До /reload работает старый, а RapDiss молчит, иначе дисы двоились бы.
function ns.MigrateFromOld()
    local old, oldChar = _G.LumenDissDB, _G.LumenDissCharDB
    if type(old) == "table" and not RapDissDB.imported then
        if type(RapDissDB.settings) ~= "table" and type(old.settings) == "table" then RapDissDB.settings = Copy(old.settings) end
        if (type(RapDissDB.guild) ~= "table" or next(RapDissDB.guild) == nil) and type(old.guild) == "table" then
            RapDissDB.guild = Copy(old.guild)
        end
        RapDissDB.imported = true
    end
    if type(oldChar) == "table" and not RapDissCharDB.imported and (tonumber(RapDissCharDB.count) or 0) == 0 then
        for k, v in pairs(oldChar) do RapDissCharDB[k] = Copy(v) end
        RapDissCharDB.imported = true
    end
    local disable = (C_AddOns and C_AddOns.DisableAddOn) or DisableAddOn
    if disable then pcall(disable, OLD_ADDON) end
    ns.passive = true
    Print("это новое имя Lumen Diss. Перенес статистику и выключил старый аддон. Сделай /reload, и дисы пойдут от RapDiss. Папку LumenDiss в AddOns можно удалить.")
end

local function Init()
    RapDissDB = type(RapDissDB) == "table" and RapDissDB or {}
    RapDissCharDB = type(RapDissCharDB) == "table" and RapDissCharDB or {}
    if OldLoaded() then ns.MigrateFromOld() end
    DB, CharDB = RapDissDB, RapDissCharDB
    DB.settings = type(DB.settings) == "table" and DB.settings or {}
    for k, v in pairs(DEFAULTS) do
        if type(DB.settings[k]) ~= type(v) then DB.settings[k] = v end
    end
    for k, lim in pairs(LIMITS) do
        if DB.settings[k] < lim[1] or DB.settings[k] > lim[2] then DB.settings[k] = DEFAULTS[k] end
    end
    if StyleOf(DB.settings.bubbleStyle).key ~= DB.settings.bubbleStyle then DB.settings.bubbleStyle = DEFAULTS.bubbleStyle end
    DB.guild = type(DB.guild) == "table" and DB.guild or {}
    CharDB.count = CharDB.count or 0
    CharDB.byMob = CharDB.byMob or {}
    CharDB.namedSeen = type(CharDB.namedSeen) == "table" and CharDB.namedSeen or {}
    -- встречи с боссами старше 2 часов больше не нужны
    CharDB.bosses = type(CharDB.bosses) == "table" and CharDB.bosses or {}
    local now = time()
    for k, t in pairs(CharDB.bosses) do
        if type(t) ~= "number" or now - t >= BOSS_MEMORY then CharDB.bosses[k] = nil end
    end
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
        if a1 == ADDON then
            Init()
        elseif a1 == OLD_ADDON and DB and not ns.passive then
            ns.MigrateFromOld()       -- старый загрузился позже нового
        end
        return
    end
    if not DB or ns.passive then return end
    if e == "CHAT_MSG_ADDON" then
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
