--[================[
LibClassicDurations
Author: d87
Description: Tracks all aura applications in combat log and provides duration, expiration time.
And additionally enemy buffs info.

Usage example 1:
-----------------

    -- Using UnitAura wrapper
    local UnitAura = _G.UnitAura

    local LibClassicDurations = LibStub("LibClassicDurations", true)
    if LibClassicDurations then
        LibClassicDurations:Register("YourAddon")
        UnitAura = LibClassicDurations.UnitAuraWrapper
    end

--]================]
if WOW_PROJECT_ID ~= WOW_PROJECT_CLASSIC then return end

local MAJOR, MINOR = "LibClassicDurations", 39
local lib = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end

lib.callbacks = lib.callbacks or LibStub("CallbackHandler-1.0"):New(lib)
lib.frame = lib.frame or CreateFrame("Frame")

lib.guids = lib.guids or {}
lib.spells = lib.spells or {}
lib.npc_spells = lib.npc_spells or {}

lib.spellNameToID = lib.spellNameToID or {}
local spellNameToID = lib.spellNameToID

local NPCspellNameToID = {}
if lib.NPCSpellTableTimer then
    lib.NPCSpellTableTimer:Cancel()
end

lib.DRInfo = lib.DRInfo or {}
local DRInfo = lib.DRInfo

lib.buffCache = lib.buffCache or {}
local buffCache = lib.buffCache

lib.buffCacheValid = lib.buffCacheValid or {}
local buffCacheValid = lib.buffCacheValid

lib.nameplateUnitMap = lib.nameplateUnitMap or {}
local nameplateUnitMap = lib.nameplateUnitMap

lib.castLog = lib.castLog or {}
local castLog = lib.castLog

lib.guidAccessTimes = lib.guidAccessTimes or {}
local guidAccessTimes = lib.guidAccessTimes

local f = lib.frame
local callbacks = lib.callbacks
local guids = lib.guids
local spells = lib.spells
local npc_spells = lib.npc_spells
local indirectRefreshSpells = lib.indirectRefreshSpells

local INFINITY = math.huge
local PURGE_INTERVAL = 900
local PURGE_THRESHOLD = 1800
local UNKNOWN_AURA_DURATION = 3600 -- 60m

local CombatLogGetCurrentEventInfo = CombatLogGetCurrentEventInfo
local UnitGUID = UnitGUID
local UnitAura = UnitAura
local GetSpellInfo = GetSpellInfo
local GetTime = GetTime
local tinsert = table.insert
local unpack = unpack
local GetAuraDurationByUnitDirect

if lib.enableEnemyBuffTracking == nil then lib.enableEnemyBuffTracking = false end
local enableEnemyBuffTracking = lib.enableEnemyBuffTracking

local COMBATLOG_OBJECT_CONTROL_PLAYER = COMBATLOG_OBJECT_CONTROL_PLAYER

f:SetScript("OnEvent", function(self, event, ...)
    return self[event](self, event, ...)
end)

lib.dataVersions = lib.dataVersions or {}
local SpellDataVersions = lib.dataVersions

function lib:SetDataVersion(dataType, version)
    SpellDataVersions[dataType] = version
    npc_spells = lib.npc_spells
    indirectRefreshSpells = lib.indirectRefreshSpells
end

function lib:GetDataVersion(dataType)
    return SpellDataVersions[dataType] or 0
end

