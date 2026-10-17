-- AdventureTime module: burns (1.22.0). The [Burn] list - read from this character's AdventureTime burn file or
-- its E3 ini - and the burn check (/atburncheck). Moved out of init.lua as it was; loaded in place with
-- at_module('burns'). Shares state with init.lua through globals: burnState, myName, log, BURN_FILE_USED...
local mq = require('mq')
local ImGui = require('ImGui')

-- Parse THIS toon's own [Burn] 5minBurn lines from its E3 INI -> bare names (strip the /...
local function e3_path_override()
    local dir
    dir = AT_SRC_DIR   -- the AdventureTime folder (this file sits in modules/ under it)
    local fh = io.open((dir or '') .. 'AdventureTime_e3path.txt', 'r')
    if not fh then return nil end
    local line = fh:read('*l'); fh:close()
    if not line then return nil end
    line = line:gsub('^%s+', ''):gsub('%s+$', ''):gsub('[/\\]+$', '')
    if line == '' or line:sub(1, 1) == ';' then return nil end
    return line
end

-- Last resort when none of the guessed paths hit: LOOK for the file.
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
    d = AT_SRC_DIR   -- the AdventureTime folder (this file sits in modules/ under it)
    local fh = io.open((d or '') .. 'AdventureTime_e3path.txt', 'w')
    if not fh then return end
    fh:write('; found automatically - delete this file to search again\n')
    fh:write(dir .. '\n')
    fh:close()
end


-- AT'S OWN BURN LIST, per toon, in the Settings folder.
function burn_file_path()
    local base = (AT_MODULE_DIR ~= nil and AT_MODULE_DIR ~= '') and (AT_MODULE_DIR .. 'Settings\\') or ''
    if base == '' then
        local cfg = ''
        pcall(function() cfg = tostring(mq.TLO.MacroQuest.Path('config')() or '') end)
        base = (cfg ~= '') and (cfg .. '\\') or ''
    end
    return base .. 'adventuretime_burns_' .. ((myName ~= '') and myName or 'unknown') .. '.txt'
end
BURN_FILE_USED = nil   -- path the current BURN_WATCH came from, for the Burns tab

function burn_file_write_template(path)
    local fh = io.open(path, 'w')
    if not fh then return false end
    fh:write('; AdventureTime burn list for ' .. myName .. '\n')
    fh:write('; One line per ability the Burns tab should watch: <tier>=<exact item, AA or spell name>\n')
    fh:write('; Tiers are listed in the order they first appear. Lines starting with ; are ignored.\n')
    fh:write('; RGMercs: open its Rotations window, find the Burn rotation, and copy the names here.\n')
    fh:write('; Save, then press Reload INIs on the Burns tab.\n')
    fh:write('[Burn]\n')
    fh:write(';Quick Burn=Some Clicky Name\n')
    fh:write(';Long Burn=Some AA Name\n')
    fh:close()
    return true
end

