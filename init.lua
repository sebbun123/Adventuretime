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
-- VERSION vs BUILD_TAG. They answer different questions and both are worth having:
--   VERSION   what release this is. Moves rarely, and means something to a person - "am I on 1.0 or
--             1.1" is a question about features.
--   BUILD_TAG which exact copy of the file is loaded. Moves on every change, and exists because "did
--             my edit land" cost a round trip more than once before TSL had one.
-- Shown together in the log header and the title bar, so a screenshot answers both.
VERSION = '1.11'
local BUILD_TAG = '1.11'  -- bump on every change; prints on startup
-- Until when we will accept an incoming trade. Set by /at_expecttrade, which the giver sends just
-- before it walks over. Outside that window trades are left alone so a human can use one.
-- Global, not local: this chunk is at Lua's 200-local ceiling.
expectTradeUntil = 0

-- File logging: mirror every line to AdventureTime_<name>_log.txt (fresh each run, flushed per line) so a
-- run can be reconstructed from the file - same as the crafter/listener.
-- FORWARD SLASHES WHEN PRINTING A PATH. MQ reads \a as the start of a colour code and eats the next
-- character with it, so "Config\adventuretime_settings.txt" prints as "Configventuretime_settings.txt" -
-- the \a and the d are swallowed. The path is right; the display was not, and it points at a file that
-- does not exist, which is a fine way to spend twenty minutes.
-- Windows takes forward slashes anywhere a path is typed, so this stays copy-pasteable.
function path_show(p) return (tostring(p or ''):gsub('\\', '/')) end
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
    -- THE MODULE FOLDER, kept for at_dir() below - the Logs step reassigns `dir` a moment from now.
    AT_MODULE_DIR = dir or ''
    -- LOGS LIVE IN Logs\. No migration: old logs are not worth moving, they just stop growing where
    -- they are and new ones start here.
    -- PROBE BEFORE MKDIR. Writing a file into a folder that already exists is cheap and answers the
    -- same question; lfs.mkdir returns FALSE when the directory is already there, so treating that as
    -- failure meant the os.execute fallback spawned a shell on EVERY startup. That was the freeze.
    if dir and dir ~= '' then
        local logdir = dir .. 'Logs'
        local probe  = logdir .. '\\.atwrite'
        local pf = io.open(probe, 'w')
        if not pf then
            local made = false
            pcall(function() local lfs = require('lfs'); made = lfs.mkdir(logdir) end)
            if not made then pcall(function() os.execute('mkdir "' .. logdir .. '"') end) end
            pf = io.open(probe, 'w')
        end
        -- Only move in if it is genuinely writable. A log that cannot be written is worse than a log in
        -- an untidy place, and this runs before there is any way to report the problem.
        if pf then
            pf:close()
            pcall(function() os.remove(probe) end)
            dir = logdir .. '\\'
        end
    end
    local who = '?'
    pcall(function() who = mq.TLO.Me.Name() or '?' end)
    LOG_FILE_PATH = (dir or '') .. 'AdventureTime_' .. who .. '_log.txt'
    -- Separate file, overwritten rather than appended: we only ever want the LAST value, and a file
    -- that grows is a file that eventually costs something to write.
    PHASE_FILE_PATH = (dir or '') .. 'AdventureTime_' .. who .. '_lastphase.txt'
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
        fh:write(string.format('=== AdventureTime %s log (%s) - started %s [build %s] ===\n',
            VERSION, who, os.date('%Y-%m-%d %H:%M:%S'), BUILD_TAG))
        fh:close()
    else
        LOG_FILE_PATH = nil
    end
end
-- CRASH BREADCRUMB. Six crashes in, the logs have told us almost nothing about the moment of death -
-- the last line before the last one was 33 seconds earlier, because most of what this script does is
-- silent. A crash kills the process outright, so nothing can be written AFTER it; the only way to know
-- what was running is to have written it BEFORE.
-- So: every subsystem stamps its name here as it starts, and the main loop flushes the stamp to a tiny
-- file once a second. After a crash that file holds whatever was running in the last second of life.
-- Cost is one 40-byte overwrite per second, which is nothing next to what it answers.
-- This is DIAGNOSIS, not a fix. It exists to turn "something in AdventureTime, out of combat" into a
-- named subsystem, which is the first genuinely narrowing thing we would have had.
-- A RING OF THE LAST FEW PHASES, not a single current value.
-- The first version recorded one phase and flushed it at the END of the loop - immediately after setting
-- it to 'idle'. So the file could only ever say 'idle', whichever subsystem had just run. Two crashes
-- were spent finding that out, and the answer they gave was an artefact of the instrument.
-- Recording a RING fixes it properly rather than just moving the flush: the phase that crashed may not
-- be the one that happened to be current at flush time, so the last several are kept with timestamps.
-- Whatever was running in the final second is then in the file regardless of when the flush landed.
AT_PHASE_RING = {}
AT_PHASE_N    = 0
AT_PHASE_AT   = 0
AT_PHASE_KEEP = 10
function atphase(name)
    -- Collapse repeats: idle every tick would otherwise push everything interesting out of the ring.
    local last = AT_PHASE_RING[((AT_PHASE_N - 1) % AT_PHASE_KEEP) + 1]
    if last and last.name == name then last.n = (last.n or 1) + 1; last.t = mq.gettime(); return end
    AT_PHASE_N = AT_PHASE_N + 1
    AT_PHASE_RING[((AT_PHASE_N - 1) % AT_PHASE_KEEP) + 1] =
        { name = name, t = mq.gettime(), wall = os.date('%H:%M:%S'), n = 1 }
end
-- 200ms, NOT 1000. This writes the breadcrumb ring to disk, and at one write per second a crash mid-tick
-- loses the phases that mattered - the file then names the last FLUSHED phase, which is whatever the tick
-- happened to be doing a second earlier rather than the thing that died.
-- That is exactly what happened chasing the porter crash: two characters died and the file said
-- 'doevents' on both, which was true and useless.
-- The tick is 250ms, so 200 means at most one tick is unaccounted for.
-- force=true bypasses the throttle. The flush normally runs once per tick, AFTER the work - so a crash
-- mid-tick never gets written and the file reports the previous tick instead. That is why the porter
-- crashes kept showing 'doevents' no matter which subsystem actually died.
-- Anything known to be risky calls this with force before doing the risky thing, so the breadcrumb is
-- on disk BEFORE the client has a chance to go down.
function atphase_flush(force)
    if not PHASE_FILE_PATH then return end
    if not force and (mq.gettime() - AT_PHASE_AT) < 200 then return end
    AT_PHASE_AT = mq.gettime()
    local fh = io.open(PHASE_FILE_PATH, 'w')
    if not fh then return end
    fh:write(string.format('=== %s  build %s ===\n', os.date('%Y-%m-%d %H:%M:%S'), BUILD_TAG))
    fh:write('last phases, oldest first - the bottom line is the most recent:\n')
    local total = math.min(AT_PHASE_N, AT_PHASE_KEEP)
    for i = 1, total do
        local idx = ((AT_PHASE_N - total + i - 1) % AT_PHASE_KEEP) + 1
        local e = AT_PHASE_RING[idx]
        if e then
            fh:write(string.format('  %s  %-16s x%d\n', e.wall, e.name, e.n or 1))
        end
    end
    fh:close()
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
-- A gem within this many seconds of ready counts as ready. Separates a cast in flight or a global
-- cooldown (a second or two) from an actual recast. Used by the magic clicks and the DI ladder.
-- Replaced a SpellReady debounce: SpellReady answers "can I cast this INSTANT", which on a bard is
-- false nearly all the time, and no amount of debouncing fixes a signal that is false continuously.
GEM_READY_SLACK = 5

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
-- /echo, NOT printf. printf does not process MQ colour codes on every build - on 1.55.25 the whole
-- prefix prints as the literal text "\ao[AdventureTime]\ax", on every single line, while E3's own
-- coloured output in the same window renders fine. /echo handles them everywhere.
-- '%s' with the text as an ARGUMENT in the fallback, never as the format string: printf IS a format
-- function, so an already-built message containing a '%' - and plenty of these carry percentages - gets
-- read as a specifier and throws.
-- The '$' guard is because /echo expands ${...} before printing. Nothing here should contain one, but
-- an item or mob name is not ours to vouch for, and a stray TLO expansion in a log line is a bad way to
-- find that out.
local function log(fmt, ...)
    local msg = safe_fmt(fmt, ...)
    local line = '\\ao[AdventureTime]\\ax ' .. msg
    if line:find('$', 1, true) then
        printf('%s', line)
    else
        local ok = pcall(function() mq.cmd('/echo ' .. line) end)
        if not ok then printf('%s', line) end
    end
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
ITEMS[#ITEMS + 1] = 'Ruby'
-- DIAMOND COIN IS DELIBERATELY NOT IN THIS LIST. It is handled on its own row with its own button,
-- because it behaves differently from everything else here: it exists half in bags and half in a
-- currency tab, needs converting before it can be moved, and is wanted occasionally rather than kept
-- topped up. Folding that into the shared Give out made the common case carry the odd one's baggage -
-- six extra queries on every refresh, a currency read nobody asked for, and a conversion step in the
-- middle of a routine that otherwise just moves things.
-- ITEMS drives the counts pass, the grid and the planner, so leaving it out keeps all three simple.
ALT_ITEMS = { 'Diamond Coin' }

-- Everything a REFRESH should read. Give out still walks ITEMS on its own, so a general hand-out never
-- disturbs the alt items - but "what has everyone got" means all of it.
function all_items()
    local t = {}
    for _, it in ipairs(ITEMS) do t[#t + 1] = it end
    for _, it in ipairs(ALT_ITEMS) do t[#t + 1] = it end
    return t
end

-- ---------------------------------------------------------------------------
-- Group draught buttons. One press = every group member drinks the BEST tier it personally holds.
-- Deliberately NOT decided on the driver: the driver's counts are only as fresh as the last Refresh,
-- and picking the tier here would drink the wrong one after any hand-trade. Each toon reads its own
-- inventory instead - always right, and one message per toon per press rather than any polling.
-- Globals, not locals: this chunk is at Lua's 200-local ceiling.
-- ---------------------------------------------------------------------------
GROUP_POTS = {
    { key = 'shimmer',   base = 'Draught of Shimmering Reflection', label = 'Group Shimmering'           },
    { key = 'fortitude', base = 'Draught of Fleeting Fortitude',    label = 'Group Fleeting'              },
    -- Inferno Ward moved here from the INIs. As a burn line it fired on every 15 and 30 minute burn
    -- whether or not the fight warranted it; as a button it is spent when someone decides to spend it.
    -- Same shape as the two above, so it gets the tier picking, the per-toon inventory read and the
    -- carries/up/timer display for free.
    { key = 'inferno',   base = 'Draught of Inferno Ward',        label = 'Group Inferno'               },
}
function pot_base_for(key)
    for _, p in ipairs(GROUP_POTS) do if p.key == key then return p.base, p.label end end
    return nil
end
-- driver: potState[char][key] = { carries, up, secs, dsecs, updated }. Worker: last-pushed key per pot.
potState = {}

-- ===== NIGHTVEIL EMBLEMS =====
-- REBUILT AROUND THE SPLIT ITEMS. These used to be augs socketed in a charm, and an aug reports
-- TimerReady = 0 through a live two hour cooldown - every TLO lied about it. That forced a whole
-- apparatus: a self-tracked countdown persisted to a file, a deliberate second click on a bagged copy
-- to provoke a refusal the client would answer with a real number, eight click methods tried in order,
-- and a chat event to correct the guess. All of it existed to work around one unreadable number.
-- The server split them into carryable items, one per role. A bag item answers TimerReady honestly, so
-- the entire apparatus is gone: read the timer, click the item.
-- WHO HAS WHICH IS DETECTED, NOT ASSUMED. Membership is "this character has this item in its bags",
-- not "this character is a cleric" - so a melee carrying the caster one is listed where it actually is.
NV_SPLIT = {
    { role = 'Defense',    item = 'Veiled Bastion' },
    { role = 'Healer',     item = 'Veiled Seal' },
    { role = 'Melee DPS',  item = 'Veiled Blade' },
    { role = 'Caster DPS', item = 'Veiled Eclipse' },
}
NIGHTVEIL_OPTS = '/CastType|Item/NoInterrupt'
NIGHTVEIL_BUFF = 'Intensity of the Resolute'   -- what a landed click applies; used only for display
-- ONE CHARACTER CAN CARRY ALL FOUR. This held a single item per character, which quietly assumed the
-- item matched the class - and the whole point of splitting them is that it need not. Somebody holding
-- all four appears in all four rows and can be sent whichever one the situation wants.
-- [char] = { items = { [index into NV_SPLIT] = secondsLeft }, updated }
nvState = {}
nvLast  = ''      -- change key for the push
nvPushAt = 0      -- last push, so a slow keepalive can re-send a dropped entry
nvErrLast = nil   -- last reported push error, so a repeating one is logged once

function nv_hms(s)
    s = tonumber(s) or 0
    if s <= 0 then return 'ready' end
    if s < 60 then return string.format('%ds', s) end
    if s < 3600 then return string.format('%dm', math.floor(s / 60)) end
    return string.format('%dh%02dm', math.floor(s / 3600), math.floor((s % 3600) / 60))
end

-- TimerReady DOES NOT ALWAYS RETURN A NUMBER. It can come back as text - "Not ready" - and tonumber()
-- on that is nil, which `or 0` then turns into "ready". A plausible wrong answer, which is the worst
-- kind: it reads as a working check right up until it matters.
function timer_secs(v)
    if v == nil then return 0 end
    if type(v) == 'number' then return math.max(0, math.floor(v)) end
    local s = tostring(v)
    local n = tonumber(s)
    if n then return math.max(0, math.floor(n)) end
    if s:lower():find('not ready', 1, true) then return 60 end
    return 0
end

-- WHICH of the four do I hold? Indexes into NV_SPLIT. Cached once found, because carrying one is a
-- per-character fact - but a MISS is never cached, since this is asked at startup before inventory is
-- reliably readable and one early empty answer would mean "carries none" for the whole session.
nvHave, nvHaveAt = nil, 0
function nv_have()
    if nvHave and #nvHave > 0 then return nvHave end
    if nvHave and (mq.gettime() - (nvHaveAt or 0)) < 15000 then return nvHave end
    local out = {}
    for i, e in ipairs(NV_SPLIT) do
        local n = 0
        pcall(function() n = tonumber(mq.TLO.FindItemCount('=' .. e.item)()) or 0 end)
        if n == 0 then
            local id = 0
            pcall(function() id = tonumber(mq.TLO.FindItem('=' .. e.item).ID()) or 0 end)
            if id > 0 then n = 1 end
        end
        if n > 0 then out[#out + 1] = i end
    end
    if #out > 0 and (not nvHave or #nvHave == 0) then
        local names = {}
        for _, i in ipairs(out) do names[#names + 1] = NV_SPLIT[i].role end
        log('[nv] carrying %d: %s', #out, table.concat(names, ', '))
    end
    nvHave, nvHaveAt = out, mq.gettime()
    return out
end

-- Seconds until the item at NV_SPLIT[i] is ready. 0 ready, -1 not carried.
function nv_secs_at(i)
    local e = NV_SPLIT[i]
    if not e then return -1 end
    local v = nil
    pcall(function() v = mq.TLO.FindItem('=' .. e.item).TimerReady() end)
    if v == nil then return -1 end
    return timer_secs(v)
end

-- The soonest-ready of everything I hold, for anything that just wants one number.
function nv_secs()
    local best = -1
    for _, i in ipairs(nv_have()) do
        local s = nv_secs_at(i)
        if s >= 0 and (best < 0 or s < best) then best = s end
    end
    return best
end


potLast  = {}
-- Drink the best tier of `base` I actually hold. II is tried first; I is the fallback ONLY when no II
-- is carried. If a tier is held but its timer is down we STOP rather than dropping to the lower one -
-- I and II share one recast, so the lesser tier is on cooldown too and firing it just spends a command
-- on a cast that cannot go.
-- NOWCAST, NOT QUEUECAST, since 2026-08-05. A queued cast does not fail - it WAITS, and E3 holds it until
-- it can go, which means a press can discharge at a moment nobody chose. That was seen with the Nightveil
-- emblems firing by themselves across several characters long after the button was pressed, and a potion
-- queued behind a long cast has the same shape even if the stakes are lower.
-- The cost is real and accepted: /nowcast interrupts whatever that toon is already casting. Pressing this
-- mid-fight can clip a heal. It is a deliberate trade of "might go off later, unbidden" for "goes now or
-- not at all", and the second is the one that can be reasoned about.
-- DRAUGHTS GET THE SAME TREATMENT AS THE STAFF. pot_drink used to fire and log "[pot] <name>" in the same
-- breath, claiming a success nobody had checked - the exact habit that made the DI logs disagree with the
-- fight for a whole night.
-- Confirmation is free: pot_state already reports both the buff being up and the item going on cooldown,
-- and either one proves it went.
POT_RETRY_AFTER = 4000     -- a nowcast either goes or it does not, so this is now slack, not queue wait
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
    pcall(function() mq.cmdf('/nowcast me "%s"', potPending.nm) end)
end

-- DON'T RE-DRINK WHAT IS ALREADY UP, and don't re-drink too soon.
-- Two guards, both per character, because each toon knows its own state and the driver's copy is only
-- as fresh as the last refresh.
--   * buff already running -> nothing to gain. pot_state asks once per LINE rather than per tier,
--     because I and II land the same effect, so a II up correctly blocks a I as well.
--   * drunk within POT_MIN_GAP -> refuse. THIS USED TO BE 30 MINUTES and it was the wrong call.
--     Nothing drinks these automatically - the only caller is the button - so a press is already a
--     decision somebody made, and refusing it second-guesses the person who made it. The item's own
--     timer is 15 minutes; a 30 minute policy on top of it meant the button silently did nothing for
--     the whole second half of the real cooldown, with no way to tell that from a broken button.
--     Worst case without the policy is a press landing on a live cooldown, which costs nothing.
--     What is left is an anti-double-press window: long enough that one click, or the lag between
--     firing and the buff appearing, cannot drink two - and short enough to never be in the way.
POT_MIN_GAP = 15 * 1000          -- 15 seconds: stops a double-press, not a second opinion
potDrankAt  = {}                 -- [base] = when this character last got one down

function pot_drink(base)
    -- THE BUTTON GUARDS AS LITTLE AS POSSIBLE ON PURPOSE.
    -- There used to be a refusal here when the buff was already running, on the assumption that drinking
    -- over it would consume a draught for nothing. It does not - the client will not drink one - so the
    -- guard was protecting against a cost that does not exist while making the button look broken.
    -- The one guard left is worth keeping and is about US, not the game: two presses in quick succession
    -- would send two /nowcast commands, and that is our own spam to avoid. Everything else - buff up,
    -- item on cooldown, wrong tier, none carried - the game already answers correctly by doing nothing.
    local last = potDrankAt[base]
    if last and (mq.gettime() - last) < POT_MIN_GAP then
        local left = math.ceil((POT_MIN_GAP - (mq.gettime() - last)) / 1000)
        return false, nil, string.format('%s drunk %ds ago - ignoring the double press (%ds)',
                                         base, math.floor((mq.gettime() - last) / 1000), left)
    end
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
                mq.cmdf('/nowcast me "%s"', nm)
                potPending = { base = base, nm = nm, at = mq.gettime(), tries = 1 }
                -- Stamped on the ATTEMPT, not on confirmation. A cast that lands a few seconds later
                -- would otherwise leave the gap unstarted, and a second press in between would drink
                -- another one.
                potDrankAt[base] = mq.gettime()
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
-- Rubies are a cleric reagent - nobody else consumes them, so they are greyed everywhere else exactly
-- as endurance draughts are on casters and Clear Mind is on pure melee. Same mechanism, one more table:
-- the grid should say "this toon will never use these" rather than showing a red shortfall against a
-- target that does not apply to them.
local WANTS_RUBY = { CLR = true }
local function is_ruby(item) return item == 'Ruby' end

-- Encode/decode an item name for passing over the peer command channel (names have spaces).
local function enc(name) return (tostring(name):gsub(' ', '_')) end
local function dec(name) return (tostring(name):gsub('_', ' ')) end

-- ---------------------------------------------------------------------------
-- Settings: per-character target qty for each item, persisted to Adventure Time/Settings/<char>.ini.
-- ---------------------------------------------------------------------------
local target = {}   -- itemName -> target qty per character
for _, it in ipairs(ITEMS) do target[it] = 0 end
-- Alt items are not in ITEMS - they are handled separately - but they still need a target to be typed
-- into and saved, so the quantity survives a reload like every other row's does.
for _, it in ipairs(ALT_ITEMS) do target[it] = 0 end

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
    for _, it in ipairs(ALT_ITEMS) do fh:write(string.format('%s=%d\n', enc(it), target[it] or 0)) end
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

-- ===== ONE INSTANCE PER CHARACTER =====
-- The driver pings the group and launches anything that does not answer. A worker that started 400ms
-- ago has not bound /at_ping yet, so it does not answer - and gets launched again, on a client already
-- running it. Two instances then share one log file, one settings file, and bind the same commands.
-- That is what the 2026-08-11 22:14 crash looks like: all five workers were up at 22:14:06.0, the driver
-- launched all five again at 22:14:06.4, and two of them were dead by 22:14:08. It was blamed on the
-- ports feature for three builds; the port book walk was later proved harmless by /atportlist.
-- A heartbeat file is the cheapest reliable answer: a live instance touches it every few seconds, and a
-- starting one that finds a fresh timestamp knows it is the duplicate and leaves.
-- Nothing is lost by being wrong in the safe direction - if the file is stale the new instance simply
-- carries on, which is the same behaviour as before this existed.
AT_ALIVE_PATH = nil
function at_alive_path()
    if AT_ALIVE_PATH then return AT_ALIVE_PATH end
    local cfg = ''
    pcall(function() cfg = tostring(mq.TLO.MacroQuest.Path('config')() or '') end)
    local who = (myName ~= '') and myName or 'unknown'
    AT_ALIVE_PATH = ((cfg ~= '') and (cfg .. '\\') or '') .. 'adventuretime_alive_' .. who .. '.txt'
    return AT_ALIVE_PATH
end
function at_alive_touch()
    local f = io.open(at_alive_path(), 'w')
    if f then f:write(tostring(os.time())); f:close() end
end
do
    local other = 0
    local f = io.open(at_alive_path(), 'r')
    if f then other = tonumber(f:read('*a') or '0') or 0; f:close() end
    local age = os.time() - other
    -- 15s: the heartbeat is written every 5, so three missed beats means the other one is genuinely gone.
    if other > 0 and age >= 0 and age < 15 then
        printf('%s', '\\ar[AdventureTime] Another copy is already running on this character '
            .. '(last seen ' .. age .. 's ago) - this one is stopping so the two do not fight.\\ax')
        pcall(function() mq.exit() end)
        return
    end
    at_alive_touch()
end
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
-- ALT CURRENCY BALANCES, per peer. Deliberately separate from query_all_counts: that pass exists to
-- move 90 item queries without flooding DanNet, with adaptive pacing and a re-fire sweep. This is one
-- query per peer for one currency, so all of that machinery would be overhead.
-- Currency is NOT an item - it lives in the inventory window's Alt. Currency tab and FindItemCount
-- cannot see it - so it needs its own read, and this is the one that makes the Withdraw column mean
-- something rather than showing zero for everybody.
altCounts = {}   -- [peerLower][currencyName] = balance
-- MY OWN balance, read the way the probe established: off the currency LIST, column 1 is the name and
-- column 2 is the count. Me.AltCurrency was the obvious guess and is not what was verified - the probe
-- dumped "row 3: col1=\"Diamond Coin\" col2=\"4271\"" and that is the reading to trust.
-- Needs the inventory window open on the Alt. Currency tab; the rows only populate on that page.
-- Put the inventory window back if WE opened it. Only closes what we opened - a window the player had
-- up stays up.
-- ANNOUNCE MY OWN BALANCE AND COUNT. Pushed by whoever just did something, rather than waited for by
-- the driver on a timer it has to guess. Every timed guess tonight has been wrong in one direction or
-- the other, and this one was wrong in the worst way: the board showed a number that had been correct
-- a minute earlier, which reads exactly like a number that is correct now.
-- The toon that converted or reclaimed knows the moment it finishes; it just has to say so.
function altcur_announce(name)
    local bal = altcur_balance(name)
    local bags = 0
    pcall(function() bags = tonumber(mq.TLO.FindItemCount('=' .. name)()) or 0 end)
    pcall(function()
        peer_bcast('/at_altbal %s %s %d', myName, name:gsub(' ', '_'), bal or -1)
    end)
    pcall(function()
        peer_bcast('/at_altbags %s %s %d', myName, name:gsub(' ', '_'), bags)
    end)
end

altcurCloseAfter = false
function altcur_done()
    if not altcurCloseAfter then return end
    altcurCloseAfter = false
    pcall(function() mq.TLO.Window(ALTCUR_WND).DoClose() end)
end

-- SCAN THE COLUMNS, do not assume which one holds what. The name is not necessarily in column 1 - the
-- first column may be an icon or blank - and the count is not necessarily column 2. Assuming 1 and 2
-- is why this read "not listed" for every currency while the list plainly had 10 rows in it.
-- The July probe got this right by design: it walked columns 1..6 and reported only the non-empty ones.
-- Matches on CONTAINS rather than equals, because a row label may carry a count or padding with it.
-- SHOW THE TAB BEFORE READING THE LIST. IW_AltCurr_PointList only populates while the Alt. Currency
-- subwindow is the one on screen; on any other tab it reads 0 rows, and altcur_balance() then falls
-- through its loop and reports "not listed at all" for a currency the character plainly has.
-- altcur_find_tab() cannot be used for this: it calls altcur_row() first, which needs the list to be
-- readable already - so it can only find the tab when the tab is already showing. Probe on the ROW
-- COUNT instead, which is exactly the thing that changes when the right tab comes up.
-- Cached, so the sweep happens once per session rather than on every balance read.
altcurListTab = nil

function altcur_list_rows()
    local n = 0
    pcall(function() n = tonumber(mq.TLO.Window(ALTCUR_LIST).Items()) or 0 end)
    return n
end

-- ROWS TWICE, 150ms APART. A single row-count read is not enough: the list keeps its previous contents
-- for a moment after the tab changes, so the first tab tried can report rows that belong to the tab we
-- just left. Stylin found "tab 5" and then "tab 1" seconds later on 2026-08-06 for exactly that reason.
function altcur_rows_stable()   -- global: the main chunk is at Lua's 200-local ceiling
    if altcur_list_rows() <= 0 then return false end
    mq.delay(150)
    return altcur_list_rows() > 0
end

function altcur_show_tab()
    if altcur_rows_stable() then return true end
    -- TABSELECT DOES NOTHING TO A CLOSED WINDOW, so without this every one of the ten tabs "fails" in
    -- the same way and the message blames the tab control. Sunetoo reported exactly that three times
    -- over while her inventory was simply not open.
    local open = false
    pcall(function() open = (mq.TLO.Window(ALTCUR_WND).Open() == true) end)
    if not open then
        pcall(function() mq.TLO.Window(ALTCUR_WND).DoOpen() end)
        mq.delay(800, function() return mq.TLO.Window(ALTCUR_WND).Open() == true end)
        pcall(function() open = (mq.TLO.Window(ALTCUR_WND).Open() == true) end)
        if not open then
            log('\\ay[altcur] %s will not open - cannot read the currency list\\ax', ALTCUR_WND)
            return false
        end
        altcurCloseAfter = true
    end
    local tabs = {}
    if altcurListTab then tabs[1] = altcurListTab end
    for t = 1, 10 do if t ~= altcurListTab then tabs[#tabs + 1] = t end end
    for _, t in ipairs(tabs) do
        pcall(function() mq.cmdf('/notify %s IW_Subwindows tabselect %d', ALTCUR_WND, t) end)
        mq.delay(300, function() return altcur_list_rows() > 0 end)
        if altcur_rows_stable() then
            if altcurListTab ~= t then
                log('[altcur] the currency list is on tab %d', t)
                altcurListTab, ALTCUR_TAB = t, t
            end
            return true
        end
    end
    log('\\ay[altcur] no tab 1-10 makes the currency list readable - the tab control may not be '
        .. 'IW_Subwindows. Run /atcurrency to see what is there.\\ax')
    return false
end

function altcur_balance(name)
    -- NO WINDOW-OPEN GATE. This used to refuse to read unless InventoryWindow was open, on the strength
    -- of a note that "the rows only populate on that page". The log disproved it in passing:
    --     window open: false
    --     currency list rows: 10
    -- The list is there whether the window is shown or not. The gate was the entire reason peers
    -- reported "shut" - they could have answered all along.
    -- If a client really does return nothing, opening the window is tried below rather than assumed.
    -- A CLOSED WINDOW READS, BUT IT READS STALE. The earlier conclusion was half right: the list does
    -- return rows with the window shut, which is why balances appeared at all - but the values are
    -- whatever they were when it was last shown. Lunafeet converted 7,000 coins and her row still read
    -- 12,481, because nothing had refreshed the closed window's copy.
    -- So the window is opened for the read every time, and put straight back if we opened it. A few
    -- hundred milliseconds per character, against a number that is otherwise quietly wrong.
    local wasOpen = false
    pcall(function() wasOpen = (mq.TLO.Window(ALTCUR_WND).Open() == true) end)
    if not wasOpen then
        pcall(function() mq.TLO.Window(ALTCUR_WND).DoOpen() end)
        mq.delay(600, function() return mq.TLO.Window(ALTCUR_WND).Open() == true end)
        altcurCloseAfter = true
    end
    -- The window being open is not enough; the right tab has to be showing.
    altcur_show_tab()
    local rows = altcur_list_rows()
    local want = name:lower()
    for i = 1, rows do
        local cells, hit = {}, false
        for c = 1, 6 do
            local v = ''
            pcall(function() v = tostring(mq.TLO.Window(ALTCUR_LIST).List(i, c)() or '') end)
            cells[c] = v
            if v ~= '' and v:lower():find(want, 1, true) then hit = true end
        end
        if hit then
            -- The balance is the first column in this row that is purely a number. Taking "the next
            -- column" would break the moment the layout differs by one.
            for c = 1, 6 do
                local v = (cells[c] or ''):gsub('[%s,]', '')
                if v ~= '' and v:match('^%d+$') then altcur_done(); return tonumber(v) end
            end
            altcur_done()
            return 0   -- listed, but no numeric column found: they have a row and no balance
        end
    end
    altcur_done()
    return nil   -- not listed at all
end

-- Balances across the group. A peer can only read its own list, and only with that window open - so
-- this asks each peer to report rather than trying to read their client from here.
function query_alt_currency(peers, name)
    altCounts[myName:lower()] = altCounts[myName:lower()] or {}
    altCounts[myName:lower()][name] = altcur_balance(name)

    -- RE-FIRE THE ONES THAT DO NOT ANSWER. This fired once per peer with no spacing and no retry, while
    -- the item counts beside it get three re-fires and an adaptive gap - so a single dropped message left
    -- a permanent "?" against a character that was perfectly reachable. Two of six missed on 2026-08-02.
    -- Cheap to do properly: this is one query per peer, not ninety, so a flat gap and three rounds is
    -- plenty without any of the counts pass's pacing machinery.
    local waiting = {}
    for _, p in ipairs(peers) do
        if p:lower() ~= myName:lower() then
            waiting[#waiting + 1] = p
            altCounts[p:lower()] = altCounts[p:lower()] or {}
            altCounts[p:lower()][name] = nil   -- clear, so a stale value cannot look like a fresh answer
        end
    end

    for round = 1, 3 do
        if #waiting == 0 then break end
        for _, p in ipairs(waiting) do
            pcall(function() peer_cmdf(p, '/at_altrep %s %s', name:gsub(' ', '_'), myName) end)
            mq.delay(60)   -- spacing: bunched fires are what DanNet drops
        end
        -- Give them a moment, pumping events so replies actually land.
        -- 2.5s, NOT 900ms. A peer whose inventory is on the wrong tab has to open the window and sweep
        -- for the right one before it can read anything, which costs seconds - so the old window timed
        -- out on precisely the characters that most needed asking. Sunetoo "never answered" three
        -- rounds running on 2026-08-06 while doing exactly this work.
        local deadline = mq.gettime() + 2500
        while mq.gettime() < deadline do
            mq.doevents(); mq.delay(50)
            local still = {}
            for _, p in ipairs(waiting) do
                if (altCounts[p:lower()] or {})[name] == nil then still[#still + 1] = p end
            end
            waiting = still
            if #waiting == 0 then break end
        end
        if #waiting > 0 and round < 3 then
            log('[currency] no answer from %s - re-asking (round %d)', table.concat(waiting, ', '), round + 1)
        end
    end
    if #waiting > 0 then
        log('\\ay[currency] %s never answered - shown as ?\\ax', table.concat(waiting, ', '))
    end
end

-- Who should do the withdrawing: whoever holds the most, so one pull covers the request more often.
-- Returns name and balance, or nil when nobody has any.
function alt_richest(name)
    local best, bestN = nil, 0
    for peer, t in pairs(altCounts) do
        local n = (t or {})[name]
        -- type check, not just truthiness: 'shut' is a string and comparing it with > would throw.
        if type(n) == 'number' and n > bestN then best, bestN = peer, n end
    end
    return best, bestN
end

-- NOTE: this REPLACES the counts table, it does not merge into it. Anything not in `items` is gone
-- afterwards - so this is a full-refresh call and a partial list will blank every other row on the
-- board. Pass all_items() unless you genuinely want everything else discarded.
-- ===== PUSHED COUNTS =====
-- A worker counting its OWN bags is a local read: instant, and it already knows when the number changed.
-- The dquery pass below asks the driver to pull the same information 90 queries at a time, which measured
-- 5.5 seconds every startup - and the comment on dannet_query explains why it was built that way: it
-- works on a peer that is NOT running AdventureTime.
-- That fallback is worth keeping, but it is not the usual case: the driver launches a worker on every
-- group member. So push when we can and pull only for whoever did not report - the same split the burn
-- poll has used all along, and what makes the aug table fill instantly.
-- INDEXES, NOT NAMES, on the wire: the item list is fixed and ordered, and 'Draught of Shimmering
-- Reflection II' would otherwise be split across arguments the moment it hit a bind.
countsPush = {}      -- [peerlower] = { [item] = n, at = gettime }
countsPushAt, countsPushLast = 0, ''   -- worker side: when we last pushed, and what we sent
COUNTS_FRESH = 90000 -- a push older than this is not trusted; the pass re-pulls that peer

function counts_push_blob()
    local parts = {}
    for i, it in ipairs(ITEMS) do
        local n = my_count(it)
        if n > 0 then parts[#parts + 1] = i .. ':' .. n end
    end
    -- Only non-zero entries travel. Everything absent is zero, which is most of the list on most toons.
    return (#parts > 0) and table.concat(parts, ',') or '-'
end

local function query_all_counts(peers, items)
    counts = { [myName:lower()] = { __got = true, __class = mq.TLO.Me.Class.ShortName() or '?' } }
    for _, it in ipairs(items) do counts[myName:lower()][it] = my_count(it) end
    for _, p in ipairs(peers) do counts[p:lower()] = counts[p:lower()] or {} end
    if #peers == 0 or #items == 0 then
        for _, p in ipairs(peers) do counts[p:lower()].__got = true end
        return
    end

    -- TAKE THE PUSHES FIRST, QUERY ONLY WHAT IS LEFT.
    -- A worker that reported recently has already done this work locally, and its answer is better than
    -- ours would be - it counted its own bags rather than us asking across the network 18 times.
    -- Only peers with no recent push get queried, which on a normal group is none of them: the pass goes
    -- from 90 queries to zero without losing the ability to read a peer that is not running the script.
    local need, fromPush = {}, 0
    for _, p in ipairs(peers) do
        local pu = countsPush[p:lower()]
        if pu and (mq.gettime() - (pu.at or 0)) < COUNTS_FRESH then
            for _, it in ipairs(items) do counts[p:lower()][it] = pu[it] or 0 end
            counts[p:lower()].__got = true
            fromPush = fromPush + 1
        else
            need[#need + 1] = p
        end
    end
    if #need == 0 then
        log('[counts] %d peer(s) from their own reports - no queries needed', fromPush)
        return
    end
    if fromPush > 0 then
        log('[counts] %d peer(s) reported; querying the other %d', fromPush, #need)
    end
    peers = need

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
    -- 3000, arrived at by measurement rather than by feel. The budget sets the fire gap, and that gap is
    -- pure deliberate spacing - at the old 5000 it was 4.95s of a 7.4s pass spent waiting on purpose.
    -- Three runs settled where the floor is:
    --   5000 -> 55ms gap -> 7402ms,  2 re-fires
    --   2000 -> 25ms gap -> 4680ms,  3 re-fires
    --   2000 -> 25ms gap -> 5329ms, 11 re-fires
    -- All answered 90/90, so 25ms works - but eleven retries on the third run says it sits right at the
    -- edge, and retry traffic is the thing that turned an earlier pass into a 22-second storm.
    -- 3000 gives ~33ms: most of the saving, with margin.
    -- WORTH KNOWING ABOUT THE SAFETY NET: the adaptive widening only triggers when an item EXHAUSTS its
    -- retries, not when one merely needs a retry. Those eleven all succeeded, so the gap never widened.
    -- It will still catch a genuinely failing network, but it is coarser than 'it self-corrects' implies,
    -- which is why the starting value is worth getting right rather than leaning on it.
    local BUDGET_MS  = 3000
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
    -- REPORT PER CHARACTER, AS EACH ONE FINISHES. The pass interleaves every peer at once - that is what
    -- keeps it fast - but the only output was one line at the very end, so a run that took eight seconds
    -- looked like eight seconds of nothing followed by a total.
    -- Saying who is done as they finish turns that into visible progress, and it names the slow one:
    -- when a pass drags, this shows five peers answering in two seconds and one taking the rest.
    local doneAt = {}
    local function peer_done(pp)
        if doneAt[pp] then return end
        doneAt[pp] = mq.gettime()
        local got = 0
        for _, it in ipairs(items) do
            if counts[pp:lower()] and counts[pp:lower()][it] ~= nil then got = got + 1 end
        end
        log('[counts]   %-9s %2d/%d in %.1fs', pp, got, #items, (doneAt[pp] - t0all) / 1000)
    end
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
                        if idx[p] > #items then idx[p] = nil; peer_done(p) end
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
                                if idx[p] > #items then idx[p] = nil; peer_done(p) end
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
pendingClose = {}          -- lowercase name -> when to close their worker if they have not returned
                           -- GLOBAL, not local: this file sits at 200 locals in the main chunk, which is
                           -- Lua's hard ceiling, and one more will not compile.
GROUP_CLOSE_GRACE = 120000 -- how long a departed character keeps its worker before being shut down
local resyncAt     = 0     -- when to resync after a roster change (0 = nothing pending)
local resyncFirstAt = 0    -- when the current run of churn began, so the debounce cannot defer forever
local lastResyncAt  = 0    -- last time the network half actually ran
RESYNC_MIN_GAP   = 15000   -- floor between full re-reports
RESYNC_MAX_DEFER = 12000   -- stop deferring once churn has run this long
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
lastResyncHonored = 0        -- last /at_resync this worker actually acted on
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
-- WIPE MODE. AdventureTime now rezzes fast enough to put the group straight back on the thing that
-- killed it, ten times over. E3 has the same idea: after a wipe, stop rezzing until someone has zoned.
-- Deliberately NOT auto-detected. "Was that a wipe or six unlucky deaths" is a judgement call, and a
-- rez system that decides on its own to stop rezzing is worse than one that needs a word from you.
-- Cleared by ZONING, not a timer: zoning is the thing that actually means "we have regrouped and are
-- coming back deliberately", which is exactly the condition to start rezzing again.
rezWipe     = false
-- Which corpse the rezzer said it was casting on, so the loot afterwards goes to THAT body rather than
-- whichever one a name search happens to return. Cleared once used.
rezCorpseID = nil
-- FEIGN DEATH. A feigning monk or necro is alive, off the mob's list, and one cast away from being on it
-- again - so it must not be elected rezzer and must not spend a DI. Nothing here checked for it, which
-- means a feign that saved a character could be undone by the rez chain electing them a second later.
-- Read live rather than broadcast: it changes constantly and the only decision that matters is the one
-- this character makes about itself, right now.
function am_feigning()
    local fd = false
    pcall(function() fd = tlo_true(mq.TLO.Me.Feigning()) end)
    return fd
end
-- INVISIBILITY. Same shape as the feign gate and the same reasoning: casting drops invis, so an invis
-- rezzer is one cast away from being visible to everything standing around the corpse - which is
-- usually the exact reason they went invis mid-wipe. The chain has other members; let it move on.
-- The bare Me.Invis rather than a specific type, because any form of it breaks on a cast.
function am_invis()
    local iv = false
    pcall(function() iv = tlo_true(mq.TLO.Me.Invis()) end)
    return iv
end
-- Call of the Wild: the shaman/druid rez AA. Renewable, short reuse, no reagent, and no debuff to hand
-- out - so it is strictly cheaper than any clicky and fires AHEAD of the whole order. Globals, not
-- locals: the main chunk is at 180 of Lua's 200-local ceiling and this is not worth spending two on.
COTW_AA     = 'Call of the Wild'
-- SHORT NAMES FOR CHAT. The announcement used to carry the full item name, and something else parsing
-- group chat reacts to those strings - so a rez was setting off another script. Nothing here needs the
-- real name: the point of the message is "somebody has this body", and Crown or Token says that.
-- The LOG still carries the full name; only what goes out over /gsay is shortened.
REZ_SHORT = { crown = 'Crown', token = 'Token', cotw = 'CotW', divine = 'Divine Rez' }
function rez_short(kind) return REZ_SHORT[kind or ''] or 'rez' end
-- Divine Resurrection: the cleric rez AA. Renewable, no reagent, and it returns more experience than
-- either clicky - so it goes ahead of CotW and the whole clicky order.
-- Globals, not locals: this chunk is at Lua's 200-local ceiling.
DIVINE_SPELL = 'Divine Resurrection'
rezDivine    = true   -- Divine Res fires before CotW and the clickies whenever a holder is up
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
-- TWO FLAGS, NOT ONE. These were a single boolean doing both jobs and the meanings drifted apart:
-- the decline path set "clicked" purely to stop re-evaluating the dialog every tick, and everything
-- downstream then believed a rez had been accepted.
--   rezBoxClicked - we actually pressed it. Arms the corpse watcher.
--   rezBoxSeen    - we have made a decision about this dialog, whatever it was. Stops re-evaluation.
rezBoxClicked  = false -- we pressed it
rezBoxSeen     = false -- we have judged this dialog; do not judge it again every tick
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
-- WHAT EACH ONE SHOUTS. The announce was hardcoded as class name + the entry's say, which is fine as a
-- default and no use at all if you want the raid to read something of your own.
-- Keyed by CLASS AND ABILITY, the same key a combo member uses, because a beastlord has two buttons and
-- should be able to say different things for Mercy and Paragon.
-- Empty or missing = use the default, so clearing the box restores it rather than announcing nothing.
mgbSay = mgbSay or {}
function mgb_say_key(cls, e) return (cls or '?') .. ':' .. ((e and e.key) or '?') end
function mgb_say_default(cls, e)
    return string.format('%s %s inc', MGB_WHO[cls] or cls or '?', (e and e.say) or 'MGB')
end
function mgb_say_text(cls, e)
    local v = mgbSay[mgb_say_key(cls, e)]
    if v and v ~= '' then return v end
    return mgb_say_default(cls, e)
end
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
            pcall(function() mq.cmdf('/rsay %s', mgb_say_text(cls, e)) end)
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
                log('[burns] found E3 config by searching: %s', path_show(path))
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
    log('[burns] parsed %d burn item(s) from %s', #list, path_show(path))
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
    -- SPREAD THAT ACTUALLY SPREADS. Summing the bytes of a name gives nearly the same total for names of
    -- similar length - Sebbun, Nityrc, Stylin and Lunafeet all landed within 200ms of each other, so the
    -- stagger was doing almost nothing however wide the window was.
    -- Multiplying by position makes an anagram or a same-length name land somewhere different.
    local off = 0
    for i = 1, #myName do off = off + myName:byte(i) * i * 37 end
    -- 2-5s, not 8-16s. The wide stagger was sized for a poll that read every watched item in full; since
    -- ability_state started short-circuiting on ready items - and a ready item is the normal state for
    -- most entries most of the time - the opening pass costs a fraction of what it did, so there is far
    -- less to spread out.
    -- The cost of the old number was paid every session: eight to sixteen seconds of an empty Burns tab
    -- on a driver that had already finished everything else.
    -- Still staggered, because five workers reporting in the same instant is what this exists to stop.
    burnStartAt  = mq.gettime() + 2000 + (off % 3000)
    -- 2-3s, not 8-16s: a few small messages, still spread a little so five workers do not all
    -- speak in the same instant.
    clickStartAt = mq.gettime() + 2000 + (off % 1000)
end

-- ===== Rez target priority: a reorderable, persisted list (top gets rezzed first) =====
local REZ_FILE
local function rez_file_path()
    if REZ_FILE then return REZ_FILE end
    local cfg = ''; pcall(function() cfg = tostring(mq.TLO.MacroQuest.Path('config')() or '') end)
    -- Settings folder, with the old flat path as a read fallback. Written to the new one from then on.
    REZ_FILE = at_read('adventuretime_rezpriority.txt')
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
-- ===== WHERE STATE LIVES: lua\adventuretime\Settings\ =====
-- Probe before mkdir, for the reason spelled out at the log folder above: lfs.mkdir reports false when
-- the directory already exists, so treating that as failure spawned a shell every single startup.
-- Falls back to the old flat config folder if the folder cannot be made or written - losing the tidy
-- layout is a nuisance, losing settings is not.
AT_DIR = nil
function at_dir()
    if AT_DIR ~= nil then return AT_DIR end
    local cfg = ''
    pcall(function() cfg = tostring(mq.TLO.MacroQuest.Path('config')() or '') end)
    local flat = (cfg ~= '') and (cfg .. '\\') or ''
    local sub  = (AT_MODULE_DIR ~= '' and AT_MODULE_DIR or flat) .. 'Settings'
    if sub == 'Settings' then AT_DIR = flat; return AT_DIR end
    local probe = sub .. '\\.atwrite'
    local pf = io.open(probe, 'w')
    if not pf then
        local made = false
        pcall(function() local lfs = require('lfs'); made = lfs.mkdir(sub) end)
        if not made then pcall(function() os.execute('mkdir "' .. sub .. '"') end) end
        pf = io.open(probe, 'w')
    end
    if pf then
        pf:close(); pcall(function() os.remove(probe) end)
        AT_DIR = sub .. '\\'
    else
        AT_DIR = flat
    end
    return AT_DIR
end

-- Where a state file is WRITTEN. Always the new folder.
function at_write(name) return at_dir() .. name end
-- Where a state file is READ from. New folder if something is there, otherwise the old flat location -
-- so an existing install is picked up on first run with nothing copied anywhere. Whatever is loaded is
-- then saved to the new path by the normal save, and the old file is simply never read again.
function at_read(name)
    local newp = at_dir() .. name
    local f = io.open(newp, 'r')
    if f then f:close(); return newp end
    local cfg = ''
    pcall(function() cfg = tostring(mq.TLO.MacroQuest.Path('config')() or '') end)
    if cfg == '' then return newp end
    local oldp = cfg .. '\\' .. name
    local g = io.open(oldp, 'r')
    if g then g:close(); return oldp end
    return newp
end

-- ONE SETTINGS FILE FOR THE GROUP. It was per character because a worker's save wrote all 35 keys from
-- its own state - and a worker has no UI, so its layout keys are always defaults. One broadcast setting
-- change and eleven workers overwrote the driver's customised layout with blanks. That is not a
-- concurrency problem, it is a CONTENT problem, and the fix is that workers do not save at all: they
-- cannot customise anything, they receive every shared value by broadcast, and a worker is only ever
-- launched by a driver, so it never needs a file of its own.
-- Nothing in here is genuinely per character - pacGem is keyed by character inside the value, mgbSay by
-- class and ability - so one file loses nothing.
SETTINGS_NAME = 'adventuretime_settings.txt'
local function settings_path() return at_write(SETTINGS_NAME) end
-- Declared above save_settings and load_settings so neither can see it nil. It works either way -
-- nothing calls those during chunk load - but a global used 260,000 characters before it is created is
-- a footgun for whoever edits this next.
invisPick = invisPick or {}   -- [ITU|Invis] = character name
-- ROWS THE USER HAS TURNED OFF in Countermeasures. Separate from the automatic hiding, which drops a row
-- when NOBODY owns it: this is for things you do own and do not want on the panel.
-- Keyed by the row's group name, which is what the panel shows and what Settings lists.
cmOff = cmOff or {}
function cm_hidden(g) return cmOff[tostring(g or '')] == true end
local function save_settings()
    -- DRIVER ONLY. A worker has no UI, so every layout key it holds is a default - and it saves whenever
    -- a broadcast setting arrives. Letting it write meant one gem change on the driver was followed by
    -- eleven workers replacing the shared file with their own blank layout.
    -- Nothing is lost: a worker is launched by a driver and gets every shared value by broadcast, so it
    -- has nothing of its own worth keeping.
    if not SHOW_UI then return end
    pcall(function()
        local f = io.open(settings_path(), 'w')
        if f then
            f:write('rezAuto=' .. (rezAuto and '1' or '0') .. '\n')
            f:write('rezAccept=' .. (rezAccept and '1' or '0') .. '\n')
            f:write('rezCotw=' .. (rezCotw and '1' or '0') .. '\n')
            f:write('rezDivine=' .. (rezDivine and '1' or '0') .. '\n')
            f:write('diLadderOff=' .. (DI.ladderOff and '1' or '0') .. '\n')
            for _, k in ipairs({ 'tribute', 'pots', 'burns', 'rez' }) do
                f:write('show_' .. k .. '=' .. (showSec[k] and '1' or '0') .. '\n')
            end
            f:write('diAuto=' .. (DI.auto and '1' or '0') .. '\n')
            f:write('miniRez=' .. (miniRez and '1' or '0') .. '\n')
            f:write('miniDI=' .. (miniDI and '1' or '0') .. '\n')
            f:write('miniCombos=' .. (miniCombos and '1' or '0') .. '\n')
            f:write('miniInvisRows=' .. (miniInvisRows and '1' or '0') .. '\n')
            f:write('miniInvisCombo=' .. (miniInvisCombo and '1' or '0') .. '\n')
            for _, g in ipairs({ 'ITU', 'Invis' }) do
                if invisPick[g] then f:write('invispick_' .. g .. '=' .. invisPick[g] .. '\n') end
            end
            -- Only the HIDDEN ones are written, so a row added later shows by default rather than
            -- inheriting a stale off state from a file that predates it.
            for g, v in pairs(cmOff) do
                if v then f:write('cmoff_' .. g:gsub(' ', '_') .. '=1\n') end
            end
            f:write('miniCures=' .. (miniCures and '1' or '0') .. '\n')
            f:write('miniArcane=' .. (miniArcane and '1' or '0') .. '\n')
            f:write('miniPhantom=' .. (miniPhantom and '1' or '0') .. '\n')
            f:write('miniPlacate=' .. (miniPlacate and '1' or '0') .. '\n')
            f:write('miniPacify=' .. (miniPacify and '1' or '0') .. '\n')
            do
                local po = {}
                for pn, pv in pairs(pacOff) do if pv then po[#po + 1] = pn end end
                table.sort(po)
                f:write('pacOff=' .. table.concat(po, ',') .. '\n')
                local pg = {}
                for pn, pv in pairs(pacGem) do pg[#pg + 1] = pn .. ':' .. tostring(pv) end
                table.sort(pg)
                f:write('pacGem=' .. table.concat(pg, ',') .. '\n')
            end
            do
                local fold = {}
                for fk, fv in pairs(miniFold) do if fv then fold[#fold + 1] = fk end end
                table.sort(fold)
                f:write('miniFold=' .. table.concat(fold, ',') .. '\n')
            end
            f:write('miniNightveil=' .. (miniNightveil and '1' or '0') .. '\n')
            f:write('epGem=' .. tostring(epGem or 8) .. '\n')
            f:write('miniMagic=' .. (miniMagic and '1' or '0') .. '\n')
            f:write('miniOrder=' .. table.concat(miniOrder, ',') .. '\n')
            f:write('miniMode=' .. (miniMode and '1' or '0') .. '\n')
            f:write('uiLocked=' .. (uiLocked and '1' or '0') .. '\n')
            do
                local sk = {}
                for nm, md in pairs(chainMode) do sk[#sk + 1] = nm .. ':' .. md end
                table.sort(sk)
                f:write('chainMode=' .. table.concat(sk, ',') .. '\n')
            end
            f:write('miniBurnView=' .. tostring(miniBurnView) .. '\n')
            f:write('charOrder=' .. table.concat(charOrder, ',') .. '\n')
            f:write('miniBurnFilter=' .. tostring(miniBurnFilter) .. '\n')
            f:write('miniBurns=' .. (miniBurns and '1' or '0') .. '\n')
            f:write('miniPots=' .. (miniPots and '1' or '0') .. '\n')
            f:write('miniClicks=' .. (miniClicks and '1' or '0') .. '\n')
            f:write('miniCoth=' .. (miniCoth and '1' or '0') .. '\n')
            f:write('xtankAnnounce=' .. (xtankAnnounce and '1' or '0') .. '\n')
            -- One line per override. Only the ones that differ from the default are written, so the file
            -- stays small and a changed default still reaches anyone who never customised that class.
            for k, v in pairs(mgbSay) do
                if v and v ~= '' then f:write('mgbsay_' .. k .. '=' .. v .. '\n') end
            end
            -- Persisted now that it is a Settings checkbox. It never was before: on the top button
            -- row it was a per-session toggle you re-ticked after every reload, which is fine for a
            -- button and useless for a preference.
            f:write('autoXTank=' .. (autoXTank and '1' or '0') .. '\n')
            f:write('xtankPinned=' .. table.concat(xtankPinned, ',') .. '\n')
            f:close()
        end
    end)
end
local function load_settings()
    pcall(function()
        -- FIRST RUN PICKS UP AN EXISTING INSTALL, with nothing copied anywhere. Try the new shared file;
        -- then this character's old per-character file, which is where a current setup's real
        -- customisation lives; then the pre-per-character shared file from before that.
        -- Whatever is found is loaded and then written to the new path by the next save, so the old
        -- files are simply never read again. No migration step, no copying, nothing to go wrong twice.
        local cfg = ''
        pcall(function() cfg = tostring(mq.TLO.MacroQuest.Path('config')() or '') end)
        local who = ''
        pcall(function() who = tostring(mq.TLO.Me.Name() or '') end)
        local base = (cfg ~= '') and (cfg .. '\\') or ''
        local tries = {
            -- at_write, NOT at_read: at_read falls back to the flat file of the SAME NAME, which is the
            -- stale pre-per-character shared file - and it would win over this character's real settings.
            -- The new path has to be tried on its own, with the older ones ranked deliberately below it.
            at_write(SETTINGS_NAME),
            (who ~= '') and (base .. 'adventuretime_settings_' .. who .. '.txt') or nil,
            base .. 'adventuretime_settings.txt',
        }
        local f, from
        for _, path in ipairs(tries) do
            if path then
                local h = io.open(path, 'r')
                if h then f, from = h, path; break end
            end
        end
        if not f then return end
        SETTINGS_LOADED_FROM = from
        for line in f:lines() do
            -- [%w_] not %w: the show_* keys carry an underscore, so the old pattern returned nil for
            -- them and the k:match below threw. Wrapped in pcall, that aborted the WHOLE load on the
            -- second line of the file - every setting after rezAuto silently never restored.
            -- CUSTOM ANNOUNCE TEXT HAS SPACES IN IT, and the general pattern below demands a value with
            -- none - it would silently drop every one. Handled first, with its own pattern. The general
            -- match cannot collide: these keys contain a colon, which [%w_]+ does not accept.
            local sk, sv = line:match('^mgbsay_([%w:_]+)%s*=%s*(.-)%s*$')
            if sk then mgbSay[sk] = (sv ~= '') and sv or nil end
            local k, v = line:match('^([%w_]+)%s*=%s*(%S+)%s*$')
            if k then
            if k == 'rezAuto' then rezAuto = (v == '1' or v:lower() == 'true') end
            if k == 'rezAccept' then rezAccept = (v == '1' or v:lower() == 'true') end
            if k == 'rezCotw' then rezCotw = (v == '1' or v:lower() == 'true') end
            if k == 'rezDivine' then rezDivine = (v == '1' or v:lower() == 'true') end
            if k == 'diLadderOff' then DI.ladderOff = (v == '1') end
            local sec = k:match('^show_(%w+)$')
            if sec and showSec[sec] ~= nil then showSec[sec] = (v == '1' or v:lower() == 'true') end
            if k == 'diAuto'    then DI.auto   = (v == '1' or v:lower() == 'true') end
            if k == 'miniRez'   then miniRez   = (v == '1' or v:lower() == 'true') end
            if k == 'miniDI'    then miniDI    = (v == '1' or v:lower() == 'true') end
            if k == 'miniCombos' then miniCombos = (v == '1' or v:lower() == 'true') end
            if k == 'miniInvisRows'  then miniInvisRows  = (v == '1' or v:lower() == 'true') end
            if k == 'miniInvisCombo' then miniInvisCombo = (v == '1' or v:lower() == 'true') end
            local ig = k:match('^invispick_(%a+)$')
            if ig and v ~= '' then invisPick[ig] = v end
            local cg = k:match('^cmoff_([%w_]+)$')
            if cg and v == '1' then cmOff[cg:gsub('_', ' ')] = true end
            if k == 'miniCures' then miniCures  = (v == '1' or v:lower() == 'true') end
            if k == 'miniArcane' then miniArcane = (v == '1' or v:lower() == 'true') end
            if k == 'miniPhantom' then miniPhantom = (v == '1' or v:lower() == 'true') end
            if k == 'miniPlacate' then miniPlacate = (v == '1' or v:lower() == 'true') end
            if k == 'miniPacify' then miniPacify = (v == '1' or v:lower() == 'true') end
            if k == 'pacOff' then
                pacOff = pacOff or {}
                for pn in pairs(pacOff) do pacOff[pn] = nil end
                for n in tostring(v or ''):gmatch('[^,]+') do if n ~= '' then pacOff[n:lower()] = true end end
            end
            if k == 'pacGem' then
                pacGem = pacGem or {}
                for pn in pairs(pacGem) do pacGem[pn] = nil end
                for ent in tostring(v or ''):gmatch('[^,]+') do
                    local pn, pv = ent:match('^(.-):(%d+)$')
                    if pn then pacGem[pn:lower()] = tonumber(pv) end
                end
            end
            if k == 'miniFold' then
                miniFold = miniFold or {}
                for fname in pairs(miniFold) do miniFold[fname] = nil end   -- clear in place, keep the table
                for n in tostring(v or ''):gmatch('[^,]+') do if n ~= '' then miniFold[n] = true end end
            end
            if k == 'miniNightveil' then miniNightveil = (v == '1' or v:lower() == 'true') end
            if k == 'epGem' then epGem = math.max(1, math.min(12, tonumber(v) or 8)) end
            if k == 'miniMagic' then miniMagic  = (v == '1' or v:lower() == 'true') end
            if k == 'miniMode' then miniMode = (v == '1' or v:lower() == 'true') end
            if k == 'uiLocked' then uiLocked = (v == '1' or v:lower() == 'true') end
            if k == 'chainMode' then
                chainMode = {}
                for ent in tostring(v or ''):gmatch('[^,]+') do
                    local nm, md = ent:match('^(.-):(.+)$')
                    if nm and (md == 'off' or md == 'raid') then chainMode[nm:lower()] = md end
                end
            end
            -- Migration: old files carry miniBurnTable, new ones miniBurnView. Reading both means an
            -- upgrade keeps whichever view was in use rather than silently resetting it.
            if k == 'miniBurnTable' then miniBurnView = (v == '1' or v:lower() == 'true') and 2 or 1 end
            if k == 'miniBurnView' then miniBurnView = math.max(0, math.min(2, tonumber(v) or 1)) end
            if k == 'xtankAnnounce' then xtankAnnounce = (v == '1' or v:lower() == 'true') end
            if k == 'autoXTank'     then autoXTank     = (v == '1' or v:lower() == 'true') end
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
    -- PER CHARACTER. This was one shared file for every toon on the machine, so running a second box
    -- overwrote the first's rez order - the B team's driver came up showing the A team's crowns, because
    -- whichever saved last won.
    -- The path is ALWAYS the per-character one, so writes can never collide again. The old shared file is
    -- only consulted when loading, and only if no per-character file exists yet - see load_rez_order.
    local who = ''
    pcall(function() who = tostring(mq.TLO.Me.Name() or '') end)
    local base = (cfg ~= '') and (cfg .. '\\') or ''
    -- Per character for real: this is THIS toon's place in the chain, not a group setting.
    REZ_ORDER_FILE = at_read('adventuretime_rezorder_' .. ((who ~= '') and who or 'unknown') .. '.txt')
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

-- WHERE IS THE EMBLEM SOCKETED? An aug is readable as a sub-item of whatever it sits in -
-- Me.Inventory[slot].Item[n] - so the equipped slots can be walked to find it.
-- Worth knowing because the click only works from a CHARM. FindItem finds the aug wherever it is, so
-- the current check says "you have it" for an emblem sitting in a primary, and then the summon quietly
-- does nothing. That note in the settings tooltip is the only thing that has been enforcing it.
-- Returns slot name and aug index, or nil.
AUG_SLOTS = { 'charm', 'mainhand', 'offhand', 'ranged', 'head', 'chest', 'arms', 'wrist', 'hands',
              'legs', 'feet', 'neck', 'back', 'waist', 'ear1', 'ear2', 'ring1', 'ring2',
              'leftfinger', 'rightfinger', 'shoulder', 'face', 'powersource' }
-- Find a named aug in any equipped slot. Returns slot, aug index, and the item carrying it.
-- Generic because two things need it now: the CoTH emblem and the Nightveil emblem, both of which only
-- fire from a charm and both of which FindItem will happily report from a bag.
function find_aug(name)
    for _, slot in ipairs(AUG_SLOTS) do
        local carrier = ''
        pcall(function() carrier = tostring(mq.TLO.Me.Inventory(slot).Name() or '') end)
        if carrier ~= '' then
            for a = 1, 6 do
                local aug = ''
                pcall(function() aug = tostring(mq.TLO.Me.Inventory(slot).Item(a).Name() or '') end)
                if aug ~= '' and aug:lower() == (name or ''):lower() then
                    return slot, a, carrier
                end
            end
        end
    end
    return nil
end
function coth_find_aug() return find_aug(COTH.ITEM) end

-- Say where it is and whether that will actually work. Called by /atcothaug and once at startup.
function coth_aug_report(quiet)
    local slot, idx, carrier = coth_find_aug()
    if not slot then
        local loose = 0
        pcall(function() loose = tonumber(mq.TLO.FindItemCount('=' .. COTH.ITEM)()) or 0 end)
        if loose > 0 then
            log('[coth] %s is in your bags rather than socketed - that is fine, it clicks from there', COTH.ITEM)
        elseif not quiet then
            log('[coth] no %s found on this character', COTH.ITEM)
        end
        return false
    end
    if slot == 'charm' then
        if not quiet then
            log('\\ag[coth] %s is aug %d in %s (charm) - good\\ax', COTH.ITEM, idx, carrier)
        end
        return true
    end
    -- Socketed, but somewhere the click will not reach.
    log('\\ar[coth] %s is aug %d in %s (%s) - it must be in a CHARM to work\\ax',
        COTH.ITEM, idx, carrier, slot)
    return false
end

function coth_read_self()
    -- OWNING IT IS NOT THE SAME AS BEING ABLE TO CLICK IT. FindItem finds the emblem wherever it is -
    -- bags, a primary, a charm - so this reported "have it, ready" for an emblem that could never fire,
    -- and the gather then picked that character as a summoner and got nothing.
    -- Only a charm counts. Checked once and cached: augs do not move mid-fight, and walking twenty-odd
    -- equipment slots every read would be silly.
    -- USABLE FROM A BAG. This used to require the aug to sit in an EQUIPPED charm, mirroring the rule
    -- the Nightveil emblem really does have (EffectType 4, "Click Worn"). The Wayfarers emblem does not
    -- share that rule - it fires perfectly well from a charm sitting in a bag, and the click at the
    -- bottom of this file has always used FindItem by name, which reaches into bags.
    -- So the gate was stricter than the click: find_aug walks equipped slots only, returned nil for a
    -- bagged charm, and this character reported "no emblem" while being entirely capable of summoning.
    -- The test now is simply whether the client can find the item at all.
    -- NOT CACHED WHEN FALSE. The old cache latched on the first look and never re-checked, so moving the
    -- charm into a bag disabled the character until a reload - and moving it back did not bring it back.
    local em = -1
    if cothAugOk ~= true then
        local found = 0
        pcall(function() found = tonumber(mq.TLO.FindItem('=' .. COTH.ITEM).ID()) or 0 end)
        cothAugOk = (found > 0)
        if not cothAugOk then coth_aug_report(true) end
    end
    if cothAugOk then
        pcall(function()
            if (tonumber(mq.TLO.FindItem('=' .. COTH.ITEM).ID()) or 0) > 0 then
                em = tonumber(mq.TLO.FindItem('=' .. COTH.ITEM).TimerReady()) or 0
            end
        end)
    end
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
            -- REPORT WHAT WE ACTUALLY KNOW ABOUT THEM. "never arrived" on its own does not say whether
            -- they moved at all, whether their report is stale, or whether they are simply out of range.
            local st = COTH.state[pn]
            if st then
                rezlog('[coth] %s never arrived - releasing (their last report: %ds away, los=%d, %dms old)',
                       pn, st.dist or -1, st.los or 0, now - (st.updated or now))
            else
                rezlog('[coth] %s never arrived - releasing (NO report from them at all)', pn)
            end
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

    -- ONE SUMMONER AT A TIME, DECIDED THE SAME WAY BY EVERYONE.
    -- The claim below is set locally and THEN broadcast, which is a race: on 2026-08-06 Sebbun, Sunetoo
    -- and Nityrc all fired at Lunafeet within 400ms, each seeing no claim because none of the broadcasts
    -- had landed yet. Three emblems spent on one summon.
    -- A claim cannot fix that on its own - whoever checks first still wins, and "first" is decided by
    -- network timing. So the choice is COMPUTED instead: every toon sorts the ready holders the same way
    -- and only the top one acts. Nothing has to arrive in time, because nothing is sent.
    -- The cascade still works: as each summoner's emblem goes on cooldown it drops out of the list and
    -- the next one takes over, which is the same order it would have happened in anyway.
    do
        local ready = {}
        for _, nm in ipairs(group_members()) do
            if coth_gathered(nm) then
                local st = COTH.state[nm]
                -- Fresh reports only. A stale one would keep electing a toon that has since spent its
                -- emblem, and the gather would stall waiting on somebody who cannot act.
                if st and (now - (st.updated or 0)) < 6000 and (st.emblem or -1) == 0 then
                    ready[#ready + 1] = nm
                end
            end
        end
        table.sort(ready, function(a, b) return a:lower() < b:lower() end)
        -- EVERY READY HOLDER SUMMONS, EACH A DIFFERENT TARGET. This let only ready[1] act, so a gather
        -- was one summon at a time however many emblems were standing there - and the cascade never
        -- happened. coth_targets already puts emblem-holders at the FRONT of the list, so the first
        -- people brought in are the ones who can then help: one summons one, two summon two, four
        -- summon four.
        -- Split by POSITION, not by a claim. Every toon computes the same ready list and the same target
        -- list from the same shared state, so summoner N takes target N with nothing sent and nothing to
        -- arrive in time. That is what the single-summoner rule was protecting against - three emblems
        -- landing on one target because no broadcast had propagated yet - and slicing by index gives the
        -- same guarantee without serialising the whole gather.
        local myTurn = nil
        for i, nm in ipairs(ready) do
            if nm:lower() == myName:lower() then myTurn = i; break end
        end
        if not myTurn then
            COTH.dbg = (#ready > 0) and ('summoners: ' .. table.concat(ready, ', ')) or 'nobody ready'
            return
        end
        -- My slice of the queue: targets myTurn, myTurn+#ready, myTurn+2*#ready ...
        local mine = {}
        for i = myTurn, #left, #ready do mine[#mine + 1] = left[i] end
        left = mine
        if #left == 0 then
            COTH.dbg = string.format('summoner %d of %d - nothing in my slice', myTurn, #ready)
            return
        end
    end

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
                -- SAY WHAT STATE WE FIRED FROM. "never arrived" covers two completely different failures -
                -- the cast never went, or it went and the arrival was not seen - and the log could not
                -- tell them apart. Observed 2026-08-05: every FIRST summon of a gather failed and every
                -- retry worked, on the same character, which fits an interrupted cast far better than a
                -- detection problem. The emblem has a cast time and NoInterrupt does not stop MOVEMENT
                -- from breaking it, and the first summon fires while the group is still settling.
                local emT, mv = -1, 0
                pcall(function() emT = tonumber(mq.TLO.FindItem('=' .. COTH.ITEM).TimerReady()) or -1 end)
                pcall(function() mv = tonumber(mq.TLO.Me.Speed()) or 0 end)
                rezlog('[coth] summoning %s (%d) - my emblem timer %s, my speed %.1f', nm, tid,
                       (emT == 0) and 'ready' or tostring(emT), mv)
                -- Same cursor rule before the emblem click. Best effort only here: a CoTH that does not
                -- go out strands somebody, which is worse than the risk of clicking while holding.
                cursor_stow('coth')
                pcall(function() mq.cmdf('/nowcast me "%s%s" %d', COTH.ITEM, COTH.OPTS, tid) end)
                -- DID A CAST ACTUALLY START? One look shortly after. If nothing is being cast the click
                -- never took, and no amount of waiting for an arrival will help.
                mq.delay(600)
                local castingNow, castName = 0, ''
                pcall(function() castingNow = tonumber(mq.TLO.Me.Casting.ID()) or 0 end)
                pcall(function() castName = tostring(mq.TLO.Me.Casting.Name() or '') end)
                if castingNow > 0 then
                    rezlog('[coth]   cast started: %s', (castName ~= '') and castName or tostring(castingNow))
                else
                    rezlog('\\ay[coth]   NO CAST STARTED - the click did not take (moving? interrupted? on cooldown?)\\ax')
                end
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
    -- 6s, NOT 12. This gap only ever costs time when a rung FAILS: the tank-save gate runs before the
    -- ladder and exits the moment a save appears, so a rung that works never waits this out.
    -- The number to cover is therefore the DETECTION lag, not the worst case ever observed - and the
    -- comment below records that measured lag as under four seconds.
    -- What it was really protecting against was firing again at a tank that was already covered, and
    -- 1.09.13 now re-checks that immediately before spending a rung. The gap no longer has to do that job.
    RUNG_GAP = 6000,
    -- How long SpellReady must stay false before it is believed. A real cooldown holds it false for
    -- minutes; a global cooldown or an in-flight cast blinks it for well under a second.
    -- A gem within this many seconds of ready counts as ready. Above it, something genuinely cast it -
    -- us, E3, or the player by hand - and the rung is spent. Separates a global cooldown from a recast.
    RUNG_READY_SLACK = 5,
    -- ITEMS NEED LONGER, because their cooldown read is the slow one. Spell and AA rungs have reported in
    -- 2-5s every time; the boots took ~13s on 2026-07-30 (cast 22:35:21.9, save on Sebbun 22:35:35.4) and
    -- lagged 29s in an earlier session. At a flat 12s the boots were re-cast one second before the first
    -- one registered. One gap cannot serve both, and erring long is cheap: the tank-save gate runs before
    -- the ladder, so a landed save means the ladder is never reached and this delay never applies.
    -- 10s, NOT 25. Same reasoning, with more room because the boots' own cooldown read is the slow one.
    -- The 25 came from two outlier observations - 13s once, 29s another time - but both were measured in
    -- sessions where the ladder was firing at an ALREADY-COVERED tank, so no new save could ever appear
    -- and the wait was always going to run out in full. That case is fixed; the outliers were the bug.
    -- The cost of being wrong here is one duplicate save. The cost of being wrong the other way is the
    -- tank standing uncovered for 25 seconds, which is a wipe.
    RUNG_GAP_ITEM = 10000,
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

-- REMEMBER THE FIRE ACROSS A RESTART.
-- Every character reads TimerReady=0 and ItemReady=true at load - the 'staff reads at load' line says so
-- on all of them, including staffs that are certainly on cooldown. So a restarted AdventureTime believes
-- every staff in the group is ready, offers one, and the cast goes nowhere.
-- The client cannot be asked about this, so remember it ourselves: one line per character holding when
-- the staff was last fired. os.time() rather than gettime(), because gettime restarts with the script.
function di_staff_stamp_path()
    local cfg = ''
    pcall(function() cfg = tostring(mq.TLO.MacroQuest.Path('config')() or '') end)
    local who = (myName ~= '') and myName or 'unknown'
    return ((cfg ~= '') and (cfg .. '\\') or '') .. 'adventuretime_distaff_' .. who .. '.txt'
end

function di_staff_stamp_write()
    pcall(function()
        local f = io.open(di_staff_stamp_path(), 'w')
        if f then f:write(tostring(os.time())); f:close() end
    end)
end

-- Called once at load. If the staff was fired recently enough to still be in reuse, put the assume-spent
-- brake back where it would have been - which is the same brake a running instance would have had.
function di_staff_stamp_read()
    local when = 0
    pcall(function()
        local f = io.open(di_staff_stamp_path(), 'r')
        if f then when = tonumber(f:read('*a') or '0') or 0; f:close() end
    end)
    if when <= 0 then return end
    local ago = os.time() - when
    local reuse = DI.ASSUME_SPENT / 1000
    if ago >= 0 and ago < reuse then
        DI.assumeSpentUntil = mq.gettime() + ((reuse - ago) * 1000)
        rezlog('\\ay[di] my staff was fired %ds ago (before this restart) - treating it as spent for %ds\\ax',
               ago, reuse - ago)
    end
end

function di_read_self()
    local staff = di_raw_staff()
    -- ONCE, ON EVERY TOON. This used to sit inside the cleric-only block, so the only staff we ever saw
    -- probed was Nityrc's - the one that reads honestly. Sunetoo's is the one that lies, and we had no
    -- reading of it at all.
    if not DI.saidStaffReads then
        DI.saidStaffReads = true
        rezlog('[di] staff reads at load: %s', di_staff_reads())
        -- Every one of those reads says ready at load whether or not it is, so put back what we know.
        di_staff_stamp_read()
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
-- Runs on the CASTER after it fires. Answers "did my cast actually start" from local reads, and tells
-- the tank at once if it did not - which is far faster than the tank timing out.
function diq_self_check()
    local s = DIQ.self
    if not s then return end
    -- Casting means it went out. Nothing more to watch here; the normal verify owns what happens next.
    local casting = 0
    pcall(function() casting = tonumber(mq.TLO.Me.Casting.ID()) or 0 end)
    if casting > 0 then DIQ.self = nil; return end
    -- ItemReady flipping false is the other proof - a boolean, so it cannot lag the way a countdown does.
    if DI.itemReadyWorks and not tlo_true(DI.itemReady) then DIQ.self = nil; return end
    -- AND THE COOLDOWN ITSELF STARTING, which is the most direct proof of all: if the thing went off, its
    -- reuse is now counting. Better than watching Me.Casting for a spell or an AA, where the cast can be
    -- over before we next look - the cooldown stays visible for minutes afterwards.
    local secs = di_raw_staff()
    if secs > 0 then DIQ.self = nil; return end
    -- Give it a moment: a cast does not register in the same instant the command is sent.
    if (mq.gettime() - s.at) < DIQ_SELF_MS then return end
    -- Neither signal ever appeared. The cast did not happen.
    rezlog('\\ay[diq] my cast never started - telling %s to ask somebody else\\ax', s.tank)
    pcall(function() peer_cmdf(s.tank, '/at_diack %s no cast-never-started', myName) end)
    DIQ.self = nil
    DI.watch = nil                 -- nothing to verify; do not hold the slot for 45s
    DI.assumeSpentUntil = nil      -- and it was not spent, so do not pretend it was
    DI.pushNow = true              -- correct the record as promptly as we spoiled it
    pcall(function() os.remove(di_staff_stamp_path()) end)   -- nor across a restart
end

-- Runs on the TANK, every tick. This is the whole fast path.
function diq_tick()
    local tank = di_tank()
    if not tank or tank:lower() ~= myName:lower() then return end   -- only the tank drives this
    -- DI.auto, NOT diOn. There is no such variable as diOn anywhere in this file - it was nil, so this
    -- returned on every single call and the whole fast path never ran once on 1.09.16. Nothing errored,
    -- nothing logged; it simply did nothing, which is the hardest kind of wrong to notice.
    if not DI.auto then return end

    local inCombat = false
    pcall(function() inCombat = (tostring(mq.TLO.Me.CombatState() or ''):upper() == 'COMBAT') end)

    -- MY OWN SAVE, READ LOCALLY. No report, no lag - this is the fact the whole system turns on and the
    -- tank is the only character that has it immediately.
    local haveSave = false
    for _, b in ipairs(DI.SAVES) do
        local up = false
        pcall(function() up = (tonumber(mq.TLO.Me.Buff(b).ID()) or 0) > 0 end)
        if up then haveSave = true; break end
    end

    if haveSave or not inCombat then
        if DIQ.active then
            -- Covered, or the fight is over. Tell everyone to stand down so nobody spends a second save
            -- on the strength of a report that has not caught up yet.
            rezlog('[diq] covered%s - standing the group down after %.1fs',
                   haveSave and '' or ' (out of combat)', (mq.gettime() - DIQ.startedAt) / 1000)
            pcall(function() peer_bcast('/at_disaved %d', DI.SAVED_HOLD) end)
            DIQ.active, DIQ.asked, DIQ.tried, DIQ.casting = false, nil, {}, nil
            DIQ.saidLong = nil
            DIQ.exhaustedUntil = nil
        end
        return
    end

    -- Still standing back from an exhausted round.
    if DIQ.exhaustedUntil and mq.gettime() < DIQ.exhaustedUntil then return end

    -- No save, in combat. Start asking.
    if not DIQ.active then
        DIQ.active, DIQ.tried, DIQ.startedAt = true, {}, mq.gettime()
        DIQ.asked = nil
        rezlog('[diq] my save is down - asking the group')
    end

    -- NOTHING TO HAND OVER TO. This used to stop after DIQ_GIVEUP_MS and let the old ladder try - but the
    -- ladder is gone, so stopping meant the tank simply gave up while still uncovered. On 2026-08-14
    -- 06:04:54 it announced "handing over to the old ladder" and then nothing happened at all.
    -- Keep asking instead. An emergency does not stop being an emergency because it has lasted a while,
    -- and the backoff below already stops this from spinning when nobody can help.
    if (mq.gettime() - DIQ.startedAt) > DIQ_GIVEUP_MS then
        if not DIQ.saidLong then
            DIQ.saidLong = true
            rezlog('\\ay[diq] still no save after %.0fs - still asking\\ax', DIQ_GIVEUP_MS / 1000)
        end
        -- A fresh round: anyone who declined a while ago may have come off cooldown since.
        DIQ.tried, DIQ.startedAt = {}, mq.gettime()
    end

    -- A CLAIM OUTRANKS EVERYTHING. Somebody is mid-cast; asking a second character or falling through to
    -- the ladder now is how one emergency costs two saves.
    if DIQ.casting then
        if (mq.gettime() - DIQ.castAt) < DIQ_CAST_MS then return end
        -- Reaching here means a cast that was claimed never produced a save in fifteen seconds. That is
        -- a failure worth seeing rather than a routine step.
        rezlog('\\ay[diq] %s claimed a cast %.0fs ago and no save ever appeared - trying somebody else\\ax',
               DIQ.casting, (mq.gettime() - DIQ.castAt) / 1000)
        DIQ.tried[DIQ.casting:lower()] = true
        DIQ.casting, DIQ.asked = nil, nil
    end

    -- Waiting on an answer? A 'no' clears DIQ.asked immediately; this only catches silence.
    if DIQ.asked then
        if (mq.gettime() - DIQ.at) < DIQ_ANSWER_MS then return end
        rezlog('[diq] %s did not answer in %dms - next', DIQ.asked, DIQ_ANSWER_MS)
        DIQ.tried[DIQ.asked:lower()] = true
        DIQ.asked = nil
    end
    diq_ask_next(tank)
end

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



-- A staff came back up. Pull the baton forward to that toon if they sit earlier in the ring than whoever
-- holds it now - the ring belongs at the front, and a returning staff is the only thing that should move it
-- backwards. Same rule locally and remotely so every client reaches the same answer from the same fact.



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
    -- Anyone sat out is simply absent from the order, so the baton skips straight past them rather than
    -- being handed over and stalling on a toon that will never fire.
    for _, nm in ipairs(rezPriority) do
        if not chain_off(nm) and rez_rank(member_class(nm)) ~= 1 then out[#out + 1] = nm end
    end
    for _, nm in ipairs(rezPriority) do
        if not chain_off(nm) and rez_rank(member_class(nm)) == 1 then out[#out + 1] = nm end
    end
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
-- ===== TANK-DRIVEN SAVES =====
-- THE TANK ASKS; NOBODY INFERS.
-- The old path has every cleric watching a pushed report of the tank's save, deciding for itself, and
-- coordinating by baton. That is five deciders working from data that is a second or two stale, and
-- nearly every bug tonight came from two of them acting on the same emergency - a duplicate staff, the
-- boots spent on a tank that was already covered.
-- This has ONE decider, and it is the character that knows first: the tank sees its own save drop with a
-- local read and no lag at all.
-- The polled state stops needing to be right. It only orders the candidates; the character actually
-- ASKED checks locally, which is instant and authoritative, and answers yes or no. A stale guess costs
-- one round trip instead of a wasted Donal's Boots.
-- And the waits change character entirely: the old ones sat 12 to 25 seconds waiting for a BUFF TO
-- BECOME OBSERVABLE, which is slow and ambiguous. This waits for an ANSWER, which is fast and definite -
-- so the timeout is about a second, and it means "that client is not responding" rather than "I still
-- cannot tell".
-- The old ladder stays as a fallback while this is proven, and comes out once it is.
DIQ = {
    active   = false,   -- an ask is in flight
    asked    = nil,     -- who we asked
    what     = nil,     -- which save we asked for
    at       = 0,       -- when
    tried    = {},      -- who has already answered no this emergency
    startedAt= 0,
}
DIQ_ANSWER_MS = 1200    -- how long to wait for a yes/no before treating it as silence
-- A CLAIM MEANS IT IS HANDLED. FULL STOP.
-- This was 5000, chosen from how long a cleric's Divine Intervention took to become visible - and it was
-- immediately wrong for the staff, which takes about 4.4s to land plus detection lag. On 2026-08-14
-- 05:49 the claim expired at 5.08s and the tank asked the next character, so two staffs went out five
-- seconds apart for one emergency.
-- Tuning it per cast type is the wrong shape. A character that said yes is casting; there is nothing to
-- wait a measured interval for and nothing to second-guess. So this is no longer a window - it is a
-- CEILING on a cast that has clearly failed, and it is deliberately generous. Reaching it is an
-- exception, not part of the normal path.
-- The asking itself stays instant, because a DECLINE is instant: the fast loop is only ever slowed by
-- somebody who can actually help.
DIQ_CAST_MS = 15000
-- THE STAFF GETS LONGER. Measured: it lands 4.2-4.4s after firing, and the save then has to be seen -
-- so a 5s claim expires a fraction before the tank knows it worked. On 2026-08-14 that gap was 80
-- milliseconds wide and cost a second staff: Ejtou fired at 05:48:59.28, the claim lapsed at 05:49:04.28,
-- Shela fired at 05:49:04.37, and the first one landed at 05:49:08.5.
-- Twelve seconds is comfortably past the observed landing plus the detection lag. The cost of being
-- generous here is a slower retry if a staff genuinely fails; the cost of being tight is a second staff,
-- and the staff is the most expensive thing in the group.
-- How long to stay quiet after finding that nobody has anything. Long enough that the staff chain gets a
-- clear run, short enough that a save coming off cooldown is picked up quickly.
DIQ_EXHAUST_MS = 4000
-- How long to give a cast to show ANY sign of starting. Casting state and ItemReady both move within a
-- few hundred milliseconds of a real cast; this is generous against that.
DIQ_SELF_MS = 1500
DIQ_GIVEUP_MS = 8000    -- whole-emergency ceiling; past this, let the old ladder have it

-- What to ask for, best first. Ordering only - the asked character has the final word.
function diq_candidates()
    local out = {}
    for nm, s in pairs(DI.state or {}) do
        if nm:lower() ~= myName:lower() and not DIQ.tried[nm:lower()] then
            local age = (mq.gettime() - (s.updated or 0)) / 1000
            -- A report older than a minute is not evidence of anything; ask anyway, but last.
            local stale = (age > 60) and 1 or 0
            -- ORDER, NEVER EXCLUDE. This used to drop anyone whose last report showed nothing ready, so
            -- they were never asked at all - and on 2026-08-14 13:17 the tank went straight past Ejtou to
            -- Shela's staff without ever finding out whether Ejtou's gem save had come back.
            -- That is the polled state DECIDING, which is the one thing it must not do: it is up to 20
            -- seconds old, and the whole design rests on the asked character checking locally and having
            -- the final word. A poor report should put somebody last, not remove them.
            -- dgReady covers all three cleric rungs, not just the AA - it is computed from di_rung_list.
            local rank = 0
            if (s.dgReady or 0) == 1 then rank = rank + 2 end
            if (s.staff or -1) == 0 then rank = rank + 1 end
            out[#out + 1] = { nm = nm, rank = rank - stale * 3, age = age }
        end
    end
    table.sort(out, function(a, b)
        if a.rank ~= b.rank then return a.rank > b.rank end
        return a.nm < b.nm
    end)
    return out
end

function diq_ask_next(tank)
    local list = diq_candidates()
    if #list == 0 then
        -- BACK OFF, DO NOT SPIN. Clearing active here let the next tick see no save, reset the tried
        -- list, and ask all five again - twice in two seconds on 2026-08-14 05:31:37.
        -- If nobody had a save 300ms ago, nobody has one now: cooldowns do not turn over that fast. The
        -- pause also gives the old ladder and the staff chain room to do their work without this talking
        -- over them.
        DIQ.exhaustedUntil = mq.gettime() + DIQ_EXHAUST_MS
        rezlog('[diq] nobody has a save - standing back %.0fs and letting the staff chain work',
               DIQ_EXHAUST_MS / 1000)
        DIQ.active = false
        return false
    end
    local pick = list[1]
    DIQ.asked, DIQ.what, DIQ.at = pick.nm, 'save', mq.gettime()
    rezlog('[diq] asking %s for a save on %s (rank %d, report %.0fs old)',
           pick.nm, tank, pick.rank, pick.age)
    pcall(function() peer_cmdf(pick.nm, '/at_dineed %s', tank) end)
    return true
end

-- WHAT IS ABOUT TO BE CAST, in the group's chat, in the short form you actually track by.
--   Divine Intervention -> "Casting DI in Gem 1"
--   Divine Redemption   -> "Casting DR in Gem 1"
--   the AA              -> "Casting Guardian AA"
--   the boots           -> "Casting Guardian boots"
-- Said by the CASTER, because it is the only character that knows which gem its own spell sits in.
function di_announce(r, tank)
    -- BY NAME FIRST, kind second. The staff is also kind 'Item', so deciding on kind alone announced it
    -- as "Guardian boots" - which read like a necro and a wizard casting a cleric item they do not own.
    -- They were firing their own staffs perfectly correctly; only the label was wrong.
    local what
    if r.name == DI.STAFF or r.staff then what = 'DI staff'
    elseif r.name == 'Divine Intervention' then what = 'DI in Gem ' .. tostring(r.gem or '?')
    elseif r.name == 'Divine Redemption' then what = 'DR in Gem ' .. tostring(r.gem or '?')
    elseif r.name == DI.DG_BOOT then what = 'Guardian boots'
    elseif r.name == DI.DG_AA then what = 'Guardian AA'
    elseif r.kind == 'Alt'  then what = 'Guardian AA'
    elseif r.kind == 'Item' then what = 'Guardian boots'
    else what = r.name end
    pcall(function() mq.cmdf('/gsay Casting %s on %s', what, tank or '?') end)
    rezlog('[di] announce: Casting %s on %s', what, tank or '?')
    -- CLAIM IT WITH THE TANK. A save takes seconds to become visible - the cleric's DI on 2026-08-14
    -- was cast at 05:26:08.6 and had still not shown at 05:26:11.5 - and during that gap the tank sees no
    -- save, asks everyone, finds nothing left, and falls through to the staff. Then the DI lands and the
    -- staff has been spent for nothing.
    -- Announcing is exactly the right moment to say so, and this function is called by BOTH the old
    -- ladder and the tank-driven path, so one claim covers both without them having to know about each
    -- other. That is the part that was missing: two systems, no shared "something is already in flight".
    pcall(function() peer_cmdf(tank or '', '/at_diclaim %s %s', myName, (r.name or '?'):gsub(' ', '_')) end)
end

-- DID I JUST FIRE THIS? The stamp was written for every rung but only ever READ for the cleric spell,
-- so the AA and the boots had no guard at all - and TimerReady reads 0 for a while after a real fire,
-- exactly as it does for the staff. Ejtou claimed the boots twice 26 seconds apart on 2026-08-14 12:47
-- for that reason.
-- The reuse comes from whichever read applies to the thing: an item carries it on its clicky, an AA on
-- the ability, a spell on the spell. If none of them answers, fall back to a flat minute - long enough
-- to cover the lag, short enough that a genuinely ready rung is not held back for long.
function di_rung_spent(name, kind)
    local fired = DI.rungFiredAt and DI.rungFiredAt[name]
    if not fired then return false end
    local rc = 0
    if kind == 'Item' then
        pcall(function() rc = tonumber(mq.TLO.FindItem('=' .. name).Clicky.TimerID()) or 0 end)
    elseif kind == 'Alt' then
        pcall(function() rc = tonumber(mq.TLO.Me.AltAbility(name).MyReuseTime()) or 0 end)
        if rc <= 0 then pcall(function() rc = tonumber(mq.TLO.Me.AltAbility(name).ReuseTime()) or 0 end) end
    else
        pcall(function() rc = tonumber(mq.TLO.Spell(name).RecastTime()) or 0 end)
    end
    if rc <= 0 then rc = 60 end
    return (mq.gettime() - fired) < (rc * 1000)
end

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
            -- SpellReady AS WELL AS THE GEM TIMER. The gem's refresh is a short per-gem thing; a save
            -- spell also has its own long reuse, and the two are not the same number. Mamittuk's log
            -- shows rung 1 re-firing every 12 seconds - exactly RUNG_GAP - which is what "the timer we
            -- are reading returns to 0 immediately" looks like.
            -- THE GEM'S OWN COOLDOWN, WITH SLACK. This is the number that actually answers the question,
            -- and it answers it for a cast by ANYONE - the script, E3, or the player pressing the gem by
            -- hand - because casting from a gem is what starts that timer. A manual cast was the case
            -- nothing else could see.
            -- SpellReady used to gate this and it was the wrong read: it answers "can I cast this
            -- INSTANT", not "is it off cooldown", so it dropped to false during every global cooldown.
            -- Ejtou's log flipped it 31 times each way in three minutes, and the tank's death save read
            -- as unavailable through about half of them.
            -- The slack is what makes the timer usable on its own: a global cooldown or a cast in flight
            -- leaves a second or two on the gem, a real recast leaves minutes. Five seconds sits well
            -- clear of the first and nowhere near the second, and a save that is within five seconds of
            -- ready is worth waiting for rather than skipping the rung over.
            local rdy = (s >= 0 and s <= DI.RUNG_READY_SLACK)
            -- I FIRED IT, SO IT IS SPENT UNTIL PROVEN OTHERWISE. Same rule the staff already uses, for
            -- the same reason: a state read taken right after an action can lag or lie, and the cost of
            -- believing "ready" wrongly here is casting a death save on a loop forever.
            local spent = di_rung_spent(nm, 'Spell')
            local ready = rdy and not spent
            -- SAY THE INPUTS when the verdict changes. Three rounds were lost on the placate ceiling
            -- guessing at reads instead of printing them; this one prints them.
            -- Change-detected AND rate limited. Change-detection alone printed 62 lines in a 114 line
            -- log, because the thing it was watching flickers by nature.
            local k = string.format('%s/%d/%s', tostring(s), gem, tostring(spent))
            if DI.rungSaid ~= k and (mq.gettime() - (DI.rungSaidAt or 0)) > 30000 then
                DI.rungSaid, DI.rungSaidAt = k, mq.gettime()
                rezlog('[di] rung 1 %s: gem %d, gem timer %ss (slack %ds), assumed-spent %s -> %s',
                       nm, gem, tostring(s), DI.RUNG_READY_SLACK, tostring(spent),
                       ready and 'READY' or 'not ready')
            end
            -- Carry the gem number: the announce says which gem it came from, which is the one detail
            -- that lets you follow along on the caster's own bar rather than taking the log's word.
            out[#out + 1] = { name = nm, kind = 'Spell', ready = ready, gem = gem }
            break                                   -- one or the other is memmed, never both
        end
    end
    -- RUNG 2 - Divine Guardian AA, if we have it. Rank proves ownership, AltAbilityTimer is the cooldown.
    do
        local rank = 0; pcall(function() rank = tonumber(mq.TLO.Me.AltAbility(DI.DG_AA).Rank()) or 0 end)
        if rank > 0 then
            local s = -1
            pcall(function() s = tonumber(mq.TLO.Me.AltAbilityTimer(DI.DG_AA).TotalSeconds()) or -1 end)
            out[#out + 1] = { name = DI.DG_AA, kind = 'Alt',
                              ready = (s == 0) and not di_rung_spent(DI.DG_AA, 'Alt') }
        end
    end
    -- RUNG 3 - the boots, if we carry them. ID proves ownership, TimerReady is the cooldown.
    do
        local id = 0; pcall(function() id = tonumber(mq.TLO.FindItem('=' .. DI.DG_BOOT).ID()) or 0 end)
        if id > 0 then
            local t = -1
            pcall(function() t = tonumber(mq.TLO.FindItem('=' .. DI.DG_BOOT).TimerReady()) or -1 end)
            out[#out + 1] = { name = DI.DG_BOOT, kind = 'Item',
                              ready = (t == 0) and not di_rung_spent(DI.DG_BOOT, 'Item') }
        end
    end
    return out
end


-- di_tick - RETIRED AS A DECIDER.
-- It used to run the whole show: a save ladder with 12 and 25 second waits per rung, and a baton walked
-- around the group a hop at a time to decide whose staff went out. Both are gone.
-- They were removed because two systems deciding the same thing is not a system - it is a race, and
-- every bug in DI over the last week came out of it: the boots spent on a tank that was already covered,
-- two staffs for one emergency, and on 2026-08-14 05:39 three characters each believing they held the
-- baton while the one the tank had actually chosen sat blocked by its own hold.
-- The tank asks now. It is the only character that knows instantly that it needs a save, the character
-- it asks checks its own gems and cooldowns locally - which is authoritative and takes about 25ms - and
-- answers yes or no. See diq_tick.
-- What is left here is the feign and invis guards, which belong to the character rather than to either
-- system. The cast VERIFY is untouched and lives in the main loop, so what happens after a staff goes
-- out is exactly as it was.
local function di_tick()
    if not DI.auto then return end
    -- Feigning: casting DI stands the character up and undoes the feign, and the whole point of a DI is
    -- to keep somebody alive - spending one at the cost of the caster's own life is not a trade worth
    -- making.
    if am_feigning() then
        gate('feigning - not spending a DI')
        return
    end
    -- Invis: the same trade. Casting drops it, and a DI caster who becomes visible standing over a dying
    -- group is usually about to join them.
    if am_invis() then
        gate('invis - not spending a DI')
        return
    end
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
        -- TELL THE GROUP THE EMERGENCY IS OVER, not just that my staff is gone.
        -- A landed staff proves the tank is covered exactly as conclusively as a blocked one does, and
        -- the blocked path already broadcasts this - the success path did not, which left the next toon
        -- in the chain to work it out from the tank's own report. That report lags: on 2026-08-14 the
        -- staff landed at 03:43:37.9, the baton moved the same millisecond, and Sunetoo committed at
        -- 03:43:38.4 with Sebbun still reporting save=0 from 0.2s earlier. Two staffs and four emeralds
        -- for one emergency.
        -- Only when the tank is CONFIRMED carrying it: a staff that came off cooldown without the save
        -- appearing has not covered anybody, and holding the chain on that would be worse than the
        -- duplicate.
        if tankHasOurs then
            DI.savedUntil = mq.gettime() + DI.SAVED_HOLD
            DI.trigAt, DI.turnAt = 0, nil
            pcall(function() peer_bcast('/at_disaved %d', DI.SAVED_HOLD) end)
        end
        -- THE POINT OF THE WHOLE THING. My staff is now spent for its full reuse, which is the one fact
        -- about myself I can establish reliably - so hand the turn on rather than making five other toons
        -- work it out from a timer that lies.
        rezlog('[di] LANDED after %.1fs - %s%s (staff timer reads %ds, %d emerald(s) spent)', age / 1000,
               tankHasOurs and ((w.tank or 'the tank') .. ' is carrying ' .. DI.STAFF_SPELL) or 'staff on reuse',
               tankHasOurs and '' or '', st, spent)
    elseif verdict == 'stale' then
        -- We just got a TRUE reading out of a read that normally lies - the staff was already this far into
        -- reuse. Trust it and hold ourselves out for exactly that long, instead of going back to a zero that
        -- would let us re-commit on the very next tick (Nityrc did precisely that, twice, at 21:18:31).
        rezlog('[di] staff reads at the misread: %s', di_staff_reads())
        DI.assumeSpentUntil = mq.gettime() + (st * 1000)
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
-- MY Divine Res: seconds until ready, 0 = ready, -1 = don't own it. Same contract as my_cotw_secs, and
-- now the same MECHANISM: this is an AA, not a spell. The first version read Me.Book and Me.Gem, which
-- is why a cleric who owns it reported -1 - the AA is not in the spellbook and never will be.
-- Ownership comes from RANK for the same reason CotW's does: AltAbilityTimer returns 1 for an AA the
-- character does not own, so "timer > 0" would mark everyone a holder. Rank also IS the class check, so
-- nothing here touches Me.Class and it needs no edit if the group changes.
function my_divine_secs()
    local rank = 0; pcall(function() rank = tonumber(mq.TLO.Me.AltAbility(DIVINE_SPELL).Rank()) or 0 end)
    if rank <= 0 then return -1 end
    local rdy = false; pcall(function() rdy = tlo_true(mq.TLO.Me.AltAbilityReady(DIVINE_SPELL)()) end)
    if rdy then return 0 end
    local s = -1; pcall(function() s = tonumber(mq.TLO.Me.AltAbilityTimer(DIVINE_SPELL).TotalSeconds()) or -1 end)
    return (s and s > 0) and s or 0
end

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
    -- 'divine' HAD NO CASE HERE and fell through to the crown, so a divine slot asked about the CROWN's
    -- cooldown instead of the AA's. my_divine_secs existed and read rank, readiness and timer correctly -
    -- nothing ever called it. The AA's own cooldown was never consulted by anything, which is exactly
    -- what "she casts it and it never goes on cooldown" looks like from the outside.
    -- The comment above this function says the mapping exists so the election and the did-it-fire retry
    -- can never disagree about what a slot needs. This was the one kind where they did.
    if kind == 'divine' then return my_divine_secs() end
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
-- Order is Divine Res -> CotW -> the clicky order, cheapest and best first. Divine goes in front for the
-- same reason CotW goes in front of the clickies: renewable, no consumable behind it, and it returns more
-- experience than either. Pins are sorted by name because every toon builds this list locally and they
-- must all arrive at the same one.
function rez_divine_pins()
    local pins = {}
    for _, nm in ipairs(group_members()) do
        local secs = (nm:lower() == myName:lower()) and my_divine_secs()
                      or (rezReady[nm] and rezReady[nm].divine)
        if secs ~= nil and secs >= 0 and not chain_off(nm) then pins[#pins + 1] = nm end
    end
    table.sort(pins, function(a, b) return a:lower() < b:lower() end)
    return pins
end

function rez_chain()
    if #rezOrder == 0 then load_rez_order() end
    local chain = {}
    if rezDivine then
        for _, nm in ipairs(rez_divine_pins()) do chain[#chain + 1] = { name = nm, clicky = 'divine' } end
    end
    if not rezCotw then
        for _, sl in ipairs(rezOrder) do
            if not chain_off(sl.name) then chain[#chain + 1] = sl end
        end
        if #chain == 0 then return rezOrder end
        return chain
    end
    local pins = {}
    for _, nm in ipairs(group_members()) do
        -- my own read is live and authoritative; everyone else's arrives on the heartbeat
        local secs = (nm:lower() == myName:lower()) and my_cotw_secs() or (rezReady[nm] and rezReady[nm].cotw)
        if secs ~= nil and secs >= 0 and not chain_off(nm) then pins[#pins + 1] = nm end
    end
    table.sort(pins, function(a, b) return a:lower() < b:lower() end)
    for _, nm in ipairs(pins) do chain[#chain + 1] = { name = nm, clicky = 'cotw' } end
    -- Slots belonging to a sat-out character are dropped here rather than filtered at the election, so
    -- every toon builds the identical chain - filtering later would leave each client with a different
    -- idea of whose turn it is, which is exactly how a baton desyncs.
    for _, sl in ipairs(rezOrder) do
        if not chain_off(sl.name) then chain[#chain + 1] = sl end
    end
    if #chain == 0 then return rezOrder end
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
-- every one of those long casts failed while burning a charge.
-- 100, NOT THE CLICKY'S REACH. The binding constraint is not how far the rez can be cast, it is how far
-- a corpse can be DRAGGED - /corpse pulls a body from about 100 and does nothing beyond that. Rezzing
-- from 150 casts fine and leaves the body where it fell, which is the case the drag exists to prevent.
-- Gating on the shorter of the two means every rez we attempt is one where the corpse comes to us.
REZ_MAX_DIST = 100
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
-- PRE-EXISTING. This is the rez-box window check and it predates the safe-read sweep; the sweep
-- collided with its name. Returns open plus the raw value, for the probe.
local function win_open_raw(w)
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
    if win_open_raw(REZ_WINDOW) then
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
            -- ARM THE CORPSE WATCHER HERE TOO. It normally arms on the dead->alive transition, but a
            -- healer who rezzes the instant you drop means the tick never SEES you dead - there is no
            -- transition to catch, and the corpse is left lying there.
            -- Accepting a rez box is the other moment we know a rez just happened, and it is the one
            -- that survives being rezzed faster than we poll.
            if rezBoxClicked then
                corpseLootUntil = mq.gettime() + 60000
                rezlog('[corpse] rez accepted - watching for my corpse')
            end
            rezBoxAt, rezBoxClicked, rezBoxSeen = 0, false, false
        end
        return
    end

    if rezBoxAt == 0 then
        rezBoxAt, rezBoxClicked, rezBoxSeen = now, false, false
        rezlog('[rez] rez box OPEN: %s', txt:sub(1, 70))
        -- Announce the moment the box exists, whether or not WE click it. The previous version polled
        -- Window().Open() == true from the main loop - the same truthiness bug that hid the box from us
        -- for several builds - so in practice it never announced at all.
        rezDone[myName:lower()] = now + 15000
        pcall(function() peer_bcast('/at_rezdone %s', myName) end)
    end
    if rezBoxSeen or not rezAccept then return end

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
        rezBoxSeen = true       -- judged, not clicked - do not re-evaluate it every tick
        return
    end

    -- Try each button name; the first that makes the window go away was the right one.
    for _, b in ipairs(REZ_BUTTONS) do
        -- /nomodkey, as E3 does. A held shift or ctrl changes what a click means to the EQ UI, and the
        -- one thing you do not want is a rez accept that quietly does something else because the user
        -- happened to be holding a key.
        pcall(function() mq.cmdf('/nomodkey /notify %s %s leftmouseup', REZ_WINDOW, b) end)
        mq.delay(60)
        if not mq.TLO.Window(REZ_WINDOW).Open() then
            rezBoxClicked, rezBoxSeen = true, true
            rezExpectUntil = 0
            rezlog('[rez] accepted with %s, %dms after the box opened', b, now - rezBoxAt)
            return
        end
    end
    rezlog('\\ay[rez] rez box is open but none of the buttons closed it: %s\\ax', table.concat(REZ_BUTTONS, ', '))
    -- SEEN, not clicked. Every button was tried and the window is still open, so nothing was accepted -
    -- claiming otherwise would arm the corpse watcher for a rez that never happened.
    rezBoxSeen = true      -- do not hammer it every tick
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
        -- LOOT MY OWN CORPSE. A rez leaves the body on the floor with everything in it, and the character
        -- carries on fighting in whatever they were wearing when they died - which after a wipe is
        -- nothing. Doing it here, on the dead->alive transition, is the one moment we know for certain
        -- it just happened.
        -- WATCH FOR THE CORPSE rather than waiting a fixed time. A delay is a guess about how long a
        -- zone-in takes, and a character still loading when it expires would find nothing and give up
        -- silently. The corpse APPEARING is the actual signal, so we look for it instead.
        -- A window rather than forever: if no corpse turns up in a minute there is nothing to loot -
        -- somebody else dragged it, or the rez was accepted somewhere else entirely.
        corpseLootUntil = mq.gettime() + 60000
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
    if rezWipe then return end        -- wipe called: nobody rezzes until this character zones
    -- Feigning: standing up to cast would put this character straight back on the mob's list, which is
    -- the exact thing the feign was for. The baton times out and moves to the next rezzer.
    if am_invis() then
        rezdbg('invis - not taking the rez, letting the chain move on')
        return
    end
    if am_feigning() then
        rezdbg('feigning - not taking the rez, letting the chain move on')
        return
    end
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
            -- THE RETRY CLOCK RUNS FROM WHEN THE CAST ENDS, NOT FROM WHEN IT WAS FIRED.
            -- The gap below was measured from rezCast.at, the moment we sent it - so a cast that takes a
            -- second left only half a second before the retry, and the clicky's own cooldown has not
            -- registered by then. It still reads ready, that reads as "it never went off", and a rez that
            -- landed perfectly well gets cast a second time.
            -- Ejtou did exactly this at 04:17:09.854, 1.5s after firing but half a second after finishing,
            -- while Ehaba's log shows the first one had already taken.
            -- Pushing the stamp forward each tick we are still casting means the gap starts counting when
            -- the cast actually completes.
            rezCast.at = now
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
            -- SUMMON AGAIN on the retry. A first cast that failed on range failed because the body was
            -- too far, and going straight back to /nowcast repeats it from the same spot. /corpse needs
            -- the corpse targeted, so re-target first - the picker's target may have moved on by now.
            pcall(function() mq.cmdf('/target id %d', rezCast.id) end)
            mq.delay(400, function() return (tonumber(mq.TLO.Target.ID()) or 0) == rezCast.id end)
            if (tonumber(mq.TLO.Target.ID()) or 0) == rezCast.id then
                pcall(function() mq.cmd('/corpse') end)
                mq.delay(250)
            end
            -- A retry is MORE exposed than the first attempt: seconds have passed and a loot window, a
            -- summoned item or a trade has had time to put something on the cursor since.
            -- Best effort on the retry too - same reasoning as the first attempt.
            if not cursor_stow('rez') then
                rezlog('\\ay[rez] cursor will not clear - retrying anyway rather than lose the rez\\ax')
            end
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
    -- RAID CORPSES ARE OPT-IN NOW. Purple means this character is willing to spend a charge on someone
    -- outside the group; anything else declines and lets a raid rezzer handle it. The tank rule below
    -- still applies on top - a tank set to purple is opted in, but a tank is still not the right person
    -- to be walking to a stranger mid-fight.
    if tgtRaid and chain_mode(myName) ~= 'raid' then
        -- SAY SO, once per corpse. Declining in silence is indistinguishable from the feature being
        -- broken - which is exactly how it looked the first time a raid corpse went unrezzed after this
        -- gate went in. rezdbg is the picker's own channel, so this costs nothing unless you are watching.
        rezdbg(string.format('target %s(%d): raid corpse and I am set to %s - purple is needed for raid',
                             tgtName, tgtID, chain_mode(myName)))
        return
    end
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
    -- Same omission on the firing side: a divine slot resolved to CROWN_ITEM and clicked the crown. The
    -- log said "Ejtou(divine) slot1" and then fired Bloodcursed Crown of Vzith one line later.
    local item = (myClicky == 'divine') and DIVINE_SPELL
              or ((myClicky == 'cotw') and COTW_AA
              or ((myClicky == 'token') and TOKEN_ITEM or CROWN_ITEM))
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
        -- RETIRE IT NOW, not on confirmation. rezCorpseDone is normally set when the target says it
        -- accepted - but a raid stranger is not running this script and never will say so, so the only
        -- guard left was a 15s rezPending. It expires, the corpse is still lying there (rezzed corpses
        -- persist on this server), and everyone fires again: on 2026-08-03 one body took a CotW, then a
        -- token 15s later from the SAME rezzer, then a crown 10s after that.
        -- We can never learn whether a stranger's rez landed, so one charge per body is the rule. A
        -- missed rez costs a corpse run; three charges costs three charges.
        rezCorpseDone[tgtID] = true
        -- Tell any other AdventureTime user in earshot, so they do not spend a token on the same body.
        pcall(function() mq.cmdf('/say ATREZ %d %s', tgtID, tgtName) end)
        rezlog('[rez] RAID token on %s @%dm (not in my group)', tgtName, tgtDist)
    end
    -- SEND THE CORPSE ID, not just who is casting. The target uses it to loot the RIGHT body afterwards:
    -- 'pccorpse <name>' returns whichever the client feels like, and after a wipe with more than one
    -- death of yours on the floor that is a coin toss. The rezzer is holding the exact id already.
    pcall(function() peer_cmdf(tgtName, '/at_rezinc %s %d', myName, tgtID) end)
    -- PULL THE CORPSE FIRST. /corpse drags a nearby body to your feet, and a corpse just out of reach is
    -- the difference between a rez and a wasted charge - which matters most exactly when it is hardest
    -- to walk, mid-wipe with things still up.
    -- Costs nothing when the corpse is already close: the command is ignored rather than failing, and it
    -- needs the corpse targeted, which it is by this point.
    -- Deliberately NOT gated on distance. Reading a distance to decide whether to try is another read
    -- that can be wrong; issuing it unconditionally cannot be.
    -- SAY WHETHER IT DID ANYTHING. This was issued silently, so a log could not distinguish "dragged the
    -- body to my feet" from "did nothing at all" - and the answer matters, because /corpse only reaches a
    -- short radius and needs the owner's consent for anyone else's corpse. Measured, not assumed.
    local dBefore = tgtDist
    pcall(function() dBefore = tonumber(mq.TLO.Spawn(tgtID).Distance()) or tgtDist end)
    pcall(function() mq.cmd('/corpse') end)
    mq.delay(250)
    local dAfter = dBefore
    pcall(function() dAfter = tonumber(mq.TLO.Spawn(tgtID).Distance()) or dBefore end)
    if math.abs(dBefore - dAfter) >= 1 then
        rezlog('[rez] /corpse pulled %s from %dm to %dm', tgtName, dBefore, dAfter)
    elseif dAfter <= CORPSE_NEAR then
        -- ALREADY AT HAND. This used to be reported as "/corpse did nothing - out of drag range, or no
        -- consent", which is true about the drag and wrong about the reason: a body at 1m has nowhere to
        -- be dragged TO, so it cannot move a measurable amount and the command is ignored rather than
        -- failing. Every observed case was 0-5m - all in reach, all reported as failures.
        -- It sent two separate investigations down a consent rabbit hole while corpse clearing was in
        -- fact working. A message that says "failed" when nothing was wrong is worse than no message.
        rezlog('[rez] %s is already at hand (%dm) - no drag needed', tgtName, dAfter)
    else
        rezlog('[rez] /corpse did nothing on %s (still %dm) - out of drag range, or no consent', tgtName, dAfter)
    end
    -- NOTHING ON THE CURSOR BEFORE A CLICK. The rule the placate queue learned the hard way: an item held
    -- while a click goes out is how it ends up somewhere nobody expects. Rez is the likeliest of all of
    -- them to collide - deaths and looting happen in the same minute - and it fires on its own.
    -- Skipping is cheap: the baton comes back round and another rezzer or another pass takes it.
    -- BEST EFFORT, then fire anyway. Stow it if it will go - that is the whole point - but do NOT skip
    -- the rez if it will not. A rez that does not go out costs a corpse run and possibly the pull; an
    -- item that stays on the cursor through a click is a risk, not a certainty. Bags do fill up, and
    -- four "will not stow" events in one session say this path gets taken for real.
    -- Same call the CoTH click makes, for the same reason: stranding someone is the worse outcome.
    do
        local ok, held = cursor_stow('rez')
        if not ok then
            rezlog('\\ay[rez] %s is stuck on the cursor (bags full?) - firing anyway rather than lose the rez\\ax',
                   tostring(held or '?'))
        end
    end
    rezlog('[rez] FIRING /nowcast me "%s" %d (target %s @%dm, reach %d)', item, tgtID, tgtName, tgtDist, rez_range())
    pcall(function() mq.cmdf('/nowcast me "%s" %d', item, tgtID) end)
    pcall(function() mq.cmdf('/gsay %s %s on %s',
        (myClicky == 'cotw' or myClicky == 'divine') and 'Cast' or 'Clicked',
        rez_short(myClicky), tgtName) end)   -- short name only: the full one trips other chat parsers
    lastRezFire = now
    -- kind is carried so the retry and died-mid-cast paths know which timer proves the cast went off
    rezCast = { id = tgtID, item = item, kind = myClicky, at = now, tries = 1, name = tgtName, far = tgtFar }
    -- 15s, not 4s. The claim has to outlive the CAST, and the box can take eight seconds to appear when
    -- the target is still zoning - which is exactly when someone dies. At 4s the claim lapsed mid-flight
    -- and a second rezzer took the same corpse. A cast that genuinely fails releases this early via the
    -- skip path, so the longer hold costs nothing when it is not needed.
    rezPending[tgtID] = now + 15000
    peer_bcast('/at_rezclaim %d %d', tgtID, 15000)   -- CAST IS OUT: hold it for the whole flight
    -- AND RETIRE IT ACROSS THE GROUP when it is a raid corpse. Inside the group a claim is enough
    -- because the target confirms acceptance and everyone retires the id - but a stranger never
    -- confirms, so the claim simply lapses after 15s and the next rezzer in the chain takes the same
    -- body. That is how one corpse took a CotW, a token and a crown inside 25 seconds.
    if tgtRaid then peer_bcast('/at_rezretire %d', tgtID) end
    rezlog('[rez] claim SENT on corpse %d for 15000ms (cast is out)', tgtID)
    local msg = string.format('%s -> %s -> %s', myName, pick.kind or 'crown', tgtName)
    if SHOW_UI then rez_note(msg) elseif driverName then peer_cmdf(driverName, '/at_rezlog %s', msg) end
end



-- Liveness: the driver pings, a running instance pongs back. Used to auto-start the tool on any group
-- member that isn't running it, instead of assuming the user launched it everywhere.
local running = true   -- forward-declared here so the /at_close bind below sets THIS (not a global)
local alive = {}
pcall(function()
    -- TWO DRIVERS IN ONE GROUP IS A REAL PROBLEM AND IT IS OTHERWISE INVISIBLE.
    -- Only a driver arms the roster-change resync, and resync_group calls bring_up_group, which launches
    -- AdventureTime on any group member that does not answer a ping. So a second driver quietly relaunches
    -- everything the first one just shut down - which looks exactly like "it restarted on its own after
    -- Close all", with nothing in the log to explain it.
    -- A driver receiving a ping FROM another character means that character is also driving: only
    -- bring_up_group sends this, and only a driver calls that. Said once per offender so it cannot spam.
    atDriverSaid = atDriverSaid or {}
    mq.bind('/at_ping', function(driver)
        if not driver then return end
        if SHOW_UI and driver:lower() ~= myName:lower() and not atDriverSaid[driver:lower()] then
            atDriverSaid[driver:lower()] = true
            log('\\ar[sync] %s is ALSO running as a driver in this group.\\ax', driver)
            log('\\ay[sync] Two drivers fight: each relaunches workers the other closes, so Close all '
                .. 'looks like it restarts by itself. Run ONE driver - close AdventureTime on %s and '
                .. 'let this one start it as a worker.\\ax', driver)
        end
        driverName = driver
        peer_cmdf(driver, '/at_pong %s', myName)
    end)
    mq.bind('/at_expecttrade', function(ms)
        expectTradeUntil = mq.gettime() + (tonumber(ms) or 60000)
    end)
    mq.bind('/at_close', function()
        atExitWhy = 'told to close by the driver (/at_close)'
        e3_release_all(); running = false
    end)   -- broadcast close: resume E3, then exit
    -- A PEER asking us to hold E3 is a third owner, not an override. Without this, a peer finishing its
    -- distribution would send /at_e3 off and unpause a character that is mid-placate here.
    mq.bind('/at_e3', function(mode)
        if mode == 'on' then e3_hold('remote') else e3_release('remote') end
    end)
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
    mq.bind('/at_rezdivine', function(mode) rezDivine = (mode == 'on'); rezlog('[rez] Divine Res priority %s', mode or '?') end)
    mq.bind('/at_wipe', function(mode)
        rezWipe = (mode == 'on')
        rezlog(rezWipe and '\\ay[rez] WIPE - no rezzes until this character zones\\ax'
                        or '[rez] wipe cleared')
    end)
    -- /atwipe from any toon holds the whole group. /atwipe off releases early if it was a false alarm.
    mq.bind('/atwipe', function(mode)
        local on = (mode ~= 'off')
        rezWipe = on
        pcall(function() peer_bcast('/at_wipe %s', on and 'on' or 'off') end)
        rezlog(on and '\\ay[rez] WIPE called - the group will not rez until it zones\\ax'
                   or '[rez] wipe cleared for the group')
        if on then pcall(function() mq.cmd('/gsay AdventureTime: WIPE - holding rezzes until we zone') end) end
    end)
    -- Why is Divine Res not reporting? Three possible answers - wrong class, not scribed, not memmed -
    -- and they need different fixes. Ask rather than infer.
    mq.bind('/atdivine', function()
        local rank, rdy, secs = 0, false, -1
        pcall(function() rank = tonumber(mq.TLO.Me.AltAbility(DIVINE_SPELL).Rank()) or 0 end)
        pcall(function() rdy = tlo_true(mq.TLO.Me.AltAbilityReady(DIVINE_SPELL)()) end)
        pcall(function() secs = tonumber(mq.TLO.Me.AltAbilityTimer(DIVINE_SPELL).TotalSeconds()) or -1 end)
        log('[divine] AA "%s"', DIVINE_SPELL)
        log('   rank      %d   %s', rank, (rank > 0) and 'owned' or 'NOT owned - name may be wrong here')
        log('   ready     %s', tostring(rdy))
        log('   timer     %ss', tostring(secs))
        log('   my_divine_secs() = %d   (-1 means it will not be offered)', my_divine_secs())
    end)
    mq.bind('/at_chainskip', function(who, md)
        if not who or who == '' then return end
        if md == 'off' or md == 'raid' then chainMode[who:lower()] = md
        else chainMode[who:lower()] = nil end
        save_settings()
    end)
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
    mq.bind('/at_epadd', function(id, nm)
        id = tonumber(id); if not id or ep_find(id) then return end
        epQueue[#epQueue + 1] = { id = id, name = (nm or '?'):gsub('_', ' '), oor = false }
        ep_queue_log('peer add')
    end)
    mq.bind('/at_epdel', function(id)
        local i = ep_find(tonumber(id) or 0); if i then table.remove(epQueue, i) end
    end)
    -- Kept so a peer still on an older build does not error, but it will NOT throw away work in progress.
    -- Older builds broadcast this whenever their own queue emptied, which is exactly the message that
    -- wiped a live queue mid-cast. If we have anything pending or a cast in flight, ignore it.
    mq.bind('/at_epclear', function()
        if epCast then return end
        for _, q in ipairs(epQueue) do if not q.state then return end end
        epQueue, epDoneAt = {}, nil
        ep_queue_log('cleared')
    end)
    mq.bind('/at_epmark', function(id, st)
        local _, e = ep_find(tonumber(id) or 0)
        if e then e.state, e.oor = st, false end
    end)
    mq.bind('/at_ephave', function(who) if who and who ~= '' then epState[who] = true end end)
    mq.bind('/at_pacoff', function(who, v)
        if not who or who == '' then return end
        if v == '1' then pacOff[who:lower()] = true else pacOff[who:lower()] = nil end
        save_settings()
    end)
    mq.bind('/at_pacgem', function(who, g)
        if not who or who == '' then return end
        pacGem[who:lower()] = math.max(1, math.min(12, tonumber(g) or 8))
        save_settings()
    end)
    mq.bind('/at_pacadd', function(id, nm, lvl, who)
        local n = tonumber(id); if not n or pac_find(n) then return end
        pacQueue[#pacQueue + 1] = { id = n, name = (nm or '?'):gsub('_', ' '),
                                    level = tonumber(lvl) or 0, who = who }
    end)
    mq.bind('/at_pacdel', function(id)
        local i = pac_find(tonumber(id) or 0); if i then table.remove(pacQueue, i) end
    end)
    -- SNAPSHOT HERE TOO. This is the path that actually empties the driver's list most of the time:
    -- whichever character's auto-clear resolves first broadcasts the clear, and everyone else - the
    -- driver included - loses the queue through this bind rather than through their own pac_autoclear.
    -- Without the snapshot here, "Redo last" had nothing to offer after a normal run and never appeared.
    mq.bind('/at_pacclear', function() pac_snapshot(); pacQueue = {} end)
    mq.bind('/at_pacmark', function(id, st)
        local _, e = pac_find(tonumber(id) or 0)
        if e then e.state, e.oor, e.oorSince, e.oorDist = st, false, nil, nil end
    end)
    -- The caster reporting that a mob it owns is too far to reach. Not a state - see pac_set_oor.
    mq.bind('/at_pacoor', function(id, v, d)
        local _, e = pac_find(tonumber(id) or 0)
        if e then pac_set_oor(e, v == '1', tonumber(d) or 0) end
    end)
    -- Reassignment of an entry that nobody has picked up yet. Ignored once it is sent or resolved, so a
    -- message that crosses with a pickup cannot steal a mob out from under the caster working it.
    mq.bind('/at_pacwho', function(id, who)
        local n = tonumber(id) or 0
        local _, e = pac_find(n)
        if not (e and who and who ~= '') then return end
        if e.sent or e.state then return end
        -- AM I THE ONE LOSING IT, AND AM I ALREADY ON IT?
        -- The grace above makes this rare, but rare is not never, and the failure it prevents is the
        -- expensive one: two casters stripped and casting at the same mob.
        -- If it is in flight here, refuse the move and say so - I am mid-cast, the assignment is mine.
        if e.who and e.who:lower() == myName:lower() and who:lower() ~= myName:lower() then
            if (epCast and epCast.id == n) or (pwCast and pwCast.id == n) then
                pcall(function() peer_bcast('/at_pacsent %d', n) end)
                rezlog('[pacify] %s tried to move %s away, but I am casting at it - keeping it',
                       who, e.name or ('#' .. n))
                e.sent = true
                return
            end
            -- Not in flight: drop it from my own queue so it is not worked twice.
            local i = ep_find(n); if i then table.remove(epQueue, i) end
            local j = pw_find(n); if j then table.remove(pwQueue, j) end
        end
        e.who, e.assignedAt = who, mq.gettime()
    end)
    mq.bind('/at_pacsent', function(id)
        local _, e = pac_find(tonumber(id) or 0); if e then e.sent = true end
    end)
    mq.bind('/atpac', function() if not pac_announce() then log('[pacify] I have no pacify spell') end end)
    mq.bind('/at_paccap', function(who, cap, rng, kind)
        if not who or who == '' then return end
        pacCap[who] = { cap = tonumber(cap) or 0, range = tonumber(rng) or 0,
                        kind = kind or '?', updated = mq.gettime() }
    end)
    -- /at_epcaster is gone with the election. Pinning a caster only meant anything when several
    -- characters shared one queue and one of them had to be chosen; Smart Cast addresses every mob to a
    -- single caster by name, so there is nothing left to pin.
    -- THE CHARACTER THAT SPEAKS IT NEEDS IT. mgbSay is saved per character, but the announce is issued
    -- by whoever casts - so text typed on the driver stayed on the driver and the cleric went on saying
    -- the default. Same shape as /at_epgem: set it anywhere, broadcast, everyone saves their own copy.
    -- VARARGS, not one argument: mq splits a bind's arguments on spaces and the whole point of this
    -- setting is that it contains them. Rejoin everything after the key.
    mq.bind('/at_mgbsay', function(key, ...)
        if not key or key == '' then return end
        local txt = table.concat({ ... }, ' ')
        -- '-' is the wire form of "cleared", because an empty trailing argument does not survive the trip.
        if txt == '' or txt == '-' then mgbSay[key] = nil else mgbSay[key] = txt end
        save_settings()
    end)
    mq.bind('/at_epgem', function(n)
        local g = math.max(1, math.min(12, math.floor(tonumber(n) or 8)))
        if g ~= epGem then
            epGem = g
            epSaidGem, epMemAt = nil, nil   -- new gem: re-check and allow a fresh mem attempt
            save_settings()
            log('[placate] gem set to %d by the driver%s', g,
                ep_is_enchanter() and (' (' .. (ep_spell() or 'that gem is empty') .. ')') or '')
        end
    end)
    -- Manual escape hatch. If a run is abandoned with the weapons off - a crash, a zone, a stop - this
    -- puts them back without waiting for the backstop.
    mq.bind('/atregear', function()
        -- Works from the recovery FILE too, not just an in-flight run. After a crash there is no
        -- epSaved in memory, and that is exactly when someone types this.
        if not epSaved then
            local saved = ep_recovery_read()
            if saved then
                epSaved = saved
                epStripAt = mq.gettime()
                rezlog('[placate] recovering from %s', path_show(ep_recovery_path()))
            end
        end
        ep_restore('asked by hand')
    end)
    -- What each slot actually reads. If a strip ever quietly does nothing again, this says why in one
    -- line instead of by inference - the same trick that settled the DI staff timer.
    mq.bind('/atplacatetest', function(n) epTestWant = tonumber(n) or 10 end)
    -- IS IT AN ITEM OR A CURRENCY? The give-out counts things with FindItemCount, which only sees
    -- inventory. Alt currency lives in its own tab and is read off the currency LIST, so if Diamond Coin
    -- is currency then no amount of item-counting will ever find it - which is the likely reason this
    -- was started once and never finished.
    -- Prints both readings side by side so the answer is data rather than assumption.
    -- Pull currency out as items so the give-out can distribute it. Runs from the MAIN LOOP, not here:
    -- it drives windows and delays for seconds.
    mq.bind('/atpull', function(a, b)
        local qty = tonumber(b) or tonumber(a)
        local nm  = tonumber(a) and 'Diamond Coin' or (a or 'Diamond Coin')
        if a and not tonumber(a) and b then nm = a end
        altPullWant = { name = nm:gsub('_', ' '), qty = qty or 20 }
    end)
    -- A peer reporting its own currency balance. It has to be read locally - the list only exists on
    -- that client, and only when its inventory is open on the Alt. Currency tab.
    mq.bind('/at_altrep', function(nm, asker)
        if not nm or not asker then return end
        local name = nm:gsub('_', ' ')
        local bal = altcur_balance(name)
        pcall(function()
            peer_cmdf(asker, '/at_altbal %s %s %d', myName, nm, bal or -1)
        end)
    end)
    mq.bind('/at_altbags', function(who, nm, v)
        if not who or not nm then return end
        local name = nm:gsub('_', ' ')
        counts[who:lower()] = counts[who:lower()] or {}
        counts[who:lower()][name] = tonumber(v) or 0
        statusCounts[who:lower()] = counts[who:lower()]
    end)
    mq.bind('/at_altbal', function(who, nm, v)
        if not who or not nm then return end
        local name = nm:gsub('_', ' ')
        altCounts[who:lower()] = altCounts[who:lower()] or {}
        local n = tonumber(v)
        -- THREE OUTCOMES, not two. -1 means the peer answered but could not read its own list - almost
        -- always an inventory window that is shut or not on the Alt. Currency tab. That is a different
        -- thing from never answering, and the difference is actionable: one needs a window opened, the
        -- other needs the query re-firing. Storing both as nil made them indistinguishable.
        altCounts[who:lower()][name] = (n and n >= 0) and n or 'shut'
    end)
    mq.bind('/attribprobe', function() trib_probe() end)
    mq.bind('/attribute', function(a, b)
        local qty = tonumber(b) or tonumber(a) or 0
        local nm  = (a and not tonumber(a)) and a:gsub('_', ' ') or 'Diamond Coin'
        if qty <= 0 then log('[tribute] /attribute [item] <qty>'); return end
        tribWant = { item = nm, qty = qty }
    end)
    mq.bind('/attab', function()
        log('[altcur] looking for the Alt. Currency tab...')
        altcurTabFound = nil
        local wasOpen = false
        pcall(function() wasOpen = (mq.TLO.Window(ALTCUR_WND).Open() == true) end)
        if not wasOpen then
            pcall(function() mq.TLO.Window(ALTCUR_WND).DoOpen() end)
            mq.delay(600, function() return mq.TLO.Window(ALTCUR_WND).Open() == true end)
        end
        mq.delay(400)   -- a freshly opened window needs a beat before the list is readable
        local t = altcur_find_tab('Diamond Coin')
        if not t then log('[altcur] tab not identified - see the line above for why') end
        if not wasOpen then pcall(function() mq.TLO.Window(ALTCUR_WND).DoClose() end) end
    end)
    -- No quantity argument: Reclaim converts every stack of the item in one press.
    mq.bind('/atreclaim', function(a)
        local nm = (a and a ~= '') and a:gsub('_', ' ') or 'Diamond Coin'
        altReclaimWant = { name = nm }
    end)
    -- WHAT DOES THIS CLIENT ACTUALLY CALL AN AUG? find_aug reads Me.Inventory[slot].Item[n], which is the
    -- obvious shape and may simply be wrong here - the same way Me.Book was wrong for an AA earlier.
    -- Tries several forms against the charm and prints all of them, so the right one is data rather than
    -- another guess.
    -- WHICH RANGE MEMBER ACTUALLY REFLECTS MY FOCUS? MyRange is documented as "YOUR actual cast range,
    -- including extended range from focus effects" - so if it matches Range here, this build is not
    -- applying the focus and something else has to be read.
    -- Location and AERange are the only other distance-ish members on the spell type; both are printed
    -- rather than guessed at.
    mq.bind('/atrange', function(spellArg)
        local sp = (spellArg and spellArg ~= '') and spellArg:gsub('_', ' ') or ep_spell()
        if not sp then log('[range] no spell - mem placate or pass a name'); return end
        log('[range] "%s"', sp)
        for _, m in ipairs({ 'MyRange', 'Range', 'AERange', 'Location' }) do
            local v = 'n/a'
            pcall(function() v = tostring(mq.TLO.Spell(sp)[m]() or 'nil') end)
            log('   %-9s %s', m, v)
        end
        log('   ep_range() currently returns %d', ep_range())
        log('   focus ratio, from the memmed gems:')
        for g = 1, 12 do
            local gn = ''
            pcall(function() gn = tostring(mq.TLO.Me.Gem(g).Name() or '') end)
            if gn ~= '' and gn ~= 'NULL' then
                local mr, rr = 0, 0
                pcall(function() mr = tonumber(mq.TLO.Spell(gn).MyRange()) or 0 end)
                pcall(function() rr = tonumber(mq.TLO.Spell(gn).Range()) or 0 end)
                local ben = true
                -- tlo_true, NOT a raw string compare. This TLO comes back as a Lua boolean, so tostring gives
                -- 'true' and the old test against 'TRUE' was false for every spell in the book - which
                -- meant nothing was ever treated as beneficial and the filter below let heals through.
                -- Ejtou read her placate range off Desperate Renewal, a HEAL, and got 279; she then fired
                -- at mobs past placate's real reach and logged them as 'would not land'. Shela and
                -- Antilerd happened to have a detrimental as their longest and looked fine.
                pcall(function() ben = tlo_true(mq.TLO.Spell(gn).Beneficial()) end)
                if rr > 0 then
                    log('     gem %-2d %-26s %-5s Range %-5s MyRange %-5s %s', g, gn:sub(1, 26),
                        ben and 'ben' or 'DET', tostring(rr), tostring(mr),
                        (mr > rr) and string.format('= %.2fx', mr / rr) or '')
                end
            end
        end
    end)
    -- One command, because there is one thing left to ask. Everything the old probes hunted for -
    -- which TLO answers, which click form works, whether the pool is shared - was solving the aug's
    -- unreadability, and a bag item just answers.
    -- ===== BURN AUDIT =====
    -- Answers one question: is each burn sitting in a tier long enough for its own reuse?
    -- A 30 minute item parked in 15minBurn fires on the first 15 and is dead for the second, which looks
    -- exactly like the burn "not working" and is invisible from the logs.
    -- Writes a file rather than spamming chat: it is a table you read once, per character, and comparing
    -- twelve of them in a window is worse than opening twelve files.
    mq.bind('/atburnaudit', function()
        -- Total reuse, in seconds, by whichever kind of thing this is. Each read is tried in the same
        -- order have_thing uses, because that is the order that has proven to identify things correctly.
        -- Every read here is checked against the official MQ Lua definitions (mq-definitions), not
        -- inferred. The first draft of this used FindItem[...].RecastTime, WHICH DOES NOT EXIST - the
        -- item datatype has no such field - so every item would have fallen through and been reported
        -- as the wrong kind with the wrong number.
        local function reuse_of(nm)
            local v
            -- ITEM: the reuse lives on the CLICKY, as TimerID in seconds. Same field the Nightveil
            -- investigation landed on - Clicky.TimerID read 7200 for the two hour emblem.
            pcall(function() v = tonumber(mq.TLO.FindItem('=' .. nm).Clicky.TimerID()) end)
            if v and v > 0 then return v, 'item' end
            -- AA: MyReuseTime is the reuse AFTER hastened-AA, which is the number that applies to this
            -- character. ReuseTime is the unmodified one and is the fallback.
            pcall(function() v = tonumber(mq.TLO.Me.AltAbility(nm).MyReuseTime()) end)
            if not (v and v > 0) then
                pcall(function() v = tonumber(mq.TLO.Me.AltAbility(nm).ReuseTime()) end)
            end
            if v and v > 0 then return v, 'AA' end
            -- DISC or SPELL: RecastTime on the spell data covers both.
            pcall(function() v = tonumber(mq.TLO.Spell(nm).RecastTime()) end)
            if v and v > 0 then return v, 'spell/disc' end
            return -1, '?'
        end
        -- What is LEFT right now, so the file also answers "when does this come back".
        -- What is LEFT right now. Item.TimerReady is seconds; AltAbilityTimer returns a timestamp and
        -- CombatAbilityTimer returns ticks, so both need .TotalSeconds - which is why they are read
        -- differently from the item above rather than all three the same way.
        local function left_of(nm)
            local v
            pcall(function() v = timer_secs(mq.TLO.FindItem('=' .. nm).TimerReady()) end)
            if v and v > 0 then return v end
            pcall(function() v = tonumber(mq.TLO.Me.AltAbilityTimer(nm).TotalSeconds()) end)
            -- >1 not >0: AltAbilityTimer reports 1 for an AA you do not own, which the DI notes above
            -- record as a read that lies. One second of remaining cooldown is not worth reporting anyway.
            if v and v > 1 then return math.floor(v) end
            pcall(function() v = tonumber(mq.TLO.Me.CombatAbilityTimer(nm).TotalSeconds()) end)
            if v and v > 0 then return math.floor(v) end
            return 0
        end
        -- The tier's own length, taken from its NAME - "15minBurn" is 15 minutes. Anything that does not
        -- parse (Rez, Quick Burn, Full Burn) has no implied length, so it cannot be misaligned.
        local function tier_secs(key)
            local n = tostring(key or ''):match('^(%d+)%s*min')
            return n and (tonumber(n) * 60) or nil
        end

        local rows = {}
        for _, e in ipairs(BURN_WATCH or {}) do
            if have_thing(e.name) then
                local reuse, kind = reuse_of(e.name)
                local tsec = tier_secs(e.tkey)
                local flag = ''
                if reuse > 0 and tsec and reuse > tsec then
                    flag = string.format('MISALIGNED - needs %s', nv_hms(reuse))
                elseif reuse < 0 then
                    flag = 'no reuse reported'
                end
                rows[#rows + 1] = { tier = e.tkey, order = e.tier, name = e.name, kind = kind,
                                    reuse = reuse, left = left_of(e.name), flag = flag }
            end
        end
        table.sort(rows, function(a, b)
            if a.order ~= b.order then return a.order < b.order end
            return a.name:lower() < b.name:lower()
        end)

        local who = ''
        pcall(function() who = tostring(mq.TLO.Me.Name() or 'unknown') end)
        local path = at_write('AdventureTime_burnaudit_' .. who .. '.txt')
        local f = io.open(path, 'w')
        if not f then log('\\ar[burns] could not write %s\\ax', path_show(path)); return end
        f:write(string.format('AdventureTime burn audit - %s - %s\n', who, os.date('%Y-%m-%d %H:%M:%S')))
        f:write('tier is where the INI puts it; reuse is what the thing actually needs.\n')
        f:write(string.format('%-14s %-38s %-11s %9s %9s  %s\n',
                'TIER', 'NAME', 'KIND', 'REUSE', 'READY IN', 'NOTE'))
        local bad = 0
        for _, r in ipairs(rows) do
            if r.flag ~= '' then bad = bad + 1 end
            f:write(string.format('%-14s %-38s %-11s %9s %9s  %s\n',
                    r.tier, r.name:sub(1, 38), r.kind,
                    (r.reuse > 0) and nv_hms(r.reuse) or '-',
                    (r.left > 0) and nv_hms(r.left) or 'ready', r.flag))
        end
        f:write(string.format('\n%d entries, %d worth a look.\n', #rows, bad))
        f:close()
        log('[burns] audit written: %s', path_show(path))
        log('[burns] %d entr(ies), %d worth a look', #rows, bad)
    end)

    mq.bind('/atnv', function()
        local have = nv_have()
        if #have == 0 then
            log('\\ay[nv] I am carrying none of the four.\\ax')
            for _, e in ipairs(NV_SPLIT) do log('   looked for: %s (%s)', e.item, e.role) end
            return
        end
        for _, i2 in ipairs(have) do
            local e = NV_SPLIT[i2]
            local raw = nil
            pcall(function() raw = mq.TLO.FindItem('=' .. e.item).TimerReady() end)
            log('[nv] %-16s %-16s TimerReady=%-10s -> %s', e.role, e.item, tostring(raw),
                nv_hms(nv_secs_at(i2)))
        end
    end)
    mq.bind('/at_arcstate', function(char, have, secs, up)
        if not char then return end
        arcState[char] = { have = tonumber(have) or 0, secs = tonumber(secs) or -1,
                           up = tonumber(up) or 0, updated = mq.gettime() }
    end)
    -- INDEXES, NOT NAMES. The item names contain spaces and mq splits a bind's arguments on spaces, so
    -- sending "Veiled Bastion" would arrive as two arguments. An index into NV_SPLIT has neither
    -- problem and is shorter on the wire: "1:0,3:7180" is everything this character holds.
    mq.bind('/at_nvstate', function(char, list)
        if not char then return end
        local items = {}
        for pair in tostring(list or ''):gmatch('[^,]+') do
            local i2, s = pair:match('^(%d+):(-?%d+)$')
            if i2 then items[tonumber(i2)] = tonumber(s) end
        end
        nvState[char] = { items = items, updated = mq.gettime() }
    end)
    -- Click mine. One item, one command - no method cascade, no second click to provoke a refusal.
    -- WHICH ONE. The driver names the index, because a character holding all four needs to be told
    -- which to use - that choice is the whole point of the split.
    mq.bind('/at_nvclick', function(idx)
        local i2 = tonumber(idx or 0) or 0
        local e = NV_SPLIT[i2]
        if not e then log('\\ay[nv] click asked for slot %s, which is not one of the four\\ax', tostring(idx)); return end
        local before = nv_secs_at(i2)
        if before < 0 then log('\\ay[nv] I do not carry %s\\ax', e.item); return end
        if before > 0 then
            log('\\ay[nv] %s is on cooldown (%s) - not clicking\\ax', e.item, nv_hms(before))
            return
        end
        pcall(function() mq.cmdf('/nowcast me "%s%s"', e.item, NIGHTVEIL_OPTS) end)
        mq.delay(1500)
        log('[nv] used %s (%s) - cooldown now %s', e.item, e.role, nv_hms(nv_secs_at(i2)))
        nvLast = ''   -- force a fresh push so the button greys immediately
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
            local open, raw = mq.TLO.Window(w).Open()
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
    -- DROP INVIS ON THIS CHARACTER. /removebuff by name, using the same recognition the coverage row
    -- uses - so whatever it can colour, it can also remove.
    -- Both windows: an invis effect lands in the buff or the song window depending on its source, and
    -- only checking one is how the placate work lost a whole subsystem for a week.
    -- WHAT DO THE READS ACTUALLY SAY? Dumps every buff and song with the verdict this character reaches,
    -- so a wrong colour can be traced to the exact name rather than guessed at.
    mq.bind('/atinvisprobe', function()
        local any = 'nil'
        pcall(function() any = tostring(mq.TLO.Me.Invis()) end)
        local nb, ns = 0, 0
        pcall(function() nb = tonumber(mq.TLO.Me.CountBuffs()) or 0 end)
        pcall(function() ns = tonumber(mq.TLO.Me.CountSongs()) or 0 end)
        log('[invisprobe] Me.Invis=%s | %d buff(s), %d song(s)', any, nb, ns)
        local function dump(kind, getName, count)
            for i = 1, (count or 0) do
                local nm = ''
                pcall(function() nm = tostring(getName(i) or '') end)
                if nm ~= '' and nm ~= 'NULL' then
                    local grp = invis_known(nm)
                    local tag = grp and (' <- reads as ' .. grp) or ''
                    log('[invisprobe]   %s %2d: %s%s', kind, i, nm, tag)
                end
            end
        end
        pcall(function() dump('buff', function(i) return mq.TLO.Me.Buff(i).Name() end, nb) end)
        pcall(function() dump('song', function(i) return mq.TLO.Me.Song(i).Name() end, ns) end)
        local n, u = invis_self()
        log('[invisprobe] verdict: invis=%d itu=%d -> %s', n, u,
            (n == 1 and u == 1) and 'purple' or (u == 1) and 'white' or (n == 1) and 'blue' or 'grey')
    end)
    mq.bind('/at_unvis', function()
        local gone = {}
        local function sweep(getName, count)
            for i = 1, (count or 0) do
                local nm = ''
                pcall(function() nm = tostring(getName(i) or '') end)
                -- ONLY NAMES WE KNOW ARE INVIS. A loose match here removed 'Undead Chokidai Blessing'
                -- from every character that had it, every press.
                if invis_known(nm) then
                    pcall(function() mq.cmdf('/removebuff "%s"', nm) end)
                    gone[#gone + 1] = nm
                end
            end
        end
        local nb, ns = 0, 0
        pcall(function() nb = tonumber(mq.TLO.Me.CountBuffs()) or 0 end)
        pcall(function() ns = tonumber(mq.TLO.Me.CountSongs()) or 0 end)
        pcall(function() sweep(function(i) return mq.TLO.Me.Buff(i).Name() end, nb) end)
        pcall(function() sweep(function(i) return mq.TLO.Me.Song(i).Name() end, ns) end)
        -- ALWAYS, WHATEVER WE THINK. /makemevis is the client's own answer to "stop being invisible" and
        -- it does not care whether our buff-name matching recognised the source. That matching only knows
        -- the four entries in MAGIC_CLICKS, so anything else - a potion, another player's cast, a clicky
        -- we have never heard of - left the character invis while the log cheerfully said 'nothing to
        -- drop', which is exactly the miss being reported.
        -- Cheap and harmless on a character that is not invis, so there is no reason to gate it on our
        -- own opinion of the state.
        pcall(function() mq.cmd('/makemevis') end)
        invisLast = ''   -- force a fresh report so the coverage row updates at once
        if #gone > 0 then log('[invis] dropped: %s (+ /makemevis)', table.concat(gone, ', '))
        else log('[invis] no known invis buff to remove - sent /makemevis anyway') end
    end)
    -- Ports are reported ON REQUEST, not on a heartbeat. A spell book changes when somebody scribes
    -- something, which is not often enough to be worth a periodic broadcast - so the driver asks when
    -- the panel is first opened and the answer is kept until asked again.
-- ===== PORTS =====
-- Druid and wizard travel, grouped the way the client's own spell menu groups it: Category is
-- 'Transport' and Subcategory is the continent, straight out of the spell data.
-- THE SCAN ONLY EVER RUNS ON THE TICK. Not in a draw, not in a bind - those are the two places where a
-- long read loop is dangerous, and this feature crashed the porters three times before /atportlist
-- proved the walk itself was harmless. The walk is cheap when bounded: 100 slots with four reads each
-- measured 110ms on a live client.
PORT_CAT = 'transport'
portBook = {}          -- [char] = { {name=, sub=, lvl=}, ... }
portScanWanted = false -- I should read my own book on the next tick
portAskedBy = nil      -- who wants my list; answered from the tick for the same reason
portAsked = false      -- have we asked the group yet this session

function port_scan()
    local out = {}
    local bookOk = false
    pcall(function() bookOk = tostring(mq.TLO.Me.Book(1).Name() or '') ~= '' end)
    if not bookOk then return nil end
    -- Stop at the end of the book rather than walking all 720 slots: a spellbook is contiguous, so five
    -- empty slots in a row is the end. The empties were most of the cost.
    local misses = 0
    for i = 1, 720 do
        local nm = ''
        pcall(function() nm = tostring(mq.TLO.Me.Book(i).Name() or '') end)
        if nm == '' or nm == 'NULL' then
            misses = misses + 1
            if misses >= 5 then break end
        else
            misses = 0
            local id = 0
            pcall(function() id = tonumber(mq.TLO.Me.Book(i).ID()) or 0 end)
            if id > 0 then
                -- BY ID, not by name: two spells can share a name and Spell[name] resolves to whichever
                -- the client picks. /atportlist confirmed the ID form reads correctly here.
                local cat = ''
                pcall(function() cat = tostring(mq.TLO.Spell(id).Category() or ''):lower() end)
                if cat == PORT_CAT then
                    -- TargetType decides how a port is used, and the three cases behave very
                    -- differently: Self takes only the caster, Group v1/v2 takes everyone in range, and
                    -- Single is a Translocate that needs somebody targeted or it goes nowhere useful.
                    -- Reduced to one letter here because it has to travel over the peer link and every
                    -- character it costs is a character of a port name that might get truncated.
                    local sub, lvl, tt = '', 0, ''
                    pcall(function() sub = tostring(mq.TLO.Spell(id).Subcategory() or '') end)
                    pcall(function() lvl = tonumber(mq.TLO.Spell(id).Level()) or 0 end)
                    pcall(function() tt = tostring(mq.TLO.Spell(id).TargetType() or ''):lower() end)
                    local kind = 'g'
                    if tt:find('self', 1, true) then kind = 's'
                    elseif tt:find('single', 1, true) then kind = 't'
                    elseif tt:find('group', 1, true) then kind = 'g' end
                    out[#out + 1] = { name = nm, sub = (sub ~= '') and sub or 'Other', lvl = lvl,
                                      kind = kind }
                end
            end
        end
    end
    table.sort(out, function(a, b)
        if a.sub ~= b.sub then return a.sub < b.sub end
        if a.lvl ~= b.lvl then return a.lvl > b.lvl end
        return a.name < b.name
    end)
    return out
end

-- Mem it, wait for it, cast it. E3 is held throughout for the same reason placate holds it: while E3 is
-- running it will re-mem its own spell into the gem we are trying to use.
function port_cast(spell)
    if not spell or spell == '' then return end
    e3_hold('port')
    local gem = ep_gem_num()
    local now = ''
    pcall(function() now = tostring(mq.TLO.Me.Gem(gem).Name() or '') end)
    if now ~= spell then
        if e3_is_paused() == false then
            log('\\ay[port] E3 has not paused yet - not memming into a live gem\\ax')
            e3_release('port'); return
        end
        log('[port] memming %s into gem %d', spell, gem)
        pcall(function() mq.cmdf('/memspell %d "%s"', gem, spell) end)
        mq.delay(10000, function() return (mq.TLO.Me.Gem(gem).Name() or '') == spell end)
        pcall(function() now = tostring(mq.TLO.Me.Gem(gem).Name() or '') end)
        if now ~= spell then
            log('\\ar[port] could not mem %s (gem %d reads "%s")\\ax', spell, gem, now)
            e3_release('port'); return
        end
        -- WAIT FOR THE GEM TO HOLD READY, not for a fixed number of milliseconds.
        -- Placate learned this the hard way: the gem reports its name back before the client has finished
        -- standing and closing the book, and the timer can read 0 MID-SETTLE and then go non-zero again.
        -- So a single sample - or a flat delay - lands in that gap and the cast goes nowhere.
        -- EP_MEM_SETTLE is the floor, then the gem must read ready continuously for EP_GEM_STEADY.
        mq.delay(EP_MEM_SETTLE)
        -- SAY WHAT THE READS ACTUALLY RETURN. The first version waited on ep_gem_ready alone and gave up
        -- after eight seconds saying 'never settled' - which tells us it was never true and nothing about
        -- why. GemTimer, SpellReady and the gem's own name disagree in ways that have caught this file
        -- out repeatedly, so all three are logged once a second while waiting.
        -- Ready is now EITHER signal: the gem timer reading 0, or SpellReady saying yes. Requiring the
        -- timer alone is what stalled it, and for a port - a single deliberate cast, not a rotation -
        -- being slightly early is a wasted click, while never casting is a broken button.
        -- LET THE GEM SAY HOW LONG IT NEEDS. A flat ceiling cannot know: memming a port leaves about ten
        -- seconds of refresh on the gem, and at 8000 we gave up with the timer reading 1 and cast into
        -- the last second of it.
        -- GemTimer counts down honestly - 9, 8, 7 ... 1 - so the deadline is pushed out to whatever it
        -- currently reports, plus a margin. A spell with a longer refresh waits longer without anyone
        -- having to guess a new number, and the hard cap only exists so a stuck read cannot hang here.
        local steadyFrom, lastSaid = nil, 0
        local giveUp = mq.gettime() + 8000
        local hardCap = mq.gettime() + 45000
        while mq.gettime() < giveUp and mq.gettime() < hardCap do
            local gt, sr, gn = -1, false, ''
            pcall(function() gt = tonumber(mq.TLO.Me.GemTimer(gem).TotalSeconds()) or -1 end)
            pcall(function() sr = tlo_true(mq.TLO.Me.SpellReady(spell)()) end)
            pcall(function() gn = tostring(mq.TLO.Me.Gem(gem).Name() or '') end)
            -- Extend for what the gem still says it needs, within the cap.
            if gt > 0 then
                local want = mq.gettime() + (gt * 1000) + 1500
                if want > giveUp then giveUp = math.min(want, hardCap) end
            end
            if (mq.gettime() - lastSaid) > 1000 then
                lastSaid = mq.gettime()
                log('[port] waiting: GemTimer=%s SpellReady=%s gem%d="%s"', tostring(gt), tostring(sr), gem, gn)
            end
            -- BOTH, not either. GemTimer reaching 0 only says the GEM's refresh is done; SpellReady is
            -- the one that says the spell can actually be cast, and the log shows it still false at the
            -- moment the timer hits zero. Casting on the timer alone went out half a second early every
            -- time - which is the same mistake the placate mem was making.
            -- Once the timer is at 0 the wait is on SpellReady, so give it room to turn true rather than
            -- falling out on a deadline that was sized for the countdown.
            if gt == 0 and not sr then
                local want = mq.gettime() + 3000
                if want > giveUp then giveUp = math.min(want, hardCap) end
            end
            if (gt == 0) and sr then
                steadyFrom = steadyFrom or mq.gettime()
                if (mq.gettime() - steadyFrom) >= EP_GEM_STEADY then break end
            else
                steadyFrom = nil   -- a blip mid-settle: start the clock again
            end
            mq.delay(100)
        end
        if not steadyFrom then
            log('\\ay[port] gem %d never reported ready - casting anyway\\ax', gem)
        end
    end
    log('[port] casting %s', spell)
    pcall(function() mq.cmdf('/nowcast me "%s"', spell) end)
    mq.delay(20000, function() return (tonumber(mq.TLO.Me.Casting.ID()) or 0) == 0 end)
    e3_release('port')
end

-- Which continent/kind rows are expanded. In memory only: a viewing preference costs nothing to set again.
portOpen = portOpen or {}

function draw_ports_tab()
    ImGui.Spacing()
    -- The scan is queued here, never run here: this is an ImGui callback and the walk belongs on the
    -- tick. One frame of 'reading books...' is the whole cost of that separation.
    if not portAsked then
        portAsked = true
        portScanWanted = true
    end
    if ImGui.SmallButton('Rescan##portrescan') then
        portBook = {}
        portScanWanted = true
    end
    if ImGui.IsItemHovered and ImGui.IsItemHovered() then
        pcall(function() ImGui.SetTooltip('Re-read every book. Only needed after somebody scribes one.') end)
    end
    if portScanWanted then ImGui.SameLine(); ImGui.TextDisabled('reading books...') end
    ImGui.SameLine()
    ImGui.TextDisabled('Group takes everyone; Single is self and targeted')
    ImGui.Separator()

    local any = false
    for _, nm in ipairs(ordered_members()) do
        local list = portBook[nm]
        if list and #list > 0 then
            any = true
            ImGui.Spacing()
            ImGui.TextColored(0.85, 0.72, 0.35, 1.0, nm)

            -- SPLIT BY WHO IT MOVES, INSIDE EACH CONTINENT. A flat list of thirty ports is a wall, and
            -- the first question is not "which continent" on its own - it is "am I moving the group or
            -- just me". Group and Single answer that before you read a single spell name.
            -- Single holds self AND targeted: from here both mean "this does not bring the group", which
            -- is the distinction that matters at the moment you press it. A wizard's Gate and its
            -- Translocates land there together, which is the right grouping for both.
            -- THREE BUCKETS, NOT TWO. A wizard has a Translocate for almost every destination, so they
            -- swamped Single and made the one list that was supposed to be short the longest one.
            -- They are also the only ports that need somebody targeted, so they were already the odd
            -- group out - giving them their own row says that structurally rather than only in a colour.
            -- Matched on the NAME rather than the target type: 'Translocate:' is the whole line and it
            -- is unambiguous, where target type alone would sweep in any other targeted port with it.
            local conts, byCont = {}, {}
            for _, e in ipairs(list) do
                local c = e.sub or 'Other'
                if not byCont[c] then byCont[c] = { g = {}, s = {}, t = {} }; conts[#conts + 1] = c end
                local b
                if e.name:lower():find('translocate', 1, true) then b = 't'
                elseif (e.kind or 'g') == 'g' then b = 'g'
                else b = 's' end
                table.insert(byCont[c][b], e)
            end

            local function row(label, entries, key, r, gg, b)
                if #entries == 0 then return end
                local open = portOpen[key]
                ImGui.SameLine()
                if ImGui.SmallButton(string.format('%s %s (%d)##%s',
                                     open and 'v' or '>', label, #entries, key)) then
                    portOpen[key] = (not open) or nil
                end
                if not open then return end
                ImGui.NewLine()
                for _, e in ipairs(entries) do
                    ImGui.TextDisabled('      ')
                    ImGui.SameLine()
                    -- Targeted ports stay amber even inside Single: they are the ones that go nowhere
                    -- useful without somebody targeted, and that is worth flagging on the button itself.
                    local kd = e.kind or 'g'
                    if kd == 't' then ImGui.PushStyleColor(ImGuiCol.Text, 0.95, 0.72, 0.35, 1.0)
                    else              ImGui.PushStyleColor(ImGuiCol.Text, r, gg, b, 1.0) end
                    local hit = ImGui.SmallButton(string.format('%s##port_%s_%s', e.name, nm, e.name))
                    ImGui.PopStyleColor()
                    if hit then
                        if nm:lower() == myName:lower() then port_cast(e.name)
                        else pcall(function() peer_cmdf(nm, '/at_portcast %s', e.name) end) end
                    end
                    if ImGui.IsItemHovered and ImGui.IsItemHovered() then
                        local what = (kd == 's') and 'SELF only - takes just ' .. nm
                                  or (kd == 't') and 'TARGETED - ' .. nm .. ' must have somebody targeted'
                                  or 'GROUP - takes everyone in range'
                        pcall(function() ImGui.SetTooltip(string.format('%s - %s (level %d)\n%s',
                                                           e.name, e.sub, e.lvl, what)) end)
                    end
                end
                ImGui.NewLine()
            end

            for _, c in ipairs(conts) do
                ImGui.TextDisabled('  ' .. c .. ':')
                row('Group',  byCont[c].g, 'po_' .. nm .. '_' .. c .. '_g', 0.45, 0.82, 0.50)
                row('Single', byCont[c].s, 'po_' .. nm .. '_' .. c .. '_s', 0.70, 0.70, 0.70)
                row('Trans',  byCont[c].t, 'po_' .. nm .. '_' .. c .. '_t', 0.95, 0.72, 0.35)
                ImGui.NewLine()
            end
            ImGui.Separator()
        end
    end
    if not any then
        ImGui.TextDisabled('no ports yet - nobody has reported a Transport spell')
    end
    -- BALANCE THE TAB. BeginTabItem returning true opens a scope that must be closed; leaving it out
    -- takes the whole script down the moment the tab is clicked.
    ImGui.EndTabItem()
end

-- ===== PORT PROBE =====
    -- Deliberately the smallest possible version. Three attempts at a ports feature crashed the two
    -- characters that have Transport spells, and each of my explanations was wrong, so this stops
    -- explaining and starts measuring.
    -- It PRINTS, and nothing else: no UI, no peer traffic, no casting, nothing on a timer. Run it by
    -- hand on ONE porter.
    -- Every step logs before AND after the read it is about to do, and log_to_file opens, writes and
    -- closes per line - so whatever the last line in the file is, the read named on the NEXT step is the
    -- one that killed the client. That is the fact none of the previous attempts established.
    -- The work happens on the TICK, not here: binds run inside doevents and that is not a safe place to
    -- be doing hundreds of reads.
    -- RECORD ONLY. A bind runs inside doevents; the scan happens on the tick.
    mq.bind('/at_ports?', function(who) portAskedBy = who or driverName end)
    mq.bind('/at_portsclr', function(char) if char then portBook[char] = {} end end)
    -- VARARGS AND REJOIN. Port names contain spaces - 'Ring of Karana' - and mq splits a bind's
    -- arguments on spaces, so a single `blob` parameter received only the text up to the first one.
    -- The visible symptom was that ONLY the Misc ports arrived: 'Gate' is the one port whose name is a
    -- single word, so it was the only entry that ever survived the split.
    -- /at_portcast already had to do this for the same reason.
    mq.bind('/at_ports!', function(char, ...)
        if not char then return end
        local blob = table.concat({ ... }, ' ')
        -- APPEND. The list arrives in several small messages now, so this adds to what is already there
        -- rather than replacing it - /at_portsclr resets before the first one.
        local out = portBook[char] or {}
        for chunk in tostring(blob or ''):gmatch('[^,][^,]*') do
            -- The kind is optional so a peer on an older build still parses: it just shows as group.
            local nm, sub, lvl, kd = chunk:match('^(.-)|(.-)|(%d+)|(%a)$')
            if not nm then nm, sub, lvl = chunk:match('^(.-)|(.-)|(%d+)$') end
            if nm then
                out[#out + 1] = { name = nm, sub = sub, lvl = tonumber(lvl) or 0, kind = kd or 'g' }
            end
        end
        portBook[char] = out
    end)
    -- The spell name has spaces, so it arrives as several arguments and has to be rejoined.
    mq.bind('/at_portcast', function(...) port_cast(table.concat({ ... }, ' ')) end)
    mq.bind('/atportlist', function(n)
        portProbeWant = math.max(1, math.min(720, tonumber(n) or 30))
        log('[portprobe] queued - will read the first %d book slot(s) on the next tick', portProbeWant)
    end)
    mq.bind('/at_inviscast', function(key, ms) invis_arm(key, tonumber(ms) or INVIS_LEAD) end)
    -- WHAT IS THE CAST TIME, REALLY? invis_cast_ms reported 0s for both rows, which cannot be right when
    -- one of them visibly takes a moment - so this tries every route to the number and prints all of
    -- them rather than trusting the one I picked. Same approach as /atportlist, which settled a question
    -- three guesses had failed to.
    mq.bind('/atinviscast', function()
        for _, e in ipairs(MAGIC_CLICKS) do
            if e.group == 'ITU' or e.group == 'Invis' then
                local nm = e.aa or e.spell or e.name or '?'
                local a, b, c, d, id = 'x', 'x', 'x', 'x', 0
                pcall(function() id = tonumber(mq.TLO.Me.AltAbility(nm).Spell.ID()) or 0 end)
                pcall(function() a = tostring(mq.TLO.Me.AltAbility(nm).Spell.CastTime()) end)
                pcall(function() b = tostring(mq.TLO.Me.AltAbility(nm).Spell.MyCastTime()) end)
                if id > 0 then
                    pcall(function() c = tostring(mq.TLO.Spell(id).CastTime()) end)
                    pcall(function() d = tostring(mq.TLO.Spell(id).MyCastTime()) end)
                end
                local have = have_thing(nm) and 'MINE' or '-'
                log('[inviscast] %-38s %s spellID=%d', nm, have, id)
                log('[inviscast]    AA.Spell.CastTime=%s  AA.Spell.MyCastTime=%s', a, b)
                log('[inviscast]    Spell(id).CastTime=%s  Spell(id).MyCastTime=%s', c, d)
            end
        end
    end)
    -- A worker reporting its own bag counts. Indexes into ITEMS, so nothing here contains a space.
    mq.bind('/at_counts', function(char, blob)
        if not char then return end
        local t = { at = mq.gettime() }
        for chunk in tostring(blob or ''):gmatch('[^,]+') do
            local i, n = chunk:match('^(%d+):(%d+)$')
            if i then
                local item = ITEMS[tonumber(i)]
                if item then t[item] = tonumber(n) or 0 end
            end
        end
        countsPush[char:lower()] = t
    end)
    mq.bind('/at_countsask', function() countsPushAt = 0 end)
    mq.bind('/at_invis', function(char, n, u)
        if not char then return end
        invisState[char] = { norm = tonumber(n) or 0, und = tonumber(u) or 0, updated = mq.gettime() }
    end)
    mq.bind('/at_magicprobe', function()   -- what does each magic entry resolve to on me?
        for _, e in ipairs(MAGIC_CLICKS) do
            local have, secs, up, dsecs = magic_state(e)
            if e.aa then
                local rank, left = 0, '?'
                pcall(function() rank = tonumber(mq.TLO.Me.AltAbility(e.aa).Rank()) or 0 end)
                pcall(function() left = tostring(mq.TLO.Me.AltAbilityTimer(e.aa).TotalSeconds()) end)
                log('[magicprobe] %s (AA) | rank=%d timer=%s -> %s', e.aa, rank, left,
                    have == 1 and 'MINE' or 'not trained')
            elseif e.spell then
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
        local ok, nm, why = pot_drink(base)
        if ok then log('[pot] %s sent', nm)      -- "landed" only once pot_retry_tick has seen it
        -- A refusal is a decision, not a failure, so it says which decision. A press that does nothing
        -- and prints nothing is indistinguishable from a broken button.
        elseif why then log('[pot] %s', why)
        elseif nm then log('[pot] %s on cooldown', nm)
        else log('[pot] no %s carried', base) end
    end)
    mq.bind('/at_difired', function() DI.firedAt = mq.gettime(); DI.trigAt, DI.turnAt = 0, nil end)
    -- The attempt has a verdict, whatever it was - stop parking on the ceiling and let the next slot act.
    mq.bind('/at_didone', function() DI.firedAt = 0 end)
    -- The holder tells everyone at once, so nobody has to work out whose turn it is from staff timers.
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
        e3_release_all()
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
    -- THE TANK IS ASKING ME FOR A SAVE. Everything that decides this is a LOCAL read - di_rung_list
    -- already answers "what can I actually cast right now" from my own gems and cooldowns, which is the
    -- authoritative answer the tank cannot have.
    -- Answer either way and answer fast: a 'no' moves the tank to the next candidate immediately, which
    -- is the whole point. Silence costs it a second.
    mq.bind('/at_dineed', function(tank)
        if not tank or tank == '' then return end
        -- CLERIC RUNGS ARE FOR CLERICS. di_rung_list proves ownership per rung - AA rank, item id, gem -
        -- but ownership is not the same as being the right character to use it: a necro carrying a pair
        -- of Donal's Boots in a bag passes the id check and offered them, which is how Azyue and Ehaba
        -- both announced 'Casting Guardian boots' on 2026-08-14.
        -- The old ladder never had to think about this because it only ever ran on clerics. This bind
        -- runs on everybody, so the gate has to be here - the same one di_read_self uses.
        local best
        local amCleric = (member_class(myName) or ''):upper() == 'CLR'
        if amCleric and not DI.ladderOff then
            for _, r in ipairs(di_rung_list()) do
                if r.ready then best = r; break end
            end
        end
        -- THE STAFF IS A CANDIDATE TOO, and it is checked here for the same reason everything else is:
        -- the holder's own TimerReady is the authoritative read, and it is local and instant. The baton
        -- chain existed to work this out by passing a turn around and waiting seconds at each hop; asking
        -- gets the same answer in one round trip.
        -- Offered only when no cleric rung is left, which preserves the ladder's order - the staff is the
        -- expensive one and stays last.
        if not best then
            -- THREE OPINIONS, NOT ONE. Accepting on TimerReady alone is how Ehaba said yes on 2026-08-14
            -- 06:04:46 with its staff on cooldown - it fired, nothing landed, and the tank spent thirty
            -- seconds discovering that. TimerReady returns NULL for transient reasons and `or 0` turns
            -- that into "ready", which is the single read that cannot be trusted on its own.
            -- All three were in the old commit and I carried only the first across when the ask replaced
            -- it. The old comment put the asymmetry exactly right: being wrongly told we are busy costs a
            -- turn that passes anyway, being wrongly told we are ready costs a charge.
            local secs = di_raw_staff()
            local em = 0
            pcall(function() em = tonumber(mq.TLO.FindItemCount('=' .. DI.REAGENT)()) or 0 end)
            local assumed = DI.assumeSpentUntil and mq.gettime() < DI.assumeSpentUntil
            -- ItemReady is a boolean rather than a countdown, so it cannot go stale the way a ticking
            -- timer can. Only consulted once it has been seen working on this client.
            local itemSaysNo = DI.itemReadyWorks and not tlo_true(DI.itemReady)
            -- My own last PUSHED reading is an independent sample from an earlier poll. Requiring it to
            -- agree costs nothing and cannot be fooled by one bad read.
            local mine = DI.state[myName]
            local reportSaysNo = mine and (mine.staff or 0) > 0
            -- Two emeralds are spent per cast, so anything less cannot fire.
            if secs == 0 and not assumed and not itemSaysNo and not reportSaysNo and em >= 2 then
                best = { name = DI.STAFF, kind = 'Item', staff = true }
            end
        end
        if not best then
            -- SAY WHY, not just no. With no fallback path to paper over a bad answer, the decline IS the
            -- diagnostic - and "nothing-ready" is the one thing that cannot be troubleshot from.
            -- Each of these is a local read that already happened above, so naming it costs nothing.
            local why = {}
            for _, r in ipairs(di_rung_list()) do
                if not r.ready then
                    local tag = di_rung_spent(r.name, r.kind) and '-just-fired' or '-cd'
                    why[#why + 1] = (r.name):gsub(' ', '-') .. tag
                end
            end
            local secs = di_raw_staff()
            if secs > 0 then why[#why + 1] = 'staff-' .. secs .. 's'
            elseif secs < 0 then why[#why + 1] = 'no-staff'
            elseif DI.assumeSpentUntil and mq.gettime() < DI.assumeSpentUntil then
                why[#why + 1] = 'staff-just-fired'
            elseif DI.itemReadyWorks and not tlo_true(DI.itemReady) then
                why[#why + 1] = 'staff-ItemReady-no'
            elseif DI.state[myName] and (DI.state[myName].staff or 0) > 0 then
                why[#why + 1] = 'staff-report-' .. DI.state[myName].staff .. 's'
            else
                local em = 0
                pcall(function() em = tonumber(mq.TLO.FindItemCount('=' .. DI.REAGENT)()) or 0 end)
                if em < 2 then why[#why + 1] = 'emeralds-' .. em end
            end
            local reason = (#why > 0) and table.concat(why, ',') or 'nothing-owned'
            pcall(function() peer_cmdf(tank, '/at_diack %s no %s', myName, reason) end)
            rezlog('[diq] %s asked for a save - declining: %s', tank, reason)
            return
        end
        rezlog('[diq] %s asked for a save - casting %s', tank, best.name)
        di_announce(best, tank)
        pcall(function() peer_cmdf(tank, '/at_diack %s yes %s', myName, (best.name):gsub(' ', '_')) end)
        -- Fired exactly the way the ladder fires it, including the spent-stamp that stops di_rung_list
        -- offering the same rung again on a timer that reads ready too soon.
        local tid = 0
        pcall(function() tid = tonumber(mq.TLO.Spawn('pc =' .. tank).ID()) or 0 end)
        if best.staff then
            -- FIRE IT HERE. Handing the baton over and letting di_tick commit does not work: the baton is
            -- soft state that every character recomputes for itself, and a character can also be sitting
            -- under its own savedUntil hold from an earlier refusal.
            -- 2026-08-14 05:39 has all of it at once - the baton was reset to Ejtou at 01.8, handed to
            -- Azyue by an ask at 02.3, Azyue was then held by a refusal and never committed, and Ejtou
            -- fired at 07.4 believing it still held the turn. Three characters, three views of the baton.
            -- THE ASK IS THE COORDINATION. The tank picked this character deliberately, a moment ago,
            -- from a local check - there is nothing left to negotiate and nothing else worth consulting.
            -- Everything the commit sets up is set up here, so the verify and retry in di_tick still
            -- own what happens after the cast.
            local em = 0
            pcall(function() em = tonumber(mq.TLO.FindItemCount('=' .. DI.REAGENT)()) or 0 end)
            peer_bcast('/at_difired')          -- everyone else stands down immediately
            if not cursor_stow('di') then
                rezlog('\\ay[di] cursor will not clear - firing the staff anyway\\ax')
            end
            local spec = DI.STAFF .. ((DI.OPTS ~= '') and DI.OPTS:format(tank) or '')
            rezlog('[diq] FIRING the staff for %s (%d emerald(s))', tank, em)
            pcall(function() mq.cmdf('/nowcast me "%s" %d', spec, tid) end)
            DI.watch = { at = mq.gettime(), em = em, tank = tank, tries = 1,
                         saveWas = (DI.state[tank] or {}).saveName }
            DI.assumeSpentUntil = mq.gettime() + DI.ASSUME_SPENT
            di_staff_stamp_write()   -- so a restart still knows this happened
            DI.pushNow = true        -- and say so at once; the client's timers will not
            -- DID IT ACTUALLY GO OUT? Two local reads answer that in about a second, and neither of them
            -- has anything to do with whether the save eventually lands on the tank - which is the slow
            -- question the 45s watch is for.
            -- Without this the tank has to infer a dud by waiting out its whole ceiling: on 2026-08-14
            -- 13:23 Ejtou claimed the staff, nothing went out, and fifteen seconds passed before anybody
            -- tried Azyue. The character that fired knew immediately.
            DIQ.self = { at = mq.gettime(), tank = tank, saw = false }
            DI.trigAt, DI.turnAt = 0, nil
        else
            DI.rungFiredAt = DI.rungFiredAt or {}
            DI.rungFiredAt[best.name] = mq.gettime()
            DI.pushNow = true          -- say so at once; the timers will not
            local spec = string.format(DI.RUNG_OPTS, best.name, best.kind, tank)
            pcall(function() mq.cmdf('/nowcast me "%s" %d', spec, tid) end)
        end
    end)
    -- The answer. 'yes' means it has gone out and the tank should watch for the save rather than ask
    -- somebody else; 'no' means move on now.
    -- NAMED /at_diack, NOT /at_didone: that one already exists and clears DI.firedAt. Binding the same
    -- command twice silently replaces the first, which is how the pre-existing win_open got shadowed
    -- earlier - a name already in use is not a free name.
    -- SOMEBODY IS CASTING A SAVE ON ME. Hold everything until it has had time to land: no asking anyone
    -- else, and no handing over to the old ladder. The claim is the only reason to wait, and it expires
    -- on its own if the cast comes to nothing.
    -- WHAT DOES THE STAFF ACTUALLY READ, RIGHT NOW?
    --   /atstaff        this character
    --   /atstaff all    every character in the group answers into its own log
    -- Every raw read side by side with what AdventureTime concludes from them, so a disagreement between
    -- "the client says ready" and "we decided ready" is visible rather than inferred.
    -- Worth having as a command rather than only at load: the load-time reading is the SUSPECT one -
    -- every character reports TimerReady=0 ItemReady=true there, including ones whose staff is certainly
    -- on cooldown - and the question is whether that ever corrects itself.
    mq.bind('/atstaff', function(scope)
        if scope and tostring(scope):lower() == 'all' then
            pcall(function() peer_bcast('/atstaff') end)
        end
        log('[staff] raw: %s', di_staff_reads())
        -- AT's own view, which is what actually decides
        local secs   = di_raw_staff()
        local assume = DI.assumeSpentUntil and math.max(0, DI.assumeSpentUntil - mq.gettime()) or 0
        local mine   = DI.state[myName]
        local em = 0
        pcall(function() em = tonumber(mq.TLO.FindItemCount('=' .. DI.REAGENT)()) or 0 end)
        log('[staff] AT sees: di_raw_staff=%ss | assumeSpent=%.0fs | myReport=%s | emeralds=%d | itemReadyWorks=%s',
            tostring(secs), assume / 1000,
            mine and tostring(mine.staff) or 'none', em, tostring(DI.itemReadyWorks))
        -- And the verdict the ask would give, with the reason.
        local itemSaysNo   = DI.itemReadyWorks and not tlo_true(DI.itemReady)
        local reportSaysNo = mine and (mine.staff or 0) > 0
        local ok = (secs == 0) and assume == 0 and not itemSaysNo and not reportSaysNo and em >= 2
        log('[staff] would I accept an ask? %s%s', ok and 'YES' or 'NO',
            ok and '' or string.format('  (%s%s%s%s%s)',
                (secs ~= 0) and ('timer=' .. tostring(secs) .. ' ') or '',
                (assume > 0) and 'just-fired ' or '',
                itemSaysNo and 'ItemReady-false ' or '',
                reportSaysNo and 'my-report-says-busy ' or '',
                (em < 2) and 'no-emeralds' or ''))
    end)
    mq.bind('/at_diclaim', function(who, what)
        if not who then return end
        -- IT IS HANDLED. No per-cast-type window, because there is nothing to time: a character that
        -- said yes is casting, and the tank's job is now to wait for its own save to appear - which it
        -- reads locally and instantly. Tuning a hold per spell was a guess that had to be right for every
        -- ability; this has nothing to be wrong about.
        local nm = tostring(what or ''):gsub('_', ' ')
        DIQ.casting, DIQ.castAt = who, mq.gettime()
        rezlog('[diq] %s has it - %s is on the way', who, nm)
    end)
    mq.bind('/at_diack', function(who, verdict, what)
        if not who then return end
        if DIQ.asked and who:lower() == DIQ.asked:lower() then
            if verdict == 'yes' then
                rezlog('[diq] %s is casting %s', who, tostring(what):gsub('_', ' '))
                DIQ.at = mq.gettime()      -- restart the clock: a cast is in flight now
            else
                rezlog('[diq] %s cannot (%s) - next', who, tostring(what or '?'))
                DIQ.tried[who:lower()] = true
                DIQ.asked = nil
            end
        elseif DIQ.casting and who:lower() == DIQ.casting:lower() and verdict ~= 'yes' then
            -- A character that CLAIMED and then found its cast never started. Releasing the claim here is
            -- the whole saving: without it the tank waits out DIQ_CAST_MS for something already known to
            -- have failed.
            rezlog('[diq] %s could not cast after all (%s) - moving on now', who, tostring(what or '?'))
            DIQ.tried[who:lower()] = true
            DIQ.casting, DIQ.asked = nil, nil
        end
    end)
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
    mq.bind('/at_rezready', function(char, cr, tk, al, zone, cw, dv) if char then rezReady[char] = { crown = tonumber(cr) or -1, token = tonumber(tk) or -1, cotw = tonumber(cw) or -1, divine = tonumber(dv) or -1, alive = (tonumber(al) == 1), zone = tonumber(zone) or 0, updated = mq.gettime() } end end)
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
    -- Retire a corpse permanently across the group. Used for raid bodies, where nobody will ever confirm
    -- the rez landed and a lapsing claim means a second charge on the same corpse.
    mq.bind('/at_rezretire', function(id)
        local n = tonumber(id)
        if n and n > 0 then rezCorpseDone[n] = true end
    end)
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
    mq.bind('/at_rezinc', function(from, cid)   -- a rezzer is casting on me right now: arm the accept window
        rezIncAt       = mq.gettime()   -- a REZZER said so; my own readiness does not count
        rezExpectFrom  = mq.gettime()
        rezExpectUntil = mq.gettime() + 20000
        -- Remember WHICH corpse, so the loot afterwards goes to the right one. Older builds send no id,
        -- in which case this is nil and the loot falls back to searching by name as before.
        rezCorpseID    = tonumber(cid) or nil
        rezlog('[rez] %s is rezzing me%s - watching for the confirmation box', tostring(from or '?'),
               rezCorpseID and (' (corpse ' .. rezCorpseID .. ')') or '')
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

-- Declared with the other persisted flags rather than here, so save_settings and load_settings -
-- which sit above this point in the file - can see it. A local declared below them would be a
-- different variable entirely and the setting would silently never load.
autoXTank = (autoXTank ~= false)  -- auto-maintain tank XTargets on the group's healers; on by default
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
        -- Retire, not a hold. An 8s back-off expires and we fire anyway - which is exactly what happened
        -- when Emerold crowned a body ten seconds after hearing Homar call it. Someone has spent a charge
        -- on this corpse; that is the whole reason for the shout.
        rezPending[n] = mq.gettime() + 8000
        rezCorpseDone[n] = true
        rezlog('[rez] %s (outside my group) called corpse %d (%s) - retiring it, they have it',
               who, n, tostring(tgt))
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
    -- THE GAME SAYS SO WHEN A MOB CANNOT BE PLACATED AT ALL. Retrying an immune mob is three casts and
    -- three cast times spent proving something the first message already told us - and worse, it looks
    -- exactly like a resist, which IS worth retrying. This tells the two apart.
    -- Marks whichever queue currently has a cast in flight; both use the same "did it land" question.
    -- THE CLIENT TELLING US IT IS DOWN. Catches the two cases self-tracking cannot see on its own: a
    -- fresh session with no history, and a click made by hand outside the script. The message costs
    -- nothing to provoke and settles the question absolutely - if the client refuses on recast, the pool
    -- is down whatever our own bookkeeping says.
    -- It cannot tell us HOW LONG is left, so it assumes a full cycle. That overshoots when the refusal
    -- comes late in the cooldown, which is the safe direction to be wrong in: a button that greys too
    -- long costs a few minutes, one that greys too little wastes the whole two hours on a refused click.
    -- at_nv_recast is gone with the guesswork. It existed to correct a self-tracked countdown from
    -- the client's refusal message; the item's own TimerReady needs no correcting.
    mq.event('at_ep_immune', 'Your target looks unaffected#*#', function()
        if epCast then
            rezlog('[placate] %s is immune - not retrying', epCast.name)
            ep_mark(epCast.id, 'immune', 'immune to placate')
            epCast = nil
        elseif pwCast then
            rezlog('[pw] %s is immune - not retrying', pwCast.name or '?')
            pw_mark(pwCast.id, 'immune', 'immune to it')
            if pwCast.prevTarget and pwCast.prevTarget > 0 then
                pcall(function() mq.cmdf('/target id %d', pwCast.prevTarget) end)
            end
            pwLast, pwCast = mq.gettime(), nil
        end
    end)
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
        -- A FLOOR HERE TOO, not just on the driver. This clears every last-reported cache, so the next
        -- few polls push the full state of this character back across the wire - burns, pots, heals,
        -- cures, magic, tribute. Cheap once. Three times in ten seconds, on six characters, is a flood
        -- for no new information: nothing about this toon changed just because the roster did.
        -- The driver rate limits its sending, but a worker should not depend on the driver being the
        -- build it thinks it is.
        if (mq.gettime() - lastResyncHonored) < 10000 then return end
        lastResyncHonored = mq.gettime()
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
    -- STOP AS SOON AS EVERYONE HAS ANSWERED. Every wait here used to run to its full length whatever
    -- happened, so a group already up and responding in 200ms still cost the driver 1.2 + 3.0 + 2.5
    -- seconds of frozen client. That is the multi-second startup gap, and it is on the driver only -
    -- which is why the worker logs go from "ready" to their next line in under half a second.
    -- The waits are still the same LENGTH; they are just ceilings now instead of fixed costs.
    local function all_up()
        for _, p in ipairs(peers) do if not alive[p:lower()] then return false end end
        return true
    end
    for _, p in ipairs(peers) do alive[p:lower()] = nil; peer_cmdf(p, '/at_ping %s', myName) end
    local w = 0
    while w < 1200 and not all_up() do mq.doevents(); mq.delay(100); w = w + 100 end

    -- SAY WHEN WE LAUNCH SOMETHING, AND WHY. This was silent, which makes "AdventureTime restarted on
    -- its own" impossible to tell from "somebody pressed something".
    -- It is the only path in the file that starts AT anywhere, and it fires whenever a driver sees a
    -- roster change and a group member does not answer a ping - so after a Close all that missed an
    -- instance outside the group, one surviving DRIVER brings everybody back.
    -- Close all only reaches group_members(); anything outside the group never hears it.
    local launched = false
    local started = {}
    for _, p in ipairs(peers) do
        if not alive[p:lower()] then
            peer_cmdf(p, '/lua run adventuretime worker %s', myName)
            started[#started + 1] = p
            launched = true
        end
    end
    if #started > 0 then
        log('\\ay[sync] starting AdventureTime on %s - no answer to my ping\\ax', table.concat(started, ', '))
    end
    -- ARE THEY STILL THERE? A pong only proves the instance was alive when it answered, and an instance
    -- can be on its way out: a Close all broadcast from a previous driver is still in flight for a second
    -- or so after the new one starts, so every worker answers the ping and then shuts down immediately
    -- afterwards. The driver saw a full group, launched nothing, and ended up alone.
    -- One more round after a short settle costs almost nothing when they are genuinely up - all_up
    -- returns at once - and catches exactly the toons that answered while dying.
    do
        mq.delay(1500)
        for _, p in ipairs(peers) do alive[p:lower()] = nil; peer_cmdf(p, '/at_ping %s', myName) end
        local w3 = 0
        while w3 < 1200 and not all_up() do mq.doevents(); mq.delay(100); w3 = w3 + 100 end
        local second = {}
        for _, p in ipairs(peers) do
            if not alive[p:lower()] then
                peer_cmdf(p, '/lua run adventuretime worker %s', myName)
                second[#second + 1] = p
                launched = true
            end
        end
        if #second > 0 then
            log('\\ay[sync] %s answered but went away - starting them again\\ax', table.concat(second, ', '))
        end
    end
    if launched then
        -- Only the ones that did NOT answer are being launched, so this settle is for them - and it can
        -- end the moment they check in rather than always running the full three seconds.
        local s = 0
        while s < 3000 and not all_up() do mq.doevents(); mq.delay(100); s = s + 100 end
        for _, p in ipairs(peers) do if not alive[p:lower()] then peer_cmdf(p, '/at_ping %s', myName) end end
        local w2 = 0
        while w2 < 2500 and not all_up() do mq.doevents(); mq.delay(100); w2 = w2 + 100 end
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
    -- FIRE THEM ALL, THEN SETTLE ONCE. This waited 50ms after every bag, so ten bags cost 500ms of
    -- nothing before the 300ms settle even started - and the settle is what actually matters, since the
    -- windows come up asynchronously regardless of how the commands were spaced.
    -- Reading Container() per bag is cheap; it is only the delays that were expensive.
    local opened = 0
    for b = 1, 10 do
        if (mq.TLO.Me.Inventory('pack' .. b).Container() or 0) > 0 then
            mq.cmdf('/itemnotify pack%d rightmouseup', b)
            opened = opened + 1
        end
    end
    -- One settle, scaled a little by how many actually went out rather than a flat number.
    if opened > 0 then mq.delay(250 + opened * 20) end
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
        mq.delay(900, function() local o = false
            pcall(function() o = mq.TLO.Window('QuantityWnd').Open() == true end)
            return o or (mq.TLO.Cursor.ID() or 0) > 0 end)
        if want < slotStack and not mq.TLO.Window('QuantityWnd').Open()
           and (mq.TLO.Cursor.ID() or 0) > 0 and (mq.TLO.Cursor.Stack() or 1) > want then
            mq.cmd('/autoinventory'); mq.delay(400, function() return (mq.TLO.Cursor.ID() or 0) == 0 end)
            mq.cmdf('/itemnotify pack%d rightmouseup', bag); mq.delay(300)
            mq.cmdf('/itemnotify in pack%d %d leftmouseup', bag, sl)
            mq.delay(900, function() local o = false
            pcall(function() o = mq.TLO.Window('QuantityWnd').Open() == true end)
            return o or (mq.TLO.Cursor.ID() or 0) > 0 end)
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
    mq.delay(3000, function() local o = false
        pcall(function() o = mq.TLO.Merchant.Open() == true end); return o end)
    if not mq.TLO.Merchant.Open() then log('\\arCould not open %s\'s merchant window.\\ax', vendor); return 0 end
    mq.delay(6000, function() local o = false
        pcall(function() o = mq.TLO.Merchant.ItemsReceived() == true end); return o end)

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
        mq.delay(900, function() local o = false
            pcall(function() o = mq.TLO.Window('QuantityWnd').Open() == true end)
            return o or my_count(item) >= goal end)
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
    -- Named hold rather than a bare /e3p, so finishing a distribution cannot release a placate run that
    -- is still holding this character's weapons off.
    if mode == 'on' then e3_hold('distribute') else e3_release('distribute') end
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
-- Per-character rez scope. THREE states, not two, because "sit them out" and "let them rez strangers"
-- are different decisions and both come up:
--   nil / 'group'  green   - group corpses only. The default, and what everyone did before.
--   'off'          red     - no rezzes at all. Sat out of the rez and DI chains entirely.
--   'raid'         purple  - group AND raid corpses. Willing to spend a charge on a stranger.
-- One list drives both chains, because the reason to change a character's scope is about the character
-- rather than the mechanic, and two lists would be two things to keep in step.
-- A character is still SHOWN whatever their mode: knowing what a sat-out toon is holding is exactly what
-- you want when deciding to put them back in.
chainMode       = {}      -- [nameLower] = 'off' | 'raid'   (absent = group only)
function chain_mode(nm) return chainMode[(nm or ''):lower()] or 'group' end
function chain_off(nm)  return chain_mode(nm) == 'off' end
uiLocked        = false   -- lock both windows in place: no dragging, no resizing
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
portProbeWant = nil      -- slots to probe on the next tick; set by /atportlist
miniInvisRows   = false   -- show the per-character Invis/ITU pick rows
miniInvisCombo  = false   -- show the one-press Invis combo button
miniCures       = false   -- show the cure buttons (Radiant Cure etc) in the mini window
miniArcane      = false   -- show the Arcane Reprisal row in the mini window
miniPhantom     = false   -- show the Phantom Whispers queue in the mini window
miniPlacate     = false   -- show the enchanter Placate queue in the mini window
miniPacify      = false   -- show the routed Pacify queue in the mini window
miniNightveil   = false   -- show the Nightveil emblem buttons in the mini window
epState         = {}      -- char -> true when that toon is the enchanter working the queue
epLast          = 0
epSaidGem       = nil     -- last gem contents we spoke about, so it is said once not every tick
epGemSaidAt     = 0       -- rate-limit for the 'waiting on the gem' line
epCursorTryAt   = 0       -- rate-limit on /autoinventory attempts to clear the cursor
epOorSaidAt     = 0       -- rate-limit for the 'out of range' line
epMemAt         = nil     -- when we last issued a /memspell, so we do not stack attempts
epPrevTarget    = 0       -- the caller's target when the run started; put back when the queue finishes
epTestWant      = nil     -- set by /atplacatetest; the MAIN LOOP runs the soak, not the bind callback
altPullWant     = nil     -- set by /atpull; the MAIN LOOP does the window driving
altWithdrawAllWant = nil  -- set by Withdraw All; the MAIN LOOP asks EVERY holder
altReclaimAllWant  = nil  -- set by Reclaim All; asks every holder to push items back to currency
altReclaimWant     = nil  -- set by /atreclaim on this toon
altcurTabFound  = nil     -- the Alt. Currency tab index once proven, so the search runs once
tribWant        = nil     -- set by the Tribute button; the MAIN LOOP navs and donates
tribGroupWant   = nil     -- set by Trib group; the MAIN LOOP fans it out to everyone holding some
tribBagsOpen    = false   -- so cleanup only closes bags this routine actually opened
dcGiveWant      = nil     -- set by the Diamond Coin Give button; the MAIN LOOP runs it
altCurRefresh   = nil     -- when to re-read balances after a withdraw
arcLast         = nil     -- my last-pushed arcane state, for change detection
miniMagic       = false   -- show the magic protection clicky buttons in the mini window
miniBurnView    = 1       -- burns section: 0 = compact, 1 = tier matrix, 2 = full detail table
miniBurnTable   = false   -- LEGACY, kept only so an old settings file can be migrated below
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
atExitWhy = nil                   -- set at whichever exit is taken, printed on the way out
local collectRequested = false   -- set by the Collect-all button; MAIN LOOP runs collect_all
local showStatus = false          -- toggle: show each toon's count per item (green if >= target, red if <)
local refreshRequested = false    -- set to re-read the group's counts for the status view
local statusResize = false        -- widen the window once when status is turned on
-- GLOBAL, NOT LOCAL. /at_altbags at line ~4916 writes to this, which is ABOVE this line - so as a local
-- it was not yet in scope there and the name resolved to a nil global, crashing the bind every time a
-- peer reported its bag count. Declaring it global also gives a local slot back, and the main chunk is
-- at Lua's 200 ceiling.
statusCounts = {}                 -- peerlower -> { item -> count } (cached)
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
        -- The PLANNER, not just the display. Greying a cell without this would be cosmetic - the give-out
        -- would still walk rubies out to five characters who cannot use them.
        if ck and is_ruby(item) and not WANTS_RUBY[ck] then return 0 end
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
local COL_RUBY = { 0.90, 0.35, 0.42 }   -- ruby red
local COL_DC   = { 0.62, 0.82, 0.95 }   -- diamond pale blue

-- Grouped item lists (organized by tier).
local LIST_I, LIST_II = {}, {}
for _, base in ipairs(DRAUGHTS) do
    LIST_I[#LIST_I + 1]  = base .. ' I'
    LIST_II[#LIST_II + 1] = base .. ' II'
end

local function short_name(n) return (n:sub(1, 7)) end   -- 7: 'Sunetoo' fits, 5 gave 'Sunet'

-- `altCurrency` draws one extra row INSIDE this table for a currency of the same name. It has to be in
-- the table or it cannot line up: the balances belong under the same per-character columns as the item
-- counts, and a line drawn after EndTable is just text floating under a grid at whatever width it likes.
-- That is what "Alt Currency: Sebb 168 Nity 100 ..." was - correct numbers, no relationship to the
-- columns above them.
local function render_group(label, color, items, altCurrency)
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
    -- One more column for the group TOTAL. Free: it is a sum of numbers already fetched, so no extra
    -- query and no extra network - the counts pass is unchanged.
    local nCols = statusOn and (3 + #statusNames) or 2   -- name + [one per toon] + total + target
    if ImGui.BeginTable('##grp_' .. (label or items[1]), nCols, (ImGuiTableFlags.BordersOuter or 0) + (ImGuiTableFlags.SizingFixedFit or 0)) then
        ImGui.TableSetupColumn('##n', ImGuiTableColumnFlags.WidthFixed or 0, 150)
        if statusOn then
            for _, nm in ipairs(statusNames) do ImGui.TableSetupColumn(short_name(nm), ImGuiTableColumnFlags.WidthFixed or 0, 56) end
            ImGui.TableSetupColumn('all', ImGuiTableColumnFlags.WidthFixed or 0, 56)
        end
        -- The last column holds a target box on item rows, but a quantity field AND two buttons on a
        -- currency row. At 60px those overlap into the "| |" mess - so widen it when there is a currency
        -- row to draw, and leave it alone otherwise.
        -- 172 fitted a quantity box and two buttons. It now carries five controls - qty, Get, All,
        -- Me, Group - and ImGui truncates rather than wrapping, so the column has to be sized for what
        -- is actually in it. Measured roughly: 56 field + four small buttons + spacing.
        ImGui.TableSetupColumn('##e', ImGuiTableColumnFlags.WidthFixed or 0, altCurrency and 330 or 60)
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
                    elseif ck and ((is_endurance(it) and not WANTS_ENDURANCE[ck])
                                or (is_mana(it) and not WANTS_MANA[ck])
                                or (is_ruby(it) and not WANTS_RUBY[ck])) then
                        ImGui.TextDisabled(tostring(n))   -- holds this many but won't use them (grey = not needed)
                    elseif n >= tgt then
                        ImGui.TextColored(0.40, 0.82, 0.45, 1.0, tostring(n))
                    else
                        ImGui.TextColored(0.93, 0.42, 0.42, 1.0, tostring(n))
                    end
                end
                -- GROUP TOTAL. Sums only what was actually read: a toon whose count timed out is
                -- excluded and the figure is marked with a + so it reads as "at least this many"
                -- rather than a number that quietly understates what the group is holding.
                local total, missing = 0, 0
                for _, nm2 in ipairs(statusNames) do
                    local sc2 = statusCounts[nm2:lower()]
                    if sc2 and sc2.__unknown and sc2.__unknown[it] then missing = missing + 1
                    else total = total + ((sc2 and sc2[it]) or 0) end
                end
                ImGui.TableNextColumn()
                -- The group target counts only characters that can actually use the item, so a
                -- cleric-only reagent does not read as a shortfall against six people's worth.
                local users = 0
                for _, nm3 in ipairs(statusNames) do
                    local ck3 = class_key((statusCounts[nm3:lower()] or {}).__class)
                    local skip = ck3 and ((is_endurance(it) and not WANTS_ENDURANCE[ck3])
                                       or (is_mana(it) and not WANTS_MANA[ck3])
                                       or (is_ruby(it) and not WANTS_RUBY[ck3]))
                    if not skip then users = users + 1 end
                end
                -- WANTED IS PER USER, NOT PER CHARACTER. Rubies are cleric-only, so a target of 500 with
                -- one cleric needs 500 across the group - not 3000 because there happen to be six of you.
                -- The same rule that greys the cells and stops the planner handing them out decides this.
                local wanted = tgt * users
                if missing > 0 then
                    -- Incomplete: cannot honestly call it either way, so neither green nor red.
                    ImGui.TextColored(0.95, 0.85, 0.30, 1.0, string.format('%d+', total))
                elseif wanted <= 0 then
                    -- No target set, or nobody in the group uses it. Nothing to be short OF.
                    ImGui.TextDisabled(tostring(total))
                elseif total >= wanted then
                    ImGui.TextColored(0.40, 0.82, 0.45, 1.0, tostring(total))
                else
                    ImGui.TextColored(0.93, 0.42, 0.42, 1.0, tostring(total))
                end
                if ImGui.IsItemHovered and ImGui.IsItemHovered() then
                    pcall(function() ImGui.SetTooltip(string.format(
                        '%s\n%d across the group%s\n%s',
                        display_name(it), total,
                        (missing > 0) and string.format('\n%d toon(s) did not report - the real total is higher', missing) or '',
                        (users == 0) and 'nobody in the group uses this'
                          or (tgt <= 0) and 'no target set'
                          or string.format('need %d (%d each x %d who use it) - %s',
                                           wanted, tgt, users,
                                           (total >= wanted) and 'enough' or string.format('short %d', wanted - total))
                        )) end)
                end
            end
            ImGui.TableNextColumn()
            ImGui.SetNextItemWidth(-1)
            -- Narrower when a Give button shares the cell, so the two do not fight for width.
            ImGui.SetNextItemWidth((altCurrency == it) and 70 or -1)
            local v = ImGui.InputInt('##t_' .. it, target[it] or 0, 0)   -- step 0 -> no +/- buttons
            v = math.max(0, math.floor(tonumber(v) or 0))
            if v ~= target[it] then target[it] = v; save_targets() end
            -- GIVE SITS NEXT TO THE NUMBER IT USES. It was on the currency row, one line below and
            -- beside a DIFFERENT quantity box - so which number it would hand out was a guess. The
            -- target is the per-character amount, so the button belongs against it.
            if altCurrency == it then
                local q = target[it] or 0
                ImGui.SameLine()
                if ImGui.SmallButton('Give##dcgive_' .. it) then
                    dcGiveWant = { item = it, currency = altCurrency }
                end
                if ImGui.IsItemHovered and ImGui.IsItemHovered() then
                    pcall(function() ImGui.SetTooltip(string.format(
                        'Will give %d %s to each character,\nand pull from Alt Currency if short.', q, it)) end)
                end
                -- TRIBUTE READS THE SAME BOX. It used to mean "all of it", sitting on the row below
                -- next to Withdraw All - so the obvious reading was that it would donate every coin the
                -- group owned. That is a bad thing to be one misread away from. Bound to the quantity,
                -- on the same line as the number, it can only ever spend what is typed there.
                ImGui.SameLine()
                ImGui.TextDisabled('Tribute:')
                ImGui.SameLine()
                if ImGui.SmallButton('Me##trib_' .. it) then
                    tribWant = { item = it, qty = q }
                end
                if ImGui.IsItemHovered and ImGui.IsItemHovered() then
                    pcall(function() ImGui.SetTooltip(string.format(
                        'Will walk to a tribute master and donate %d %s.\nYou are holding %d.',
                        q, it, (counts[myName:lower()] or {})[it] or 0)) end)
                end
                ImGui.SameLine()
                if ImGui.SmallButton('Group##tribg_' .. it) then
                    tribGroupWant = { item = it, qty = q }
                end
                if ImGui.IsItemHovered and ImGui.IsItemHovered() then
                    pcall(function() ImGui.SetTooltip(string.format(
                        'Every character walks to its own tribute master\nand donates up to %d %s of its own.', q, it)) end)
                end
            end
        end

        -- The currency row: same columns, so a character's balance sits directly under their count.
        if altCurrency and statusOn then
            ImGui.TableNextRow()
            ImGui.TableNextColumn()
            ImGui.TextColored(0.62, 0.82, 0.95, 1.0, 'in Alt Currency')
            local total, unknown = 0, 0
            for _, nm in ipairs(statusNames) do
                ImGui.TableNextColumn()
                local bal = (altCounts[nm:lower()] or {})[altCurrency]
                if bal == nil then
                    unknown = unknown + 1
                    ImGui.TextDisabled('?')
                    if ImGui.IsItemHovered and ImGui.IsItemHovered() then
                        pcall(function() ImGui.SetTooltip(nm .. '\nnever answered - press Counts again') end)
                    end
                elseif bal == 'shut' then
                    unknown = unknown + 1
                    ImGui.TextColored(0.90, 0.72, 0.35, 1.0, 'shut')
                    if ImGui.IsItemHovered and ImGui.IsItemHovered() then
                        pcall(function() ImGui.SetTooltip(nm ..
                            '\nanswered, but could not read its currency list') end)
                    end
                elseif bal > 0 then
                    total = total + bal
                    ImGui.TextColored(0.62, 0.82, 0.95, 1.0, tostring(bal))
                else
                    ImGui.TextDisabled('0')
                end
            end
            ImGui.TableNextColumn()
            if unknown > 0 then ImGui.TextColored(0.95, 0.85, 0.30, 1.0, string.format('%d+', total))
            else                ImGui.TextColored(0.62, 0.82, 0.95, 1.0, tostring(total)) end
            ImGui.TableNextColumn()
            -- WITHDRAW ALL, no quantity box. There is nothing to decide: converting a balance you are
            -- not using costs nothing and the alternative was a second number sitting next to a
            -- different one, with no way to tell which button read which.
            local anyBal = false
            for _, nm in ipairs(statusNames) do
                local b2 = (altCounts[nm:lower()] or {})[altCurrency]
                if type(b2) == 'number' and b2 > 0 then anyBal = true; break end
            end
            if anyBal then
                if ImGui.SmallButton('Withdraw All##altwall_' .. altCurrency) then
                    altWithdrawAllWant = { name = altCurrency }
                end
                if ImGui.IsItemHovered and ImGui.IsItemHovered() then
                    pcall(function() ImGui.SetTooltip(
                        'Will withdraw all ' .. altCurrency .. ' from Alt Currency,\non every character that has any.') end)
                end
            else
                ImGui.TextDisabled('nothing to withdraw')
            end
            -- The other direction. Anyone holding the ITEM can push it back into currency, which is a
            -- different set of characters from the ones holding a balance - hence its own check.
            local anyItem = false
            for _, nm in ipairs(statusNames) do
                if ((counts[nm:lower()] or {})[altCurrency] or 0) > 0 then anyItem = true; break end
            end
            ImGui.SameLine()
            if anyItem then
                if ImGui.SmallButton('Reclaim All##altrec_' .. altCurrency) then
                    altReclaimAllWant = { name = altCurrency }
                end
                if ImGui.IsItemHovered and ImGui.IsItemHovered() then
                    pcall(function() ImGui.SetTooltip(
                        'Will put all ' .. altCurrency .. ' in bags back into Alt Currency,\non every character holding any.') end)
                end
            else
                -- SAY THE SPACE IS EMPTY rather than drawing nothing. With no else branch the button
                -- simply vanished whenever nobody held any in bags - which is the normal state right
                -- after a tribute run - and a control that disappears reads as broken, not as idle.
                -- The Withdraw side above already does this; the two now behave the same way.
                ImGui.TextDisabled('nothing to reclaim')
            end

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

-- THE THIRD VIEW: ONE DOT PER TIER, not one per item. That is where the size goes - the other two
-- views both draw every burn as its own glyph, so transposing the grid changed the shape and not the
-- width. Six characters at five glyphs each is the same table either way round.
--
--             Khul 18/18  Luna 15/17  Sune 9/9  Styl 17/17
--   5min      *           -           *         *
--   10min     *           *           *         *
--   15min     *           *           *         *
--
-- Each cell is a single dot whose colour is that tier's state for that character, and the header
-- carries the ready count. That is the "quick glance" question answered - is this tier up for this
-- toon - and the item-level detail is what the other two views are for. Hover names the items.
-- Roughly a third the width, because a column now needs room for one glyph rather than six.
function draw_burn_compact()
    local chars = {}
    for _, c in ipairs(ordered_members()) do
        if burnState[c] then chars[#chars + 1] = c end
    end
    if #chars == 0 then ImGui.TextDisabled('no burn reports yet'); return end
    local tiers = burn_tiers_present(chars)
    if #tiers == 0 then ImGui.TextDisabled('no burns configured'); return end

    local flags = (ImGuiTableFlags.BordersInnerV or 0) + (ImGuiTableFlags.RowBg or 0)
                + (ImGuiTableFlags.SizingFixedFit or 0)
    if not ImGui.BeginTable('##burncompact', 1 + #chars, flags) then return end
    ImGui.TableSetupColumn('', ImGuiTableColumnFlags.WidthFixed or 0, 58)
    for _ = 1, #chars do ImGui.TableSetupColumn('', ImGuiTableColumnFlags.WidthFixed or 0, 46) end

    ImGui.TableNextRow()
    ImGui.TableNextColumn()
    for _, c in ipairs(chars) do
        ImGui.TableNextColumn()
        local total, ready = 0, 0
        for _, st in pairs(burnState[c] or {}) do
            if (st.tier or 0) > 0 then
                total = total + 1
                if st.active or burn_remain(st) == 0 then ready = ready + 1 end
            end
        end
        -- NAME ONLY. The 18/18 totals were the least useful number on the row: nobody acts on "how many
        -- burns does this character own", and every cell below already says what is up per tier.
        ImGui.TextColored(0.80, 0.80, 0.80, 1.0, c:sub(1, 4))
        local _ = ready + total   -- counted above; kept for the hover, not shown here
    end

    for _, t in ipairs(tiers) do
        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        -- 'minBurn' on every label is noise when the column is only ever burns.
        ImGui.TextColored(0.85, 0.72, 0.35, 1.0, (t.label:gsub('[Bb]urns?$', ''):gsub('%s+$', '')))
        for _, c in ipairs(chars) do
            ImGui.TableNextColumn()
            local n, up, soon, names = 0, 0, false, {}
            for it, st in pairs(burnState[c] or {}) do
                if (st.tier or 0) > 0 and (st.tkey or '?') == t.key then
                    n = n + 1
                    local r = burn_remain(st)
                    if st.active or r == 0 then up = up + 1
                    elseif r > 0 and r < 60 then soon = true end
                    names[#names + 1] = it
                end
            end
            if n == 0 then
                ImGui.TextDisabled('-')
                if ImGui.IsItemHovered and ImGui.IsItemHovered() then
                    pcall(function() ImGui.SetTooltip(c .. ' has nothing at ' .. t.label) end)
                end
            else
                -- ONE PLAIN DOT PER BURN, each coloured by its own state. Not the FontAwesome icons the
                -- other views use - those carry the item KIND, which is detail this view is deliberately
                -- dropping, and they are three or four times the width of a bullet. Not "3/5" either:
                -- five dots with two of them red says the same thing and reads without parsing.
                -- ONE TOOLTIP FOR THE WHOLE CELL, attached to every dot in it. A bullet is a tiny hover
                -- target and there is no point making them bigger - the size is the feature - so instead
                -- each dot answers for the cell. Hovering anywhere in the run gives the same full list,
                -- which makes the effective target the whole group of dots rather than one of them.
                -- Built once per cell rather than per dot: same string, and it is not free to assemble.
                table.sort(names)
                local lines = { c .. '  ' .. t.label }
                for _, it in ipairs(names) do
                    local st = burnState[c][it]
                    local r = burn_remain(st)
                    if st.active then      lines[#lines + 1] = '  ' .. it .. '  (running)'
                    elseif r == 0 then     lines[#lines + 1] = '  ' .. it .. '  ready'
                    elseif r < 0 then      lines[#lines + 1] = '  ' .. it
                    else lines[#lines + 1] = string.format('  %s  %d:%02d', it, math.floor(r / 60), r % 60) end
                end
                local tip = table.concat(lines, '\n')
                for i, it in ipairs(names) do
                    local st = burnState[c][it]
                    local cr, cg, cb = burn_colour(st)
                    if i > 1 then ImGui.SameLine(0, 2) end
                    ImGui.TextColored(cr, cg, cb, 1.0, '\226\128\162')
                    if ImGui.IsItemHovered and ImGui.IsItemHovered() then
                        pcall(function() ImGui.SetTooltip(tip) end)
                    end
                end
            end
        end
    end
    ImGui.EndTable()
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
-- Whether the tank is covered, as one line. Shared so it can sit on the section HEADER as well as in
-- the panel: it is the thing you actually want to know from the DI section, and it should not disappear
-- because the section happens to be folded.
function draw_di_save_line()
    local tank = di_tank()
    if not tank then
        ImGui.TextDisabled('no tank in group')
        return
    end
    local ds = DI.state[tank]
    if not ds then
        ImGui.TextDisabled(tank .. ': no report')
    elseif ds.saveUp == 1 then
        -- NAME IT. 'has a save' does not tell you whether that is the thirty-second Guardian or a real
        -- Divine Intervention, and those are very different amounts of comfort - the tank already reports
        -- saveName, it simply was not being shown.
        -- Shortened the way the announce does, because the panel is narrow and 'Divine Intervention'
        -- pushes everything else off the row.
        local nm = tostring(ds.saveName or '')
        local short = (nm == 'Divine Intervention') and 'DI'
                   or (nm == 'Divine Redemption') and 'DR'
                   or (nm == 'Divine Guardian') and 'Guardian'
                   or (nm ~= '' and nm) or 'a save'
        ImGui.TextColored(0.35, 0.90, 1.00, 1.0, string.format('%s: %s', tank, short))
        if ImGui.IsItemHovered and ImGui.IsItemHovered() and nm ~= '' then
            pcall(function() ImGui.SetTooltip(tank .. ' is carrying ' .. nm) end)
        end
    else
        ImGui.TextDisabled(tank .. ': no save')
    end
    -- OFF SWITCH, ON THE ROW YOU ALREADY WATCH. Worth having anywhere, and worth having HERE once DI runs
    -- outside combat: the moment you want it off is the moment something is behaving oddly, and hunting
    -- through Settings for it is the wrong experience at that moment.
    -- PLAIN SameLine, NOT one positioned from the window width. Placing at GetWindowWidth() - 46 extends
    -- the content width to that point, which grows the window, which moves the position further right on
    -- the next frame - and the window creeps wider every frame it is drawn.
    -- Exactly the drift the CoTH status text caused in 1.07.8, fixed the same way: stop deriving a
    -- position from the size the position affects.
    ImGui.SameLine()
    if DI.auto then
        ImGui.PushStyleColor(ImGuiCol.Text, 0.45, 0.82, 0.50, 1.0)
        if ImGui.SmallButton('DI on##ditoggle') then DI.auto = false; save_settings() end
        ImGui.PopStyleColor()
    else
        ImGui.PushStyleColor(ImGuiCol.Text, 0.95, 0.55, 0.45, 1.0)
        if ImGui.SmallButton('DI OFF##ditoggle') then DI.auto = true; save_settings() end
        ImGui.PopStyleColor()
    end
    if ImGui.IsItemHovered and ImGui.IsItemHovered() then
        pcall(function() ImGui.SetTooltip(DI.auto
            and 'DI is running - click to stop it asking for saves'
            or  'DI is OFF - nothing will be asked for or cast') end)
    end
end

function draw_di_mini()
    -- Drawn on the header now, so the panel does not repeat it. See the mini render loop.

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
    COMBO_FILE = at_read('adventuretime_combos.txt')
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
    -- ONE 'Boots' ROW FOR BOTH. The enchanter shoes and the shaman boots are the same effect from two
    -- sources, so they share a group and collapse into a single row - two rows become one whenever a
    -- group happens to hold both. short only shows when ONE character carries both, which is the only
    -- case where telling them apart matters.
    { key = 'illusionist', label = 'Boots', group = 'Boots', short = 'shoes',
      name = "Forsaken Illusionist's Shoes" },
    { key = 'jaundiced',   label = 'Boots', group = 'Boots', short = 'boots',
      name = 'Forsaken Jaundiced Bone Boots' },
    { key = 'echoes',      label = 'Rune of Echoes',    group = 'Echoes', short = 'rune',
      name = 'Imbued Rune of Echoes' },
    -- spell = ... rather than name = ...: this one is a SONG, so "do you have it" means memmed in a
    -- gem, not sitting in a bag. Un-memmed and the button simply is not drawn.
    { key = 'echopast',    label = 'Echoes of the Past', group = 'Echoes', short = 'past',
      spell = 'Echoes of the Past' },
    -- Echoes of the Ancient: the glyph and the song are two ways at the SAME effect, so they share a
    -- group and appear as one row with two buttons rather than two near-identical rows. The glyph is an
    -- item (name =, so ownership means it is in a bag); the song is a spell (spell =, so ownership means
    -- memmed in a gem). A toon carrying neither gets no button at all.
    { key = 'echoancglyph', label = 'Echoes of the Ancient', group = 'Echoes', short = 'glyph',
      name = 'Imbued Glyph: Echoes of the Ancient' },
    { key = 'echoancient',  label = 'Echoes of the Ancient', group = 'Echoes', short = 'ancient',
      spell = 'Echoes of the Ancient' },
    -- CIRCLE OF ALENDAR, two ways at it. The bracelet clicks the same spell the enchanter casts, so they
    -- share a group and read as one row - same pattern as the Boots and the Echoes lines above.
    -- spell = for the cast (ownership means memmed in a gem), name = for the clicky (ownership means it
    -- is in a bag), so a character with only one of them gets only that button.
    { key = 'alendar',     label = 'Circle of Alendar', group = 'Alendar', short = 'spell',
      spell = 'Circle of Alendar' },
    { key = 'alendarband', label = 'Circle of Alendar', group = 'Alendar', short = 'bracelet',
      name = "Forsaken Illusionist's Bracelet" },
    -- INVIS AND INVIS-TO-UNDEAD, as AAs. Two rows because they are two different effects and you pick
    -- one deliberately: walking past undead with plain invis gets somebody killed.
    -- aa = rather than spell = or name =: an AA is not gemmed and is not in a bag, so neither of the
    -- existing kinds reads it correctly - the gem branch would look for a gem it never occupies.
    { key = 'invisperf',  label = 'Invis', group = 'Invis', short = 'perfected',
      aa = 'Group Perfected Invisibility' },
    { key = 'invissilent', label = 'Invis', group = 'Invis', short = 'silent',
      aa = 'Group Silent Presence' },
    { key = 'inviscamo',  label = 'Invis', group = 'Invis', short = 'camo',
      aa = 'Shared Camouflage' },
    { key = 'itu',        label = 'ITU',   group = 'ITU',   short = 'perfected',
      aa = 'Group Perfected Invisibility to Undead' },
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
    -- AA FIRST, because it is neither of the other two. An AA has no gem and no item timer, so the spell
    -- branch below would look for a gem it never occupies and the item branch for a bag entry that is
    -- not there - both reporting "not owned" for something the character definitely has.
    -- AltAbilityTimer is what is LEFT on it. It reports 1 for an ability you do not own, so ownership is
    -- settled by have_thing, which checks AltAbility.Rank.
    -- Four values, matching every other branch: have, secs, up, dsecs.
    if e.aa then
        local secs = 0
        pcall(function() secs = math.floor(tonumber(mq.TLO.Me.AltAbilityTimer(e.aa).TotalSeconds()) or 0) end)
        if secs <= 1 then secs = 0 end
        return (have_thing(e.aa) and 1 or 0), secs, 0, 0
    end
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
        -- THE GEM'S OWN TIMER, WITH SLACK - not SpellReady, and not a debounce on it either.
        -- SpellReady answers "can I cast this INSTANT", so on a bard it is false nearly all the time:
        -- twisting songs means something is almost always going out. Debouncing only forgives a false
        -- that is held BRIEFLY, and a bard's is held continuously - so the window expired and the button
        -- went red anyway, which is the Echoes row staying red after we thought it was fixed.
        -- The gem timer does not care what else is being cast. A song in flight leaves a second or two
        -- on it; a real recast leaves far more. Same five second split that fixed the DI save ladder.
        local secs = 0
        pcall(function() secs = math.floor(tonumber(mq.TLO.Me.GemTimer(e.spell).TotalSeconds()) or 0) end)
        local rdy = (secs <= GEM_READY_SLACK)
        if rdy then secs = 0 end
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
    if e.aa then
        pcall(function() mq.cmdf('/nowcast %s "%s/CastType|AA"', myName, e.aa) end)
    elseif e.spell then
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
        -- INVIS AND ITU BELONG TO THE INVIS SECTION, not here. They live in MAGIC_CLICKS because that is
        -- where ownership, cooldowns and the click path are already solved - but they are drawn by
        -- draw_invis, with its own coverage row, combo and Drop invis. Leaving them here as well put the
        -- same two rows in two places.
        if g ~= 'Invis' and g ~= 'ITU' then
            if not byGroup[g] then byGroup[g] = {}; order[#order + 1] = g end
            table.insert(byGroup[g], e)
        end
    end

    local drewAny = false
    for _, g in ipairs(order) do
      if not cm_hidden(g) then
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
    end
    -- Same here: silent when there is nothing to show. If every row in Countermeasures is empty the
    -- section simply draws nothing, which is the correct amount of space for no content.
    if not drewAny then return end
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

-- The per-character scope buttons, shared by the mini section and the Rez tab. One implementation on
-- purpose: two copies of a three-state cycle is two places for the states to end up in a different
-- order, and it is the sort of difference nobody notices until a character is set to something they
-- did not intend.
-- The wipe button, shared by the mini section and the Rez tab. ONE button that changes rather than two
-- sitting side by side: only one of them is ever the right thing to press, and a permanent 'Clear wipe'
-- next to a live 'Wipe' is an invitation to hit the wrong one in a hurry.
-- Colour carries the state as well as the label, because in a wipe you are reading at a glance.
-- A SETTLE AFTER IT FLIPS. Wipe and Clear wipe share one position and swap on rezWipe, so the instant
-- a press sets it the button underneath the cursor becomes the opposite one - and the same press can
-- take it straight back off. Antilerd's log has both lines 13ms apart, one frame, from one click.
-- Of every button in the file this is the worst one for it: you press Wipe in a hurry, mid-death, and
-- the failure is silent - rezzes resume and everyone lands back on what killed them.
-- Half a second is far longer than a frame and far shorter than a deliberate second press.
rezWipeFlipAt = 0
-- CLOSE ALL ASKS FIRST. It shuts down every instance across the group, and it sits one button away from
-- Mini on the top row - a button you press casually, several times a session. There is no undo: the only
-- way back is relaunching the driver and letting it re-spread the workers, which is exactly what "AT
-- keeps restarting on the driver" looks like from the outside.
-- Two presses, and the second has a five second window - long enough to be deliberate, short enough that
-- an armed button cannot sit there waiting to catch a later stray click.
closeArmedAt = 0
function draw_close_all(tag, big)
    local armed = (mq.gettime() - (closeArmedAt or 0)) < 5000
    local label = armed and ('Really close all?##' .. tag) or ('Close all##' .. tag)
    if armed then ImGui.PushStyleColor(ImGuiCol.Button, 0.62, 0.20, 0.20, 1.0) end
    local hit
    if big then hit = ImGui.Button(label, 130, 0) else hit = ImGui.SmallButton(label) end
    if armed then pop_state_button(1) end
    if hit then
        if armed then
            closeArmedAt = 0
            closeAllRequested = true
        else
            closeArmedAt = mq.gettime()
        end
    end
    if ImGui.IsItemHovered and ImGui.IsItemHovered() then
        pcall(function() ImGui.SetTooltip(armed
            and 'Press again to shut down AdventureTime on EVERY character.'
            or  'Shuts down AdventureTime on every character in the group.\nAsks once more before it does.') end)
    end
end

function draw_wipe_button(tag)
    local settled = (mq.gettime() - (rezWipeFlipAt or 0)) > 500
    if rezWipe then
        ImGui.PushStyleColor(ImGuiCol.Button, 0.55, 0.32, 0.12, 1.0)
        local hit = ImGui.SmallButton('Clear wipe##wipe' .. tag)
        pop_state_button(1)
        if hit and settled then
            rezWipe, rezWipeFlipAt = false, mq.gettime()
            pcall(function() peer_bcast('/at_wipe off') end)
            rezlog('[rez] wipe cleared for the group')
        end
        if ImGui.IsItemHovered and ImGui.IsItemHovered() then
            pcall(function() ImGui.SetTooltip(
                'Rezzes are HELD. Clears itself when this character zones,\nor press this to start again now.') end)
        end
        ImGui.SameLine()
        ImGui.TextColored(0.95, 0.62, 0.25, 1.0, 'WIPE - rezzes held')
    else
        if ImGui.SmallButton('Wipe##wipe' .. tag) and settled then
            rezWipe, rezWipeFlipAt = true, mq.gettime()
            pcall(function() peer_bcast('/at_wipe on') end)
            pcall(function() mq.cmd('/gsay AdventureTime: WIPE - holding rezzes until we zone') end)
            rezlog('\\ay[rez] WIPE called - the group will not rez until it zones\\ax')
        end
        if ImGui.IsItemHovered and ImGui.IsItemHovered() then
            pcall(function() ImGui.SetTooltip(
                'Stop the whole group rezzing until it zones.\n' ..
                'For when a fast rez just puts everyone back on the thing that killed them.\n' ..
                'Clears itself the moment this character zones.') end)
        end
    end
end

function draw_chain_modes(names, wide)
    for i, nm in ipairs(names) do
        if wide and i > 1 then ImGui.SameLine() end
        local md = chain_mode(nm)
        if md == 'off' then      ImGui.PushStyleColor(ImGuiCol.Text, 0.90, 0.35, 0.35, 1.0)
        elseif md == 'raid' then ImGui.PushStyleColor(ImGuiCol.Text, 0.74, 0.55, 0.96, 1.0)
        else                     ImGui.PushStyleColor(ImGuiCol.Text, 0.40, 0.82, 0.45, 1.0) end
        if ImGui.SmallButton(nm:sub(1, 9) .. '##skip_' .. (wide and 'w' or 'm') .. nm) then
            local nxt = (md == 'group') and 'off' or ((md == 'off') and 'raid' or 'group')
            chainMode[nm:lower()] = (nxt ~= 'group') and nxt or nil
            save_settings()
            pcall(function() peer_bcast('/at_chainskip %s %s', nm, nxt) end)
            rezlog('[rez] %s: %s', nm, (nxt == 'off') and 'no rezzes'
                                    or (nxt == 'raid') and 'group AND raid' or 'group only')
        end
        ImGui.PopStyleColor(1)
        if ImGui.IsItemHovered and ImGui.IsItemHovered() then
            pcall(function() ImGui.SetTooltip(string.format(
                '%s - %s\n\nclick to cycle:\n  green  group corpses only\n  red    no rezzes at all\n  purple group AND raid corpses',
                nm, (md == 'off') and 'no rezzes'
                 or (md == 'raid') and 'group AND raid' or 'group only')) end)
        end
    end
end

local function draw_rez_mini()
    -- Same shape as the Burns tab: characters across the top, one row per clicky.
    local cols = {}
    for _, nm in ipairs(rezPriority) do
        local rr = rezReady[nm]
        -- divine belongs in this test. Without it, a character whose ONLY rez is the Divine Res AA gets no
        -- column at all - so the row that was added to show it could never show it. It was added to the
        -- chain, the wire and the display row, and missed in the one place that decides who is listed.
        if rr and ((rr.crown or -1) >= 0 or (rr.token or -1) >= 0
                   or (rr.cotw or -1) >= 0 or (rr.divine or -1) >= 0) then cols[#cols + 1] = nm end
    end
    -- The wipe button used to sit here. It is on the section HEADER now, so it stays reachable when the
    -- section is folded - which is exactly when you would still want it. One button, one place.
    if #cols == 0 then ImGui.TextDisabled('rez: no crown/token reports'); return end
    local flags = (ImGuiTableFlags.BordersInnerV or 0) + (ImGuiTableFlags.RowBg or 0)
                + (ImGuiTableFlags.SizingFixedFit or 0)
    if not ImGui.BeginTable('##rezmini', 1 + #cols, flags) then return end
    ImGui.TableSetupColumn('')
    for _, nm in ipairs(cols) do ImGui.TableSetupColumn('') end
    -- Clickable scope buttons, one per character - see draw_chain_modes.
    ImGui.TableNextRow()
    ImGui.TableNextColumn()
    ImGui.TextDisabled('click a name')
    for _, nm in ipairs(cols) do
        ImGui.TableNextColumn()
        draw_chain_modes({ nm }, false)
    end
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
    -- ONE ROW for both spell rezzes. They are the same thing from the display's point of view - a
    -- renewable rez with no consumable behind it - and no character has both, so a row each was two
    -- rows where five of six cells were always blank.
    -- Divine wins where a character somehow has both, matching the chain order.
    if rezDivine or rezCotw then
        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.TextColored(0.85, 0.72, 0.35, 1.0, 'AA Rez')
        for _, nm in ipairs(cols) do
            ImGui.TableNextColumn()
            local rr = rezReady[nm]
            local dv = (rezDivine and rr and rr.divine) or -1
            local cw = (rezCotw   and rr and rr.cotw)   or -1
            local v  = (dv >= 0) and dv or cw
            rez_cell(v, rr and rr.updated)
            if ImGui.IsItemHovered and ImGui.IsItemHovered() and v >= 0 then
                pcall(function() ImGui.SetTooltip(nm .. ': ' ..
                    ((dv >= 0) and 'Divine Resurrection' or 'Call of the Wild')) end)
            end
        end
    end
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
            -- Per-character rez scope, at the top because it is the thing you change mid-session. The
            -- same control as the mini section, same shared renderer.
            draw_wipe_button('tab')
            ImGui.Separator()
            ImGui.Spacing()
            ImGui.TextColored(0.85, 0.72, 0.35, 1.0, 'Who rezzes')
            ImGui.TextDisabled('click a name: green group only, red none, purple group AND raid')
            draw_chain_modes(rezPriority, true)
            ImGui.Separator()
            ImGui.Spacing()
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
               rezDivine = ImGui.Checkbox('Divine Res first', rezDivine)
               if ImGui.IsItemHovered and ImGui.IsItemHovered() then
                   pcall(function() ImGui.SetTooltip(
                       'Cleric Divine Resurrection, ahead of Call of the Wild and the clickies.\n' ..
                       'Renewable, costs nothing, and returns more experience.') end)
               end
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
    local ok2, nm2, why2 = pot_drink(base)
    if not ok2 and why2 then log('[pot] %s', why2)
    elseif not ok2 and nm2 then log('[pot] %s on cooldown', nm2) end
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

-- ===== ALT CURRENCY -> ITEMS =====
-- Diamond Coins live in the inventory window's Alt. Currency tab, not in bags, so FindItemCount will
-- never see them and the give-out cannot distribute them until they are pulled out as items.
-- The control names below were established by driving the window by hand with a probe on 2026-07-29;
-- they are not guesses: IW_AltCurr_PointList holds one row per currency, and Create Item is what turns
-- a balance into a stack on the cursor. Pressing Create opens QuantityWnd defaulted to the maximum.
-- The quantity idiom is LazCraft's accept_qty_window - the DIRECT TLO setter, not /invoke SetText,
-- which took ~400ms to commit there and produced an every-other-round failure.
-- Control names came out of EQUI_Inventory.xml and were all confirmed to resolve in game.
ALTCUR_WND     = 'InventoryWindow'
ALTCUR_LIST_C  = 'IW_AltCurr_PointList'            -- control name ALONE, for /notify
ALTCUR_CREATE_C= 'IW_AltCurr_CreateItemButton'
ALTCUR_LIST    = 'InventoryWindow/IW_AltCurr_PointList'   -- slash-joined, for Window() READS only
-- /notify TAKES THE WINDOW AND THE CONTROL AS SEPARATE ARGUMENTS. Slash-joining them is accepted
-- silently and does nothing - "list select not found" was exactly this, found and fixed on 2026-07-29
-- and reintroduced here by writing the command from memory instead of from that session.
--     right: /notify InventoryWindow IW_AltCurr_PointList listselect 3
--     wrong: /notify InventoryWindow/IW_AltCurr_PointList listselect 3
-- Window() reads are the opposite - they want the slash-joined path. Hence two constants.

-- Which row in the currency list is this currency? Returns nil when the tab is not showing it, which
-- is also what a closed inventory window looks like - the caller says so rather than pressing blindly.
function altcur_row(name)
    local rows = 0
    pcall(function() rows = tonumber(mq.TLO.Window(ALTCUR_LIST).Items()) or 0 end)
    if rows <= 0 then return nil, 0 end
    local want = name:lower()
    for i = 1, rows do
        for col = 1, 6 do
            local txt = ''
            pcall(function() txt = tostring(mq.TLO.Window(ALTCUR_LIST).List(i, col)() or '') end)
            -- CONTAINS, not equals - matching altcur_balance. These two had drifted: the balance reader
            -- used find() and this used ==, so a cell carrying any padding or a suffix read fine in the
            -- display and returned "no such row" to the pull. /attab exited silently on exactly that.
            if txt ~= '' and txt:lower():find(want, 1, true) then return i, rows end
        end
    end
    return nil, rows
end

-- Pull `qty` of a currency out as items. Returns how many actually landed.
-- The tab index for Alt. Currency inside the inventory window. A guess that is easy to correct rather
-- than a value dug out of the XML: the pull below VERIFIES by checking the Create button became enabled,
-- and says so when it did not, so a wrong number here is one obvious log line and a one-digit fix.
ALTCUR_TAB = 4

-- FIND THE TAB RATHER THAN GUESS IT. Index 4 turned out to be Shrouds, and the next guess would have
-- been another coin flip. The test is exact and needs no XML: select a currency row, then ask whether
-- Create Item became ENABLED - it only does when the row is on the page that is actually showing.
-- Caches the answer, so this runs once and every later pull goes straight there.
function altcur_find_tab(name)
    if altcurTabFound then
        log('[altcur] already know the tab: %d', altcurTabFound)
        return altcurTabFound
    end
    altcur_show_tab()   -- altcur_row() below cannot read the list until the tab is up
    local row, rows = altcur_row(name)
    if not row then
        -- Say WHY. This returned nil in silence, which from the outside is indistinguishable from the
        -- command not being registered at all - and that is exactly how it looked.
        log('\\ay[altcur] cannot find "%s" in the currency list (%d row(s) read) - run /atcurrency to see '
            .. 'what is actually there\\ax', name, rows or 0)
        return nil
    end
    log('[altcur] %s is row %d of %d - trying tabs 1-10...', name, row, rows or 0)
    for t = 1, 10 do
        pcall(function() mq.cmdf('/notify %s IW_Subwindows tabselect %d', ALTCUR_WND, t) end)
        mq.delay(250)
        pcall(function() mq.cmdf('/notify %s %s listselect %d', ALTCUR_WND, ALTCUR_LIST_C, row) end)
        mq.delay(250)
        local ok = false
        pcall(function() ok = (mq.TLO.Window(ALTCUR_WND .. '/' .. ALTCUR_CREATE_C).Enabled() == true) end)
        if ok then
            altcurTabFound = t
            ALTCUR_TAB = t
            log('\\ag[altcur] Alt. Currency is tab %d\\ax', t)
            return t
        end
    end
    log('\\ay[altcur] no tab index 1-10 enabled Create Item - the tab control may not be IW_Subwindows\\ax')
    return nil
end

-- The reverse of a pull, and far simpler than one: select the currency row, press Reclaim, and the
-- game converts EVERY stack of that item in bags back into currency in a single action.
-- Nothing is picked up and there is no quantity - which is why this takes no qty argument. The first
-- version looped, picked each stack onto the cursor and pressed Reclaim per stack; that was modelled on
-- the pull, and the pull needs a loop only because Create hands back one stack at a time. Reclaim does
-- not work that way.
ALTCUR_RECLAIM_C = 'IW_AltCurr_ReclaimButton'
function altcur_reclaim(name)
    if (mq.TLO.Cursor.ID() or 0) ~= 0 then
        log('\\ay[altcur] something is on the cursor - clear it before reclaiming\\ax'); return 0
    end
    local before = 0
    pcall(function() before = tonumber(mq.TLO.FindItemCount('=' .. name)()) or 0 end)
    if before <= 0 then log('\\ay[altcur] no %s in bags to reclaim\\ax', name); return 0 end

    local wasOpen = false
    pcall(function() wasOpen = (mq.TLO.Window(ALTCUR_WND).Open() == true) end)
    if not wasOpen then
        pcall(function() mq.TLO.Window(ALTCUR_WND).DoOpen() end)
        mq.delay(600, function() return mq.TLO.Window(ALTCUR_WND).Open() == true end)
    end
    if not mq.TLO.Window(ALTCUR_WND).Open() then
        log('\\ay[altcur] could not open the inventory\\ax'); return 0
    end
    pcall(function() mq.cmdf('/notify %s IW_Subwindows tabselect %d', ALTCUR_WND, ALTCUR_TAB) end)
    mq.delay(400)
    if not altcurTabFound then altcur_find_tab(name) end

    local row, rows = altcur_row(name)
    if not row then
        log('\\ay[altcur] %s is not in the currency list (%d rows) - cannot reclaim\\ax', name, rows or 0)
        if not wasOpen then pcall(function() mq.TLO.Window(ALTCUR_WND).DoClose() end) end
        return 0
    end
    pcall(function() mq.cmdf('/notify %s %s listselect %d', ALTCUR_WND, ALTCUR_LIST_C, row) end)
    mq.delay(400)

    pcall(function() mq.cmdf('/notify %s %s leftmouseup', ALTCUR_WND, ALTCUR_RECLAIM_C) end)
    -- One action, so wait on the COUNT dropping rather than on a cursor that never fills.
    mq.delay(4000, function()
        return (tonumber(mq.TLO.FindItemCount('=' .. name)()) or 0) < before
    end)
    mq.delay(400)

    if not wasOpen then pcall(function() mq.TLO.Window(ALTCUR_WND).DoClose() end) end
    local left = 0
    pcall(function() left = tonumber(mq.TLO.FindItemCount('=' .. name)()) or 0 end)
    local gone = before - left
    altcur_announce(name)
    if gone > 0 then
        log('\\ag[altcur] reclaimed %d %s back into currency%s\\ax', gone, name,
            (left > 0) and string.format(' (%d still in bags)', left) or '')
    else
        log('\\ay[altcur] Reclaim took nothing - %s still reads %d in bags\\ax', name, left)
    end
    return gone
end

altcurStuck = false
function altcur_pull(name, qty)
    qty = math.max(1, math.floor(tonumber(qty) or 1))
    -- Do not start a new pull with the last one still on the cursor.
    if (mq.TLO.Cursor.ID() or 0) ~= 0 then
        log('\\ay[altcur] something is already on the cursor - clear it before converting more\\ax')
        return 0
    end

    -- OPEN THE WINDOW AND SHOW THE TAB. Reading the list works with the window shut, which is why the
    -- balances display fine - but pressing a button on a hidden page does not, so the pull needs the
    -- window up and the Alt. Currency page showing where the reads did not.
    -- Whatever we open here is closed again at the end unless it was already open.
    local wasOpen = false
    pcall(function() wasOpen = (mq.TLO.Window(ALTCUR_WND).Open() == true) end)
    if not wasOpen then
        pcall(function() mq.TLO.Window(ALTCUR_WND).DoOpen() end)
        mq.delay(600, function() return mq.TLO.Window(ALTCUR_WND).Open() == true end)
    end
    if not mq.TLO.Window(ALTCUR_WND).Open() then
        log('\\ay[altcur] could not open the inventory window\\ax')
        return 0
    end
    -- Try the known-good tab first; if it has never been established, go and find it.
    pcall(function() mq.cmdf('/notify %s IW_Subwindows tabselect %d', ALTCUR_WND, ALTCUR_TAB) end)
    mq.delay(400)
    if not altcurTabFound then altcur_find_tab(name) end

    local row, rows = altcur_row(name)
    if not row then
        log('\\ay[altcur] %s is not in the currency list (%d row(s) visible) - is the Alt. Currency tab showing?\\ax',
            name, rows)
        return 0
    end

    local before = 0
    pcall(function() before = tonumber(mq.TLO.FindItemCount('=' .. name)()) or 0 end)

    -- ONE PRESS GIVES ONE STACK. Create Item converts up to a single stack per press, so asking for 1879
    -- and pressing once returns 200 and stops - which is exactly what happened. Everything below the
    -- select is therefore a LOOP: press, take the stack, stow it, press again, until we have what was
    -- asked for or something says stop.
    -- Bounded so a misread balance cannot spin forever. 40 was short of a real conversion - 10,234 coins
    -- at 200 a stack is 52 rounds, so it stopped at 8,000 and wanted a second press. Rounds are ~1s and
    -- every one of them logs, so a high ceiling costs nothing when it is not needed.
    local rounds = 0
    while rounds < 120 do
        rounds = rounds + 1
        local have = 0
        pcall(function() have = tonumber(mq.TLO.FindItemCount('=' .. name)()) or 0 end)
        local stillWant = qty - (have - before)
        if stillWant <= 0 then break end

    pcall(function() mq.cmdf('/notify %s %s listselect %d', ALTCUR_WND, ALTCUR_LIST_C, row) end)
    mq.delay(400)
    -- The Create button only enables once a row on the VISIBLE page is selected, so this doubles as the
    -- check that the tab is actually showing - which is the thing ALTCUR_TAB is guessing at.
    local canCreate = false
    pcall(function() canCreate = (mq.TLO.Window(ALTCUR_WND .. '/' .. ALTCUR_CREATE_C).Enabled() == true) end)
    if not canCreate then
        log('\\ay[altcur] Create Item is not enabled after selecting %s - the Alt. Currency tab is probably '
            .. 'not showing (ALTCUR_TAB is %d; try another index)\\ax', name, ALTCUR_TAB)
    end
    pcall(function() mq.cmdf('/notify %s %s leftmouseup', ALTCUR_WND, ALTCUR_CREATE_C) end)
    mq.delay(1200, function() local o = false
        pcall(function() o = mq.TLO.Window('QuantityWnd').Open() == true end); return o end)

    if mq.TLO.Window('QuantityWnd').Open() then
        -- QUANTITY, THE WAY LAZCRAFT DOES IT. This used to set the field once, wait 500ms, and press
        -- Accept regardless - so when the field had not taken, it accepted whatever the dialog was
        -- defaulted to. That is the intermittent behaviour: most rounds fine, the occasional one wrong.
        -- LazCraft's hand-off loop is the hardened version and it does three things this did not:
        --   * RE-ISSUES the SetText every ~320ms until the field actually reads the number back
        --   * polls at 40ms, so it commits as soon as it takes rather than waiting out a fixed delay
        --   * on failure presses ESC, never the Cancel button - Cancel PULLS THE STACK, which is how a
        --     "cancelled" round would still leave coins on the cursor
        -- ASK FOR WHAT THE DIALOG CAN ACTUALLY GIVE. It opens defaulted to the maximum it will allow -
        -- one stack - and CLAMPS anything larger. Asking for 10234 therefore leaves the field reading
        -- 200, and a verify loop that insists on seeing 10234 backs out of a round that was working
        -- perfectly. The previous build got away with it only because it accepted without checking.
        -- The default IS the cap, so read it rather than hardcoding a stack size that varies by item.
        local capTxt = ''
        pcall(function() capTxt = tostring(mq.TLO.Window('QuantityWnd/QTYW_SliderInput').Text() or '') end)
        local cap = tonumber((capTxt:gsub('[^%d]', ''))) or 0
        local askFor = (cap > 0) and math.min(stillWant, cap) or stillWant
        local wantS, set = tostring(askFor), false
        pcall(function() mq.cmdf('/invoke ${Window[QuantityWnd/QTYW_SliderInput].SetText[%d]}', askFor) end)
        local qDeadline, ticks = mq.gettime() + 1200, 0
        repeat
            if (mq.TLO.Window('QuantityWnd/QTYW_SliderInput').Text() or '') == wantS then set = true; break end
            mq.delay(40); ticks = ticks + 1
            if ticks % 8 == 0 then
                pcall(function() mq.cmdf('/invoke ${Window[QuantityWnd/QTYW_SliderInput].SetText[%d]}', askFor) end)
            end
        until mq.gettime() > qDeadline

        if not set then
            log('\\ay[altcur] could not set the quantity to %d (cap %d, reads %s) - backing out of this round\\ax',
                askFor, cap, tostring(mq.TLO.Window('QuantityWnd/QTYW_SliderInput').Text()))
            mq.cmd('/keypress esc')   -- NOT Cancel: Cancel pulls the stack onto the cursor
            mq.delay(400, function() return not mq.TLO.Window('QuantityWnd').Open() end)
            break
        end
        mq.cmd('/notify QuantityWnd QTYW_Accept_Button leftmouseup')
        mq.delay(1500, function() return not mq.TLO.Window('QuantityWnd').Open() end)
        if mq.TLO.Window('QuantityWnd').Open() then
            log('\\ay[altcur] the quantity window did not close - backing out\\ax')
            mq.cmd('/keypress esc')
            mq.delay(400, function() return not mq.TLO.Window('QuantityWnd').Open() end)
            break
        end
    end

    -- STOW IT, AND STOP IF IT WILL NOT GO. A full inventory means the pulled stack sits on the cursor,
    -- and the next thing that touches the cursor - a trade, a click, anything - either loses it or
    -- refuses to work. Converting more on top of that would be strictly worse.
    -- Checked properly rather than assumed: clear_cursor tries, then we look.
    -- WAIT FOR THE COINS TO ACTUALLY REACH THE CURSOR BEFORE STOWING THEM. /autoinventory is exactly
    -- right for this - it drops into the first free bag slot, which is all a stack of coins needs - but
    -- it does nothing at all if the cursor is still empty when it fires.
    -- That was the bug: a 600ms wait, then stow regardless. The coins arrived a moment later, found an
    -- empty-handed /autoinventory had already been and gone, and sat there - so the check right after
    -- saw a full cursor and called it "bags are full" on a character with plenty of room.
    -- So: wait for the item BY NAME, up to 3s, and only then stow.
    local landedOnCursor = false
    local deadline = mq.gettime() + 3000
    while mq.gettime() < deadline do
        local cn = ''
        pcall(function() cn = tostring(mq.TLO.Cursor.Name() or '') end)
        if cn ~= '' and cn:lower():find(name:lower(), 1, true) then landedOnCursor = true; break end
        mq.delay(50)
    end
    if not landedOnCursor then
        -- Nothing came. Could be an exhausted balance or a refused Create; either way there is nothing
        -- to stow and nothing to call stuck.
        local cn = ''
        pcall(function() cn = tostring(mq.TLO.Cursor.Name() or '') end)
        if cn ~= '' then
            log('\\ay[altcur] something else is on the cursor (%s) - stopping\\ax', cn)
            altcurStuck = true
            if not wasOpen then pcall(function() mq.TLO.Window(ALTCUR_WND).DoClose() end) end
            local sofar = 0
            pcall(function() sofar = tonumber(mq.TLO.FindItemCount('=' .. name)()) or 0 end)
            return math.max(0, sofar - before)
        end
        break   -- no coins appeared: end the loop, the round-yield check below reports it
    end

    local held = ''
    pcall(function() held = tostring(mq.TLO.Cursor.Name() or '') end)
    -- RETRY THE STOW. On 2026-08-02 fifteen rounds stowed cleanly at ~1.1s each and the sixteenth did
    -- not, on a character with plenty of free bags - so a single /autoinventory that does not take is
    -- not evidence of anything except that it did not take. Three attempts with a wait between.
    -- A BEAT BEFORE STOWING, AND A SHORTER WAIT AFTER. The log shows the shape exactly: the first
    -- /autoinventory missed on 25 of 52 rounds, and the second - about 400ms later - worked every time.
    -- That is not a full bag, it is firing the instant the coins appear, before the client is ready to
    -- move them. So: settle first, which should stop most of the misses happening at all.
    -- And when one does miss, 1500ms is far too long to find out. A stow that works, works quickly; the
    -- long wait only ever delayed the retry that was going to fix it. Four short attempts instead of
    -- three long ones is both faster on failure and more forgiving.
    mq.delay(150)
    for attempt = 1, 4 do
        mq.cmd('/autoinventory')
        mq.delay(700, function() return (mq.TLO.Cursor.ID() or 0) == 0 end)
        if (mq.TLO.Cursor.ID() or 0) == 0 then break end
        if attempt < 4 then
            log('[altcur]   stow did not take - retry %d of 4', attempt + 1)
            mq.delay(250)
        end
    end
    if (mq.TLO.Cursor.ID() or 0) ~= 0 then
        -- COUNT THE FREE SLOTS rather than claim the bags are full. They were not, the last time this
        -- said so, and a message that asserts the wrong cause sends the next hour in the wrong direction.
        -- Counted through bag_usable, so a tradeskill bag's empty slots are not reported as room. Saying
        -- "47 free slots" about slots that cannot take the item is worse than saying nothing.
        local free = 0
        for b = 1, 10 do
            local usable, slots = bag_usable(b)
            if usable then
                for sl = 1, slots do
                    local occupied = true
                    pcall(function()
                        occupied = (tonumber(mq.TLO.Me.Inventory('pack' .. b).Item(sl).ID()) or 0) > 0
                    end)
                    if not occupied then free = free + 1 end
                end
            end
        end
        log('\\ar[altcur] %s will not leave the cursor after 3 tries (%d free bag slot(s)). STOPPING.\\ax',
            (held ~= '') and held or name, free)
        if free > 0 then
            log('\\ar[altcur] there IS room, so this is not a full-bags problem - the stow is being refused.\\ax')
        end
        -- PUT IT BACK rather than leave it dangling. Reclaim is the reverse of Create - it pushes a
        -- stack from the cursor back into the currency tab - and a stack left on the cursor blocks
        -- every later trade, click and pickup on that character until a person notices. Better to
        -- return it and stop cleanly than to stop holding something.
        pcall(function() mq.cmdf('/notify %s IW_AltCurr_ReclaimButton leftmouseup', ALTCUR_WND) end)
        mq.delay(1200, function() return (mq.TLO.Cursor.ID() or 0) == 0 end)
        if (mq.TLO.Cursor.ID() or 0) == 0 then
            log('[altcur] put the stuck stack back into currency - cursor is clear')
        else
            log('\\ar[altcur] could not reclaim it either - %s is still on the cursor, clear it by hand\\ax',
                (held ~= '') and held or name)
        end
        altcurStuck = true
        if not wasOpen then pcall(function() mq.TLO.Window(ALTCUR_WND).DoClose() end) end
        -- Report what DID land, not zero. Earlier rounds may have stowed several stacks fine, and
        -- claiming nothing happened would send the caller looking for a problem it does not have.
        local sofar = 0
        pcall(function() sofar = tonumber(mq.TLO.FindItemCount('=' .. name)()) or 0 end)
        local landed = math.max(0, sofar - before)
        if landed > 0 then log('[altcur] %d %s did land before the bags filled', landed, name) end
        return landed
    end
    altcurStuck = false

        -- A round that produced nothing means the currency is exhausted, or Create refused. Either way
        -- pressing again will not help.
        local now = 0
        pcall(function() now = tonumber(mq.TLO.FindItemCount('=' .. name)()) or 0 end)
        if now <= have then
            if rounds == 1 then log('\\ay[altcur] the first press produced nothing\\ax')
            else log('[altcur] nothing more to convert after %d round(s)', rounds) end
            break
        end
        log('[altcur]   round %d: +%d (%d of %d)', rounds, now - have, now - before, qty)
    end

    local after = 0
    pcall(function() after = tonumber(mq.TLO.FindItemCount('=' .. name)()) or 0 end)
    if not wasOpen then pcall(function() mq.TLO.Window(ALTCUR_WND).DoClose() end) end

    local got = after - before
    altcur_announce(name)
    if got > 0 then log('\\ag[altcur] pulled %d %s (now %d in bags)\\ax', got, name, after)
    else          log('\\ay[altcur] pulled nothing - %s still reads %d in bags\\ax', name, after) end
    return got
end

-- ===== TRIBUTE =====
-- Walk to a tribute master and donate a set number of Diamond Coins. Nothing else - it never touches
-- anything not named here, because a routine that donates "what it finds" next to a bank of consumables
-- is one mis-set filter away from feeding somebody's draughts to a favour counter.
--
-- WHAT IS KNOWN vs GUESSED, stated plainly because it decides where to look when it misbehaves:
--   known   - the nav, the spawn search, and the donate quantity flow (same QuantityWnd loop the
--             currency pull uses, which is now proven)
--   guessed - the NPC name pattern and the window control names. Both are printed by /attribprobe, so
--             one run replaces the guesses with facts rather than another round of me inventing them.
TRIB_NPC_HINTS = { 'Tribute Master', 'tribute' }
TRIB_WND       = 'TributeMasterWnd'
TRIB_DONATE_C  = 'TMW_DonateButton'

-- Nearest NPC whose name looks like a tribute master. Returns id, name, distance.
function trib_find_npc()
    for _, hint in ipairs(TRIB_NPC_HINTS) do
        local id, nm, d = 0, '', -1
        pcall(function() id = tonumber(mq.TLO.Spawn('npc ' .. hint).ID()) or 0 end)
        if id > 0 then
            pcall(function() nm = tostring(mq.TLO.Spawn(id).CleanName() or '') end)
            pcall(function() d  = math.floor(tonumber(mq.TLO.Spawn(id).Distance()) or -1) end)
            return id, nm, d
        end
    end
    return nil
end

-- Dump whatever the tribute window exposes, so the donate step can be written against real controls.
function trib_probe()
    log('[tribute] window %s open: %s', TRIB_WND, tostring(mq.TLO.Window(TRIB_WND).Open()))
    -- Wider net, and the cursor state reported alongside - because "Donate is disabled" means nothing
    -- on its own. The first probe ran with an empty cursor, which is exactly when it SHOULD be disabled,
    -- so it told us the button exists and nothing about whether holding a coin is enough.
    local cur = ''
    pcall(function() cur = tostring(mq.TLO.Cursor.Name() or '') end)
    log('   cursor holds: %s', (cur ~= '') and cur or '(empty)')
    for _, c in ipairs({ TRIB_DONATE_C, 'TMW_DonateButton', 'TMW_TributeList', 'TMW_ItemList',
                         'TMW_CurrentTribute', 'TMW_Value', 'TMW_ActivateButton',
                         'TMW_TributeSlot', 'TMW_ItemSlot', 'TMW_Slot1', 'TMW_TributePool',
                         'TMW_MyTribute', 'TMW_TributeValue', 'TMW_PointsLabel', 'TMW_Tier',
                         'TMW_Benefit', 'TMW_ItemWnd', 'TMW_DonateItemSlot' }) do
        local exists, txt, en = 'no', '', 'n/a'
        pcall(function()
            if mq.TLO.Window(TRIB_WND .. '/' .. c)() ~= nil then exists = 'yes' end
        end)
        pcall(function() txt = tostring(mq.TLO.Window(TRIB_WND .. '/' .. c).Text() or '') end)
        pcall(function() en = tostring(mq.TLO.Window(TRIB_WND .. '/' .. c).Enabled()) end)
        log('   %-22s exists=%-3s enabled=%-5s text="%s"', c, exists, en, txt)
    end
    local id, nm, d = trib_find_npc()
    log('   nearest tribute NPC: %s', id and string.format('%s (%dm)', nm, d) or 'none found')
    log('   NOTE: run this again holding a %s on the cursor. If Donate becomes enabled, pressing it is '
        .. 'all that is needed; if it stays disabled, the item has to go into a slot first and one of '
        .. 'the slot names above will have appeared.', 'Diamond Coin')
end

-- Walk there and open it. Split out so the donate can assume it is standing in front of one.
function trib_reach()
    local id, nm, d = trib_find_npc()
    if not id then
        log('\\ay[tribute] no tribute master in this zone (looked for: %s)\\ax',
            table.concat(TRIB_NPC_HINTS, ', '))
        return nil
    end
    log('[tribute] %s is %dm away - heading over', nm, d)
    pcall(function() mq.cmdf('/nav id %d distance=15', id) end)
    mq.delay(1000)
    local deadline = mq.gettime() + 30000
    while mq.gettime() < deadline do
        local nav = false
        pcall(function() nav = (tostring(mq.TLO.Navigation.Active()) == 'TRUE') end)
        if not nav then break end
        mq.delay(200)
    end
    pcall(function() mq.cmdf('/target id %d', id) end)
    mq.delay(600, function() return (tonumber(mq.TLO.Target.ID()) or 0) == id end)
    -- Right-clicking the NPC is what opens the tribute window, the same way a merchant opens.
    pcall(function() mq.cmd('/click right target') end)
    mq.delay(2500, function() local o = false
        pcall(function() o = mq.TLO.Window(TRIB_WND).Open() == true end); return o end)
    if not mq.TLO.Window(TRIB_WND).Open() then
        log('\\ay[tribute] %s did not open a %s - run /attribprobe here to see what did open\\ax',
            nm, TRIB_WND)
        return nil
    end
    return id, nm
end

-- Donate `qty` of one named item. Deliberately takes the name: this never scans inventory for
-- "things worth donating", so nothing can be fed to the favour counter by accident.
--
-- IT WORKS LIKE SELLING, not like moving an item. With the tribute window open, left-clicking a stack
-- in a bag SELECTS it - it does not go to the cursor - and Donate then acts on the selection. The first
-- version picked the item up first, which is why the probe kept showing a disabled Donate and an item
-- stuck in hand: the button was never going to act on something the window did not consider selected.
-- Close what we opened: the tribute window and the bags. Safe to call more than once.
function trib_cleanup()
    if tribBagsOpen then
        tribBagsOpen = false
        toggle_all_bags()
    end
    if mq.TLO.Window(TRIB_WND).Open() then
        pcall(function() mq.TLO.Window(TRIB_WND).DoClose() end)
        mq.delay(500, function() return not mq.TLO.Window(TRIB_WND).Open() end)
        if mq.TLO.Window(TRIB_WND).Open() then
            -- Some vendor-style windows ignore DoClose; escape closes them.
            mq.cmd('/keypress esc')
            mq.delay(400, function() return not mq.TLO.Window(TRIB_WND).Open() end)
        end
    end
    clear_cursor()
end

function trib_donate(item, qty)
    qty = math.max(1, math.floor(tonumber(qty) or 1))
    local have = 0
    pcall(function() have = tonumber(mq.TLO.FindItemCount('=' .. item)()) or 0 end)
    if have <= 0 then log('\\ay[tribute] no %s in bags\\ax', item); return 0 end
    qty = math.min(qty, have)

    if not mq.TLO.Window(TRIB_WND).Open() then
        if not trib_reach() then return 0 end
    end
    -- Bags open once up front so a slot click lands on the item rather than the bag.
    toggle_all_bags()
    tribBagsOpen = true

    local before = have
    local rounds = 0
    while rounds < 120 do
        rounds = rounds + 1
        local now = 0
        pcall(function() now = tonumber(mq.TLO.FindItemCount('=' .. item)()) or 0 end)
        local done = before - now
        if done >= qty then break end

        local bag, sl = nil, nil
        for b2 = 1, 10 do
            local slots = 0
            pcall(function() slots = tonumber(mq.TLO.Me.Inventory('pack' .. b2).Container()) or 0 end)
            for i = 1, slots do
                local nm = ''
                pcall(function() nm = tostring(mq.TLO.Me.Inventory('pack' .. b2).Item(i).Name() or '') end)
                if nm:lower() == item:lower() then bag, sl = b2, i; break end
            end
            if bag then break end
        end
        if not bag then log('[tribute] no more %s in bags after %d', item, done); break end

        -- SELECT it. Nothing should reach the cursor; if something does, the window is not treating
        -- this as a selection and pressing Donate would be the wrong move.
        -- RE-READ THE SLOT IMMEDIATELY BEFORE CLICKING IT, and refuse if it is not what we scanned.
        -- The scan above walks the bags, but a donate a moment earlier may not have landed in the
        -- client's inventory yet - so the scan can return a slot that USED to hold coins. Clicking it
        -- then selects whatever is there now, and Donate spends it. That is how a tribute run ate items
        -- it was never asked to touch.
        -- One extra read per round, and it is the difference between donating coins and donating
        -- somebody's draughts.
        local confirm = ''
        pcall(function() confirm = tostring(mq.TLO.Me.Inventory('pack' .. bag).Item(sl).Name() or '') end)
        if confirm:lower() ~= item:lower() then
            log('\\ar[tribute] pack%d slot %d now holds "%s", not %s - NOT clicking it. Stopping.\\ax',
                bag, sl, (confirm ~= '') and confirm or 'nothing', item)
            break
        end
        mq.cmdf('/itemnotify in pack%d %d leftmouseup', bag, sl)
        -- WAIT FOR DONATE TO ENABLE, do not sleep a fixed 500ms and then test. Coins stack to 200, so a
        -- request for 400 is two stacks and 453 is three - and the second selection is where a flat wait
        -- bites: if the button had not re-enabled yet the loop called it a refusal and stopped after one
        -- stack. Same mistake as the currency stow: a delay standing in for knowing.
        local can = false
        local dl = mq.gettime() + 2000
        while mq.gettime() < dl do
            pcall(function() can = (mq.TLO.Window(TRIB_WND .. '/' .. TRIB_DONATE_C).Enabled() == true) end)
            if can or (mq.TLO.Cursor.ID() or 0) ~= 0 then break end
            mq.delay(50)
        end
        if (mq.TLO.Cursor.ID() or 0) ~= 0 then
            log('\\ay[tribute] the click picked %s up instead of selecting it - putting it back and '
                .. 'stopping\\ax', item)
            clear_cursor()
            break   -- falls through to trib_cleanup below
        end

        if not can then
            log('\\ay[tribute] Donate did not enable within 2s of selecting %s (stack %d) - stopping\\ax',
                item, rounds)
            break
        end

        mq.cmdf('/notify %s %s leftmouseup', TRIB_WND, TRIB_DONATE_C)
        -- A quantity dialog may follow; if it does, drive it with the loop that is proven elsewhere.
        mq.delay(800, function()
            local o = false
            pcall(function() o = mq.TLO.Window('QuantityWnd').Open() == true end)
            return o
                or (tonumber(mq.TLO.FindItemCount('=' .. item)()) or 0) < now
        end)
        if mq.TLO.Window('QuantityWnd').Open() then
            local capTxt = ''
            pcall(function() capTxt = tostring(mq.TLO.Window('QuantityWnd/QTYW_SliderInput').Text() or '') end)
            local cap = tonumber((capTxt:gsub('[^%d]', ''))) or 0
            local ask = (cap > 0) and math.min(qty - done, cap) or (qty - done)
            local wantS, set = tostring(ask), false
            pcall(function() mq.cmdf('/invoke ${Window[QuantityWnd/QTYW_SliderInput].SetText[%d]}', ask) end)
            local dl, ticks = mq.gettime() + 1200, 0
            repeat
                if (mq.TLO.Window('QuantityWnd/QTYW_SliderInput').Text() or '') == wantS then set = true; break end
                mq.delay(40); ticks = ticks + 1
                if ticks % 8 == 0 then
                    pcall(function() mq.cmdf('/invoke ${Window[QuantityWnd/QTYW_SliderInput].SetText[%d]}', ask) end)
                end
            until mq.gettime() > dl
            if not set then
                log('\\ay[tribute] could not set the quantity - stopping\\ax')
                mq.cmd('/keypress esc'); break        -- ESC, never Cancel
            end
            mq.cmd('/notify QuantityWnd QTYW_Accept_Button leftmouseup')
            mq.delay(1200, function() return not mq.TLO.Window('QuantityWnd').Open() end)
        end

        -- WAIT FOR THE COUNT TO ACTUALLY DROP before scanning again. Reading it immediately is what let
        -- the next round see stale bags. If it never drops, something other than our item was spent -
        -- stop at once and say so loudly rather than going round again.
        local after = now
        local settle = mq.gettime() + 2500
        while mq.gettime() < settle do
            pcall(function() after = tonumber(mq.TLO.FindItemCount('=' .. item)()) or 0 end)
            if after < now then break end
            mq.delay(100)
        end
        if after >= now then
            log('\\ar[tribute] pressed Donate but %s did not go down. Something else may have been '
                .. 'donated. STOPPING immediately.\\ax', item)
            break
        end
        mq.delay(400)   -- let the bags finish reshuffling before the next scan reads them
        log('[tribute]   stack %d: donated %d (%d of %d)', rounds, now - after, before - after, qty)
    end

    -- TIDY UP. Leaving a tribute window open on a background toon blocks the next thing that wants a
    -- window there, and leaving ten bags open is the same nuisance the currency pull already avoids.
    -- Both are closed on EVERY exit above too, because the interesting paths are the ones that stop
    -- early - a refused donate should not leave the character sitting in front of an open vendor.
    trib_cleanup()
    local left = 0
    pcall(function() left = tonumber(mq.TLO.FindItemCount('=' .. item)()) or 0 end)
    local gave = before - left
    local favor = 0
    pcall(function() favor = tonumber(mq.TLO.Me.CurrentFavor()) or 0 end)
    pcall(function() altcur_announce(item) end)
    log('\\ag[tribute] donated %d %s - favor now %d\\ax', gave, item, favor)
    return gave
end

-- Give out ONE item, end to end, touching nothing else. Diamond Coin's own button runs this.
-- Separate from give_out on purpose: that plans across every item, every character and a vendor buy
-- list, and none of that applies here. This reads one item's counts, converts from currency if the
-- group is short, and hands the surplus round. Six queries instead of ninety.
function give_out_one(item, currency)
    if distributing then log('[dc] busy - already distributing'); return end
    distributing = true
    local ok, err = pcall(function()
        local roster = group_members()
        if #roster <= 1 then log('\\ay[dc] no group members found\\ax'); return end
        local peers = {}
        for _, m in ipairs(roster) do if m:lower() ~= myName:lower() then peers[#peers + 1] = m end end

        -- READS EVERYTHING, same as any other refresh. Reading just this one item saved ~96 queries
        -- and about a second, at the cost of a second refresh path that could drift from the first -
        -- and a stale grid everywhere else the moment you pressed it. Not a good trade for a second.
        uiStatus = 'Reading counts...'
        query_all_counts(peers, all_items())
        if currency then query_alt_currency(roster, currency) end

        local function held(w) return (counts[w:lower()] and counts[w:lower()][item]) or 0 end
        local tgt = target[item] or 0
        if tgt <= 0 then log('\\ay[dc] set a target quantity for %s first\\ax', item); return end

        -- Convert from currency only if the group is actually short, and only the shortfall.
        local need, have = tgt * #roster, 0
        for _, m in ipairs(roster) do have = have + held(m) end
        if currency and have < need then
            local short = need - have
            local who, most = alt_richest(currency)
            if who and most > 0 then
                local pull = math.min(short, most)
                log('[dc] short %d - %s converting %d from currency', short, who, pull)
                uiStatus = string.format('%s converting %d...', who, pull)
                if who:lower() == myName:lower() then
                    altcur_pull(currency, pull)
                else
                    pcall(function() peer_cmdf(who, '/atpull %s %d', currency:gsub(' ', '_'), pull) end)
                    local deadline = mq.gettime() + math.min(180000, 6000 + math.ceil(pull / 200) * 2500)
                    local want = held(who) + pull
                    while mq.gettime() < deadline do
                        mq.doevents(); mq.delay(500)
                        local n = 0
                        pcall(function()
                            n = tonumber(mq.TLO.DanNet(who).Q('FindItemCount[=' .. item .. ']')()) or 0
                        end)
                        if n >= want then break end
                    end
                end
                query_all_counts(peers, all_items())
            else
                log('[dc] nothing in currency either')
            end
        end

        -- Hand it round: richest tops up whoever is short, exactly as give_out does for one item.
        local richest, richestN = roster[1], -1
        for _, m in ipairs(roster) do if held(m) > richestN then richest, richestN = m, held(m) end end
        local surplus = math.max(0, richestN - tgt)
        local moved, short = 0, {}
        for _, m in ipairs(roster) do
            if m:lower() ~= richest:lower() then
                local gap = tgt - held(m)
                if gap > 0 then
                    local give = math.min(gap, surplus)
                    if give > 0 then
                        uiStatus = string.format('%s -> %s: %d %s', richest, m, give, item)
                        -- do_give_bundle is what give_out uses: it handles the local case, the remote
                        -- /at_give_multi handoff and the wait-for-done. Writing a second path here is
                        -- how the two drift - I had already invented an /at_giveto that does not exist.
                        do_give_bundle(richest, m, { [item] = give })
                        surplus = surplus - give; moved = moved + give
                    end
                    if gap - give > 0 then short[#short + 1] = string.format('%s short %d', m, gap - give) end
                end
            end
        end
        if moved > 0 then log('\\ag[dc] moved %d %s\\ax', moved, item) end
        if #short > 0 then log('\\ay[dc] still short: %s\\ax', table.concat(short, ', ')) end
        uiStatus = string.format('%s: moved %d%s', item, moved,
                                 (#short > 0) and (', ' .. #short .. ' short') or '')
        altCurRefresh = mq.gettime() + 2000
    end)
    distributing = false
    if not ok then log('\\ar[dc] %s\\ax', tostring(err)) end
end

-- ===== ENCHANTER PLACATE =====
-- The caster-group counterpart to the phantom queue: click mobs, the enchanter works down the list.
--
-- ENCHANTERS ONLY, and by CLASS rather than by owning the spell. Several classes get a placate line,
-- but only the enchanter has the problem below - gating on the spell would rope in a cleric or a druid
-- who has one and does not need any of this.
--
-- WHY IT UNEQUIPS. An enchanter's weapon augments can proc while CASTING, and a proc on a mob you are
-- trying to placate undoes the placate. So the primary, secondary and range slots come off before the
-- first cast and go back on when the queue is finished.
-- ONCE AROUND THE WHOLE QUEUE, not once per mob: stripping and re-equipping between every cast is three
-- item swaps per mob for no benefit, and each swap is another chance to leave something on the cursor.
--
-- The save/restore is LazCraft's remember_slot / restore_saved_slots, which handles the awkward cases
-- already - a slot that was legitimately empty, an item that will not seat, something stranded on the
-- cursor. Copied rather than reinvented.
-- MQ's INVENTORY SLOT NAMES, which are not the ones the game UI shows. It is mainhand/offhand/ranged,
-- not primary/secondary/range - and Me.Inventory['primary'] does not error, it just resolves to nothing.
-- So the strip read an empty name for every slot, decided there was nothing to take off, and recorded
-- all three as "was empty" - which then made the restore a no-op as well. Silent both ways.
-- LazCraft uses 'mainhand' and 'ammo' in its trophy swap; same naming.
EP_SLOTS = { 'mainhand', 'offhand', 'ranged' }
EP_STRIP_MAX = 180000    -- backstop: never stay stripped longer than this, whatever the queue is doing
epGem      = 8           -- legacy single-gem setting; superseded by pacGem per character
-- MY gem for pacify. pacGem is per character and set in Settings; epGem is the old shared number and
-- remains the fallback so a group that never touches Smart Cast behaves exactly as before.
function ep_gem_num()
    return (pacGem and pacGem[myName:lower()]) or epGem or 8
end
epQueue    = {}          -- { { id, name, oor, state } }  state: nil | 'done' | 'failed'
epSaved    = nil         -- slot -> original item name ('' = was empty). nil = not stripped.
epStripAt  = 0
epCast     = nil         -- { id, name, at, tries }
epDoneAt   = nil
EP_RECAST  = 1500        -- gap between casts; placate is quick, this is just breathing room
-- After a /memspell, how long before the first cast. The gem reports its name back before the client
-- has finished standing and closing the book, and a cast in that window goes nowhere - so this is not
-- covered by the gem timer, which can read 0 while the character is still getting up.
EP_MEM_SETTLE = 1500
-- Consecutive failed memorise attempts before the pause is released. Holding across retries stops E3
-- re-memming its own spell into the contested gem between our tries; releasing eventually stops a gem
-- we can never win from pinning E3 down for the rest of the session.
EP_MEM_TRIES = 3
-- How long the gem must read READY CONTINUOUSLY after a memorise before the first cast. A single sample
-- can land in a gap where the timer reads 0 mid-settle; holding for this long cannot.
EP_GEM_STEADY = 750
epGemSteadyAt = nil
epMemFails = 0
epMemWaitSaid = 0
EP_CHECK_AFTER = 1000    -- pause after the cast completes before looking at the mob
-- How many ticks we will spend trying to get back onto a mob to READ it. Separate from EP_RETRY, which
-- counts re-CASTS: failing to look is not the same as failing to cast, and spending a cast because the
-- target slipped is the bug this exists to avoid.
EP_CHECK_TRIES = 8
EP_RETRY   = 3
EP_LINGER  = 8000

-- ONE PAUSE for the whole placate run: from before the memorise through to the gear going back on.
-- It used to be two - one around the mem, one around the strip - which left a gap between them where
-- E3 could act, and that gap is exactly where the character is standing up with a spellbook open.
-- Tracked with a flag rather than paired calls, because the run has several exits and a pause that
-- outlives the thing it was protecting is worse than no pause: an enchanter frozen out of E3 does not
-- announce itself, it just stops fighting.
-- WHAT WE TOOK OFF, WRITTEN TO DISK. epSaved lives in memory, which is fine right up until the client
-- crashes mid-run - and this client does crash. The record dies with it, and the character is left with
-- an epic in a bag and nothing that knows it should be worn.
-- So the moment anything comes off it goes in a file, and the moment everything is back on the file
-- goes. A file still present at startup means a run did not finish, and the gear goes back before
-- anything else happens.
function ep_recovery_path()
    local dir = ''
    pcall(function() dir = tostring(mq.TLO.MacroQuest.Path('config')() or '') end)
    local who = ''
    pcall(function() who = tostring(mq.TLO.Me.Name() or 'unknown') end)
    -- Per character for real: it records THIS toon's weapons, mid-run.
    return at_read('adventuretime_stripped_' .. who .. '.txt')
end
function ep_recovery_write()
    local fh = io.open(ep_recovery_path(), 'w')
    if not fh then return end
    for _, slot in ipairs(EP_SLOTS) do
        fh:write(string.format('%s=%s\n', slot, (epSaved and epSaved[slot]) or ''))
    end
    fh:close()
end
function ep_recovery_clear()
    pcall(function() os.remove(ep_recovery_path()) end)
end
function ep_recovery_read()
    local fh = io.open(ep_recovery_path(), 'r')
    if not fh then return nil end
    local t, any = {}, false
    for line in fh:lines() do
        local k, v = line:match('^(%w+)=(.*)$')
        if k then t[k] = v or ''; if v and v ~= '' then any = true end end
    end
    fh:close()
    return any and t or nil
end

-- ===== WHO IS HOLDING E3 DOWN =====
-- E3's IsPaused is ONE BOOLEAN with no reference count - /e3p on sets it, /e3p off clears it, and the
-- last caller wins. AT has more than one thing that needs E3 held: the placate run (mem, strip, cast,
-- re-equip) and the consumable distributor (pickups and trades), and either can be asked to pause by a
-- PEER as well, through /at_e3.
-- With a single flag per subsystem they clobbered each other. The expensive direction: placate strips
-- the enchanter's weapons and pauses, the distributor finishes an unrelated trade and sends /e3p off,
-- and E3 starts driving a character that is standing there with no weapons mid-placate.
-- So count holders instead. /e3p on goes out only when the FIRST one takes hold and /e3p off only when
-- the LAST one lets go, which makes releasing someone else's hold impossible by construction.
E3HOLD = {}
-- IS E3 ACTUALLY PAUSED? Not what we believe - what E3 says.
-- E3 exposes Basics.IsPaused through its reflection lookup, and MQ2Mono.Query wraps whatever it is given
-- in ${...} and runs it through Casting.Ifs_Results - the same resolver that handles ${E3N.State.*}. So
-- the internal value IS reachable from here, via that bridge, even though ${E3N.State.Basics.IsPaused}
-- is not an MQ TLO on its own and cannot be read directly.
-- Returns nil if the bridge itself did not answer - E3 not loaded, not initialised, mid-reload. nil is
-- deliberately NOT false: "I could not tell" and "it is running" want different handling, and treating
-- the first as the second is how you get a confident wrong answer.
e3PausedSaidRaw = false
function e3_is_paused()
    local v
    pcall(function() v = mq.TLO.MQ2Mono.Query('e3', 'E3N.State.Basics.IsPaused')() end)
    local s = (v == nil) and '' or tostring(v):lower()
    -- SAY WHAT THE BRIDGE ACTUALLY RETURNS, once, the first time it is asked. Everything built on this
    -- read is only as good as the read, and there is no way to tell from the outside whether the query
    -- resolved. One line in the log removes the guesswork permanently.
    if not e3PausedSaidRaw then
        e3PausedSaidRaw = true
        rezlog('[e3] pause probe returns "%s" (want true/false; anything else means the query did not '
            .. 'resolve and every pause check is blind)', s)
    end
    -- ONLY AN EXPLICIT TRUE OR FALSE IS AN ANSWER.
    -- Ifs_Results does string REPLACEMENT: if it cannot resolve the key it hands back the text unchanged,
    -- so a failed query returns the literal "${e3n.state.basics.ispaused}". The old test asked "is it
    -- true?" and returned false for that - which reads as "E3 is running" and is indistinguishable from
    -- E3 actually running. That is how "asked E3 to pause and it reports it is still RUNNING" could be
    -- printed by a check that had in fact learned nothing.
    -- nil means I DO NOT KNOW, and callers treat that differently from false on purpose.
    if s == 'true' or s == '1' then return true end
    if s == 'false' or s == '0' then return false end
    return nil
end

local function e3_holders()
    local n = 0
    for _ in pairs(E3HOLD) do n = n + 1 end
    return n
end
function e3_hold(owner)
    owner = owner or 'unknown'
    if E3HOLD[owner] then return end          -- idempotent per owner: strip may ask after the mem did
    local was = e3_holders()
    E3HOLD[owner] = true
    if was == 0 then
        mq.cmd('/e3p on')
        -- /e3p IS QUEUED, NOT IMMEDIATE. E3's own IsPaused() starts with
        --     EventProcessor.ProcessEventsInQueues("/e3p")
        -- so the command sits in a queue and only lands when E3's loop next asks whether it is paused.
        -- The call returns to us instantly either way, so without this we send "pause", then strip
        -- weapons and open the spellbook while E3 is still driving - which is precisely the window it
        -- was paused to avoid.
        -- Bounded, not indefinite: it is one iteration of E3's loop, and every character here runs
        -- ProcessLoopDelayInMS=50. 250ms is several times that and is paid ONCE, on the transition into
        -- being held, not per owner and not on release.
        -- VERIFY, do not assume. e3_is_paused reads E3's own flag through the mono bridge, so instead of
        -- waiting a fixed guess we wait until it is actually true - and find out if it never becomes so.
        -- 2.5s, not 1s. Measured: E3 took between 1.0 and 1.6s to process /e3p on a live pull, so a
        -- one second window reported a false alarm on a pause that was simply still in flight.
        -- This is a ceiling, not a wait - it returns the moment E3 reports paused.
        mq.delay(2500, function() return e3_is_paused() == true end)
        local st = e3_is_paused()
        if st == false then
            -- It took the command and is still running. Say it plainly rather than carrying on and
            -- wondering later why E3 healed through a placate or stepped on a /nowcast.
            rezlog('\\ar[e3] asked E3 to pause and it reports it is still RUNNING - retrying once\\ax')
            mq.cmd('/e3p on')
            mq.delay(2500, function() return e3_is_paused() == true end)
            local after = e3_is_paused()
            if after == false then
                rezlog('\\ar[e3] E3 WILL NOT PAUSE - it is going to act underneath us. /atresume then retry.\\ax')
            elseif after == nil then
                -- Treating "could not read" as success is how this hid. It is not success.
                rezlog('\\ar[e3] cannot read E3 pause state at all - proceeding BLIND, E3 may act '
                    .. 'underneath us. Check MQ2Mono is loaded and e3 is running.\\ax')
            end
        elseif st == nil then
            -- Bridge did not answer. Fall back to the old behaviour: wait out one E3 loop and hope.
            mq.delay(250)
        end
    end
end
-- CALLED ON THE TICK WHILE WE HOLD IT. E3 can be unpaused by anything that sends /e3p - a stray macro,
-- a hotkey, a peer command, somebody typing it - and the symptom is E3 healing and overriding /nowcast
-- while AT believes it has the character. Cheap to check, and re-asserting costs nothing when it is
-- already true.
function e3_assert_held()
    if e3_holders() == 0 then return end
    if e3_is_paused() == false then
        rezlog('\\ar[e3] E3 came back up while %d hold(s) were still on it - pausing it again\\ax',
               e3_holders())
        mq.cmd('/e3p on')
        mq.delay(2500, function() return e3_is_paused() == true end)
    end
end

function e3_release(owner)
    owner = owner or 'unknown'
    if not E3HOLD[owner] then return end
    E3HOLD[owner] = nil
    if e3_holders() == 0 then mq.cmd('/e3p off') end
end
-- Unconditional: for the way out and for /atresume, where the point is to leave nothing held whatever
-- anyone thinks they own.
function e3_release_all()
    for k in pairs(E3HOLD) do E3HOLD[k] = nil end
    mq.cmd('/e3p off')
end

-- STOW WHATEVER IS ON THE CURSOR. Returns true if the cursor ended up empty.
-- /autoinventory only moves the item to a free bag slot: it does not destroy anything and does not pick
-- a destination beyond that, so the worst case of being wrong is an item in a bag.
function cursor_stow(tag)
    if (mq.TLO.Cursor.ID() or 0) == 0 then return true end
    local held = tostring(mq.TLO.Cursor.Name() or '?')
    pcall(function() mq.cmd('/autoinventory') end)
    mq.delay(600, function() return (mq.TLO.Cursor.ID() or 0) == 0 end)
    if (mq.TLO.Cursor.ID() or 0) == 0 then
        rezlog('[%s] stowed %s off the cursor', tag or 'cursor', held)
        return true
    end
    return false, held
end

-- WHAT TO CALL THE PAUSE IN A LOG LINE. Two messages said "(E3 paused)" and "E3 paused; stripping" as
-- fixed text, two lines after the probe had printed "E3 WILL NOT PAUSE - it is going to act underneath
-- us". Shylain then memmed, stripped three weapons and cast for eleven seconds with E3 live, and the log
-- said it was paused throughout. A log that states an assumption in the same words it would state a fact
-- is worse than one that says nothing.
function e3_pause_note()
    local st = e3_is_paused()
    if st == true  then return 'E3 paused' end
    -- No colour codes here: this string is passed as a %s into another format, and the log writer
    -- stripped the escape and left the letter - Shylain's log reads "(r E3 NOT PAUSED x)".
    if st == false then return 'E3 NOT PAUSED' end
    return 'E3 pause state unknown'
end

epPaused = false
function ep_pause()
    if epPaused then return end
    epPaused = true
    e3_hold('placate')
end
function ep_resume(why)
    if not epPaused then return end
    epPaused = false
    e3_release('placate')
    rezlog('[placate] E3 resumed (%s)', why or 'done')
end

-- WHO CAN WORK THE PLACATE QUEUE. Enchanters and clerics both get a placate line, and everything
-- downstream is already class-agnostic: ep_best_placate scans THIS character's spellbook for the Calm
-- line and takes the highest rank it owns, ep_ensure_gem mems whatever that turns out to be, and the
-- range comes from the resolved spell. So adding a class is genuinely this one list.
-- Still a CLASS check rather than "owns a placate spell", so which classes are in is a deliberate list.
-- DRUIDS ADDED. This list used to say a druid "has one and does not need any of this", the reasoning
-- being the strip: it exists so augment procs cannot break the placate, and that only matters for a
-- character swinging weapons. A druid usually is not - but the strip is harmless when there is nothing
-- proccing, and having a fourth caster in the rotation is worth more than skipping a no-op.
-- Their line is Nature's Serenity; the name hint below is what lets ep_best_placate find it.
EP_CLASSES = { ENC = true, CLR = true, PAL = true, DRU = true }
-- WHO ACTUALLY WORKS THE QUEUE when more than one character can. Without this every capable toon in the
-- group strips its weapons and casts at the same mob - three characters doing one job, three sets of
-- gear off, and the mob placated twice over.
-- Class order, best first. Enchanter leads because placate is their line and the rank they carry is
-- normally the highest; cleric next; paladin last, since theirs tends to be the shortest-ranged.
-- Druid sits at the end: their line is real but it is not what they are there for, so when two casters
-- can both take a mob from the SHARED list the druid is the one to leave alone.
-- This order only decides the manual-button queue. Smart Cast routes assigned work by ceiling and load,
-- and ignores the election entirely - so a druid with the highest ceiling still gets sent the high mobs.
EP_CLASS_ORDER = { 'ENC', 'CLR', 'PAL', 'DRU' }
-- `or ''` not `= ''`, same reason as miniFold: this sits above load_settings() today, and a plain
-- assignment would silently discard a loaded pin if either ever moved.
pacOff = pacOff or {}     -- [nameLower] = true when taken out of the rotation
-- PER CHARACTER GEM. epGem is one number shared by whoever happens to be the placate caster, which was
-- fine with a single enchanter and is wrong the moment three characters each have their own layout.
-- Only spell casters need one - a monk's phantom line is a disc and has no gem.
pacGem = pacGem or {}     -- [nameLower] = gem number
pacQueue = pacQueue or {}
function pac_find(id)
    for i, e in ipairs(pacQueue) do if e.id == id then return i, e end end
    return nil
end
-- Who the group has elected. Every toon computes this from the SAME inputs - the reported capability
-- list and the class order - so they all reach the same answer without a negotiation.
-- Ties are broken by name, for the same reason the rez chain sorts its pins: two toons of the same class
-- must not disagree about which of them is first.
-- ===== PACIFY ROUTING =====
-- One queue, several casters, each with a different level ceiling. A monk's phantom line, an enchanter's
-- placate, a cleric's and a paladin's all do the same job and all cap out somewhere different - so the
-- interesting question is not "who can pacify" but "who should take THIS mob".
--
-- Spell[x].MaxLevel is spell DATA, so any character can read it - but the RANK each caster owns differs,
-- so each reports its own. The driver never has to know what anyone carries.
--
-- ASSIGNMENT RULE: the LOWEST ceiling that still covers the mob. Sending a level 70 mob to the caster
-- capped at 95 wastes the only one who can take a level 90, and that matters precisely when a pull has
-- a mix - which is when pacifying matters at all.
pacCap = {}   -- [char] = { cap, spell, range, kind, updated }

-- What I can pacify with, whatever class I am. Returns spell name, level cap, range - or nil.
function pac_self()
    local sp, kind, spID
    if ep_can_placate() then
        -- VALIDATE THE GEM, do not just read it. This used to fall back to the spellbook only when the
        -- gem was EMPTY, so a gem holding the wrong spell was taken at face value - a paladin whose
        -- placate gem held Brell's Vibrant Barricade announced that as his pacify, and MaxLevel on a
        -- buff is 0.
        -- A cap of 0 is not a cosmetic wrong number, it is a DEADLOCK: pac_assign only sends a mob to a
        -- caster whose ceiling covers it, no mob is level 0 or under, so that character is never
        -- assigned anything - which means ep_tick never runs, which means ep_ensure_gem never gets the
        -- chance to mem the right spell and fix the very problem. It cannot recover on its own.
        -- Announcing off the best placate in their BOOK breaks the cycle: the ceiling is honest, Smart
        -- Cast routes to them, and ep_tick mems the spell on demand the first time it has work.
        -- ANNOUNCE THE BEST CEILING AVAILABLE, not merely a valid one.
        -- The gem was trusted whenever it held ANY placate, so a character sitting on a lower rank
        -- announced that rank and never looked further - Shela reported 76 while an 80 sat in her book.
        -- The gem says what is memmed right now; the book says what she can reach. ep_ensure_gem mems on
        -- demand anyway, so the higher one is what she will actually cast.
        local gemSp = ep_spell()
        if gemSp and not ep_spell_ok(gemSp) then gemSp = nil end
        local bookSp = ep_best_placate and ep_best_placate() or nil
        -- BY ID where we have one. Same reason as the book scan: a name can resolve to the wrong spell.
        local function capof(n, id)
            if id and id > 0 then
                local c = 0
                pcall(function() c = tonumber(mq.TLO.Spell(id).MaxLevel()) or 0 end)
                if c > 0 then return c end
            end
            if not n then return -1 end
            local c = 0
            pcall(function() c = tonumber(mq.TLO.Spell(n).MaxLevel()) or 0 end)
            return c
        end
        -- ONLY READ THE GEM'S ID IF THE GEM HOLDS A PLACATE. gemSp is set to nil just above when what is
        -- memmed is not one, but the ID was still being read from that same gem - so capof reported the
        -- ceiling of the WRONG SPELL entirely. Shylain's startup logged 'gem "none" caps 6006', which is
        -- Sunburst Blessing's number wearing the gem slot's clothes. It happened to be harmless because
        -- gemSp was nil and the book branch won, but a large bogus number one branch away from winning
        -- is not something to leave sitting there.
        local gemID = 0
        if gemSp then pcall(function() gemID = tonumber(mq.TLO.Me.Gem(ep_gem_num()).ID()) or 0 end) end
        local gemCap, bookCap = capof(gemSp, gemID), capof(bookSp, epBestPlacateID)
        -- CARRY THE ID, not just the name. The whole point of resolving by ID is lost the moment the
        -- name is handed onward and looked up again - which is exactly what happened: the check below
        -- reported 80 and the announce two lines later said 76, because it re-read Spell["Placate"].
        if bookCap > gemCap then sp, spID = bookSp, epBestPlacateID
        elseif gemSp then        sp, spID = gemSp, gemID
        else                     sp, spID = bookSp, epBestPlacateID end
        -- SAY THE WORKING, once. Two separate wrong ceilings were chased on inference alone; the numbers
        -- this decision is made from were never in the log.
        if not epCapSaid then
            epCapSaid = true
            rezlog('[placate] ceiling check - gem "%s" caps %d | book "%s" caps %d -> using "%s"',
                   tostring(gemSp or 'none'), gemCap, tostring(bookSp or 'none'), bookCap, tostring(sp or 'none'))
        end
        kind = 'placate'
    end
    if not sp and pw_have and pw_have() then
        local d = pw_disc()
        if d then sp, kind = d.name, 'phantom' end
    end
    if not sp then return nil end
    -- THE ANNOUNCED CEILING, read by ID when we have one. This was a by-name lookup and it is the line
    -- that produced the wrong number the whole time: every fix upstream computed 80 correctly and then
    -- this threw it away and asked about a different spell of the same name.
    local cap = 0
    if spID and spID > 0 then
        pcall(function() cap = tonumber(mq.TLO.Spell(spID).MaxLevel()) or 0 end)
    end
    if cap <= 0 then
        pcall(function() cap = tonumber(mq.TLO.Spell(sp).MaxLevel()) or 0 end)
    end
    -- A ceiling of 0 covers nothing, so announcing it just puts a caster on the panel that can never be
    -- given a mob. Say so plainly instead - a missing caster with a reason beats a silent useless one.
    if cap <= 0 then
        rezlog('\\ar[pacify] "%s" reports a level ceiling of 0 - not announcing. Check the placate gem '
            .. 'and the spell in it.\\ax', tostring(sp))
        return nil
    end
    -- RANGE THROUGH THE EXISTING RESOLVERS, not a fresh MyRange read. MyRange is the member that lies for
    -- placate on this build - it returns the base and ignores the focus - which is the whole reason
    -- ep_range exists: it derives the focus ratio from a DETRIMENTAL spell that does report it and
    -- applies that to the placate base.
    -- pw_range does the equivalent for the monk disc line. Reading MyRange here would have quietly
    -- undone both and routed on unfocused numbers.
    local rng = 0
    if kind == 'placate' then rng = ep_range() or 0
    else                      rng = pw_range() or 0 end
    if rng <= 0 then
        pcall(function() rng = tonumber(mq.TLO.Spell(sp).MyRange()) or 0 end)
        if rng <= 0 then pcall(function() rng = tonumber(mq.TLO.Spell(sp).Range()) or 0 end) end
    end
    return sp, cap, rng, kind
end

-- Who should take a mob of this level. Lowest sufficient ceiling wins; ties break by name so every toon
-- reaches the same answer without asking anyone.
-- Announce what I can pacify. Called ONCE at startup rather than on the heartbeat: the spell and its
-- ceiling do not change during a session unless something is re-memmed, and pac_self is half a dozen
-- TLO reads to answer a question whose answer is fixed.
-- /atpac re-announces, which is the thing to run after memming a different rank.
function pac_announce()
    local sp, cap, rng, kind = pac_self()
    if not sp then return false end
    pacCap[myName] = { cap = cap, spell = sp, range = rng, kind = kind, updated = mq.gettime() }
    pcall(function() peer_bcast('/at_paccap %s %d %d %s', myName, cap or 0, rng or 0, kind or '?') end)
    log('[pacify] I can pacify with %s - caps at level %d, range %d', sp, cap or 0, rng or 0)
    -- ANNOUNCE AGAIN IF THE RANGE IS STILL THE FALLBACK. ep_range caches only a real answer, so a
    -- fallback here means the spell was not readable yet - typically because the gem is not memmed 8
    -- seconds into a session. Broadcasting 200 once and never revisiting it would pin this character at
    -- the unfocused number for the whole session, and the routing would quietly favour the wrong caster.
    -- ONLY RE-CHECK IF THE SPELL ITSELF DID NOT RESOLVE. Comparing the RESULT against the fallback value
    -- was wrong: the monk's phantom line genuinely reads 200, which is also the fallback number, so a
    -- correctly resolved range re-announced itself every minute forever.
    -- The question is whether we got an answer, not whether the answer happens to equal a default.
    local resolved = (kind == 'placate') and (epRangeCache ~= nil) or (pwRangeCache ~= nil)
    if not resolved then
        pacAnnounceAt = mq.gettime() + 60000
        log('[pacify] range not resolved yet (using %d) - will re-check in a minute', rng)
    end
    return true
end

-- Who should take a mob of this level AT this distance.
-- Two filters, then two preferences:
--   filter  ceiling covers the mob, and range reaches it
--   prefer  the LOWEST sufficient ceiling - so the high-cap caster stays free for mobs only they can take
--   prefer  then the LONGEST range, because a caster who can hit it from further out is less likely to
--           have to move, and moving is what breaks a pacify
-- HAND MY ASSIGNED MOBS TO MY OWN QUEUE. Smart Cast decides WHO; the existing placate and phantom
-- queues already know HOW - the strip, the mem, the range stalls, the retries, the verification, the
-- gear recovery. Feeding them is far better than a third implementation of all that.
-- Each character dispatches only its own entries, so this runs everywhere and does nothing on five of
-- six toons. `sent` marks an entry handed off, so it happens once rather than every tick.
-- CLEAR THE QUEUE WHEN THERE IS NOTHING LEFT TO DO. A finished list that stays on screen is the same
-- problem the placate queue had: you cannot tell "done" from "stuck", and the next pull starts with
-- yesterday's mobs still listed.
-- Two conditions, both meaning "no further work":
--   * every entry resolved - pacified, immune, failed, above everyone's ceiling
--   * an entry stuck OUT OF RANGE for more than PAC_OOR_MAX - the group has moved on and it is not
--     coming back into reach, so holding the whole list for it helps nobody
-- Cleared across the group, since every toon keeps its own copy.
-- HOW LONG AN ASSIGNED ENTRY MAY GO UNRESOLVED before we assume it is never happening.
-- This is NOT a "stayed out of range" timer, though it was written as one at 10 seconds - and that was
-- far too short. A caster that has taken an entry then strips its weapons, mems, closes the spellbook,
-- walks into range, casts, waits out the cast, verifies the debuff, retries twice and re-equips. Forty
-- seconds is an ordinary run, so a 10-second bound cleared the list out from under work in progress.
-- The caster resolves its own entries through pac_reflect, so this only catches the ones that never
-- come back at all.
-- TWO DIFFERENT FAILURES, TWO DIFFERENT CLOCKS. These used to be one number doing both jobs, which is
-- why it was wrong at 10 seconds and then only approximately right at 90.
--   PAC_OOR_MAX    the caster has REPORTED this mob out of reach and it has stayed that way. The group
--                  has moved on and it is not coming back into range, so holding the list for it helps
--                  nobody. This is now a real out-of-range timer: the caster reflects its own oor state
--                  through pac_reflect_oor rather than us guessing from how long something has taken.
--   PAC_STALL_MAX  dispatched and then nothing at all - no outcome, no oor report. That is a caster
--                  that is not running, or a queue that has wedged. A caster doing ordinary work strips,
--                  mems, closes the book, walks in, casts, verifies, retries and re-equips, so forty
--                  seconds is a normal run and this bound has to stay generous.
-- Both are backstops. In the normal case the casting queue gives up first (EP_FAR_MAX / PW_FAR_MAX at
-- 45s) and reflects a real outcome, and neither of these ever fires.
-- HOW LONG AN ASSIGNMENT IS LEFT ALONE BEFORE IT MAY BE MOVED.
-- e.sent is set by the ASSIGNEE and reaches everyone else as a broadcast, so between it picking the mob
-- up and that message landing, whoever is adding mobs still sees the entry as free and would happily
-- reassign a mob that is already being worked. Nothing on the wire is instant; a short grace covers it.
-- Inside this, a corpse is close enough to rez and loot without dragging, so /corpse having no
-- measurable effect is the expected outcome rather than a failure.
CORPSE_NEAR = 10
PAC_MOVE_GRACE = 2500
PAC_OOR_MAX   = 90000
PAC_STALL_MAX = 90000
PAC_LINGER    = 6000     -- show the finished list briefly before it goes
pacDoneAt     = nil

function pac_autoclear()
    if not pacQueue or #pacQueue == 0 then pacDoneAt = nil; return end
    local pending, oldOor, oldStall = 0, 0, 0
    for _, e in ipairs(pacQueue) do
        if not e.state then
            -- The clock starts when it was DISPATCHED, not when it was queued: time spent waiting for a
            -- caster to pick it up is not time that caster has failed to act.
            if e.sent then e.waitSince = e.waitSince or mq.gettime() end
            local gone = false
            if e.oor and e.oorSince and (mq.gettime() - e.oorSince) > PAC_OOR_MAX then
                oldOor, gone = oldOor + 1, true
            elseif e.sent and not e.oor and e.waitSince
                   and (mq.gettime() - e.waitSince) > PAC_STALL_MAX then
                oldStall, gone = oldStall + 1, true
            end
            if not gone then pending = pending + 1 end
        end
    end
    if pending > 0 then pacDoneAt = nil; return end

    -- Everything is resolved, or the only things left are ones we have given up on.
    pacDoneAt = pacDoneAt or mq.gettime()
    if (mq.gettime() - pacDoneAt) > PAC_LINGER then
        if oldOor > 0 then
            log('[pacify] clearing - %d entry(s) stayed out of reach for %ds',
                oldOor, PAC_OOR_MAX / 1000)
        end
        if oldStall > 0 then
            log('[pacify] clearing - %d entry(s) were never heard back on within %ds',
                oldStall, PAC_STALL_MAX / 1000)
        end
        if oldOor == 0 and oldStall == 0 then
            log('[pacify] all done - clearing the list')
        end
        pac_snapshot()
        pacQueue, pacDoneAt = {}, nil
        pcall(function() peer_bcast('/at_pacclear') end)
    end
end

-- WHAT THE LAST BATCH WAS. Taken just before the list is emptied, from whichever path emptied it -
-- the auto-clear when everything resolved, or the Clear button. Only the id and name are kept: level
-- is re-read from the spawn on the way back in, and WHO had it is deliberately not kept.
pacRedo = {}
function pac_snapshot()
    if not pacQueue or #pacQueue == 0 then return end
    local snap = {}
    for _, e in ipairs(pacQueue) do
        if e.id and e.id > 0 then snap[#snap + 1] = { id = e.id, name = e.name or '?' } end
    end
    if #snap > 0 then pacRedo = snap end
end

-- Re-queue that batch. Skips anything dead or gone, and anything already queued.
function pac_redo()
    if not pacRedo or #pacRedo == 0 then log('\\ay[pacify] nothing to redo\\ax'); return end
    local added, dead, dup = 0, 0, 0
    for _, e in ipairs(pacRedo) do
        if pac_find(e.id) then
            dup = dup + 1
        else
            -- STILL THERE AND STILL ALIVE? A spawn id is reused by the zone, so check the type too:
            -- coming back as a PC or an empty read means this is not the mob we queued.
            local ty, hp, lvl, dist = '', 0, 0, 0
            pcall(function() ty   = tostring(mq.TLO.Spawn(e.id).Type() or '') end)
            pcall(function() hp   = tonumber(mq.TLO.Spawn(e.id).PctHPs()) or 0 end)
            pcall(function() lvl  = tonumber(mq.TLO.Spawn(e.id).Level()) or 0 end)
            pcall(function() dist = math.floor(tonumber(mq.TLO.Spawn(e.id).Distance()) or 0) end)
            if ty ~= 'NPC' or hp <= 0 then
                dead = dead + 1
            else
                -- Routed fresh: caps, reach and load have all moved on since the first time.
                local who, cap, rng = pac_assign(lvl, dist)
                if not who then who, cap, rng = pac_assign(lvl) end
                pacQueue[#pacQueue + 1] = { id = e.id, name = e.name, level = lvl, dist = dist,
                                            who = who, assignedAt = mq.gettime() }
                if who then
                    added = added + 1
                    log('[pacify] redo: %s (level %d, %dm) -> %s (caps %d, reach %d)',
                        e.name, lvl, dist, who, cap or 0, rng or 0)
                    pcall(function() peer_bcast('/at_pacadd %d %s %d %s',
                                                e.id, e.name:gsub(' ', '_'), lvl, who) end)
                else
                    log('\\ay[pacify] redo: %s is level %d - nobody here can pacify that high\\ax', e.name, lvl)
                end
            end
        end
    end
    if added > 0 then pac_rebalance() end
    log('[pacify] redo last: %d re-queued, %d gone, %d already listed', added, dead, dup)
end

function pac_dispatch()
    if not pacQueue or #pacQueue == 0 then return end
    local me = myName:lower()
    for _, e in ipairs(pacQueue) do
        if e.who and e.who:lower() == me and not e.sent and not e.state then
            -- LEVEL CAP, checked here rather than in the casting queues. Unlike range - which changes as
            -- the group closes and so is worth retrying - a mob above the ceiling never becomes eligible,
            -- so it is marked once and never queued at all.
            local myCap = (pacCap[myName] or {}).cap or 0
            if (e.level or 0) > myCap and myCap > 0 then
                e.sent, e.state = true, 'too high'
                pcall(function() peer_bcast('/at_pacmark %d %s', e.id, 'too high') end)
                rezlog('[pacify] %s is level %d, my ceiling is %d - not attempting', e.name, e.level or 0, myCap)
            else
                e.sent = true
                if ep_can_placate() then
                    if not ep_find(e.id) then
                        -- mine=true: ASSIGNED TO ME BY SMART CAST, as opposed to an entry broadcast to
                        -- everybody's queue by the manual button. The election below stands a character
                        -- down when it is not the group's chosen caster, which is right for a shared
                        -- list and wrong for work addressed to this character specifically.
                        epQueue[#epQueue + 1] = { id = e.id, name = e.name, oor = false, farSince = nil,
                                                  mine = true }
                        -- HOLD E3 NOW, not at the mem a tick later.
                        -- /e3p is queued on E3's side and measured 1.0-1.6s to actually land - far longer
                        -- than its 50ms loop - so asking for the pause and immediately memming and
                        -- stripping meant E3 was still driving through the part that matters.
                        -- Taking it here buys a whole tick of lead time at no cost: by the time ep_tick
                        -- gets to the mem it is already held. If the work then evaporates - mob dies,
                        -- gets reassigned - the "paused, holding nothing, nothing queued" backstop in
                        -- ep_tick lets go on its own.
                        ep_pause()
                        pcall(function() peer_bcast('/at_pacsent %d', e.id) end)
                        rezlog('[pacify] taking %s#%d (level %d) into my placate queue', e.name, e.id, e.level or 0)
                    end
                elseif pw_have and pw_have() then
                    if not pw_find(e.id) then
                        pwQueue[#pwQueue + 1] = { id = e.id, name = e.name, oor = false }
                        pcall(function() peer_bcast('/at_pacsent %d', e.id) end)
                        rezlog('[pacify] taking %s#%d (level %d) into my phantom queue', e.name, e.id, e.level or 0)
                    end
                end
            end
        end
    end
end

-- HOW MANY UNRESOLVED MOBS ARE ALREADY ON THIS CASTER. Read off the shared queue, so every character
-- computes the same number and reaches the same assignment without asking anyone.
function pac_load(nm)
    local n = 0
    local low = (nm or ''):lower()
    for _, e in ipairs(pacQueue or {}) do
        if not e.state and e.who and e.who:lower() == low then n = n + 1 end
    end
    return n
end

-- REASSIGN WHAT HAS NOT BEEN PICKED UP YET.
-- Assignments are made one mob at a time as they are added, so a choice made at mob 1 can be wrong by
-- mob 4 - the classic case being the high-ceiling caster taking a couple of ordinary mobs and then a
-- level 79 arriving that only they can take.
-- ONLY UN-SENT ENTRIES MOVE. Once e.sent is set the assignee has it in its own queue and may already be
-- stripped, memming or mid-cast for it; taking it back then is how you get two casters on one mob.
-- Before that it is just a name on the shared list and costs nothing to change.
-- A move must STRICTLY even things out - the receiver's load after the move must still be below the
-- giver's. That is what stops two casters passing the same mob back and forth forever.
function pac_rebalance()
    local moved = 0
    for _ = 1, 8 do          -- bounded: a pull is small and this runs on every add
        local pick
        for _, e in ipairs(pacQueue or {}) do
            -- not state: already done, failed or ruled too high - settled, leave it.
            -- not sent: nobody has picked it up, so nobody is stripped or casting for it yet.
            -- grace: and the pickup message has had time to get here if it was coming.
            if not e.state and not e.sent and e.who
               and (mq.gettime() - (e.assignedAt or 0)) > PAC_MOVE_GRACE then
                local fromLoad = pac_load(e.who)
                for nm, c in pairs(pacCap) do
                    if nm:lower() ~= e.who:lower() and not pacOff[nm:lower()]
                       and (c.cap or 0) >= (e.level or 0)
                       and ((e.dist or 0) <= 0 or (c.range or 0) >= (e.dist or 0)) then
                        local toLoad = pac_load(nm)
                        local fromCap = (pacCap[e.who] or {}).cap or 0
                        -- Two reasons to move, and the second is the one that matters most.
                        --  1. STRICTLY EVENER: the receiver ends up below the giver even after taking it.
                        --  2. SAME BALANCE, LOWER CEILING: counts come out equal, but the work shifts to
                        --     the caster with the smaller ceiling. Three 69s and a 79 across a 70/76/80
                        --     group is 2/1/1 either way - the question is who holds the two, and it must
                        --     not be the only one who can take the 79.
                        -- Rule 2 cannot oscillate: it only ever moves toward a LOWER ceiling, so a mob
                        -- cannot come back the way it went.
                        local evener = (toLoad + 1 < fromLoad)
                        local downhill = (toLoad + 1 == fromLoad) and ((c.cap or 0) < fromCap)
                        if evener or downhill then
                            local gain = evener and (fromLoad - toLoad) or 1
                            if not pick or gain > pick.gain then
                                pick = { e = e, to = nm, from = e.who, gain = gain }
                            end
                        end
                    end
                end
            end
        end
        if not pick then break end
        pick.e.who = pick.to
        pick.e.assignedAt = mq.gettime()   -- fresh grace on its new owner
        moved = moved + 1
        log('[pacify] moved %s from %s to %s to even out the queue', pick.e.name, pick.from, pick.to)
        pcall(function() peer_bcast('/at_pacwho %d %s', pick.e.id, pick.to) end)
    end
    return moved
end

function pac_assign(mobLevel, dist)
    local best, bestCap, bestRng, bestLoad = nil, nil, nil, nil
    for nm, c in pairs(pacCap) do
        -- NO STALENESS CHECK. A spell's level ceiling does not change, so an old report is as good as a
        -- fresh one - and expiring it meant a quiet character dropped out of the routing and mobs got
        -- sent to the wrong caster, or to nobody.
        -- Being OFF is a decision; being quiet is not.
        local capOk = (c.cap or 0) >= (mobLevel or 0) and not pacOff[nm:lower()]
        -- No distance given means "do not filter on it" - the caller did not know, so neither do we.
        local rngOk = (not dist) or dist <= 0 or (c.range or 0) >= dist
        if capOk and rngOk then
            -- SPREAD THE WORK, THEN PREFER THE LOW CEILING.
            -- The ceiling is a CONSTRAINT - only casters who can take this mob are in here at all - but it
            -- used to be the whole rule, and that is not a sharing rule. With a cleric at 76 and an
            -- enchanter at 80, every mob up to 76 went to the cleric and the enchanter sat idle unless
            -- something 77+ turned up. One caster did all the work, one recast at a time, stripping and
            -- re-equipping for every mob.
            -- Fewest already queued wins first, so an even pull splits evenly. Lowest sufficient ceiling
            -- is the tiebreak, which is what keeps the high-cap caster free when loads are level - so a
            -- level 79 that only they can take still finds them with an empty queue.
            local load = pac_load(nm)
            local better = false
            if not bestCap then better = true
            elseif load < bestLoad then better = true
            elseif load == bestLoad then
                if c.cap < bestCap then better = true
                elseif c.cap == bestCap then
                    if (c.range or 0) > (bestRng or 0) then better = true
                    elseif (c.range or 0) == (bestRng or 0) and nm:lower() < best:lower() then better = true end
                end
            end
            if better then best, bestCap, bestRng, bestLoad = nm, c.cap, c.range, load end
        end
    end
    return best, bestCap, bestRng
end


-- Summon my own corpse, loot everything, close the window.
-- Ordered deliberately: summon FIRST, because a corpse that is out of reach cannot be looted and /corpse
-- is free when it is already close. Then loot, then close - leaving the loot window open blocks trades,
-- pickups and the next rez, and nothing else would ever close it.
function loot_my_corpse(wantID)
    local id = tonumber(wantID) or 0
    if id <= 0 then
        pcall(function() id = tonumber(mq.TLO.Spawn('pccorpse ' .. myName).ID()) or 0 end)
    end
    if id <= 0 then return end

    -- STOP CASTING FIRST. The client will not open a loot window while a spell is going out, and this
    -- runs right after a rez - the moment everything else starts casting again. A cast that began a
    -- fraction earlier silently ate the /loot, the window never opened, and the corpse was left lying
    -- there with only "the loot window did not open - corpse may be out of reach" to explain it, which
    -- points at the wrong thing entirely.
    -- Cheap to give up: /stopcast costs one spell that is about to be re-cast a second later anyway,
    -- and the alternative is a corpse that stays on the ground until someone notices.
    -- Only if something IS casting, so this does not interrupt for nothing on the normal path.
    do
        local casting = false
        pcall(function() casting = (tonumber(mq.TLO.Me.Casting.ID()) or 0) > 0 end)
        if casting then
            rezlog('[corpse] stopping a cast so the loot window can open')
            pcall(function() mq.cmd('/stopcast') end)
            mq.delay(600, function() return (tonumber(mq.TLO.Me.Casting.ID()) or 0) == 0 end)
        end
    end

    pcall(function() mq.cmdf('/target id %d', id) end)
    mq.delay(1000, function() return (tonumber(mq.TLO.Target.ID()) or 0) == id end)
    if (tonumber(mq.TLO.Target.ID()) or 0) ~= id then
        rezlog('[corpse] could not target my corpse'); return
    end
    pcall(function() mq.cmd('/corpse') end)
    mq.delay(600)

    -- AND AGAIN IMMEDIATELY BEFORE THE LOOT. Targeting and /corpse take about a second between them,
    -- which is long enough for E3 to have started something new.
    do
        local casting = false
        pcall(function() casting = (tonumber(mq.TLO.Me.Casting.ID()) or 0) > 0 end)
        if casting then
            pcall(function() mq.cmd('/stopcast') end)
            mq.delay(600, function() return (tonumber(mq.TLO.Me.Casting.ID()) or 0) == 0 end)
        end
    end
    pcall(function() mq.cmd('/loot') end)
    mq.delay(2500, function() local o = false
        pcall(function() o = mq.TLO.Window('LootWnd').Open() == true end); return o end)
    if not mq.TLO.Window('LootWnd').Open() then
        -- Name the two possibilities rather than only the one. The cast case is now stopped for above,
        -- so if this still fires while casting, /stopcast is not taking and that is worth knowing.
        local casting = false
        pcall(function() casting = (tonumber(mq.TLO.Me.Casting.ID()) or 0) > 0 end)
        rezlog('[corpse] the loot window did not open - %s',
               casting and 'still casting despite /stopcast' or 'corpse may be out of reach')
        return
    end

    -- NOTHING TO TAKE. Corpses here do not hold gear - opening and closing the loot window is simply
    -- what makes the body go away, and that is the entire point: a rezzed corpse left lying around is
    -- clutter that the next rez has to look past.
    -- This used to walk thirty slots three times looking for items that were never there.

    -- ALWAYS close it, whatever happened above.
    pcall(function() mq.cmd('/notify LootWnd LW_DoneButton leftmouseup') end)
    mq.delay(800, function() return not mq.TLO.Window('LootWnd').Open() end)
    if mq.TLO.Window('LootWnd').Open() then
        pcall(function() mq.TLO.Window('LootWnd').DoClose() end)
        mq.delay(500, function() return not mq.TLO.Window('LootWnd').Open() end)
    end
    -- DID IT ACTUALLY GO? The point is the body disappearing, so check rather than assume - and try once
    -- more if it is still there, since a loot window that opened on a busy client does not always take.
    mq.delay(1200)
    local still = ''
    pcall(function() still = tostring(mq.TLO.Spawn(id).Type() or '') end)
    if still == 'Corpse' then
        rezlog('[corpse] still there after looting - one more go')
        pcall(function() mq.cmdf('/target id %d', id) end)
        mq.delay(800, function() return (tonumber(mq.TLO.Target.ID()) or 0) == id end)
        -- The retry is the MOST likely one to be eaten by a cast: a second or two has passed since the
        -- first attempt and E3 has had every chance to start something.
        do
            local casting = false
            pcall(function() casting = (tonumber(mq.TLO.Me.Casting.ID()) or 0) > 0 end)
            if casting then
                pcall(function() mq.cmd('/stopcast') end)
                mq.delay(600, function() return (tonumber(mq.TLO.Me.Casting.ID()) or 0) == 0 end)
            end
        end
        pcall(function() mq.cmd('/loot') end)
        mq.delay(2000, function() local o = false
        pcall(function() o = mq.TLO.Window('LootWnd').Open() == true end); return o end)
        pcall(function() mq.cmd('/notify LootWnd LW_DoneButton leftmouseup') end)
        mq.delay(800, function() return not mq.TLO.Window('LootWnd').Open() end)
        pcall(function() still = tostring(mq.TLO.Spawn(id).Type() or '') end)
    end
    if still == 'Corpse' then
        rezlog('\\ay[corpse] my corpse is still lying there - loot it by hand\\ax')
    else
        rezlog('[corpse] corpse cleared')
    end
end

function ep_can_placate()
    local c = ''
    pcall(function() c = tostring(mq.TLO.Me.Class.ShortName() or ''):upper() end)
    return EP_CLASSES[c] == true
end
-- Kept as an alias: the name is wrong now but it is referenced from several places and a rename that
-- misses one would fail silently as "this character cannot placate".
function ep_is_enchanter() return ep_can_placate() end

-- The spell currently memmed in the placate gem. Read rather than configured: the user picks the gem,
-- and whatever is in it is what gets cast, so upgrading the spell needs no settings change.
function ep_spell()
    local nm = ''
    pcall(function() nm = tostring(mq.TLO.Me.Gem(ep_gem_num()).Name() or '') end)
    if nm == '' or nm == 'NULL' then return nil end
    return nm
end

-- IS THAT ACTUALLY A PLACATE? Casting "whatever is in gem 8" is fine right up to the evening somebody
-- rearranges their gems and the queue starts throwing Mez, or a nuke, at a row of mobs.
-- Two tests, cheapest first. Subcategory is the real one - the pacify line shares a spell subcategory,
-- so it catches every rank including ones nobody thought to list. The name fragments are a fallback for
-- when that TLO does not resolve, and both are logged the first time so the actual values can be seen
-- rather than guessed at - the subcategory string on this build is not something to assume.
-- 'serenity' rather than the full "Nature's Serenity": these are plain substring matches, so the short
-- form catches the whole line however the apostrophe is punctuated and whatever the rank is called.
EP_NAME_HINTS = { 'placate', 'pacify', 'calm', 'lull', 'soothe', 'wake of tranquility', 'serenity' }
EP_SUBCAT_HINT = 'calm'
function ep_spell_ok(nm)
    if not nm or nm == '' then return false, 'gem is empty' end
    local sub = ''
    pcall(function() sub = tostring(mq.TLO.Spell(nm).Subcategory() or '') end)
    if sub ~= '' and sub ~= 'NULL' and sub:lower():find(EP_SUBCAT_HINT, 1, true) then
        return true, sub
    end
    local low = nm:lower()
    for _, h in ipairs(EP_NAME_HINTS) do
        if low:find(h, 1, true) then return true, 'name match' end
    end
    return false, (sub ~= '' and sub ~= 'NULL') and ('subcategory "' .. sub .. '"') or 'no subcategory'
end

-- THE BEST PLACATE THIS ENCHANTER OWNS. Scans the spellbook once and caches, because the alternative -
-- a hardcoded list of ranks - goes stale the moment anyone scribes an upgrade, and the phantom line
-- taught that lesson already: pick from what the character actually has, do not assume.
-- Scanning is ~720 lookups, so it happens ONCE per session and only when it is actually needed, which
-- is when the chosen gem does not already hold a placate.
epBestPlacate = nil     -- false = looked and found none, so we do not scan again every tick
epBestMissAt = 0        -- when the last fruitless scan ran, so a miss can be retried
epCapSaid    = false    -- log the ceiling working once per session
epBestPlacateID = 0     -- the ID of the book spell we chose, so nothing re-looks it up by name
function ep_best_placate()
    if epBestPlacate then return epBestPlacate end
    -- A MISS IS NOT A FACT, IT IS A READING - and readings this early are unreliable.
    -- This used to cache false forever. That was safe while the only caller was "the gem is EMPTY",
    -- which is rare and late. Since pac_self started validating the gem, this is also called whenever
    -- the gem holds something that is not a placate - which at startup is the NORMAL state, because the
    -- gem still holds whatever was memmed last session. Shela's gem 8 holds her pet spell, so the scan
    -- ran seconds into load, before Me.Book was readable, cached false, and she never announced a
    -- ceiling again for the whole session. The enchanter with the highest cap in the group vanished.
    -- So: retry a miss every 30s instead of never, and do not even scan until the book reads back.
    if epBestPlacate == false and (mq.gettime() - (epBestMissAt or 0)) < 30000 then return nil end
    local bookOk = false
    pcall(function() bookOk = tostring(mq.TLO.Me.Book(1).Name() or '') ~= '' end)
    if not bookOk then
        -- Not "no placate" - "cannot read the book yet". Leave the cache alone so this is retried.
        return nil
    end
    local best, bestCap, bestLvl = nil, -1, -1
    for i = 1, 720 do
        local nm, sid = '', 0
        pcall(function() nm = tostring(mq.TLO.Me.Book(i).Name() or '') end)
        -- THE SPELL ID FROM THE BOOK SLOT, not a second lookup by name.
        -- Spell["Placate"] resolves a NAME to one particular spell, and more than one spell is called
        -- Placate. So walking the book and then asking Spell[name] threw away which one we had found and
        -- asked about a different one: Shela's scan reported ceiling 76 / spell level 255 for an entry
        -- that an earlier session had read as level 67. Two different spells, one name, and every number
        -- after that point was about the wrong one.
        -- Me.Book(i).ID() is the spell that is actually in that slot. Ask about that.
        pcall(function() sid = tonumber(mq.TLO.Me.Book(i).ID()) or 0 end)
        if nm ~= '' and nm ~= 'NULL' and sid > 0 then
            if ep_spell_ok(nm) then
                -- RANK BY MaxLevel, NOT BY THE SPELL'S OWN LEVEL.
                -- MaxLevel is the ceiling - the highest mob this will hold - and it is the only number
                -- Smart Cast routes on. The spell's Level is what you needed to scribe it, and the two
                -- do not have to move together: Shela's book has a higher-Level placate whose CEILING is
                -- 76, alongside the one she had memmed that reaches 80. Picking by Level chose the 76
                -- and quietly cost the group its highest-capped caster.
                -- Level stays as the tie-break, so two ranks with the same ceiling still resolve to the
                -- later one.
                local cap, lvl = 0, 0
                pcall(function() cap = tonumber(mq.TLO.Spell(sid).MaxLevel()) or 0 end)
                pcall(function() lvl = tonumber(mq.TLO.Spell(sid).Level()) or 0 end)
                if cap > bestCap or (cap == bestCap and lvl > bestLvl) then
                    best, bestCap, bestLvl, epBestPlacateID = nm, cap, lvl, sid
                end
            end
        end
    end
    epBestPlacate = best or false
    if best then
        -- Both numbers, because they differ and the difference is the whole point of this choice.
        -- ID included: if two spells share a name, this is the one that decided the ceiling.
        rezlog('[placate] best placate in my book: %s [id %d] (ceiling %d, spell level %d)',
               best, epBestPlacateID or 0, bestCap, bestLvl)
    else
        epBestMissAt = mq.gettime()
        rezlog('\\ar[placate] no placate-line spell found in my spellbook - will look again in 30s\\ax')
    end
    return best
end

-- Put it in the chosen gem if it is not already there. /memspell overwrites, which is the point: the
-- user pointing at a gem IS the instruction that the gem is for placate.
function ep_ensure_gem()
    local have = ep_spell()
    local want = ep_best_placate()
    -- ACCEPT WHAT IS THERE ONLY IF NOTHING BETTER EXISTS. This returned true for any valid placate, so a
    -- gem holding a lower rank was left alone forever and the higher one in the book was never memmed.
    if have and ep_spell_ok(have) then
        if not want or want == have then return true end
        local hc, wc = 0, 0
        pcall(function() hc = tonumber(mq.TLO.Spell(have).MaxLevel()) or 0 end)
        pcall(function() wc = tonumber(mq.TLO.Spell(want).MaxLevel()) or 0 end)
        if wc <= hc then return true end
        rezlog('[placate] gem holds "%s" (ceiling %d) but "%s" reaches %d - upgrading', have, hc, want, wc)
    end
    if not want then return false end
    if epMemAt and (mq.gettime() - epMemAt) < 15000 then return false end   -- one attempt in flight
    epMemAt = mq.gettime()
    -- PAUSE E3 FOR THE MEM. This runs BEFORE ep_strip, so it is outside the pause that covers the rest
    -- of a placate run - meaning E3 was live for the one part that sits the character and opens a window.
    -- It will happily re-mem, stand, or start casting underneath us mid-memorise.
    -- Self-contained pause and resume: ep_strip takes its own immediately afterwards, and /e3p is
    -- idempotent, so the two cannot fight.
    ep_pause()
    -- DO NOT MEM INTO A LIVE E3. While E3 is paused it does no gem swapping at all, so the memorise is
    -- uncontested and takes first time. While it is running it will put its own spell straight back -
    -- Shela's gem 8 is her pet spell, and three ten-second attempts in a row failed for exactly that.
    -- The pause is verified rather than assumed: ep_pause has already waited for confirmation, so a
    -- false here means it genuinely did not take and memorising now is throwing the attempt away.
    -- Return WITHOUT resuming: the hold stays, and the next tick tries again against a paused E3.
    if e3_is_paused() == false then
        if (mq.gettime() - (epMemWaitSaid or 0)) > 5000 then
            epMemWaitSaid = mq.gettime()
            rezlog('\\ay[placate] E3 is not paused yet - holding the memorise rather than losing it\\ax')
        end
        return false
    end
    rezlog('[placate] gem %d holds %s - memming %s instead (%s)', ep_gem_num(),
           (have and ('"' .. have .. '"')) or 'nothing', want, e3_pause_note())
    pcall(function() mq.cmdf('/memspell %d "%s"', ep_gem_num(), want) end)
    mq.delay(10000, function() return (mq.TLO.Me.Gem(ep_gem_num()).Name() or '') == want end)
    local now = ''
    pcall(function() now = tostring(mq.TLO.Me.Gem(ep_gem_num()).Name() or '') end)
    if now ~= want then
        rezlog('\\ar[placate] could not mem %s into gem %d (it reads "%s")\\ax', want, ep_gem_num(), now)
        -- HOLD THE PAUSE ACROSS RETRIES. Releasing here and re-taking it on the next attempt produced
        -- three full pause/resume cycles in thirty seconds on Shela, and each release handed E3 a window
        -- to put its own spell straight back into the gem we were trying to use - so the retry was
        -- fighting a problem the retry itself kept recreating.
        -- The gem is contested here, which is exactly when E3 should stay held rather than be let go.
        -- Released after EP_MEM_TRIES consecutive failures, so a genuinely impossible mem cannot hold
        -- E3 down forever - and the backstops in ep_tick still cover the case where this is never
        -- reached again.
        epMemFails = (epMemFails or 0) + 1
        if epMemFails >= EP_MEM_TRIES then
            rezlog('\\ar[placate] giving up on the gem after %d tries - releasing E3\\ax', epMemFails)
            epMemFails = 0
            ep_resume('mem failed repeatedly')
        end
        return false
    end
    epMemFails = 0
    -- STAND UP AND SHUT THE BOOK. /memspell opens the spellbook and sits the character, and a cast
    -- attempted while sitting with the book open simply does not go out - so every placate after a mem
    -- was silently wasted until someone stood up by hand.
    -- /stand does both on this client. Verified rather than assumed: if it did not take, say so, because
    -- the alternative is a queue that looks like it is working and never casts.
    mq.cmd('/stand')
    mq.delay(1200, function()
        local sitting = true
        pcall(function() sitting = tlo_true(mq.TLO.Me.Sitting()) end)
        return not sitting and not mq.TLO.Window('SpellBookWnd').Open()
    end)
    local stillSitting, bookOpen = false, false
    pcall(function() stillSitting = tlo_true(mq.TLO.Me.Sitting()) end)
    pcall(function() bookOpen = (mq.TLO.Window('SpellBookWnd').Open() == true) end)
    if bookOpen then
        pcall(function() mq.TLO.Window('SpellBookWnd').DoClose() end)
        mq.delay(400, function() return not mq.TLO.Window('SpellBookWnd').Open() end)
    end
    if stillSitting or mq.TLO.Window('SpellBookWnd').Open() then
        rezlog('\\ay[placate] memmed %s but could not stand / close the book - the next cast may not go out\\ax', want)
    end
    -- LET THE CHARACTER SETTLE BEFORE THE FIRST CAST. Standing up and closing the book are actions the
    -- client takes a moment to finish, and the gem reads its name back before it is genuinely castable -
    -- so the cast went out into the tail of the memorise and did nothing. The gem timer alone does not
    -- catch this: it can read 0 while the client is still standing.
    -- ep_tick will not fire a placate until this has passed.
    epMemDoneAt = mq.gettime()
    -- E3 stays paused from here: the strip and the casting follow immediately, and ep_restore hands it
    -- back once the gear is on.
    rezlog('[placate] %s is memmed in gem %d', want, ep_gem_num())
    return true
end

-- CAST RANGE FOR PLACATE. Read from the spell, cached, exactly as the phantom line does.
-- This was missing entirely, and the 2026-08-03 log shows what that costs: a queue where the first three
-- mobs landed and the last three each burned three casts and were marked failed. Nothing was wrong with
-- them - they were simply further away, because they were clicked later while the group moved.
-- Three wasted casts per mob, and a red (--) against a mob that was never given a fair attempt.
EP_RANGE_FALLBACK = 200
-- How long a mob may sit out of reach before it is given up on. Long enough for a pull to close the
-- distance, short enough that one stuck mob cannot hold the gear off indefinitely.
-- HOW LONG A MOB CAN SIT OUT OF REACH BEFORE WE DROP IT. Ten seconds, not the forty-five it was.
-- The number is set by the spell, not by patience: placate lasts about 45 seconds, so waiting 45 for
-- the mob to come into range spends the entire duration getting there - the cast lands as it expires.
-- Ten keeps most of it. It is also ten seconds of standing stripped instead of forty-five, and the
-- group has usually moved on by then anyway.
-- The safe direction is short: dropping a mob costs one cast, and Smart Cast will re-queue it the
-- moment it is reachable again. Holding one costs the whole placate AND the weapons.
EP_FAR_MAX = 10000
epRangeCache = nil
function ep_range()
    if epRangeCache then return epRangeCache end
    -- TAKE THE RANGE STRAIGHT OFF A DETRIMENTAL SPELL. They all share the same 200 base and they DO
    -- report the focus, so whatever one of them says is simply the answer - no ratio, no arithmetic on
    -- top of a base that may or may not already include it.
    -- The maths version got this wrong twice: once by feeding Location into the base, and once by
    -- multiplying a MyRange that had already had the focus applied. Both produced a confident number
    -- past 400. Reading a spell that answers correctly avoids the whole class of error.
    -- Placate itself is excluded: it is the one that does NOT report its focus, which is why this exists.
    local sp = ep_spell()
    local best, from = 0, nil
    for g = 1, 12 do
        local gn = ''
        pcall(function() gn = tostring(mq.TLO.Me.Gem(g).Name() or '') end)
        if gn ~= '' and gn ~= 'NULL' and gn ~= sp then
            local ben = true
            -- tlo_true, NOT a raw string compare. This TLO comes back as a Lua boolean, so tostring gives
                -- 'true' and the old test against 'TRUE' was false for every spell in the book - which
                -- meant nothing was ever treated as beneficial and the filter below let heals through.
                -- Ejtou read her placate range off Desperate Renewal, a HEAL, and got 279; she then fired
                -- at mobs past placate's real reach and logged them as 'would not land'. Shela and
                -- Antilerd happened to have a detrimental as their longest and looked fine.
                pcall(function() ben = tlo_true(mq.TLO.Spell(gn).Beneficial()) end)
            if not ben then
                local mr = 0
                pcall(function() mr = tonumber(mq.TLO.Spell(gn).MyRange()) or 0 end)
                if mr > best then best, from = mr, gn end
            end
        end
    end
    if best > 0 then
        epRangeCache = best
        rezlog('[placate] cast range %d, read from %s', best, from)
        return best
    end
    -- No detrimental memmed to ask. Fall back to placate's own reading, unfocused though it is - short
    -- is the safe direction, since it only makes the queue wait rather than fire at something unreachable.
    local r = 0
    if sp then
        pcall(function() r = tonumber(mq.TLO.Spell(sp).MyRange()) or 0 end)
        if r <= 0 then pcall(function() r = tonumber(mq.TLO.Spell(sp).Range()) or 0 end) end
    end
    if r > 0 then
        rezlog('[placate] no detrimental memmed to read a focused range from - using %d unfocused', r)
        return r
    end
    return EP_RANGE_FALLBACK
end
-- BOTH THE GEM AND THE SPELL. GemTimer reaching 0 says the GEM's refresh is done; SpellReady says the
-- spell can actually be cast, and they disagree for about a second. The port work caught it on a log:
-- GemTimer=0 SpellReady=false, then a second later SpellReady=true - and casting on the timer alone went
-- out early every single time.
-- Placate had the same blind spot and it is harder to see there: a cast into that window fails quietly,
-- looks like a resist, and the retry covers it up.
-- SpellReady is only consulted once the timer is at 0. On its own it is useless here - it reads false
-- through every global cooldown, which is why the DI ladder and the bard buttons had to stop using it as
-- a standalone signal.
function ep_gem_ready()
    local t = -1
    pcall(function() t = tonumber(mq.TLO.Me.GemTimer(ep_gem_num()).TotalSeconds()) or -1 end)
    if t ~= 0 then return false end
    local sp, rdy = ep_spell(), false
    if not sp or sp == '' then return true end   -- nothing to ask about; the timer is all we have
    pcall(function() rdy = tlo_true(mq.TLO.Me.SpellReady(sp)()) end)
    return rdy
end

-- A ONE-LINE SNAPSHOT OF THE QUEUE, logged whenever it CHANGES. Reports of placate "jumping around the
-- list" are impossible to chase from the cast lines alone: those say what was targeted, not what the
-- queue looked like when it chose. This prints the whole thing with every state, so a session log can be
-- read back as a sequence rather than inferred from which mob happened to be cast at.
-- Change-gated, not every tick, so it costs nothing when the queue is stable.
epQueueSig = ''
function ep_queue_log(why)
    local parts = {}
    for i, e in ipairs(epQueue) do
        -- ID as well as name. A zone full of lavaspinners produces a queue of identically-named
        -- entries, and a log that cannot tell two of them apart is a log that makes the queue look like
        -- it jumped backwards when it did nothing of the sort.
        parts[#parts + 1] = string.format('%d:%s#%d=%s', i, (e.name or '?'):sub(1, 14),
                                          e.id or 0, e.state or 'pending')
    end
    local sig = table.concat(parts, ' | ')
    if sig == epQueueSig then return end
    epQueueSig = sig
    rezlog('[placate] queue (%s): %s', why or 'changed', (sig ~= '') and sig or '(empty)')
end

function ep_find(id)
    for i, e in ipairs(epQueue) do if e.id == id then return i, e end end
    return nil
end

-- Tell Smart Cast how it went, so the shared queue shows the outcome rather than sitting on 'assigned'.
function pac_reflect(id, state)
    local _, e = pac_find(id)
    if e and not e.state then
        e.state = state
        e.oor, e.oorSince, e.oorDist = false, nil, nil
        pcall(function() peer_bcast('/at_pacmark %d %s', id, state) end)
    end
end

-- OUT OF RANGE IS A STATE, NOT A SILENCE.
-- Both casting queues already know when a mob is too far - they set their own `oor` flag and skip past
-- it - but that never left the caster. On the shared list the entry looked identical to one that had
-- been handed over and simply not acted on yet, so the only thing distinguishing "waiting for the group
-- to close" from "that caster is not running" was elapsed time. That is what PAC_OOR_MAX was inferring,
-- and inference is why it was set to the wrong thing twice.
-- Now the caster says so. `oor` is DELIBERATELY NOT a state: state means resolved and stops the entry
-- being worked, whereas out of range is temporary by definition - the group walks forward and it clears
-- itself. It is a flag alongside the state, not one of its values.
function pac_set_oor(e, oor, dist)
    if not e or e.state then return end
    if oor then
        -- The clock starts on the FIRST report and is not restarted by later ones, so a mob that has
        -- been unreachable for a minute does not look fresh because the caster mentioned it again.
        e.oorSince = e.oorSince or mq.gettime()
        e.oor, e.oorDist = true, dist
    else
        e.oor, e.oorSince, e.oorDist = false, nil, nil
    end
end

-- Called by the casting queues on a TRANSITION only - in or out - so this is not chatter on the wire.
function pac_reflect_oor(id, oor, dist)
    local _, e = pac_find(id)
    if not e or e.state then return end
    pac_set_oor(e, oor, dist)
    pcall(function() peer_bcast('/at_pacoor %d %d %d', id, oor and 1 or 0, math.floor(dist or 0)) end)
end

function ep_mark(id, state, why)
    local _, e = ep_find(id)
    if not e or e.state then return end
    e.state, e.oor = state, false
    rezlog('[placate] %s#%d - %s', e.name or '?', id or 0, why)
    pac_reflect(id, state)
    ep_queue_log('after mark')
    -- Local only, same reason. A mob belongs to exactly one caster now, so a peer has no entry to mark -
    -- and pac_reflect already reports the outcome to the shared pacify list, which is what the group
    -- actually reads. Two paths saying the same thing is how they end up disagreeing.
end

-- Strip the three slots. Records what was there first, INCLUDING empty, so the restore knows the
-- difference between "put the sword back" and "leave it empty".
-- Put whatever is on the cursor into a specific FREE BAG SLOT.
-- USED BY THE CURRENCY PULL TOO, not just the placate strip. That pull used /autoinventory and reported
-- "bags are full" on a character with plenty of room - the same failure the weapon strip had, where
-- /autoinventory decides for itself and can simply decline. Naming a destination slot removes the
-- decision. One implementation, so a fix here fixes both.
-- NOT /autoinventory: that returns an item to where it belongs, and for a weapon or a shield where it
-- belongs is the equipment slot we just took it out of. The 2026-08-02 log caught it exactly - "picked
-- up Staff of Ancient Eloquence, stowing" and 32ms later "still holds Staff of Ancient Eloquence". The
-- torch bagged fine because nothing wanted to equip it, which is why two of three slots failed and one
-- appeared to work.
-- Naming a destination slot removes the choice.
-- BAGS THAT WILL NOT TAKE A WEAPON. A tradeskill-only container reports free slots like any other bag,
-- so a stow aimed at one silently does nothing and the item stays on the cursor - which then reads as
-- "bags are full" and stops the run.
-- Checked by the container's own flag where the client offers one, and by name as a backstop, because
-- the flag is exactly the sort of thing that reads wrong on this build.
STOW_SKIP_BAGS = {
    ["artisan's adept attache"] = true,
}
function bag_usable(b)
    local slots = 0
    pcall(function() slots = tonumber(mq.TLO.Me.Inventory('pack' .. b).Container()) or 0 end)
    if slots <= 0 then return false, 0 end
    local nm = ''
    pcall(function() nm = tostring(mq.TLO.Me.Inventory('pack' .. b).Name() or '') end)
    if nm ~= '' and STOW_SKIP_BAGS[nm:lower()] then return false, slots end
    -- Some clients expose this directly. Treated as advisory: a true here is trusted, a nil is ignored.
    local tsOnly = false
    pcall(function() tsOnly = (tostring(mq.TLO.Me.Inventory('pack' .. b).TradeskillsOnly()) == 'TRUE') end)
    if tsOnly then return false, slots end
    return true, slots
end

function ep_stow_cursor()
    if (mq.TLO.Cursor.ID() or 0) == 0 then return true end
    for b = 1, 10 do
        local usable, slots = bag_usable(b)
        if usable then
            for sl = 1, slots do
                local occupied = true
                pcall(function()
                    occupied = (tonumber(mq.TLO.Me.Inventory('pack' .. b).Item(sl).ID()) or 0) > 0
                end)
                if not occupied then
                    pcall(function() mq.cmdf('/itemnotify in pack%d %d leftmouseup', b, sl) end)
                    mq.delay(600, function() return (mq.TLO.Cursor.ID() or 0) == 0 end)
                    if (mq.TLO.Cursor.ID() or 0) == 0 then return true end
                end
            end
        end
    end
    rezlog('\\ar[placate] no free bag slot to stow %s - putting it back\\ax',
           tostring(mq.TLO.Cursor.Name() or '?'))
    clear_cursor()   -- last resort: let the game decide rather than leave it on the cursor
    return false
end

-- RE-ENTRANT ON PURPOSE, up to EP_STRIP_PASSES. Conceding a slot after three pickup attempts and then
-- refusing to cast because that slot is occupied is a deadlock: the strip will not try again and the
-- cast guard will not relent, so the run spins until the 180s backstop tears it down and the next run
-- walks into the same wall. Observed on Shela 2026-08-05 - the offhand needed three attempts and got
-- them, the mainhand needed a fourth and did not.
-- Re-running is safe as long as epSaved is not clobbered: a slot stripped on pass one now reads empty,
-- and overwriting its saved name with '' would lose the item's identity for the restore.
EP_STRIP_PASSES = 3
epStripPass     = 0
epNotReadyAt    = 0

epCursorSaidAt = 0

function ep_strip()
    if epSaved then
        local stuck = false
        for _, sl in ipairs(EP_SLOTS) do
            local w = ''
            pcall(function() w = tostring(mq.TLO.Me.Inventory(sl).Name() or '') end)
            if w ~= '' then stuck = true; break end
        end
        if not stuck then return true end
        if epStripPass >= EP_STRIP_PASSES then return true end   -- caller decides what to do about it
        epStripPass = epStripPass + 1
        rezlog('[placate] a slot is still equipped - strip pass %d of %d', epStripPass, EP_STRIP_PASSES)
    else
        epSaved, epStripAt, epStripPass = {}, mq.gettime(), 1
    end
    -- PAUSE E3 FOR THE WHOLE RUN. Everything from here to the re-equip is cursor work and casting, and a
    -- live E3 grabs the cursor, re-targets and re-equips underneath it - it will happily put the weapons
    -- straight back on while we are trying to take them off, and re-target mid-placate.
    -- Bracketed by strip/restore on purpose: those two are already paired, and every way out of a placate
    -- run goes through ep_restore - queue finished, the stripped-too-long backstop, /atregear, and the
    -- script exiting. So there is no path that pauses E3 without something later resuming it.
    -- /e3p on = paused, /e3p off = E3 driving. Backwards-looking, but it is E3's naming, not ours.
    ep_pause()
    -- REMEMBER THE TARGET ONCE, not per mob. The verification step targets each mob to read the debuff
    -- off it, and it used to put the previous target back straight afterwards - then target the next mob
    -- a second later and restore again. Two extra target switches per mob, each with a settle wait, for
    -- a target nobody looks at until the queue is done. And when the enchanter was self-targeted, which
    -- casters usually are, the restore meant visibly re-targeting yourself between every placate.
    -- One save here, one restore at the end.
    epPrevTarget = 0
    pcall(function() epPrevTarget = tonumber(mq.TLO.Target.ID()) or 0 end)
    rezlog('[placate] %s; stripping weapons before the first cast...', e3_pause_note())
    -- Record BEFORE removing anything. Written first so a crash between the read and the click still
    -- leaves a file naming what should be worn - the opposite order would lose exactly the case this
    -- exists for.
    for _, slot in ipairs(EP_SLOTS) do
        local nm0 = ''
        pcall(function() nm0 = tostring(mq.TLO.Me.Inventory(slot).Name() or '') end)
        -- Only record it the first time. On a re-strip pass an already-removed slot reads empty, and
        -- writing that over the saved name is how the restore forgets what to put back.
        if (epSaved[slot] or '') == '' then epSaved[slot] = nm0 end
    end
    ep_recovery_write()
    for _, slot in ipairs(EP_SLOTS) do
        local nm = ''
        pcall(function() nm = tostring(mq.TLO.Me.Inventory(slot).Name() or '') end)
        if (epSaved[slot] or '') == '' then epSaved[slot] = nm end   -- never clobber on a re-strip pass
        -- SAY WHAT WE READ AND WHAT WE DID, per slot. Two attempts at this have failed silently: first
        -- because the slot names were wrong and every read came back empty, then again for a reason the
        -- logs could not show because nothing logged the intermediate steps. A strip that does nothing
        -- must not look identical to a strip that had nothing to do.
        if nm == '' then
            rezlog('[placate]   %s: reads empty - nothing to take off', slot)
        else
            -- VERIFY EVERY STEP, one slot at a time. This used to fire the commands and check the slot
            -- afterwards, which is fast and wrong: the client can be mid-move when the next command
            -- arrives, and three items going through one cursor is exactly where that bites.
            -- Pick up -> confirm THE RIGHT ITEM is on the cursor -> stow -> confirm the cursor is empty.
            -- Slower by a fraction of a second per item, against an epic in the wrong place.
            clear_cursor()
            mq.delay(400, function() return (mq.TLO.Cursor.ID() or 0) == 0 end)
            if (mq.TLO.Cursor.ID() or 0) ~= 0 then
                rezlog('\\ar[placate]   %s: cursor will not clear before pickup - skipping this slot\\ax', slot)
                goto continue_slot
            end

            -- SIX, NOT THREE. The offhand took three attempts on Shela and the mainhand ran out of
            -- budget at three - the pickup is flaky timing rather than a refusal, so the fix is to keep
            -- asking. Costs nothing when the first attempt works, which is the normal case.
            local picked = false
            for tryN = 1, 6 do
                pcall(function() mq.cmdf('/itemnotify %s leftmouseup', slot) end)
                mq.delay(900, function()
                    return tostring(mq.TLO.Cursor.Name() or '') == nm
                end)
                if tostring(mq.TLO.Cursor.Name() or '') == nm then picked = true; break end
                rezlog('[placate]   %s: pickup did not take, retry %d of 6', slot, tryN)
                mq.delay(400)
            end
            if not picked then
                local got = tostring(mq.TLO.Cursor.Name() or '')
                rezlog('\\ar[placate]   %s: wanted %s on the cursor, got "%s" - leaving it equipped\\ax',
                       slot, nm, (got ~= '') and got or 'nothing')
                clear_cursor()
                goto continue_slot
            end
            rezlog('[placate]   %s: picked up %s, stowing', slot, nm)

            local stowed = false
            for tryN = 1, 3 do
                ep_stow_cursor()   -- into a bag slot by name, never /autoinventory
                mq.delay(700, function() return (mq.TLO.Cursor.ID() or 0) == 0 end)
                if (mq.TLO.Cursor.ID() or 0) == 0 then stowed = true; break end
                rezlog('[placate]   %s: stow did not take, retry %d of 3', slot, tryN)
                mq.delay(300)
            end
            if not stowed then
                rezlog('\\ar[placate]   %s: %s is stuck on the cursor - putting it back on\\ax', slot, nm)
                pcall(function() mq.cmdf('/itemnotify %s leftmouseup', slot) end)
                mq.delay(700)
                clear_cursor()
                goto continue_slot
            end

            mq.delay(200)      -- let the equipment slot catch up before we judge it
            local after = ''
            pcall(function() after = tostring(mq.TLO.Me.Inventory(slot).Name() or '') end)
            if after ~= '' then
                rezlog('\\ar[placate]   %s: still holds %s after the attempt\\ax', slot, after)
            end
        end
        ::continue_slot::
    end
    -- Say what actually came off, not what we intended to take off. The previous line announced all
    -- three unconditionally, which is how a strip that removed nothing still read as a success.
    local took, kept = {}, {}
    for _, slot in ipairs(EP_SLOTS) do
        local now = ''
        pcall(function() now = tostring(mq.TLO.Me.Inventory(slot).Name() or '') end)
        if (epSaved[slot] or '') ~= '' and now == '' then took[#took + 1] = epSaved[slot]
        elseif (epSaved[slot] or '') ~= '' then kept[#kept + 1] = slot end
    end
    if #took > 0 then
        rezlog('[placate] stripped %s so augment procs cannot break the placate', table.concat(took, ', '))
    else
        rezlog('[placate] nothing to strip - all three slots were already empty')
    end
    if #kept > 0 then
        rezlog('\\ar[placate] could NOT remove: %s - a proc from those may break the placate\\ax',
               table.concat(kept, ', '))
    end
    -- CONFIRM EACH ITEM IS FINDABLE BEFORE WE GO ANYWHERE. Taking something off is only half of it - the
    -- restore puts it back by NAME, so an item that came off but cannot be found again is already lost
    -- at this point, and we would not learn that until the run ended.
    -- Checking here means the failure is reported while the cause is still on screen.
    local lost = {}
    for _, slot in ipairs(EP_SLOTS) do
        local want = epSaved[slot] or ''
        if want ~= '' then
            local held = 0
            pcall(function() held = tonumber(mq.TLO.FindItemCount('=' .. want)()) or 0 end)
            local worn = ''
            pcall(function() worn = tostring(mq.TLO.Me.Inventory(slot).Name() or '') end)
            if held < 1 and worn ~= want then lost[#lost + 1] = want end
        end
    end
    if #lost > 0 then
        rezlog('\\ar[placate] STRIPPED BUT CANNOT FIND: %s - stopping before casting\\ax',
               table.concat(lost, ', '))
        pcall(function() mq.cmdf('/gsay AdventureTime: cannot find %s after stripping - stopping',
                                 table.concat(lost, ', ')) end)
        ep_restore('lost an item during the strip')   -- put back whatever we still can, at once
        return false
    end
    return true
end

-- Put everything back. Safe to call at any time, including when nothing was stripped.
function ep_restore(why)
    if not epSaved then
        -- Nothing was stripped, but the mem may still have paused E3 - release it either way.
        ep_resume(why or 'nothing to restore')
        return
    end
    -- BAGS OPEN FOR THE WHOLE RESTORE. The strip stows each weapon into a named bag slot, and putting it
    -- back means finding it by name - which is not reliable with the bags shut. The strip already opens
    -- them for its own work; the restore never did, which is how a run could report success with an epic
    -- still sitting in a bag.
    toggle_all_bags()
    for _, slot in ipairs(EP_SLOTS) do
        local original = epSaved[slot] or ''
        local now = ''
        pcall(function() now = tostring(mq.TLO.Me.Inventory(slot).Name() or '') end)
        if now ~= original then
            -- SAME VERIFY-EACH-STEP AS THE STRIP, in reverse. Pick it up, confirm the RIGHT item is on the
            -- cursor, seat it, confirm the slot reads it back. Firing the two commands and hoping is what
            -- let a run finish with a weapon still sitting in a bag.
            clear_cursor()
            mq.delay(400, function() return (mq.TLO.Cursor.ID() or 0) == 0 end)
            if original ~= '' then
                local held = false
                for tryN = 1, 3 do
                    pcall(function() mq.cmdf('/itemnotify "%s" leftmouseup', original) end)
                    mq.delay(900, function() return tostring(mq.TLO.Cursor.Name() or '') == original end)
                    if tostring(mq.TLO.Cursor.Name() or '') == original then held = true; break end
                    rezlog('[placate]   %s: could not pick up %s, retry %d of 3', slot, original, tryN)
                    mq.delay(300)
                end
                if held then
                    for tryN = 1, 3 do
                        pcall(function() mq.cmdf('/itemnotify %s leftmouseup', slot) end)
                        mq.delay(900, function()
                            return (mq.TLO.Me.Inventory(slot).Name() or '') == original
                        end)
                        local seated = ''
                        pcall(function() seated = tostring(mq.TLO.Me.Inventory(slot).Name() or '') end)
                        if seated == original then break end
                        rezlog('[placate]   %s: %s did not seat, retry %d of 3', slot, original, tryN)
                        mq.delay(300)
                    end
                else
                    rezlog('\\ar[placate]   %s: %s is not findable in bags\\ax', slot, original)
                end
            end
            ep_stow_cursor()
        end
    end
    -- SECOND AND THIRD ATTEMPT. One pass was enough when it worked and silent when it did not; a
    -- weapon that failed to seat first time usually seats on a retry, and the cost of trying twice more
    -- is a second against the cost of walking around without an epic.
    -- KEEP TRYING WHILE E3 IS STILL HELD. Two attempts then resume regardless meant the pause ended
    -- with a weapon in a bag - E3 came back, the character carried on, and nothing else was ever going
    -- to put it on. Six rounds instead, and the verify below decides when we stop rather than a count.
    -- Bounded rather than infinite: an item that cannot be equipped at all (wrong zone, cursed, gone)
    -- would otherwise hold E3 down forever, which is worse than fighting a weapon short.
    for attempt = 2, 6 do
        local anyMissing = false
        for _, slot in ipairs(EP_SLOTS) do
            local original = epSaved[slot] or ''
            local now = ''
            pcall(function() now = tostring(mq.TLO.Me.Inventory(slot).Name() or '') end)
            if now ~= original and original ~= '' then
                anyMissing = true
                clear_cursor()
                pcall(function() mq.cmdf('/itemnotify "%s" leftmouseup', original) end)
                mq.delay(700, function() return (mq.TLO.Cursor.ID() or 0) ~= 0 end)
                if (mq.TLO.Cursor.ID() or 0) ~= 0 then
                    pcall(function() mq.cmdf('/itemnotify %s leftmouseup', slot) end)
                    mq.delay(900, function()
                        return (mq.TLO.Me.Inventory(slot).Name() or '') == original
                    end)
                end
                ep_stow_cursor()
            end
        end
        if not anyMissing then break end
        rezlog('[placate] re-equip attempt %d of 6', attempt)
        mq.delay(300)   -- let the client settle between passes rather than hammering it
    end

    toggle_all_bags()   -- back as we found them, before the final check

    -- THE CHECK THAT MATTERS: read every slot again, right here, immediately before E3 is handed back.
    -- Everything above reports what it BELIEVES it did; this reads what is actually worn.
    local missed = {}
    for _, slot in ipairs(EP_SLOTS) do
        local original = epSaved[slot] or ''
        local now = ''
        pcall(function() now = tostring(mq.TLO.Me.Inventory(slot).Name() or '') end)
        if now ~= original then
            missed[#missed + 1] = string.format('%s (want "%s", have "%s")',
                slot, (original ~= '') and original or 'nothing',
                (now ~= '') and now or 'nothing')
        end
    end
    if #missed > 0 then
        -- LOUD, and the file STAYS. This is the case that cost an epic: the run said it was done, E3 came
        -- back, and the weapon sat in a bag with nothing left that knew about it.
        -- Said three ways because one line in a busy log is exactly what got missed - the group is told
        -- as well, since the person is usually looking at the game and not at a log file.
        rezlog('\\ar[placate] GEAR NOT RESTORED: %s\\ax', table.concat(missed, ', '))
        rezlog('\\ar[placate] recorded in %s - it will be retried on the next start, or type /atregear\\ax',
               ep_recovery_path())
        pcall(function() mq.cmdf('/gsay AdventureTime: my gear did NOT go back on - %s',
                                 table.concat(missed, ', ')) end)
        -- E3 IS COMING BACK ANYWAY, and that is deliberate: holding it down indefinitely turns a missing
        -- weapon into a character that does nothing at all. But say so, so the state is not a surprise.
        rezlog('\\ar[placate] handing E3 back with gear still off - fix it and /atregear\\ax')
    else
        ep_recovery_clear()   -- verified back on: the record has done its job
        rezlog('[placate] re-equipped %s (%s)', table.concat(EP_SLOTS, ', '), why or 'done')
    end
    -- KEEP the record when something is still off. Clearing it on failure threw away the one thing that
    -- knew what should be worn, so a second /atregear in the same session had nothing to work from.
    if #missed == 0 then
        epSaved, epStripAt = nil, 0
    else
        epStripAt = mq.gettime()   -- restart the backstop clock so it tries again rather than firing at once
    end
    -- Put the original target back, once, now the whole queue is done.
    if epPrevTarget and epPrevTarget > 0 then
        local cur = 0
        pcall(function() cur = tonumber(mq.TLO.Target.ID()) or 0 end)
        if cur ~= epPrevTarget then
            pcall(function() mq.cmdf('/target id %d', epPrevTarget) end)
        end
    end
    epPrevTarget = 0
    -- Hand the toon back. Last thing, after the gear is actually on - resuming earlier would let E3
    -- start driving while items are still moving.
    ep_resume(why or 'gear restored')
end

-- Runs on every toon; returns immediately on anyone who is not an enchanter. Main loop only - it
-- equips, unequips and casts, none of which belongs anywhere near an ImGui callback.
-- SOAK TEST FOR THE STRIP/RESTORE CYCLE. Run before trusting this on anyone else's characters: the
-- failure being looked for is an item that comes off and does not come back - a desync where the client
-- and server disagree about where a weapon is - and that is not something to discover on a stranger.
-- Checks the things that would actually constitute losing a weapon, not just that the commands ran:
--   * after the strip, is the item findable in the BAGS (not merely absent from the slot)
--   * after the restore, is it back in the SAME slot it started in
-- ABORTS on the first failure rather than looping - if something has gone wrong with an item, doing it
-- nine more times is the worst available response.
epTestRuns = 0
epTestOK   = 0
function ep_soak_test(times)
    -- ENCHANTER ONLY, like the real thing. ep_tick is gated on class so the placate strip can only ever
    -- touch an enchanter - but this command called ep_strip directly, so /atplacatetest on a monk would
    -- have taken a monk's weapons off. A test that can do the damage it exists to rule out is no good.
    if not ep_is_enchanter() then
        log('\\ay[placate test] placate is an enchanter/cleric routine - not stripping a %s\\ax',
            tostring(mq.TLO.Me.Class.ShortName() or '?'))
        return
    end
    times = math.max(1, math.min(50, math.floor(tonumber(times) or 10)))
    if epSaved then
        log('\\ay[placate test] weapons are already stripped - run /atregear first\\ax')
        return
    end
    local start = {}
    for _, slot in ipairs(EP_SLOTS) do
        local nm = ''
        pcall(function() nm = tostring(mq.TLO.Me.Inventory(slot).Name() or '') end)
        start[slot] = nm
    end
    log('[placate test] %d cycles. Starting gear:', times)
    for _, slot in ipairs(EP_SLOTS) do
        log('   %-9s %s', slot, start[slot] ~= '' and start[slot] or '(empty)')
    end

    epTestRuns, epTestOK = 0, 0
    for i = 1, times do
        epTestRuns = i
        local fault = nil

        ep_strip()
        -- Every item we took off must be findable in the bags. "Not in the slot" is not good enough -
        -- that is also what a vanished item looks like.
        for _, slot in ipairs(EP_SLOTS) do
            local want = start[slot]
            if want ~= '' then
                local still = ''
                pcall(function() still = tostring(mq.TLO.Me.Inventory(slot).Name() or '') end)
                local inBags = 0
                pcall(function() inBags = tonumber(mq.TLO.FindItemCount('=' .. want)()) or 0 end)
                if still ~= '' then fault = string.format('%s still equipped (%s)', slot, still)
                elseif inBags < 1 then fault = string.format('%s: %s is NOT in bags after stripping', slot, want) end
            end
        end

        if not fault then
            mq.delay(3000)
            ep_restore('soak test')
            mq.delay(500)
            for _, slot in ipairs(EP_SLOTS) do
                local want = start[slot]
                local now = ''
                pcall(function() now = tostring(mq.TLO.Me.Inventory(slot).Name() or '') end)
                if now ~= want then
                    fault = string.format('%s reads "%s", expected "%s"', slot,
                                          now ~= '' and now or '(empty)', want ~= '' and want or '(empty)')
                end
            end
        end

        if fault then
            log('\\ar[placate test] cycle %d FAILED: %s\\ax', i, fault)
            log('\\ar[placate test] stopping here so nothing is made worse. Check your gear.\\ax')
            ep_restore('test aborted')
            break
        end
        epTestOK = epTestOK + 1
        log('[placate test] cycle %d/%d ok', i, times)
        if i < times then mq.delay(3000) end
    end
    log('[placate test] %d of %d cycles clean.', epTestOK, epTestRuns)
    if epTestOK == epTestRuns and epTestRuns > 0 then
        log('\\ag[placate test] no desyncs seen.\\ax')
    end
end

function ep_tick()
    if not ep_is_enchanter() then return end
    -- ANYTHING ON THE CURSOR STOPS THE WHOLE TICK. The per-cast checks below catch it at the moment of
    -- casting, but by then the run may already have stripped gear or targeted a mob - and an item held
    -- while any of that happens is how it gets put somewhere nobody expects.
    -- Checked first, before anything is touched.
    --
    -- IT USED TO JUST STAND DOWN, on the reasoning that whatever is on the cursor got there for a reason
    -- and is not ours to move. In practice what is on it is a heal orb the group's own healing put there:
    -- Ejtou held Orb of the Sanguine and refused to placate for as long as it sat on her cursor, because
    -- unlike Shela and Ehaba she has no OrbInv=/autoinventory event to stow it. Standing down forever
    -- over a potion that belongs in a bag is worse than putting it in the bag.
    -- So: TRY TO STOW IT FIRST. /autoinventory only ever moves the item to a free bag slot - it does not
    -- destroy anything and it does not choose where things go beyond that - so the cost of being wrong
    -- is an item in a bag rather than on the cursor.
    -- If it will NOT stow - bags full, or something the client refuses to put away - fall back to exactly
    -- the old behaviour and stand down, because then it really is stuck and worth stopping for.
    --
    -- ONLY WHEN THERE IS SOMETHING TO CAST AT. This used to run on every pulse of every tick, so simply
    -- HAVING placate enabled meant an /autoinventory every three seconds for as long as anything sat on
    -- the cursor - stowing loot, gems and shards all day for a queue that was empty. The cursor is only
    -- our business when we are about to act on this character; the rest of the time what is held is the
    -- player's, or E3's, and none of ours to move.
    local epWork = false
    for _, q in ipairs(epQueue) do if not q.state then epWork = true; break end end
    if epWork and (mq.TLO.Cursor.ID() or 0) ~= 0 then
        local held = tostring(mq.TLO.Cursor.Name() or '?')
        -- Rate limited so a genuinely stuck cursor does not mean an /autoinventory every pulse.
        if (mq.gettime() - (epCursorTryAt or 0)) > 3000 then
            epCursorTryAt = mq.gettime()
            pcall(function() mq.cmd('/autoinventory') end)
            mq.delay(600, function() return (mq.TLO.Cursor.ID() or 0) == 0 end)
        end
        if (mq.TLO.Cursor.ID() or 0) ~= 0 then
            if (mq.gettime() - (epCursorSaidAt or 0)) > 5000 then
                epCursorSaidAt = mq.gettime()
                rezlog('\\ay[placate] holding off - %s will not stow off the cursor (bags full?)\\ax', held)
            end
            return
        end
        rezlog('[placate] stowed %s off the cursor', held)
    end
    -- BACKSTOP FIRST, before anything else can return early. Being stripped is a state with a real cost -
    -- an enchanter with no weapons is an enchanter not meleeing and not proccing anything useful - and a
    -- queue that stalls on an unreachable mob would otherwise leave them that way indefinitely.
    if epSaved and (mq.gettime() - epStripAt) > EP_STRIP_MAX then
        ep_restore('backstop - stripped too long')
    end
    -- SECOND BACKSTOP, for the pause without a strip. The mem takes the pause before anything is
    -- removed, so a run that memmed and then found nothing to cast at - mob died, queue cleared, gem
    -- emptied - would leave E3 held with epSaved never set, and the backstop above cannot see it.
    -- If we are paused, holding nothing, with no cast in flight and no work queued, let go.
    if epPaused and not epSaved and not epCast then
        local pending, casting = 0, false
        for _, q in ipairs(epQueue) do if not q.state then pending = pending + 1 end end
        -- Same reason as the queue-finished release: epCast being nil does not prove nothing is being
        -- cast, only that we have stopped tracking it.
        pcall(function() casting = (tonumber(mq.TLO.Me.Casting.ID()) or 0) > 0 end)
        if pending == 0 and not casting then ep_resume('nothing left to do') end
    end

    -- CLEARING IS THE TICK'S JOB, not the panel's - the same fault the phantom queue had.
    -- This lived only inside the placate panel's draw, so it ran only on a character with that
    -- window open. Every
    -- headless worker accumulated resolved entries forever: Ejtou's queue grew 1, 2, 3, 4 with every
    -- entry already done or failed, and the stand-down line kept reporting a queue that should have
    -- emptied minutes earlier.
    if #epQueue > 0 then
        local pend = 0
        for _, q in ipairs(epQueue) do if not q.state then pend = pend + 1 end end
        if pend == 0 then
            epDoneAt = epDoneAt or mq.gettime()
            local hold = (#epQueue == 1) and 10000 or EP_LINGER
            if (mq.gettime() - epDoneAt) > hold then
                epQueue, epDoneAt = {}, nil
                -- NOT BROADCAST ANY MORE. epQueue used to be one shared list every capable caster held a
                -- copy of, so clearing it everywhere was the point. Since the manual queue went, it is
                -- THIS character's assigned work - and telling the group to clear meant Ejtou finishing
                -- her mob wiped Shela's queue mid-cast, dropping a second mob she had been given and
                -- ending the run early. Each character clears its own.
                ep_queue_log('linger expired')
            end
        else
            epDoneAt = nil
        end
    end

    -- THE ELECTION IS GONE. It decided which of several capable casters worked the SHARED queue, which
    -- only ever existed for the manual Placate button. Smart Cast assigns every mob to exactly one
    -- caster by ceiling and load, so the collision the election prevented cannot happen, and the
    -- election itself caused two real failures: it silently refused mobs Smart Cast had assigned, and
    -- standing down left a character stripped with E3 paused for three minutes.
    -- Everything in epQueue is now, by construction, work addressed to this character.

    if epCast then
        -- PLACATE HAS A CAST TIME, so nothing can be concluded while it is still going out. This used to
        -- read the gem timer immediately and call the job done the moment it moved, which reported a
        -- success before the spell had even finished being cast.
        local casting = false
        pcall(function() casting = (tonumber(mq.TLO.Me.Casting.ID()) or 0) > 0 end)
        if casting then
            epCast.sawCast = true
            -- WATCH THE CURSOR THROUGH THE CAST, not only before it.
            -- Everything else checks at a moment: tick start, before the strip, before a retry. The cast
            -- itself is the longest window in the whole run and was the one nobody was watching - the
            -- tick returned here immediately on every pulse while a spell was going out. A heal orb,
            -- a summoned item, a trade landing in that window put an item on the cursor with a cast
            -- already in flight, which is how it ends up somewhere nobody expects.
            -- STOP THE CAST FIRST, then stow. Order matters: stowing while the spell is still going out
            -- leaves the same race open a moment longer, and the cast is the thing we can cancel.
            -- The retry costs nothing here - see freeRetry below - because being interrupted is not the
            -- same as being resisted, and it was not this mob's fault.
            if (mq.TLO.Cursor.ID() or 0) ~= 0 then
                local held = tostring(mq.TLO.Cursor.Name() or '?')
                pcall(function() mq.cmd('/stopcast') end)
                mq.delay(400, function() return (tonumber(mq.TLO.Me.Casting.ID()) or 0) == 0 end)
                local ok = cursor_stow('placate')
                rezlog('\\ay[placate] %s appeared on the cursor mid-cast at %s - stopped the cast%s\\ax',
                       held, epCast.name or '?', ok and ' and stowed it' or ' (it will NOT stow)')
                epCast.freeRetry = true
            end
            return
        end

        -- Then LOOK. A resist is not a failure to cast - the gem still cycles, the cast still completes -
        -- so the only way to tell a landed placate from a resisted one is to look at the mob. Target it
        -- briefly, read the debuff, and put the previous target straight back.
        -- A beat after the cast ends, because the debuff does not appear on the same frame.
        if (mq.gettime() - epCast.at) < EP_CHECK_AFTER then return end

        -- RE-TARGET IF IT MOVED, then read. "E3 is paused so nothing moves the target" was wrong: the
        -- cast ITSELF goes out through E3 via /nowcast, and E3 targets to cast. So the target had almost
        -- always moved by the time we looked, the read was skipped, and a placate that had landed
        -- perfectly well was recast - three times, then marked as a failure. 1180 placate lines in one
        -- session, most of them re-doing work.
        -- Cheap to fix and cheap to run: one target call, only when it is not already on the mob.
        if (tonumber(mq.TLO.Target.ID()) or 0) ~= epCast.id then
            pcall(function() mq.cmdf('/target id %d', epCast.id) end)
            mq.delay(600, function() return (tonumber(mq.TLO.Target.ID()) or 0) == epCast.id end)
        end
        local landed = false
        if (tonumber(mq.TLO.Target.ID()) or 0) == epCast.id then
            local sp = ep_spell()
            if sp then
                local has = false
                pcall(function() has = (tonumber(mq.TLO.Target.Buff(sp).ID()) or 0) > 0 end)
                if not epCast.hadBuff then
                    -- It had none before, so its having one now is our cast and nothing else.
                    landed = has
                elseif has then
                    -- IT ALREADY HAD ONE. Presence proves nothing here - it was true before we cast. The
                    -- honest signal is the DURATION going back up, which only a landed refresh does.
                    local dur = 0
                    pcall(function() dur = tonumber(mq.TLO.Target.Buff(sp).Duration.TotalSeconds()) or 0 end)
                    if dur > (epCast.preDur or 0) + 2 then
                        landed = true
                    else
                        -- Duration unreadable or not yet updated: fall back to the cast having actually
                        -- COMPLETED. sawCast means we watched it go out, and Casting clearing means it is
                        -- finished - which is the thing we were concluding without ever checking.
                        local casting = false
                        pcall(function() casting = (tonumber(mq.TLO.Me.Casting.ID()) or 0) > 0 end)
                        landed = epCast.sawCast and not casting
                    end
                end
            end
        else
            -- STILL NOT ON IT. Do not assume either way - keep trying. Assuming it landed marks a mob
            -- placated that may not be; assuming it failed re-casts one that already is. Both are guesses
            -- and the mob is right there to be read.
            -- Is it even still alive? A dead or despawned mob is the one case with a real answer.
            local ty, hp = '', 0
            pcall(function() ty = tostring(mq.TLO.Spawn(epCast.id).Type() or '') end)
            pcall(function() hp = tonumber(mq.TLO.Spawn(epCast.id).PctHPs()) or 0 end)
            if ty ~= 'NPC' or hp <= 0 then
                rezlog('[placate] %s is gone - nothing left to check', epCast.name)
                ep_mark(epCast.id, 'done', 'died or despawned')
                epCast = nil
                return
            end
            -- Alive and we cannot get on it yet. Come back next tick WITHOUT spending a retry: the cast
            -- is not in question, only our ability to look at the result.
            epCast.checkTries = (epCast.checkTries or 0) + 1
            if epCast.checkTries <= EP_CHECK_TRIES then
                rezlog('[placate] could not target %s to check (%d of %d) - trying again',
                       epCast.name, epCast.checkTries, EP_CHECK_TRIES)
                return
            end
            -- Out of attempts, still alive, still unreadable. Say so plainly and leave it UNRESOLVED in
            -- the queue rather than claiming an outcome we never observed.
            rezlog('\\ay[placate] gave up trying to read %s after %d attempts - state unknown\\ax',
                   epCast.name, EP_CHECK_TRIES)
            ep_mark(epCast.id, 'unknown', 'could not be read')
            epCast = nil
            return
        end
        -- Deliberately NOT restoring here: the next mob in the queue gets targeted a moment later
        -- anyway, and the caller's target goes back once when the queue finishes.

        if landed then
            ep_mark(epCast.id, 'done', 'placate landed')
            epCast = nil
            return
        end
        if epCast.tries < EP_RETRY then
            -- An interrupted cast does not spend a retry. EP_RETRY exists to stop us re-casting forever
            -- at a mob that keeps resisting; a cast we cancelled ourselves because an item appeared on
            -- the cursor tells us nothing about the mob and should not count against it.
            if epCast.freeRetry then epCast.freeRetry = false
            else epCast.tries = epCast.tries + 1 end
            epCast.at, epCast.sawCast, epCast.checkTries = mq.gettime(), false, 0
            -- NOTHING ON THE CURSOR, on a retry as much as on a first cast. Casting while holding an item
            -- is how it ends up somewhere unexpected, and a retry is MORE exposed than the first cast:
            -- seconds have passed, and anything that touches the cursor - a stow that did not take, a
            -- trade, a manual pickup - has had time to happen since the strip checked.
            cursor_stow('placate')
            if (mq.TLO.Cursor.ID() or 0) ~= 0 then
                rezlog('\\ay[placate] not retrying %s#%d - %s will not stow off the cursor\\ax',
                       epCast.name, epCast.id or 0, tostring(mq.TLO.Cursor.Name() or '?'))
                return
            end
            rezlog('[placate] did not land on %s#%d - retry %d of %d', epCast.name, epCast.id or 0, epCast.tries, EP_RETRY)
            if (tonumber(mq.TLO.Target.ID()) or 0) ~= epCast.id then
                pcall(function() mq.cmdf('/target id %d', epCast.id) end)
                mq.delay(400, function() return (tonumber(mq.TLO.Target.ID()) or 0) == epCast.id end)
            end
            pcall(function() mq.cmdf('/nowcast me "%s" %d', ep_spell() or '', epCast.id) end)
            return
        end
        rezlog('\\ay[placate] gave up on %s#%d after %d tries\\ax', epCast.name, epCast.id or 0, epCast.tries)
        ep_mark(epCast.id, 'failed', 'would not land')
        epCast = nil
        return
    end

    -- Anything left to do?
    -- PICK THE FIRST REACHABLE ONE, not simply the first pending one. Stalling on a far mob blocked
    -- everything behind it - a Stillmoon novice sat at 210m for a minute while three reachable mobs
    -- waited their turn, and the enchanter stayed stripped throughout.
    -- Far entries are kept in the queue and retried; they just do not hold up the ones we can reach.
    -- EVERY ENTRY IS MEASURED, not just up to the first reachable one. This used to break out of the
    -- loop the moment it had something to cast at, which meant anything behind that mob kept whatever
    -- oor flag it was last given - so the panel could show a mob as out of range long after the group
    -- had walked up to it, and the flag we now report to Smart Cast would have been stale on arrival.
    local next_e, reach = nil, ep_range()
    local farOnes = 0
    for _, q in ipairs(epQueue) do
        if not q.state then
            local d = 9999
            pcall(function() d = math.floor(tonumber(mq.TLO.Spawn(q.id).Distance()) or 9999) end)
            if d <= reach then
                if q.oor then
                    q.farSince = nil
                    pac_reflect_oor(q.id, false, d)
                    rezlog('[placate] %s is back in reach (%dm) - picking it up again', q.name, d)
                end
                q.oor = false
                next_e = next_e or q
            else
                if not q.oor then
                    pac_reflect_oor(q.id, true, d)
                    rezlog('[placate] %s is %dm away (reach %d) - skipping it for now', q.name, d, reach)
                end
                q.oor = true
                farOnes = farOnes + 1
                -- GIVE UP ON ONE THAT NEVER CLOSES. Without this the queue can never finish, so the gear
                -- never goes back on and only the 3-minute backstop saves it.
                q.farSince = q.farSince or mq.gettime()
                if (mq.gettime() - q.farSince) > EP_FAR_MAX then
                    ep_mark(q.id, 'failed', string.format('stayed out of range (%dm) for %ds', d, EP_FAR_MAX / 1000))
                end
            end
        end
    end
    ep_queue_log('choosing')
    if not next_e and farOnes > 0 and (mq.gettime() - (epOorSaidAt or 0)) > 5000 then
        epOorSaidAt = mq.gettime()
        -- SAY HOW LONG IS LEFT. "waiting" on its own scrolls past and tells you nothing you can act on;
        -- the useful question is whether to close the distance or let it drop, and that is a number.
        local soonest = nil
        for _, q in ipairs(epQueue) do
            if not q.state and q.oor and q.farSince then
                local leftms = EP_FAR_MAX - (mq.gettime() - q.farSince)
                if not soonest or leftms < soonest then soonest = leftms end
            end
        end
        rezlog('[placate] %d queued mob(s) out of reach (my reach %d) - giving up on the first in %ds',
               farOnes, reach, math.max(0, math.floor((soonest or EP_FAR_MAX) / 1000)))
    end
    if not next_e then
        -- NOT WHILE STILL CASTING. epCast is cleared the moment the mob is seen to hold the buff, and
        -- that read is "does it have a placate on it" - not "did MY cast land". If Shela got there
        -- first, or a previous attempt took, it reads true straight away and this tick concludes while
        -- our own spell is still going out. The next tick then finds the queue finished and re-equips
        -- and releases E3 mid-cast, which is the rare unpause-too-early.
        -- Waiting costs a tick. Putting weapons back on and handing E3 the character in the middle of a
        -- cast costs the cast, and possibly the placate.
        local casting = false
        pcall(function() casting = (tonumber(mq.TLO.Me.Casting.ID()) or 0) > 0 end)
        if casting then return end
        -- Queue finished. Put the weapons back - this is the "once everything is placated" half.
        if epSaved then ep_restore('queue finished') end
        return
    end

    local sp = ep_spell()
    if not sp then
        -- Empty gem is the same situation as a wrong one: fill it rather than complain about it.
        if not ep_ensure_gem() then return end
        sp = ep_spell()
        if not sp then return end
    end
    -- WRONG SPELL IN THE GEM? MEM THE RIGHT ONE. This used to refuse and print an error, on the grounds
    -- that memming interrupts the enchanter and displaces what they chose to put there. Neither holds up:
    -- choosing the gem IS the instruction that the gem is for placate, and this whole feature already
    -- strips their weapons off, which is considerably more intrusive than swapping one gem.
    -- The one real objection was picking a rank on their behalf - answered by reading it out of their own
    -- spellbook rather than a list, the same way the phantom line picks the best disc a monk owns.
    -- An error here would also land on a background toon nobody is watching, so the queue would just
    -- quietly do nothing. Memming makes it work.
    local spOk, spWhy = ep_spell_ok(sp)
    if not spOk then
        if not ep_ensure_gem() then return end
        sp = ep_spell()
        if not sp then return end
        spOk, spWhy = ep_spell_ok(sp)
        if not spOk then return end
    end
    if epSaidGem ~= sp then
        epSaidGem = sp
        -- ep_gem_num(), not epGem. epGem is the legacy shared default (8); the real gem can be per
        -- character via pacGem. Ejtou memmed into gem 11 and this line said 8 in the same breath.
        rezlog('[placate] using "%s" from gem %d (matched on %s)', sp, ep_gem_num(), tostring(spWhy))
    end

    if (mq.gettime() - (epLast or 0)) < EP_RECAST then return end
    -- FRESH MEM: WAIT FOR A CONDITION, NOT A GUESS.
    -- A flat delay was always going to be either too short or wasteful, and it was too short - the cast
    -- still went out into the tail of the memorise and errored.
    -- What actually matters is that the gem has been READY for a moment, not that some number of
    -- milliseconds has passed: the timer can read 0 while the client is still finishing, then go
    -- non-zero again, so a single sample catches it mid-settle. Requiring it to hold is what a single
    -- sample cannot tell you - the same reason the bard buttons could not use SpellReady directly.
    -- EP_MEM_SETTLE stays as a floor so there is always some pause after a mem.
    if epMemDoneAt then
        if (mq.gettime() - epMemDoneAt) < EP_MEM_SETTLE then return end
        if not ep_gem_ready() then
            epGemSteadyAt = nil
            return
        end
        epGemSteadyAt = epGemSteadyAt or mq.gettime()
        if (mq.gettime() - epGemSteadyAt) < EP_GEM_STEADY then return end
        -- Held steady: the memorise is genuinely finished, so stop re-checking for this run.
        epMemDoneAt, epGemSteadyAt = nil, nil
    end
    -- THE GEM COOLDOWN, SAID OUT LOUD. This returned silently, so a queue waiting on the spell's recast
    -- is indistinguishable from a queue that has stopped - and with several mobs the third cast is
    -- typically the first to hit it, which is exactly when "it stops after a few" gets reported.
    -- Rate-limited to once every 5s so a long recast does not fill the log.
    if not ep_gem_ready() then
        local t = -1
        pcall(function() t = tonumber(mq.TLO.Me.GemTimer(ep_gem_num()).TotalSeconds()) or -1 end)
        if (mq.gettime() - (epGemSaidAt or 0)) > 5000 then
            epGemSaidAt = mq.gettime()
            local sp2, rdy2 = ep_spell(), false
            if sp2 then pcall(function() rdy2 = tlo_true(mq.TLO.Me.SpellReady(sp2)()) end) end
            rezlog('[placate] waiting on the gem - %ss left, ready=%s, %d still queued',
                   tostring(t), tostring(rdy2), (function()
                local n = 0
                for _, q in ipairs(epQueue) do if not q.state then n = n + 1 end end
                return n
            end)())
        end
        return
    end

    -- Dead or gone while it waited its turn.
    local ty, hp = '', 0
    pcall(function() ty = tostring(mq.TLO.Spawn(next_e.id).Type() or '') end)
    pcall(function() hp = tonumber(mq.TLO.Spawn(next_e.id).PctHPs()) or 0 end)
    if ty ~= 'NPC' or hp <= 0 then ep_mark(next_e.id, 'failed', 'dead or gone'); return end

    -- Range was already checked when this one was chosen, so nothing to re-test here.

    -- STRIP BEFORE THE FIRST CAST, not before each one. Nothing above this point casts, so by the time
    -- we get here we know there is real work to do and it is worth paying for.
    -- CONFIRM WE ARE ACTUALLY STRIPPED BEFORE CASTING. The strip reports per slot, but reports are what
    -- it BELIEVES; this reads the slots and the cursor one last time. Casting with a weapon still on
    -- defeats the whole point - the proc breaks the placate - and casting with something on the cursor
    -- is how items end up somewhere unexpected.
    -- Checked here rather than inside ep_strip so it also covers a queue resumed after a stall.
    -- Hoisted out of ep_tick so the RETRY path can use it too - see below. It was a local here and the
    -- retry went straight to /nowcast without it, so an item picked up mid-run was only caught before
    -- the first cast of a mob and not before the two retries that follow.
    local function ep_ready_to_cast()
        for _, slot in ipairs(EP_SLOTS) do
            local worn = ''
            pcall(function() worn = tostring(mq.TLO.Me.Inventory(slot).Name() or '') end)
            if worn ~= '' then return false, slot .. ' still holds ' .. worn end
        end
        if (mq.TLO.Cursor.ID() or 0) ~= 0 then
            return false, 'something is on the cursor: ' .. tostring(mq.TLO.Cursor.Name() or '?')
        end
        return true
    end

    -- ep_strip returns false when something came off and cannot be found again. Do not cast in that
    -- state: it has already put back what it could, and pressing on would mean casting a queue while an
    -- item is unaccounted for.
    if not ep_strip() then return end

    local ready, why = ep_ready_to_cast()
    if not ready then
        -- THROTTLED, AND IT GIVES UP. This printed twice a second for three minutes on Shela and then
        -- the backstop tore the run down, which is the worst of both - a wall of identical lines and no
        -- progress. Once ep_strip has spent its passes the slot is not coming off, so say so once and
        -- stand down rather than waiting out the backstop repeating ourselves.
        if (mq.gettime() - (epNotReadyAt or 0)) > 5000 then
            epNotReadyAt = mq.gettime()
            rezlog('\\ay[placate] not casting: %s\\ax', why)
        end
        if epStripPass >= EP_STRIP_PASSES then
            rezlog('\\ar[placate] giving up: %s after %d strip passes. Gear is going back on; the queue is '
                .. 'held, not lost - fix the slot and re-run.\\ax', why, EP_STRIP_PASSES)
            ep_restore('could not strip')
        end
        return
    end

    epLast = mq.gettime()
    -- Target it BEFORE the cast, once. It stays there for the verification read afterwards because E3
    -- is paused for the whole run - one target per mob rather than one to cast plus one to check.
    pcall(function() mq.cmdf('/target id %d', next_e.id) end)
    mq.delay(400, function() return (tonumber(mq.TLO.Target.ID()) or 0) == next_e.id end)
    -- DID IT ALREADY HAVE ONE, AND FOR HOW LONG? Read BEFORE the cast, because afterwards there is no
    -- way to tell a fresh placate from the one that was already there.
    -- Placate runs about 40 seconds, so refreshing a mob before it drops is normal play - and on a
    -- refresh the verification "does the target have the buff" is true the instant we look, whether or
    -- not our cast did anything. It marked done, dropped the cast, and the next tick re-equipped and
    -- released E3 with the spell still going out.
    local hadBuff, preDur = false, 0
    pcall(function() hadBuff = (tonumber(mq.TLO.Target.Buff(sp).ID()) or 0) > 0 end)
    if hadBuff then
        pcall(function() preDur = tonumber(mq.TLO.Target.Buff(sp).Duration.TotalSeconds()) or 0 end)
    end
    rezlog('[placate] %s on %s#%d%s', sp, next_e.name, next_e.id or 0,
           hadBuff and string.format(' (refresh - %ds left)', preDur) or '')
    pcall(function() mq.cmdf('/nowcast me "%s" %d', sp, next_e.id) end)
    epCast = { id = next_e.id, name = next_e.name, at = mq.gettime(), tries = 1, sawCast = false,
               checkTries = 0, hadBuff = hadBuff, preDur = preDur }
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
-- GIVE UP ON ONE THAT NEVER CLOSES, the same way the placate queue does (EP_FAR_MAX). Without it an
-- entry that goes out of reach once has no way out of the queue: nothing marks it, so it stays pending
-- forever and the list can never finish. Same 45s, and deliberately shorter than PAC_OOR_MAX (90s) so
-- the outcome reflects back into Smart Cast before the shared list gives up and clears itself.
PW_FAR_MAX   = 45000
pwOorSaidAt  = 0         -- rate limit on the "everything is out of reach" line
pwCursorSaidAt = 0       -- rate limit on the stuck-cursor line
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
    -- NOT BROADCAST. Nothing binds /at_pwmark - it lands on every peer as an unknown command and does
    -- nothing else. pwQueue is this character's own assigned work, exactly like epQueue, and the group
    -- already learns the outcome through pac_reflect on the shared pacify list.
    pac_reflect(id, state)
end

-- Runs on EVERY toon; returns immediately on anyone without the disc. Main loop only - it targets and
-- yields, neither of which belongs anywhere near an ImGui callback.
function pw_tick()
    local disc = pw_disc()
    if not disc then return end

    -- SAME CURSOR RULE AS PLACATE. The phantom line never had one: it fires a disc rather than a spell,
    -- so it does not strip gear and looked lower risk - but a disc still goes out while an item is held,
    -- and it targets and re-targets exactly the same way. An item on the cursor through any of that is
    -- how it gets put somewhere nobody expects.
    -- Stow it if it will go; only stand down if it will not.
    -- ONLY WHEN THERE IS SOMETHING TO CAST AT - same fix as the placate tick, and this side had it worse:
    -- cursor_stow has no rate limit of its own, so an unconditional check here meant an /autoinventory
    -- on EVERY pulse rather than every three seconds.
    local pwWork = false
    for _, q in ipairs(pwQueue) do if not q.state then pwWork = true; break end end
    if pwWork and (mq.TLO.Cursor.ID() or 0) ~= 0 then
        local ok, held = cursor_stow('pw')
        if not ok then
            if (mq.gettime() - (pwCursorSaidAt or 0)) > 5000 then
                pwCursorSaidAt = mq.gettime()
                rezlog('\\ay[pw] holding off - %s will not stow off the cursor\\ax', tostring(held or '?'))
            end
            return
        end
    end

    if pwCast then
        local age = mq.gettime() - pwCast.at
        -- MID-DISC, same as placate: cancel first, then stow. A disc has a cast time on this line and
        -- that window was unwatched.
        local casting = false
        pcall(function() casting = (tonumber(mq.TLO.Me.Casting.ID()) or 0) > 0 end)
        if casting and (mq.TLO.Cursor.ID() or 0) ~= 0 then
            local held = tostring(mq.TLO.Cursor.Name() or '?')
            pcall(function() mq.cmd('/stopcast') end)
            mq.delay(400, function() return (tonumber(mq.TLO.Me.Casting.ID()) or 0) == 0 end)
            local ok = cursor_stow('pw')
            rezlog('\\ay[pw] %s appeared on the cursor mid-cast at %s - stopped it%s\\ax',
                   held, pwCast.name or '?', ok and ' and stowed it' or ' (it will NOT stow)')
            pwCast.freeRetry = true
            return
        end
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
            -- An interruption we caused does not count against the mob - same reasoning as placate.
            if pwCast.freeRetry then pwCast.freeRetry = false
            else pwCast.tries = pwCast.tries + 1 end
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

    if #pwQueue == 0 then pwDoneAt = nil; return end

    -- THE SWEEP RUNS BEFORE THE RECAST AND READY GATES, not after. Ageing a far mob out, noticing one
    -- has died, and tidying a finished list are all housekeeping - none of them need the disc to be up,
    -- and putting them behind the gates meant a queue could sit untouched for a whole recast cycle.
    --
    -- PICK THE FIRST REACHABLE ONE, not simply the first pending one. This is the same bug the placate
    -- queue had and fixed (see ep_tick): stalling on a far mob blocked everything behind it. Worse here,
    -- because nothing else in the phantom path ever cleared the queue - one mob out of reach once and
    -- this character stopped pacifying for the rest of the session.
    -- Far entries stay in the queue and get retried; they just do not hold up the ones we can reach.
    local next_e, nextDist, reach = nil, 0, pw_range()
    local farOnes = 0
    for _, q in ipairs(pwQueue) do
        if not q.state then
            if not pw_spawn_ok(q.id) then
                pw_mark(q.id, 'failed', 'dead or gone')
            else
                local d = 9999
                pcall(function() d = math.floor(tonumber(mq.TLO.Spawn(q.id).Distance()) or 9999) end)
                if d <= reach then
                    if q.oor then
                        q.oor, q.farSince = false, nil
                        pac_reflect_oor(q.id, false, d)
                        rezlog('[pw] %s is back in reach (%dm) - picking it up again', q.name, d)
                    end
                    if not next_e then next_e, nextDist = q, d end
                else
                    if not q.oor then
                        q.oor = true
                        pac_reflect_oor(q.id, true, d)
                        rezlog('[pw] %s is %dm away (reach %d) - skipping it for now', q.name, d, reach)
                    end
                    farOnes = farOnes + 1
                    q.farSince = q.farSince or mq.gettime()
                    if (mq.gettime() - q.farSince) > PW_FAR_MAX then
                        pw_mark(q.id, 'failed', string.format('stayed out of range (%dm) for %ds',
                                d, PW_FAR_MAX / 1000))
                    end
                end
            end
        end
    end

    -- CLEARING IS THE TICK'S JOB, not the panel's. It used to live inside draw_phantom, which only runs
    -- when the mini section is open - and miniPhantom is off by default. So on a normal session the list
    -- was never tidied at all, and the next pull started behind whatever was left over.
    local pending = 0
    for _, q in ipairs(pwQueue) do if not q.state then pending = pending + 1 end end
    if pending == 0 then
        pwDoneAt = pwDoneAt or mq.gettime()
        local hold = (#pwQueue == 1) and PW_LINGER_ONE or PW_LINGER
        if (mq.gettime() - pwDoneAt) > hold then
            pwQueue, pwDoneAt = {}, nil
            pcall(function() peer_bcast('/at_pwclear') end)
            rezlog('[pw] all done - clearing the list')
        end
        return
    end
    pwDoneAt = nil

    if not next_e then
        if farOnes > 0 and (mq.gettime() - (pwOorSaidAt or 0)) > 5000 then
            pwOorSaidAt = mq.gettime()
            rezlog('[pw] %d queued mob(s) out of reach (%d) - waiting', farOnes, reach)
        end
        return
    end

    if (mq.gettime() - pwLast) < disc.recast then return end
    local rdy = false
    pcall(function() rdy = tlo_true(mq.TLO.Me.CombatAbilityReady(disc.name)()) end)
    if not rdy then return end

    local e, dist = next_e, nextDist

    local prev = 0
    pcall(function() prev = tonumber(mq.TLO.Target.ID()) or 0 end)
    pcall(function() mq.cmdf('/target id %d', e.id) end)
    mq.delay(250)
    rezlog('[pw] %s on %s @%dm', disc.name, e.name, dist)
    pcall(function() mq.cmdf('/disc %s', disc.name) end)
    pwCast = { id = e.id, name = e.name, at = mq.gettime(), tries = 1, prevTarget = prev }
end

-- NIGHTVEIL EMBLEMS, grouped by role. One button per character plus an All per row, because the two
-- things you actually want are "everybody now" and "that one specific toon" - and a flat list of six
-- names makes you find the healers by reading rather than by looking.
-- Colour is the state: green ready, amber counting down, grey unusable (no emblem in a charm). A name
-- that is grey is not a missing button, it is a character whose emblem is in the wrong place.
function draw_nightveil()
    -- FOUR FIXED ROWS, ONE PER ITEM. A character can hold all four, so membership is per ITEM rather
    -- than per character - somebody carrying the lot appears in every row and can be sent whichever one
    -- the situation wants. That choice is the entire point of the server splitting them.
    -- Rows keep NV_SPLIT's order so they never shuffle as people zone in and out.
    local any = false
    local nMembers, nReported = 0, 0
    local members = ordered_members()
    for _, nm in ipairs(members) do
        nMembers = nMembers + 1
        if nvState[nm] and nvState[nm].items then nReported = nReported + 1 end
    end

    local function click(nm, i)
        if nm:lower() == myName:lower() then pcall(function() mq.cmdf('/at_nvclick %d', i) end)
        else pcall(function() peer_cmdf(nm, '/at_nvclick %d', i) end) end
    end

    for i, e in ipairs(NV_SPLIT) do
        local holders, ready = {}, {}
        for _, nm in ipairs(members) do
            local st = nvState[nm]
            local s  = st and st.items and st.items[i]
            if s ~= nil and s >= 0 then
                holders[#holders + 1] = nm
                ready[nm] = (s == 0)
            end
        end
        if #holders > 0 then
            any = true
            ImGui.TextColored(0.85, 0.72, 0.35, 1.0, e.role .. ':')
            ImGui.SameLine()
            local nReady = 0
            for _, nm in ipairs(holders) do if ready[nm] then nReady = nReady + 1 end end
            -- NO 'All' FOR A ROW OF ONE: it would be the same button twice, side by side.
            if #holders > 1 and nReady > 0 then
                if ImGui.SmallButton(string.format('All##nvall_%d', i)) then
                    for _, nm in ipairs(holders) do if ready[nm] then click(nm, i) end end
                end
                if ImGui.IsItemHovered and ImGui.IsItemHovered() then
                    pcall(function() ImGui.SetTooltip(string.format('Click %s on all %d ready',
                                                       e.item, nReady)) end)
                end
                ImGui.SameLine()
            end
            for _, nm in ipairs(holders) do
                local rdy = ready[nm]
                if rdy then ImGui.PushStyleColor(ImGuiCol.Text, 0.40, 0.82, 0.45, 1.0)
                else        ImGui.PushStyleColor(ImGuiCol.Text, 0.62, 0.62, 0.62, 1.0) end
                if ImGui.SmallButton(nm:sub(1, 8) .. '##nv_' .. i .. '_' .. nm) then
                    if rdy then click(nm, i) end
                end
                ImGui.PopStyleColor()
                if ImGui.IsItemHovered and ImGui.IsItemHovered() then
                    local s = nvState[nm] and nvState[nm].items and nvState[nm].items[i]
                    pcall(function() ImGui.SetTooltip(string.format('%s - %s\n%s', nm, e.item,
                        rdy and 'ready' or (nv_hms(s or 0) .. ' left'))) end)
                end
                ImGui.SameLine()
            end
            ImGui.NewLine()
        end
    end

    if not any then
        -- Say WHICH kind of empty this is: no group, nobody reporting, or everyone reporting none.
        ImGui.TextDisabled(string.format('no Nightveil rows - %d group member(s), %d reporting',
                                         nMembers, nReported))
    end
end

-- The pacify panel: who can do it, what each caps at, and the queue with each mob routed to a caster.
function draw_pacify()
    -- WHO IS AVAILABLE, and what they top out at. Shown because the routing is only as good as this
    -- table, and a caster missing from it is the first thing you would want to notice.
    local names = {}
    for nm in pairs(pacCap) do names[#names + 1] = nm end
    table.sort(names, function(a, b) return (pacCap[a].cap or 0) < (pacCap[b].cap or 0) end)
    if #names == 0 then ImGui.TextDisabled('nobody has reported a pacify spell yet'); return end

    ImGui.TextDisabled('casters:')
    for _, nm in ipairs(names) do
        local c = pacCap[nm]
        ImGui.SameLine()
        -- CLICKABLE, like the rez chain: green in, red out. A paladin who technically has a placate but
        -- should never be the one casting it is a normal thing to want, and the alternative is
        -- remembering not to queue mobs in their band.
        local off = pacOff[nm:lower()] and true or false
        if off then ImGui.PushStyleColor(ImGuiCol.Text, 0.90, 0.35, 0.35, 1.0)
        else        ImGui.PushStyleColor(ImGuiCol.Text, 0.40, 0.82, 0.45, 1.0) end
        if ImGui.SmallButton(string.format('%s %d##pacoff_%s', nm:sub(1, 6), c.cap or 0, nm)) then
            pacOff[nm:lower()] = (not off) or nil
            save_settings()
            pcall(function() peer_bcast('/at_pacoff %s %d', nm, off and 0 or 1) end)
        end
        ImGui.PopStyleColor(1)
        if ImGui.IsItemHovered and ImGui.IsItemHovered() then
            pcall(function() ImGui.SetTooltip(string.format('%s\n%s\ncaps at level %d, range %d\n\n%s',
                nm, c.spell or c.kind or '?', c.cap or 0, c.range or 0,
                off and 'OUT of the rotation - click to put back in'
                    or 'in the rotation - click to take out')) end)
        end
        -- The gem lives in SETTINGS, not here. It is set once per character and then never touched, so
        -- it does not belong on a panel you look at during a pull - unlike the in/out click above, which
        -- is a decision you make in the moment.
    end

    if ImGui.Button('Pacify target##pacadd', 150, 0) then
        local id, nm, ty, hp, lvl = 0, '', '', 0, 0
        pcall(function() id = tonumber(mq.TLO.Target.ID()) or 0 end)
        pcall(function() nm = tostring(mq.TLO.Target.CleanName() or '') end)
        pcall(function() ty = tostring(mq.TLO.Target.Type() or '') end)
        pcall(function() hp = tonumber(mq.TLO.Target.PctHPs()) or 0 end)
        pcall(function() lvl = tonumber(mq.TLO.Target.Level()) or 0 end)
        local dist = 0
        pcall(function() dist = math.floor(tonumber(mq.TLO.Target.Distance()) or 0) end)
        if id <= 0 or ty ~= 'NPC' or hp <= 0 then
            log('\\ay[pacify] target an NPC first\\ax')
        elseif pac_find(id) then
            log('[pacify] %s is already queued', nm)
        else
            -- ROUTED AT CLICK TIME, from the level the mob actually is. Deciding later would mean
            -- deciding again on every tick, and the answer cannot change - a mob's level is fixed.
            -- Distance is a snapshot: the mob may close before its turn comes, so it is used to PREFER a
            -- caster who can already reach it rather than to rule anyone out permanently.
            local who, cap, rng = pac_assign(lvl, dist)
            if not who then who, cap, rng = pac_assign(lvl) end   -- nobody in range: fall back on level
            pacQueue[#pacQueue + 1] = { id = id, name = nm, level = lvl, dist = dist, who = who,
                                        assignedAt = mq.gettime() }
            if who then
                log('[pacify] %s (level %d, %dm) -> %s (caps %d, reach %d)', nm, lvl, dist, who, cap or 0, rng or 0)
                pcall(function() peer_bcast('/at_pacadd %d %s %d %s', id, nm:gsub(' ', '_'), lvl, who) end)
                -- Every add can change who should have what, so settle the list before anyone picks up.
                pac_rebalance()
            else
                log('\\ay[pacify] %s is level %d - nobody here can pacify that high\\ax', nm, lvl)
            end
        end
    end
    ImGui.SameLine()
    if ImGui.SmallButton('Clear##pacclear') then
        pac_snapshot()
        pacQueue = {}
        pcall(function() peer_bcast('/at_pacclear') end)
    end
    -- REDO LAST. A wipe, a bad pull, or a clear you did not mean re-queues the same mobs without
    -- re-targeting each one. Dead mobs are dropped on the way through - the whole point is the ones
    -- still standing - and so is anything already in the queue, so pressing it twice is harmless.
    -- Routing is done FRESH rather than reusing who had it last time: caps, reach and load will have
    -- moved on, and the old assignment was right for a group state that no longer exists.
    if pacRedo and #pacRedo > 0 then
        ImGui.SameLine()
        if ImGui.SmallButton(string.format('Redo last (%d)##pacredo', #pacRedo)) then pac_redo() end
        if ImGui.IsItemHovered and ImGui.IsItemHovered() then
            pcall(function() ImGui.SetTooltip('Re-queue the last batch, skipping anything now dead') end)
        end
    end

    for i, e in ipairs(pacQueue) do
        ImGui.Text(string.format('%d.', i)); ImGui.SameLine()
        if not e.who then
            ImGui.TextColored(0.85, 0.35, 0.35, 1.0,
                string.format('%s  lvl %d  - too high for anyone', e.name, e.level or 0))
        elseif e.state == 'done' then
            ImGui.TextColored(0.36, 0.85, 0.46, 1.0, string.format('%s  (%s)', e.name, e.who))
        elseif e.state == 'too high' then
            ImGui.TextColored(0.85, 0.35, 0.35, 1.0,
                string.format('%s  lvl %d  above %s\'s ceiling', e.name, e.level or 0, e.who))
        elseif e.state then
            ImGui.TextColored(0.90, 0.72, 0.35, 1.0, string.format('%s  (%s: %s)', e.name, e.who, e.state))
        elseif e.oor then
            -- REPORTED out of range by the caster that owns it, not inferred here. Skipped for now and
            -- picked up again the moment it is in reach - so this is a normal, self-correcting state and
            -- not a fault. Amber rather than red for that reason: red is for something that has stopped.
            local secs = e.oorSince and math.floor((mq.gettime() - e.oorSince) / 1000) or 0
            ImGui.TextColored(0.90, 0.60, 0.30, 1.0,
                string.format('%s  %s - out of range%s', e.name, e.who,
                    (e.oorDist and e.oorDist > 0) and string.format(' (%dm)', e.oorDist) or ''))
            if ImGui.IsItemHovered and ImGui.IsItemHovered() then
                pcall(function() ImGui.SetTooltip(string.format(
                    '%s\n%s has it queued but cannot reach it%s.\nSkipped for now - it goes back in the'
                    .. ' rotation as soon as it is in range.\nout of reach for %ds; given up on at %ds.',
                    e.name, e.who,
                    (e.oorDist and e.oorDist > 0) and string.format(' - %dm at the last check', e.oorDist) or '',
                    secs, PAC_OOR_MAX / 1000)) end)
            end
        elseif e.sent then
            -- Handed to that character's own queue, which owns it from here. Worth distinguishing from
            -- 'assigned but not yet picked up' - one is working, the other might be a caster that is
            -- not running.
            ImGui.TextColored(0.62, 0.82, 0.95, 1.0,
                string.format('%s  lvl %d  %s is on it', e.name, e.level or 0, e.who))
        else
            ImGui.TextColored(0.80, 0.80, 0.80, 1.0,
                string.format('%s  lvl %d  -> %s', e.name, e.level or 0, e.who))
        end
        ImGui.SameLine()
        if ImGui.SmallButton('x##pacdel' .. i) then
            pcall(function() peer_bcast('/at_pacdel %d', e.id) end)
            table.remove(pacQueue, i)
            break
        end
    end
end



function draw_arcane_buttons()
    local btns = {}
    for _, nm in ipairs(group_members()) do
        local st = arcState[nm]
        if st and st.have == 1 then btns[#btns + 1] = { nm = nm, st = st } end
    end
    -- DRAW NOTHING when nobody has it. A row saying "nobody has this" is worse than no row: it takes
    -- the space it was meant to save and tells you something you cannot act on. The section already
    -- hides rows nobody owns; this line was defeating that for the one row it applied to.
    if #btns == 0 then return end
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
        -- BELOW, NOT BESIDE. This sits on the mini header at an absolute X near the right edge, so a
        -- SameLine after it started the text past the window and ImGui grew the window to fit - the
        -- whole panel stretched off to the right the moment a gather was running.
        -- A new line starts at the window's left margin, so it costs a row and cannot overflow.
        ImGui.TextColored(0.36, 0.80, 0.46, 1.0, 'CoTH gathering on ' .. (coth_anchor() or '?'))
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
-- Hover text for the mini sections whose behaviour is not obvious from the label. Kept beside the
-- section list rather than inside the render so it reads as documentation, which is what it is.
MINI_HELP = {
    coth = 'Uses Call of the Hero from the Wayfarers aug.\n' ..
           'Note: the aug needs to be in a charm to work.\n' ..
           'Use /atcoth to start a gather anchored on another character.',
    rez  = 'Configure the rez order under the Rez tab.',
    combos = 'Group MGB heals with class combinations,\nso you only need to click one button.',
    phantom = 'Monk placate line. Click mobs to queue them;\nthe monk works down the list.',
    placate = 'Enchanter or cleric placate. Strips weapons first so\naugment procs cannot break it, then puts them back.',
}

-- Which mini sections are folded shut. Persisted, because a fold you have to redo every session is
-- worse than no fold at all.
-- `or {}` rather than `= {}`: this line sits above load_settings() today, but a plain assignment would
-- silently wipe the loaded folds if either ever moved - and it would fail as a missing fold rather than
-- an error, which is the hardest kind to notice.
miniFold = miniFold or {}
-- ONLY THE BULKY SECTIONS FOLD. A fold header costs a line, so for a section that is two rows of
-- buttons it takes up more room than it saves - header plus panel is bigger than the panel was.
-- These three are tables that can run many rows deep; everything else is a button strip and is better
-- served by the Settings on/off box, which removes it entirely rather than trading one line for another.
-- MERGED CLICKY SECTIONS. Cures, magic protection and Arcane Reprisal were three separate sections
-- drawing four rows between them, each paying for its own separator, its own Settings on/off box and
-- its own slot in the order list. They are all the same shape - an amber label and one small button per
-- owner - and they all answer the same question, so they are one section now.
-- Arcane Reprisal sits here rather than with the heals: it is a protection-ish click, which is where it
-- reads naturally even though it is a proc.
-- ===== INVIS =====
-- WHO IS ACTUALLY INVIS, read from the client rather than inferred from what we cast. Me.Invis takes
-- NORMAL and UNDEAD separately, so the two are distinguishable without tracking which spell went out -
-- and a character invis'd by anything at all, including a potion or another player, shows correctly.
invisState = {}   -- driver: [char] = { norm = 0|1, und = 0|1, updated }
invisLast  = ''

-- Me.Invis[NORMAL] and Me.Invis[UNDEAD] return nothing on this build - only the bare Me.Invis answers.
-- So "am I invis at all" is a clean read, and WHICH KIND has to come from the buffs.
-- The trade is worth being explicit about: the bare read sees invis from ANY source, including a potion
-- or another player's cast, while the buff scan only recognises effects we can name. So a character
-- invis'd by something unknown shows as invis (correct) but not as ITU (unknown, and treated as not).
-- Erring that way is deliberate - the dangerous mistake is believing somebody is hidden from undead
-- when they are not, never the reverse.
-- EXACT NAMES, NOT A SUBSTRING. This matched any buff containing "undead", which caught
-- 'Undead Chokidai Blessing' - the Forgotten Leather Leash buff, nothing to do with invisibility.
-- Two consequences, and the second is the bad one: every character carrying the leash showed white as
-- though hidden from undead, and Drop invis STRIPPED IT, removing a real buff every press.
-- The buff an invis AA applies is named the same as the AA, which the logs confirmed, so the entries in
-- MAGIC_CLICKS are the list - add one there and it is recognised here with nothing else to update.
-- Nothing outside that list is touched, which is the property that matters for a button that removes
-- buffs from six characters at once.
function invis_known(name)
    local low = tostring(name or ''):lower()
    if low == '' then return nil end
    for _, e in ipairs(MAGIC_CLICKS) do
        if (e.group == 'ITU' or e.group == 'Invis') and e.aa then
            if low == e.aa:lower() then return e.group end
        end
    end
    return nil
end
function invis_self()
    local anyInvis = false
    pcall(function() anyInvis = tlo_true(mq.TLO.Me.Invis()) end)
    local n, u = false, false
    -- Buffs AND songs: these land in either window depending on the source, which the placate work
    -- established the hard way.
    local function look(getName, count)
        for i = 1, (count or 0) do
            local nm = ''
            pcall(function() nm = tostring(getName(i) or '') end)
            local grp = invis_known(nm)
            if grp == 'ITU' then u = true
            elseif grp == 'Invis' then n = true end
        end
    end
    local nb, ns = 0, 0
    pcall(function() nb = tonumber(mq.TLO.Me.CountBuffs()) or 0 end)
    pcall(function() ns = tonumber(mq.TLO.Me.CountSongs()) or 0 end)
    pcall(function() look(function(i) return mq.TLO.Me.Buff(i).Name() end, nb) end)
    pcall(function() look(function(i) return mq.TLO.Me.Song(i).Name() end, ns) end)
    -- The bare read is the authority on plain invis: if the client says invis and no ITU buff was found,
    -- it is normal invis whatever cast it.
    if anyInvis and not u then n = true end
    return n and 1 or 0, u and 1 or 0
end

-- Two rows, ITU and Invis, and they are two rows on purpose: walking past undead with plain invis is
-- how somebody dies, so the choice is made deliberately rather than by whichever fired first.
-- The name buttons SELECT rather than cast. One pick per row - these are group spells, so a second
-- caster is a wasted cast, not a bigger effect. The combo does the casting.
-- No callouts: unlike the MGB heals nobody needs telling, and a /rsay before a sneak is the opposite of
-- what the spell is for.
INVIS_ROWS = { 'ITU', 'Invis' }

-- Who in the group owns anything in this row, from the same state the Countermeasures buttons use.
function invis_holders(grp)
    local out = {}
    for _, nm in ipairs(ordered_members()) do
        for _, e in ipairs(MAGIC_CLICKS) do
            if e.group == grp then
                local st = magicState[nm] and magicState[nm][e.key]
                if st and st.have == 1 then out[#out + 1] = { nm = nm, e = e, secs = st.secs or 0 } end
            end
        end
    end
    return out
end

-- HOW LONG THE CASTERS GET TO PREPARE before the coordinated fire. It has to cover the relay hop plus
-- pausing E3 and stopping any cast in flight, and every millisecond of it is a millisecond the group is
-- standing still - so it is as short as those two things allow.
INVIS_LEAD = 1500
-- CLERIC FIRST, DRUID A QUARTER SECOND BEHIND.
-- The measured rule is simple: CASTING STRIPS THE INVIS YOU ALREADY HAVE. So whoever goes second has
-- already received the first caster's buff, and their own cast removes it. The logs show it exactly:
--   23:04:08.058 ITU fires,  before invis=0 itu=0
--   23:04:08.818 camo fires, 760ms later
--   +4700ms  ITU caster  invis=1 itu=1   both
--   +4700ms  camo caster invis=1 itu=0   lost the ITU it had just been given
-- An earlier run with a 544ms gap scraped through, which is what makes this look intermittent - it is
-- not, it is a race, and any gap at all is enough to lose it.
-- ITU has a short cast time; invisibility is instant. So the window to aim for is: the cleric's ITU is
-- STILL IN FLIGHT when the druid's instant camo goes out. Neither has received anything yet, so neither
-- cast strips anything, and both land afterwards.
-- 250ms, not the 700 this started at. 700 was long enough for the ITU to arrive first, which is the
-- thing being avoided - the offset has to be shorter than the cast, not longer.
-- The measured rule underneath all of this: CASTING STRIPS THE INVIS YOU ALREADY HAVE.
--   23:04:08.058 ITU fires
--   23:04:08.818 camo fires 760ms later
--   +4700ms  ITU caster  invis=1 itu=1   both
--   +4700ms  camo caster invis=1 itu=0   lost the ITU it had just been given
-- An earlier run at 544ms scraped through, which is what made this look intermittent. It is a race, and
-- the fix is to land inside the cast rather than after it.
-- THE DRUID FIRES WHILE THE CLERIC IS MID-CAST.
-- Measured gaps against outcome, with the offset set to 250:
--   101ms  both covered
--   451ms  camo caster lost the ITU it had just been given
-- Neither is 250, because each caster fires on the first tick AFTER its deadline and the tick is 250ms.
-- That quantisation is larger than the offset it was supposed to be honouring, so tuning the offset was
-- tuning the smaller of the two numbers.
-- Casting ANYTHING breaks the invis you are holding, and it breaks it when the cast STARTS. So the
-- instant camo has to land after the cleric has begun casting - land before that and the cleric's own
-- cast start strips it a moment later.
-- Zero does not work for this: with no offset the two fire within a few milliseconds and the ORDER is a
-- coin flip. The 8ms run lost it for exactly that reason - the druid went first by 8 thousandths of a
-- second, so the camo was already on the cleric when the cleric started casting:
--   785645927 FIRING inviscamo   <- druid first
--   785645935 FIRING itu
--   result: cleric invis=0 itu=1, druid invis=1 itu=1
-- THE WINDOW IS THE CAST ITSELF, and it is about half a second wide - not the two seconds first assumed.
-- Every run we have fits this: the druid must cast after the cleric's ITU has STARTED and before it
-- LANDS.
--     8ms  druid fired first - camo was on the cleric before its cast start, so the start stripped it
--   101ms  inside the window - both covered
--   451ms  after the cast landed - the druid's own cast start stripped the ITU it had just received
--   609ms  same again: cleric invis=1 itu=1, druid invis=1 itu=0
-- The tell for the width is `casting` in the after-log: 16229 at +1200ms on the 8ms run, 0 at +1200ms on
-- the 609ms run - so the cast completes somewhere under a second, and the earlier reading was a longer
-- cast being caught mid-flight rather than the normal case.
-- 50, AND THE ORDER NO LONGER MATTERS. Once BOTH casters use a spell with a cast time, the requirement
-- is only that each one has STARTED before the other's lands - and the cast duration is the window, so
-- there is well over a second of room rather than a precise moment to hit.
-- That is why the coin-flip worry behind the old 150 no longer applies. It mattered when one side was an
-- instant cast: whoever went first had their invis stripped by the other's cast start. Two cast times and
-- both breaks happen before either buff arrives, whichever order they go in.
-- What forced this down: the A-team runs the shaman group invis and its gaps came out at 311ms against a
-- configured 150 - the offset is right, the extra is relay and fire jitter - and 311 was past the ITU
-- landing, so the shaman received it and then stripped it. Halving the configured value keeps the
-- observed gap inside the cast on a jittery box.
-- Effectively simultaneous is the target; 50 exists only so they are not fighting for the same instant.
INVIS_ROW_OFFSET = { ITU = 0, Invis = 50 }
invisFireKey, invisFireAt = nil, nil

-- What does this thing take to cast? Logged so the offset above can be set from evidence.
-- AAs carry their cast time on the spell behind them; a plain spell has it directly.
function invis_cast_ms(key)
    local e
    for _, x in ipairs(MAGIC_CLICKS) do if x.key == key then e = x; break end end
    if not e then return -1 end
    local secs = -1
    if e.aa then
        pcall(function() secs = tonumber(mq.TLO.Me.AltAbility(e.aa).Spell.CastTime.TotalSeconds()) or -1 end)
    elseif e.spell then
        pcall(function() secs = tonumber(mq.TLO.Spell(e.spell).MyCastTime.TotalSeconds()) or -1 end)
    end
    return secs
end

-- Arm the countdown and get ready during it. Called on the caster, whether that is this character or a
-- peer that was sent /at_inviscast.
function invis_arm(key, ms)
    if not key or key == '' then return end
    invisFireKey = key
    invisFireAt  = mq.gettime() + (tonumber(ms) or INVIS_LEAD)
    -- PREPARE NOW, CAST LATER. Holding E3 and clearing a cast in flight are the two things that would
    -- otherwise happen at the deadline and make this caster late - which is the whole problem.
    e3_hold('invis')
    local casting = false
    pcall(function() casting = (tonumber(mq.TLO.Me.Casting.ID()) or 0) > 0 end)
    if casting then
        pcall(function() mq.cmd('/stopcast') end)
        mq.delay(400, function() return (tonumber(mq.TLO.Me.Casting.ID()) or 0) == 0 end)
    end
    -- The cast time is the number the offset has to be set against, so it goes in the log every time.
    log('[invis] armed %s - firing in %dms (this spell casts in %ss)',
        key, tonumber(ms) or INVIS_LEAD, tostring(invis_cast_ms(key)))
end

-- Called from the tick. Fires when the countdown expires, then hands E3 back.
function invis_fire_tick()
    if not invisFireAt then return end
    -- FIRE AT THE DEADLINE, NOT ON THE NEXT TICK. The main loop runs every 250ms, so waiting for a tick
    -- to notice the deadline has passed adds up to a quarter second of error - and the two casters draw
    -- that error independently, which is where a 250ms offset turned into gaps of 101 and 451.
    -- Once the deadline is within one tick, wait out the remainder precisely and go. The whole point of
    -- the countdown is that both casters know exactly when to act; this is what lets them act on it.
    local left = invisFireAt - mq.gettime()
    if left > 300 then return end
    if left > 0 then mq.delay(left) end
    local key = invisFireKey
    invisFireKey, invisFireAt = nil, nil
    if key then
        -- Timestamped on both casters so the two logs can be laid side by side and the real gap read off
        -- rather than inferred from whether the buff stuck.
        local n0, u0 = invis_self()
        log('[invis] FIRING %s at %d (before: invis=%d itu=%d)', key, mq.gettime(), n0, u0)
        pcall(function() magic_click(key) end)
        -- And what it actually achieved, a moment later. If invis reads 0 here after firing an invis,
        -- something stripped it between the cast and now - which is the failure being chased.
        -- SAMPLED, NOT A SINGLE LOOK. One read at 1.2s cannot tell a cast still in flight from one that
        -- landed and was stripped - and those want opposite fixes. Three looks show which.
        for _, wait in ipairs({ 1200, 1500, 2000 }) do
            mq.delay(wait)
            local n1, u1 = invis_self()
            local casting = 0
            pcall(function() casting = tonumber(mq.TLO.Me.Casting.ID()) or 0 end)
            log('[invis] after %s +%dms: invis=%d itu=%d casting=%d', key,
                (wait == 1200) and 1200 or ((wait == 1500) and 2700 or 4700), n1, u1, casting)
        end
    end
    e3_release('invis')
end

-- A COUNTDOWN, NOT A COMMAND. Two casters told to go separately go separately: the relay delivers at
-- slightly different times, each starts whenever it next ticks, and the second one to cast BREAKS ITS
-- OWN INVIS from the first - which is the staggering you are seeing.
-- Sending "cast this, N milliseconds from now" instead means both count down locally and fire together,
-- with no negotiation round-trip and no dependence on the two clients agreeing what time it is: each one
-- measures N from the moment it receives, and the relay hop is the only variance left.
-- The lead time is also prep time - each caster holds E3 and stops any cast in flight while it waits, so
-- when the deadline arrives there is nothing left to do but cast.
function invis_cast(grp, lead)
    local pick = invisPick[grp]
    if not pick then return false end
    lead = lead or INVIS_LEAD
    for _, h in ipairs(invis_holders(grp)) do
        if h.nm == pick then
            if h.nm:lower() == myName:lower() then invis_arm(h.e.key, lead)
            else peer_cmdf(h.nm, '/at_inviscast %s %d', h.e.key, lead) end
            return true
        end
    end
    -- Picked somebody who has since gone, died or dropped the AA. Say so rather than failing quietly:
    -- an invis that did not go out is only discovered by something hitting you.
    log('\\ay[invis] %s is picked for %s but cannot cast it now\\ax', pick, grp)
    return false
end

-- THE PICKS LIVE IN SETTINGS, not in the mini window. They are a set-once choice - who casts each row -
-- and a set-once choice does not need to occupy space next to the button you press every pull.
function draw_invis_picks()
    for _, grp in ipairs(INVIS_ROWS) do
        local hs = invis_holders(grp)
        if #hs > 0 then
            ImGui.TextDisabled('   ' .. grp .. ':')
            ImGui.SameLine()
            for _, h in ipairs(hs) do
                local picked = (invisPick[grp] == h.nm)
                local ready  = (h.secs or 0) <= 0
                if picked then      ImGui.PushStyleColor(ImGuiCol.Text, 0.40, 0.82, 0.45, 1.0)
                elseif ready then   ImGui.PushStyleColor(ImGuiCol.Text, 0.78, 0.78, 0.78, 1.0)
                else                ImGui.PushStyleColor(ImGuiCol.Text, 0.52, 0.52, 0.52, 1.0) end
                if ImGui.SmallButton(h.nm:sub(1, 8) .. '##inv_' .. grp .. '_' .. h.nm) then
                    -- ONE PICK PER ROW. Clicking the picked one clears it, so a row can be left out of
                    -- the combo without having to pick somebody else instead.
                    invisPick[grp] = (picked and nil) or h.nm
                    save_settings()
                end
                ImGui.PopStyleColor()
                if ImGui.IsItemHovered and ImGui.IsItemHovered() then
                    pcall(function() ImGui.SetTooltip(string.format('%s - %s\n%s\nClick to %s',
                        h.nm, h.e.aa or h.e.name or h.e.spell or '?',
                        ready and 'ready' or (nv_hms(h.secs) .. ' left'),
                        picked and 'unpick' or 'pick for the combo')) end)
                end
                ImGui.SameLine()
            end
            ImGui.NewLine()
        end
    end
end

function draw_invis()
    local anyRow = true
    -- EVERY CHARACTER, COLOURED BY WHAT IT ACTUALLY HAS. Not who can cast it - who is covered right now.
    -- The whole point of the row is answering "is anyone about to walk into something" at a glance,
    -- which is a question about state, not capability.
    --   dim grey  nothing
    --   blue      invis
    --   white     invis to undead
    --   purple    both
    -- Colour is doing a lot of work here, and blue against white against grey is not a distinction
    -- everybody can make quickly - so the tooltip always spells it out in words, and a character with
    -- neither is dimmed as well as grey so "no invis" reads differently even if the hue does not.
    if miniInvisRows then
        ImGui.TextColored(0.85, 0.72, 0.35, 1.0, 'Covered:')
        ImGui.SameLine()
        for _, nm in ipairs(ordered_members()) do
            local st = invisState[nm]
            local n  = (st and st.norm == 1)
            local u  = (st and st.und  == 1)
            if n and u then      ImGui.PushStyleColor(ImGuiCol.Text, 0.72, 0.51, 0.90, 1.0)   -- purple
            elseif u then        ImGui.PushStyleColor(ImGuiCol.Text, 0.95, 0.95, 0.95, 1.0)   -- white
            elseif n then        ImGui.PushStyleColor(ImGuiCol.Text, 0.42, 0.66, 0.95, 1.0)   -- blue
            else                 ImGui.PushStyleColor(ImGuiCol.Text, 0.48, 0.48, 0.48, 1.0)   -- dim grey
            end
            ImGui.SmallButton(nm:sub(1, 8) .. '##invst_' .. nm)
            ImGui.PopStyleColor()
            if ImGui.IsItemHovered and ImGui.IsItemHovered() then
                local what = (n and u) and 'invis AND invis to undead'
                          or u and 'invis to undead only'
                          or n and 'invis only - UNDEAD CAN SEE THIS CHARACTER'
                          or (st and 'not invis' or 'no report yet')
                pcall(function() ImGui.SetTooltip(nm .. ': ' .. what) end)
            end
            ImGui.SameLine()
        end
        ImGui.NewLine()
    end
    if miniInvisCombo then
        local n = 0
        for _, grp in ipairs(INVIS_ROWS) do if invisPick[grp] then n = n + 1 end end
        if n > 0 then
            if ImGui.SmallButton(string.format('Invis combo (%d)##invcombo', n)) then
                -- ONE lead for both, so the two countdowns expire together. Passing the same number
                -- rather than letting each default is the entire point: two defaults started a few
                -- milliseconds apart are two different deadlines.
                -- Same base for both, plus the per-row offset that keeps the slow cast ahead of the
                -- instant one. INVIS_ROWS is { 'ITU', 'Invis' } so ITU is dispatched first as well.
                local lead = INVIS_LEAD
                for _, grp in ipairs(INVIS_ROWS) do
                    invis_cast(grp, lead + (INVIS_ROW_OFFSET[grp] or 0))
                end
            end
            if ImGui.IsItemHovered and ImGui.IsItemHovered() then
                local who = {}
                for _, grp in ipairs(INVIS_ROWS) do
                    if invisPick[grp] then who[#who + 1] = grp .. ': ' .. invisPick[grp] end
                end
                pcall(function() ImGui.SetTooltip('Cast both picks\n' .. table.concat(who, '\n')) end)
            end
            -- DELIBERATELY NOT ADJACENT. This undoes what the button beside it just did, and the two get
            -- pressed in opposite situations - one before a sneak, one when you want to fight. A gap is
            -- cheap; pressing Drop invis when you meant the combo is not.
            -- Same reasoning as keeping CoTH away from Close all on the header.
            ImGui.SameLine(0, 28)
            ImGui.PushStyleColor(ImGuiCol.Text, 0.95, 0.72, 0.35, 1.0)
            local dropHit = ImGui.SmallButton('Drop invis##invdrop')
            ImGui.PopStyleColor()
            if dropHit then
                -- Everyone, not just the picks: the picks are who CASTS it, and by now the whole group
                -- is invis. Leaving one character hidden is how somebody gets left behind.
                for _, nm in ipairs(ordered_members()) do
                    if nm:lower() == myName:lower() then pcall(function() mq.cmd('/at_unvis') end)
                    else pcall(function() peer_cmdf(nm, '/at_unvis') end) end
                end
            end
            if ImGui.IsItemHovered and ImGui.IsItemHovered() then
                pcall(function() ImGui.SetTooltip(
                    'Remove invis from the whole group.\nFor when you are ready to fight and do not want '
                    .. 'to wait for it to break on its own.') end)
            end
        elseif not anyRow then
            ImGui.TextDisabled('nobody in the group has an invis ability')
        else
            ImGui.TextDisabled('pick who casts each row')
        end
    end
end

function draw_protect_buttons()
    -- DRAUGHTS FIRST. They were their own section for one row of three buttons, paying a separator and
    -- a settings entry for it. They are consumables you press when something is going wrong, which is
    -- what everything else in here is - and putting them under the fold means one click hides the whole
    -- lot rather than leaving three orphan buttons behind.
    -- Each block is a row the user can turn off in Settings. draw_magic_buttons gates its own rows
    -- individually, because it draws several.
    if not cm_hidden('Draughts') then draw_pot_buttons() end
    if not cm_hidden('Cures')    then draw_cure_buttons() end
    draw_magic_buttons()
    if not cm_hidden('Arcane Reprisal') then draw_arcane_buttons() end
end

-- Every row Countermeasures can draw, for the Settings list. Built from the same tables the panel uses,
-- so a new entry appears here without a second list to maintain.
-- Invis and ITU are deliberately absent: they have their own section now.
function cm_rows()
    local out, seen = { 'Draughts', 'Cures' }, { Draughts = true, Cures = true }
    for _, e in ipairs(MAGIC_CLICKS) do
        local g = e.group or e.label
        if g and g ~= 'Invis' and g ~= 'ITU' and not seen[g] then
            seen[g] = true; out[#out + 1] = g
        end
    end
    out[#out + 1] = 'Arcane Reprisal'
    return out
end
-- MGB and the combo buttons, same reasoning: two rows, two separators, two settings entries, one job.
function draw_groupheal_buttons()
    -- TWO HALVES, TWO SWITCHES. Merging these into one section saved a separator, and then took away the
    -- ability to show combos WITHOUT the individual class buttons - which is the normal setup once you
    -- have a combo, because the combo already presses them and the row of singles is just noise.
    -- The section checkbox in Settings is the master; these two decide what is inside it.
    if miniClicks then draw_mgb_buttons() end
    if miniCombos then draw_combo_buttons() end
end

-- FOLD WHERE FOLDING BUYS SOMETHING. The header costs a row of its own, so a two-row section that folds
-- is three rows open to save one - not worth the click. Protection draws four rows and the emblems up
-- to four, so those fold; group heals is two rows and stays plain.
MINI_FOLDABLE = { rez = true, di = true, burns = true, protect = true, nightveil = true,
                  invis = true }

MINI_SECTIONS = {
    { key = 'rez',    label = 'Rez',                   draw = draw_rez_mini,
      get = function() return miniRez end,    set = function(v) miniRez = v end },
    { key = 'di',     label = 'DI staff',              draw = draw_di_mini,
      get = function() return miniDI end,     set = function(v) miniDI = v end },
    { key = 'burns',  label = 'Burns',
      draw = function()
          -- THREE VIEWS, smallest first: compact (name + ready count + dots), the tier matrix, then
          -- the full table. miniBurnView supersedes the old miniBurnTable boolean, which could only
          -- say "matrix or table"; the loader below migrates the old value so nobody loses their choice.
          if miniBurnView == 0 then draw_burn_compact(); return end
          if miniBurnView == 1 then draw_burn_dots(); return end
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
    -- ON IF EITHER OF THE OLD FLAGS WAS ON. MGB and combos were separate sections with separate
    -- visibility, so gating the merged one on miniClicks alone hid it for anyone who had combos on and
    -- MGB off - a merge is not supposed to lose a section you were already showing.
    -- set writes BOTH, so the checkbox stays authoritative from here on.
    { key = 'groupheals', label = 'Group heals',       draw = draw_groupheal_buttons,
      get = function() return (miniClicks or miniCombos) and true or false end,
      set = function(v) miniClicks = v; miniCombos = v end },   -- master: both halves follow
    -- 'Countermeasures', not 'Magic protection': cures are not protection, and the four things in here
    -- are united by being pressed BECAUSE something is being done to you - two strip a debuff, the boots
    -- resist, Arcane Reprisal punishes the caster. Not 'Defense Cooldowns' either, which would read as a
    -- planned defensive window and collide with the burn tiers, which genuinely are cooldowns.
    -- ON IF EITHER HALF IS ON, same as Group heals: the section checkbox is the master and the two
    -- sub-checkboxes on its row decide what is inside it.
    { key = 'invis',  label = 'Invis',                 draw = draw_invis,
      get = function() return (miniInvisRows or miniInvisCombo) and true or false end,
      set = function(v) miniInvisRows = v; miniInvisCombo = v end },
    { key = 'protect', label = 'Countermeasures',      draw = draw_protect_buttons,
      get = function() return (miniCures or miniMagic or miniArcane or miniPots) and true or false end,
      set = function(v) miniCures = v; miniMagic = v; miniArcane = v; miniPots = v end },
    { key = 'coth',   label = 'CoTH Group button',     draw = draw_coth_mini,
      get = function() return miniCoth end,   set = function(v) miniCoth = v end },
    { key = 'nightveil', label = 'Nightveil Emblems',    draw = draw_nightveil,
      get = function() return miniNightveil end, set = function(v) miniNightveil = v end },
    { key = 'pacify',  label = 'Pacify',                  draw = draw_pacify,
      get = function() return miniPacify end, set = function(v) miniPacify = v end },
}
miniOrder = {}   -- list of keys, in display order; rebuilt from settings, defaults to the list above
function mini_section(key)
    for _, s in ipairs(MINI_SECTIONS) do if s.key == key then return s end end
    return nil
end
function mini_order_normalise()
    -- Keep only keys we know, then append anything missing. Survives an old settings file that
    -- predates a section, and drops a key from a future one without breaking the list.
    -- LEGACY KEYS MAP TO THE SECTION THAT ABSORBED THEM, rather than being dropped as unknown.
    -- Without this, merging cures/magic/arcane into 'protect' would quietly delete wherever you had put
    -- them and re-add the merged section at the bottom - an upgrade silently rearranging a layout you
    -- set by hand. The first legacy key wins the position, the rest collapse into it.
    -- 'placate' folded into 'pacify': the manual single-target queue is gone, Smart Cast is the
    -- only placate view, so an old layout keeps its position rather than losing the entry.
    local MERGED = { cures = 'protect', magic = 'protect', arcane = 'protect', pots = 'protect',
                     mgb = 'groupheals', combos = 'groupheals', placate = 'pacify',
                     -- The monk phantom panel was the same thing as the manual placate panel:
                     -- an add-target button and a clear, for a queue Pacify already fills.
                     phantom = 'pacify' }
    local out, seen = {}, {}
    for _, k0 in ipairs(miniOrder) do
        local k = MERGED[k0] or k0
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
-- THE LOCAL HALF ON ITS OWN. Dropping a departed character's entries costs nothing and should never be
-- rate limited - a stale row in the UI is the thing a roster change most needs cleaned up. Split out so
-- churn can be answered cheaply without pinging, launching and asking five toons to re-report.
-- DROP ONE CHARACTER'S ROWS. Needed because the grace-period close happens on a TIMER, not on a roster
-- change - so nothing else would ever run a prune afterwards, and the worker's last reported state would
-- sit in the UI until the next time somebody joined or left. Closing the worker stops new reports; this
-- clears the ones already on the board.
function prune_one(name)
    local key = tostring(name or ''):lower()
    if key == '' then return end
    local function drop(t)
        if type(t) ~= 'table' then return end
        for k in pairs(t) do
            if type(k) == 'string' and k:lower() == key then t[k] = nil end
        end
    end
    drop(burnState); drop(potState); drop(healState); drop(cureState)
    drop(DI.state);  drop(rezReady); drop(tributeState)
    drop(counts);    drop(nvState)
    -- COTH.state IS DELIBERATELY NOT DROPPED HERE. coth_can_summon() reads false when a character has no
    -- entry, so clearing one is the same as declaring that toon unable to summon - and this path can run
    -- WITHOUT the re-report that would refill it: the grace-period close is a timer, not a roster change.
    -- The original code pruned it only inside resync_group, where a fresh round of reports always
    -- follows. Left that way.
end

function resync_prune_only()
    local inGroup = {}
    for _, nm in ipairs(group_members()) do inGroup[nm:lower()] = true end
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
    -- COTH.state left alone; see prune_one. This runs on every roster change including the ones the
    -- rate limit stops from re-reporting, so anything cleared here can stay cleared.
    return prune(burnState) + prune(potState) + prune(healState) + prune(cureState)
         + prune(DI.state) + prune(rezReady) + prune(tributeState)
         + prune(counts) + prune(nvState)
end

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
        -- TIMED. This is where the startup gap lived, and it was blamed on three other things first.
        local t0 = mq.gettime()
        bring_up_group(peers)   -- pings first; only launches on toons that do not answer
        local ms = mq.gettime() - t0
        if ms >= 250 then log('[boot] bringing the group up took %dms', ms) end
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
reviveFirstSeen = {} -- char -> when first considered, so 'never reported yet' is not read as
                     -- 'silent since the epoch' and the worker killed before it can speak
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
            -- NEVER HEARD FROM IS NOT THE SAME AS WENT SILENT. last stays 0 for a worker that has not
            -- reported yet, so now-last is the driver's whole uptime - the log said "silent 87640s",
            -- which is 24 hours, for workers that had started seconds earlier. They were then killed and
            -- relaunched before their first burn poll, over and over, which is why burns never arrived.
            -- A worker that has said nothing yet gets the same grace as one that has just gone quiet.
            if last == 0 then last = reviveFirstSeen[nm] or now; reviveFirstSeen[nm] = last end
            if (now - last) <= limit then
                reviveStrike[nm] = 0                      -- talking: clear any strikes
            elseif (now - (reviveAt[nm] or 0)) > 120000 then
                alive[nm:lower()] = nil
                peer_cmdf(nm, '/at_ping %s', myName)
                -- WAIT FOR THE PONG, do not sleep a fixed 700ms and hope. peer_cmdf is asynchronous and
                -- the reply comes back through the relay, so on a busy network a healthy worker can miss
                -- that window twice in a row and be restarted for it. This returns the moment it answers.
                local pw = 0
                while pw < 2000 and not alive[nm:lower()] do mq.doevents(); mq.delay(100); pw = pw + 100 end
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
        local mflags = (miniBurns and miniBurnView == 2)
            and 0
            or ((ImGuiWindowFlags.AlwaysAutoResize or 0) + (ImGuiWindowFlags.NoScrollbar or 0))
        -- LOCK. NoMove alone is not enough - a window you cannot drag but can still resize by the corner
        -- still wanders, and the reason to lock one is that a stray click while fighting moves it.
        if uiLocked then
            mflags = mflags + (ImGuiWindowFlags.NoMove or 0) + (ImGuiWindowFlags.NoResize or 0)
        end
        -- Fires once per session as well as on the toggle: if detail was ALREADY on at load, the toggle
        -- never runs, and ImGui just restores the small size it remembered from when this was an
        -- auto-resizing window. Two call signatures because bindings differ; a silent pcall failure here
        -- is exactly why the first attempt did nothing.
        if (miniBurns and miniBurnView == 2) and not miniSizedOnce then
            miniSizedOnce = true; miniSizeWanted = true
        end
        if miniSizeWanted then
            miniSizeWanted = false
            local w, h = mini_table_size()
            local okS = pcall(function() ImGui.SetNextWindowSize(w, h, ImGuiCond.Always or 1) end)
            if not okS then pcall(function() ImGui.SetNextWindowSize(w, h) end) end
        end
        local show = ImGui.Begin('AdventureTime ' .. VERSION .. '###advtime_mini', windowOpen, mflags)
        windowOpen = show
        if show then
            -- Padlock: closed when locked, open when not. A glyph rather than a word because both title
            -- strips are already tight, and the state is legible at a glance either way.
            if ImGui.SmallButton((uiLocked and '\240\159\148\146' or '\240\159\148\147') .. '##at_lock') then
                uiLocked = not uiLocked
                save_settings()
            end
            if ImGui.IsItemHovered and ImGui.IsItemHovered() then
                pcall(function() ImGui.SetTooltip(uiLocked
                        and 'Locked - the window cannot be moved or resized.\nClick to unlock.'
                        or  'Unlocked. Click to pin it in place so a stray click cannot drag it.') end)
            end
            ImGui.SameLine()
            if ImGui.SmallButton('Expand') then miniMode = false; save_settings() end
            ImGui.SameLine()
            -- The same Close all that sits at the bottom of the expanded window, put where it can be
            -- reached without expanding first. It sets the flag and the MAIN LOOP does the work - the
            -- broadcast and exit must not happen inside an ImGui callback.
            -- Deliberately NOT a new /at_close bind: that name is already the group shutdown, and binding
            -- it again here would have silently replaced it with something that only hides a window.
            draw_close_all('miniclose', false)
            -- COTH ON THE HEADER, HARD RIGHT. As its own section it cost a separator and a full row for
            -- one button. Up here it costs nothing: the header row already exists and its right-hand end
            -- was empty. Pushed to the far edge rather than tucked beside Close all deliberately - those
            -- two are the most and least reversible buttons in the window, and they should not be
            -- neighbours where a mis-click swaps one for the other.
            -- SameLine takes an absolute X, so this is measured from the window rather than guessed. If
            -- the window is too narrow to place it, it falls back to simply following on.
            if miniCoth then
                local ww = 0
                pcall(function() ww = tonumber(ImGui.GetWindowWidth()) or 0 end)
                if ww > 220 then ImGui.SameLine(ww - 100) else ImGui.SameLine() end
                draw_coth_mini()
            end
            -- The Burns and Rez toggles that used to sit here are gone. They predated Settings owning
            -- section visibility, covered only 2 of the 8 sections, and - the real problem - flipped
            -- the flag WITHOUT saving, so anything set from here reverted on the next restart while
            -- the same box in Settings persisted. One control per setting, and it saves.
            ImGui.Spacing()
            draw_tribute_mini()
            -- COLLAPSE PER SECTION. Separate from the Settings on/off box on purpose: that decides
            -- whether a section EXISTS and stops it rendering at all, this is "not right now" for one
            -- you still want a moment later. Turning Rez off in Settings to stop looking at it means
            -- going back to Settings to get it back, which is too much friction for a glance.
            -- A folded section draws only its title, so it costs a line rather than a panel.
            for _, k in ipairs(miniOrder) do
                local sec = mini_section(k)
                -- CoTH is drawn on the header row above, so it is skipped here. It stays in the section
                -- list so its Settings checkbox still turns it on and off - only its position in the
                -- order list is now inert, since the header is a fixed spot.
                if k == 'coth' then sec = nil end
                if sec and sec.get and sec.get() and sec.draw then
                    ImGui.Spacing(); ImGui.Separator(); ImGui.Spacing()
                    local folded = false
                    if MINI_FOLDABLE[k] then
                        folded = miniFold[k] and true or false
                        -- The caret IS the button, so the title line is the hit target rather than a
                        -- separate widget crowding the row.
                        if ImGui.SmallButton((folded and '> ' or 'v ') .. (sec.label or k) .. '##fold_' .. k) then
                            miniFold[k] = (not folded) or nil
                            save_settings()
                        end
                        if ImGui.IsItemHovered and ImGui.IsItemHovered() then
                            pcall(function() ImGui.SetTooltip(folded
                                and 'Click to show this section'
                                or  'Click to fold it away - it stays on, just out of the way') end)
                        end
                        -- WIPE LIVES ON THE HEADER, always - not just when folded. It is the one control
                        -- in the rez section you reach for in a hurry, and having it move depending on
                        -- whether the panel happens to be open is worse than it simply being in one
                        -- place. Folding the section is exactly when you would still want it.
                        -- draw_wipe_button already handles both states and is shared with the Rez tab.
                        if k == 'rez' then
                            ImGui.SameLine()
                            draw_wipe_button('minihdr')
                        end
                        -- Same reasoning as the wipe button: "is the tank covered" is the one fact the
                        -- DI section exists to tell you, so it belongs where folding cannot hide it.
                        if k == 'di' then
                            ImGui.SameLine()
                            draw_di_save_line()
                        end
                    end
                    if not folded then sec.draw() end
                end
            end
        end
        ImGui.End()
        return
    end
    ImGui.SetNextWindowSize(560, 500, ImGuiCond.FirstUseEver)
    local wflags = uiLocked and ((ImGuiWindowFlags.NoMove or 0) + (ImGuiWindowFlags.NoResize or 0)) or 0
    local show = ImGui.Begin('AdventureTime ' .. VERSION .. '###advtime', windowOpen, wflags)
    windowOpen = show
    if show then
        -- top strip: global controls + the tribute glance (always visible, above the tabs)
        -- Padlock: closed when locked, open when not. A glyph rather than a word because both title
        -- strips are already tight, and the state is legible at a glance either way.
        if ImGui.SmallButton((uiLocked and '\240\159\148\146' or '\240\159\148\147') .. '##at_lock') then
            uiLocked = not uiLocked
            save_settings()
        end
        if ImGui.IsItemHovered and ImGui.IsItemHovered() then
            pcall(function() ImGui.SetTooltip(uiLocked
                and 'Locked - the window cannot be moved or resized.\nClick to unlock.'
                or  'Unlocked. Click to pin it in place so a stray click cannot drag it.') end)
        end
        ImGui.SameLine()
        if ImGui.Button('Mini', 50, 0) then miniMode = true; save_settings() end
        -- CLOSE ALL MOVED UP HERE from the bottom of the window. At the bottom it sat below the tab bar,
        -- so where it landed depended on which tab was open and how long that tab's content was - the
        -- one button in the window that shuts down every instance in the group was also the one that
        -- moved around. Top row, fixed position, next to the other window-level controls.
        ImGui.SameLine()
        draw_close_all('mainclose', true)   -- global: shuts every instance, asks first
        -- Counts, Tank XT and its Auto checkbox removed from this row - see the note by the tab bar.
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
                -- These call sites are hardcoded rather than driven from ITEMS, so adding a name to
                -- that list gets it COUNTED but never DRAWN - which is exactly what happened to Ruby
                -- and Diamond Coin: eighteen items queried, sixteen visible.
                render_group(nil, COL_RUBY, { 'Ruby' })
                render_group(nil, COL_DC,   { 'Diamond Coin' }, 'Diamond Coin')
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
            if ImGui.BeginTabItem('Ports') then
                draw_ports_tab()
            end
            if ImGui.BeginTabItem('Settings') then
                ImGui.Spacing()
                ImGui.TextColored(0.45, 0.75, 0.95, 1.0,
                    'AdventureTime ' .. VERSION .. '   (build ' .. BUILD_TAG .. ')')
                ImGui.Separator()
                ImGui.Spacing()
                -- SMART CAST GEMS. Set once per character and then forgotten, which is what Settings is
                -- for - the in/out clicks stay on the panel because those are decisions you make during
                -- a pull, and these are not.
                -- Listed from the capability reports, so only characters that actually have a pacify
                -- SPELL appear. A monk's phantom line is a disc and needs no gem.
                do
                    local casters = {}
                    for nm, c in pairs(pacCap) do
                        if c.kind == 'placate' then casters[#casters + 1] = nm end
                    end
                    if #casters > 0 then
                        table.sort(casters)
                        ImGui.TextColored(0.85, 0.72, 0.35, 1.0, 'Pacify gems')
                        ImGui.TextDisabled('which gem holds each caster\'s pacify spell')
                        for _, nm in ipairs(casters) do
                            ImGui.SetNextItemWidth(70)
                            local cur = pacGem[nm:lower()] or 8
                            local g = ImGui.InputInt(nm .. '##pacgemset_' .. nm, cur, 0)
                            g = math.max(1, math.min(12, math.floor(tonumber(g) or 8)))
                            if g ~= cur then
                                pacGem[nm:lower()] = g
                                dirty = true
                                pcall(function() peer_bcast('/at_pacgem %s %d', nm, g) end)
                            end
                            if ImGui.IsItemHovered and ImGui.IsItemHovered() then
                                local c = pacCap[nm]
                                pcall(function() ImGui.SetTooltip(string.format('%s\n%s\ncaps at level %d',
                                    nm, (c and c.spell) or '?', (c and c.cap) or 0)) end)
                            end
                        end
                        ImGui.Spacing(); ImGui.Separator(); ImGui.Spacing()
                    end
                end
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
                ImGui.Spacing(); ImGui.Separator(); ImGui.Spacing()
                -- Was 'Raid chat', which named the MECHANISM of the one setting under it rather than the
                -- feature. Both settings here are about tank XTargets, so the heading says that.
                ImGui.TextColored(0.85, 0.72, 0.35, 1.0, 'Auto-XTarget')
                ImGui.Spacing()
                do
                    -- MOVED OFF THE TOP BUTTON ROW. It sat there as a bare 'Auto' next to the Tank XT
                    -- button, which told you nothing without the button beside it for context - and the
                    -- button has gone. This is a set-once preference, which is what Settings is for.
                    local prev = autoXTank
                    autoXTank = ImGui.Checkbox('Keep tank XTargets up to date automatically', autoXTank)
                    if autoXTank ~= prev then
                        save_settings()
                        if autoXTank then xtankAutoRequested = true end
                    end
                    if ImGui.IsItemHovered and ImGui.IsItemHovered() then
                        pcall(function() ImGui.SetTooltip(
                            'Healers put the raid\'s tanks on their XTarget list so E3 XTarget heals\n'
                            .. 'can reach them. On: rechecked periodically and after a roster change.') end)
                    end
                end
                do
                    local prev = xtankAnnounce
                    xtankAnnounce = ImGui.Checkbox('Announce tank swaps in /rsay', xtankAnnounce)
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
                            -- A '?' beside the rows whose behaviour is not obvious from the label.
                            -- These are the things people have to be told once and then never again -
                            -- which is exactly what a hover is for, rather than a line of help text
                            -- taking up space forever.
                            if MINI_HELP[k] then
                                ImGui.SameLine()
                                ImGui.TextDisabled('?')
                                if ImGui.IsItemHovered and ImGui.IsItemHovered() then
                                    pcall(function() ImGui.SetTooltip(MINI_HELP[k]) end)
                                end
                            end
                            -- SHOWN ON EVERY TOON, NOT JUST THE ENCHANTER. This was gated on
                            -- ep_is_enchanter(), which hid it everywhere it would actually be used: the
                            -- person setting it is looking at the DRIVER's window, and the driver is not
                            -- the enchanter - so the field only appeared on the one character nobody has
                            -- on screen. Set it anywhere and it is broadcast to whoever does the casting,
                            -- the same way the rez order and the CotW toggle already work.
                            -- MOVED FROM THE 'placate' ROW, which no longer exists. This is the
                            -- placate gem number and it is still very much needed - it is what
                            -- decides which gem ep_ensure_gem mems into. It now rides on the
                            -- Smart Cast row, which is where placate is configured from.
                            -- The two halves of Group heals. Shown on its row so they read as part of
                            -- that section rather than as two more top-level settings.
                            -- WHICH ROWS COUNTERMEASURES SHOWS. Ticked = shown, so the default of
                            -- nothing-hidden reads correctly on a fresh install.
                            if k == 'protect' and (miniCures or miniMagic or miniArcane or miniPots) then
                                local n = 0
                                for _, g in ipairs(cm_rows()) do
                                    n = n + 1
                                    if n % 3 == 1 then ImGui.TextDisabled('     ') else ImGui.SameLine() end
                                    local was = not cm_hidden(g)
                                    local now = ImGui.Checkbox(g .. '##cmrow_' .. g, was)
                                    if now ~= was then
                                        cmOff[g] = (not now) or nil
                                        dirty = true
                                    end
                                end
                            end
                            if k == 'invis' and (miniInvisRows or miniInvisCombo) then
                                ImGui.SameLine()
                                local wasR = miniInvisRows
                                miniInvisRows = ImGui.Checkbox('coverage##at_inv_rows', miniInvisRows)
                                if miniInvisRows ~= wasR then dirty = true end
                                ImGui.SameLine()
                                local wasC = miniInvisCombo
                                miniInvisCombo = ImGui.Checkbox('combo##at_inv_combo', miniInvisCombo)
                                if miniInvisCombo ~= wasC then dirty = true end
                                -- WHO CASTS EACH ROW, configured here rather than in the mini window.
                                -- Only shown when the combo is on, because that is the only thing that
                                -- uses a pick.
                                if miniInvisCombo then draw_invis_picks() end
                            end
                            if k == 'groupheals' and (miniClicks or miniCombos) then
                                ImGui.SameLine()
                                local wasC = miniClicks
                                miniClicks = ImGui.Checkbox('class buttons##at_gh_mgb', miniClicks)
                                if miniClicks ~= wasC then dirty = true end
                                ImGui.SameLine()
                                local wasK = miniCombos
                                miniCombos = ImGui.Checkbox('combos##at_gh_combo', miniCombos)
                                if miniCombos ~= wasK then dirty = true end
                            end
                            -- The placate gem field used to sit here. It is a DUPLICATE: the same
                            -- setting has its own 'Pacify gems' block higher up in Settings, which
                            -- is where it belongs. Two controls for one value is a way to be unsure
                            -- which one you last changed.
                            if k == 'burns' and miniBurns then
                                ImGui.SameLine()
                                -- Three named views instead of a "full detail" tick, because there are
                                -- three now and a checkbox cannot say which of the other two you get.
                                local wasV = miniBurnView
                                for vi, vlabel in ipairs({ 'compact', 'matrix', 'full' }) do
                                    if vi > 1 then ImGui.SameLine() end
                                    local on, vpushed = (miniBurnView == vi - 1), 0
                                    if on and ImGuiCol and ImGuiCol.Button then
                                        local okv = pcall(function()
                                            ImGui.PushStyleColor(ImGuiCol.Button, 0.20, 0.45, 0.70, 1.0)
                                        end)
                                        if okv then vpushed = 1 end
                                    end
                                    if ImGui.SmallButton(vlabel .. '##at_bv_' .. vlabel) then
                                        miniBurnView = vi - 1
                                    end
                                    pop_state_button(vpushed)
                                end
                                if ImGui.IsItemHovered and ImGui.IsItemHovered() then
                                    pcall(function() ImGui.SetTooltip(
                                        'compact - one line each, ready count and dots\n' ..
                                        'matrix  - a column per burn tier\n' ..
                                        'full    - every item, timers and names') end)
                                end
                                local nowT = (miniBurnView == 2)
                                if miniBurnView ~= wasV then
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
                        -- WHAT EACH CHECKED HEAL SHOUTS. One field per member of THIS combo, because the
                        -- announce is per class-and-ability and that is exactly what a member is.
                        -- Placeholder shows the default, so an empty box reads as "the normal one" rather
                        -- than as silence - and clearing a box restores the default rather than muting it.
                        for _, m in ipairs(c.members) do
                            local mcls, mkey = combo_parse(m)
                            local me = mkey and mgb_entry(mkey)
                            if mcls and me then
                                local sk  = mgb_say_key(mcls, me)
                                local cur = mgbSay[sk] or ''
                                -- The DEFAULT goes in the label, not as an InputText hint. Nothing else in
                                -- this file uses InputText at all, so its exact binding here is unproven,
                                -- and InputTextWithHint is a newer overload that some MQ ImGui builds do
                                -- not expose - it would fail inside a pcall and draw nothing at all.
                                -- Label text costs nothing and cannot fail.
                                ImGui.TextDisabled(string.format('   /rsay for %s  (default: %s)',
                                                   mgb_label(mcls, me), mgb_say_default(mcls, me)))
                                ImGui.SameLine()
                                ImGui.SetNextItemWidth(220)
                                local nv = cur
                                local okIn = pcall(function()
                                    nv = ImGui.InputText('##at_say_' .. ci .. '_' .. sk, cur)
                                end)
                                if okIn and type(nv) == 'string' and nv ~= cur then
                                    mgbSay[sk] = (nv ~= '') and nv or nil
                                    dirty = true
                                    -- Tell the group, so the character that actually says this line has it.
                                    pcall(function()
                                        peer_bcast('/at_mgbsay %s %s', sk, (nv ~= '') and nv or '-')
                                    end)
                                elseif not okIn then
                                    -- Say so rather than showing an empty gap where a field should be.
                                    ImGui.TextColored(0.95, 0.85, 0.30, 1.0, '(text field unavailable in this ImGui build)')
                                end
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

    end
    ImGui.End()
end

-- MUTE THE RELAY ECHO, AND KEEP TRYING UNTIL IT TAKES.
-- localecho is my own '--> (peer)' send lines; commandecho is the received-command lines on the far end.
-- This used to be a single guarded block at load: if MQ2DanNet was not up yet, it was skipped and never
-- attempted again - and AdventureTime itself loads the plugin later, when the peer channel is first
-- detected. So on a client where the plugin comes up late, every relayed command printed to chat for
-- the whole session and nothing ever turned it off.
-- Idempotent, so calling it repeatedly costs nothing.
atMuted = false
function mute_relay_echo()
    if atMuted then return end
    if not mq.TLO.Plugin('MQ2DanNet')() then return end
    pcall(function() mq.cmd('/squelch /dnet localecho off') end)
    pcall(function() mq.cmd('/squelch /dnet commandecho off') end)
    atMuted = true
    log('[sync] DanNet relay echo muted (localecho + commandecho off)')
end
mute_relay_echo()
-- Retried on the tick until it lands, then never again. The plugin can arrive seconds after we do.
atMuteRetryAt = mq.gettime() + 5000
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
-- BRINGING IT BACK. Closing the window with the X sets windowOpen false and there is nothing left on
-- screen to click, so the only way back was /at - which is easy to forget and not obviously a toggle.
-- These two say what they do and always OPEN rather than toggle, because someone typing them has just
-- lost the window and wants it back; a toggle would half the time close it again.
-- Bound here rather than with the rest because windowOpen and miniMode are locals declared far below
-- that block, and a bind up there would close over nothing.
pcall(function() mq.bind('/atui', function()
    windowOpen = true
    miniMode = true
    save_settings()
    printf('\ag[AdventureTime]\ax mini window open (\ay/atuie\ax for the full one)')
end) end)
pcall(function() mq.bind('/atuie', function()
    windowOpen = true
    miniMode = false
    save_settings()
    printf('\ag[AdventureTime]\ax expanded window open (\ay/atui\ax for the mini one)')
end) end)
-- TOP LEVEL, NOT INSIDE `if SHOW_UI`. It was moved next to its first use and landed inside the
-- driver-only branch, so on a WORKER the global was never created and the call further down - which is
-- outside that branch - died with "attempt to call global 'boot_step' (a nil value)".
-- The driver was fine, every worker crashed on load, and the driver kept relaunching them into the same
-- crash. Anything called from outside a SHOW_UI branch has to be DEFINED outside one.
atBootT0 = mq.gettime()
function boot_step(label, fn)
    local t0 = mq.gettime()
    local ok, err = pcall(fn)
    local ms = mq.gettime() - t0
    if ms >= 250 then
        log('[boot] %s took %dms', label, ms)
    end
    if not ok then log('\ar[boot] %s failed: %s\ax', label, tostring(err)) end
    return ms
end
if SHOW_UI then
    log('AdventureTime %s ready [%s] - \\ay/lua run adventuretime\\ax on each toon; open \\ay/at\\ax here and Give out.',
        VERSION, BUILD_TAG)
    log('   \\ay/atcoth\\ax starts the CoTH gather from any toon (\\ay/atcoth off\\ax to stop).')
    -- Said at startup because the moment you need it is the moment the window is gone, and a command
    -- you have never seen is no help then.
    log('   \\ay/atui\\ax reopens the mini window, \\ay/atuie\\ax the expanded one.')
    log('   \\ay/atpac\\ax re-announces my pacify ceiling (run it after memming a new rank).')
    log('   \\ay/atwipe\\ax holds all rezzes until the group zones (\\ay/atwipe off\\ax to release).')
    log('   \\ay/atburnaudit\\ax writes a file listing every burn, its real reuse, and whether its tier fits.')

-- RECOVER STRIPPED GEAR AT STARTUP. A file here means a placate run did not put the weapons back -
-- almost always because the client died mid-run. Nothing else will ever notice: the character just
-- fights on without an epic, and the only clue is a stack of DPS that quietly is not there.
-- Runs before anything else touches the character, and holds E3 while it works.
-- OFF THE CRITICAL PATH. This still has to happen - gear left stripped by a run that died mid-way is
-- invisible otherwise, and the character fights the whole session without an epic while nothing
-- notices - but it does not have to happen DURING load.
-- It reads a file, and if there is one it pauses E3, which now waits up to 2.5 seconds for confirmation
-- and retries once. That is several seconds of a startup that is already slow, spent on a case that is
-- rare and not urgent to the millisecond.
-- Deferred to the first tick five seconds in: late enough that the client has settled and Me.Inventory
-- reads properly, early enough that nobody has fought a pull unarmed.
epRecoverAt = mq.gettime() + 5000
function ep_recover_startup()
    local saved = ep_recovery_read()
    if not saved then return end
    log('\\ay[placate] found gear stripped by an unfinished run - putting it back\\ax')
    ep_pause()
    for _, slot in ipairs(EP_SLOTS) do
        local want = saved[slot] or ''
        local now = ''
        pcall(function() now = tostring(mq.TLO.Me.Inventory(slot).Name() or '') end)
        if want ~= '' and now ~= want then
            clear_cursor()
            pcall(function() mq.cmdf('/itemnotify "%s" leftmouseup', want) end)
            mq.delay(800, function() return (mq.TLO.Cursor.ID() or 0) ~= 0 end)
            if (mq.TLO.Cursor.ID() or 0) ~= 0 then
                pcall(function() mq.cmdf('/itemnotify %s leftmouseup', slot) end)
                mq.delay(1000, function()
                    return (mq.TLO.Me.Inventory(slot).Name() or '') == want
                end)
            end
            ep_stow_cursor()
            local got = ''
            pcall(function() got = tostring(mq.TLO.Me.Inventory(slot).Name() or '') end)
            log('   %s: %s', slot, (got == want) and ('restored ' .. want)
                                                 or ('\\arSTILL MISSING ' .. want .. '\\ax'))
        end
    end
    ep_resume('startup recovery')
    -- Only forget it once every slot matches. Anything short of that and the file stays, so the next
    -- start tries again - the whole point is that this cannot quietly give up.
    local ok = true
    for _, slot in ipairs(EP_SLOTS) do
        local want = saved[slot] or ''
        local now = ''
        pcall(function() now = tostring(mq.TLO.Me.Inventory(slot).Name() or '') end)
        if want ~= '' and now ~= want then ok = false end
    end
    if ok then ep_recovery_clear(); log('[placate] gear recovery complete')
    else log('\\ar[placate] gear recovery INCOMPLETE - will try again next start\\ax') end
end
else
    log('AdventureTime %s ready [%s] (worker - headless; obeying the driver).', VERSION, BUILD_TAG)
    -- FIND THE CURRENCY TAB ONCE, NOW, while nothing is waiting on an answer. The sweep costs up to
    -- three seconds; paying that inside a balance query is what made peers miss the reply window.
    -- Cached in altcurListTab afterwards, so every later read is immediate.
    pcall(function() altcur_show_tab(); altcur_done() end)
end
-- DRIVER ONLY. This populates the Pots status columns, which only exist on the driver - but it used to
-- run unconditionally, so all six toons each fired a full peers x items query pass at startup. Six
-- concurrent 80-query passes is 480 queries in a few seconds, and that self-inflicted burst was most
-- of the congestion the pacing above was working around. A worker has no status board to fill.
if SHOW_UI then refreshRequested = true end
DI.startedAt = mq.gettime()   -- clock the settling window from load, not from the first tick

-- Timed, because this was the multi-second startup gap and it took three attempts to find.
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

-- ===== WHERE STARTUP TIME GOES =====
-- There is a consistent multi-second gap between the banner and the first setting being restored, and it
-- has been blamed on whatever changed most recently more than once - the file migration took the blame
-- despite the same gap being in logs from before that code existed.
-- So: time each step and print anything slow. One number ends the argument.
-- Only slow steps are logged, so a healthy startup stays quiet.
boot_step('load settings', load_settings)
-- Say where they came from. On an upgrade this reads the old flat file once and then never again, and
-- "which file am I actually using" is the first question when something does not persist.
if SHOW_UI then
    log('[settings] %s', SETTINGS_LOADED_FROM and ('loaded from ' .. path_show(SETTINGS_LOADED_FROM))
        or 'no settings file found - starting from defaults')
    log('[settings] saving to %s', path_show(at_write(SETTINGS_NAME)))
end   -- restore persisted toggles before we talk to anyone
-- Announce what this character can pacify, once. Not on the heartbeat: the spell and its ceiling do not
-- change during a session unless something is re-memmed, and /atpac covers that.
-- Deferred slightly - the spellbook and gems are not reliably readable the instant a script starts.
pacAnnounceAt = mq.gettime() + 8000
load_combos()
mini_order_normalise()   -- fills in defaults / drops unknown keys from a stale settings file
-- The peer check was written and then never wired in, so the one diagnostic aimed at split/broken
-- networks has never run. Deferred rather than immediate: DanNet needs a moment to discover peers,
-- and asking too early reports everyone missing on a perfectly healthy setup.
-- A driver that has just (re)started has EMPTY state tables, while every worker still believes it has
-- already reported - so nothing would ever arrive and the buttons would stay blank forever. Restarting
-- the driver is not a roster change, so resync_group() never fired for it. Ask everyone to speak up.
-- NOT local: this chunk is at Lua's 200-local ceiling and one more tips it over.
-- 1200, NOT 4000. This is the driver telling the group "I am listening now, report everything" - and it
-- is only reached AFTER the driver's own binds are registered, which is the thing the delay was guarding
-- against. Four seconds of caution on top of that is four seconds of an empty Burns tab.
-- The workers' own startup settle exists for the same reason and is cut short by this message, so the
-- two were racing: whichever finished last decided when burns appeared. Asking sooner ends the race in
-- the useful direction.
driverResyncAt = SHOW_UI and (mq.gettime() + 1200) or 0

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

-- Say what this character has and where it stands. One read, no history, no assumption.
-- (The old warning that lived here - never poke the emblem to refresh the read, because on a ready pool
-- that FIRES it - died with the aug path. There is nothing to poke now: the item reports its own timer.)
pcall(function()
    local have = nv_have()
    if #have == 0 then
        log('[nv] none of the four in my bags yet - will keep looking')
        return
    end
    for _, i in ipairs(have) do
        local e = NV_SPLIT[i]
        local s = nv_secs_at(i)
        log('[nv]   %-11s %s', e.role, (s > 0) and ('on cooldown - ' .. nv_hms(s) .. ' left') or 'ready')
    end
end)

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
        atExitWhy = 'Close all pressed on this character'
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
                -- ANYONE BACK IN THE GROUP IS OFF THE HOOK. Checked before the departure sweep so an
                -- exit and re-entry inside the grace window cancels cleanly and nothing is sent at all.
                for m in pairs(pendingClose) do
                    if stillHere[m] then
                        pendingClose[m] = nil
                        log('[sync] %s came back within the grace period - worker left running', m)
                    end
                end
                for _, m in ipairs(lastGroupList) do
                    if not stillHere[m:lower()] and m:lower() ~= myName:lower() then
                        -- NOT CLOSED ON THE SPOT. Closing costs a script shutdown and a relaunch on
                        -- rejoin, and people bounce out of groups for reasons that resolve in seconds -
                        -- a zone, a corpse run, a mis-click. Two minutes of grace turns the common case
                        -- into nothing happening at all.
                        -- The cost of waiting: their rows keep updating in the UI while they are gone,
                        -- because a live worker still knows the driver name and keeps reporting.
                        if not pendingClose[m:lower()] then
                            pendingClose[m:lower()] = mq.gettime() + GROUP_CLOSE_GRACE
                            log('[sync] %s left the group - closing its worker in %ds unless it returns',
                                m, math.floor(GROUP_CLOSE_GRACE / 1000))
                        end
                    end
                end
            end
            lastGroupKey  = gk
            lastGroupList = now
            if peerCheckAt == 0 then peerCheckAt = mq.gettime() + 8000 end
            -- Not on the first look: startup already brings the group up, and doing it twice would
            -- fire a second round of pings and launches for no reason.
            -- DEBOUNCED, BUT WITH A CEILING. Each change used to push the resync 3s further out, so a
            -- roster that keeps churning defers it forever and the driver never re-reads anyone.
            -- resyncFirstAt remembers when the churn STARTED; once RESYNC_MAX_DEFER has passed we stop
            -- deferring and run one, however much the group is still moving.
            if not firstLook and SHOW_UI then
                local nowms = mq.gettime()
                if resyncFirstAt == 0 then resyncFirstAt = nowms end
                if (nowms - resyncFirstAt) >= RESYNC_MAX_DEFER then resyncAt = nowms
                else resyncAt = nowms + 3000 end
            end
        end
        if driverResyncAt > 0 and mq.gettime() >= driverResyncAt then
            driverResyncAt = 0
            for _, nm in ipairs(group_members()) do
                if nm:lower() ~= myName:lower() then peer_cmdf(nm, '/at_resync') end
            end
            log('[sync] asked the group to re-report (driver just started)')
        end
        -- GRACE EXPIRY. Deliberately re-checks the live roster rather than trusting the pending list:
        -- a rejoin that happened while no other roster change fired would otherwise still get closed.
        if SHOW_UI and next(pendingClose) then
            local hereNow = {}
            for _, m in ipairs(now) do hereNow[m:lower()] = true end
            for m, due in pairs(pendingClose) do
                if hereNow[m] then pendingClose[m] = nil
                elseif mq.gettime() >= due then
                    pendingClose[m] = nil
                    peer_cmdf(m, '/at_close')
                    prune_one(m)   -- no roster change is coming to clean this up; do it here
                    log('[sync] %s did not return - closing its worker and clearing its rows', m)
                end
            end
        end
        if resyncAt > 0 and mq.gettime() >= resyncAt then
            resyncAt, resyncFirstAt = 0, 0
            -- A FLOOR ON HOW OFTEN THIS CAN COST ANYTHING. resync_group prunes, pings, launches missing
            -- workers and asks all five for a full re-report. Enter/exit/enter spaced a few seconds
            -- apart used to buy three of those back to back.
            -- The prune still runs every time - it is local, free, and dropping a departed character's
            -- entries promptly is the whole point. Only the network half is rate limited.
            if (mq.gettime() - lastResyncAt) >= RESYNC_MIN_GAP then
                lastResyncAt = mq.gettime()
                pcall(resync_group)
            else
                pcall(resync_prune_only)
                log('[sync] roster changed again within %ds - pruned locally, skipped the re-report',
                    math.floor(RESYNC_MIN_GAP / 1000))
            end
        end
        -- Crash watch every 5s. The per-character gates inside (a silence limit derived from the
        -- beacons, two failed pings, a 2 minute cooldown) are what stop this becoming a launch loop.
        -- REPORT, do not swallow. A bare pcall here hid a nil-index in di_check_landed for eight builds:
        -- every call threw, no verdict ever ran, and any toon that fired the staff was silently locked out
        -- of DI because DI.watch could never be cleared. Rate-limited so a persistent fault says so once a
        -- minute instead of flooding, and it keeps running rather than disabling itself - a broken verdict
        -- is bad, but a DI system that quietly stops is exactly what we could not see.
        atphase('arcane'); pcall(arc_retry_tick)
        atphase('pots'); pcall(pot_retry_tick)
        atphase('phantom'); pcall(pw_tick)
        -- The Withdraw button only sets a request; the work happens here because it drives windows on
        -- a peer and waits on them.
        if dcGiveWant then
            local w = dcGiveWant; dcGiveWant = nil
            pcall(function() give_out_one(w.item, w.currency) end)
        end
        if tribGroupWant then
            local w = tribGroupWant; tribGroupWant = nil
            local sent = 0
            for _, nm in ipairs(group_members()) do
                local n = (counts[nm:lower()] or {})[w.item] or 0
                if n > 0 then
                    sent = sent + 1
                    -- Capped at what each actually holds, so a toon with 40 donates 40 rather than
                    -- failing on a request for 400.
                    local send = math.min(w.qty, n)
                    if nm:lower() == myName:lower() then
                        tribWant = { item = w.item, qty = send }
                    else
                        pcall(function()
                            peer_cmdf(nm, '/attribute %s %d', w.item:gsub(' ', '_'), send)
                        end)
                    end
                end
            end
            log('[tribute] asked %d character(s) to donate up to %d %s each', sent, w.qty, w.item)
            -- Long: several toons are walking to their own tribute masters.
            altCurRefresh = mq.gettime() + 45000
        end
        if tribWant then
            local w = tribWant; tribWant = nil
            pcall(function() trib_donate(w.item, w.qty) end)
            altCurRefresh = mq.gettime() + 2000   -- ours is already done; just let the counts settle
        end
        -- The one-shot pacify announce, once the client has settled.
        if pacAnnounceAt and mq.gettime() > pacAnnounceAt then
            pacAnnounceAt = nil
            pcall(pac_announce)
        end
        -- Poll for my corpse after a rez, until it shows up or the window closes. Cheap: one spawn read
        -- per tick, and only during the minute after standing up.
        if corpseLootUntil then
            if mq.gettime() > corpseLootUntil then
                corpseLootUntil = nil
                rezlog('[corpse] no corpse found within a minute of the rez - nothing to loot')
            else
                -- The exact corpse the rezzer named, if we were told. Falling back to a name search only
                -- when we were not - which is an older rezzer, or a rez nobody announced.
                local cid = 0
                if rezCorpseID then
                    local ty = ''
                    pcall(function() ty = tostring(mq.TLO.Spawn(rezCorpseID).Type() or '') end)
                    if ty == 'Corpse' then cid = rezCorpseID end
                else
                    pcall(function() cid = tonumber(mq.TLO.Spawn('pccorpse ' .. myName).ID()) or 0 end)
                end
                -- Not while zoning: the spawn list is unreliable mid-transition and a read there is how
                -- we would decide there is no corpse when there is.
                local zoning = false
                pcall(function() zoning = tlo_true(mq.TLO.Me.Zoning()) end)
                if cid > 0 and not zoning then
                    corpseLootUntil = nil
                    local lootID = cid
                    pcall(function() loot_my_corpse(lootID) end)
                    rezCorpseID = nil
                end
            end
        end
        if altReclaimWant then
            -- No quantity: Reclaim is all-or-nothing by design, so there is nothing to compute here.
            local w = altReclaimWant; altReclaimWant = nil
            pcall(function() altcur_reclaim(w.name) end)
        end
        if altReclaimAllWant then
            local w = altReclaimAllWant; altReclaimAllWant = nil
            local asked = 0
            for _, nm in ipairs(group_members()) do
                local n = (counts[nm:lower()] or {})[w.name] or 0
                if n > 0 then
                    asked = asked + 1
                    if nm:lower() == myName:lower() then
                        pcall(function() altcur_reclaim(w.name) end)
                    else
                        pcall(function() peer_cmdf(nm, '/atreclaim %s', w.name:gsub(' ', '_')) end)
                    end
                end
            end
            log('[altcur] asked %d character(s) to reclaim all their %s', asked, w.name)
            altCurRefresh = mq.gettime() + 8000
        end
        if altWithdrawAllWant then
            local w = altWithdrawAllWant; altWithdrawAllWant = nil
            -- EVERY character that has a balance, not just the richest. Picking one made sense while
            -- this was "get me enough to hand out"; for "withdraw all" it just left five toons holding
            -- currency they cannot use. Each converts its OWN, in parallel, so it is no slower.
            local asked = 0
            for _, nm in ipairs(group_members()) do
                local bal = (altCounts[nm:lower()] or {})[w.name]
                if type(bal) == 'number' and bal > 0 then
                    asked = asked + 1
                    if nm:lower() == myName:lower() then
                        pcall(function() altcur_pull(w.name, bal) end)
                    else
                        pcall(function() peer_cmdf(nm, '/atpull %s %d', w.name:gsub(' ', '_'), bal) end)
                    end
                end
            end
            log('[altcur] asked %d character(s) to withdraw all their %s', asked, w.name)
            altCurRefresh = mq.gettime() + 8000   -- longer: several may be converting at once
        end
        -- RE-READ BOTH SIDES. Every action on this row moves coins between bags and the currency tab,
        -- so re-reading only the balances left the row half stale - the top line still showing what
        -- was in bags before the withdraw, or before the tribute spent it.
        if altCurRefresh and mq.gettime() > altCurRefresh then
            altCurRefresh = nil
            local roster = group_members()
            local peers = {}
            for _, m in ipairs(roster) do if m:lower() ~= myName:lower() then peers[#peers + 1] = m end end
            -- ALL ITEMS, not just the alt one. query_all_counts REPLACES the counts table on entry -
            -- `counts = { [me] = {...} }` - so a partial query does not update a subset, it discards
            -- everything it was not asked about. Refreshing after a tribute therefore blanked every
            -- draught on the board.
            -- That is correct behaviour for a full refresh and simply cannot be used for a partial one,
            -- so this asks for everything. It is the same call Counts makes.
            pcall(function() query_all_counts(peers, all_items()) end)
            for _, it in ipairs(ALT_ITEMS) do pcall(function() query_alt_currency(roster, it) end) end
            statusCounts = {}
            for _, nm in ipairs(roster) do statusCounts[nm:lower()] = counts[nm:lower()] or {} end
            statusNames = roster
            uiStatus = 'Diamond Coin counts updated.'
        end
        if altPullWant then
            local w = altPullWant; altPullWant = nil
            pcall(function() altcur_pull(w.name, w.qty) end)
        end
        if epTestWant then
            local n = epTestWant; epTestWant = nil
            pcall(function() ep_soak_test(n) end)
        end
        -- Hand out any Smart Cast entries assigned to me BEFORE the queues run, so a mob queued this
        -- tick is worked this tick rather than next.
        -- REBALANCE ON THE TICK, not only when a mob is added. PAC_MOVE_GRACE means a freshly assigned
        -- entry is not eligible to move yet, so a burst of adds inside that window would settle nothing
        -- and - since the only other caller was the add itself - nothing would ever settle it later.
        -- Cheap: it exits immediately unless there is an un-sent entry past its grace worth moving.
        -- Check E3 is still where we put it BEFORE the placate and phantom ticks run, since those are
        -- the two that act on the assumption that it is held.
        -- ONE-SHOT, five seconds in. Cleared before it runs, so a throw inside cannot make it repeat.
        if epRecoverAt and mq.gettime() >= epRecoverAt then
            epRecoverAt = nil
            atphase('gear_recovery'); pcall(ep_recover_startup)
        end
        if not atMuted and atMuteRetryAt and mq.gettime() >= atMuteRetryAt then
            atMuteRetryAt = mq.gettime() + 5000
            pcall(mute_relay_echo)
        end
        -- The port probe. On the tick, staged, and every stage logged so the file names the read that
        -- kills the client rather than leaving us to guess a fourth time.
        if portProbeWant then
            local want = portProbeWant
            portProbeWant = nil
            atphase('port_probe'); atphase_flush(true)
            log('[portprobe] START - %d slot(s). Each step logs before it reads.', want)
            local ok, err = pcall(function()
                log('[portprobe] step 1: Me.Book(1).Name()')
                local n1 = 'ERR'
                pcall(function() n1 = tostring(mq.TLO.Me.Book(1).Name() or 'nil') end)
                log('[portprobe]   -> %s', n1)

                log('[portprobe] step 2: Me.Book(1).ID()')
                local i1 = -1
                pcall(function() i1 = tonumber(mq.TLO.Me.Book(1).ID()) or -1 end)
                log('[portprobe]   -> %d', i1)

                log('[portprobe] step 3: Spell(<id>).Category()  -- reading a spell BY ID')
                local c1 = 'ERR'
                if i1 > 0 then pcall(function() c1 = tostring(mq.TLO.Spell(i1).Category() or 'nil') end) end
                log('[portprobe]   -> %s', c1)

                log('[portprobe] step 4: Spell(<name>).Category() -- reading the same spell BY NAME')
                local c2 = 'ERR'
                if n1 ~= 'ERR' and n1 ~= 'nil' then
                    pcall(function() c2 = tostring(mq.TLO.Spell(n1).Category() or 'nil') end)
                end
                log('[portprobe]   -> %s', c2)

                -- Only now the walk, and only as far as asked. No delay: this is a measurement, and a
                -- yield is one more variable in something that has already misled me three times.
                log('[portprobe] step 5: walking %d slot(s), name only', want)
                local seen = 0
                for i = 1, want do
                    local nm = ''
                    pcall(function() nm = tostring(mq.TLO.Me.Book(i).Name() or '') end)
                    if nm ~= '' and nm ~= 'NULL' then seen = seen + 1 end
                end
                log('[portprobe]   -> %d name(s) in the first %d slot(s)', seen, want)

                log('[portprobe] step 6: same walk, reading Category by ID as well')
                local ports = {}
                for i = 1, want do
                    local nm, id = '', 0
                    pcall(function() nm = tostring(mq.TLO.Me.Book(i).Name() or '') end)
                    if nm ~= '' and nm ~= 'NULL' then
                        pcall(function() id = tonumber(mq.TLO.Me.Book(i).ID()) or 0 end)
                        if id > 0 then
                            local cat = ''
                            pcall(function() cat = tostring(mq.TLO.Spell(id).Category() or ''):lower() end)
                            if cat == 'transport' then
                                local sub = ''
                                pcall(function() sub = tostring(mq.TLO.Spell(id).Subcategory() or '?') end)
                                ports[#ports + 1] = string.format('%s (%s)', nm, sub)
                            end
                        end
                    end
                end
                log('[portprobe]   -> %d transport spell(s) found', #ports)
                for _, s in ipairs(ports) do log('[portprobe]      %s', s) end
            end)
            if not ok then log('\\ar[portprobe] THREW: %s\\ax', tostring(err)) end
            log('[portprobe] DONE - if you are reading this, nothing crashed.')
        end
        -- Ports. Both of these read the spellbook, so both belong here rather than where they were asked.
        if portScanWanted then
            portScanWanted = false
            atphase('port_scan'); atphase_flush(true)
            pcall(function()
                portBook[myName] = port_scan() or {}
                peer_bcast('/at_ports? %s', myName)
            end)
        end
        if portAskedBy then
            local who = portAskedBy
            portAskedBy = nil
            atphase('port_reply'); atphase_flush(true)
            pcall(function()
                local list = port_scan()
                if not list or #list == 0 then return end
                -- SMALL MESSAGES. The whole list went in ONE command: 24 ports at ~37 characters each is
                -- close to 900 characters relayed through DanNet in a single line, and that is what was
                -- killing the porters - they are the only characters that SEND one. A toon with no ports
                -- returns just above this line and never transmits, which is why they were never hit,
                -- and why /atportlist survived a 100-slot walk: it only ever logged.
                -- Four per message keeps each one around 150 characters. The receiver appends, so the
                -- order they arrive in does not matter.
                pcall(function() peer_cmdf(who, '/at_portsclr %s', myName) end)
                local parts = {}
                local function flush()
                    if #parts == 0 then return end
                    pcall(function() peer_cmdf(who, '/at_ports! %s %s', myName, table.concat(parts, ',,')) end)
                    parts = {}
                    -- A beat between messages: bunched relay traffic is what DanNet drops, and this is
                    -- the same reason the counts pass spaces its queries.
                    mq.delay(60)
                end
                for _, e in ipairs(list) do
                    parts[#parts + 1] = string.format('%s|%s|%d|%s', e.name, e.sub, e.lvl, e.kind or 'g')
                    if #parts >= 4 then flush() end
                end
                flush()
            end)
        end
        if (mq.gettime() - (atAliveAt or 0)) > 5000 then
            atAliveAt = mq.gettime()
            pcall(at_alive_touch)
        end
        atphase('invis'); pcall(invis_fire_tick)
        -- Bag counts, pushed. Change-gated so a stable inventory costs nothing, with a slow keepalive so
        -- a driver that restarted still gets a picture without asking.
        if not SHOW_UI and driverName then
            if (mq.gettime() - (countsPushAt or 0)) > 20000 then
                atphase('counts_push')
                local blob = counts_push_blob()
                if blob ~= countsPushLast or (mq.gettime() - (countsPushAt or 0)) > 120000 then
                    countsPushLast = blob
                    pcall(function() peer_cmdf(driverName, '/at_counts %s %s', myName, blob) end)
                end
                countsPushAt = mq.gettime()
            end
        end
        atphase('e3hold'); pcall(e3_assert_held)
        atphase('pacify'); pcall(pac_dispatch); pcall(pac_rebalance); pcall(pac_autoclear)
        atphase('placate'); pcall(ep_tick)
        if not epSaidHave and ep_is_enchanter() then
            epSaidHave = true
            epState[myName] = true
            pcall(function() peer_bcast('/at_ephave %s', myName) end)
            log('[placate] I can placate (%s) - I will work the queue',
                tostring(mq.TLO.Me.Class.ShortName() or '?'))
        end
        if not pwSaidHave and pw_have() then
            pwSaidHave = true
            pwState[myName] = pw_label()
            -- /at_pwhave had no handler either; the phantom panel it fed is gone. Left as a no-op
            -- rather than a command nobody receives.
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
        -- ONE CALL WITH EVERYTHING. Two back-to-back query_all_counts passes is not just wasteful, it
        -- is how the draughts came back blank: the second pass rebuilds the per-peer bookkeeping for
        -- the items IT was given, and the first pass's results were the collateral.
        -- A refresh means "tell me where everything is", so it reads one combined list.
        query_all_counts(peers, all_items())
        for _, it in ipairs(ALT_ITEMS) do pcall(function() query_alt_currency(peers, it) end) end
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
        if z ~= lastZoneID then
            lastZoneID = z; zoneSettleAt = mq.gettime() + 3000
            -- Zoned: the wipe is over by definition. Cleared per character rather than broadcast, so a
            -- toon still standing in the zone stays held until it comes back too.
            if rezWipe then
                rezWipe = false
                rezlog('\\ag[rez] zoned - wipe mode cleared, rezzing again\\ax')
            end
        end
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
    if (mq.gettime() - lastDiscPoll) > 1000 then
        atphase('disc_watch')   -- disc watcher: start/fade log, and catch discs cut short
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
    if burnPollOn and mq.gettime() > burnStartAt and (mq.gettime() - lastBurnPoll) > 2000 then
        atphase('burn_poll')   -- read MY watched item timers locally (cheap), push changes
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
        atphase('di_read_self')
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
            -- Nothing to pass any more: the tank asks, so a staff going down is simply a fact this
            -- character reports rather than a turn it has to hand on.
            if not DI.watch then DI.saidStaffDown = true end
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
        -- PUSH AFTER AN ACTION, WHATEVER THE READS SAY.
        -- The key is built from the client's own timers, and those are exactly what does not move when we
        -- fire something - TimerReady and Timer both sit at 0 for a while, and at load both read 0 even on
        -- a staff that is minutes into reuse. So firing changes nothing the key can see, no push goes out,
        -- and the tank keeps ranking this character on a picture taken before the cast.
        -- We do not need the client to tell us what we just did. DI.pushNow is set by every fire, and it
        -- forces one push through - which is the moment the information is most worth having and least
        -- likely to be in the reads.
        if DI.pushNow or key ~= DI.key or (mq.gettime() - DI.lastPush) > (ic and 4000 or 20000) then
            DI.pushNow = nil
            DI.key, DI.lastPush = key, mq.gettime()
            -- saveName TOO. The peer path has always carried it and this one never did, so every
            -- character had a name for everybody else's save and none for its own - and the tank reads
            -- its OWN entry, which is why the panel said 'a save' instead of 'DI'.
            DI.state[myName] = { staff = a, emeralds = b, dgReady = c, saveUp = d,
                                 saveName = (e and e ~= '') and e or nil, updated = mq.gettime() }
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
        -- THE FAST PATH FIRST. On the tank this decides and asks; on everyone else it returns at once.
        -- It runs BEFORE di_tick so that when it is working, the old ladder sees a covered tank and never
        -- reaches for anything - the stand-down it broadcasts is the same one the ladder already honours.
        atphase('diq')
        local oks, errs = pcall(diq_self_check)
        if not oks then log('\\ar[diq] self-check error: %s\\ax', tostring(errs)) end
        local okq, errq = pcall(diq_tick)
        if not okq then log('\\ar[diq] error: %s\\ax', tostring(errq)) end
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
    -- NIGHTVEIL, OUTSIDE THE REZ GATE. This used to sit inside the auto-rez heartbeat because that is
    -- where the other clicky state is reported - but the emblem has nothing to do with rezzing, and
    -- riding along meant it stopped being polled entirely whenever auto-rez was off or a give-out was
    -- running. The symptom is a button that never leaves whatever colour it was when the gate closed.
    -- Change-gated the same way, so a stable state still costs one comparison rather than a message.
    -- WRAPPED, BECAUSE OF WHAT IT SITS IN FRONT OF. Moving this ahead of the rez heartbeat put a purely
    -- cosmetic button indicator upstream of the load-bearing part of the pulse - so when nv_state() threw
    -- on a nil (2026-08-05, missing declarations), the error took the pulse down before the rez state
    -- broadcast ran. rezReady never filled, and the visible symptom was "we aren't parsing rez items",
    -- which points nowhere near the actual fault.
    -- A rez chain must not be able to stop because a button could not decide what colour to be.
    -- BUT SAY WHEN IT FAILS. A bare pcall here swallowed the error completely, so a throw inside looked
    -- exactly like "this character has nothing to report": nvState stayed empty, the panel said nobody
    -- was carrying anything, and the log was silent about it. Reported once per distinct error, so a
    -- repeating fault does not fill the log but also cannot hide.
    local nvOk, nvErr = pcall(function()
        -- NO POKE HERE. It used to sit on a ten minute timer and it was firing the emblems. nv_secs()
        -- counts down from the recorded click without needing to ask the client anything.
        -- The ITEM NAME rides along, because the panel groups by item now. '-' is the wire form of
        -- "none", since an empty trailing argument does not survive the trip.
        -- Invis is a fast-changing state - it drops the moment you act - so this is change-gated like
        -- the rest and costs nothing while it is not moving.
        do
            local n, u = invis_self()
            local ik = n .. '/' .. u
            if invisLast ~= ik then
                invisLast = ik
                if SHOW_UI then invisState[myName] = { norm = n, und = u, updated = mq.gettime() }
                elseif driverName then peer_cmdf(driverName, '/at_invis %s %d %d', myName, n, u) end
            end
        end
        -- EVERY ITEM THIS CHARACTER HOLDS, as index:seconds pairs. The change key is the whole list, so
        -- one item coming off cooldown re-pushes the lot - which is cheaper than tracking four keys and
        -- cannot get them out of step with each other.
        local parts = {}
        for _, i in ipairs(nv_have()) do
            parts[#parts + 1] = string.format('%d:%d', i, nv_secs_at(i))
        end
        local list = (#parts > 0) and table.concat(parts, ',') or '-'
        local nk = list
        -- ON CHANGE, PLUS A SLOW KEEPALIVE. Change-gating alone means that if the driver's copy is ever
        -- dropped - a roster event prunes these tables - nothing re-sends it, because from this side
        -- nothing changed. The entry then stays missing until the cooldown happens to tick over.
        if (mq.gettime() - (nvPushAt or 0)) > 30000 then nvLast = '' end
        if nvLast ~= nk then
            nvPushAt = mq.gettime()
            nvLast = nk
            if SHOW_UI then
                local items = {}
                for _, i in ipairs(nv_have()) do items[i] = nv_secs_at(i) end
                nvState[myName] = { items = items, updated = mq.gettime() }
            elseif driverName then
                peer_cmdf(driverName, '/at_nvstate %s %s', myName, list)
            end
        end
    end)
    if not nvOk then
        local e = tostring(nvErr)
        if nvErrLast ~= e then
            nvErrLast = e
            log('\\ar[nv] state push failed: %s\\ax', e)
        end
    end
    if rezAuto and not distributing then
        -- ON CHANGE, plus a slow keepalive. This used to be a flat 2-5s heartbeat because the baton read
        -- the raw cooldown number; now that peers count it down themselves (rez_peer_secs), the only
        -- things worth sending are the discontinuities - a clicky got used, one came up, I zoned, I died.
        -- The keepalive is not for freshness, it is so a DROPPED message heals and so a peer that has
        -- never heard of me learns I exist.
        local cr, tk, cw = my_rez_secs(CROWN_ITEM), my_rez_secs(TOKEN_ITEM), my_cotw_secs()
        local dv = my_divine_secs()
        -- REPORT AS UNAVAILABLE WHILE FEIGNING, rather than leaving peers to discover it by timeout. The
        -- chain is built from these numbers, so saying "nothing ready" here is what actually keeps a
        -- feigned character out of it - the local gates above only stop this toon acting, they do not
        -- stop it being elected and holding the baton for the full wait first.
        -- Invis rides with feigning here, not just in the local gate. The local gate stops this toon
        -- acting; it does not stop the chain electing it and holding the baton for the full wait first.
        if am_feigning() or am_invis() then cr, tk, cw, dv = -1, -1, -1, -1 end
        local dead = false; pcall(function() dead = tlo_true(mq.TLO.Me.Dead()) end)
        local zone = 0; pcall(function() zone = tonumber(mq.TLO.Zone.ID()) or 0 end)
        local al = dead and 0 or 1
        -- Buckets, not raw seconds: a ticking countdown changes every second and would defeat the whole
        -- point. What the baton cares about is ready-or-not, so that is what triggers a send.
        -- CotW carries ownership as well as readiness, so the key tracks both: -1 (don't own) must be
        -- distinguishable from a live cooldown, or a shaman who has just bought the AA never re-reports.
        -- Divine is in the key for the same reason CotW is: a cleric memming it mid-session goes from
        -- "cannot cast" to "ready", and without it in the key that change never triggers a report - so
        -- the group would keep spending clickies while a free rez sat there.
        local key = string.format('%d/%d/%d/%d/%d/%d', (cr == 0) and 0 or 1, (tk == 0) and 0 or 1,
                                  (cw < 0) and 2 or ((cw == 0) and 0 or 1), al, zone,
                                  (dv < 0) and 2 or ((dv == 0) and 0 or 1))
        -- 2s while a corpse is in the zone, 20s otherwise. The election now decides everything else
        -- locally; the ONLY thing it still needs the network for is knowing a peer's script is alive
        -- and what its clicky is doing. Both matter exactly when someone is dead, so that is when the
        -- beat tightens - and it costs nothing the rest of the time.
        local due = (mq.gettime() - lastRezReadyPoll) > (rez_event_now() and 2000 or 20000)
        if key ~= rezReadyKey or due then
            rezReadyKey = key
            lastRezReadyPoll = mq.gettime()
            rezReady[myName] = { crown = cr, token = tk, cotw = cw, divine = dv, alive = (al == 1), zone = zone, updated = mq.gettime() }
            -- cotw goes LAST on the wire on purpose: a toon still on the previous build sends five args,
            -- the new bind reads the sixth as nil, and it becomes -1 ("doesn't own"). A mixed-build
            -- window therefore degrades to exactly the current behaviour instead of desyncing.
            peer_bcast('/at_rezready %s %d %d %d %d %d %d', myName, cr, tk, al, zone, cw, dv)
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
        atphase('rez_tick')
        lastRezPoll = mq.gettime(); rez_announce_ready(); rez_autoaccept(); rez_tick()
    end
    accept_incoming()
    atphase('doevents'); mq.doevents()
    -- Flush FIRST, then mark idle. The other way round overwrote the tick's actual work with 'idle'
    -- before it was ever written down.
    atphase_flush()
    atphase('idle')
    mq.delay(250)
    -- Label goes LAST in the block so the client_ready skip at the top does not jump into the scope of
    -- any local declared in the body - Lua permits a goto to a label at the end of a block precisely
    -- for this pattern.
    ::continue_tick::
end

pcall(function() mq.unbind('/at') end)
pcall(function() mq.unbind('/atuie') end)
pcall(function() mq.unbind('/atui') end)
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
pcall(function() mq.unbind('/at_distaff') end)
pcall(function() mq.unbind('/at_distaffprobe') end)
pcall(function() mq.unbind('/at_distaffreport') end)
pcall(function() mq.unbind('/at_diack') end)
pcall(function() mq.unbind('/at_diclaim') end)
pcall(function() mq.unbind('/atstaff') end)
pcall(function() mq.unbind('/at_disaved') end)
pcall(function() mq.unbind('/at_dineed') end)
pcall(function() mq.unbind('/at_didone') end)
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
pcall(function() mq.unbind('/at_rezretire') end)
pcall(function() mq.unbind('/at_rezrdy?') end)
pcall(function() mq.unbind('/at_rezrdy!') end)
pcall(function() mq.unbind('/at_rezskip') end)
pcall(function() mq.unbind('/at_rezdone') end)
pcall(function() mq.unbind('/at_rezorder') end)
pcall(function() mq.unbind('/at_rezorder?') end)
-- SAY WHY IT ENDED, AND WHEN. A clean shutdown and a crash leave an identical log - it simply stops -
-- so "did it exit or did it die" has been unanswerable, and that is the first question when somebody
-- reports it restarting on its own.
-- A restart with no stop line before it means the previous instance did NOT exit through here: it was
-- killed, the client went down, or /lua stop was used. A restart WITH one means something asked it to.
pcall(function()
    log('=== AdventureTime stopping: %s ===', atExitWhy or '/lua stop, a reload, or the client closing')
end)
-- NEVER LEAVE THE ENCHANTER STRIPPED. Whatever route we exited by, put the weapons back before the
-- script stops - there is nothing left running afterwards that could.
-- Remove the heartbeat so a deliberate restart is not blocked by our own file.
pcall(function() os.remove(at_alive_path()) end)
pcall(function() ep_restore('script stopping') end)
pcall(function() mq.unbind('/at_bags') end)
pcall(function() mq.unbind('/atregear') end)
pcall(function() mq.unbind('/atslots') end)
pcall(function() mq.unbind('/atsongs') end)
pcall(function() mq.unbind('/atcurrency') end)
pcall(function() mq.unbind('/atcothaug') end)
pcall(function() mq.unbind('/atnv') end)
pcall(function() mq.unbind('/atburnaudit') end)
pcall(function() mq.unbind('/atrange') end)
pcall(function() mq.unbind('/atreclaim') end)
pcall(function() mq.unbind('/attab') end)
pcall(function() mq.unbind('/attribute') end)
pcall(function() mq.unbind('/attribprobe') end)
pcall(function() mq.unbind('/at_altrep') end)
pcall(function() mq.unbind('/at_altbal') end)
pcall(function() mq.unbind('/at_altbags') end)
pcall(function() mq.unbind('/atpull') end)
pcall(function() mq.unbind('/atplacatetest') end)
pcall(function() mq.unbind('/atplacategem') end)
pcall(function() mq.unbind('/at_ephave') end)
pcall(function() mq.unbind('/at_paccap') end)
pcall(function() mq.unbind('/atpac') end)
pcall(function() mq.unbind('/at_pacmark') end)
pcall(function() mq.unbind('/at_pacoor') end)
pcall(function() mq.unbind('/at_pacwho') end)
pcall(function() mq.unbind('/at_pacsent') end)
pcall(function() mq.unbind('/at_pacclear') end)
pcall(function() mq.unbind('/at_pacdel') end)
pcall(function() mq.unbind('/at_pacadd') end)
pcall(function() mq.unbind('/at_pacgem') end)
pcall(function() mq.unbind('/at_pacoff') end)
pcall(function() mq.unbind('/at_epcaster') end)
pcall(function() mq.unbind('/at_epgem') end)
pcall(function() mq.unbind('/at_mgbsay') end)
pcall(function() mq.unbind('/at_epmark') end)
pcall(function() mq.unbind('/at_epclear') end)
pcall(function() mq.unbind('/at_epdel') end)
pcall(function() mq.unbind('/at_epadd') end)
-- Everything else this script binds. These were left registered on /lua stop, so a stopped script
-- still owned 21 command names pointing at closures from a dead run.
pcall(function() mq.unbind('/at_cure') end)
pcall(function() mq.unbind('/at_cureprobe') end)
pcall(function() mq.unbind('/at_curestate') end)
pcall(function() mq.unbind('/at_diprobe') end)
pcall(function() mq.unbind('/at_healstate') end)
pcall(function() mq.unbind('/at_magic') end)
pcall(function() mq.unbind('/at_invis') end)
pcall(function() mq.unbind('/atportlist') end)
pcall(function() mq.unbind('/atinviscast') end)
pcall(function() mq.unbind('/at_ports?') end)
pcall(function() mq.unbind('/at_ports!') end)
pcall(function() mq.unbind('/at_portsclr') end)
pcall(function() mq.unbind('/at_portcast') end)
pcall(function() mq.unbind('/at_unvis') end)
pcall(function() mq.unbind('/atinvisprobe') end)
pcall(function() mq.unbind('/at_magicprobe') end)
pcall(function() mq.unbind('/at_magicstate') end)
pcall(function() mq.unbind('/at_mgbclick') end)
pcall(function() mq.unbind('/at_pot') end)
pcall(function() mq.unbind('/at_potprobe') end)
pcall(function() mq.unbind('/at_potstate') end)
pcall(function() mq.unbind('/at_nvclick') end)
pcall(function() mq.unbind('/at_nvstate') end)
pcall(function() mq.unbind('/at_quiet') end)
pcall(function() mq.unbind('/at_resync') end)
pcall(function() mq.unbind('/at_rezaccept') end)
pcall(function() mq.unbind('/at_rezcotw') end)
pcall(function() mq.unbind('/at_rezdivine') end)
pcall(function() mq.unbind('/atwipe') end)
pcall(function() mq.unbind('/at_wipe') end)
pcall(function() mq.unbind('/at_chainskip') end)
pcall(function() mq.unbind('/atdivine') end)
pcall(function() mq.unbind('/at_chainskip') end)
pcall(function() mq.unbind('/atdivine') end)
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
pcall(function() e3_release_all() end)   -- always hand our toon back to E3 on the way out
if SHOW_UI then mq.imgui.destroy(scriptName) end
