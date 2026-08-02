-- ===========================================================================
--  AdventureTime  -  group consumable distributor for MacroQuest
-- ===========================================================================
--  Keeps a boxed group topped up on shared consumables (Project Lazarus
--  "Draught" potions, Orb of Shadows, and Emerald) without hand-trading pots
--  around. You set a per-item target; it shuffles everyone's stock so each
--  character carries what it needs, and buys the shortfall for the one
--  purchasable item.
--
--  HOW TO USE
--    * Run it on EVERY character in the group:  /lua run adventuretime
--    * Open the window on ONE character (your "driver", usually the tank):  /at
--    * Set how many of each item everyone should carry, then click:
--        Give out    - whoever holds the most of an item tops the short
--                      characters up to target; the driver buys the shortfall
--                      for purchasable items (Emerald).
--        Collect all - pulls every tracked item onto the clicking character
--                      (consolidate, then Give out again to redistribute).
--        Close all   - shuts every instance across the group.
--    * The board shows each toon's count per item:
--        green = at target,  red = short,  grey = holds some but won't use them.
--
--  It auto-detects your peer network (E3 /e3bct, EQBC /bct, or DanNet /dex),
--  starts itself on any groupmate that isn't running it, pauses E3 during the
--  trades, and is class-aware (endurance pots skip casters, mana pots skip
--  melee - see WANTS_ENDURANCE / WANTS_MANA below).
--
--  REQUIREMENTS:  MacroQuest with a Lua/ImGui build + one of E3 / EQBC / DanNet.
--  INSTALL:       put AdventureTime.lua in your MacroQuest  lua/  folder.
--  SETTINGS:      per-item targets persist to AdventureTime_targets.ini beside
--                 this file.
--
--  Item names, the Emerald vendor (Audri Deepfacet), and the class lists are
--  Project Lazarus specific - edit ITEMS / VENDOR / WANTS_* near the top to fit
--  a different server or consumable set. Provided as-is; have fun out there.
-- ===========================================================================

local mq    = require('mq')
local ImGui = require('ImGui')

local scriptName = 'AdventureTime'
-- A human-launched instance shows the UI and drives; instances the driver auto-starts get the
-- 'worker' arg (see the /lua run below) and run HEADLESS - same file, no window, just obey the
-- driver's /at_* commands (pause/trade/bags). No UI = no accidental second driver.
local ARGS = { ... }
local SHOW_UI = (ARGS[1] ~= 'worker')
local BUILD_TAG = 'at-rezgate-2026-08-01'   -- bump on every change; prints on startup
-- Until when we will accept an incoming trade. Set by /at_expecttrade, which the giver sends just
-- before it walks over. Outside that window trades are left alone so a human can use one.
-- Global, not local: this chunk is at Lua's 200-local ceiling.
expectTradeUntil = 0

-- File logging: mirror every line to AdventureTime_<name>_log.txt (fresh each run, flushed per line) so a
-- run can be reconstructed from the file - same as the crafter/listener.
local LOG_FILE_PATH
do
    local dir
    local ok, src = pcall(function() return debug.getinfo(1, 'S').source end)
    if ok and src then src = tostring(src):gsub('^@', ''); dir = src:match('^(.*[/\\])') end
    if not dir or dir == '' then
        local luaPath
        pcall(function() luaPath = mq.TLO.MacroQuest.Path('lua')() end)
        -- keep logs inside the module folder rather than dumping six of them in the lua root
        if luaPath and luaPath ~= '' then dir = luaPath .. '\\adventuretime\\' end
    end
    local who = '?'
    pcall(function() who = mq.TLO.Me.Name() or '?' end)
    LOG_FILE_PATH = (dir or '') .. 'AdventureTime_' .. who .. '_log.txt'
    -- KEEP THE PREVIOUS RUNS. This used to open 'w' - fresh each run - which meant a crash destroyed its
    -- own evidence: the client goes down, the client comes back, the script restarts and wipes the log
    -- covering the crash. Three minidumps on 2026-08-01 (14:50:05, 14:51:35, 03:54:42) had no readable
    -- log window for exactly this reason, because the restart at 14:53 had truncated all six files.
    -- Same approach LazCraft already uses. A crash costs a few hundred KB of log instead of the answer.
    local KEEP_SESSIONS = 8
    local prior = ''
    local rf = io.open(LOG_FILE_PATH, 'r')
    if rf then
        local content = rf:read('*a') or ''
        rf:close()
        local marker = '=== AdventureTime log'
        local sessions, idx = {}, 1
        while true do
            local st = content:find(marker, idx, true)
            if not st then break end
            local nxt = content:find(marker, st + #marker, true)
            sessions[#sessions + 1] = content:sub(st, (nxt and nxt - 1) or #content)
            if not nxt then break end
            idx = nxt
        end
        local first = math.max(1, #sessions - (KEEP_SESSIONS - 1) + 1)
        local keep = {}
        for i = first, #sessions do keep[#keep + 1] = sessions[i] end
        prior = table.concat(keep)
    end
    local fh = io.open(LOG_FILE_PATH, 'w')   -- rewrite: kept prior sessions, then this one
    if fh then
        if prior ~= '' then fh:write(prior) end
        fh:write(string.format('=== AdventureTime log (%s) - started %s [build %s] ===\n',
            who, os.date('%Y-%m-%d %H:%M:%S'), BUILD_TAG))
        fh:close()
    else
        LOG_FILE_PATH = nil
    end
end
-- Both clocks, sampled together, so elapsed milliseconds can be turned back into a wall time.
LOG_T0_WALL = os.time()
LOG_T0_MS   = mq.gettime()

local function log_to_file(line)
    if not LOG_FILE_PATH then return end
    local fh = io.open(LOG_FILE_PATH, 'a')
    if not fh then return end
    -- Strip MQ colour codes: they are for the console, and in a text file they are noise. Also drops
    -- any stray BEL that a single-backslash '\a' escape would produce.
    line = tostring(line):gsub('\27%[[%d;]*m', ''):gsub('\\a[a-z]', ''):gsub('%c', '')
    -- Millisecond precision, ANCHORED to the wall clock. The first attempt printed mq.gettime() % 1000
    -- beside os.date's seconds - but gettime is a monotonic counter with no relationship to the second
    -- boundary, so the fraction wrapped independently and timestamps appeared to run backwards inside
    -- one second. Every gap measured from those files was unreliable.
    -- Fix: capture both clocks once at startup, then derive the whole timestamp from elapsed gettime.
    -- One clock, so the seconds and the milliseconds cannot disagree.
    local ms = mq.gettime() - LOG_T0_MS
    fh:write(string.format('[%s.%03d] %s\n', os.date('%H:%M:%S', LOG_T0_WALL + math.floor(ms / 1000)),
                           ms % 1000, line))
    fh:close()
end
-- MQ bindings are inconsistent about booleans: true, 1 and "TRUE" all turn up depending on the build
-- and the TLO. Comparing to `true` alone silently reads as false - that is what hid the rez window for
-- several builds, and there were fourteen more of the same comparison scattered about.
function tlo_true(v)
    if v == true or v == 1 then return true end
    if v == nil or v == false then return false end
    local sv = tostring(v):upper()
    return sv == 'TRUE' or sv == '1'
end

-- A LOGGING BUG MUST NEVER TAKE DOWN A SUBSYSTEM. string.format throws on a mismatched argument - a nil
-- where a %d is expected, most often a variable that a refactor removed - and because these helpers are
-- called from inside di_tick and the rez picker, that throw propagates into their pcall wrapper and
-- disables the whole feature. That is exactly what happened on 2026-07-30: an orphaned myPos left one %d
-- reading nil, and DI switched itself off on whichever toon the baton had just reached.
-- Formatting failures now degrade to the raw format string plus the arguments, which still says enough to
-- find the call site, and the caller carries on.
function safe_fmt(fmt, ...)   -- global on purpose: the main chunk is at Lua's 200-local ceiling
    if select('#', ...) == 0 then return fmt end
    local ok, msg = pcall(string.format, fmt, ...)
    if ok then return msg end
    local parts = {}
    for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    return '[fmt error] ' .. tostring(fmt) .. ' | args: ' .. table.concat(parts, ', ')
end
local function log(fmt, ...)
    local msg = safe_fmt(fmt, ...)
    printf('\\ao[AdventureTime]\\ax ' .. msg)
    log_to_file(msg)
end
local function rezlog(fmt, ...)   -- file-only (keeps the [rez] chatter out of the MQ window)
    log_to_file(safe_fmt(fmt, ...))
end

-- ---------------------------------------------------------------------------
-- Items. The six draughts each come in I and II; Orb of Shadows is a single item. `key` is a stable
-- id for encoding across the peer network (no spaces).
-- ---------------------------------------------------------------------------
local DRAUGHTS = {
    'Draught of Shimmering Reflection',
    'Draught of Opulent Healing',
    'Draught of Frenzied Endurance',
    'Draught of Fleeting Fortitude',
    'Draught of Earthen Grit',
    'Draught of Inferno Ward',
    'Draught of the Clear Mind',
}
local ITEMS = {}
for _, base in ipairs(DRAUGHTS) do
    ITEMS[#ITEMS + 1] = base .. ' I'
    ITEMS[#ITEMS + 1] = base .. ' II'
end
ITEMS[#ITEMS + 1] = 'Orb of Shadows'
ITEMS[#ITEMS + 1] = 'Emerald'

-- ---------------------------------------------------------------------------
-- Group draught buttons. One press = every group member drinks the BEST tier it personally holds.
-- Deliberately NOT decided on the driver: the driver's counts are only as fresh as the last Refresh,
-- and picking the tier here would drink the wrong one after any hand-trade. Each toon reads its own
-- inventory instead - always right, and one message per toon per press rather than any polling.
-- Globals, not locals: this chunk is at Lua's 200-local ceiling.
-- ---------------------------------------------------------------------------
GROUP_POTS = {
    { key = 'shimmer',   base = 'Draught of Shimmering Reflection', label = 'Group Shimmering Reflection' },
    { key = 'fortitude', base = 'Draught of Fleeting Fortitude',    label = 'Group Fleeting Fortitude'    },
}
function pot_base_for(key)
    for _, p in ipairs(GROUP_POTS) do if p.key == key then return p.base, p.label end end
    return nil
end
-- driver: potState[char][key] = { carries, up, secs, dsecs, updated }. Worker: last-pushed key per pot.
potState = {}
potLast  = {}
-- Drink the best tier of `base` I actually hold. II is tried first; I is the fallback ONLY when no II
-- is carried. If a tier is held but its timer is down we STOP rather than dropping to the lower one -
-- I and II share one recast, so the lesser tier is on cooldown too and queuecasting it just burns a
-- slot in the queue for a cast that cannot fire.
-- DRAUGHTS GET THE SAME TREATMENT AS THE STAFF. pot_drink used to fire and log "[pot] <name>" in the same
-- breath, claiming a success nobody had checked - the exact habit that made the DI logs disagree with the
-- fight for a whole night. And these go out via /queuecast, which QUEUES behind whatever that toon is
-- already casting, so a draught genuinely can sit and never happen.
-- Confirmation is free: pot_state already reports both the buff being up and the item going on cooldown,
-- and either one proves it went.
POT_RETRY_AFTER = 4000     -- generous, because queuecast waits its turn
POT_RETRY_MAX   = 3
potPending      = nil      -- { base, nm, at, tries }

function pot_retry_tick()
    if not potPending then return end
    local _, up, secs = pot_state(potPending.base)
    if up == 1 or (secs or 0) > 0 then
        log('[pot] %s landed', potPending.nm)
        potPending = nil; return
    end
    local age = mq.gettime() - potPending.at
    if age < POT_RETRY_AFTER * potPending.tries then return end
    if potPending.tries >= POT_RETRY_MAX then
        log('\\ay[pot] %s never went off after %d tries\\ax', potPending.nm, potPending.tries)
        potPending = nil; return
    end
    potPending.tries = potPending.tries + 1
    log('[pot] no sign of %s - retry %d of %d', potPending.nm, potPending.tries, POT_RETRY_MAX)
    pcall(function() mq.cmdf('/queuecast me "%s"', potPending.nm) end)
end

function pot_drink(base)
    for _, tier in ipairs({ 'II', 'I' }) do
        local nm = base .. ' ' .. tier
        local have, ready = 0, -1
        pcall(function()
            if (tonumber(mq.TLO.FindItem('=' .. nm).ID()) or 0) > 0 then
                have  = tonumber(mq.TLO.FindItemCount('=' .. nm)()) or 0
                ready = tonumber(mq.TLO.FindItem('=' .. nm).TimerReady()) or -1
            end
        end)
        if have > 0 then
            if ready == 0 then
                mq.cmdf('/queuecast me "%s"', nm)
                potPending = { base = base, nm = nm, at = mq.gettime(), tries = 1 }
                return true, nm
            end
            return false, nm   -- held but on cooldown; the other tier shares that timer
        end
    end
    return false, nil
end


-- Purchasable items: if the group can't cover the targets, the DRIVER (the character running this Lua)
-- buys the shortfall from this vendor and hands it out. Emerald is the only buyable one for now. Kept
-- self-contained on purpose - no dependency on Lazcraft's merchant map.
local VENDOR = { ['Emerald'] = 'Audri Deepfacet' }

-- Classes that DO use endurance (melee + hybrids - "if they can use a tome, they can use endurance").
-- Matched on the 3-letter class short-name; anyone not listed skips the Frenzied Endurance AND Earthen Grit draughts.
-- WAR Warrior, PAL Paladin, SHD Shadow Knight, BST Beastlord, RNG Ranger, ROG Rogue, MNK Monk,
-- BER Berserker, BRD Bard. The pure casters (CLR/DRU/SHM/NEC/WIZ/MAG/ENC) are simply left out.
local WANTS_ENDURANCE = { WAR = true, PAL = true, SHD = true, BST = true, RNG = true, ROG = true, MNK = true, BER = true, BRD = true }
local function is_endurance(item) return item:find('Frenzied Endurance', 1, true) ~= nil or item:find('Earthen Grit', 1, true) ~= nil end
-- Classes that use mana - the Clear Mind (mana) draught is skipped for everyone else (pure melee).
local WANTS_MANA = { CLR = true, DRU = true, SHM = true, NEC = true, WIZ = true, MAG = true, ENC = true }
-- Class strings arrive from two places (Me.Class.ShortName locally, a /dquery for peers) and the
-- unknown value is '?', not ''. Normalise here, and treat anything we could not resolve as UNKNOWN so
-- the caller can skip the class filter entirely rather than reading '?' as "a class that does not want
-- this" - which greyed out Clear Mind on priests whenever the class query happened to fail.
local CLASS_SHORT = { WARRIOR='WAR', CLERIC='CLR', PALADIN='PAL', RANGER='RNG', SHADOWKNIGHT='SHD',
                      ['SHADOW KNIGHT']='SHD', DRUID='DRU', MONK='MNK', BARD='BRD', ROGUE='ROG',
                      SHAMAN='SHM', NECROMANCER='NEC', WIZARD='WIZ', MAGICIAN='MAG', ENCHANTER='ENC',
                      BEASTLORD='BST', BERSERKER='BER' }
function class_key(c)
    c = tostring(c or ''):upper()
    if c == '' or c == '?' or c == 'NULL' then return nil end   -- unknown: do not filter on it
    return CLASS_SHORT[c] or c
end
local function is_mana(item) return item:find('Clear Mind', 1, true) ~= nil end

-- Encode/decode an item name for passing over the peer command channel (names have spaces).
local function enc(name) return (tostring(name):gsub(' ', '_')) end
local function dec(name) return (tostring(name):gsub('_', ' ')) end

-- ---------------------------------------------------------------------------
-- Settings: per-character target qty for each item, persisted to Adventure Time/Settings/<char>.ini.
-- ---------------------------------------------------------------------------
local target = {}   -- itemName -> target qty per character
for _, it in ipairs(ITEMS) do target[it] = 0 end

local SETTINGS_PATH
do
    local dir
    local okSrc, src = pcall(function() return debug.getinfo(1, 'S').source end)
    if okSrc and src then dir = tostring(src):gsub('^@', ''):match('^(.*[/\\])') end
    dir = dir or ''
    -- A single tiny file right beside AdventureTime.lua - no subfolder to create, and it SURVIVES
    -- swapping in a new build of the script (unlike baking the numbers into the .lua itself). Targets
    -- are a group-wide policy ("everyone gets N"), so one shared file, not per-character.
    SETTINGS_PATH = dir .. 'AdventureTime_targets.ini'
    local fh = io.open(SETTINGS_PATH, 'r')
    if fh then
        for line in fh:lines() do
            local k, v = line:match('^(.-)%s*=%s*(%d+)%s*$')
            if k and target[dec(k)] ~= nil then target[dec(k)] = tonumber(v) end
        end
        fh:close()
    end
end
-- Renamed from save_settings: a SECOND local save_settings further down (the UI settings one) shadowed
-- this from its own definition onward, so every call site resolved to that instead. Targets were never
-- written, and editing one rewrote the UI settings file.
local function save_targets()
    local fh = io.open(SETTINGS_PATH, 'w')
    if not fh then return end
    fh:write('; AdventureTime per-character target quantities\n')
    for _, it in ipairs(ITEMS) do fh:write(string.format('%s=%d\n', enc(it), target[it] or 0)) end
    fh:close()
end

-- ---------------------------------------------------------------------------
-- Peer network: prefer E3 (/e3bct), then EQBC (/bct), then DanNet (/dex). Detected once.
-- ---------------------------------------------------------------------------
local peerChan
local function peer_cmdf(char, fmt, ...)
    if not peerChan then
        -- Prefer DanNet (/dex): its echo can be silenced. Ensure it's loaded; E3/EQBC only if DanNet can't come up.
        local dnet = mq.TLO.Plugin('MQ2DanNet')() ~= nil
        if not dnet then pcall(function() mq.cmd('/plugin mq2dannet load') end); mq.delay(750); dnet = mq.TLO.Plugin('MQ2DanNet')() ~= nil end
        -- Loaded locally is NOT the same as able to reach anyone: a stale/mismatched DanNet build, or a
        -- second MQ install, leaves this client alone on its own island. If we can see no peers but E3 is
        -- there, use E3 - otherwise every relay vanishes into a void and nothing works but our own toon.
        if dnet then
            local peers = ''
            pcall(function() peers = tostring(mq.TLO.DanNet.Peers() or '') end)
            if peers == '' and mq.TLO.Plugin('MQ2Mono')() then
                dnet = false
                log('DanNet is loaded but sees no peers - falling back to E3 (/e3bct).')
            end
        end
        if dnet then peerChan = 'dannet'
        elseif mq.TLO.Plugin('MQ2Mono')() then peerChan = 'e3'
        elseif mq.TLO.Plugin('MQ2EQBC')() then peerChan = 'eqbc'
        else peerChan = 'dannet' end
    end
    local cmd = fmt:format(...)
    if peerChan == 'e3' then mq.cmdf('/e3bct %s %s', char, cmd)
    elseif peerChan == 'eqbc' then mq.cmdf('/bct %s %s', char, cmd)
    else mq.cmdf('/dex %s %s', char, cmd) end
end
local function peer_bcast(fmt, ...)   -- broadcast to the whole in-game group in ONE relay (5x less window spam than looping /dex)
    -- mq.TLO directly, not myName: peer_bcast is defined ABOVE the myName local, so referring to it
    -- here read a nil global and the detection ping went to an empty name.
    if not peerChan then peer_cmdf(tostring(mq.TLO.Me.Name() or ''), '/echo') end   -- force channel detection + commandecho-off
    local cmd = fmt:format(...)
    if peerChan == 'e3' then mq.cmdf('/e3bcga %s', cmd)
    elseif peerChan == 'eqbc' then mq.cmdf('/bcga %s', cmd)
    else mq.cmdf('/dgge %s', cmd) end   -- DanNet: in-game group execute (all but self)
end

-- The GROUP roster (this tool is group-only for now): self + grouped members, by name.
-- Strip a corpse suffix off a group name. A dead character reports as "Sebbun's corpse103".
-- NOT local: this chunk is at Lua's 200-local ceiling.
function strip_corpse(nm)
    if not nm or nm == '' then return nm end
    return nm:match("^(.-)'s? corpse%d*$") or nm
end

local function group_members()
    local list, seen = {}, {}
    -- MY OWN name needs stripping too. I only did the Group.Member names, so when the DRIVER died its
    -- own name came back as "Sebbun's corpse103", went into the roster unstripped, and then "left the
    -- group" a moment later - firing a full resync in the middle of a wipe, twice, with every worker
    -- re-reporting everything exactly when the network was busiest.
    local me = strip_corpse(mq.TLO.Me.Name() or '')
    if me ~= '' then list[#list + 1] = me; seen[me:lower()] = true end
    local n = mq.TLO.Group.Members() or 0
    for i = 1, n do
        local nm = mq.TLO.Group.Member(i).Name()
        -- A DEAD member reports as its corpse: "Sebbun's corpse99". That name then flows into the rez
        -- priority, the tank check, ordered_members, and the roster-change watcher - which saw a member
        -- "leave", fired a resync, and tried to close a worker on a corpse. Strip the suffix and keep
        -- the character: they are still in the group, they are just dead.
        if nm and nm ~= '' then
            local realName = strip_corpse(nm)
            if realName ~= '' and not seen[realName:lower()] then
                list[#list + 1] = realName; seen[realName:lower()] = true
            end
        end
    end
    return list
end

-- ---------------------------------------------------------------------------
-- Counts. Own count is local; a peer's count is a live DanNet query of FindItemCount (bags, i.e. what
-- can actually be traded).
-- ---------------------------------------------------------------------------
local myName = mq.TLO.Me.Name() or ''
-- Count what's in BAGS only, NOT worn/equipped slots. FindItemCount includes equipped items AND the
-- augments slotted into them, so an aug sharing a name with a tradeable item would inflate the count and
-- we'd promise to hand over something that's actually in our gear. Bags-only is the right scope for
-- trading. (No bank here - AdventureTime only ever hands over what's on hand.)
local function my_count(item)
    local target = (item or ''):lower()
    local total  = 0
    local ok = pcall(function()
        for pk = 1, 12 do
            local slot = mq.TLO.Me.Inventory('pack' .. pk)
            if (slot.ID() or 0) > 0 then
                local cap = slot.Container() or 0
                if cap > 0 then                                   -- a bag: count its contents
                    for i = 1, cap do
                        local it = slot.Item(i)
                        if (it.ID() or 0) > 0 and (it.Name() or ''):lower() == target then
                            local c = it.Stack() or 1
                            total = total + (c < 1 and 1 or c)
                        end
                    end
                elseif (slot.Name() or ''):lower() == target then -- a plain item directly in an inventory slot
                    local c = slot.Stack() or 1
                    total = total + (c < 1 and 1 or c)
                end
            end
        end
    end)
    if not ok then return 0 end
    return total
end

-- Peer counts via request/reply (reliable, unlike a raw DanNet query): the driver sends /at_count to a
-- toon, that toon answers with /at_have <me> <item> <count>, and the driver reads the reply. Both binds
-- live on every instance since the tool runs everywhere.
local reportedCounts = {}   -- "peerlower|item" -> count
pcall(function()
    -- On a PEER: someone asks how many of an item we hold; answer back to them.
    mq.bind('/at_count', function(driver, encItem)
        if not driver or not encItem then return end
        peer_cmdf(driver, '/at_have %s %s %d', myName, encItem, my_count(dec(encItem)))
    end)
    -- On the DRIVER: record a peer's reported count.
    mq.bind('/at_have', function(peer, encItem, n)
        if not peer or not encItem then return end
        reportedCounts[peer:lower() .. '|' .. dec(encItem)] = tonumber(n) or 0
    end)
end)

-- Direct DanNet query: ask a peer to evaluate a TLO and read the answer back. QUOTE the query - names
-- with spaces (FindItemCount[=Powder of Ro]) get chopped at the first space otherwise. This replaces the
-- /at_count request/reply: no handshake spam, and it works as long as the peer runs DanNet (it does NOT
-- need to be running AdventureTime). Ported from Lazcraft's proven dannet_query.
local function dannet_query(peer, query, timeout)
    if not peer or peer == '' or not query or query == '' then return '' end
    pcall(function() mq.cmdf('/squelch /dquery %s -q "%s"', peer, query) end)
    local dl = mq.gettime() + (timeout or 2000)
    while mq.gettime() < dl do
        mq.delay(40)
        local ok, v = pcall(function() return mq.TLO.DanNet(peer).Q(query)() end)
        if ok and v ~= nil and tostring(v) ~= '' and tostring(v) ~= 'NULL' then
            return (tostring(v)):gsub('^%s+', ''):gsub('%s+$', '')
        end
    end
    return ''
end

local function peer_count(peer, item)
    return tonumber(dannet_query(peer, ('FindItemCount[=%s]'):format(item))) or 0
end

-- Batched counts: ask each toon for EVERY item in one round-trip (like Lazcraft's multi-check), instead
-- of one query per item per toon. counts[peerlower][item] = n after query_all_counts.
local counts = {}
pcall(function()
    -- PEER: answer a whole batch of items in one reply (enc:count pairs, comma-separated).
    mq.bind('/at_count_multi', function(driver, list)
        if not driver or not list then return end
        local parts = { '__class:' .. (mq.TLO.Me.Class.ShortName() or '?') }
        for encItem in list:gmatch('[^,]+') do parts[#parts + 1] = encItem .. ':' .. my_count(dec(encItem)) end
        peer_cmdf(driver, '/at_have_multi %s %s', myName, table.concat(parts, ','))
    end)
    -- DRIVER: store a peer's batch.
    mq.bind('/at_have_multi', function(peer, list)
        if not peer then return end
        local pl = peer:lower()
        counts[pl] = counts[pl] or {}
        for pair in (list or ''):gmatch('[^,]+') do
            local e, v = pair:match('^(.-):(.+)$')
            if e == '__class' then counts[pl].__class = dec(v)
            elseif e then counts[pl][dec(e)] = tonumber(v) end
        end
        counts[pl].__got = true
    end)
end)

-- Ask every peer for ALL item counts at once (self counted locally). Fills `counts`; returns when all
-- have replied or a short timeout elapses.
local peerClass = {}   -- peerlower -> class ShortName; static per character, so query it once and cache
-- PER-PEER PIPELINE: each peer works through the item list on its OWN, one outstanding query at a time
-- (Laz DanNet's single-.Q-slot rule), but peers run in PARALLEL - the instant a peer answers its current
-- item we fire its next one, while other peers are still on earlier items. So a jittery/slow peer no
-- longer gates every item-sweep; total time is bounded by the busiest single peer, not the sum of
-- per-item worst cases. A fire and its read are always a poll-tick apart, so we never read a stale slot.
local function query_all_counts(peers, items)
    counts = { [myName:lower()] = { __got = true, __class = mq.TLO.Me.Class.ShortName() or '?' } }
    for _, it in ipairs(items) do counts[myName:lower()][it] = my_count(it) end
    for _, p in ipairs(peers) do counts[p:lower()] = counts[p:lower()] or {} end
    if #peers == 0 or #items == 0 then
        for _, p in ipairs(peers) do counts[p:lower()].__got = true end
        return
    end
    local t0all = mq.gettime()
    -- Ask the group to hold its chatter. Generous window, refreshed below if the pass runs long.
    pcall(function() peer_bcast('/at_quiet %d', 15000) end)

    local function fire(p, q) pcall(function() mq.cmdf('/squelch /dquery %s -q "%s"', p, q) end) end
    local function readQ(p, q)
        local got, raw = nil, 'nil'
        pcall(function()
            local v = mq.TLO.DanNet(p).Q(q)()
            raw = (v == nil) and 'nil' or tostring(v)
            if v ~= nil and raw ~= '' and raw ~= 'NULL' then got = raw end
        end)
        return got, raw
    end

    -- Class needs NO network. member_class reads it from burnClass (pushed by peers on their burn
    -- reports) and falls back to a local spawn lookup - both free. It used to be a /dquery per peer,
    -- which is one more thing to lose under load: when it lost, the class became '?' and every
    -- class-gated decision went wrong for that toon until the next run. A query we do not send cannot
    -- fail. Only peers that resolve to nothing fall through to the query.
    local need = {}
    for _, p in ipairs(peers) do
        if not peerClass[p:lower()] then
            local c = (member_class(p) or ''):upper()
            if c ~= '' and c ~= '?' then peerClass[p:lower()] = c else need[#need + 1] = p end
        end
    end
    if #need > 0 then
        for _, p in ipairs(need) do fire(p, 'Me.Class.ShortName') end
        local dl, left = mq.gettime() + 1500, #need
        while left > 0 and mq.gettime() < dl do
            mq.delay(10)
            for _, p in ipairs(need) do
                if peerClass[p:lower()] == nil then
                    local v = readQ(p, 'Me.Class.ShortName')
                    if v then peerClass[p:lower()] = v; left = left - 1 end
                end
            end
        end
        -- Deliberately NOT caching a failure: leaving it nil means the next run retries, instead of a
        -- single unlucky query poisoning this toon's class for the rest of the session.
        for _, p in ipairs(need) do
            if not peerClass[p:lower()] then log('[counts] class unresolved for %s - will retry next run', p) end
        end
    end
    for _, p in ipairs(peers) do counts[p:lower()].__class = peerClass[p:lower()] or '?' end   -- '?' = unknown; class_key() treats it as 'do not filter'

    -- Item counts, pipelined per peer. On a nil (a query lost under load, NOT a real 0) we RE-FIRE the same
    -- item a few times before giving up on it - transient drops recover. We only abandon a whole peer after
    -- several CONSECUTIVE items fail all their retries (genuinely dark, e.g. DanNet not answering at all).
    local qstr = {}
    for i, it in ipairs(items) do qstr[i] = ('FindItemCount[=%s]'):format(it) end
    local idx, firedAt, tries, dead, ans, fired = {}, {}, {}, {}, {}, {}
    for _, p in ipairs(peers) do idx[p] = 1; tries[p] = 0; dead[p] = 0; ans[p] = 0; fired[p] = false end

    local PER_Q      = 300   -- a working query answers in ~50ms; no answer in this long = lost, re-fire
    local MAX_TRIES  = 3     -- re-fires of one item before we park it for the sweep below
    local MAX_DEAD   = 4     -- consecutive fully-failed items before we call the peer dark and drop it
    -- Starting gap is derived from a TIME BUDGET, not hardcoded. 5 peers x 16 items = 80 queries, so
    -- the old fixed 25ms was really a 2-second budget by accident - fast, and far too tight: bunched
    -- fires are exactly what DanNet drops. Spending 5s instead roughly triples the spacing and the
    -- pass then usually finishes first time, which is quicker overall than 2s plus a retry storm.
    -- Clamped so a tiny run does not crawl and a huge one does not take all day.
    local BUDGET_MS  = 5000
    local FIRE_GAP   = math.max(25, math.min(150, math.floor(BUDGET_MS / math.max(1, #peers * #items))))
    local lastFire   = 0     -- gettime of the last fire (global), so no two queries go out the same instant
    -- Adaptive gap. A fixed stagger cannot know how much this network can take, so it either wastes
    -- time when things are fine or floods when they are not. Widen on every exhausted item, and creep
    -- back down after a run of clean answers. Retrying INTO the congestion that caused the miss is
    -- what turned an ~2s job into a 22s one.
    local gap, GAP_MAX, goodRun, refires = FIRE_GAP, 250, 0, 0
    log('[counts] %d peers x %d items = %d queries, %dms gap (%.1fs budget)',
        #peers, #items, #peers * #items, FIRE_GAP, BUDGET_MS / 1000)
    local unresolved = {}   -- { {peer, itemIndex}, ... } parked for the quiet sweep after the main pass
    -- Deadline scales with the budget rather than sitting at a flat 20s.
    local hardDl = mq.gettime() + math.max(20000, BUDGET_MS * 4)
    local function pending() for _, p in ipairs(peers) do if idx[p] then return true end end return false end
    local nextLog = mq.gettime() + 700

    while pending() and mq.gettime() < hardDl do
        mq.delay(10)
        for _, p in ipairs(peers) do
            local i = idx[p]
            if i then
                if not fired[p] then
                    -- item i needs firing; only fire if the global gap has passed, so fires never bunch up
                    -- (DanNet drops queries when a burst goes out at once - that was the scattered nils).
                    if mq.gettime() - lastFire >= gap then
                        fire(p, qstr[i]); firedAt[p] = mq.gettime(); lastFire = mq.gettime(); fired[p] = true
                    end
                else
                    local v, raw = readQ(p, qstr[i])
                    if v then
                        counts[p:lower()][items[i]] = tonumber(v) or 0
                        ans[p] = ans[p] + 1; dead[p] = 0; tries[p] = 0
                        goodRun = goodRun + 1
                        if goodRun >= 8 and gap > FIRE_GAP then gap = math.max(FIRE_GAP, gap - 10); goodRun = 0 end
                        idx[p] = i + 1; fired[p] = false
                        if idx[p] > #items then idx[p] = nil end
                    elseif (mq.gettime() - (firedAt[p] or 0)) > PER_Q then
                        tries[p] = tries[p] + 1
                        if tries[p] < MAX_TRIES then
                            refires = refires + 1
                            fired[p] = false                                -- lost query: re-fire same item (gated by the adaptive gap)
                        else
                            -- Park it rather than calling it 0. It gets one more go in the sweep, once
                            -- every other peer has finished and there is nothing to contend with.
                            unresolved[#unresolved + 1] = { p, i }
                            gap = math.min(GAP_MAX, gap + 25); goodRun = 0
                            dead[p] = dead[p] + 1; tries[p] = 0
                            if dead[p] >= MAX_DEAD then                     -- several items in a row fully failed: peer is dark
                                for j = i, #items do
                                    if counts[p:lower()][items[j]] == nil then unresolved[#unresolved + 1] = { p, j } end
                                end
                                idx[p] = nil; log('[counts] %s DROPPED (dark) after item %d, ans %d', p, i, ans[p])
                            else
                                idx[p] = i + 1; fired[p] = false
                                -- the success path guards this; the MISS path did not, so a miss on the
                                -- LAST item walked off the end and then indexed counts[peer][nil].
                                if idx[p] > #items then idx[p] = nil end
                            end
                        end
                    end
                end
            end
        end
    end
    -- Anything still in flight at the deadline joins the parked list - the sweep gets a crack at it too.
    if pending() then
        local st = {}
        for _, p in ipairs(peers) do
            if idx[p] then
                st[#st + 1] = p .. '@item' .. idx[p]
                for j = idx[p], #items do
                    if counts[p:lower()][items[j]] == nil then unresolved[#unresolved + 1] = { p, j } end
                end
            end
        end
        log('[counts] !! HARD DEADLINE (%dms) - still pending: %s', mq.gettime() - t0all, table.concat(st, ', '))
    end

    -- QUIET SWEEP. Everything above ran while five other peers were also being queried; by now that is
    -- over, so the parked items get retried one at a time with a wide gap and a patient timeout. This is
    -- the cheapest reliability we can buy - the failures were caused by contention, and there is none
    -- left here. Only what fails THIS pass is genuinely unknown.
    if #unresolved > 0 then
        local before, t0sweep = #unresolved, mq.gettime()
        log('[counts] sweep: retrying %d unanswered item(s) with the network quiet', before)
        local SWEEP_GAP, SWEEP_Q, SWEEP_TRIES, sweepDl = 120, 800, 2, mq.gettime() + 12000
        local still = {}
        for _, u in ipairs(unresolved) do
            local pr, ii = u[1], u[2]
            if counts[pr:lower()][items[ii]] == nil and mq.gettime() < sweepDl then
                local got = false
                for _ = 1, SWEEP_TRIES do
                    fire(pr, qstr[ii])
                    local dl = mq.gettime() + SWEEP_Q
                    while mq.gettime() < dl do
                        mq.delay(20)
                        local v = readQ(pr, qstr[ii])
                        if v then counts[pr:lower()][items[ii]] = tonumber(v) or 0; got = true; break end
                    end
                    if got then break end
                    mq.delay(SWEEP_GAP)
                end
                if not got then still[#still + 1] = { pr, ii } end
            elseif counts[pr:lower()][items[ii]] == nil then
                still[#still + 1] = { pr, ii }
            end
        end
        log('[counts] sweep recovered %d/%d in %dms', before - #still, before, mq.gettime() - t0sweep)
        for _, u in ipairs(still) do
            local pl = u[1]:lower()
            counts[pl].__unknown = counts[pl].__unknown or {}
            counts[pl].__unknown[items[u[2]]] = true
        end
    end

    do
        -- Belt and braces: anything still nil after the sweep is UNKNOWN, and must NOT read as zero -
        -- held() ends in 'or 0', so a nil would look like "carries none" and earn a full hand-out.
        for _, p in ipairs(peers) do
            local pl = p:lower()
            for _, it in ipairs(items) do
                if counts[pl][it] == nil then
                    counts[pl].__unknown = counts[pl].__unknown or {}
                    counts[pl].__unknown[it] = true
                end
            end
        end
    end
    pcall(function() peer_bcast('/at_quiet 0') end)   -- pass over: everyone may talk again
    for _, p in ipairs(peers) do counts[p:lower()].__got = true end
    local miss = 0
    for _, p in ipairs(peers) do
        local u = counts[p:lower()].__unknown
        if u then for _ in pairs(u) do miss = miss + 1 end end
    end
    -- refires and the final gap are the diagnostic: 0 re-fires with the gap still at its starting value
    -- means the pass was genuinely clean and the budget could come down. A grown gap means queries were
    -- lost and quietly recovered in-pass - healthy result, unhealthy network.
    log('[counts] done in %dms - %d/%d answered%s | %d re-fire(s), gap %d->%dms', mq.gettime() - t0all,
        (#peers * #items) - miss, #peers * #items,
        miss > 0 and string.format(', %d still unknown', miss) or '', refires, FIRE_GAP, gap)
end

-- ============ Tank XTargets: healers put the RAID's tanks on their XTarget list (E3 XTarget heals) ============
local HEALER_CLASS = { CLR = true, DRU = true, SHM = true }
local TANK_CLASS   = { WAR = true, PAL = true, SHD = true }
local lastXTankKey = nil   -- last list this toon set (for the on-change announce)
local lastGroupKey  = nil   -- group roster as last seen, so a membership change can re-test the network
local lastGroupList = {}    -- the actual names, so we know WHO left and can shut their worker down
local resyncAt     = 0     -- when to resync after a roster change (0 = nothing pending)
local lastRevive   = 0     -- last crash-watch sweep

-- OTHER groups' raid tanks, minus me and minus my OWN group's tank (he's already covered by the group
-- heal/assist setup - an XTarget slot on him is wasted). Deduped. Not raiding => nothing to watch.
local function raid_tank_names()
    local names, seen = {}, {}
    local mine = {}
    for _, gm in ipairs(group_members()) do mine[gm:lower()] = true end
    local n = tonumber(mq.TLO.Raid.Members()) or 0
    if n > 0 then
        for i = 1, n do
            local m   = mq.TLO.Raid.Member(i)
            local cls = (m.Class.ShortName() or ''):upper()
            local nm  = m.Name() or ''
            if TANK_CLASS[cls] and nm ~= '' and nm:lower() ~= myName:lower()
               and not mine[nm:lower()] and not seen[nm:lower()] then
                seen[nm:lower()] = true; names[#names + 1] = nm
            end
        end
    end
    return names
end

-- Healer-only. Clears the managed slots (2..13, leaving slot 1 for autohater), then sets each tank BY NAME
-- via /xtarget set - never targeting them. The list is recorded to the log file, not announced.
local function set_tank_xtargets(auto)
    -- auto=true : only touch XTargets when the tank list CHANGED since last time (no churn).
    -- auto=false: manual - always clear/set and always announce.
    local myCls = (mq.TLO.Me.Class.ShortName() or ''):upper()
    if not HEALER_CLASS[myCls] then return nil end   -- only healers manage tank XTargets
    if (tonumber(mq.TLO.Raid.Members()) or 0) == 0 then
        -- Not raiding. If we HAD tanks set, we just left a raid: clear the managed slots ONCE, then stay quiet.
        if lastXTankKey and lastXTankKey ~= '' then
            for slot = 2, 13 do pcall(function() mq.cmdf('/xtarget set %d autohater', slot) end) end
            lastXTankKey = nil
        end
        return nil
    end
    local tanks = raid_tank_names()

    -- The list we WANT in the managed slots: raid tanks first, then any pinned extras.
    -- Membership is raid roster (a DEAD tank keeps its place), but a name only takes a slot if its
    -- spawn is in THIS zone - someone out of zone is skipped now and picked up on return.
    -- LATCHED. Spawn('pc =Name') only sees what the CLIENT currently has in its spawn list, and the
    -- client culls distant spawns - so a tank across a big raid zone reads as "not here", loses its
    -- slot, and gets it back when they wander closer. The log showed exactly that: the list flapping
    -- 5 -> 4 -> 5 -> 4 about once a minute, each flap clearing and rebuilding every managed slot.
    -- A tank does not stop being a tank because the client stopped drawing them. Hold a name for a
    -- couple of minutes past the last time it was genuinely visible; someone who actually leaves the
    -- zone falls off after that, which is soon enough for an XTarget slot.
    local function in_zone(nm)
        local ok = false
        pcall(function() ok = (tonumber(mq.TLO.Spawn('pc =' .. nm).ID()) or 0) > 0 end)
        local k = nm:lower()
        if ok then
            xtankSeenAt[k] = mq.gettime()
            return true
        end
        return (mq.gettime() - (xtankSeenAt[k] or 0)) < XTANK_ZONE_LATCH_MS
    end
    local want, seen = {}, {}
    for _, nm in ipairs(tanks) do
        if #want >= 12 then break end
        if in_zone(nm) then want[#want + 1] = nm; seen[nm:lower()] = true end
    end
    -- PINNED extras: names you added by hand. They survive every roster change and every clear,
    -- because they are rebuilt from the saved list each time rather than left sitting in a slot.
    for _, nm in ipairs(xtankPinned) do
        if #want >= 12 then break end
        if not seen[nm:lower()] and in_zone(nm) then want[#want + 1] = nm; seen[nm:lower()] = true end
    end

    local key = table.concat(want, ','):lower()
    local changed = (key ~= (lastXTankKey or '\1'))

    -- VERIFY THE SLOTS, do not just trust the cached key. If someone clears an XTarget by hand the
    -- roster has not changed, so the old "only act when the list changed" test saw nothing to do and
    -- the slot stayed empty until the next raid event. Read what is actually there and compare.
    --
    -- THROTTLED. The roster comparison above is cheap and stays responsive - a tank joining is picked
    -- up at once. This part is twelve TLO reads, and a slot someone cleared by hand is not urgent: it
    -- wants finding within a couple of minutes, not within a second. A manual pass (the Tank XT
    -- button) always verifies, so there is a way to force it.
    -- ASYMMETRIC ON PURPOSE. A tank MISSING from the slots is a problem; an extra name sitting there is
    -- not. So we only rebuild when someone we want is absent - never because a slot holds a name that
    -- is no longer in the list.
    --
    -- This is a fix for a regression I introduced with the verification. The original code only
    -- rebuilt when the roster KEY changed, so a tank whose spawn the client had culled simply KEPT its
    -- slot - stale, but harmless and invisible. The first version of this check compared every slot
    -- against the wanted list and called a culled tank a mismatch, which turned that harmless staleness
    -- into an active deletion: tanks vanished from XTargets mid-raid, which had never happened before.
    -- Membership is by NAME anywhere in the managed range, not by position, because the order shifts
    -- whenever someone is briefly culled and position-matching would call that a mismatch too.
    local mismatch = false
    local dueVerify = (not auto) or ((mq.gettime() - (lastXTankVerify or 0)) >= XTANK_VERIFY_MS)
    if not changed and dueVerify then
        lastXTankVerify = mq.gettime()
        local present = {}
        for i = 1, 12 do
            local got = ''
            pcall(function() got = mq.TLO.Me.XTarget(i + 1).Name() or '' end)
            if got ~= '' then present[got:lower()] = true end
        end
        for _, nm in ipairs(want) do
            if not present[nm:lower()] then
                mismatch = true
                rezlog('[xtank] %s is not on my XTargets - rebuilding', nm)
                break
            end
        end
    end

    lastXTankKey = key
    if changed then lastXTankVerify = mq.gettime() end   -- a rebuild leaves them correct by definition
    if auto and not changed and not mismatch then return tanks end   -- slots already correct
    if mismatch and auto then
        rezlog('[xtank] slots did not match the expected list - restoring')
    end

    for slot = 2, 13 do pcall(function() mq.cmdf('/xtarget set %d autohater', slot) end) end   -- clear managed range
    local slot = 2
    for _, nm in ipairs(want) do
        if slot > 13 then break end
        pcall(function() mq.cmdf('/xtarget set %d %s', slot, nm) end)   -- by name, no /tar, no target change
        mq.delay(40)
        slot = slot + 1
    end
    tanks = want
    -- The log line always happens. The /rsay only when the Announce setting is on - it is raid-wide
    -- chat on every roster change, which is either useful or noise depending on the raid.
    if #tanks > 0 then
        rezlog('[xtank] set %d xtarget(s): %s', #tanks, table.concat(tanks, ', '))
        if xtankAnnounce then
            pcall(function() mq.cmdf('/rsay XTargets set to %d tank(s): %s', #tanks, table.concat(tanks, ', ')) end)
        end
    end
    return tanks
end

-- Manual (the Tank XT button): set mine now and tell every in-group healer to set now too.
-- The AUTO path is autonomous per-healer (each maintains its own in its loop) - no broadcast, no /at_xtank_auto.
local function trigger_tank_xtargets()
    set_tank_xtargets(false)
    for _, nm in ipairs(group_members()) do
        if nm:lower() ~= myName:lower() then peer_cmdf(nm, '/at_xtank') end
    end
end

-- ===== Burn/cooldown watch: each worker reads its OWN item timers locally and PUSHES changes to the driver.
-- No driver-side polling, no query spam - traffic only happens when an item flips (plus a 20s resync). =====
local BURN_WATCH     = {}    -- items/abilities to watch; filled at startup from this toon's [Burn]
local burnLast       = {}    -- worker: last secs seen per item (change detection)
local lastClickPoll = 0     -- button reporters: their own poll, off the burn schedule
lastClickResync = 0         -- NOT local: this chunk is at Lua's 200-local ceiling
local clickStartAt  = 0     -- ...and their own, much shorter startup settle
local lastBurnPoll   = 0     -- worker: last local read
local burnRefreshRequested = false   -- Burns tab 'Refresh' - re-parse the INI and re-report everything
burnPollOn = true            -- /atburnpoll off to silence the burn poll on this toon (crash test)
tribLast   = nil             -- last tribute state sent to the driver, so we only send on change
local burnStartAt    = 0     -- first poll is delayed: reporting before the driver's binds exist loses items
local lastBurnResync = 0     -- slow full re-report; reports only fire on CHANGE, so a dropped one is
                             -- otherwise lost until that item next flips. This heals it.
local lastBurnSend   = 0     -- rate limiter for burn reports (their own lane - see the dribble below)
local burnPending    = {}    -- name -> pending report. Firing a burn flips EVERY item at once, so we queue
                             -- the reports and dribble them out instead of dumping 20+ messages in one tick.
-- Declared AFTER burnPending: a function placed above it would capture a GLOBAL of that name (nil),
-- and pairs(nil) is a hard error the moment the first report queues.
local function burnQueueLen() local n = 0; for _ in pairs(burnPending) do n = n + 1 end; return n end
local discWatch      = nil   -- { name=, at=, expected= } : the disc currently running, for the fade log
local lastDiscPoll   = 0
local burnState      = {}    -- driver: burnState[char][item] = { secs=, updated= }
local driverName     = (not SHOW_UI) and ARGS[2] or nil   -- worker: driver name passed at launch (fallback: /at_ping)
local tributeState   = {}   -- name -> {active=bool, favor=num, updated=} : pushed by peers, never queried
local burnClass      = {}     -- driver: char -> class short name (for the role filter)
local burnFilter     = 'All'  -- Burns tab role filter: All / Tank / DPS / Healer
rezPriority    = {}     -- ordered char names: rez-target priority (top first); saved to disk
local CROWN_ITEM = 'Bloodcursed Crown of Vzith'
local TOKEN_ITEM = 'Exalted Glowing Bath Token'
rezAuto     = false   -- master auto-rez toggle (default OFF - flip on deliberately)
-- Call of the Wild: the shaman/druid rez AA. Renewable, short reuse, no reagent, and no debuff to hand
-- out - so it is strictly cheaper than any clicky and fires AHEAD of the whole order. Globals, not
-- locals: the main chunk is at 180 of Lua's 200-local ceiling and this is not worth spending two on.
COTW_AA     = 'Call of the Wild'
rezCotw     = true    -- CotW fires before the clicky order whenever a holder is up (ON when owned)
rezLog      = {}      -- last 5 actions (driver-side display)
local lastRezPoll = 0
local lastRezFire = 0       -- my own 0.5s stagger
rezPending  = {}      -- corpseID -> gettime to hold off re-firing (rez in flight)
rezDebug    = ''      -- live picker view for diagnosing
rezDebugLast = ''
rezReady    = {}      -- char -> {crown=secs, token=secs}; -1 = doesn't own. Pushed to the group (no queries)
rezCast     = nil     -- my in-flight rez: { id=, item=, at=, tries=, name= } - one corpse at a time
rezConfirm  = {}      -- target name:lower -> gettime of last 'I'm at bind, ready' pong (gates the cast)
local rezMultiWarn = {}     -- name -> corpse count we last mentioned (only speak up when it changes)
local rezDone     = {}      -- name:lower -> expiry: this toon has a rez pending -> stop targeting its corpse
-- Corpse ids that have ALREADY had a rez accepted. NO expiry: on this server a corpse does not vanish
-- when it is rezzed, it can lie there for an hour. Anything keyed on a timeout eventually lapses and
-- re-targets a body rezzed ten minutes ago - which is how Stylin took two crowns for one death. Corpse
-- ids are unique per death, so retiring one permanently cannot block the next.
local rezCorpseDone = {}
rezClaimAt  = {}      -- corpse id -> when I last broadcast a claim on it (do not spam the claim)
rezGateAt   = {}      -- corpse id -> last time we logged which gate is holding the cast
-- What a peer's clicky timer reads RIGHT NOW, counted down from when they reported it. This is the
-- whole reason the rez beat had to run every 2 seconds: the baton compared the raw reported number, so
-- a report of "90s" still said 90 a minute later and a slot that had come up long ago still read as
-- busy. Counting down here means an old report stays an accurate one, and the beat only has to carry
-- CHANGES - which is the difference between broadcasting every 2s and broadcasting when something
-- actually happens.
function rez_peer_secs(rr, clicky)
    if not rr then return nil end
    -- A LOOKUP, not a two-way branch. This read 'token and rr.token or rr.crown', so the moment a third
    -- kind existed 'cotw' fell through to the crown's timer - a shaman with a spent crown would have
    -- looked like a blocked CotW slot and stalled the baton behind itself.
    local base = rr[clicky]
    if base == nil or base < 0 then return base end          -- -1 = does not own it; leave as is
    if base == 0 then return 0 end
    local left = base - math.floor((mq.gettime() - (rr.updated or 0)) / 1000)
    return (left > 0) and left or 0
end
rezPingAt   = {}      -- target name:lower -> gettime of my last handshake ping (rate-limit)
rezExpectUntil = 0    -- until when a rez is inbound for ME (set when I answer a handshake)
rezBoxAt       = 0    -- when the confirmation box appeared (0 = not showing)
rezBoxClicked  = false -- have we already clicked this one
rezNoBoxWarn   = 0    -- last time we said 'expecting a rez, no box found'
rezExpectFrom  = 0    -- when the expecting-a-rez window opened
rezIncAt       = 0    -- when a REZZER last said it was casting on me (not my own readiness)
rezWasDead     = false -- for spotting the moment I get back up
rezAnnounceAt  = 0    -- re-announce readiness once shortly after, in case the first was lost
rezAccept      = true -- click the rez confirmation myself instead of waiting for a human
rezWaitFrom = {}      -- target -> when we started waiting on its handshake
rezWaitWarn = {}      -- target -> last time we complained about the wait
rezFireAt   = {}      -- corpseID -> my jittered earliest fire time (anti-race stagger)
rezSkip     = {}      -- corpseID -> { name:lower -> expiry } : candidates that reported they can't rez it
rezFirstSeen = {}     -- corpseID -> gettime first targeted; drives the baton backstop below
lastCorpseSweep = 0   -- last prune of the corpse-keyed tables above
-- How long a slot may block the chain without either claiming the corpse or broadcasting a skip before a
-- later slot takes over. Only reachable when NO claim is outstanding, so it cannot collide with a rezzer
-- that actually committed. Generous on purpose: a live peer claims within a heartbeat or two, so anything
-- approaching this means its script is not running at all.
REZ_BATON_MAX = 10000
rezOrder    = {}      -- ordered slots { name=, clicky='token'|'crown' } : the cast order (rearrangeable, persisted)
pcall(function() math.randomseed(os.time() + #myName * 131 + (myName:byte(1) or 0)) end)
local rezReadyKey = ''      -- my last-broadcast ready-state (change detection)
local rezHoldUntil = 0      -- after a counts/give pass, give peers a beat to re-heartbeat before trusting staleness
local wasDistributing = false
local lastRezReadyPoll = 0
local myClass        = ''
pcall(function() myClass = (mq.TLO.Me.Class.ShortName() or ''):upper() end)
local function role_of(cls)
    cls = (cls or ''):upper()
    if TANK_CLASS[cls] then return 'Tank' elseif HEALER_CLASS[cls] then return 'Healer' else return 'DPS' end
end

-- Auto-detect an entry's type and return have, ready(bool), secs (0=ready, >0=item countdown, -1=down w/o timer).
local buffNameOf = {}   -- watched item/AA name -> the buff/song it applies ('' = none/unresolvable)
local buffLatch  = {}   -- name -> seconds remaining captured when it went up (held so the push key is stable)
-- Seconds left on the buff a watched thing applies, or 0. Looks on ME only: a debuff lands on the mob and
-- so never shows here, which is exactly the filter we want - no TargetType table to keep in step.
local function my_effect_secs(name, resolver, kind)
    local bn = buffNameOf[name]
    if bn == nil then
        bn = ''
        pcall(function() bn = tostring(resolver() or '') end)
        -- Fallback: lots of AA buffs carry the AA's own name (Fierce Eye grants 'Fierce Eye'), so if the
        -- resolver gives nothing, try the name itself before giving up.
        if bn == '' or bn == 'NULL' then
            local self_named = false
            pcall(function()
                self_named = (tonumber(mq.TLO.Me.Buff(name).Duration.TotalSeconds()) or 0) > 0
                          or (tonumber(mq.TLO.Me.Song(name).Duration.TotalSeconds()) or 0) > 0
            end)
            bn = self_named and name or ''
        end
        buffNameOf[name] = bn
    end
    if bn == '' then return 0 end
    -- ONLY PROBE THE TABLE THE EFFECT CAN ACTUALLY BE IN. This used to read the buff table and then, if
    -- that came back empty, the SONG table - and "empty" is the normal case, because most burns are not
    -- running. So every inactive burn cost a song-table lookup every 2 seconds.
    -- An item's or an AA's granted effect lands in the buff window, not the song window; only spells and
    -- discs can sit in the song table. The song read for kind 'i' and 'a' was always waste.
    -- It is also the dangerous kind of waste. The 2026-08-01 18:50:55 crash was Stylin - the bard, the
    -- toon with the most burn entries (20) and the only one whose song table is rewritten continuously.
    -- Five of six toons logged past that crash; Stylin logged nothing after it.
    -- This does not change what the dashboard shows for items and AAs, because their effects were never
    -- in the song table to find.
    local rem = 0
    pcall(function() rem = tonumber(mq.TLO.Me.Buff(bn).Duration.TotalSeconds()) or 0 end)
    if rem <= 0 and (kind == nil or kind == 'd' or kind == 's') then
        pcall(function() rem = tonumber(mq.TLO.Me.Song(bn).Duration.TotalSeconds()) or 0 end)
    end
    if rem <= 0 then buffLatch[name] = nil; return 0 end
    if not buffLatch[name] then buffLatch[name] = rem end   -- latch so dsecs doesn't churn the push key
    return buffLatch[name]
end
-- Off by default: see the note in the disc branch of ability_state. Flip to true to restore disc
-- countdowns once the client crashes are understood.
DISC_TIME_LEFT = false

-- A SWITCH TO TEST THE CRASH, not a feature. /atburnpoll off stops the 2s burn poll on that toon.
-- Why this one: the 2026-08-01 18:50:55 dump was Stylin, and Stylin is the bard - the toon whose SONG
-- table is rewritten constantly. Five of the six logged past the crash; Stylin logged nothing after it.
-- The burn poll is the only hot path here that both scales with a toon's burn count (Stylin parses 20
-- items, the most in the group) and reads the song table by name, twice per entry, every 2 seconds.
-- That is a hypothesis, NOT a finding. The point of a switch rather than a rewrite is that it gives a
-- clean answer either way: run a session with it off on the bard and the crashes either stop or they do
-- not. Guessing at a fix without that answer is how the last few builds went.
-- Costs while off: the burn dashboard stops updating for that toon. Nothing else uses it.
local DISC_TICK_SECS = 6   -- MQ spell durations are in ticks; if disc countdowns read 6x too long, set this to 1
local function ability_state(name)
    local isItem = false
    pcall(function() isItem = (tonumber(mq.TLO.FindItem('=' .. name).ID()) or 0) > 0 end)
    if isItem then
        local t = 0; pcall(function() t = tonumber(mq.TLO.FindItem('=' .. name).TimerReady()) or 0 end)
        -- ONLY LOOK FOR THE EFFECT WHILE THE THING THAT GRANTS IT IS ON COOLDOWN. A burn's effect cannot
        -- be running if the item has not been used, and an item that has not been used is READY. So a
        -- ready item needs no buff-table lookup at all - and ready is the normal state, most of the time,
        -- for most entries. That single condition removes the great majority of these reads, and it comes
        -- free from the timer we just read.
        -- Early fade is still caught: while it is cooling we keep checking every poll, so an effect that
        -- ends sooner than expected still updates on the next 2s tick. That is the case that mattered.
        local ds = 0
        if t > 0 then
            ds = my_effect_secs(name, function() return mq.TLO.FindItem('=' .. name).Spell.Name() end, 'i')
        else
            buffLatch[name] = nil       -- ready again: whatever it granted is done
        end
        return true, (t == 0), t, (ds > 0), ds, 'i'
    end
    -- OWNERSHIP, not existence. Me.AltAbility[x].ID resolves out of the game's AA table and answers
    -- "is this a real AA", not "have I bought it" - so every character claimed to own Radiant Cure.
    -- It never showed up before because this function was only ever asked about abilities already
    -- known to be owned (burns come from the toon's own [Burn]; MGB entries are gated by class first).
    -- Rank OR ready, and deliberately NOT the timer: on this build AltAbilityTimer returns 1 for an AA
    -- the character does not own, so treating "timer > 0" as ownership marked everyone an owner.
    --   has it:        rank=9 ready=true  timer=0
    --   does not:      rank=0 ready=false timer=1   <- the 1 is noise, not a cooldown
    local aaRank, aaRdy, aaSecs = 0, false, -1
    pcall(function() aaRank = tonumber(mq.TLO.Me.AltAbility(name).Rank()) or 0 end)
    pcall(function() aaRdy  = tlo_true(mq.TLO.Me.AltAbilityReady(name)()) end)
    pcall(function() aaSecs = tonumber(mq.TLO.Me.AltAbilityTimer(name).TotalSeconds()) or -1 end)
    local isAA = (aaRank > 0) or aaRdy
    if isAA then
        -- Same rule as items: a ready AA has not been fired, so nothing it grants can be running.
        local ds = 0
        if not aaRdy then
            ds = my_effect_secs(name, function() return mq.TLO.Me.AltAbility(name).Spell.Name() end, 'a')
        else
            buffLatch[name] = nil
        end
        if aaRdy then return true, true, 0, false, 0, 'a' end
        return true, false, (aaSecs and aaSecs > 0 and aaSecs or -1), (ds > 0), ds, 'a'
    end
    local isSpell = false   -- otherwise a discipline
    pcall(function() isSpell = (tonumber(mq.TLO.Spell(name).ID()) or 0) > 0 end)
    if isSpell then   -- a discipline: also flag whether it's the one currently RUNNING (ActiveDisc)
        local active = false; pcall(function() active = (tostring(mq.TLO.Me.ActiveDisc.Name() or '') == name) end)
        local dsecs = 0
        if active then
            -- DISC COUNTDOWN IS OFF BY DEFAULT - deliberately, pending a crash investigation.
            --
            -- Reading the remaining time means my_effect_secs, which hits Me.Buff(name).Duration and
            -- Me.Song(name).Duration - LIVE buff/song table reads, per active disc, on every burn poll.
            -- Spell.MyDuration below is a static spell-data lookup and touches neither table.
            --
            -- On 2026-07-28 two clients crashed 13 minutes apart, both ACCESS_VIOLATION writing to null
            -- at eqgame.exe +0x40DF45 - the SAME address, so a deterministic client bug rather than
            -- memory pressure. The fault is inside the client's own code and nothing in the crashing
            -- stack implicates the script. BUT the two that died were Lunafeet and Stylin - a monk
            -- cycling four discs and a bard whose song table churns constantly - which are precisely
            -- the worst cases for this read. The rogue and both healers, on the same build, did not.
            -- That is circumstantial, not proof. It is also the one thing that changed.
            --
            -- So this is off until a run shows the crashes continue without it. Set DISC_TIME_LEFT true
            -- to turn it back on; everything else about the burn dashboard is unaffected, and discs
            -- still show their FULL duration while active - just not a countdown.
            --
            -- UPDATE 2026-08-01: that condition has now been met. FOUR ACCESS_VIOLATION dumps (03:54,
            -- 14:50, 14:51, 15:51) all landed with this flag OFF, all at the identical fault address,
            -- all a null-pointer WRITE inside eqgame.exe. The countdown was never the cause - it was
            -- circumstantial, exactly as the note above admitted. This can be turned back on whenever
            -- the countdown is wanted; it is no longer a suspect.
            -- What the 15:51 crash DID narrow: the log covering it (kept, now that sessions rotate)
            -- shows the toon idle - not zoning, not casting, not rezzing, not in combat. Which matches
            -- the observation from play that these happen out of combat.
            if DISC_TIME_LEFT then
                dsecs = my_effect_secs(name, function() return mq.TLO.Spell(name).Name() end, 'd')
            end
            -- MyDuration is YOUR duration (level/focus applied) and is a ticktype, so .TotalSeconds
            -- gives seconds outright; base Duration in ticks is the last resort.
            if dsecs <= 0 then pcall(function() dsecs = tonumber(mq.TLO.Spell(name).MyDuration.TotalSeconds()) or 0 end) end
            if dsecs <= 0 then pcall(function() dsecs = tonumber(mq.TLO.Spell(name).Duration.TotalSeconds()) or 0 end) end
            if dsecs <= 0 then pcall(function() dsecs = (tonumber(mq.TLO.Spell(name).Duration()) or 0) * DISC_TICK_SECS end) end
        end
        local rdy = false; pcall(function() rdy = tlo_true(mq.TLO.Me.CombatAbilityReady(name)()) end)
        if rdy then return true, true, 0, active, dsecs, 'd' end
        local secs = -1; pcall(function() secs = tonumber(mq.TLO.Me.CombatAbilityTimer(name).TotalSeconds()) or -1 end)
        return true, false, (secs and secs > 0 and secs or -1), active, dsecs, 'd'
    end
    return false, false, 0, false, 0, 'i'
end

-- Which buff a draught ACTUALLY lands, resolved once and remembered.
-- ability_state asks the item for Spell.Name() and looks that up in Me.Buff. That is right for most
-- clickies, but potions routinely land a buff named differently from the spell that cast them, and
-- then the lookup finds nothing and the pot reads as never-up. So: try the spell name first, and
-- failing that, scan my buffs for one carrying the draught's own name ('Shimmering Reflection'),
-- which covers both tiers and hardcodes nothing.
-- Once a name resolves it is cached for good, so the scan is a one-off per draught per session. The
-- scan is throttled while unresolved so a toon that has simply never drunk one is not paying for it.
potBuffName = {}
potScanAt   = {}

-- ASK THE CLIENT HOW MANY SLOTS THERE ARE. Every buff/song walk in this file used a hardcoded ceiling -
-- 45 in one place, 55 in four others - which is a guess about someone else's data structure. Reading
-- past the real end of the buff table is a textbook out-of-bounds, and the crash we keep taking is a
-- null-pointer WRITE inside eqgame.exe (four dumps on 2026-08-01, identical address, mq2lua on the live
-- stack every time), which happened most recently while the toon was idle - polling, not fighting.
-- This does not prove the walks are the cause. It removes a guess and costs nothing: reading the number
-- the client reports can only ever be the same or fewer slots than the number we invented.
-- Cached, and re-asked if it ever reads as nothing.
pwBuffSlots = 0
function buff_slot_max(fallback)
    if pwBuffSlots > 0 then return pwBuffSlots end
    local n = 0
    pcall(function() n = tonumber(mq.TLO.Me.MaxBuffSlots()) or 0 end)
    if n > 0 then
        pwBuffSlots = n
        rezlog('[buffs] the client reports %d buff slots (was walking to %d)', n, fallback)
        return n
    end
    return fallback
end
function pot_buff_secs(base)
    local function dur(n)
        local r = 0
        pcall(function() r = tonumber(mq.TLO.Me.Buff(n).Duration.TotalSeconds()) or 0 end)
        if r <= 0 then pcall(function() r = tonumber(mq.TLO.Me.Song(n).Duration.TotalSeconds()) or 0 end) end
        return r
    end
    local cached = potBuffName[base]
    if cached then return dur(cached) end          -- resolved: 0 here is a real "not up", not a miss

    if (mq.gettime() - (potScanAt[base] or 0)) < 5000 then return 0 end
    potScanAt[base] = mq.gettime()

    for _, tier in ipairs({ 'II', 'I' }) do        -- 1) the item's own spell name
        local sn = ''
        pcall(function() sn = tostring(mq.TLO.FindItem('=' .. base .. ' ' .. tier).Spell.Name() or '') end)
        if sn ~= '' and sn ~= 'NULL' and dur(sn) > 0 then potBuffName[base] = sn; return dur(sn) end
    end

    local key = base:gsub('^Draught of ', '')      -- 2) scan for a buff named after the draught
    for i = 1, buff_slot_max(45) do
        local nm = ''
        pcall(function() nm = tostring(mq.TLO.Me.Buff(i).Name() or '') end)
        if nm ~= '' and nm ~= 'NULL' and nm:find(key, 1, true) then
            potBuffName[base] = nm
            return dur(nm)
        end
    end
    return 0
end

-- ---------------------------------------------------------------------------
-- Healer group/raid clicks. One button per healer CLASS present in the group - never per name, so
-- this works for anyone's roster. To add a class, add a line here and nothing else changes.
-- MGB is attached to the FIRST AA only: it buffs the next spell cast, so a second attachment would
-- do nothing. That mirrors the hand-built macro this replaces.
-- ---------------------------------------------------------------------------
-- Keyed by ABILITY, not class: an ability can be usable by several classes, and a class can have
-- more than one. A beastlord gets two buttons (Mercy and Paragon) because they are different
-- abilities on different timers, and each can go into a combo on its own.
MGB_WHO = { CLR='Cleric', DRU='Druid', SHM='Shaman', BRD='Bard', ENC='Enchanter',
            BST='Beastlord', RNG='Ranger' }
MGB_CLICKS = {
    -- short = the button's second word; the first is the caster's class, so a beastlord reads
    -- 'Beastlord Mercy' and 'Beastlord Paragon'. say = the raid announce after the class name.
    { key = 'celestial', short = 'Heals',   say = 'MGB heals',        classes = { 'CLR' },
      abils = { 'Celestial Regeneration', 'Exquisite Benediction' } },
    { key = 'wood',      short = 'Heals',   say = 'MGB heals',        classes = { 'DRU' },
      abils = { 'Spirit of the Wood' } },
    { key = 'ancestral', short = 'Heals',   say = 'MGB heals',        classes = { 'SHM' },
      abils = { 'Ancestral Aid' } },
    { key = 'mercy',     short = 'Mercy',   say = "MGB Nife's Mercy", classes = { 'BRD', 'ENC', 'BST' },
      abils = { "Tome of Nife's Mercy" } },
    { key = 'paragon',   short = 'Paragon', say = 'MGB Paragon',      classes = { 'BST' },
      abils = { 'Paragon of Spirit' } },
    { key = 'auspice',   short = 'Auspice', say = 'MGB Auspice',      classes = { 'RNG' },
      abils = { 'Auspice of the Hunter' } },
}
function mgb_entry(key)
    for _, e in ipairs(MGB_CLICKS) do if e.key == key then return e end end
    return nil
end
function mgb_entries_for(cls)
    local out = {}
    for _, e in ipairs(MGB_CLICKS) do
        for _, c in ipairs(e.classes) do
            if c == cls then out[#out + 1] = e; break end
        end
    end
    return out
end
function mgb_label(cls, e)
    return ((MGB_WHO[cls] or cls) .. ' ' .. (e.short or e.key))
end
MGB_AA    = 'Mass Group Buff'
healState = {}   -- driver: healState[char] = { cls, raid, mgb, aas = {secs...}, updated }
healLast  = {}   -- worker: last-pushed key per ability entry, for change detection

-- Seconds until an ability is usable. 0 = ready now, -1 = I do not have it, >0 = cooling.
-- Routed through ability_state so an ENTRY CAN BE AN AA OR A CLICKY ITEM without the table saying
-- which - Tome of Nife's Mercy is an item, Ancestral Aid is an AA, and both answer the same way here.
function click_secs(name)
    local have, ready, secs = ability_state(name)
    if not have then return -1 end
    if ready then return 0 end
    return (secs and secs > 0) and math.floor(secs) or 0
end

-- Fire my own class's heal chain. The RAID decision is made here, on the healer, not on the driver -
-- raid membership is a local fact and asking for it over the network would only add a way to be wrong.
function mgb_click(key)
    local cls = (mq.TLO.Me.Class.ShortName() or ''):upper()
    local e = mgb_entry(key)
    if not e or #e.abils == 0 then return end
    local raiding = (tonumber(mq.TLO.Raid.Members()) or 0) > 0
    for i, ab in ipairs(e.abils) do
        -- A clicky needs /CastType|Item or E3 looks for a spell by that name and finds nothing.
        local isItem = false
        pcall(function() isItem = (tonumber(mq.TLO.FindItem('=' .. ab).ID()) or 0) > 0 end)
        local opts = isItem and '/CastType|Item' or ''
        if raiding and i == 1 then
            -- MGB rides the FIRST ability only (it buffs the next cast), so the announce fires once.
            pcall(function() mq.cmdf('/nowcast %s "%s%s/BeforeSpell|%s"', myName, ab, opts, MGB_AA) end)
            pcall(function() mq.cmdf('/rsay %s %s', MGB_WHO[cls] or cls, e.say or 'MGB') end)
        else
            pcall(function() mq.cmdf('/nowcast %s "%s%s"', myName, ab, opts) end)
        end
    end
    log('[mgb] %s%s', mgb_label(cls, e), raiding and ' (MGB, raid)' or ' (group)')
end

-- What I can see about ONE draught line, read locally. Both tiers share a recast and land the same
-- kind of buff, so this collapses them into a single answer per line:
--   carries = I hold at least one tier (a toon holding none is left OUT of the group count entirely,
--             otherwise a toon that never carries pots pins the indicator off-colour forever)
--   up      = the buff is running on me right now (ability_state resolves the buff via the item's own
--             Spell.Name, so no buff names are hardcoded and both tiers resolve themselves)
--   secs    = recast remaining on the best tier I hold; 0 = pressing the button would work
--   dsecs   = latched buff duration, so the driver can count down locally without any more traffic
function pot_state(base)
    local carries, up, secs, dsecs = 0, 0, -1, 0
    for _, tier in ipairs({ 'II', 'I' }) do
        local have, ready, s = ability_state(base .. ' ' .. tier)
        if have then
            local n = 0
            pcall(function() n = tonumber(mq.TLO.FindItemCount('=' .. base .. ' ' .. tier)()) or 0 end)
            if n > 0 and carries == 0 then carries, secs = 1, (ready and 0 or (s or -1)) end
        end
    end
    -- One buff per draught LINE, not per tier: I and II land the same effect, so this is asked once.
    local rem = pot_buff_secs(base)
    if rem > 0 then up, dsecs = 1, math.floor(rem) end
    return carries, up, secs, dsecs
end

-- Parse THIS toon's own [Burn] 5minBurn lines from its E3 INI -> bare names (strip the /... suffix).
-- Where this machine keeps its E3 character INIs, when it is not somewhere we would guess.
-- Needed because a boxed group can be split across COMPUTERS: each client resolves its own MQ paths
-- fine, but if E3 lives outside MQ's config tree on one of them, nothing below will find it.
-- Read from a one-line file beside this script rather than from settings, because parse_burns runs
-- long before load_settings and a setting would arrive far too late to be used.
local function e3_path_override()
    local dir
    local ok, src = pcall(function() return debug.getinfo(1, 'S').source end)
    if ok and src then dir = tostring(src):gsub('^@', ''):match('^(.*[/\\])') end
    local fh = io.open((dir or '') .. 'AdventureTime_e3path.txt', 'r')
    if not fh then return nil end
    local line = fh:read('*l'); fh:close()
    if not line then return nil end
    line = line:gsub('^%s+', ''):gsub('%s+$', ''):gsub('[/\\]+$', '')
    if line == '' or line:sub(1, 1) == ';' then return nil end
    return line
end

-- Last resort when none of the guessed paths hit: LOOK for the file. LuaFileSystem is available in
-- this MQ build, so instead of maintaining a list of places E3 might be installed, we walk a few
-- roots and find <Char>_<Server>.ini wherever it actually lives. That makes the whole thing
-- computer-agnostic, which matters when a group is split across machines with different layouts.
-- Bounded hard - depth, total directories, and a skip list - because a filesystem walk on a big
-- drive is not free and this runs at startup.
local function find_e3_ini(who, roots)
    local ok, lfs = pcall(require, 'lfs')
    if not ok or type(lfs) ~= 'table' then return nil end
    local SKIP = { resources = true, logs = true, icons = true, images = true, temp = true,
                   cache = true, ['.git'] = true, backup = true, backups = true, fonts = true }
    local MAX_DIRS, MAX_DEPTH, seen = 600, 4, 0

    local function walk(dir, depth)
        if depth > MAX_DEPTH or seen > MAX_DIRS then return nil end
        seen = seen + 1
        local okIt, it = pcall(function() return lfs.dir(dir) end)
        if not okIt or not it then return nil end
        -- Match ANY <Char>_*.ini rather than one exact name. The server suffix differs between
        -- machines ('Lazarus' vs 'Project Lazarus'), and globbing sidesteps that entirely.
        local pat = '^' .. who:lower():gsub('%W', '%%%0') .. '_.+%.ini$'
        local subs, hitFile = {}, nil
        local okScan = pcall(function()
            for entry in it do
                if entry ~= '.' and entry ~= '..' then
                    local p = dir .. '\\' .. entry
                    local a
                    pcall(function() a = lfs.attributes(p) end)
                    if a and a.mode == 'directory' then
                        if not SKIP[entry:lower()] then subs[#subs + 1] = p end
                    elseif not hitFile and entry:lower():match(pat) then
                        hitFile = entry
                    end
                end
            end
        end)
        if not okScan then return nil end
        if hitFile then return dir, hitFile end
        for _, sd in ipairs(subs) do
            local hit, hf = walk(sd, depth + 1)   -- both values: capturing only the dir loses the name
            if hit then return hit, hf end
        end
        return nil
    end

    for _, r in ipairs(roots) do
        if r and r ~= '' then
            local hit, hitFile = walk((r:gsub('[/\\]+$', '')), 1)
            if hit then return hit, hitFile end
        end
    end
    return nil
end

-- Remember a discovered folder so the next load takes the fast path instead of walking again.
local function write_e3_path(dir)
    local d
    local ok, src = pcall(function() return debug.getinfo(1, 'S').source end)
    if ok and src then d = tostring(src):gsub('^@', ''):match('^(.*[/\\])') end
    local fh = io.open((d or '') .. 'AdventureTime_e3path.txt', 'w')
    if not fh then return end
    fh:write('; found automatically - delete this file to search again\n')
    fh:write(dir .. '\n')
    fh:close()
end


local function parse_burns()
    -- The server TLO is NOT reliable for this: it returns 'Lazarus' on one machine and 'Project
    -- Lazarus' on another, and E3 names the file after the short form. Trusting it blindly meant
    -- hunting for Azyue_Project Lazarus.ini while Azyue_Lazarus.ini sat right there. So: try every
    -- plausible form, and let the directory search below glob rather than match an exact name.
    local srv = ''
    pcall(function() srv = tostring(mq.TLO.MacroQuest.Server() or '') end)
    if srv == 'NULL' then srv = '' end
    local fnames, fseen = {}, {}
    local function addfn(v)
        if v and v ~= '' then
            local nm = myName .. '_' .. v .. '.ini'
            if not fseen[nm] then fseen[nm] = true; fnames[#fnames + 1] = nm end
        end
    end
    addfn(srv)                                   -- whatever the client calls it
    addfn(srv:match('(%S+)%s*$'))                -- last word: 'Project Lazarus' -> 'Lazarus'
    addfn((srv:gsub('%s+', '')))                 -- spaces stripped: 'ProjectLazarus'
    addfn('Lazarus')                             -- the known-good form on Laz
    local fn = fnames[1] or (myName .. '_Lazarus.ini')
    local cfg, root = '', ''
    pcall(function() cfg  = tostring(mq.TLO.MacroQuest.Path('config')() or '') end)
    pcall(function() root = tostring(mq.TLO.MacroQuest.Path('root')()   or '') end)
    local dirs = {}
    local ovr = e3_path_override()
    if ovr then dirs[#dirs + 1] = ovr; dirs[#dirs + 1] = ovr .. '\\e3 Bot Inis' end
    if cfg ~= '' then
        dirs[#dirs + 1] = cfg .. '\\e3 Bot Inis'            -- Path[config] = ...\config
        dirs[#dirs + 1] = cfg .. '\\config\\e3 Bot Inis'    -- if Path[config] = MQ root
    end
    -- Every folder derives from MQ's OWN paths - no install-specific fallback, so this runs anywhere.
    if root ~= '' then
        dirs[#dirs + 1] = root .. '\\config\\e3 Bot Inis'
        dirs[#dirs + 1] = root .. '\\e3 Bot Inis'
        dirs[#dirs + 1] = root .. '\\..\\config\\e3 Bot Inis'   -- MQ installed beside E3
    end
    local candidates = {}
    for _, d in ipairs(dirs) do
        for _, nm in ipairs(fnames) do candidates[#candidates + 1] = d .. '\\' .. nm end
    end
    local f, path
    for _, cand in ipairs(candidates) do
        local fh = io.open(cand, 'r')
        if fh then f, path = fh, cand; break end
    end
    if not f then
        -- Guesses exhausted: go looking for it, then remember where it was so we only do this once.
        local found, foundFile = find_e3_ini(myName, { cfg, root, (root ~= '' and root .. '\\..' or nil) })
        if found and foundFile then
            local fh = io.open(found .. '\\' .. foundFile, 'r')
            if fh then
                f, path = fh, found .. '\\' .. foundFile
                log('[burns] found E3 config by searching: %s', path)
                write_e3_path(found)
            end
        end
    end
    if not f then
        log('\\ar[burns] no INI found for %s\\ax', fn)
        for _, c in ipairs(candidates) do log('   tried: %s', c) end
        log('\\ayA search of the MQ folders did not find it either. Put the folder holding %s', fn)
        log('\\ayinto a file named AdventureTime_e3path.txt next to this script - one line, no')
        log('\\ayquotes - then reload.\\ax')
        return nil
    end
    -- rank for a key: known keys keep their escalation order; anything else sorts after them by the
    -- order it first appeared in the file, so unrecognised names still display sensibly.
    -- Tier order is simply the order the keys appear in the INI. No known-key list to maintain, and
    -- no guessing: people write [Burn] in escalation order anyway, so file order IS the right order.
    local rankOf, seen, nextRank, sec = {}, {}, 0, ''
    local function rank_for(key)
        if not rankOf[key] then nextRank = nextRank + 1; rankOf[key] = nextRank end
        return rankOf[key]
    end
    local tierOf, keyOf = {}, {}
    for line in f:lines() do
        local hdr = line:match('^%s*%[(.-)%]')
        if hdr then sec = hdr:lower() end
        if sec == 'burn' then
            local key, val = line:match('^%s*([^;=%[][^=]-)%s*=%s*(.+)')
            if key and val then
                local r  = rank_for(key)
                local nm = val:match('^([^/\r\n]+)')
                if nm then nm = nm:gsub('%s+$', '') end
                if nm and nm ~= '' then
                    if not tierOf[nm] or r < tierOf[nm] then tierOf[nm] = r; keyOf[nm] = key end   -- LOWEST tier wins
                end
                if not seen[key] then seen[key] = true end
            end
        elseif sec == 'rez' then   -- crown/token rez items -> rank 0 (their own 'Rez' section)
            local val = line:match('^%s*[Aa]uto Rez Spells%s*=%s*(.+)') or line:match('^%s*Rez Spells%s*=%s*(.+)')
            if val then
                local nm = val:match('^([^/\r\n]+)')
                if nm then nm = nm:gsub('%s+$', '') end
                if nm and nm ~= '' and not tierOf[nm] then tierOf[nm] = 0; keyOf[nm] = 'Rez' end
            end
        end
    end
    f:close()
    local list, keys = {}, {}
    for nm, ti in pairs(tierOf) do list[#list + 1] = { name = nm, tier = ti, tkey = keyOf[nm] or '?' } end
    for k in pairs(seen) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return rank_for(a) < rank_for(b) end)
    log('[burns] parsed %d burn item(s) from %s', #list, path)
    log('[burns] tiers found: %s', table.concat(keys, ', '))
    return list
end

-- No INI, or an empty [Burn]: watch NOTHING rather than inventing an item. The old fallback named a
-- specific clicky, which on anyone else's toon is an item they don't own - it reported forever as
-- missing and looked like a broken dashboard.
BURN_WATCH = parse_burns() or {}
if #BURN_WATCH == 0 then
    log('\\ay[burns] no [Burn] entries found for %s - the Burns tab stays empty until that toon has some in its E3 ini.\\ax', myName)
end
do   -- 8s settle + up to 3s of per-character offset, so the group's first reports don't collide
    local off = 0
    for i = 1, #myName do off = off + myName:byte(i) end
    -- 8-16s, not 8-11s: a 3s spread across five workers still bunches them. Wider stagger means the
    -- opening dumps interleave instead of stacking.
    burnStartAt  = mq.gettime() + 8000 + (off % 8000)
    -- 2-3s, not 8-16s: a few small messages, still spread a little so five workers do not all
    -- speak in the same instant.
    clickStartAt = mq.gettime() + 2000 + (off % 1000)
end

-- ===== Rez target priority: a reorderable, persisted list (top gets rezzed first) =====
local REZ_FILE
local function rez_file_path()
    if REZ_FILE then return REZ_FILE end
    local cfg = ''; pcall(function() cfg = tostring(mq.TLO.MacroQuest.Path('config')() or '') end)
    REZ_FILE = (cfg ~= '' and (cfg .. '\\adventuretime_rezpriority.txt')) or 'adventuretime_rezpriority.txt'
    return REZ_FILE
end
local function rez_rank(cls)
    cls = (cls or ''):upper()
    if TANK_CLASS[cls] then return 1 elseif HEALER_CLASS[cls] then return 2
    elseif cls == 'BRD' or cls == 'ENC' then return 4 else return 3 end   -- 3 = DPS, 4 = support
end
-- Group members in the user's chosen display order. Names in charOrder come first, in that order;
-- anyone not listed (a new member, or a fresh install with no order saved) follows in group order.
-- Never invents members - it only ever reorders whoever is actually grouped right now.
function ordered_members()
    local inGroup, out, taken = {}, {}, {}
    for _, nm in ipairs(group_members()) do inGroup[nm:lower()] = nm end
    for _, nm in ipairs(charOrder) do
        local real = inGroup[tostring(nm):lower()]
        if real and not taken[real] then taken[real] = true; out[#out + 1] = real end
    end
    for _, nm in ipairs(group_members()) do
        if not taken[nm] then taken[nm] = true; out[#out + 1] = nm end
    end
    return out
end

-- Global, not local: query_all_counts sits ABOVE this line and calls it. A local would not be in
-- scope there and would resolve as a nil global at runtime.
function member_class(nm)
    local c = burnClass[nm]
    if not c or c == '' then pcall(function() c = (mq.TLO.Spawn('pc =' .. nm).Class.ShortName() or ''):upper() end) end
    return c or ''
end
function default_rez_priority()
    local list = {}
    for _, nm in ipairs(group_members()) do list[#list + 1] = nm end
    table.sort(list, function(a, b)
        local ra, rb = rez_rank(member_class(a)), rez_rank(member_class(b))
        if ra ~= rb then return ra < rb end
        return a:lower() < b:lower()
    end)
    return list
end
function save_rez_priority()
    pcall(function()
        local f = io.open(rez_file_path(), 'w')
        if f then for _, nm in ipairs(rezPriority) do f:write(nm .. '\n') end; f:close() end
    end)
end
function load_rez_priority()
    local list = {}
    pcall(function()
        local f = io.open(rez_file_path(), 'r')
        if f then for line in f:lines() do local nm = (line:gsub('%s+$', '')); if nm ~= '' then list[#list + 1] = nm end end; f:close() end
    end)
    if #list == 0 then list = default_rez_priority() end
    local have = {}; for _, nm in ipairs(list) do have[nm:lower()] = true end
    for _, nm in ipairs(group_members()) do if not have[nm:lower()] then list[#list + 1] = nm end end   -- append any new group members
    rezPriority = list
end

-- ===== Rezzer cast order: a reorderable, persisted list of (name, clicky) slots that DRIVES the baton =====
-- Persisted toggles, so they survive a reload. One key=value per line; add more keys freely.
local SETTINGS_FILE
local function settings_path()
    if SETTINGS_FILE then return SETTINGS_FILE end
    local cfg = ''; pcall(function() cfg = tostring(mq.TLO.MacroQuest.Path('config')() or '') end)
    SETTINGS_FILE = (cfg ~= '' and (cfg .. '\\adventuretime_settings.txt')) or 'adventuretime_settings.txt'
    return SETTINGS_FILE
end
local function save_settings()
    pcall(function()
        local f = io.open(settings_path(), 'w')
        if f then
            f:write('rezAuto=' .. (rezAuto and '1' or '0') .. '\n')
            f:write('rezAccept=' .. (rezAccept and '1' or '0') .. '\n')
            f:write('rezCotw=' .. (rezCotw and '1' or '0') .. '\n')
            f:write('diLadderOff=' .. (DI.ladderOff and '1' or '0') .. '\n')
            for _, k in ipairs({ 'tribute', 'pots', 'burns', 'rez', 'misc' }) do
                f:write('show_' .. k .. '=' .. (showSec[k] and '1' or '0') .. '\n')
            end
            f:write('diAuto=' .. (DI.auto and '1' or '0') .. '\n')
            f:write('miniRez=' .. (miniRez and '1' or '0') .. '\n')
            f:write('miniDI=' .. (miniDI and '1' or '0') .. '\n')
            f:write('miniCombos=' .. (miniCombos and '1' or '0') .. '\n')
            f:write('miniCures=' .. (miniCures and '1' or '0') .. '\n')
            f:write('miniArcane=' .. (miniArcane and '1' or '0') .. '\n')
            f:write('miniPhantom=' .. (miniPhantom and '1' or '0') .. '\n')
            f:write('miniMagic=' .. (miniMagic and '1' or '0') .. '\n')
            f:write('miniOrder=' .. table.concat(miniOrder, ',') .. '\n')
            f:write('miniMode=' .. (miniMode and '1' or '0') .. '\n')
            f:write('miniBurnTable=' .. (miniBurnTable and '1' or '0') .. '\n')
            f:write('charOrder=' .. table.concat(charOrder, ',') .. '\n')
            f:write('miniBurnFilter=' .. tostring(miniBurnFilter) .. '\n')
            f:write('miniBurns=' .. (miniBurns and '1' or '0') .. '\n')
            f:write('miniPots=' .. (miniPots and '1' or '0') .. '\n')
            f:write('miniClicks=' .. (miniClicks and '1' or '0') .. '\n')
            f:write('miniCoth=' .. (miniCoth and '1' or '0') .. '\n')
            f:write('xtankAnnounce=' .. (xtankAnnounce and '1' or '0') .. '\n')
            f:write('xtankPinned=' .. table.concat(xtankPinned, ',') .. '\n')
            f:close()
        end
    end)
end
local function load_settings()
    pcall(function()
        local f = io.open(settings_path(), 'r')
        if not f then return end
        for line in f:lines() do
            -- [%w_] not %w: the show_* keys carry an underscore, so the old pattern returned nil for
            -- them and the k:match below threw. Wrapped in pcall, that aborted the WHOLE load on the
            -- second line of the file - every setting after rezAuto silently never restored.
            local k, v = line:match('^([%w_]+)%s*=%s*(%S+)%s*$')
            if k then
            if k == 'rezAuto' then rezAuto = (v == '1' or v:lower() == 'true') end
            if k == 'rezAccept' then rezAccept = (v == '1' or v:lower() == 'true') end
            if k == 'rezCotw' then rezCotw = (v == '1' or v:lower() == 'true') end
            if k == 'diLadderOff' then DI.ladderOff = (v == '1') end
            local sec = k:match('^show_(%w+)$')
            if sec and showSec[sec] ~= nil then showSec[sec] = (v == '1' or v:lower() == 'true') end
            if k == 'diAuto'    then DI.auto   = (v == '1' or v:lower() == 'true') end
            if k == 'miniRez'   then miniRez   = (v == '1' or v:lower() == 'true') end
            if k == 'miniDI'    then miniDI    = (v == '1' or v:lower() == 'true') end
            if k == 'miniCombos' then miniCombos = (v == '1' or v:lower() == 'true') end
            if k == 'miniCures' then miniCures  = (v == '1' or v:lower() == 'true') end
            if k == 'miniArcane' then miniArcane = (v == '1' or v:lower() == 'true') end
            if k == 'miniPhantom' then miniPhantom = (v == '1' or v:lower() == 'true') end
            if k == 'miniMagic' then miniMagic  = (v == '1' or v:lower() == 'true') end
            if k == 'miniMode' then miniMode = (v == '1' or v:lower() == 'true') end
            if k == 'miniBurnTable' then miniBurnTable = (v == '1' or v:lower() == 'true') end
            if k == 'xtankAnnounce' then xtankAnnounce = (v == '1' or v:lower() == 'true') end
            if k == 'xtankPinned' then
                xtankPinned = {}
                for part in v:gmatch('[^,]+') do
                    part = part:match('^%s*(.-)%s*$')
                    if part ~= '' then xtankPinned[#xtankPinned + 1] = part end
                end
            end
            if k == 'miniBurnFilter' then
                if v == 'All' or v == 'Tank' or v == 'DPS' or v == 'Healer' then miniBurnFilter = v end
            end
            if k == 'charOrder' then
                charOrder = {}
                for part in v:gmatch('[^,]+') do charOrder[#charOrder + 1] = part end
            end
            if k == 'miniOrder' then
                miniOrder = {}
                for part in v:gmatch('[^,]+') do miniOrder[#miniOrder + 1] = part end
            end
            if k == 'miniBurns' then miniBurns = (v == '1' or v:lower() == 'true') end
            if k == 'miniPots'  then miniPots  = (v == '1' or v:lower() == 'true') end
            -- miniHealers: the old name for this setting, still read so it is not lost on upgrade.
            if k == 'miniClicks' or k == 'miniHealers' then miniClicks = (v == '1' or v:lower() == 'true') end
            if k == 'miniCoth'  then miniCoth  = (v == '1' or v:lower() == 'true') end
            end
        end
        f:close()
    end)
end

local REZ_ORDER_FILE
local function rez_order_path()
    if REZ_ORDER_FILE then return REZ_ORDER_FILE end
    local cfg = ''; pcall(function() cfg = tostring(mq.TLO.MacroQuest.Path('config')() or '') end)
    REZ_ORDER_FILE = (cfg ~= '' and (cfg .. '\\adventuretime_rezorder.txt')) or 'adventuretime_rezorder.txt'
    return REZ_ORDER_FILE
end
function default_rez_order()
    if #rezPriority == 0 then load_rez_priority() end
    local nons, tanks = {}, {}
    for _, nm in ipairs(rezPriority) do
        if rez_rank(member_class(nm)) == 1 then tanks[#tanks + 1] = nm else nons[#nons + 1] = nm end
    end
    local ord = {}
    for _, nm in ipairs(nons)  do ord[#ord + 1] = { name = nm, clicky = 'token' } end   -- all non-tank tokens
    for _, nm in ipairs(nons)  do ord[#ord + 1] = { name = nm, clicky = 'crown' } end   -- then non-tank crowns
    for _, nm in ipairs(tanks) do ord[#ord + 1] = { name = nm, clicky = 'token' } end   -- then tank token
    for _, nm in ipairs(tanks) do ord[#ord + 1] = { name = nm, clicky = 'crown' } end   -- then tank crown (last)
    return ord
end
function bcast_rez_order()   -- share the order so every toon's baton agrees (no worker restart needed)
    local parts = {}
    for _, sl in ipairs(rezOrder) do parts[#parts + 1] = sl.name .. ':' .. sl.clicky end
    if #parts > 0 then peer_bcast('/at_rezorder %s', table.concat(parts, ' ')) end
end
function save_rez_order()
    pcall(function()
        local f = io.open(rez_order_path(), 'w')
        if f then for _, sl in ipairs(rezOrder) do f:write(sl.name .. ':' .. sl.clicky .. '\n') end; f:close() end
    end)
end
function load_rez_order()
    local ord = {}
    pcall(function()
        local f = io.open(rez_order_path(), 'r')
        if f then
            for line in f:lines() do
                local nm, ck = line:match('^(.-):(%a+)%s*$')
                if nm and nm ~= '' and (ck == 'token' or ck == 'crown') then ord[#ord + 1] = { name = nm, clicky = ck } end
            end
            f:close()
        end
    end)
    if #ord == 0 then ord = default_rez_order() end
    rezOrder = ord
end

-- ===== Call of the Hero: gather the group by CASCADE =====
-- CoTH summons the target TO the caster, so anyone already gathered who holds an emblem becomes a new
-- summoner. Pulling emblem-holders FIRST therefore doubles the number of summoners each round:
-- 1 -> 2 -> 4 -> 6, instead of one toon casting five times against a long reuse timer.
-- Same-zone only: the summon needs a spawn ID, so someone at bind in another zone is unreachable.
COTH = {
    ITEM   = 'Wayfarers Brotherhood Emblem',
    OPTS   = '/CastType|Item/NoInterrupt',   -- it has a cast time, so it can be interrupted
    RANGE  = 50,           -- within this of the anchor AND in line of sight = 'gathered'
    active = false,        -- gather in progress
    state  = {},           -- name -> { emblem, dist, updated }
    claims = {},           -- name -> expiry, so two summoners don't grab the same target
    lastPush = 0, lastPoll = 0, castAt = 0, startedAt = 0, dbg = '',
    pending = nil,         -- { name, at } : who I summoned, awaiting confirmation they arrived
    anchor  = nil,         -- who everyone is gathering ON: whoever STARTED this gather
}

-- Who everyone is gathering ON: the driver.
-- Who everyone gathers ON. Whoever started the gather, not whoever runs the UI - so /atcoth from any
-- character pulls the group to THAT character. Falls back to the driver only if a gather is somehow
-- running without an anchor having been announced.
function coth_anchor()
    if COTH.anchor and COTH.anchor ~= '' then return COTH.anchor end
    if SHOW_UI then return myName end
    return driverName
end

function coth_read_self()
    local em = -1
    pcall(function()
        if (tonumber(mq.TLO.FindItem('=' .. COTH.ITEM).ID()) or 0) > 0 then
            em = tonumber(mq.TLO.FindItem('=' .. COTH.ITEM).TimerReady()) or 0
        end
    end)
    local d, los = -1, 0
    local a = coth_anchor()
    if a and a:lower() == myName:lower() then
        d, los = 0, 1                           -- I am the anchor
    elseif a then
        pcall(function()
            local sp = mq.TLO.Spawn('pc =' .. a)
            if (tonumber(sp.ID()) or 0) > 0 then
                d = math.floor(tonumber(sp.Distance()) or -1)
                if sp.LineOfSight() == true then los = 1 end
            end
        end)
    end
    return em, d, los
end

-- 'Gathered' means actually WITH the anchor: close enough AND in line of sight, so someone stuck the
-- other side of a wall at 40 units still counts as away and gets pulled.
function coth_gathered(nm)
    local st = COTH.state[nm]
    if not st then return false end
    return (st.dist or -1) >= 0 and st.dist <= COTH.RANGE and (st.los or 0) == 1
end

-- Targets worth summoning, best first: emblem-HOLDERS lead, because each one we pull becomes a summoner.
function coth_targets()
    local hold, rest, now = {}, {}, mq.gettime()
    for _, nm in ipairs(group_members()) do
        local st = COTH.state[nm]
        -- Require FRESH evidence that they're away. With no report yet, 'not gathered' is just
        -- ignorance - and acting on it is what made all six toons summon each other at once.
        local known = st and (now - (st.updated or 0)) < 6000
        if known and not coth_gathered(nm) then
            if (st.emblem or -1) >= 0 then hold[#hold + 1] = nm else rest[#rest + 1] = nm end
        end
    end
    for _, nm in ipairs(rest) do hold[#hold + 1] = nm end
    return hold
end

-- Start or stop the gather, and tell the group. The Misc tab button, the mini button and /atcoth all
-- come through here so the three can never drift apart. Callable from ANY toon, not just the driver:
-- the binds are registered everywhere, so whoever runs /atcoth becomes the one who kicks it off.
function coth_set(on, anchor)
    COTH.active = on and true or false
    anchor = (anchor and anchor ~= '' and anchor) or myName
    if COTH.active then
        COTH.claims = {}; COTH.pending = nil; COTH.startedAt = mq.gettime()
        COTH.anchor = anchor
        COTH.state  = {}   -- distances were measured against the OLD anchor; they mean nothing now
    else
        COTH.anchor = nil
    end
    for _, nm in ipairs(group_members()) do
        if nm:lower() ~= myName:lower() then
            peer_cmdf(nm, '/at_cothgo %s %s', COTH.active and 'on' or 'off', anchor)
        end
    end
    log('[coth] gather %s%s', COTH.active and 'started' or 'stopped',
        COTH.active and (' - gathering on ' .. anchor) or '')
end

function draw_misc_tab()
    ImGui.TextColored(0.85, 0.72, 0.35, 1.0, 'Call of the Hero')
    ImGui.TextDisabled('Gathers the group. Emblem holders are pulled first - each one becomes another')
    ImGui.TextDisabled('summoner, so it cascades instead of one toon casting five times.')
    ImGui.Spacing()
    if COTH.active then
        if ImGui.Button('Stop gather', 110, 0) then coth_set(false) end
    else
        if ImGui.Button('CoTH Group', 110, 0) then coth_set(true) end
    end
    ImGui.SameLine()
    if ImGui.Button('Resync group', 110, 0) then resync_group() end
    ImGui.SameLine()
    if COTH.active then
        ImGui.TextColored(0.36, 0.80, 0.46, 1, 'gathering on ' .. (coth_anchor() or '?'))
    else
        ImGui.TextDisabled('idle')
    end
    ImGui.Spacing()
    -- No table. A gather is automatic and over in seconds, so nobody sits reading six rows of distances
    -- while it runs - and when idle nothing reports at all, which made it six rows of '?' saying
    -- nothing. What actually matters is a stalled gather and WHY, so: one line, detail on hover.
    if not COTH.active and next(COTH.state) == nil then
        ImGui.TextDisabled('Positions are only reported while a gather is running.')
    else
        local here, total, rows = 0, 0, {}
        for _, nm in ipairs(group_members()) do
            total = total + 1
            local st = COTH.state[nm]
            local why
            if coth_gathered(nm) then
                here = here + 1
            elseif not st then
                why = 'no report'
            elseif (st.dist or -1) < 0 then
                why = 'position unknown'
            elseif st.dist <= COTH.RANGE and (st.los or 0) == 0 then
                why = string.format('%d away, no line of sight', st.dist)
            else
                why = string.format('%d away', st.dist)
            end
            local em = st and st.emblem or -1
            if em > 0 then
                why = (why and (why .. ', ') or '') .. string.format('emblem %d:%02d', math.floor(em / 60), em % 60)
            end
            if why then rows[#rows + 1] = nm .. '  ' .. why end
        end
        local cr, cg, cb
        if here >= total then   cr, cg, cb = 0.36, 0.80, 0.46
        elseif here > 0 then    cr, cg, cb = 0.95, 0.85, 0.30
        else                    cr, cg, cb = 0.85, 0.35, 0.35 end
        ImGui.TextColored(cr, cg, cb, 1.0, string.format('%d/%d gathered', here, total))
        if #rows > 0 then
            ImGui.SameLine()
            ImGui.TextDisabled('(hover for who)')
            if ImGui.IsItemHovered and ImGui.IsItemHovered() then
                pcall(function() ImGui.SetTooltip(table.concat(rows, '\n')) end)
            end
        end
    end
    if COTH.dbg ~= '' then ImGui.Spacing(); ImGui.TextColored(0.55, 0.70, 0.80, 1.0, COTH.dbg) end
end

local function coth_tick()
    if not COTH.active then return end
    local now = mq.gettime()
    -- Watch the cast rather than guessing at a duration. The catch is that Me.Casting doesn't register
    -- the instant you fire, so checking immediately reads 'not casting' and we'd move on mid-cast -
    -- hence the 1s settle before the check is trusted. After that, the moment casting ends we're free,
    -- so a fast cast doesn't cost us a fixed wait. (Same pattern the rez cast machine uses.)
    if COTH.castAt > 0 then
        if (now - COTH.castAt) < 1000 then return end
        -- (A rez claim-refresh block used to sit here. It was copied in with the cast-watch pattern
        -- from the rez machine, but CoTH has no corpse and no claim - rezCast is nil in this path, so
        -- every CoTH summon died on "attempt to index global 'rezCast'". Removed; the cast watch below
        -- is the only part that belonged.)
        local casting = false
        pcall(function() casting = (tonumber(mq.TLO.Me.Casting.ID()) or 0) > 0 end)
        if casting then COTH.dbg = 'casting...'; return end
        COTH.castAt = 0
    end
    -- Confirm the last summon landed before considering anyone else. Everyone pushes their distance
    -- every 2s, so we wait for THEIR report rather than assuming. Without this, summoners re-fired the
    -- moment the claim lapsed and the same toon got summoned two or three times.
    if COTH.pending then
        local pn = COTH.pending.name
        if coth_gathered(pn) then
            rezlog('[coth] %s arrived', pn)
            COTH.pending = nil
        elseif (now - COTH.pending.at) > 20000 then
            rezlog('[coth] %s never arrived - releasing', pn)
            COTH.claims[pn] = nil
            peer_bcast('/at_cothfail %s', pn)
            COTH.pending = nil
        else
            COTH.dbg = 'waiting for ' .. pn .. ' to arrive'
            return
        end
    end
    -- Start as soon as everyone has reported a position, rather than sitting out a fixed delay.
    -- Bounded, so one silent/crashed toon can't stall the gather - after that we go with who we have,
    -- and since targets need fresh data anyway, the silent one simply won't be summoned.
    local missing = {}
    for _, nm in ipairs(group_members()) do
        local st = COTH.state[nm]
        if not (st and (now - (st.updated or 0)) < 6000) then missing[#missing + 1] = nm end
    end
    if #missing > 0 and (now - COTH.startedAt) < 10000 then
        COTH.dbg = 'waiting on positions: ' .. table.concat(missing, ', ')
        return
    end
    local left = coth_targets()
    if #left == 0 then
        COTH.active = false; COTH.dbg = 'group gathered'
        rezlog('[coth] gather complete')
        return
    end
    if not coth_gathered(myName) then COTH.dbg = 'not gathered yet myself'; return end
    local em = select(1, coth_read_self())
    if em ~= 0 then COTH.dbg = (em < 0) and 'no emblem' or 'emblem on cooldown'; return end

    for _, nm in ipairs(left) do
        local c = COTH.claims[nm]
        if not (c and now < c) then
            local tid = 0
            pcall(function() tid = tonumber(mq.TLO.Spawn('pc =' .. nm).ID()) or 0 end)
            if tid > 0 then
                COTH.claims[nm] = now + 25000
                COTH.castAt = now
                COTH.pending = { name = nm, at = now }
                peer_bcast('/at_cothclaim %s', nm)
                rezlog('[coth] summoning %s (%d) via "%s%s"', nm, tid, COTH.ITEM, COTH.OPTS)
                pcall(function() mq.cmdf('/nowcast me "%s%s" %d', COTH.ITEM, COTH.OPTS, tid) end)
                pcall(function() mq.cmdf('/gsay Call of the Hero on %s', nm) end)
                return
            end
        end
    end
    COTH.dbg = 'no reachable target (out of zone?)'
end

-- ===== DI staff: the tank's last-ditch death save, fired once the cleric's own options are spent =====
-- Same baton idea as the rez, but simpler: fixed target (the tank), no corpse, no handshake. Kept in ONE
-- global table rather than a dozen locals - this chunk is at Lua's 200-local ceiling.
DI = {
    STAFF   = 'Fabled Staff of Forbidden Rites',
    -- WHAT THE STAFF PUTS ON THE TANK, and the only thing in the whole system that produces it. The cleric
    -- ladder yields Divine Redemption (rung 1) or Divine Guardian (rung 2 AND the boots, which cast the
    -- same buff) - so Divine Intervention appearing on the tank can only have come from a staff. The
    -- client named it for us in "your divine intervention did not take hold on Sebbun".
    STAFF_SPELL = 'Divine Intervention',
    -- Options passed through to E3, mirroring the INI line this replaced. %s = the tank's name:
    -- E3 needs the target NAMED for CheckFor to be evaluated against him rather than the caster.
    -- CheckFor lists EVERY save a tank might already be carrying. Divine Redemption is the upgrade
    -- to Divine Intervention; a cleric who has it casts that instead. Both stay listed so a group
    -- mixing upgraded and un-upgraded clerics still recognises a save that is already up, rather
    -- than spending a staff charge on a tank who is covered.
    -- MATCHES THE RUNG SPEC EXACTLY, minus nothing but the reagent. Inline options are not the problem -
    -- if they were, the rungs would fail too, and they land saves on Sebbun reliably with this same syntax:
    --     rung:  Divine Redemption/CastType|Spell/Sebbun/CheckFor|.../NoInterrupt
    -- The one field the staff carried that the rungs never did is Reagent|Emerald, and reagent tracking is
    -- an ini-config concept for E3's own bookkeeping rather than something the inline caster can act on.
    -- With it in the string the staff clicked, took its cooldown, spent its charge and landed nothing on a
    -- target the log confirmed was Sebbun the PC at 16m.
    -- CheckFor is kept deliberately: it is what stops a charge going into an already-covered tank, and it
    -- costs nothing to leave in a form that is proven to parse.
    OPTS    = '/CastType|Item/%s/CheckFor|Divine Guardian,Divine Intervention,Divine Redemption/NoInterrupt',
    REAGENT = 'Emerald',
    -- EMERALDS DO EXACTLY ONE JOB: below this, do not try to cast. They are not evidence of anything else.
    -- Every other use of them tonight was wrong. As a reagent field in the cast spec they broke the cast
    -- outright. As proof a cast landed they were worse than useless: a refused cast spends them WITHOUT
    -- taking the staff's cooldown, so "emeralds moved" reads identically to success and turned blocked
    -- casts into false LANDED verdicts.
    MIN_EMERALDS = 10,
    -- Retry an apparently-dropped cast this often, and this many times total, before calling it a nocast.
    -- TWELVE seconds, not eight. The staff has a 3s cast time, and the save then has to appear on the tank
    -- and be broadcast back - observed landings run 3.6s, 3.8s, 3.9s, 5.0s, 5.7s and 8.0s. At eight the
    -- retry would have fired at the exact moment that last one landed, spending a second charge on a cast
    -- that was already working. The margin has to clear the SLOWEST success seen, not the average.
    RETRY_AFTER = 12000,
    RETRY_MAX   = 3,
    -- TESTING SWITCH. With the cleric ladder working, the tank is almost always covered and the staff chain
    -- barely runs - which makes it the least exercised part of the system. Turning the ladder off forces
    -- every save to come from a staff. Persisted, because testing means reloading constantly, and shouted
    -- about at every startup so it cannot be left on by accident.
    ladderOff = false,
    DG_AA   = 'Divine Guardian',
    DG_BOOT = "Forsaken Donal's Boots of Mourning",
    -- TOP OF THE CLERIC'S LADDER, in order. EITHER/OR in practice: an upgraded cleric has Divine
    -- Redemption memmed, an un-upgraded one has Divine Intervention, so whichever is actually present is
    -- the rung that counts. Listing both means the gate does not care which cleric is in the group.
    -- Each is read as an AA *and* as a spell - see di_read_self for why SpellReady alone is not enough.
    -- Full ladder: these, then Divine Guardian (AA, then boots), and only then the staff chain.
    CLR_SAVES = { 'Divine Redemption', 'Divine Intervention' },
    -- How long dgReady stays up after a source was last genuinely available. Rides out the global
    -- cooldown between a healing cleric's casts without hiding a real cooldown.
    DG_LATCH_MS = 4000,
    dgLastUp = 0,
    -- Any of these on the tank means a save is up and the staff holds. Divine Redemption is the
    -- upgraded Divine Intervention; keeping the older name costs nothing and covers a peer who
    -- has not upgraded yet.
    SAVES   = { 'Divine Guardian', 'Divine Intervention', 'Divine Redemption' },
    -- How long a REFUSAL stands the chain down. A refusal proves the tank was covered at that instant,
    -- not that it stays covered: a death save can be consumed seconds later. So this expires and re-arms
    -- rather than latching - the cheap side of a wrong guess here is one more emerald, the expensive side
    -- is a tank nobody saved.
    SAVED_HOLD = 25000,
    -- Spec for casting a LADDER RUNG through E3, mirroring the staff's. %s = ability name, cast type, tank.
    -- CheckFor makes E3 decline if the tank is already covered, which is free insurance on top of our own
    -- gate. The CastType tokens are E3's vocabulary, not MQ's: Item is proven on this setup by the staff,
    -- Spell and Alt are not. If a rung logs FIRING and nothing happens, correct the token HERE first.
    RUNG_OPTS = '%s/CastType|%s/%s/CheckFor|Divine Guardian,Divine Intervention,Divine Redemption/NoInterrupt',
    -- How long the ladder sits still after issuing a rung, so the TANK'S save flag can catch up. NOT a wait
    -- on the rung's own cooldown - that read lags badly on items (the boots showed nothing for 29s).
    -- Twelve seconds, from measurement rather than taste: rung casts have landed at 3s, 3.5s, 5s and 7.5s
    -- through NoInterrupt, and at six seconds the 7.5s one got Divine Redemption cast TWICE on 2026-07-30
    -- (21:48:49 and again at 21:48:55, the first landing at 21:48:56). The cost of erring long is small,
    -- because the tank-save gate runs BEFORE the ladder - once a save lands the ladder is not reached at
    -- all, so this only delays the case where the rung genuinely did nothing.
    RUNG_GAP = 12000,
    -- ITEMS NEED LONGER, because their cooldown read is the slow one. Spell and AA rungs have reported in
    -- 2-5s every time; the boots took ~13s on 2026-07-30 (cast 22:35:21.9, save on Sebbun 22:35:35.4) and
    -- lagged 29s in an earlier session. At a flat 12s the boots were re-cast one second before the first
    -- one registered. One gap cannot serve both, and erring long is cheap: the tank-save gate runs before
    -- the ladder, so a landed save means the ladder is never reached and this delay never applies.
    RUNG_GAP_ITEM = 25000,
    -- How long to treat MY staff as spent after I fire it, regardless of what TimerReady says - and that
    -- read has to be treated as untrustworthy, not merely laggy. On 2026-07-30 Nityrc reported staff=0 for
    -- 88 consecutive seconds while genuinely 1408s into reuse, on both the live read AND the pushed sample,
    -- then read 1408 once and dropped straight back to 0. The boots did the same for 29s and Sunetoo's
    -- staff for ~50s. So this has to cover the WHOLE reuse, not a couple of minutes: at 120000 it expired
    -- almost immediately and handed trust back to the read that lies.
    -- It is not a blind bench, though - di_check_landed clears it the moment a verdict says the cast never
    -- happened, so a dropped command costs nothing.
    ASSUME_SPENT = 1800000,
    -- Hard ceiling on waiting for a cast to declare itself. Measured 2026-07-30: 14.5s from the /nowcast
    -- to the staff actually going on reuse, because NoInterrupt queues behind whatever the caster is
    -- already doing. Any FIXED window near that races the cast and calls a queued success a failure - so
    -- the watch now polls until the staff timer moves or the client says it was blocked, and this is only
    -- the backstop for a command E3 silently dropped.
    WATCH_MAX = 45000,
    -- How long to hold for a peer ahead that looks able before taking the turn anyway. Only reachable when
    -- nobody has broadcast /at_difired, so it cannot collide with a cast already out. Ten seconds is long
    -- enough that a live peer will have committed and short enough that a wedged one does not cost the
    -- tank the whole fight.
    baton   = nil,    -- who owns the staff turn right now; defaults to the front of di_order()
    -- Shortest believable time from /nowcast to the staff going on reuse. Observed real flights on
    -- 2026-07-30: 8.4s, 14.5s, 33s - never under eight. So a timer that is ALREADY non-zero a moment
    -- after firing did not just start; the staff was on cooldown and the pre-check misread it as ready.
    -- Without this, 'staff timer > 0' called Stylin's declined command a landing after 1.2s, at 1459s
    -- remaining - a reuse already 300s into counting down rather than a fresh one.
    -- The staff's cast time is 3s (the rez crowns are 1s), so nothing can possibly have landed sooner -
    -- which is exactly why a non-zero staff timer before this point means the cast never left the ground.
    MIN_FLIGHT = 3000,
    auto    = false,
    state   = {},     -- name -> { staff, emeralds, dgReady, saveUp, updated }
    key     = '',     -- my last-pushed state, for change detection
    lastPush = 0, lastPoll = 0, firedAt = 0, trigAt = 0, dbg = '',
    startedAt = 0,    -- set at load; the staff will not fire until the state table has had time to fill
}

-- Everything I can see about myself, read locally.
-- The staff timer EXACTLY as the client reports it - asked TWO WAYS, because one of them lies.
-- TimerReady (seconds) has returned 0 while the staff was demonstrably 1408s into reuse, for 88 seconds
-- straight, on both the live read and the pushed sample. Timer is a separate accessor in TICKS, and the
-- probe on 2026-07-30 showed the pair agreeing to within one tick: TimerReady=1339 against Timer=224
-- (224 x 6 = 1344). Two independent numbers for the same cooldown, so take whichever says "not ready" -
-- a false zero from either one can no longer get a spent staff past the gate on its own.
-- Deliberately max(), not average or preference: being wrongly told we are ON cooldown costs a turn that
-- passes to the next toon anyway, while being wrongly told we are READY costs a wasted commit and a fire
-- into a live reuse. The errors are not symmetric.
function di_raw_staff()
    local secs, ticks = -1, -1
    pcall(function()
        if (tonumber(mq.TLO.FindItem('=' .. DI.STAFF).ID()) or 0) > 0 then
            secs  = tonumber(mq.TLO.FindItem('=' .. DI.STAFF).TimerReady()) or 0
            ticks = tonumber(mq.TLO.FindItem('=' .. DI.STAFF).Timer()) or -1
        end
    end)
    if secs < 0 then return -1 end                  -- do not carry the staff at all
    -- Sample Me.ItemReady here too, because MQ's NULL arrives in Lua as nil and so does a TLO that does not
    -- exist on this build - the two are indistinguishable from one reading. Seeing it return true even once
    -- proves it works, and from then on a nil means "not ready" rather than "no such TLO".
    pcall(function()
        local ir = mq.TLO.Me.ItemReady(DI.STAFF)()
        DI.itemReady = ir
        if tlo_true(ir) then DI.itemReadyWorks = true end
    end)
    local fromTicks = (ticks and ticks > 0) and (ticks * DISC_TICK_SECS) or 0
    -- Say so when they disagree by more than a tick. If this line never appears the pair is sound; if it
    -- appears constantly then the tick conversion is wrong and this whole cross-check needs revisiting.
    if math.abs(fromTicks - secs) > DISC_TICK_SECS and (fromTicks > 0 or secs > 0) then
        if (mq.gettime() - (DI.lastTimerWarn or 0)) > 30000 then
            DI.lastTimerWarn = mq.gettime()
            rezlog('\\ay[di] staff timers disagree: TimerReady=%ds vs Timer=%d ticks (%ds) - using %ds\\ax',
                   secs, ticks, fromTicks, math.max(secs, fromTicks))
        end
    end
    local best = math.max(secs, fromTicks)

    -- A COOLDOWN COUNTS DOWN AT ONE SECOND PER SECOND. Anything else is the read lying, and we can prove it
    -- from our own two readings without persisting a thing or trusting anyone else. Seen on 2026-07-30:
    -- Sunetoo read 1072s remaining, then 0 for five consecutive samples over the next minute, then 88s -
    -- and the arithmetic on both honest readings dates its cast to 23:20:24 either way. A drop of a
    -- thousand seconds in twelve is not a cooldown expiring, it is the client failing to answer.
    -- So: remember the last reading and when it was taken, extrapolate it forward, and if the live read
    -- claims ready while the extrapolation says otherwise, believe the arithmetic. It heals by itself the
    -- moment the client starts answering again, because a real reading always replaces the estimate.
    local now = mq.gettime()
    if best > 0 then
        DI.lastStaffSecs, DI.lastStaffAt = best, now
    elseif DI.lastStaffSecs and DI.lastStaffAt then
        local elapsed = (now - DI.lastStaffAt) / 1000
        local expect  = DI.lastStaffSecs - elapsed
        -- Only argue about a reading big enough to matter. A 6s cooldown genuinely running out looks
        -- identical to the failure at this scale, and second-guessing it just prints noise - which is
        -- exactly what "staff read 0 but it was 6s only 0s ago" was on 2026-07-31. The failure this exists
        -- for is a thousand seconds vanishing, not six.
        if expect > 2 and DI.lastStaffSecs > 15 then
            if (now - (DI.lastImpossibleLog or 0)) > 30000 then
                DI.lastImpossibleLog = now
                rezlog('\\ay[di] staff read 0 but it was %ds only %.0fs ago - impossible, using %ds\\ax',
                       DI.lastStaffSecs, elapsed, math.floor(expect))
            end
            return math.floor(expect)
        end
    end
    return best
end

function di_read_self()
    local staff = di_raw_staff()
    -- ONCE, ON EVERY TOON. This used to sit inside the cleric-only block, so the only staff we ever saw
    -- probed was Nityrc's - the one that reads honestly. Sunetoo's is the one that lies, and we had no
    -- reading of it at all.
    if not DI.saidStaffReads then
        DI.saidStaffReads = true
        rezlog('[di] staff reads at load: %s', di_staff_reads())
    end
    -- I FIRED IT, SO IT IS SPENT UNTIL PROVEN OTHERWISE. TimerReady can keep reading 0 for tens of seconds
    -- after the staff has actually gone on reuse - see ASSUME_SPENT. Trusting that stale zero is what let
    -- the same toon commit twice for one charge. Take whichever is larger, so a real reading always wins.
    if staff >= 0 and DI.assumeSpentUntil and mq.gettime() < DI.assumeSpentUntil then
        local assumed = math.floor((DI.assumeSpentUntil - mq.gettime()) / 1000)
        if assumed > staff then staff = assumed end
    end
    local em = 0; pcall(function() em = tonumber(mq.TLO.FindItemCount('=' .. DI.REAGENT)()) or 0 end)
    -- dgReady is only meaningful from a cleric: 1 = a save source is still IN HAND, so the staff holds.
    -- LADDER ORDER: Divine Redemption, then Divine Guardian (AA, then the boots), then the staff chain.
    local dg = 0
    if (member_class(myName) or ''):upper() == 'CLR' and not DI.ladderOff then
        -- ONCE, at first read: does this cleric even HAVE the lower rungs? The 2026-07-30 logs showed
        -- dg=0 at rest, before any combat, with only Divine Redemption ever flipping on - which means the
        -- ladder is effectively DR-only and the staff engages the instant DR is spent. Whether that is
        -- because the rungs are on cooldown or because they are not owned is not something to guess at.
        if not DI.saidRungs then
            DI.saidRungs = true
            local rank, owns = 0, false
            pcall(function() rank = tonumber(mq.TLO.Me.AltAbility(DI.DG_AA).Rank()) or 0 end)
            pcall(function() owns = (tonumber(mq.TLO.FindItem('=' .. DI.DG_BOOT).ID()) or 0) > 0 end)
            rezlog('[di] ladder inventory: %s rank=%d (%s) | boots %s', DI.DG_AA, rank,
                   (rank > 0) and 'owned' or 'NOT OWNED - this rung can never hold',
                   owns and 'carried' or 'NOT carried - this rung can never hold')
        end
        -- SINGLE SOURCE OF TRUTH. dg was computed here from its own castability reads while the selector
        -- used cooldown timers - so the flag the other five toons gate the staff on could say "the cleric has
        -- nothing left" during a global cooldown while the ladder knew perfectly well rung 1 was up. Same
        -- list, same reads, one answer. The probe on 2026-07-30 settled which reads are honest: gemTimer
        -- counted 35 -> 24 -> 0 while spellReady sat NULL until the very end, and aaTimer ran 210 -> 199 ->
        -- 159 while aaReady read NULL throughout.
        local up = nil
        for _, r in ipairs(di_rung_list()) do
            if r.ready then up = r.name; break end
        end
        if up then
            DI.dgLastUp = mq.gettime()
            DI.dgRung, DI.dgLatched = up, false
            dg = 1
        elseif (mq.gettime() - (DI.dgLastUp or 0)) < DI.DG_LATCH_MS then
            -- The latch should be inert now that these are cooldown reads. Kept so a build where a timer
            -- TLO stops resolving degrades to the old behaviour instead of thrashing the staff chain.
            DI.dgLatched = true
            dg = 1
        else
            DI.dgRung, DI.dgLatched = 'none - staff chain is up', false
        end
    end
    -- Plain name lookup on MY OWN buffs. I tried matching by spell id, copying E3 - that cannot work
    -- here, because Me.Buff(i).ID() returns the SLOT INDEX on this build (the probe showed id=1..25
    -- lining up exactly with slots 1..25), so it can never equal a real spell id. The name lookup was
    -- right all along: the probe reads byName=15 for Divine Intervention and saveUp resolves to 1.
    -- BUFF **OR** SONG. This checked only Me.Buff, and that is the whole DI bug of 2026-07-30: the game
    -- itself said "Your divine intervention did not take hold on Sebbun. (Blocked by Divine Redemption.)"
    -- while saveUp read 0 - so the gate never held, pos 2 committed, and the emerald went on a refusal.
    -- Divine Redemption lives in the short-duration window, where Me.Buff cannot see it. Every other
    -- live-effect read in this file already falls back to Me.Song (my_effect_secs, the burn timers, the
    -- MGB panel); this one place did not, and it was the one place gating a death save.
    -- BUFF TABLE ONLY. This briefly also read Me.Song as a fallback, on a theory that Divine Redemption
    -- lived in the short-duration window. The probe on 2026-07-30 disproved it - Divine Intervention came
    -- back buff=1 song=0, Divine Redemption buff=0 song=0 - so the fallback never once found a save.
    -- It is removed rather than left harmless because di_read_self runs on EVERY DI poll, 250ms in combat,
    -- which made it roughly twelve live song-table reads a second per toon. Frequent live buff/song table
    -- reads are the documented suspect in the 2026-07-28 ACCESS_VIOLATION crashes (see DISC_TIME_LEFT
    -- above, where the same read pattern is gated off for the same reason), and the two clients that died
    -- were the monk and the bard - the worst song-churn cases in the group.
    local save, saveName = 0, nil
    for _, b in ipairs(DI.SAVES) do
        local up = false
        pcall(function() up = (tonumber(mq.TLO.Me.Buff(b).ID()) or 0) > 0 end)
        if up then save, saveName = 1, b; break end
    end
    -- SAY WHICH ONE, not just whether. A bare 0/1 cannot tell you where a save came from, which is why
    -- "did the staff actually land" has needed inference all night instead of an answer. Divine Intervention
    -- appearing on the tank right after a staff cast IS the staff landing; Divine Redemption is the cleric's
    -- rung 1. Logged on change, on the tank itself, so it costs one line per save rather than one per tick.
    if saveName ~= DI.mySaveSaid then
        DI.mySaveSaid = saveName
        if saveName then rezlog('[di] I am now carrying %s', saveName)
        else             rezlog('[di] my save is gone') end
    end
    return staff, em, dg, save, saveName
end

-- The group's tank (same rule the XTarget code uses).
function di_tank()
    for _, nm in ipairs(rezPriority) do
        if rez_rank(member_class(nm)) == 1 then return nm end
    end
    return nil
end

-- Fire order: non-tanks in rez-priority order, tank last. Derived entirely from class + the rez
-- priority list, so it reproduces a hand-built healer -> dps -> tank chain without a second config
-- to maintain, and works for any group composition.
-- WHAT DOES THAT TARGET ID ACTUALLY POINT AT? Every cast in the DI system passes a trailing spawn id, and
-- nothing has ever checked what it resolves to. It has been wrong before - 2026-07-28 logged "FIRING ... 105"
-- where 105 was Sebbun's CORPSE - and on 2026-07-30 Lunafeet's staff took its cooldown and spent its charge
-- while no save appeared on Sebbun, which is exactly what casting at the wrong thing looks like.
-- Logged for the rungs too, because those DO land: a working cast and a failing one side by side is the
-- fastest way to see which part differs.
function di_target_desc(tid, want)
    local nm, ty, dist = '?', '?', -1
    pcall(function() nm = tostring(mq.TLO.Spawn(tid).Name() or '?') end)
    pcall(function() ty = tostring(mq.TLO.Spawn(tid).Type() or '?') end)
    pcall(function() dist = tonumber(mq.TLO.Spawn(tid).Distance()) or -1 end)
    local ok = (nm ~= '?' and want and nm:lower():find(want:lower(), 1, true)) and 'MATCH' or 'MISMATCH'
    return string.format('id=%d -> %s [%s] @%dm (%s, wanted %s)', tid, nm, ty, dist, ok, want or '?')
end

-- ===== BATON STATE =====
-- Who currently owns the DI staff turn. Everyone defaults to the front of the ring, so six toons that have
-- never spoken to each other still agree without a negotiation. It moves only when the holder proves it
-- cannot fire - which for a ~30 minute reuse means a handful of times an hour.
function di_baton_valid(order)
    if not DI.baton or DI.baton == '' then return false end
    for _, nm in ipairs(order) do if nm:lower() == DI.baton:lower() then return true end end
    return false                                    -- holder left the group / is no longer a rezzer
end

function di_baton_set(who, why)
    if not who or who == '' then return end
    if DI.baton and DI.baton:lower() == who:lower() then return end
    DI.baton = who
    rezlog('[di] baton -> %s (%s)', who, why or 'passed')
    peer_bcast('/at_dibaton %s', who)
end

-- A staff came back up. Pull the baton forward to that toon if they sit earlier in the ring than whoever
-- holds it now - the ring belongs at the front, and a returning staff is the only thing that should move it
-- backwards. Same rule locally and remotely so every client reaches the same answer from the same fact.
function di_baton_back(who)
    if not who or who == '' then return end
    local order, wi, bi = di_order(), nil, nil
    for i, nm in ipairs(order) do
        if nm:lower() == who:lower() then wi = i end
        if nm:lower() == (DI.baton or ''):lower() then bi = i end
    end
    if wi and (not bi or wi < bi) then
        DI.baton = who
        rezlog('[di] baton -> %s (its staff is back up)', who)
    end
end

-- Hand it to the next toon in the ring who could ACTUALLY FIRE. Passing blindly to the next name is what
-- put the baton in an infinite loop on 2026-07-30: with all six staves on cooldown, every toon received it,
-- saw its own staff was down, passed it on, and got it back one circuit later - a permanent storm of passes
-- and broadcasts that never settled. A pass to somebody who also cannot act achieves nothing.
-- Peer staff timers are read here ONLY to choose where to send it, never to decide whether to fire - that
-- stays a purely local decision by the holder, which is the whole point of the baton. A wrong guess here is
-- harmless: the receiver simply passes it on when asked to act.
function di_baton_pass(order, why)
    local at
    for i, nm in ipairs(order) do if nm:lower() == (DI.baton or ''):lower() then at = i; break end end
    at = at or 0
    local now = mq.gettime()
    -- TWO PASSES, and the order matters. This used to accept a peer with NO fresh report as a candidate,
    -- on the reasoning that handing it to someone we cannot see beats parking it. That is backwards: a
    -- silent peer is the one toon we have positive evidence ISN'T answering. On 2026-07-31 Khulian's
    -- worker died at 14:28:28 - the sync layer had already logged "silent 18s and failed 2 pings" - and
    -- the baton was handed to it anyway, with reports 15-28s stale, and the chain stopped there.
    -- So: look for someone we can actually see and who can actually fire. Only if nobody qualifies do we
    -- consider the ones we cannot see, because a silent peer is still better than nobody.
    for _, wantFresh in ipairs({ true, false }) do
        for step = 1, #order do
            local cand = order[((at - 1 + step) % #order) + 1]
            if cand:lower() ~= (DI.baton or ''):lower() then
                local st = DI.state[cand]
                local age = st and (now - (st.updated or 0)) or math.huge
                if wantFresh then
                    if age < 15000 and di_peer_staff(st) == 0 and (st.emeralds or 0) >= DI.MIN_EMERALDS then
                        di_baton_set(cand, why); return true
                    end
                elseif age >= 15000 then
                    rezlog('[di] handing the baton to %s despite a %s report - nobody fresher can fire',
                           cand, (age == math.huge) and 'missing' or string.format('%.0fs old', age / 1000))
                    di_baton_set(cand, why); return true
                end
            end
        end
    end
    -- Nobody in the ring can fire. Keep it rather than spinning; whoever's staff comes back first will
    -- pull it forward with /at_dibatonback.
    if (now - (DI.lastParkLog or 0)) > 30000 then
        DI.lastParkLog = now
        rezlog('[di] nobody in the ring can fire - parking the baton with %s (%s)', DI.baton or '?', why or '')
    end
    return false
end

-- EVERY WAY OF ASKING ABOUT THE STAFF'S COOLDOWN, SIDE BY SIDE. FindItem().TimerReady is one accessor, not
-- the only one, and it is the one that has lied in four distinct ways in a single night - 0 for 88s while
-- 1408s into reuse, 0 for 45s after a cast that demonstrably landed, 0 for ~50s after firing, 0 for 29s on
-- the boots. Rather than keep hardening its consumers, print the alternatives next to it and let the
-- numbers say which one is honest. This is what /at_dirungs did for the cleric rungs, where putting
-- gemTimer beside spellReady settled it in one command.
function di_staff_reads()
    local f = {}
    local function get(label, fn)
        local v = 'n/a'
        pcall(function() v = tostring(fn() or 'NULL') end)
        f[#f + 1] = label .. '=' .. v
    end
    get('TimerReady',  function() return mq.TLO.FindItem('=' .. DI.STAFF).TimerReady() end)
    get('Timer',       function() return mq.TLO.FindItem('=' .. DI.STAFF).Timer() end)
    get('ItemReady',   function() return mq.TLO.Me.ItemReady(DI.STAFF)() end)
    get('RecastTime',  function() return mq.TLO.FindItem('=' .. DI.STAFF).Spell.RecastTime() end)
    get('slot',        function() return mq.TLO.FindItem('=' .. DI.STAFF).ItemSlot() end)
    get('slot2',       function() return mq.TLO.FindItem('=' .. DI.STAFF).ItemSlot2() end)
    get('count',       function() return mq.TLO.FindItemCount('=' .. DI.STAFF)() end)
    -- BY SLOT, not by name. A different code path into the same item: if FindItem's cache is what is
    -- empty after a load, reaching it through the pack may already know the truth.
    local pk, sl2 = nil, nil
    pcall(function() pk = tonumber(mq.TLO.FindItem('=' .. DI.STAFF).ItemSlot()) end)
    pcall(function() sl2 = tonumber(mq.TLO.FindItem('=' .. DI.STAFF).ItemSlot2()) end)
    if pk and sl2 and pk >= 23 and pk <= 32 then
        -- 'pack3', not 3. Me.Inventory takes the slot NAME; passing a number returned NULL on every toon,
        -- so this accessor has never actually been tested. It reaches the item through the container
        -- rather than through FindItem's name lookup, which is the point - if FindItem's cache is what is
        -- empty before the item is first touched, the container path may already hold the truth.
        get('bagTimer', function()
            return mq.TLO.Me.Inventory('pack' .. (pk - 22)).Item(sl2 + 1).TimerReady()
        end)
        get('bagItem', function()
            return mq.TLO.Me.Inventory('pack' .. (pk - 22)).Item(sl2 + 1).Name()
        end)
    end
    get('assumed',     function()
        if DI.assumeSpentUntil and mq.gettime() < DI.assumeSpentUntil then
            return math.floor((DI.assumeSpentUntil - mq.gettime()) / 1000)
        end
        return 0
    end)
    return table.concat(f, ' ')
end

function di_order()
    local out = {}
    for _, nm in ipairs(rezPriority) do if rez_rank(member_class(nm)) ~= 1 then out[#out + 1] = nm end end
    for _, nm in ipairs(rezPriority) do if rez_rank(member_class(nm)) == 1 then out[#out + 1] = nm end end
    return out
end

-- The DI panel, as its own function: keeps render() under Lua's 60-upvalue cap.
function draw_di_panel()
do local prev = DI.auto; DI.auto = ImGui.Checkbox('Auto-DI', DI.auto)
   ImGui.SameLine(); if DI.auto then ImGui.TextColored(0.36,0.80,0.46,1,'ON') else ImGui.TextColored(0.85,0.35,0.35,1,'OFF') end
   if prev ~= DI.auto then
       save_settings()
       for _, nm in ipairs(group_members()) do if nm:lower() ~= myName:lower() then peer_cmdf(nm, '/at_diauto %s', DI.auto and 'on' or 'off') end end
   end
end
ImGui.TextDisabled('Death save on the tank, once the cleric has spent Divine Guardian.')
ImGui.Spacing()
do
    local tank = di_tank()
    ImGui.Text('Tank: '); ImGui.SameLine()
    if tank then ImGui.TextColored(0.70,0.70,0.70,1.0, tank) else ImGui.TextColored(0.85,0.35,0.35,1.0,'none') end
    if ImGui.BeginTable('##distaff', 3, (ImGuiTableFlags.BordersInnerV or 0) + (ImGuiTableFlags.RowBg or 0)) then
        ImGui.TableSetupColumn(''); ImGui.TableSetupColumn('Staff'); ImGui.TableSetupColumn('Gem')
        ImGui.TableHeadersRow()
        for _, nm in ipairs(di_order()) do
            local st = DI.state[nm]
            if st and (st.staff or -1) >= 0 then       -- only toons carrying a staff
                ImGui.TableNextRow(); ImGui.TableNextColumn()
                ImGui.TextColored(0.70,0.70,0.70,1.0, nm:sub(1,9))
                ImGui.TableNextColumn()
                local left = math.max(0, (st.staff or 0) - math.floor((mq.gettime() - (st.updated or 0)) / 1000))
                if left == 0 then ImGui.TextColored(0.36,0.80,0.46,1.0,'ready')
                else ImGui.TextColored(0.85,0.35,0.35,1.0, string.format('%d:%02d', math.floor(left/60), left%60)) end
                ImGui.TableNextColumn()
                if (st.emeralds or 0) > 0 then ImGui.TextColored(0.36,0.80,0.46,1.0, tostring(st.emeralds))
                else ImGui.TextColored(0.85,0.35,0.35,1.0,'0') end
            end
        end
        ImGui.EndTable()
    end
    if DI.auto and DI.dbg ~= '' then
        ImGui.Spacing(); ImGui.TextColored(0.55,0.70,0.80,1.0, DI.dbg)
    end
end
end

-- SAY WHY NOTHING HAPPENED. Every gate in the DI path sets DI.dbg and returns, but DI.dbg only ever
-- rendered in the UI panel - so in the log a correct decision ("the tank already has a save") and a broken
-- one look exactly the same: silence. That is what made 2026-07-30 a guessing game about which gate was
-- holding. Logged on CHANGE only, so a steady state costs one line rather than one per tick.
function gate(why)
    if DI.dbg ~= why then
        DI.dbg = why
        rezlog('[di] %s', why)
    end
end

-- ===== THE SAVE LADDER, AS ACTIONS =====
-- We always want a save on the tank. Priority: the cleric's own save spell (Divine Redemption, or Divine
-- Intervention un-upgraded - whichever is actually memmed), then Divine Guardian AA, then the DG boots,
-- and only when all three are down does the DI staff chain take over. When a cleric source comes back up
-- it takes priority again.
--
-- Rungs 1-3 previously had NO ACTOR. AdventureTime read them purely to decide whether to hold the staff,
-- and then waited for E3 to cast them - while E3 was gating them on its own conditions. So on 2026-07-30
-- Sebbun sat uncovered for sixteen seconds with Nityrc holding a ready Divine Redemption AND a ready
-- Divine Guardian, AdventureTime holding the staff because "the cleric has a source", and nobody applying
-- a save at all. Two deciders, no actor. Now there is one decider and it acts.
--
-- Ownership per kind, because the reads differ and each has bitten us:
--   AA    - rank, never the timer (AltAbilityTimer returns 1 for an AA you do not own)
--   spell - SpellReady, which is false forever for something that is actually an AA
--   item  - ID first, because TimerReady on an item you lack reads NULL -> 0 -> "ready"
function di_rung_list()
    local out = {}
    -- RUNG 1 - the cleric's save spell: whichever of Divine Redemption / Divine Intervention is IN A GEM.
    -- Gem presence is the memmed check and the gem's refresh timer is the cooldown. There is deliberately no
    -- AA branch here: the probe showed Divine Redemption reads rank=0 gem=1, so treating it as a possible AA
    -- was invention rather than something the data asked for.
    for _, nm in ipairs(DI.CLR_SAVES) do
        local gem = 0; pcall(function() gem = tonumber(mq.TLO.Me.Gem(nm)()) or 0 end)
        if gem > 0 then
            local s = -1
            pcall(function() s = tonumber(mq.TLO.Me.GemTimer(gem).TotalSeconds()) or -1 end)
            out[#out + 1] = { name = nm, kind = 'Spell', ready = (s == 0) }
            break                                   -- one or the other is memmed, never both
        end
    end
    -- RUNG 2 - Divine Guardian AA, if we have it. Rank proves ownership, AltAbilityTimer is the cooldown.
    do
        local rank = 0; pcall(function() rank = tonumber(mq.TLO.Me.AltAbility(DI.DG_AA).Rank()) or 0 end)
        if rank > 0 then
            local s = -1
            pcall(function() s = tonumber(mq.TLO.Me.AltAbilityTimer(DI.DG_AA).TotalSeconds()) or -1 end)
            out[#out + 1] = { name = DI.DG_AA, kind = 'Alt', ready = (s == 0) }
        end
    end
    -- RUNG 3 - the boots, if we carry them. ID proves ownership, TimerReady is the cooldown.
    do
        local id = 0; pcall(function() id = tonumber(mq.TLO.FindItem('=' .. DI.DG_BOOT).ID()) or 0 end)
        if id > 0 then
            local t = -1
            pcall(function() t = tonumber(mq.TLO.FindItem('=' .. DI.DG_BOOT).TimerReady()) or -1 end)
            out[#out + 1] = { name = DI.DG_BOOT, kind = 'Item', ready = (t == 0) }
        end
    end
    return out
end

-- Returns true if the ladder is handling it and the staff chain should stand down this tick.
-- A SELECTOR, NOT A TRANSACTION. Read the cooldowns, cast the first one that is up, done. Everything that
-- used to live here - watches, settles, per-rung verdicts, a skip list, a post-cast hold, strike counters -
-- was machinery I invented to work around state reads that lie right after an action, and every regression
-- on 2026-07-30 came out of that machinery rather than out of the ladder itself. The cooldown read is the
-- state: once a rung is cast its timer starts, so the next tick naturally moves down the list.
function di_try_rung(tank, tid, now)
    if DI.ladderOff then return false end          -- testing: force everything through the staff chain
    if (member_class(myName) or ''):upper() ~= 'CLR' then return false end

    -- LET THE TANK'S FLAG BE THE ANSWER, and give it a moment to catch up. Asking the rung "has your
    -- cooldown started" worked for the spell and AA rungs (Divine Redemption reported in ~2s, Divine
    -- Guardian in ~3.5s) but is useless for the BOOTS, because FindItem().TimerReady() lags - the boots sat
    -- at "cooldown not started yet" for 29 seconds on 2026-07-30, the same lag already documented on the
    -- staff. And clearing on the cooldown fired a second rung 1.6s before the save became visible, so two
    -- saves went out for one emergency.
    -- So: after issuing, sit still for RUNG_GAP. The tank-save gate in di_tick runs BEFORE this function, so
    -- if the save landed the ladder is never reached at all; if it did not, we move down. Measured lag from
    -- cast to the flag reading 1 is under four seconds.
    local gapFor = (DI.rungKind == 'Item') and DI.RUNG_GAP_ITEM or DI.RUNG_GAP
    if DI.rungAt and (now - DI.rungAt) < gapFor then
        gate(string.format('%s issued %.0fs ago of %.0fs - waiting for %s to show a save',
                           DI.rungName or 'a rung', (now - DI.rungAt) / 1000, gapFor / 1000, tank))
        return true
    end
    DI.rungName, DI.rungAt = nil, nil

    for i, r in ipairs(di_rung_list()) do
        if r.ready then
            DI.rungName, DI.rungAt, DI.rungKind = r.name, now, r.kind
            rezlog('[di] LADDER rung %d: %s on %s | %s', i, r.name, tank, di_target_desc(tid, tank))
            local spec = string.format(DI.RUNG_OPTS, r.name, r.kind, tank)
            pcall(function() mq.cmdf('/nowcast me "%s" %d', spec, tid) end)
            return true
        end
    end

    gate('all three cleric saves are down - staff chain')
    return false                                    -- rungs 1-3 all on cooldown: the staff chain is next
end

local function di_tick()
    if not DI.auto then return end
    local now = mq.gettime()

    -- A CAST IN FLIGHT BLOCKS EVERYTHING. My own watch being open means I have a command out that has not
    -- declared itself yet; re-committing into that is what queued two casts in E3 on 2026-07-30 (00:54:59
    -- then 00:55:16, one landing at ~00:55:31). Peers park on DI.firedAt until the ceiling, but the
    -- verdict broadcast releases them the moment there is an answer, so the chain is not actually slower.
    if DI.watch then return end
    if (now - DI.firedAt) < DI.WATCH_MAX then return end
    -- Somebody's cast was refused very recently, which means the tank was covered. Expires on its own.
    if DI.savedUntil and now < DI.savedUntil then
        gate(string.format('a refusal says the tank is covered (%.0fs left)', (DI.savedUntil - now) / 1000))
        DI.trigAt, DI.turnAt = 0, nil
        return
    end
    local tank = di_tank()
    if not tank then gate('no tank in group'); DI.trigAt, DI.turnAt = 0, nil; return end

    local inCombat = false
    pcall(function() inCombat = (tostring(mq.TLO.Me.CombatState() or ''):upper() == 'COMBAT') end)
    if not inCombat then gate('not in combat'); DI.trigAt, DI.turnAt = 0, nil; return end

    local ts = DI.state[tank]
    if ts and ts.saveUp == 1 then gate(tank .. ' already has a save up'); DI.trigAt, DI.turnAt = 0, nil; return end
    -- No report from the tank at all? Then this gate did nothing, and we are about to fire blind into a
    -- tank that may well already be saved. Worth saying out loud - it is the difference between the
    -- check failing and the check never running.
    if not ts then
        if (now - (DI.noTankWarn or 0)) > 15000 then
            DI.noTankWarn = now
            rezlog('\\ay[di] no DI report from %s - cannot tell if it already has a save\\ax', tank)
        end
    elseif (now - (ts.updated or 0)) > 10000 then
        if (now - (DI.noTankWarn or 0)) > 15000 then
            DI.noTankWarn = now
            rezlog('\\ay[di] %s report is %ds old - save state may be stale\\ax', tank,
                   math.floor((now - (ts.updated or 0)) / 1000))
        end
    end
    -- EVERY guard below is a reason to HOLD, so an empty DI.state makes them all pass vacuously and the
    -- staff fires blind. That is what happened one second after load: no tank report yet, so "does he
    -- already have a save" could not be asked, nobody was known to be ahead, and nothing said wait.
    -- Refuse to commit without a fresh word from the tank - firing when he is already saved is exactly
    -- the waste this whole baton exists to prevent.
    if not ts or (now - (ts.updated or 0)) >= 8000 then
        gate('no fresh report from ' .. tank .. ' - holding')
        DI.trigAt, DI.turnAt = 0, nil
        return
    end
    if (now - DI.startedAt) < 12000 then
        gate('settling after load')   -- peers report on their own schedule; do not act on a half-built table
        DI.trigAt, DI.turnAt = 0, nil
        return
    end

    -- THE LADDER GOES FIRST. If I am the cleric and I still have a rung, I apply the save myself - the
    -- staff chain is the LAST rung, not a parallel system. This is the actor that rungs 1-3 never had.
    do
        local tid = 0
        pcall(function() tid = tonumber(mq.TLO.Spawn('pc =' .. tank).ID()) or 0 end)
        if tid > 0 and di_try_rung(tank, tid, now) then
            DI.trigAt, DI.turnAt = 0, nil
            return
        end
    end

    -- ALWAYS CHECK THE CLERIC, and treat "cannot check" as a reason to hold. The loop below only holds
    -- when it FINDS a fresh dgReady=1 - so a cleric with no entry yet, or one whose report has aged out,
    -- fell through it and the staff fired on the assumption the ladder was spent. That assumption is the
    -- wrong way round: this chain is the rare last resort, so silence from the cleric means wait, not go.
    -- Same rule the tank already gets a few lines up.
    for _, nm in ipairs(group_members()) do
        if (member_class(nm) or ''):upper() == 'CLR' then
            local cs = DI.state[nm]
            if not cs or (now - (cs.updated or 0)) >= 30000 then
                gate('no fresh save-ladder report from ' .. nm .. ' - holding')
                if (now - (DI.noClrWarn or 0)) > 15000 then
                    DI.noClrWarn = now
                    rezlog('\\ay[di] no fresh report from %s (CLR) - holding the staff rather than assuming its ladder is spent\\ax', nm)
                end
                DI.trigAt, DI.turnAt = 0, nil
                return
            end
        end
    end

    -- Which cleric, if any, currently claims a save source. Found first, judged second - the old form
    -- returned from inside the loop, which left nowhere to reset the timer below.
    local clrHold = nil
    for nm, st in pairs(DI.state) do
        -- 30s, matching the other DI freshness window. This was left at 8000 when the beat went to a
        -- 20s idle keepalive: in combat the cadence tightens to 4s so it is fine, but at the START of a
        -- fight the last report can be far older than 8s - the gate would read a perfectly good cleric
        -- as stale and fire the staff while Divine Guardian was still up.
        if st.dgReady == 1 and (now - (st.updated or 0)) < 30000 then clrHold = nm; break end
    end
    if clrHold then
        -- NO GRACE VALVE ANY MORE. It used to release the staff after 15s of a cleric "claiming" a source
        -- while the tank stayed uncovered - a workaround for rungs 1-3 having no actor, where a claim
        -- genuinely never turned into a save. The cleric now casts its own rungs, so a claim becomes a
        -- save or the ladder logs why it did not, and jumping the cleric would just stack a second save.
        gate('cleric ladder still has a rung (' .. clrHold .. ')')
        if (now - (DI.lastHoldLog or 0)) > 5000 then
            DI.lastHoldLog = now
            local cst = DI.state[clrHold]
            rezlog('[di] holding: %s still has a save source (report %.1fs old)', clrHold,
                   (now - ((cst and cst.updated) or now)) / 1000)
        end
        DI.trigAt, DI.turnAt = 0, nil; return
    end

    -- ===== THE BATON =====
    -- ONE HOLDER, PASSED ON THE STAFF'S OWN COOLDOWN. Every toon used to evaluate every other toon's staff
    -- timer over the network to work out whose turn it was - six reads of a signal that, on 2026-07-30,
    -- reported Nityrc's staff ready for 88 straight seconds while it sat 1408s into reuse, on both the live
    -- read and the pushed sample. Deciding turn order from six copies of an unreliable number is what made
    -- the ring "get rough" while the cleric ladder stayed solid.
    -- The baton needs ONE toon to know ONE thing about ITSELF: I just fired, so I am out. That we can
    -- establish - we watch our own cast and hold the full reuse on a confirmed landing. A ~30 minute reuse
    -- makes it a natural token: it moves a handful of times an hour, not per fight.
    -- It is also race-free by construction. Only the holder may commit, so two toons cannot fire at once -
    -- which is what the stagger, the distance checks and the hold windows all existed to prevent.
    if DI.trigAt == 0 then DI.trigAt = now end
    local order = di_order()
    if #order == 0 then gate('nobody in the DI order'); return end
    if not di_baton_valid(order) then di_baton_set(order[1], 'holder is gone - resetting to the front') end
    if DI.baton:lower() ~= myName:lower() then
        gate(string.format('%s has the baton', DI.baton)); return
    end

    local staff, em = di_read_self()                       -- authoritative self-check before committing
    -- HOLDING THE BATON WHILE UNABLE IS THE ONE WAY THIS DESIGN STALLS. Every branch that means "not me"
    -- has to hand it on, or the ring stops at whoever happens to be holding it.
    if staff ~= 0 or em < DI.MIN_EMERALDS then
        di_baton_pass(order, string.format('%s cannot fire (staff %ds, %d emerald(s))', myName, staff, em))
        gate('I have the baton but cannot fire - passed it on'); return
    end
    if DI.cannotFire and mq.gettime() < DI.cannotFire then
        di_baton_pass(order, myName .. ' is stood down')
        gate(string.format('I am stood down for another %.0fs - passed the baton',
                           (DI.cannotFire - mq.gettime()) / 1000)); return
    elseif DI.cannotFire then
        DI.cannotFire, DI.noCastStrikes = nil, 0    -- window elapsed: back in the chain, clean slate
        rezlog('[di] stand-down elapsed - I am back in the DI chain')
    end
    -- THIRD OPINION, AND A DIRECT ONE. Me.ItemReady is a boolean rather than a countdown, so it cannot go
    -- stale the way a ticking timer can. The probe on 2026-07-30 had it unanimous across all six toons -
    -- true on the four with ready staves, NULL on the two genuinely on cooldown - agreeing with both
    -- timers every time. If it disagrees with them here, believe it and hand the baton on: being wrongly
    -- told we are busy costs a turn that passes anyway, being wrongly told we are ready costs a charge.
    if DI.itemReadyWorks and not tlo_true(DI.itemReady) then
        di_baton_pass(order, string.format('%s ItemReady says the staff is not ready', myName))
        gate('timers read ready but ItemReady disagrees - passed the baton'); return
    end
    -- SECOND OPINION. TimerReady() returns NULL for a transient reason and `or 0` turns that into "ready",
    -- which is how Stylin committed on 2026-07-30 with its staff 300s into reuse. DI.state[myName] holds
    -- the last PUSHED reading - an independent sample taken on an earlier poll - so requiring both to
    -- agree costs nothing and cannot be fooled by a single bad read.
    do
        local mine = DI.state[myName]
        if mine and (mine.staff or 0) > 0 then
            di_baton_pass(order, string.format('%s staff is really %ds into reuse', myName, mine.staff))
            gate(string.format('staff read ready but my last report said %ds - not trusting it', mine.staff))
            return
        end
    end
    local tid = 0; pcall(function() tid = tonumber(mq.TLO.Spawn('pc =' .. tank).ID()) or 0 end)
    if tid <= 0 then gate('tank not in zone'); return end
    -- ALIVE, not merely present. A death save cannot land on someone who is already dead, and a
    -- freshly-dead PC spawn lingers three to four seconds - exactly the window where the tank dies and
    -- this fires into it. Seen 2026-07-28: "FIRING ... 105" where 105 was Sebbun's CORPSE id, twice,
    -- followed both times by "the staff did NOT go off" - and the emerald count still fell 1976 -> 1974
    -- between the two attempts, so the misfires were not free.
    -- Same check the rez path uses: Spawn.Dead plus a HOVER/DEAD state, because Type()=='PC' stays true
    -- on a corpse. If the tank is gone, the rez chain is the right answer, not a save.
    local tSeen, tAlive = owner_seen(tank)
    if not (tSeen and tAlive) then
        gate('tank is not alive - a save cannot land on a corpse')
        rezlog('[di] holding: %s is down (a death save cannot land on a corpse) - the rez chain has it', tank)
        DI.trigAt, DI.turnAt = 0, nil
        return
    end

    DI.firedAt = now
    DI.trigAt, DI.turnAt = 0, nil
    peer_bcast('/at_difired')   -- everyone else stands down immediately
    -- No position any more - holding the baton IS the turn. myPos was declared by the peer-scan block that
    -- the baton replaced, and this line kept referencing it: string.format('%d', nil) threw, and DI shut
    -- itself off on whichever toon the baton had just been passed to. Sunetoo, 21:30:44, one second after
    -- receiving it.
    rezlog('[di] committing with the baton (%d emerald(s)) - told the group to stand down', em)
    -- WHAT I BELIEVED WHEN I COMMITTED. The decision reads every peer's staff/emerald/dgReady/saveUp
    -- and then throws that away, which left "why did it fire while a cleric had a save ready" as an
    -- argument about freshness windows rather than a line in the log. Every other thing fixed in this
    -- system became easy the moment it recorded what it thought it knew.
    do
        local parts = {}
        for nm, st in pairs(DI.state) do
            parts[#parts + 1] = string.format('%s[staff=%s em=%s dg=%s save=%s age=%.1fs]',
                nm, tostring(st.staff), tostring(st.emeralds), tostring(st.dgReady),
                tostring(st.saveUp), (now - (st.updated or now)) / 1000)
        end
        table.sort(parts)
        rezlog('[di] state at commit: %s', table.concat(parts, ' '))
    end
    -- OPTS is empty now, so this is just the item name - but keep the concat so restoring the old string
    -- is a one-line change. :format on a string with no %s is a no-op, so an empty OPTS is safe.
    local spec = DI.STAFF .. ((DI.OPTS ~= '') and DI.OPTS:format(tank) or '')
    rezlog('[di] target check: %s', di_target_desc(tid, tank))
    rezlog('[di] FIRING /nowcast me "%s" %d', spec, tid)
    pcall(function() mq.cmdf('/nowcast me "%s" %d', spec, tid) end)
    -- NOT ANNOUNCED HERE. Saying "DI staff on X" at fire time claims something we do not know yet: the
    -- cast may be interrupted, dropped or refused. Announcing it anyway is how a log ends up disagreeing
    -- with what actually happened, which is exactly the thing that makes an issue report useless.
    -- The /gsay now happens at the verdict - see di_check_landed.
    -- Remember what we had, so the next tick can tell whether the cast actually happened. E3 declines
    -- silently when CheckFor|Divine Guardian,Divine Intervention finds the tank already has a save -
    -- so from here it looks identical to a successful cast, and the trigger simply fires again.
    DI.watch = { at = now, em = em, tank = tank, tries = 1,
                 cmd = string.format('/nowcast me "%s" %d', spec, tid),
                 saveWas = (DI.state[tank] or {}).saveName }   -- so a NEW one is attributable to this cast
    -- From this moment my staff counts as spent, whatever TimerReady claims. Set alongside the watch so
    -- that even a verdict which goes wrong cannot hand me back a staff I have already fired.
    DI.assumeSpentUntil = now + DI.ASSUME_SPENT
end

-- Did the last DI staff cast actually go off? THREE outcomes, not two - lumping the last two together
-- is what made Sunetoo fire the same save three times on 2026-07-30.
--     staff on reuse                -> it landed
--     still ready, emerald spent    -> it CAST and was refused (the reagent goes on completion, the
--                                      reuse timer only starts if the effect takes hold)
--     still ready, emerald intact   -> it never cast; E3 declined before doing anything. The only retry.
function di_check_landed()
    if not DI.watch then return end
    -- POLLED, not timed. Every fixed window tried here has been wrong in one direction or the other: 4s
    -- called an 8.4s cast a failure, and 15s called a 14.5s cast a failure by half a second. Both signals
    -- that matter are definitive the instant they appear, so watch for them instead of guessing a
    -- duration - the staff timer moving proves it landed, the client's block message proves it did not.
    -- Landing is now noticed within a loop iteration rather than at the end of a window, which also lets
    -- the chain advance immediately.
    -- w IS TAKEN FIRST, and this is not cosmetic. It used to be declared below the verdict block while
    -- spentEm referenced w.em above it - so `w` resolved to a nil global and every call threw. The call
    -- site is pcall(di_check_landed), which discarded the error, so from at-emeraldproof onwards NO verdict
    -- ever ran: no LANDED, no BLOCKED, no nocast. And because DI.watch is only cleared in here, and di_tick
    -- returns early while a watch is open, every toon that fired the staff was locked out of DI for good.
    local w = DI.watch
    local age = mq.gettime() - w.at
    -- RAW, not di_read_self. The assume-spent overlay makes the timer non-zero the instant we fire, which
    -- this check would read as "already on reuse" and call every cast a misread.
    local st = di_raw_staff()
    local _, em = di_read_self()
    local blocked = DI.blockedAt and DI.blockedAt >= w.at
    -- EMERALDS PROVE NOTHING HERE. This briefly treated a drop in the emerald count as proof the cast
    -- landed, on the reasoning that the timer sometimes lies. But a REFUSED cast spends emeralds and does
    -- NOT take the staff's cooldown - so "emeralds moved, timer still zero" is precisely what a refusal
    -- looks like, and this rule was reading refusals as successes. Both "LANDED ... staff on reuse 0s,
    -- 2 emerald(s) spent" verdicts on 2026-07-30 have that exact signature, and both toons still read
    -- ready long afterwards, which a real cast would not allow.
    -- The staff's own cooldown starting is the only thing that proves a cast happened.
    -- THE TANK CARRYING OUR SPELL IS THE PROOF. This is the only signal that has never been wrong, and it
    -- is the actual goal rather than a proxy for it. On 2026-07-31 Nityrc fired at 00:08:15.265, Sebbun
    -- reported "I am now carrying Divine Intervention" at 00:08:20.515 - and the staff's own TimerReady
    -- read 0 for the entire 45s watch, so the verdict called it a dropped command and handed him back a
    -- staff he had just spent. Divine Intervention can only come from a staff: the cleric's ladder makes
    -- Divine Redemption or Divine Guardian.
    local ts = DI.state[w.tank or '']
    local tankHasOurs = ts and ts.saveName == DI.STAFF_SPELL and ts.saveName ~= w.saveWas
    local verdict
    if tankHasOurs                                then verdict = 'landed'
    elseif (st or 0) > 0 and age >= DI.MIN_FLIGHT then verdict = 'landed'
    -- Non-zero this fast means it never left the ground: the staff was already on reuse and the readiness
    -- check that let us commit was reading a NULL TimerReady as zero.
    elseif (st or 0) > 0                     then verdict = 'stale'
    elseif blocked                           then verdict = 'blocked'
    elseif age >= DI.WATCH_MAX               then verdict = 'nocast'
    else
        -- RETRY BEFORE GIVING UP. A cast can be interrupted - the caster moves, gets stunned, gets hit
        -- mid-cast - and one dropped command should not cost the full watch and a strike. The rez has
        -- done this for ages ("retry 2 /nowcast me Call of the Wild") and the staff never learned it.
        -- Only fires while NOTHING has happened: a landing, a block or a real cooldown all resolve above,
        -- so reaching here means the command went nowhere at all.
        local due = DI.RETRY_AFTER * (w.tries or 1)
        if (w.tries or 1) < DI.RETRY_MAX and age >= due then
            -- Stop if the tank got covered meanwhile - somebody else's cast landed and this is no longer
            -- needed. Retrying into that just spends a charge for a refusal.
            local ts2 = DI.state[w.tank or '']
            if ts2 and (ts2.saveUp or 0) == 1 then return end
            w.tries = (w.tries or 1) + 1
            rezlog('[di] no sign of that cast after %.0fs - retry %d of %d', age / 1000, w.tries, DI.RETRY_MAX)
            pcall(function() mq.cmd(w.cmd) end)
        end
        return                              -- still in flight - E3 may be holding it behind a heal
    end
    DI.watch = nil
    local spent = (w.em or 0) - em        -- reported only; nothing branches on it
    -- THE VERDICT DECIDES WHETHER THE ASSUMPTION SURVIVES. assumeSpentUntil is set optimistically at fire
    -- time because TimerReady cannot be trusted in that window; here we know what actually happened, so
    -- either keep it (spent) or drop it (never left the ground). Without this, a dropped command would
    -- bench a toon for the full reuse.
    if verdict == 'landed' then
        DI.noCastStrikes = 0
        -- Announce it NOW, because now it is true. Includes the retry count when it took more than one
        -- attempt, so the group sees the cast was fought for rather than clean.
        pcall(function()
            if (w.tries or 1) > 1 then mq.cmdf('/gsay DI staff on %s (took %d tries)', w.tank, w.tries)
            else                       mq.cmdf('/gsay DI staff on %s', w.tank) end
        end)
        -- THE POINT OF THE WHOLE THING. My staff is now spent for its full reuse, which is the one fact
        -- about myself I can establish reliably - so hand the turn on rather than making five other toons
        -- work it out from a timer that lies.
        di_baton_pass(di_order(), string.format('%s spent its staff', myName))
        rezlog('[di] LANDED after %.1fs - %s%s (staff timer reads %ds, %d emerald(s) spent)', age / 1000,
               tankHasOurs and ((w.tank or 'the tank') .. ' is carrying ' .. DI.STAFF_SPELL) or 'staff on reuse',
               tankHasOurs and '' or '', st, spent)
    elseif verdict == 'stale' then
        -- We just got a TRUE reading out of a read that normally lies - the staff was already this far into
        -- reuse. Trust it and hold ourselves out for exactly that long, instead of going back to a zero that
        -- would let us re-commit on the very next tick (Nityrc did precisely that, twice, at 21:18:31).
        rezlog('[di] staff reads at the misread: %s', di_staff_reads())
        DI.assumeSpentUntil = mq.gettime() + (st * 1000)
        di_baton_pass(di_order(), string.format('%s staff was already %ds into reuse', myName, st))
        rezlog('\\ay[di] NOT A CAST - staff read ready but is %ds into reuse %0.1fs later. The readiness check misread it; nothing was spent. Holding myself out %ds.\\ax',
               st, age / 1000, st)
    elseif verdict == 'blocked' then
        -- A REFUSAL IS A SAVE DETECTOR, and a shared one. The game blocks the cast because the tank is
        -- already covered, so there is no reason for the next four toons to each try and discover the
        -- same fact. Confirmed live 2026-07-30 ("Blocked by Divine Redemption").
        DI.assumeSpentUntil = nil     -- a refused cast does not take the cooldown; I am still ready
        DI.savedUntil = mq.gettime() + DI.SAVED_HOLD
        peer_bcast('/at_disaved %d', DI.SAVED_HOLD)
        pcall(function() peer_cmdf(w.tank or '', '/at_disavedump %s', myName) end)
        rezlog('\\ay[di] BLOCKED after %.1fs - %s is already covered by %s. Holding the chain %ds. (saveUp=%s)\\ax',
               age / 1000, DI.blockedOn ~= '' and DI.blockedOn or (w.tank or '?'), DI.blockedBy or '?',
               math.floor(DI.SAVED_HOLD / 1000), ts and tostring(ts.saveUp) or 'no report')
    else
        -- TWO STRIKES AND I STOP VOLUNTEERING. A nocast means 45s passed with no cooldown and no block
        -- message: the command went nowhere at all. Once is a fluke; twice means this character cannot
        -- actually fire the staff whatever the item table says, and holding a slot in the chain for it
        -- costs the tank a real save every time the baton reaches it. Session-only and local - nothing is
        -- persisted, so a relog re-tests it, and the loud line is the point.
        -- Either the command really was dropped, or TimerReady lied for the whole watch. These are the
        -- moments worth capturing: every accessor at once, so the next log says which one was right.
        rezlog('[di] staff reads at the nocast: %s', di_staff_reads())
        DI.assumeSpentUntil = nil     -- the command went nowhere: I still have my staff
        -- A SAVE CANNOT LAND ON A CORPSE, so a cast that failed because the tank died is not evidence that
        -- I cannot fire. On 2026-07-31 Sunetoo took both of its strikes during a wipe - Sebbun died 0.7s
        -- and 4s after the two casts - and benched itself for the rest of the session for something that
        -- was never its fault.
        local tankAlive = true
        do
            local rr = rezReady[w.tank or '']
            if rr and rr.alive == false then tankAlive = false end
        end
        if not tankAlive then
            rezlog('[di] the staff did NOT go off, but %s died during the cast - not counting that against me',
                   w.tank or 'the tank')
            DI.firedAt = 0
            peer_bcast('/at_didone')
            return
        end
        DI.noCastStrikes = (DI.noCastStrikes or 0) + 1
        pcall(function()
            mq.cmdf('/gsay DI staff interrupted %dx on %s, passing to the next caster', w.tries or 1, w.tank)
        end)
        rezlog('\\ay[di] the staff did NOT go off in %ds - no block message, staff still ready. E3 dropped it. (strike %d)\\ax',
               math.floor(DI.WATCH_MAX / 1000), DI.noCastStrikes)
        if DI.noCastStrikes >= 2 and not DI.cannotFire then
            -- TIME-LIMITED, not for the session. Standing a toon down after two genuine failures is right,
            -- but making it permanent means one bad patch of a fight removes it until a reload - and we now
            -- know a toon that failed twice can land the very next cast (Khulian failed on corpse 258 at
            -- 01:12:06, Lunafeet landed on the same target 45s later).
            DI.cannotFire = mq.gettime() + 600000
            di_baton_pass(di_order(), myName .. ' cannot get the staff to fire')
            rezlog('\\ar[di] failed to fire the staff %d times with no cooldown and no block - standing myself down for 10 minutes. /at_distaff to see why.\\ax',
                   DI.noCastStrikes)
        end
    end
    -- RELEASE THE CHAIN. Peers were parked on DI.firedAt waiting out the ceiling; the verdict is the real
    -- end of the attempt, so say so and let the next slot go now instead of at the timeout.
    DI.firedAt = 0
    peer_bcast('/at_didone')
end

-- ===== distributed rez picker: each toon decides locally; E3 only eats the /nowcast =====
local function my_rez_secs(itemName)   -- MY own clicky: seconds until ready, 0 = ready, -1 = don't own it
    local has = false
    pcall(function() has = (tonumber(mq.TLO.FindItem('=' .. itemName).ID()) or 0) > 0 end)
    if not has then return -1 end
    local t = 0; pcall(function() t = tonumber(mq.TLO.FindItem('=' .. itemName).TimerReady()) or 0 end)
    return t
end
-- MY CotW: seconds until ready, 0 = ready, -1 = don't own it. Same contract as my_rez_secs above so the
-- push, the election and the display all treat it identically.
-- Ownership comes from RANK, never the timer: on this build AltAbilityTimer returns 1 for an AA the
-- character does not own (ability_state documents the same trap), so "timer > 0" would mark all six
-- toons holders. Rank also IS the class check - only shamans and druids can buy CotW - which is why
-- nothing here touches Me.Class and why this needs no edit when the group composition changes.
function my_cotw_secs()
    local rank = 0; pcall(function() rank = tonumber(mq.TLO.Me.AltAbility(COTW_AA).Rank()) or 0 end)
    if rank <= 0 then return -1 end
    local rdy = false; pcall(function() rdy = tlo_true(mq.TLO.Me.AltAbilityReady(COTW_AA)()) end)
    if rdy then return 0 end
    local s = -1; pcall(function() s = tonumber(mq.TLO.Me.AltAbilityTimer(COTW_AA).TotalSeconds()) or -1 end)
    return (s and s > 0) and s or 0
end
-- One mapping from slot kind to MY seconds-until-ready, so the election and the did-it-actually-fire
-- retry check can never disagree about what a slot needs.
function rez_kind_secs(kind)
    if kind == 'cotw'  then return my_cotw_secs() end
    if kind == 'token' then return my_rez_secs(TOKEN_ITEM) end
    return my_rez_secs(CROWN_ITEM)
end
-- EFFECTIVE ORDER = CotW holders first, then the saved clicky order untouched. Pinning rather than
-- inserting is deliberate: rezOrder stays exactly what the arrows and the saved file say it is, so this
-- feature cannot quietly rewrite an order you spent time arranging.
-- With one holder and one corpse the claim broadcast still applies, so nothing double-rezzes. With a
-- shaman AND a druid on a wipe, both fire before a single consumable is spent - which is the point.
-- SORTED BY NAME because every toon builds this list locally from its own reports and they all have to
-- arrive at the same list. Anything derived from table iteration order would differ per client and
-- desync the baton. Alphabetical is arbitrary; identical everywhere is the requirement.
function rez_chain()
    if #rezOrder == 0 then load_rez_order() end
    if not rezCotw then return rezOrder end
    local pins = {}
    for _, nm in ipairs(group_members()) do
        -- my own read is live and authoritative; everyone else's arrives on the heartbeat
        local secs = (nm:lower() == myName:lower()) and my_cotw_secs() or (rezReady[nm] and rezReady[nm].cotw)
        if secs ~= nil and secs >= 0 then pins[#pins + 1] = nm end
    end
    if #pins == 0 then return rezOrder end
    table.sort(pins, function(a, b) return a:lower() < b:lower() end)
    local chain = {}
    for _, nm in ipairs(pins)     do chain[#chain + 1] = { name = nm, clicky = 'cotw' } end
    for _, sl in ipairs(rezOrder) do chain[#chain + 1] = sl end
    return chain
end
-- Heartbeat cadence state. On a global table rather than four locals: this chunk is at Lua's ceiling.
HB = { rezFast = false, diFast = false, lastCheck = 0, corpse = false }
-- Set by the driver while it is running a count pass. Workers hold their OWN chatter for the duration,
-- so the queries get the network to themselves. Workers cannot see the driver's `distributing` flag,
-- and the two collide by construction: a worker's first burn poll lands 8-11s after load and dumps
-- every watched item at once, which is exactly when the driver's startup Refresh is querying.
-- Expires on its own so a driver that dies mid-pass cannot mute the group forever.
-- Only the BURN dribble honours this. The rez and DI heartbeats keep talking: their staleness windows
-- are 6s and 8s, shorter than a quiet window, and a toon that goes silent is indistinguishable from a
-- toon whose script died - which is the exact failure those heartbeats exist to prevent. They are a
-- handful of messages against the burn burst's 86.
quietUntil = 0
function peer_quiet() return mq.gettime() < quietUntil end
-- Is there a rez event in progress from where I stand? Throttled to once a second: it is asked every
-- frame to decide the cadence, and SpawnCount is not free. Counts ANY pc corpse in zone rather than
-- walking the group by name - one TLO call instead of eighteen, and over-triggering on a stranger's
-- corpse only costs us the fast cadence we would otherwise have had anyway.
-- WHICH SPAWN FILTERS ACTUALLY WORK ON THIS BUILD? Run /at_corpseprobe with a GROUP corpse on the
-- ground and read the numbers off. This exists because the guard above skips the whole sweep when the
-- zone has no pc corpses - and rez_event_now() counts EVERY pc corpse, strangers included. In a busy
-- zone somebody else's corpse keeps the fast path armed and the saving evaporates.
-- If a narrower filter works, both the cadence and the skip get sharper. Whether MQ accepts 'group' or
-- 'raid' alongside a corpse type is not something to assume: a corpse is not itself a group member, so
-- the filter may legitimately return 0 always. Guessing at syntax is what cost this project a night;
-- printing the variants side by side settles it in one command.
function corpse_probe()
    local q = { 'pccorpse', 'pccorpse group', 'group pccorpse', 'pccorpse raid', 'raid pccorpse',
                'corpse group', 'pccorpse radius 200' }
    log('[corpse] spawn-search variants (want: a narrow one that matches the group count):')
    for _, v in ipairs(q) do
        local n = 'ERR'
        pcall(function() n = tostring(mq.TLO.SpawnCount(v)() or 'NULL') end)
        log('   SpawnCount[%-22s] = %s', v, n)
    end
    local mine = 0
    for _, nm in ipairs(group_members()) do
        local c = 0
        pcall(function() c = tonumber(mq.TLO.SpawnCount('pccorpse ' .. nm)()) or 0 end)
        mine = mine + c
    end
    log('   per-name sum over the group = %d   <- the number a narrow filter should agree with', mine)
end

function rez_event_now()
    if (mq.gettime() - HB.lastCheck) > 1000 then
        HB.lastCheck = mq.gettime()
        local dead, n = false, 0
        pcall(function() dead = tlo_true(mq.TLO.Me.Dead()) end)
        -- NOTE THE TRAILING (). Without it this passes the TLO object to tonumber, which yields nil,
        -- so n was always 0 and HB.corpse was 'dead or false'. The fast tick therefore never engaged
        -- for a living rezzer - the rez loop has been running at 1000ms instead of 250ms all along,
        -- which is the ~970ms gap between "ready to fire" and FIRING in the logs.
        pcall(function() n = tonumber(mq.TLO.SpawnCount('pccorpse')()) or 0 end)
        HB.corpse = dead or n > 0
    end
    return HB.corpse
end

-- How far the rez clickies actually reach, asked of the item rather than assumed. Cached, because it
-- cannot change mid-session - but only once a real answer comes back, so a toon that has not got the
-- item yet does not lock in the fallback forever.
-- Do not even try beyond this. The clicky reports 200 of reach and we briefly attempted out to 300 on
-- the theory that the reading might be stale - but with Distance3D on a 250ms tick it is current, and
-- every one of those long casts failed while burning a charge. 150 is inside the reach with room for
-- the boundary flicker that comes from a group moving.
REZ_MAX_DIST = 150
-- ---------------------------------------------------------------------------
-- Raid rezzes. Deliberately meaner than group rezzes on every axis:
--   TOKENS ONLY   - the crown applies a debuff, and that is not ours to hand out to someone else's
--                   character. Tokens are cheap, clean, and only cost a longer reuse.
--   100, not 150  - no walking across a zone for a stranger.
--   GROUP FIRST   - a raid corpse is only ever considered when no group corpse is targetable. Spending
--                   our rez capacity on people we do not control while our own cleric lies there is
--                   exactly the wrong trade.
--   STAGGERED     - one token per rezzer per RAID_TOKEN_GAP, so five holders do not empty at once.
-- They accept on their own: they run E3, whose dialog handler clicks the box on a 1s timer. We are not
-- trying to beat them to the accept, only to the cast.
-- ---------------------------------------------------------------------------
RAID_REZ        = true    -- rez raid members outside the group at all
RAID_MAX_DIST   = 100
RAID_TOKEN_GAP  = 15000   -- per rezzer
-- Who may spend a CROWN on someone outside the group. The crown lands a debuff, which is why raid
-- rezzes were tokens-only to begin with - but the healers and the bard carry crowns that would
-- otherwise sit idle while the raid waits on one token every fifteen seconds. Everyone else stays
-- tokens-only, so a melee crown is never spent on a stranger.
RAID_CROWN_CLASSES = { CLR = true, DRU = true, SHM = true, BRD = true }
function raid_crown_ok()
    return RAID_CROWN_CLASSES[myClass] == true
end
RAID_OFFER_GAP  = 15000   -- per corpse: long enough to cast, be accepted, and stand up
raidOffered     = {}      -- corpse id -> when we last threw a token at it
lastRaidToken   = 0       -- my own last raid token
lastRaidScan    = 0       -- the raid corpse sweep is expensive; once a second is plenty

-- Raid members who are NOT in my group. Group is handled by the normal path and always wins.
function raid_outsiders()
    local out, mine = {}, {}
    for _, nm in ipairs(group_members()) do mine[nm:lower()] = true end
    local n = 0
    pcall(function() n = tonumber(mq.TLO.Raid.Members()) or 0 end)
    for i = 1, n do
        local nm = ''
        pcall(function() nm = tostring(mq.TLO.Raid.Member(i).Name() or '') end)
        nm = strip_corpse(nm)
        if nm ~= '' and not mine[nm:lower()] then out[#out + 1] = nm end
    end
    return out
end
-- The DI staff is cast ON THE TANK, so it has a reach too - and nothing was checking it. A peer five
-- hundred units from the tank with a ready staff counted as "able", so everyone behind held for a cast
-- that could never land. Exactly the hole the rez had before distance went local.
-- Flat 200. The clicky reports 200 and that is the standard cast range, so there is nothing to gain
-- from asking the item and a fallback to guess at when it is not in hand. One number, no cache, no
-- probe - and if a peer is further than this from the tank they cannot help, whatever the item says.
DI_MAX_DIST = 200
rezRangeCache = nil
function rez_range()
    if rezRangeCache then return rezRangeCache end
    local best = 0
    for _, it in ipairs({ CROWN_ITEM, TOKEN_ITEM }) do
        local r = 0
        pcall(function() r = tonumber(mq.TLO.FindItem('=' .. it).Spell.MyRange()) or 0 end)
        if r > best then best = r end
    end
    if best > 0 then
        rezRangeCache = best
        rezlog('[rez] cast range resolved to %d from the clicky', best)
        return best
    end
    return 100   -- no item in hand yet: assume the usual, ask again next time
end

-- Returns corpseID, distance - the NEWEST corpse this toon has.
-- A character can have several corpses at once, because a rezzed one does not disappear here. Asking
-- Spawn[] for "their corpse" returns whichever the search happens to hit, and different rezzers got
-- different answers: one targeted a body from ten minutes ago, another the fresh one, each claimed a
-- different id, and the poor sod got rezzed twice. Spawn ids climb over time, so the highest is the
-- most recent death - and every rezzer picking the highest means everyone agrees on the same body.
-- How far a PEER is from a corpse - computed here, from spawn positions, asking nobody.
-- This is the piece that lets the whole election go local. "Is slot 1 close enough to act?" was the one
-- fact we could not see and therefore had to wait to be told, and every timeout, skip broadcast and
-- re-fire in the old baton existed to paper over that wait. Both positions are in our own spawn list.
-- Returns nil when we cannot see them at all, which the caller treats as "not close" - correct, since a
-- peer we cannot even see is not standing next to a corpse we can.
-- Is this character standing here alive, right now? Asked of the zone, not of a report. A living PC
-- and a corpse are different spawn types, so seeing their PC spawn IS the answer - and it is available
-- the instant the script loads, with no network at all.
-- This is why five toons queued up to rez an OLD corpse seconds after a restart: the owner was visible
-- and alive the whole time, but their report had not arrived yet, so we assumed the worst.
-- Returns SEEN, ALIVE. Two answers, not one, because "I cannot see them" and "I can see them and
-- they are dead" are completely different situations and collapsing them into a single boolean is
-- what let a stale report override a plain local fact.
-- Change-detected log of what the LOCAL read sees, per character. This is here to answer one
-- question with evidence rather than assumption: does the zone tell us someone is dead, promptly and
-- correctly, without any network at all? If it does, most of the rez heartbeat is redundant - alive
-- and zone both come free - and only clicky cooldowns still need broadcasting.
seenLast = {}
function owner_seen(nm)
    local t = ''
    pcall(function() t = tostring(mq.TLO.Spawn('pc =' .. nm).Type() or '') end)
    local seen, alive, dead, state
    if t:upper() ~= 'PC' then
        seen, alive, dead, state = false, false, false, ''
    else
        dead, state = false, ''
        pcall(function() dead = tlo_true(mq.TLO.Spawn('pc =' .. nm).Dead()) end)
        pcall(function() state = tostring(mq.TLO.Spawn('pc =' .. nm).State() or ''):upper() end)
        seen  = true
        alive = not (dead or state == 'DEAD' or state == 'HOVER')
    end
    local key = string.format('%s/%s/%s/%s', tostring(seen), tostring(alive), tostring(dead), state)
    if seenLast[nm] ~= key then
        seenLast[nm] = key
        rezlog('[state] %s: seen=%s alive=%s dead=%s state=%s', nm,
               seen and 'Y' or 'N', alive and 'Y' or 'N', dead and 'Y' or 'N',
               (state ~= '' and state or '-'))
    end
    return seen, alive
end

function owner_is_up(nm)
    local t = ''
    pcall(function() t = tostring(mq.TLO.Spawn('pc =' .. nm).Type() or '') end)
    if t:upper() ~= 'PC' then return false end
    -- A PC spawn is not the same as a LIVE PC. A freshly killed character's spawn lingers on our
    -- client for three or four seconds before it goes, and treating that as "owner is up" is what put
    -- a 3.4s pause in front of every rez. The spawn itself says whether it is alive - ask it, instead
    -- of waiting for it to disappear. HOVER is the dead-but-not-released state, DEAD the released one.
    local dead, state = false, ''
    pcall(function() dead = tlo_true(mq.TLO.Spawn('pc =' .. nm).Dead()) end)
    pcall(function() state = tostring(mq.TLO.Spawn('pc =' .. nm).State() or ''):upper() end)
    if dead or state == 'DEAD' or state == 'HOVER' then return false end
    return true
end


function peer_dist_to_corpse(peerName, corpseID)
    local cx, cy, cz, px, py, pz
    pcall(function()
        local c = mq.TLO.Spawn(corpseID)
        cx, cy, cz = tonumber(c.X()), tonumber(c.Y()), tonumber(c.Z())
    end)
    pcall(function()
        local sp = mq.TLO.Spawn('pc =' .. peerName)
        px, py, pz = tonumber(sp.X()), tonumber(sp.Y()), tonumber(sp.Z())
    end)
    if not (cx and cy and px and py) then return nil end
    local dx, dy, dz = cx - px, cy - py, (cz or 0) - (pz or 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function rez_corpse(name)
    local id, dist = 0, 99999
    local n = 0
    pcall(function() n = tonumber(mq.TLO.SpawnCount('pccorpse ' .. name)()) or 0 end)
    if n and n > 1 then
        -- BACK TO HIGHEST ID, deliberately. TimeBeenDead looked like the right answer - it is what
        -- the field is for - but in practice it is per-client and frequently garbage: one corpse read
        -- as 28652s / 29719s / 30263s / 30774s / 52410s simultaneously across five characters, and
        -- stale entries come back as tens of millions of seconds. Worse than being wrong, it made the
        -- rezzers DISAGREE: Sebbun picked corpse 1497 while Khulian and Lunafeet picked 350 at the
        -- same instant. Spawn ids are at least identical on every client, so the election stays
        -- coherent even when the pick is stale. Consistency beats a better guess that nobody shares.
        -- The stale-corpse problem is real and still open; it needs a signal all six can agree on.
        for i = 1, n do
            local sid, sd = 0, 99999
            pcall(function()
                local sp = mq.TLO.NearestSpawn(string.format('%d, pccorpse %s', i, name))
                sid = tonumber(sp.ID()) or 0
                sd  = tonumber(sp.Distance3D()) or tonumber(sp.Distance()) or 99999
            end)
            if sid > id then id, dist = sid, sd end
        end
        if id > 0 then
            -- Only when the COUNT changes. Throttled by time it landed on the keepalive tick and said
            -- the same thing every twenty seconds on all six toons, for a fact that only changes when
            -- somebody dies.
            if rezMultiWarn[name] ~= n then
                rezMultiWarn[name] = n
                -- log(), not rezdbg(): rezdbg is declared BELOW this function, so calling it here would
                -- resolve to a nil global. Throttled to once per 20s per name, so the console is safe.
                log('[rez] %s has %d corpses here - taking id %d (highest; ids are consistent across clients)', name, n, id)
            end
            return id, dist
        end
    end

    local forms = { name .. " corpse", "=" .. name .. "'s corpse", "pccorpse " .. name }
    for _, f in ipairs(forms) do
        pcall(function()
            local sp = mq.TLO.Spawn(f)
            local sid = tonumber(sp.ID()) or 0
            if sid > 0 then
                id = sid
                -- Distance3D, not Distance. Distance is HORIZONTAL only, so a corpse thirty units below
                -- you measures as nearer than it is - which decides the wrong way right on the boundary,
                -- and the boundary is exactly where the group tends to stand.
                local d
                pcall(function() d = tonumber(sp.Distance3D()) end)
                if not d then pcall(function() d = tonumber(sp.Distance()) end) end
                dist = d or 99999
            end
        end)
        if id > 0 then break end
    end
    return id, dist
end
local function rez_note(msg)
    table.insert(rezLog, 1, os.date('%H:%M:%S ') .. msg)
    while #rezLog > 5 do table.remove(rezLog) end
end

local function rezdbg(msg) if msg ~= rezDebugLast then rezDebugLast = msg; rezlog('[rez] ' .. msg) end; rezDebug = msg end

-- Take the rez ourselves. The corpse only clears when the box is ACCEPTED, so a rez nobody clicks
-- leaves the corpse up, the picker re-targets it, and a second clicky gets spent on the same person.
-- Only ever runs inside the 15s window opened by answering a handshake.
-- MQ bindings are inconsistent about booleans: true, 1 and "TRUE" all turn up depending on build and
-- TLO. Comparing to `true` alone silently reported every window shut even while one was on screen.
local function win_open(w)
    local v
    local ok = pcall(function() v = mq.TLO.Window(w).Open() end)
    if not ok or v == nil then return false, 'nil' end
    if v == true or v == 1 then return true, tostring(v) end
    local sv = tostring(v):upper()
    return (sv == 'TRUE' or sv == '1'), tostring(v)
end

-- Identify the box by its TEXT, not by probing for a button. Window(x).Child(y).ID is not a member in
-- this build, so the old existence check errored, `has` stayed false, and the box was never matched
-- even with the window plainly open. The wording is also a far better signal than a button name: it
-- confirms this is a resurrection offer rather than some other yes/no the game decided to ask.
--   "Nityrc wants to cast spiritual awakening (100 percent) upon you? Do you wish this?"
local REZ_WINDOW = 'ConfirmationDialogBox'
-- ANY of these marks the box as a resurrection, rather than ALL of one phrasing. The old test demanded
-- both 'wants to cast' AND 'upon you', which is exactly how the clicky box reads - "Nityrc wants to cast
-- Divine Resurrection (100 percent) upon you" - so clickies were accepted the instant they appeared.
-- Call of the Wild is a different spell and phrases it differently, so it failed the test, nobody clicked,
-- and the CotW rez sat waiting for a person. It looked like CotW was just slower to zone in; it was not
-- being auto-accepted at all.
-- Matching on the RESURRECTION WORDS is the durable version: a box offering to restore experience is a
-- rez whatever the caster's spell is called.
local REZ_TEXT   = { 'wants to cast', 'upon you', 'resurrect', 'restore', 'experience', 'call of the wild' }
local REZ_BUTTONS = { 'CD_Yes_Button', 'Yes_Button', 'CD_OK_Button' }
local function rez_autoaccept()
    local now = mq.gettime()
    local isRez, txt = false, ''
    if win_open(REZ_WINDOW) then
        pcall(function() txt = tostring(mq.TLO.Window(REZ_WINDOW).Child('CD_TextOutput').Text() or '') end)
        local low = txt:lower()
        -- ANY match, not all. See REZ_TEXT.
        for _, needle in ipairs(REZ_TEXT) do
            if low:find(needle, 1, true) then isRez = true; break end
        end
        -- Nothing matched, but a confirmation box IS open while we are dead with a rez inbound. Say what
        -- it says rather than ignoring it - if a third rez source words things a third way, this line is
        -- how we find out instead of wondering why one caster is slow.
        if not isRez and rezBoxAt == 0 and mq.gettime() < rezExpectUntil then
            rezlog('\\ay[rez] a dialog is open that I do not recognise as a rez: %s\\ax', txt:sub(1, 90))
        end
    end

    if not isRez then
        -- Alive with no corpse of my own? Then nothing is coming and the window should shut. Otherwise
        -- the warning kept repeating for the rest of its twenty seconds after the rez had landed.
        if now < rezExpectUntil then
            local iAmDead = true
            pcall(function() iAmDead = tlo_true(mq.TLO.Me.Dead()) end)
            if not iAmDead and rez_corpse(myName) == 0 then rezExpectUntil = 0 end
        end
        -- ...but not straight away. Being ready and the box existing are seconds apart by nature, and
        -- warning in that gap cries wolf on a perfectly normal rez.
        -- Only complain when a REZZER actually told us it was casting. Announcing our own readiness -
        -- which happens on any dead-to-alive transition, including a misread - also opens the accept
        -- window, and warning on that produced 'expecting a rez' on a toon that was alive and well and
        -- had nothing coming.
        if now < rezExpectUntil and (now - rezIncAt) < 20000
           and (now - rezExpectFrom) > 6000 and (now - rezNoBoxWarn) > 4000 then
            rezNoBoxWarn = now
            rezlog('\\ay[rez] expecting a rez but no resurrection box is open\\ax')
        end
        if rezBoxAt > 0 then
            rezlog('[rez] rez box gone after %dms%s', now - rezBoxAt,
                   rezBoxClicked and ' (we clicked it)' or ' (NOT clicked by us)')
            rezBoxAt, rezBoxClicked = 0, false
        end
        return
    end

    if rezBoxAt == 0 then
        rezBoxAt, rezBoxClicked = now, false
        rezlog('[rez] rez box OPEN: %s', txt:sub(1, 70))
        -- Announce the moment the box exists, whether or not WE click it. The previous version polled
        -- Window().Open() == true from the main loop - the same truthiness bug that hid the box from us
        -- for several builds - so in practice it never announced at all.
        rezDone[myName:lower()] = now + 15000
        pcall(function() peer_bcast('/at_rezdone %s', myName) end)
    end
    if rezBoxClicked or not rezAccept then return end

    -- ONE MORE GATE BEFORE CLICKING YES. Up to here the only thing standing between this and pressing
    -- the Yes button on an arbitrary ConfirmationDialogBox is the REZ_TEXT word list - and that list was
    -- widened on a guess to catch Call of the Wild, which words its box completely differently from the
    -- clickies ("is attempting to return you to your corpse", sharing not one phrase with "wants to cast
    -- ... upon you"). Widening it was right, and it fixed a real bug, but 'restore' and 'experience' are
    -- generic enough to appear in some other dialog nobody has thought of.
    -- So check the one thing that is true of every resurrection and nothing else: you cannot be rezzed
    -- unless you are dead, or alive at bind with your corpse still on the ground. Neither costs anything
    -- here because this only runs with a dialog already open, which is rare.
    -- This cannot reject a real rez: both states are covered, and a corpse that has expired cannot be
    -- rezzed anyway.
    local canBeRezzed = false
    pcall(function() canBeRezzed = tlo_true(mq.TLO.Me.Dead()) end)
    if not canBeRezzed then canBeRezzed = (rez_corpse(myName) > 0) end
    if not canBeRezzed then
        rezlog('\\ay[rez] a dialog looks like a rez but I am alive with no corpse - not clicking it: %s\\ax',
               txt:sub(1, 80))
        rezBoxClicked = true    -- do not re-evaluate it every tick
        return
    end

    -- Try each button name; the first that makes the window go away was the right one.
    for _, b in ipairs(REZ_BUTTONS) do
        -- /nomodkey, as E3 does. A held shift or ctrl changes what a click means to the EQ UI, and the
        -- one thing you do not want is a rez accept that quietly does something else because the user
        -- happened to be holding a key.
        pcall(function() mq.cmdf('/nomodkey /notify %s %s leftmouseup', REZ_WINDOW, b) end)
        mq.delay(60)
        if not win_open(REZ_WINDOW) then
            rezBoxClicked = true
            rezExpectUntil = 0
            rezlog('[rez] accepted with %s, %dms after the box opened', b, now - rezBoxAt)
            return
        end
    end
    rezlog('\\ay[rez] rez box is open but none of the buttons closed it: %s\\ax', table.concat(REZ_BUTTONS, ', '))
    rezBoxClicked = true   -- do not hammer it every tick
end

-- Tell the group I am up the INSTANT I release, instead of waiting for a rezzer to ask. The ping/pong
-- costs a round trip - the ask lands on one tick, the answer is read on the next - and every rezzer
-- pays it separately. I already know the moment I stand up, so one broadcast replaces all of them.
-- Cheaper as well as faster: one message per death instead of a ping and a pong per rezzer.
local function rez_announce_ready()
    local dead, zoning = false, false
    pcall(function() dead = tlo_true(mq.TLO.Me.Dead()) end)
    pcall(function() zoning = tlo_true(mq.TLO.Me.Zoning()) end)
    if zoning then return end
    if rezWasDead and not dead then          -- just got back up
        rezWasDead = false
        rezExpectFrom  = mq.gettime()
        rezExpectUntil = mq.gettime() + 15000
        -- Two '/at_rezrdy!' broadcasts used to go from here - one now, one 1.2s later against loss -
        -- to tell rezzers I had released, so they could skip the bind handshake. That handshake is now
        -- unreachable: a corpse is only targeted when its owner is not visibly alive, and that same
        -- condition already sets rezConfirm, so the ping path is never entered. Ten peer messages per
        -- rez for a listener with nothing left to do.
        -- The dead/alive tracking stays: it drives the "expecting a rez but no box is open" warning.
    elseif dead then
        rezWasDead = true
    end
end

local function rez_tick()
    if #rezPriority == 0 then load_rez_priority() end   -- workers have no UI to load it; load here so their picker runs
    if not rezAuto or #rezPriority == 0 then return end
    local now = mq.gettime()

    -- 0) If I'm mid-rez, finish THAT cast before starting another (one corpse at a time, retry on interrupt).
    if rezCast then
        local iDead = false; pcall(function() iDead = tlo_true(mq.TLO.Me.Dead()) end)
        if iDead then   -- died mid-rez: release my claim and skip the slot I was casting so the next slot takes over NOW
            rezPending[rezCast.id] = nil
            local ck = rezCast.kind or 'crown'   -- recorded at fire time; inferring it from the item name cannot see 'cotw'
            local key = myName:lower() .. ':' .. ck
            rezSkip[rezCast.id] = rezSkip[rezCast.id] or {}; rezSkip[rezCast.id][key] = now + 8000
            peer_bcast('/at_rezskip %s %d', key, rezCast.id)
            rezlog('[rez] died mid-cast; skip %s for %d', key, rezCast.id)
            rezCast = nil; return
        end
        local cid = rez_corpse(rezCast.name)                       -- SUCCESS = the corpse cleared (target accepted)
        if cid == 0 or cid ~= rezCast.id then rezCast = nil; return end
        local casting = false
        pcall(function() casting = (tonumber(mq.TLO.Me.Casting.ID()) or 0) > 0 end)
        if casting then
            if (now - (rezGateAt[rezCast.id] or 0)) > 900 then
                rezGateAt[rezCast.id] = now
                rezdbg(string.format('cast in flight on %s, still casting', rezCast.name))
            end
            return
        end
        -- PER KIND, because these are not the same cast. The crowns and tokens are 1s clickies, so 1.5s is
        -- a fair "it should have happened by now". Call of the Wild is a SPELL with a real cast time, and
        -- at 1.5s it was re-firing while the first cast was still resolving: on 2026-07-31 Sunetoo cast at
        -- 01:01:09.8, logged 'still casting' at .234, retried at 01:01:11.5, and Stylin did not stand up
        -- until 01:01:20.5 - about 5s slower than a clicky rez, and the wait was our own second cast.
        local gap = (rezCast.kind == 'cotw') and 6000 or 1500
        if (now - rezCast.at) < gap then return end
        -- One attempt when we were already beyond reach, three when we were not. A cast that failed on
        -- range will fail again from the same spot, so grinding out three of them just holds the baton.
        local maxTries = rezCast.far and 1 or 3
        if rez_kind_secs(rezCast.kind) == 0 and rezCast.tries < maxTries then   -- clicky still ready => it did not go off
            rezCast.tries = rezCast.tries + 1; rezCast.at = now
            rezlog('[rez] retry %d /nowcast me "%s" %d', rezCast.tries, rezCast.item, rezCast.id)
            pcall(function() mq.cmdf('/nowcast me "%s" %d', rezCast.item, rezCast.id) end)
            return
        end
        if rez_kind_secs(rezCast.kind) == 0 then
            -- Tries exhausted with the clicky untouched: it never went off. PASS THE BATON rather than
            -- looping on it - somebody closer should get the chance.
            local ck = rezCast.kind or 'crown'
            local key = myName:lower() .. ':' .. ck
            rezSkip[rezCast.id] = rezSkip[rezCast.id] or {}
            rezSkip[rezCast.id][key] = now + 5000
            peer_bcast('/at_rezskip %s %d %d', key, rezCast.id, 5000)
            rezlog('[rez] %s did not land on %s - passing to the next slot', rezCast.item, rezCast.name)
        end
        rezCast = nil   -- done; if the corpse is still there the picker re-handshakes and tries again
        return
    end

    -- 1) TARGET: highest-priority toon with a CORPSE in my zone, owner still connected, reachable.
    --    Uses corpse EXISTENCE, not the Dead flag - a released toon is 'alive' at bind but still has a corpse.
    -- Every corpse we decline records WHY. Four quite different situations used to collapse into two
    -- messages: a corpse 18 units away that another rezzer had already claimed reported as 'no
    -- reachable corpse', which reads as a range problem and sent me looking in the wrong place.
    local tgtName, tgtID, skipped, tgtFar, tgtDist = nil, nil, {}, false, -1
    -- NOTHING TO SWEEP IF THE ZONE HAS NO CORPSES. rez_event_now() is one cached SpawnCount over ALL pc
    -- corpses, refreshed at most once a second; the loop below calls rez_corpse() per priority slot, and
    -- each of THOSE is its own SpawnCount plus a NearestSpawn walk. Twelve slots, every tick, to discover
    -- what a single cached read already knew.
    -- The implication only runs one way and that is the safe way: if there is not one pc corpse in the
    -- zone then no individual member can have one, so skipping is exact rather than approximate. It also
    -- returns true whenever I am dead, so nothing about my own corpse is affected.
    -- Same reasoning the raid sweep already uses one screen down; it just never got applied to the group.
    if not rez_event_now() then return end
    local myZone0 = 0; pcall(function() myZone0 = tonumber(mq.TLO.Zone.ID()) or 0 end)
    for _, nm in ipairs(rezPriority) do
        local id, dist = rez_corpse(nm)
        if id > 0 then
            local rr = rezReady[nm]
            -- ONE QUESTION: is this person alive? Everything else follows from it.
            -- Alive means we can see them and the spawn is not dead or hovering. Nothing else counts -
            -- not a report, not how old the corpse is, not how long ago they were last heard from.
            -- If they are alive, there is nothing to do. If they are not and their corpse is in range,
            -- rez it. The elaborate versions of this - stale-report fallbacks, corpse-age windows -
            -- were each added to cover a case that does not really occur for a grouped character, and
            -- every one of them cost seconds on a real death.
            local seen, alive = owner_seen(nm)
            local ownerHereAlive = (seen and alive) or false
            local rezPend = rezDone[nm:lower()] and now < rezDone[nm:lower()]   -- owner already has a rez inbound
            if rezCorpseDone[id] then
                rezPend = true
                skipped[#skipped + 1] = nm .. ': already rezzed (corpse ' .. id .. ' retired)'
            end
            local claimed = rezPending[id] and now < rezPending[id]             -- another rezzer called it
            if ownerHereAlive then
                skipped[#skipped + 1] = nm .. ': owner is already up'
            elseif rezPend then
                skipped[#skipped + 1] = nm .. ': rez already inbound'
            elseif claimed then
                skipped[#skipped + 1] = string.format('%s: claimed by another rezzer (%dm away)', nm, math.floor(dist))
            elseif dist > REZ_MAX_DIST then
                -- Beyond arguing with. Inside REZ_TRY_MAX we attempt regardless of the reach figure,
                -- because the reading is a snapshot - the corpse may be summoned in, we may be walking
                -- up, and a cast that cannot reach just does not consume the clicky. Past it, the corpse
                -- is somewhere else entirely and trying only holds the baton.
                skipped[#skipped + 1] = string.format('%s: too far, %dm (limit %d)', nm, math.floor(dist), REZ_MAX_DIST)
            else
                tgtName, tgtID, tgtFar, tgtDist = nm, id, (dist > rez_range()), math.floor(dist)
                break
            end
        end
    end

    -- RAID, only once the group is clear. Tokens only, 100 units, and one per rezzer per gap.
    -- THROTTLED to once a second. This pass runs rez_corpse() for every raid member, and each of those
    -- is a SpawnCount plus a NearestSpawn walk - so in a thirty-person raid it was thirty-odd spawn
    -- searches every 250ms tick. That is what pushed a loop iteration past half a second and left an
    -- 869ms gap between "ready to fire" and FIRING, on a tick supposedly running at 250ms.
    -- Scanning faster buys nothing anyway: a raid rez is rate-limited to one per RAID_TOKEN_GAP.
    local tgtRaid = false
    -- Either clicky counts for the classes allowed to use a crown on a raid target; everyone else
    -- still needs a ready token before the pass is even worth running.
    local raidClickyReady = (my_rez_secs(TOKEN_ITEM) == 0)
                            or (raid_crown_ok() and my_rez_secs(CROWN_ITEM) == 0)
                            -- a shaman with both clickies spent but CotW up is still worth the sweep
                            or (rezCotw and my_cotw_secs() == 0)
    -- The TANK sits out raid rezzes entirely - not "scans then declines", does not look at all. Its
    -- job is to hold aggro, and this sweep is the expensive part of the tick: one rez_corpse() per
    -- raid member, every second. Skipping the pass saves the tank that work and stops it evaluating
    -- corpses it was never going to touch. (177 of 420 lines in one tank log were exactly that.)
    local iAmTank = (rez_rank(member_class(myName)) == 1)
    if RAID_REZ and not iAmTank and not tgtID and raidClickyReady
       and (now - lastRaidScan) > 1000
       and (now - lastRaidToken) > RAID_TOKEN_GAP then
        lastRaidScan = now
        for _, nm in ipairs(raid_outsiders()) do
            local id, dist = rez_corpse(nm)
            if id > 0 and dist <= RAID_MAX_DIST then
                -- They are not running AdventureTime, so nothing announces on their behalf: no
                -- /at_rezdone, no corpse retirement. owner_is_up() catches them once they stand up, and
                -- this offer gap covers the gap before that - cast, accept, zone back.
                local offered = raidOffered[id] and (now - raidOffered[id]) < RAID_OFFER_GAP
                if not offered and not owner_is_up(nm)
                   and not (rezPending[id] and now < rezPending[id]) and not rezCorpseDone[id] then
                    tgtName, tgtID, tgtFar, tgtDist, tgtRaid = nm, id, false, math.floor(dist), true
                    break
                end
            end
        end
    end
    if not tgtID then
        -- No out-of-range skip any more. It existed so the timeout baton could tell "cannot act" from
        -- "has not acted yet" - the election works that out locally now, so the broadcast tells nobody
        -- anything they cannot already see. Worse, it was refreshed every tick while far away, so the
        -- first toon to walk into range then had to sit out its OWN three-second skip before acting:
        -- four toons all logged "I passed on this one" the instant they arrived.
        if #skipped == 0 then rezdbg('no corpses in zone')
        else rezdbg('nothing to rez | ' .. table.concat(skipped, ' | ')) end
        return
    end

    -- 2) REZZER = SLOT baton over rezOrder (name + clicky). I act when one of MY slots is the first not-out slot.
    --    A slot is 'out' if its owner skipped it, is dead/stale, or doesn't own that clicky. Default = wait (assume handled).
    local myZone = 0; pcall(function() myZone = tonumber(mq.TLO.Zone.ID()) or 0 end)
    -- CotW holders pinned ahead of the saved order. Built ONCE per pass and reused below, because the
    -- election compares positions within it - rebuilding mid-pass could shift indices under us.
    local chain = rez_chain()
    if not rezFirstSeen[tgtID] then rezFirstSeen[tgtID] = now end
    local iAmDead = false; pcall(function() iAmDead = tlo_true(mq.TLO.Me.Dead()) end)

    -- my earliest slot whose clicky I can actually use right now (local, authoritative)
    local myPos, myClicky
    if not iAmDead then
        for pos, sl in ipairs(chain) do
            if sl.name:lower() == myName:lower() and sl.name:lower() ~= tgtName:lower() then
                if rez_kind_secs(sl.clicky) == 0 then myPos, myClicky = pos, sl.clicky; break end
            end
        end
    end

    if iAmDead or not myPos then   -- no usable slot: skip ALL my slots so the baton advances past me, release any claim
        for _, sl in ipairs(chain) do
            if sl.name:lower() == myName:lower() then
                local key = myName:lower() .. ':' .. sl.clicky
                rezSkip[tgtID] = rezSkip[tgtID] or {}; rezSkip[tgtID][key] = now + 3000
                peer_bcast('/at_rezskip %s %d %d', key, tgtID, 3000)   -- re-sent each tick while true
            end
        end
        rezdbg(string.format('target %s(%d): I (%s) have no clicky; baton passes me', tgtName, tgtID, myName))
        return
    end

    -- THE TANK HOLDS while anybody else could do it. The tank is the one who walks out to fetch a body,
    -- so it is routinely the only character in range of a corpse the group is nowhere near - and the
    -- baton, seeing everyone else skip on distance, hands it the cast. Dragging it back is the point;
    -- rezzing it where it lies defeats that.
    -- IN MY ZONE, not "alive": death auto-zones to bind here, so a corpse reports alive=1 and a dead
    -- healer with a ready crown would look like a perfectly good rezzer. The zone is what separates
    -- someone still in the fight from someone standing at their bind point waiting for this very rez.
    -- ...and only for MY GROUP. A raid stranger is not the tank's problem: the hold rule exists so the
    -- tank keeps tanking while a groupmate handles the rez, but applied to every corpse in the zone it
    -- just makes the tank evaluate hundreds of strangers in order to decline each one. That was 350+
    -- lines of "I am the tank ... holding" in one twenty-minute run, one per corpse per second.
    if tgtRaid and rez_rank(member_class(myName)) == 1 then
        return
    end
    if rez_rank(member_class(myName)) == 1 then
        local other
        for _, nm in ipairs(group_members()) do
            if nm:lower() ~= myName:lower() and nm:lower() ~= tgtName:lower() then
                local rr = rezReady[nm]
                -- CotW BELONGS IN THIS LIST. Without it, a shaman whose crown and token were both spent
                -- read as "nobody else is up" and the tank fired a crown while the shaman's free,
                -- renewable rez sat there ready - the exact waste this whole feature exists to stop.
                if rr and (rr.zone or 0) == myZone and rr.zone > 0
                   and ((rez_peer_secs(rr, 'token') == 0) or (rez_peer_secs(rr, 'crown') == 0)
                        or (rezCotw and rez_peer_secs(rr, 'cotw') == 0)) then
                    other = nm; break
                end
            end
        end
        if other then
            rezdbg(string.format('target %s(%d): I am the tank and %s is up in-zone with a clicky - holding',
                                 tgtName, tgtID, other))
            return
        end
    end

    -- Respect my OWN skip. Passing the baton then immediately re-taking it is not passing: Lunafeet
    -- fired, gave up, and fired again one second later, burning a second charge from the same spot the
    -- first one failed at. If I have skipped this corpse for this clicky, I am out until it lapses.
    do
        local mine = rezSkip[tgtID] and rezSkip[tgtID][myName:lower() .. ':' .. myClicky]
        if mine and now < mine then
            rezdbg(string.format('target %s(%d): I passed on this one, waiting %dms', tgtName, tgtID, mine - now))
            return
        end
    end

    -- LOCAL ELECTION. Every slot ahead of me is judged on facts I can establish here and now, so there
    -- is nothing to wait for and no timeout. A slot ahead is OUT if:
    --     it cannot reach the corpse   - computed from spawn positions, no network
    --     its clicky is not ready      - pushed on change, counted down locally
    --     it is dead or its script is  - the beat tells us, and death is visible anyway
    --     it explicitly stood down     - the skip broadcasts, still honoured
    -- Only a slot that is genuinely able makes me wait, and then I am right to. The old version could
    -- not see distance, so "hasn't acted" and "can't act" were the same thing and it had to guess with
    -- a per-slot timeout - which is where the multi-second stalls came from.
    local cleared, blocker = true, nil
    for pos = 1, myPos - 1 do
        local sl = chain[pos]
        local owner, clicky = sl.name, sl.clicky
        if owner:lower() ~= tgtName:lower() and owner:lower() ~= myName:lower() then
            local key = owner:lower() .. ':' .. clicky
            local sk = rezSkip[tgtID] and rezSkip[tgtID][key]
            local skipped = sk and now < sk
            local rr = rezReady[owner]
            -- NO REPORT MEANS DO NOT WAIT ON THEM. Both of these used to read `rr and ...`, so when rr was
            -- nil - peer's script not running, worker restarted, entry dropped by a resync - each evaluated
            -- to nil, nothing marked the slot skippable, and the slot blocked the whole chain. "We have
            -- never heard from them" was being treated as "they are ready and about to fire".
            -- Seen on Levaquin 2026-07-30: stuck at slot9 with a ready crown for two minutes behind slot6
            -- Lovenox, whose worker had been silent 88s and whose rezReady entry had been dropped, while its
            -- spawn sat 23m from the corpse so the distance check passed it through.
            local noReport  = (rr == nil)
            local deadStale = noReport or (rr.alive == false) or (now - (rr.updated or 0)) >= 30000
            local notReady  = noReport or (rez_peer_secs(rr, clicky) ~= 0)
            -- the new one: can they even reach it?
            local pd = peer_dist_to_corpse(owner, tgtID)
            local tooFar = (pd == nil) or (pd > REZ_MAX_DIST)
            if not (skipped or deadStale or notReady or tooFar) then
                cleared = false
                blocker = string.format('slot%d %s(%s) @%s', pos, owner, clicky,
                                        pd and string.format('%dm', math.floor(pd)) or '?')
                break
            end
        end
    end
    if not cleared then
        -- BACKSTOP, GATED ON THE CLAIM. The baton advances when a blocker either claims the corpse or
        -- broadcasts a skip - and a peer whose script has died can do NEITHER, so the chain waits on it for
        -- ever. Seen on Levaquin 2026-07-30: two minutes at slot9 holding a ready crown behind slot6
        -- Lovenox, whose worker had been silent 88 seconds, while Levora stayed dead.
        -- The old positional timeout ((myPos-1) * 2s) was removed for good reason - it fired INTO the
        -- handshake window and produced dogpiles. What makes a timeout safe now is the claim: a blocker
        -- that actually committed has already broadcast one, and rezPending makes everyone else drop the
        -- corpse before they ever reach this branch. So reaching here with NO claim outstanding means
        -- nobody has committed, and going ahead cannot collide with anyone.
        local claimed = rezPending[tgtID] and now < rezPending[tgtID]
        local waited  = now - (rezFirstSeen[tgtID] or now)
        if claimed or waited < REZ_BATON_MAX then
            rezdbg(string.format('target %s(%d): waiting my turn [me:%s %s slot%d] behind %s%s',
                                 tgtName, tgtID, myName, myClicky, myPos, blocker,
                                 claimed and ' (claimed)' or string.format(' (%.0fs of %.0fs)',
                                 waited / 1000, REZ_BATON_MAX / 1000)))
            return
        end
        rezlog('\\ay[rez] %s(%d): %s has held the baton %.0fs without claiming or skipping - taking it\\ax',
               tgtName, tgtID, blocker, waited / 1000)
    end
    -- A raid corpse is a token, full stop - never a crown, because the crown's debuff is not ours to
    -- put on someone else's character. If my elected slot is a crown slot, I am not the one for this.
    -- 'crown', not 'not token': CotW is an AA with no debuff and no consumable behind it, so it is the
    -- BEST thing to put on a stranger, not something to gate. Only the crown stays restricted.
    if tgtRaid and myClicky == 'crown' and not raid_crown_ok() then
        rezdbg(string.format('target %s(%d): raid corpse and my slot is a crown - tokens only for %s',
                             tgtName, tgtID, myClass))
        return
    end
    local item = (myClicky == 'cotw') and COTW_AA or ((myClicky == 'token') and TOKEN_ITEM or CROWN_ITEM)
    local pick = { name = myName, token = (myClicky == 'token'), kind = myClicky }
    rezdbg(string.format('target %s(%d) <- ME %s(%s) slot%d @%dm%s', tgtName, tgtID, myName, myClicky,
                         myPos, tgtDist, tgtFar and ' (beyond reach - one attempt)' or ''))
    -- CLAIM ONCE, not every tick. Re-broadcasting kept renewing a claim I could not act on: slot 12
    -- claimed while it was the only one in range, then sat on the handshake for eight seconds while
    -- slot 1 walked to 9m and got told 'claimed by another rezzer' every single tick.
    if not (rezClaimAt[tgtID] and (now - rezClaimAt[tgtID]) < 2500) then
        rezClaimAt[tgtID] = now
        peer_bcast('/at_rezclaim %d %d', tgtID, 5000)   -- pre-cast: short, I may yet hand it back
    end

    -- HANDSHAKE: don't cast until the target has zoned to its bind and settled (a too-early rez is wasted).
    -- Ping the target; it pongs only when at bind (valid zone, different from mine, not zoning). No pong -> keep waiting.
    local tkey = tgtName:lower()
    -- The rez HEARTBEAT already answers this. Every toon broadcasts alive + zone every few seconds, so
    -- a target that is alive, in a different zone from me, and reported recently is up at bind - which
    -- is exactly what the handshake asks. Using it skips the round trip entirely and fires on the next
    -- tick instead of the one after. The ping/pong stays for anyone whose heartbeat we have not got.
    local trr = rezReady[tgtName]
    local upFromBeat = trr and trr.alive and (trr.zone or 0) > 0 and trr.zone ~= myZone
                       and (now - (trr.updated or 0)) < 30000
    if upFromBeat then rezConfirm[tkey] = now end

    -- 5s, not 2.5s. A readiness announced on release has to still count when a rezzer picks the target
    -- a few seconds later, or the push is wasted and everyone falls back to asking.
    -- A RAID target cannot answer this. It is not running AdventureTime, so the ping goes nowhere: we
    -- wait 1.5s, release, re-take, wait again - forever. That is what filled the log with Algophobia
    -- and Nyctophobia and meant the raid rez never actually fired. There is nobody to shake hands
    -- with, so skip straight to casting and let the game reject it if they are not really down.
    if tgtRaid then rezConfirm[tkey] = now end
    -- And skip it for anyone we can SEE is dead. The handshake asks the target "are you ready for a
    -- rez?" - but a dead character's script cannot answer while it is dying and zoning, which is
    -- precisely when we ask. So the ping goes unanswered, we wait, release, and someone outside the
    -- group rezzes our tank while we are still being polite about it. That is what happened to
    -- Sebbun: six seconds of handshakes from two rezzers, then Levora landed it.
    -- owner_seen() already told us locally, a second earlier, that they were not up. Believe it.
    do
        local tseen, talive = owner_seen(tgtName)
        if not (tseen and talive) then rezConfirm[tkey] = now end
    end
    if not (rezConfirm[tkey] and (now - rezConfirm[tkey]) < 5000) then
        if (now - (rezPingAt[tkey] or 0)) > 250 then   -- match the fast tick; a lost ping cost 700ms
            rezPingAt[tkey] = now
            peer_cmdf(tgtName, '/at_rezrdy? %s %d', myName, myZone)
        end
        -- Say so if this is going nowhere. Waiting silently is indistinguishable from a bug, and both
        -- real causes - target not running AdventureTime, target has not released - need a human.
        rezWaitFrom[tkey] = rezWaitFrom[tkey] or now
        -- LET GO after 1500ms, not 3000. Two things make the shorter wait safe. The target ANNOUNCES
        -- when it comes up - rez_announce_ready broadcasts on the dead-to-alive edge - so this poll is
        -- only the fallback for a missed announcement, not the normal path. And releasing the claim is
        -- far cheaper than when 3000 was chosen: back then it also benched us for two seconds, where
        -- now it is 750ms. Nothing can happen while the target is mid-zone anyway, so waiting longer
        -- buys nothing; the moment it lands, whoever is nearest takes it.
        -- Watch for: 'no confirmation' appearing more often, or the baton bouncing between slots. That
        -- would mean 1500 is under the real zone time and it should go back up.
        if (now - rezWaitFrom[tkey]) > 1500 then
            rezWaitFrom[tkey] = nil
            rezPending[tgtID] = nil
            rezClaimAt[tgtID] = nil
            rezFireAt[tgtID]  = nil   -- fresh jitter on the retry; the old one is spent
            -- 750ms, not 2000. Releasing the CLAIM is the point - it lets anyone better placed step in.
            -- Standing myself down for two seconds on top is pure cost when nobody better exists, which
            -- is the common case: the target is simply still zoning and comes up a moment later, with
            -- me having just benched myself.
            local key = myName:lower() .. ':' .. myClicky
            rezSkip[tgtID] = rezSkip[tgtID] or {}
            rezSkip[tgtID][key] = now + 750
            peer_bcast('/at_rezskip %s %d %d', key, tgtID, 750)
            rezdbg(string.format('target %s(%d): no confirmation in 1.5s, releasing my claim', tgtName, tgtID))
            return
        end
        if (now - rezWaitFrom[tkey]) > 15000 and (now - (rezWaitWarn[tkey] or 0)) > 30000 then
            rezWaitWarn[tkey] = now
            rezlog('\\ay[rez] %s has not confirmed in %ds - is it running AdventureTime, and has it released?\\ax',
                   tgtName, math.floor((now - rezWaitFrom[tkey]) / 1000))
        end
        rezdbg(string.format('target %s(%d): waiting for bind handshake [me:%s]', tgtName, tgtID, myName))
        return
    end

    -- Past the handshake and still not casting? SAY WHICH GATE. These three returned silently, so a
    -- two-second hole between 'target <- ME' and 'FIRING' was indistinguishable from the script simply
    -- not running - and there is no way to tell tuning from a bug without knowing which one held it.
    local function blocked(why)
        if (now - (rezGateAt[tgtID] or 0)) > 900 then
            rezGateAt[tgtID] = now
            rezdbg(string.format('target %s(%d): ready to fire but %s', tgtName, tgtID, why))
        end
    end
    -- anti-race jitter: stagger toons by a small random delay so two don't fire in the same tick.
    -- 40ms, down from 150. At a 250ms tick almost any jitter costs a whole extra tick, and the logs
    -- showed 145ms doing exactly that. It is worth far less than it was: the election is deterministic
    -- now and peers independently computed the same distance to the same corpse, so there is no tie to
    -- break - and the claim is the real protection against two casts, not this.
    if not rezFireAt[tgtID] then rezFireAt[tgtID] = now + math.random(0, 40) end
    if now < rezFireAt[tgtID] then
        blocked(string.format('jitter, %dms left', rezFireAt[tgtID] - now)); return
    end
    if rezPending[tgtID] and now < rezPending[tgtID] then
        blocked(string.format('someone else holds a claim, %dms left', rezPending[tgtID] - now)); return
    end
    if (now - lastRezFire) < 500 then
        blocked(string.format('I fired %dms ago (500ms spacing)', now - lastRezFire)); return
    end
    -- Tell the TARGET a rez is on its way. Everything else that armed its accept-window is unreliable
    -- on this server: the handshake ping is now skipped when the heartbeat already answers, and the
    -- dead->alive transition never gets sampled because death IS a zone - the character is mid-zoning
    -- when it would have been seen as dead, and alive again by the time zoning ends. The rezzer knows
    -- for certain, so it says so.
    if tgtRaid then
        raidOffered[tgtID] = now
        lastRaidToken = now
        -- Tell any other AdventureTime user in earshot, so they do not spend a token on the same body.
        pcall(function() mq.cmdf('/say ATREZ %d %s', tgtID, tgtName) end)
        rezlog('[rez] RAID token on %s @%dm (not in my group)', tgtName, tgtDist)
    end
    pcall(function() peer_cmdf(tgtName, '/at_rezinc %s', myName) end)
    rezlog('[rez] FIRING /nowcast me "%s" %d (target %s @%dm, reach %d)', item, tgtID, tgtName, tgtDist, rez_range())
    pcall(function() mq.cmdf('/nowcast me "%s" %d', item, tgtID) end)
    pcall(function() mq.cmdf('/gsay %s %s on %s', (myClicky == 'cotw') and 'Cast' or 'Clicked', item, tgtName) end)   -- announce the rez in group chat
    lastRezFire = now
    -- kind is carried so the retry and died-mid-cast paths know which timer proves the cast went off
    rezCast = { id = tgtID, item = item, kind = myClicky, at = now, tries = 1, name = tgtName, far = tgtFar }
    -- 15s, not 4s. The claim has to outlive the CAST, and the box can take eight seconds to appear when
    -- the target is still zoning - which is exactly when someone dies. At 4s the claim lapsed mid-flight
    -- and a second rezzer took the same corpse. A cast that genuinely fails releases this early via the
    -- skip path, so the longer hold costs nothing when it is not needed.
    rezPending[tgtID] = now + 15000
    peer_bcast('/at_rezclaim %d %d', tgtID, 15000)   -- CAST IS OUT: hold it for the whole flight
    rezlog('[rez] claim SENT on corpse %d for 15000ms (cast is out)', tgtID)
    local msg = string.format('%s -> %s -> %s', myName, pick.kind or 'crown', tgtName)
    if SHOW_UI then rez_note(msg) elseif driverName then peer_cmdf(driverName, '/at_rezlog %s', msg) end
end



-- Liveness: the driver pings, a running instance pongs back. Used to auto-start the tool on any group
-- member that isn't running it, instead of assuming the user launched it everywhere.
local running = true   -- forward-declared here so the /at_close bind below sets THIS (not a global)
local alive = {}
pcall(function()
    mq.bind('/at_ping', function(driver) if driver then driverName = driver; peer_cmdf(driver, '/at_pong %s', myName) end end)
    mq.bind('/at_expecttrade', function(ms)
        expectTradeUntil = mq.gettime() + (tonumber(ms) or 60000)
    end)
    mq.bind('/at_close', function() mq.cmd('/e3p off'); running = false end)   -- broadcast close: resume E3, then exit
    mq.bind('/at_e3', function(mode) mq.cmd('/e3p ' .. (mode == 'on' and 'on' or 'off')) end)   -- pause/resume E3
    mq.bind('/at_xtank', function() set_tank_xtargets(false) end)   -- healer: set raid tanks on my XTargets
    -- Pin / unpin a non-tank. Takes effect on the next pass; the list is saved immediately so it is
    -- still there after a restart. /at_xtpin with no name lists what is pinned.
    mq.bind('/at_xtpin', function(...)
        local nm = table.concat({ ... }, ' '):match('^%s*(.-)%s*$')
        if nm == '' then
            log('[xtank] pinned: %s', (#xtankPinned > 0) and table.concat(xtankPinned, ', ') or '(none)')
            return
        end
        for _, e in ipairs(xtankPinned) do
            if e:lower() == nm:lower() then log('[xtank] %s is already pinned.', e); return end
        end
        xtankPinned[#xtankPinned + 1] = nm
        save_settings()
        log('[xtank] pinned %s (%d total). Applies on the next pass.', nm, #xtankPinned)
        lastXTankKey = nil   -- force the next pass to rebuild rather than see "no change"
    end)
    mq.bind('/at_xtunpin', function(...)
        local nm = table.concat({ ... }, ' '):match('^%s*(.-)%s*$')
        for i, e in ipairs(xtankPinned) do
            if e:lower() == nm:lower() then
                table.remove(xtankPinned, i)
                save_settings()
                log('[xtank] unpinned %s (%d left).', e, #xtankPinned)
                lastXTankKey = nil
                return
            end
        end
        log('[xtank] %s was not pinned.', nm ~= '' and nm or '(no name given)')
    end)
    mq.bind('/at_rezlog', function(...) rez_note(table.concat({...}, ' ')) end)   -- a rezzer reports its cast
    mq.bind('/at_rezaccept', function(v) rezAccept = (v == 'on') end)
    mq.bind('/at_rezauto', function(mode) rezAuto = (mode == 'on'); rezlog('[rez] auto-rez %s', mode or '?') end)
    -- Must reach every toon, not just the driver: each one builds the chain locally, so a toon left on
    -- the old value would compute a different order and elect against everyone else.
    mq.bind('/at_rezcotw', function(mode) rezCotw = (mode == 'on'); rezlog('[rez] CotW priority %s', mode or '?') end)
    -- The announce toggle has to REACH THE HEALERS. The checkbox lives on the driver, but the /rsay
    -- fires on whoever is maintaining the XTargets - a worker. Workers read the settings file once at
    -- startup and never again, so unchecking it on the driver changed the file and the driver's own
    -- copy while the two characters actually announcing carried on with whatever they loaded.
    -- Same shape as /at_rezauto: the driver says so, everyone sets their own flag.
    mq.bind('/at_xtsay', function(mode)
        xtankAnnounce = (mode == 'on')
        rezlog('[xtank] raid announce %s (from the driver)', mode or '?')
    end)
    mq.bind('/at_coth', function(name, em, dist, los)
        if name then COTH.state[name] = { emblem = tonumber(em) or -1, dist = tonumber(dist) or -1,
                                          los = tonumber(los) or 0, updated = mq.gettime() } end
    end)
    mq.bind('/at_cothclaim', function(name) if name then COTH.claims[name] = mq.gettime() + 25000 end end)
    mq.bind('/at_cothfail', function(name) if name then COTH.claims[name] = nil end end)
    -- User-facing: /atcoth [on|off|stop]. No arg = start. Registered on every toon, so the gather can
    -- be kicked off from whichever one you happen to be looking at rather than only from the driver.
    mq.bind('/atsync', function() resync_group() end)
    mq.bind('/atcoth', function(mode)
        local m = tostring(mode or ''):lower()
        if m == 'off' or m == 'stop' then coth_set(false) else coth_set(true) end
    end)
    mq.bind('/at_cothgo', function(mode, anchor)
        COTH.active = (mode == 'on')
        COTH.claims = {}; COTH.pending = nil; COTH.startedAt = mq.gettime()
        COTH.anchor = COTH.active and (anchor ~= '' and anchor or nil) or nil
        COTH.state  = {}   -- old distances were measured against a different anchor
    end)
    mq.bind('/at_di', function(name, staff, em, dg, save, sname)
        if name then
            local nm = (sname and sname ~= '' and sname ~= '-') and sname:gsub('_', ' ') or nil
            DI.state[name] = { staff = tonumber(staff) or -1, emeralds = tonumber(em) or 0,
                               dgReady = tonumber(dg) or 0, saveUp = tonumber(save) or 0,
                               saveName = nm, updated = mq.gettime() }
        end
    end)
    mq.bind('/at_arcane', function() arc_click() end)
    mq.bind('/at_corpseprobe', function() corpse_probe() end)
    mq.bind('/at_burnpoll', function(mode)
        burnPollOn = (mode ~= 'off')
        log('burn poll is %s here', burnPollOn and 'ON' or 'OFF (crash test - dashboard will not update)')
    end)
    mq.bind('/atburnpoll', function(mode)
        local on = (mode ~= 'off')
        for _, nm in ipairs(group_members()) do
            if nm:lower() ~= myName:lower() then pcall(function() peer_cmdf(nm, '/at_burnpoll %s', on and 'on' or 'off') end) end
        end
        burnPollOn = on
        log('burn poll %s for the whole group', on and 'enabled' or 'DISABLED')
    end)
    -- The queue is mirrored on every toon so the driver can draw it and the holder can work it.
    mq.bind('/at_pwadd', function(id, nm)
        id = tonumber(id); if not id or pw_find(id) then return end
        pwQueue[#pwQueue + 1] = { id = id, name = (nm or '?'):gsub('_', ' '), oor = false }
    end)
    mq.bind('/at_pwdel', function(id)
        local i = pw_find(tonumber(id) or 0); if i then table.remove(pwQueue, i) end
    end)
    mq.bind('/at_pwclear', function() pwQueue = {} end)
    mq.bind('/at_pwmark', function(id, st)
        local _, e = pw_find(tonumber(id) or 0)
        if e then e.state, e.oor = st, false end
    end)
    mq.bind('/at_pwoor', function(id, v)
        local _, e = pw_find(tonumber(id) or 0); if e then e.oor = (v == '1') end
    end)
    -- Carries the disc NAME, not just a flag: the driver's button is labelled with whatever the holder
    -- will really cast, and only the holder knows which one that is.
    mq.bind('/at_pwhave', function(who, disc)
        if who and who ~= '' then pwState[who] = (disc and disc ~= '') and disc:gsub('_', ' ') or true end
    end)
    mq.bind('/at_arcstate', function(char, have, secs, up)
        if char then
            arcState[char] = { have = tonumber(have) or 0, secs = tonumber(secs) or -1,
                               up = tonumber(up) or 0, updated = mq.gettime() }
        end
    end)
    mq.bind('/at_potstate', function(char, key, carries, up, secs, dsecs)
        if not char or not key then return end
        potState[char] = potState[char] or {}
        potState[char][key] = { carries = tonumber(carries) or 0, up = tonumber(up) or 0,
                                secs = tonumber(secs) or -1, dsecs = tonumber(dsecs) or 0,
                                updated = mq.gettime() }
    end)
    mq.bind('/at_potprobe', function()   -- diagnostic: what does each draught tier ACTUALLY resolve to?
        for _, gp in ipairs(GROUP_POTS) do
            for _, tier in ipairs({ 'II', 'I' }) do
                local nm = gp.base .. ' ' .. tier
                local id, cnt, rdy, spell = 0, 0, -1, ''
                pcall(function() id = tonumber(mq.TLO.FindItem('=' .. nm).ID()) or 0 end)
                if id > 0 then
                    pcall(function() cnt = tonumber(mq.TLO.FindItemCount('=' .. nm)()) or 0 end)
                    pcall(function() rdy = tonumber(mq.TLO.FindItem('=' .. nm).TimerReady()) or -1 end)
                    pcall(function() spell = tostring(mq.TLO.FindItem('=' .. nm).Spell.Name() or '') end)
                end
                local bufSpell, bufItem = -1, -1
                if spell ~= '' and spell ~= 'NULL' then
                    pcall(function() bufSpell = tonumber(mq.TLO.Me.Buff(spell).Duration.TotalSeconds()) or -1 end)
                end
                pcall(function() bufItem = tonumber(mq.TLO.Me.Buff(nm).Duration.TotalSeconds()) or -1 end)
                log('[potprobe] %s | id=%d cnt=%d timer=%d | Spell.Name="%s" | Buff[spell]=%d Buff[item]=%d',
                    nm, id, cnt, rdy, spell, bufSpell, bufItem)
            end
        end
        -- and every buff currently on me, so we can eyeball what the draught ACTUALLY landed
        local names = {}
        for i = 1, 60 do
            local b = ''
            pcall(function() b = tostring(mq.TLO.Me.Buff(i).Name() or '') end)
            if b ~= '' and b ~= 'NULL' then names[#names + 1] = b end
        end
        log('[potprobe] my buffs: %s', table.concat(names, ' | '))
    end)
    mq.bind('/at_healstate', function(char, key, raid, ...)
        if not char or not key then return end
        local secs = {}
        for _, v in ipairs({ ... }) do secs[#secs + 1] = tonumber(v) or -1 end
        local aas = {}
        for i = 2, #secs do aas[#aas + 1] = secs[i] end
        healState[char] = healState[char] or {}
        healState[char][key] = { raid = (tonumber(raid) == 1), mgb = secs[1] or -1,
                                 aas = aas, updated = mq.gettime() }
    end)
    mq.bind('/at_mgbclick', function(key) mgb_click(key) end)
    mq.bind('/at_rezwindows', function()   -- confirmation window names differ by build; check, do not assume
        for _, w in ipairs({ 'ConfirmationDialogBox', 'LargeDialogWindow', 'RespawnWnd',
                             'ConfirmDialog', 'MessageBoxWnd', 'AlertWnd', 'YesNoWnd',
                             'RezConfirmationWnd', 'ResurrectWnd' }) do
            local open, raw = win_open(w)
            local kids = {}
            for _, c in ipairs({ 'CD_Yes_Button', 'Yes_Button', 'LDW_YesButton', 'LDW_OkButton',
                                 'CD_OK_Button', 'OK_Button' }) do
                local id = 0
                pcall(function() id = tonumber(mq.TLO.Window(w).Child(c).ID()) or 0 end)
                if id > 0 then kids[#kids + 1] = c end
            end
            log('[rezwin] %-24s Open=%-6s -> %s%s', w, raw, open and 'OPEN' or 'shut',
                (#kids > 0) and ('  buttons: ' .. table.concat(kids, ', ')) or '')
        end
        log('[rezwin] auto-accept %s, expecting-a-rez window %s', rezAccept and 'ON' or 'OFF',
            (mq.gettime() < rezExpectUntil) and 'OPEN' or 'closed')
    end)
    mq.bind('/at_diprobe', function()   -- what do the save names actually resolve to on me?
        for _, nm in ipairs(DI.SAVES) do
            local byName, bySong, aaID, spID = 0, 0, 0, 0
            pcall(function() byName = tonumber(mq.TLO.Me.Buff(nm).ID()) or 0 end)
            pcall(function() bySong = tonumber(mq.TLO.Me.Song(nm).ID()) or 0 end)
            pcall(function() aaID   = tonumber(mq.TLO.Me.AltAbility(nm).Spell.ID()) or 0 end)
            pcall(function() spID   = tonumber(mq.TLO.Spell(nm).ID()) or 0 end)
            local want, found = (aaID > 0) and aaID or spID, 0
            -- BY NAME, not by id. The old scan compared Me.Buff(i).ID() against a spell id, but on this
            -- build that read returns the SLOT INDEX (documented over in di_read_self) - so it could
            -- never match and printed slot 0 every time, which looked like "not present" rather than
            -- "this test is broken". Substring matching also catches a rank suffix: a buff that lands as
            -- 'Divine Redemption Rk. II' defeats every exact-name lookup in this file, and that is the
            -- obvious suspect the moment buff= and song= both read 0 while the game says it is blocked.
            local hit = ''
            for i = 1, buff_slot_max(55) do
                local bn, sn = '', ''
                pcall(function() bn = tostring(mq.TLO.Me.Buff(i).Name() or '') end)
                pcall(function() sn = tostring(mq.TLO.Me.Song(i).Name() or '') end)
                if bn ~= '' and bn:lower():find(nm:lower(), 1, true) then hit = string.format('buff slot %d "%s"', i, bn); break end
                if sn ~= '' and sn:lower():find(nm:lower(), 1, true) then hit = string.format('song slot %d "%s"', i, sn); break end
            end
            log('[diprobe] %s | buff=%d song=%d aaSpellID=%d spellID=%d -> name match: %s',
                nm, byName, bySong, aaID, spID, (hit ~= '') and hit or 'NONE')
        end
        local _, _, _, sv = di_read_self()
        log('[diprobe] saveUp resolves to %d', sv)
        -- Dump what is ACTUALLY on me. If the id we are looking for is not here, the buff that lands
        -- differs from the generic Spell[name] lookup and we need its real id, not a better guess.
        log('[diprobe] my buffs right now:')
        local shown = 0
        for i = 1, buff_slot_max(55) do
            local bid, bnm = 0, ''
            pcall(function() bid = tonumber(mq.TLO.Me.Buff(i).ID()) or 0 end)
            pcall(function() bnm = tostring(mq.TLO.Me.Buff(i).Name() or '') end)
            if bid > 0 then
                shown = shown + 1
                log('   slot %-2d  id=%-6d %s', i, bid, bnm)
            end
        end
        if shown == 0 then log('   (none)') end
        -- AND THE SONG TABLE. The dump above only ever covered Me.Buff, so anything short-duration was
        -- invisible to the very probe meant to explain why it was invisible.
        log('[diprobe] my songs / short-duration effects right now:')
        local sshown = 0
        for i = 1, buff_slot_max(55) do
            local sid, snm = 0, ''
            pcall(function() sid = tonumber(mq.TLO.Me.Song(i).ID()) or 0 end)
            pcall(function() snm = tostring(mq.TLO.Me.Song(i).Name() or '') end)
            if snm ~= '' and snm ~= 'NULL' then
                sshown = sshown + 1
                log('   song %-2d  id=%-6d %s', i, sid, snm)
            end
        end
        if sshown == 0 then log('   (none)') end
    end)
    mq.bind('/at_rezprobe', function()   -- what do the rez clickies actually report for range?
        for _, it in ipairs({ CROWN_ITEM, TOKEN_ITEM }) do
            local id, myr, r, nm = 0, -1, -1, ''
            pcall(function() id  = tonumber(mq.TLO.FindItem('=' .. it).ID()) or 0 end)
            pcall(function() nm  = tostring(mq.TLO.FindItem('=' .. it).Spell.Name() or '') end)
            pcall(function() myr = tonumber(mq.TLO.FindItem('=' .. it).Spell.MyRange()) or -1 end)
            pcall(function() r   = tonumber(mq.TLO.FindItem('=' .. it).Spell.Range()) or -1 end)
            log('[rezprobe] %s | id=%d spell="%s" MyRange=%s Range=%s', it, id, nm, tostring(myr), tostring(r))
        end
        log('[rezprobe] gate currently using %d', rez_range())
    end)
    mq.bind('/at_cureprobe', function()   -- diagnostic: what does each cure source resolve to on me?
        for _, e in ipairs(CURE_CLICKS) do
            local itemID, rank, rdy, secs, spellID = 0, 0, false, -1, 0
            pcall(function() itemID  = tonumber(mq.TLO.FindItem('=' .. e.name).ID()) or 0 end)
            pcall(function() rank    = tonumber(mq.TLO.Me.AltAbility(e.name).Rank()) or 0 end)
            pcall(function() rdy     = tlo_true(mq.TLO.Me.AltAbilityReady(e.name)()) end)
            pcall(function() secs    = tonumber(mq.TLO.Me.AltAbilityTimer(e.name).TotalSeconds()) or -1 end)
            pcall(function() spellID = tonumber(mq.TLO.Spell(e.name).ID()) or 0 end)
            local have = cure_state(e.name)
            log('[cureprobe] %s | item=%d aaRank=%d ready=%s timer=%s spellID=%d -> %s',
                e.name, itemID, rank, tostring(rdy), tostring(secs), spellID,
                have == 1 and 'MINE (button shown)' or 'not mine')
        end
    end)
    mq.bind('/at_magic', function(key) magic_click(key) end)
    mq.bind('/at_magicprobe', function()   -- what does each magic entry resolve to on me?
        for _, e in ipairs(MAGIC_CLICKS) do
            local have, secs, up, dsecs = magic_state(e)
            if e.spell then
                local gem, rdy = 0, '?'
                pcall(function() gem = tonumber(mq.TLO.Me.Gem(e.spell)()) or 0 end)
                pcall(function() rdy = tostring(mq.TLO.Me.SpellReady(e.spell)()) end)
                log('[magicprobe] %s (song) | gem=%d ready=%s -> %s', e.spell, gem, rdy,
                    have == 1 and 'MINE' or 'not memmed')
            else
                local id = 0
                pcall(function() id = tonumber(mq.TLO.FindItem('=' .. e.name).ID()) or 0 end)
                log('[magicprobe] %s (item) | id=%d -> %s', e.name, id, have == 1 and 'MINE' or 'not carried')
            end
            if have == 1 then log('   secs=%d running=%d left=%d', secs, up, dsecs) end
        end
    end)
    mq.bind('/at_magicstate', function(char, key, have, secs, up, dsecs)
        if not char or not key then return end
        magicState[char] = magicState[char] or {}
        magicState[char][key] = { have = tonumber(have) or 0, secs = tonumber(secs) or -1,
                                  up = tonumber(up) or 0, dsecs = tonumber(dsecs) or 0,
                                  updated = mq.gettime() }
    end)
    mq.bind('/at_cure', function(key) cure_click(key) end)
    mq.bind('/at_curestate', function(char, key, have, secs)
        if not char or not key then return end
        cureState[char] = cureState[char] or {}
        cureState[char][key] = { have = tonumber(have) or 0, secs = tonumber(secs) or -1,
                                 updated = mq.gettime() }
    end)
    mq.bind('/at_quiet', function(ms)
        local n = tonumber(ms) or 0
        quietUntil = (n > 0) and (mq.gettime() + math.min(n, 30000)) or 0
    end)
    mq.bind('/at_diauto', function(mode) DI.auto = (mode == 'on') end)
    mq.bind('/at_pot', function(key)   -- group draught button: drink the best tier I hold
        local base = pot_base_for(key)
        if not base then return end
        local ok, nm = pot_drink(base)
        if ok then log('[pot] %s sent', nm)      -- "landed" only once pot_retry_tick has seen it
        elseif nm then log('[pot] %s on cooldown', nm)
        else log('[pot] no %s carried', base) end
    end)
    mq.bind('/at_difired', function() DI.firedAt = mq.gettime(); DI.trigAt, DI.turnAt = 0, nil end)
    -- The attempt has a verdict, whatever it was - stop parking on the ceiling and let the next slot act.
    mq.bind('/at_didone', function() DI.firedAt = 0 end)
    -- The holder tells everyone at once, so nobody has to work out whose turn it is from staff timers.
    mq.bind('/at_dibaton', function(who) if who and who ~= '' then DI.baton = who end end)
    mq.bind('/at_dibatonback', function(who) di_baton_back(who) end)
    mq.bind('/at_diladder', function(mode)
        DI.ladderOff = (mode == 'off')
        pcall(save_settings)
        log('cleric save ladder is %s%s', DI.ladderOff and 'OFF' or 'ON',
            DI.ladderOff and ' - every save must now come from a DI staff' or '')
    end)
    mq.bind('/atladder', function(mode)
        local off = (mode == 'off')
        for _, nm in ipairs(group_members()) do
            if nm:lower() ~= myName:lower() then pcall(function() peer_cmdf(nm, '/at_diladder %s', off and 'off' or 'on') end) end
        end
        DI.ladderOff = off
        pcall(save_settings)
        log('cleric save ladder %s for the whole group', off and 'DISABLED' or 'enabled')
    end)
    mq.bind('/at_distafftimer', function() rezlog('[di] staff reads: %s', di_staff_reads()) end)
    -- COOLDOWN vs CASTABILITY, side by side. The whole ladder misbehaved because those two were conflated,
    -- so print both and let the numbers say which is stable. Run it a few times mid-fight: the timer column
    -- should hold still while the ready column blinks.
    mq.bind('/at_dirungs', function()
        for _, nm in ipairs({ DI.CLR_SAVES[1], DI.CLR_SAVES[2], DI.DG_AA, DI.DG_BOOT }) do
            local rank, aaT, aaR, gem, gemT, spR, itID, itT = 0, 'n/a', 'n/a', 0, 'n/a', 'n/a', 0, 'n/a'
            pcall(function() rank = tonumber(mq.TLO.Me.AltAbility(nm).Rank()) or 0 end)
            pcall(function() aaT = tostring(mq.TLO.Me.AltAbilityTimer(nm).TotalSeconds() or 'NULL') end)
            pcall(function() aaR = tostring(mq.TLO.Me.AltAbilityReady(nm)() or 'NULL') end)
            pcall(function() gem = tonumber(mq.TLO.Me.Gem(nm)()) or 0 end)
            if gem > 0 then pcall(function() gemT = tostring(mq.TLO.Me.GemTimer(gem).TotalSeconds() or 'NULL') end) end
            pcall(function() spR = tostring(mq.TLO.Me.SpellReady(nm)() or 'NULL') end)
            pcall(function() itID = tonumber(mq.TLO.FindItem('=' .. nm).ID()) or 0 end)
            if itID > 0 then pcall(function() itT = tostring(mq.TLO.FindItem('=' .. nm).TimerReady() or 'NULL') end) end
            log('[dirungs] %-28s rank=%d aaTimer=%-6s aaReady=%-6s gem=%d gemTimer=%-6s spellReady=%-6s itemID=%d itemTimer=%s',
                nm, rank, aaT, aaR, gem, gemT, spR, itID, itT)
        end
        log('[dirungs] ladder as the selector sees it:')
        for i, r in ipairs(di_rung_list()) do
            log('   rung %d  %-28s kind=%-5s ready=%s', i, r.name, r.kind, tostring(r.ready))
        end
    end)
    -- RESCUE. Hand E3 back to every toon, unconditionally. A leaked pause presents as "the toon looks
    -- perfectly healthy but no E3 command it is sent ever happens", which is close to undiagnosable in the
    -- moment - so make undoing it trivial rather than clever.
    mq.bind('/atresume', function()
        mq.cmd('/e3p off')
        for _, nm in ipairs(group_members()) do
            if nm:lower() ~= myName:lower() then pcall(function() peer_cmdf(nm, '/at_e3 off') end) end
        end
        log('handed E3 back to the whole group (/e3p off everywhere)')
    end)
    -- WHAT DOES THE STAFF LOOK LIKE ON ME? Lunafeet and Khulian have reported staff=0 all night and never
    -- once produced a cooldown, while the cleric, shaman and bard all have. staff=0 rather than -1 means
    -- FindItem does resolve it, so they carry it and cannot fire it - and guessing at which TLO says so is
    -- how the last three theories went wrong. Print the raw fields and let them answer.
    mq.bind('/at_distaffprobe', function(who)
        local function f(field)
            local v = 'n/a'
            pcall(function() v = tostring(mq.TLO.FindItem('=' .. DI.STAFF)[field]() or 'NULL') end)
            return v
        end
        local line = string.format('id=%s timer=%s slot=%s/%s spell=%s canuse=%s class=%s',
            f('ID'), f('TimerReady'), f('ItemSlot'), f('ItemSlot2'),
            f('Spell'), f('CanUse'), member_class(myName) or '?')
        rezlog('[di] staff probe: %s', line)
        if who and who ~= '' then pcall(function() peer_cmdf(who, '/at_distaffreport %s %s', myName, line) end) end
    end)
    mq.bind('/at_distaffreport', function(...) rezlog('[di] staff probe reply: %s', table.concat({ ... }, ' ')) end)
    mq.bind('/at_distaff', function()   -- ask everyone, collect here
        rezlog('[di] asking the group what the staff looks like on them')
        peer_bcast('/at_distaffprobe %s', myName)
        mq.cmdf('/at_distaffprobe %s', myName)
    end)
    -- A peer's cast was refused: the tank is covered, so stand down too rather than each of us paying an
    -- emerald to learn it. Duration comes from the sender so one config value governs the whole group.
    mq.bind('/at_disaved', function(ms)
        DI.savedUntil = mq.gettime() + (tonumber(ms) or DI.SAVED_HOLD)
        DI.trigAt, DI.turnAt = 0, nil
    end)
    -- I am the tank and someone's save was just refused on me: say what I am actually carrying, right
    -- now, by name across BOTH tables. Logged here and echoed to the asker so it lands in one file.
    mq.bind('/at_disavedump', function(who)
        local parts = {}
        for _, nm in ipairs(DI.SAVES) do
            local hit = ''
            for i = 1, buff_slot_max(55) do
                local bn, sn = '', ''
                pcall(function() bn = tostring(mq.TLO.Me.Buff(i).Name() or '') end)
                pcall(function() sn = tostring(mq.TLO.Me.Song(i).Name() or '') end)
                if bn ~= '' and bn:lower():find(nm:lower(), 1, true) then hit = 'buff:' .. bn; break end
                if sn ~= '' and sn:lower():find(nm:lower(), 1, true) then hit = 'song:' .. sn; break end
            end
            parts[#parts + 1] = string.format('%s=%s', nm, (hit ~= '') and hit or 'absent')
        end
        local _, _, _, sv = di_read_self()
        local line = string.format('saveUp=%d | %s', sv, table.concat(parts, ' | '))
        rezlog('[di] refusal dump (asked by %s): %s', who or '?', line)
        if who and who ~= '' then pcall(function() peer_cmdf(who, '/at_disavereport %s %s', myName, line) end) end
    end)
    mq.bind('/at_disavereport', function(...)
        rezlog('[di] tank reports at refusal: %s', table.concat({ ... }, ' '))
    end)
    mq.bind('/at_rezready', function(char, cr, tk, al, zone, cw) if char then rezReady[char] = { crown = tonumber(cr) or -1, token = tonumber(tk) or -1, cotw = tonumber(cw) or -1, alive = (tonumber(al) == 1), zone = tonumber(zone) or 0, updated = mq.gettime() } end end)
    mq.bind('/at_rezdone', function(name)
        if not name then return end
        rezDone[name:lower()] = mq.gettime() + 15000
        -- Retire the corpse ITSELF, not just the name behind a timeout. Resolve it here while we still
        -- know which body this was about; that id stays retired for the session.
        local id = rez_corpse(name)
        if id and id > 0 then rezCorpseDone[id] = true end
    end)
    mq.bind('/at_rezorder?', function(who)   -- a worker just came up and wants the current order
        if not SHOW_UI or not who then return end
        if #rezOrder == 0 then load_rez_order() end
        -- UNICAST the answer. Broadcasting meant five workers asking produced five group-wide sends,
        -- so every worker adopted the same order five or six times over.
        local parts = {}
        for _, sl in ipairs(rezOrder) do parts[#parts + 1] = sl.name .. ':' .. sl.clicky end
        if #parts > 0 then peer_cmdf(who, '/at_rezorder %s', table.concat(parts, ' ')) end
    end)
    mq.bind('/at_rezorder', function(...)   -- driver reordered the rezzer slots: adopt it so all batons agree
        local ord = {}
        for _, tok in ipairs({...}) do
            local nm, ck = tostring(tok):match('^(.-):(%a+)$')
            if nm and nm ~= '' and (ck == 'token' or ck == 'crown') then ord[#ord + 1] = { name = nm, clicky = ck } end
        end
        if #ord > 0 then rezOrder = ord; save_rez_order(); rezlog('[rez] adopted shared rezzer order (%d slots)', #ord) end
    end)
    -- The SENDER says how long. This hardcoded 4000, so raising the firer's own hold to 15s did
    -- nothing for anyone else: the group released the corpse four seconds in and a second rezzer took
    -- it mid-cast. A pre-cast claim is worth a few seconds; a claim made after actually casting has to
    -- outlive the whole cast, and the box can take eight seconds when the target is still zoning.
    mq.bind('/at_rezclaim', function(id, ms)
        local n = tonumber(id)
        if n then
            rezPending[n] = mq.gettime() + (tonumber(ms) or 4000)
            -- LOG THE RECEIPT. Without this, a double-rez is undiagnosable: "never sent", "never
            -- arrived" and "arrived but ignored" all look identical from the logs. Seen on 2026-07-27 -
            -- Lunafeet fired on Sebbun(435) and Khulian fired on the SAME corpse 1.8s later, having
            -- deferred to Lunafeet moments before. The block message ("someone else holds a claim")
            -- never appeared in Khulian's log, so the claim did not land - but with no receipt line
            -- there was no way to tell whether it was sent at all.
            rezlog('[rez] claim received on corpse %d for %dms', n, tonumber(ms) or 4000)
        end
    end)
    mq.bind('/at_rezrdy?', function(rezzer, rzone)   -- a rezzer asks: are you at bind, ready for a rez?
        if not rezzer then return end
        local zoning = false; pcall(function() zoning = tlo_true(mq.TLO.Me.Zoning()) end)
        local myz = 0; pcall(function() myz = tonumber(mq.TLO.Zone.ID()) or 0 end)
        local dead = true; pcall(function() dead = tlo_true(mq.TLO.Me.Dead()) end)
        -- "Am I up and away from my corpse?" A DIFFERENT ZONE used to be the only proof, which is a
        -- proxy for "released to bind" - and it never becomes true for anyone whose bind is in the zone
        -- they died in. They sat unrezzable forever with the rezzer stuck on the handshake. Being alive
        -- answers the real question directly, whatever the bind point is.
        if (not zoning) and myz > 0 and ((not dead) or myz ~= (tonumber(rzone) or -1)) then
            peer_cmdf(rezzer, '/at_rezrdy! %s', myName)
            -- A rez is now genuinely on its way to me. Only inside this window will the confirmation
            -- box get clicked automatically - a blanket "click any Yes button" would happily accept
            -- whatever else the game decided to ask.
            rezExpectFrom  = mq.gettime()
            rezExpectUntil = mq.gettime() + 15000
        end
    end)
    mq.bind('/at_rezinc', function(from)   -- a rezzer is casting on me right now: arm the accept window
        rezIncAt       = mq.gettime()   -- a REZZER said so; my own readiness does not count
        rezExpectFrom  = mq.gettime()
        rezExpectUntil = mq.gettime() + 20000
        rezlog('[rez] %s is rezzing me - watching for the confirmation box', tostring(from or '?'))
    end)
    mq.bind('/at_rezrdy!', function(tname) if tname then rezConfirm[tname:lower()] = mq.gettime() end end)   -- target confirmed ready
    -- The SENDER decides how long its skip is good for. This used to hardcode 8s, so a toon that skipped
    -- because it was 250 units away - and then walked to 150 - stayed 'out' in everyone else's table for
    -- eight seconds after it was able again. Distance skips are worth 3s, a failed cast 5s, no-clicky 8s.
    -- Missing duration = 8000, so a peer on an older build still behaves as before.
    mq.bind('/at_rezskip', function(key, id, ms)
        local n = tonumber(id)
        if key and n then
            rezSkip[n] = rezSkip[n] or {}
            rezSkip[n][key:lower()] = mq.gettime() + (tonumber(ms) or 8000)
            -- DO NOT clear rezPending here. A skip says "*I* am standing down on this corpse" - it is a
            -- statement about the SENDER's eligibility, not about whether the corpse is free. Clearing
            -- the claim meant any rezzer with no clicky could wipe a claim held by someone mid-cast,
            -- and the next slot would then fire on a corpse that already had a rez in flight.
            -- Seen 2026-07-27: Lunafeet claimed Sebbun(455) and cast; Stylin sent a skip for 455
            -- ("I have no clicky; baton passes me"); Sunetoo - which had received and stored Lunafeet's
            -- claim a moment earlier - found it gone and spent a second clicky on the same corpse.
            -- The claim expires on its own, and a rezzer whose cast genuinely fails releases it via the
            -- timeout path. Neither of those needs a third party to do it.
        end
    end)
    mq.bind('/at_burn', function(char, class, tier, secs, active, dsecs, kind, ord, tkey, ...)   -- driver receives a worker's item-timer report
        if not char then return end
        local item = table.concat({...}, ' ')
        if item == '' then return end
        burnClass[char] = class
        burnState[char] = burnState[char] or {}
        burnState[char][item] = { tier = tonumber(tier) or 1, secs = tonumber(secs) or 0, active = (tonumber(active) == 1), dsecs = tonumber(dsecs) or 0, kind = kind or 'i', ord = tonumber(ord) or 0, tkey = ((tkey or '?'):gsub('~', ' ')), updated = mq.gettime() }
    end)
end)

local autoXTank       = true    -- auto-maintain tank XTargets on the group's healers (set-and-forget; on by default)
-- Announce roster changes to the raid? The /rsay used to be unconditional, was removed for being
-- raid-wide chat on every change, and is now a setting so it can be either. Off by default - the log
-- line always happens regardless, so turning this off never costs you the ability to check after
-- the fact. Global, not local: this chunk is at Lua's 200-local ceiling.
xtankAnnounce = false
-- Names you want on your XTargets that are NOT raid tanks. Rebuilt into the slots on every pass, so
-- they survive a raid roster change, a zone, and the clear that happens when the raid ends - you set
-- them once and stop re-adding them by hand. Persisted with the other settings.
-- Global, not local: this chunk is at Lua's 200-local ceiling.
xtankPinned = {}
local iAmHealer       = false   -- set at startup; only priest-classes self-maintain tank XTargets
pcall(function() iAmHealer = ({ CLR = true, DRU = true, SHM = true })[(mq.TLO.Me.Class.ShortName() or ''):upper()] or false end)
local lastXTankPoll   = 0       -- gettime of last auto tank-xtarget sweep
-- How often the AUTO pass re-reads the XTarget slots to check nothing has been cleared by hand.
-- The roster check stays instant; only this verification is throttled. Two minutes: long enough that
-- twelve TLO reads are nothing, short enough that you never spend a raid missing a tank.
XTANK_VERIFY_MS = 120000
-- How long a tank keeps its slot after the client last had its spawn loaded. The client culls distant
-- spawns, so this is about the client's draw distance, not about who is in the zone.
XTANK_ZONE_LATCH_MS = 120000
xtankSeenAt = {}          -- lowercase name -> when its spawn was last actually visible
lastXTankVerify = 0
local xtankRecheckAt  = nil     -- debounce: re-check tank XTargets at this time after a raid event
-- Event-driven raid watch: each toon watches its OWN raid and, on any change, debounces a re-check.
-- The 60s poll below is the failsafe if a message wording doesn't match on Laz.
local function raid_changed() if autoXTank then xtankRecheckAt = mq.gettime() + 2000 end end
pcall(function()
    -- Another AdventureTime user calling a raid corpse. /say is enough: to be eligible for a corpse at
    -- all we both have to be within 100 units of it, so we are near each other by construction. If it
    -- does not carry, the worst case is the double-rez we would have had anyway with no announcement.
    -- The corpse ID is what makes this a real claim rather than a hint - it drops straight into
    -- rezPending, exactly like our own internal one.
    mq.event('at_rez_say', "#1# says, 'ATREZ #2# #3#'#*#", function(_, who, id, tgt)
        local n = tonumber(id)
        if not n or not who then return end
        if who:lower() == myName:lower() then return end          -- our own shout, heard back
        for _, m in ipairs(group_members()) do
            if m:lower() == who:lower() then return end           -- our own group: already coordinated
        end
        rezPending[n] = mq.gettime() + 8000
        rezlog('[rez] %s (outside my group) called %s - backing off corpse %d', who, tostring(tgt), n)
    end)
    mq.event('at_raid_join',   '#1# joined the raid#*#',            raid_changed)   -- Laz: 'Name joined the raid.'
    mq.event('at_raid_leave',  '#1# has left the raid#*#',          raid_changed)   -- Laz: 'Name has left the raid.'
    mq.event('at_raid_removed','#1# has been removed from the raid#*#', raid_changed)
    mq.event('at_raid_dispand','#*#raid has been disbanded#*#',     raid_changed)
    -- THE GAME TELLS US DIRECTLY - but only about the cast we care about. This used to match any
    -- "#*#did not take hold on #1##*#", which on a cleric means every heal that fails to land. On
    -- 2026-07-30 that caught an unrelated heal of Nityrc's blocked by the shaman's Transcendental Torpor
    -- and reported it as the STAFF being blocked, because the only other test was timing. The spell is
    -- captured now and has to be one of the saves the staff actually casts before it counts.
    mq.event('at_di_blocked', 'Your #1# did not take hold on #2#.#*#', function(line, spell, who)
        local sp = tostring(spell or ''):lower()
        local mine = false
        for _, nm in ipairs(DI.SAVES) do if sp == nm:lower() then mine = true; break end end
        if not mine then return end                 -- somebody else's spell failing; not our business
        DI.blockedAt = mq.gettime()
        DI.blockedOn = tostring(who or ''):gsub('[%.%s]+$', '')
        DI.blockedBy = tostring(line or ''):match('Blocked by ([^%.%)]+)') or 'unknown'
    end)
    mq.bind('/at_pong', function(peer) if peer then alive[peer:lower()] = true end end)
    mq.bind('/at_resync', function()   -- driver says the group changed: re-report EVERYTHING
        burnLast = {}; burnPending = {}; buffNameOf = {}; buffLatch = {}; tribLast = nil
        potLast = {}; healLast = {}; cureLast = {}; magicLast = {}
        lastBurnPoll, lastClickPoll = 0, 0   -- poll on the next tick rather than waiting out the 2s
        burnStartAt, clickStartAt = 0, 0   -- skip both startup settles: the driver is waiting on us now
        lastBurnResync = mq.gettime()
        log('[sync] re-reporting everything at the driver request')
    end)
    mq.bind('/at_burnrefresh', function()   -- re-parse my [Burn] INI and re-report every item from scratch
        local fresh = parse_burns()
        if fresh and #fresh > 0 then BURN_WATCH = fresh end
        burnLast = {}                        -- forget last-reported states so everything reports again
        burnPending = {}
        buffNameOf = {}                      -- re-resolve buff names too, in case items changed
        buffLatch = {}
        if SHOW_UI then burnState[myName] = nil end
        lastBurnPoll = 0                     -- poll immediately
        lastBurnResync = mq.gettime()
        burnStartAt, clickStartAt = 0, 0
        log('[burns] refresh: watching %d item(s)', #BURN_WATCH)
    end)
    mq.bind('/at_tribreq', function(who)   -- someone wants tribute status: read mine locally and reply
        if not who then return end
        local a = false; pcall(function() local v = mq.TLO.Me.TributeActive(); a = (v == true) or (tostring(v):upper() == 'TRUE') end)
        local f = 0; pcall(function() f = tonumber(mq.TLO.Me.CurrentFavor()) or 0 end)
        peer_cmdf(who, '/at_trib %s %d %d', myName, a and 1 or 0, f)
    end)
    mq.bind('/at_trib', function(name, act, favor)   -- a peer reported its tribute status
        if name then tributeState[name] = { active = (tonumber(act) == 1), favor = tonumber(favor) or 0, updated = mq.gettime() } end
    end)
end)


-- Bring the whole group up in PARALLEL: ping everyone at once, launch all the non-responders at once,
-- then wait a single settle - instead of a launch+wait per toon. Returns the list that's responsive.
local function bring_up_group(peers)
    for _, p in ipairs(peers) do alive[p:lower()] = nil; peer_cmdf(p, '/at_ping %s', myName) end
    local w = 0
    while w < 1200 do mq.doevents(); mq.delay(100); w = w + 100 end   -- collect the fast pongs

    local launched = false
    for _, p in ipairs(peers) do
        if not alive[p:lower()] then peer_cmdf(p, '/lua run adventuretime worker %s', myName); launched = true end
    end
    if launched then
        mq.delay(3000)   -- ONE settle for all the launches
        for _, p in ipairs(peers) do if not alive[p:lower()] then peer_cmdf(p, '/at_ping %s', myName) end end
        local w2 = 0
        while w2 < 2500 do mq.doevents(); mq.delay(100); w2 = w2 + 100 end
    end

    local up = {}
    for _, p in ipairs(peers) do if alive[p:lower()] then up[#up + 1] = p end end
    return up
end

-- ---------------------------------------------------------------------------
-- Trade gesture: hand exactly `qty` of `item` from OUR bags to `receiver`. Mirrors the proven Lazcraft
-- hand-off: nav to them, target, pick the EXACT count via the quantity split (right-click bag to open,
-- left-click slot, SetText, wait for the field to read it, then accept - a plain grab takes the whole
-- stack), drop on target, click Trade. The receiver's AdventureTime auto-accepts. Never over-hands.
-- ---------------------------------------------------------------------------
local giving = false

local function clear_cursor()
    if (mq.TLO.Cursor.ID() or 0) ~= 0 then
        mq.cmd('/autoinventory'); mq.delay(400, function() return (mq.TLO.Cursor.ID() or 0) == 0 end)
    end
end

local function find_slot(item)
    local up = item:upper()
    for b = 1, 10 do
        local cont = mq.TLO.Me.Inventory('pack' .. b).Container() or 0
        for s = 1, cont do
            local nm = mq.TLO.Me.Inventory('pack' .. b).Item(s).Name()
            if nm and nm:upper() == up then return b, s end
        end
    end
end

-- Open (or close) every inventory bag once. Right-clicking a container toggles it, so calling this at
-- the start AND end of a trade returns each bag to its original open/closed state - and in between the
-- normally-closed bags are OPEN, so the quantity split pops without a right-click per pickup.
local function toggle_all_bags()
    for b = 1, 10 do
        if (mq.TLO.Me.Inventory('pack' .. b).Container() or 0) > 0 then
            mq.cmdf('/itemnotify pack%d rightmouseup', b); mq.delay(50)
        end
    end
    mq.delay(300)   -- let the container windows settle
end
pcall(function() mq.bind('/at_bags', function() toggle_all_bags() end) end)

local function give_items_to(receiver, bundle)   -- bundle = { {item=, qty=}, ... }; may span MANY trades
    local todo = {}
    for _, b in ipairs(bundle) do
        local q = math.min(math.floor(tonumber(b.qty) or 0), my_count(b.item))
        if q > 0 then todo[#todo + 1] = { item = b.item, remaining = q } end
    end
    if #todo == 0 then return {} end
    -- Tell the receiver we are coming, so its accept window opens. Without this it would sit with the
    -- trade untouched, because it no longer accepts blindly. 60s covers nav + fill + confirm with room
    -- for a slow zone; it lapses on its own if the hand-off never arrives.
    pcall(function() peer_cmdf(receiver, '/at_expecttrade %d', 60000) end)
    giving = true
    local placedMap = {}

    local function grab_and_drop(item, want)
        clear_cursor()
        local bag, sl = find_slot(item)
        if not bag then return 0 end
        local slotStack = mq.TLO.Me.Inventory('pack' .. bag).Item(sl).Stack() or 1
        want = math.min(want, slotStack)
        -- Bags are opened ONCE up front (open_bags), so a plain slot left-click pops the split for a
        -- partial. Fallback: if the split didn't appear and we grabbed the whole stack, that bag wasn't
        -- open - put it back, open it, retry once.
        mq.cmdf('/itemnotify in pack%d %d leftmouseup', bag, sl)
        mq.delay(900, function() return mq.TLO.Window('QuantityWnd').Open() or (mq.TLO.Cursor.ID() or 0) > 0 end)
        if want < slotStack and not mq.TLO.Window('QuantityWnd').Open()
           and (mq.TLO.Cursor.ID() or 0) > 0 and (mq.TLO.Cursor.Stack() or 1) > want then
            mq.cmd('/autoinventory'); mq.delay(400, function() return (mq.TLO.Cursor.ID() or 0) == 0 end)
            mq.cmdf('/itemnotify pack%d rightmouseup', bag); mq.delay(300)
            mq.cmdf('/itemnotify in pack%d %d leftmouseup', bag, sl)
            mq.delay(900, function() return mq.TLO.Window('QuantityWnd').Open() or (mq.TLO.Cursor.ID() or 0) > 0 end)
        end
        if mq.TLO.Window('QuantityWnd').Open() then
            local wantS, setok = tostring(want), false
            mq.cmdf('/invoke ${Window[QuantityWnd/QTYW_SliderInput].SetText[%d]}', want)
            local deadline, ticks = mq.gettime() + 1500, 0
            repeat
                if (mq.TLO.Window('QuantityWnd/QTYW_SliderInput').Text() or '') == wantS then setok = true; break end
                mq.delay(40); ticks = ticks + 1
                if ticks % 8 == 0 then mq.cmdf('/invoke ${Window[QuantityWnd/QTYW_SliderInput].SetText[%d]}', want) end
            until mq.gettime() > deadline
            if not setok then mq.cmd('/keypress esc'); return 0 end
            mq.cmd('/notify QuantityWnd QTYW_Accept_Button leftmouseup')
            mq.delay(600, function() return (mq.TLO.Cursor.ID() or 0) > 0 end)
        end
        if (mq.TLO.Cursor.ID() or 0) == 0 then return 0 end
        local onCursor = mq.TLO.Cursor.Stack() or 1
        if onCursor > want then mq.cmd('/autoinventory'); return 0 end
        mq.cmd('/notify TargetWindow Target_HP leftmouseup')          -- drop into the (open) trade window
        mq.delay(700, function() return (mq.TLO.Cursor.ID() or 0) == 0 end)
        if (mq.TLO.Cursor.ID() or 0) > 0 then mq.cmd('/click left target'); mq.delay(700, function() return (mq.TLO.Cursor.ID() or 0) == 0 end) end
        if (mq.TLO.Cursor.ID() or 0) > 0 then mq.cmd('/autoinventory'); return 0 end
        return onCursor
    end

    local ok = pcall(function()
        local pid = mq.TLO.Spawn(string.format('pc =%s', receiver)).ID() or 0
        if pid == 0 then log('\\arCannot find %s in zone.\\ax', receiver); return end
        if (mq.TLO.Spawn('id ' .. pid).Distance() or 999) > 15 then
            mq.cmdf('/nav id %d', pid)
            mq.delay(8000, function() return (mq.TLO.Spawn('id ' .. pid).Distance() or 999) <= 15 end)
            mq.cmd('/nav stop')
        end
        mq.cmdf('/target id %d', pid)
        mq.delay(600, function() return (mq.TLO.Target.ID() or 0) == pid end)
        if (mq.TLO.Target.ID() or 0) ~= pid then log('\\arCould not target %s.\\ax', receiver); return end

        -- keep opening trades (8 stacks each) until everything is handed or nothing more can be picked up
        local guard = 0
        while guard < 40 do
            guard = guard + 1
            local anyLeft = false
            for _, t in ipairs(todo) do if t.remaining > 0 and my_count(t.item) > 0 then anyLeft = true; break end end
            if not anyLeft then break end

            local slots, movedThisTrade = 0, 0
            for _, t in ipairs(todo) do
                while t.remaining > 0 and slots < 8 and my_count(t.item) > 0 do
                    local moved = grab_and_drop(t.item, t.remaining)
                    if moved <= 0 then break end
                    placedMap[t.item] = (placedMap[t.item] or 0) + moved
                    t.remaining = t.remaining - moved
                    slots = slots + 1; movedThisTrade = movedThisTrade + moved
                end
                if slots >= 8 then break end
            end

            if movedThisTrade > 0 and mq.TLO.Window('TradeWnd').Open() then
                mq.delay(300)
                mq.cmd('/notify TradeWnd TRDW_Trade_Button leftmouseup')
                mq.delay(8000, function() return not mq.TLO.Window('TradeWnd').Open() end)
                if mq.TLO.Window('TradeWnd').Open() then mq.cmd('/notify TradeWnd TRDW_Cancel_Button leftmouseup') end
            else
                if mq.TLO.Window('TradeWnd').Open() then mq.cmd('/notify TradeWnd TRDW_Cancel_Button leftmouseup') end
                break   -- couldn't move anything this pass; stop
            end
        end
    end)
    giving = false
    if not ok then clear_cursor() end
    for item, placed in pairs(placedMap) do log('\\agHanded %d %s to %s.\\ax', placed, item, receiver) end
    return placedMap
end

-- single-item convenience (used by the Emerald buy hand-out)
local function give_item_to(receiver, item, qty)
    local m = give_items_to(receiver, { { item = item, qty = qty } })
    return m[item] or 0
end

-- Receiver side: if a trade window is open and we did NOT initiate it, accept it.
-- Accept a trade ONLY while a hand-off to us is actually in progress. This used to fire on any open
-- trade window, every tick - so opening a trade with one of these toons by hand got it slammed shut
-- 300ms later, before anything could be placed in it. The receiver knows perfectly well when a
-- hand-off is coming: the giver announces it right before navigating over. Outside that window we
-- leave the trade alone and a human can use it normally.
local function accept_incoming()
    if giving then return end
    if mq.gettime() > (expectTradeUntil or 0) then return end
    if mq.TLO.Window('TradeWnd').Open() then
        mq.delay(300)
        mq.cmd('/notify TradeWnd TRDW_Trade_Button leftmouseup')
        mq.delay(2000, function() return not mq.TLO.Window('TradeWnd').Open() end)
    end
end

-- Set an exact quantity in the QuantityWnd (buy/split), waiting for the field to read it before accept.
local function accept_qty_window(n)
    if not mq.TLO.Window('QuantityWnd').Open() then return end
    if n and n > 0 then
        mq.cmdf('/invoke ${Window[QuantityWnd/QTYW_SliderInput].SetText[%d]}', n)
        mq.delay(700, function() return (mq.TLO.Window('QuantityWnd/QTYW_SliderInput').Text() or '') == tostring(n) end)
    end
    mq.cmd('/notify QuantityWnd QTYW_Accept_Button leftmouseup')
    mq.delay(1500, function() return not mq.TLO.Window('QuantityWnd').Open() end)
end

-- Buy up to `qty` of `item` onto US from `vendor`. Self-contained port of Lazcraft's merchant buy:
-- target the vendor, close in, open by target id, select the item (by-name method), then Buy ->
-- QuantityWnd -> exact amount, looping until we reach the target count. Returns how many we gained.
local function buy_from_vendor(vendor, item, qty)
    qty = math.floor(tonumber(qty) or 0)
    if qty <= 0 then return 0 end
    local before = my_count(item)
    local pid = mq.TLO.Spawn(string.format('npc =%s', vendor)).ID() or 0
    if pid == 0 then log('\\arVendor %s isn\'t in this zone - can\'t buy %s.\\ax', vendor, item); return 0 end
    mq.cmdf('/target id %d', pid)
    mq.delay(700, function() return (mq.TLO.Target.ID() or 0) == pid end)
    if (mq.TLO.Target.Distance() or 999) > 2 then
        mq.cmdf('/nav id %d distance=1', pid)
        mq.delay(10000, function() return (mq.TLO.Target.Distance() or 999) <= 2 or not mq.TLO.Navigation.Active() end)
        mq.cmd('/nav stop'); mq.cmd('/face fast')
    end
    mq.cmd('/invoke ${Merchant.OpenWindow}')
    mq.delay(3000, function() return mq.TLO.Merchant.Open() end)
    if not mq.TLO.Merchant.Open() then log('\\arCould not open %s\'s merchant window.\\ax', vendor); return 0 end
    mq.delay(6000, function() return mq.TLO.Merchant.ItemsReceived() end)

    mq.TLO.Merchant.SelectItem('=' .. item)()   -- by-name exact select (skips the widget row-walk)
    mq.delay(1800, function() return (mq.TLO.Merchant.SelectedItem.Name() or ''):upper() == item:upper() end)
    if (mq.TLO.Merchant.SelectedItem.Name() or ''):upper() ~= item:upper() then
        log('\\ar%s doesn\'t sell %s (or it couldn\'t be selected).\\ax', vendor, item)
        mq.cmd('/notify MerchantWnd MW_Done_Button leftmouseup'); return 0
    end

    local goal, guard = before + qty, 0
    while my_count(item) < goal and guard < 25 do
        guard = guard + 1
        clear_cursor()
        mq.cmd('/notify MerchantWnd MW_Buy_Button leftmouseup')
        mq.delay(900, function() return mq.TLO.Window('QuantityWnd').Open() or my_count(item) >= goal end)
        if mq.TLO.Window('QuantityWnd').Open() then
            accept_qty_window(goal - my_count(item))
            mq.delay(2500, function() return my_count(item) >= goal end)
            clear_cursor()
        else
            mq.delay(500); clear_cursor()
        end
    end
    mq.cmd('/notify MerchantWnd MW_Done_Button leftmouseup')
    local got = my_count(item) - before
    if got > 0 then log('\\agBought %d %s from %s.\\ax', got, item, vendor) end
    return got
end

-- Completion replies: a peer says /at_done when it finishes a commanded give/collect, so the driver
-- waits for ACTUAL completion (a multi-trade collect can take a while) instead of a fixed guess.
local doneReplies = {}
pcall(function() mq.bind('/at_done', function(peer) if peer then doneReplies[peer:lower()] = true end end) end)

-- The driver tells a holder to hand items out via these binds.
pcall(function()
    mq.bind('/at_give', function(encItem, qtyStr, receiver)
        if not encItem or not receiver then return end
        give_item_to(receiver, dec(encItem), tonumber(qtyStr) or 0)
    end)
    -- Bundle give: hand a set of items to one receiver (may span trades). list = enc:qty,enc:qty,...
    mq.bind('/at_give_multi', function(driver, receiver, list)
        if not driver or not receiver or not list then return end
        local bundle = {}
        for pair in list:gmatch('[^,]+') do
            local e, q = pair:match('^(.-):(%d+)$')
            if e then bundle[#bundle + 1] = { item = dec(e), qty = tonumber(q) } end
        end
        give_items_to(receiver, bundle)
        peer_cmdf(driver, '/at_done %s', myName)
    end)
    -- Collect: hand EVERYTHING of the listed items to the collector (uses my own current counts). list = enc,enc,...
    mq.bind('/at_collect', function(collector, list)
        if not collector or not list then return end
        local bundle = {}
        for e in list:gmatch('[^,]+') do
            local it = dec(e); local n = my_count(it)
            if n > 0 then bundle[#bundle + 1] = { item = it, qty = n } end
        end
        give_items_to(collector, bundle)
        peer_cmdf(collector, '/at_done %s', myName)
    end)
end)

-- Wait (up to timeoutMs) for a peer to report /at_done. Accepts any trade opened TO us meanwhile, so a
-- collect (peer trading INTO the driver) goes through.
local function wait_done(peer, timeoutMs)
    local w = 0
    while w < (timeoutMs or 60000) do
        accept_incoming()
        mq.doevents(); mq.delay(150); w = w + 150
        if doneReplies[peer:lower()] then return true end
    end
    return false
end

-- Hand a bundle from `giver` to `receiver`: locally if we're the giver, else command the giver's toon
-- and wait for its /at_done.
local function do_give_bundle(giver, receiver, itemsMap)
    local bundle = {}
    for item, qty in pairs(itemsMap) do if qty > 0 then bundle[#bundle + 1] = { item = item, qty = qty } end end
    if #bundle == 0 then return end
    if giver:lower() == myName:lower() then
        give_items_to(receiver, bundle)
    else
        local parts = {}
        for _, b in ipairs(bundle) do parts[#parts + 1] = enc(b.item) .. ':' .. b.qty end
        doneReplies[giver:lower()] = nil
        peer_cmdf(giver, '/at_give_multi %s %s %s', myName, receiver, table.concat(parts, ','))
        wait_done(giver, 45000)   -- wait for the peer to actually finish (was a fixed 9s)
    end
end

-- Pause ('on') or resume ('off') E3 on ourselves AND every listed peer, so E3 can't grab the cursor
-- mid-pickup or reposition a toon during a trade. Peers handle it via /at_e3.
local function group_e3(mode, peers)
    mq.cmd('/e3p ' .. mode)
    for _, p in ipairs(peers or {}) do peer_cmdf(p, '/at_e3 ' .. mode) end
end

-- Toggle all bags on ourselves AND every listed peer. Called once at the start of an op (open) and once
-- at the end (close) - symmetric, so bags return to their original state - instead of per trade.
local function group_bags(peers)
    toggle_all_bags()
    for _, p in ipairs(peers or {}) do peer_cmdf(p, '/at_bags') end
end

-- ---------------------------------------------------------------------------
-- Distribution (driver): for each item with a target, top everyone up to it from the biggest holder.
-- ---------------------------------------------------------------------------
local uiStatus  = ''
local tributeRows = {}   -- { {name=, active=bool, favor=number}, ... } filled by refresh_tribute()
miniMode        = false   -- compact window when minimized. NOT local: save_settings is defined
                          -- further up the file and would otherwise write a same-named global.
-- NOT local: save_settings/load_settings are defined further up the file, so a local declared here
-- is invisible to them - they would read and write a same-named GLOBAL while the UI used the local,
-- and the setting would silently never persist. rezAuto, showSec and DI are globals for this reason.
-- (Also buys four back against the 200-local ceiling.)
miniBurns       = true    -- show the burn dot matrix in the mini window
miniRez         = true    -- show crown/token cooldowns in the mini window
miniDI          = false   -- show the tank save line + DI staff cooldowns in the mini window
miniPots        = false   -- show the group draught buttons in the mini window
miniClicks      = false   -- show the per-class MGB/group click buttons in the mini window
miniCombos      = false   -- show the combo buttons in the mini window
miniCures       = false   -- show the cure buttons (Radiant Cure etc) in the mini window
miniArcane      = false   -- show the Arcane Reprisal row in the mini window
miniPhantom     = false   -- show the Phantom Whispers queue in the mini window
arcLast         = nil     -- my last-pushed arcane state, for change detection
miniMagic       = false   -- show the magic protection clicky buttons in the mini window
miniBurnTable   = false   -- burns section: false = dot matrix, true = the full detail table
-- Who appears first, left to right. Separate from rezPriority on purpose: that is who gets RESSED
-- first, which is a different question from who you want to read first. Empty = plain group order.
charOrder       = {}
miniBurnFilter  = 'All'   -- the mini burn view's own role filter, independent of the Burns tab
miniSizeWanted  = false   -- one-shot: resize the mini window next frame (set when detail turns on)
miniSizedOnce   = false   -- has the detail view been sized yet this session?
-- Width the detail table actually needs: a column per reporting character at 250, plus room for the
-- row labels and the window chrome. Clamped so it never asks for more than a sane screen width.
function mini_table_size()
    local n = 0
    for _, c in ipairs(ordered_members()) do
        if burnState[c] and (miniBurnFilter == 'All' or role_of(burnClass[c]) == miniBurnFilter) then
            n = n + 1
        end
    end
    if n < 1 then n = 1 end
    return math.min(1800, n * 300 + 60), 620   -- 300: comfortable, under the 400 ceiling
end
miniCoth        = false   -- show the CoTH Group button in the mini window
-- GLOBAL, not local: this chunk is at Lua's hard 200-local ceiling and one more would stop it
-- compiling. One table holds every section toggle rather than a local per setting.
showSec = { tribute = true, pots = true, burns = true, rez = true, misc = true }   -- section visibility (persisted)
local lastTributePoll = 0       -- gettime of last tribute refresh
local lastTribPush    = 0       -- my own tribute report to the driver
local lastZoneID      = -1      -- detect zoning to force a refresh
local zoneSettleAt    = nil     -- refresh this long after a zone (let DanNet peers resync)
local shortfalls = {}   -- { "Item: Char short N", ... } from the last run
running    = true
local windowOpen = true
local distributing = false
local giveRequested = false   -- set by the button; the MAIN LOOP runs give_out (delays can't yield in render)
local closeAllRequested = false   -- set by the Close-all button; MAIN LOOP broadcasts and exits
local collectRequested = false   -- set by the Collect-all button; MAIN LOOP runs collect_all
local showStatus = false          -- toggle: show each toon's count per item (green if >= target, red if <)
local refreshRequested = false    -- set to re-read the group's counts for the status view
local statusResize = false        -- widen the window once when status is turned on
local statusCounts = {}           -- peerlower -> { item -> count } (cached)
local statusNames = {}            -- ordered display names for the status columns


local function give_out()
    if distributing then return end
    distributing = true
    shortfalls = {}
    local full = group_members()
    if #full <= 1 then uiStatus = 'No group members found (are you grouped and on the network?).'; distributing = false; return end

    -- Count EVERYONE first, straight over DanNet - a peer does NOT need to be running AdventureTime just to
    -- report its counts, so there's no pinging the group here. We only bring toons up (after planning) if
    -- the plan actually needs them to GIVE.
    local peers = {}
    for _, m in ipairs(full) do if m:lower() ~= myName:lower() then peers[#peers + 1] = m end end
    uiStatus = "Reading everyone's counts..."
    query_all_counts(peers, ITEMS)
    local roster = { myName }
    for _, p in ipairs(peers) do roster[#roster + 1] = p end
    local function held(who, item) return (counts[who:lower()] and counts[who:lower()][item]) or 0 end
    -- True when we never got an answer for this item from this toon. Distinct from "holds none".
    local function unknown(who, item)
        local c = counts[who:lower()]
        return (c and c.__unknown and c.__unknown[item]) and true or false
    end
    local giverUp = {}   -- givers we successfully brought up (filled after planning)

    -- PLAN: aggregate every hand-off into giver -> receiver -> {item = qty}. No trades yet, so we can
    -- then hand each receiver EVERYTHING from a given giver in one trade.
    local plan = {}   -- giverLower -> { name, rcv = { rcvLower -> { name, items = {item=qty} } } }
    local function add_give(gName, rName, item, qty)
        if qty <= 0 or gName:lower() == rName:lower() then return end   -- no self-trades
        local g = gName:lower()
        plan[g] = plan[g] or { name = gName, rcv = {} }
        local r = rName:lower()
        plan[g].rcv[r] = plan[g].rcv[r] or { name = rName, items = {} }
        plan[g].rcv[r].items[item] = (plan[g].rcv[r].items[item] or 0) + qty
    end
    local buyNeed = {}   -- item -> total the driver must buy to cover shortfalls

    -- Casters don't use endurance - skip Frenzied Endurance for them (they receive 0, and if one happens
    -- to be holding the most, its keep-amount is 0 so it gives the whole stash away).
    local function class_of(who) return (counts[who:lower()] and counts[who:lower()].__class) or '' end
    local function eff_target(who, item)
        local c = class_of(who)
        local ck = class_key(c)
        if ck and is_endurance(item) and not WANTS_ENDURANCE[ck] then return 0 end
        if ck and is_mana(item) and not WANTS_MANA[ck] then return 0 end
        return target[item] or 0
    end

    for _, item in ipairs(ITEMS) do
        local tgt = target[item] or 0
        if tgt > 0 then
            local richest, richestN = roster[1], -1
            for _, m in ipairs(roster) do
                if not unknown(m, item) and held(m, item) > richestN then richest, richestN = m, held(m, item) end
            end
            local surplus = math.max(0, richestN - eff_target(richest, item))
            local function cover(member, short)
                local give = math.min(short, surplus)
                if give > 0 then add_give(richest, member, item, give); surplus = surplus - give end
                local remaining = short - give
                if remaining > 0 then
                    if VENDOR[item] then
                        buyNeed[item] = (buyNeed[item] or 0) + remaining
                        add_give(myName, member, item, remaining)   -- driver hands the bought ones (self skipped)
                    else
                        shortfalls[#shortfalls + 1] = string.format('%s: %s short %d', item, member, remaining)
                        log('  %s short %d (not purchasable)', member, remaining)
                    end
                end
            end
            for _, m in ipairs(roster) do
                if m:lower() ~= richest:lower() then
                    if unknown(m, item) then
                        -- Refuse to guess. Handing a full target to a toon that may already be carrying
                        -- one is worse than handing nothing, and it is silent when it goes wrong.
                        shortfalls[#shortfalls + 1] = string.format('%s: %s count unknown (timed out) - skipped', item, m)
                        log('  %s count unknown for %s - skipped rather than assuming zero', item, m)
                    else
                        cover(m, math.max(0, eff_target(m, item) - held(m, item)))
                    end
                end
            end
            cover(richest, math.max(0, eff_target(richest, item) - richestN))   -- the holder itself may still be under target
        end
    end

    -- Only the toons that actually GIVE need AdventureTime running (to hand items over). Bring up JUST
    -- those - no pinging the whole group - then pause their E3 and open their bags.
    local givers = {}
    for gl, g in pairs(plan) do if gl ~= myName:lower() then givers[#givers + 1] = g.name end end
    local giverPeers = {}
    if #givers > 0 then
        uiStatus = 'Starting AdventureTime on the giver(s)...'
        local up = bring_up_group(givers)
        for _, pp in ipairs(up) do giverUp[pp:lower()] = true; giverPeers[#giverPeers + 1] = pp end
        for _, gn in ipairs(givers) do
            if not giverUp[gn:lower()] then shortfalls[#shortfalls + 1] = 'Could not start AdventureTime on ' .. gn .. ' - its hand-off is skipped' end
        end
    end
    group_e3('on', giverPeers)   -- pause E3 on the givers so it can't grab the cursor mid-trade
    group_bags(giverPeers)       -- open the givers' bags ONCE for the whole op (closed at the end)

    -- PROTECTED. The pause used to be taken here and released 25 lines down with nothing in between to
    -- guarantee we got there. give_out() is called bare from the main loop, so ANY error in the buy or the
    -- trades killed the script with the givers still paused - and an E3 pause lives in E3, not here, so it
    -- survived every AdventureTime restart afterwards. Those toons then look completely healthy: they
    -- report state, they pass the readiness check, they commit, and every /nowcast is silently dropped
    -- while /gsay still works. That is an extremely hard failure to see from the outside, and it cost a
    -- whole evening of chasing the DI staff. Whatever happens in here, E3 gets handed back.
    local ok, err = pcall(function()
    -- BUY: the driver buys everything it owes to hand out (purchasable only), once per item.
    for item, need in pairs(buyNeed) do
        if need > 0 and VENDOR[item] then
            uiStatus = string.format('Buying %d %s from %s...', need, item, VENDOR[item])
            log('buying %d %s from %s', need, item, VENDOR[item])
            buy_from_vendor(VENDOR[item], item, need)
        end
    end

    -- EXECUTE: each giver hands each receiver their WHOLE bundle in one trade.
    for _, g in pairs(plan) do
        if g.name:lower() == myName:lower() or giverUp[g.name:lower()] then   -- skip givers we couldn't bring up (noted above)
            for _, rc in pairs(g.rcv) do
                local desc = {}
                for it, q in pairs(rc.items) do desc[#desc + 1] = string.format('%dx %s', q, it) end
                uiStatus = string.format('%s -> %s (%d item type(s))', g.name, rc.name, #desc)
                log('%s hands %s: %s', g.name, rc.name, table.concat(desc, ', '))
                do_give_bundle(g.name, rc.name, rc.items)
            end
        end
    end
    end)

    group_bags(giverPeers)       -- close the givers' bags back
    group_e3('off', giverPeers)   -- work done - hand the group back to E3
    if not ok then
        log('\\ar[give] the pass errored: %s\\ax', tostring(err))
        log('\\ayE3 has been handed back to everyone anyway - run /atresume if anything still looks stuck.\\ax')
    end

    -- Re-read counts so the status board shows the POST-trade result (verify everyone went green).
    query_all_counts(peers, ITEMS)
    statusCounts = {}
    for _, m in ipairs(roster) do statusCounts[m:lower()] = counts[m:lower()] or {} end
    statusNames = roster

    if #shortfalls == 0 then
        uiStatus = 'Done - everyone topped up.'
        log('Give out complete - everyone at target.')
    else
        uiStatus = string.format('Done - %d shortfall(s), see list.', #shortfalls)
        log('Give out complete with %d shortfall(s).', #shortfalls)
    end
    distributing = false
end

-- Pull EVERYTHING (all tracked items) from every group member onto the toon running this. Great for
-- consolidating before a fresh Give out.
local function collect_all()
    if distributing then return end
    distributing = true
    shortfalls = {}
    local full = group_members()
    if #full <= 1 then uiStatus = 'No group members found (are you grouped and on the network?).'; distributing = false; return end
    local peers = {}
    for _, m in ipairs(full) do if m:lower() ~= myName:lower() then peers[#peers + 1] = m end end

    uiStatus = 'Starting AdventureTime across the group...'
    local up = bring_up_group(peers)
    group_e3('on', up)   -- pause E3 so it can't grab the cursor mid-trade
    group_bags(up)       -- open every giver's bags ONCE for the whole collect
    log('Collect all: pulling everything onto %s', myName)

    local encList = {}
    for _, it in ipairs(ITEMS) do encList[#encList + 1] = enc(it) end
    local listStr = table.concat(encList, ',')

    -- PROTECTED, same reason as give_out: a leaked E3 pause is invisible and permanent.
    local ok, err = pcall(function()
    for _, p in ipairs(up) do
        uiStatus = 'Collecting from ' .. p .. '...'
        log('collecting from %s', p)
        doneReplies[p:lower()] = nil
        peer_cmdf(p, '/at_collect %s %s', myName, listStr)
        wait_done(p, 120000)   -- a full stash can be several trades; give it room
    end
    end)

    group_bags(up)       -- close bags back
    group_e3('off', up)   -- work done - hand the group back to E3
    if not ok then
        log('\\ar[collect] the pass errored: %s\\ax', tostring(err))
        log('\\ayE3 has been handed back to everyone anyway - run /atresume if anything still looks stuck.\\ax')
    end

    -- Re-read counts so the board shows the post-collect result.
    query_all_counts(up, ITEMS)
    statusCounts = {}
    local roster = { myName }
    for _, p in ipairs(up) do roster[#roster + 1] = p end
    for _, m in ipairs(roster) do statusCounts[m:lower()] = counts[m:lower()] or {} end
    statusNames = roster

    uiStatus = 'Collect complete - everything is on ' .. myName .. '.'
    log('Collect complete.')
    distributing = false
end

-- ---------------------------------------------------------------------------
-- UI
-- ---------------------------------------------------------------------------
local function display_name(it)
    -- strip "Draught of ", a leading article, and the trailing tier (the group header carries I/II)
    local n = it:gsub('^Draught of ', ''):gsub('^the ', '')
    return (n:gsub(' II?$', ''))
end

-- Colors: I = blue, II = orange, Orb of Shadows = purple, Emerald = green.
local COL_I    = { 0.45, 0.70, 0.96 }
local COL_II   = { 0.96, 0.62, 0.28 }
local COL_ORB  = { 0.74, 0.55, 0.96 }
local COL_EM   = { 0.50, 0.86, 0.50 }

-- Grouped item lists (organized by tier).
local LIST_I, LIST_II = {}, {}
for _, base in ipairs(DRAUGHTS) do
    LIST_I[#LIST_I + 1]  = base .. ' I'
    LIST_II[#LIST_II + 1] = base .. ' II'
end

local function short_name(n) return (n:sub(1, 7)) end   -- 7: 'Sunetoo' fits, 5 gave 'Sunet'

local function render_group(label, color, items)
    if label then ImGui.TextColored(color[1], color[2], color[3], 1.0, label) end
    -- A COUNT, not a flag. pop_state_button pops n colours, and a boolean here short-circuits to a
    -- no-op - which would leave this table-border push on the stack every frame.
    local pushed = 0
    if ImGuiCol and ImGuiCol.TableBorderStrong then
        local ok = pcall(function()
            ImGui.PushStyleColor(ImGuiCol.TableBorderStrong, color[1], color[2], color[3], 0.75)
        end)
        if ok then pushed = 1 end
    end
    local statusOn = #statusNames > 0   -- shown by default once counts are read
    local nCols = statusOn and (2 + #statusNames) or 2   -- name + [one per toon] + target
    if ImGui.BeginTable('##grp_' .. (label or items[1]), nCols, (ImGuiTableFlags.BordersOuter or 0) + (ImGuiTableFlags.SizingFixedFit or 0)) then
        ImGui.TableSetupColumn('##n', ImGuiTableColumnFlags.WidthFixed or 0, 150)
        if statusOn then
            for _, nm in ipairs(statusNames) do ImGui.TableSetupColumn(short_name(nm), ImGuiTableColumnFlags.WidthFixed or 0, 56) end
        end
        ImGui.TableSetupColumn('##e', ImGuiTableColumnFlags.WidthFixed or 0, 60)
        if statusOn then ImGui.TableHeadersRow() end
        for _, it in ipairs(items) do
            ImGui.TableNextRow()
            ImGui.TableNextColumn()
            ImGui.TextColored(color[1], color[2], color[3], 1.0, display_name(it))
            if VENDOR[it] then ImGui.SameLine(); ImGui.TextDisabled('\xc2\xb7 buy') end
            if statusOn then
                local tgt = target[it] or 0
                for _, nm in ipairs(statusNames) do
                    ImGui.TableNextColumn()
                    local sc = statusCounts[nm:lower()]
                    local c  = (sc and sc.__class) or ''
                    local n  = (sc and sc[it]) or 0
                    local ck = class_key(c)
                    -- '?' not '0'. A count that timed out is UNKNOWN, and showing it as a red zero says
                    -- "this toon has none" - the exact confusion that had 50 emeralds handed to people
                    -- already carrying them. The planner already refuses to act on these; the grid you
                    -- read while deciding should say the same thing.
                    if sc and sc.__unknown and sc.__unknown[it] then
                        ImGui.TextColored(0.95, 0.85, 0.30, 1.0, '?')
                        if ImGui.IsItemHovered and ImGui.IsItemHovered() then
                            pcall(function() ImGui.SetTooltip(nm .. ': count timed out - skipped by Give out') end)
                        end
                    elseif ck and ((is_endurance(it) and not WANTS_ENDURANCE[ck]) or (is_mana(it) and not WANTS_MANA[ck])) then
                        ImGui.TextDisabled(tostring(n))   -- holds this many but won't use them (grey = not needed)
                    elseif n >= tgt then
                        ImGui.TextColored(0.40, 0.82, 0.45, 1.0, tostring(n))
                    else
                        ImGui.TextColored(0.93, 0.42, 0.42, 1.0, tostring(n))
                    end
                end
            end
            ImGui.TableNextColumn()
            ImGui.SetNextItemWidth(-1)
            local v = ImGui.InputInt('##t_' .. it, target[it] or 0, 0)   -- step 0 -> no +/- buttons
            v = math.max(0, math.floor(tonumber(v) or 0))
            if v ~= target[it] then target[it] = v; save_targets() end
        end
        ImGui.EndTable()
    end
    pop_state_button(pushed)
    ImGui.Spacing()
end

local function fmt_favor(n)
    n = tonumber(n) or 0
    if n >= 1000 then return string.format('%.1fk', n / 1000) end
    return tostring(math.floor(n))
end

-- Query each group member's tribute over DanNet (self read directly). CurrentFavor = current favor points;
-- TributeActive = whether tribute is toggled on. Runs from the loop (not render) so the /dquery waits yield.
-- What a peer's staff timer reads RIGHT NOW, counted down from when they sent it. This is why the DI
-- beat had to run every six seconds: the hold compared the raw number, so a report of "90" still said
-- 90 a minute later. Counting down here means the beat only has to carry CHANGES.
function di_peer_staff(st)
    if not st then return nil end
    local base = st.staff
    if base == nil or base < 0 then return base end
    if base == 0 then return 0 end
    local left = base - math.floor((mq.gettime() - (st.updated or 0)) / 1000)
    return (left > 0) and left or 0
end

-- Rebuild the display rows from pushed peer state (+ my own live read). Pure local work - no waiting.
local function rebuild_tribute_rows()
    local rows = {}
    local myAct = mq.TLO.Me.TributeActive()
    tributeState[myName] = {
        active  = (myAct == true) or (tostring(myAct):upper() == 'TRUE'),
        favor   = tonumber(mq.TLO.Me.CurrentFavor()) or 0,
        updated = mq.gettime(),
    }
    for _, nm in ipairs(group_members()) do
        local st = tributeState[nm]
        rows[#rows + 1] = { name = nm, active = st and st.active or false, favor = st and st.favor or 0 }
    end
    tributeRows = rows
end

-- Ask the group to report tribute. Replies land in tributeState via /at_trib - nothing blocks here, so this
-- can run often without stalling the loop (the old version made 10 blocking /dquery calls and hitched rezzes).
local function refresh_tribute()
    rebuild_tribute_rows()
    peer_bcast('/at_tribreq %s', myName)
end

-- The two-line cell grid (used by both the full window and the mini view). Fixed-width cells so the mini
-- (auto-resize) window sizes cleanly.
-- Green 'Turn Tribute On' when THIS character's tribute is off; red 'Turn Tribute Off' when it's on.
-- Click broadcasts /tribute on|off to the whole group so every character flips together.
local function tribute_toggle_button()
    local on = false
    pcall(function() local a = mq.TLO.Me.TributeActive(); on = (a == true) or (tostring(a):upper() == 'TRUE') end)
    local pushed = 0
    if ImGuiCol and ImGuiCol.Button then
        if on then ImGui.PushStyleColor(ImGuiCol.Button, 0.55, 0.18, 0.18, 1.0)
        else       ImGui.PushStyleColor(ImGuiCol.Button, 0.18, 0.48, 0.24, 1.0) end
        pushed = 1
        if ImGuiCol.ButtonHovered then
            if on then ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.68, 0.24, 0.24, 1.0)
            else       ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.24, 0.60, 0.30, 1.0) end
            pushed = 2
        end
    end
    if on then
        if ImGui.Button('Turn Tribute Off') then tributeToggleRequested = 'off' end
    else
        if ImGui.Button('Turn Tribute On') then tributeToggleRequested = 'on' end
    end
    if pushed > 0 then ImGui.PopStyleColor(pushed) end
end

local function draw_tribute_grid()
    ImGui.TextColored(0.55, 0.80, 0.85, 1.0, 'Tribute')
    ImGui.SameLine()
    tribute_toggle_button()
    if #tributeRows == 0 then return end
    local cols = 3
    if ImGui.BeginTable('##at_tribute', cols, (ImGuiTableFlags.Borders or 0) + (ImGuiTableFlags.RowBg or 0)) then
        for c = 1, cols do ImGui.TableSetupColumn('##atc' .. c, ImGuiTableColumnFlags.WidthFixed or 0, 108) end
        for i, r in ipairs(tributeRows) do
            if (i - 1) % cols == 0 then ImGui.TableNextRow() end
            ImGui.TableNextColumn()
            ImGui.Text(r.name)
            ImGui.SameLine()
            if r.active then ImGui.TextColored(0.36, 0.80, 0.46, 1.0, '(ON)')
            else             ImGui.TextColored(0.85, 0.35, 0.35, 1.0, '(OFF)') end
            if (r.favor or 0) < 100000 then
                ImGui.TextColored(0.90, 0.35, 0.35, 1.0, fmt_favor(r.favor))
            else
                ImGui.TextColored(0.72, 0.80, 0.84, 1.0, fmt_favor(r.favor))
            end
        end
        ImGui.EndTable()
    end
end

-- Glyph per kind so the mini view shows WHAT a burn is, not just its state.
-- MQ ships FontAwesome, so use real icons when the module is there and fall back to ASCII when it
-- isn't - no image assets to load and nothing to break on a build without it.
local ICONS_OK, ICO = pcall(require, 'mq.icons')
local BURN_DOT = '#'   -- the dot glyph; ASCII so it renders in any ImGui font. Swap freely.
                       -- Declared HERE, above burn_glyph: it used to sit below, so the 'or BURN_DOT'
                       -- fallback read a nil global and an unknown kind rendered nothing at all.
local BURN_GLYPH, BURN_GLYPH_BY_NAME
if ICONS_OK and type(ICO) == 'table' then
    -- Other item candidates if the hand doesn't land: MD_TOUCH_APP, FA_DIAMOND, MD_DIAMOND,
    -- MD_INVENTORY_2, FA_FLASK, FA_MAGIC, FA_BOLT. Swap the first name on the line.
    BURN_GLYPH = { i = ICO.FA_MAGIC or ICO.MD_AUTO_FIX_HIGH or ICO.FA_DIAMOND or '#',   -- item clicky
                   d = ICO.FA_SHIELD or ICO.MD_SHIELD or '=',              -- discipline
                   a = ICO.FA_BOLT or ICO.MD_BOLT or '*' }                 -- AA / spell
    -- Name overrides beat the kind glyph: a Draught is an item, but a flask says far more.
    BURN_GLYPH_BY_NAME = { { 'Draught', ICO.FA_FLASK or ICO.MD_SCIENCE } }
    -- crown/token glyphs dropped: the mini rez table labels its rows 'Token'/'Crown' as plain text
    -- now, and nothing else ever read them.
else
    BURN_GLYPH = { i = '#', d = '=', a = '*' }
    BURN_GLYPH_BY_NAME = {}
end
-- Glyph for one reported entry: name override first, then the kind.
function burn_glyph(st, itemName)
    for _, ov in ipairs(BURN_GLYPH_BY_NAME or {}) do
        if ov[2] and itemName:find(ov[1], 1, true) then return ov[2] end
    end
    return BURN_GLYPH[st.kind or 'i'] or BURN_DOT
end
-- The tiers actually being reported, ordered, as { key, label } entries. Built from the data rather
-- than a fixed list, so an INI using keys we've never seen still displays.
-- A tier's IDENTITY is the INI KEY, not the worker's numeric rank. parse_burns' rank_for() numbers
-- keys by the order they appear in each character's OWN ini, starting at 1 - so a toon with no
-- 5minBurn reports its 10minBurn as rank 1, and grouping on rank drops those clickies into the
-- 5-minute column. Grouping on tkey keeps every character's 10minBurn in the 10minBurn column and
-- leaves a genuine hole where a character has nothing at that tier.
--
-- ORDER comes from the INIs themselves, not a hardcoded key list. Each character's reported ranks
-- rebuild that character's own [Burn] key order; those partial orders are then MERGED into one
-- sequence consistent with all of them (a topological merge). One toon listing 5min,10min,15min,Long
-- and another listing 10min,Long yields 5min,10min,15min,Long - the second simply has a hole at 5min.
-- No known-key table to maintain, and 'Supercoolburns' lands wherever its ini puts it.
function burn_tiers_present(chars)
    -- 1) Rebuild each character's [Burn] key order from the ranks its worker reported.
    local lists, freq = {}, {}
    for _, c in ipairs(chars) do
        local byRank = {}
        for _, st in pairs(burnState[c] or {}) do
            if (st.tier or 0) > 0 then byRank[st.tier] = st.tkey or '?' end
        end
        local ranks = {}
        for r in pairs(byRank) do ranks[#ranks + 1] = r end
        table.sort(ranks)
        local seq, dup = {}, {}
        for _, r in ipairs(ranks) do
            local k = byRank[r]
            if not dup[k] then dup[k] = true; seq[#seq + 1] = k; freq[k] = (freq[k] or 0) + 1 end
        end
        if #seq > 0 then lists[#lists + 1] = seq end
    end

    -- 2) Merge. Take the head of some character's remaining list that no OTHER character places
    --    later in its own - i.e. nothing left is supposed to come before it. Ties go to the key the
    --    most characters share (the most canonical), then alphabetically, so the result is stable
    --    run to run rather than depending on pairs() order.
    local pos = {}
    for i = 1, #lists do pos[i] = 1 end
    local out, used = {}, {}
    while true do
        local pick
        local function better(k)
            if not pick then return true end
            local fk, fp = freq[k] or 0, freq[pick] or 0
            if fk ~= fp then return fk > fp end
            return k < pick
        end
        for i, seq in ipairs(lists) do
            local k = seq[pos[i]]
            if k then
                local blocked = false
                for j, other in ipairs(lists) do
                    if j ~= i then
                        for p = pos[j] + 1, #other do
                            if other[p] == k then blocked = true; break end
                        end
                        if blocked then break end
                    end
                end
                if not blocked and better(k) then pick = k end
            end
        end
        -- Two INIs genuinely disagree on order (a cycle): every head is blocked. Take the best head
        -- anyway so we always terminate - one of the two orderings has to lose, deterministically.
        if not pick then
            for i, seq in ipairs(lists) do
                local k = seq[pos[i]]
                if k and better(k) then pick = k end
            end
        end
        if not pick then break end
        out[#out + 1] = { key = pick, label = pick }
        used[pick] = true
        -- Advance every list past this key AND past anything already emitted. Skipping only exact
        -- head matches lets the cycle fallback above emit a tier twice: the loser's copy is still
        -- sitting further down another list, and surfaces as a head on a later pass.
        for i, seq in ipairs(lists) do
            while seq[pos[i]] and used[seq[pos[i]]] do pos[i] = pos[i] + 1 end
        end
    end
    return out
end
-- Shared burn helpers (used by both the Burns tab and the mini dot-matrix window).
function burn_remain(st)
    if (st.secs or 0) < 0 then return -1 end
    return math.max(0, (st.secs or 0) - math.floor((mq.gettime() - st.updated) / 1000))
end
-- Sort key: running first, then ready, then soonest. Puts what you can USE at the front.
function burn_rank(st)
    if st.active then return 0, 0 end
    local r = burn_remain(st)
    if r == 0 then return 1, 0 end
    if r < 0 then return 3, 0 end
    return 2, r
end
-- One colour scheme everywhere: cyan running, green ready, then a yellow->orange->red urgency ramp.
function burn_colour(st)
    if st.active then return 0.35, 0.90, 1.00 end
    local r = burn_remain(st)
    if r < 0 then return 0.85, 0.35, 0.35 end
    if r == 0 then return 0.36, 0.80, 0.46 end
    if r < 60 then return 0.95, 0.85, 0.30 end
    if r < 300 then return 0.95, 0.62, 0.25 end
    return 0.85, 0.35, 0.35
end

-- Compact burn view: one row per character, one dot per burn item, colour carries the whole state.
-- No names at all - you read it as a pattern. Hover any dot for the item and its timer.
-- Mini tribute: one line. All on = just 'Tribute ON'; the count only appears when someone ISN'T,
-- so it stays invisible in the normal case and only speaks up when there's something to fix.
local function draw_tribute_mini()
    local on, tot, off = 0, 0, {}
    for _, r in ipairs(tributeRows or {}) do
        tot = tot + 1
        if r.active then on = on + 1 else off[#off + 1] = r.name end
    end
    if tot == 0 then ImGui.TextDisabled('tribute: no data'); return end
    if on == tot then
        ImGui.TextColored(0.36, 0.80, 0.46, 1.0, 'Tribute ON')
    else
        ImGui.TextColored(0.95, 0.62, 0.25, 1.0, string.format('Tribute ON  %d/%d', on, tot))
        if ImGui.IsItemHovered and ImGui.IsItemHovered() then
            pcall(function() ImGui.SetTooltip('off: ' .. table.concat(off, ', ')) end)
        end
    end
end

-- Mini rez: just the crown/token cooldowns. Anyone owning neither is left out entirely - the point
-- is 'who can rez right now', not a full roster.
-- One cooldown cell, shared by the rez rows and the DI staff row so they read identically:
-- '-' when not carried, green 'ready', else the usual yellow -> orange -> red ramp.
function rez_cell(base, updated)
    if (base or -1) < 0 then ImGui.TextDisabled('-'); return end
    local left = math.max(0, base - math.floor((mq.gettime() - (updated or 0)) / 1000))
    if left == 0 then
        ImGui.TextColored(0.36, 0.80, 0.46, 1.0, 'ready')
    else
        local cr, cg, cb
        if left < 60 then      cr, cg, cb = 0.95, 0.85, 0.30
        elseif left < 300 then cr, cg, cb = 0.95, 0.62, 0.25
        else                   cr, cg, cb = 0.85, 0.35, 0.35 end
        ImGui.TextColored(cr, cg, cb, 1.0, string.format('%d:%02d', math.floor(left / 60), left % 60))
    end
end

-- DI staff, kept OUT of the crown/token table so that stays exactly as it was. The tank's save state
-- comes first (it is the thing you actually want to know), then the staff cooldowns underneath.
function draw_di_mini()
    local tank = di_tank()
    if not tank then
        ImGui.TextDisabled('no tank in group')
    else
        local ds = DI.state[tank]
        if not ds then
            ImGui.TextDisabled(tank .. ': no report')
        elseif ds.saveUp == 1 then
            ImGui.TextColored(0.35, 0.90, 1.00, 1.0, tank .. ' has a save')
        else
            ImGui.TextDisabled(tank .. ': no save')
        end
    end

    local cols = {}
    for _, nm in ipairs(rezPriority) do
        local ds = DI.state[nm]
        if ds and (ds.staff or -1) >= 0 then cols[#cols + 1] = nm end
    end
    if #cols == 0 then ImGui.TextDisabled('no DI staff reports'); return end
    local flags = (ImGuiTableFlags.BordersInnerV or 0) + (ImGuiTableFlags.RowBg or 0)
                + (ImGuiTableFlags.SizingFixedFit or 0)
    if not ImGui.BeginTable('##dimini', 1 + #cols, flags) then return end
    ImGui.TableSetupColumn('')
    for _, nm in ipairs(cols) do ImGui.TableSetupColumn(nm:sub(1, 9)) end
    ImGui.TableHeadersRow()
    ImGui.TableNextRow()
    ImGui.TableNextColumn()
    ImGui.TextColored(0.85, 0.72, 0.35, 1.0, 'Staff')
    for _, nm in ipairs(cols) do
        ImGui.TableNextColumn()
        local ds = DI.state[nm]
        rez_cell(ds and ds.staff or -1, ds and ds.updated)
    end
    ImGui.EndTable()
end

-- ---------------------------------------------------------------------------
-- Combos: one button that presses several of the class buttons. Members are stored as typed keys
-- ('mgb:CLR') rather than bare class names so draughts or CoTH can join later without a file format
-- change. Labels are DERIVED from the members - no text box to build, nothing to type, and the label
-- can never drift out of step with what the button actually does.
-- ---------------------------------------------------------------------------
COMBOS = {}
local COMBO_FILE

-- Members are 'mgb:<CLASS>:<abilitykey>' - class AND ability, because a beastlord has two buttons and
-- a combo has to be able to take one without the other.
function combo_parse(m)
    local cls, key = m:match('^mgb:(%u+):(%w+)$')
    if cls then return cls, key end
    return nil
end
function combo_label(c)
    local parts = {}
    for _, m in ipairs(c.members or {}) do
        local cls, key = combo_parse(m)
        local e = key and mgb_entry(key)
        parts[#parts + 1] = (cls and e) and mgb_label(cls, e) or m
    end
    return (#parts > 0) and table.concat(parts, ' + ') or '(empty)'
end

-- Old combos stored just 'mgb:<CLASS>', from when a class had exactly one ability. That mapping is
-- unambiguous looking backwards, so upgrade in place rather than making anyone rebuild their combos.
local LEGACY_MEMBER = { CLR='celestial', DRU='wood', SHM='ancestral',
                        BRD='mercy', ENC='mercy', BST='paragon', RNG='auspice' }
local function combo_migrate(m)
    local cls = m:match('^mgb:(%u+)$')
    if cls and LEGACY_MEMBER[cls] then return 'mgb:' .. cls .. ':' .. LEGACY_MEMBER[cls] end
    return m
end

local function save_combos()
    if not COMBO_FILE then return end
    local fh = io.open(COMBO_FILE, 'w')
    if not fh then return end
    fh:write('; AdventureTime combos - one per line: members separated by commas.\n')
    fh:write('; mgb:<CLASS> presses that class button. Delete a line to remove the combo.\n')
    for _, c in ipairs(COMBOS) do
        if #(c.members or {}) > 0 then fh:write(table.concat(c.members, ',') .. '\n') end
    end
    fh:close()
end

local function load_combos()
    local cfg = ''
    pcall(function() cfg = tostring(mq.TLO.MacroQuest.Path('config')() or '') end)
    COMBO_FILE = (cfg ~= '' and (cfg .. '\\adventuretime_combos.txt')) or 'adventuretime_combos.txt'
    COMBOS = {}
    local fh = io.open(COMBO_FILE, 'r')
    if not fh then return end
    for line in fh:lines() do
        line = line:gsub('^%s+', ''):gsub('%s+$', '')
        if line ~= '' and line:sub(1, 1) ~= ';' then
            local members = {}
            for m in line:gmatch('[^,]+') do
                m = m:gsub('^%s+', ''):gsub('%s+$', '')
                if m ~= '' then members[#members + 1] = combo_migrate(m) end
            end
            if #members > 0 then COMBOS[#COMBOS + 1] = { members = members } end
        end
    end
    fh:close()
end

-- Press every member that is actually in the group. A member for a class nobody is playing is simply
-- skipped rather than being an error - combos are built once and groups change.
function combo_fire(c)
    local fired = 0
    for _, m in ipairs(c.members or {}) do
        local cls, key = combo_parse(m)
        if cls and key then
            for _, nm in ipairs(group_members()) do
                if (member_class(nm) or ''):upper() == cls then
                    if nm:lower() == myName:lower() then mgb_click(key)
                    else peer_cmdf(nm, '/at_mgbclick %s', key) end
                    fired = fired + 1
                    break
                end
            end
        end
    end
    log('[combo] %s - pressed %d', combo_label(c), fired)
end

-- ---------------------------------------------------------------------------
-- Cure clicks. Unlike the MGB buttons these are keyed by OWNERSHIP, not class: anyone holding the AA
-- or the item gets a button, whatever they are. ability_state already resolves item-or-AA, so adding
-- another cure source is one line here and nothing else changes.
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
-- Magic protection clickies. Same ownership-driven shape as the cures - a button appears only for a
-- toon that is actually carrying the item, and vanishes when they are not - but these confer a BUFF,
-- so they also report whether it is currently running. Adding another is one line.
-- ---------------------------------------------------------------------------
-- group = the row it appears under; entries sharing a group share a row, so several ways of getting
-- the same effect read as one thing with several buttons rather than a stack of near-identical rows.
-- Defaults to the label, so an entry that is the only one of its kind needs no group at all.
-- short = only used to tell two sources apart when ONE toon has both.
MAGIC_CLICKS = {
    { key = 'illusionist', label = 'Illusionist Shoes', name = "Forsaken Illusionist's Shoes" },
    { key = 'jaundiced',   label = 'Jaundiced Boots',   name = 'Forsaken Jaundiced Bone Boots' },
    { key = 'echoes',      label = 'Rune of Echoes',    group = 'Echoes', short = 'rune',
      name = 'Imbued Rune of Echoes' },
    -- spell = ... rather than name = ...: this one is a SONG, so "do you have it" means memmed in a
    -- gem, not sitting in a bag. Un-memmed and the button simply is not drawn.
    { key = 'echopast',    label = 'Echoes of the Past', group = 'Echoes', short = 'song',
      spell = 'Echoes of the Past' },
    -- Echoes of the Ancient: the glyph and the song are two ways at the SAME effect, so they share a
    -- group and appear as one row with two buttons rather than two near-identical rows. The glyph is an
    -- item (name =, so ownership means it is in a bag); the song is a spell (spell =, so ownership means
    -- memmed in a gem). A toon carrying neither gets no button at all.
    { key = 'echoancglyph', label = 'Echoes of the Ancient', group = 'Ancient', short = 'glyph',
      name = 'Imbued Glyph: Echoes of the Ancient' },
    { key = 'echoancient',  label = 'Echoes of the Ancient', group = 'Ancient', short = 'song',
      spell = 'Echoes of the Ancient' },
}
magicState = {}   -- driver: magicState[char][key] = { have, secs, up, dsecs, updated }
magicLast  = {}   -- worker: last-pushed key per item

function magic_source(key)
    for _, e in ipairs(MAGIC_CLICKS) do if e.key == key then return e end end
    return nil
end

-- have / recast-remaining / is-it-running / how-much-is-left, for an ITEM or a SPELL.
-- Ownership is deliberately concrete in both cases - the item in my inventory, or the song memmed in a
-- gem - and never routed through ability_state, which falls through to a global Spell[] lookup and
-- would cheerfully report that everyone owns everything.
function magic_state(e)
    if e.spell then
        -- Ask by name first, then fall back to walking the gems and comparing. E3 only ever does the
        -- second - it never asks Me.Gem[spellname] anywhere in its source - which suggests the by-name
        -- form is not dependable across builds. It works here, so keep it as the fast path and let the
        -- scan cover the case where it quietly returns nothing.
        local gem = 0
        pcall(function() gem = tonumber(mq.TLO.Me.Gem(e.spell)()) or 0 end)
        if gem <= 0 then
            for i = 1, 14 do
                local nm = ''
                pcall(function() nm = tostring(mq.TLO.Me.Gem(i).Name() or '') end)
                if nm ~= '' and nm:lower() == e.spell:lower() then gem = i; break end
            end
        end
        if gem <= 0 then return 0, -1, 0, 0 end        -- not memmed: draw nothing
        local rdy = false
        pcall(function()
            local v = mq.TLO.Me.SpellReady(e.spell)()
            rdy = (v == true) or (tostring(v):upper() == 'TRUE')
        end)
        local secs = 0
        if not rdy then
            pcall(function() secs = math.floor(tonumber(mq.TLO.Me.GemTimer(e.spell).TotalSeconds()) or 0) end)
            if secs <= 0 then secs = 1 end             -- not ready but no timer: show as cooling, not ready
        end
        local rem = 0
        pcall(function() rem = tonumber(mq.TLO.Me.Song(e.spell).Duration.TotalSeconds()) or 0 end)
        if rem <= 0 then pcall(function() rem = tonumber(mq.TLO.Me.Buff(e.spell).Duration.TotalSeconds()) or 0 end) end
        return 1, secs, (rem > 0) and 1 or 0, math.floor(rem or 0)
    end

    local itemID = 0
    pcall(function() itemID = tonumber(mq.TLO.FindItem('=' .. e.name).ID()) or 0 end)
    if itemID <= 0 then return 0, -1, 0, 0 end
    local t = 0
    pcall(function() t = tonumber(mq.TLO.FindItem('=' .. e.name).TimerReady()) or 0 end)
    local bn, rem = '', 0
    pcall(function() bn = tostring(mq.TLO.FindItem('=' .. e.name).Spell.Name() or '') end)
    if bn ~= '' and bn ~= 'NULL' then
        pcall(function() rem = tonumber(mq.TLO.Me.Buff(bn).Duration.TotalSeconds()) or 0 end)
        if rem <= 0 then pcall(function() rem = tonumber(mq.TLO.Me.Song(bn).Duration.TotalSeconds()) or 0 end) end
    end
    return 1, (t > 0) and math.floor(t) or 0, (rem > 0) and 1 or 0, math.floor(rem or 0)
end

function magic_click(key)
    local e = magic_source(key)
    if not e then return end
    if e.spell then
        pcall(function() mq.cmdf('/nowcast %s "%s"', myName, e.spell) end)
    else
        pcall(function() mq.cmdf('/nowcast %s "%s/CastType|Item"', myName, e.name) end)
    end
    log('[magic] %s', e.label)
end

CURE_CLICKS = {
    { key = 'radiant', label = 'Radiant Cure',   name = 'Radiant Cure' },
    { key = 'band',    label = 'Cleansing Band', name = 'Cleansing Band of Twilight' },
}
cureState = {}   -- driver: cureState[char][key] = { have, secs, updated }
cureLast  = {}   -- worker: last-pushed key per source

function cure_source(key)
    for _, e in ipairs(CURE_CLICKS) do if e.key == key then return e end end
    return nil
end

-- Do I have this, and can I fire it? have=0 means no button is drawn for me at all.
-- Deliberately NOT routed through ability_state: that function falls through to a Spell[] lookup for
-- disciplines, and Spell['Radiant Cure'].ID resolves out of the GLOBAL spell table - so every
-- character matched and every character got a button. Harmless for burns (a toon only ever asks about
-- entries from its own [Burn] section) but wrong here, where we ask everyone about a fixed list.
-- Only two things count as proof of ownership: the item is in my inventory, or the AA has a rank /
-- reports ready. The AA timer is excluded - it returns 1 for an AA the character does not own.
-- "Do I own this?", asked of every place a thing can live. Lifted from E3, which checks all six before
-- telling you something in your ini does not exist. We were asking only two - an item and an AA - so a
-- cure that happens to be a SPELL, a DISC or a SKILL on some class read as not-mine and no button ever
-- appeared. Cheap enough to ask all six, and it means an entry does not have to declare its own type.
function have_thing(name)
    local checks = {
        function() return tlo_true(mq.TLO.FindItem('=' .. name)()) end,
        function() return (tonumber(mq.TLO.Me.AltAbility(name).Rank()) or 0) > 0 end,
        function() return tlo_true(mq.TLO.Me.Book(name)()) end,
        -- A DISCIPLINE REPORTS ITS INDEX, not true/false. This was wrapped in tlo_true, which only accepts
        -- 1 or TRUE - so every disc that was not sitting at index 1 read as not-owned. Arcane Reprisal was
        -- invisible on all six toons because of this line.
        function() return (tonumber(mq.TLO.Me.CombatAbility(name)()) or 0) > 0 end,
        function() return tlo_true(mq.TLO.Me.Ability(name)()) end,
        function() return tlo_true(mq.TLO.Me.Gem(name)()) end,
    }
    for _, f in ipairs(checks) do
        local ok, got = pcall(f)
        if ok and got then return true end
    end
    return false
end

function cure_state(name)
    local itemID = 0
    pcall(function() itemID = tonumber(mq.TLO.FindItem('=' .. name).ID()) or 0 end)
    if itemID > 0 then
        local t = 0
        pcall(function() t = tonumber(mq.TLO.FindItem('=' .. name).TimerReady()) or 0 end)
        return 1, (t > 0) and math.floor(t) or 0
    end
    local rank, rdy = 0, false
    pcall(function() rank = tonumber(mq.TLO.Me.AltAbility(name).Rank()) or 0 end)
    pcall(function() rdy  = tlo_true(mq.TLO.Me.AltAbilityReady(name)()) end)
    if (rank > 0) or rdy then
        if rdy then return 1, 0 end
        local s = -1
        pcall(function() s = tonumber(mq.TLO.Me.AltAbilityTimer(name).TotalSeconds()) or -1 end)
        return 1, (s and s > 0) and math.floor(s) or 0
    end
    -- Not an item and not an AA - but it may still be mine as a spell, disc or skill. Owned with no
    -- timer we can read is better than invisible: the button appears and simply always looks ready.
    if have_thing(name) then return 1, 0 end
    return 0, -1
end

function cure_click(key)
    local e = cure_source(key)
    if not e then return end
    local isItem = false
    pcall(function() isItem = (tonumber(mq.TLO.FindItem('=' .. e.name).ID()) or 0) > 0 end)
    pcall(function()
        mq.cmdf('/nowcast %s "%s%s"', myName, e.name, isItem and '/CastType|Item' or '')
    end)
    log('[cure] %s', e.label)
end

-- Mini: cures, grouped by source with one button per OWNER. Only characters that actually hold the
-- AA or the item get a button, so the row stays short - a source nobody has draws nothing at all.
-- Button label is just the character name; the source is named once at the head of its row.
-- Mini: magic protection, one row per GROUP with a button per owner across every source in it.
-- Colour is the three states that matter here - CYAN the buff is up, GREEN you can click it, RED it is
-- cooling - rather than the graded ramp the cures use, because there is nothing to weigh up between.
-- Colour the WHOLE button, not just its label. ImGui's default button fill is a mid blue, and putting
-- a red or green label on top of it fights for legibility - red on blue worst of all. A dark tint of
-- the state colour lets the label sit at full strength and the button reads at a glance.
function push_state_button(cr, cg, cb)
    local n = 0
    if not (ImGui.PushStyleColor and ImGuiCol) then return 0 end
    local function try(slot, r, g, b)
        if slot then
            local ok = pcall(function() ImGui.PushStyleColor(slot, r, g, b, 1.0) end)
            if ok then n = n + 1 end
        end
    end
    try(ImGuiCol.Button,        cr * 0.22, cg * 0.22, cb * 0.22)
    try(ImGuiCol.ButtonHovered, cr * 0.38, cg * 0.38, cb * 0.38)
    try(ImGuiCol.ButtonActive,  cr * 0.55, cg * 0.55, cb * 0.55)
    try(ImGuiCol.Text,          cr,        cg,        cb)
    return n
end
function pop_state_button(n)
    if n and n > 0 then pcall(function() ImGui.PopStyleColor(n) end) end
end

function draw_magic_buttons()
    local order, byGroup = {}, {}
    for _, e in ipairs(MAGIC_CLICKS) do
        local g = e.group or e.label
        if not byGroup[g] then byGroup[g] = {}; order[#order + 1] = g end
        table.insert(byGroup[g], e)
    end

    local drewAny = false
    for _, g in ipairs(order) do
        -- Collect every (source, owner) pair in this group first, so we know whether one toon holds
        -- two of them and its buttons need telling apart.
        local btns, perName = {}, {}
        for _, e in ipairs(byGroup[g]) do
            for _, nm in ipairs(group_members()) do
                local st = (magicState[nm] or {})[e.key]
                if st and st.have == 1 then
                    btns[#btns + 1] = { nm = nm, e = e, st = st }
                    perName[nm] = (perName[nm] or 0) + 1
                end
            end
        end
        if #btns > 0 then
            drewAny = true
            ImGui.TextColored(0.85, 0.72, 0.35, 1.0, g)
            for bi, b in ipairs(btns) do
                ImGui.SameLine()
                local age  = math.floor((mq.gettime() - (b.st.updated or 0)) / 1000)
                local left = math.max(0, (b.st.dsecs or 0) - age)
                local r    = b.st.secs or -1
                if r > 0 then r = math.max(0, r - age) end
                local cr, cg, cb, tip
                if b.st.up == 1 and left > 0 then
                    cr, cg, cb = 0.35, 0.90, 1.00
                    tip = string.format('running, %d:%02d left', math.floor(left / 60), left % 60)
                elseif r <= 0 then
                    cr, cg, cb = 0.36, 0.80, 0.46
                    tip = 'ready'
                else
                    cr, cg, cb = 0.85, 0.35, 0.35
                    tip = string.format('cooling, %d:%02d', math.floor(r / 60), r % 60)
                end
                local face = b.nm
                if (perName[b.nm] or 0) > 1 then face = b.nm .. ' ' .. (b.e.short or b.e.key) end
                local pushed = push_state_button(cr, cg, cb)
                if ImGui.SmallButton(face .. '##at_magic_' .. b.e.key .. '_' .. b.nm) then
                    if b.nm:lower() == myName:lower() then magic_click(b.e.key)
                    else peer_cmdf(b.nm, '/at_magic %s', b.e.key) end
                end
                pop_state_button(pushed)
                if ImGui.IsItemHovered and ImGui.IsItemHovered() then
                    pcall(function()
                        ImGui.SetTooltip(string.format('%s - %s\n  %s', b.nm, b.e.label, tip))
                    end)
                end
                if bi == #btns then ImGui.Spacing() end
            end
        end
    end
    if not drewAny then ImGui.TextDisabled('nobody is carrying a magic protection clicky') end
end

function draw_cure_buttons()
    local drewAny = false
    for _, e in ipairs(CURE_CLICKS) do
        local owners = {}
        for _, nm in ipairs(group_members()) do
            local st = (cureState[nm] or {})[e.key]
            if st and st.have == 1 then owners[#owners + 1] = { nm = nm, st = st } end
        end
        if #owners > 0 then
            drewAny = true
            ImGui.TextColored(0.85, 0.72, 0.35, 1.0, e.label)
            for oi, o in ipairs(owners) do
                ImGui.SameLine()
                local r = o.st.secs or -1
                if r > 0 then r = math.max(0, r - math.floor((mq.gettime() - (o.st.updated or 0)) / 1000)) end
                local cr, cg, cb
                if r <= 0 then          cr, cg, cb = 0.36, 0.80, 0.46   -- green: can fire now
                elseif r < 60 then      cr, cg, cb = 0.95, 0.85, 0.30
                elseif r < 300 then     cr, cg, cb = 0.95, 0.62, 0.25
                else                    cr, cg, cb = 0.85, 0.35, 0.35 end
                local pushed = push_state_button(cr, cg, cb)
                if ImGui.SmallButton(o.nm .. '##at_cure_' .. e.key .. '_' .. o.nm) then
                    if o.nm:lower() == myName:lower() then cure_click(e.key)
                    else peer_cmdf(o.nm, '/at_cure %s', e.key) end
                end
                pop_state_button(pushed)
                if ImGui.IsItemHovered and ImGui.IsItemHovered() then
                    pcall(function()
                        ImGui.SetTooltip(string.format('%s - %s\n  %s', o.nm, e.label,
                            (r <= 0) and 'ready' or string.format('%d:%02d', math.floor(r / 60), r % 60)))
                    end)
                end
                if oi == #owners then ImGui.Spacing() end
            end
        end
    end
    if not drewAny then ImGui.TextDisabled('no cure sources in group') end
end

local function draw_rez_mini()
    -- Same shape as the Burns tab: characters across the top, one row per clicky.
    local cols = {}
    for _, nm in ipairs(rezPriority) do
        local rr = rezReady[nm]
        if rr and ((rr.crown or -1) >= 0 or (rr.token or -1) >= 0 or (rr.cotw or -1) >= 0) then cols[#cols + 1] = nm end
    end
    if #cols == 0 then ImGui.TextDisabled('rez: no crown/token reports'); return end
    local flags = (ImGuiTableFlags.BordersInnerV or 0) + (ImGuiTableFlags.RowBg or 0)
                + (ImGuiTableFlags.SizingFixedFit or 0)
    if not ImGui.BeginTable('##rezmini', 1 + #cols, flags) then return end
    ImGui.TableSetupColumn('')
    for _, nm in ipairs(cols) do ImGui.TableSetupColumn(nm:sub(1, 9)) end
    ImGui.TableHeadersRow()
    local function row(which, label)
        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.TextColored(0.85, 0.72, 0.35, 1.0, label)
        for _, nm in ipairs(cols) do
            ImGui.TableNextColumn()
            local rr = rezReady[nm]
            rez_cell(rr and rr[which] or -1, rr and rr.updated)
        end
    end
    -- CotW on top: it fires first, so it reads first. rez_cell already renders -1 as 'doesn't own',
    -- so the melee simply show blank on this row.
    if rezCotw then row('cotw', 'CotW') end
    row('token', 'Token')   -- token first: it's the scarce one, so it burns first
    row('crown', 'Crown')
    ImGui.EndTable()
end

local function draw_burn_dots()
    -- Same order as everywhere else. This built its list from pairs(burnState) and sorted it
    -- alphabetically, so the mini matrix read in a different order from the table right next to it -
    -- and could still show someone who had left the group.
    local chars = {}
    for _, c in ipairs(ordered_members()) do
        if burnState[c] then chars[#chars + 1] = c end
    end
    if #chars == 0 then ImGui.TextDisabled('no burn reports yet'); return end
    -- A TABLE, so every tier starts at the same x for every character - a tier with nothing in it
    -- shows as an empty cell rather than shifting everything after it leftwards.
    -- Only tiers SOMEBODY is using get a column - with eight possible tiers, empty ones would be
    -- most of the grid. (The main tab already skips them the same way.)
    local tiers = burn_tiers_present(chars)
    if #tiers == 0 then ImGui.TextDisabled('no burns configured'); return end
    local flags = (ImGuiTableFlags.BordersInnerV or 0) + (ImGuiTableFlags.RowBg or 0)
                + (ImGuiTableFlags.SizingFixedFit or 0)
    if not ImGui.BeginTable('##burndots', 1 + #tiers, flags) then return end
    ImGui.TableSetupColumn('')
    for _, t in ipairs(tiers) do   -- '5','10','L','S'... short tag from the key itself
        ImGui.TableSetupColumn(t.label:match('^(%d+)') or t.label:sub(1, 1):upper())
    end
    ImGui.TableHeadersRow()
    for _, c in ipairs(chars) do
        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.TextColored(0.70, 0.70, 0.70, 1.0, c:sub(1, 9))
        for _, t in ipairs(tiers) do
            ImGui.TableNextColumn()
            local its = {}
            for it, st in pairs(burnState[c] or {}) do
                if (st.tier or 0) > 0 and (st.tkey or '?') == t.key then its[#its + 1] = it end
            end
            if #its == 0 then
                ImGui.TextDisabled('--')   -- nothing at this tier: hold the slot, don't pull the next one up
            else
                table.sort(its, function(a, b)
                    local oa = burnState[c][a].ord or 0
                    local ob = burnState[c][b].ord or 0
                    if oa ~= ob then return oa < ob end
                    return a < b
                end)
                for i, it in ipairs(its) do
                    local st = burnState[c][it]
                    local cr, cg, cb = burn_colour(st)
                    if i > 1 then ImGui.SameLine(0, 3) end
                    ImGui.TextColored(cr, cg, cb, 1.0, burn_glyph(st, it))
                    if ImGui.IsItemHovered and ImGui.IsItemHovered() then
                        local r = burn_remain(st)
                        local tag = t.label
                        local lbl
                        if st.active then    lbl = string.format('[%s] %s  (running)', tag, it)
                        elseif r == 0 then   lbl = string.format('[%s] %s  ready', tag, it)
                        elseif r < 0 then    lbl = string.format('[%s] %s', tag, it)
                        else                 lbl = string.format('[%s] %s  %d:%02d', tag, it, math.floor(r / 60), r % 60) end
                        pcall(function() ImGui.SetTooltip(lbl) end)
                    end
                end
            end
        end
    end
    ImGui.EndTable()
end

-- The whole Rez tab lives in its own function: render() was over Lua's 60-upvalue limit.
function draw_rez_tab()
            if #rezPriority == 0 then load_rez_priority() end
            if ImGui.BeginTable('##reztabsplit', 2, (ImGuiTableFlags.BordersInnerV or 0)) then
            ImGui.TableSetupColumn('rez');  ImGui.TableSetupColumn('di')
            ImGui.TableNextRow(); ImGui.TableNextColumn()
            do local prev = rezAuto; rezAuto = ImGui.Checkbox('Auto-Rez', rezAuto)
               ImGui.SameLine(); if rezAuto then ImGui.TextColored(0.36,0.80,0.46,1,'ON') else ImGui.TextColored(0.85,0.35,0.35,1,'OFF') end
               if prev ~= rezAuto then
                   save_settings()
                   for _, nm in ipairs(group_members()) do if nm:lower() ~= myName:lower() then peer_cmdf(nm, '/at_rezauto %s', rezAuto and 'on' or 'off') end end
               end
            end
            do local prevA = rezAccept
               rezAccept = ImGui.Checkbox('Auto-accept the rez box', rezAccept)
               if ImGui.IsItemHovered and ImGui.IsItemHovered() then
                   pcall(function() ImGui.SetTooltip(
                       'Clicks the confirmation for you, but only in the 15s after answering a rez\n' ..
                       'handshake - so it never accepts some other dialog. Without it the corpse stays\n' ..
                       'up until a human clicks, and the picker may spend a second clicky on it.') end)
               end
               if prevA ~= rezAccept then
                   save_settings()
                   for _, nm in ipairs(group_members()) do if nm:lower() ~= myName:lower() then peer_cmdf(nm, '/at_rezaccept %s', rezAccept and 'on' or 'off') end end
               end
            end
            do local prevC = rezCotw
               rezCotw = ImGui.Checkbox('Call of the Wild first', rezCotw)
               if ImGui.IsItemHovered and ImGui.IsItemHovered() then
                   pcall(function() ImGui.SetTooltip(
                       'Any shaman or druid holding the CotW AA rezzes BEFORE the clicky order.\\n' ..
                       'The AA is renewable and short-reuse, so it costs nothing a consumable does.\\n' ..
                       'Owning the AA is the class check - nobody else can buy it. Off = clickies only.') end)
               end
               if prevC ~= rezCotw then
                   save_settings()
                   for _, nm in ipairs(group_members()) do if nm:lower() ~= myName:lower() then peer_cmdf(nm, '/at_rezcotw %s', rezCotw and 'on' or 'off') end end
               end
            end
            if rezAuto then ImGui.TextColored(0.55,0.70,0.80,1.0, 'picker: ' .. (rezDebug ~= '' and rezDebug or '(evaluating...)')) end
            ImGui.TextDisabled('Rez priority - the highest reachable dead toon gets rezzed first.')
            if ImGui.SmallButton('Reset to default') then rezPriority = default_rez_priority(); save_rez_priority() end
            ImGui.Spacing()
            for i = 1, #rezPriority do
                local nm = rezPriority[i]
                if ImGui.SmallButton('^##rezup' .. i) then
                    if i > 1 then rezPriority[i], rezPriority[i - 1] = rezPriority[i - 1], rezPriority[i]; save_rez_priority() end
                end
                ImGui.SameLine()
                if ImGui.SmallButton('v##rezdn' .. i) then
                    if i < #rezPriority then rezPriority[i], rezPriority[i + 1] = rezPriority[i + 1], rezPriority[i]; save_rez_priority() end
                end
                ImGui.SameLine()
                ImGui.Text(string.format('%d.  %s', i, nm))
                ImGui.SameLine()
                ImGui.TextDisabled('(' .. member_class(nm) .. ')')
                -- crown/token ownership (from their reported rez items) - green = has it, grey = doesn't
                local rr = rezReady[nm]
                local hasCrown = rr and rr.crown and rr.crown >= 0
                local hasToken = rr and rr.token and rr.token >= 0
                ImGui.SameLine()
                if hasCrown then ImGui.TextColored(0.36, 0.80, 0.46, 1.0, 'crown') else ImGui.TextColored(0.45, 0.45, 0.45, 1.0, 'crown') end
                ImGui.SameLine()
                if hasToken then ImGui.TextColored(0.36, 0.80, 0.46, 1.0, 'token') else ImGui.TextColored(0.45, 0.45, 0.45, 1.0, 'token') end
            end
            -- Rezzer Order: the reorderable slot list that DRIVES the baton. Arrows reorder; unowned slots are hidden.
            -- Green = ready, red + M:SS = on cooldown. Token-before-crown, tank last is just the default - rearrange freely.
            ImGui.Spacing(); ImGui.TextColored(0.85, 0.72, 0.35, 1.0, 'Rezzer Order')
            if #rezOrder == 0 then load_rez_order() end
            -- PINNED, so no arrows: these sit ahead of the list by rule, not by arrangement. Showing them
            -- here anyway matters - the order that actually runs is what you want to be looking at.
            if rezCotw then
                for _, sl in ipairs(rez_chain()) do
                    if sl.clicky ~= 'cotw' then break end
                    local rr = rezReady[sl.name]
                    local secs = (sl.name:lower() == myName:lower()) and my_cotw_secs() or (rr and rr.cotw)
                    ImGui.TextDisabled('pin'); ImGui.SameLine()
                    local label = sl.name .. ' (CotW)'
                    if secs == nil then      ImGui.TextColored(0.70, 0.70, 0.70, 1.0, label)
                    elseif secs == 0 then    ImGui.TextColored(0.36, 0.80, 0.46, 1.0, label)
                    else                     ImGui.TextColored(0.85, 0.35, 0.35, 1.0, string.format('%s  %d:%02d', label, math.floor(secs / 60), secs % 60)) end
                end
            end
            for i = 1, #rezOrder do
                local sl = rezOrder[i]
                local rr = rezReady[sl.name]
                local secs = rr and rr[sl.clicky]
                if not (secs ~= nil and secs < 0) then   -- hide slots the owner is known not to have
                    if ImGui.SmallButton('^##ro' .. i) then if i > 1 then rezOrder[i], rezOrder[i - 1] = rezOrder[i - 1], rezOrder[i]; save_rez_order(); bcast_rez_order() end end
                    ImGui.SameLine()
                    if ImGui.SmallButton('v##ro' .. i) then if i < #rezOrder then rezOrder[i], rezOrder[i + 1] = rezOrder[i + 1], rezOrder[i]; save_rez_order(); bcast_rez_order() end end
                    ImGui.SameLine()
                    local label = string.format('%s (%s)', sl.name, sl.clicky == 'token' and 'Token' or 'Crown')
                    if secs == nil then      ImGui.TextColored(0.70, 0.70, 0.70, 1.0, label)
                    elseif secs == 0 then    ImGui.TextColored(0.36, 0.80, 0.46, 1.0, label)
                    else                     ImGui.TextColored(0.85, 0.35, 0.35, 1.0, string.format('%s  %d:%02d', label, math.floor(secs / 60), secs % 60)) end
                end
            end
            if ImGui.SmallButton('Reset order to default') then rezOrder = default_rez_order(); save_rez_order(); bcast_rez_order() end
            if #rezLog > 0 then
                ImGui.Spacing(); ImGui.TextColored(0.85, 0.72, 0.35, 1.0, 'Recent rezzes')
                for _, l in ipairs(rezLog) do ImGui.TextDisabled(l) end
            end

            ImGui.TableNextColumn()
            draw_di_panel()
            ImGui.EndTable()
            end   -- close the two-column split
            ImGui.EndTabItem()
end

-- Driver: tell every group member to drink, and drink myself. The tier choice happens on each toon
-- (see pot_drink), so this sends one identical message per member and nothing comes back.
function group_pot(key)
    local base, label = pot_base_for(key)
    if not base then return end
    log('[pot] %s', label)
    pot_drink(base)
    for _, nm in ipairs(group_members()) do
        if nm:lower() ~= myName:lower() then peer_cmdf(nm, '/at_pot %s', key) end
    end
end

-- Mini: the two group draught buttons, side by side on one row.
-- Same colour language as the burn dashboard: CYAN = running, GREEN = ready, then the cooldown ramp.
-- The buff is short and the recast is long, so "is it up" is the rare state and "can we click" is the
-- one you actually read most of the time - hence green, not red, once the recast clears with no buff.
-- Toons carrying neither tier are excluded from the counts (and named in the tooltip).
function pot_group_state(key)
    local total, upN, readyN, worst = 0, 0, 0, 0
    local rows, none, unknown = {}, {}, {}
    for _, nm in ipairs(group_members()) do
        local st = (potState[nm] or {})[key]
        if st == nil then
            unknown[#unknown + 1] = nm
        elseif st.carries == 0 then
            none[#none + 1] = nm
        else
            total = total + 1
            local age = math.floor((mq.gettime() - (st.updated or 0)) / 1000)
            if st.up == 1 then
                local b = math.max(0, (st.dsecs or 0) - age)
                upN = upN + 1
                rows[#rows + 1] = string.format('%s  up %d:%02d', nm, math.floor(b / 60), b % 60)
            else
                local r = (st.secs or -1)
                if r > 0 then r = math.max(0, r - age) end
                if r <= 0 then
                    readyN = readyN + 1
                    rows[#rows + 1] = nm .. '  ready'
                else
                    if r > worst then worst = r end
                    rows[#rows + 1] = string.format('%s  %d:%02d', nm, math.floor(r / 60), r % 60)
                end
            end
        end
    end
    return total, upN, readyN, worst, rows, none, unknown
end

-- Mini: one button per healer CLASS present in the group. A class with no AAs configured yet draws
-- nothing, so DRU/SHM stay invisible until their table entries are filled in.
-- Red if anything the press needs is down. MGB only counts while actually raiding - out of raid the
-- press will not use it, so letting it gate the colour would sit the button red all night for a
-- reason that does not apply.
function mgb_button_state(nm, cfg)
    local st = (healState[nm] or {})[cfg.key]
    if not st then return 'unknown', {} end
    local age  = math.floor((mq.gettime() - (st.updated or 0)) / 1000)
    local rows, down = {}, false
    -- gates=false: shown in the tooltip but NOT counted against the colour. MGB out of raid is the
    -- only case - the press will not use it, so it should be visible without turning the button red.
    local function add(label, s, gates, note)
        local txt
        if s < 0 then
            txt = label .. '  not owned'
            if gates then down = true end
        else
            local r = math.max(0, s - age)
            if r > 0 then
                txt = string.format('%s  %d:%02d', label, math.floor(r / 60), r % 60)
                if gates then down = true end
            else
                txt = label .. '  ready'
            end
        end
        rows[#rows + 1] = txt .. (note or '')
    end
    add(MGB_AA, st.mgb or -1, st.raid, st.raid and '' or '   (unused - not in raid)')
    for i, ab in ipairs(cfg.abils) do add(ab, (st.aas or {})[i] or -1, true) end
    return (down and 'down' or 'ready'), rows, st.raid
end

-- Mini: one button per configured combo. Colour is the WORST of its members - green only when every
-- one of them could actually fire, since a green button that half-works is worse than no button.
function draw_combo_buttons()
    local first = true
    for ci, c in ipairs(COMBOS) do
        if #(c.members or {}) > 0 then
            local worst, rows, present = 'ready', {}, 0
            for _, m in ipairs(c.members) do
                local cls, key = combo_parse(m)
                local e = key and mgb_entry(key)
                local who
                if cls then
                    for _, nm in ipairs(group_members()) do
                        if (member_class(nm) or ''):upper() == cls then who = nm; break end
                    end
                end
                if not who or not e then
                    rows[#rows + 1] = ((cls and e) and mgb_label(cls, e) or m) .. '  not in group'
                else
                    present = present + 1
                    local st, srows = mgb_button_state(who, e)
                    if st == 'down' then worst = 'down'
                    elseif st == 'unknown' and worst ~= 'down' then worst = 'unknown' end
                    rows[#rows + 1] = who .. '  (' .. mgb_label(cls, e) .. ')'
                    for _, r in ipairs(srows) do rows[#rows + 1] = '   ' .. r end
                end
            end
            if not first then ImGui.SameLine() end
            first = false
            local cr, cg, cb
            if present == 0        then cr, cg, cb = 0.55, 0.55, 0.55
            elseif worst == 'down' then cr, cg, cb = 0.85, 0.35, 0.35
            elseif worst == 'unknown' then cr, cg, cb = 0.55, 0.55, 0.55
            else                        cr, cg, cb = 0.36, 0.80, 0.46 end
            local pushed = push_state_button(cr, cg, cb)
            if ImGui.SmallButton(combo_label(c) .. '##at_combo_' .. ci) and present > 0 then combo_fire(c) end
            pop_state_button(pushed)
            if ImGui.IsItemHovered and ImGui.IsItemHovered() then
                local lines = { combo_label(c) }
                for _, r in ipairs(rows) do lines[#lines + 1] = '  ' .. r end
                pcall(function() ImGui.SetTooltip(table.concat(lines, '\n')) end)
            end
        end
    end
end

function draw_mgb_buttons()
    -- One button per (character, ability). A beastlord draws two; two toons of the same class each
    -- draw their own, disambiguated by name. Ids are per character AND per ability, because two
    -- widgets sharing an id are treated as one by ImGui and the second click fires the first.
    local seen = {}
    for _, nm in ipairs(group_members()) do
        local c = (member_class(nm) or ''):upper()
        if #mgb_entries_for(c) > 0 then seen[c] = (seen[c] or 0) + 1 end
    end
    local first = true
    for _, nm in ipairs(group_members()) do
        local cls = (member_class(nm) or ''):upper()
        for _, e in ipairs(mgb_entries_for(cls)) do
            if #e.abils > 0 then
                if not first then ImGui.SameLine() end
                first = false
                local label = mgb_label(cls, e) .. ((seen[cls] or 0) > 1 and (' (' .. nm .. ')') or '')
                local state, rows, raiding = mgb_button_state(nm, e)
                local cr, cg, cb
                if state == 'unknown'  then cr, cg, cb = 0.55, 0.55, 0.55
                elseif state == 'down' then cr, cg, cb = 0.85, 0.35, 0.35
                else                        cr, cg, cb = 0.36, 0.80, 0.46 end
                local pushed = push_state_button(cr, cg, cb)
                if ImGui.SmallButton(label .. '##at_mgb_' .. nm .. '_' .. e.key) then
                    if nm:lower() == myName:lower() then mgb_click(e.key)
                    else peer_cmdf(nm, '/at_mgbclick %s', e.key) end
                end
                pop_state_button(pushed)
                if ImGui.IsItemHovered and ImGui.IsItemHovered() then
                    local lines = { string.format('%s  (%s)', nm, raiding and 'raid: MGB + announce' or 'group only') }
                    for _, r in ipairs(rows) do lines[#lines + 1] = '  ' .. r end
                    if state == 'unknown' then lines[#lines + 1] = '  no report yet' end
                    pcall(function() ImGui.SetTooltip(table.concat(lines, '\n')) end)
                end
            end
        end
    end
end

function draw_pot_buttons()
    for i, p in ipairs(GROUP_POTS) do
        if i > 1 then ImGui.SameLine() end
        local total, upN, readyN, worst, rows, none, unknown = pot_group_state(p.key)
        local cr, cg, cb
        if total == 0 then                     cr, cg, cb = 0.55, 0.55, 0.55   -- grey: nothing known / nobody carries any
        elseif #unknown > 0 then               cr, cg, cb = 0.95, 0.85, 0.30   -- yellow: someone has not reported
        elseif upN >= total then               cr, cg, cb = 0.35, 0.90, 1.00   -- cyan: running on everyone
        elseif readyN >= total then            cr, cg, cb = 0.36, 0.80, 0.46   -- green: everyone can click
        elseif worst < 60 then                 cr, cg, cb = 0.95, 0.85, 0.30   -- yellow: about to come up
        elseif worst < 300 then                cr, cg, cb = 0.95, 0.62, 0.25   -- orange
        else                                   cr, cg, cb = 0.85, 0.35, 0.35   -- red: a long way out
        end
        local pushed = push_state_button(cr, cg, cb)
        if ImGui.SmallButton(p.label .. '##at_pot_' .. p.key) then group_pot(p.key) end
        pop_state_button(pushed)
        if ImGui.IsItemHovered and ImGui.IsItemHovered() then
            local lines = { string.format('%s  %d/%d up, %d/%d can click', p.label, upN, total, readyN, total) }
            for _, r in ipairs(rows) do lines[#lines + 1] = '  ' .. r end
            if #unknown > 0 then lines[#lines + 1] = '  no report yet: ' .. table.concat(unknown, ', ') end
            if #none > 0 then lines[#lines + 1] = '  carries none: ' .. table.concat(none, ', ') end
            pcall(function() ImGui.SetTooltip(table.concat(lines, '\n')) end)
        end
    end
end

-- Mini: CoTH gather on its own row. Same toggle the Misc tab uses, so pressing either is the same act.
-- ===== ARCANE REPRISAL =====
-- A melee discipline that answers casters. Presented exactly like the magic-protection clickies: one
-- button per character that actually has it, coloured by state, and clicking fires it on that toon.
-- Detection goes through the ability INDEX. Me.CombatAbility[name] returns where the disc sits in the
-- list, not whether you have it - see the note in have_thing, where wrapping it in tlo_true made every
-- disc past index 1 invisible.
ARCANE = 'Arcane Reprisal'
arcState = {}     -- char -> { have, secs, up, updated }

-- have (0/1), seconds until ready (0 = now), running (0/1)
function arc_state()
    local idx = 0
    pcall(function() idx = tonumber(mq.TLO.Me.CombatAbility(ARCANE)()) or 0 end)
    if idx <= 0 then return 0, -1, 0 end
    local rdy = false
    pcall(function() rdy = tlo_true(mq.TLO.Me.CombatAbilityReady(ARCANE)()) end)
    local secs = 0
    if not rdy then
        pcall(function() secs = math.floor(tonumber(mq.TLO.Me.CombatAbilityTimer(ARCANE).TotalSeconds()) or 0) end)
        if secs <= 0 then secs = 1 end          -- not ready but no timer: show cooling, never "ready"
    end
    local up = false
    pcall(function() up = (tostring(mq.TLO.Me.ActiveDisc.Name() or '') == ARCANE) end)
    return 1, secs, up and 1 or 0
end

-- Fire it. Confirmed working form: /nowcast <name> "Arcane Reprisal", and it needs an NPC target.
-- The caster's OWN target is not good enough - a healer or a bard is usually targeting a groupmate, and
-- the log showed exactly that: "target Stylin". So the mob is resolved locally, on the toon about to
-- cast, and passed as a trailing id the same way the rez passes a corpse and the DI staff passes the tank.
-- Resolved on the CASTER rather than on whoever clicked, so the reading is fresh and local either way.
-- Fire it. That is the whole thing: /nowcast <name> "Arcane Reprisal", confirmed working by hand.
-- No target resolution, no id, no retargeting. This only ever gets used while the melee are already
-- swinging at the mob, so the caster is on it by definition - and an earlier version that hunted through
-- xtargets and juggled targets was solving a problem that only exists out of combat, where you would not
-- be pressing this button anyway.
-- The target is still logged, because if it ever does fail that is the first thing worth seeing.
-- THE GAME'S OWN COMMAND, unquoted: /disc Arcane Reprisal. Confirmed working 2026-07-31.
-- This bypasses E3 entirely, which is why it works where nothing else did - no cast spec to parse, no
-- CastType token to guess at, no argument order to get wrong, and it uses whatever the character already
-- has targeted. Every failure tonight came from routing a discipline through machinery built for items
-- and spells: CastType|Disc (a token I invented), a trailing target id (proven for items, never a disc),
-- and 'me' versus the character name as arg 1.
-- NO QUOTES around the name. The client takes the rest of the line as-is, so quoting makes it hunt for a
-- disc literally called "Arcane Reprisal" with the quote marks - which is almost certainly why an earlier
-- attempt at /disc "..." did nothing and sent this off down the E3 path for another four builds.
ARC_CMD = '/disc %s'

-- Retry state for the disc. Same reasoning as the staff: a melee disc can be interrupted or land on a
-- swing that never connects, and one press should mean "get this up", not "send one command and hope".
-- Driven from the MAIN LOOP, never from the button handler - arc_click is called straight out of an ImGui
-- callback, and anything that yields in there is the documented hard-crash path.
-- Arcane Reprisal is INSTANT, so if it has not gone off in a second and a half it did not go off. The
-- staff waits 12s because it has a 3s cast plus a save that must appear on the tank and be relayed back;
-- none of that applies here, and matching the staff's spacing made a failed press take 9s to notice.
ARC_RETRY_AFTER = 1500
ARC_RETRY_MAX   = 3
arcPending      = nil     -- { at, tries }

function arc_retry_tick()
    if not arcPending then return end
    local have, secs, up = arc_state()
    -- Up, or on cooldown: it went off. Either way we are done.
    if up == 1 or (have == 1 and (secs or 0) > 0) then
        rezlog('[arcane] %s is up', ARCANE)
        arcPending = nil; return
    end
    local age = mq.gettime() - arcPending.at
    if age < ARC_RETRY_AFTER * arcPending.tries then return end
    if arcPending.tries >= ARC_RETRY_MAX then
        -- Same rule as the staff: say what actually happened, not what we attempted.
        pcall(function() mq.cmdf('/gsay %s interrupted %dx - could not get it up', ARCANE, arcPending.tries) end)
        rezlog('\\ay[arcane] %s did not go off after %d tries - giving up\\ax', ARCANE, arcPending.tries)
        arcPending = nil; return
    end
    arcPending.tries = arcPending.tries + 1
    rezlog('[arcane] no sign of it - retry %d of %d', arcPending.tries, ARC_RETRY_MAX)
    pcall(function() mq.cmdf(ARC_CMD, ARCANE) end)
end

function arc_click()
    local tnm, dist = '', -1
    pcall(function() tnm  = tostring(mq.TLO.Target.CleanName() or '') end)
    pcall(function() dist = math.floor(tonumber(mq.TLO.Target.Distance()) or -1) end)
    local cmd = string.format(ARC_CMD, ARCANE)
    -- Distance is logged because range is now a known failure mode rather than a guess.
    log('[arcane] %s   (on %s%s)', cmd, (tnm ~= '' and tnm) or 'no target',
        (dist >= 0) and string.format(' @%dm', dist) or '')
    pcall(function() mq.cmd(cmd) end)
    arcPending = { at = mq.gettime(), tries = 1 }   -- the main loop watches it from here
end

-- ===== PHANTOM LINE (placate) =====
-- A queue rather than a button: the driver clicks a mob to enqueue it, and whoever holds the disc works
-- down the list in order, one at a time, waiting out the 10s recast between casts.
-- WHO CASTS IT is decided by who OWNS it, not by class or name - only the monk has this disc, so "has it"
-- and "is the monk" are the same test, and the ownership version keeps working if a second one shows up.
-- OUT OF RANGE STALLS, it does not skip. The queue is an explicit instruction from a person, and quietly
-- reordering it would mean the mob you clicked first is not the one that gets hit first.
-- THE WHOLE PHANTOM LINE, best first. This started as a hardcoded 'Phantom Whispers', which is the level
-- 71 DoN version - so a monk without it got nothing at all, when the same placate exists seven ways down
-- to level 35. Levels and recasts are read off the client's own discipline list (2026-07-31).
-- RECAST IS PER DISC and is NOT uniform: Whispers recycles in 10s, every older one in 20s. The hardcoded
-- 10000 would have been wrong for six of the seven, letting the queue try again while the disc was still
-- recycling. CombatAbilityReady would have caught it, but only after a wasted attempt.
PHANTOM_LINE = {
    { name = 'Phantom Whispers', level = 71, recast = 10000 },
    { name = 'Phantom Cry',      level = 69, recast = 20000 },
    { name = 'Phantom Shadow',   level = 65, recast = 20000 },
    { name = 'Phantom Call',     level = 64, recast = 20000 },
    { name = 'Phantom Echo',     level = 57, recast = 20000 },
    { name = 'Phantom Wind',     level = 50, recast = 20000 },
    { name = 'Phantom Zephyr',   level = 35, recast = 20000 },
}
pwDisc     = nil    -- the best one THIS character owns, resolved from the list above
pwDiscLook = 0      -- last time we went looking, so a miss is retried rather than cached forever

-- The highest phantom this character actually has. Cached once found; a MISS is only rate-limited, never
-- cached - discs read as absent for a moment after a reload, and caching that would disable the feature
-- for the session on the one toon that can use it.
function pw_disc()
    if pwDisc then return pwDisc end
    local now = mq.gettime()
    if (now - pwDiscLook) < 5000 then return nil end
    pwDiscLook = now
    for _, d in ipairs(PHANTOM_LINE) do
        local idx = 0
        pcall(function() idx = tonumber(mq.TLO.Me.CombatAbility(d.name)()) or 0 end)
        if idx > 0 then
            pwDisc = d
            rezlog('[pw] using %s (level %d, %ds recast) - the best phantom I have', d.name, d.level, d.recast / 1000)
            return pwDisc
        end
    end
    return nil
end

-- Name for display when nothing is resolved yet: the line as a whole, not one member of it.
function pw_label()
    local d = pwDisc
    return d and d.name or 'Phantom'
end
-- RANGE IS ASKED FOR, NOT GUESSED. This started as a flat 50 that turned out to be far too short, which
-- is the same mistake as every hardcoded number in this file - the client knows the answer, so ask it.
-- Mirrors rez_range(), which resolves the clicky's reach from Spell.MyRange and caches it. MyRange rather
-- than Range because it accounts for range-extension focus; a base number would under-report and stall
-- the queue on mobs that are comfortably reachable.
PW_RANGE_FALLBACK = 200  -- only if the TLO gives nothing: the standard cast range, same as DI_MAX_DIST
pwRangeCache = nil
function pw_range()
    if pwRangeCache then return pwRangeCache end
    local d = pw_disc(); if not d then return PW_RANGE_FALLBACK end
    local r = 0
    pcall(function() r = tonumber(mq.TLO.Spell(d.name).MyRange()) or 0 end)
    if r <= 0 then pcall(function() r = tonumber(mq.TLO.Spell(d.name).Range()) or 0 end) end
    if r > 0 then
        pwRangeCache = r
        rezlog('[pw] cast range resolved to %d from %s', r, d.name)
        return r
    end
    return PW_RANGE_FALLBACK   -- not readable yet; assume the usual and ask again next time
end
PW_VERIFY_MS = 2000      -- how long to watch for the debuff before calling a cast lost
PW_RETRY_MAX = 3
-- ENTRIES ARE MARKED, NOT REMOVED. A queue that empties as it works gives you nothing to look at: by the
-- time you glance over, the evidence of what happened is gone. Each mob stays put and changes colour -
-- grey waiting, red out of range, green landed, amber gave up - so the whole sweep is visible at once,
-- and the list only clears a few seconds after the LAST one resolves.
pwQueue = {}             -- { { id, name, oor, state } }  state: nil | 'done' | 'failed'
pwDoneAt = nil           -- when everything finished, for the linger before clearing
-- How long the finished list stays up, and it depends on how much there was to watch. A single mob
-- resolves in one cast - by the time you look up it is already over - so that gets the longer hold.
-- A long queue you have been watching fill in as it goes, and does not need it.
PW_LINGER     = 5000
PW_LINGER_ONE = 10000
pwCast  = nil            -- the attempt in flight: { id, at, tries, prevTarget }
pwLast  = 0              -- when I last got one to land, for the recast gate
pwState = {}             -- char -> true if that toon owns the disc (so the UI can name the holder)

function pw_have() return pw_disc() ~= nil end

function pw_find(id)
    for i, e in ipairs(pwQueue) do if e.id == id then return i, e end end
    return nil
end

-- Is the debuff actually on the mob? Only readable while it is targeted, which it is during a cast.
function pw_on_mob()
    local up = false
    local d = pwDisc; if not d then return false end
    -- CHECK THERE IS A TARGET FIRST. Target.Buff[name].ID() is a two-level walk into the target's buff
    -- table, and with no target the first step is null. The pcall around it is no help - it catches Lua
    -- errors, and a null dereference inside the client is not one; it takes the process down before Lua
    -- hears about it. The only protection is not making the read.
    local tid = 0
    pcall(function() tid = tonumber(mq.TLO.Target.ID()) or 0 end)
    if tid <= 0 then return false end
    pcall(function() up = (tonumber(mq.TLO.Target.Buff(d.name).ID()) or 0) > 0 end)
    return up
end

function pw_spawn_ok(id)
    local ty, hp = '', 0
    pcall(function() ty = tostring(mq.TLO.Spawn(id).Type() or '') end)
    pcall(function() hp = tonumber(mq.TLO.Spawn(id).PctHPs()) or 0 end)
    return ty == 'NPC' and hp > 0
end

function pw_mark(id, state, why)
    local _, e = pw_find(id)
    if not e or e.state then return end
    e.state, e.oor = state, false
    rezlog('[pw] %s - %s', e.name or ('id ' .. id), why)
    pcall(function() peer_bcast('/at_pwmark %d %s', id, state) end)
end

-- Runs on EVERY toon; returns immediately on anyone without the disc. Main loop only - it targets and
-- yields, neither of which belongs anywhere near an ImGui callback.
function pw_tick()
    local disc = pw_disc()
    if not disc then return end

    if pwCast then
        local age = mq.gettime() - pwCast.at
        if pw_on_mob() then
            local _, e = pw_find(pwCast.id)
            rezlog('[pw] landed on %s%s', (e and e.name) or ('id ' .. pwCast.id),
                   (pwCast.tries > 1) and string.format(' (took %d tries)', pwCast.tries) or '')
            pw_mark(pwCast.id, 'done', 'landed')
            if pwCast.prevTarget and pwCast.prevTarget > 0 then
                pcall(function() mq.cmdf('/target id %d', pwCast.prevTarget) end)
            end
            pwLast, pwCast = mq.gettime(), nil
            return
        end
        if age < PW_VERIFY_MS then return end
        if pwCast.tries < PW_RETRY_MAX then
            pwCast.tries = pwCast.tries + 1
            pwCast.at = mq.gettime()
            rezlog('[pw] no sign of it on %s - retry %d of %d', pwCast.name or '?', pwCast.tries, PW_RETRY_MAX)
            pcall(function() mq.cmdf('/disc %s', disc.name) end)
            return
        end
        rezlog('\\ay[pw] gave up on %s after %d tries\\ax', pwCast.name or '?', pwCast.tries)
        pw_mark(pwCast.id, 'failed', 'could not land it')
        if pwCast.prevTarget and pwCast.prevTarget > 0 then
            pcall(function() mq.cmdf('/target id %d', pwCast.prevTarget) end)
        end
        pwLast, pwCast = mq.gettime(), nil
        return
    end

    if #pwQueue == 0 then return end
    if (mq.gettime() - pwLast) < disc.recast then return end
    local rdy = false
    pcall(function() rdy = tlo_true(mq.TLO.Me.CombatAbilityReady(disc.name)()) end)
    if not rdy then return end

    local e
    for _, q in ipairs(pwQueue) do if not q.state then e = q; break end end
    if not e then return end          -- everything resolved; the UI handles the linger and clear
    if not pw_spawn_ok(e.id) then pw_mark(e.id, 'failed', 'dead or gone'); return end

    local dist = 9999
    pcall(function() dist = math.floor(tonumber(mq.TLO.Spawn(e.id).Distance()) or 9999) end)
    local reach = pw_range()
    if dist > reach then
        if not e.oor then
            e.oor = true
            pcall(function() peer_bcast('/at_pwoor %d 1', e.id) end)
            rezlog('[pw] %s is %dm away (reach %d) - holding until we are closer', e.name, dist, reach)
        end
        return                      -- STALL, deliberately. Do not reorder someone's list behind their back.
    end
    if e.oor then
        e.oor = false
        pcall(function() peer_bcast('/at_pwoor %d 0', e.id) end)
    end

    local prev = 0
    pcall(function() prev = tonumber(mq.TLO.Target.ID()) or 0 end)
    pcall(function() mq.cmdf('/target id %d', e.id) end)
    mq.delay(250)
    rezlog('[pw] %s on %s @%dm', disc.name, e.name, dist)
    pcall(function() mq.cmdf('/disc %s', disc.name) end)
    pwCast = { id = e.id, name = e.name, at = mq.gettime(), tries = 1, prevTarget = prev }
end

function draw_phantom()
    local holder = nil
    for _, nm in ipairs(group_members()) do
        if pwState[nm] then holder = nm; break end
    end

    -- Named for the disc that will ACTUALLY be cast, which differs by monk. A button reading "Phantom
    -- Whispers" on a toon that owns Phantom Echo would be quietly lying about what it does.
    -- pwState[holder] carries the disc NAME from a current build, but a peer on an older one reports a
    -- bare true - and concatenating a boolean into the label throws. Take it only when it is a string.
    local lbl = pw_label()
    if holder and type(pwState[holder]) == 'string' then lbl = pwState[holder] end
    if ImGui.Button(lbl .. '##pwadd', 160, 0) then
        local id, nm, ty, hp = 0, '', '', 0
        pcall(function() id = tonumber(mq.TLO.Target.ID()) or 0 end)
        pcall(function() nm = tostring(mq.TLO.Target.CleanName() or '') end)
        pcall(function() ty = tostring(mq.TLO.Target.Type() or '') end)
        pcall(function() hp = tonumber(mq.TLO.Target.PctHPs()) or 0 end)
        if id <= 0 or ty ~= 'NPC' or hp <= 0 then
            log('\\ay[pw] target an NPC first\\ax')
        elseif pw_find(id) then
            log('[pw] %s is already queued', nm)
        else
            pwQueue[#pwQueue + 1] = { id = id, name = nm, oor = false }
            log('[pw] queued %s (%d in the list)', nm, #pwQueue)
            pcall(function() peer_bcast('/at_pwadd %d %s', id, nm:gsub(' ', '_')) end)
        end
    end
    -- Always present, not just when the list has something in it: a control that appears and disappears
    -- is one you have to hunt for, and it moves everything below it when it does.
    ImGui.SameLine()
    if ImGui.SmallButton('Clear list##pwclear') then
        pwQueue, pwDoneAt = {}, nil
        pcall(function() peer_bcast('/at_pwclear') end)
        log('[pw] queue cleared')
    end
    if #pwQueue == 0 then return end
    local pending = 0
    for i, e in ipairs(pwQueue) do
        if not e.state then pending = pending + 1 end
        ImGui.Text(string.format('%d.', i)); ImGui.SameLine()
        local label, tip
        if e.state == 'done' then
            ImGui.TextColored(0.36, 0.85, 0.46, 1.0, e.name .. '  (on)')
            tip = e.name .. '\n' .. pw_label() .. ' is on it'
        elseif e.state == 'failed' then
            ImGui.TextColored(0.90, 0.72, 0.35, 1.0, e.name .. '  (--)')
            tip = e.name .. '\ngave up on this one - dead, gone, or it would not land'
        elseif e.oor then
            ImGui.TextColored(0.90, 0.35, 0.35, 1.0, e.name .. '  (oor)')
            tip = e.name .. '\nout of range - ' .. (holder or 'the holder') .. ' is holding until it is closer'
        else
            ImGui.TextColored(0.80, 0.80, 0.80, 1.0, e.name)
            tip = e.name .. '\nwaiting its turn'
        end
        if ImGui.IsItemHovered and ImGui.IsItemHovered() then
            pcall(function() ImGui.SetTooltip(tip) end)
        end
        ImGui.SameLine()
        if ImGui.SmallButton('x##pwdel' .. i) then
            pcall(function() peer_bcast('/at_pwdel %d', e.id) end)
            table.remove(pwQueue, i)
            break
        end
    end
    -- All resolved: hold the finished list up briefly so the sweep is actually visible, then tidy.
    if pending == 0 and #pwQueue > 0 then
        pwDoneAt = pwDoneAt or mq.gettime()
        local hold = (#pwQueue == 1) and PW_LINGER_ONE or PW_LINGER
        local left = math.max(0, hold - (mq.gettime() - pwDoneAt))
        ImGui.TextDisabled(string.format('all done - clearing in %.0fs', left / 1000))
        if left <= 0 then
            pwQueue, pwDoneAt = {}, nil
            pcall(function() peer_bcast('/at_pwclear') end)
        end
    else
        pwDoneAt = nil
    end
    ImGui.Spacing()
end

function draw_arcane_buttons()
    local btns = {}
    for _, nm in ipairs(group_members()) do
        local st = arcState[nm]
        if st and st.have == 1 then btns[#btns + 1] = { nm = nm, st = st } end
    end
    if #btns == 0 then ImGui.TextDisabled('nobody has ' .. ARCANE); return end
    ImGui.TextColored(0.85, 0.72, 0.35, 1.0, ARCANE)
    for _, b in ipairs(btns) do
        ImGui.SameLine()
        local age = math.floor((mq.gettime() - (b.st.updated or 0)) / 1000)
        local r   = b.st.secs or -1
        if r > 0 then r = math.max(0, r - age) end
        local cr, cg, cb, tip
        if b.st.up == 1 then
            cr, cg, cb, tip = 0.35, 0.90, 1.00, 'running now'
        elseif r <= 0 then
            cr, cg, cb, tip = 0.36, 0.80, 0.46, 'ready'
        else
            cr, cg, cb = 0.85, 0.35, 0.35
            tip = string.format('cooling, %d:%02d', math.floor(r / 60), r % 60)
        end
        local pushed = push_state_button(cr, cg, cb)
        if ImGui.SmallButton(b.nm .. '##at_arc_' .. b.nm) then
            if b.nm:lower() == myName:lower() then arc_click()
            else peer_cmdf(b.nm, '/at_arcane') end
        end
        pop_state_button(pushed)
        if ImGui.IsItemHovered and ImGui.IsItemHovered() then
            pcall(function() ImGui.SetTooltip(string.format('%s - %s\n  %s', b.nm, ARCANE, tip)) end)
        end
    end
    ImGui.Spacing()
end

function draw_coth_mini()
    if COTH.active then
        if ImGui.SmallButton('Stop gather##at_coth_mini') then coth_set(false) end
        ImGui.SameLine(); ImGui.TextColored(0.36, 0.80, 0.46, 1.0, 'on ' .. (coth_anchor() or '?'))
    else
        if ImGui.SmallButton('CoTH Group##at_coth_mini') then coth_set(true) end
    end
end

-- Mini section registry. Order lives in ONE list so it can be reordered in Settings and saved, rather
-- than being baked into the render function - which meant every layout change was a code change.
-- Tribute is not here: it is the mini window's whole identity and stays pinned at the top.
-- get/set CLOSURES, not a _G lookup by name. MQ gives each Lua script its own environment, so _G is
-- NOT this chunk's globals: the checkbox wrote _G.miniPots while save_settings read the real miniPots,
-- two different variables. It looked fine in-session (the checkbox and the render loop agreed with
-- each other) and saved nothing, which is a horrible way to fail. Closures capture the actual upvalue.
MINI_SECTIONS = {
    { key = 'rez',    label = 'Rez',                   draw = draw_rez_mini,
      get = function() return miniRez end,    set = function(v) miniRez = v end },
    { key = 'di',     label = 'DI staff',              draw = draw_di_mini,
      get = function() return miniDI end,     set = function(v) miniDI = v end },
    { key = 'burns',  label = 'Burns',
      draw = function()
          if not miniBurnTable then draw_burn_dots(); return end
          for i, f in ipairs({ 'All', 'Tank', 'DPS', 'Healer' }) do
              if i > 1 then ImGui.SameLine() end
              local on, pushed = (miniBurnFilter == f), 0   -- count, so pop_state_button balances
              if on and ImGuiCol and ImGuiCol.Button then
                  local ok = pcall(function() ImGui.PushStyleColor(ImGuiCol.Button, 0.20, 0.45, 0.70, 1.0) end)
                  if ok then pushed = 1 end
              end
              if ImGui.SmallButton(f .. '##at_mbf_' .. f) and not on then
                  miniBurnFilter = f; save_settings()
              end
              pop_state_button(pushed)
          end
          ImGui.SameLine()
          if ImGui.SmallButton('fit##at_minifit') then miniSizeWanted = true end
          draw_burn_table(miniBurnFilter)
      end,
      get = function() return miniBurns end,  set = function(v) miniBurns = v end },
    { key = 'pots',   label = 'Group draught buttons', draw = draw_pot_buttons,
      get = function() return miniPots end,   set = function(v) miniPots = v end },
    { key = 'mgb',    label = 'Class MGB buttons',     draw = draw_mgb_buttons,
      get = function() return miniClicks end, set = function(v) miniClicks = v end },
    { key = 'combos', label = 'Combo buttons',         draw = draw_combo_buttons,
      get = function() return miniCombos end, set = function(v) miniCombos = v end },
    { key = 'cures',  label = 'Cure buttons',          draw = draw_cure_buttons,
      get = function() return miniCures end,  set = function(v) miniCures = v end },
    { key = 'magic',  label = 'Magic protection',      draw = draw_magic_buttons,
      get = function() return miniMagic end,  set = function(v) miniMagic = v end },
    { key = 'coth',   label = 'CoTH Group button',     draw = draw_coth_mini,
      get = function() return miniCoth end,   set = function(v) miniCoth = v end },
    { key = 'arcane', label = 'Arcane Reprisal',        draw = draw_arcane_buttons,
      get = function() return miniArcane end, set = function(v) miniArcane = v end },
    { key = 'phantom', label = 'Phantom (placate)',     draw = draw_phantom,
      get = function() return miniPhantom end, set = function(v) miniPhantom = v end },
}
miniOrder = {}   -- list of keys, in display order; rebuilt from settings, defaults to the list above
function mini_section(key)
    for _, s in ipairs(MINI_SECTIONS) do if s.key == key then return s end end
    return nil
end
function mini_order_normalise()
    -- Keep only keys we know, then append anything missing. Survives an old settings file that
    -- predates a section, and drops a key from a future one without breaking the list.
    local out, seen = {}, {}
    for _, k in ipairs(miniOrder) do
        if mini_section(k) and not seen[k] then seen[k] = true; out[#out + 1] = k end
    end
    for _, s in ipairs(MINI_SECTIONS) do
        if not seen[s.key] then out[#out + 1] = s.key end
    end
    miniOrder = out
end

-- Bring the group's picture back in step after a membership change. Two halves:
--   NEW characters may not be running the script at all, and even if they are, every report is
--   change-detected - a toon that has been sitting idle has nothing to "change", so it would stay
--   invisible to a driver that has never heard from it until the 120s burn resync came round.
--   DEPARTED characters leave entries in every state table. Mostly harmless because the draws all
--   iterate group_members(), but it keeps stale numbers around to resurface if they rejoin.
function resync_group()
    local inGroup, peers = {}, {}
    for _, nm in ipairs(group_members()) do
        inGroup[nm:lower()] = true
        if nm:lower() ~= myName:lower() then peers[#peers + 1] = nm end
    end
    local function prune(t)
        if type(t) ~= 'table' then return 0 end
        local n = 0
        for k in pairs(t) do
            if type(k) == 'string' and not inGroup[k:lower()] and k:sub(1, 2) ~= '__' then
                t[k] = nil; n = n + 1
            end
        end
        return n
    end
    local dropped = prune(burnState) + prune(potState) + prune(healState) + prune(cureState)
                  + prune(DI.state) + prune(rezReady) + prune(tributeState) + prune(COTH.state)
                  + prune(counts)

    if #peers > 0 then
        bring_up_group(peers)   -- pings first; only launches on toons that do not answer
        for _, nm in ipairs(peers) do
            peer_cmdf(nm, '/at_ping %s', myName)                              -- make sure they know the driver
            peer_cmdf(nm, '/at_rezauto %s', rezAuto and 'on' or 'off')
            peer_cmdf(nm, '/at_diauto %s', DI.auto and 'on' or 'off')
            peer_cmdf(nm, '/at_resync')                                       -- forget change-detection, report all
        end
    end
    log('[sync] %d peer(s) resynced%s', #peers,
        dropped > 0 and string.format(', %d stale entr(ies) dropped', dropped) or '')
end

-- Bring back a group member whose worker has stopped talking - a crash, a manual /lua stop, or a
-- reload that did not take.
-- Detection keys off the UNCONDITIONAL beacons rather than a flat timeout. /at_trib goes out every 15s
-- from every worker no matter what, and the rez and DI heartbeats run at 5-6s idle when their toggles
-- are on - so we know how long silence is actually meaningful, instead of guessing a minute.
-- Two strikes before acting, because a client that is zoning answers nothing either and would
-- otherwise look exactly like a crash.
reviveAt     = {}   -- char -> gettime of the last relaunch attempt (cooldown)
reviveStrike = {}   -- char -> consecutive failed pings
function expected_gap()
    local g = 15000                              -- tribute: unconditional, every worker
    if rezAuto then g = math.min(g, 5000) end    -- rez heartbeat, idle cadence
    if DI.auto then g = math.min(g, 6000) end    -- DI heartbeat, out-of-combat cadence
    return g
end
function revive_check()
    if not SHOW_UI then return end
    local now, limit = mq.gettime(), expected_gap() * 2 + 3000
    for _, nm in ipairs(group_members()) do
        if nm:lower() ~= myName:lower() then
            local last = 0
            for _, t in ipairs({ burnState[nm], potState[nm], healState[nm], cureState[nm],
                                 DI.state[nm], rezReady[nm], tributeState[nm] }) do
                if type(t) == 'table' then
                    if t.updated and t.updated > last then last = t.updated end
                    for _, v in pairs(t) do
                        if type(v) == 'table' and v.updated and v.updated > last then last = v.updated end
                    end
                end
            end
            if (now - last) <= limit then
                reviveStrike[nm] = 0                      -- talking: clear any strikes
            elseif (now - (reviveAt[nm] or 0)) > 120000 then
                alive[nm:lower()] = nil
                peer_cmdf(nm, '/at_ping %s', myName)
                mq.delay(700)
                mq.doevents()
                if alive[nm:lower()] then
                    reviveStrike[nm] = 0                  -- answered: alive, just had nothing to say
                else
                    reviveStrike[nm] = (reviveStrike[nm] or 0) + 1
                    if reviveStrike[nm] >= 2 then
                        reviveStrike[nm] = 0
                        reviveAt[nm] = now
                        peer_cmdf(nm, '/lua run adventuretime worker %s', myName)
                        log('\\ay[sync] %s silent %ds and failed 2 pings - restarting its worker\\ax',
                            nm, math.floor((now - last) / 1000))
                    end
                end
            end
        end
    end
end

-- The detailed burn table, lifted out of the Burns tab so BOTH windows can use it. It only ever
-- existed inline there, which is why mini had to make do with the dot matrix - the detail was not
-- missing, it was just welded to a tab. No behaviour change: this is the same code, moved.
-- Both windows are sizeable now, so the table behaves the same in each: stretch to fill, capped so a
-- single filtered column cannot span the screen. The old `clamp` argument distinguished the mini
-- window back when it was AlwaysAutoResize; it no longer is, so the argument is gone.
function draw_burn_table(filter)
    -- Its OWN filter, not the tab's. Mini is where you sit on DPS all night; the tab is where you go
    -- to look at everyone. Sharing one filter would make each view keep changing the other.
    local flt = filter or burnFilter
        if next(burnState) == nil then
            ImGui.TextDisabled('waiting for reports...')
        else
            -- Driven by GROUP ORDER, not pairs(burnState) sorted alphabetically. Two reasons:
            -- every other panel lists people in group order, and reading the same six names in a
            -- different order here costs you when you are scanning in a hurry; and building from
            -- burnState meant this was the one panel that could still show someone who had left,
            -- until the prune caught up.
            local chars = {}
            for _, c in ipairs(ordered_members()) do
                if burnState[c] and (flt == 'All' or role_of(burnClass[c]) == flt) then
                    chars[#chars + 1] = c
                end
            end
            if #chars == 0 then ImGui.TextDisabled('no ' .. flt .. ' characters reporting') end
            -- Prefix strip only - NO character cap. The measured path below trims to whatever the
            -- column actually is, so an 18-char cap just left the rest of the column blank while still
            -- cutting the name. Without it the name fills the space, which means the column can be
            -- narrower for the same amount of text.
            local function short(nm) return (nm:gsub('^Draught of ', '')) end
            local function shortCap(nm)   -- fallback path only; it cannot measure
                nm = short(nm)
                if #nm > 18 then return nm:sub(1, 17) .. '...' end
                return nm
            end
            -- Seconds left on a report (-1 = permanently down, e.g. a disc with no timer read).
            local remain_of, sort_rank = burn_remain, burn_rank
            -- Name left, timer RIGHT-ALIGNED. The timer owns its space first and the name is trimmed
            -- to whatever is left, so the number can never be clipped by the column edge. No 'ready'
            -- text - green already says that; the right slot stays empty when something is up.
            local function cell(st, it)
                local r = remain_of(st)
                local stamp, cr, cg, cb
                if st.active then
                    -- RUNNING NOW. Deliberately outside the warm yellow/orange/red cooldown ramp -
                    -- active shows a countdown too, so colour alone had to carry the difference.
                    -- The '>' marker is redundancy so it reads without relying on colour at all.
                    cr, cg, cb = 0.35, 0.90, 1.00                          -- cyan
                    local left = (st.dsecs or 0) - math.floor((mq.gettime() - st.updated) / 1000)
                    if (st.dsecs or 0) > 0 and left > 0 then
                        stamp = string.format('>%d:%02d', math.floor(left / 60), left % 60)
                    else
                        stamp = '>run'
                    end
                elseif r < 0 then
                    stamp, cr, cg, cb = '-', 0.85, 0.35, 0.35
                elseif r == 0 then
                    stamp, cr, cg, cb = '', 0.36, 0.80, 0.46               -- green name, nothing on the right
                else
                    stamp = string.format('%d:%02d', math.floor(r / 60), r % 60)
                    if r < 60 then       cr, cg, cb = 0.95, 0.85, 0.30     -- yellow: about to come up
                    elseif r < 300 then  cr, cg, cb = 0.95, 0.62, 0.25     -- orange
                    else                 cr, cg, cb = 0.85, 0.35, 0.35 end -- red: a long way out
                end

                -- Measure so the name gets exactly the leftover width. If this ImGui build doesn't
                -- expose the measuring calls, fall back to the plain inline form.
                local okMeasure, availW, stampW, startX = pcall(function()
                    local aw = ImGui.GetContentRegionAvail()
                    local sw = (stamp ~= '') and ImGui.CalcTextSize(stamp) or 0
                    return aw, sw, ImGui.GetCursorPosX()
                end)
                if not okMeasure or not availW then
                    ImGui.TextColored(cr, cg, cb, 1.0, shortCap(it) .. (stamp ~= '' and ('  ' .. stamp) or ''))
                else
                    local budget = availW - stampW - 10        -- 10px gutter between name and timer
                    -- Trim BEFORE measuring. This measured the raw item name, so short()'s
                    -- 'Draught of ' strip only ever applied in the fallback path below - which
                    -- is why every draught still read 'Draught of Inferno ...' with the useful
                    -- half cut off.
                    local full = short(it)
                    local nm = full
                    local okT = pcall(function()
                        while #nm > 4 and ImGui.CalcTextSize(nm) > budget do nm = nm:sub(1, #nm - 1) end
                    end)
                    if not okT then nm = shortCap(it) end
                    if nm ~= full and #nm > 3 then nm = nm:sub(1, #nm - 3) .. '...' end
                    ImGui.TextColored(cr, cg, cb, 1.0, nm)
                    if stamp ~= '' then
                        ImGui.SameLine()
                        pcall(function() ImGui.SetCursorPosX(startX + availW - stampW) end)
                        ImGui.TextColored(cr, cg, cb, 1.0, stamp)
                    end
                end
                if ImGui.IsItemHovered and ImGui.IsItemHovered() then pcall(function() ImGui.SetTooltip(it) end) end   -- full name on hover
            end
            -- Each character's column flows independently: its own tier headings, its own items,
            -- no blank padding to line up with whoever has the most. Columns size to content.
            -- STRETCH only where there is a width to stretch into. In the mini window (AlwaysAutoResize)
            -- there isn't: stretch columns collapse to their content minimum, the window sizes to that,
            -- and the outer width never gets a say - which is why detailed burns came out no wider than
            -- the dot matrix. Fixed columns give the window an actual number to grow to.
            local tflags = (ImGuiTableFlags.BordersInnerV or 0) + (ImGuiTableFlags.RowBg or 0)
                         + (ImGuiTableFlags.Resizable or 0)
                         + (ImGuiTableFlags.SizingStretchSame or ImGuiTableFlags.SizingStretchProp or 0)
            -- A per-column CEILING, not a target. 190 was a target, so the table stayed 1140 wide no
            -- matter how far you dragged the window and the names stayed truncated. 400 is loose enough
            -- that six columns will always take the whole window, while still stopping a single
            -- filtered column from spanning the screen with its timer stranded at the far edge.
            local wantW = #chars * 400
            local okW, availW2 = pcall(function() return ImGui.GetContentRegionAvail() end)
            if okW and availW2 and availW2 > 0 then wantW = math.min(wantW, availW2) end
            local opened = false
            if #chars > 0 then
                -- The 5-argument form (with an outer size) is not in every ImGui binding, so try
                -- it and fall back. pcall'd carefully: on success the table is ALREADY open, and
                -- calling BeginTable a second time would open a second one we never end.
                local ok, res = pcall(ImGui.BeginTable, '##burns', #chars, tflags, wantW, 0)
                if ok then opened = res and true or false
                else       opened = ImGui.BeginTable('##burns', #chars, tflags) end
            end
            if opened then
                -- Equal real estate: every column the same width. (Weighting them by content
                -- made the widths jump around as names changed, which read worse than a plain grid.)
                for _, c in ipairs(chars) do
                    local ok = pcall(function()
                        ImGui.TableSetupColumn(c, (ImGuiTableColumnFlags.WidthStretch or 0), 1.0)
                    end)
                    if not ok then ImGui.TableSetupColumn(c) end
                end
                ImGui.TableHeadersRow()

                -- rollup row
                ImGui.TableNextRow()
                for _, c in ipairs(chars) do
                    ImGui.TableNextColumn()
                    local rdy, tot = 0, 0
                    for _, st in pairs(burnState[c]) do
                        if (st.tier or 0) > 0 then
                            tot = tot + 1
                            if st.active or burn_remain(st) == 0 then rdy = rdy + 1 end
                        end
                    end
                    local frac = (tot > 0) and (rdy / tot) or 0
                    if frac >= 0.66 then      ImGui.TextColored(0.36, 0.80, 0.46, 1.0, string.format('%d/%d ready', rdy, tot))
                    elseif frac >= 0.33 then  ImGui.TextColored(0.95, 0.62, 0.25, 1.0, string.format('%d/%d ready', rdy, tot))
                    else                      ImGui.TextColored(0.85, 0.35, 0.35, 1.0, string.format('%d/%d ready', rdy, tot)) end
                end

                -- One row per tier, so the tier headings line up across every column and you can
                -- scan sideways. Costs some blank space under short columns - that's the trade
                -- against the free-flowing version, where nothing aligned.
                for _, tinfo in ipairs(burn_tiers_present(chars)) do
                    do
                        -- ONE tier heading, in the first column only. It used to print in every
                        -- column, so a six-character group showed '10minBurn' six times per tier
                        -- - four tiers meant 24 repetitions of text that says nothing new.
                        ImGui.TableNextRow()
                        ImGui.TableNextColumn()
                        ImGui.TextColored(0.85, 0.72, 0.35, 1.0, tinfo.label)
                        ImGui.TableNextRow()
                        for _, c in ipairs(chars) do
                            ImGui.TableNextColumn()
                            local its = {}
                            for it, st in pairs(burnState[c]) do
                                if (st.tier or 0) > 0 and (st.tkey or '?') == tinfo.key then its[#its + 1] = it end
                            end
                            table.sort(its, function(a, b)   -- INI order: a static list that doesn't
                                local oa = burnState[c][a].ord or 0   -- reshuffle as timers tick
                                local ob = burnState[c][b].ord or 0
                                if oa ~= ob then return oa < ob end
                                return a < b
                            end)
                            if #its == 0 then
                                ImGui.TextDisabled('--')   -- nothing at this tier: hold the slot
                            else
                                for _, it in ipairs(its) do cell(burnState[c][it], it) end
                            end
                        end
                    end
                end
                ImGui.EndTable()
            end
        end
end

local function render()
    if not windowOpen then return end
    if miniMode then   -- compact tribute-only window (its own ###id so it keeps its own small size/pos)
        -- AlwaysAutoResize is right for the compact view, and WRONG once the detail burn table is on:
        -- auto-resize will not grow past what the rest of the content wants, and ImGui clamps a table's
        -- outer width to the available region - so the extra columns just got clipped off the edge.
        -- With the table on, the window becomes resizable and scrollable so it can actually be dragged.
        local mflags = (miniBurns and miniBurnTable)
            and 0
            or ((ImGuiWindowFlags.AlwaysAutoResize or 0) + (ImGuiWindowFlags.NoScrollbar or 0))
        -- Fires once per session as well as on the toggle: if detail was ALREADY on at load, the toggle
        -- never runs, and ImGui just restores the small size it remembered from when this was an
        -- auto-resizing window. Two call signatures because bindings differ; a silent pcall failure here
        -- is exactly why the first attempt did nothing.
        if (miniBurns and miniBurnTable) and not miniSizedOnce then
            miniSizedOnce = true; miniSizeWanted = true
        end
        if miniSizeWanted then
            miniSizeWanted = false
            local w, h = mini_table_size()
            local okS = pcall(function() ImGui.SetNextWindowSize(w, h, ImGuiCond.Always or 1) end)
            if not okS then pcall(function() ImGui.SetNextWindowSize(w, h) end) end
        end
        local show = ImGui.Begin('AdventureTime###advtime_mini', windowOpen, mflags)
        windowOpen = show
        if show then
            if ImGui.SmallButton('Expand') then miniMode = false; save_settings() end
            ImGui.SameLine()
            -- The same Close all that sits at the bottom of the expanded window, put where it can be
            -- reached without expanding first. It sets the flag and the MAIN LOOP does the work - the
            -- broadcast and exit must not happen inside an ImGui callback.
            -- Deliberately NOT a new /at_close bind: that name is already the group shutdown, and binding
            -- it again here would have silently replaced it with something that only hides a window.
            if ImGui.SmallButton('Close all##miniclose') then closeAllRequested = true end
            -- The Burns and Rez toggles that used to sit here are gone. They predated Settings owning
            -- section visibility, covered only 2 of the 8 sections, and - the real problem - flipped
            -- the flag WITHOUT saving, so anything set from here reverted on the next restart while
            -- the same box in Settings persisted. One control per setting, and it saves.
            ImGui.Spacing()
            draw_tribute_mini()
            for _, k in ipairs(miniOrder) do
                local sec = mini_section(k)
                if sec and sec.get and sec.get() and sec.draw then
                    ImGui.Spacing(); ImGui.Separator(); ImGui.Spacing()
                    sec.draw()
                end
            end
        end
        ImGui.End()
        return
    end
    ImGui.SetNextWindowSize(560, 500, ImGuiCond.FirstUseEver)
    local show = ImGui.Begin('AdventureTime###advtime', windowOpen)
    windowOpen = show
    if show then
        -- top strip: global controls + the tribute glance (always visible, above the tabs)
        if ImGui.Button('Counts', 70, 0) then refreshRequested = true end   -- the 80-query pass; not cheap
        ImGui.SameLine()
        if ImGui.Button('Mini', 50, 0) then miniMode = true; save_settings() end
        ImGui.SameLine()
        if ImGui.Button('Tank XT', 70, 0) then xtankRequested = true end
        ImGui.SameLine()
        do local prev = autoXTank; autoXTank = ImGui.Checkbox('Auto', autoXTank); if autoXTank and not prev then xtankAutoRequested = true end end
        if #statusNames == 0 then ImGui.SameLine(); ImGui.TextDisabled('reading counts...') end
        if showSec.tribute then ImGui.Spacing(); draw_tribute_grid() end

        ImGui.Spacing()
        if ImGui.BeginTabBar('##at_tabs') then
            if showSec.pots and ImGui.BeginTabItem('Pots') then
                ImGui.TextDisabled('How many each group member should have. Give out tops everyone up.')
                render_group('Draughts I', COL_I, LIST_I)
                render_group('Draughts II', COL_II, LIST_II)
                render_group(nil, COL_ORB, { 'Orb of Shadows' })
                render_group(nil, COL_EM,  { 'Emerald' })
                if distributing then
                    ImGui.TextDisabled('Working...')
                else
                    if ImGui.Button('Give out', 100, 0) then giveRequested = true end
                end
                ImGui.SameLine()
                if ImGui.Button('Collect all', 100, 0) then collectRequested = true end   -- pull everything to this toon
                if uiStatus ~= '' then ImGui.SameLine(); ImGui.TextDisabled(uiStatus) end
                if #shortfalls > 0 then
                    ImGui.Spacing()
                    ImGui.TextColored(0.90, 0.75, 0.35, 1.0, 'Shortfalls')
                    ImGui.BeginChild('##at_short', 0, 90, false)   -- BeginChild/EndChild always paired
                    for _, s in ipairs(shortfalls) do ImGui.TextDisabled(s) end
                    ImGui.EndChild()
                end
                ImGui.EndTabItem()
            end
            if showSec.burns and ImGui.BeginTabItem('Burns') then
                local function fbtn(label, w)
                    local active, pushed = (burnFilter == label), 0   -- count, so pop_state_button balances
                    if active and ImGuiCol and ImGuiCol.Button then
                        local ok = pcall(function() ImGui.PushStyleColor(ImGuiCol.Button, 0.20, 0.45, 0.70, 1.0) end)
                        if ok then pushed = 1 end
                    end
                    if ImGui.Button(label, w or 55, 0) then burnFilter = label end
                    pop_state_button(pushed)
                end
                fbtn('All'); ImGui.SameLine(); fbtn('Tank'); ImGui.SameLine(); fbtn('DPS'); ImGui.SameLine(); fbtn('Healer', 60)
                ImGui.SameLine(); if ImGui.Button('Reload INIs', 90, 0) then burnRefreshRequested = true end
                ImGui.Spacing()
                draw_burn_table()
                ImGui.EndTabItem()
            end
            if showSec.rez and ImGui.BeginTabItem('Rez') then
                draw_rez_tab()
            end
            if showSec.misc and ImGui.BeginTabItem('Misc') then
                if not pcall(draw_misc_tab) then
                    ImGui.TextColored(0.85, 0.35, 0.35, 1.0, 'Misc panel error - see console')
                end
                ImGui.EndTabItem()
            end
            if ImGui.BeginTabItem('Settings') then
                ImGui.Spacing()
                ImGui.TextColored(0.85, 0.72, 0.35, 1.0, 'Sections')
                ImGui.TextDisabled('Turn off anything you do not use - hidden sections stop rendering.')
                ImGui.Spacing()
                local dirty = false
                local function chk(key, label)
                    local prev = showSec[key]
                    showSec[key] = ImGui.Checkbox(label, showSec[key])
                    if prev ~= showSec[key] then dirty = true end
                end
                chk('tribute', 'Tribute panel')
                chk('pots',    'Pots tab')
                chk('burns',   'Burns tab')
                chk('rez',     'Rez tab')
                chk('misc',    'Misc tab')
                ImGui.Spacing(); ImGui.Separator(); ImGui.Spacing()
                ImGui.TextColored(0.85, 0.72, 0.35, 1.0, 'Raid chat')
                ImGui.Spacing()
                do
                    local prev = xtankAnnounce
                    xtankAnnounce = ImGui.Checkbox('/rsay XTarget tank swaps', xtankAnnounce)
                    if xtankAnnounce ~= prev then
                        save_settings()
                        peer_bcast('/at_xtsay %s', xtankAnnounce and 'on' or 'off')
                    end
                end
                -- Auto-Rez and Auto-DI used to be duplicated here. They live on the Rez tab beside the
                -- thing they control, with live ON/OFF state and the picker/tank context around them -
                -- two controls for one flag, under two different names, is just a way to be unsure
                -- which one you last changed.
                ImGui.Spacing(); ImGui.Separator(); ImGui.Spacing()
                ImGui.TextColored(0.85, 0.72, 0.35, 1.0, 'Mini window')
                do
                    -- One row per section: arrows set the order, the checkbox sets visibility. Both
                    -- persist, so the mini window can be laid out without touching the code.
                    for i, k in ipairs(miniOrder) do
                        local sec = mini_section(k)
                        if sec then
                            if ImGui.SmallButton('^##at_up_' .. k) and i > 1 then
                                miniOrder[i], miniOrder[i - 1] = miniOrder[i - 1], miniOrder[i]
                                dirty = true
                            end
                            ImGui.SameLine()
                            if ImGui.SmallButton('v##at_dn_' .. k) and i < #miniOrder then
                                miniOrder[i], miniOrder[i + 1] = miniOrder[i + 1], miniOrder[i]
                                dirty = true
                            end
                            ImGui.SameLine()
                            local was = sec.get() and true or false
                            local now = ImGui.Checkbox(sec.label .. '##at_sec_' .. k, was)
                            if now ~= was then sec.set(now); dirty = true end
                            if k == 'burns' and miniBurns then
                                ImGui.SameLine()
                                local wasT = miniBurnTable and true or false
                                local nowT = ImGui.Checkbox('full detail##at_burntbl', wasT)
                                if nowT ~= wasT then
                                    miniBurnTable = nowT
                                    -- One-shot: give the window a usable size the moment detail goes on,
                                    -- rather than leaving it at whatever the compact view had shrunk to.
                                    if nowT then miniSizeWanted = true end
                                    dirty = true
                                end
                            end
                        end
                    end
                end
                ImGui.Spacing(); ImGui.Separator(); ImGui.Spacing()

                -- Character order: who reads left-to-right in the burn views.
                ImGui.TextColored(0.85, 0.72, 0.35, 1.0, 'Character order')
                ImGui.TextDisabled('Left to right in the burn views.')
                do
                    local ord = ordered_members()
                    for i, nm in ipairs(ord) do
                        if ImGui.SmallButton('^##at_cu_' .. nm) and i > 1 then
                            ord[i], ord[i - 1] = ord[i - 1], ord[i]
                            charOrder = ord; dirty = true
                        end
                        ImGui.SameLine()
                        if ImGui.SmallButton('v##at_cd_' .. nm) and i < #ord then
                            ord[i], ord[i + 1] = ord[i + 1], ord[i]
                            charOrder = ord; dirty = true
                        end
                        ImGui.SameLine()
                        ImGui.Text(string.format('%d. %s', i, nm))
                    end
                    if #ord > 1 and ImGui.SmallButton('Reset to group order##at_cord') then
                        charOrder = {}; dirty = true
                    end
                end
                ImGui.Spacing(); ImGui.Separator(); ImGui.Spacing()

                -- Combo editor. Every configured class is offered, not just the ones grouped right
                -- now, so a combo can be built before the character it needs is online. Members that
                -- are not in the group are simply skipped when the button is pressed.
                ImGui.TextColored(0.85, 0.72, 0.35, 1.0, 'Combos')
                ImGui.TextDisabled('One button that presses several class buttons.')
                -- Only classes actually in the group get a checkbox. The catch: a combo built earlier
                -- can hold a class that has since left, and that member would be invisible here while
                -- still living in the file and still firing. So anything absent is listed below the
                -- checkboxes with its own remove button - offered, but never hidden.
                -- One checkbox per (grouped class, ability) pair, so a beastlord offers Mercy and
                -- Paragon separately. Anything a combo holds whose class has left the group is listed
                -- underneath with its own remove button - offered, but never hidden.
                local opts, inGroup = {}, {}
                for _, nm in ipairs(group_members()) do
                    local cls = (member_class(nm) or ''):upper()
                    if not inGroup[cls] then
                        for _, e in ipairs(mgb_entries_for(cls)) do
                            if #e.abils > 0 then
                                opts[#opts + 1] = { key = 'mgb:' .. cls .. ':' .. e.key,
                                                    label = mgb_label(cls, e), cls = cls }
                            end
                        end
                        inGroup[cls] = true
                    end
                end
                table.sort(opts, function(x, y) return x.label < y.label end)
                if #opts == 0 then
                    ImGui.TextDisabled('No group member has a class with MGB abilities configured.')
                end
                local comboDirty = false
                for ci = #COMBOS, 1, -1 do
                    local c = COMBOS[ci]
                    ImGui.Separator()
                    ImGui.Text(string.format('%d. %s', ci, combo_label(c)))
                    ImGui.SameLine()
                    if ImGui.SmallButton('Delete##at_cdel_' .. ci) then
                        table.remove(COMBOS, ci); comboDirty = true
                    else
                        local has = {}
                        for _, m in ipairs(c.members) do has[m] = true end
                        for oi, opt in ipairs(opts) do
                            if oi > 1 then ImGui.SameLine() end
                            local was = has[opt.key] and true or false
                            local now = ImGui.Checkbox(opt.label .. '##at_c' .. ci .. '_' .. opt.key, was)
                            if now ~= was then
                                if now then
                                    c.members[#c.members + 1] = opt.key
                                else
                                    for k = #c.members, 1, -1 do
                                        if c.members[k] == opt.key then table.remove(c.members, k) end
                                    end
                                end
                                comboDirty = true
                            end
                        end
                        for k = #c.members, 1, -1 do
                            local mcls, mkey = combo_parse(c.members[k])
                            if mcls and not inGroup[mcls] then
                                local me = mgb_entry(mkey)
                                ImGui.TextColored(0.95, 0.85, 0.30, 1.0,
                                    '   ' .. (me and mgb_label(mcls, me) or c.members[k]) .. ' (not in group)')
                                ImGui.SameLine()
                                if ImGui.SmallButton('remove##at_crm_' .. ci .. '_' .. k) then
                                    table.remove(c.members, k); comboDirty = true
                                end
                            end
                        end
                    end
                end
                ImGui.Separator()
                if ImGui.Button('New combo', 110, 0) then
                    COMBOS[#COMBOS + 1] = { members = {} }
                    comboDirty = true
                end
                if comboDirty then save_combos() end

                ImGui.Spacing(); ImGui.Separator(); ImGui.Spacing()
                ImGui.TextDisabled('build ' .. BUILD_TAG)
                if dirty then save_settings() end
                ImGui.EndTabItem()
            end
            ImGui.EndTabBar()
        end

        ImGui.Spacing()
        if ImGui.Button('Close all', 100, 0) then closeAllRequested = true end   -- global: shuts every instance
    end
    ImGui.End()
end

if mq.TLO.Plugin('MQ2DanNet')() then   -- mute DanNet relay spam: localecho = my own '--> (peer)' send lines, commandecho = received-command lines
    pcall(function() mq.cmd('/squelch /dnet localecho off') end)
    pcall(function() mq.cmd('/squelch /dnet commandecho off') end)
end
-- PRIME THE PEER TRANSPORT BEFORE THE UI EXISTS. peer_cmdf detects its channel lazily, and that detection
-- can mq.delay(750) while MQ2DanNet loads. Yielding inside an ImGui callback is a HARD CLIENT CRASH, not a
-- Lua error - and peer_cmdf is reachable from button and checkbox handlers (the auto-rez, auto-accept and
-- Call of the Wild toggles all relay to peers). Until now nothing decided which came first: if the main
-- loop happened to relay something before you touched the window, it was fine; if you clicked first, the
-- delay ran inside the render callback. Do the detection here, on the main thread, where yielding is legal.
pcall(function() peer_cmdf(tostring(mq.TLO.Me.Name() or ''), '/echo') end)
if DI.ladderOff then
    log('\\ar*** CLERIC SAVE LADDER IS OFF *** every save must come from a DI staff. /atladder on to restore.\\ax')
end
if SHOW_UI then mq.imgui.init(scriptName, render) end
pcall(function() mq.bind('/at', function() windowOpen = not windowOpen end) end)
if SHOW_UI then
    log('ready [%s] - \\ay/lua run adventuretime\\ax on each toon; open \\ay/at\\ax here and Give out.', BUILD_TAG)
    log('   \\ay/atcoth\\ax starts the CoTH gather from any toon (\\ay/atcoth off\\ax to stop).')
else
    log('ready [%s] (worker - headless; obeying the driver).', BUILD_TAG)
end
-- DRIVER ONLY. This populates the Pots status columns, which only exist on the driver - but it used to
-- run unconditionally, so all six toons each fired a full peers x items query pass at startup. Six
-- concurrent 80-query passes is 480 queries in a few seconds, and that self-inflicted burst was most
-- of the congestion the pacing above was working around. A worker has no status board to fill.
if SHOW_UI then refreshRequested = true end
DI.startedAt = mq.gettime()   -- clock the settling window from load, not from the first tick

-- Driver only, ONCE at startup: spread a headless worker to each GROUP member so they're present to take
-- commands (tank XTargets, etc.). Not a recurring ping - no pingpong. Counts still come straight from
-- DanNet whether or not they run this; this just lets them ACT on /at_* commands.
-- Startup sanity check: can we actually REACH the rest of the group? A client whose peer network is
-- broken looks completely healthy from the inside - it parses its own INI, renders its own UI, and
-- silently gets nothing from anyone else. Say so loudly instead of leaving it to be diagnosed.
local function check_peer_network()
    local mine = {}
    for _, m in ipairs(group_members()) do if m:lower() ~= myName:lower() then mine[#mine + 1] = m end end
    if #mine == 0 then
        -- Not grouped. Everything here is group-scoped (burns, rez targets, potion counts), so this
        -- looks identical to a broken network from the outside. Say which it is.
        log('\\ayNot in a group - AdventureTime only reports on GROUP members, so nothing will populate.\\ax')
        log('\\ayForm your group in-game, then reload (or hit Refresh on the Burns tab).\\ax')
        return
    end
    local peers = ''
    pcall(function() peers = tostring(mq.TLO.DanNet.Peers() or ''):lower() end)
    -- A DEAD toon is off DanNet while it zones to bind, which looks exactly like a broken network - so
    -- this fired mid-wipe and told the user to go rewrite their MQ2DanNet.ini when nothing was wrong.
    -- A corpse in the zone is proof they are simply dead, not misconfigured.
    local missing, dead = {}, {}
    for _, m in ipairs(mine) do
        if not peers:find(m:lower(), 1, true) then
            if rez_corpse(m) > 0 then dead[#dead + 1] = m else missing[#missing + 1] = m end
        end
    end
    if #dead > 0 then
        log('[net] %s off the network, but dead - that is expected while they zone', table.concat(dead, ', '))
    end
    if #missing == 0 then return end
    log('\\ar*** PEER NETWORK PROBLEM ***\\ax')
    log('\\arCannot see %d of %d group member(s) on DanNet: %s\\ax', #missing, #mine, table.concat(missing, ', '))
    log('\\ayNothing from those characters will arrive - no burns, no rez help, no potion counts.\\ax')
    log('\\ayCheck: /dnet info on each toon. If they only list themselves, they are on separate')
    log('\\ayDanNet islands - fix the Interface setting in MQ2DanNet.ini (config folder) so every')
    log('\\ayclient matches, then FULLY restart them. See the AdventureTime readme.\\ax')
end

load_settings()   -- restore persisted toggles (auto-rez) before we start talking to anyone
load_combos()
mini_order_normalise()   -- fills in defaults / drops unknown keys from a stale settings file
-- The peer check was written and then never wired in, so the one diagnostic aimed at split/broken
-- networks has never run. Deferred rather than immediate: DanNet needs a moment to discover peers,
-- and asking too early reports everyone missing on a perfectly healthy setup.
-- A driver that has just (re)started has EMPTY state tables, while every worker still believes it has
-- already reported - so nothing would ever arrive and the buttons would stay blank forever. Restarting
-- the driver is not a roster change, so resync_group() never fired for it. Ask everyone to speak up.
-- NOT local: this chunk is at Lua's 200-local ceiling and one more tips it over.
driverResyncAt = SHOW_UI and (mq.gettime() + 4000) or 0

local peerCheckAt = mq.gettime() + 12000
if SHOW_UI then
    pcall(function()
        local gpeers = {}
        for _, m in ipairs(group_members()) do if m:lower() ~= myName:lower() then gpeers[#gpeers + 1] = m end end
        if #gpeers > 0 then bring_up_group(gpeers) end
        if rezAuto then   -- restored ON: make sure the workers come up matching, not stuck OFF
            for _, nm in ipairs(group_members()) do if nm:lower() ~= myName:lower() then peer_cmdf(nm, '/at_rezauto on') end end
            log('[rez] auto-rez restored ON from settings')
        end
        if DI.auto then   -- same for DI: the driver restored it from settings, the workers are still OFF
            for _, nm in ipairs(group_members()) do if nm:lower() ~= myName:lower() then peer_cmdf(nm, '/at_diauto on') end end
            log('[di] auto-DI restored ON from settings')
        end
        if #rezOrder == 0 then load_rez_order() end
        bcast_rez_order()   -- driver is the source of truth: hand the shared baton order to everyone at startup
    end)
elseif driverName then
    pcall(function() peer_cmdf(driverName, '/at_rezorder? %s', myName) end)   -- late joiner (e.g. crash relaunch): ask for the live order
end

-- SKIP EVERYTHING WHILE THE CLIENT IS NOT IN A FIT STATE TO BE ASKED. During a zone the client tears
-- down and rebuilds its spawn, buff and inventory structures, and a TLO read landing in that window
-- dereferences pointers that are briefly null. Three minidumps on 2026-08-01 were all the same fault -
-- a null-pointer WRITE inside eqgame.exe, with mq2lua on the live stack in every one - and this group
-- zones constantly because of the CoTH gather.
-- This is a GUESS, and it is the safe kind: skipping a poll costs nothing, because every subsystem here
-- is a poll loop that will simply look again next tick. Nothing is timed off the number of iterations.
-- IMPORTANT, and the reason the existing pcalls have never helped: pcall catches LUA errors. An access
-- violation inside the client is not a Lua error - it takes the whole process down before Lua sees
-- anything. Guarding has to happen BEFORE the read, never around it.
-- GLOBAL, not local: this chunk is at Lua's 200-local ceiling and two more tipped it over.
function client_ready()
    local zoning, state = false, ''
    pcall(function() zoning = tlo_true(mq.TLO.Me.Zoning()) end)
    pcall(function() state  = tostring(mq.TLO.MacroQuest.GameState() or '') end)
    if zoning then return false end
    if state ~= '' and state ~= 'INGAME' then return false end
    return true
end
notReadySince = 0

while running do
    if not client_ready() then
        -- Say so once per stretch rather than every 250ms, and only if it lasts long enough to matter.
        if notReadySince == 0 then notReadySince = mq.gettime()
        elseif (mq.gettime() - notReadySince) > 15000 then
            notReadySince = mq.gettime()
            log('[sync] holding - the client is zoning or not in game')
        end
        mq.delay(250)
        goto continue_tick
    end
    notReadySince = 0
    if closeAllRequested then
        log('Close all - shutting down the group.')
        for _, m in ipairs(group_members()) do
            if m:lower() ~= myName:lower() then peer_cmdf(m, '/at_close') end
        end
        mq.delay(300)   -- let the broadcast go out before we drop
        running = false
        break
    end
    if peerCheckAt > 0 and mq.gettime() >= peerCheckAt then
        peerCheckAt = 0
        pcall(check_peer_network)
    end
    -- Group changed since the last look? Re-test. A peer on ANOTHER machine can drop off DanNet without
    -- leaving the in-game group, and nothing else in here would ever notice - the reports just stop.
    do
        local now = group_members()
        local gk = table.concat(now, ',')
        if gk ~= lastGroupKey then
            local firstLook = (lastGroupKey == nil)
            -- Shut down the worker on anyone who LEFT. Pruning their entries was not enough: they were
            -- still running, still knew the driver name, and their next report put everything straight
            -- back. Ending the script is the honest fix - a worker that is not in the group has nothing
            -- to report to us. Sent by /dex, not /dgge, because they are no longer in the group to
            -- broadcast to. They come back automatically on rejoin via bring_up_group.
            if not firstLook and SHOW_UI then
                local stillHere = {}
                for _, m in ipairs(now) do stillHere[m:lower()] = true end
                for _, m in ipairs(lastGroupList) do
                    if not stillHere[m:lower()] and m:lower() ~= myName:lower() then
                        peer_cmdf(m, '/at_close')
                        log('[sync] %s left the group - closing its worker', m)
                    end
                end
            end
            lastGroupKey  = gk
            lastGroupList = now
            if peerCheckAt == 0 then peerCheckAt = mq.gettime() + 8000 end
            -- Not on the first look: startup already brings the group up, and doing it twice would
            -- fire a second round of pings and launches for no reason.
            if not firstLook and SHOW_UI then resyncAt = mq.gettime() + 3000 end
        end
        if driverResyncAt > 0 and mq.gettime() >= driverResyncAt then
            driverResyncAt = 0
            for _, nm in ipairs(group_members()) do
                if nm:lower() ~= myName:lower() then peer_cmdf(nm, '/at_resync') end
            end
            log('[sync] asked the group to re-report (driver just started)')
        end
        if resyncAt > 0 and mq.gettime() >= resyncAt then
            resyncAt = 0
            pcall(resync_group)
        end
        -- Crash watch every 5s. The per-character gates inside (a silence limit derived from the
        -- beacons, two failed pings, a 2 minute cooldown) are what stop this becoming a launch loop.
        -- REPORT, do not swallow. A bare pcall here hid a nil-index in di_check_landed for eight builds:
        -- every call threw, no verdict ever ran, and any toon that fired the staff was silently locked out
        -- of DI because DI.watch could never be cleared. Rate-limited so a persistent fault says so once a
        -- minute instead of flooding, and it keeps running rather than disabling itself - a broken verdict
        -- is bad, but a DI system that quietly stops is exactly what we could not see.
        pcall(arc_retry_tick)
        pcall(pot_retry_tick)
        pcall(pw_tick)
        if not pwSaidHave and pw_have() then
            pwSaidHave = true
            pwState[myName] = pw_label()
            pcall(function() peer_bcast('/at_pwhave %s %s', myName, pw_label():gsub(' ', '_')) end)
            log('[pw] I have %s - I will work the queue', pw_label())
        end
        do
            local ok, err = pcall(di_check_landed)
            if not ok and (mq.gettime() - (DI.lastCheckErr or 0)) > 60000 then
                DI.lastCheckErr = mq.gettime()
                rezlog('\\ar[di] di_check_landed errored: %s\\ax', tostring(err))
            end
        end
        -- Corpse-keyed tables grow for the life of the session: every body ever targeted leaves an entry in
        -- rezSkip (up to one per slot), rezFirstSeen and rezPending, and nothing ever removed them. Over a
        -- four hour session with repeated wipes that is thousands of live table entries for corpses that
        -- decayed long ago. Corpse ids are also per zone-session, so an old one can collide with a new body
        -- after a zone and hand it a stale skip list. Sweep anything untouched for five minutes.
        if (mq.gettime() - lastCorpseSweep) > 60000 then
            lastCorpseSweep = mq.gettime()
            local cutoff, dropped = mq.gettime() - 300000, 0
            for id, t in pairs(rezSkip) do
                local newest = 0
                for _, exp in pairs(t) do if exp > newest then newest = exp end end
                if newest < cutoff then rezSkip[id] = nil; dropped = dropped + 1 end
            end
            for id, t in pairs(rezFirstSeen) do if t < cutoff then rezFirstSeen[id] = nil end end
            for id, t in pairs(rezPending)   do if t < cutoff then rezPending[id]   = nil end end
            if dropped > 0 then rezdbg(string.format('swept %d retired corpse entr(ies)', dropped)) end
        end
        if SHOW_UI and (mq.gettime() - lastRevive) > 5000 then
            lastRevive = mq.gettime()
            pcall(revive_check)
        end
    end
    if giveRequested and not distributing then
        giveRequested = false
        give_out()   -- runs HERE, not in the ImGui render, so its nav/trade/buy delays can yield
    end
    if collectRequested and not distributing then
        collectRequested = false
        collect_all()
    end
    if refreshRequested and not distributing and SHOW_UI then   -- belt and braces: workers never refresh
        refreshRequested = false
        distributing = true
        uiStatus = 'Reading group counts...'
        local full = group_members()
        local peers = {}
        for _, m in ipairs(full) do if m:lower() ~= myName:lower() then peers[#peers + 1] = m end end
        query_all_counts(peers, ITEMS)   -- DanNet reads counts directly - a refresh never needs to ping or start anyone
        local roster = { myName }
        for _, p in ipairs(peers) do roster[#roster + 1] = p end
        statusCounts = {}
        for _, nm in ipairs(roster) do statusCounts[nm:lower()] = counts[nm:lower()] or {} end
        statusNames = roster
        uiStatus = 'Counts updated.'
        distributing = false
    end
    do   -- timed background jobs: tribute refresh, and (if the toggle's on) auto tank-XTargets. Zone = always.
        local z = mq.TLO.Zone.ID() or 0
        if z ~= lastZoneID then lastZoneID = z; zoneSettleAt = mq.gettime() + 3000 end
        local settled = false
        if zoneSettleAt and mq.gettime() >= zoneSettleAt then zoneSettleAt = nil; settled = true end
        if settled then tributeRequested = true end
        if windowOpen and (mq.gettime() - lastTributePoll) > 15000 then tributeRequested = true end
        if windowOpen then rebuild_tribute_rows() end   -- cheap local rebuild so replies show up as they land
        if autoXTank and iAmHealer then   -- each priest self-maintains; silent, no broadcast
            if settled then xtankAutoRequested = true end
            if xtankRecheckAt and mq.gettime() >= xtankRecheckAt then xtankRecheckAt = nil; xtankAutoRequested = true end   -- event debounce
            if (mq.gettime() - lastXTankPoll) > 60000 then xtankAutoRequested = true end   -- 60s failsafe
        end
    end
    if tributeRequested and not distributing then
        tributeRequested = false          -- no `distributing` here: this is instant now, and claiming that
        refresh_tribute()                 -- flag would stall the rez picker every time it ran
        lastTributePoll = mq.gettime()
    end
    if xtankRequested and not distributing then
        xtankRequested = false
        distributing = true
        uiStatus = 'Setting tank XTargets...'
        trigger_tank_xtargets()
        uiStatus = 'Tank XTargets set.'
        distributing = false
    end
    if xtankAutoRequested and not distributing then
        xtankAutoRequested = false
        set_tank_xtargets(true)   -- just me - every healer runs its own loop; nothing broadcast
        lastXTankPoll = mq.gettime()
    end
    if tributeToggleRequested then
        local mode = tributeToggleRequested
        tributeToggleRequested = nil
        pcall(function() mq.cmdf('/tribute %s', mode) end)   -- /tribute on|off already applies to the whole group
        tributeRequested = true   -- refresh the readout so the button + roster reflect the new state
    end
    if burnRefreshRequested then
        burnRefreshRequested = false
        burnState = {}; burnClass = {}          -- drop the whole table so stale toons/items clear out
        peer_bcast('/at_burnrefresh')
        mq.cmd('/at_burnrefresh')               -- and re-read my own
    end
    -- Burn reports are the ONLY bulk traffic here - everything else is a handful of small, latency-
    -- sensitive messages. So they get their own rate limit rather than sharing the main loop's pace:
    -- 2 per 250ms pass is 8/s per toon, 40/s across the group, and the opening dump is 86 reports.
    -- Slowing them is close to free because the DRIVER counts down locally from `updated` - a late
    -- report delays the first value appearing, not the accuracy of a running timer. A bulk dump
    -- (startup, or Refresh) spreads wider still, since nothing is waiting on it.
    if next(burnPending) ~= nil and not peer_quiet()
       and (mq.gettime() - lastBurnSend) >= (burnQueueLen() > 8 and 600 or 300) then
        lastBurnSend = mq.gettime()
        local sent = 0
        for nm, d in pairs(burnPending) do
            burnPending[nm] = nil
            if driverName then peer_cmdf(driverName, '/at_burn %s %s %d %d %d %d %s %d %s %s', myName, myClass, d.tier, d.secs, d.av, d.dsecs, d.kind or 'i', d.ord or 0, d.tkey or '?', nm)
            else peer_bcast('/at_burn %s %s %d %d %d %d %s %d %s %s', myName, myClass, d.tier, d.secs, d.av, d.dsecs, d.kind or 'i', d.ord or 0, d.tkey or '?', nm) end
            sent = sent + 1
            if sent >= 1 then break end
        end
    end
    -- CHANGE-GATED, like every other reporter here. This was the one push left that went out on a timer
    -- regardless: every worker told the driver its tribute state every 15s whether or not it had moved,
    -- which is five messages a minute per toon carrying a flag and a number that change maybe twice a
    -- session. The read stays on the 15s tick - it is two cheap TLOs - only the SEND is gated.
    -- tribLast is cleared by /at_resync along with the other last-sent tables, so a driver that restarts
    -- still gets a full report rather than silence.
    if driverName and (mq.gettime() - lastTribPush) > 15000 then
        lastTribPush = mq.gettime()
        local a = false; pcall(function() local v = mq.TLO.Me.TributeActive(); a = (v == true) or (tostring(v):upper() == 'TRUE') end)
        local f = 0; pcall(function() f = tonumber(mq.TLO.Me.CurrentFavor()) or 0 end)
        local k = string.format('%d/%d', a and 1 or 0, f)
        if tribLast ~= k then
            tribLast = k
            peer_cmdf(driverName, '/at_trib %s %d %d', myName, a and 1 or 0, f)
        end
    end
    if (mq.gettime() - lastDiscPoll) > 1000 then   -- disc watcher: start/fade log, and catch discs cut short
        lastDiscPoll = mq.gettime()
        local cur = ''
        pcall(function() cur = tostring(mq.TLO.Me.ActiveDisc.Name() or '') end)
        local prev = discWatch and discWatch.name or ''
        if cur ~= prev then
            if prev ~= '' then   -- FADE: elapsed is observed, expected was predicted at activation
                local ran = math.floor((mq.gettime() - discWatch.at) / 1000)
                local exp = math.floor(discWatch.expected or 0)
                if exp > 0 and ran < (exp - 3) then
                    rezlog('[disc] %s faded after %ds (expected %ds) - CUT SHORT by %ds', prev, ran, exp, exp - ran)
                else
                    rezlog('[disc] %s faded after %ds (expected %ds)', prev, ran, exp)
                end
            end
            if cur ~= '' then    -- START: record the duration we predict for it
                local exp = 0
                pcall(function() exp = tonumber(mq.TLO.Spell(cur).MyDuration.TotalSeconds()) or 0 end)
                if exp <= 0 then pcall(function() exp = tonumber(mq.TLO.Spell(cur).Duration.TotalSeconds()) or 0 end) end
                discWatch = { name = cur, at = mq.gettime(), expected = exp }
                rezlog('[disc] %s started (%ds expected)', cur, math.floor(exp))
            else
                discWatch = nil
            end
        end
    end
    -- The BUTTON reporters get their own, much shorter settle. They used to sit behind burnStartAt,
    -- which is 8-16 SECONDS after load and staggered per toon - so cures, magic, draughts and MGB all
    -- trickled in one character at a time and a window opened in the first quarter minute looked half
    -- empty. That delay exists to stop five workers dumping twenty burn items each at once; these are a
    -- handful of messages and do not need it.
    -- SELF-HEAL. Change-detection alone gives a state exactly one chance to be heard: a clicky sitting
    -- ready never changes its key again, so a message lost in flight means that button is missing until
    -- something unrelated forces a resync. Burns have had a 120s re-report for this reason; these had
    -- nothing. Forget what we think we have sent every 90s and say it all again - four or five small
    -- messages a minute and a half, against a button that is silently absent for a whole session.
    if not SHOW_UI and (mq.gettime() - lastClickResync) > 90000 then
        lastClickResync = mq.gettime()
        potLast, healLast, cureLast, magicLast = {}, {}, {}, {}
    end
    if mq.gettime() > clickStartAt and (mq.gettime() - lastClickPoll) > 2000 then
        lastClickPoll = mq.gettime()
        do   -- MGB clicks: one report per ability this class can use (a beastlord has two)
            local hcls = (mq.TLO.Me.Class.ShortName() or ''):upper()
            for _, he in ipairs(mgb_entries_for(hcls)) do
                if #he.abils > 0 then
                    local raiding = (tonumber(mq.TLO.Raid.Members()) or 0) > 0
                    local parts = { tostring(click_secs(MGB_AA)) }
                    for _, ab in ipairs(he.abils) do parts[#parts + 1] = tostring(click_secs(ab)) end
                    local k = he.key .. '/' .. (raiding and 1 or 0) .. '/' .. table.concat(parts, '/')
                    if healLast[he.key] ~= k then   -- only mark sent if it actually went; see magic
                        if SHOW_UI then
                            local sec = {}
                            for i = 2, #parts do sec[#sec + 1] = tonumber(parts[i]) or -1 end
                            healState[myName] = healState[myName] or {}
                            healState[myName][he.key] = { raid = raiding, mgb = tonumber(parts[1]) or -1,
                                                          aas = sec, updated = mq.gettime() }
                            healLast[he.key] = k
                        elseif driverName then
                            peer_cmdf(driverName, '/at_healstate %s %s %d %s', myName, he.key,
                                      raiding and 1 or 0, table.concat(parts, ' '))
                            healLast[he.key] = k
                        end
                    end
                end
            end
        end
        for _, me2 in ipairs(MAGIC_CLICKS) do   -- magic protection: only owners report
            local have, secs, up, dsecs = magic_state(me2)
            local k = have .. '/' .. secs .. '/' .. up .. '/' .. dsecs
            -- Never announce that I do NOT have something. To the driver a missing entry and a "have=0"
            -- entry mean the same thing - no button - so the only report worth sending is one that
            -- follows an earlier yes, telling it to take the button away again.
            if have == 0 and magicLast[me2.key] == nil then magicLast[me2.key] = k end
            -- Only mark it sent if it ACTUALLY went. Updating the key first meant that a poll landing
            -- before the driver had introduced itself recorded a report that never left the building -
            -- and since a stable item never changes its key again, that toon stayed silent for the whole
            -- session and its button simply never appeared.
            if magicLast[me2.key] ~= k then
                if SHOW_UI then
                    magicState[myName] = magicState[myName] or {}
                    magicState[myName][me2.key] = { have = have, secs = secs, up = up, dsecs = dsecs,
                                                    updated = mq.gettime() }
                    magicLast[me2.key] = k
                elseif driverName then
                    peer_cmdf(driverName, '/at_magicstate %s %s %d %d %d %d', myName, me2.key,
                              have, secs, up, dsecs)
                    magicLast[me2.key] = k
                end
            end
        end
        for _, ce in ipairs(CURE_CLICKS) do   -- cures: only owners ever report, so silence means "not mine"
            local have, secs = cure_state(ce.name)
            local k = have .. '/' .. secs
            if have == 0 and cureLast[ce.key] == nil then cureLast[ce.key] = k end   -- see magic, above
            if cureLast[ce.key] ~= k then   -- only mark sent if it actually went; see magic, above
                if SHOW_UI then
                    cureState[myName] = cureState[myName] or {}
                    cureState[myName][ce.key] = { have = have, secs = secs, updated = mq.gettime() }
                    cureLast[ce.key] = k
                elseif driverName then
                    peer_cmdf(driverName, '/at_curestate %s %s %d %d', myName, ce.key, have, secs)
                    cureLast[ce.key] = k
                end
            end
        end
        do
            local have, secs, up = arc_state()
            local k = string.format('%d/%d/%d', have, secs, up)
            if arcLast ~= k then                     -- change-detected, exactly like the pots and cures
                if SHOW_UI then
                    arcState[myName] = { have = have, secs = secs, up = up, updated = mq.gettime() }
                    arcLast = k
                elseif driverName then
                    peer_cmdf(driverName, '/at_arcstate %s %d %d %d', myName, have, secs, up)
                    arcLast = k
                end
            end
        end
        for _, gp in ipairs(GROUP_POTS) do
            local carries, up, secs, dsecs = pot_state(gp.base)
            local k = string.format('%d/%d/%d/%d', carries, up, secs, dsecs)
            if potLast[gp.key] ~= k then   -- only mark sent if it actually went; see magic
                if SHOW_UI then
                    potState[myName] = potState[myName] or {}
                    potState[myName][gp.key] = { carries = carries, up = up, secs = secs, dsecs = dsecs, updated = mq.gettime() }
                    potLast[gp.key] = k
                elseif driverName then
                    peer_cmdf(driverName, '/at_potstate %s %s %d %d %d %d', myName, gp.key, carries, up, secs, dsecs)
                    potLast[gp.key] = k
                end
            end
        end
    end
    if mq.gettime() > burnStartAt and (mq.gettime() - lastBurnResync) > 120000 then
        lastBurnResync = mq.gettime()   -- periodic re-sync: forget last-sent state so everything reports again
        if not SHOW_UI then burnLast = {} end
    end
    if burnPollOn and mq.gettime() > burnStartAt and (mq.gettime() - lastBurnPoll) > 2000 then   -- read MY watched item timers locally (cheap), push changes
        lastBurnPoll = mq.gettime()
        -- Group draughts ride the same local poll. secs/dsecs are LATCHED values, not live countdowns,
        -- so the key only moves when the state genuinely flips - one push on drink, one on fall-off.
        -- The driver counts down from `updated` itself, exactly like burn_remain does.
        for _ord, entry in ipairs(BURN_WATCH) do
            local name, tier = entry.name, entry.tier
            local have, ready, secs, active, dsecs, kind = ability_state(name)
            local ord = _ord
            if have then
                local key = (ready and 'R' or 'd') .. (active and 'A' or '-') .. tostring(dsecs or 0)
                local prev = burnLast[name]
                if prev == nil or prev ~= key then   -- report on ready<->down OR active<->inactive flip
                    burnLast[name] = key
                    if SHOW_UI then   -- I'm the driver: update my own table directly, no network
                        burnClass[myName] = myClass
                        burnState[myName] = burnState[myName] or {}
                        burnState[myName][name] = { tier = tier, secs = secs, active = active, dsecs = dsecs or 0, kind = kind, ord = ord, tkey = (entry.tkey or '?'), updated = mq.gettime() }
                    else              -- queue it; the drain below spreads the burst over a second or so
                        burnPending[name] = { tier = tier, secs = secs, av = (active and 1 or 0), dsecs = math.floor(dsecs or 0), kind = kind, ord = ord, tkey = ((entry.tkey or '?'):gsub(' ', '~')) }   -- '~' so 'Quick Burn' survives arg splitting
                    end
                end
            end
        end
    end
    if COTH.active and not distributing and (mq.gettime() - COTH.lastPush) > 1000 then
        COTH.lastPush = mq.gettime()
        local e, d, l = coth_read_self()
        COTH.state[myName] = { emblem = e, dist = d, los = l, updated = mq.gettime() }
        peer_bcast('/at_coth %s %d %d %d', myName, e, d, l)
    end
    if COTH.active and not distributing and (mq.gettime() - COTH.lastPoll) > 1000 then
        COTH.lastPoll = mq.gettime()
        local ok, err = pcall(coth_tick)
        if not ok then COTH.active = false; log('\\ar[coth] stopped after an error: %s\\ax', tostring(err)) end
    end
    -- REPORTING is not gated on `distributing`; only acting is. A counts pass or a give-out sets that
    -- flag for the better part of ten seconds, and the driver here IS the tank - so the one character
    -- whose save state everyone needs went silent exactly while it was busy, and every peer fell back
    -- to firing blind. Casting the staff mid-trade is worth preventing; saying "I already have a save"
    -- is one small broadcast and always worth sending.
    if not DI.auto and not DI.saidOff then
        DI.saidOff = true
        rezlog('[di] auto-DI is OFF here - I will not report my staff or save state to the group')
    end
    if DI.auto then
        DI.saidOff = false
        local ic = false
        pcall(function() ic = (tostring(mq.TLO.Me.CombatState() or ''):upper() == 'COMBAT') end)
        if ic ~= HB.diFast then HB.diFast = ic; DI.lastPush = 0 end   -- edge -> push now
        -- 6000 not 20000: the cleric-DG hold only trusts a report < 8000ms old. A cleric that has
        -- not taken aggro is not COMBAT-flagged, so it would sit on the slow tick and read as
        -- stale - and the staff would fire early believing no DG source is left.
        -- OUT OF COMBAT, READ THIS FOUR TIMES SLOWER. di_read_self is not cheap: three Me.Buff name
        -- lookups for the save flags, plus the staff timers, the emerald count, the DG rank and the
        -- boots - roughly fifteen TLO reads, and it ran on every 250ms tick regardless of state.
        -- The push it feeds is gated to 4s in combat and 20s idle, so out of combat we were reading
        -- eighty times more often than we could ever send. And di_tick itself early-returns when not
        -- in combat, so nothing local consumed the extra freshness either.
        -- In combat the rate is untouched: a save being consumed is exactly the discontinuity that
        -- needs to reach the group immediately, and a change pushes the instant it is seen.
        -- 1000ms idle is still eight times fresher than the 8s staleness window the cleric-DG hold
        -- trusts, so the hold cannot start reading stale reports because of this.
        DI.selfGap = ic and 250 or 1000
        if (mq.gettime() - (DI.lastSelfRead or 0)) < DI.selfGap then goto di_read_done end
        DI.lastSelfRead = mq.gettime()
        local a, b, c, d, e = di_read_self()   -- e = the save's NAME; dropping it left the wire arg nil
        -- MY STAFF CAME BACK - SAY SO, AND THE BATON COMES HOME. The ring should sit as far forward as it
        -- can, so the earliest toon with a ready staff is the natural holder. Announcing on the edge means
        -- nobody polls anybody: the one toon that knows says it once. It also means the baton can never go
        -- stale, because every returning staff pulls it forward again without any timer watching for it.
        -- Deliberately unguarded beyond this. The worst outcome of getting it wrong is that somebody fires
        -- their staff out of turn, which costs one charge - far cheaper than another layer of coordination.
        if a == 0 and DI.staffWasSpent then
            DI.staffWasSpent = false
            DI.saidStaffDown = false                -- re-arm the one-shot pass for the next cooldown
            peer_bcast('/at_dibatonback %s', myName)
            di_baton_back(myName)                   -- and apply it locally, same rule
        elseif a > 0 then
            DI.staffWasSpent = true
            -- GIVE IT UP THE MOMENT MY STAFF IS DOWN, not when a save is finally needed. The commit path
            -- also passes, but that only runs once the tank is already in trouble - so the ring would walk
            -- itself forward a position per tick in the middle of the emergency it exists to handle. Doing
            -- it here keeps the holder correct at all times, so the first toon asked can actually act.
            -- ON THE EDGE ONLY. This branch runs on every poll while the staff is down, so an unconditional
            -- pass here fired once per poll for as long as the cooldown lasted - which, once the baton had
            -- gone round the ring and come back, never stopped.
            -- NOT WHILE MY OWN CAST IS STILL UNDECIDED. Passing the baton the instant the staff goes down
            -- hands the turn to the next toon before anyone knows whether this cast worked, and the
            -- /at_difired park that should hold them back is a network hop behind. On 2026-07-31 Lunafeet
            -- fired at 14:18:00.334, passed the baton at .687, and Sebbun committed at .902 - 0.6s later,
            -- into the same emergency. Lunafeet's landed; Sebbun's was refused.
            -- Holding until the verdict costs nothing now: it resolves in 3-5s since the tank started
            -- naming its own save, and every verdict path already passes the baton on its way out.
            if DI.watch then
                -- undecided; the verdict will pass it
            elseif DI.baton and DI.baton:lower() == myName:lower() and not DI.saidStaffDown then
                DI.saidStaffDown = true
                di_baton_pass(di_order(), string.format('%s staff is down (%ds)', myName, a))
            end
        end
        -- ON CHANGE, plus a keepalive. Peers count the staff timer down themselves now (di_peer_staff),
        -- so the only things worth sending are the discontinuities - the staff came up or went down, an
        -- emerald was spent, DG became available, a save landed. The keepalive is not for freshness; it
        -- is so a dropped message heals and a peer that has never heard of me learns I exist.
        -- Buckets on the staff timer, not raw seconds: a ticking countdown changes every second and
        -- would defeat the whole point. Emeralds and the flags are sent raw - they only move on an event.
        -- The save NAME is part of the key: a tank swapping Divine Redemption for Divine Intervention
        -- without a gap leaves saveUp at 1 the whole time, and that swap is exactly the event the
        -- verdict needs to see.
        local key = string.format('%d/%d/%d/%d/%s', (a == 0) and 0 or 1, b, c, d, tostring(e or '-'))
        if key ~= DI.key or (mq.gettime() - DI.lastPush) > (ic and 4000 or 20000) then
            DI.key, DI.lastPush = key, mq.gettime()
            DI.state[myName] = { staff = a, emeralds = b, dgReady = c, saveUp = d, updated = mq.gettime() }
            -- The save NAME goes last, so a peer on an older build simply reads nil and behaves as before.
            peer_bcast('/at_di %s %d %d %d %d %s', myName, a, b, c, d, (e and e ~= '') and e:gsub(' ', '_') or '-')
            -- Say it ONCE. Peers keep reporting they have never heard from the tank; I have twice now
            -- theorised about why and been wrong, so this settles whether the send happens at all.
            -- If this line never appears, the block is not running. If it appears and peers still see
            -- nothing, the message is not arriving and the problem is transport, not logic.
            if not DI.saidPush then
                DI.saidPush = true
                rezlog('[di] first state broadcast: staff=%d emeralds=%d dg=%d save=%d', a, b, c, d)
            end
            -- NAME THE RUNG. dg is 0/1 on the wire, which is all a peer needs, but the whole 2026-07-30
            -- investigation was one unexplained dg=0 - so the cleric says out loud which source it thinks
            -- it still has. If dg goes 0 while Divine Redemption is in fact available, this line is where
            -- that shows up, in the cleric's own log, at the moment it happens.
            if DI.dgRung and DI.dgRung ~= DI.dgRungSaid then
                DI.dgRungSaid = DI.dgRung
                rezlog('[di] my save ladder: %s%s (dg=%d)', DI.dgRung,
                       DI.dgLatched and ' [latched]' or '', c)
            end
        end
        -- Label last in the block, so the skip above cannot jump into the scope of a local declared here.
        ::di_read_done::
    end
    -- 250ms in combat, 1000ms otherwise. This poll is what notices the tank has gained a save, and the
    -- broadcast is change-detected - so a faster poll costs NO extra traffic, it just spots the change
    -- sooner. At 1000ms the tank could be a whole second late, and anyone firing in that window got
    -- declined by E3's CheckFor: a wasted commit, a wasted stand-down, and a puzzling log.
    -- It also shortens the trigger itself, which for a death save is the half that matters.
    do
        local inCbt = false
        pcall(function() inCbt = (tostring(mq.TLO.Me.CombatState()):upper() == 'COMBAT') end)
        DI.pollGap = inCbt and 250 or 1000
    end
    if DI.auto and not distributing and (mq.gettime() - DI.lastPoll) > (DI.pollGap or 1000) then
        DI.lastPoll = mq.gettime()
        local ok, err = pcall(di_tick)
        if not ok then
            DI.auto = false                     -- stop rather than error every second
            log('\\ar[di] disabled after an error: %s\\ax', tostring(err))
        end
    end
    -- Adaptive heartbeat. These two 2s broadcasts were ~93% of idle DanNet traffic, and BOTH are only
    -- ever consumed during an event: di_tick early-returns unless in combat, and the rez baton only
    -- matters once a corpse exists. So run fast during the event and slow between - but force an
    -- IMMEDIATE push on the edge INTO the event, because a stale first tick is precisely the failure
    -- the heartbeat was added to prevent. Slow is a keepalive, not silence: a toon that stopped
    -- talking entirely could not be told apart from one whose script died.
    if rezAuto and not distributing then
        -- ON CHANGE, plus a slow keepalive. This used to be a flat 2-5s heartbeat because the baton read
        -- the raw cooldown number; now that peers count it down themselves (rez_peer_secs), the only
        -- things worth sending are the discontinuities - a clicky got used, one came up, I zoned, I died.
        -- The keepalive is not for freshness, it is so a DROPPED message heals and so a peer that has
        -- never heard of me learns I exist.
        local cr, tk, cw = my_rez_secs(CROWN_ITEM), my_rez_secs(TOKEN_ITEM), my_cotw_secs()
        local dead = false; pcall(function() dead = tlo_true(mq.TLO.Me.Dead()) end)
        local zone = 0; pcall(function() zone = tonumber(mq.TLO.Zone.ID()) or 0 end)
        local al = dead and 0 or 1
        -- Buckets, not raw seconds: a ticking countdown changes every second and would defeat the whole
        -- point. What the baton cares about is ready-or-not, so that is what triggers a send.
        -- CotW carries ownership as well as readiness, so the key tracks both: -1 (don't own) must be
        -- distinguishable from a live cooldown, or a shaman who has just bought the AA never re-reports.
        local key = string.format('%d/%d/%d/%d/%d', (cr == 0) and 0 or 1, (tk == 0) and 0 or 1,
                                  (cw < 0) and 2 or ((cw == 0) and 0 or 1), al, zone)
        -- 2s while a corpse is in the zone, 20s otherwise. The election now decides everything else
        -- locally; the ONLY thing it still needs the network for is knowing a peer's script is alive
        -- and what its clicky is doing. Both matter exactly when someone is dead, so that is when the
        -- beat tightens - and it costs nothing the rest of the time.
        local due = (mq.gettime() - lastRezReadyPoll) > (rez_event_now() and 2000 or 20000)
        if key ~= rezReadyKey or due then
            rezReadyKey = key
            lastRezReadyPoll = mq.gettime()
            rezReady[myName] = { crown = cr, token = tk, cotw = cw, alive = (al == 1), zone = zone, updated = mq.gettime() }
            -- cotw goes LAST on the wire on purpose: a toon still on the previous build sends five args,
            -- the new bind reads the sixth as nil, and it becomes -1 ("doesn't own"). A mixed-build
            -- window therefore degrades to exactly the current behaviour instead of desyncing.
            peer_bcast('/at_rezready %s %d %d %d %d %d', myName, cr, tk, al, zone, cw)
        end
    end
    if distributing then
        wasDistributing = true
    elseif wasDistributing then           -- pass just ended: heartbeats were paused, so everyone looks stale.
        wasDistributing = false           -- hold the picker ~4s so peers re-report before staleness is trusted
        rezHoldUntil = mq.gettime() + 4000   -- (otherwise 'stale' reads as 'crashed' and several toons fire at once)
    end
    -- 250ms while a corpse is in the zone, 1000ms otherwise. Everything in the rez path is a state
    -- machine stepped by this tick - detect, claim, handshake, fire - so at 1000ms even a perfect rez
    -- cost 3-4 seconds in tick granularity alone. rez_event_now() is the SAME cheap SpawnCount the
    -- heartbeat already runs, throttled to once a second, so the fast rate costs nothing when idle.
    if not distributing and mq.gettime() >= rezHoldUntil
       and (mq.gettime() - lastRezPoll) > (rez_event_now() and 250 or 1000) then
        lastRezPoll = mq.gettime(); rez_announce_ready(); rez_autoaccept(); rez_tick()
    end
    accept_incoming()
    mq.doevents()   -- pump raid-watch events
    mq.delay(250)
    -- Label goes LAST in the block so the client_ready skip at the top does not jump into the scope of
    -- any local declared in the body - Lua permits a goto to a label at the end of a block precisely
    -- for this pattern.
    ::continue_tick::
end

pcall(function() mq.unbind('/at') end)
pcall(function() mq.unbind('/at_expecttrade') end)
pcall(function() mq.unbind('/at_close') end)
pcall(function() mq.unbind('/at_give') end)
pcall(function() mq.unbind('/at_give_multi') end)
pcall(function() mq.unbind('/at_collect') end)
pcall(function() mq.unbind('/at_done') end)
pcall(function() mq.unbind('/at_count') end)
pcall(function() mq.unbind('/at_have') end)
pcall(function() mq.unbind('/at_count_multi') end)
pcall(function() mq.unbind('/at_have_multi') end)
pcall(function() mq.unbind('/at_ping') end)
pcall(function() mq.unbind('/at_pong') end)
pcall(function() mq.unbind('/at_burnrefresh') end)
pcall(function() mq.unbind('/at_tribreq') end)
pcall(function() mq.unbind('/at_trib') end)
pcall(function() mq.unbind('/at_e3') end)
pcall(function() mq.unbind('/atresume') end)
pcall(function() mq.unbind('/atladder') end)
pcall(function() mq.unbind('/at_diladder') end)
pcall(function() mq.unbind('/at_dirungs') end)
pcall(function() mq.unbind('/at_distafftimer') end)
pcall(function() mq.unbind('/at_dibaton') end)
pcall(function() mq.unbind('/at_dibatonback') end)
pcall(function() mq.unbind('/at_distaff') end)
pcall(function() mq.unbind('/at_distaffprobe') end)
pcall(function() mq.unbind('/at_distaffreport') end)
pcall(function() mq.unbind('/at_didone') end)
pcall(function() mq.unbind('/at_disaved') end)
pcall(function() mq.unbind('/at_disavedump') end)
pcall(function() mq.unbind('/at_disavereport') end)
pcall(function() mq.unbind('/at_xtank') end)
pcall(function() mq.unbind('/at_xtsay') end)
pcall(function() mq.unbind('/at_xtpin') end)
pcall(function() mq.unbind('/at_xtunpin') end)
pcall(function() mq.unbind('/at_burn') end)
pcall(function() mq.unbind('/at_rezlog') end)
pcall(function() mq.unbind('/at_rezauto') end)
pcall(function() mq.unbind('/at_coth') end)
pcall(function() mq.unbind('/at_cothclaim') end)
pcall(function() mq.unbind('/at_cothfail') end)
pcall(function() mq.unbind('/at_cothgo') end)
pcall(function() mq.unbind('/at_di') end)
pcall(function() mq.unbind('/at_diauto') end)
pcall(function() mq.unbind('/at_difired') end)
pcall(function() mq.unbind('/at_rezready') end)
pcall(function() mq.unbind('/at_rezclaim') end)
pcall(function() mq.unbind('/at_rezrdy?') end)
pcall(function() mq.unbind('/at_rezrdy!') end)
pcall(function() mq.unbind('/at_rezskip') end)
pcall(function() mq.unbind('/at_rezdone') end)
pcall(function() mq.unbind('/at_rezorder') end)
pcall(function() mq.unbind('/at_rezorder?') end)
pcall(function() mq.unbind('/at_bags') end)
-- Everything else this script binds. These were left registered on /lua stop, so a stopped script
-- still owned 21 command names pointing at closures from a dead run.
pcall(function() mq.unbind('/at_cure') end)
pcall(function() mq.unbind('/at_cureprobe') end)
pcall(function() mq.unbind('/at_curestate') end)
pcall(function() mq.unbind('/at_diprobe') end)
pcall(function() mq.unbind('/at_healstate') end)
pcall(function() mq.unbind('/at_magic') end)
pcall(function() mq.unbind('/at_magicprobe') end)
pcall(function() mq.unbind('/at_magicstate') end)
pcall(function() mq.unbind('/at_mgbclick') end)
pcall(function() mq.unbind('/at_pot') end)
pcall(function() mq.unbind('/at_potprobe') end)
pcall(function() mq.unbind('/at_potstate') end)
pcall(function() mq.unbind('/at_quiet') end)
pcall(function() mq.unbind('/at_resync') end)
pcall(function() mq.unbind('/at_rezaccept') end)
pcall(function() mq.unbind('/at_rezcotw') end)
pcall(function() mq.unbind('/at_rezinc') end)
pcall(function() mq.unbind('/at_rezprobe') end)
pcall(function() mq.unbind('/at_rezwindows') end)
pcall(function() mq.unbind('/atcoth') end)
pcall(function() mq.unbind('/atsync') end)
pcall(function() mq.unbind('/at_arcstate') end)
pcall(function() mq.unbind('/at_arcane') end)
pcall(function() mq.unbind('/at_corpseprobe') end)
pcall(function() mq.unbind('/atburnpoll') end)
pcall(function() mq.unbind('/at_burnpoll') end)
pcall(function() mq.unbind('/at_pwhave') end)
pcall(function() mq.unbind('/at_pwoor') end)
pcall(function() mq.unbind('/at_pwmark') end)
pcall(function() mq.unbind('/at_pwclear') end)
pcall(function() mq.unbind('/at_pwdel') end)
pcall(function() mq.unbind('/at_pwadd') end)
pcall(function() mq.cmd('/e3p off') end)   -- always hand our toon back to E3 on the way out
if SHOW_UI then mq.imgui.destroy(scriptName) end
