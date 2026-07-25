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
local BUILD_TAG = 'at-e3glob-2026-07-25'   -- bump on every change; prints on startup

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
    local fh = io.open(LOG_FILE_PATH, 'w')   -- 'w' = fresh each run
    if fh then
        fh:write(string.format('=== AdventureTime log (%s) - started %s [build %s] ===\n',
            who, os.date('%Y-%m-%d %H:%M:%S'), BUILD_TAG))
        fh:close()
    else
        LOG_FILE_PATH = nil
    end
end
local function log_to_file(line)
    if not LOG_FILE_PATH then return end
    local fh = io.open(LOG_FILE_PATH, 'a')
    if not fh then return end
    -- Strip MQ colour codes: they are for the console, and in a text file they are noise. Also drops
    -- any stray BEL that a single-backslash '\a' escape would produce.
    line = tostring(line):gsub('\27%[[%d;]*m', ''):gsub('\\a[a-z]', ''):gsub('%c', '')
    fh:write(string.format('[%s] %s\n', os.date('%H:%M:%S'), line))
    fh:close()
end
local function log(fmt, ...)
    local msg = (select('#', ...) > 0) and string.format(fmt, ...) or fmt
    printf('\\ao[AdventureTime]\\ax ' .. msg)
    log_to_file(msg)
