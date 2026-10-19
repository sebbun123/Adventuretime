-- AdventureTime offline tests (1.22.0): each module loaded on its own with a fake mq and ImGui.
-- Run from the AdventureTime folder: luajit tests/run.lua
local ROOT = (debug.getinfo(1, 'S').source:gsub('^@', ''):match('^(.*[/\\])') or './') .. '../../'
local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then passed = passed + 1; print('  ok    ' .. name)
    else failed = failed + 1; print('  FAIL  ' .. name .. '\n' .. tostring(err)) end
end
local function eq(a, b, what) if a ~= b then error(string.format('%s: expected %s, got %s', what or 'value', tostring(b), tostring(a)), 2) end end
local function truthy(v, what) if not v then error((what or 'condition') .. ' was false', 2) end end

-- the host: a clock, a log, spells by name
local now = 1000
local spells = {}
local function spell(tt, ben, dur)
    return { TargetType = function() return tt end, Beneficial = function() return ben end,
             Duration = setmetatable({ TotalSeconds = function() return dur end }, { __call = function() return dur / 6 end }) }
end
package.loaded.mq = { gettime = function() return now end, TLO = {
    FindItem = function(q) return { Spell = spells[q:gsub('^=', '')] } end,
    Me = { AltAbility = function(n) return { Spell = spells[n] } end },
    Spell = function(n) return spells[n] end } }