lib.AddAura = function(id, opts)
    if not opts then return end

    local lastRankID
    if type(id) == "table" then
        local clones = id
        lastRankID = clones[#clones]
    else
        lastRankID = id
    end

    local spellName = GetSpellInfo(lastRankID)
    spellNameToID[spellName] = lastRankID

    if type(id) == "table" then
        for _, spellID in ipairs(id) do
            spells[spellID] = opts
        end
    else
        spells[id] = opts
    end
end


lib.Talent = function (...)
    for i=1, 5 do
        local spellID = select(i, ...)
        if not spellID then break end
        if IsPlayerSpell(spellID) then return i end
    end
    return 0
end

local prevID
local counter = 0
local function processNPCSpellTable()
    local dataTable = lib.npc_spells
    counter = 0
    local id = next(dataTable, prevID)
    while (id and counter < 300) do
        NPCspellNameToID[GetSpellInfo(id)] = id

        counter = counter + 1
        prevID = id
        id = next(dataTable, prevID)
    end
    if (id) then
        C_Timer.After(1, processNPCSpellTable)
    end
end
lib.NPCSpellTableTimer = C_Timer.NewTimer(10, processNPCSpellTable)


local function isHunterGUID(guid)
    return select(2, GetPlayerInfoByGUID(guid)) == "HUNTER"
end
local function isFriendlyFeigning(guid)
    if IsInRaid() then
        for i = 1, MAX_RAID_MEMBERS do
            local unitID = "raid"..i
            if (UnitGUID(unitID) == guid) and UnitIsFeignDeath(unitID) then
                return true
            end
        end
    elseif IsInGroup() then
        for i = 1, MAX_PARTY_MEMBERS do
            local unitID = "party"..i
            if (UnitGUID(unitID) == guid) and UnitIsFeignDeath(unitID) then
                return true
            end
        end
    end
end
--------------------------
-- OLD GUIDs PURGE
--------------------------

local function purgeOldGUIDs()
    local now = GetTime()
    local deleted = {}
    for guid, lastAccessTime in pairs(guidAccessTimes) do
        if lastAccessTime + PURGE_THRESHOLD < now then
            guids[guid] = nil
            nameplateUnitMap[guid] = nil
            buffCacheValid[guid] = nil
            buffCache[guid] = nil
            DRInfo[guid] = nil
            castLog[guid] = nil
            tinsert(deleted, guid)
        end
    end
    for _, guid in ipairs(deleted) do
        guidAccessTimes[guid] = nil
    end
end
lib.purgeTicker = lib.purgeTicker or C_Timer.NewTicker( PURGE_INTERVAL, purgeOldGUIDs)

--------------------------
-- DIMINISHING RETURNS
--------------------------
local bit_band = bit.band
local DRResetTime = 18.4
local COMBATLOG_OBJECT_TYPE_PLAYER = COMBATLOG_OBJECT_TYPE_PLAYER
local COMBATLOG_OBJECT_REACTION_FRIENDLY = COMBATLOG_OBJECT_REACTION_FRIENDLY

local DRMultipliers = { 0.5, 0.25, 0}
local function addDRLevel(dstGUID, category)
    local guidTable = DRInfo[dstGUID]
    if not guidTable then
        DRInfo[dstGUID] = {}
        guidTable = DRInfo[dstGUID]
    end

    local catTable = guidTable[category]
    if not catTable then
        guidTable[category] = {}
        catTable = guidTable[category]
    end

    local now = GetTime()
    local isExpired = (catTable.expires or 0) <= now
    if isExpired then
        catTable.level = 1
        catTable.expires = now + DRResetTime
    else
        catTable.level = catTable.level + 1
    end
end
local function clearDRs(dstGUID)
    DRInfo[dstGUID] = nil
end
local function getDRMul(dstGUID, spellID)
    local category = lib.DR_CategoryBySpellID[spellID]
    if not category then return 1 end

    local guidTable = DRInfo[dstGUID]
    if guidTable then
        local catTable = guidTable[category]
        if catTable then
            local now = GetTime()
            local isExpired = (catTable.expires or 0) <= now
            if isExpired then
                return 1
            else
                local mul = DRMultipliers[catTable.level]
                return mul or 1
            end
        end
    end
    return 1
end

local function CountDiminishingReturns(eventType, srcGUID, srcFlags, dstGUID, dstFlags, spellID, auraType)
    if auraType == "DEBUFF" then
        if eventType == "SPELL_AURA_REMOVED" or eventType == "SPELL_AURA_REFRESH" then
            local category = lib.DR_CategoryBySpellID[spellID]
            if not category then return end

            local isDstPlayer = bit_band(dstFlags, COMBATLOG_OBJECT_TYPE_PLAYER) > 0
            -- local isFriendly = bit_band(dstFlags, COMBATLOG_OBJECT_REACTION_FRIENDLY) > 0

            if not isDstPlayer then
                if not lib.DR_TypesPVE[category] then return end
            end

            addDRLevel(dstGUID, category)
        end
        if eventType == "UNIT_DIED" then
            if not isHunterGUID(dstGUID) then
                clearDRs(dstGUID)
            end
        end
    end
end

------------------------
-- COMBO POINTS
------------------------

local GetComboPoints = GetComboPoints
local _, playerClass = UnitClass("player")
local cpWas = 0
local cpNow = 0
local function GetCP()
    if not cpNow then return GetComboPoints("player", "target") end
    return cpWas > cpNow and cpWas or cpNow
end

function f:PLAYER_TARGET_CHANGED(event)
    return self:UNIT_POWER_UPDATE(event, "player", "COMBO_POINTS")
end
function f:UNIT_POWER_UPDATE(event,unit, ptype)
    if ptype == "COMBO_POINTS" then
        cpWas = cpNow
        cpNow = GetComboPoints(unit, "target")
    end
end

---------------------------
-- COMBAT LOG
---------------------------

local function cleanDuration(duration, spellID, srcGUID, comboPoints)
    if type(duration) == "function" then
        local isSrcPlayer = srcGUID == UnitGUID("player")
        -- Passing startTime for the sole reason of identifying different Rupture/KS applications for Rogues
        -- Then their duration func will cache one actual duration calculated at the moment of application
        return duration(spellID, isSrcPlayer, comboPoints)
    end
    return duration
end

local function RefreshTimer(srcGUID, dstGUID, spellID)
    local guidTable = guids[dstGUID]
    if not guidTable then return end

    local spellTable = guidTable[spellID]
    if not spellTable then return end

    local applicationTable
    if spellTable.applications then
        applicationTable = spellTable.applications[srcGUID]
    else
        applicationTable = spellTable
    end
    if not applicationTable then return end

    applicationTable[2] = GetTime() -- set start time to now
    return true
end

local function SetTimer(srcGUID, dstGUID, dstName, dstFlags, spellID, spellName, opts, auraType, doRemove)
    if not opts then return end

    local guidTable = guids[dstGUID]
    if not guidTable then
        guids[dstGUID] = {}
        guidTable = guids[dstGUID]
    end

    local isStacking = opts.stacking
    -- local auraUID = MakeAuraUID(spellID, isStacking and srcGUID)

    if doRemove then
        if guidTable[spellID] then
            if isStacking then
                if guidTable[spellID].applications then
                    guidTable[spellID].applications[srcGUID] = nil
                end
            else
                guidTable[spellID] = nil
            end
        end
        return
    end

    local spellTable = guidTable[spellID]
    if not spellTable then
        guidTable[spellID] = {}
        spellTable = guidTable[spellID]
        if isStacking then
            spellTable.applications = {}
        end
    end

    local applicationTable
    if isStacking then
        applicationTable = spellTable.applications[srcGUID]
        if not applicationTable then
            spellTable.applications[srcGUID] = {}
            applicationTable = spellTable.applications[srcGUID]
        end
    else
        applicationTable = spellTable
    end

    local duration = opts.duration
    local isDstPlayer = bit_band(dstFlags, COMBATLOG_OBJECT_CONTROL_PLAYER) > 0
    if isDstPlayer and opts.pvpduration then
        duration = opts.pvpduration
    end

    if not duration then
        return SetTimer(srcGUID, dstGUID, dstName, dstFlags, spellID, spellName, opts, auraType, true)
    end
    -- local mul = getDRMul(dstGUID, spellID)
    -- duration = duration * mul
    local now = GetTime()
    -- local expirationTime
    -- if duration == 0 then
    --     expirationTime = now + UNKNOWN_AURA_DURATION -- 60m
    -- else
    --     -- local temporaryDuration = cleanDuration(opts.duration, spellID, srcGUID)
    --     expirationTime = now + duration
    -- end

    applicationTable[1] = duration
    applicationTable[2] = now
    -- applicationTable[2] = expirationTime
    applicationTable[3] = auraType

    local isSrcPlayer = srcGUID == UnitGUID("player")
    local comboPoints
    if isSrcPlayer and playerClass == "ROGUE" then
        comboPoints = GetCP()
    end
    applicationTable[4] = comboPoints

    guidAccessTimes[dstGUID] = now
end

local function FireToUnits(event, dstGUID)
    if dstGUID == UnitGUID("target") then
        callbacks:Fire(event, "target")
    end
    local nameplateUnit = nameplateUnitMap[dstGUID]
    if nameplateUnit then
        callbacks:Fire(event, nameplateUnit)
    end
end

local function GetLastRankSpellID(spellName)
    local spellID = spellNameToID[spellName]
    if not spellID then
        spellID = NPCspellNameToID[spellName]
    end
    return spellID
end

local eventSnapshot
castLog.SetLastCast = function(self, srcGUID, spellID, timestamp)
    self[srcGUID] = { spellID, timestamp }
    guidAccessTimes[srcGUID] = timestamp
end
castLog.IsCurrent = function(self, srcGUID, spellID, timestamp, timeWindow)
    local entry = self[srcGUID]
    if entry then
        local lastSpellID, lastTimestamp = entry[1], entry[2]
        return lastSpellID == spellID and (timestamp - lastTimestamp < timeWindow)
    end
end

local lastResistSpellID
local lastResistTime = 0
---------------------------
-- COMBAT LOG HANDLER
---------------------------
function f:COMBAT_LOG_EVENT_UNFILTERED(event)
    return self:CombatLogHandler(CombatLogGetCurrentEventInfo())
end

local function ProcIndirectRefresh(eventType, spellName, srcGUID, srcFlags, dstGUID, dstFlags, dstName)
    if indirectRefreshSpells[spellName] then
        local refreshTable = indirectRefreshSpells[spellName]
        if refreshTable.events[eventType] then
            local targetSpellID = refreshTable.targetSpellID

            local condition = refreshTable.condition
            if condition then
                local isMine = bit_band(srcFlags, COMBATLOG_OBJECT_AFFILIATION_MINE) == COMBATLOG_OBJECT_AFFILIATION_MINE
                if not condition(isMine) then return end
            end

            if refreshTable.targetResistCheck then
                local now = GetTime()
                if lastResistSpellID == targetSpellID and now - lastResistTime < 0.4 then
                    return
                end
            end

            if refreshTable.applyAura then
                local opts = spells[targetSpellID]
                if opts then
                    local targetAuraType = "DEBUFF"
                    local targetSpellName = GetSpellInfo(targetSpellID)
                    SetTimer(srcGUID, dstGUID, dstName, dstFlags, targetSpellID, targetSpellName, opts, targetAuraType)
                end
            else
                RefreshTimer(srcGUID, dstGUID, targetSpellID)
            end
        end
    end
end

function f:CombatLogHandler(...)
    local timestamp, eventType, hideCaster,
    srcGUID, srcName, srcFlags, srcFlags2,
    dstGUID, dstName, dstFlags, dstFlags2,
    spellID, spellName, spellSchool, auraType = ...


    ProcIndirectRefresh(eventType, spellName, srcGUID, srcFlags, dstGUID, dstFlags, dstName)

    if  eventType == "SPELL_MISSED" and
        bit_band(srcFlags, COMBATLOG_OBJECT_AFFILIATION_MINE) == COMBATLOG_OBJECT_AFFILIATION_MINE
    then
        local missType = auraType
        if missType == "RESIST" then
            spellID = GetLastRankSpellID(spellName)
            if not spellID then
                return
            end

            lastResistSpellID = spellID
            lastResistTime = GetTime()
        end
    end

    if auraType == "BUFF" or auraType == "DEBUFF" or eventType == "SPELL_CAST_SUCCESS" then
        if spellID == 0 then
            -- so not to rewrite the whole thing to spellnames after the combat log change
            -- just treat everything as max rank id of that spell name
            spellID = GetLastRankSpellID(spellName)
            if not spellID then
                return
            end
        end

        CountDiminishingReturns(eventType, srcGUID, srcFlags, dstGUID, dstFlags, spellID, auraType)

        local isDstFriendly = bit_band(dstFlags, COMBATLOG_OBJECT_REACTION_FRIENDLY) > 0

        local opts = spells[spellID]

        if not opts then
            local npc_aura_duration = npc_spells[spellID]
            if npc_aura_duration then
                opts = { duration = npc_aura_duration }
            -- elseif enableEnemyBuffTracking and not isDstFriendly and auraType == "BUFF" then
                -- opts = { duration = 0 } -- it'll be accepted but as an indefinite aura
            end
        end

        if opts then
            local castEventPass
            if opts.castFilter then
                -- Buff and Raidwide Buff events arrive in the following order:
                -- 1571716930.161 ID: 21562 SPELL_AURA_APPLIED/REFRESH to Caster himself (if selfcast or raidwide)
                -- 1571716930.161 ID: 21562 SPELL_CAST_SUCCESS on Cast Target
                -- 1571716930.161 ID: 21562 SPELL_AURA_APPLIED/REFRESH to everyone else

                -- For spells that have cast filter enabled:
                    -- First APPLIED event gets snapshotted and otherwise ignored
                    -- CAST event effectively sets castEventPass to true
                    -- Snapshotted event now gets handled with cast pass
                    -- All the following APPLIED events are accepted while cast pass is valid
                    -- (Unconfirmed whether timestamp is the same even for a 40m raid)
                local now = GetTime()
                castEventPass = castLog:IsCurrent(srcGUID, spellID, now, 0.4)
                if not castEventPass and (eventType == "SPELL_AURA_REFRESH" or eventType == "SPELL_AURA_APPLIED") then
                    eventSnapshot = { timestamp, eventType, hideCaster,
                    srcGUID, srcName, srcFlags, srcFlags2,
                    dstGUID, dstName, dstFlags, dstFlags2,
                    spellID, spellName, spellSchool, auraType }
                    return
                end

                if eventType == "SPELL_CAST_SUCCESS" then
                    -- Aura spell ID can be different from cast spell id
                    -- But all buffs are usually simple spells and it's the same for them
                    castLog:SetLastCast(srcGUID, spellID, now)
                    if eventSnapshot then
                        self:CombatLogHandler(unpack(eventSnapshot))
                        eventSnapshot = nil
                    end
                end
            end

            local isEnemyBuff = not isDstFriendly and auraType == "BUFF"
            -- print(eventType, srcGUID, "=>", dstName, spellID, spellName, auraType )
            if  eventType == "SPELL_AURA_REFRESH" or
                eventType == "SPELL_AURA_APPLIED" or
                eventType == "SPELL_AURA_APPLIED_DOSE"
            then
                if  not opts.castFilter or
                    castEventPass or
                    isEnemyBuff
                then
                    SetTimer(srcGUID, dstGUID, dstName, dstFlags, spellID, spellName, opts, auraType)
                end
            elseif eventType == "SPELL_AURA_REMOVED" then
                SetTimer(srcGUID, dstGUID, dstName, dstFlags, spellID, spellName, opts, auraType, true)
            -- elseif eventType == "SPELL_AURA_REMOVED_DOSE" then
                -- self:RemoveDose(srcGUID, dstGUID, spellID, spellName, auraType, amount)
            end
            if enableEnemyBuffTracking and isEnemyBuff then
                -- invalidate buff cache
                buffCacheValid[dstGUID] = nil

                FireToUnits("UNIT_BUFF", dstGUID)
                if  eventType == "SPELL_AURA_REFRESH" or
                    eventType == "SPELL_AURA_APPLIED" or
                    eventType == "SPELL_AURA_APPLIED_DOSE"
                then
                    FireToUnits("UNIT_BUFF_GAINED", dstGUID, spellID)
                end
            end
        end
    end
    if eventType == "UNIT_DIED" then
        if isHunterGUID(dstGUID) then
            local isDstFriendly = bit_band(dstFlags, COMBATLOG_OBJECT_REACTION_FRIENDLY) > 0
            if not isDstFriendly or isFriendlyFeigning(dstGUID) then
                return
            end
        end

        guids[dstGUID] = nil
        buffCache[dstGUID] = nil
        buffCacheValid[dstGUID] = nil
        guidAccessTimes[dstGUID] = nil
        local isDstFriendly = bit_band(dstFlags, COMBATLOG_OBJECT_REACTION_FRIENDLY) > 0
        if enableEnemyBuffTracking and not isDstFriendly then
            FireToUnits("UNIT_BUFF", dstGUID)
        end
        nameplateUnitMap[dstGUID] = nil
    end
end

---------------------------
-- ENEMY BUFFS
---------------------------
local makeBuffInfo = function(spellID, applicationTable, dstGUID, srcGUID)
    local name, rank, icon, castTime, minRange, maxRange, _spellId = GetSpellInfo(spellID)
    local durationFunc, startTime, auraType, comboPoints = unpack(applicationTable)
    local duration = cleanDuration(durationFunc, spellID, srcGUID, comboPoints) -- srcGUID isn't needed actually
    -- no DRs on buffs
    local expirationTime = startTime + duration
    if duration == INFINITY then
        duration = 0
        expirationTime = 0
    end
    local now = GetTime()
    if expirationTime > now then
        return { name, icon, 0, nil, duration, expirationTime, nil, nil, nil, spellID }
    end
end

local shouldDisplayAura = function(auraTable)
    if auraTable[3] == "BUFF" then
        local now = GetTime()
        local expirationTime = auraTable[2]
        return expirationTime > now
    end
    return false
end

local function RegenerateBuffList(dstGUID)
    local guidTable = guids[dstGUID]
    if not guidTable then
        return
    end

    local buffs = {}
    for spellID, t in pairs(guidTable) do
        if t.applications then
            for srcGUID, auraTable in pairs(t.applications) do
                if auraTable[3] == "BUFF" then
                    local buffInfo = makeBuffInfo(spellID, auraTable, dstGUID, srcGUID)
                    if buffInfo then
                        tinsert(buffs, buffInfo)
                    end
                end
            end
        else
            if t[3] == "BUFF" then
                local buffInfo = makeBuffInfo(spellID, t, dstGUID)
                if buffInfo then
                    tinsert(buffs, buffInfo)
                end
            end
        end
    end

    buffCache[dstGUID] = buffs
    buffCacheValid[dstGUID] = true
end

local FillInDuration = function(unit, buffName, icon, count, debuffType, duration, expirationTime, caster, canStealOrPurge, nps, spellId, ...)
    if buffName then
        local durationNew, expirationTimeNew = GetAuraDurationByUnitDirect(unit, spellId, caster, buffName)
        if duration == 0 and durationNew then
            duration = durationNew
            expirationTime = expirationTimeNew
        end
        return buffName, icon, count, debuffType, duration, expirationTime, caster, canStealOrPurge, nps, spellId, ...
    end
end

function lib.UnitAuraDirect(unit, index, filter)
    if enableEnemyBuffTracking and filter == "HELPFUL" and not UnitIsFriend("player", unit) and not UnitAura(unit, 1, filter) then
        local unitGUID = UnitGUID(unit)
        if not unitGUID then return end
        if not buffCacheValid[unitGUID] then
            RegenerateBuffList(unitGUID)
        end

        local buffCacheHit = buffCache[unitGUID]
        if buffCacheHit then
            local buffReturns = buffCache[unitGUID][index]
            if buffReturns then
                return unpack(buffReturns)
            end
        end
    else
        return FillInDuration(unit, UnitAura(unit, index, filter))
    end
end
lib.UnitAuraWithBuffs = lib.UnitAuraDirect

function lib.UnitAuraWrapper(unit, ...)
    return FillInDuration(unit, UnitAura(unit, ...))
end

function lib:UnitAura(...)
    return self.UnitAuraDirect(...)
end

function f:NAME_PLATE_UNIT_ADDED(event, unit)
    local unitGUID = UnitGUID(unit)
    nameplateUnitMap[unitGUID] = unit
end
function f:NAME_PLATE_UNIT_REMOVED(event, unit)
    local unitGUID = UnitGUID(unit)
    if unitGUID then -- it returns correctly on death, but just in case
        nameplateUnitMap[unitGUID] = nil
    end
end

function callbacks.OnUsed()
    lib.enableEnemyBuffTracking = true
    enableEnemyBuffTracking = lib.enableEnemyBuffTracking
    f:RegisterEvent("NAME_PLATE_UNIT_ADDED")
    f:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
end
function callbacks.OnUnused()
    lib.enableEnemyBuffTracking = false
    enableEnemyBuffTracking = lib.enableEnemyBuffTracking
    f:UnregisterEvent("NAME_PLATE_UNIT_ADDED")
    f:UnregisterEvent("NAME_PLATE_UNIT_REMOVED")
end

if next(callbacks.events) then
    callbacks.OnUsed()
end

---------------------------
-- PUBLIC FUNCTIONS
---------------------------
local function GetGUIDAuraTime(dstGUID, spellName, spellID, srcGUID, isStacking)
    local guidTable = guids[dstGUID]
    if guidTable then

        local lastRankID = spellNameToID[spellName]

        local spellTable = guidTable[lastRankID]
        if spellTable then
            local applicationTable
            if isStacking then
                if srcGUID and spellTable.applications then
                    applicationTable = spellTable.applications[srcGUID]
                elseif spellTable.applications then -- return some duration
                    applicationTable = select(2,next(spellTable.applications))
                end
            else
                applicationTable = spellTable
            end
            if not applicationTable then return end
            local durationFunc, startTime, auraType, comboPoints = unpack(applicationTable)
            local duration = cleanDuration(durationFunc, spellID, srcGUID, comboPoints)
            if duration == INFINITY then return nil end
            if not duration then return nil end
            local mul = getDRMul(dstGUID, spellID)
            -- local mul = getDRMul(dstGUID, lastRankID)
            duration = duration * mul
            local expirationTime = startTime + duration
            if GetTime() <= expirationTime then
                return duration, expirationTime
            end
        end
    end
end

if playerClass == "MAGE" then
    local NormalGetGUIDAuraTime = GetGUIDAuraTime
    local Chilled = GetSpellInfo(12486)
    GetGUIDAuraTime = function(dstGUID, spellName, spellID, ...)

        -- Overriding spellName for Improved blizzard's spellIDs
        if spellName == Chilled and
            spellID == 12486 or spellID == 12484 or spellID == 12485
        then
            spellName = "ImpBlizzard"
        end
        return NormalGetGUIDAuraTime(dstGUID, spellName, spellID, ...)
    end
end

function lib.GetAuraDurationByUnitDirect(unit, spellID, casterUnit, spellName)
    assert(spellID, "spellID is nil")
    local opts = spells[spellID]
    if not opts then return end
    local dstGUID = UnitGUID(unit)
    local srcGUID = casterUnit and UnitGUID(casterUnit)
    if not spellName then spellName = GetSpellInfo(spellID) end
    return GetGUIDAuraTime(dstGUID, spellName, spellID, srcGUID, opts.stacking)
end
GetAuraDurationByUnitDirect = lib.GetAuraDurationByUnitDirect

function lib:GetAuraDurationByUnit(...)
    return self.GetAuraDurationByUnitDirect(...)

end
function lib:GetAuraDurationByGUID(dstGUID, spellID, srcGUID, spellName)
    local opts = spells[spellID]
    if not opts then return end
    if not spellName then spellName = GetSpellInfo(spellID) end
    return GetGUIDAuraTime(dstGUID, spellName, spellID, srcGUID, opts.stacking)
end

function lib:GetLastRankSpellIDByName(spellName)
    return GetLastRankSpellID(spellName)
end

-- Will not work for cp-based durations, KS and Rupture
function lib:GetDurationForRank(spellName, spellID, srcGUID)
    local lastRankID = spellNameToID[spellName]
    local opts = spells[lastRankID]
    if opts then
        return cleanDuration(opts.duration, spellID, srcGUID)
    end
end

local activeFrames = {}
function lib:RegisterFrame(frame)
    activeFrames[frame] = true
    if next(activeFrames) then
        f:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
        if playerClass == "ROGUE" then
            f:RegisterEvent("PLAYER_TARGET_CHANGED")
            f:RegisterUnitEvent("UNIT_POWER_UPDATE", "player")
        end
    end
end
lib.Register = lib.RegisterFrame

function lib:UnregisterFrame(frame)
    activeFrames[frame] = nil
    if not next(activeFrames) then
        f:UnregisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
        if playerClass == "ROGUE" then
            f:UnregisterEvent("PLAYER_TARGET_CHANGED")
            f:UnregisterEvent("UNIT_POWER_UPDATE")
        end
    end
end
lib.Unregister = lib.UnregisterFrame


function lib:ToggleDebug()
    if not lib.debug then
        lib.debug = CreateFrame("Frame")
        lib.debug:SetScript("OnEvent",function( self, event )
            local timestamp, eventType, hideCaster,
            srcGUID, srcName, srcFlags, srcFlags2,
            dstGUID, dstName, dstFlags, dstFlags2,
            spellID, spellName, spellSchool, auraType, amount = CombatLogGetCurrentEventInfo()
            local isSrcPlayer = (bit_band(srcFlags, COMBATLOG_OBJECT_AFFILIATION_MINE) == COMBATLOG_OBJECT_AFFILIATION_MINE)
            if isSrcPlayer then
                print (GetTime(), "ID:", spellID, spellName, eventType, srcFlags, srcGUID,"|cff00ff00==>|r", dstGUID, dstFlags, auraType, amount)
            end
        end)
    end
    if not lib.debug.enabled then
        lib.debug:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
        lib.debug.enabled = true
        print("[LCD] Enabled combat log event display")
    else
        lib.debug:UnregisterAllEvents()
        lib.debug.enabled = false
        print("[LCD] Disabled combat log event display")
    end
end

function lib:MonitorUnit(unit)
    if not lib.debug then
        lib.debug = CreateFrame("Frame")
        local debugGUID = UnitGUID(unit)
        lib.debug:SetScript("OnEvent",function( self, event )
            local timestamp, eventType, hideCaster,
            srcGUID, srcName, srcFlags, srcFlags2,
            dstGUID, dstName, dstFlags, dstFlags2,
            spellID, spellName, spellSchool, auraType, amount = CombatLogGetCurrentEventInfo()
            if srcGUID == debugGUID or dstGUID == debugGUID then
                print (GetTime(), "ID:", spellID, spellName, eventType, srcFlags, srcGUID,"|cff00ff00==>|r", dstGUID, dstFlags, auraType, amount)
            end
        end)
    end
    if not lib.debug.enabled then
        lib.debug:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
        lib.debug.enabled = true
        print("[LCD] Enabled combat log event display")
    else
        lib.debug:UnregisterAllEvents()
        lib.debug.enabled = false
        print("[LCD] Disabled combat log event display")
    end
end