end
local function rezlog(fmt, ...)   -- file-only (keeps the [rez] chatter out of the MQ window)
    log_to_file((select('#', ...) > 0) and string.format(fmt, ...) or fmt)
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
local function group_members()
    local list, seen = {}, {}
    local me = mq.TLO.Me.Name() or ''
    if me ~= '' then list[#list + 1] = me; seen[me:lower()] = true end
    local n = mq.TLO.Group.Members() or 0
    for i = 1, n do
        local nm = mq.TLO.Group.Member(i).Name()
        if nm and nm ~= '' and not seen[nm:lower()] then list[#list + 1] = nm; seen[nm:lower()] = true end
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
local lastGroupKey = nil   -- group roster as last seen, so a membership change can re-test the network

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
    local key = table.concat(tanks, ','):lower()
    local changed = (key ~= (lastXTankKey or '\1'))
    lastXTankKey = key
    if auto and not changed then return tanks end    -- nothing changed - leave the slots alone
    for slot = 2, 13 do pcall(function() mq.cmdf('/xtarget set %d autohater', slot) end) end   -- clear managed range
    local slot = 2
    for _, nm in ipairs(tanks) do
        if slot > 13 then break end
        -- Membership is raid roster (a DEAD tank stays), but only actually set the slot if the tank's
        -- spawn is in THIS zone - a live out-of-zone tank is skipped now and picked up on return.
        local inzone = false
        pcall(function() inzone = (tonumber(mq.TLO.Spawn('pc =' .. nm).ID()) or 0) > 0 end)
        if inzone then
            pcall(function() mq.cmdf('/xtarget set %d %s', slot, nm) end)   -- by name, no /tar, no target change
            mq.delay(40)
            slot = slot + 1
        end
    end
    -- The /rsay announce that used to live here is gone: it was there to prove the slots were being
    -- set correctly, that has held up, and it was raid-wide chat on every change. Kept as a local log
    -- line so it is still checkable after the fact without saying anything to the raid.
    if #tanks > 0 then
        rezlog('[xtank] set %d xtarget(s): %s', #tanks, table.concat(tanks, ', '))
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
local lastBurnPoll   = 0     -- worker: last local read
local burnRefreshRequested = false   -- Burns tab 'Refresh' - re-parse the INI and re-report everything
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
rezLog      = {}      -- last 5 actions (driver-side display)
local lastRezPoll = 0
local lastRezFire = 0       -- my own 0.5s stagger
rezPending  = {}      -- corpseID -> gettime to hold off re-firing (rez in flight)
rezDebug    = ''      -- live picker view for diagnosing
rezDebugLast = ''
rezReady    = {}      -- char -> {crown=secs, token=secs}; -1 = doesn't own. Pushed to the group (no queries)
rezCast     = nil     -- my in-flight rez: { id=, item=, at=, tries=, name= } - one corpse at a time
rezConfirm  = {}      -- target name:lower -> gettime of last 'I'm at bind, ready' pong (gates the cast)
local rezDone     = {}      -- name:lower -> expiry: this toon has a rez pending (E3 will accept it) -> stop targeting its corpse
local lastRezDoneBcast = 0
rezPingAt   = {}      -- target name:lower -> gettime of my last handshake ping (rate-limit)
rezFireAt   = {}      -- corpseID -> my jittered earliest fire time (anti-race stagger)
rezSkip     = {}      -- corpseID -> { name:lower -> expiry } : candidates that reported they can't rez it
rezFirstSeen = {}     -- corpseID -> gettime first targeted (baton timeout per position)
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
local function my_effect_secs(name, resolver)
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
    local rem = 0
    pcall(function() rem = tonumber(mq.TLO.Me.Buff(bn).Duration.TotalSeconds()) or 0 end)
    if rem <= 0 then pcall(function() rem = tonumber(mq.TLO.Me.Song(bn).Duration.TotalSeconds()) or 0 end)  end
    if rem <= 0 then buffLatch[name] = nil; return 0 end
    if not buffLatch[name] then buffLatch[name] = rem end   -- latch so dsecs doesn't churn the push key
    return buffLatch[name]
end
local DISC_TICK_SECS = 6   -- MQ spell durations are in ticks; if disc countdowns read 6x too long, set this to 1
local function ability_state(name)
    local isItem = false
    pcall(function() isItem = (tonumber(mq.TLO.FindItem('=' .. name).ID()) or 0) > 0 end)
    if isItem then
        local t = 0; pcall(function() t = tonumber(mq.TLO.FindItem('=' .. name).TimerReady()) or 0 end)
        local ds = my_effect_secs(name, function() return mq.TLO.FindItem('=' .. name).Spell.Name() end)
        return true, (t == 0), t, (ds > 0), ds, 'i'
    end
    local isAA = false
    pcall(function() isAA = (tonumber(mq.TLO.Me.AltAbility(name).ID()) or 0) > 0 end)
    if isAA then
        local ds = my_effect_secs(name, function() return mq.TLO.Me.AltAbility(name).Spell.Name() end)
        local rdy = false; pcall(function() rdy = (mq.TLO.Me.AltAbilityReady(name)() == true) end)
        if rdy then return true, true, 0, (ds > 0), ds, 'a' end
        local secs = -1; pcall(function() secs = tonumber(mq.TLO.Me.AltAbilityTimer(name).TotalSeconds()) or -1 end)
        return true, false, (secs and secs > 0 and secs or -1), (ds > 0), ds, 'a'
    end
    local isSpell = false   -- otherwise a discipline
    pcall(function() isSpell = (tonumber(mq.TLO.Spell(name).ID()) or 0) > 0 end)
    if isSpell then   -- a discipline: also flag whether it's the one currently RUNNING (ActiveDisc)
        local active = false; pcall(function() active = (tostring(mq.TLO.Me.ActiveDisc.Name() or '') == name) end)
        local dsecs = 0
        if active then
            -- MyDuration is YOUR duration (level/focus applied) and is a ticktype, so .TotalSeconds gives
            -- seconds outright - no tick maths. Fall back to base Duration in ticks if it isn't exposed.
            pcall(function() dsecs = tonumber(mq.TLO.Spell(name).MyDuration.TotalSeconds()) or 0 end)
            if dsecs <= 0 then pcall(function() dsecs = tonumber(mq.TLO.Spell(name).Duration.TotalSeconds()) or 0 end) end
            if dsecs <= 0 then pcall(function() dsecs = (tonumber(mq.TLO.Spell(name).Duration()) or 0) * DISC_TICK_SECS end) end
        end
        local rdy = false; pcall(function() rdy = (mq.TLO.Me.CombatAbilityReady(name)() == true) end)
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
    for i = 1, 45 do
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
MGB_CLICKS = {
    -- who/say = the raid announce, sent as "<who> <say>" (e.g. "Cleric MGB heals").
    -- abils   = fired in order. MGB attaches to the FIRST one only - it buffs the next cast, so a
    --           second attachment would do nothing. Entries may be AAs *or* clicky items; which one
    --           is worked out at cast time, so nothing here has to say which it is.
    CLR = { label = 'Cleric Heals',     who = 'Cleric',    say = 'MGB heals',
            abils = { 'Celestial Regeneration', 'Exquisite Benediction' } },
    DRU = { label = 'Druid Heals',      who = 'Druid',     say = 'MGB heals',
            abils = { 'Spirit of the Wood' } },
    SHM = { label = 'Shaman Heals',     who = 'Shaman',    say = 'MGB heals',
            abils = { 'Ancestral Aid' } },
    BRD = { label = 'Bard Mercy',       who = 'Bard',      say = "MGB Nife's Mercy",
            abils = { "Tome of Nife's Mercy" } },
    ENC = { label = 'Enchanter Mercy',  who = 'Enchanter', say = "MGB Nife's Mercy",
            abils = { "Tome of Nife's Mercy" } },
    BST = { label = 'Beastlord Paragon', who = 'Beastlord', say = 'MGB Paragon',
            abils = { 'Paragon of Spirit' } },
    RNG = { label = 'Ranger Auspice',   who = 'Ranger',    say = 'MGB Auspice',
            abils = { 'Auspice of the Hunter' } },
}
MGB_AA    = 'Mass Group Buff'
healState = {}   -- driver: healState[char] = { cls, raid, mgb, aas = {secs...}, updated }
healLast  = ''   -- worker: last-pushed key, for change detection

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
function mgb_click()
    local cls = (mq.TLO.Me.Class.ShortName() or ''):upper()
    local cfg = MGB_CLICKS[cls]
    if not cfg or #cfg.abils == 0 then return end
    local raiding = (tonumber(mq.TLO.Raid.Members()) or 0) > 0
    for i, ab in ipairs(cfg.abils) do
        -- A clicky needs /CastType|Item or E3 looks for a spell by that name and finds nothing.
        -- Detected here rather than declared in the table, so entries stay one string each.
        local isItem = false
        pcall(function() isItem = (tonumber(mq.TLO.FindItem('=' .. ab).ID()) or 0) > 0 end)
        local opts = isItem and '/CastType|Item' or ''
        if raiding and i == 1 then
            -- MGB rides the FIRST ability only (it buffs the next cast), so the announce fires once too.
            pcall(function() mq.cmdf('/nowcast %s "%s%s/BeforeSpell|%s"', myName, ab, opts, MGB_AA) end)
            pcall(function() mq.cmdf('/rsay %s %s', cfg.who or cls, cfg.say or 'MGB') end)
        else
            pcall(function() mq.cmdf('/nowcast %s "%s%s"', myName, ab, opts) end)
        end
    end
    log('[mgb] %s%s', cfg.label, raiding and ' (MGB, raid)' or ' (group)')
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
    burnStartAt = mq.gettime() + 8000 + (off % 8000)
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
            for _, k in ipairs({ 'tribute', 'pots', 'burns', 'rez', 'misc' }) do
                f:write('show_' .. k .. '=' .. (showSec[k] and '1' or '0') .. '\n')
            end
            f:write('diAuto=' .. (DI.auto and '1' or '0') .. '\n')
            f:write('miniRez=' .. (miniRez and '1' or '0') .. '\n')
            f:write('miniDI=' .. (miniDI and '1' or '0') .. '\n')
            f:write('miniBurns=' .. (miniBurns and '1' or '0') .. '\n')
            f:write('miniPots=' .. (miniPots and '1' or '0') .. '\n')
            f:write('miniClicks=' .. (miniClicks and '1' or '0') .. '\n')
            f:write('miniCoth=' .. (miniCoth and '1' or '0') .. '\n')
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
            local sec = k:match('^show_(%w+)$')
            if sec and showSec[sec] ~= nil then showSec[sec] = (v == '1' or v:lower() == 'true') end
            if k == 'diAuto'    then DI.auto   = (v == '1' or v:lower() == 'true') end
            if k == 'miniRez'   then miniRez   = (v == '1' or v:lower() == 'true') end
            if k == 'miniDI'    then miniDI    = (v == '1' or v:lower() == 'true') end
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
    if COTH.active then
        ImGui.TextColored(0.36, 0.80, 0.46, 1, 'gathering on ' .. (coth_anchor() or '?'))
    else
        ImGui.TextDisabled('idle')
    end
    ImGui.Spacing()
    if ImGui.BeginTable('##cothtbl', 4, (ImGuiTableFlags.BordersInnerV or 0) + (ImGuiTableFlags.RowBg or 0)) then
        ImGui.TableSetupColumn(''); ImGui.TableSetupColumn('Emblem')
        ImGui.TableSetupColumn('Dist'); ImGui.TableSetupColumn('')
        ImGui.TableHeadersRow()
        for _, nm in ipairs(group_members()) do
            local st = COTH.state[nm]
            ImGui.TableNextRow(); ImGui.TableNextColumn()
            ImGui.TextColored(0.70,0.70,0.70,1.0, nm:sub(1,9))
            ImGui.TableNextColumn()
            local em = st and st.emblem or -1
            if em < 0 then ImGui.TextDisabled('-')
            elseif em == 0 then ImGui.TextColored(0.36,0.80,0.46,1.0,'ready')
            else ImGui.TextColored(0.85,0.35,0.35,1.0, string.format('%d:%02d', math.floor(em/60), em%60)) end
            ImGui.TableNextColumn()
            local d = st and st.dist or -1
            if d < 0 then ImGui.TextColored(0.85,0.35,0.35,1.0,'?')
            else ImGui.TextColored(0.70,0.70,0.70,1.0, tostring(d)) end
            ImGui.TableNextColumn()
            if coth_gathered(nm) then ImGui.TextColored(0.36,0.80,0.46,1.0,'here')
            elseif st and (st.dist or -1) >= 0 and st.dist <= COTH.RANGE and (st.los or 0) == 0 then
                ImGui.TextColored(0.95,0.62,0.25,1.0,'no LoS')
            else ImGui.TextColored(0.95,0.62,0.25,1.0,'away') end
        end
        ImGui.EndTable()
    end
    if COTH.dbg ~= '' then ImGui.Spacing(); ImGui.TextColored(0.55,0.70,0.80,1.0, COTH.dbg) end
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
    -- Options passed through to E3, mirroring the INI line this replaced. %s = the tank's name:
    -- E3 needs the target NAMED for CheckFor to be evaluated against him rather than the caster.
    OPTS    = '/CastType|Item/%s/Reagent|Emerald/CheckFor|Divine Guardian,Divine Intervention/NoInterrupt',
    REAGENT = 'Emerald',
    DG_AA   = 'Divine Guardian',
    DG_BOOT = "Forsaken Donal's Boots of Mourning",
    SAVES   = { 'Divine Guardian', 'Divine Intervention' },   -- already up on the tank = don't fire
    auto    = false,
    state   = {},     -- name -> { staff, emeralds, dgReady, saveUp, updated }
    key     = '',     -- my last-pushed state, for change detection
    lastPush = 0, lastPoll = 0, firedAt = 0, trigAt = 0, dbg = '',
    startedAt = 0,    -- set at load; the staff will not fire until the state table has had time to fill
}

-- Everything I can see about myself, read locally.
function di_read_self()
    local staff = -1
    pcall(function()
        if (tonumber(mq.TLO.FindItem('=' .. DI.STAFF).ID()) or 0) > 0 then
            staff = tonumber(mq.TLO.FindItem('=' .. DI.STAFF).TimerReady()) or 0
        end
    end)
    local em = 0; pcall(function() em = tonumber(mq.TLO.FindItemCount('=' .. DI.REAGENT)()) or 0 end)
    -- dgReady is only meaningful from a cleric: 1 = a Divine Guardian source is still UP, so hold the staff
    local dg = 0
    if (member_class(myName) or ''):upper() == 'CLR' then
        local aa, boot = false, false
        pcall(function() aa = (mq.TLO.Me.AltAbilityReady(DI.DG_AA)() == true) end)
        pcall(function() boot = (tonumber(mq.TLO.FindItem('=' .. DI.DG_BOOT).TimerReady()) or 0) == 0 end)
        if aa or boot then dg = 1 end
    end
    local save = 0
    for _, b in ipairs(DI.SAVES) do
        local up = false
        pcall(function() up = (tonumber(mq.TLO.Me.Buff(b).ID()) or 0) > 0 end)
        if up then save = 1; break end
    end
    return staff, em, dg, save
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

local function di_tick()
    if not DI.auto then return end
    local now = mq.gettime()
    if (now - DI.firedAt) < 12000 then return end         -- just fired; let it land before retrying
    local tank = di_tank()
    if not tank then DI.dbg = 'no tank in group'; DI.trigAt = 0; return end

    local inCombat = false
    pcall(function() inCombat = (tostring(mq.TLO.Me.CombatState() or ''):upper() == 'COMBAT') end)
    if not inCombat then DI.dbg = 'not in combat'; DI.trigAt = 0; return end

    local ts = DI.state[tank]
    if ts and ts.saveUp == 1 then DI.dbg = tank .. ' already has a save up'; DI.trigAt = 0; return end
    -- EVERY guard below is a reason to HOLD, so an empty DI.state makes them all pass vacuously and the
    -- staff fires blind. That is what happened one second after load: no tank report yet, so "does he
    -- already have a save" could not be asked, nobody was known to be ahead, and nothing said wait.
    -- Refuse to commit without a fresh word from the tank - firing when he is already saved is exactly
    -- the waste this whole baton exists to prevent.
    if not ts or (now - (ts.updated or 0)) >= 8000 then
        DI.dbg = 'no fresh report from ' .. tank .. ' - holding'
        DI.trigAt = 0
        return
    end
    if (now - DI.startedAt) < 12000 then
        DI.dbg = 'settling after load'   -- peers report on their own schedule; do not act on a half-built table
        DI.trigAt = 0
        return
    end

    for nm, st in pairs(DI.state) do                       -- any cleric still holding a DG source: wait
        if st.dgReady == 1 and (now - (st.updated or 0)) < 8000 then
            DI.dbg = 'cleric DG still available (' .. nm .. ')'; DI.trigAt = 0; return
        end
    end

    -- BATON. Fixed order; the default is to WAIT and assume whoever is ahead of me is handling it.
    -- I only act once everyone ahead is known-unable, or their window has elapsed as a backstop.
    if DI.trigAt == 0 then DI.trigAt = now end
    local order, myPos = di_order(), nil
    for i, nm in ipairs(order) do if nm:lower() == myName:lower() then myPos = i; break end end
    if not myPos then DI.dbg = 'not in the DI order'; return end
    -- Two separate reasons to hold, and they need DIFFERENT rules:
    --   * someone ahead is KNOWN able  -> wait for them, and the short timeout must NOT overtake them
    --     (that's what let two toons fire at once: position 3 timed out past a ready position 2)
    --   * someone ahead is simply UNKNOWN -> wait briefly, then proceed, or a missing toon stalls us
    local knownAble, unknown = false, false
    for i = 1, myPos - 1 do
        local st = DI.state[order[i]]
        local fresh = st and (now - (st.updated or 0)) < 8000
        if fresh then
            if st.staff == 0 and (st.emeralds or 0) > 0 then knownAble = true; break end
        else
            unknown = true
        end
    end
    if knownAble and (now - DI.trigAt) < 10000 then
        DI.dbg = string.format('holding for a ready toon ahead (pos %d)', myPos); return
    end
    if unknown and (now - DI.trigAt) < (myPos - 1) * 1500 then
        DI.dbg = string.format('waiting my turn (pos %d)', myPos); return
    end

    local staff, em = di_read_self()                       -- authoritative self-check before committing
    if staff ~= 0 or em <= 0 then DI.dbg = 'picked me but I cannot fire'; return end
    local tid = 0; pcall(function() tid = tonumber(mq.TLO.Spawn('pc =' .. tank).ID()) or 0 end)
    if tid <= 0 then DI.dbg = 'tank not in zone'; return end

    DI.firedAt = now
    DI.trigAt = 0
    peer_bcast('/at_difired')   -- everyone else stands down immediately
    local spec = DI.STAFF .. DI.OPTS:format(tank)
    rezlog('[di] FIRING /nowcast me "%s" %d', spec, tid)
    pcall(function() mq.cmdf('/nowcast me "%s" %d', spec, tid) end)
    pcall(function() mq.cmdf('/gsay DI staff on %s', tank) end)
end

-- ===== distributed rez picker: each toon decides locally; E3 only eats the /nowcast =====
local function my_rez_secs(itemName)   -- MY own clicky: seconds until ready, 0 = ready, -1 = don't own it
    local has = false
    pcall(function() has = (tonumber(mq.TLO.FindItem('=' .. itemName).ID()) or 0) > 0 end)
    if not has then return -1 end
    local t = 0; pcall(function() t = tonumber(mq.TLO.FindItem('=' .. itemName).TimerReady()) or 0 end)
    return t
end
local function rez_present(name)   -- still on DanNet? a crashed/LD toon drops off (this is the anti-ghost check)
    local ok = false
    pcall(function() ok = tostring(mq.TLO.DanNet.Peers() or ''):lower():find(name:lower(), 1, true) ~= nil end)
    return ok
end
local function rez_dead(name)
    local d = false; pcall(function() d = (mq.TLO.Group.Member(name).Dead() == true) end); return d
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
function rez_event_now()
    if (mq.gettime() - HB.lastCheck) > 1000 then
        HB.lastCheck = mq.gettime()
        local dead, n = false, 0
        pcall(function() dead = (mq.TLO.Me.Dead() == true) end)
        pcall(function() n = tonumber(mq.TLO.SpawnCount('pccorpse')) or 0 end)
        HB.corpse = dead or n > 0
    end
    return HB.corpse
end

local function rez_corpse(name)   -- returns corpseID, distance. Laz names PC corpses "<Name>'s corpse".
    local id, dist = 0, 99999
    local forms = { name .. " corpse", "=" .. name .. "'s corpse", "pccorpse " .. name }
    for _, f in ipairs(forms) do
        pcall(function()
            local sp = mq.TLO.Spawn(f)
            local sid = tonumber(sp.ID()) or 0
            if sid > 0 then id = sid; dist = tonumber(sp.Distance()) or 99999 end
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

local function rez_tick()
    if #rezPriority == 0 then load_rez_priority() end   -- workers have no UI to load it; load here so their picker runs
    if not rezAuto or #rezPriority == 0 then return end
    local now = mq.gettime()

    -- 0) If I'm mid-rez, finish THAT cast before starting another (one corpse at a time, retry on interrupt).
    if rezCast then
        local iDead = false; pcall(function() iDead = (mq.TLO.Me.Dead() == true) end)
        if iDead then   -- died mid-rez: release my claim and skip the slot I was casting so the next slot takes over NOW
            rezPending[rezCast.id] = nil
            local ck = (rezCast.item == TOKEN_ITEM) and 'token' or 'crown'
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
        if casting then return end                                 -- still casting - wait
        if (now - rezCast.at) < 1500 then return end               -- 1s cast + settle; recast fast if it was interrupted
        if my_rez_secs(rezCast.item) == 0 and rezCast.tries < 3 then   -- clicky still ready => interrupted; recast
            rezCast.tries = rezCast.tries + 1; rezCast.at = now
            rezlog('[rez] retry %d /nowcast me "%s" %d', rezCast.tries, rezCast.item, rezCast.id)
            pcall(function() mq.cmdf('/nowcast me "%s" %d', rezCast.item, rezCast.id) end)
            return
        end
        rezCast = nil   -- done with this cast; if the corpse is still there, the picker re-handshakes and tries again
        return
    end

    -- 1) TARGET: highest-priority toon with a CORPSE in my zone, owner still connected, reachable.
    --    Uses corpse EXISTENCE, not the Dead flag - a released toon is 'alive' at bind but still has a corpse.
    local tgtName, tgtID, anyCorpse, dbg
    local myZone0 = 0; pcall(function() myZone0 = tonumber(mq.TLO.Zone.ID()) or 0 end)
    for _, nm in ipairs(rezPriority) do
        local id, dist = rez_corpse(nm)
        if id > 0 then
            local rr = rezReady[nm]
            local ownerHereAlive = rr and rr.alive and rr.zone == myZone0   -- owner up & in my zone => this corpse is stale
            local rezPend = rezDone[nm:lower()] and now < rezDone[nm:lower()]   -- owner already has a rez pending -> done
            if not ownerHereAlive and not rezPend then
                anyCorpse = true
                dbg = string.format('%s corpse=%d@%d', nm, id, math.floor(dist))
                if dist <= 100 and not (rezPending[id] and now < rezPending[id]) then
                    tgtName, tgtID = nm, id; break
                end
            end
        end
    end
    if not anyCorpse then rezdbg('no corpses in zone'); return end
    if not tgtID then rezdbg('no reachable corpse | ' .. (dbg or '')); return end

    -- 2) REZZER = SLOT baton over rezOrder (name + clicky). I act when one of MY slots is the first not-out slot.
    --    A slot is 'out' if its owner skipped it, is dead/stale, or doesn't own that clicky. Default = wait (assume handled).
    local myZone = 0; pcall(function() myZone = tonumber(mq.TLO.Zone.ID()) or 0 end)
    if #rezOrder == 0 then load_rez_order() end
    if not rezFirstSeen[tgtID] then rezFirstSeen[tgtID] = now end
    local iAmDead = false; pcall(function() iAmDead = (mq.TLO.Me.Dead() == true) end)

    -- my earliest slot whose clicky I can actually use right now (local, authoritative)
    local myPos, myClicky
    if not iAmDead then
        for pos, sl in ipairs(rezOrder) do
            if sl.name:lower() == myName:lower() and sl.name:lower() ~= tgtName:lower() then
                local ready = (sl.clicky == 'token' and my_rez_secs(TOKEN_ITEM) == 0) or (sl.clicky == 'crown' and my_rez_secs(CROWN_ITEM) == 0)
                if ready then myPos, myClicky = pos, sl.clicky; break end
            end
        end
    end

    if iAmDead or not myPos then   -- no usable slot: skip ALL my slots so the baton advances past me, release any claim
        for _, sl in ipairs(rezOrder) do
            if sl.name:lower() == myName:lower() then
                local key = myName:lower() .. ':' .. sl.clicky
                rezSkip[tgtID] = rezSkip[tgtID] or {}; rezSkip[tgtID][key] = now + 8000
                peer_bcast('/at_rezskip %s %d', key, tgtID)
            end
        end
        rezdbg(string.format('target %s(%d): I (%s) have no clicky; baton passes me', tgtName, tgtID, myName))
        return
    end

    -- am I cleared? every slot before mine must be out (skipped / owner dead-stale / doesn't own it). My own earlier
    -- (unusable) slots count as out since I know locally I can't use them.
    local cleared = true
    for pos = 1, myPos - 1 do
        local sl = rezOrder[pos]
        local owner, clicky = sl.name, sl.clicky
        if owner:lower() ~= tgtName:lower() and owner:lower() ~= myName:lower() then
            local key = owner:lower() .. ':' .. clicky
            local sk = rezSkip[tgtID] and rezSkip[tgtID][key]
            local skipped = sk and now < sk
            local rr = rezReady[owner]
            local deadStale = rr and ((rr.alive == false) or (now - (rr.updated or 0)) >= 6000)
            -- 'out' if I have FRESH data showing the clicky isn't ready (cooldown or not owned). No data -> assume viable, wait.
            local notReady = rr and ((clicky == 'token' and rr.token ~= 0) or (clicky == 'crown' and rr.crown ~= 0))
            if not (skipped or deadStale or notReady) then cleared = false; break end   -- a ready/unknown slot ahead -> wait
        end
    end
    local timedOut = (now - rezFirstSeen[tgtID]) >= (myPos - 1) * 2000
    if not (cleared or timedOut) then
        rezdbg(string.format('target %s(%d): waiting my turn [me:%s %s slot%d]', tgtName, tgtID, myName, myClicky, myPos))
        return
    end
    local item = (myClicky == 'token') and TOKEN_ITEM or CROWN_ITEM
    local pick = { name = myName, token = (myClicky == 'token') }
    rezdbg(string.format('target %s(%d) <- ME %s(%s) slot%d', tgtName, tgtID, myName, myClicky, myPos))
    -- CLAIM NOW (before the handshake) so others back off immediately instead of timing out into a dogpile.
    peer_bcast('/at_rezclaim %d', tgtID)

    -- HANDSHAKE: don't cast until the target has zoned to its bind and settled (a too-early rez is wasted).
    -- Ping the target; it pongs only when at bind (valid zone, different from mine, not zoning). No pong -> keep waiting.
    local tkey = tgtName:lower()
    if not (rezConfirm[tkey] and (now - rezConfirm[tkey]) < 2500) then
        if (now - (rezPingAt[tkey] or 0)) > 700 then
            rezPingAt[tkey] = now
            peer_cmdf(tgtName, '/at_rezrdy? %s %d', myName, myZone)
        end
        rezdbg(string.format('target %s(%d): waiting for bind handshake [me:%s]', tgtName, tgtID, myName))
        return
    end

    -- anti-race jitter: stagger toons by a small random delay so two don't fire in the same tick.
    if not rezFireAt[tgtID] then rezFireAt[tgtID] = now + math.random(0, 500) end
    if now < rezFireAt[tgtID] then return end
    if rezPending[tgtID] and now < rezPending[tgtID] then return end   -- someone else already claimed it in the meantime
    if (now - lastRezFire) < 500 then return end
    rezlog('[rez] FIRING /nowcast me "%s" %d (target %s)', item, tgtID, tgtName)
    pcall(function() mq.cmdf('/nowcast me "%s" %d', item, tgtID) end)
    pcall(function() mq.cmdf('/gsay Clicked %s on %s', item, tgtName) end)   -- announce the rez in group chat
    lastRezFire = now
    rezCast = { id = tgtID, item = item, at = now, tries = 1, name = tgtName }   -- wait for THIS to clear before the next
    rezPending[tgtID] = now + 4000
    peer_bcast('/at_rezclaim %d', tgtID)   -- CLAIM: everyone else skips this corpse
    local msg = string.format('%s -> %s -> %s', myName, (pick.token and 'token' or 'crown'), tgtName)
    if SHOW_UI then rez_note(msg) elseif driverName then peer_cmdf(driverName, '/at_rezlog %s', msg) end
end



-- Liveness: the driver pings, a running instance pongs back. Used to auto-start the tool on any group
-- member that isn't running it, instead of assuming the user launched it everywhere.
local running = true   -- forward-declared here so the /at_close bind below sets THIS (not a global)
local alive = {}
pcall(function()
    mq.bind('/at_ping', function(driver) if driver then driverName = driver; peer_cmdf(driver, '/at_pong %s', myName) end end)
    mq.bind('/at_close', function() mq.cmd('/e3p off'); running = false end)   -- broadcast close: resume E3, then exit
    mq.bind('/at_e3', function(mode) mq.cmd('/e3p ' .. (mode == 'on' and 'on' or 'off')) end)   -- pause/resume E3
    mq.bind('/at_xtank', function() set_tank_xtargets(false) end)   -- healer: set raid tanks on my XTargets
    mq.bind('/at_rezlog', function(...) rez_note(table.concat({...}, ' ')) end)   -- a rezzer reports its cast
    mq.bind('/at_rezauto', function(mode) rezAuto = (mode == 'on'); rezlog('[rez] auto-rez %s', mode or '?') end)
    mq.bind('/at_coth', function(name, em, dist, los)
        if name then COTH.state[name] = { emblem = tonumber(em) or -1, dist = tonumber(dist) or -1,
                                          los = tonumber(los) or 0, updated = mq.gettime() } end
    end)
    mq.bind('/at_cothclaim', function(name) if name then COTH.claims[name] = mq.gettime() + 25000 end end)
    mq.bind('/at_cothfail', function(name) if name then COTH.claims[name] = nil end end)
    -- User-facing: /atcoth [on|off|stop]. No arg = start. Registered on every toon, so the gather can
    -- be kicked off from whichever one you happen to be looking at rather than only from the driver.
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
    mq.bind('/at_di', function(name, staff, em, dg, save)
        if name then DI.state[name] = { staff = tonumber(staff) or -1, emeralds = tonumber(em) or 0,
                                        dgReady = tonumber(dg) or 0, saveUp = tonumber(save) or 0,
                                        updated = mq.gettime() } end
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
    mq.bind('/at_healstate', function(char, cls, raid, ...)
        if not char or not cls then return end
        local secs = {}
        for _, v in ipairs({ ... }) do secs[#secs + 1] = tonumber(v) or -1 end
        local aas = {}
        for i = 2, #secs do aas[#aas + 1] = secs[i] end
        healState[char] = { cls = cls, raid = (tonumber(raid) == 1), mgb = secs[1] or -1,
                            aas = aas, updated = mq.gettime() }
    end)
    mq.bind('/at_mgbclick', function() mgb_click() end)
    mq.bind('/at_quiet', function(ms)
        local n = tonumber(ms) or 0
        quietUntil = (n > 0) and (mq.gettime() + math.min(n, 30000)) or 0
    end)
    mq.bind('/at_diauto', function(mode) DI.auto = (mode == 'on') end)
    mq.bind('/at_pot', function(key)   -- group draught button: drink the best tier I hold
        local base = pot_base_for(key)
        if not base then return end
        local ok, nm = pot_drink(base)
        if ok then log('[pot] %s', nm)
        elseif nm then log('[pot] %s on cooldown', nm)
        else log('[pot] no %s carried', base) end
    end)
    mq.bind('/at_difired', function() DI.firedAt = mq.gettime(); DI.trigAt = 0 end)
    mq.bind('/at_rezready', function(char, cr, tk, al, zone) if char then rezReady[char] = { crown = tonumber(cr) or -1, token = tonumber(tk) or -1, alive = (tonumber(al) == 1), zone = tonumber(zone) or 0, updated = mq.gettime() } end end)
    mq.bind('/at_rezdone', function(name) if name then rezDone[name:lower()] = mq.gettime() + 15000 end end)   -- that toon has a rez pending; stop targeting its corpse
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
    mq.bind('/at_rezclaim', function(id) local n = tonumber(id); if n then rezPending[n] = mq.gettime() + 4000 end end)   -- a rezzer claimed this corpse
    mq.bind('/at_rezrdy?', function(rezzer, rzone)   -- a rezzer asks: are you at bind, ready for a rez?
        if not rezzer then return end
        local zoning = false; pcall(function() zoning = (mq.TLO.Me.Zoning() == true) end)
        local myz = 0; pcall(function() myz = tonumber(mq.TLO.Zone.ID()) or 0 end)
        if (not zoning) and myz > 0 and myz ~= (tonumber(rzone) or -1) then   -- settled at bind (diff zone) -> ready
            peer_cmdf(rezzer, '/at_rezrdy! %s', myName)
        end
    end)
    mq.bind('/at_rezrdy!', function(tname) if tname then rezConfirm[tname:lower()] = mq.gettime() end end)   -- target confirmed ready
    mq.bind('/at_rezskip', function(key, id) local n = tonumber(id); if key and n then rezSkip[n] = rezSkip[n] or {}; rezSkip[n][key:lower()] = mq.gettime() + 8000; rezPending[n] = nil end end)   -- a slot can't rez this corpse; release its claim
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
local iAmHealer       = false   -- set at startup; only priest-classes self-maintain tank XTargets
pcall(function() iAmHealer = ({ CLR = true, DRU = true, SHM = true })[(mq.TLO.Me.Class.ShortName() or ''):upper()] or false end)
local lastXTankPoll   = 0       -- gettime of last auto tank-xtarget sweep
local xtankRecheckAt  = nil     -- debounce: re-check tank XTargets at this time after a raid event
-- Event-driven raid watch: each toon watches its OWN raid and, on any change, debounces a re-check.
-- The 60s poll below is the failsafe if a message wording doesn't match on Laz.
local function raid_changed() if autoXTank then xtankRecheckAt = mq.gettime() + 2000 end end
pcall(function()
    mq.event('at_raid_join',   '#1# joined the raid#*#',            raid_changed)   -- Laz: 'Name joined the raid.'
    mq.event('at_raid_leave',  '#1# has left the raid#*#',          raid_changed)   -- Laz: 'Name has left the raid.'
    mq.event('at_raid_removed','#1# has been removed from the raid#*#', raid_changed)
    mq.event('at_raid_dispand','#*#raid has been disbanded#*#',     raid_changed)
    mq.bind('/at_pong', function(peer) if peer then alive[peer:lower()] = true end end)
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
        burnStartAt = 0
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

local function is_up(peer, waitMs)
    alive[peer:lower()] = nil
    peer_cmdf(peer, '/at_ping %s', myName)
    local w = 0
    while w < (waitMs or 900) do
        mq.doevents(); mq.delay(100); w = w + 100
        if alive[peer:lower()] then return true end
    end
    return alive[peer:lower()] == true
end

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
local function count_for(who, item)
    if who:lower() == myName:lower() then return my_count(item) end
    return peer_count(who, item)
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
local function accept_incoming()
    if giving then return end
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
local miniMode        = false   -- compact window when minimized
-- NOT local: save_settings/load_settings are defined further up the file, so a local declared here
-- is invisible to them - they would read and write a same-named GLOBAL while the UI used the local,
-- and the setting would silently never persist. rezAuto, showSec and DI are globals for this reason.
-- (Also buys four back against the 200-local ceiling.)
miniBurns       = true    -- show the burn dot matrix in the mini window
miniRez         = true    -- show crown/token cooldowns in the mini window
miniDI          = false   -- show the tank save line + DI staff cooldowns in the mini window
miniPots        = false   -- show the group draught buttons in the mini window
miniClicks      = false   -- show the per-class MGB/group click buttons in the mini window
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

local function do_give(giver, receiver, item, qty)
    if giver:lower() == myName:lower() then
        give_item_to(receiver, item, qty)
    else
        peer_cmdf(giver, '/at_give %s %d %s', enc(item), qty, receiver)
        -- give the remote hand-off time to finish before the next one (nav + trade)
        mq.delay(9000)
    end
end

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

    group_bags(giverPeers)       -- close the givers' bags back
    group_e3('off', giverPeers)   -- work done - hand the group back to E3

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

    for _, p in ipairs(up) do
        uiStatus = 'Collecting from ' .. p .. '...'
        log('collecting from %s', p)
        doneReplies[p:lower()] = nil
        peer_cmdf(p, '/at_collect %s %s', myName, listStr)
        wait_done(p, 120000)   -- a full stash can be several trades; give it room
    end

    group_bags(up)       -- close bags back
    group_e3('off', up)   -- work done - hand the group back to E3

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
    -- strip "Draught of " and the trailing tier (the group header carries I/II)
    local n = it:gsub('^Draught of ', '')
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

local function short_name(n) return (n:sub(1, 5)) end

local function render_group(label, color, items)
    if label then ImGui.TextColored(color[1], color[2], color[3], 1.0, label) end
    local pushed = false
    if ImGuiCol and ImGuiCol.TableBorderStrong then
        ImGui.PushStyleColor(ImGuiCol.TableBorderStrong, color[1], color[2], color[3], 0.75); pushed = true
    end
    local statusOn = #statusNames > 0   -- shown by default once counts are read
    local nCols = statusOn and (2 + #statusNames) or 2   -- name + [one per toon] + target
    if ImGui.BeginTable('##grp_' .. (label or items[1]), nCols, (ImGuiTableFlags.BordersOuter or 0) + (ImGuiTableFlags.SizingStretchProp or 0)) then
        ImGui.TableSetupColumn('##n', ImGuiTableColumnFlags.WidthStretch or 0)
        if statusOn then
            for _, nm in ipairs(statusNames) do ImGui.TableSetupColumn(short_name(nm), ImGuiTableColumnFlags.WidthFixed or 0, 42) end
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
                    local c = (statusCounts[nm:lower()] and statusCounts[nm:lower()].__class) or ''
                    local n = (statusCounts[nm:lower()] and statusCounts[nm:lower()][it]) or 0
                    local ck = class_key(c)
                    if ck and ((is_endurance(it) and not WANTS_ENDURANCE[ck]) or (is_mana(it) and not WANTS_MANA[ck])) then
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
    if pushed then ImGui.PopStyleColor() end
    ImGui.Spacing()
end

local function fmt_favor(n)
    n = tonumber(n) or 0
    if n >= 1000 then return string.format('%.1fk', n / 1000) end
    return tostring(math.floor(n))
end

-- Query each group member's tribute over DanNet (self read directly). CurrentFavor = current favor points;
-- TributeActive = whether tribute is toggled on. Runs from the loop (not render) so the /dquery waits yield.
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
-- Items a character is reporting, burns only, in display order.
function burn_items_of(c)
    local its = {}
    for it, st in pairs(burnState[c] or {}) do if (st.tier or 0) > 0 then its[#its + 1] = it end end
    table.sort(its, function(a, b)
        local ra, sa = burn_rank(burnState[c][a])
        local rb, sb = burn_rank(burnState[c][b])
        if ra ~= rb then return ra < rb end
        if sa ~= sb then return sa < sb end
        return a < b
    end)
    return its
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

local function draw_rez_mini()
    -- Same shape as the Burns tab: characters across the top, one row per clicky.
    local cols = {}
    for _, nm in ipairs(rezPriority) do
        local rr = rezReady[nm]
        if rr and ((rr.crown or -1) >= 0 or (rr.token or -1) >= 0) then cols[#cols + 1] = nm end
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
    row('token', 'Token')   -- token first: it's the scarce one, so it burns first
    row('crown', 'Crown')
    ImGui.EndTable()
end

local function draw_burn_dots()
    local chars = {}
    for c, _ in pairs(burnState) do chars[#chars + 1] = c end
    table.sort(chars)
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
            for i = 1, #rezOrder do
                local sl = rezOrder[i]
                local rr = rezReady[sl.name]
                local secs = rr and (sl.clicky == 'token' and rr.token or rr.crown)
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
    local st = healState[nm]
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
    for i, aa in ipairs(cfg.abils) do add(aa, (st.aas or {})[i] or -1, true) end
    return (down and 'down' or 'ready'), rows, st.raid
end

function draw_mgb_buttons()
    -- Count classes first: two toons of the SAME class would otherwise draw two buttons with the same
    -- ImGui id (it was keyed on class), and ImGui treats same-id widgets as one - clicking the second
    -- fired the first. Ids are per-CHARACTER now, and a duplicated class gets its name in the label so
    -- the two are tellable apart.
    local seen = {}
    for _, nm in ipairs(group_members()) do
        local c = (member_class(nm) or ''):upper()
        if MGB_CLICKS[c] then seen[c] = (seen[c] or 0) + 1 end
    end
    local first = true
    for _, nm in ipairs(group_members()) do
        local cls = (member_class(nm) or ''):upper()
        local cfg = MGB_CLICKS[cls]
        if cfg and #cfg.abils > 0 then
            if not first then ImGui.SameLine() end
            first = false
            local label = cfg.label .. ((seen[cls] or 0) > 1 and (' (' .. nm .. ')') or '')
            local state, rows, raiding = mgb_button_state(nm, cfg)
            local cr, cg, cb
            if state == 'unknown'  then cr, cg, cb = 0.55, 0.55, 0.55   -- grey: no report yet
            elseif state == 'down' then cr, cg, cb = 0.85, 0.35, 0.35   -- red: something it needs is down
            else                        cr, cg, cb = 0.36, 0.80, 0.46   -- green: everything ready
            end
            local pushed = false
            if ImGuiCol and ImGuiCol.Text then
                ImGui.PushStyleColor(ImGuiCol.Text, cr, cg, cb, 1.0); pushed = true
            end
            if ImGui.SmallButton(label .. '##at_mgb_' .. nm) then
                if nm:lower() == myName:lower() then mgb_click()
                else peer_cmdf(nm, '/at_mgbclick') end
            end
            if pushed then ImGui.PopStyleColor() end
            if ImGui.IsItemHovered and ImGui.IsItemHovered() then
                local lines = { string.format('%s  (%s)', nm, raiding and 'raid: MGB + announce' or 'group only') }
                for _, r in ipairs(rows) do lines[#lines + 1] = '  ' .. r end
                if state == 'unknown' then lines[#lines + 1] = '  no report yet' end
                pcall(function() ImGui.SetTooltip(table.concat(lines, '\n')) end)
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
        local pushed = false
        if ImGuiCol and ImGuiCol.Text then
            ImGui.PushStyleColor(ImGuiCol.Text, cr, cg, cb, 1.0); pushed = true
        end
        if ImGui.SmallButton(p.label .. '##at_pot_' .. p.key) then group_pot(p.key) end
        if pushed then ImGui.PopStyleColor() end
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
function draw_coth_mini()
    if COTH.active then
        if ImGui.SmallButton('Stop gather##at_coth_mini') then coth_set(false) end
        ImGui.SameLine(); ImGui.TextColored(0.36, 0.80, 0.46, 1.0, 'on ' .. (coth_anchor() or '?'))
    else
        if ImGui.SmallButton('CoTH Group##at_coth_mini') then coth_set(true) end
    end
end

local function render()
    if not windowOpen then return end
    if miniMode then   -- compact tribute-only window (its own ###id so it keeps its own small size/pos)
        local show = ImGui.Begin('Tribute###advtime_mini', windowOpen,
            (ImGuiWindowFlags.AlwaysAutoResize or 0) + (ImGuiWindowFlags.NoScrollbar or 0))
        windowOpen = show
        if show then
            if ImGui.SmallButton('Expand') then miniMode = false end
            ImGui.SameLine()
            if ImGui.SmallButton('Refresh') then tributeRequested = true end
            ImGui.SameLine()
            if ImGui.SmallButton('Burns') then miniBurns = not miniBurns end
            ImGui.SameLine()
            if ImGui.SmallButton('Rez') then miniRez = not miniRez end
            ImGui.Spacing()
            draw_tribute_mini()
            if miniRez then
                ImGui.Spacing(); ImGui.Separator(); ImGui.Spacing()
                draw_rez_mini()
            end
            if miniDI then
                ImGui.Spacing(); ImGui.Separator(); ImGui.Spacing()
                draw_di_mini()
            end
            if miniBurns then
                ImGui.Spacing(); ImGui.Separator(); ImGui.Spacing()
                draw_burn_dots()
            end
            if miniPots then
                ImGui.Spacing(); ImGui.Separator(); ImGui.Spacing()
                draw_pot_buttons()
            end
            if miniClicks then
                ImGui.Spacing(); ImGui.Separator(); ImGui.Spacing()
                draw_mgb_buttons()
            end
            if miniCoth then
                ImGui.Spacing(); ImGui.Separator(); ImGui.Spacing()
                draw_coth_mini()
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
        if ImGui.Button('Refresh', 70, 0) then refreshRequested = true end
        ImGui.SameLine()
        if ImGui.Button('Tribute', 70, 0) then tributeRequested = true end
        ImGui.SameLine()
        if ImGui.Button('Mini', 50, 0) then miniMode = true end
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
                    local active = (burnFilter == label); local pushed = false
                    if active and ImGuiCol and ImGuiCol.Button then ImGui.PushStyleColor(ImGuiCol.Button, 0.20, 0.45, 0.70, 1.0); pushed = true end
                    if ImGui.Button(label, w or 55, 0) then burnFilter = label end
                    if pushed then ImGui.PopStyleColor() end
                end
                fbtn('All'); ImGui.SameLine(); fbtn('Tank'); ImGui.SameLine(); fbtn('DPS'); ImGui.SameLine(); fbtn('Healer', 60)
                ImGui.SameLine(); if ImGui.Button('Refresh', 70, 0) then burnRefreshRequested = true end
                ImGui.Spacing()
                if next(burnState) == nil then
                    ImGui.TextDisabled('waiting for reports...')
                else
                    local chars = {}
                    for c in pairs(burnState) do
                        if burnFilter == 'All' or role_of(burnClass[c]) == burnFilter then chars[#chars + 1] = c end
                    end
                    table.sort(chars)
                    if #chars == 0 then ImGui.TextDisabled('no ' .. burnFilter .. ' characters reporting') end
                    local function short(nm) if #nm > 18 then return nm:sub(1, 17) .. '...' end return nm end
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
                            ImGui.TextColored(cr, cg, cb, 1.0, short(it) .. (stamp ~= '' and ('  ' .. stamp) or ''))
                        else
                            local budget = availW - stampW - 10        -- 10px gutter between name and timer
                            local nm = it
                            local okT = pcall(function()
                                while #nm > 4 and ImGui.CalcTextSize(nm) > budget do nm = nm:sub(1, #nm - 1) end
                            end)
                            if not okT then nm = short(it) end
                            if nm ~= it and #nm > 3 then nm = nm:sub(1, #nm - 3) .. '...' end
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
                    local tflags = (ImGuiTableFlags.BordersInnerV or 0) + (ImGuiTableFlags.RowBg or 0)
                                 + (ImGuiTableFlags.SizingStretchSame or ImGuiTableFlags.SizingStretchProp or 0) + (ImGuiTableFlags.Resizable or 0)
                    if #chars > 0 and ImGui.BeginTable('##burns', #chars, tflags) then
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
                                ImGui.TableNextRow()
                                for i, c in ipairs(chars) do
                                    ImGui.TableNextColumn()
                                    if i == 1 then ImGui.TextColored(0.85, 0.72, 0.35, 1.0, tinfo.label)
                                    else           ImGui.TextColored(0.45, 0.40, 0.25, 1.0, tinfo.label) end
                                end
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
                ImGui.TextColored(0.85, 0.72, 0.35, 1.0, 'Automation')
                do
                    local a, b = rezAuto, DI.auto
                    rezAuto = ImGui.Checkbox('Auto-Rez', rezAuto)
                    DI.auto = ImGui.Checkbox('Auto-DI staff', DI.auto)
                    if a ~= rezAuto or b ~= DI.auto then
                        dirty = true
                        for _, nm in ipairs(group_members()) do
                            if nm:lower() ~= myName:lower() then
                                if a ~= rezAuto then peer_cmdf(nm, '/at_rezauto %s', rezAuto and 'on' or 'off') end
                                if b ~= DI.auto then peer_cmdf(nm, '/at_diauto %s', DI.auto and 'on' or 'off') end
                            end
                        end
                    end
                end
                ImGui.Spacing(); ImGui.Separator(); ImGui.Spacing()
                ImGui.TextColored(0.85, 0.72, 0.35, 1.0, 'Mini window')
                do
                    local a, b, c, d, e, f2 = miniRez, miniBurns, miniPots, miniCoth, miniClicks, miniDI
                    miniRez    = ImGui.Checkbox('Rez in mini', miniRez)
                    miniDI     = ImGui.Checkbox('DI staff in mini', miniDI)
                    miniBurns  = ImGui.Checkbox('Burns in mini', miniBurns)
                    miniPots   = ImGui.Checkbox('Group draught buttons in mini', miniPots)
                    miniClicks = ImGui.Checkbox('Class MGB buttons in mini', miniClicks)
                    miniCoth   = ImGui.Checkbox('CoTH Group button in mini', miniCoth)
                    if a ~= miniRez or b ~= miniBurns or c ~= miniPots or d ~= miniCoth or e ~= miniClicks or f2 ~= miniDI then dirty = true end
                end
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
    local missing = {}
    for _, m in ipairs(mine) do
        if not peers:find(m:lower(), 1, true) then missing[#missing + 1] = m end
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
-- The peer check was written and then never wired in, so the one diagnostic aimed at split/broken
-- networks has never run. Deferred rather than immediate: DanNet needs a moment to discover peers,
-- and asking too early reports everyone missing on a perfectly healthy setup.
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

while running do
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
        local gk = table.concat(group_members(), ',')
        if gk ~= lastGroupKey then
            lastGroupKey = gk
            if peerCheckAt == 0 then peerCheckAt = mq.gettime() + 8000 end
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
    if driverName and (mq.gettime() - lastTribPush) > 15000 then   -- report MY tribute to the driver, unprompted
        lastTribPush = mq.gettime()
        local a = false; pcall(function() local v = mq.TLO.Me.TributeActive(); a = (v == true) or (tostring(v):upper() == 'TRUE') end)
        local f = 0; pcall(function() f = tonumber(mq.TLO.Me.CurrentFavor()) or 0 end)
        peer_cmdf(driverName, '/at_trib %s %d %d', myName, a and 1 or 0, f)
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
    if mq.gettime() > burnStartAt and (mq.gettime() - lastBurnResync) > 120000 then
        lastBurnResync = mq.gettime()   -- periodic re-sync: forget last-sent state so everything reports again
        if not SHOW_UI then burnLast = {} end
    end
    if mq.gettime() > burnStartAt and (mq.gettime() - lastBurnPoll) > 2000 then   -- read MY watched item timers locally (cheap), push changes
        lastBurnPoll = mq.gettime()
        -- Group draughts ride the same local poll. secs/dsecs are LATCHED values, not live countdowns,
        -- so the key only moves when the state genuinely flips - one push on drink, one on fall-off.
        -- The driver counts down from `updated` itself, exactly like burn_remain does.
        do   -- healer clicks: only healers with configured AAs report at all
            local hcls = (mq.TLO.Me.Class.ShortName() or ''):upper()
            local hcfg = MGB_CLICKS[hcls]
            if hcfg and #hcfg.abils > 0 then
                local raiding = (tonumber(mq.TLO.Raid.Members()) or 0) > 0
                local parts = { tostring(click_secs(MGB_AA)) }
                for _, aa in ipairs(hcfg.abils) do parts[#parts + 1] = tostring(click_secs(aa)) end
                local k = hcls .. '/' .. (raiding and 1 or 0) .. '/' .. table.concat(parts, '/')
                if healLast ~= k then
                    healLast = k
                    if SHOW_UI then
                        local sec = {}
                        for i = 2, #parts do sec[#sec + 1] = tonumber(parts[i]) or -1 end
                        healState[myName] = { cls = hcls, raid = raiding, mgb = tonumber(parts[1]) or -1,
                                              aas = sec, updated = mq.gettime() }
                    elseif driverName then
                        peer_cmdf(driverName, '/at_healstate %s %s %d %s', myName, hcls,
                                  raiding and 1 or 0, table.concat(parts, ' '))
                    end
                end
            end
        end
        for _, gp in ipairs(GROUP_POTS) do
            local carries, up, secs, dsecs = pot_state(gp.base)
            local k = string.format('%d/%d/%d/%d', carries, up, secs, dsecs)
            if potLast[gp.key] ~= k then
                potLast[gp.key] = k
                if SHOW_UI then
                    potState[myName] = potState[myName] or {}
                    potState[myName][gp.key] = { carries = carries, up = up, secs = secs, dsecs = dsecs, updated = mq.gettime() }
                elseif driverName then
                    peer_cmdf(driverName, '/at_potstate %s %s %d %d %d %d', myName, gp.key, carries, up, secs, dsecs)
                end
            end
        end
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
    if DI.auto and not distributing then
        local ic = false
        pcall(function() ic = (tostring(mq.TLO.Me.CombatState() or ''):upper() == 'COMBAT') end)
        if ic ~= HB.diFast then HB.diFast = ic; DI.lastPush = 0 end   -- edge -> push now
        -- 6000 not 20000: the cleric-DG hold only trusts a report < 8000ms old. A cleric that has
        -- not taken aggro is not COMBAT-flagged, so it would sit on the slow tick and read as
        -- stale - and the staff would fire early believing no DG source is left.
        if (mq.gettime() - DI.lastPush) > (ic and 2000 or 6000) then
        DI.lastPush = mq.gettime()
        local a, b, c, d = di_read_self()
        DI.state[myName] = { staff = a, emeralds = b, dgReady = c, saveUp = d, updated = mq.gettime() }
        -- Heartbeat, not push-on-change: with change-only pushes a stable toon never re-announces, so
        -- everyone else's table holds only themselves - and then everyone thinks they're first. That is
        -- exactly the dogpile the rez baton was built to stop. Out of combat it drops to a 20s keepalive
        -- and snaps back to 2s the instant combat starts.
        peer_bcast('/at_di %s %d %d %d %d', myName, a, b, c, d)
        end
    end
    if DI.auto and not distributing and (mq.gettime() - DI.lastPoll) > 1000 then
        DI.lastPoll = mq.gettime()
        local ok, err = pcall(di_tick)
        if not ok then
            DI.auto = false                     -- stop rather than error every second
            log('\\ar[di] disabled after an error: %s\\ax', tostring(err))
        end
    end
    if rezAuto and not distributing then   -- (held during a counts/give pass so we never drown its /dquery replies)
        local rezBox = false
        pcall(function() rezBox = (mq.TLO.Window('ConfirmationDialogBox').Open() == true) end)
        if rezBox and (mq.gettime() - lastRezDoneBcast) > 2000 then
            lastRezDoneBcast = mq.gettime()
            rezDone[myName:lower()] = mq.gettime() + 15000
            peer_bcast('/at_rezdone %s', myName)
        end
    end
    -- Adaptive heartbeat. These two 2s broadcasts were ~93% of idle DanNet traffic, and BOTH are only
    -- ever consumed during an event: di_tick early-returns unless in combat, and the rez baton only
    -- matters once a corpse exists. So run fast during the event and slow between - but force an
    -- IMMEDIATE push on the edge INTO the event, because a stale first tick is precisely the failure
    -- the heartbeat was added to prevent. Slow is a keepalive, not silence: a toon that stopped
    -- talking entirely could not be told apart from one whose script died.
    if rezAuto and not distributing then
        local ev = rez_event_now()
        if ev ~= HB.rezFast then HB.rezFast = ev; lastRezReadyPoll = 0 end   -- edge -> push now
        -- 5000 not 10000: the picker treats a report >= 6000ms old as dead-or-stale (deadStale),
        -- so the idle cadence has to stay UNDER that window or every living toon reads stale.
        if (mq.gettime() - lastRezReadyPoll) > (ev and 2000 or 5000) then
        lastRezReadyPoll = mq.gettime()                 -- on-change-only made stable-but-alive toons look stale -> baton skipped them
        local cr, tk = my_rez_secs(CROWN_ITEM), my_rez_secs(TOKEN_ITEM)
        local dead = false; pcall(function() dead = (mq.TLO.Me.Dead() == true) end)
        local zone = 0; pcall(function() zone = tonumber(mq.TLO.Zone.ID()) or 0 end)
        local al = dead and 0 or 1
        rezReady[myName] = { crown = cr, token = tk, alive = (al == 1), zone = zone, updated = mq.gettime() }
        peer_bcast('/at_rezready %s %d %d %d %d', myName, cr, tk, al, zone)
        end
    end
    if distributing then
        wasDistributing = true
    elseif wasDistributing then           -- pass just ended: heartbeats were paused, so everyone looks stale.
        wasDistributing = false           -- hold the picker ~4s so peers re-report before staleness is trusted
        rezHoldUntil = mq.gettime() + 4000   -- (otherwise 'stale' reads as 'crashed' and several toons fire at once)
    end
    if not distributing and mq.gettime() >= rezHoldUntil and (mq.gettime() - lastRezPoll) > 1000 then
        lastRezPoll = mq.gettime(); rez_tick()
    end
    accept_incoming()
    mq.doevents()   -- pump raid-watch events
    mq.delay(250)
end

pcall(function() mq.unbind('/at') end)
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
pcall(function() mq.unbind('/at_xtank') end)
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
pcall(function() mq.cmd('/e3p off') end)   -- always hand our toon back to E3 on the way out
if SHOW_UI then mq.imgui.destroy(scriptName) end