package.loaded.ImGui = {}
local logs = {}
function log(fmt, ...) logs[#logs + 1] = string.format(fmt, ...) end
function rezlog(fmt, ...) logs[#logs + 1] = string.format(fmt, ...) end
function path_show(p) return tostring(p) end
function tlo_true(v) return v == true or tostring(v) == 'TRUE' end
function cast_backend() return 'e3' end
function ordered_members() return MEMBERS end
local function has(p) for _, l in ipairs(logs) do if l:find(p, 1, true) then return true end end return false end
local function reset() logs = {}; burnState = {}; BURNCHK = nil; burnExpect = {}; burnWarn = {}; burnTT = {}; burnExpectCache = {}; now = 1000 end

myName = 'Tester'
burnState = {}
assert(loadfile(ROOT .. 'modules/burns.lua'))()

print('burns')
test('parse: every burn an item is listed under; the lowest is its tier', function()
    reset()
    local path = os.tmpname()
    local fh = io.open(path, 'w')
    fh:write('[Burn]\n5minBurn=Greaves/CastType|Item\n10minBurn=Greaves/CastType|Item/CheckFor|X\n15minBurn=Breastplate/CastType|Item\n30minBurn=Greaves/CastType|Item\n[Other]\nx=y\n')
    fh:close()
    local list = parse_burn_file(io.open(path, 'r'), path)
    os.remove(path)
    local by = {}
    for _, e in ipairs(list) do by[e.name] = e end
    eq(by.Greaves.tkey, '5minBurn'); eq(table.concat(by.Greaves.keys, '+'), '5minBurn+10minBurn+30minBurn')
    eq(by.Breastplate.tkey, '15minBurn')
end)
test('check: ready items of that burn only; drops off as each fires; one line at the end', function()
    reset(); MEMBERS = { 'Sebbun', 'Nityrc' }
    burnState.Sebbun = { A = { secs = 0, tkey = '5minBurn', keys = burn_key_set('5minBurn+15minBurn') },
                         B = { secs = 0, tkey = '15minBurn', keys = burn_key_set('15minBurn') },
                         Old = { secs = 30, tkey = '15minBurn', keys = burn_key_set('15minBurn') } }
    burnState.Nityrc = { C = { secs = 0, tkey = '15minBurn', keys = burn_key_set('15minBurn') } }
    burncheck_start('15minburn')
    eq(BURNCHK.total, 3, 'three ready'); truthy(has('1 already on cooldown'), 'the one on cooldown said')
    burnState.Sebbun.A.secs = 600; burnState.Sebbun.B.secs = -1; burncheck_tick()
    truthy(BURNCHK and not BURNCHK.pending.Sebbun.A and BURNCHK.pending.Nityrc.C, 'C still waiting')
    burnState.Nityrc.C.secs = 300; burncheck_tick()
    eq(BURNCHK, nil); truthy(has('15minburn: all 3 fired'), 'said')
end)
test('the same burn pressed again keeps the check; what had not fired stays, newly ready joins', function()
    reset(); MEMBERS = { 'Sebbun' }
    burnState.Sebbun = { A = { secs = 0, keys = burn_key_set('10minBurn') }, B = { secs = 0, keys = burn_key_set('10minBurn') },
                         C = { secs = 40, keys = burn_key_set('10minBurn') } }
    burncheck_start('10minBurn'); local c = BURNCHK; eq(c.total, 2)
    burnState.Sebbun.A.secs = 600; burncheck_tick()            -- A fired, B still waiting
    burnState.Sebbun.C.secs = 0; burnState.Sebbun.A.secs = 0    -- C ready now; A ready again (already counted)
    burncheck_start('10minBurn')
    eq(BURNCHK, c, 'same check'); truthy(c.pending.Sebbun.B and c.pending.Sebbun.C and not c.pending.Sebbun.A, 'B kept, C added, A not re-added')
    truthy(has('10minBurn pressed again - keeping the check (2 still waiting, 1 newly ready added)'), 'said')
end)
test('hover: what a burn line casts, from the spell table', function()
    reset(); burnSpell = { Lunafeet = { ['Forsaken Martialist Pants'] = 'Crystalpalm Discipline' } }
    spells['Crystalpalm Discipline'] = spell('Self', true, 48)
    spells['Crystalpalm Discipline'].TargetType = function() return 'Self' end
    eq(burn_tip('Lunafeet', 'Forsaken Martialist Pants'), 'Forsaken Martialist Pants\ncasts Crystalpalm Discipline (Self, 0:48)')
    burnState = { Lunafeet = { X = {} } }
    eq(burn_tip(nil, 'X', burnState.Lunafeet.X), 'X', 'nothing known: just the name')
end)
test('check: a typo says the names it knows and leaves a running check alone', function()
    reset(); MEMBERS = { 'Sebbun' }
    burnState.Sebbun = { A = { secs = 0, tkey = '5minBurn', keys = burn_key_set('5minBurn') } }
    burncheck_start('5minBurn'); local c = BURNCHK
    burncheck_start('Nope')
    eq(BURNCHK, c, 'still the first'); truthy(has('nobody has a burn named "Nope" - the names seen: 5minburn'), 'said')
end)
test('buff items wait for their buff; none in the grace -> fired, no buff; it can still land late', function()
    reset(); MEMBERS = { 'Sunetoo' }
    spells.Spire = spell('Single in Group', true, 60); spells.Nuke = spell('Single', false, 0); spells.Disc = spell('Self', true, 30)
    eq(burn_expects_buff('Spire', 'a'), true); eq(burn_expects_buff('Nuke', 'i'), false); eq(burn_expects_buff('Disc', 'd'), true)
    burnExpect.Sunetoo = { Spire = true, Disc = true }
    burnState.Sunetoo = { Spire = { secs = 0, keys = burn_key_set('b') }, Nuke = { secs = 0, keys = burn_key_set('b') },
                          Disc = { secs = 0, keys = burn_key_set('b') } }
    burncheck_start('b')
    burnState.Sunetoo.Spire.secs = 600; burnState.Sunetoo.Nuke.secs = 30
    burnState.Sunetoo.Disc.secs = 300; burnState.Sunetoo.Disc.active = true
    burncheck_tick()
    truthy(BURNCHK.pending.Sunetoo.Spire and not BURNCHK.pending.Sunetoo.Nuke and not BURNCHK.pending.Sunetoo.Disc, 'only the spire waits')
    now = now + BURNCHK_BUFF_GRACE + 100; burncheck_tick()
    truthy(BURNCHK and BURNCHK.nobuff.Sunetoo.Spire, 'no buff'); truthy(has('went on cooldown with no buff showing'), 'said once')
    burnState.Sunetoo.Spire.active = true; burncheck_tick()
    eq(BURNCHK, nil, 'landed late: done')
end)
test('a friendly-target burn line is warned about once', function()
    reset()
    spells.Spire = spell('Single in Group', true, 60)
    truthy(burn_target_warn('Spire', 'a'):find('friendly target', 1, true)); burn_target_warn('Spire', 'a')
    local n = 0; for _, l in ipairs(logs) do if l:find('its spell targets', 1, true) then n = n + 1 end end
    eq(n, 1, 'once')
end)

test('a buff item on cooldown with no buff is explained once, 8s in', function()
    reset(); burnDiag = {}
    spells.Legs = spell('Self', true, 60); spells.Legs.Name = function() return 'Legs Effect' end
    local it = { Spell = spells.Legs }
    burn_nobuff_diag('Legs', 0, 0, it)
    burn_nobuff_diag('Legs', 300, 0, it)
    now = now + 5000; burn_nobuff_diag('Legs', 295, 0, it); truthy(not has('on cooldown'), 'not yet')
    now = now + 4000; burn_nobuff_diag('Legs', 291, 0, it)
    truthy(has('Legs: on cooldown 9s with no buff - its spell "Legs Effect" (Self, 60s)'), 'said'); truthy(has('buffs -1/-1, songs -1'), 'window counts')
    local n = #logs; now = now + 4000; burn_nobuff_diag('Legs', 287, 0, it); eq(#logs, n, 'once')
    burn_nobuff_diag('Legs', 0, 0, it); eq(burnDiag.Legs.ready, true, 'ready again')
end)
test('an AA with no buff is explained too, with the slot count; the driver shows it (1.23.1)', function()
    reset(); burnDiag = {}; burnExpectCache = burnExpectCache or {}; burnExpectCache.ITC = true
    local M = package.loaded.mq
    local oc, om, os_ = M.TLO.Me.CountBuffs, M.TLO.Me.MaxBuffSlots, M.TLO.Me.CountSongs
    M.TLO.Me.CountBuffs = function() return 39 end; M.TLO.Me.MaxBuffSlots = function() return 39 end
    M.TLO.Me.CountSongs = function() return 7 end
    spells.ITC = spell('Self', true, 60)
    local it = { Spell = spells.ITC }
    burn_nobuff_diag('ITC', 0, 0, it, 'a'); burn_nobuff_diag('ITC', 1, 0, it, 'a')
    now = now + 9000
    local nb, mb, ns = burn_nobuff_diag('ITC', 1, 0, it, 'a')
    truthy(has('buffs 39/39, songs 7'), 'counts in the log line'); eq(nb, '39'); eq(mb, '39'); eq(ns, '7')
    burnWhy = { Azyue = { ITC = { nb = nb, mb = mb, ns = ns } } }
    eq(burn_why_text('Azyue', 'ITC'), ' (buffs 39/39, songs 7, buff window full)'); eq(burn_why_text('Azyue', 'Other'), '')
    M.TLO.Me.CountBuffs, M.TLO.Me.MaxBuffSlots, M.TLO.Me.CountSongs = oc, om, os_
end)
test('"did not take hold ... Blocked by X" is quoted by the no-buff line and carried to the driver (1.23.3)', function()
    reset(); burnDiag = {}; burnExpectCache = burnExpectCache or {}; burnExpectCache.ITC2 = true
    spells.ITC2 = spell('Self', true, 60); spells.ITC2.Name = function() return 'Twincast' end
    local it = { Spell = spells.ITC2 }
    burnBlocked = { twincast = { by = 'Gift of Something', on = 'Tester', at = now } }
    burn_nobuff_diag('ITC2', 0, 0, it, 'a'); burn_nobuff_diag('ITC2', 1, 0, it, 'a')
    now = now + 9000
    local nb, mb, ns, by = burn_nobuff_diag('ITC2', 1, 0, it, 'a')
    eq(by, 'Gift of Something'); truthy(has('blocked by Gift of Something'), 'logged')
    burnWhy = { Azyue = { ITC2 = { nb = '31', mb = '39', ns = '13', by = by } } }
    eq(burn_why_text('Azyue', 'ITC2'), ' (buffs 31/39, songs 13, blocked by Gift of Something)')
end)
test('a block by an effect another burn line casts is called a duplicate (1.23.4)', function()
    burnSpell = { Ejtou = { ['Battle Frenzy'] = 'Battle Frenzy', ['Fanatical Hammer'] = 'Battle Frenzy', Icon = 'Something' } }
    burnWhy = { Ejtou = { ['Fanatical Hammer'] = { nb = '27', mb = '39', ns = '9', by = 'Battle Frenzy' },
                          Icon = { nb = '27', mb = '39', ns = '9', by = 'Other Thing' } } }
    eq(burn_dup_of('Ejtou', 'Fanatical Hammer'), 'Battle Frenzy')
    eq(burn_why_text('Ejtou', 'Fanatical Hammer'), ' (buffs 27/39, songs 9, duplicate of Battle Frenzy)')
    truthy(burn_dup_text('Ejtou', 'Fanatical Hammer'):find('Another burn item (Battle Frenzy) kept this from landing', 1, true), 'hover says what to do')
    eq(burn_dup_of('Ejtou', 'Icon'), nil); eq(burn_why_text('Ejtou', 'Icon'), ' (buffs 27/39, songs 9, blocked by Other Thing)')
    burnSpell = { Ejtou = { Solo = 'Solo Buff' } }; burnWhy = { Ejtou = { Solo = { nb = '1', mb = '39', ns = '0', by = 'Solo Buff' } } }
    eq(burn_dup_of('Ejtou', 'Solo'), ''); truthy(burn_dup_text('Ejtou', 'Solo'):find('already up'), 'own effect')
    burnSpell = {}; burnWhy = {}
end)
test('hints: full windows, a shared timer, a disc clash (1.23.4)', function()
    burnSpell = {}
    burnWhy = { A = { X = { nb = '30', mb = '39', ns = '20' }, Y = { nb = '30', mb = '39', ns = '5', sh = 'Gathering Dusk' },
                      Z = { nb = '30', mb = '39', ns = '5', dsc = 'Crystalpalm Discipline' }, Q = { nb = '30', mb = '39', ns = '5', sh = '?' } } }
    eq(burn_hints('A', 'X')[1][1], 'songs full'); truthy(burn_why_text('A', 'X'):find('song window full', 1, true), 'tag')
    truthy(burn_hints('A', 'Y')[1][2]:find('Gathering Dusk', 1, true), 'names the partner')
    eq(burn_why_text('A', 'Y'), ' (buffs 30/39, songs 5, may share a timer with Gathering Dusk)')
    eq(burn_hints('A', 'Z')[1][1], 'disc clash'); eq(burn_hints('A', 'Q')[1][1], 'shared timer?')
    burnWhy = {}
end)
test('an AA put on cooldown at a length not its own names what went down with it (1.23.4)', function()
    reset(); burnDiag = {}; burnExpectCache = burnExpectCache or {}; burnExpectCache.ITC3 = true
    spells.ITC3 = spell('Self', true, 60); spells.ITC3.Name = function() return 'Twincast' end
    local it = { Spell = spells.ITC3, Reuse = 900 }
    burn_nobuff_diag('ITC3', 0, 0, it, 'a'); burn_nobuff_diag('Dusk', 0, 0, { Spell = spells.ITC3, Reuse = 600 }, 'a')
    burn_nobuff_diag('ITC3', 598, 0, it, 'a'); burn_nobuff_diag('Dusk', 598, 0, { Spell = spells.ITC3, Reuse = 600 }, 'a')
    now = now + 9000
    local _, _, _, _, _, sh = burn_nobuff_diag('ITC3', 589, 0, it, 'a')
    eq(sh, 'Dusk'); truthy(has('may share a timer with: Dusk'), 'logged')
end)
test('stacking from the spells themselves: Glyph of Courage vs Illusions of Grandeur (1.24.1)', function()
    reset(); stackFx = {}; stackCache = {}; stackTrig = {}
    local function sp(id, tt, fx)
        local o = spell(tt, true, 60)
        o.ID = function() return id end; o.NumEffects = function() return 12 end
        o.Attrib = function(i) return function() return (fx[i] or { 254, 0 })[1] end end
        o.Base = function(i) return function() return (fx[i] or { 254, 0 })[2] end end
        o.Trigger = function() return { Name = function() return nil end } end
        return o
    end
    spells['Glyph of Courage'] = sp(12748, 'Self', { { 10, 0 }, { 273, 10 }, { 375, 105 }, nil, { 294, 10 } })
    spells['Illusions of Grandeur'] = sp(38603, 'Group v2', { { 10, 0 }, { 273, 10 }, { 375, 110 }, { 10, 0 }, { 294, 10 } })
    spells['Twincast'] = sp(10634, 'Self', { { 399, 100 }, { 137, 0 }, nil, { 348, 10 } })
    spells['Third Spire'] = sp(16290, 'Self', { { 375, 155 } })
    local r = stack_check('Glyph of Courage', 'Illusions of Grandeur')
    eq(r.slot, 3); eq(r.spa, 375); eq(r.wins, 'b'); eq(r.va, 105); eq(r.vb, 110)
    truthy(stack_why('Glyph of Courage', 'Illusions of Grandeur', r):find('110 - Illusions of Grandeur wins', 1, true), 'reason')
    eq(stack_check('Twincast', 'Third Spire'), nil, 'different effects in slot 1')
    eq(stack_check('Twincast', 'Twincast').same, true)
    burnSpell = { Azyue = { GoC = 'Glyph of Courage', ITC = 'Twincast' }, Shela = { IoG = 'Illusions of Grandeur' } }
    local txt = burn_stack_text('Azyue', 'GoC')
    truthy(txt and txt:find("Shela's IoG", 1, true), 'names the other toon and line')
    eq(burn_stack_text('Azyue', 'ITC'), nil, 'Twincast fights nothing')
    eq(#burn_stack_conflicts('Shela', 'IoG'), 0, "Azyue's self-only Glyph is not on Shela")
    burnSpell = {}; stackFx = {}; stackCache = {}
end)
test('a cooldown already running when AT loads is not explained', function()
    reset(); burnDiag = {}
    local it = { Spell = spells.Legs }
    burn_nobuff_diag('Legs', 300, 0, it); now = now + 9000; burn_nobuff_diag('Legs', 291, 0, it)
    truthy(not has('on cooldown'), 'quiet')
end)

print('coth')
test('the module loads on its own and defines what init.lua calls', function()
    assert(loadfile(ROOT .. 'modules/coth.lua'))()
    truthy(type(COTH) == 'table' and type(COTHG) == 'table', 'COTH and COTHG')
    eq(COTH_SPELL, 'Call of the Hero')
    for _, f in ipairs({ 'coth_tick', 'coth_cast_step', 'coth_find_charm', 'cothg_tick', 'coth_swap_tick', 'coth_watch_tick' }) do
        eq(type(_G[f]), 'function', f)
    end
end)

-- A small inventory for the charm swap: a charm slot, a cursor, bags. /itemnotify swaps the cursor with what
-- it clicks, the way the client does. Knobs make the client misbehave.
local W
local function wreset(t) W = { charm = t.charm or '', cursor = '', bags = t.bags or { {} }, refuseSeat = t.refuseSeat or 0,
    boxOnSeat = t.boxOnSeat, emptyOnSeat = t.emptyOnSeat, box = false, clicks = {} } end
local M = package.loaded.mq
local function find(name)
    for b, bag in pairs(W.bags) do for sl = 1, 10 do if bag[sl] == name then return b, sl end end end
end
local realFind = M.TLO.FindItem
M.TLO.FindItem = function(q)
    local nm = q:gsub('^=', '')
    local b, sl; if W then b, sl = find(nm) end
    local o = realFind(q)
    o.ItemSlot = function() return b and (22 + b) or nil end
    o.ItemSlot2 = function() return sl and (sl - 1) or nil end
    o.ID = function() return b and 1 or 0 end
    return o
end
M.TLO.Me.Inventory = function(s) return { Name = function() return (s == 'charm' and W.charm ~= '') and W.charm or nil end } end
M.TLO.Me.Name = function() return 'Tester' end
M.TLO.Cursor = { Name = function() return W.cursor ~= '' and W.cursor or nil end, ID = function() return W.cursor ~= '' and 1 or 0 end }
M.delay = function() end
M.gettime = function() return now end
local function stow() for b, bag in pairs(W.bags) do for sl = 1, 10 do if not bag[sl] then bag[sl] = W.cursor; W.cursor = ''; return end end end end
M.cmd = function(c) if c == '/autoinventory' and W.cursor ~= '' then stow() end end
M.cmdf = function(fmt, ...)
    local c = string.format(fmt, ...)
    W.clicks[#W.clicks + 1] = c
    if c:find('CD_No_Button', 1, true) then W.box = false; return end
    local b, sl = c:match('^/itemnotify in pack(%d+) (%d+) leftmouseup$')
    if b then b, sl = tonumber(b), tonumber(sl)
        local there = W.bags[b][sl] or ''
        W.bags[b][sl] = (W.cursor ~= '') and W.cursor or nil; W.cursor = there; return end
    if c == '/itemnotify charm leftmouseup' then
        if W.boxOnSeat then W.box = true; return end
        if W.refuseSeat > 0 then W.refuseSeat = W.refuseSeat - 1; return end
        if W.emptyOnSeat then W.emptyOnSeat = false; local new = W.cursor; W.cursor = W.charm; W.charm = ''
            local nb = #W.bags[1] + 1; W.bags[1][nb] = new; return end
        W.charm, W.cursor = W.cursor, W.charm
    end
end
function cursor_stow() if W.cursor ~= '' then stow() end; return W.cursor == '' end
function win_open_raw() return W.box end
function e3_hold() end
function e3_release() end
function at_read(n) return os.tmpname() .. n end
local function seated(what) eq(W.charm, what, 'charm slot'); eq(W.cursor, '', 'cursor') end

print('charm swap')
test('one click swaps; the old charm lands where the new one was; restore swaps back', function()
    reset(); wreset({ charm = 'Old', bags = { { 'A', 'B', 'Emblem' } } })
    eq(coth_charm_equip_inner("Emblem"), true); seated("Emblem"); eq(W.bags[1][3], 'Old', 'old charm in the emblem slot')
    eq(cothCharmSaved, 'Old')
    eq(coth_charm_restore_inner('gather finished'), true); seated('Old'); eq(W.bags[1][3], 'Emblem', 'emblem home again')
    eq(cothCharmSaved, nil, 'record cleared')
end)
test('the slot refuses every click: the old charm stays on, the emblem goes home', function()
    reset(); wreset({ charm = 'Old', bags = { { 'Emblem' } }, refuseSeat = 99 })
    eq(coth_charm_equip_inner('Emblem'), false); seated('Old'); eq(W.bags[1][1], 'Emblem')
    eq(cothCharmSaved, nil, 'nothing changed, no record')
end)
test('a confirmation box: answered no, old charm stays on, emblem back in its slot', function()
    reset(); wreset({ charm = 'Old', bags = { { 'Emblem' } }, boxOnSeat = true })
    eq(coth_charm_equip_inner('Emblem'), false); seated('Old'); eq(W.box, false, 'box closed'); eq(W.bags[1][1], 'Emblem')
    truthy(has('confirmation box'), 'said why')
end)
test('the slot reads EMPTY after the click: the old charm goes straight back on', function()
    reset(); wreset({ charm = 'Old', bags = { { 'Emblem' } }, emptyOnSeat = true })
    eq(coth_charm_equip_inner('Emblem'), false)
    seated('Old')
    truthy(has('reads EMPTY'), 'said')
end)
test('a slot that was empty before is empty after the restore', function()
    reset(); wreset({ charm = '', bags = { { 'Emblem' } } })
    eq(coth_charm_equip_inner('Emblem'), true); seated('Emblem')
    eq(coth_charm_restore_inner('gather finished'), true); seated('')
end)
test('the guard: the emblem came off mid-gather - it goes back on with one swap', function()
    reset(); wreset({ charm = 'Old', bags = { { 'Emblem' } } })
    eq(coth_charm_equip_inner('Emblem'), true)
    W.charm, W.bags[1][1] = 'Old', 'Emblem'   -- something put the old one back on
    coth_charm_guard(); seated('Emblem'); truthy(has('Emblem is back on'), 'said')
end)
test('an emblem not in the bags: nothing is touched', function()
    reset(); wreset({ charm = 'Old', bags = { { 'A' } } })
    eq(coth_charm_equip_inner('Emblem'), false); seated('Old'); eq(#W.clicks, 0, 'no clicks')
end)

print(string.format('\n%d passed, %d failed', passed, failed))
os.exit(failed == 0 and 0 or 1)
