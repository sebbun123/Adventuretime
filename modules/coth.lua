-- AdventureTime module: CoTH (1.22.2). Call of the Hero gathers - the group cascade (/atcoth), the solo gather
-- (/atcoth group) and the emblem charm swap. Moved out of init.lua as it was; loaded in place with at_module('coth').
-- Shares state with init.lua through globals (COTH, COTHG, myName, log, rezlog...).
local mq = require('mq')
local ImGui = require('ImGui')

-- ===== Call of the Hero: gather the group by CASCADE ===== CoTH summons the target TO the caster, so
-- anyone already gathered who holds an emblem becomes a new summoner.
COTH = {
    ITEM   = 'Wayfarers Brotherhood Emblem',
    OPTS   = '/CastType|Item/NoInterrupt',   -- it has a cast time, so it can be interrupted
    RANGE  = 50,           -- within this of the anchor POINT counts as gathered
    JUMPED = 75,           -- moving further than this in one go is a summon, not walking
    active = false,
    state  = {},           -- name -> { emblem, dist, updated } : emblem timer + distance to the anchor
    at     = nil,          -- { x, y, z, zone, who } : the anchor POINT, and who set it (for LOS)
    skip   = {},           -- name -> when I may consider them again, after they told me no
    grey   = {},           -- name -> when I cast at them: assumed arrived until they say otherwise
    absent = {},           -- summoner -> when they first read as away, so a blip does not lose their job
    startedAt = 0, lastPush = 0, lastPoll = 0,
    pending = nil,         -- { name, at, cast } : who I am summoning and how it is going
}

-- Am I standing at the anchor point AND able to see it?
function coth_here(nm)
    -- HOLD THE TABLE, do not keep reading the global.
    local anchor = COTH.at
    if not anchor then return false end
    if nm and nm:lower() ~= myName:lower() then
        -- THEIR VERDICT, not our arithmetic on their numbers.
        local st = COTH.state[nm]
        if not st then return false end
        if st.here ~= nil then return st.here == 1 end
        return (st.dist or -1) >= 0 and st.dist <= COTH.RANGE and (st.los or 0) == 1
    end
    local z = 0
    pcall(function() z = tonumber(mq.TLO.Zone.ID()) or 0 end)
    if anchor.zone ~= 0 and z ~= anchor.zone then return false end
    local d = coth_dist_to_anchor()
    if d > COTH.RANGE then return false end
    -- CLOSE ENOUGH IS CLOSE ENOUGH.
    if d <= COTH_LOS_FREE then return true end
    return coth_los() == 1
end

-- 1 = I can see the anchor character, or there is nobody to check against. 0 = they are there and I
-- cannot see them.
function coth_los()
    local anchor = COTH.at
    local by = anchor and anchor.by
    if not by or by == '' or by:lower() == myName:lower() then return 1 end
    local id = 0
    pcall(function() id = tonumber(mq.TLO.Spawn('pc =' .. by).ID()) or 0 end)
    if id <= 0 then return 1 end                      -- not in zone: cannot tell, do not block on it
    local los = false
    pcall(function() los = tlo_true(mq.TLO.Spawn('pc =' .. by).LineOfSight()) end)
    return los and 1 or 0
end

function coth_dist_to_anchor()
    local anchor = COTH.at
    if not anchor then return 99999 end
    local x, y, z = 0, 0, 0
    pcall(function() x = tonumber(mq.TLO.Me.X()) or 0 end)
    pcall(function() y = tonumber(mq.TLO.Me.Y()) or 0 end)
    pcall(function() z = tonumber(mq.TLO.Me.Z()) or 0 end)
    local dx, dy, dz = x - anchor.x, y - anchor.y, z - anchor.z
    return math.floor(math.sqrt(dx*dx + dy*dy + dz*dz))
end

-- Can I actually click the emblem?
function coth_emblem()
    local id = 0
    pcall(function() id = tonumber(mq.TLO.FindItem('=' .. COTH.ITEM).ID()) or 0 end)
    if id <= 0 then return -1 end
    local t = -1
    pcall(function() t = tonumber(mq.TLO.FindItem('=' .. COTH.ITEM).TimerReady()) or -1 end)
    if t < 0 then t = 0 end
    return t
end

function coth_read_self()
    local em = coth_emblem()
    local d  = COTH.at and coth_dist_to_anchor() or -1
    return em, d, coth_los()
end