function parse_burns()
    local own = burn_file_path()
    local of = io.open(own, 'r')
    if of then
        local list = parse_burn_file(of, own)
        -- AN EMPTY LIST DOES NOT SHADOW THE INI.
        if (list and #list > 0) or cast_backend() ~= 'e3' then
            BURN_FILE_USED = own
            return list
        end
        log('[burns] %s has no active lines - reading the E3 ini instead', path_show(own))
        return parse_burns_e3()
    end
    if cast_backend() ~= 'e3' then
        -- RGMercs build with no list yet: leave a template where the person will look, say so once.
        BURN_FILE_USED = nil
        if burn_file_write_template(own) then
            log('\\ay[burns] no burn list yet - wrote a template to %s. Fill it in and press Reload INIs.\\ax',
                path_show(own))
        else
            log('\\ay[burns] no burn list at %s and could not create one\\ax', path_show(own))
        end
        return nil
    end
    return parse_burns_e3()
end

function parse_burns_e3()
    -- The server TLO is NOT reliable for this: it returns 'Lazarus' on one machine and 'Project
    -- Lazarus' on another, and E3 names the file after the short form.
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
    BURN_FILE_USED = path
    return parse_burn_file(f, path)
end

function parse_burn_file(f, path)
    -- rank for a key: known keys keep their escalation order; anything else sorts after them by the
    -- order it first appeared in the file, so unrecognised names still display sensibly.
    local rankOf, seen, nextRank, sec = {}, {}, 0, ''
    local function rank_for(key)
        if not rankOf[key] then nextRank = nextRank + 1; rankOf[key] = nextRank end
        return rankOf[key]
    end
    local tierOf, keyOf, keysOf = {}, {}, {}
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
                    -- and EVERY burn it is listed under (1.21.3, the burn check: /atburncheck 15minBurn checks
                    -- all of 15minBurn's items, not only those whose lowest tier it is)
                    keysOf[nm] = keysOf[nm] or {}
                    local dup = false
                    for _, k in ipairs(keysOf[nm]) do if k:lower() == key:lower() then dup = true end end
                    if not dup then keysOf[nm][#keysOf[nm] + 1] = key end
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
    for nm, ti in pairs(tierOf) do list[#list + 1] = { name = nm, tier = ti, tkey = keyOf[nm] or '?', keys = keysOf[nm] } end
    for k in pairs(seen) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return rank_for(a) < rank_for(b) end)
    log('[burns] parsed %d burn item(s) from %s', #list, path_show(path))
    log('[burns] tiers found: %s', table.concat(keys, ', '))
    return list
end

-- ===== THE BURN CHECK (1.21.3) =====
-- /atburncheck <burn> takes, for every group member, that burn's items that are READY at that moment; each drops
-- off once its report says it went on cooldown or is running. What is left is shown greyed under Running now -
-- not an error, just what has not fired yet in that sequence (melee discs wait their turn). It ends when all
-- have fired, at the next check, or with /atburncheck off; each end is one log line.
BURNCHK = nil
burnWarn = burnWarn or {}   -- driver: char -> item -> why that line may not fire from a burn
function burn_key_set(list)
    local set = {}
    for k in tostring(list or ''):gmatch('[^+]+') do set[k:lower()] = true end
    return set
end
-- A burn line whose spell needs a friendly target: fired with the mob targeted, it may not go off (the shaman
-- spire). Read once per item from its spell. nil = nothing to say.
burnTT = burnTT or {}
function burn_target_warn(name, kind)
    if burnTT[name] ~= nil then return burnTT[name] or nil end
    local tt, ben = '', nil
    pcall(function()
        local sp
        if kind == 'i' then sp = mq.TLO.FindItem('=' .. name).Spell
        elseif kind == 'a' then sp = mq.TLO.Me.AltAbility(name).Spell
        else sp = mq.TLO.Spell(name) end
        tt = tostring(sp.TargetType() or '')
        ben = sp.Beneficial()
    end)
    if tt == 'NULL' then tt = '' end
    local friendly = tt:find('Single in Group', 1, true) or tt:lower():find('friendly', 1, true)
        or (tt == 'Single' and (ben == true or tostring(ben):upper() == 'TRUE'))
    if friendly then
        local why = 'needs a friendly target (' .. tt .. ')'
        burnTT[name] = why
        log('\\ay[burns] %s: its spell targets "%s" - fired from a burn with a mob targeted it may not go off\\ax', name, tt)
        return why
    end
    burnTT[name] = false
    return nil
end
-- Does this burn line put a lasting buff on the one who fires it (self, group, or a friendly single target)? Those
-- only count as fired once the buff shows (1.21.5: a spire clicked at the mob goes on cooldown and buffs nobody).
-- Nukes, mob debuffs and effects with no duration keep the cooldown rule. Read once per item from its spell.
burnExpectCache = burnExpectCache or {}
burnExpect = burnExpect or {}   -- driver: char -> item -> true when its buff is waited for
function burn_expects_buff(name, kind)
    if burnExpectCache[name] ~= nil then return burnExpectCache[name] end
    local tt, ben, dur = '', nil, 0
    pcall(function()
        local sp
        if kind == 'i' then sp = mq.TLO.FindItem('=' .. name).Spell
        elseif kind == 'a' then sp = mq.TLO.Me.AltAbility(name).Spell
        else sp = mq.TLO.Spell(name) end
        tt = tostring(sp.TargetType() or '')
        ben = sp.Beneficial()
        dur = tonumber(sp.Duration.TotalSeconds()) or 0
        if dur <= 0 then dur = (tonumber(sp.Duration()) or 0) * 6 end
    end)
    if tt == 'NULL' then tt = '' end
    local isBen = (ben == true) or tostring(ben):upper() == 'TRUE'
    local mine = tt == 'Self' or tt:find('^Group') ~= nil or tt:find('Single in Group', 1, true) ~= nil
        or tt:lower():find('friendly', 1, true) ~= nil or (tt == 'Single' and isBen)
    local yes = (dur > 0) and mine and (isBen or tt == 'Self' or tt:find('^Group') ~= nil) or false
    burnExpectCache[name] = yes
    return yes
end
-- WHY DID A BUFF ITEM SHOW NO BUFF? (1.22.3) Logging only, no behaviour change. Forsaken legs on Khulian and
-- Lunafeet went on cooldown with nothing in the buff or song window, and the disc watcher saw no new disc from
-- them either. Once per cooldown, 8s after it starts, this worker writes what its spell is and where the effect
-- could be: the running disc, and the spells it triggers (a click that casts X which lands Y).
burnDiag = burnDiag or {}
function burn_nobuff_diag(name, t, ds, it)
    -- ONLY A COOLDOWN WE SAW START (1.22.5): one already running when AT loaded began long ago, and its buff
    -- may have come and gone - six false lines on the 18:49 restart.
    if t <= 0 then burnDiag[name] = { ready = true }; return end
    local d = burnDiag[name]
    if not d then burnDiag[name] = { done = true }; return end
    if d.done then return end
    if not d.at then d.at = mq.gettime(); return end
    if ds > 0 then d.done = true; return end
    if (mq.gettime() - d.at) < BURNCHK_BUFF_GRACE then return end
    d.done = true
    if not burn_expects_buff(name, 'i') then return end
    local sp, tt, dur, disc = '?', '?', 0, ''
    pcall(function()
        sp = tostring(it.Spell.Name() or '?'); tt = tostring(it.Spell.TargetType() or '?')
        dur = tonumber(it.Spell.Duration.TotalSeconds()) or 0
    end)
    pcall(function() disc = tostring(mq.TLO.Me.ActiveDisc.Name() or '') end)
    local trig = {}
    for i = 1, 4 do
        local tn = ''
        pcall(function() tn = tostring(mq.TLO.Spell(sp).Trigger(i).Name() or '') end)
        if tn ~= '' and tn ~= 'NULL' then
            local b, s = 0, 0
            pcall(function() b = tonumber(mq.TLO.Me.Buff(tn).Duration.TotalSeconds()) or 0 end)
            pcall(function() s = tonumber(mq.TLO.Me.Song(tn).Duration.TotalSeconds()) or 0 end)
            trig[#trig + 1] = string.format('%s (buff %ds, song %ds)', tn, b, s)
        end
    end
    -- HOW FULL ARE THE WINDOWS? (1.22.16) The 03:47 30minBurn had four effects that land as songs on other
    -- nights (Ancestral Aid, Frenzied Devastation, Seditionist's Scourge, Battle Frenzy) never showing. A full
    -- song window refuses new ones; the counts say whether that is it.
    local nb, ns = -1, -1
    pcall(function() nb = tonumber(mq.TLO.Me.CountBuffs()) or -1 end)
    pcall(function() ns = tonumber(mq.TLO.Me.CountSongs()) or -1 end)
    rezlog('[burns] %s: on cooldown %ds with no buff - its spell "%s" (%s, %ds) is in neither window; running disc: %s; it triggers: %s; buffs %d, songs %d',
        name, math.floor((mq.gettime() - d.at) / 1000), sp, tt, dur, (disc ~= '' and disc ~= 'NULL') and disc or 'none',
        (#trig > 0) and table.concat(trig, ', ') or 'nothing', nb, ns)
    -- WHAT IS IN THE SONG WINDOW (1.22.16), so the ones worth blocking in the E3 ini can be picked from a log.
    local songs = {}
    for i = 1, 30 do
        local n = ''
        pcall(function() n = tostring(mq.TLO.Me.Song(i).Name() or '') end)
        if n ~= '' and n ~= 'NULL' then songs[#songs + 1] = n end
    end
    if #songs > 0 then rezlog('[burns]   songs up now: %s', table.concat(songs, ', ')) end
end
-- WHAT A BURN LINE CASTS (1.22.15), for the hovers. The worker reads it once per item - the item's or AA's
-- spell, or the disc itself - and sends it with the item's first report; the driver describes it from the
-- spell table (target type, duration).
burnSpellCache = burnSpellCache or {}   -- worker: name -> spell it casts ('' when it casts nothing readable)
burnSpell = burnSpell or {}             -- driver: char -> item -> spell
function burn_spell_of(name, kind)
    local v = burnSpellCache[name]
    if v ~= nil then return v end
    local sp = ''
    pcall(function()
        if kind == 'i' then sp = tostring(mq.TLO.FindItem('=' .. name).Spell.Name() or '')
        elseif kind == 'a' then sp = tostring(mq.TLO.Me.AltAbility(name).Spell.Name() or '')
        else sp = tostring(mq.TLO.Spell(name).Name() or '') end
    end)
    if sp == 'NULL' then sp = '' end
    burnSpellCache[name] = sp
    return sp
end
function burn_tip(c, it, st)
    if not c and st then
        for ch, t in pairs(burnState) do if t[it] == st then c = ch; break end end
    end
    local sp = c and (burnSpell[c] or {})[it] or nil
    if not sp or sp == '' then return it end
    local tt, dur = '', 0
    pcall(function()
        tt = tostring(mq.TLO.Spell(sp).TargetType() or '')
        dur = tonumber(mq.TLO.Spell(sp).Duration.TotalSeconds()) or 0
    end)
    if tt == 'NULL' then tt = '' end
    local d = (dur > 0) and string.format('%d:%02d', math.floor(dur / 60), dur % 60) or 'no duration'
    local how = ((tt ~= '') and (tt .. ', ') or '') .. d
    if sp == it then return string.format('%s\n%s', it, how) end
    return string.format('%s\ncasts %s (%s)', it, sp, how)
end
BURNCHK_BUFF_GRACE = 8000   -- after its cooldown starts, how long a buff item gets for its buff to show
function burn_in(st, burn)
    local b = burn:lower()
    if st.keys and st.keys[b] then return true end
    return (st.tkey or ''):lower() == b
end
function burncheck_stop(why)
    local c = BURNCHK
    if not c then return end
    BURNCHK = nil
    local left, n = {}, 0
    for _, ch in ipairs(c.order) do
        local its = {}
        for it in pairs(c.pending[ch] or {}) do its[#its + 1] = it; n = n + 1 end
        if #its > 0 then table.sort(its); left[#left + 1] = ch .. ': ' .. table.concat(its, ', ') end
    end
    local nob, nn = {}, 0
    for _, ch in ipairs(c.order) do
        local its = {}
        for it in pairs((c.nobuff or {})[ch] or {}) do its[#its + 1] = it; nn = nn + 1 end
        if #its > 0 then table.sort(its); nob[#nob + 1] = ch .. ': ' .. table.concat(its, ', ') end
    end
    local secs = math.floor((mq.gettime() - c.at) / 1000)
    local extra = (nn > 0) and ('; fired, but no buff showed: ' .. table.concat(nob, ' | ')) or ''
    if n == 0 and nn == 0 then
        log('[burncheck] %s: all %d fired in %ds', c.name, c.total, secs)
    elseif n == 0 then
        log('[burncheck] %s (%s after %ds): all %d fired%s', c.name, why, secs, c.total, extra)
    else
        log('[burncheck] %s (%s after %ds): %d of %d fired; not fired: %s%s', c.name, why, secs, c.total - n, c.total,
            table.concat(left, ' | '), extra)
    end
end
function burncheck_start(name)
    local c = { name = name, at = mq.gettime(), pending = {}, order = {}, total = 0, notReady = 0, anyListed = false }
    for _, ch in ipairs(ordered_members()) do
        for it, st in pairs(burnState[ch] or {}) do
            if burn_in(st, name) then
                c.anyListed = true
                if (st.secs or 0) == 0 and not st.active then
                    if not c.pending[ch] then c.pending[ch] = {}; c.order[#c.order + 1] = ch end
                    c.pending[ch][it] = true
                    c.total = c.total + 1
                else
                    c.notReady = c.notReady + 1
                end
            end
        end
    end
    if not c.anyListed then
        local seen, list = {}, {}
        for _, ch in ipairs(ordered_members()) do
            for _, st in pairs(burnState[ch] or {}) do
                for k in pairs(st.keys or { [(st.tkey or '?'):lower()] = true }) do
                    if not seen[k] then seen[k] = true; list[#list + 1] = k end
                end
            end
        end
        table.sort(list)
        log('\\ay[burncheck] nobody has a burn named "%s" - the names seen: %s\\ax', name,
            (#list > 0) and table.concat(list, ', ') or 'none (no burn reports yet)')
        return
    end
    -- THE SAME BURN AGAIN KEEPS THE CHECK (1.22.11). A burn hotkey pressed twice used to end the first check
    -- and start a fresh one with only what was still ready - 02:08-02:10 log: three 10minBurn checks in two
    -- minutes, and each one dropped what the last had not seen fire. Now the running check stays: what has
    -- not fired stays on the list, and anything ready that it was not already watching joins it.
    local cur = BURNCHK
    if cur and (cur.name or ''):lower() == name:lower() then
        cur.seen = cur.seen or {}
        local added = 0
        for _, ch in ipairs(c.order) do
            for it in pairs(c.pending[ch]) do
                if not ((cur.seen[ch] or {})[it]) then
                    if not cur.pending[ch] then cur.pending[ch] = {}; cur.order[#cur.order + 1] = ch end
                    cur.pending[ch][it] = true
                    cur.seen[ch] = cur.seen[ch] or {}; cur.seen[ch][it] = true
                    cur.total = cur.total + 1
                    added = added + 1
                end
            end
        end
        local waiting = 0
        for _, ch in ipairs(cur.order) do for _ in pairs(cur.pending[ch] or {}) do waiting = waiting + 1 end end
        log('[burncheck] %s pressed again - keeping the check (%d still waiting%s)', cur.name, waiting,
            (added > 0) and string.format(', %d newly ready added', added) or '')
        return
    end
    if BURNCHK then burncheck_stop('a new check') end   -- only for a burn that exists: a typo leaves it running
    log('[burncheck] %s: watching %d ready item(s) on %d character(s)%s', name, c.total, #c.order,
        (c.notReady > 0) and string.format(' (%d already on cooldown, left out)', c.notReady) or '')
    if c.total == 0 then return end
    c.seen = {}
    for ch, its in pairs(c.pending) do c.seen[ch] = {}; for it in pairs(its) do c.seen[ch][it] = true end end
    BURNCHK = c
end
function burncheck_tick()
    local c = BURNCHK
    if not c then return end
    local n, nn, now = 0, 0, mq.gettime()
    c.nobuff, c.firedAt = c.nobuff or {}, c.firedAt or {}
    for _, ch in ipairs(c.order) do
        for it in pairs(c.pending[ch] or {}) do
            local st = (burnState[ch] or {})[it]
            local fired = st and ((st.secs or 0) ~= 0 or st.active)
            if fired and (st.active or not (burnExpect[ch] or {})[it]) then
                c.pending[ch][it] = nil                                   -- fired (and its buff showed, if it has one)
            elseif fired then
                -- cooldown started, buff not seen yet: give the report a moment, then call it what it is
                local k = ch .. '|' .. it
                c.firedAt[k] = c.firedAt[k] or now
                if now - c.firedAt[k] >= BURNCHK_BUFF_GRACE then
                    c.pending[ch][it] = nil
                    c.nobuff[ch] = c.nobuff[ch] or {}
                    c.nobuff[ch][it] = true
                else
                    n = n + 1
                end
            else
                n = n + 1
            end
        end
        for it in pairs(c.nobuff[ch] or {}) do
            local st = (burnState[ch] or {})[it]
            if st and st.active then c.nobuff[ch][it] = nil else nn = nn + 1 end   -- it landed after all
        end
    end
    -- done when nothing waits; a no-buff one stays on show until cleared or the next check
    if n == 0 and nn == 0 then burncheck_stop('all fired')
    elseif n == 0 and not c.saidNoBuff then
        c.saidNoBuff = true
        log('\\ay[burncheck] %s: everything fired; %d went on cooldown with no buff showing (amber under Running now)\\ax', c.name, nn)
    end
end
-- Under Running now: what has not fired yet, by character, greyed (1.21.4: a column per character like the
-- tiles above, one short name a line with its icon, at most BURNCHK_ROWS a column - the rest on hover. The
-- first version ran every item of a character along one line; with 62 items it could not be read).
BURNCHK_ROWS = 6
BURNCHK_CHARS = 13
function draw_burncheck()
    local c = BURNCHK
    if not c then return end
    local cols, left, nob = {}, 0, 0
    for _, ch in ipairs(c.order) do
        local its, nb = {}, {}
        for it in pairs(c.pending[ch] or {}) do its[#its + 1] = it end
        for it in pairs((c.nobuff or {})[ch] or {}) do nb[#nb + 1] = it end
        if #its + #nb > 0 then
            table.sort(its); table.sort(nb)
            cols[#cols + 1] = { ch = ch, its = its, nb = nb }; left = left + #its; nob = nob + #nb
        end
    end
    if #cols == 0 then return end
    local secs = math.floor((mq.gettime() - c.at) / 1000)
    ui_text(UI_HEAD, 'Not fired yet')
    ImGui.SameLine()
    ImGui.TextDisabled(string.format('%s - %d of %d left, %d:%02d', c.name, left, c.total, math.floor(secs / 60), secs % 60))
    if nob > 0 then
        ImGui.SameLine()
        ui_text(UI_WAIT, string.format('%d fired, no buff', nob))
        if ui_tip_hover() then pcall(function() ImGui.SetTooltip('Went on cooldown, but its buff never showed (for example a spire clicked with the mob targeted)') end) end
    end
    ImGui.SameLine()
    if ImGui.SmallButton('x##burnchk_x') then burncheck_stop('cleared'); return end
    if ui_tip_hover() then pcall(function() ImGui.SetTooltip('Clear this list (/atburncheck off)') end) end
    local ts = math.max(12, math.floor(ui_icon_size() * 0.8))
    local flags = (ImGuiTableFlags.SizingFixedFit or 0) + (ImGuiTableFlags.BordersInnerV or 0)
    if not ImGui.BeginTable('##burnchk', #cols, flags) then return end
    for _ = 1, #cols do ImGui.TableSetupColumn('') end
    ImGui.TableNextRow()
    for _, col in ipairs(cols) do
        ImGui.TableNextColumn()
        ui_text(UI_LABEL, string.format('%s (%d)', col.ch, #col.its + #col.nb))
    end
    ImGui.TableNextRow()
    for ci, col in ipairs(cols) do
        ImGui.TableNextColumn()
        for i = 1, math.min(#col.its, BURNCHK_ROWS) do
            local it = col.its[i]
            local w = (burnWarn[col.ch] or {})[it]
            local x, y = 0, 0
            pcall(function() x, y = ImGui.GetCursorScreenPos() end)
            local drew = ui_icon(it, nil, ts)
            if drew then
                pcall(function()   -- greyed: it has not fired
                    ImGui.GetWindowDrawList():AddRectFilled(ImVec2(x, y), ImVec2(x + ts, y + ts), IM_COL32(0, 0, 0, 130), 2)
                end)
                ImGui.SameLine()
            end
            ImGui.TextDisabled(burn_short_name(it, BURNCHK_CHARS) .. (w and ' (!)' or ''))
            if ui_tip_hover() then pcall(function() ImGui.SetTooltip(burn_tip(col.ch, it) .. (w and ('\n' .. w) or '')) end) end
        end
        if #col.its > BURNCHK_ROWS then
            ImGui.TextDisabled(string.format('+%d more', #col.its - BURNCHK_ROWS))
            if ui_tip_hover() then
                local rest = {}
                for i = BURNCHK_ROWS + 1, #col.its do rest[#rest + 1] = col.its[i] end
                pcall(function() ImGui.SetTooltip(table.concat(rest, '\n')) end)
            end
        end
        -- fired, but the buff never showed: amber, under the ones still waiting
        for _, it in ipairs(col.nb) do
            ui_text(UI_WAIT, burn_short_name(it, BURNCHK_CHARS) .. ' - no buff')
            local w = (burnWarn[col.ch] or {})[it]
            if ui_tip_hover() then pcall(function() ImGui.SetTooltip(burn_tip(col.ch, it) .. '\nwent on cooldown, but its effect never showed'
                .. (w and ('\n' .. w) or '')) end) end
        end
    end
    ImGui.EndTable()
end