-- Everyone still away from the anchor point, emblem holders first: each one we pull becomes a summoner,
-- so pulling them first is what turns one summoner into three.
function coth_targets()
    local hold, rest, now = {}, {}, mq.gettime()
    for _, nm in ipairs(group_members()) do
        if nm:lower() ~= myName:lower() then
            local st = COTH.state[nm]
            -- Fresh evidence only.
            local skipped = COTH.skip[nm] and now < COTH.skip[nm]
            local grey    = COTH.grey[nm] and (now - COTH.grey[nm]) < COTH_GREY_MS
            if st and (now - (st.updated or 0)) < 6000 and not coth_here(nm)
               and not skipped and not grey then
                if (st.emblem or -1) >= 0 then hold[#hold + 1] = nm else rest[#rest + 1] = nm end
            end
        end
    end
    -- EMBLEM HOLDERS IN CASTING-SPEED ORDER.
    table.sort(hold, function(a, b)
        local ra, rb = coth_rank(a), coth_rank(b)
        if ra ~= rb then return ra < rb end
        return a < b
    end)
    table.sort(rest)
    for _, nm in ipairs(rest) do hold[#hold + 1] = nm end
    -- A BARD GOES TO THE BACK.
    local ordered, bards = {}, {}
    for _, nm in ipairs(hold) do
        if (member_class(nm) or ''):upper() == 'BRD' then bards[#bards + 1] = nm
        else ordered[#ordered + 1] = nm end
    end
    for _, nm in ipairs(bards) do ordered[#ordered + 1] = nm end
    return ordered
end

-- NOBODY REASSIGNS.

-- IS EVERYBODY ACTUALLY HERE?
function coth_all_here()
    for _, nm in ipairs(group_members()) do
        if nm:lower() == myName:lower() then
            if not coth_here() then return false, nm end
        else
            local st = COTH.state[nm]
            if not st then return false, nm end
            if not coth_here(nm) then return false, nm end
        end
    end
    return true
end

-- Everyone at the anchor with a ready emblem, in one order every client computes identically.
function coth_summoners()
    local out, now = {}, mq.gettime()
    for _, nm in ipairs(group_members()) do
        local st = COTH.state[nm]
        if nm:lower() == myName:lower() then
            if coth_here() and coth_emblem() == 0 then out[#out + 1] = nm end
        elseif st and (now - (st.updated or 0)) < 6000 and coth_here(nm) and (st.emblem or -1) == 0 then
            out[#out + 1] = nm
        end
    end
    table.sort(out)
    return out
end

-- HOW MANY EMBLEMS ARE IN THIS GROUP AT ALL?
function coth_emblem_holders()
    local n, now = 0, mq.gettime()
    for _, nm in ipairs(group_members()) do
        if nm:lower() == myName:lower() then
            if coth_emblem() >= 0 then n = n + 1 end
        else
            local st = COTH.state[nm]
            if st and (st.emblem or -1) >= 0 and (now - (st.updated or 0)) < 60000 then n = n + 1 end
        end
    end
    return n
end

function coth_set(on, at)
    if on then
        -- CAPTURE THE POINT, not the person. Whoever starts it fixes the spot; if they wander off
        -- afterwards the gather still means the same place.
        if at then
            COTH.at = at
        else
            local x, y, z, zn = 0, 0, 0, 0
            pcall(function() x = tonumber(mq.TLO.Me.X()) or 0 end)
            pcall(function() y = tonumber(mq.TLO.Me.Y()) or 0 end)
            pcall(function() z = tonumber(mq.TLO.Me.Z()) or 0 end)
            pcall(function() zn = tonumber(mq.TLO.Zone.ID()) or 0 end)
            COTH.at = { x = x, y = y, z = z, zone = zn, by = myName }
            pcall(function() peer_bcast('/at_cothat %d %d %d %d %s', x, y, z, zn, myName) end)
        end
        COTH.active, COTH.startedAt, COTH.pending = true, mq.gettime(), nil
        COTH.skip, COTH.grey, COTHW = {}, {}, nil
        COTH.saidDone, COTH.quietAt, COTH.saidWait = nil, nil, nil
        COTH.saidScarce = nil
        -- Fresh gather, fresh answers: last run's charm reports say nothing about this one.
        COTH.swapped, COTH.saidWaitSwap, COTH.saidSwapDone = {}, nil, nil
        COTH.mine = 0
        -- AND SWAP MY OWN, EXPLICITLY.
        cothSwapWant = { auto = true }
        pcall(function() peer_bcast('/at_cothgo on') end)
        rezlog('[coth] gather started - anchor point %d,%d,%d',
               COTH.at and COTH.at.x or 0, COTH.at and COTH.at.y or 0, COTH.at and COTH.at.z or 0)
        -- SAY SO IF I CANNOT HELP. A gather where nobody can summon looks identical to one that is simply
        -- slow, and that is worth ten seconds of nobody understanding why nothing happened.
        local em = coth_emblem()
        if em < 0 then
            -- ASK TWICE BEFORE SAYING NO.
            local c = coth_find_charm()
            if c then
                log('[coth] my emblem is in %s - putting it on before I summon', c)
            else
                log('\\ay[coth] I have no %s - I cannot summon anybody\\ax', COTH.ITEM)
            end
        elseif em > 0 then
            log('[coth] my emblem is %ds into reuse - I will summon when it is ready', em)
        end
    else
        COTH.active, COTH.pending, COTH.at, COTHW = false, nil, nil, nil
        COTH.dbg = ''
        pcall(function() peer_bcast('/at_cothgo off') end)
        cothSwapWant = { back = true, auto = true }   -- same reason: I do not hear my own broadcast
        rezlog('[coth] gather stopped')
    end
end

-- Runs on the SUMMONED character: has my own position jumped?
COTHW = nil
function coth_watch_tick()
    local w = COTHW
    if not w then return end
    local x, y, z = 0, 0, 0
    pcall(function() x = tonumber(mq.TLO.Me.X()) or 0 end)
    pcall(function() y = tonumber(mq.TLO.Me.Y()) or 0 end)
    pcall(function() z = tonumber(mq.TLO.Me.Z()) or 0 end)
    local dx, dy, dz = x - w.x, y - w.y, z - w.z
    local moved = math.floor(math.sqrt(dx*dx + dy*dy + dz*dz))
    -- ARRIVED IS A PLACE, NOT A DISTANCE.
    local here = false
    pcall(function() here = (coth_dist_to_anchor() <= COTH.RANGE) and (coth_los() == 1) end)
    if moved >= COTH.JUMPED or here then
        -- MY WHOLE PICTURE AT THE MOMENT I LAND. If I am about to decide I am NOT with the group, this
        -- line says which half failed - too far from the point, or no line of sight to the anchor.
        local a = COTH.at
        rezlog('[coth] arrived after %s cast - moved %d, now %d from the anchor (limit %d, los=%d to %s)%s',
               w.by, moved, coth_dist_to_anchor(), COTH.RANGE, coth_los(), a and a.by or '?',
               (moved < COTH.JUMPED) and ' [short summon - counted by position, not distance]' or '')
        -- Arrival is the expected case and does not need announcing to five other people; the summoner
        -- hears it directly and the log has it.
        pcall(function() peer_bcast('/at_cotharrived %s', myName) end)
        COTHW = nil
        return
    end
    -- Not moved yet.
    if not w.cast then return end
    if (mq.gettime() - w.castAt) > COTH_SETTLE then
        rezlog('[coth] %s finished casting and I did not move - telling them', w.by)
        pcall(function() mq.cmdf('/gsay CoTH: %s cast but I did NOT move - still %d away',
                                 w.by, coth_dist_to_anchor()) end)
        pcall(function() peer_cmdf(w.by, '/at_cothhere %s no failed', myName) end)
        COTHW = nil
    end
end


-- How long to leave a target alone after it says no.
COTH_BARD_CAST = 11000
-- How many summons a bard does before handing over, if anyone else can take it.
COTH_BARD_MAX  = 2
-- ...UNLESS THE EMBLEM IS SCARCE.
COTH_BARD_SCARCE = 2

-- WHO SHOULD SPEND THE EMBLEM WHEN MORE THAN ONE COULD.
COTH_CLASS_RANK = {
    DRU = 1, CLR = 1, SHM = 1,                 -- healers: beneficial spell haste is near universal
    ENC = 2, NEC = 2, WIZ = 2, MAG = 2,        -- pure casters
    RNG = 3, BST = 3, SHD = 3, PAL = 3,        -- hybrids
    BRD = 4,                                   -- already stands back on its own; last if it does not
}
COTH_RANK_DEFAULT = 4
-- How many the anchor takes before class order applies to it.
COTH_ANCHOR_CASTS = 2

-- MY OWN CLASS, read locally, which is the one read that cannot fail for want of a spawn.
function coth_my_class()
    local c = ''
    pcall(function() c = tostring(mq.TLO.Me.Class.ShortName() or '') end)
    return (c ~= '' and c ~= 'NULL') and c:upper() or '?'
end

-- THE REPORT FIRST, the local read second. What the character said about itself beats what we can see of
-- it from here - and during a gather we can usually see nothing at all.
function coth_rank(nm)
    local st = COTH.state[nm]
    local c = st and st.class or ''
    if c == '' then c = (member_class(nm) or ''):upper() end
    return COTH_CLASS_RANK[c] or COTH_RANK_DEFAULT
end
-- How long the driver will hold the first summon waiting for charms to go on. Generous: the swap is
-- cursor work behind an E3 pause that itself waits up to 2.5s for E3 to actually stop.
COTH_SWAP_WAIT = 12000
COTH_LOS_FREE  = 25
-- How long to keep reporting after deciding the gather is over. Covers the gap where somebody else has
-- not reached the same conclusion and is still deciding from my last report.
COTH_LINGER    = 15000
COTH_GREY_MS   = 8000
COTH_ASK_MS    = 400
COTH_SKIP_BUSY = 15000
COTH_SKIP_FAIL = 4000
-- How many times the charm may be put back in one gather before we stop fighting whatever removes it.
COTH_RESEAT_MAX = 3
COTH_SETTLE  = 3000    -- after the cast lands, how long to allow for the client to actually move me
COTH_GIVE_UP = 25000   -- backstop for a target that never answers at all: crashed, zoned, gone
-- AND A BACKSTOP FOR THE WHOLE GATHER.
COTH_RUN_MAX = 300000

-- THE SUMMON IN STEPS (1.21.2). Ask, cast, see it start, see it land - each looked at once a tick instead of
-- waited out inside one (it used to hold the whole loop: the ask 400ms, the start up to 3s, the cast up to 20s,
-- and a bard 11s - no rez, DI or burn work while it waited). Returns true while a summon is in hand.
function coth_cast_step(now)
    local c = COTH.cast
    if not c then return false end
    local function done()
        COTH.grey[c.name] = mq.gettime()
        COTH.pending = nil
        COTH.mine = (COTH.mine or 0) + 1
        COTH.cast = nil
    end
    if c.phase == 'ask' then
        if COTH.pending == nil then COTH.cast = nil; return true end   -- they said no while we asked: nothing spent
        if now < c.untilT then COTH.dbg = 'asking ' .. c.name; return true end
        -- AND LOOK AGAIN BEFORE SPENDING IT.
        if coth_here(c.name) then
            rezlog('[coth] %s got here while I was asking - not summoning them', c.name)
            COTH.pending, COTH.cast = nil, nil
            return true
        end
        -- TELL EVERYONE THEY ARE MINE, now that the target has agreed.
        pcall(function() peer_bcast('/at_cothmine %s', c.name) end)
        local ts = COTH.state[c.name] or {}
        rezlog('[coth] summoning %s (their report: dist=%s los=%s here=%s, %.1fs old)',
               c.name, tostring(ts.dist), tostring(ts.los), tostring(ts.here),
               (mq.gettime() - (ts.updated or mq.gettime())) / 1000)
        -- IN GROUP CHAT, not just the log.
        pcall(function() mq.cmdf('/gsay CoTH: summoning %s', c.name) end)
        -- NOTHING ON THE CURSOR, OR NOTHING HAPPENS.
        local clear, stuck = cursor_stow('coth')
        if not clear then
            rezlog('\\ar[coth] NOT casting - "%s" is stuck on the cursor and casting with a held item '
                .. 'disconnects the client. Clear it and the next pass will summon %s.\\ax',
                   tostring(stuck or '?'), c.name)
            COTH.pending, COTH.cast = nil, nil
            return true
        end
        at_cast(COTH.ITEM .. COTH.OPTS, c.tid)
        -- BARDS GET NO CAST BAR FROM THE EMBLEM.
        if c.bard then
            rezlog('[coth] bard: no cast bar to watch, firing blind and assuming it lands')
            c.phase, c.untilT = 'bard', now + COTH_BARD_CAST
            return true
        end
        -- WAIT FOR IT TO START BEFORE WAITING FOR IT TO END.
        c.phase, c.castFrom, c.untilT = 'start', now, now + 3000
        return true
    end
    if c.phase == 'bard' then
        if now < c.untilT then COTH.dbg = 'bard casting on ' .. c.name; return true end
        pcall(function() peer_cmdf(c.name, '/at_cothcast %s', myName) end)
        local nm = c.name
        done()
        rezlog('[coth]   cast sent for %s - assuming they made it, moving on', nm)
        return true
    end
    local casting = 0
    pcall(function() casting = tonumber(mq.TLO.Me.Casting.ID()) or 0 end)
    if c.phase == 'start' then
        local t = -1
        pcall(function() t = tonumber(mq.TLO.FindItem('=' .. COTH.ITEM).TimerReady()) or -1 end)
        if casting <= 0 and t <= 0 then
            if now < c.untilT then COTH.dbg = 'emblem going out for ' .. c.name; return true end
            rezlog('\\ay[coth] the emblem never went out for %s (no cast bar, timer still ready) - releasing\\ax', c.name)
            COTH.pending, COTH.cast = nil, nil
            COTH.skip[c.name] = mq.gettime() + COTH_SKIP_FAIL
            return true
        end
        -- Now wait for it to LAND.
        c.sawBar = casting > 0
        if c.sawBar then
            c.untilT = now + 20000
        else
            rezlog('[coth] no cast bar on this character - waiting out the emblem cast time instead')
            local ms = 0
            pcall(function()
                ms = (tonumber(mq.TLO.FindItem('=' .. COTH.ITEM).Clicky.CastTime.TotalSeconds()) or 0) * 1000
            end)
            if ms <= 0 then ms = 10000 end
            c.untilT = now + ms
        end
        c.phase = 'cast'
        return true
    end
    -- c.phase == 'cast'
    if now < c.untilT and not (c.sawBar and casting <= 0) then COTH.dbg = 'summoning ' .. c.name; return true end
    if COTH.pending then
        pcall(function() peer_cmdf(c.name, '/at_cothcast %s', myName) end)
    end
    -- ASSUME IT LANDED AND CARRY ON.
    local nm, sawBar = c.name, c.sawBar
    local took = (mq.gettime() - (c.castFrom or mq.gettime())) / 1000
    done()
    -- Only meaningful when a cast bar was seen: without one the wait above was the cast time, not a measure.
    if sawBar then
        COTH.castSecs = took
        -- READ THE SLOT, NOT OUR OWN BOOKKEEPING.
        local wornNow = false
        pcall(function() wornNow = coth_item_has_emblem(mq.TLO.Me.Inventory('charm')) end)
        rezlog('[coth]   cast finished for %s in %.1fs (emblem %s) - assuming they made it, moving on',
               nm, took, wornNow and 'WORN' or 'in a bag')
    else
        rezlog('[coth]   cast finished for %s - assuming they made it, moving on', nm)
    end
    return true
end

function coth_tick()
    -- GIVE UP ON THE WHOLE RUN, not just on one target. See COTH_RUN_MAX.
    if COTH.active and COTH.startedAt and (mq.gettime() - COTH.startedAt) > COTH_RUN_MAX then
        local left = {}
        for _, nm in ipairs(group_members()) do
            local st = COTH.state[nm]
            if st and (st.here or 0) == 0 and nm:lower() ~= myName:lower() then left[#left + 1] = nm end
        end
        rezlog('\\ay[coth] gather ran %ds without finishing - stopping%s\\ax', COTH_RUN_MAX / 1000,
               (#left > 0) and (' (still out: ' .. table.concat(left, ', ') .. ')') or '')
        COTH.active, COTH.pending = false, nil
        -- Same restore the clean finish does, so nobody is left wearing the emblem charm.
        cothSwapWant = { back = true, auto = true }
        if (COTH.at and COTH.at.by or ''):lower() == myName:lower() then
            pcall(function() peer_bcast('/at_cothgo off') end)
        end
        return
    end
    -- Still reporting after the gather ends, briefly: see COTH.quietAt below.
    local now = mq.gettime()
    if not COTH.active then
        COTH.cast = nil   -- a summon in hand ends with the gather (1.21.2)
        if COTH.quietAt and (now - COTH.quietAt) < COTH_LINGER then
            local em, d, los = coth_read_self()
            if (now - COTH.lastPush) > 1000 then
                COTH.lastPush = now
                pcall(function()
                    peer_bcast('/at_coth %s %d %d %d %d %s', myName, em, d, los,
                               coth_here() and 1 or 0, coth_my_class())
                end)
            end
        end
        return
    end

    -- Report my own emblem and distance so the others can plan.
    if (now - COTH.lastPush) > 1000 then
        COTH.lastPush = now
        -- Send the VERDICT alongside the parts. The parts stay for the panel and for diagnosing a
        -- disagreement; the verdict is what everyone actually acts on.
        local em, d, los = coth_read_self()
        local here = coth_here() and 1 or 0
        -- SAY WHEN MY OWN VERDICT CHANGES, with the numbers behind it.
        if here ~= COTH.saidHere then
            COTH.saidHere = here
            local a = COTH.at
            rezlog('[coth] I am now %s: %d from the anchor (limit %d), los=%d to %s, zone %s',
                   (here == 1) and 'WITH THE GROUP' or 'AWAY', d, COTH.RANGE, los,
                   a and a.by or '?', a and tostring(a.zone) or '?')
        end
        COTH.state[myName] = { emblem = em, dist = d, los = los, here = here, updated = now }
        pcall(function() peer_bcast('/at_coth %s %d %d %d %d %s', myName, em, d, los, here,
                                    coth_my_class()) end)
    end

    -- A SUMMON IN HAND GOES ON FIRST (1.21.2: in steps, one a tick).
    if coth_cast_step(now) then return end

    -- NOBODY SUMMONS UNTIL EVERYONE HAS SWAPPED.
    if (COTH.mine or 0) == 0 and (now - (COTH.startedAt or now)) < COTH_SWAP_WAIT then
        local waiting = {}
        COTH.swapped = COTH.swapped or {}
        for _, nm in ipairs(group_members()) do
            if not COTH.swapped[nm] then waiting[#waiting + 1] = nm end
        end
        if #waiting > 0 then
            COTH.dbg = 'waiting for charms: ' .. table.concat(waiting, ', ')
            if not COTH.saidWaitSwap then
                COTH.saidWaitSwap = true
                rezlog('[coth] holding the first summon until the charms are on (%s)',
                       table.concat(waiting, ', '))
            end
            return
        end
        -- SAY WHEN THE HOLD LIFTS, and how long it took.
        if COTH.saidWaitSwap and not COTH.saidSwapDone then
            COTH.saidSwapDone = true
            local el = (now - (COTH.startedAt or now)) / 1000
            rezlog('[coth] charms are on after %.1fs%s - summoning can start',
                   el, (el >= (COTH_SWAP_WAIT / 1000) - 0.5) and ' (TIMED OUT, somebody never reported)' or '')
        end
    end

    -- Am I waiting on somebody? Nothing else happens until that resolves.
    if COTH.pending then
        local p = COTH.pending
        if (now - p.at) > COTH_GIVE_UP then
            rezlog('\\ay[coth] %s never answered in %ds - giving up on them\\ax', p.name, COTH_GIVE_UP / 1000)
            COTH.pending = nil
        end
        COTH.dbg = 'waiting on ' .. p.name
        return
    end

    -- FINISHED ONLY WHEN EVERY MEMBER SAYS THEY ARE HERE, not when the queue happens to be empty.
    local left = coth_targets()
    local allHere, waitingOn = coth_all_here()
    if allHere then
        COTH.active, COTH.dbg = false, 'group gathered'
        -- KEEP REPORTING FOR A MOMENT.
        COTH.quietAt = now
        -- ONCE. Every character reached this and logged it on its own pass, so one finished gather
        -- produced six identical lines.
        if not COTH.saidDone then
            COTH.saidDone = true
            -- HOW LONG IT TOOK, from the moment the gather started.
            local secs = (now - (COTH.startedAt or now)) / 1000
            rezlog('[coth] gather complete in %.1fs - everyone is with the group', secs)
            -- PUT THE CHARM BACK HERE, because this is where a gather really ends.
            cothSwapWant = { back = true, auto = true }
            if (COTH.at and COTH.at.by or ''):lower() == myName:lower() then
                pcall(function()
                    mq.cmdf('/gsay CoTH: Everyone is here. Took %.0f seconds to summon the group.', secs)
                end)
            end
        end
        return
    end
    -- NOT finished.
    if #left == 0 then
        COTH.dbg = 'waiting on ' .. tostring(waitingOn)
        if not COTH.saidWait or (now - COTH.saidWait) > 5000 then
            COTH.saidWait = now
            rezlog('[coth] nobody to summon right now - still waiting on %s', tostring(waitingOn))
        end
        return
    end

    -- Can I summon at all?
    if not coth_here() then COTH.dbg = 'not at the anchor myself'; return end
    local em = coth_emblem()
    if em ~= 0 then COTH.dbg = (em < 0) and 'no emblem' or ('emblem ' .. em .. 's'); return end

    -- WHO COULD BE HELPING, AND WHO IS NOT. A gather where one character does all the work while three
    -- stand there able-bodied is the symptom; this says which of the two tests each one failed.
    if not COTH.saidWho or (now - COTH.saidWho) > 10000 then
        COTH.saidWho = now
        local parts = {}
        for _, nm in ipairs(group_members()) do
            if nm:lower() ~= myName:lower() then
                local st = COTH.state[nm]
                parts[#parts + 1] = string.format('%s[%s/%s]', nm,
                    st and tostring(st.here) or '?', st and tostring(st.emblem) or '?')
            end
        end
        rezlog('[coth] group (here/emblem): %s', table.concat(parts, ' '))
    end

    -- Am I a bard? Needed twice below - for the always-casting exemption and for the blind cast - so it
    -- is read once here rather than derived at each site.
    local iAmBard = (member_class(myName) or ''):upper() == 'BRD'

    -- A BARD THAT STARTED THIS STEPS BACK ONCE OTHERS CAN CARRY IT.
    if iAmBard and (COTH.mine or 0) >= COTH_BARD_MAX then
        -- ONE OTHER SUMMONER IS NOT ENOUGH WHEN IT IS THE ONLY OTHER SUMMONER.
        local holders = coth_emblem_holders()
        if holders > COTH_BARD_SCARCE then
            local others = 0
            for _, nm in ipairs(coth_summoners()) do
                if nm:lower() ~= myName:lower() then others = others + 1 end
            end
            if others > 0 then
                COTH.dbg = string.format('bard: %d others can summon now, standing back', others)
                return
            end
        else
            COTH.dbg = string.format('bard: only %d emblem(s) in the group - carrying on', holders)
            if not COTH.saidScarce then
                COTH.saidScarce = true
                rezlog('[coth] only %d emblem(s) between us - the bard keeps summoning rather than standing back',
                       holders)
            end
        end
    end

    -- LET THE FASTER CASTER TAKE IT.
    do
        local iAmAnchor = ((COTH.at and COTH.at.by) or ''):lower() == myName:lower()
        if not (iAmAnchor and (COTH.mine or 0) < COTH_ANCHOR_CASTS) then
            local myRank, better = coth_rank(myName), nil
            for _, nm in ipairs(coth_summoners()) do
                if nm:lower() ~= myName:lower() and coth_rank(nm) < myRank then
                    better = nm; break
                end
            end
            if better then
                COTH.dbg = string.format('%s casts faster and is ready - standing back', better)
                if not COTH.saidRank or (now - COTH.saidRank) > 8000 then
                    COTH.saidRank = now
                    rezlog('[coth] %s (%s) is ready and casts faster than me (%s) - letting them take it',
                           better, member_class(better) or '?', member_class(myName) or '?')
                end
                return
            end
        end
    end

    -- TAKE THE FIRST ONE NOBODY HAS. coth_targets is already ordered - emblem holders first - and skip
    -- holds anyone who has told me no recently, whether that was 'busy' or a failed summon.
    local mine
    for _, tgt in ipairs(left) do
        if not (COTH.skip[tgt] and now < COTH.skip[tgt]) then mine = tgt; break end
    end
    if not mine then COTH.dbg = 'everyone left is spoken for'; return end

    -- NOT WHILE ALREADY CASTING.
    if not iAmBard then
        local busy = 0
        pcall(function() busy = tonumber(mq.TLO.Me.Casting.ID()) or 0 end)
        if busy > 0 then COTH.dbg = 'already casting'; return end
    end

    local tid = 0
    pcall(function() tid = tonumber(mq.TLO.Spawn('pc =' .. mine).ID()) or 0 end)
    if tid <= 0 then COTH.dbg = mine .. ' is not in zone'; return end

    -- ASK FIRST, THEN SPEND THE EMBLEM. The answer is read on later ticks (coth_cast_step), not waited for.
    pcall(function() peer_cmdf(mine, '/at_cothwatch %s', myName) end)
    COTH.pending = { name = mine, at = now }
    COTH.cast = { phase = 'ask', name = mine, tid = tid, bard = iAmBard, untilT = now + COTH_ASK_MS }
end


COTH_SPELL = 'Call of the Hero'

function coth_item_has_emblem(item)
    local nm = ''
    pcall(function() nm = tostring(item.Name() or '') end)
    if nm == '' or nm == 'NULL' then return false end
    for a = 1, 6 do
        local stype = 0
        pcall(function() stype = tonumber(item['AugSlot' .. a]()) or 0 end)
        if stype > 0 and stype ~= 20 and stype ~= 30 then
            local an = ''
            pcall(function() an = tostring(item.AugSlot(a).Item.Name() or '') end)
            if an == COTH.ITEM then return true end
        end
    end
    -- Fallback: the item itself is the clicky rather than hosting an aug that is.
    local sp, cl = '', ''
    pcall(function() sp = tostring(mq.TLO.FindItem('=' .. nm).Spell.Name() or '') end)
    pcall(function() cl = tostring(mq.TLO.FindItem('=' .. nm).Clicky.Name() or '') end)
    local want = COTH_SPELL:lower()
    return sp:lower() == want or cl:lower() == want
end

-- Returns: name, alreadyWorn. nil when this character has no such item at all.
function coth_find_charm()
    local worn = ''
    pcall(function() worn = tostring(mq.TLO.Me.Inventory('charm').Name() or '') end)
    if worn ~= '' and worn ~= 'NULL' then
        local hit = false
        pcall(function() hit = coth_item_has_emblem(mq.TLO.Me.Inventory('charm')) end)
        if hit then return worn, true end
    end
    -- Twelve, not ten: augcheck walks pack1..12 and there is no reason to look at fewer.
    for pk = 1, 12 do
        local slots = 0
        pcall(function() slots = tonumber(mq.TLO.Me.Inventory('pack' .. pk).Container()) or 0 end)
        for s = 1, slots do
            local id = 0
            pcall(function() id = tonumber(mq.TLO.Me.Inventory('pack' .. pk).Item(s).ID()) or 0 end)
            if id > 0 then
                local hit, nm = false, ''
                pcall(function()
                    hit = coth_item_has_emblem(mq.TLO.Me.Inventory('pack' .. pk).Item(s))
                    nm  = tostring(mq.TLO.Me.Inventory('pack' .. pk).Item(s).Name() or '')
                end)
                if hit and nm ~= '' then return nm, false end
            end
        end
    end
    return nil, false
end

-- =========================================================================== SOLO GATHER - /atcoth
-- group.
COTHG = { active = false, at = nil, castAt = 0, done = 0, saidWait = 0, startedAt = 0 }
COTHG_GIVE_UP = 300000   -- a whole run cannot outlast this, however stubborn the list is

-- Everyone in the group except me, with what the CLIENT can see: spawn id and how far away they are.
-- A member with no spawn is in another zone and cannot be summoned - said once rather than retried.
function cothg_targets()
    local out = {}
    local n = 0
    pcall(function() n = tonumber(mq.TLO.Group.Members()) or 0 end)
    for i = 1, n do
        local nm, id, dist = '', 0, -1
        pcall(function() nm = tostring(mq.TLO.Group.Member(i).Name() or '') end)
        pcall(function() id = tonumber(mq.TLO.Group.Member(i).Spawn.ID()) or 0 end)
        pcall(function() dist = tonumber(mq.TLO.Group.Member(i).Spawn.Distance3D()) or -1 end)
        -- Distance3D exists (checked against MacroQuest's own MQ2SpawnType), but a failed read would
        -- come back -1 and read as 'far', which summons somebody standing next to me.
        if dist < 0 then
            pcall(function() dist = tonumber(mq.TLO.Group.Member(i).Spawn.Distance()) or -1 end)
        end
        if nm ~= '' and nm:lower() ~= myName:lower() then
            out[#out + 1] = { name = nm, id = id, dist = dist }
        end
    end
    return out
end

function cothg_set(on)
    if on then
        local x, y, z = 0, 0, 0
        pcall(function() x = tonumber(mq.TLO.Me.X()) or 0 end)
        pcall(function() y = tonumber(mq.TLO.Me.Y()) or 0 end)
        pcall(function() z = tonumber(mq.TLO.Me.Z()) or 0 end)
        COTHG.active, COTHG.at = true, { x = x, y = y, z = z }
        COTHG.castAt, COTHG.done, COTHG.saidWait = 0, 0, 0
        COTHG.startedAt = mq.gettime()
        rezlog('[cothg] solo gather started - I am the only summoner')
        -- SAY IT OUT LOUD.
        pcall(function() mq.cmd('/gsay CoTH: Gathering the group') end)
        -- The charm goes on the same way it does for a group gather, through the same code and the same
        -- recovery file. Off means click it from the bag, exactly as the toggle promises everywhere else.
        if cothSwap then cothSwapWant = { auto = true } end
    else
        COTHG.active = false
        rezlog('[cothg] solo gather stopped after %d summon(s)', COTHG.done or 0)
        cothSwapWant = { back = true, auto = true }
    end
end

function cothg_tick()
    if not COTHG.active then COTHG.cast = nil; return end
    local now = mq.gettime()
    -- A SUMMON IN HAND, in steps (1.21.2): see the cast start, then see it finish - looked at once a tick, not
    -- waited out inside it (it held the whole loop up to 3s, then up to 20s).
    local c = COTHG.cast
    if c then
        local casting = 0
        pcall(function() casting = tonumber(mq.TLO.Me.Casting.ID()) or 0 end)
        if c.phase == 'start' then
            local tr = -1
            pcall(function() tr = tonumber(mq.TLO.FindItem('=' .. COTH.ITEM).TimerReady()) or -1 end)
            if casting <= 0 and tr <= 0 then
                if now < c.untilT then return end
                rezlog('\\ay[cothg] the emblem never went out for %s\\ax', c.name)
                COTHG.cast = nil
                return
            end
            c.sawBar = casting > 0
            c.phase, c.untilT = 'cast', now + (c.sawBar and 20000 or 11000)
            return
        end
        if now < c.untilT and not (c.sawBar and casting <= 0) then return end
        COTHG.cast = nil
        COTHG.done = (COTHG.done or 0) + 1
        local wornNow = false
        pcall(function() wornNow = coth_item_has_emblem(mq.TLO.Me.Inventory('charm')) end)
        rezlog('[cothg]   cast finished for %s in %.1fs (emblem %s)', c.name,
               (mq.gettime() - c.castFrom) / 1000, wornNow and 'WORN' or 'in a bag')
        return
    end
    if (now - (COTHG.startedAt or now)) > COTHG_GIVE_UP then
        rezlog('\\ay[cothg] giving up after %ds\\ax', COTHG_GIVE_UP / 1000)
        pcall(function() mq.cmd('/gsay CoTH: giving up - some of you will need to make your own way.') end)
        cothg_set(false)
        return
    end
    -- Nothing starts until the charm is settled. cothSwapWant is cleared by the swap tick, so this is
    -- simply 'a swap has been asked for and has not run yet'.
    if cothSwapWant then return end

    local far, missing = {}, {}
    for _, m in ipairs(cothg_targets()) do
        if m.id <= 0 then missing[#missing + 1] = m.name
        elseif m.dist < 0 or m.dist > COTH.RANGE then far[#far + 1] = m end
    end
    if #far == 0 then
        rezlog('[cothg] everyone is here after %d summon(s)%s', COTHG.done or 0,
               (#missing > 0) and (' - not in zone: ' .. table.concat(missing, ', ')) or '')
        local secs = (now - (COTHG.startedAt or now)) / 1000
        -- Only worth saying if something actually happened - announcing a gather where nobody needed
        -- summoning is noise in somebody else's chat window.
        if (COTHG.done or 0) > 0 then
            pcall(function()
                mq.cmdf('/gsay CoTH: everyone is here - %d summoned in %.0f seconds.', COTHG.done, secs)
            end)
        end
        -- NAME WHO IS STILL OUT. This is the one thing a person can act on and the script cannot: a
        -- member in another zone has to walk or gate, and nobody knows that unless they are told.
        if #missing > 0 then
            pcall(function()
                mq.cmdf('/gsay CoTH: cannot reach %s - not in this zone.', table.concat(missing, ', '))
            end)
        end
        cothg_set(false)
        return
    end
    -- FURTHEST FIRST. With one summoner the order is only about not wasting a cast on somebody who was
    -- about to walk in anyway.
    table.sort(far, function(a, b) return (a.dist or 0) > (b.dist or 0) end)

    local em = coth_emblem()
    if em ~= 0 then
        if em > 0 and (now - (COTHG.saidWait or 0)) > 10000 then
            COTHG.saidWait = now
            rezlog('[cothg] emblem back in %ds - %d still out', em, #far)
        elseif em < 0 then
            rezlog('\\ay[cothg] I have no %s - stopping\\ax', COTH.ITEM)
            pcall(function() mq.cmd('/gsay CoTH: I cannot find my emblem - stopping.') end)
            cothg_set(false)
        end
        return
    end

    local t = far[1]
    -- SAME CURSOR GUARD AS THE GROUP GATHER. This path had none at all - it cast straight into whatever
    -- was held, and casting with an item on the cursor disconnects the client.
    local clear, stuck = cursor_stow('cothg')
    if not clear then
        rezlog('\\ar[cothg] NOT casting - "%s" is stuck on the cursor. Clear it and the next pass '
            .. 'will summon %s.\\ax', tostring(stuck or '?'), t.name)
        return
    end
    rezlog('[cothg] summoning %s (%d away)', t.name, t.dist or -1)
    pcall(function() mq.cmdf('/gsay CoTH: summoning %s now.', t.name) end)
    at_cast(COTH.ITEM .. COTH.OPTS, t.id)
    -- SAME TWO-PART WATCH AS THE GROUP GATHER: see the cast start, then see it finish (the steps at the top). A bard
    -- gets no bar from the emblem, so the reuse timer starting counts as proof it went out.
    COTHG.cast = { phase = 'start', name = t.name, castFrom = now, untilT = now + 3000 }
end

-- =========================================================================== CHARM SWAP - the emblem charm
-- goes on for a gather and the original comes back after
-- =========================================================================== Spell haste applies to a
-- clicky only when ...
cothCharmSaved = nil     -- what was in the charm slot before we touched it ('' = empty)
cothCharmWorn  = nil     -- what WE seated, so a charm that comes back off can be spotted and re-seated
cothCharmReseat = 0      -- how many times we have had to put it back this gather
cothSwapWant   = nil     -- set by the bind, drained by the main loop: this does cursor work and delays

-- OUR OWN HOLD, NOT THE PLACATE'S.
cothSwapHeld = false
function coth_swap_hold()
    if cothSwapHeld then return end
    cothSwapHeld = true
    e3_hold('cothswap')
end
function coth_swap_unhold(why)
    if not cothSwapHeld then return end
    cothSwapHeld = false
    e3_release('cothswap')
    rezlog('[coth] E3 released (%s)', why or 'done')
end

function coth_charm_recovery_path()
    local who = ''
    pcall(function() who = tostring(mq.TLO.Me.Name() or 'unknown') end)
    return at_read('adventuretime_cothcharm_' .. who .. '.txt')
end

function coth_charm_recovery_write()
    local fh = io.open(coth_charm_recovery_path(), 'w')
    if not fh then return end
    fh:write('charm=' .. (cothCharmSaved or '') .. '\n')
    fh:close()
end

function coth_charm_recovery_clear()
    pcall(function() os.remove(coth_charm_recovery_path()) end)
end

function coth_charm_recovery_read()
    local fh = io.open(coth_charm_recovery_path(), 'r')
    if not fh then return nil end
    local v = nil
    for line in fh:lines() do
        local k, val = line:match('^(%w+)=(.*)$')
        if k == 'charm' and val and val ~= '' then v = val end
    end
    fh:close()
    return v
end

-- ONE CLICK SWAPS (1.22.4). The new charm goes onto the cursor; one click on the charm slot puts it on and
-- lifts the old one onto the cursor in the same move; the old one goes into the bag slot the new one just
-- left, which is empty by definition. The slot is never empty along the way, and every step that fails
-- leaves the old charm worn - or, if the slot ever does read empty, puts whatever is on the cursor straight
-- back into it. Short waits that end as soon as the client shows the result, no fixed settles: about a
-- second a swap instead of three.
COTH_STEP_MS = 900   -- how long one click gets to show its result
COTH_TRIES   = 3

function coth_worn()
    local v = ''
    pcall(function() v = tostring(mq.TLO.Me.Inventory('charm').Name() or '') end)
    if v == 'NULL' then v = '' end
    return v
end
function coth_cursor()
    local v = ''
    pcall(function() v = tostring(mq.TLO.Cursor.Name() or '') end)
    if v == 'NULL' then v = '' end
    return v
end
function coth_click(spot) pcall(function() mq.cmdf('/itemnotify %s leftmouseup', spot) end) end

-- Where an item sits in the bags, as /itemnotify wants it: 'in packN S' inside a bag, 'packN' in a top-level
-- slot. nil when it is not in the bags (worn, in the bank, not carried).
function coth_bag_spot(name)
    local pk, s2
    pcall(function() pk = tonumber(mq.TLO.FindItem('=' .. name).ItemSlot()) end)
    pcall(function() s2 = tonumber(mq.TLO.FindItem('=' .. name).ItemSlot2()) end)
    if not pk or pk < 23 or pk > 32 then return nil end
    if s2 and s2 >= 0 then return string.format('in pack%d %d', pk - 22, s2 + 1) end
    return string.format('pack%d', pk - 22)
end

-- Whatever is on the cursor into `spot`, else into any free bag slot. true when the cursor is clear.
function coth_put_down(spot)
    if coth_cursor() == '' then return true end
    local held = coth_cursor()
    for n = 1, COTH_TRIES do
        coth_click(spot)
        mq.delay(COTH_STEP_MS, function() return coth_cursor() == '' end)
        if coth_cursor() == '' then return true end
        if coth_cursor() ~= held then break end   -- the spot was not empty and handed something back
        rezlog('[coth]   %s did not go into %s, retry %d', held, spot, n)
    end
    rezlog('\\ay[coth]   %s - into any free bag slot instead\\ax', coth_cursor())
    return cursor_stow('coth') == true
end

-- NEVER EMPTY. Called on every way out of a swap that did not finish: an empty slot with a charm on the
-- cursor gets that charm put straight back in.
function coth_never_empty(old)
    if coth_worn() ~= '' or old == '' then return end
    local held = coth_cursor()
    rezlog('\\ar[coth] the charm slot reads EMPTY - putting %s back on\\ax', (held ~= '') and held or old)
    if held == '' then
        local spot = coth_bag_spot(old)
        if not spot then rezlog('\\ar[coth] %s is not in the bags either\\ax', old); return end
        coth_click(spot)
        mq.delay(COTH_STEP_MS, function() return coth_cursor() ~= '' end)
    end
    coth_click('charm')
    mq.delay(COTH_STEP_MS, function() return coth_worn() ~= '' end)
    rezlog('[coth] charm slot now holds "%s"', coth_worn())
    if coth_cursor() ~= '' then cursor_stow('coth') end
end

-- Put `want` into the charm slot. true once it reads back as worn.
function coth_swap_in(want)
    local old = coth_worn()
    if old == want then return true end
    if coth_cursor() ~= '' then cursor_stow('coth') end
    if coth_cursor() ~= '' then
        rezlog('\\ar[coth] the cursor holds %s and will not clear - not swapping\\ax', coth_cursor())
        return false
    end
    if win_open_raw(COTH_BOX) then
        rezlog('\\ay[coth] a confirmation box is open - not swapping into it\\ax')
        return false
    end
    local spot = coth_bag_spot(want)
    if not spot then
        rezlog('\\ar[coth] %s is not in the bags - not swapping\\ax', want)
        return false
    end
    -- 1. The new charm onto the cursor. Nothing worn has changed yet.
    for n = 1, COTH_TRIES do
        -- By slot first; by name on a retry, the way the old swap always picked it up.
        coth_click((n == 1) and spot or ('"' .. want .. '"'))
        mq.delay(COTH_STEP_MS, function() return coth_cursor() == want end)
        if coth_cursor() == want then break end
        if coth_cursor() ~= '' then cursor_stow('coth') end
        rezlog('[coth]   %s did not come up from %s, retry %d', want, spot, n)
        spot = coth_bag_spot(want) or spot
    end
    if coth_cursor() ~= want then
        rezlog('\\ar[coth] %s never reached the cursor - %s stays on\\ax', want, (old ~= '') and old or '(empty slot)')
        if coth_cursor() ~= '' then cursor_stow('coth') end
        return false
    end
    -- 2. One click: the new charm on, the old one up onto the cursor.
    for n = 1, COTH_TRIES do
        coth_click('charm')
        mq.delay(COTH_STEP_MS, function() return coth_worn() == want end)
        if coth_worn() == want then break end
        if win_open_raw(COTH_BOX) then
            local _, txt = coth_attune_box()
            rezlog('\\ar[coth] %s put up a confirmation box: "%s"\\ax', want, tostring(txt):sub(1, 90))
            rezlog('\\ay[coth] equip it by hand once and answer the box - keeping %s on\\ax', (old ~= '') and old or '(empty slot)')
            coth_dismiss_box()
            break
        end
        if coth_worn() ~= old or coth_cursor() ~= want then break end   -- something else moved: stop clicking
        rezlog('[coth]   %s did not go on, retry %d', want, n)
    end
    if coth_worn() ~= want then
        rezlog('\\ar[coth] %s would not go on - the slot reads "%s"\\ax', want, coth_worn())
        coth_never_empty(old)
        if coth_cursor() ~= '' then coth_put_down(spot) end
        return false
    end
    -- 3. The old charm, now on the cursor, into the slot the new one just left. The lift can trail the
    -- seat by a moment, so wait for it rather than reading an empty cursor too early.
    if old ~= '' then
        mq.delay(COTH_STEP_MS, function() return coth_cursor() ~= '' end)
        if coth_cursor() == '' then
            rezlog('\\ay[coth]   %s never showed on the cursor after the swap\\ax', old)
        elseif not coth_put_down(spot) then
            rezlog('\\ar[coth] %s is still on the cursor - %s is worn; put it away by hand\\ax', coth_cursor(), want)
        end
    end
    -- 4. Read it back once more after the client has caught up.
    mq.delay(250)
    if coth_worn() ~= want then
        rezlog('\\ar[coth] charm reads "%s" after the swap, wanted %s\\ax', coth_worn(), want)
        coth_never_empty(old)
        return false
    end
    return true
end

-- Only for a slot that was EMPTY before the gather: putting it back means taking the charm off.
function coth_charm_take_off()
    local now = coth_worn()
    if now == '' then return true, '' end
    if coth_cursor() ~= '' then cursor_stow('coth') end
    for n = 1, COTH_TRIES do
        coth_click('charm')
        mq.delay(COTH_STEP_MS, function() return coth_cursor() == now end)
        if coth_cursor() == now then
            if cursor_stow('coth') then
                rezlog('[coth]   took off %s and stowed it', now)
                return true, now
            end
            rezlog('\\ar[coth] %s will not stow - putting it back on\\ax', now)
            coth_click('charm')
            mq.delay(COTH_STEP_MS, function() return coth_worn() == now end)
            return false, now
        end
        rezlog('[coth]   charm pickup did not take, retry %d of %d', n, COTH_TRIES)
    end
    return false, now
end

-- IS A CONFIRMATION BOX BLOCKING US?
COTH_BOX = 'ConfirmationDialogBox'

function coth_attune_box()
    if not win_open_raw(COTH_BOX) then return false, '' end
    local txt = ''
    pcall(function() txt = tostring(mq.TLO.Window(COTH_BOX).Child('CD_TextOutput').Text() or '') end)
    -- A box we do not recognise is still a box, and still blocks the inventory.
    return true, txt
end

-- NO, NEVER YES.
function coth_dismiss_box()
    for _, b in ipairs({ 'CD_No_Button', 'No_Button', 'CD_Cancel_Button' }) do
        pcall(function() mq.cmdf('/nomodkey /notify %s %s leftmouseup', COTH_BOX, b) end)
        mq.delay(120)
        if not win_open_raw(COTH_BOX) then return true end
    end
    return not win_open_raw(COTH_BOX)
end

function coth_charm_clear_record()
    cothCharmSaved = nil
    cothCharmWorn, cothCharmReseat = nil, 0
    coth_charm_recovery_clear()
end

function coth_charm_equip_inner(want)
    local now = coth_worn()
    if now == want then
        rezlog('[coth] %s is already worn - nothing to swap', want)
        return true
    end
    if not coth_bag_spot(want) then
        rezlog('\\ar[coth] cannot find "%s" in the bags - not swapping\\ax', want)
        return false
    end
    if win_open_raw(COTH_BOX) then
        rezlog('\\ay[coth] a confirmation box is open - not starting a swap into it\\ax')
        return false
    end
    -- E3 PAUSED FOR THE SWAP: a live E3 grabs the cursor and re-equips underneath us.
    coth_swap_hold()
    -- THE RECORD GOES TO DISK FIRST, so a crash mid-swap still knows what belongs in the slot.
    cothCharmSaved = now
    cothCharmWorn, cothCharmReseat = want, 0
    coth_charm_recovery_write()
    rezlog('[coth] charm slot holds "%s" - swapping in %s', (now ~= '') and now or '(empty)', want)
    local t0 = mq.gettime()
    if coth_swap_in(want) then
        rezlog('[coth] charm swap done - %s is worn (%dms)', want, mq.gettime() - t0)
        return true
    end
    if coth_worn() == now then
        -- Nothing changed: the old charm never came off. No record to keep, nothing to put back.
        coth_charm_clear_record()
        coth_swap_unhold('coth swap failed')
        return false
    end
    pcall(function() coth_charm_restore('swap aborted') end)
    return false
end

function coth_charm_restore_inner(why)
    local original = cothCharmSaved or coth_charm_recovery_read()
    if original == nil then
        coth_swap_unhold(why or 'nothing to restore')
        return true
    end
    if coth_worn() == original then
        rezlog('[coth] charm already back to "%s" (%s)', original, why or 'restore')
        coth_charm_clear_record()
        coth_swap_unhold(why or 'coth swap done')
        return true
    end
    local t0 = mq.gettime()
    local ok
    if original == '' then ok = coth_charm_take_off()
    else ok = coth_swap_in(original) end
    if ok and coth_worn() == original then
        rezlog('[coth] charm restored to "%s" (%s, %dms)', (original ~= '') and original or '(empty)',
               why or 'restore', mq.gettime() - t0)
        coth_charm_clear_record()
    else
        -- KEEP THE RECORD: it is what the backstop and /atcothswap back work from.
        ok = false
        rezlog('\\ar[coth] charm reads "%s", wanted "%s" - keeping the record to retry (/atcothswap back)\\ax',
               (coth_worn() ~= '') and coth_worn() or '(empty)', original)
    end
    coth_swap_unhold(why or 'coth swap done')
    return ok
end

-- ONE HOLD PER CALL, RELEASED WHATEVER HAPPENS.
function coth_charm_equip(want)
    if COTH_OPEN_BAGS then bags_hold() end
    local ran, res = pcall(coth_charm_equip_inner, want)
    if COTH_OPEN_BAGS then bags_drop() end
    if not ran then
        rezlog('\\ar[coth] charm swap errored: %s\\ax', tostring(res))
        return false
    end
    return res
end

function coth_charm_restore(why)
    if COTH_OPEN_BAGS then bags_hold() end
    local ran, res = pcall(coth_charm_restore_inner, why)
    if COTH_OPEN_BAGS then bags_drop() end
    if not ran then
        rezlog('\\ar[coth] charm restore errored: %s\\ax', tostring(res))
        return false
    end
    return res
end

-- Drained from the main loop, not the bind: this does cursor work and second-long delays, and a bind
-- runs inside doevents where blocking is how you hold the whole loop down.
if cothSwap == nil then cothSwap = true end

COTH_SWAP_MAX = 180000   -- backstop: never stay swapped longer than this, whatever the gather is doing

-- TELL THE GROUP, AND TELL MYSELF.
function coth_report_swap(state)
    COTH.swapped = COTH.swapped or {}
    COTH.swapped[myName] = state
    pcall(function() peer_bcast('/at_cothswapped %s %s', myName, state) end)
end
cothSwapAt    = 0

-- IT CAME OFF AGAIN.
function coth_charm_guard()
    if not cothCharmWorn or cothCharmWorn == '' then return end
    local now = ''
    pcall(function() now = tostring(mq.TLO.Me.Inventory('charm').Name() or '') end)
    if now == cothCharmWorn then return end
    if (cothCharmReseat or 0) >= COTH_RESEAT_MAX then return end
    cothCharmReseat = (cothCharmReseat or 0) + 1
    rezlog('\\ay[coth] %s came back off - slot now holds "%s" - reseating (%d of %d)\\ax',
           cothCharmWorn, (now ~= '') and now or '(empty)', cothCharmReseat, COTH_RESEAT_MAX)
    -- Clear the cursor first: whatever displaced the charm may still be on it, and clicking with a full
    -- cursor swaps the two round instead of fixing anything.
    cursor_stow('coth')
    if (mq.TLO.Cursor.ID() or 0) ~= 0 then
        rezlog('\\ar[coth] cursor will not clear - not reseating into a held item\\ax')
        return
    end
    if coth_swap_in(cothCharmWorn) then
        rezlog('[coth] %s is back on', cothCharmWorn)
    elseif cothCharmReseat >= COTH_RESEAT_MAX then
        rezlog('\\ar[coth] %s has come off %d times this gather - something is re-equipping underneath '
            .. 'us. Leaving it alone rather than fighting the client.\\ax', cothCharmWorn, cothCharmReseat)
    end
end

function coth_swap_tick()
    coth_charm_guard()
    -- BACKSTOP FIRST.
    if cothCharmSaved and cothSwapAt > 0 and (mq.gettime() - cothSwapAt) > COTH_SWAP_MAX then
        cothSwapAt = 0
        rezlog('\\ay[coth] swapped for over %ds - putting the charm back\\ax', COTH_SWAP_MAX / 1000)
        pcall(function() coth_charm_restore('stayed swapped too long') end)
        return
    end
    if not cothSwapWant then return end
    local w = cothSwapWant
    cothSwapWant = nil

    if w.back then
        cothSwapAt = 0
        coth_charm_restore(w.auto and 'gather finished' or 'asked by hand')
        return
    end

    -- The automatic path has no name to work from: find it. A character with no emblem simply has
    -- nothing to do, which is the honest answer for most of the group and needs no special case.
    local name = w.name
    local wornAlready = false
    if w.auto then
        name, wornAlready = coth_find_charm()
    end
    -- SWITCHED OFF: answer immediately and do nothing. Reporting still matters - a character that is not
    -- swapping must say so, or the gather waits the full COTH_SWAP_WAIT for an answer never coming.
    if w.auto and not cothSwap then
        coth_report_swap('off')
        return
    end
    if w.auto and (not name or wornAlready) then
        -- Nothing to swap. Report anyway - the driver is counting answers, and a character that cannot
        -- help still has to say so or the whole gather waits on it.
        coth_report_swap(name and 'worn' or 'none')
        return
    end
    if not name then
        rezlog('[coth] no charm holding the %s was found', COTH.ITEM)
        return
    end
    local ok = coth_charm_equip(name)
    if ok then cothSwapAt = mq.gettime() end
    if w.auto then coth_report_swap(ok and 'ok' or 'fail') end
end

-- A RECORD LEFT ON DISK means the last run stopped while swapped (a crash, /lua stop mid-gather). Put the
-- charm back on the first pass of the main loop instead of waiting for someone to notice.
do
    local left = nil
    pcall(function() left = coth_charm_recovery_read() end)
    if left and cothSwapWant == nil then
        rezlog('[coth] the last run stopped with the charm swapped - putting "%s" back', left)
        cothSwapWant = { back = true }
    end
end
