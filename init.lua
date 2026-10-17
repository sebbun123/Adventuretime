-- ===========================================================================
--  AdventureTime 1.22  -  group consumable distributor for MacroQuest
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
--  RGMERCS GROUPS:  /lua run adventuretime/rg  instead (see rg.lua beside this file). Same code;
--                 it pins bot control to RGMercs and sends casts natively rather than via E3.
--  REQUIREMENTS:  MacroQuest with a Lua/ImGui build + one of E3 / EQBC / DanNet.
--  INSTALL:       put AdventureTime.lua in your MacroQuest  lua/  folder.
--  SETTINGS:      per-item targets persist to AdventureTime_targets.ini beside
--                 this file.
--
--  Item names, the Emerald vendor (Audri Deepfacet), and the class lists are
--  Project Lazarus specific - edit ITEMS / VENDOR / WANTS_* near the top to fit
--  a different server or consumable set. Provided as-is; have fun out there.
-- ===========================================================================

-- THE WHOLE RUN, CAUGHT (1.21.1). An error used to go only to the MQ console and the character simply
-- stopped (1.20.46 logs: Lunafeet, Stylin and Sunetoo each went silent with no last word, and the driver
-- restarted them minutes later). The file runs itself once more inside xpcall, so the traceback lands in the
-- AT log as well; the error still stops the script as before. Globals only: the main chunk is at Lua's
-- 200-local ceiling, and the main loop cannot be a function (more than 60 upvalues). If loadfile is not
-- there, it simply runs as it always did.
if not AT_RUN_WRAPPED and type(loadfile) == 'function' and type(xpcall) == 'function' then
    AT_RUN_WRAPPED = true
    AT_RUN_SRC = tostring((debug.getinfo(1, 'S') or {}).source or ''):gsub('^@', '')
    AT_RUN_CHUNK = (AT_RUN_SRC ~= '') and loadfile(AT_RUN_SRC) or nil
    if AT_RUN_CHUNK then
        AT_RUN_OK, AT_RUN_ERR = xpcall(AT_RUN_CHUNK, debug.traceback, ...)
        if not AT_RUN_OK then
            pcall(function()
                local f = AT_LOG_FILE_PATH and io.open(AT_LOG_FILE_PATH, 'a')
                if f then
                    f:write(os.date('[%H:%M:%S] ') .. '[error] AdventureTime stopped on an error: ' .. tostring(AT_RUN_ERR) .. '\n')
                    f:close()
                end
            end)
            pcall(function() print('\ar[AdventureTime] stopped on an error - the traceback is in the AT log\ax') end)
            error(AT_RUN_ERR, 0)
        end
        return
    end
end

local mq    = require('mq')

-- =========================================================================== WHICH HANDLER IS
-- BLOCKING?

-- EVERY USER-FACING COMMAND THIS SCRIPT BINDS, collected as they are registered rather than written out
-- by hand.
AT_ALL_BINDS = {}
-- AND COUNT INBOUND RELAY TRAFFIC, in the same wrapper.
do
    local realBind = mq.bind
    mq.bind = function(name, fn)
        if type(name) == 'string' and name:sub(1, 4) ~= '/at_' then
            AT_ALL_BINDS[#AT_ALL_BINDS + 1] = name
            return realBind(name, fn)
        end
        if type(name) == 'string' and type(fn) == 'function' then
            local cmd = name
            return realBind(name, function(...)
                pcall(function() net_in(cmd) end)
                return fn(...)
            end)
        end
        return realBind(name, fn)
    end
end

local ImGui = require('ImGui')
-- MODULES (1.22.0). Parts of AdventureTime live in modules/ next to this file, each loaded in place with
-- at_module(name) - where its code used to sit in this file. They share state through globals (this chunk is at
-- Lua's 200-local ceiling; a local here cannot be seen from another file).
AT_SRC_DIR = (AT_RUN_SRC and AT_RUN_SRC ~= '' and AT_RUN_SRC or (tostring((debug.getinfo(1, 'S') or {}).source or ''):gsub('^@', '')))
AT_SRC_DIR = AT_SRC_DIR:match('^(.*[/\\])') or ''
function at_module(name)
    local path = AT_SRC_DIR .. 'modules/' .. name .. '.lua'
    local chunk, err = loadfile(path)
    if not chunk then error('AdventureTime: cannot load ' .. path .. ' (' .. tostring(err) .. ') - is the modules folder there?', 0) end
    return chunk()
end

local scriptName = 'AdventureTime'
-- A human-launched instance shows the UI and drives; instances the driver auto-starts get the
-- 'worker' arg (see the /lua run below) and run HEADLESS - same file, no window, just obey the
-- driver's /at_* commands (pause/trade/bags). No UI = no accidental second driver.
local ARGS = { ... }
-- WHICH FILE STARTED US. rg.lua (the RGMercs entry) sets AT_ENTRY before loading this file, so the
-- workers it spawns on the rest of the group are started the same way and end up on the same backend.
AT_ENTRY = AT_ENTRY or 'adventuretime'
local SHOW_UI = (ARGS[1] ~= 'worker')
-- VERSION vs BUILD_TAG.
VERSION = '1.22'
local BUILD_TAG = '1.22.6'  -- bump on every change; prints on startup

-- ONE PLACE FOR THE UI COLOURS.
UI_POT_RGB = { 150, 130, 230 }
UI_SECTION = {
    rez        = { dot = {  95, 165, 230 }, label = { 0.52, 0.70, 0.90 } },  -- blue
    di         = { dot = { 150, 120, 215 }, label = { 0.64, 0.56, 0.85 } },  -- violet
    burns      = { dot = { 225, 120,  70 }, label = { 0.88, 0.56, 0.38 } },  -- ember
    running    = { dot = {  90, 210, 255 }, label = { 0.42, 0.78, 0.94 } },  -- cyan: matches 'running' everywhere else
    raid       = { dot = { 130, 170, 235 }, label = { 0.51, 0.67, 0.92 } },  -- cool blue: a roster, not an alarm
    groupheals = { dot = {  80, 185, 130 }, label = { 0.45, 0.76, 0.58 } },  -- green
    invis      = { dot = { 130, 140, 160 }, label = { 0.58, 0.62, 0.70 } },  -- slate
    protect    = { dot = { 215, 170,  70 }, label = { 0.85, 0.72, 0.40 } },  -- gold
    coth       = { dot = {  70, 180, 190 }, label = { 0.40, 0.76, 0.80 } },  -- teal
    nightveil  = { dot = { 175, 105, 175 }, label = { 0.72, 0.50, 0.74 } },  -- magenta
    effects    = { dot = {  90, 210, 255 }, label = { 0.42, 0.78, 0.94 } },  -- cyan, like everything running
    pacify     = { dot = { 190, 195, 120 }, label = { 0.76, 0.78, 0.52 } },  -- pale olive
}

-- DRAW, DO NOT SPELL.

-- A COOLDOWN RING.
uiDlTextOK = nil   -- nil = untried, true = AddText works, false = fall back to the cursor path

function ui_dl_text(dl, x, y, rgb, text)
    if text == nil or text == '' then return end
    if uiDlTextOK ~= false then
        local ok = pcall(function()
            dl:AddText(ImVec2(x, y), IM_COL32(rgb[1], rgb[2], rgb[3], 255), text)
        end)
        if ok then uiDlTextOK = true; return end
        uiDlTextOK = false
    end
    -- Exactly what these widgets did before. The caller restores the cursor either way.
    ImGui.SetCursorScreenPos(x, y)
    ImGui.TextColored(rgb[1] / 255, rgb[2] / 255, rgb[3] / 255, 1.0, text)
end

function ui_ring(frac, rgb, label, size, thick, centreDot)
    local ok = pcall(function()
        local fs = ImGui.GetFontSize()
        local d  = size or math.floor(fs * 1.9)
        local r  = d * 0.5
        local w  = thick or 2.5
        local cx, cy = ImGui.GetCursorScreenPos()
        local mx, my = cx + r, cy + r
        local dl = ImGui.GetWindowDrawList()
        -- The track first: a full faint ring, so an almost-empty one still reads as a ring rather
        -- than as a stray arc floating in the panel.
        dl:AddCircle(ImVec2(mx, my), r - w * 0.6, IM_COL32(rgb[1], rgb[2], rgb[3], 55), 0, w)
        frac = math.max(0, math.min(1, frac or 0))
        if frac > 0.001 then
            local a0 = -math.pi * 0.5
            dl:PathClear()
            dl:PathArcTo(ImVec2(mx, my), r - w * 0.6, a0, a0 + (math.pi * 2 * frac))
            dl:PathStroke(IM_COL32(rgb[1], rgb[2], rgb[3], 235), 0, w)
        end
        if centreDot then
            dl:AddCircleFilled(ImVec2(mx, my), math.max(1.5, r * 0.32),
                               IM_COL32(rgb[1], rgb[2], rgb[3], 235), 0)
        end
        if label and label ~= '' then
            local tw = ImGui.CalcTextSize(label)
            ui_dl_text(dl, mx - tw * 0.5, my - fs * 0.5, rgb, label)
        end
        ImGui.SetCursorScreenPos(cx, cy)
        -- Reserve the ring's WIDTH but only a text line's HEIGHT. A square Dummy makes every row it
        -- appears in taller than the text beside it, which is what turns a tidy grid ragged.
        ImGui.Dummy(d, math.max(d, fs))
    end)
    if not ok then ImGui.Text(label or '') end
end

-- HOW WIDE DOES THIS TEXT ACTUALLY NEED TO BE?
function ui_fit_w(text, minW)
    local w = minW or 0
    pcall(function()
        local t = ImGui.CalcTextSize(text)
        if t then w = math.max(w, math.ceil(t) + 14) end   -- frame padding either side
    end)
    return w
end

-- CENTRE THE NEXT MARK IN ITS TABLE CELL.
function ui_cell_centre(w)
    pcall(function()
        local avail = ImGui.GetContentRegionAvail()
        if avail and avail > w then
            ImGui.SetCursorPosX(ImGui.GetCursorPosX() + (avail - w) * 0.5)
        end
    end)
end

-- WRAPPING ROWS.
UI_MAX_ROW   = 420
uiRowStarted = false
uiChainNameLen = 4   -- set per frame by the rez table; how much name its scope buttons show

-- ASK WHERE THE CURSOR ACTUALLY IS.
function ui_row_reset(_)
    uiRowStarted = false
end

-- Call BEFORE drawing an item, with the width it is about to take.
function ui_row_item(w)
    if not uiRowStarted then uiRowStarted = true; return end
    ImGui.SameLine(0, 6)
    local x = 0
    pcall(function() x = ImGui.GetCursorPosX() or 0 end)
    -- Past the limit once this item is placed: undo the SameLine and let it fall to the next line.
    if x + (w or 0) > UI_MAX_ROW then pcall(function() ImGui.NewLine() end) end
end

-- EXPERIMENT 3: THE SEGMENTED RING.
function ui_seg_ring(segs, size, thick)
    local ok = pcall(function()
        local fs = ImGui.GetFontSize()
        local d  = size or math.floor(fs * 1.05)
        local r  = d * 0.5
        local w  = thick or 2.2
        local cx, cy = ImGui.GetCursorScreenPos()
        local mx, my = cx + r, cy + r
        local dl = ImGui.GetWindowDrawList()
        local n = #segs
        if n < 1 then ImGui.Dummy(d, math.max(d, fs)); return end
        local span = (math.pi * 2) / n
        local gap  = math.min(span * 0.18, 0.25)
        for i, sg in ipairs(segs) do
            local a0 = -math.pi * 0.5 + (i - 1) * span + gap * 0.5
            local a1 = a0 + span - gap
            local c  = sg.rgb or { 150, 150, 160 }
            dl:PathClear()
            dl:PathArcTo(ImVec2(mx, my), r - w * 0.6, a0, a1)
            dl:PathStroke(IM_COL32(c[1], c[2], c[3], 55), 0, w)
            -- fill grows as the burn comes back: 0 remaining = the whole segment
            local f = math.max(0, math.min(1, sg.fill or 0))
            if f > 0.02 then
                dl:PathClear()
                dl:PathArcTo(ImVec2(mx, my), r - w * 0.6, a0, a0 + (a1 - a0) * f)
                dl:PathStroke(IM_COL32(c[1], c[2], c[3], 240), 0, w)
            end
        end
        ImGui.Dummy(d, math.max(d, fs))
    end)
    if not ok then ImGui.Text('o') end
end

-- EXPERIMENT 1: THE READY PULSE.
UI_PULSE    = true
UI_PULSE_MS = 1500
uiPulseSeen = {}   -- id -> true once it has been ready at least once
uiPulseAt   = {}   -- id -> gettime when it became ready

function ui_pulse_note(id, isReady)
    if not id then return end
    if isReady then
        if uiPulseSeen[id] == false then uiPulseAt[id] = mq.gettime() end
        uiPulseSeen[id] = true
    else
        uiPulseSeen[id] = false
        uiPulseAt[id] = nil
    end
end

-- Drawn AROUND whatever mark was just placed, so it works for a disc or a name button alike.
function ui_pulse_draw(id, rgb, x, y, w, h)
    if not (UI_PULSE and id and uiPulseAt[id]) then return end
    local dt = mq.gettime() - uiPulseAt[id]
    if dt > UI_PULSE_MS then uiPulseAt[id] = nil; return end
    pcall(function()
        local k = dt / UI_PULSE_MS
        local a = math.floor(200 * (1 - k))
        local grow = 2 + k * 7
        ImGui.GetWindowDrawList():AddRect(
            ImVec2(x - grow, y - grow), ImVec2(x + w + grow, y + h + grow),
            IM_COL32(rgb[1], rgb[2], rgb[3], a), (h + grow * 2) * 0.5, 0, 1.5)
    end)
end

-- The ready state: a filled disc, so it reads as louder than any partial ring beside it.
function ui_disc(rgb, size, pulseId)
    local ok = pcall(function()
        local fs = ImGui.GetFontSize()
        local d = size or math.floor(fs * 0.78)
        local r = d * 0.5
        local cx, cy = ImGui.GetCursorScreenPos()
        local top = cy + math.floor(fs * 0.5) - r
        if pulseId then
            ui_pulse_note(pulseId, true)
            ui_pulse_draw(pulseId, rgb, cx, top, d, d)
        end
        ImGui.GetWindowDrawList():AddCircleFilled(
            ImVec2(cx + r, cy + math.floor(fs * 0.5)), r, IM_COL32(rgb[1], rgb[2], rgb[3], 240), 0)
        ImGui.Dummy(d, fs)
    end)
    if not ok then ImGui.Text('*') end
end

burnPeak = {}   -- longest remaining seen per burn item; the ring's denominator

-- A STOP SIGN.
function ui_stop_button(id, on, size)
    local clicked = false
    local ok = pcall(function()
        local d = size or math.floor(ImGui.GetFontSize() * 1.5)
        local x, y = ImGui.GetCursorScreenPos()
        ImGui.InvisibleButton(id, d, d)
        clicked = ImGui.IsItemClicked()
        local hov = ImGui.IsItemHovered()
        local dl  = ImGui.GetWindowDrawList()
        local cx, cy, r = x + d * 0.5, y + d * 0.5, d * 0.46
        if on then
            local red = hov and IM_COL32(224, 72, 64, 255) or IM_COL32(196, 48, 44, 255)
            dl:AddNgonFilled(ImVec2(cx, cy), r, red, 8)
            local bw, bh = r * 0.55, math.max(1.5, r * 0.14)
            dl:AddRectFilled(ImVec2(cx - bw, cy - bh), ImVec2(cx + bw, cy + bh),
                             IM_COL32(255, 248, 242, 255), 1.0)
        else
            local a = hov and 235 or 150
            dl:AddNgon(ImVec2(cx, cy), r, IM_COL32(196, 92, 86, a), 8, 2.0)
            local bw, bh = r * 0.45, math.max(1.2, r * 0.11)
            dl:AddRectFilled(ImVec2(cx - bw, cy - bh), ImVec2(cx + bw, cy + bh),
                             IM_COL32(196, 92, 86, a), 1.0)
        end
    end)
    if not ok then clicked = ImGui.SmallButton((on and 'Clear wipe##' or 'Wipe##') .. id) end
    return clicked
end

-- A RUNNING BURN SHOULD LOOK LIKE IT IS RUNNING.
function ui_spinner(rgb, size)
    local ok = pcall(function()
        local fs = ImGui.GetFontSize()
        local d  = size or math.floor(fs * 1.05)
        local r  = d * 0.5
        local cx, cy = ImGui.GetCursorScreenPos()
        local mx, my = cx + r, cy + r
        local dl = ImGui.GetWindowDrawList()
        dl:AddCircleFilled(ImVec2(mx, my), r - 3, IM_COL32(rgb[1], rgb[2], rgb[3], 90), 0)
        local a0 = (mq.gettime() % 1400) / 1400 * math.pi * 2
        dl:PathClear()
        dl:PathArcTo(ImVec2(mx, my), r - 1.5, a0, a0 + math.pi * 0.7)
        dl:PathStroke(IM_COL32(rgb[1], rgb[2], rgb[3], 250), 0, 2.2)
        ImGui.Dummy(d, math.max(d, fs))
    end)
    if not ok then ImGui.Text('*') end
end

-- A REAL TOGGLE, not a checkbox.
function ui_check(label, on)
    local text = tostring(label or ''):gsub('##.*$', '')
    local id   = tostring(label or ''):match('##.*$') or ('##chk_' .. text)
    local v = on and true or false
    if ui_toggle(id, v) then v = not v end
    if text ~= '' then
        ImGui.SameLine()
        ImGui.Text(text)
    end
    return v
end

function ui_toggle(id, isOn, w, h)
    local clicked = false
    local ok = pcall(function()
        local fs = ImGui.GetFontSize()
        w = w or math.floor(fs * 2.2)
        h = h or math.floor(fs * 1.15)
        local r = h * 0.5
        local x, y = ImGui.GetCursorScreenPos()
        ImGui.InvisibleButton(id, w, h)
        clicked = ImGui.IsItemClicked()
        local hov = ImGui.IsItemHovered()
        local dl = ImGui.GetWindowDrawList()
        local tr = isOn and { 60, 130, 85 } or { 58, 62, 74 }
        if hov then tr = { math.min(255, tr[1] + 25), math.min(255, tr[2] + 25), math.min(255, tr[3] + 25) } end
        dl:AddRectFilled(ImVec2(x, y), ImVec2(x + w, y + h), IM_COL32(tr[1], tr[2], tr[3], 255), r)
        local kx = isOn and (x + w - r) or (x + r)
        dl:AddCircleFilled(ImVec2(kx, y + r), r - 2,
            IM_COL32(isOn and 225 or 150, isOn and 240 or 152, isOn and 228 or 160, 255), 0)
    end)
    if not ok then
        local v = ImGui.Checkbox(id, isOn)
        clicked = (v ~= isOn)
    end
    return clicked
end

-- EXPERIMENT 2: HP AS BARS RATHER THAN DOTS.

-- THE WHOLE GROUP IN ONE STRIP. Six dots, one per character, coloured by whatever the caller cares
-- about. Sits above the panels so "is anyone in trouble" is answerable without reading a single row.

-- WINDOW CHROME, PUSHED ONCE AROUND Begin/End.
UI_CHROME = true

-- FIVE FRAMES, ONE SWITCH.
AT_THEMES = {
    { name = 'Midnight',                       -- the original: deep blue-black, soft corners
      cols = { WindowBg = { 18, 20, 27, 242 }, TitleBg = { 24, 28, 40, 255 },
               ResizeGrip = { 0, 0, 0, 0 }, ResizeGripHovered = { 62, 72, 96, 140 },
               ResizeGripActive = { 80, 95, 125, 190 },
               ScrollbarBg = { 0, 0, 0, 0 }, ScrollbarGrab = { 44, 50, 66, 200 },
               ScrollbarGrabHovered = { 62, 72, 96, 230 }, Separator = { 46, 54, 72, 200 },
               TitleBgActive = { 38, 54, 84, 255 }, Border = { 46, 54, 72, 255 },
               FrameBg = { 32, 36, 48, 255 }, FrameBgHovered = { 48, 54, 72, 255 },
               Button = { 44, 50, 66, 255 }, ButtonHovered = { 62, 72, 96, 255 },
               ButtonActive = { 80, 95, 125, 255 },
               TableRowBg = { 22, 24, 32, 255 }, TableRowBgAlt = { 26, 29, 39, 255 } },
      vars = { WindowRounding = 6, FrameRounding = 4, ChildRounding = 4, WindowBorderSize = 1 , WindowTitleAlign = 0.5, ScrollbarSize = 10, ScrollbarRounding = 5, GrabRounding = 4, PopupRounding = 6} },

    { name = 'Slate',                          -- neutral grey, square, hairline border. Quiet.
      cols = { WindowBg = { 26, 27, 30, 240 }, TitleBg = { 34, 35, 39, 255 },
               ResizeGrip = { 0, 0, 0, 0 }, ResizeGripHovered = { 72, 75, 82, 140 },
               ResizeGripActive = { 92, 96, 104, 190 },
               ScrollbarBg = { 0, 0, 0, 0 }, ScrollbarGrab = { 52, 54, 60, 200 },
               ScrollbarGrabHovered = { 72, 75, 82, 230 }, Separator = { 70, 72, 78, 200 },
               TitleBgActive = { 52, 54, 60, 255 }, Border = { 70, 72, 78, 255 },
               FrameBg = { 40, 42, 46, 255 }, FrameBgHovered = { 56, 58, 64, 255 },
               Button = { 52, 54, 60, 255 }, ButtonHovered = { 72, 75, 82, 255 },
               ButtonActive = { 92, 96, 104, 255 },
               TableRowBg = { 30, 31, 35, 255 }, TableRowBgAlt = { 34, 35, 40, 255 } },
      vars = { WindowRounding = 0, FrameRounding = 0, ChildRounding = 0, WindowBorderSize = 1 , WindowTitleAlign = 0.5, ScrollbarSize = 9,  ScrollbarRounding = 0, GrabRounding = 0, PopupRounding = 0} },

    { name = 'Ember',                           -- near-black ground, warm edges. Matches the burn ramp.
      cols = { WindowBg = { 22, 18, 16, 244 }, TitleBg = { 36, 26, 20, 255 },
               ResizeGrip = { 0, 0, 0, 0 }, ResizeGripHovered = { 84, 58, 34, 140 },
               ResizeGripActive = { 122, 80, 40, 190 },
               ScrollbarBg = { 0, 0, 0, 0 }, ScrollbarGrab = { 54, 38, 26, 200 },
               ScrollbarGrabHovered = { 84, 58, 34, 230 }, Separator = { 96, 62, 34, 200 },
               TitleBgActive = { 92, 54, 24, 255 }, Border = { 96, 62, 34, 255 },
               FrameBg = { 40, 30, 24, 255 }, FrameBgHovered = { 62, 44, 30, 255 },
               Button = { 54, 38, 26, 255 }, ButtonHovered = { 84, 58, 34, 255 },
               ButtonActive = { 122, 80, 40, 255 },
               TableRowBg = { 26, 21, 18, 255 }, TableRowBgAlt = { 31, 25, 21, 255 } },
      vars = { WindowRounding = 8, FrameRounding = 6, ChildRounding = 6, WindowBorderSize = 1 , WindowTitleAlign = 0.5, ScrollbarSize = 10, ScrollbarRounding = 6, GrabRounding = 6, PopupRounding = 8} },

    { name = 'Glass',                           -- barely there: heavy transparency, no border, no corners
      cols = { WindowBg = { 12, 14, 20, 170 }, TitleBg = { 16, 20, 30, 190 },
               ResizeGrip = { 0, 0, 0, 0 }, ResizeGripHovered = { 255, 255, 255, 40 },
               ResizeGripActive = { 255, 255, 255, 70 },
               ScrollbarBg = { 0, 0, 0, 0 }, ScrollbarGrab = { 255, 255, 255, 40 },
               ScrollbarGrabHovered = { 255, 255, 255, 70 }, Separator = { 255, 255, 255, 45 },
               TitleBgActive = { 30, 42, 66, 210 }, Border = { 0, 0, 0, 0 },
               FrameBg = { 30, 34, 46, 160 }, FrameBgHovered = { 48, 54, 72, 190 },
               Button = { 40, 46, 62, 170 }, ButtonHovered = { 60, 70, 94, 200 },
               ButtonActive = { 78, 92, 122, 220 },
               TableRowBg = { 0, 0, 0, 0 }, TableRowBgAlt = { 255, 255, 255, 10 } },
      vars = { WindowRounding = 10, FrameRounding = 8, ChildRounding = 8, WindowBorderSize = 0 , WindowTitleAlign = 0.5, ScrollbarSize = 8,  ScrollbarRounding = 6, GrabRounding = 6, PopupRounding = 10} },
}
uiTheme = 'Midnight'

function at_theme()
    for _, t in ipairs(AT_THEMES) do if t.name == uiTheme then return t end end
    return AT_THEMES[1]
end

function ui_push_chrome()
    if not UI_CHROME then return 0, 0 end
    local th = at_theme()
    local cols, vars = 0, 0
    local function col(slot, rgba)
        if not slot or not rgba then return end
        if pcall(function() ImGui.PushStyleColor(slot, IM_COL32(rgba[1], rgba[2], rgba[3], rgba[4])) end) then
            cols = cols + 1
        end
    end
    local function var(slot, a, b)
        if not slot or a == nil then return end
        local ok = pcall(function()
            if b then ImGui.PushStyleVar(slot, a, b) else ImGui.PushStyleVar(slot, a) end
        end)
        if ok then vars = vars + 1 end
    end
    -- Counted, not assumed. A slot the binding does not have simply is not pushed, and the caller pops
    -- exactly what went on - which is the difference between a missing colour and an ImGui stack assert.
    local c = th.cols or {}
    col(ImGuiCol.WindowBg,       c.WindowBg)
    col(ImGuiCol.TitleBg,        c.TitleBg)
    col(ImGuiCol.TitleBgActive,  c.TitleBgActive)
    col(ImGuiCol.Border,         c.Border)
    col(ImGuiCol.FrameBg,        c.FrameBg)
    col(ImGuiCol.FrameBgHovered, c.FrameBgHovered)
    col(ImGuiCol.Button,         c.Button)
    col(ImGuiCol.ButtonHovered,  c.ButtonHovered)
    col(ImGuiCol.ButtonActive,   c.ButtonActive)
    col(ImGuiCol.TableRowBg,     c.TableRowBg)
    col(ImGuiCol.TableRowBgAlt,  c.TableRowBgAlt)
    -- THE TELLS.
    col(ImGuiCol.ResizeGrip,           c.ResizeGrip)
    col(ImGuiCol.ResizeGripHovered,    c.ResizeGripHovered)
    col(ImGuiCol.ResizeGripActive,     c.ResizeGripActive)
    col(ImGuiCol.ScrollbarBg,          c.ScrollbarBg)
    col(ImGuiCol.ScrollbarGrab,        c.ScrollbarGrab)
    col(ImGuiCol.ScrollbarGrabHovered, c.ScrollbarGrabHovered)
    col(ImGuiCol.Separator,            c.Separator)
    -- THE SLOTS THAT ONLY SHOW UP ONCE WINDOWS ARE MERGED.
    local function pick(named, fallback) return named or fallback end
    col(ImGuiCol.Tab,                pick(c.Tab,                c.TitleBg))
    col(ImGuiCol.TabHovered,         pick(c.TabHovered,         c.ButtonHovered))
    col(ImGuiCol.TabActive,          pick(c.TabActive,          c.TitleBgActive))
    col(ImGuiCol.TabUnfocused,       pick(c.TabUnfocused,       c.TitleBg))
    col(ImGuiCol.TabUnfocusedActive, pick(c.TabUnfocusedActive, c.FrameBg))
    col(ImGuiCol.TitleBgCollapsed,   pick(c.TitleBgCollapsed,   c.TitleBg))
    col(ImGuiCol.Header,             pick(c.Header,             c.Button))
    col(ImGuiCol.HeaderHovered,      pick(c.HeaderHovered,      c.ButtonHovered))
    col(ImGuiCol.HeaderActive,       pick(c.HeaderActive,       c.ButtonActive))
    col(ImGuiCol.PopupBg,            pick(c.PopupBg,            c.WindowBg))
    col(ImGuiCol.MenuBarBg,          pick(c.MenuBarBg,          c.TitleBg))
    col(ImGuiCol.CheckMark,          pick(c.CheckMark,          c.ButtonActive))
    col(ImGuiCol.SliderGrab,         pick(c.SliderGrab,         c.Button))
    col(ImGuiCol.SliderGrabActive,   pick(c.SliderGrabActive,   c.ButtonActive))
    col(ImGuiCol.DockingPreview,     pick(c.DockingPreview,     c.TitleBgActive))
    col(ImGuiCol.DockingEmptyBg,     pick(c.DockingEmptyBg,     c.WindowBg))
    local v = th.vars or {}
    var(ImGuiStyleVar.WindowRounding,   v.WindowRounding)
    var(ImGuiStyleVar.FrameRounding,    v.FrameRounding)
    var(ImGuiStyleVar.ChildRounding,    v.ChildRounding)
    var(ImGuiStyleVar.WindowBorderSize, v.WindowBorderSize)
    var(ImGuiStyleVar.ScrollbarSize,     v.ScrollbarSize)
    var(ImGuiStyleVar.ScrollbarRounding, v.ScrollbarRounding)
    var(ImGuiStyleVar.GrabRounding,      v.GrabRounding)
    var(ImGuiStyleVar.PopupRounding,     v.PopupRounding)
    -- A CENTRED TITLE, which is a two-float var - the only one here that is. Left-aligned is the stock
    -- setting and reads as a debug window more than anything else a single line can change.
    if v.WindowTitleAlign then var(ImGuiStyleVar.WindowTitleAlign, v.WindowTitleAlign, 0.5) end
    -- WHAT ACTUALLY LANDED.
    if AT_chromeSaid ~= uiTheme then
        AT_chromeSaid = uiTheme
        AT_chromeNote = string.format('[ui] theme "%s": %d/%d colours and %d/%d style vars accepted',
                                      uiTheme, cols, 34, vars, 9)
    end
    return cols, vars
end

function ui_pop_chrome(cols, vars)
    if (vars or 0) > 0 then pcall(function() ImGui.PopStyleVar(vars) end) end
    if (cols or 0) > 0 then pcall(function() ImGui.PopStyleColor(cols) end) end
end

-- A DRAWN PADLOCK, because the lock was an emoji sitting in the chrome of both windows - and an emoji
-- is the one glyph guaranteed to be rendered by a different font than everything around it, at a size
-- nothing else uses.
function ui_lock_button(id, locked, size)
    local fs = 16
    pcall(function() fs = ImGui.GetFontSize() or 16 end)
    local d  = size or math.floor(fs * 0.95)
    local pressed = false
    local ok = pcall(function()
        local x, y = ImGui.GetCursorScreenPos()
        pressed = ImGui.InvisibleButton(id, d, d)
        local hov = ImGui.IsItemHovered and ImGui.IsItemHovered()
        local dl  = ImGui.GetWindowDrawList()
        local col = locked and IM_COL32(225, 195, 110, hov and 255 or 220)
                            or IM_COL32(150, 155, 170, hov and 255 or 190)
        local bw, bh = d * 0.72, d * 0.46
        local bx, by = x + (d - bw) * 0.5, y + d - bh - 1
        dl:AddRectFilled(ImVec2(bx, by), ImVec2(bx + bw, by + bh), col, 2)
        -- The shackle: a half arc above the body. Shut sits centred and closed; open is lifted and
        -- swung off to one side, which is legible at this size where a colour change is not.
        local r  = bw * 0.34
        local cx = locked and (bx + bw * 0.5) or (bx + bw * 0.72)
        local cy = by - (locked and 1 or 3)
        dl:PathClear()
        dl:PathArcTo(ImVec2(cx, cy), r, math.pi, math.pi * 2, 12)
        dl:PathStroke(col, 0, math.max(1.5, d * 0.11))
    end)
    if not ok then
        -- No draw list, no arcs: fall back to something that is at least a button.
        pressed = ImGui.SmallButton((locked and '[L]' or '[ ]') .. id)
    end
    return pressed
end

function ui_dot(rgb, scale)
    local ok = pcall(function()
        local fs = ImGui.GetFontSize()
        local r  = math.max(3, math.floor(fs * (scale or 0.28)))
        local cx, cy = ImGui.GetCursorScreenPos()
        ImGui.GetWindowDrawList():AddCircleFilled(
            ImVec2(cx + r + 2, cy + math.floor(fs * 0.5) + 1), r,
            IM_COL32(rgb[1], rgb[2], rgb[3], 255), 0)
        ImGui.Dummy(r * 2 + 6, 1)
        ImGui.SameLine(0, 0)
    end)
    if not ok then ImGui.Text(' ') ; ImGui.SameLine(0, 4) end
end

-- The separator takes the section's own hue too, so the rule and the title read as one band rather
-- than a grey line with something colourful after it.
function ui_section_head(key, label)
    local c = UI_SECTION[key]
    local sep = c and c.dot or { 90, 95, 110 }
    local okS = pcall(function()
        ImGui.PushStyleColor(ImGuiCol.Separator, IM_COL32(sep[1], sep[2], sep[3], 90))
        ImGui.Separator()
        ImGui.PopStyleColor(1)
    end)
    if not okS then ImGui.Separator() end
    if c then ui_dot(c.dot) end
    ui_text(c and c.label or UI_HEAD, label)
end

-- A PILL, NOT A WORD.
-- ===== SMALL UI HELPERS (1.20.43) =====
-- TOOLTIP HOVER: ImGui's tooltip test - waits for the mouse to rest a moment, so a tooltip does not
-- flash up as the pointer passes over a row of buttons. Plain IsItemHovered on a build without it.
UI_TIP_FLAG = nil
function ui_tip_hover()
    if UI_TIP_FLAG == nil then
        UI_TIP_FLAG = false
        local f = ImGuiHoveredFlags and (ImGuiHoveredFlags.ForTooltip or ImGuiHoveredFlags.DelayShort)
        if f then
            local ok = pcall(function() return ImGui.IsItemHovered(f) end)
            if ok then UI_TIP_FLAG = f end
        end
    end
    if UI_TIP_FLAG then return ImGui.IsItemHovered(UI_TIP_FLAG) end
    return ImGui.IsItemHovered and ImGui.IsItemHovered() or false
end
-- SECTION HEADING drawn into its divider line, in the label colour; the old rule-and-label otherwise.
UI_SEPTEXT_OK = nil
function ui_heading(text)
    if UI_SEPTEXT_OK ~= false and ImGui.SeparatorText then
        ImGui.Spacing()
        local pushed = pcall(function() ui_push_text(UI_LABEL) end)
        local ok = pcall(function() ImGui.SeparatorText(text) end)
        if pushed then pcall(function() ImGui.PopStyleColor(1) end) end
        if ok then UI_SEPTEXT_OK = true; ImGui.Spacing(); return end
        UI_SEPTEXT_OK = false
    end
    ImGui.Spacing(); ImGui.Separator(); ImGui.Spacing()
    ui_text(UI_LABEL, text)
end
-- A small (?) after the item before it, carrying the long explanation.
function ui_help(text)
    ImGui.SameLine()
    ImGui.TextDisabled('(?)')
    if ui_tip_hover() then pcall(function() ImGui.SetTooltip(text) end) end
end
-- GREYED OUT while it cannot act. Returns whether it pushed, for ui_enable.
function ui_disable_if(cond)
    if not cond or not ImGui.BeginDisabled then return false end
    return (pcall(function() ImGui.BeginDisabled(true) end))
end
function ui_enable(pushed)
    if pushed then pcall(function() ImGui.EndDisabled() end) end
end

-- A PILL THAT DRAINS: same footprint as ui_pill, filled to frac (0-1), text on top.
function ui_drain_bar(text, frac, rgb, w)
    local ok = pcall(function()
        local fs = ImGui.GetFontSize()
        local pw = math.max(w or (UI_BTN_W or 62), ui_fit_w(text, 0))
        local ph = fs + 4
        local cx, cy = ImGui.GetCursorScreenPos()
        local dl = ImGui.GetWindowDrawList()
        frac = math.max(0, math.min(1, frac or 0))
        dl:AddRectFilled(ImVec2(cx, cy), ImVec2(cx + pw, cy + ph), IM_COL32(rgb[1], rgb[2], rgb[3], 35), ph * 0.5)
        if frac > 0 then
            dl:AddRectFilled(ImVec2(cx, cy), ImVec2(cx + math.max(ph, pw * frac), cy + ph),
                             IM_COL32(rgb[1], rgb[2], rgb[3], 120), ph * 0.5)
        end
        dl:AddRect(ImVec2(cx, cy), ImVec2(cx + pw, cy + ph), IM_COL32(rgb[1], rgb[2], rgb[3], 170), ph * 0.5)
        ui_dl_text(dl, cx + math.max(4, (pw - ImGui.CalcTextSize(text)) * 0.5), cy + 2, { 235, 245, 255 }, text)
        ImGui.SetCursorScreenPos(cx, cy)
        ImGui.Dummy(pw, ph)
    end)
    if not ok then ImGui.Text(text) end
end
function ui_pill(text, rgb, w)
    local ok = pcall(function()
        local fs = ImGui.GetFontSize()
        local pw = math.max(w or (UI_BTN_W or 62), ui_fit_w(text, 0))
        local ph = fs + 4
        local cx, cy = ImGui.GetCursorScreenPos()
        local dl = ImGui.GetWindowDrawList()
        dl:AddRectFilled(ImVec2(cx, cy), ImVec2(cx + pw, cy + ph),
                         IM_COL32(rgb[1], rgb[2], rgb[3], 55), ph * 0.5)
        dl:AddRect(ImVec2(cx, cy), ImVec2(cx + pw, cy + ph),
                   IM_COL32(rgb[1], rgb[2], rgb[3], 160), ph * 0.5)
        ui_dl_text(dl, cx + math.max(4, (pw - ImGui.CalcTextSize(text)) * 0.5), cy + 2, rgb, text)
        ImGui.SetCursorScreenPos(cx, cy)
        ImGui.Dummy(pw, ph)
    end)
    if not ok then ImGui.Text(text) end
end

UI_READY  = { 0.40, 0.82, 0.45 }   -- up, usable, go
UI_WAIT   = { 0.95, 0.62, 0.25 }   -- on cooldown, counting down
UI_LABEL  = { 0.85, 0.72, 0.35 }   -- row labels down the left
UI_OFF    = { 0.55, 0.55, 0.55 }   -- not applicable, no report, unusable
UI_HEAD   = { 0.52, 0.64, 0.80 }   -- section titles

function ui_text(c, fmt, ...)
    ImGui.TextColored(c[1], c[2], c[3], 1.0, (select('#', ...) > 0) and string.format(fmt, ...) or fmt)
end

function ui_push_text(c)
    ImGui.PushStyleColor(ImGuiCol.Text, c[1], c[2], c[3], 1.0)
end

-- A NAME BUTTON OF A FIXED WIDTH.
UI_BTN_W      = 62
uiWideButtons = true

function ui_name_button(label, id, colour)
    local pushed = 0
    if colour then
        local ok = pcall(function() ui_push_text(colour) end)
        if ok then pushed = 1 end
    end
    local clicked
    if uiWideButtons then
        local padded = pcall(function() ImGui.PushStyleVar(ImGuiStyleVar.FramePadding, 3, 1) end)
        -- A FLOOR, NOT A CEILING. A fixed width lines the rows up, but only until a label is wider than
        -- it - at which point it silently clips, which is worse than a ragged edge.
        clicked = ImGui.Button(label .. '##' .. id, ui_fit_w(label, UI_BTN_W), 0)
        if padded then pcall(function() ImGui.PopStyleVar(1) end) end
    else
        clicked = ImGui.SmallButton(label .. '##' .. id)
    end
    if pushed > 0 then pcall(function() ImGui.PopStyleColor(pushed) end) end
    return clicked
end

-- Until when we will accept an incoming trade.
expectTradeUntil = 0

-- File logging: mirror every line to AdventureTime_<name>_log.txt (fresh each run, flushed per line) so
-- a run can be reconstructed from the file - same as the crafter/listener.
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
    -- LOGS LIVE IN Logs\.
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
    AT_LOG_FILE_PATH = LOG_FILE_PATH   -- for the run's error catch at the top of the file (1.21.1)
    -- The old crash breadcrumb file is gone; clear any copy left from earlier builds.
    pcall(os.remove, (dir or '') .. 'AdventureTime_' .. who .. '_lastphase.txt')
    -- KEEP THE PREVIOUS RUNS.
    local KEEP_SESSIONS = 8
    local prior = ''
    local rf = io.open(LOG_FILE_PATH, 'r')
    if rf then
        local content = rf:read('*a') or ''
        rf:close()
        -- A PATTERN, NOT A FIXED STRING, and this is why KEEP_SESSIONS has been keeping zero.
        local marker = '=== AdventureTime[^\n]-%s+log%s+%('
        local sessions, idx = {}, 1
        while true do
            local st, en = content:find(marker, idx)
            if not st then break end
            local nxt = content:find(marker, en + 1)
            sessions[#sessions + 1] = content:sub(st, (nxt and nxt - 1) or #content)
            if not nxt then break end
            idx = nxt
        end
        -- #sessions - KEEP + 1 is the index of the FIRST of the last KEEP.
        local first = math.max(1, #sessions - KEEP_SESSIONS + 1)
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
-- WHICH PHASE ATE THE TICK.
AT_SLOW_MS   = 700      -- a phase slower than this is worth a line
AT_slowSaid  = 0
-- WHAT IS THIS COSTING THE CLIENT?
AT_CPU = { phase = {}, busy = 0, idle = 0, since = 0, ticks = 0 }

-- THE PROFILER CAN BE SWITCHED OFF.
if atProfile == nil then atProfile = false end
AT_TICKS = 0
-- ITS OWN CLOCK.
AT_TICKS_AT = 0
-- A SEPARATE ROLLING COUNTER FOR THE PANEL.
AT_DISP_TICKS, AT_DISP_AT, AT_DISP_RATE, AT_DISP_WORK = 0, 0, 0, 0
-- SAMPLED PROFILING.
AT_SLOW_TICK_MS = 400
AT_SLOW_SUM = { n = 0, at = 0, worst = 0, worstPhase = '?', worstPhaseMs = 0, by = {} }
-- PHASES THAT BLOCK ON PURPOSE, and roughly what they cost when behaving.
AT_HEAVY    = {}
AT_HEAVY_MS = {}
AT_HEAVY_N  = 0
AT_SLOW_EXPECTED = {
    invis_combo = 8000,   -- lead 3500 + cast wait <=3000 + hold 2500, measured at 6042-6284ms
    invis_arm   = 8000,   -- the same schedule, reached from the worker side
    invis_prep  = 3000,   -- pause confirm plus two 400ms settles
}
-- FAST LANE VISIBILITY.
AT_LANE_ON, AT_LANE_AT, AT_LANE_TICKS = false, 0, 0
-- When the rez tick last found nothing worth doing; 0 means it has work right now.
rezIdleAt      = 0
-- How long the lane stays up after the rez tick goes quiet.
REZ_LANE_IDLE  = 5000
-- WHAT THE LOOP ACTUALLY ASKED TO WAIT, averaged, rather than what pace(250) says it should have.
AT_DISP_WANT_SUM, AT_DISP_WANT = 0, 0
AT_SLOW_TICK_AT = 0
-- ARMED TRACING.

-- AND THE ACTUAL LENGTH OF THE WAIT.
AT_DISP_WAIT_SUM, AT_DISP_WAIT = 0, 0

-- GAME FRAMES A PASS SPANS. MacroQuest runs a Lua script for turboNum instructions (default 500) and
-- then parks it until the next frame, so a pass that needs N instructions takes ~N/turbo frames of wall
-- time whatever the CPU cost. Counted off the window's frame counter (driver only).
AT_DISP_FR_SUM, AT_DISP_FR, AT_DISP_FR_N, AT_TURBO = 0, -1, 0, -1
AT_TURBO_FAST = 2000
-- LATE JOINERS. Each worker reports its turbo on change (checked every 30s); a driver in Fast mode
-- raises anyone who reports lower.
turboLast, turboCheckAt, turboState = nil, 0, {}
-- IS THIS MACHINE STRUGGLING? Driver only: frame rate off the window, AT's share of each second.
-- Low spec is suggested after 12 straight 5s windows (a minute) under 30 fps with AT over 10%.
AT_DISP_FPS, AT_DISP_SHARE, AT_DISP_F_AT, AT_LOWSPEC_STREAK = -1, -1, 0, 0
AT_LOWSPEC_FPS, AT_LOWSPEC_SHARE, AT_LOWSPEC_WINDOWS = 30, 10, 12
function at_turbo()
    local ok, v = pcall(function() return mq.TLO.Lua.Turbo() end)
    return (ok and tonumber(v)) or -1
end
-- PHASE CLOCK. mq.gettime() steps in ~15.6ms, so phase times read 0 or 16; os.clock reads finer.
AT_CLOCK = (type(os.clock) == 'function') and os.clock or function() return mq.gettime() / 1000 end
-- ~40 CALLS A PASS, so it is kept to the fewest Lua steps: under MacroQuest's turbo limit every step
-- is pass length. The profiler half lives in its own function and costs one check while off.
AT_tickWorstMs = 0
function atphase_profile(nowT)
    local cur, at = AT_phaseName, AT_phaseAt
    if cur and at then
        local took = nowT - at
        AT_CPU.phase[cur] = (AT_CPU.phase[cur] or 0) + took
        if cur ~= 'idle' and took >= AT_SLOW_MS and (mq.gettime() - AT_slowSaid) > 3000 then
            AT_slowSaid = mq.gettime()
            AT_slowPending = string.format('%s held the loop for %dms - everything else waited',
                                           cur, math.floor(took))
        end
    end
    AT_phaseAt = nowT
end
function atphase(name)
    local nowT = AT_CLOCK() * 1000
    local st = AT_phaseStart
    if st then
        local took = nowT - st
        if took > AT_tickWorstMs then AT_tickWorstMs, AT_tickWorst = took, AT_phaseName end
    end
    if atProfile then atphase_profile(nowT) end
    AT_phaseName, AT_phaseStart = name, nowT
end

-- Both clocks, sampled together, so elapsed milliseconds can be turned back into a wall time.
do
    local spinFrom = mq.gettime()
    local t0 = os.time()
    local t  = t0
    -- Bounded, because a clock that never advances must not hang the load. If it gives up, the timestamps
    -- are no worse than they were before this existed.
    while t == t0 and (mq.gettime() - spinFrom) < 1200 do
        -- Yield rather than burn a core: six clients each spinning up to a second is real CPU on the box
        -- this is meant to be gentle on. Falls back to a plain spin if delay is unavailable this early.
        pcall(function() mq.delay(5) end)
        t = os.time()
    end
    LOG_T0_WALL = t
    LOG_T0_MS   = mq.gettime()
    LOG_T0_SPUN = (t ~= t0)
end

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
function log(fmt, ...)   -- global (1.22.0): modules use it
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
function rezlog(fmt, ...)   -- file-only (keeps the [rez] chatter out of the MQ window)
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

-- ===== DIAMOND COIN HAND-OFF =====
-- Every character claims its own coins into inventory and hands them to one named character, so the
-- balance ends up in one place instead of six.
-- THE RECEIVER ARBITRATES, not the driver. It is the actual bottleneck - one trade window - it knows
-- when it is free, and it keeps working through a driver restart. A driver-held token would be a second
-- source of truth about a queue the receiver already owns.
-- Blank name = off. Nothing here runs unless somebody has been named.
dcGiveTo      = ''      -- who receives; set in Settings > Pots
DC_ITEM       = 'Diamond Coin'
-- Stop claiming with this many inventory slots left. Two rather than one: a claim can land a partial
-- stack in a fresh slot, and running to literally zero leaves nothing free for the trade itself.
DC_MIN_FREE   = 2
-- A FULL STACK PER PRESS. Was 100 for no better reason than it being a round number, which meant two
-- presses, two window round-trips and two log lines for every stack that could have moved in one.
DC_PULL_EACH  = 200
-- The receiver empties its own bags back into currency below this many free slots, so it can keep
-- accepting. Higher than the giver's threshold: a trade arrives as several stacks at once, and a
-- receiver that waits until it is as full as a giver has nowhere to put the last one.
DC_RECV_FREE  = 6
DC_RECLAIM_GAP = 5000   -- least time between reclaim attempts, so a failing one cannot spin
dcReclaimAt   = 0
DC_TURN_MS    = 120000  -- a granted turn expires after this, so one stuck giver cannot jam the queue
DC_RETRY_MS   = 30000   -- how long a giver waits before asking again
dcTurnHolder  = nil     -- receiver: who currently has the trade window
dcTurnAt      = 0       -- receiver: when that turn was granted
dcQueue       = {}      -- receiver: who is waiting
dcAskedAt     = 0       -- giver: when we last asked for a turn
dcHaveTurn    = false   -- giver: we have been told to come
dcSaidFull    = false   -- giver: so 'inventory full' is said once, not every tick
dcGiveNowWant = false   -- set by the button; consumed on the tick, never acted on in a draw
-- A RUN, NOT A MODE. Naming somebody in the box used to be enough to start claiming - so the first thing
-- that happened after typing a name was six characters emptying their currency tabs unasked. The name is
-- now only a destination; nothing moves until the button says so, and the run ends by itself.
dcRunning     = false   -- giver: a claim-and-hand-over run is in progress
dcRunSaid     = false
dcHeldWindow  = false   -- we are holding the inventory open for the duration of a run

function dc_free_slots()
    local n = 0
    pcall(function() n = tonumber(mq.TLO.Me.FreeInventory()) or 0 end)
    return n
end

function dc_my_coins()
    local n = 0
    pcall(function() n = tonumber(mq.TLO.FindItemCount('=' .. DC_ITEM)()) or 0 end)
    return n
end

-- Am I the receiver? Compared case-insensitively, because a name typed into a settings box will not
-- match Me.Name exactly, and silently doing nothing is the worst possible failure here.
-- READS THE NAME ITSELF rather than using myName. myName is a LOCAL declared at ~1721, and this function
-- sits above it - so the myName in here was never that local, it was a nil global, and the first call
-- indexed nil and took the script down at startup. 2026-08-27.
-- One TLO read on a function that is called a few times a second at most.
function dc_i_am_receiver()
    if (dcGiveTo or '') == '' then return false end
    -- Read once: this sits above the myName local, and a character's name does not change.
    if (DC_ME or '') == '' then pcall(function() DC_ME = tostring(mq.TLO.Me.Name() or '') end) end
    local me = DC_ME or ''
    return me ~= '' and dcGiveTo:lower() == me:lower()
end

function dc_active()
    return dcGiveTo ~= '' and not dc_i_am_receiver()
end

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
    -- buffs: what each draught actually lands, looked up by name - one read each, no searching.
    -- find: a name fragment for FindBuff, only used if none of the listed names is found.
    { key = 'shimmer',   base = 'Draught of Shimmering Reflection', label = 'Grp Shimmering',
      buffs = { 'Shimmering Reflection II', 'Shimmering Reflection I' }, find = 'Shimmering Reflection' },
    { key = 'fortitude', base = 'Draught of Fleeting Fortitude',    label = 'Grp Fleeting',
      buffs = { 'Fleeting Fortitude II', 'Fleeting Fortitude I' }, find = 'Fleeting Fortitude' },
    -- Inferno Ward moved here from the INIs. As a burn line it fired on every 15 and 30 minute burn
    -- whether or not the fight warranted it; as a button it is spent when someone decides to spend it.
    -- Same shape as the two above, so it gets the tier picking, the per-toon inventory read and the
    -- carries/up/timer display for free.
    { key = 'inferno',   base = 'Draught of Inferno Ward',        label = 'Grp Inferno',
      buffs = { 'Inferno Ward II', 'Inferno Ward I' }, find = 'Inferno Ward' },
}
function pot_base_for(key)
    for _, p in ipairs(GROUP_POTS) do if p.key == key then return p.base, p.label end end
    return nil
end
-- driver: potState[char][key] = { carries, up, secs, dsecs, updated }. Worker: last-pushed key per pot.
potState = {}
-- Buffs are handed out on the server's own tick, so a draught read four times between two of them
-- returns the same answer three times over. The click poll runs at 2s because MGB and cures want that;
-- draughts do not, and they were the ones doing the reading.
POT_POLL_MS = 6000
lastPotPoll = 0

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
-- THE REZ CAST WAS THE ONLY CLICKY IN THIS FILE WITHOUT THIS, and it cost real time. On 2026-08-21
-- Nityrc fired the token on Lunafeet at 15:01:08.175, E3 interrupted for healing four times over the
-- next twelve seconds, the cast never completed, and Khulian took the baton at 15:01:22.9 - sixteen
-- seconds, plus a crown charge spent on a rez that was no longer needed. A cleric healing through a
-- wipe interrupting her own rez is the normal case, not the unlucky one.
-- Appended INSIDE the quotes, which is where every other call site puts it; the trailing corpse id is
-- untouched from the form that was already casting successfully.
-- BLANK THIS STRING to go back to the old behaviour if E3 turns out not to accept options and a target
-- id together - that failure would look like the cast never being issued at all.
-- WHICH KIND IS IT? Three answers, not two.
-- The MGB chain mixes items and AAs - Tome of Nife's Mercy is an item, Ancestral Aid is an AA - and the
-- old test asked only 'is it an item', leaving everything else with NO CastType at all. E3's fallback for
-- an untyped name is to treat it as a SPELL, which means memorising it into a gem: reported 2026-08-22 as
-- spells being unmemmed during MGB, and that is exactly what it looks like from the character's side.
-- Ownership rule copied from ability_state deliberately: rank OR ready, never the timer, because on this
-- build AltAbilityTimer returns 1 for an AA the character does NOT own and testing it marks everyone an
-- owner.
-- An empty return is still right for a genuine spell - those SHOULD be memorised.
function cast_opts(name)
    local isItem = false
    pcall(function() isItem = (tonumber(mq.TLO.FindItem('=' .. name).ID()) or 0) > 0 end)
    if isItem then return '/CastType|Item' end
    local rank, rdy = 0, false
    pcall(function() rank = tonumber(mq.TLO.Me.AltAbility(name).Rank()) or 0 end)
    pcall(function() rdy  = tlo_true(mq.TLO.Me.AltAbilityReady(name)()) end)
    if rank > 0 or rdy then return '/CastType|Alt' end
    return ''
end

-- PER KIND, because the rez order is not four clickies. Crown and Token are items; Call of the Wild and
-- Divine Resurrection are AAs, and E3 spells that Alt - see the DI casts, which have been sending
-- 'Divine Guardian/CastType|Alt/...' correctly the whole time.
-- One blanket /CastType|Item went in on 2026-08-21 and broke both AAs. It cost a real rez on 2026-08-22:
-- Divine Resurrection fired on Sebbun at 13:48:52, retried twice, and gave up with 'did not land - passing
-- to the next slot'. Twice in a row. The clickies were unaffected, which is why it read as a rez system
-- that mostly worked.
REZ_OPTS_ITEM = '/CastType|Item/NoInterrupt'
REZ_OPTS_ALT  = '/CastType|Alt/NoInterrupt'
-- DERIVED FIRST, DECLARED ONLY AS A FALLBACK.
-- The kind map below is the same shape as the mapping that broke: a hand-written list of which sources
-- are AAs, kept in a different place from the sources themselves. When those two drift, nothing notices
-- until a rez does not land - which is what happened on 2026-08-22 after one blanket /CastType|Item went
-- in and Divine Resurrection retried twice and gave up.
-- cast_opts asks the client what the thing actually IS, so a source changing type, or a fifth being
-- added, corrects itself. The map is kept underneath for the one case cast_opts cannot answer: a
-- character that does not own the AA reads as neither item nor AA, and an untyped rez would be worse
-- than a guess from the kind.
function rez_opts(kind, item)
    if item and item ~= '' then
        local o = cast_opts(item)
        if o ~= '' then return o .. '/NoInterrupt' end
    end
    return (kind == 'cotw' or kind == 'divine') and REZ_OPTS_ALT or REZ_OPTS_ITEM
end

-- ===========================================================================
--  CAST ADAPTER. Every cast this file issues goes through at_cast / at_queuecast.
-- ===========================================================================
-- Under E3 the spec is handed to /nowcast exactly as before - nothing on that path changed. Under
-- RGMercs there is no equivalent: RGMercs has no "cast this now on that target" command (/rgl useitem
-- exists but only QUEUES into its main loop, which is paused whenever AT is doing anything). So the
-- native backend does what E3 would have done, by hand, with plain client commands:
--     item  -> /useitem "Name"          AA -> /alt activate <id>        spell -> /cast <gem>
-- after targeting whatever the spec asked for. The spec grammar is E3's own, so the call sites did not
-- have to learn a second one:
--     Name[/CastType|Item|Alt|AA][/NoInterrupt][/BeforeSpell|Other][/TargetName]   [targetId]
-- A bare segment that is not a known key is a target NAME (that is how DI.OPTS passes the tank).
-- AT_CAST_BACKEND is set by rg.lua; otherwise the backend follows the Bot control setting.
AT_CAST_BACKEND = AT_CAST_BACKEND or nil
function cast_backend()
    if AT_CAST_BACKEND == 'native' or AT_CAST_BACKEND == 'e3' then return AT_CAST_BACKEND end
    -- LOAD ORDER. The burn list is parsed at load, thousands of lines before active_bot_control exists,
    -- so calling it here errored. Before it is defined, nothing but rg.lua could have chosen native.
    if type(active_bot_control) ~= 'function' then return 'e3' end
    return (active_bot_control() == 'rgmercs') and 'native' or 'e3'
end

function cast_parse(spec)
    local r = { name = '', kind = nil, nointerrupt = false, before = nil, tname = nil }
    local first = true
    for seg in tostring(spec or ''):gmatch('[^/]+') do
        if first then r.name = seg; first = false
        else
            local k, v = seg:match('^([^|]+)|(.*)$')
            k = (k or seg):lower()
            if k == 'casttype' then
                v = (v or ''):lower()
                r.kind = (v == 'item') and 'item' or ((v == 'alt' or v == 'aa') and 'alt' or 'spell')
            elseif k == 'nointerrupt' then r.nointerrupt = true
            elseif k == 'beforespell' then r.before = v
            elseif k == 'afterspell' or k == 'gem' or k == 'ifs' or k == 'checkfor' then -- E3-only, ignored natively
            else r.tname = seg end
        end
    end
    return r
end

-- What the thing IS, when the spec did not say. Same reads as cast_opts.
function cast_kind_of(name)
    local o = cast_opts(name)
    if o == '/CastType|Item' then return 'item' end
    if o == '/CastType|Alt'  then return 'alt' end
    return 'spell'
end

-- Find the gem holding a spell, memorising it into the last gem if it is in the book but not memmed -
-- which is what E3 does for an untyped spec. Returns gem number or 0.
function cast_gem_for(name)
    local found = 0
    pcall(function()
        for g = 1, 12 do
            if tostring(mq.TLO.Me.Gem(g)() or '') == name then found = g; break end
        end
    end)
    if found > 0 then return found end
    local inBook = false
    pcall(function() inBook = tlo_true(mq.TLO.Me.Book(name)()) end)
    if not inBook then return 0 end
    local gem = 12
    pcall(function() gem = math.min(12, tonumber(mq.TLO.Me.NumGems()) or 12) end)
    rezlog('[cast] %s is not memorised - memming it into gem %d', name, gem)
    pcall(function() mq.cmdf('/memspell %d "%s"', gem, name) end)
    mq.delay(10000, function() return tostring(mq.TLO.Me.Gem(gem)() or '') == name end)
    local now = ''
    pcall(function() now = tostring(mq.TLO.Me.Gem(gem)() or '') end)
    if now ~= name then return 0 end
    -- a freshly memmed gem is not castable for a moment
    mq.delay(3000, function() return tlo_true(mq.TLO.Me.SpellReady(gem)()) end)
    return gem
end

function cast_native(p, tid)   -- global on purpose: the main chunk is at Lua's 200-local ceiling
    tid = tonumber(tid) or 0
    -- TARGET FIRST. E3 did this for us; the client will not.
    if tid > 0 then
        if (tonumber(mq.TLO.Target.ID()) or 0) ~= tid then
            pcall(function() mq.cmdf('/target id %d', tid) end)
            mq.delay(600, function() return (tonumber(mq.TLO.Target.ID()) or 0) == tid end)
        end
    elseif p.tname and p.tname ~= '' then
        local want = p.tname:lower()
        local cur = ''
        pcall(function() cur = tostring(mq.TLO.Target.CleanName() or ''):lower() end)
        if cur ~= want then
            pcall(function() mq.cmdf('/target "%s"', p.tname) end)
            mq.delay(600, function()
                return tostring(mq.TLO.Target.CleanName() or ''):lower() == want
            end)
        end
    end
    -- NOT OVER A CAST IN FLIGHT. E3 queued behind one; the client just drops the command.
    local casting = 0
    pcall(function() casting = tonumber(mq.TLO.Me.Casting.ID()) or 0 end)
    if casting > 0 then
        mq.delay(4000, function() return (tonumber(mq.TLO.Me.Casting.ID()) or 0) == 0 end)
    end
    -- MGB rides the next cast: fire the AA first, then the ability.
    if p.before and p.before ~= '' then
        local bid = 0
        pcall(function() bid = tonumber(mq.TLO.Me.AltAbility(p.before).ID()) or 0 end)
        if bid > 0 then
            pcall(function() mq.cmdf('/alt activate %d', bid) end)
            mq.delay(1500, function() return tlo_true(mq.TLO.Me.Buff(p.before)()) end)
        else
            rezlog('\\ay[cast] cannot resolve AA "%s" for BeforeSpell - casting without it\\ax', p.before)
        end
    end
    local kind = p.kind or cast_kind_of(p.name)
    local cmd
    if kind == 'item' then
        cmd = string.format('/useitem "%s"', p.name)
    elseif kind == 'alt' then
        local aid = 0
        pcall(function() aid = tonumber(mq.TLO.Me.AltAbility(p.name).ID()) or 0 end)
        if aid == 0 then
            -- /alt activate takes an ID only; a name would be silently ignored, and a cast the log says
            -- went out but never did is the failure this whole file is written to avoid.
            rezlog('\\ar[cast] cannot resolve AA "%s" on this character - nothing sent\\ax', p.name)
            return nil
        end
        cmd = string.format('/alt activate %d', aid)
    else
        local gem = cast_gem_for(p.name)
        if gem == 0 then
            rezlog('\\ar[cast] %s is not memorised and not in the book - nothing sent\\ax', p.name)
            return nil
        end
        cmd = string.format('/cast %d', gem)
    end
    pcall(function() mq.cmd(cmd) end)
    return cmd
end

-- Returns the command string actually issued (for the log lines that print it), or nil.
function at_cast(spec, tid)
    tid = tonumber(tid) or 0
    if cast_backend() == 'e3' then
        local cmd = (tid > 0) and string.format('/nowcast me "%s" %d', spec, tid)
                              or string.format('/nowcast me "%s"', spec)
        pcall(function() mq.cmd(cmd) end)
        return cmd
    end
    return cast_native(cast_parse(spec), tid)
end

-- /queuecast has no native equivalent: at_cast already waited out any cast in flight, so the retry
-- the queue was buying is not needed. Sent only under E3.
function at_queuecast(spec, tid)
    if cast_backend() ~= 'e3' then return nil end
    tid = tonumber(tid) or 0
    local cmd = (tid > 0) and string.format('/queuecast me "%s" %d', spec, tid)
                          or string.format('/queuecast me "%s"', spec)
    pcall(function() mq.cmd(cmd) end)
    return cmd
end

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
-- COUNT IT DOWN HERE. The push is gated to the minute now, so the number that arrives is up to a minute
-- old - and displaying it raw would make the timer jump in minute steps instead of ticking.
-- The sender's seconds plus the age of the message is the real remaining time, which is the same trick
-- burn_remain and the draught panel already use. Smooth display, one message a minute.
function nv_peer_secs(nm, i)
    local st = nvState[nm]
    if not st or not st.items then return nil end
    local v = st.items[i]
    if v == nil then return nil end
    if v <= 0 then return v end
    local age = math.floor((mq.gettime() - (st.updated or 0)) / 1000)
    return math.max(0, v - age)
end

-- HOW LONG MY EMBLEM'S EFFECT HAS LEFT, in seconds (0 = not running). The effect is the item's click
-- spell, looked up once per emblem. Only asked while the emblem is cooling - it cannot be running
-- otherwise - so a ready emblem costs nothing.
nvBuffName = {}
function nv_effect_secs(i)
    local e = NV_SPLIT[i]
    if not e then return 0 end
    local nm = nvBuffName[i]
    if nm == nil then
        nm = false
        pcall(function()
            local v = tostring(mq.TLO.FindItem('=' .. e.item).Clicky.Spell.Name() or '')
            if v ~= '' and v ~= 'NULL' then nm = v end
        end)
        nvBuffName[i] = nm
    end
    if not nm then return 0 end
    local secs = 0
    pcall(function() secs = tonumber(mq.TLO.Me.Buff(nm).Duration.TotalSeconds()) or 0 end)
    if secs <= 0 then pcall(function() secs = tonumber(mq.TLO.Me.Song(nm).Duration.TotalSeconds()) or 0 end) end
    return math.max(0, math.floor(secs))
end
function nv_secs_at(i)
    local e = NV_SPLIT[i]
    if not e then return -1 end
    local v = nil
    pcall(function() v = mq.TLO.FindItem('=' .. e.item).TimerReady() end)
    if v == nil then return -1 end
    return timer_secs(v)
end

-- The soonest-ready of everything I hold, for anything that just wants one number.


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
    at_cast(potPending.nm .. '/CastType|Item')
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
                -- /CastType|Item because it IS one - FindItemCount above just proved it. Untyped, E3
                -- hunts for a spell of that name, and the fallback for a name it cannot place is to try
                -- to memorise it.
                at_cast(nm .. '/CastType|Item')
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
-- Peer network: prefer DanNet (/dex), then E3 (/e3bct), then EQBC (/bct). Detected once, in peer_detect.
-- ---------------------------------------------------------------------------
local peerChan
peerTransport = peerTransport or 'auto'  -- auto, e3, eqbc, dannet. Saved in Settings.
PEER_TRANSPORT_LABEL = { auto = 'Auto', e3 = 'E3', eqbc = 'EQBC', dannet = 'DanNet' }
peerTransportProbeAt = peerTransportProbeAt or 0
peerTransportTestAt = peerTransportTestAt or 0
botControl = botControl or 'auto'  -- auto, e3, rgmercs. Saved in Settings.
BOT_CONTROL_LABEL = { auto = 'Auto', e3 = 'E3', rgmercs = 'RGMercs' }
-- HOW MUCH ARE WE ACTUALLY SAYING? Every feature added tonight was argued about on the basis of what I
-- thought the traffic looked like, which is exactly the kind of claim that should be a number instead.
-- Counted at the two places anything leaves this client, so nothing can be added later that skips it.
NET = { sent = 0, since = 0, byCmd = {} }
-- DECLARED HERE, NOT IN THE BIND. benchState made exactly this mistake earlier today: created inside the
-- command handler, so a reply arriving before the command had ever been run indexed a nil table and the
-- bind died silently inside its own pcall. Five peers answered and none were recorded.
netPeers = {}
-- /atgrab state. Off unless armed, and it disarms itself on a clock rather than needing a second
-- command - an always-on catch-all event is exactly the sort of thing that gets left running.
atGrabUntil = 0
-- REGISTERED ONLY WHILE /atgrab RUNS. A '#1#' event matches EVERY chat line, and left registered all
-- the time it ran a Lua callback for each one - the bulk of doevents' cost - to do nothing.
atGrabOn = false
function at_grab_line(line)
    if not atGrabUntil or mq.gettime() > atGrabUntil then return end
    local t = tostring(line or '')
    if t == '' then return end
    atGrabN = (atGrabN or 0) + 1
    if atGrabN <= AT_GRAB_MAX then rezlog('[grab] %s', t) end
end
function at_grab_tick()
    if atGrabOn and mq.gettime() > atGrabUntil then
        atGrabOn = false
        pcall(function() mq.unevent('at_grab_all') end)
    end
end
atGrabN     = 0
AT_GRAB_MAX = 400

-- INBOUND, THE HALF WE NEVER MEASURED.
-- net_count below counts what this client SENDS. On the driver that is almost nothing - and the driver
-- is the client that struggles. The cost of a message is not paid by the sender: it is paid by whoever
-- receives it, because every arriving message fires a Lua bind and every bind runs inside ONE
-- mq.doevents() call, in one tick. Five workers sending twenty messages each is a hundred callbacks
-- landing on the client that is also drawing the UI.
-- That is why cutting the change-keys helped at all. It was never the wire; it was a hundred Lua
-- callbacks arriving together.
NETIN = { got = 0, since = 0, byCmd = {}, tick = 0, worstTick = 0, worstAt = 0 }
function net_in(cmd)
    NETIN.got = NETIN.got + 1
    NETIN.tick = NETIN.tick + 1
    if NETIN.since == 0 then NETIN.since = mq.gettime() end
    NETIN.byCmd[cmd] = (NETIN.byCmd[cmd] or 0) + 1
end

function net_count(fmt)
    NET.sent = NET.sent + 1
    if NET.since == 0 then NET.since = mq.gettime() end
    -- Bucket by the command word, so the report says WHAT is talking rather than just how much.
    local c = tostring(fmt or ''):match('^(/%S+)') or '?'
    NET.byCmd[c] = (NET.byCmd[c] or 0) + 1
end

-- Is EQBC actually connected (not merely loaded)? Loaded-but-disconnected is a normal transient state
-- while the plugin reconnects, and the detection below must not treat it as 'no EQBC'.
function eqbc_connected()
    local ok = false
    pcall(function() ok = mq.TLO.EQBC.Connected() == true end)
    return ok
end

function peer_transport_valid(v)
    return v == 'auto' or v == 'e3' or v == 'eqbc' or v == 'dannet'
end

function peer_transport_label(v)
    return PEER_TRANSPORT_LABEL[v or 'auto'] or PEER_TRANSPORT_LABEL.auto
end

-- A selected transport that is missing must not re-run detection on EVERY relay: that was a red log line
-- per relay, and on the DanNet branch a /plugin load plus a 750ms delay per relay - a yield inside
-- doevents when the relay came from a bind. Say it once, then back off before trying again.
peerDetectSaid    = peerDetectSaid or false
peerDetectRetryAt = peerDetectRetryAt or 0
PEER_DETECT_BACKOFF_MS = 15000

function peer_transport_reset()
    peerChan = nil
    peerDetectSaid = false
    peerDetectRetryAt = 0
    if atMuted ~= nil then atMuted = false end
    peerTransportProbeAt = mq.gettime() + 1
end

-- The failure path of peer_detect: log the reason ONCE per reset, arm the backoff, leave peerChan nil.
function peer_detect_fail(msg)
    if not peerDetectSaid then
        peerDetectSaid = true
        log(msg)
    end
    peerDetectRetryAt = mq.gettime() + PEER_DETECT_BACKOFF_MS
    return nil
end

-- Pick the peer transport ONCE, in the advertised order: DanNet, then E3, then EQBC.
-- GLOBAL, not local: the main chunk is at Lua's 200-local ceiling.
-- DanNet first because it is what this script always ran on and what every downstream path is written
-- for (/dquery counts, DanNet.Peers roster, /dgge group-minus-self, echo muting). E3/EQBC are the
-- fallbacks for a client that has no DanNet, not the preference for one that has it - with the earlier
-- E3-first order every box in the group picked E3, because they all carry MQ2Mono for /nowcast and /e3p.
-- Nothing here loads a plugin unless no advertised transport is present at all, which keeps the legacy
-- behaviour for a Windows client that has none of them and lets everyone else run on what they have.
function peer_detect()
    if peerChan then return peerChan end
    if peerDetectRetryAt > 0 and mq.gettime() < peerDetectRetryAt then return nil end
    if not peer_transport_valid(peerTransport) then peerTransport = 'auto' end
    local mono  = mq.TLO.Plugin('MQ2Mono')() ~= nil
    local eqbc  = mq.TLO.Plugin('MQ2EQBC')() ~= nil
    local dnet  = mq.TLO.Plugin('MQ2DanNet')() ~= nil

    if peerTransport == 'e3' then
        if mono then
            peerChan = 'e3'
        else
            return peer_detect_fail('\\ar[sync] E3 peer transport selected, but MQ2Mono/E3 is not loaded - relays will not send\\ax')
        end
    elseif peerTransport == 'eqbc' then
        if eqbc then
            peerChan = 'eqbc'
            if not eqbc_connected() then
                log('\\ay[sync] EQBC peer transport selected, but MQ2EQBC is not connected - relays will drop until /bccmd connect succeeds\\ax')
            end
        else
            return peer_detect_fail('\\ar[sync] EQBC peer transport selected, but MQ2EQBC is not loaded - relays will not send\\ax')
        end
    elseif peerTransport == 'dannet' then
        if not dnet then
            pcall(function() mq.cmd('/plugin mq2dannet load') end)
            mq.delay(750)
            dnet = mq.TLO.Plugin('MQ2DanNet')() ~= nil
        end
        if dnet then
            peerChan = 'dannet'
        else
            return peer_detect_fail('\\ar[sync] DanNet peer transport selected, but MQ2DanNet would not load - relays will not send\\ax')
        end
    elseif dnet then
        -- Already loaded: use it. This is the normal case for every box in the group.
        peerChan = 'dannet'
    elseif mono then
        -- MQ2Mono loaded is not the same as E3 running - /e3bct only exists while it is. The pause probe
        -- resolves to true/false only when E3 answers (an unresolved key comes back as text, see
        -- e3_is_paused). Only demote E3 when there is a CONNECTED EQBC to fall back on; with nothing
        -- else usable, E3 keeps the benefit of the doubt exactly as before.
        local v
        pcall(function() v = mq.TLO.MQ2Mono.Query('e3', 'E3N.State.Basics.IsPaused')() end)
        local s = (v == nil) and '' or tostring(v):lower()
        if s == 'true' or s == 'false' or not (eqbc and eqbc_connected()) then
            peerChan = 'e3'
        else
            log('[sync] MQ2Mono is loaded but E3 is not answering - using the connected EQBC session instead')
            peerChan = 'eqbc'
        end
    elseif eqbc then
        -- Loaded is enough: a momentary reconnect must not push us on to loading DanNet. Say so when it
        -- is not connected yet, so a silent group has a line in the log explaining why.
        peerChan = 'eqbc'
        if not eqbc_connected() then
            log('\\ay[sync] MQ2EQBC is loaded but not connected - relays will drop until /bccmd connect succeeds\\ax')
        end
    else
        -- LAST RESORT, and the only place a plugin is loaded on auto: no DanNet, no E3, no EQBC. This is
        -- the legacy auto-load path and it is unchanged for the client that has nothing else.
        pcall(function() mq.cmd('/plugin mq2dannet load') end)
        mq.delay(750)
        if mq.TLO.Plugin('MQ2DanNet')() == nil then
            return peer_detect_fail('\\ar[sync] no peer transport found (DanNet, E3 or EQBC) and MQ2DanNet would not load - nothing will reach the group\\ax')
        end
        peerChan = 'dannet'
    end
    peerDetectSaid, peerDetectRetryAt = false, 0
    log('[sync] peer transport: %s%s', peerChan, peerTransport ~= 'auto' and (' (selected ' .. peer_transport_label(peerTransport) .. ')') or '')
    return peerChan
end

function peer_cmdf(char, fmt, ...)
    net_count(fmt)
    if not peerChan then peer_detect() end
    if not peerChan then return end
    local cmd = fmt:format(...)
    if peerChan == 'e3' then mq.cmdf('/e3bct %s %s', char, cmd)
    -- EQBC executes a tell only when the payload starts with '//' - a single '/' is delivered as chat
    -- text and printed on the far end, never run. cmd already starts with '/', so one more in front.
    elseif peerChan == 'eqbc' then mq.cmdf('/bct %s /%s', char, cmd)
    else mq.cmdf('/dex %s %s', char, cmd) end
end
function peer_bcast(fmt, ...)   -- broadcast to the whole in-game group in ONE relay (5x less window spam than looping /dex)
    net_count(fmt)
    if not peerChan then peer_detect() end
    if not peerChan then return end
    local cmd = fmt:format(...)
    if peerChan == 'e3' then mq.cmdf('/e3bcga %s', cmd)
    -- /bcg, not /bcga: /bcga includes the sender, /bcg is group-minus-self - the same set /dgge sends
    -- to, so a broadcast handler never runs against the character that sent it. Same '//' rule as above.
    elseif peerChan == 'eqbc' then mq.cmdf('/bcg /%s', cmd)
    else mq.cmdf('/dgge %s', cmd) end   -- DanNet: in-game group execute (all but self)
end

-- The GROUP roster (this tool is group-only for now): self + grouped members, by name.
-- Strip a corpse suffix off a group name. A dead character reports as "Sebbun's corpse103".
-- NOT local: this chunk is at Lua's 200-local ceiling.
function strip_corpse(nm)
    if not nm or nm == '' then return nm end
    return nm:match("^(.-)'s? corpse%d*$") or nm
end

-- MEMOISED WITHIN A TICK. This has 65 call sites and rebuilds the roster from scratch every time: my own
-- name, the member count, a Name() per member, strip_corpse on each, and two fresh tables. A dozen
-- callers in one pass is roughly ninety TLO reads and a heap of garbage to answer a question whose answer
-- cannot change between them.
-- It also runs unconditionally in the loop preamble, which was charged to 'idle' and so never appeared in
-- any profile - phase shares summed to 6% of a 41% busy figure and this is part of the difference.
-- 100ms, same as the DI memo and for the same reason: well inside one tick at its fastest, so callers
-- within a pass agree with each other and the next pass reads fresh.
-- THE ROSTER-CHANGE WATCHER STILL SEES CHANGES: it compares the list against lastGroupKey once per tick,
-- and a memo shorter than a tick cannot hide a change from it.
GROUP_MEMO_MS = 1000
-- GLOBALS, NOT LOCALS. The main chunk is at Lua's 200-local ceiling - it is in ONBOARDING as a hard
-- constraint and adding two here broke the load immediately. Anything new at this level has to be a
-- global or hang off an existing table.
GROUP_MEMO_AT, GROUP_MEMO_VAL = 0, nil

function group_members()
    if GROUP_MEMO_VAL and (mq.gettime() - GROUP_MEMO_AT) < GROUP_MEMO_MS then
        return GROUP_MEMO_VAL
    end
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
    GROUP_MEMO_AT, GROUP_MEMO_VAL = mq.gettime(), list
    return list
end

-- ---------------------------------------------------------------------------
-- Counts. Own count is local; a peer's count comes from its pushed report, else a live DanNet query of
-- FindItemCount, else (E3/EQBC) the /at_count_multi batch reply (bags, i.e. what can actually be traded).
-- ---------------------------------------------------------------------------
myName = mq.TLO.Me.Name() or ''   -- global (1.22.0): modules use it

-- ===== EVERQUEST ICONS =====
-- The game's own item and spell icons, drawn through MacroQuest's texture animations: 'A_DragItem' for
-- items (cell = Icon - 500) and 'A_SpellIcons' for spells and AAs (cell = SpellIcon). The draw never
-- reads the game: names are resolved in the main loop, cached, and saved beside the settings, so an icon
-- costs a table lookup per frame. Items the driver does not carry are asked of the group once.
-- Anything that fails falls back to the text that was there before.
uiIcons = true
ICON = { cache = {}, want = {}, anim = {}, broken = false, dirty = false,
         path = ((SETTINGS_PATH or ''):match('^(.*[/\\])') or '') .. 'AdventureTime_icons.ini' }
function icon_enc(nm) return (tostring(nm):gsub(' ', '_'):gsub("'", '~')) end
function icon_dec(nm) return (tostring(nm):gsub('_', ' '):gsub('~', "'")) end
function icon_load()
    local fh = io.open(ICON.path, 'r')
    if not fh then return end
    for line in fh:lines() do
        local nm, kind, id = line:match('^(.-)|(%a+)|(%d+)$')
        if nm and (kind == 'item' or kind == 'spell') then ICON.cache[nm] = { kind = kind, id = tonumber(id) } end
    end
    fh:close()
end
function icon_save()
    local fh = io.open(ICON.path, 'w')
    if not fh then return end
    for nm, c in pairs(ICON.cache) do
        if c then fh:write(string.format('%s|%s|%d\n', nm, c.kind, c.id)) end
    end
    fh:close()
    ICON.dirty = false
end
pcall(icon_load)
-- Draw side: never reads the game. Unknown names are queued for the main loop.
function at_icon(name, hint)
    if not name or name == '' then return nil end
    local c = ICON.cache[name]
    if c then return c end
    if c == nil then ICON.want[name] = hint or '' end
    return nil
end
-- Main loop side: a few lookups a pass, only for names something has tried to draw.
function icon_lookup(name, hint)
    local id = 0
    if hint ~= 'spell' and hint ~= 'aa' then
        pcall(function() id = tonumber(mq.TLO.FindItem('=' .. name).Icon()) or 0 end)
        if id <= 0 then pcall(function() id = tonumber(mq.TLO.FindItemBank('=' .. name).Icon()) or 0 end) end
        if id > 0 then return 'item', id end
    end
    if hint ~= 'item' then
        local sid = 0
        pcall(function() sid = tonumber(mq.TLO.Spell(name).ID()) or 0 end)
        if sid > 0 then
            pcall(function() id = tonumber(mq.TLO.Spell(name).SpellIcon()) or -1 end)
            if id >= 0 then return 'spell', id end
        end
        pcall(function() id = tonumber(mq.TLO.AltAbility(name).Spell.SpellIcon()) or -1 end)
        if id >= 0 then return 'spell', id end
        pcall(function() id = tonumber(mq.TLO.Me.AltAbility(name).Spell.SpellIcon()) or -1 end)
        if id >= 0 then return 'spell', id end
    end
    return nil
end
function icon_resolve_tick()
    local n = 0
    for name, hint in pairs(ICON.want) do
        ICON.want[name] = nil
        local kind, id = icon_lookup(name, hint)
        if kind then
            ICON.cache[name] = { kind = kind, id = id }
            ICON.dirty = true
        else
            ICON.cache[name] = false   -- not mine; the group is asked once, and a reply replaces this
            pcall(function() peer_bcast('/at_iconq %s %s', myName, icon_enc(name)) end)
        end
        n = n + 1
        if n >= 3 then break end
    end
    if ICON.dirty then pcall(icon_save) end
end
function icon_anim(kind)
    local a = ICON.anim[kind]
    if a == nil then
        local ok, v = pcall(function()
            return mq.FindTextureAnimation((kind == 'item') and 'A_DragItem' or 'A_SpellIcons')
        end)
        a = (ok and v) or false
        ICON.anim[kind] = a
    end
    return a or nil
end
-- Draw one icon at the cursor. true if it drew; false means draw the text instead.
function ui_icon(name, hint, size)
    if not uiIcons or ICON.broken then return false end
    local c = at_icon(name, hint)
    if not c then return false end
    local anim = icon_anim(c.kind)
    if not anim then return false end
    local ok = pcall(function()
        anim:SetTextureCell((c.kind == 'item') and (c.id - 500) or c.id)
        ImGui.DrawTextureAnimation(anim, size, size)
    end)
    if not ok then
        ICON.broken = true
        log('\\ay[ui] EverQuest icons are not available in this MacroQuest build - showing text\\ax')
    end
    return ok
end
function ui_icon_size()
    local s = 20
    pcall(function() s = math.floor(ImGui.GetFrameHeight()) end)
    return s
end
-- A row's title: the icon, with the title on hover - or the title as before.
function ui_row_label(text, name, hint)
    if ui_icon(name, hint, ui_icon_size()) then
        if ui_tip_hover() then pcall(function() ImGui.SetTooltip(text) end) end
        return
    end
    ui_text(UI_LABEL, text)
end
-- An icon that is a button: state colour as a border, an optional caption across the bottom (a
-- countdown), darkened while it cannot be used. nil when no icon is available, so the caller draws
-- its old button; otherwise clicked, hovered.
function ui_icon_button(id, name, hint, size, rgb, caption, dim)
    if not uiIcons or ICON.broken or not at_icon(name, hint) then return nil end
    local x, y = ImGui.GetCursorScreenPos()
    if not ui_icon(name, hint, size) then return nil end
    ImGui.SetCursorScreenPos(x, y)
    local hit = ImGui.InvisibleButton(id, size, size)
    local hov = ImGui.IsItemHovered and ImGui.IsItemHovered() or false
    pcall(function()
        local dl = ImGui.GetWindowDrawList()
        local R, G, B = math.floor(rgb[1] * 255), math.floor(rgb[2] * 255), math.floor(rgb[3] * 255)
        if dim then dl:AddRectFilled(ImVec2(x, y), ImVec2(x + size, y + size), IM_COL32(0, 0, 0, 140), 3) end
        dl:AddRect(ImVec2(x, y), ImVec2(x + size, y + size), IM_COL32(R, G, B, 235), 3, 0, 2)
        if hov then dl:AddRect(ImVec2(x - 1, y - 1), ImVec2(x + size + 1, y + size + 1), IM_COL32(255, 255, 255, 110), 3) end
        if caption and caption ~= '' then
            local fs = ImGui.GetFontSize()
            local tw = ImGui.CalcTextSize(caption) or 0
            dl:AddRectFilled(ImVec2(x + 2, y + size - fs - 2), ImVec2(x + size - 2, y + size - 2), IM_COL32(0, 0, 0, 185), 2)
            dl:AddText(ImVec2(x + math.max(2, (size - tw) * 0.5), y + size - fs - 2), IM_COL32(R, G, B, 255), caption)
        end
    end)
    return hit, hov
end

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
        -- WHEN it answered, so a pass can tell its own reply from one still in flight from an earlier
        -- ask (the batch fallback re-asks silent peers; a late reply to round 1 must not satisfy round 2
        -- of the NEXT pass with numbers from before the trade).
        counts[pl].__gotAt = mq.gettime()
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
-- HOLD THE WINDOW OPEN ACROSS A BATCH.
-- Every altcur operation opened the inventory, did one thing and closed it again - right for a single
-- read, wasteful for a run of them. A claim-and-hand-over pass is dozens of pulls back to back, so the
-- window cycled open/closed dozens of times and every cycle pays its own settle.
-- While this is held, nothing closes the window; whoever took the hold closes it once at the end.
-- A COUNT rather than a flag, so nested holders cannot close it out from under each other.
altcurHold = 0
function altcur_hold()  altcurHold = altcurHold + 1 end
function altcur_unhold(alsoClose)
    altcurHold = math.max(0, altcurHold - 1)
    if altcurHold == 0 and alsoClose then
        pcall(function() mq.TLO.Window(ALTCUR_WND).DoClose() end)
    end
end
-- EVERY close in this file goes through here, so a site that was missed cannot bypass the hold.
function altcur_close_if(wasOpen)
    if wasOpen or altcurHold > 0 then return end
    pcall(function() mq.TLO.Window(ALTCUR_WND).DoClose() end)
end

function altcur_done()
    if not altcurCloseAfter then return end
    if altcurHold > 0 then return end   -- a batch is running; it closes the window when it finishes
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
    -- NOBODY TO ASK, NOTHING TO WAIT FOR. This walked its full reply timeout with an empty peer list -
    -- 2.3 seconds of blocked loop on a character running solo, twice in one session, for answers from
    -- a group that does not exist.
    -- The local read below still happens; it is only the waiting that is skipped.
    if not peers or #peers == 0 then
        altCounts[myName:lower()] = altCounts[myName:lower()] or {}
        altCounts[myName:lower()][name] = altcur_balance(name)
        return
    end
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

-- THE SAME ASK WITHOUT THE WAIT, for refreshes that only feed the screen. Replies land through
-- /at_altbal whenever they arrive; alt_async_tick re-asks whoever stayed quiet, three rounds, 2.5s apart.
altAsync = {}   -- name -> { peers = {...}, round = n, at = gettime }
function query_alt_currency_async(peers, name)
    altCounts[myName:lower()] = altCounts[myName:lower()] or {}
    altCounts[myName:lower()][name] = altcur_balance(name)
    local waiting = {}
    for _, p in ipairs(peers or {}) do
        if p:lower() ~= myName:lower() then
            waiting[#waiting + 1] = p
            altCounts[p:lower()] = altCounts[p:lower()] or {}
            altCounts[p:lower()][name] = nil
            pcall(function() peer_cmdf(p, '/at_altrep %s %s', name:gsub(' ', '_'), myName) end)
        end
    end
    if #waiting > 0 then altAsync[name] = { peers = waiting, round = 1, at = mq.gettime() } end
end
function alt_async_tick()
    local now = mq.gettime()
    for name, a in pairs(altAsync) do
        if (now - a.at) >= 2500 then
            local still = {}
            for _, p in ipairs(a.peers) do
                if (altCounts[p:lower()] or {})[name] == nil then still[#still + 1] = p end
            end
            if #still == 0 then
                altAsync[name] = nil
            elseif a.round >= 3 then
                altAsync[name] = nil
                log('\\ay[currency] %s never answered - shown as ?\\ax', table.concat(still, ', '))
            else
                a.round, a.at, a.peers = a.round + 1, now, still
                log('[currency] no answer from %s - re-asking (round %d)', table.concat(still, ', '), a.round)
                for _, p in ipairs(still) do
                    pcall(function() peer_cmdf(p, '/at_altrep %s %s', name:gsub(' ', '_'), myName) end)
                end
            end
        end
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

-- THE BAG WALK ONLY WHEN SOMETHING MOVED. The walk stays (bags only - see my_count), but a 17-item
-- FindItemCount signature is checked first and the last blob reused while it holds.
countsSig, countsSigBlob = nil, nil
function counts_push_blob()
    local sig = {}
    for i, nm in ipairs(ITEMS) do
        local c = 0
        pcall(function() c = tonumber(mq.TLO.FindItemCount('=' .. nm)()) or 0 end)
        sig[i] = c
    end
    local sk = table.concat(sig, ',')
    if countsSigBlob and sk == countsSig then return countsSigBlob end
    local blob = counts_push_walk()
    countsSig, countsSigBlob = sk, blob
    return blob
end
function counts_push_walk()
    -- ONE PASS OVER THE BAGS, counting every item as we go.
    -- This used to call my_count once per item, and my_count walks all twelve bags from scratch - so
    -- eighteen items meant eighteen full inventory walks, thousands of TLO reads, and the loop stopped
    -- dead for THREE TO FOUR SECONDS every time it ran. The slow-phase timer caught it holding the tick
    -- for 4001ms, which is where the invis stagger came from: a caster mid-push picks its cast message up
    -- four seconds late.
    -- Walking once and tallying is the same information for a fraction of the reads.
    local want = {}
    for i, it in ipairs(ITEMS) do want[(it or ''):lower()] = i end
    local tally = {}
    pcall(function()
        for pk = 1, 12 do
            local slot = mq.TLO.Me.Inventory('pack' .. pk)
            if (tonumber(slot.ID()) or 0) > 0 then
                local cap = tonumber(slot.Container()) or 0
                if cap > 0 then
                    for s = 1, cap do
                        local it = slot.Item(s)
                        local nm = tostring(it.Name() or ''):lower()
                        local idx = want[nm]
                        if idx then tally[idx] = (tally[idx] or 0) + (tonumber(it.Stack()) or 1) end
                    end
                else
                    -- Not a bag: the pack slot holds the item itself.
                    local nm = tostring(slot.Name() or ''):lower()
                    local idx = want[nm]
                    if idx then tally[idx] = (tally[idx] or 0) + (tonumber(slot.Stack()) or 1) end
                end
            end
        end
    end)
    local parts = {}
    for i = 1, #ITEMS do
        if (tally[i] or 0) > 0 then parts[#parts + 1] = i .. ':' .. tally[i] end
    end
    -- Only non-zero entries travel. Everything absent is zero, which is most of the list on most toons.
    return (#parts > 0) and table.concat(parts, ',') or '-'
end

-- ONE BAG WALK FOR THE WHOLE LIST. my_count walks every bag per item; eighteen items was eighteen
-- walks and about 1.4s of blocked loop on every refresh. Same scope as my_count: bags only.
function my_counts_map(items)
    local want, out = {}, {}
    for _, it in ipairs(items) do want[(it or ''):lower()] = it; out[it] = 0 end
    pcall(function()
        for pk = 1, 12 do
            local slot = mq.TLO.Me.Inventory('pack' .. pk)
            if (slot.ID() or 0) > 0 then
                local cap = slot.Container() or 0
                if cap > 0 then
                    for i = 1, cap do
                        local it = slot.Item(i)
                        if (it.ID() or 0) > 0 then
                            local nm = want[(it.Name() or ''):lower()]
                            if nm then
                                local c = it.Stack() or 1
                                out[nm] = out[nm] + (c < 1 and 1 or c)
                            end
                        end
                    end
                else
                    local nm = want[(slot.Name() or ''):lower()]
                    if nm then
                        local c = slot.Stack() or 1
                        out[nm] = out[nm] + (c < 1 and 1 or c)
                    end
                end
            end
        end
    end)
    return out
end
local function query_all_counts(peers, items)
    counts = { [myName:lower()] = { __got = true, __class = mq.TLO.Me.Class.ShortName() or '?' } }
    do
        local mine = my_counts_map(items)
        for _, it in ipairs(items) do counts[myName:lower()][it] = mine[it] or 0 end
    end
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
        -- Currency is NOT asked here: every caller that shows or uses it asks for it right after.
        return
    end
    if fromPush > 0 then
        log('[counts] %d peer(s) reported; querying the other %d', fromPush, #need)
    end
    peers = need

    -- ===== NON-DANNET FALLBACK: the batch request/reply that already exists =====
    -- /dquery and DanNet(peer).Q are DanNet's. On E3 and EQBC the same question goes through
    -- /at_count_multi -> /at_have_multi: the worker counts its own bags once and answers every item plus
    -- its class in one message. Same reliability model as query_alt_currency - wait, re-ask only the
    -- silent ones, three rounds - and the same rule as the DanNet pass below: a peer that never answers
    -- is UNKNOWN for every item, never zero. held() ends in 'or 0', so a nil that was not marked
    -- __unknown would read as 'carries none' and earn a full hand-out.
    -- Unlike /dquery this needs the peer to be RUNNING AdventureTime, which the driver guarantees for
    -- its own boxes (bring_up_group) and cannot for a player - who simply stays silent and unknown.
    if not peerChan then peer_detect() end
    if peerChan ~= 'dannet' then
        local t0relay = mq.gettime()
        local encoded = {}
        for _, it in ipairs(items) do encoded[#encoded + 1] = enc(it) end
        local list = table.concat(encoded, ',')
        -- Class first, for free, exactly as the DanNet pass does below. The reply carries it too.
        for _, p in ipairs(peers) do
            if not peerClass[p:lower()] then
                local c = (member_class(p) or ''):upper()
                if c ~= '' and c ~= '?' then peerClass[p:lower()] = c end
            end
        end
        local askedAt = mq.gettime()
        local function answered(p)
            local c = counts[p:lower()]
            return c and c.__gotAt and c.__gotAt >= askedAt
        end
        local waiting = {}
        for _, p in ipairs(peers) do
            counts[p:lower()].__got = nil
            waiting[#waiting + 1] = p
        end
        for round = 1, 3 do
            for _, p in ipairs(waiting) do
                pcall(function() peer_cmdf(p, '/at_count_multi %s %s', myName, list) end)
                mq.delay(60)   -- spacing, same as the currency ask: bunched relays are what get dropped
            end
            local deadline = mq.gettime() + 2500
            while mq.gettime() < deadline do
                mq.doevents(); mq.delay(50)
                local still = {}
                for _, p in ipairs(waiting) do if not answered(p) then still[#still + 1] = p end end
                waiting = still
                if #waiting == 0 then break end
            end
            if #waiting == 0 then break end
            if round < 3 then
                log('[counts] no batch answer from %s - re-asking (round %d)', table.concat(waiting, ', '), round + 1)
            end
        end
        local miss = 0
        for _, p in ipairs(peers) do
            local pl = p:lower()
            if answered(p) then
                local cls = tostring(counts[pl].__class or ''):upper()
                if cls ~= '' and cls ~= '?' then peerClass[pl] = cls end
            end
            counts[pl].__class = peerClass[pl] or '?'   -- '?' = unknown; class_key() treats it as 'do not filter'
            for _, it in ipairs(items) do
                if counts[pl][it] == nil then
                    counts[pl].__unknown = counts[pl].__unknown or {}
                    counts[pl].__unknown[it] = true
                    miss = miss + 1
                end
            end
            counts[pl].__got = true
        end
        if #waiting > 0 then
            log('\\ay[counts] %s never answered /at_count_multi - shown as ? (not running AdventureTime, or not ours)\\ax',
                table.concat(waiting, ', '))
        end
        log('[counts] %s batch done in %dms - %d/%d answered%s', peerChan, mq.gettime() - t0relay,
            (#peers * #items) - miss, #peers * #items, miss > 0 and string.format(', %d still unknown', miss) or '')
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

    -- QUIET SWEEP.
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
    -- means the pass was genuinely clean and the budget could come down.
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

    -- VERIFY THE SLOTS, do not just trust the cached key.
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
-- BURN DIGEST. One message a minute: how many burns I have reported and a hash of their states.
-- The driver hashes what it holds for me; if the two disagree a report was lost and it asks me to
-- re-send (/at_burnresend). Agreeing costs nothing more.
function burn_key_of(secs, active, dsecs)
    return ((tonumber(secs) or 0) == 0 and 'R' or 'd') .. (active and 'A' or '-')
        .. (((tonumber(dsecs) or 0) > 0) and 'e' or '-')
end
function burn_digest(map)   -- map: name -> key
    local names = {}
    for nm in pairs(map) do names[#names + 1] = nm end
    table.sort(names)
    local h = 5381
    for _, nm in ipairs(names) do
        local line = nm .. '=' .. map[nm] .. ';'
        for i = 1, #line do h = (h * 33 + line:byte(i)) % 4294967296 end
    end
    return #names, string.format('%08x', h)
end
BURN_SUM_MS = 60000
lastBurnSum = 0
burnResendAt = {} -- driver: char -> when I last asked it to re-send
burnSumAt   = {}   -- driver: char -> { updated = when its last digest arrived } (also proof of life)
local function burnQueueLen() local n = 0; for _ in pairs(burnPending) do n = n + 1 end; return n end
local discWatch      = nil   -- { name=, at=, expected= } : the disc currently running, for the fade log
local lastDiscPoll   = 0
burnState      = {}    -- driver: burnState[char][item] = { secs=, updated= }
local driverName     = (not SHOW_UI) and ARGS[2] or nil   -- worker: driver name passed at launch (fallback: /at_ping)
local tributeState   = {}   -- name -> {active=bool, favor=num, updated=} : pushed by peers, never queried
local burnClass      = {}     -- driver: char -> class short name (for the role filter)
local burnFilter     = 'All'  -- Burns tab role filter: All / Tank / DPS / Healer
rezPriority    = {}     -- ordered char names: rez-target priority (top first); saved to disk
local CROWN_ITEM = 'Bloodcursed Crown of Vzith'
local TOKEN_ITEM = 'Exalted Glowing Bath Token'
rezAuto     = false   -- master auto-rez toggle (default OFF - flip on deliberately)
-- THE REZ FAST LANE.
rezWipe     = false
-- Which corpse the rezzer said it was casting on, so the loot afterwards goes to THAT body rather than
-- whichever one a name search happens to return. Cleared once used.
rezCorpseID = nil
-- FEIGN DEATH.
function am_feigning()
    local fd = false
    pcall(function() fd = tlo_true(mq.TLO.Me.Feigning()) end)
    return fd
end
-- INVISIBILITY.
function am_invis()
    local iv = false
    pcall(function() iv = tlo_true(mq.TLO.Me.Invis()) end)
    return iv
end
-- Call of the Wild: the shaman/druid rez AA.
COTW_AA     = 'Call of the Wild'
-- SHORT NAMES FOR CHAT.
REZ_SHORT = { crown = 'Crown', token = 'Token', cotw = 'CotW', divine = 'Divine Rez' }
function rez_short(kind) return REZ_SHORT[kind or ''] or 'rez' end
-- Divine Resurrection: the cleric rez AA.
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
-- Corpse ids that have ALREADY had a rez delivered or accepted: corpse id -> gettime it expires.
local rezCorpseDone = {}
REZ_RETIRE_MS = 20 * 60 * 1000
REZ_SAY_HOLD  = 15000   -- how long anyone's "Rezzing X" claim holds everyone off that corpse; no "Rezzed" by then and it is free again
REZ_QUEUECAST = true    -- also /queuecast the first rez attempt so an E3 emergency heal delays it instead of eating it
REZ_QUEUE_WAIT = 15000  -- after E3 cuts our rez, how long to wait on the queued copy - matches the claim hold
REZ_INFLIGHT_MAX = 15000 -- a rez still "casting" after this long is something else E3 is casting
REZ_TANK_HOLD = 6000    -- the tank defers to an in-zone rezzer this long; no claim by then and it rezzes itself
function rez_retire(id, why)
    id = tonumber(id)
    if not id or id <= 0 then return end
    local fresh = not (rezCorpseDone[id] and mq.gettime() < rezCorpseDone[id])
    rezCorpseDone[id] = mq.gettime() + REZ_RETIRE_MS
    rezPending[id] = nil
    if fresh then rezlog('[rez] corpse %d retired for %dm (%s)', id, REZ_RETIRE_MS / 60000, why or '?') end
end
function rez_retired(id)
    local exp = rezCorpseDone[tonumber(id) or 0]
    if not exp then return false end
    if mq.gettime() >= exp then rezCorpseDone[tonumber(id)] = nil; return false end
    return true
end
function rez_retire_sweep()
    local now, n = mq.gettime(), 0
    for id, exp in pairs(rezCorpseDone) do if now >= exp then rezCorpseDone[id] = nil; n = n + 1 end end
    return n
end
function rez_retire_clear(id)
    if id then rezCorpseDone[id] = nil else for k in pairs(rezCorpseDone) do rezCorpseDone[k] = nil end end
end
-- A CLICKY ON COOLDOWN IS NOT A REZ.
REZ_BOX_WAIT = 10000
rezVerify = {}     -- corpse id -> { name, at }
rezBoxFor = {}     -- corpse id -> when its owner reported a box
function rez_verify_arm(id, name)
    id = tonumber(id)
    if not id or id <= 0 or not name then return end
    if not net_is_peer(name, net_peer_set()) then return end
    rezVerify[id] = { name = name, at = mq.gettime() }
end
function rez_verify_tick()
    local now = mq.gettime()
    for id, v in pairs(rezVerify) do
        -- By id, or by name: an owner whose AT was not told the corpse id reports 0 and the id it
        -- resolves locally may be a different body of theirs. rezDone holds report time + 15s.
        local box = (rezBoxFor[id] and rezBoxFor[id] >= v.at - 2000)
                    or (rezDone[v.name:lower()] and (rezDone[v.name:lower()] - 15000) >= v.at - 2000)
        local up = false
        pcall(function() up = owner_is_up(v.name) end)
        if box or up then
            rezVerify[id] = nil
        elseif (now - v.at) > REZ_BOX_WAIT then
            rezVerify[id] = nil
            local ty = ''
            pcall(function() ty = tostring(mq.TLO.Spawn(id).Type() or '') end)
            if ty == 'Corpse' then
                rez_retire_clear(id)
                rezPending[id] = nil
                pcall(function() peer_bcast('/at_rezclear %d', id) end)
                rezlog('\\ay[rez] %s never got a box from my rez on corpse %d in %ds - opening it again\\ax',
                       v.name, id, math.floor(REZ_BOX_WAIT / 1000))
            end
        end
    end
end
rezClaimAt  = {}      -- corpse id -> when I last broadcast a claim on it (do not spam the claim)
rezGateAt   = {}      -- corpse id -> last time we logged which gate is holding the cast
-- What a peer's clicky timer reads RIGHT NOW, counted down from when they reported it.
function rez_peer_secs(rr, clicky)
    if not rr then return nil end
    -- A LOOKUP, not a two-way branch.
    local base = rr[clicky]
    if base == nil or base < 0 then return base end          -- -1 = does not own it; leave as is
    if base == 0 then return 0 end
    local left = base - math.floor((mq.gettime() - (rr.updated or 0)) / 1000)
    return (left > 0) and left or 0
end
rezPingAt   = {}      -- target name:lower -> gettime of my last handshake ping (rate-limit)
rezExpectUntil = 0    -- until when a rez is inbound for ME (set when I answer a handshake)
rezBoxAt       = 0    -- when the confirmation box appeared (0 = not showing)
-- TWO FLAGS, NOT ONE.
rezBoxClicked  = false -- we pressed it
rezBoxSeen     = false -- we have judged this dialog; do not judge it again every tick
rezBoxRefused  = false -- refused once already: keep re-judging quietly while it stays open
rezBoxJudgeAt  = 0     -- next time a refused box gets looked at again
rezNoBoxWarn   = 0    -- last time we said 'expecting a rez, no box found'
rezExpectFrom  = 0    -- when the expecting-a-rez window opened
rezIncAt       = 0    -- when a REZZER last said it was casting on me (not my own readiness)
rezIncFrom     = ''   -- who said it, so the box's caster can be matched against it
rezOwedAt      = 0    -- when I died and have not yet taken a rez; 0 = nothing owed
REZ_OWED_MS    = 3 * 3600 * 1000   -- a death this old no longer vouches for a rez box on its own
-- ON LAZARUS A DEATH IS NOT A STATE. You are back up at bind the same instant, so Me.Dead() is never
-- seen; the death message (rezOwedAt) is the only reliable sign. Recent = within these windows.
REZ_DOWN_MS    = 120000   -- a rezzer that died this recently is not offering rezzes
DIQ_DOWN_MS    = 600000   -- a tank that died this recently is not asking for death saves
function died_recently(ms) return rezOwedAt > 0 and (mq.gettime() - rezOwedAt) < ms end
rezWasDead     = false -- for spotting the moment I get back up
rezAccept      = true -- click the rez confirmation myself instead of waiting for a human
rezWaitFrom = {}      -- target -> when we started waiting on its handshake
rezWaitWarn = {}      -- target -> last time we complained about the wait
rezFireAt   = {}      -- corpseID -> my jittered earliest fire time (anti-race stagger)
rezSkip     = {}      -- corpseID -> { name:lower -> expiry } : candidates that reported they can't rez it
rezFirstSeen = {}     -- corpseID -> gettime first targeted; drives the baton backstop below
lastCorpseSweep = 0   -- last prune of the corpse-keyed tables above
-- How long a slot may block the chain without either claiming the corpse or broadcasting a skip before
-- a later slot takes over.
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
-- WHERE DOES THIS EFFECT ACTUALLY LIVE?
burnEffectWhere   = {}   -- watched name -> 'b' (buff table) or 's' (song table)
burnEffectProbeAt = {}   -- watched name -> last time we paid to look in the song table
BURN_SONG_PROBE_MS = 5000

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
    -- ONLY PROBE THE TABLE THE EFFECT CAN ACTUALLY BE IN.
    local where = burnEffectWhere[name]
    local rem = 0
    if where ~= 's' then
        pcall(function() rem = tonumber(mq.TLO.Me.Buff(bn).Duration.TotalSeconds()) or 0 end)
        if rem > 0 then burnEffectWhere[name] = 'b' end
    end
    if rem <= 0 and where ~= 'b' then
        local look = (where == 's') or (kind == nil or kind == 'd' or kind == 's')
        -- An unresolved item or AA still gets looked for, just not on every single poll.
        if not look and (mq.gettime() - (burnEffectProbeAt[name] or 0)) >= BURN_SONG_PROBE_MS then
            burnEffectProbeAt[name] = mq.gettime()
            look = true
        end
        if look then
            pcall(function() rem = tonumber(mq.TLO.Me.Song(bn).Duration.TotalSeconds()) or 0 end)
            if rem > 0 and burnEffectWhere[name] ~= 's' then
                burnEffectWhere[name] = 's'
                -- SAY IT ONCE. These are precisely the burns that were invisible before, so name them -
                -- it is the difference between "the fix works" and "nothing looks different".
                rezlog('[burns] %s lands in the short-duration window (%s) - now tracked', name, bn)
            end
        end
    end
    if rem <= 0 then buffLatch[name] = nil; return 0 end
    if not buffLatch[name] then buffLatch[name] = rem end   -- latch so dsecs doesn't churn the push key
    return buffLatch[name]
end
-- Off by default: see the note in the disc branch of ability_state. Flip to true to restore disc
-- countdowns once the client crashes are understood.
DISC_TIME_LEFT = false

-- A SWITCH TO TEST THE CRASH, not a feature.
local DISC_TICK_SECS = 6   -- MQ spell durations are in ticks; if disc countdowns read 6x too long, set this to 1
ABILITY_MISS_MS = 30000
local function ability_state(name)
    -- ONE INVENTORY SEARCH, NOT THREE.
    abilityKind = abilityKind or {}
    local cachedKind = abilityKind[name]
    -- NOTHING BY THIS NAME: an item not carried, an AA not bought. Every probe below fails, every poll.
    -- Ask again every ABILITY_MISS_MS instead; a new item or AA shows up within that.
    abilityMiss = abilityMiss or {}
    if cachedKind == nil and abilityMiss[name] and (mq.gettime() - abilityMiss[name]) < ABILITY_MISS_MS then
        return false, false, 0, false, 0, 'i'
    end
    local it = (cachedKind == nil or cachedKind == 'i') and mq.TLO.FindItem('=' .. name) or nil
    local isItem = false
    if it then pcall(function() isItem = (tonumber(it.ID()) or 0) > 0 end) end
    if isItem then
        local t = 0; pcall(function() t = tonumber(it.TimerReady()) or 0 end)
        -- ONLY LOOK FOR THE EFFECT WHILE THE THING THAT GRANTS IT IS ON COOLDOWN.
        local ds = 0
        if t > 0 then
            ds = my_effect_secs(name, function() return it.Spell.Name() end, 'i')
        else
            buffLatch[name] = nil       -- ready again: whatever it granted is done
        end
        if burn_nobuff_diag then burn_nobuff_diag(name, t, ds, it) end   -- 1.22.3: why a buff item showed no buff
        abilityKind[name] = 'i'
        return true, (t == 0), t, (ds > 0), ds, 'i'
    end
    -- OWNERSHIP, not existence.
    local aaRank, aaRdy, aaSecs = 0, false, -1
    local isAA = false
    -- A name already known to be a disc is not an AA: skip the three AA reads.
    if cachedKind ~= 'd' then
        if cachedKind ~= 'a' then
            pcall(function() aaRank = tonumber(mq.TLO.Me.AltAbility(name).Rank()) or 0 end)
        end
        pcall(function() aaRdy  = tlo_true(mq.TLO.Me.AltAbilityReady(name)()) end)
        pcall(function() aaSecs = tonumber(mq.TLO.Me.AltAbilityTimer(name).TotalSeconds()) or -1 end)
        isAA = (cachedKind == 'a') or (aaRank > 0) or aaRdy
    end
    if isAA then
        -- Same rule as items: a ready AA has not been fired, so nothing it grants can be running.
        local ds = 0
        if not aaRdy then
            ds = my_effect_secs(name, function() return mq.TLO.Me.AltAbility(name).Spell.Name() end, 'a')
        else
            buffLatch[name] = nil
        end
        abilityKind[name] = 'a'
        if aaRdy then return true, true, 0, false, 0, 'a' end
        return true, false, (aaSecs and aaSecs > 0 and aaSecs or -1), (ds > 0), ds, 'a'
    end
    local isSpell = false   -- otherwise a discipline
    pcall(function() isSpell = (tonumber(mq.TLO.Spell(name).ID()) or 0) > 0 end)
    -- Remembered too: a name that resolves in the spell table is not going to start resolving in the
    -- bags instead. Everything the cache skips is a search that could only ever fail.
    if isSpell then abilityKind[name] = 'd' end
    if isSpell then   -- a discipline: also flag whether it's the one currently RUNNING (ActiveDisc)
        local active = false; pcall(function() active = (tostring(mq.TLO.Me.ActiveDisc.Name() or '') == name) end)
        local dsecs = 0
        if active then
            -- DISC COUNTDOWN IS OFF BY DEFAULT - deliberately, pending a crash investigation.
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
    abilityMiss[name] = mq.gettime()
    return false, false, 0, false, 0, 'i'
end

-- Which buff a draught ACTUALLY lands, resolved once and remembered.
potBuffName = {}
potScanAt   = {}

-- ASK THE CLIENT HOW MANY SLOTS THERE ARE.
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
-- LATCHED, NOT LIVE - the same thing buffLatch does for burns, and for the same reason.
potBuffLatch = {}
function pot_buff_secs(base)
    local rem = pot_buff_read(base)
    if rem <= 0 then potBuffLatch[base] = nil; return 0 end
    if not potBuffLatch[base] then potBuffLatch[base] = math.floor(rem) end
    return potBuffLatch[base]
end

function pot_buff_read(base)
    local function dur(n)
        local r = 0
        pcall(function() r = tonumber(mq.TLO.Me.Buff(n).Duration.TotalSeconds()) or 0 end)
        if r <= 0 then pcall(function() r = tonumber(mq.TLO.Me.Song(n).Duration.TotalSeconds()) or 0 end) end
        return r
    end
    -- ONE READ WHEN NOTHING CHANGED. Same buff count as last time and this draught was not up then:
    -- nothing can have landed, so there is nothing to look up. Drinking adds a buff and moves the count.
    local cnt = pot_buff_count()
    local last = potBuffSeen[base]
    if cnt >= 0 and last and last.count == cnt and not last.up then return 0 end

    local function done(rem)
        potBuffSeen[base] = { count = cnt, up = (rem or 0) > 0 }
        return rem or 0
    end

    -- KNOWN BUFF NAMES FIRST. One direct lookup each, the one that was up last time first, and no 5s
    -- gate: the count check above already decides when it is worth asking. Not cached as 'the' name -
    -- a draught's I and II land differently named buffs, and caching one would miss the other.
    local gp
    for _, g in ipairs(GROUP_POTS) do if g.base == base then gp = g; break end end
    if gp and gp.buffs then
        local prev = potBuffName[base]
        if prev then
            local r = dur(prev)
            if r > 0 then return done(r) end
        end
        for _, bn in ipairs(gp.buffs) do
            if bn ~= prev then
                local r = dur(bn)
                if r > 0 then potBuffName[base] = bn; return done(r) end
            end
        end
        if gp.find then
            local found, ok = '', pcall(function() found = tostring(mq.TLO.Me.FindBuff('name ' .. gp.find).Name() or '') end)
            if ok and found ~= '' and found ~= 'NULL' then potBuffName[base] = found; return done(dur(found)) end
        end
        return done(0)
    end

    local cached = potBuffName[base]
    if cached then return done(dur(cached)) end    -- resolved: 0 here is a real "not up", not a miss

    if (mq.gettime() - (potScanAt[base] or 0)) < 5000 then return 0 end
    potScanAt[base] = mq.gettime()

    for _, tier in ipairs({ 'II', 'I' }) do        -- 1) the item's own spell name (never changes: cached)
        local ik = base .. ' ' .. tier
        local sn = potItemSpell[ik]
        if not sn then
            sn = ''
            pcall(function() sn = tostring(mq.TLO.FindItem('=' .. ik).Spell.Name() or '') end)
            if sn ~= '' and sn ~= 'NULL' then potItemSpell[ik] = sn end
        end
        if sn ~= '' and sn ~= 'NULL' and dur(sn) > 0 then potBuffName[base] = sn; return done(dur(sn)) end
    end

    local key = base:gsub('^Draught of ', '')      -- 2) a buff named after the draught
    -- ONE LOOKUP, not a walk: FindBuff searches by name for us. Only if this build cannot answer it at
    -- all does it fall back to reading the slots.
    local found, ok = '', pcall(function() found = tostring(mq.TLO.Me.FindBuff('name ' .. key).Name() or '') end)
    if ok then
        if found ~= '' and found ~= 'NULL' then potBuffName[base] = found; return done(dur(found)) end
        return done(0)
    end
    for _, nm in ipairs(pot_buff_names()) do
        if nm:find(key, 1, true) then
            potBuffName[base] = nm
            return done(dur(nm))
        end
    end
    return done(0)
end
potItemSpell = {}
potBuffSeen  = {}   -- base -> { count = buff count at the last look, up = was it up }
-- Buffs AND songs: a draught that lands in the short window moves the song count, not the buff count.
-- Read once per poll and shared by every draught.
potCount = { at = 0, v = -1 }
function pot_buff_count()
    if (mq.gettime() - potCount.at) < 1000 then return potCount.v end
    local b, sg = -1, 0
    pcall(function() b = tonumber(mq.TLO.Me.CountBuffs()) or -1 end)
    pcall(function() sg = tonumber(mq.TLO.Me.CountSongs()) or 0 end)
    potCount.at, potCount.v = mq.gettime(), (b >= 0) and (b * 1000 + sg) or -1
    return potCount.v
end
potBuffSnap  = { at = 0, names = {}, count = -1 }
function pot_buff_names()
    local now = mq.gettime()
    if (now - potBuffSnap.at) < 1000 then return potBuffSnap.names end
    -- ONLY WHEN THE BUFF COUNT MOVED. A draught landing adds a buff, so an unchanged count means the
    -- last walk still answers - one read instead of thirty-nine. A full re-walk every 30s regardless,
    -- for the rare swap that leaves the count where it was.
    local cnt = -1
    pcall(function() cnt = tonumber(mq.TLO.Me.CountBuffs()) or -1 end)
    if cnt >= 0 and cnt == potBuffSnap.count and (now - potBuffSnap.at) < 30000 then
        return potBuffSnap.names
    end
    potBuffSnap.count = cnt
    local names = {}
    for i = 1, buff_slot_max(45) do
        local nm = ''
        pcall(function() nm = tostring(mq.TLO.Me.Buff(i).Name() or '') end)
        if nm ~= '' and nm ~= 'NULL' then names[#names + 1] = nm end
    end
    potBuffSnap.at, potBuffSnap.names = now, names
    return names
end

-- --------------------------------------------------------------------------- Healer group/raid clicks.
MGB_WHO = { CLR='Cleric', DRU='Druid', SHM='Shaman', BRD='Bard', ENC='Enchanter',
            BST='Beastlord', RNG='Ranger' }
-- WHAT EACH ONE SHOUTS.
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

-- Seconds until an ability is usable.
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
        -- Item, AA or spell - see cast_opts. This used to be a two-way test and everything that was not
        -- an item went out untyped.
        local opts = cast_opts(ab)
        if raiding and i == 1 then
            -- MGB rides the FIRST ability only (it buffs the next cast), so the announce fires once.
            at_cast(ab .. opts .. '/BeforeSpell|' .. MGB_AA)
            pcall(function() mq.cmdf('/rsay %s', mgb_say_text(cls, e)) end)
        else
            at_cast(ab .. opts)
        end
    end
    log('[mgb] %s%s', mgb_label(cls, e), raiding and ' (MGB, raid)' or ' (group)')
end

-- What I can see about ONE draught line, read locally.
function pot_state(base)
    local carries, up, secs, dsecs = 0, 0, -1, 0
    -- COUNT FIRST. A tier you do not carry used to run the whole item / AA / spell probe before the
    -- count said zero; the count alone answers it.
    for _, tier in ipairs({ 'II', 'I' }) do
        local n = 0
        pcall(function() n = tonumber(mq.TLO.FindItemCount('=' .. base .. ' ' .. tier)()) or 0 end)
        if n > 0 and carries == 0 then
            local have, ready, s = ability_state(base .. ' ' .. tier)
            if have then carries, secs = 1, (ready and 0 or (s or -1)) end
        end
    end
    -- One buff per draught LINE, not per tier: I and II land the same effect, so this is asked once.
    local rem = pot_buff_secs(base)
    if rem > 0 then up, dsecs = 1, math.floor(rem) end
    return carries, up, secs, dsecs
end

at_module('burns')   -- the [Burn] list and the burn check (modules/burns.lua)

-- No INI, or an empty [Burn]: watch NOTHING rather than inventing an item.
BURN_WATCH = parse_burns() or {}
if #BURN_WATCH == 0 then
    log('\\ay[burns] no [Burn] entries found for %s - the Burns tab stays empty until %s has some.\\ax', myName,
        BURN_FILE_USED and path_show(BURN_FILE_USED) or (cast_backend() == 'e3' and 'its E3 ini' or 'its burn list'))
end
do   -- 8s settle + up to 3s of per-character offset, so the group's first reports don't collide
    -- SPREAD THAT ACTUALLY SPREADS.
    local off = 0
    for i = 1, #myName do off = off + myName:byte(i) * i * 37 end
    -- 2-5s, not 8-16s.
    burnStartAt  = mq.gettime() + 2000 + (off % 3000)
    -- 2-3s, not 8-16s: a few small messages, still spread a little so five workers do not all
    -- speak in the same instant.
    clickStartAt = mq.gettime() + 2000 + (off % 1000)
end

-- ===== Rez target priority: a reorderable, persisted list (top gets rezzed first) =====
local REZ_FILE
-- PER CHARACTER, for the same reason the rez ORDER is - and this is the half of that fix that never
-- landed.
local function rez_file_path()
    if REZ_FILE then return REZ_FILE end
    local who = ''
    pcall(function() who = tostring(mq.TLO.Me.Name() or '') end)
    REZ_FILE = at_read('adventuretime_rezpriority_' .. ((who ~= '') and who or 'unknown') .. '.txt')
    return REZ_FILE
end

-- The pre-1.19.20 shared file. Read once, never written.
local function rez_file_path_shared()
    return at_read('adventuretime_rezpriority.txt')
end
local function rez_rank(cls)
    cls = (cls or ''):upper()
    if TANK_CLASS[cls] then return 1 elseif HEALER_CLASS[cls] then return 2
    elseif cls == 'BRD' or cls == 'ENC' then return 4 else return 3 end   -- 3 = DPS, 4 = support
end
-- Group members in the user's chosen display order.
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
    local function readInto(path)
        pcall(function()
            local f = io.open(path, 'r')
            if f then
                for line in f:lines() do
                    local nm = (line:gsub('%s+$', ''))
                    if nm ~= '' then list[#list + 1] = nm end
                end
                f:close()
            end
        end)
    end
    readInto(rez_file_path())
    -- MIGRATION, ONCE. No per-character file yet means either a first run or an upgrade, and the shared
    -- file is the best guess for what this character was using. It is never written back to.
    if #list == 0 then readInto(rez_file_path_shared()) end
    -- NAMES THAT ARE NOT HERE ARE NOT A REZ CHAIN.
    if #list > 0 then
        local here = {}
        for _, nm in ipairs(group_members()) do here[nm:lower()] = true end
        local hits = 0
        for _, nm in ipairs(list) do if here[nm:lower()] then hits = hits + 1 end end
        if hits == 0 then
            rezlog('\\ay[rez] the saved rez list names nobody in this group (%s) - rebuilding from who is '
                .. 'actually here\\ax', table.concat(list, ', '))
            list = {}
        end
    end
    if #list == 0 then list = default_rez_priority() end
    local have = {}; for _, nm in ipairs(list) do have[nm:lower()] = true end
    for _, nm in ipairs(group_members()) do if not have[nm:lower()] then list[#list + 1] = nm end end   -- append any new group members
    rezPriority = list
end

-- ===== Rezzer cast order: a reorderable, persisted list of (name, clicky) slots that DRIVES the baton =====
-- Persisted toggles, so they survive a reload. One key=value per line; add more keys freely.
local SETTINGS_FILE
-- ===== WHERE STATE LIVES: lua\adventuretime\Settings\ ===== Probe before mkdir, for the reason spelled
-- out at the log folder above: lfs.mkdir reports false when the directory already exists, so treating
-- that as failure spawned a shell every single startup.
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
-- Where a state file is READ from.
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

AT_UPDATE_STATUS = AT_UPDATE_STATUS or {
    nextRead = 0,
    available = false,
    status = 'unknown',
    latestSha = '',
    installedSha = '',
    checkedAtUtc = '',
    error = '',
}
AT_UPDATE_ARMED_UNTIL = AT_UPDATE_ARMED_UNTIL or 0

function at_path_trim(path)
    return (tostring(path or ''):gsub('[\\/]+$', ''))
end

function at_mq_root()
    local root = ''
    pcall(function() root = tostring(mq.TLO.MacroQuest.Path() or '') end)
    return at_path_trim(root)
end

function at_config_dir()
    local cfg = ''
    pcall(function() cfg = tostring(mq.TLO.MacroQuest.Path('config')() or '') end)
    if cfg == '' and mq.configDir then cfg = tostring(mq.configDir or '') end
    return at_path_trim(cfg)
end

function at_read_all(path)
    local f = io.open(tostring(path or ''), 'r')
    if not f then return nil end
    local body = f:read('*a')
    f:close()
    return body
end

function at_file_exists(path)
    local f = io.open(tostring(path or ''), 'r')
    if not f then return false end
    f:close()
    return true
end

function at_json_string(body, key)
    body = tostring(body or '')
    key = tostring(key or ''):gsub('([^%w_])', '%%%1')
    return body:match('"' .. key .. '"%s*:%s*"([^"]*)"') or ''
end

function at_json_bool(body, key)
    body = tostring(body or '')
    key = tostring(key or ''):gsub('([^%w_])', '%%%1')
    local v = body:match('"' .. key .. '"%s*:%s*(true)')
        or body:match('"' .. key .. '"%s*:%s*(false)')
    if v == 'true' then return true end
    if v == 'false' then return false end
    return nil
end

function at_update_status_path()
    local cfg = at_config_dir()
    if cfg == '' then return '' end
    return cfg .. '\\adventuretime_update_status.json'
end

function at_short_sha(sha)
    sha = tostring(sha or '')
    if #sha > 12 then return sha:sub(1, 12) end
    return sha
end

function at_refresh_update_status(force)
    local now = mq.gettime()
    if not force and now < (AT_UPDATE_STATUS.nextRead or 0) then return AT_UPDATE_STATUS end
    AT_UPDATE_STATUS.nextRead = now + 30000

    local path = at_update_status_path()
    local body = (path ~= '') and at_read_all(path) or nil
    if not body or body == '' then
        AT_UPDATE_STATUS.available = false
        AT_UPDATE_STATUS.status = 'unknown'
        AT_UPDATE_STATUS.latestSha = ''
        AT_UPDATE_STATUS.installedSha = ''
        AT_UPDATE_STATUS.checkedAtUtc = ''
        AT_UPDATE_STATUS.error = ''
        return AT_UPDATE_STATUS
    end

    local status = at_json_string(body, 'status')
    local available = at_json_bool(body, 'updateAvailable')
    if available == nil then available = (status == 'update_available') end
    AT_UPDATE_STATUS.available = available == true
    AT_UPDATE_STATUS.status = status ~= '' and status or (AT_UPDATE_STATUS.available and 'update_available' or 'unknown')
    AT_UPDATE_STATUS.latestSha = at_json_string(body, 'latestSha')
    AT_UPDATE_STATUS.installedSha = at_json_string(body, 'installedSha')
    AT_UPDATE_STATUS.checkedAtUtc = at_json_string(body, 'checkedAtUtc')
    AT_UPDATE_STATUS.error = at_json_string(body, 'error')
    return AT_UPDATE_STATUS
end

function at_find_patcher()
    local root = at_mq_root()
    if root == '' then return nil end
    for _, dir in ipairs({ root, root .. '\\AdventureTimePatcher', root .. '\\Patcher' }) do
        for _, name in ipairs({ 'AdventureTimePatcher.exe', 'AdventureTimeUpdater.exe' }) do
            local path = dir .. '\\' .. name
            if at_file_exists(path) then return path end
        end
    end
    return nil
end

function at_win_quote(path)
    return '"' .. tostring(path or ''):gsub('"', '') .. '"'
end

function at_shell_open(target, params)
    target = tostring(target or ''):match('^%s*(.-)%s*$') or ''
    if target == '' then return false end
    params = tostring(params or ''):match('^%s*(.-)%s*$') or ''
    if params == '' then params = nil end

    local okFfi, ffi = pcall(require, 'ffi')
    if okFfi and ffi then
        if not AT_SHELL_CDEF_DONE then
            pcall(ffi.cdef, [[
                void* ShellExecuteA(void* hwnd, const char* lpOperation, const char* lpFile,
                                    const char* lpParameters, const char* lpDirectory, int nShowCmd);
            ]])
            AT_SHELL_CDEF_DONE = true
        end
        local ok = pcall(function()
            AT_SHELL32 = AT_SHELL32 or ffi.load('shell32')
            local ret = AT_SHELL32.ShellExecuteA(nil, 'open', target, params, nil, 1)
            local code = tonumber(ffi.cast('intptr_t', ret))
            if not code or code <= 32 then error('ShellExecuteA failed: ' .. tostring(code)) end
        end)
        if ok then return true end
    end

    local ok = pcall(function()
        if target:lower():match('^https?://') then
            os.execute('start "" ' .. at_win_quote(target))
        elseif params then
            os.execute('start "" ' .. at_win_quote(target) .. ' ' .. params)
        else
            os.execute('start "" ' .. at_win_quote(target))
        end
    end)
    return ok == true
end

function at_launch_patcher()
    local exe = at_find_patcher()
    if not exe then
        local url = 'https://github.com/sebbun123/AdventureTimePatcher/releases/latest'
        if at_shell_open(url) then
            log('\\ay[update] AdventureTimePatcher.exe not found - opened download page.\\ax')
        else
            log('\\ay[update] AdventureTimePatcher.exe not found. Open: %s\\ax', url)
        end
        return false
    end
    local root = at_mq_root()
    local params = 'update --mq ' .. at_win_quote(root)
    if at_shell_open(exe, params) then
        log('\\ag[update] AdventureTimePatcher launched: %s\\ax', exe)
        return true
    end
    log('\\ar[update] Could not launch AdventureTimePatcher: %s\\ax', exe)
    return false
end

function at_draw_update_button(tag)
    local st = at_refresh_update_status(false)
    if not st.available then return end
    local now = mq.gettime()
    local armed = now < (AT_UPDATE_ARMED_UNTIL or 0)
    local label = armed and ('Really update?##' .. tag) or ('Update available##' .. tag)
    local pushed = 0
    if ImGuiCol and ImGuiCol.Button then
        if pcall(function() ImGui.PushStyleColor(ImGuiCol.Button, 0.58, 0.38, 0.16, 1.0) end) then pushed = pushed + 1 end
        if pcall(function() ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 0.72, 0.48, 0.20, 1.0) end) then pushed = pushed + 1 end
        if pcall(function() ImGui.PushStyleColor(ImGuiCol.ButtonActive, 0.84, 0.56, 0.24, 1.0) end) then pushed = pushed + 1 end
    end
    local clicked = ImGui.Button(label, armed and 118 or 132, 0)
    if pushed > 0 then pcall(function() ImGui.PopStyleColor(pushed) end) end
    if ui_tip_hover() then
        pcall(function()
            ImGui.SetTooltip(armed
                and 'Click again to close AdventureTime on the group and run the patcher.'
                or  'AdventureTime update is available. Click once, then confirm.')
        end)
    end
    if clicked then
        if armed then
            updateLaunchRequested = true
            AT_UPDATE_ARMED_UNTIL = 0
        else
            AT_UPDATE_ARMED_UNTIL = now + 5000
        end
    end
end

-- ONE SETTINGS FILE FOR THE GROUP.
SETTINGS_NAME = 'adventuretime_settings.txt'
local function settings_path() return at_write(SETTINGS_NAME) end
-- Declared above save_settings and load_settings so neither can see it nil.
invisPick = invisPick or {}   -- [ITU|Invis] = character name
-- ROWS THE USER HAS TURNED OFF in Countermeasures.
cmOff = cmOff or {}
function cm_hidden(g) return cmOff[tostring(g or '')] == true end
local function save_settings()
    -- DRIVER ONLY.
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
            f:write('raidFolded=' .. (raidFolded and '1' or '0') .. '\n')
            f:write('dcGiveTo=' .. (dcGiveTo or '') .. '\n')
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
            -- Which panel each section sits in, as key:number pairs. Absent = the mini, so only the ones
            -- that have been moved take up any space in the file.
            do
                local parts = {}
                for k, v in pairs(popOut) do
                    if type(v) == 'number' then
                        parts[#parts + 1] = k .. ':' .. v .. ':' .. (popSeq[k] or 0)
                    end
                end
                table.sort(parts)
                f:write('popOut=' .. table.concat(parts, ',') .. '\n')
            end
            f:write('miniMode=' .. (miniMode and '1' or '0') .. '\n')
            f:write('uiLocked=' .. (uiLocked and '1' or '0') .. '\n')
            f:write('uiTheme=' .. tostring(uiTheme or 'Midnight') .. '\n')
            f:write('miniRaid=' .. (miniRaid and '1' or '0') .. '\n')
            f:write('cothSwap=' .. (cothSwap and '1' or '0') .. '\n')
            f:write('perfScale=' .. tostring(perfScale or 1) .. '\n')
            do   -- which pop-out panels are pinned. Numbers only, so an empty list is an empty line.
                local pl = {}
                for n, on in pairs(popLocked or {}) do if on then pl[#pl + 1] = tostring(n) end end
                table.sort(pl)
                f:write('popLocked=' .. table.concat(pl, ',') .. '\n')
            end
            f:write('uiWideButtons=' .. (uiWideButtons and '1' or '0') .. '\n')
            f:write('uiIcons=' .. (uiIcons and '1' or '0') .. '\n')
            f:write('peerTransport=' .. tostring(peerTransport or 'auto') .. '\n')
            f:write('botControl=' .. tostring(botControl or 'auto') .. '\n')
            f:write('miniRunning=' .. (miniRunning and '1' or '0') .. '\n')
            f:write('uiPulse=' .. (UI_PULSE and '1' or '0') .. '\n')
            f:write('uiChrome=' .. (UI_CHROME and '1' or '0') .. '\n')
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
            -- Persisted now that it is a Settings checkbox.
            f:write('autoXTank=' .. (autoXTank and '1' or '0') .. '\n')
            f:write('xtankPinned=' .. table.concat(xtankPinned, ',') .. '\n')
            f:close()
        end
    end)
end
local function load_settings()
    pcall(function()
        -- FIRST RUN PICKS UP AN EXISTING INSTALL, with nothing copied anywhere.
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
            -- them and the k:match below threw.
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
            if k == 'raidFolded'     then raidFolded     = (v == '1' or v:lower() == 'true') end
            -- Not trimmed to a word: a name is one token, but a trailing space typed into the box would
            -- otherwise make every comparison fail with nothing to show for it.
            if k == 'dcGiveTo'       then dcGiveTo       = (v or ''):gsub('^%s+', ''):gsub('%s+$', '') end
            if k == 'miniInvisCombo' then miniInvisCombo = (v == '1' or v:lower() == 'true') end
            local ig = k:match('^invispick_(%a+)$')
            if ig and v ~= '' then invisPick[ig] = v end
            local cg = k:match('^cmoff_([%w_]+)$')
            if cg and v == '1' then cmOff[cg:gsub('_', ' ')] = true end
            if k == 'miniCures' then miniCures  = (v == '1' or v:lower() == 'true') end
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
            if k == 'miniRaid' then miniRaid = (v == '1' or v:lower() == 'true') end
            if k == 'cothSwap' then cothSwap = (v == '1' or v:lower() == 'true') end
            if k == 'perfScale' then
                local n = tonumber(v) or 1
                perfScale = (n >= 1 and n <= 4) and n or 1
            end
            -- BY NAME, and validated against the table. A settings file naming a theme that no longer
            -- exists falls back rather than leaving at_theme() to guess every frame.
            if k == 'uiTheme' then
                for _, t in ipairs(AT_THEMES) do if t.name == v then uiTheme = v end end
            end
            if k == 'popLocked' then
                popLocked = {}
                for part in v:gmatch('%d+') do popLocked[tonumber(part)] = true end
            end
            if k == 'uiWideButtons' then uiWideButtons = (v == '1' or v:lower() == 'true') end
            if k == 'uiIcons' then uiIcons = (v == '1' or v:lower() == 'true') end
            if k == 'peerTransport' and peer_transport_valid(v) and v ~= peerTransport then
                peerTransport = v
                -- THE SETTING WAS DEFUNCT BECAUSE OF ORDER.
                if peerChan then
                    peer_transport_reset()
                    peerTransportProbeAt = 0
                    pcall(peer_detect)
                    pcall(mute_relay_echo)
                end
            end
            if k == 'botControl' and (v == 'auto' or v == 'e3' or v == 'rgmercs') then botControl = v end
            if k == 'miniRunning' then miniRunning = (v == '1' or v:lower() == 'true') end
            if k == 'uiPulse' then UI_PULSE = (v == '1' or v:lower() == 'true') end
            if k == 'uiChrome' then UI_CHROME = (v == '1' or v:lower() == 'true') end
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
            if k == 'popOut' then
                popOut = {}
                for part in v:gmatch('[^,]+') do
                    -- key:panel:seq, with key:panel still accepted so a settings file written before the
                    -- ordering existed loads without complaint.
                    local sk, pn, sq = part:match('^(.-):(%d+):(%d+)$')
                    if not sk then sk, pn = part:match('^(.-):(%d+)$') end
                    if sk then
                        popOut[sk] = tonumber(pn)
                        local n = tonumber(sq) or 0
                        popSeq[sk] = n
                        if n > popSeqN then popSeqN = n end
                    end
                end
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
    -- PER CHARACTER.
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

-- THE ROSTER IS NOT A STARTUP FACT.
function rez_roster_sync()
    if #rezPriority == 0 then load_rez_priority(); return end
    local have, added = {}, {}
    for _, nm in ipairs(rezPriority) do have[nm:lower()] = true end
    for _, nm in ipairs(group_members()) do
        if not have[nm:lower()] then
            rezPriority[#rezPriority + 1] = nm; have[nm:lower()] = true; added[#added + 1] = nm
        end
    end
    if #added == 0 then return end
    rezlog('[rez] roster: now watching %s for corpses', table.concat(added, ', '))
    if SHOW_UI then save_rez_priority() end
    -- THE DRIVER ALSO OWNS THE REZZER ORDER. New members get their slots - non-tanks ahead of the first
    -- tank slot, tanks at the end, same shape as default_rez_order - and the order goes out to everyone.
    if not SHOW_UI then return end
    if #rezOrder == 0 then load_rez_order() end
    local inOrder = {}
    for _, sl in ipairs(rezOrder) do inOrder[sl.name:lower()] = true end
    local changed = false
    for _, nm in ipairs(added) do
        if not inOrder[nm:lower()] then
            changed = true
            if rez_rank(member_class(nm)) == 1 then
                rezOrder[#rezOrder + 1] = { name = nm, clicky = 'token' }
                rezOrder[#rezOrder + 1] = { name = nm, clicky = 'crown' }
            else
                local at = #rezOrder + 1
                for i, sl in ipairs(rezOrder) do
                    if rez_rank(member_class(sl.name)) == 1 then at = i; break end
                end
                table.insert(rezOrder, at, { name = nm, clicky = 'crown' })
                table.insert(rezOrder, at, { name = nm, clicky = 'token' })
            end
        end
    end
    if changed then save_rez_order(); bcast_rez_order() end
end

at_module('coth')   -- Call of the Hero: the gathers and the charm swap (modules/coth.lua)

-- Invis alignment test: fires the combo on a timer and records how far apart the two casters landed.
INVT = { on = false, n = 0, total = 0, bucket = {}, seen = {}, until_ = 0, every = 15000, nextAt = 0,
         covered = 0, partial = 0, checkAt = nil, checkRun = 0, worstMiss = nil }
-- How long after the casts to read everyone's coverage. Both spells have a cast time and their reports
-- have to travel, so an immediate read would show misses that are only late.
INVT_CHECK_MS = 5000

-- Who ended up with what. Runs a few seconds after each test press.
function invistest_check()
    -- COVERAGE IS NO LONGER MEASURED FROM HERE.
    local miss = {}
    if #miss == 0 then
        INVT.covered = INVT.covered + 1
        log('[invistest] run %d: everybody has both', INVT.checkRun)
    else
        INVT.partial = INVT.partial + 1
        INVT.worstMiss = table.concat(miss, ' ')
        log('\\ay[invistest] run %d: MISSED - %s\\ax', INVT.checkRun, INVT.worstMiss)
    end
end
function invistest_report()
    if INVT.n == 0 then log('[invistest] no completed runs'); return end
    log('\\ag[invistest] %d runs - best %dms, worst %dms, average %dms\\ax',
        INVT.n, INVT.best or 0, INVT.worst or 0, INVT.total / INVT.n)
    -- COVERAGE FIRST. The gap is diagnostic; this is the result.
    local runs = INVT.covered + INVT.partial
    if runs > 0 then
        log('\\ag[invistest] everybody covered on %d of %d runs (%d%%)\\ax',
            INVT.covered, runs, math.floor(INVT.covered * 100 / runs + 0.5))
        if INVT.partial > 0 then
            log('[invistest]   last miss: %s', tostring(INVT.worstMiss))
        end
    end
    local names = { '<=50ms', '51-150ms', '151-500ms', '501-1000ms', '>1s' }
    for i = 1, 5 do
        local c = INVT.bucket[i] or 0
        if c > 0 then
            log('[invistest]   %-11s %3d  (%d%%)', names[i], c, math.floor(c * 100 / INVT.n + 0.5))
        end
    end
end

potWanted     = nil    -- set by /atshimmer and friends; the tick drinks, because group_pot relays
pacAddWanted  = nil    -- set by /atpacify; the tick queues it
cothSetWanted = nil    -- set by the CoTH buttons; the tick calls coth_set, because it broadcasts
magicWanted   = nil    -- set by a Countermeasures button; the tick casts it
pacDelWanted  = nil    -- set by the placate 'x' button; the tick tells the group
-- How long a fired rung stays assumed-spent before the client's own timers are believed again.
DI_SPENT_CAP = 20000

-- Same baton idea as the rez, but simpler: fixed target (the tank), no corpse, no handshake. Kept in ONE
-- global table rather than a dozen locals - this chunk is at Lua's 200-local ceiling.
DI = {
    STAFF   = 'Fabled Staff of Forbidden Rites',
    -- WHAT THE STAFF PUTS ON THE TANK, and the only thing in the whole system that produces it.
    STAFF_SPELL = 'Divine Intervention',
    -- Options passed through to E3, mirroring the INI line this replaced.
    OPTS    = '/CastType|Item/%s/NoInterrupt',
    REAGENT = 'Emerald',
    -- EMERALDS DO EXACTLY ONE JOB: below this, do not try to cast.
    MIN_EMERALDS = 10,
    -- Retry an apparently-dropped cast this often, and this many times total, before calling it a
    -- nocast.
    RETRY_AFTER = 12000,
    RETRY_MAX   = 3,
    -- TESTING SWITCH.
    ladderOff = false,
    DG_AA   = 'Divine Guardian',
    DG_BOOT = "Forsaken Donal's Boots of Mourning",
    -- TOP OF THE CLERIC'S LADDER, in order.
    CLR_SAVES = { 'Divine Redemption', 'Divine Intervention' },
    -- How long dgReady stays up after a source was last genuinely available. Rides out the global
    -- cooldown between a healing cleric's casts without hiding a real cooldown.
    DG_LATCH_MS = 4000,
    dgLastUp = 0,
    -- Any of these on the tank means a save is up and the staff holds.
    SAVES   = { 'Divine Guardian', 'Divine Intervention', 'Divine Redemption' },
    -- How long a REFUSAL stands the chain down.
    SAVED_HOLD = 25000,
    -- Spec for casting a LADDER RUNG through E3, mirroring the staff's.
    RUNG_OPTS_SPELL = '%s/NoInterrupt',
    RUNG_OPTS       = '%s/CastType|%s/%s/NoInterrupt',
    -- How long the ladder sits still after issuing a rung, so the TANK'S save flag can catch up.
    RUNG_GAP = 6000,
    -- How long SpellReady must stay false before it is believed.
    RUNG_READY_SLACK = 5,
    -- ITEMS NEED LONGER, because their cooldown read is the slow one.
    RUNG_GAP_ITEM = 10000,
    -- How long to treat MY staff as spent after I fire it, regardless of what TimerReady says - and
    -- that read has to be treated as untrustworthy, not merely laggy.
    ASSUME_SPENT = 1800000,
    -- Hard ceiling on waiting for a cast to declare itself.
    WATCH_MAX = 45000,
    -- How long to hold for a peer ahead that looks able before taking the turn anyway.
    baton   = nil,    -- who owns the staff turn right now; defaults to the front of di_order()
    -- Shortest believable time from /nowcast to the staff going on reuse.
    MIN_FLIGHT = 3000,
    auto    = false,
    state   = {},     -- name -> { staff, emeralds, dgReady, saveUp, updated }
    key     = '',     -- my last-pushed state, for change detection
    lastPush = 0, lastPoll = 0, firedAt = 0, trigAt = 0, dbg = '',
    startedAt = 0,    -- set at load; the staff will not fire until the state table has had time to fill
}

-- Everything I can see about myself, read locally.
DI_STAFF_MEMO_MS = 100

function di_raw_staff(fresh)
    if not fresh and DI.rawAt and (mq.gettime() - DI.rawAt) < DI_STAFF_MEMO_MS then
        return DI.rawVal
    end
    local secs, ticks = -1, -1
    pcall(function()
        -- ONE SEARCH, THREE FIELDS.
        local it = mq.TLO.FindItem('=' .. DI.STAFF)
        if (tonumber(it.ID()) or 0) > 0 then
            secs  = tonumber(it.TimerReady()) or 0
            ticks = tonumber(it.Timer()) or -1
        end
    end)
    if secs < 0 then
        DI.rawAt, DI.rawVal = mq.gettime(), -1
        return -1                                  -- do not carry the staff at all
    end
    -- Sample Me.ItemReady here too, because MQ's NULL arrives in Lua as nil and so does a TLO that does
    -- not exist on this build - the two are indistinguishable from one reading.
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

    -- A COOLDOWN COUNTS DOWN AT ONE SECOND PER SECOND.
    local now = mq.gettime()
    if best > 0 then
        DI.lastStaffSecs, DI.lastStaffAt = best, now
    elseif DI.lastStaffSecs and DI.lastStaffAt then
        local elapsed = (now - DI.lastStaffAt) / 1000
        local expect  = DI.lastStaffSecs - elapsed
        -- Only argue about a reading big enough to matter.
        if expect > 2 and DI.lastStaffSecs > 15 then
            if (now - (DI.lastImpossibleLog or 0)) > 30000 then
                DI.lastImpossibleLog = now
                rezlog('\\ay[di] staff read 0 but it was %ds only %.0fs ago - impossible, using %ds\\ax',
                       DI.lastStaffSecs, elapsed, math.floor(expect))
            end
            -- Memoised like every other exit, so callers within this tick agree with each other.
            local v = math.floor(expect)
            DI.rawAt, DI.rawVal = mq.gettime(), v
            return v
        end
    end
    DI.rawAt, DI.rawVal = mq.gettime(), best
    return best
end

-- REMEMBER THE FIRE ACROSS A RESTART.
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
    -- ONCE, ON EVERY TOON.
    if not DI.saidStaffReads then
        DI.saidStaffReads = true
        rezlog('[di] staff reads at load: %s', di_staff_reads())
        -- Every one of those reads says ready at load whether or not it is, so put back what we know.
        di_staff_stamp_read()
    end
    -- I FIRED IT, SO IT IS SPENT UNTIL PROVEN OTHERWISE.
    if staff >= 0 and DI.assumeSpentUntil and mq.gettime() < DI.assumeSpentUntil then
        local assumed = math.floor((DI.assumeSpentUntil - mq.gettime()) / 1000)
        if assumed > staff then staff = assumed end
    end
    -- SAME MEMO, SAME REASON.
    local em = 0
    if DI.emAt and (mq.gettime() - DI.emAt) < DI_STAFF_MEMO_MS then
        em = DI.emVal or 0
    else
        pcall(function() em = tonumber(mq.TLO.FindItemCount('=' .. DI.REAGENT)()) or 0 end)
        DI.emAt, DI.emVal = mq.gettime(), em
    end
    -- dgReady is only meaningful from a cleric: 1 = a save source is still IN HAND, so the staff holds.
    -- LADDER ORDER: Divine Redemption, then Divine Guardian (AA, then the boots), then the staff chain.
    local dg = 0
    if (member_class(myName) or ''):upper() == 'CLR' and not DI.ladderOff then
        -- ONCE, at first read: does this cleric even HAVE the lower rungs?
        if not DI.saidRungs then
            DI.saidRungs = true
            local rank, owns = 0, false
            pcall(function() rank = tonumber(mq.TLO.Me.AltAbility(DI.DG_AA).Rank()) or 0 end)
            pcall(function() owns = (tonumber(mq.TLO.FindItem('=' .. DI.DG_BOOT).ID()) or 0) > 0 end)
            rezlog('[di] ladder inventory: %s rank=%d (%s) | boots %s', DI.DG_AA, rank,
                   (rank > 0) and 'owned' or 'NOT OWNED - this rung can never hold',
                   owns and 'carried' or 'NOT carried - this rung can never hold')
        end
        -- SINGLE SOURCE OF TRUTH.
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
    -- Plain name lookup on MY OWN buffs.
    local save, saveName = 0, nil
    for _, b in ipairs(DI.SAVES) do
        local up = false
        pcall(function() up = (tonumber(mq.TLO.Me.Buff(b).ID()) or 0) > 0 end)
        if up then save, saveName = 1, b; break end
    end
    -- SAY WHICH ONE, not just whether.
    if saveName ~= DI.mySaveSaid then
        DI.mySaveSaid = saveName
        if saveName then rezlog('[di] I am now carrying %s', saveName)
        else             rezlog('[di] my save is gone') end
    end
    return staff, em, dg, save, saveName
end

-- A SAVE HELD WHILE MOVING. The asked character keeps the job: it tells the tank it has it, re-tells it
-- every 5s so the tank's claim does not time out, and fires once it has been still for DI_STILL_MS. Gives
-- the job back if still moving after DI_MOVE_WAIT_MAX, or stands down if the tank is covered meanwhile.
DI_STILL_MS      = 300
DI_MOVE_WAIT_MAX = 30000
DI_CLAIM_EVERY   = 5000
function am_moving()
    local m = false
    pcall(function() m = tlo_true(mq.TLO.Me.Moving()) end)
    return m
end
function di_pend(tank, best, tid, why)
    DIQ.pending = { tank = tank, best = best, tid = tid, since = mq.gettime(), claimAt = mq.gettime() }
    rezlog('[diq] %s - holding %s for %s until I stop moving', why, best.name, tank)
    pcall(function() peer_cmdf(tank, '/at_diclaim %s %s', myName, (best.name or '?'):gsub(' ', '_')) end)
end
function di_pend_tick()
    local p = DIQ.pending
    if not p then return end
    local now = mq.gettime()
    if (DI.savedUntil or 0) > now then
        DIQ.pending = nil
        rezlog('[diq] %s is covered - dropping the held %s', p.tank, p.best.name)
        return
    end
    if am_moving() then
        p.stillAt = nil
        if (now - p.since) > DI_MOVE_WAIT_MAX then
            DIQ.pending = nil
            rezlog('\\ay[diq] still moving after %ds - handing %s back to %s\\ax',
                   DI_MOVE_WAIT_MAX / 1000, p.best.name, p.tank)
            pcall(function() peer_cmdf(p.tank, '/at_diack %s no still-moving', myName) end)
        elseif (now - p.claimAt) >= DI_CLAIM_EVERY then
            p.claimAt = now
            pcall(function() peer_cmdf(p.tank, '/at_diclaim %s %s', myName, (p.best.name or '?'):gsub(' ', '_')) end)
        end
        return
    end
    p.stillAt = p.stillAt or now
    if (now - p.stillAt) < DI_STILL_MS then return end
    DIQ.pending = nil
    -- STILL WORTH FIRING? Somebody else's save may have gone out, or the tank may be gone, while I moved.
    if (DI.firedAt or 0) > p.since then
        rezlog('[diq] another save went out while I was moving - dropping the held %s', p.best.name)
        return
    end
    local ty = ''
    pcall(function() ty = tostring(mq.TLO.Spawn(p.tid).Type() or '') end)
    if ty ~= 'PC' then
        rezlog('[diq] %s is no longer there to save (%s) - dropping the held %s', p.tank,
               (ty ~= '') and ty or 'gone', p.best.name)
        pcall(function() peer_cmdf(p.tank, '/at_diack %s no target-is-dead', myName) end)
        return
    end
    rezlog('[diq] stopped after %.1fs - firing %s for %s', (now - p.since) / 1000, p.best.name, p.tank)
    di_announce(p.best, p.tank)
    di_fire_best(p.best, p.tank, p.tid)
end

-- The group's tank (same rule the XTarget code uses).
function diq_self_check()
    local s = DIQ.self
    if not s then return end
    -- Casting means it went out. Nothing more to watch here; the normal verify owns what happens next.
    local casting = 0
    pcall(function() casting = tonumber(mq.TLO.Me.Casting.ID()) or 0 end)
    if casting > 0 then DIQ.self = nil; return end
    -- ItemReady flipping false is the other proof - a boolean, so it cannot lag the way a countdown does.
    if DI.itemReadyWorks and not tlo_true(DI.itemReady) then DIQ.self = nil; return end
    -- AND THE COOLDOWN ITSELF STARTING, which is the most direct proof of all: if the thing went off,
    -- its reuse is now counting.
    local secs = di_raw_staff()
    if secs > 0 then DIQ.self = nil; return end
    -- Give it a moment: a cast does not register in the same instant the command is sent.
    if (mq.gettime() - s.at) < DIQ_SELF_MS then return end
    -- Neither signal ever appeared. The cast did not happen.
    DIQ.self = nil
    DI.watch = nil                 -- nothing to verify; do not hold the slot for 45s
    DI.assumeSpentUntil = nil      -- and it was not spent, so do not pretend it was
    DI.pushNow = true              -- correct the record as promptly as we spoiled it
    pcall(function() os.remove(di_staff_stamp_path()) end)   -- nor across a restart
    -- CUT BY MOVEMENT: keep the job and fire again when I stop, rather than handing it to the next toon.
    if s.best and am_moving() then
        di_pend(s.tank, s.best, s.tid, 'cast cut by movement')
        return
    end
    rezlog('\\ay[diq] my cast never started - telling %s to ask somebody else\\ax', s.tank)
    pcall(function() peer_cmdf(s.tank, '/at_diack %s no cast-never-started', myName) end)
end

-- Runs on the TANK, every tick. This is the whole fast path.
function diq_tick()
    local tank = di_tank()
    if not tank or tank:lower() ~= myName:lower() then return end   -- only the tank drives this
    -- DI.auto, NOT diOn.
    if not DI.auto then return end

    -- ZONE, NOT COMBAT.
    local safe = diq_safe_zone()

    -- MY OWN SAVE, READ LOCALLY. No report, no lag - this is the fact the whole system turns on and the
    -- tank is the only character that has it immediately.
    local haveSave = false
    for _, b in ipairs(DI.SAVES) do
        local up = false
        pcall(function() up = (tonumber(mq.TLO.Me.Buff(b).ID()) or 0) > 0 end)
        if up then haveSave = true; break end
    end

    if haveSave or safe then
        if DIQ.active then
            -- Covered, or somewhere nothing can hurt us. Tell everyone to stand down so nobody spends a
            -- second save on the strength of a report that has not caught up yet.
            rezlog('[diq] covered%s - standing the group down after %.1fs',
                   haveSave and '' or ' (safe zone)', (mq.gettime() - DIQ.startedAt) / 1000)
            pcall(function() peer_bcast('/at_disaved %d', DI.SAVED_HOLD) end)
            DIQ.active, DIQ.asked, DIQ.tried, DIQ.casting = false, nil, {}, nil
            DIQ.saidLong = nil
            DIQ.exhaustedUntil = nil
        end
        DIQ.quietKey = nil
        return
    end

    -- Still standing back from an exhausted round.
    if DIQ.exhaustedUntil and mq.gettime() < DIQ.exhaustedUntil then return end

    -- DO NOT ASK WHILE DEAD.
    do
        local iAmCorpse = false
        pcall(function()
            iAmCorpse = corpse_id_exact(myName) > 0
        end)
        if not iAmCorpse then pcall(function() iAmCorpse = tlo_true(mq.TLO.Me.Dead()) end) end
        if not iAmCorpse and died_recently(DIQ_DOWN_MS) then iAmCorpse = true end
        if iAmCorpse then
            -- Stand anything in flight down, so an answer does not arrive against a stale request.
            if DIQ.active then
                rezlog('[diq] I am dead - standing the save queue down until I am up')
                DIQ.active, DIQ.asked, DIQ.tried, DIQ.casting = false, nil, {}, nil
                DIQ.saidLong, DIQ.exhaustedUntil = nil, nil
            end
            DIQ.quietKey = nil
            return
        end
    end

    -- No save, somewhere that matters. Start asking.
    if not DIQ.active then
        -- QUIET WHILE NOTHING HAS CHANGED. The last round found nobody to ask; if the same people are still
        -- out of zone, there is still nobody - look again in a few seconds without a word.
        if DIQ.quietKey then
            DIQ.tried = {}
            if diq_empty_key() == DIQ.quietKey then
                DIQ.exhaustedUntil = mq.gettime() + DIQ_EXHAUST_MS
                return
            end
            DIQ.quietKey = nil
        end
        DIQ.active, DIQ.tried, DIQ.startedAt = true, {}, mq.gettime()
        DIQ.asked = nil
        rezlog('[diq] my save is down - asking the group')
    end

    -- NOTHING TO HAND OVER TO.
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

-- Fire order: non-tanks in rez-priority order, tank last.



-- A staff came back up.



-- EVERY WAY OF ASKING ABOUT THE STAFF'S COOLDOWN, SIDE BY SIDE.
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
        -- 'pack3', not 3.
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
end
end

-- WHY NOTHING HAPPENED used to show here, through a gate() helper that set DI.dbg and a panel line that
-- rendered it.

-- ===== THE SAVE LADDER, AS ACTIONS =====
DIQ = {
    active   = false,   -- an ask is in flight
    asked    = nil,     -- who we asked
    what     = nil,     -- which save we asked for
    at       = 0,       -- when
    tried    = {},      -- who has already answered no this emergency
    startedAt= 0,
}
DIQ_ANSWER_MS = 1200    -- how long to wait for a yes/no before treating it as silence
-- A CLAIM MEANS IT IS HANDLED.
DIQ_CAST_MS = 15000
-- THE STAFF GETS LONGER.
DIQ_EXHAUST_MS = 4000
-- How long to give a cast to show ANY sign of starting. Casting state and ItemReady both move within a
-- few hundred milliseconds of a real cast; this is generous against that.
DIQ_SELF_MS = 1500

-- ZONES WHERE NOTHING CAN KILL YOU.
DIQ_SAFE_ZONES = {
    poknowledge  = true,   -- Plane of Knowledge
    nexus        = true,   -- The Nexus
    potranquility= true,   -- Plane of Tranquility
    bazaar       = true,   -- The Bazaar
    poinnovation = true,   -- often used as a hub
    guildhall    = true,
    guildlobby   = true,
}
-- Marr's temple is an instanced AFK hub and its short name varies by server; matched loosely for that
-- reason rather than listed above.
DIQ_SAFE_MATCH = { 'marr' }

function diq_safe_zone()
    local z = ''
    pcall(function() z = tostring(mq.TLO.Zone.ShortName() or ''):lower() end)
    if z == '' then return false end          -- cannot tell: assume it matters
    if DIQ_SAFE_ZONES[z] then return true end
    for _, frag in ipairs(DIQ_SAFE_MATCH) do
        if z:find(frag, 1, true) then return true end
    end
    return false
end
DIQ_GIVEUP_MS = 8000    -- whole-emergency ceiling; past this, let the old ladder have it

-- What to ask for, best first.
function diq_zone_elsewhere(nm)
    local myZone = 0
    pcall(function() myZone = tonumber(mq.TLO.Zone.ID()) or 0 end)
    if myZone <= 0 then return false end                       -- I don't know where I am: ask everyone
    local rr = rezReady[nm]
    if not rr then return false end                            -- never reported: ask
    if (rr.zone or 0) <= 0 then return false end               -- reported no zone: ask
    if (mq.gettime() - (rr.updated or 0)) >= 30000 then return false end   -- stale: ask
    return rr.zone ~= myZone
end

-- A DECLINE THAT WILL STILL BE TRUE NEXT TIME (1.21.1). 'no-staff' and 'nothing-owned' hold until that
-- character's own DI report changes (or DIQ_DECLINE_HOLD passes); invis and feigning hold DIQ_DECLINE_SHORT.
-- The quiet check used to clear DIQ.tried and ask the same character again every few seconds (1.20.46
-- logs: Sebbun asked Lopan 395 times in 36 minutes, staff=-1 dg=0, every answer the same 'no').
DIQ_DECLINE_HOLD  = 600000
DIQ_DECLINE_SHORT = 60000
DIQ.declined = DIQ.declined or {}
function diq_state_sig(nm)
    local s
    for k, v in pairs(DI.state or {}) do if k:lower() == nm:lower() then s = v; break end end
    if not s then return 'none' end
    local st = s.staff or -1
    return string.format('%s|%s', (st == 0) and 'ready' or ((st < 0) and 'none' or 'cd'), tostring(s.dgReady or 0))
end
function diq_note_decline(nm, why)
    why = tostring(why or '')
    local hold
    if why:find('no-staff', 1, true) or why:find('nothing-owned', 1, true) then hold = DIQ_DECLINE_HOLD
    elseif why == 'invis' or why == 'feigning' then hold = DIQ_DECLINE_SHORT end
    if not hold then return end
    DIQ.declined[nm:lower()] = { sig = diq_state_sig(nm), untilT = mq.gettime() + hold, why = why }
end
function diq_declined(nm)
    local d = DIQ.declined[nm:lower()]
    if not d then return false end
    if mq.gettime() >= d.untilT or diq_state_sig(nm) ~= d.sig then
        DIQ.declined[nm:lower()] = nil
        return false
    end
    return true
end

function diq_candidates()
    local out, elsewhere, away = {}, 0, {}
    for nm, s in pairs(DI.state or {}) do
        local skipZone = false
        if nm:lower() ~= myName:lower() and not DIQ.tried[nm:lower()] and diq_declined(nm) then
            DIQ.tried[nm:lower()] = true   -- same answer as last time: not asked again until it can change
        end
        if nm:lower() ~= myName:lower() and not DIQ.tried[nm:lower()] then
            skipZone = diq_zone_elsewhere(nm)
            if skipZone then elsewhere = elsewhere + 1; away[#away + 1] = nm:lower() end
        end
        if nm:lower() ~= myName:lower() and not DIQ.tried[nm:lower()] and not skipZone then
            local age = (mq.gettime() - (s.updated or 0)) / 1000
            -- A report older than a minute is not evidence of anything; ask anyway, but last.
            local stale = (age > 60) and 1 or 0
            -- ORDER, NEVER EXCLUDE.
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
    return out, elsewhere, away
end
-- nil when somebody can be asked; otherwise who is out of zone, as one string to compare.
function diq_empty_key()
    local list, _, away = diq_candidates()
    if #list > 0 then return nil end
    table.sort(away)
    return table.concat(away, ',')
end

function diq_ask_next(tank)
    local list, elsewhere, away = diq_candidates()
    if #list == 0 then
        table.sort(away)
        DIQ.quietKey = table.concat(away, ',')
        -- BACK OFF, DO NOT SPIN.
        DIQ.exhaustedUntil = mq.gettime() + DIQ_EXHAUST_MS
        -- SAY IF ZONE WAS THE REASON. "Nobody has a save" and "nobody is in this zone" want completely
        -- different responses from the person reading the log, and they used to print the same line.
        rezlog('[diq] nobody has a save%s - letting the staff chain work; quiet until someone zones in',
               ((elsewhere or 0) > 0) and string.format(' (%d out of zone, not asked)', elsewhere) or '')
        DIQ.active = false
        return false
    end
    DIQ.quietKey = nil
    local pick = list[1]
    DIQ.asked, DIQ.what, DIQ.at = pick.nm, 'save', mq.gettime()
    rezlog('[diq] asking %s for a save on %s (rank %d, report %.0fs old)',
           pick.nm, tank, pick.rank, pick.age)
    pcall(function() peer_cmdf(pick.nm, '/at_dineed %s', tank) end)
    return true
end

-- WHAT IS ABOUT TO BE CAST, in the group's chat, in the short form you actually track by.
function di_announce(r, tank)
    -- BY NAME FIRST, kind second.
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
    -- CLAIM IT WITH THE TANK.
    pcall(function() peer_cmdf(tank or '', '/at_diclaim %s %s', myName, (r.name or '?'):gsub(' ', '_')) end)
end

-- DID I JUST FIRE THIS?
function di_spell_reagent(nm)
    local id, cnt = '', ''
    local okId  = pcall(function() id  = tostring(mq.TLO.Spell(nm).ReagentID(1)() or '') end)
    local okCnt = pcall(function() cnt = tostring(mq.TLO.Spell(nm).ReagentCount(1)() or '') end)
    if not okId or id == '' or id == 'NULL' or tonumber(id) == nil or tonumber(id) <= 0 then
        return nil, 0, 0, okId          -- no component, or the member does not exist on this build
    end
    local need = tonumber(cnt) or 1
    if not okCnt or need <= 0 then need = 1 end
    -- COUNT BY ID.
    local idN = tonumber(id)
    local nmR = ''
    pcall(function() nmR = tostring(mq.TLO.FindItem(idN).Name() or '') end)
    if nmR == 'NULL' then nmR = '' end
    -- counted = did the read WORK, which is a different question from whether the answer was zero.
    local have, counted = 0, false
    local okC = pcall(function()
        local v = mq.TLO.FindItemCount(idN)()
        if v ~= nil then have = tonumber(v) or 0; counted = true end
    end)
    if (not okC or not counted) and nmR ~= '' then
        pcall(function()
            local v = mq.TLO.FindItemCount('=' .. nmR)()
            if v ~= nil then have = tonumber(v) or 0; counted = true end
        end)
    end
    return (nmR ~= '') and nmR or ('item ' .. id), have, need, true, counted
end

-- WAIT FOR THE CAST TO FINISH, do not judge it on a stopwatch.
DI_VERIFY_SETTLE = 1500     -- quiet time after casting stops, before the gem timer is believed
DI_VERIFY_MAX    = 15000    -- give up waiting for the cast to end and read anyway
-- How long to keep watching a gem that still reads zero before calling the cast lost. Exits the instant
-- the timer moves, so a working cast pays only the lag between the command and E3 acting on it.
DI_VERIFY_GRACE  = 3000
-- Send /queuecast alongside /nowcast. See the note at the cast site: off while we find out whether a
-- stale queue entry is what stops the save firing on some characters. Set true to restore the pair.
DI_SEND_QUEUECAST = false
-- Put the tank's NAME back into the rung spec alongside the trailing target id.
function di_rung_verify()
    local c = DI.rungCheck
    if not c then return end
    -- TWO CLOCKS, and they measure different things.
    c.issued = c.issued or c.at
    local total = mq.gettime() - c.issued
    -- DID THE CLIENT EVER BEGIN A CAST?
    local casting = 0
    pcall(function() casting = tonumber(mq.TLO.Me.Casting.ID()) or 0 end)
    if casting > 0 then
        c.sawCasting = true
        if not c.castingWas then
            pcall(function()
                local n = tostring(mq.TLO.Me.Casting.Name() or '')
                if n ~= '' and n ~= 'NULL' then c.castingWas = n end
            end)
        end
    end
    if (mq.gettime() - c.at) < DI_VERIFY_SETTLE then return end
    if total < DI_VERIFY_MAX then
        if casting > 0 then
            -- Still going. Push the settle out so it is measured from the END of the cast, not the start.
            c.at = mq.gettime()
            return
        end
    end
    if not c.gem or c.gem <= 0 then DI.rungCheck = nil; return end   -- not a gem spell, nothing to read
    -- ONE MORE LOOK BEFORE CALLING IT A FAILURE.
    local s = -1
    local function gemLeft()
        local best = -1
        for g = 1, 12 do
            local holds = ''
            pcall(function() holds = tostring(mq.TLO.Me.Gem(g)() or '') end)
            if holds == c.name then
                local v = -1
                pcall(function() v = tonumber(mq.TLO.Me.GemTimer(g).TotalSeconds()) or -1 end)
                -- Any copy counting is proof the cast went out, so the LARGEST reading wins: a fresh
                -- 90s on one copy is the evidence, not a 0 on another.
                if v > best then best = v end
            end
        end
        return best
    end
    s = gemLeft()
    if s == 0 then
        -- Watched on later ticks, not waited for here (1.21.2: this held the whole loop 3s - Nityrc's log,
        -- 16:23:33, di_verify 3055ms): the check stays in hand until the timer moves or the grace runs out.
        c.graceUntil = c.graceUntil or (mq.gettime() + DI_VERIFY_GRACE)
        if mq.gettime() < c.graceUntil then return end
    end
    DI.rungCheck = nil
    if s > 0 then
        -- THE CAST WENT OUT. So the only remaining question is where it landed, and there is exactly one
        -- wrong answer we can see from here: on the caster.
        local mineNow = nil
        pcall(function()
            for _, b in ipairs(DI.SAVES) do
                if (tonumber(mq.TLO.Me.Buff(b).ID()) or 0) > 0 then mineNow = b; break end
            end
        end)
        if not c.sawCasting then
            rezlog('\\ay[di] %s: a gem timer moved but the client was never seen casting - a timer alone '
                .. 'is not proof (a re-mem or another copy of the spell moves it too)\\ax', c.name)
        end
        if mineNow and mineNow ~= c.mineWas then
            rezlog('\\ar[di] %s cast, but the save landed on ME (%s), not on %s - the target was not '
                .. 'applied. Check E3\'s target handling for this character.\\ax',
                   c.name, mineNow, tostring(c.tank or '?'))
        end
        return
    end
    if s == 0 then
        rezlog('\\ar[di] %s was issued but NO gem holding it started a timer after %dms - it did not cast\\ax',
               c.name, total)
        -- The distinction that matters: a client that never began is E3 dropping the command outright;
        -- one that began and cast something else is a targeting or interrupt problem.
        if c.sawCasting then
            rezlog('[di]   the client DID start a cast in that window%s - the command was taken, and '
                .. 'something stopped it finishing',
                   c.castingWas and (' ("' .. c.castingWas .. '")') or '')
        else
            rezlog('[di]   the client never started ANY cast in that window - E3 took the command and did '
                .. 'nothing with it')
        end
        -- WHY, as far as we can see from here. Only runs on a failure, so it costs nothing in the normal
        -- case, and it names the three things E3 drops a cast over without a word.
        local rg, have, need, known, counted = di_spell_reagent(c.name)
        local mana, dist = -1, -1
        pcall(function() mana = tonumber(mq.TLO.Me.PctMana()) or -1 end)
        pcall(function() dist = tonumber(mq.TLO.Spawn('pc =' .. tostring(c.tank or '')).Distance()) or -1 end)
        if rg then
            -- 'could not count' and 'counted zero' are different answers and only one of them means
            -- anything.
            rezlog('%s[di]   %s needs %d x %s, I have %s | mana %d%% | %s @%dm',
                   (counted and have < need) and '\\ar' or '', c.name, need, rg,
                   counted and tostring(have) or '(could not count)', mana,
                   tostring(c.tank or '?'), dist)
            if counted and have < need then
                rezlog('\\ar[di]   OUT OF COMPONENT - E3 declines the cast silently while this is true.\\ax')
            end
        else
            rezlog('[di]   %s: no component %s | mana %d%% | %s @%dm', c.name,
                   known and 'required' or '(could not read - member missing on this build)',
                   mana, tostring(c.tank or '?'), dist)
        end
        -- It was never spent, so do not let the fired-stamp hold it back from the next attempt.
        if DI.rungFiredAt then DI.rungFiredAt[c.name] = nil end
        -- AND TELL THE TANK, so it asks somebody else now rather than after its claim times out.
        if c.tank and c.tank ~= '' and c.tank:lower() ~= myName:lower() then
            pcall(function() peer_cmdf(c.tank, '/at_diack %s no save-did-not-cast', myName) end)
        end
    end
end

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
    -- CAP IT.
    local ms = rc * 1000
    if ms > DI_SPENT_CAP then ms = DI_SPENT_CAP end
    return (mq.gettime() - fired) < ms
end


-- WHICH GEM IS THIS SPELL REALLY IN?
function di_gem_for(nm)
    local gem = 0
    pcall(function() gem = tonumber(mq.TLO.Me.Gem(nm)()) or 0 end)
    if gem > 0 then
        local holds = ''
        pcall(function() holds = tostring(mq.TLO.Me.Gem(gem)() or '') end)
        if holds == nm then return gem end
        DI.gemSaid = DI.gemSaid or {}
        local k = nm .. '/' .. gem .. '/' .. holds
        if not DI.gemSaid[k] then
            DI.gemSaid[k] = true
            rezlog('\\ay[di] Me.Gem("%s") said gem %d, but gem %d holds "%s" - walking the gems instead\\ax',
                   nm, gem, gem, (holds ~= '') and holds or 'nothing')
        end
        gem = 0
    end
    -- The walk: the same form E3 uses, and the one that has never been caught lying.
    local found = 0
    pcall(function()
        for g = 1, 12 do
            if tostring(mq.TLO.Me.Gem(g)() or '') == nm then found = g; break end
        end
    end)
    if found > 0 then return found end
    -- Not in a gem at all. Say so once, and only if it is even in the book - a spell the character does
    -- not have is not a problem worth a line.
    local inBook = false
    pcall(function() inBook = tlo_true(mq.TLO.Me.Book(nm)()) end)
    if inBook then
        DI.saidNoGem = DI.saidNoGem or {}
        if not DI.saidNoGem[nm] then
            DI.saidNoGem[nm] = true
            rezlog('[di] %s is in my book but not memmed - it cannot be used as a save', nm)
        end
    end
    return 0
end

function di_rung_list()
    local out = {}
    -- RUNG 1 - the cleric's save spell: whichever of Divine Redemption / Divine Intervention is IN A
    -- GEM.
    for _, nm in ipairs(DI.CLR_SAVES) do
        -- IN THE BOOK BUT NOT IN A GEM IS INVISIBLE.
        local gem = di_gem_for(nm)
        if gem > 0 then
            local s = -1
            pcall(function() s = tonumber(mq.TLO.Me.GemTimer(gem).TotalSeconds()) or -1 end)
            -- SpellReady AS WELL AS THE GEM TIMER.
            local rdy = (s >= 0 and s <= DI.RUNG_READY_SLACK)
            local castable = (s == 0)
            -- I FIRED IT, SO IT IS SPENT UNTIL PROVEN OTHERWISE.
            local spent = di_rung_spent(nm, 'Spell')
            local ready = rdy and not spent
            -- SAY THE INPUTS when the verdict changes.
            local k = tostring(ready) .. '/' .. tostring(spent)
            if DI.rungSaid ~= k and (mq.gettime() - (DI.rungSaidAt or 0)) > 2000 then
                DI.rungSaid, DI.rungSaidAt = k, mq.gettime()
                rezlog('[di] rung 1 %s: gem %d, gem timer %ss (slack %ds), assumed-spent %s -> %s',
                       nm, gem, tostring(s), DI.RUNG_READY_SLACK, tostring(spent),
                       ready and 'READY' or 'not ready')
            end
            -- Carry the gem number: the announce says which gem it came from, which is the one detail
            -- that lets you follow along on the caster's own bar rather than taking the log's word.
            out[#out + 1] = { name = nm, kind = 'Spell', ready = ready, gem = gem,
                              castable = castable, gemLeft = (s > 0) and s or 0 }
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
local function di_tick() end

-- Did the last DI staff cast actually go off?
function di_check_landed()
    if not DI.watch then return end
    -- POLLED, not timed.
    local w = DI.watch
    local age = mq.gettime() - w.at
    -- RAW, not di_read_self.
    local st = di_raw_staff(true)
    local _, em = di_read_self()
    local blocked = DI.blockedAt and DI.blockedAt >= w.at
    -- EMERALDS PROVE NOTHING HERE.
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
        -- RETRY BEFORE GIVING UP.
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
    -- THE VERDICT DECIDES WHETHER THE ASSUMPTION SURVIVES.
    if verdict == 'landed' then
        DI.noCastStrikes = 0
        -- Announce it NOW, because now it is true. Includes the retry count when it took more than one
        -- attempt, so the group sees the cast was fought for rather than clean.
        pcall(function()
            if (w.tries or 1) > 1 then mq.cmdf('/gsay DI staff on %s (took %d tries)', w.tank, w.tries)
            else                       mq.cmdf('/gsay DI staff on %s', w.tank) end
        end)
        -- TELL THE GROUP THE EMERGENCY IS OVER, not just that my staff is gone.
        if tankHasOurs then
            DI.savedUntil = mq.gettime() + DI.SAVED_HOLD
            DI.trigAt, DI.turnAt = 0, nil
            pcall(function() peer_bcast('/at_disaved %d', DI.SAVED_HOLD) end)
        end
        -- THE POINT OF THE WHOLE THING.
        rezlog('[di] LANDED after %.1fs - %s%s (staff timer reads %ds, %d emerald(s) spent)', age / 1000,
               tankHasOurs and ((w.tank or 'the tank') .. ' is carrying ' .. DI.STAFF_SPELL) or 'staff on reuse',
               tankHasOurs and '' or '', st, spent)
    elseif verdict == 'stale' then
        -- We just got a TRUE reading out of a read that normally lies - the staff was already this far
        -- into reuse.
        rezlog('[di] staff reads at the misread: %s', di_staff_reads())
        DI.assumeSpentUntil = mq.gettime() + (st * 1000)
        rezlog('\\ay[di] NOT A CAST - staff read ready but is %ds into reuse %0.1fs later. The readiness check misread it; nothing was spent. Holding myself out %ds.\\ax',
               st, age / 1000, st)
    elseif verdict == 'blocked' then
        -- A REFUSAL IS A SAVE DETECTOR, and a shared one.
        DI.assumeSpentUntil = nil     -- a refused cast does not take the cooldown; I am still ready
        DI.savedUntil = mq.gettime() + DI.SAVED_HOLD
        peer_bcast('/at_disaved %d', DI.SAVED_HOLD)
        pcall(function() peer_cmdf(w.tank or '', '/at_disavedump %s', myName) end)
        rezlog('\\ay[di] BLOCKED after %.1fs - %s is already covered by %s. Holding the chain %ds. (saveUp=%s)\\ax',
               age / 1000, DI.blockedOn ~= '' and DI.blockedOn or (w.tank or '?'), DI.blockedBy or '?',
               math.floor(DI.SAVED_HOLD / 1000), ts and tostring(ts.saveUp) or 'no report')
    else
        -- TWO STRIKES AND I STOP VOLUNTEERING.
        rezlog('[di] staff reads at the nocast: %s', di_staff_reads())
        DI.assumeSpentUntil = nil     -- the command went nowhere: I still have my staff
        -- A SAVE CANNOT LAND ON A CORPSE, so a cast that failed because the tank died is not evidence
        -- that I cannot fire.
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
            -- TIME-LIMITED, not for the session.
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
    local it, has = nil, false
    pcall(function() it = mq.TLO.FindItem('=' .. itemName); has = (tonumber(it.ID()) or 0) > 0 end)
    if not has then return -1 end
    local t = 0; pcall(function() t = tonumber(it.TimerReady()) or 0 end)
    return t
end
-- MY CotW: seconds until ready, 0 = ready, -1 = don't own it.
function my_divine_secs()
    local rank = 0; pcall(function() rank = tonumber(mq.TLO.Me.AltAbility(DIVINE_SPELL).Rank()) or 0 end)
    if rank <= 0 then return -1 end
    local rdy = false; pcall(function() rdy = tlo_true(mq.TLO.Me.AltAbilityReady(DIVINE_SPELL)()) end)
    if rdy then return 0 end
    local s = -1; pcall(function() s = tonumber(mq.TLO.Me.AltAbilityTimer(DIVINE_SPELL).TotalSeconds()) or -1 end)
    return (s and s > 0) and s or 1   -- not ready is not ready, even with no timer to read
end

function my_cotw_secs()
    local rank = 0; pcall(function() rank = tonumber(mq.TLO.Me.AltAbility(COTW_AA).Rank()) or 0 end)
    if rank <= 0 then return -1 end
    local rdy = false; pcall(function() rdy = tlo_true(mq.TLO.Me.AltAbilityReady(COTW_AA)()) end)
    if rdy then return 0 end
    local s = -1; pcall(function() s = tonumber(mq.TLO.Me.AltAbilityTimer(COTW_AA).TotalSeconds()) or -1 end)
    -- NOT READY MEANS NOT READY. A timer that reads 0 or nothing while AltAbilityReady says no used to
    -- come back as 0 - "ready" - so the did-it-land check saw an AA that had just fired as unused.
    return (s and s > 0) and s or 1
end
-- One mapping from slot kind to MY seconds-until-ready, so the election and the did-it-actually-fire
-- retry check can never disagree about what a slot needs.
function rez_kind_secs(kind)
    -- 'divine' HAD NO CASE HERE and fell through to the crown, so a divine slot asked about the CROWN's
    -- cooldown instead of the AA's.
    if kind == 'divine' then return my_divine_secs() end
    if kind == 'cotw'  then return my_cotw_secs() end
    if kind == 'token' then return my_rez_secs(TOKEN_ITEM) end
    return my_rez_secs(CROWN_ITEM)
end
-- EFFECTIVE ORDER = CotW holders first, then the saved clicky order untouched.
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
-- Set by the driver while it is running a count pass.
quietUntil = 0
function peer_quiet() return mq.gettime() < quietUntil end
-- Is there a rez event in progress from where I stand?
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
        -- NOTE THE TRAILING ().
        pcall(function() n = tonumber(mq.TLO.SpawnCount('pccorpse')()) or 0 end)
        HB.corpse = dead or n > 0
    end
    return HB.corpse
end

-- How far the rez clickies actually reach, asked of the item rather than assumed.
REZ_MAX_DIST = 100
-- --------------------------------------------------------------------------- Raid rezzes.
RAID_REZ        = true    -- rez raid members outside the group at all
RAID_MAX_DIST   = 100
RAID_TOKEN_GAP  = 15000   -- per rezzer
-- Who may spend a CROWN on someone outside the group.
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
-- The DI staff is cast ON THE TANK, so it has a reach too - and nothing was checking it.
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

-- GROUP ONLY: is the corpse's owner logged in?
REZ_ONLINE_SETTLE = 3000
rezOffSeen, rezOnAt = {}, {}
function rez_owner_online(nm)
    local k = nm:lower()
    local inGroup, off = false, false
    pcall(function()
        local m = mq.TLO.Group.Member(nm)
        if m and m() then
            inGroup = true
            off = tlo_true(m.Offline())
        end
    end)
    if not inGroup then return true end
    local t = mq.gettime()
    if off then
        if not rezOffSeen[k] then rezlog('[rez] %s is offline - holding rez until they log in', nm) end
        rezOffSeen[k], rezOnAt[k] = true, nil
        return false, 'offline'
    end
    if rezOffSeen[k] then
        rezOffSeen[k], rezOnAt[k] = nil, t
        rezlog('[rez] %s back online - rez in %ds', nm, math.floor(REZ_ONLINE_SETTLE / 1000))
    end
    if rezOnAt[k] and (t - rezOnAt[k]) < REZ_ONLINE_SETTLE then return false, 'just logged in' end
    rezOnAt[k] = nil
    return true
end

-- GROUP ONLY: PING the dead toon before firing.
REZ_PING_EVERY, REZ_PING_FRESH, REZ_PING_GIVEUP = 1000, 3000, 20000
rezPingAt, rezPingFirst, rezPong, rezPingGaveUp = {}, {}, {}, {}
function rez_owner_ready(nm)
    local ok, why = rez_owner_online(nm)
    if not ok then return false, why end
    if nm:lower() == myName:lower() then return true end
    if not net_is_peer(nm, net_peer_set()) then return true end
    local k, t = nm:lower(), mq.gettime()
    local p = rezPong[k]
    if p and p.state == 'ok' and (t - p.at) < REZ_PING_FRESH then return true end
    -- new episode if we haven't pinged them in a while
    if not rezPingAt[k] or (t - rezPingAt[k]) > 10000 then
        rezPingFirst[k], rezPingGaveUp[k] = t, nil
    end
    if (t - rezPingFirst[k]) > REZ_PING_GIVEUP and not rezPingGaveUp[k] then
        rezPingGaveUp[k] = true
        rezlog('[rez] no ready ping from %s in %ds (last: %s) - still holding', nm,
               math.floor(REZ_PING_GIVEUP / 1000), p and p.state or 'no answer')
    end
    if not rezPingAt[k] or (t - rezPingAt[k]) >= REZ_PING_EVERY then
        rezPingAt[k] = t
        pcall(function() peer_cmdf(nm, '/at_rezping %s', myName) end)
    end
    return false, 'waiting on ready ping (' .. (p and p.state or 'no answer') .. ')'
end

function owner_is_up(nm)
    local t = ''
    pcall(function() t = tostring(mq.TLO.Spawn('pc =' .. nm).Type() or '') end)
    if t:upper() ~= 'PC' then return false end
    -- A PC spawn is not the same as a LIVE PC.
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

-- WHOSE CORPSE IS IT.
function corpse_owner_is(sp, name)
    local cn = ''
    pcall(function() cn = tostring(sp.CleanName() or '') end)
    if cn == '' then pcall(function() cn = tostring(sp.Name() or '') end) end
    local owner = cn:match("^(.-)['`]s corpse")
    return owner ~= nil and owner:lower() == tostring(name):lower()
end
-- Exact corpses for one owner: list of { id, dist }. Walks the substring matches and filters them.
function corpses_of(name)
    local out, n = {}, 0
    pcall(function() n = tonumber(mq.TLO.SpawnCount('pccorpse ' .. name)()) or 0 end)
    for i = 1, n do
        pcall(function()
            local sp = mq.TLO.NearestSpawn(string.format('%d, pccorpse %s', i, name))
            local sid = tonumber(sp.ID()) or 0
            if sid > 0 and corpse_owner_is(sp, name) then
                local d = tonumber(sp.Distance3D()) or tonumber(sp.Distance()) or 99999
                out[#out + 1] = { id = sid, dist = d }
            end
        end)
    end
    return out, n
end
function corpse_count_exact(name) return #(corpses_of(name)) end
function corpse_id_exact(name)
    local best = 0
    for _, c in ipairs(corpses_of(name)) do if c.id > best then best = c.id end end
    return best
end

local function rez_corpse(name)
    -- BACK TO HIGHEST ID, deliberately (see the history in git): spawn ids are identical on every client,
    -- so the election stays coherent even when the pick is stale. Exact owner only - see corpses_of.
    local list = corpses_of(name)
    local id, dist = 0, 99999
    for _, c in ipairs(list) do if c.id > id then id, dist = c.id, c.dist end end
    if #list > 1 and rezMultiWarn[name] ~= #list then
        rezMultiWarn[name] = #list
        log('[rez] %s has %d corpses here - taking id %d (highest; ids are consistent across clients)', name, #list, id)
    end
    return id, dist
end
-- THE SCAN'S CORPSE LOOKUP: the newest corpse that is NOT retired.
rezScanCache = {}   -- name:lower -> { n = corpse count, ids = { corpse ids seen } }
function rez_corpse_scan(name)
    local n = 0
    pcall(function() n = tonumber(mq.TLO.SpawnCount('pccorpse ' .. name)()) or 0 end)
    local key = name:lower()
    if n == 0 then rezScanCache[key] = nil; return 0, 99999 end
    -- n is the SUBSTRING count, so it also moves when a groupmate with a longer name dies - that only
    -- costs a rescan, never a wrong answer.
    local c = rezScanCache[key]
    if c and c.n == n then
        local open = false
        for _, cid in ipairs(c.ids) do if not rez_retired(cid) then open = true; break end end
        if not open then return 0, 99999 end
    end
    local best, bestDist, ids = 0, 99999, {}
    for _, cc in ipairs(corpses_of(name)) do
        ids[#ids + 1] = cc.id
        if not rez_retired(cc.id) and cc.id > best then best, bestDist = cc.id, cc.dist end
    end
    rezScanCache[key] = (#ids > 0) and { n = n, ids = ids } or nil
    return best, bestDist
end
local function rez_note(msg)
    table.insert(rezLog, 1, os.date('%H:%M:%S ') .. msg)
    while #rezLog > 5 do table.remove(rezLog) end
end

local function rezdbg(msg) if msg ~= rezDebugLast then rezDebugLast = msg; rezlog('[rez] ' .. msg) end; rezDebug = msg end

-- Take the rez ourselves.
function win_exists_raw(w)
    local v
    local ok = pcall(function() v = mq.TLO.Window(w).Name() end)
    if not ok or v == nil then return false end
    local sv = tostring(v)
    return sv ~= '' and sv:upper() ~= 'NULL'
end

function win_open_raw(w)
    local v
    local ok = pcall(function() v = mq.TLO.Window(w).Open() end)
    if not ok or v == nil then return false, 'nil' end
    if v == true or v == 1 then return true, tostring(v) end
    local sv = tostring(v):upper()
    return (sv == 'TRUE' or sv == '1'), tostring(v)
end

-- Identify the box by its TEXT, not by probing for a button.
local REZ_WINDOW = 'ConfirmationDialogBox'
-- ANY of these marks the box as a resurrection, rather than ALL of one phrasing.
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
        -- Nothing matched, but a confirmation box IS open while we are dead with a rez inbound.
        if not isRez and rezBoxAt == 0 and mq.gettime() < rezExpectUntil then
            rezlog('\\ay[rez] a dialog is open that I do not recognise as a rez: %s\\ax', txt:sub(1, 90))
        end
    end

    if not isRez then
        -- Alive with no corpse of my own? Then nothing is coming and the window should shut. Otherwise
        -- the warning kept repeating for the rest of its twenty seconds after the rez had landed.
        if now < rezExpectUntil then
            -- Reverted with the gate below on 2026-08-24; see the note there for why those three
            -- refusals were correct rather than missed rezzes.
            local iAmDead = true
            pcall(function() iAmDead = tlo_true(mq.TLO.Me.Dead()) end)
            if not iAmDead and rez_corpse(myName) == 0 then rezExpectUntil = 0 end
        end
        -- ...but not straight away.
        if now < rezExpectUntil and (now - rezIncAt) < 20000
           and (now - rezExpectFrom) > 6000 and (now - rezNoBoxWarn) > 4000 then
            rezNoBoxWarn = now
            rezlog('\\ay[rez] expecting a rez but no resurrection box is open\\ax')
        end
        if rezBoxAt > 0 then
            rezlog('[rez] rez box gone after %dms%s', now - rezBoxAt,
                   rezBoxClicked and ' (we clicked it)' or ' (NOT clicked by us)')
            -- ARM THE CORPSE WATCHER HERE TOO.
            if rezBoxClicked then
                corpseLootUntil = mq.gettime() + 60000
                rezlog('[corpse] rez accepted - watching for my corpse')
            end
            rezBoxAt, rezBoxClicked, rezBoxSeen = 0, false, false
            rezBoxRefused, rezBoxJudgeAt = false, 0
        end
        return
    end

    if rezBoxAt == 0 then
        rezBoxAt, rezBoxClicked, rezBoxSeen = now, false, false
        rezBoxRefused, rezBoxJudgeAt = false, 0
        rezlog('[rez] rez box OPEN: %s', txt:sub(1, 70))
        -- Announce the moment the box exists, whether or not WE click it.
        rezDone[myName:lower()] = now + 15000
        local cidNow = ((now - rezIncAt) < 30000 and rezCorpseID) or 0
        pcall(function() peer_bcast('/at_rezdone %s %d', myName, cidNow) end)
    end
    if rezBoxSeen or not rezAccept then return end
    if rezBoxRefused and now < rezBoxJudgeAt then return end

    -- ONE MORE GATE BEFORE CLICKING YES.
    local canBeRezzed, why = false, ''
    pcall(function() canBeRezzed = tlo_true(mq.TLO.Me.Dead()) end)
    if canBeRezzed then why = 'dead' end
    if not canBeRezzed and rez_corpse(myName) > 0 then canBeRezzed, why = true, 'my corpse is here' end
    if not canBeRezzed and rezOwedAt > 0 and (now - rezOwedAt) < REZ_OWED_MS then
        canBeRezzed, why = true, string.format('died %ds ago, not rezzed yet', math.floor((now - rezOwedAt) / 1000))
    end
    if not canBeRezzed and rezIncFrom ~= '' and (now - rezIncAt) < 30000 then
        local caster = txt:match('^%s*(%S+)') or ''
        if caster:lower() == rezIncFrom:lower() then
            canBeRezzed, why = true, rezIncFrom .. ' told me it was rezzing me'
        end
    end
    if not canBeRezzed then
        -- NOT FINAL.
        if not rezBoxRefused then
            rezlog('\\ay[rez] a dialog looks like a rez but I am alive with no corpse - not clicking it yet: %s\\ax',
                   txt:sub(1, 80))
        end
        rezBoxRefused, rezBoxJudgeAt = true, now + 250
        return
    end
    if rezBoxRefused then rezlog('[rez] box re-judged after %dms: %s', now - rezBoxAt, why) end

    -- Try each button name; the first that makes the window go away was the right one.
    for _, b in ipairs(REZ_BUTTONS) do
        -- /nomodkey, as E3 does.
        pcall(function() mq.cmdf('/nomodkey /notify %s %s leftmouseup', REZ_WINDOW, b) end)
        mq.delay(60)
        if not mq.TLO.Window(REZ_WINDOW).Open() then
            rezBoxClicked, rezBoxSeen = true, true
            rezExpectUntil = 0
            rezOwedAt = 0
            rezlog('[rez] accepted with %s, %dms after the box opened (%s)', b, now - rezBoxAt, why)
            return
        end
    end
    rezlog('\\ay[rez] rez box is open but none of the buttons closed it: %s\\ax', table.concat(REZ_BUTTONS, ', '))
    -- SEEN, not clicked. Every button was tried and the window is still open, so nothing was accepted -
    -- claiming otherwise would arm the corpse watcher for a rez that never happened.
    rezBoxSeen = true      -- do not hammer it every tick
end

-- Tell the group I am up the INSTANT I release, instead of waiting for a rezzer to ask.
local function rez_announce_ready()
    local dead, zoning = false, false
    pcall(function() dead = tlo_true(mq.TLO.Me.Dead()) end)
    pcall(function() zoning = tlo_true(mq.TLO.Me.Zoning()) end)
    if zoning then return end
    if rezWasDead and not dead then          -- just got back up
        rezWasDead = false
        -- LOOT MY OWN CORPSE.
        corpseLootUntil = mq.gettime() + 60000
        rezExpectFrom  = mq.gettime()
        rezExpectUntil = mq.gettime() + 15000
        -- Two '/at_rezrdy!' broadcasts used to go from here - one now, one 1.2s later against loss - to
        -- tell rezzers I had released, so they could skip the bind handshake.
    elseif dead then
        rezWasDead = true
        if rezOwedAt == 0 then rezOwedAt = mq.gettime() end
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
        if not iDead and rezOwedAt > 0 and rezOwedAt >= (rezCast.at or 0) then iDead = true end
        if iDead then   -- died mid-rez: release my claim and skip the slot I was casting so the next slot takes over NOW
            rezPending[rezCast.id] = nil
            peer_bcast('/at_rezunclaim %d %s', rezCast.id, myName)
            local ck = rezCast.kind or 'crown'   -- recorded at fire time; inferring it from the item name cannot see 'cotw'
            local key = myName:lower() .. ':' .. ck
            rezSkip[rezCast.id] = rezSkip[rezCast.id] or {}; rezSkip[rezCast.id][key] = now + 8000
            peer_bcast('/at_rezskip %s %d', key, rezCast.id)
            rezlog('[rez] died mid-cast; skip %s for %d', key, rezCast.id)
            rezCast = nil; return
        end
        -- SUCCESS = the corpse cleared (target accepted). Asked of the corpse itself by id: rez_corpse picks
        -- the owner's highest id, which is not this one when an older corpse with a higher id is lying there.
        local ctype = ''
        pcall(function() ctype = tostring(mq.TLO.Spawn(rezCast.id).Type() or '') end)
        if ctype ~= 'Corpse' then rezCast = nil; return end
        -- IT WENT OFF - SAY SO NOW, NOT WHEN WE STOP CASTING.
        if (now - rezCast.fired) > 500 and rez_kind_secs(rezCast.kind) ~= 0 then
            local castingName = ''
            pcall(function() castingName = tostring(mq.TLO.Me.Casting.Name() or '') end)
            if castingName:lower() ~= tostring(rezCast.item):lower() then
                rez_retire(rezCast.id, 'my ' .. (rezCast.kind or 'rez') .. ' landed')
                peer_bcast('/at_rezretire %d', rezCast.id)
                pcall(function() mq.cmdf('/say Rezzed %s (corpse %d)', rezCast.name, rezCast.id) end)
                rez_verify_arm(rezCast.id, rezCast.name)
                rezCast = nil
                return
            end
        end
        -- SOMEBODY ELSE ALREADY GOT IT.
        if (now - rezCast.fired) > 1000 and rez_retired(rezCast.id) and rez_kind_secs(rezCast.kind) == 0 then
            rezlog('[rez] corpse %d was retired while my cast was out - standing down', rezCast.id)
            rezCast = nil; return
        end
        local casting = false
        pcall(function() casting = (tonumber(mq.TLO.Me.Casting.ID()) or 0) > 0 end)
        -- A rez cast is seconds long. Past REZ_INFLIGHT_MAX whatever we are casting is not it - stop
        -- treating it as our rez and let the landed / retry checks below decide.
        if casting and (now - rezCast.fired) > REZ_INFLIGHT_MAX then casting = false end
        if casting then
            if (now - (rezGateAt[rezCast.id] or 0)) > 900 then
                rezGateAt[rezCast.id] = now
                rezdbg(string.format('cast in flight on %s, still casting', rezCast.name))
            end
            -- THE RETRY CLOCK RUNS FROM WHEN THE CAST ENDS, NOT FROM WHEN IT WAS FIRED.
            rezCast.at = now
            return
        end
        -- PER KIND, because these are not the same cast.
        local gap = (rezCast.kind == 'cotw') and 6000 or 1500
        if (now - rezCast.at) < gap then return end
        -- SOMEBODY ELSE'S REZ ON THIS BODY LANDED FIRST (their shout, or the owner took a box) and mine
        -- never went off - my clicky is still ready.
        if rez_retired(rezCast.id) and rez_kind_secs(rezCast.kind) == 0 then
            rezlog('[rez] corpse %d was retired while my cast was out - standing down', rezCast.id)
            rezCast = nil; return
        end
        -- E3 CUT IT FOR AN EMERGENCY HEAL.
        if rezCast.queued and rezCast.cutAt and rez_kind_secs(rezCast.kind) == 0
           and (now - rezCast.fired) < REZ_QUEUE_WAIT then
            if (now - (rezCast.claimAt or 0)) > 5000 then
                rezCast.claimAt = now
                rezdbg(string.format('E3 cut my rez on %s for a heal - waiting on the queued cast (%ds of %ds)',
                       rezCast.name, math.floor((now - rezCast.fired) / 1000), REZ_QUEUE_WAIT / 1000))
            end
            return
        end
        -- IT WENT OFF: the clicky is on cooldown. Retire the body everywhere and say so - part two of the
        -- shout, parsed by at_rez_say_done.
        if rez_kind_secs(rezCast.kind) ~= 0 then
            rez_retire(rezCast.id, 'my ' .. (rezCast.kind or 'rez') .. ' landed')
            peer_bcast('/at_rezretire %d', rezCast.id)
            pcall(function() mq.cmdf('/say Rezzed %s (corpse %d)', rezCast.name, rezCast.id) end)
            rez_verify_arm(rezCast.id, rezCast.name)
            rezCast = nil
            return
        end
        -- One attempt when we were already beyond reach, three when we were not. A cast that failed on
        -- range will fail again from the same spot, so grinding out three of them just holds the baton.
        local maxTries = rezCast.far and 1 or 3
        if rez_kind_secs(rezCast.kind) == 0 and rezCast.tries < maxTries then   -- clicky still ready => it did not go off
            rezCast.tries = rezCast.tries + 1; rezCast.at = now
            rezlog('[rez] retry %d /nowcast me "%s%s" %d',
                   rezCast.tries, rezCast.item, rez_opts(rezCast.kind, rezCast.item), rezCast.id)
            -- SUMMON AGAIN on the retry.
            pcall(function() mq.cmdf('/target id %d', rezCast.id) end)
            mq.delay(400, function() return (tonumber(mq.TLO.Target.ID()) or 0) == rezCast.id end)
            if (tonumber(mq.TLO.Target.ID()) or 0) == rezCast.id then
                pcall(function() mq.cmd('/corpse') end)
                mq.delay(250)
            end
            -- A retry is MORE exposed than the first attempt: seconds have passed and a loot window, a
            -- summoned item or a trade has had time to put something on the cursor since.
            if not cursor_stow('rez') then
                rezlog('\\ay[rez] cursor will not clear - retrying anyway rather than lose the rez\\ax')
            end
            at_cast(rezCast.item .. rez_opts(rezCast.kind, rezCast.item), rezCast.id)
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
            -- WHAT THE WORLD LOOKED LIKE WHEN IT FAILED.
            local dNow, tgtOK, casting, myState = -1, 0, 0, '?'
            pcall(function() dNow    = tonumber(mq.TLO.Spawn(rezCast.id).Distance()) or -1 end)
            pcall(function() tgtOK   = tonumber(mq.TLO.Target.ID()) or 0 end)
            pcall(function() casting = tonumber(mq.TLO.Me.Casting.ID()) or 0 end)
            pcall(function() myState = tostring(mq.TLO.Me.State() or '?') end)
            rezlog('[rez] %s did not land on %s - passing to the next slot', rezCast.item, rezCast.name)
            rezlog('[rez]   at failure: corpse %d @%dm, my target=%d, casting=%d, state=%s, reach %d',
                   rezCast.id, dNow, tgtOK, casting, myState, rez_range())
        end
        rezCast = nil   -- done; if the corpse is still there the picker re-handshakes and tries again
        return
    end

    -- 1) TARGET: highest-priority toon with a CORPSE in my zone, owner still connected, reachable.
    local tgtName, tgtID, skipped, tgtFar, tgtDist = nil, nil, {}, false, -1
    -- NOTHING TO SWEEP IF THE ZONE HAS NO CORPSES.
    if not rez_event_now() then return end
    local myZone0 = 0; pcall(function() myZone0 = tonumber(mq.TLO.Zone.ID()) or 0 end)
    for _, nm in ipairs(rezPriority) do
        local id, dist = rez_corpse_scan(nm)
        if id > 0 then
            local rr = rezReady[nm]
            -- ONE QUESTION: is this person alive?
            local seen, alive = owner_seen(nm)
            local ownerHereAlive = (seen and alive) or false
            local rezPend = rezDone[nm:lower()] and now < rezDone[nm:lower()]   -- owner already has a rez inbound
            if rez_retired(id) then
                rezPend = true
                skipped[#skipped + 1] = nm .. ': already rezzed (corpse ' .. id .. ' retired)'
            end
            local claimed = rezPending[id] and now < rezPending[id]             -- another rezzer called it
            if ownerHereAlive then
                skipped[#skipped + 1] = nm .. ': owner is already up'
                -- AND RETIRE IT.
                if not rez_retired(id) then rez_retire(id, nm .. ' is up in zone') end
            elseif rezPend then
                skipped[#skipped + 1] = nm .. ': rez already inbound'
            elseif claimed then
                skipped[#skipped + 1] = string.format('%s: claimed by another rezzer (%dm away)', nm, math.floor(dist))
            elseif dist <= REZ_MAX_DIST and not rez_owner_ready(nm) then
                local _, why = rez_owner_ready(nm)
                skipped[#skipped + 1] = nm .. ': ' .. (why or 'not ready')
            elseif dist > REZ_MAX_DIST then
                -- Beyond arguing with.
                skipped[#skipped + 1] = string.format('%s: too far, %dm (limit %d)', nm, math.floor(dist), REZ_MAX_DIST)
            else
                tgtName, tgtID, tgtFar, tgtDist = nm, id, (dist > rez_range()), math.floor(dist)
                break
            end
        end
    end

    -- RAID, only once the group is clear.
    local tgtRaid = false
    -- Either clicky counts for the classes allowed to use a crown on a raid target; everyone else
    -- still needs a ready token before the pass is even worth running.
    local raidClickyReady = (my_rez_secs(TOKEN_ITEM) == 0)
                            or (raid_crown_ok() and my_rez_secs(CROWN_ITEM) == 0)
                            -- a shaman with both clickies spent but CotW up is still worth the sweep
                            or (rezCotw and my_cotw_secs() == 0)
    -- The TANK sits out raid rezzes entirely - not "scans then declines", does not look at all.
    local iAmTank = (rez_rank(member_class(myName)) == 1)
    if RAID_REZ and not iAmTank and not tgtID and raidClickyReady
       and (now - lastRaidScan) > 1000
       and (now - lastRaidToken) > RAID_TOKEN_GAP then
        lastRaidScan = now
        for _, nm in ipairs(raid_outsiders()) do
            local id, dist = rez_corpse_scan(nm)
            if id > 0 and owner_is_up(nm) and not rez_retired(id) then
                rez_retire(id, nm .. ' is up in zone')
            end
            if id > 0 and dist <= RAID_MAX_DIST then
                -- They are not running AdventureTime, so nothing announces on their behalf: no
                -- /at_rezdone, no corpse retirement.
                local offered = raidOffered[id] and (now - raidOffered[id]) < RAID_OFFER_GAP
                if not offered and not owner_is_up(nm)
                   and not (rezPending[id] and now < rezPending[id]) and not rez_retired(id) then
                    tgtName, tgtID, tgtFar, tgtDist, tgtRaid = nm, id, false, math.floor(dist), true
                    break
                end
            end
        end
    end
    if not tgtID then
        -- No out-of-range skip any more.
        if rezIdleAt == 0 then rezIdleAt = mq.gettime() end
        if #skipped == 0 then rezdbg('no corpses in zone')
        else rezdbg('nothing to rez | ' .. table.concat(skipped, ' | ')) end
        return
    end
    -- Something IS actionable, so the lane is wanted.
    rezIdleAt = 0

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

    -- THE TANK HOLDS while anybody else could do it.
    if tgtRaid and chain_mode(myName) ~= 'raid' then
        -- SAY SO, once per corpse.
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
                -- CotW BELONGS IN THIS LIST.
                local pd = peer_dist_to_corpse(nm, tgtID)
                if rr and (rr.zone or 0) == myZone and rr.zone > 0
                   and pd and pd <= REZ_MAX_DIST
                   and ((rez_peer_secs(rr, 'token') == 0) or (rez_peer_secs(rr, 'crown') == 0)
                        or (rezCotw and rez_peer_secs(rr, 'cotw') == 0)) then
                    other = nm; break
                end
            end
        end
        -- THE HOLD HAS A CEILING.
        local waitedT = now - (rezFirstSeen[tgtID] or now)
        if other and waitedT < REZ_TANK_HOLD then
            rezdbg(string.format('target %s(%d): I am the tank and %s is up in-zone with a clicky - holding',
                                 tgtName, tgtID, other))
            return
        end
        if other then
            rezdbg(string.format('target %s(%d): held %ds for %s and nobody claimed - taking it myself',
                                 tgtName, tgtID, math.floor(waitedT / 1000), other))
        end
    end

    -- Respect my OWN skip.
    do
        local mine = rezSkip[tgtID] and rezSkip[tgtID][myName:lower() .. ':' .. myClicky]
        if mine and now < mine then
            rezdbg(string.format('target %s(%d): I passed on this one, waiting %dms', tgtName, tgtID, mine - now))
            return
        end
    end

    -- LOCAL ELECTION.
    local cleared, blocker = true, nil
    for pos = 1, myPos - 1 do
        local sl = chain[pos]
        local owner, clicky = sl.name, sl.clicky
        if owner:lower() ~= tgtName:lower() and owner:lower() ~= myName:lower() then
            local key = owner:lower() .. ':' .. clicky
            local sk = rezSkip[tgtID] and rezSkip[tgtID][key]
            local skipped = sk and now < sk
            local rr = rezReady[owner]
            -- NO REPORT MEANS DO NOT WAIT ON THEM.
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
        -- BACKSTOP, GATED ON THE CLAIM.
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
    -- put on someone else's character.
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
    -- CLAIM ONCE, not every tick.
    if not (rezClaimAt[tgtID] and (now - rezClaimAt[tgtID]) < 2500) then
        rezClaimAt[tgtID] = now
        peer_bcast('/at_rezclaim %d %d', tgtID, 5000)   -- pre-cast: short, I may yet hand it back
    end

    -- HANDSHAKE: don't cast until the target has zoned to its bind and settled (a too-early rez is wasted).
    -- Ping the target; it pongs only when at bind (valid zone, different from mine, not zoning). No pong -> keep waiting.
    local tkey = tgtName:lower()
    -- The rez HEARTBEAT already answers this.
    local trr = rezReady[tgtName]
    local upFromBeat = trr and trr.alive and (trr.zone or 0) > 0 and trr.zone ~= myZone
                       and (now - (trr.updated or 0)) < 30000
    if upFromBeat then rezConfirm[tkey] = now end

    -- 5s, not 2.5s.
    if tgtRaid then rezConfirm[tkey] = now end
    -- And skip it for anyone we can SEE is dead.
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
        -- LET GO after 1500ms, not 3000.
        if (now - rezWaitFrom[tkey]) > 1500 then
            rezWaitFrom[tkey] = nil
            rezPending[tgtID] = nil
            rezClaimAt[tgtID] = nil
            rezFireAt[tgtID]  = nil   -- fresh jitter on the retry; the old one is spent
            -- 750ms, not 2000.
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

    -- Past the handshake and still not casting?
    local function blocked(why)
        if (now - (rezGateAt[tgtID] or 0)) > 900 then
            rezGateAt[tgtID] = now
            rezdbg(string.format('target %s(%d): ready to fire but %s', tgtName, tgtID, why))
        end
    end
    -- anti-race jitter: stagger toons by a small random delay so two don't fire in the same tick.
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
    -- Tell the TARGET a rez is on its way.
    if tgtRaid then
        raidOffered[tgtID] = now
        lastRaidToken = now
        -- NOT RETIRED AT FIRE ANY MORE (1.19.63).
        rezlog('[rez] RAID token on %s @%dm (not in my group)', tgtName, tgtDist)
    end
    -- SEND THE CORPSE ID, not just who is casting.
    pcall(function() peer_cmdf(tgtName, '/at_rezinc %s %d', myName, tgtID) end)
    -- PULL THE CORPSE FIRST.
    local dBefore = tgtDist
    pcall(function() dBefore = tonumber(mq.TLO.Spawn(tgtID).Distance()) or tgtDist end)
    pcall(function() mq.cmd('/corpse') end)
    mq.delay(250)
    local dAfter = dBefore
    pcall(function() dAfter = tonumber(mq.TLO.Spawn(tgtID).Distance()) or dBefore end)
    if math.abs(dBefore - dAfter) >= 1 then
        rezlog('[rez] /corpse pulled %s from %dm to %dm', tgtName, dBefore, dAfter)
    elseif dAfter <= CORPSE_NEAR then
        -- ALREADY AT HAND.
        rezlog('[rez] %s is already at hand (%dm) - no drag needed', tgtName, dAfter)
    else
        rezlog('[rez] /corpse did nothing on %s (still %dm) - out of drag range, or no consent', tgtName, dAfter)
    end
    -- NOTHING ON THE CURSOR BEFORE A CLICK.
    do
        local ok, held = cursor_stow('rez')
        if not ok then
            rezlog('\\ay[rez] %s is stuck on the cursor (bags full?) - firing anyway rather than lose the rez\\ax',
                   tostring(held or '?'))
        end
    end
    -- Log the string we ACTUALLY hand E3, options and all.
    local opts = rez_opts(myClicky, item)
    local sent = at_cast(item .. opts, tgtID)
    -- QUEUECAST BEHIND IT.
    local queued = REZ_QUEUECAST and at_queuecast(item .. opts, tgtID) or nil
    rezlog('[rez] FIRING %s%s [spec "%s%s" %d] (target %s @%dm, reach %d)',
           tostring(sent or 'NOTHING'), queued and ' + queuecast' or '', item, opts, tgtID, tgtName, tgtDist, rez_range())
    -- PART ONE OF THE SHOUT. /say, not /gsay, so other AdventureTime groups in earshot hold off this corpse
    -- too. The wording is parsed by at_rez_say_cast - change both together.
    pcall(function() mq.cmdf('/say Rezzing %s (corpse %d)', tgtName, tgtID) end)
    lastRezFire = now
    -- kind is carried so the retry and died-mid-cast paths know which timer proves the cast went off
    rezCast = { id = tgtID, item = item, kind = myClicky, at = now, tries = 1, name = tgtName, far = tgtFar,
                raid = tgtRaid, fired = now, queued = (queued ~= nil), claimAt = now }
    -- 15s, not 4s.
    rezPending[tgtID] = now + REZ_SAY_HOLD
    peer_bcast('/at_rezclaim %d %d', tgtID, REZ_SAY_HOLD)   -- CAST IS OUT: same window the /say claim gives everyone else
    -- AND RETIRE IT ACROSS THE GROUP when it is a raid corpse.
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
    -- /atrezclear [id] - un-retire one corpse id, or all of them. For the rare box nobody took: a retired
    -- body is skipped for REZ_RETIRE_MS, and this is the way to rez it again sooner. Group-wide.
    mq.bind('/atrezclear', function(id)
        local n = tonumber(id)
        rez_retire_clear(n)
        pcall(function() peer_bcast('/at_rezclear %s', n and tostring(n) or 'all') end)
        log('[rez] cleared %s from the retired list on the group', n and ('corpse ' .. n) or 'every corpse')
    end)
    mq.bind('/at_rezclear', function(id) rez_retire_clear(tonumber(id)) end)
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
    -- The announce toggle has to REACH THE HEALERS.
    mq.bind('/at_xtsay', function(mode)
        xtankAnnounce = (mode == 'on')
        rezlog('[xtank] raid announce %s (from the driver)', mode or '?')
    end)
    -- CLASS RIDES ALONG.
    mq.bind('/at_coth', function(name, em, dist, los, here, cls)
        if name then
            COTH.state[name] = { emblem = tonumber(em) or -1, dist = tonumber(dist) or -1,
                                 los = tonumber(los) or 0, here = tonumber(here),
                                 class = (cls and cls ~= '' and cls ~= '?') and cls:upper() or nil,
                                 updated = mq.gettime() }
        end
    end)
    -- THE ANCHOR POINT.
    -- /atburncheck <burn name> | off (1.21.3): an extra line on the burn hotkey, after /e3burns. The items of that
    -- burn that are ready right now are listed under Running now until each one fires. Nothing is sent to E3.
    mq.bind('/atburncheck', function(...)
        local name = table.concat({...}, ' '):match('^%s*(.-)%s*$')
        if not SHOW_UI then
            if driverName then pcall(function() peer_cmdf(driverName, '/atburncheck %s', name) end) end
            return
        end
        if name == '' then log('/atburncheck <burn name> (as in your E3 [Burn] section) | /atburncheck off'); return end
        if name:lower() == 'off' then burncheck_stop('cleared'); return end
        burncheck_start(name)
    end)
    mq.bind('/atcoth', function(arg)
        local a = arg and tostring(arg):lower() or ''
        -- /atcoth group - I am the only summoner and the rest of the group are other people's characters,
        -- so there is nothing to talk to. Deliberately separate from the peer gather below.
        if a == 'group' then cothgSetWanted = 'on'; return end
        if a == 'groupoff' then cothgSetWanted = 'off'; return end
        local off = arg and tostring(arg):lower() == 'off'
        if COTHG.active and off then cothgSetWanted = 'off'; return end
        -- coth_set broadcasts, and peer_bcast can wait on channel detection - so the bind records and the
        -- tick acts, the same as the buttons.
        cothSetWanted = off and 'off' or 'on'
        log('[coth] %s', off and 'stopping the gather' or 'starting a gather here')
    end)
    -- FIRE THE COMBO ON A TIMER AND MEASURE IT.
    mq.bind('/atinvistest', function(mins, gapSecs)
        if mins and tostring(mins):lower() == 'off' then invistest_report(); INVT.on = false; return end
        local m = tonumber(mins) or 10
        local g = math.max(10, tonumber(gapSecs) or 15)
        INVT.on, INVT.n, INVT.total, INVT.best, INVT.worst = true, 0, 0, nil, nil
        INVT.bucket, INVT.seen = {}, {}
        INVT.covered, INVT.partial, INVT.checkAt, INVT.worstMiss = 0, 0, nil, nil
        INVT.until_, INVT.every, INVT.nextAt = mq.gettime() + m*60000, g*1000, mq.gettime() + 1000
        log('\\ag[invistest] running for %d min, a press every %ds - /atinvistest off to stop\\ax', m, g)
    end)
        mq.bind('/atcothwho', function(scope)
        if scope and tostring(scope):lower() == 'all' then
            pcall(function() peer_bcast('/atcothwho') end)
        end
        local x, y, z = 0, 0, 0
        pcall(function() x = tonumber(mq.TLO.Me.X()) or 0 end)
        pcall(function() y = tonumber(mq.TLO.Me.Y()) or 0 end)
        pcall(function() z = tonumber(mq.TLO.Me.Z()) or 0 end)
        local a = COTH.at
        local em = coth_emblem()
        local line = string.format('CoTH %s: at %d,%d,%d | %d from anchor | los=%d | here=%s | emblem=%s',
            myName, x, y, z, coth_dist_to_anchor(), coth_los(),
            coth_here() and 'YES' or 'no',
            (em < 0) and 'none' or ((em == 0) and 'ready' or (em .. 's')))
        pcall(function() mq.cmdf('/gsay %s', line) end)
        log('[coth] %s', line)
        if a then
            log('[coth]   anchor %d,%d,%d zone %d set by %s', a.x, a.y, a.z, a.zone or 0, a.by or '?')
        else
            log('[coth]   no anchor set')
        end
        -- And what I believe about everyone else, which is what the queue is actually built from.
        for _, nm in ipairs(group_members()) do
            if nm:lower() ~= myName:lower() then
                local st = COTH.state[nm]
                if st then
                    log('[coth]   %-10s dist=%-5s los=%-2s here=%-4s emblem=%-5s %s%s',
                        nm, tostring(st.dist), tostring(st.los), tostring(st.here), tostring(st.emblem),
                        COTH.grey[nm] and 'GREY ' or '',
                        (COTH.skip[nm] and mq.gettime() < COTH.skip[nm]) and 'SKIPPED' or '')
                else
                    log('[coth]   %-10s no report', nm)
                end
            end
        end
    end)
    -- Somebody has agreed a target with them. Leave that one alone; they are handling it.
    mq.bind('/at_cothmine', function(tgt)
        if tgt and tgt:lower() ~= myName:lower() then
            COTH.skip[tgt] = mq.gettime() + COTH_SKIP_BUSY
        end
    end)
    mq.bind('/at_cothat', function(x, y, z, zn, by)
        COTH.at = { x = tonumber(x) or 0, y = tonumber(y) or 0,
                    z = tonumber(z) or 0, zone = tonumber(zn) or 0, by = by }
    end)
    -- I AM BEING SUMMONED. Record where I am RIGHT NOW; arrival is this position changing.
    mq.bind('/at_cothwatch', function(who)
        if not who or who == '' then return end
        -- Already being summoned by somebody else? Say no rather than letting two emblems go. The slice
        -- should prevent this; a character that became a summoner a moment ago can still race it.
        if COTHW and COTHW.by ~= who then
            -- Already being summoned by somebody else.
            pcall(function() peer_cmdf(who, '/at_cothhere %s no busy', myName) end)
            return
        end
        local x, y, z = 0, 0, 0
        pcall(function() x = tonumber(mq.TLO.Me.X()) or 0 end)
        pcall(function() y = tonumber(mq.TLO.Me.Y()) or 0 end)
        pcall(function() z = tonumber(mq.TLO.Me.Z()) or 0 end)
        COTHW = { by = who, at = mq.gettime(), x = x, y = y, z = z, cast = false, castAt = 0 }
        rezlog('[coth] %s is summoning me - watching my own position', who)
    end)
    -- Their cast has landed. Only now does not-having-moved mean anything.
    mq.bind('/at_cothcast', function(who)
        if who and COTHW and COTHW.by == who then
            COTHW.cast, COTHW.castAt = true, mq.gettime()
        end
    end)
    -- THE ONLY TWO ANSWERS, both from the character that was summoned.
    mq.bind('/at_cotharrived', function(who)
        if not who then return end
        -- BELIEVE THEM IMMEDIATELY.
        if COTH.state[who] then
            COTH.state[who].here = 1
            COTH.state[who].updated = mq.gettime()
        else
            COTH.state[who] = { emblem = -1, dist = 0, here = 1, updated = mq.gettime() }
        end
        COTH.grey[who] = nil          -- settled: they really are here
        if COTH.pending and COTH.pending.name == who then
            rezlog('[coth] %s arrived', who)
            COTH.pending = nil
        end
    end)
    mq.bind('/at_cothhere', function(who, verdict, why)
        if not who or verdict == 'yes' then return end
        if COTH.pending and COTH.pending.name == who then
            -- STAND OFF THIS ONE FOR A MOMENT.
            local secs = (why == 'busy') and COTH_SKIP_BUSY or COTH_SKIP_FAIL
            COTH.skip[who] = mq.gettime() + secs
            COTH.grey[who] = nil          -- settled the other way: they did not move, back in the queue
            rezlog('[coth] %s says no (%s) - leaving them for %.0fs', who, why or '?', secs / 1000)
            COTH.pending = nil
        end
    end)
    mq.bind('/at_cothgo', function(mode)
        COTH.active, COTH.pending, COTH.startedAt = (mode == 'on'), nil, mq.gettime()
        COTHW = nil        -- not being summoned any more either
        -- Distances were measured against the previous anchor point and mean nothing now. The new one
        -- arrives in /at_cothat, and until it does everyone reports -1 and nobody is judged 'away'.
        COTH.state = {}
        if mode ~= 'on' then COTH.at = nil end
        -- THE SAME PER-GATHER RESET THE STARTER DOES.
        if mode == 'on' then
            COTH.saidDone, COTH.saidWait, COTH.saidRank = nil, nil, nil
            COTH.swapped, COTH.saidWaitSwap, COTH.saidSwapDone = {}, nil, nil
            COTH.mine, COTH.saidScarce = 0, nil
            COTH.skip, COTH.grey = {}, {}
        end
        -- THE CHARM RIDES THE GATHER, both ends.
        if mode == 'on' then
            cothSwapWant = { auto = true }
        else
            cothSwapWant = { back = true, auto = true }
        end
    end)
    mq.bind('/at_cothswapset', function(mode)
        cothSwap = (mode == 'on')
        save_settings()
    end)
    -- Who has finished swapping. Collected by whoever is driving, so it knows when to start summoning.
    mq.bind('/at_cothswapped', function(who, state)
        if not who then return end
        COTH.swapped = COTH.swapped or {}
        COTH.swapped[who] = state or 'ok'
    end)
    mq.bind('/at_di', function(name, staff, em, dg, save, sname)
        if name then
            local nm = (sname and sname ~= '' and sname ~= '-') and sname:gsub('_', ' ') or nil
            DI.state[name] = { staff = tonumber(staff) or -1, emeralds = tonumber(em) or 0,
                               dgReady = tonumber(dg) or 0, saveUp = tonumber(save) or 0,
                               saveName = nm, updated = mq.gettime() }
        end
    end)
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
    -- Kept so a peer still on an older build does not error, but it will NOT throw away work in
    -- progress.
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
    -- SNAPSHOT HERE TOO.
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
    mq.bind('/atpac', function()
        -- CLEAR THE CACHE AND THE BACKOFF.
        epBestPlacate, epBestMissAt, epBestMissN = nil, 0, 0
        if not pac_announce() then log('[pacify] I have no pacify spell') end
    end)
    mq.bind('/at_paccap', function(who, cap, rng, kind)
        if not who or who == '' then return end
        pacCap[who] = { cap = tonumber(cap) or 0, range = tonumber(rng) or 0,
                        kind = kind or '?', updated = mq.gettime() }
    end)
    -- /at_epcaster is gone with the election.
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
    -- IS IT AN ITEM OR A CURRENCY?
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
        -- Stamp the report.
        counts[who:lower()].__altAt = mq.gettime()
        statusCounts[who:lower()] = counts[who:lower()]
    end)
    mq.bind('/at_altbal', function(who, nm, v)
        if not who or not nm then return end
        local name = nm:gsub('_', ' ')
        altCounts[who:lower()] = altCounts[who:lower()] or {}
        local n = tonumber(v)
        -- THREE OUTCOMES, not two.
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
        altcur_close_if(wasOpen)
    end)
    -- No quantity argument: Reclaim converts every stack of the item in one press.
    mq.bind('/atreclaim', function(a)
        local nm = (a and a ~= '') and a:gsub('_', ' ') or 'Diamond Coin'
        altReclaimWant = { name = nm }
    end)
    -- WHAT DOES THIS CLIENT ACTUALLY CALL AN AUG?
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
                -- tlo_true, NOT a raw string compare.
                pcall(function() ben = tlo_true(mq.TLO.Spell(gn).Beneficial()) end)
                if rr > 0 then
                    log('     gem %-2d %-26s %-5s Range %-5s MyRange %-5s %s', g, gn:sub(1, 26),
                        ben and 'ben' or 'DET', tostring(rr), tostring(mr),
                        (mr > rr) and string.format('= %.2fx', mr / rr) or '')
                end
            end
        end
    end)
    -- One command, because there is one thing left to ask.
    mq.bind('/atburnaudit', function()
        -- Total reuse, in seconds, by whichever kind of thing this is.
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
    mq.bind('/at_iconq', function(asker, enc)
        if not asker or not enc or SHOW_UI then return end
        local nm, id, kind = icon_dec(enc), 0, 'item'
        pcall(function() id = tonumber(mq.TLO.FindItem('=' .. nm).Icon()) or 0 end)
        if id <= 0 then
            kind, id = 'spell', -1
            pcall(function() id = tonumber(mq.TLO.Me.AltAbility(nm).Spell.SpellIcon()) or -1 end)
            if id < 0 then
                local sid = 0
                pcall(function() sid = tonumber(mq.TLO.Spell(nm).ID()) or 0 end)
                if sid > 0 then pcall(function() id = tonumber(mq.TLO.Spell(nm).SpellIcon()) or -1 end) end
            end
        end
        if (kind == 'item' and id > 0) or (kind == 'spell' and id >= 0) then
            pcall(function() peer_cmdf(asker, '/at_icon %s %d %s', enc, id, kind) end)
        end
    end)
    mq.bind('/at_icon', function(enc, id, kind)
        id = tonumber(id)
        kind = (kind == 'spell') and 'spell' or 'item'
        if not enc or not id or id < 0 or (kind == 'item' and id <= 0) then return end
        local nm = icon_dec(enc)
        if ICON.cache[nm] then return end
        ICON.cache[nm] = { kind = kind, id = id }
        pcall(icon_save)
    end)
    mq.bind('/at_turbo', function(char, v)
        v = tonumber(v)
        if not char or not v or not SHOW_UI then return end
        turboState[char] = v
        if (AT_TURBO or -1) >= AT_TURBO_FAST and v < AT_TURBO_FAST then
            log('[perf] %s is at turbo %d - Fast mode is on, raising it to %d', char, v, AT_TURBO_FAST)
            pcall(function() peer_cmdf(char, '/lua conf turboNum %d', AT_TURBO_FAST) end)
        end
    end)
    -- INDEXES, NOT NAMES.
    mq.bind('/at_nvstate', function(char, list)
        if not char then return end
        local items, ups = {}, {}
        for pair in tostring(list or ''):gmatch('[^,]+') do
            -- i:cooldown, plus :effect-left from 1.20.39 on
            local i2, s, u = pair:match('^(%d+):(-?%d+):?(%d*)$')
            if i2 then items[tonumber(i2)] = tonumber(s); ups[tonumber(i2)] = tonumber(u) or 0 end
        end
        nvState[char] = { items = items, ups = ups, updated = mq.gettime() }
    end)
    -- Click mine.
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
        -- NOWCAST + QUEUECAST, same as the rez.
        local sent   = at_cast(e.item .. NIGHTVEIL_OPTS)
        local queued = at_queuecast(e.item .. NIGHTVEIL_OPTS)
        -- PROOF IT WENT OFF: the item's cooldown starts. Returns the moment it does, so a click that
        -- lands costs no more than before; 2.5s at most so a dropped one cannot stall the loop.
        mq.delay(2500, function() return nv_secs_at(i2) > 0 end)
        local after = nv_secs_at(i2)
        if after > 0 then
            log('[nv] used %s (%s) - cooldown now %s', e.item, e.role, nv_hms(after))
        else
            log('\\ay[nv] %s did not go off within 2.5s (%s)%s\\ax', e.item, tostring(sent or 'nothing sent'),
                queued and ' - the queued cast will fire when E3 is free' or ' - click it again')
        end
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
            -- BY NAME, not by id.
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
    -- DROP INVIS ON THIS CHARACTER.
    mq.bind('/atmakemevis', function()
        pcall(function() peer_bcast('/at_makemevis') end)
        pcall(function() mq.cmd('/makemevis') end)   -- a broadcast does not come back to the sender
        log('[invis] /makemevis sent to the whole group')
    end)
    -- mechanism on this build before anything is wired to it.
    mq.bind('/atinvisprobe', function()
        local any = 'nil'
        pcall(function() any = tostring(mq.TLO.Me.Invis()) end)
        local nb, ns = 0, 0
        -- Slots, not count - see the note in invis_self.
        pcall(function() nb = buff_slot_max(tonumber(mq.TLO.Me.CountBuffs()) or 0) end)
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
        -- Slots, not count - see the note in invis_self.
        pcall(function() nb = buff_slot_max(tonumber(mq.TLO.Me.CountBuffs()) or 0) end)
        pcall(function() ns = tonumber(mq.TLO.Me.CountSongs()) or 0 end)
        pcall(function() sweep(function(i) return mq.TLO.Me.Buff(i).Name() end, nb) end)
        pcall(function() sweep(function(i) return mq.TLO.Me.Song(i).Name() end, ns) end)
        -- ALWAYS, WHATEVER WE THINK.
        pcall(function() mq.cmd('/makemevis') end)
        invisLast = ''   -- force a fresh report so the coverage row updates at once
        if #gone > 0 then log('[invis] dropped: %s (+ /makemevis)', table.concat(gone, ', '))
        else log('[invis] no known invis buff to remove - sent /makemevis anyway') end
    end)
    -- Ports are reported ON REQUEST, not on a heartbeat.
-- ===== PORTS =====
PORT_CAT = 'transport'
portBook = {}          -- [char] = { {name=, sub=, lvl=}, ... }
portScanWanted = false -- I should read my own book on the next tick
portCastWanted = nil   -- a port somebody asked me to cast; the tick does it, because casting blocks
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
        mq.delay(EP_MEM_SETTLE)
        -- SAY WHAT THE READS ACTUALLY RETURN.
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
            -- BOTH, not either.
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
    at_cast(spell)
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
    if ui_tip_hover() then
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
            ui_text(UI_LABEL, nm)

            -- SPLIT BY WHO IT MOVES, INSIDE EACH CONTINENT.
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
                    if ui_tip_hover() then
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
    -- Deliberately the smallest possible version.
    mq.bind('/at_ports?', function(who) portAskedBy = who or driverName end)
    mq.bind('/at_portsclr', function(char) if char then portBook[char] = {} end end)
    -- VARARGS AND REJOIN.
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
    mq.bind('/at_portcast', function(...) portCastWanted = table.concat({ ... }, ' ') end)
    mq.bind('/atportlist', function(n)
        portProbeWant = math.max(1, math.min(720, tonumber(n) or 30))
        log('[portprobe] queued - will read the first %d book slot(s) on the next tick', portProbeWant)
    end)
    -- TWO SHAPES.
    mq.bind('/at_invisprep', function() invisPrepWanted = true end)
    -- BARE /makemevis, on demand, with none of the prep around it - no pause, no stopcast, and no
    -- late-prep gate deciding it knows better. For testing the command itself.
    mq.bind('/at_makemevis', function()
        pcall(function() mq.cmd('/makemevis') end)
        rezlog('[invis] /makemevis (asked by the driver)')
    end)
    -- And go back to normal. Sent once the casts are done.
    mq.bind('/at_invisdone', function()
        -- NOT WHILE I AM STILL CASTING.
        local casting = 0
        pcall(function() casting = tonumber(mq.TLO.Me.Casting.ID()) or 0 end)
        if casting > 0 then return end
        -- BOTH flags, always together. Clearing invisPrepped alone is what left the stale stamp behind.
        if invisPrepped then invisPrepped = nil; e3_release('invis') end
        invisPrepAt = nil
    end)
    -- SAME RULE HERE.
    mq.bind('/at_invisfired', function(who, ms)
        local at = tonumber(ms); if not who or not at then return end
        INVT.seen[who] = at
        local names, times = {}, {}
        for nm, t in pairs(INVT.seen) do names[#names+1] = nm; times[#times+1] = t end
        if #times < 2 then return end
        table.sort(times)
        local gap = times[#times] - times[1]
        INVT.seen = {}
        if not INVT.on then return end
        INVT.n = INVT.n + 1
        INVT.total = INVT.total + gap
        if gap > (INVT.worst or -1) then INVT.worst = gap end
        if gap < (INVT.best or 1e9) then INVT.best = gap end
        -- Buckets, because an average hides the shape: what matters is how often it is BAD, not the mean.
        local b = (gap <= 50) and 1 or (gap <= 150) and 2 or (gap <= 500) and 3 or (gap <= 1000) and 4 or 5
        INVT.bucket[b] = (INVT.bucket[b] or 0) + 1
        log('[invistest] run %d: casters %dms apart', INVT.n, gap)
        -- CHECK THE GROUP, not just the two casters.
        INVT.checkAt, INVT.checkRun = mq.gettime() + INVT_CHECK_MS, INVT.n
    end)
        mq.bind('/at_inviscast', function(a, b)
        local at = mq.gettime()
        if a and b and tostring(a):match('^%d+$') and tostring(b):find(':', 1, true) then
            invisTake = { lead = a, blob = b, at = at }
        else
            invisTake = { key = a, lead = tonumber(b) or INVIS_LEAD, at = at }
        end
    end)
    -- WHAT IS THE CAST TIME, REALLY?
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
    -- STORED AGAIN as of 1.19.7, but only ever written once per combo by the sender - see
    -- invis_self_check.
    mq.bind('/at_invis', function(char, n, u, any)
        if not char then return end
        invisState[char] = { norm = tonumber(n) or 0, und = tonumber(u) or 0,
                             anyInvis = (any ~= nil) and (tonumber(any) == 1) or nil,
                             updated = mq.gettime() }
        -- Hold the row open past the LAST report rather than the first: reports trickle in over a second
        -- or two and a fixed window from the combo would close on a straggler.
        invisRowUntil = math.max(invisRowUntil or 0, mq.gettime() + INVIS_ROW_MS)
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
        local prev = magicState[char][key]
        local h = tonumber(have) or 0
        -- ONCE THEY HAVE IT, THEY HAVE IT.
        if prev and prev.have == 1 then h = 1 end
        magicState[char][key] = { have = h, secs = tonumber(secs) or -1,
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
    -- COOLDOWN vs CASTABILITY, side by side.
    mq.bind('/at_dirungs', function()
        for _, nm in ipairs({ DI.CLR_SAVES[1], DI.CLR_SAVES[2], DI.DG_AA, DI.DG_BOOT }) do
            local rank, aaT, aaR, gem, gemT, spR, itID, itT = 0, 'n/a', 'n/a', 0, 'n/a', 'n/a', 0, 'n/a'
            pcall(function() rank = tonumber(mq.TLO.Me.AltAbility(nm).Rank()) or 0 end)
            pcall(function() aaT = tostring(mq.TLO.Me.AltAbilityTimer(nm).TotalSeconds() or 'NULL') end)
            pcall(function() aaR = tostring(mq.TLO.Me.AltAbilityReady(nm)() or 'NULL') end)
            -- BOTH FORMS, SIDE BY SIDE.
            pcall(function() gem = tonumber(mq.TLO.Me.Gem(nm)()) or 0 end)
            local walk = 0
            pcall(function()
                for g = 1, 12 do
                    if tostring(mq.TLO.Me.Gem(g)() or '') == nm then walk = g; break end
                end
            end)
            if gem > 0 then pcall(function() gemT = tostring(mq.TLO.Me.GemTimer(gem).TotalSeconds() or 'NULL') end) end
            local walkT = 'n/a'
            if walk > 0 then pcall(function() walkT = tostring(mq.TLO.Me.GemTimer(walk).TotalSeconds() or 'NULL') end) end
            pcall(function() spR = tostring(mq.TLO.Me.SpellReady(nm)() or 'NULL') end)
            pcall(function() itID = tonumber(mq.TLO.FindItem('=' .. nm).ID()) or 0 end)
            if itID > 0 then pcall(function() itT = tostring(mq.TLO.FindItem('=' .. nm).TimerReady() or 'NULL') end) end
            local rg, have, need, _, counted = di_spell_reagent(nm)
            local rgTxt = 'none'
            if rg then
                rgTxt = string.format('%s %s/%d', rg, counted and tostring(have) or '?', need)
            end
            log('[dirungs] %-28s rank=%d aaTimer=%-6s aaReady=%-6s gem=%d gemTimer=%-6s walk=%d walkTimer=%-6s spellReady=%-6s itemID=%d itemTimer=%-6s reagent=%s%s%s',
                nm, rank, aaT, aaR, gem, gemT, walk, walkT, spR, itID, itT, rgTxt,
                (gem ~= walk) and '  <-- GEM READS DISAGREE' or '',
                (rg and counted and have < need) and '  <-- OUT OF COMPONENT' or '')
        end
        log('[dirungs] ladder as the selector sees it:')
        for i, r in ipairs(di_rung_list()) do
            log('   rung %d  %-28s kind=%-5s ready=%s', i, r.name, r.kind, tostring(r.ready))
        end
    end)
    -- RESCUE.
    mq.bind('/atresume', function()
        e3_release_all()
        for _, nm in ipairs(group_members()) do
            if nm:lower() ~= myName:lower() then pcall(function() peer_cmdf(nm, '/at_e3 off') end) end
        end
        log('handed bot control back to the whole group')
    end)
    -- WHAT DOES THE STAFF LOOK LIKE ON ME?
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
    -- A peer's cast was refused: the tank is covered, so stand down too rather than each of us paying
    -- an emerald to learn it.
    -- Fire a save at the tank: the staff, or a cleric rung. Called straight from the ask, or later by
    -- di_pend_tick once a character that was moving has stopped.
    function di_fire_best(best, tank, tid)
        if best.staff then
            -- FIRE IT HERE.
            local em = 0
            pcall(function() em = tonumber(mq.TLO.FindItemCount('=' .. DI.REAGENT)()) or 0 end)
            peer_bcast('/at_difired')          -- everyone else stands down immediately
            if not cursor_stow('di') then
                rezlog('\\ay[di] cursor will not clear - firing the staff anyway\\ax')
            end
            local spec = DI.STAFF .. ((DI.OPTS ~= '') and DI.OPTS:format(tank) or '')
            rezlog('[diq] FIRING the staff for %s (%d emerald(s))', tank, em)
            -- Same pairing as the rung above: nowcast is lost if E3 is busy, queuecast waits.
            at_cast(spec, tid)
            at_queuecast(spec, tid)
            DI.watch = { at = mq.gettime(), em = em, tank = tank, tries = 1,
                         saveWas = (DI.state[tank] or {}).saveName }
            DI.assumeSpentUntil = mq.gettime() + DI.ASSUME_SPENT
            di_staff_stamp_write()   -- so a restart still knows this happened
            DI.pushNow = true        -- and say so at once; the client's timers will not
            -- DID IT ACTUALLY GO OUT?
            DIQ.self = { at = mq.gettime(), tank = tank, saw = false, best = best, tid = tid }
            DI.trigAt, DI.turnAt = 0, nil
        else
            DI.rungFiredAt = DI.rungFiredAt or {}
            DI.rungFiredAt[best.name] = mq.gettime()
            DI.pushNow = true          -- say so at once; the timers will not
            -- DO NOT CAST INTO A GEM THAT IS STILL COUNTING.
            if best.kind == 'Spell' and best.castable == false and (best.gemLeft or 0) > 0 then
                local waitMs = math.min((best.gemLeft + 1) * 1000, (DI.RUNG_READY_SLACK + 1) * 1000)
                rezlog('[di] %s has %ds left on gem %d - waiting it out rather than casting into it',
                       best.name, best.gemLeft, best.gem or 0)
                mq.delay(waitMs, function()
                    local v = -1
                    pcall(function() v = tonumber(mq.TLO.Me.GemTimer(best.gem).TotalSeconds()) or -1 end)
                    return v == 0
                end)
            end
            local spec = (best.kind == 'Spell')
                     and string.format(DI.RUNG_OPTS_SPELL, best.name)
                     or  string.format(DI.RUNG_OPTS, best.name, best.kind, tank)
            -- THE EXACT STRING WE HAND E3.
            rezlog('[di] %s: %s (target id %d)',
                   (cast_backend() ~= 'e3') and 'native cast'
                       or (DI_SEND_QUEUECAST and 'nowcast + queuecast' or 'nowcast only'), spec, tid)
            at_cast(spec, tid)
            if DI_SEND_QUEUECAST then at_queuecast(spec, tid) end
            -- DID IT ACTUALLY GO OUT?
            local mineWas = nil
            pcall(function()
                for _, b in ipairs(DI.SAVES) do
                    if (tonumber(mq.TLO.Me.Buff(b).ID()) or 0) > 0 then mineWas = b; break end
                end
            end)
            DI.rungCheck = { name = best.name, gem = best.gem, at = mq.gettime(), tank = tank,
                             mineWas = mineWas }
        end
    end
    mq.bind('/at_dineed', function(tank)
        if not tank or tank == '' then return end
        -- FEIGNING OR INVIS: DECLINE, DO NOT CAST.
        if am_feigning() then
            pcall(function() peer_cmdf(tank, '/at_diack %s no feigning', myName) end)
            rezlog('[diq] %s asked for a save - feigning, not standing up for it', tank)
            return
        end
        if am_invis() then
            pcall(function() peer_cmdf(tank, '/at_diack %s no invis', myName) end)
            rezlog('[diq] %s asked for a save - invis, not dropping it', tank)
            return
        end
        -- NOT IN MY ZONE: DECLINE AT ONCE.
        do
            local tankHere, tankType, tankDead = 0, '', false
            pcall(function() tankHere = tonumber(mq.TLO.Spawn('pc =' .. tank).ID()) or 0 end)
            if tankHere <= 0 then
                pcall(function() peer_cmdf(tank, '/at_diack %s no out-of-zone', myName) end)
                rezlog('[diq] %s asked for a save - not in my zone, declining', tank)
                return
            end
            pcall(function() tankType = tostring(mq.TLO.Spawn(tankHere).Type() or '') end)
            pcall(function() tankDead = tlo_true(mq.TLO.Spawn(tankHere).Dead()) end)
            if tankType:lower():find('corpse', 1, true) or tankDead then
                pcall(function() peer_cmdf(tank, '/at_diack %s no target-is-dead', myName) end)
                rezlog('\\ay[diq] %s asked for a save but is dead (%s) - a save cannot land on a corpse\\ax',
                       tank, (tankType ~= '') and tankType or 'flagged dead')
                return
            end
        end
        -- CLERIC RUNGS ARE FOR CLERICS.
        local best
        local amCleric = (member_class(myName) or ''):upper() == 'CLR'
        if amCleric and not DI.ladderOff then
            for _, r in ipairs(di_rung_list()) do
                if r.ready then best = r; break end
            end
        end
        -- THE STAFF IS A CANDIDATE TOO, and it is checked here for the same reason everything else is:
        -- the holder's own TimerReady is the authoritative read, and it is local and instant.
        if not best then
            -- THREE OPINIONS, NOT ONE.
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
            -- SAY WHY, not just no.
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
        -- IN RANGE, OR SAY NO NOW (1.21.2): a save that cannot reach is a 'no' the asker can act on at once,
        -- not a cast that fails after it has stopped asking anyone else.
        do
            local range, dist = 0, -1
            pcall(function()
                if best.staff then range = tonumber(mq.TLO.FindItem('=' .. DI.STAFF).Spell.Range()) or 0
                else range = tonumber(mq.TLO.Spell(best.name).Range()) or 0 end
            end)
            pcall(function() dist = tonumber(mq.TLO.Spawn('pc =' .. tank).Distance()) or -1 end)
            if range > 0 and dist > range then
                local reason = string.format('out-of-range-%dm/%dm', math.floor(dist), math.floor(range))
                pcall(function() peer_cmdf(tank, '/at_diack %s no %s', myName, reason) end)
                rezlog('[diq] %s asked for a save - declining: %s (%s)', tank, reason, best.name)
                return
            end
        end
        rezlog('[diq] %s asked for a save - casting %s', tank, best.name)
        pcall(function() peer_cmdf(tank, '/at_diack %s yes %s', myName, (best.name):gsub(' ', '_')) end)
        -- Fired exactly the way the ladder fires it, including the spent-stamp that stops di_rung_list
        -- offering the same rung again on a timer that reads ready too soon.
        local tid = 0
        pcall(function() tid = tonumber(mq.TLO.Spawn('pc =' .. tank).ID()) or 0 end)
        if tid <= 0 then
            -- Try the plain exact-name form before giving up: two spellings of the same question, and
            -- only one of them has to work.
            pcall(function() tid = tonumber(mq.TLO.Spawn('=' .. tank).ID()) or 0 end)
        end
        if tid <= 0 then
            rezlog('\\ar[di] cannot resolve a spawn id for %s - not casting %s at a target I cannot '
                .. 'address. Are they in this zone?\\ax', tank, best and best.name or '?')
            pcall(function() peer_cmdf(tank, '/at_diack %s no no-spawn-id', myName) end)
            return
        end
        -- MOVING: KEEP THE JOB, CAST WHEN I STOP. Casting on the move is interrupted, the tank then asks
        -- the next toon - who is usually moving too.
        if am_moving() then
            di_pend(tank, best, tid, 'asked while moving')
            return
        end
        di_announce(best, tank)
        di_fire_best(best, tank, tid)
    end)
    -- The answer.
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
        -- IT IS HANDLED.
        local nm = tostring(what or ''):gsub('_', ' ')
        local again = DIQ.casting and DIQ.casting:lower() == who:lower()
        DIQ.casting, DIQ.castAt = who, mq.gettime()
        if not again then rezlog('[diq] %s has it - %s is on the way', who, nm) end
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
                diq_note_decline(who, what)
                DIQ.asked = nil
                -- A 'no' after its own claim frees the claim too (1.21.1): the claim branch below never ran
                -- for it, so the tank sat out DIQ_CAST_MS for a cast that had already said it would not come
                -- (1.20.46 logs: 2m19s with no save, Nityrc and Khulian swapped 9 times).
                if DIQ.casting and DIQ.casting:lower() == who:lower() then DIQ.casting = nil end
            end
        elseif DIQ.casting and who:lower() == DIQ.casting:lower() and verdict ~= 'yes' then
            -- A character that CLAIMED and then found its cast never started.
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
    mq.bind('/at_rezdone', function(name, cid)
        if not name then return end
        rezDone[name:lower()] = mq.gettime() + 15000
        -- Retire the corpse ITSELF, not just the name behind a timeout. The owner sends the id the rezzer
        -- named when it has one; otherwise resolve it here while we still know which body this was about.
        local id = tonumber(cid) or 0
        if id <= 0 then id = rez_corpse(name) end
        if id and id > 0 then
            rezBoxFor[id] = mq.gettime()
            rez_retire(id, name .. ' got the rez box')
        end
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
    -- The SENDER says how long.
    mq.bind('/at_rezretire', function(id)
        local n = tonumber(id)
        if n and n > 0 then rez_retire(n, 'peer retired it') end
    end)
    mq.bind('/at_rezunclaim', function(id, who)
        local n = tonumber(id)
        if n and rezPending[n] then
            rezPending[n] = nil
            rezlog('[rez] %s died mid-rez - corpse %d is free again', tostring(who or '?'), n)
        end
    end)
    mq.bind('/at_rezclaim', function(id, ms)
        local n = tonumber(id)
        if n then
            rezPending[n] = mq.gettime() + (tonumber(ms) or 4000)
            -- LOG THE RECEIPT.
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
        -- they died in.
        if (not zoning) and myz > 0 and ((not dead) or myz ~= (tonumber(rzone) or -1)) then
            peer_cmdf(rezzer, '/at_rezrdy! %s', myName)
            -- A rez is now genuinely on its way to me.
            rezExpectFrom  = mq.gettime()
            rezExpectUntil = mq.gettime() + 15000
        end
    end)
    mq.bind('/at_rezinc', function(from, cid)   -- a rezzer is casting on me right now: arm the accept window
        rezIncAt       = mq.gettime()   -- a REZZER said so; my own readiness does not count
        rezIncFrom     = tostring(from or '')
        rezExpectFrom  = mq.gettime()
        rezExpectUntil = mq.gettime() + 20000
        -- Remember WHICH corpse, so the loot afterwards goes to the right one. Older builds send no id,
        -- in which case this is nil and the loot falls back to searching by name as before.
        rezCorpseID    = tonumber(cid) or nil
        rezlog('[rez] %s is rezzing me%s - watching for the confirmation box', tostring(from or '?'),
               rezCorpseID and (' (corpse ' .. rezCorpseID .. ')') or '')
    end)
    mq.bind('/at_rezping', function(from)   -- a rezzer wants to know I'm zoned and loaded
        if not from or from == '' then return end
        local st = 'ok'
        pcall(function()
            if tostring(mq.TLO.EverQuest.GameState() or ''):upper() ~= 'INGAME' then st = 'loading'
            elseif (tonumber(mq.TLO.Zone.ID()) or 0) <= 0 then st = 'loading'
            elseif tlo_true(mq.TLO.Me.Dead()) or tostring(mq.TLO.Me.State() or ''):upper() == 'HOVER' then st = 'hovering'
            end
        end)
        pcall(function() peer_cmdf(from, '/at_rezpong %s %s', myName, st) end)
    end)
    mq.bind('/at_rezpong', function(who, st)
        if who and who ~= '' then rezPong[who:lower()] = { at = mq.gettime(), state = tostring(st or '?') } end
    end)
    mq.bind('/at_rezrdy!', function(tname) if tname then rezConfirm[tname:lower()] = mq.gettime() end end)   -- target confirmed ready
    -- The SENDER decides how long its skip is good for.
    mq.bind('/at_rezskip', function(key, id, ms)
        local n = tonumber(id)
        if key and n then
            rezSkip[n] = rezSkip[n] or {}
            rezSkip[n][key:lower()] = mq.gettime() + (tonumber(ms) or 8000)
            -- DO NOT clear rezPending here.
        end
    end)
    mq.bind('/at_burn', function(char, class, tier, secs, active, dsecs, kind, ord, tkey, ...)   -- driver receives a worker's item-timer report
        if not char then return end
        local item = table.concat({...}, ' ')
        if item == '' then return end
        burnClass[char] = class
        burnState[char] = burnState[char] or {}
        local keyList = ((tkey or '?'):gsub('~', ' '))
        burnState[char][item] = { tier = tonumber(tier) or 1, secs = tonumber(secs) or 0, active = (tonumber(active) == 1), dsecs = tonumber(dsecs) or 0, kind = kind or 'i', ord = tonumber(ord) or 0, tkey = (keyList:match('^[^+]+') or '?'), keys = burn_key_set(keyList), updated = mq.gettime() }
    end)
    -- a burn line whose spell cannot work from a burn (1.21.3): shown with it in the burn check
    -- this burn item puts a buff on its user: the burn check waits for the buff, not only the cooldown (1.21.5)
    mq.bind('/at_burnexp', function(char, ...)
        if not char then return end
        local item = table.concat({...}, ' ')
        if item == '' then return end
        burnExpect[char] = burnExpect[char] or {}
        burnExpect[char][item] = true
    end)
    mq.bind('/at_burnwarn', function(char, warn, ...)
        if not char or not warn then return end
        local item = table.concat({...}, ' ')
        if item == '' then return end
        burnWarn[char] = burnWarn[char] or {}
        burnWarn[char][item] = (warn:gsub('~', ' '))
    end)
end)

-- Declared with the other persisted flags rather than here, so save_settings and load_settings - which
-- sit above this point in the file - can see it.
autoXTank = (autoXTank ~= false)  -- auto-maintain tank XTargets on the group's healers; on by default
-- Announce roster changes to the raid?
xtankAnnounce = false
-- Names you want on your XTargets that are NOT raid tanks.
xtankPinned = {}
local iAmHealer       = false   -- set at startup; only priest-classes self-maintain tank XTargets
pcall(function() iAmHealer = ({ CLR = true, DRU = true, SHM = true })[(mq.TLO.Me.Class.ShortName() or ''):upper()] or false end)
local lastXTankPoll   = 0       -- gettime of last auto tank-xtarget sweep
-- How often the AUTO pass re-reads the XTarget slots to check nothing has been cleared by hand.
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
    -- Another AdventureTime user calling a raid corpse.
    mq.event('at_rez_say', "#1# says, 'ATREZ #2# #3#'#*#", function(_, who, id, tgt)
        local n = tonumber(id)
        if not n or not who then return end
        if who:lower() == myName:lower() then return end          -- our own shout, heard back
        for _, m in ipairs(group_members()) do
            if m:lower() == who:lower() then return end           -- our own group: already coordinated
        end
        -- A CLAIM FROM AN OLDER BUILD, treated like the new "Rezzing" one: hold REZ_SAY_HOLD. Older builds
        -- never shout a "Rezzed", so the body frees up afterwards rather than being retired on a guess.
        rezPending[n] = mq.gettime() + REZ_SAY_HOLD
        rezlog('[rez] %s (outside my group, older build) called corpse %d (%s) - holding off %ds',
               who, n, tostring(tgt), REZ_SAY_HOLD / 1000)
    end)
    -- THE TWO-PART SHOUT (1.19.63+).
    mq.event('at_rez_say_cast', "#1# says, 'Rezzing #2# (corpse #3#)'#*#", function(_, who, tgt, id)
        local n = tonumber(id)
        if not n or not who or who:lower() == myName:lower() then return end
        local hold = mq.gettime() + REZ_SAY_HOLD
        if not (rezPending[n] and rezPending[n] > hold) then rezPending[n] = hold end
        rezlog('[rez] %s says it is rezzing %s (corpse %d) - holding off %ds', who, tostring(tgt), n, REZ_SAY_HOLD / 1000)
    end)
    -- MY OWN DEATH, from the chat line.
    mq.event('at_me_slain', 'You have been slain by #*#', function()
        rezOwedAt = mq.gettime()
        lastRezPush = 0             -- tell the group I am not rezzing anybody, now
        rezlog('[rez] I died - the next rez box is mine to take')
    end)
    mq.event('at_me_died', 'You died.#*#', function()
        if rezOwedAt == 0 then rezOwedAt = mq.gettime(); lastRezPush = 0; rezlog('[rez] I died - the next rez box is mine to take') end
    end)
    -- AND THE PAY-OFF, however it was accepted - by us, or by a human clicking first.
    mq.event('at_me_rezzed', '#*#You regain some experience from resurrection#*#', function()
        if rezOwedAt > 0 then rezlog('[rez] resurrection landed - no rez owed now') end
        rezOwedAt = 0
    end)
    mq.event('at_rez_say_done', "#1# says, 'Rezzed #2# (corpse #3#)'#*#", function(_, who, tgt, id)
        local n = tonumber(id)
        if not n or not who or who:lower() == myName:lower() then return end
        rez_retire(n, string.format('%s rezzed %s', who, tostring(tgt)))
    end)
    mq.event('at_raid_join',   '#1# joined the raid#*#',            raid_changed)   -- Laz: 'Name joined the raid.'
    mq.event('at_raid_leave',  '#1# has left the raid#*#',          raid_changed)   -- Laz: 'Name has left the raid.'
    mq.event('at_raid_removed','#1# has been removed from the raid#*#', raid_changed)
    mq.event('at_raid_dispand','#*#raid has been disbanded#*#',     raid_changed)
    -- THE GAME TELLS US DIRECTLY - but only about the cast we care about.
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
    -- E3 INTERRUPTED OUR CAST FOR AN EMERGENCY HEAL.
    mq.event('at_e3_healcut', '#*#Interrupting [#1#] for #*#', function(line, spell)
        -- LOG THE RAW LINE.
        -- ONLY WHEN IT CAN MATTER. Every toon's E3 heal-cut reached every log - thousands of file
        -- writes a session for lines about other people's casts.
        if rezCast or epCast or pwCast or (DIQ and DIQ.self) then
            rezlog('[e3cut] %s', tostring(line or '?'))
        end
        -- THE ONE THING IT DOES DECIDE: whether E3 just cut MY rez. Matched on the exact item name, and on
        -- my own name or no name at all (own lines can come either way), so another toon's cut never counts.
        if rezCast and spell and tostring(spell) == tostring(rezCast.item) then
            local l = tostring(line or '')
            if (not l:find('<', 1, true)) or l:find('<' .. myName .. '>', 1, true) then
                rezCast.cutAt = mq.gettime()
                rezlog('[rez] E3 interrupted my %s on %s for a heal%s', rezCast.item, rezCast.name,
                       rezCast.queued and ' - the queued cast will follow' or '')
            end
        end
        do return end
        -- DO NOT CLEAR epLast.
        if epCast then
            -- GIVE THE TRY BACK.
            if (epCast.tries or 1) > 1 then epCast.tries = epCast.tries - 1 end
            rezlog('[placate] E3 cut the cast for a heal - %s keeps its try (%d used), waiting for the heal',
                   epCast.name or '?', epCast.tries or 1)
            epCast = nil
            -- WAIT FOR THE HEAL TO FINISH.
        elseif pwCast then
            rezlog('[pw] E3 cut the cast for a heal - will recast when it is done')
            pwCast = nil
        end
        -- A DI cast that was cut never produced a save. Saying so releases the tank's claim at once
        -- instead of it waiting out the fifteen second ceiling.
        if DIQ and DIQ.self then
            local s = DIQ.self
            DIQ.self = nil
            rezlog('\\ay[diq] E3 cut my save cast for an emergency heal - telling %s\\ax', s.tank)
            pcall(function() peer_cmdf(s.tank, '/at_diack %s no cut-for-heal', myName) end)
            DI.watch, DI.assumeSpentUntil = nil, nil
            DI.pushNow = true
        end
    end)
    -- E3 REFUSING A CAST.
    mq.event('at_e3_refused', '#*#CheckFor#*#', function(line)
        -- NOT CHAT (1.22.6): someone in guild chat asking about CheckFor matched this on all six.
        if tostring(line or ''):find(", '", 1, true) then return end
        rezlog('[di] E3 refused a cast: %s', tostring(line or '?'))
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
        -- A FLOOR HERE TOO, not just on the driver.
        if (mq.gettime() - lastResyncHonored) < 10000 then return end
        lastResyncHonored = mq.gettime()
        burnLast = {}; burnPending = {}; buffNameOf = {}; buffLatch = {}; tribLast = nil
        potLast = {}; healLast = {}; cureLast = {}; magicLast = {}
        -- THREE THAT WERE MISSING, and they are missing in the same way: each push is change-gated on a
        -- key that survived the resync, so the driver heard nothing about them until the value happened
        -- to move on its own.
        nvLast = ''            -- which emblems I carry and whether they are ready
        turboLast, turboCheckAt = nil, 0
        countsPushLast = ''    -- item counts behind the give-out tab
        -- NOT epLast or pwLast. Those are recast timers rather than report caches - the note above
        -- epLast is explicit that zeroing it removes the gap and refires the placate immediately.
        lastBurnPoll, lastClickPoll = 0, 0   -- poll on the next tick rather than waiting out the 2s
        burnStartAt, clickStartAt = 0, 0   -- skip both startup settles: the driver is waiting on us now
        lastBurnResync = mq.gettime()
        -- AND THE ANNOUNCE-ONCE FACTS.
        epSaidHave, pwSaidHave = false, false
        if DI then DI.saidRungs = nil end
        -- PACIFY TOO. pac_announce runs once at startup, so a driver that restarted (a crash on the tank)
        -- never heard anyone's ceiling again and the pacify panel stayed empty until every toon restarted.
        pacAnnounceAt = mq.gettime() + 1500
        pcall(rez_roster_sync)
        -- AND ASK FOR WHAT THE DRIVER OWNS.
        if driverName then
            pcall(function() peer_cmdf(driverName, '/at_rezorder? %s', myName) end)
        end
        log('[sync] re-reporting everything at the driver request')
    end)
    mq.bind('/at_burnsum', function(char, n, h)
        if not char or not SHOW_UI then return end
        burnSumAt[char] = { updated = mq.gettime() }
        local mine = {}
        for item, st in pairs(burnState[char] or {}) do
            mine[item] = burn_key_of(st.secs, st.active, st.dsecs)
        end
        local mn, mh = burn_digest(mine)
        -- At most one re-send per toon per 5 minutes: if names ever arrive mangled the two sides would
        -- disagree forever, and this must never cost more than the blind re-send it replaced.
        if (mn ~= tonumber(n) or mh ~= h) and (mq.gettime() - (burnResendAt[char] or 0)) > 300000 then
            burnResendAt[char] = mq.gettime()
            rezlog('[burns] %s digest differs (%s:%s, I hold %d:%s) - asking for a re-send', char,
                   tostring(n), tostring(h), mn, mh)
            burnState[char] = nil
            pcall(function() peer_cmdf(char, '/at_burnresend') end)
        end
    end)
    mq.bind('/at_burnresend', function()   -- driver's copy of my burns disagrees: report them all once
        burnLast = {}
        burnPending = {}
        lastBurnPoll = 0
        lastBurnSum = mq.gettime()
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
    -- A giver is full and wants the trade window.
    mq.bind('/at_dcnow', function()
        if dc_active() then dcRunning, dcRunSaid = true, true end
    end)
    mq.bind('/at_dcwant', function(who)
        if not who or not dc_i_am_receiver() then return end
        if dcTurnHolder == who then return end
        for _, q in ipairs(dcQueue) do if q == who then return end end
        dcQueue[#dcQueue + 1] = who
        rezlog('[dc] %s is waiting to hand over (%d in the queue)', who, #dcQueue)
    end)
    -- The receiver says come now.
    mq.bind('/at_dcgo', function(from)
        if not from or from:lower() ~= (dcGiveTo or ''):lower() then return end
        dcHaveTurn = true
    end)
    -- A giver finished, or gave up. Either way the window is free.
    mq.bind('/at_dcdone', function(who)
        if not who or not dc_i_am_receiver() then return end
        if dcTurnHolder == who then dcTurnHolder = nil end
    end)

    mq.bind('/at_trib', function(name, act, favor)   -- a peer reported its tribute status
        if not name then return end
        tributeState[name] = { active = (tonumber(act) == 1), favor = tonumber(favor) or 0, updated = mq.gettime() }
        -- REBUILD ON ARRIVAL, NOT ON DRAW.
        tribRowsDirty = true
    end)
end)


-- Bring the whole group up in PARALLEL: ping everyone at once, launch all the non-responders at once,
-- then wait a single settle - instead of a launch+wait per toon.
BRING_UP_GAP = 400

-- IS THIS CHARACTER ONE OF OURS AT ALL?
dnetObs = {}    -- dnetObs[peer .. '\0' .. query] = true, so everything we set can be unset



-- Subscribe, once, and record it. Returns true when the observer is live and safe to read.

-- nil means 'no answer', which the caller must treat differently from a zero.

function dnet_unobserve(peer, query)
    pcall(function() mq.cmdf('/dobserve %s -q "%s" -drop', peer, query) end)
    dnetObs[peer .. '\0' .. query] = nil
end

-- THE ONE THAT MATTERS.
function dnet_drop_all(why)
    -- SNAPSHOT FIRST.
    local keys = {}
    for key, _ in pairs(dnetObs) do keys[#keys + 1] = key end
    local n = 0
    for _, key in ipairs(keys) do
        local peer, query = key:match('^(.-)%z(.*)$')
        if peer and query then
            -- Through dnet_unobserve rather than repeating the command here: one place that knows how to
            -- phrase a drop, so a change to the syntax cannot fix one caller and miss the other.
            dnet_unobserve(peer, query)
            n = n + 1
        end
    end
    dnetObs = {}
    if n > 0 then log('[obs] dropped %d observer(s) (%s)', n, why or 'shutdown') end
    return n
end

-- The transport's list of clients we can actually reach.
netPeerSaid = false
function net_peer_set()
    if not peerChan then peer_detect() end
    local raw, src = '', 'DanNet.Peers'
    if peerChan == 'eqbc' then
        src = 'EQBC.Names'
        pcall(function() if eqbc_connected() then raw = tostring(mq.TLO.EQBC.Names() or '') end end)
    elseif peerChan == 'e3' then
        src = 'E3'
    else
        pcall(function() raw = tostring(mq.TLO.DanNet.Peers() or '') end)
    end
    -- SAY WHAT THE LIST ACTUALLY IS, once.
    if not netPeerSaid then
        netPeerSaid = true
        rezlog('[sync] %s reads: %s', src, (raw == '') and '(empty - filter fails open, everyone is treated as ours)' or raw)
    end
    if raw == '' then return nil end
    local set = {}
    -- DanNet is delimited by | on every build seen and EQBC by spaces, but split on all three plus commas
    -- rather than trusting either: a wrong guess here would silently empty the set and take the whole
    -- group down.
    for nm in raw:gmatch('[^|%s,]+') do
        -- DanNet peers arrive as server_charactername on some setups; the trailing segment is the
        -- character. EQBC names are bare, and a character name cannot contain '_' anyway.
        set[(nm:match('([^_]+)$') or nm):lower()] = true
    end
    if next(set) == nil then return nil end
    return set
end

function net_is_peer(name, set)
    if not set then return true end          -- see FAIL OPEN above
    if name:lower() == myName:lower() then return true end
    return set[name:lower()] == true
end

local function bring_up_group(peers)
    -- Filtered HERE rather than at every call site, so nothing can route round it.
    local set = net_peer_set()
    if set then
        local ours, skipped = {}, {}
        for _, p in ipairs(peers) do
            if net_is_peer(p, set) then ours[#ours + 1] = p else skipped[#skipped + 1] = p end
        end
        if #skipped > 0 then
            rezlog('[sync] not ours, leaving alone: %s', table.concat(skipped, ', '))
        end
        peers = ours
    end
    -- A TABLE, NOT A BOOLEAN.
    if #peers == 0 then return {} end
    -- STOP AS SOON AS EVERYONE HAS ANSWERED.
    local function all_up()
        for _, p in ipairs(peers) do if not alive[p:lower()] then return false end end
        return true
    end
    for _, p in ipairs(peers) do alive[p:lower()] = nil; peer_cmdf(p, '/at_ping %s', myName) end
    local w = 0
    while w < 1200 and not all_up() do mq.doevents(); mq.delay(100); w = w + 100 end

    -- SAY WHEN WE LAUNCH SOMETHING, AND WHY.
    local launched = false
    local started = {}
    for _, p in ipairs(peers) do
        if not alive[p:lower()] then
            peer_cmdf(p, '/lua run %s worker %s', AT_ENTRY, myName)
            started[#started + 1] = p
            launched = true
            if #started < #peers then mq.delay(BRING_UP_GAP) end
        end
    end
    if #started > 0 then
        log('\\ay[sync] starting AdventureTime on %s - no answer to my ping\\ax', table.concat(started, ', '))
    end
    -- ARE THEY STILL THERE?
    do
        mq.delay(1500)
        for _, p in ipairs(peers) do alive[p:lower()] = nil; peer_cmdf(p, '/at_ping %s', myName) end
        local w3 = 0
        while w3 < 1200 and not all_up() do mq.doevents(); mq.delay(100); w3 = w3 + 100 end
        local second = {}
        for _, p in ipairs(peers) do
            if not alive[p:lower()] then
                peer_cmdf(p, '/lua run %s worker %s', AT_ENTRY, myName)
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

-- --------------------------------------------------------------------------- Trade gesture: hand
-- exactly `qty` of `item` from OUR bags to `receiver`.
local giving = false

function clear_cursor()
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

-- Open (or close) every inventory bag once.
local function toggle_all_bags()
    -- FIRE THEM ALL, THEN SETTLE ONCE.
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

-- REFCOUNTED, BECAUSE toggle_all_bags IS A TOGGLE AND NOT AN OPEN.
COTH_OPEN_BAGS = false
bagsHeld = 0
function bags_hold()
    bagsHeld = bagsHeld + 1
    if bagsHeld == 1 then toggle_all_bags() end
end
function bags_drop()
    if bagsHeld <= 0 then bagsHeld = 0; return end
    bagsHeld = bagsHeld - 1
    if bagsHeld == 0 then toggle_all_bags() end
end

local function give_items_to(receiver, bundle)   -- bundle = { {item=, qty=}, ... }; may span MANY trades
    local todo = {}
    for _, b in ipairs(bundle) do
        local q = math.min(math.floor(tonumber(b.qty) or 0), my_count(b.item))
        if q > 0 then todo[#todo + 1] = { item = b.item, remaining = q } end
    end
    if #todo == 0 then return {} end
    -- Tell the receiver we are coming, so its accept window opens.
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
        -- partial.
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

-- THE GIVER.
function dc_giver_tick()
    if not dc_active() then
        -- RELEASE ON THIS PATH TOO.
        if dcHeldWindow then dcHeldWindow = false; altcur_unhold(true) end
        dcHaveTurn, dcSaidFull, dcRunning = false, false, false
        return
    end
    -- NOTHING HAPPENS UNTIL ASKED. dcRunning is set only by the button (locally or via /at_dcnow), so a
    -- name sitting in the box costs one string compare per tick and moves nothing.
    if not dcRunning and not dcHaveTurn then
        -- Run over, or never started: give the window back if we were holding it.
        if dcHeldWindow then dcHeldWindow = false; altcur_unhold(true) end
        return
    end
    -- HOLD THE INVENTORY OPEN FOR THE WHOLE RUN. Taken once, not per pull - the point is that a run of
    -- claims stops paying an open/close cycle each time.
    if not dcHeldWindow then dcHeldWindow = true; altcur_hold() end

    -- HAVE A TURN? Then this is the whole job: hand over everything and say we are done.
    if dcHaveTurn then
        dcHaveTurn = false
        local have = dc_my_coins()
        if have <= 0 then
            pcall(function() peer_cmdf(dcGiveTo, '/at_dcdone %s', myName) end)
            return
        end
        log('[dc] my turn - handing %d %s to %s', have, DC_ITEM, dcGiveTo)
        local moved = give_items_to(dcGiveTo, { { item = DC_ITEM, qty = have } })
        local n = 0
        for _, q in pairs(moved or {}) do n = n + (tonumber(q) or 0) end
        log('[dc] handed over %d %s (%d still on me)', n, DC_ITEM, dc_my_coins())
        -- Release even when nothing moved. A turn that is not given back is a queue that stops.
        pcall(function() peer_cmdf(dcGiveTo, '/at_dcdone %s', myName) end)
        dcSaidFull = false
        return
    end

    local bal = altcur_balance(DC_ITEM) or 0
    local free = dc_free_slots()

    -- ROOM LEFT AND STILL SOMETHING TO CLAIM: claim more. altcur_pull opens and restores the inventory
    -- window itself.
    if bal > 0 and free >= DC_MIN_FREE then
        dcSaidFull = false
        altcur_pull(DC_ITEM, math.min(DC_PULL_EACH, bal))
        return
    end

    -- NOTHING LEFT ANYWHERE: the run is finished. Said once, then quiet.
    if bal <= 0 and dc_my_coins() <= 0 then
        if dcRunSaid then log('[dc] nothing left to claim or hand over - done') end
        dcRunning, dcRunSaid, dcSaidFull = false, false, false
        -- Close it here, at the end of the batch, which is the whole point of having held it.
        if dcHeldWindow then dcHeldWindow = false; altcur_unhold(true) end
        return
    end

    -- EITHER FULL, OR THE BALANCE IS EMPTY AND WE ARE HOLDING COINS.
    if dc_my_coins() <= 0 then return end
    if not dcSaidFull then
        dcSaidFull = true
        log('[dc] %d slot(s) free, %d left in currency - asking %s for a turn to hand over %d %s',
            free, bal, dcGiveTo, dc_my_coins(), DC_ITEM)
    end
    if (mq.gettime() - dcAskedAt) > DC_RETRY_MS then
        dcAskedAt = mq.gettime()
        pcall(function() peer_cmdf(dcGiveTo, '/at_dcwant %s', myName) end)
    end
end

-- THE RECEIVER. One turn at a time, granted in the order asked.
-- A turn expires: a giver that crashes, zones or is killed mid-trade must not hold the window forever.
function dc_receiver_tick()
    if not dc_i_am_receiver() then
        if dcTurnHolder then dcTurnHolder, dcQueue = nil, {} end
        return
    end
    -- MAKE ROOM BEFORE TAKING MORE.
    -- The gap is checked FIRST: it is a number compare, and the two reads behind it are inventory walks
    -- that ran on every tick while a receiver name was set, for an attempt allowed once per 5s.
    if not dcTurnHolder and (mq.gettime() - (dcReclaimAt or 0)) > DC_RECLAIM_GAP
       and dc_free_slots() < DC_RECV_FREE and dc_my_coins() > 0 then
        -- STAMPED BEFORE THE ATTEMPT, not after a success.
        dcReclaimAt = mq.gettime()
        -- Held across the reclaim as well: it opens and closes the same window, and a receiver that is
        -- filling up does this repeatedly.
        altcur_hold()
        local before = dc_my_coins()
        log('[dc] %d slot(s) free - putting %d %s back into currency to make room',
            dc_free_slots(), before, DC_ITEM)
        pcall(function() altcur_reclaim(DC_ITEM) end)
        local after = dc_my_coins()
        altcur_unhold(true)
        if after >= before then
            log('\\ay[dc] reclaim moved nothing - still %d %s in bags, %d slot(s) free\\ax',
                after, DC_ITEM, dc_free_slots())
        end
        return
    end
    if dcTurnHolder then
        if (mq.gettime() - dcTurnAt) <= DC_TURN_MS then return end
        log('\\ay[dc] %s did not finish within %ds - taking the turn back\\ax',
            dcTurnHolder, math.floor(DC_TURN_MS / 1000))
        dcTurnHolder = nil
    end
    if #dcQueue == 0 then return end
    local nextUp = table.remove(dcQueue, 1)
    dcTurnHolder, dcTurnAt = nextUp, mq.gettime()
    log('[dc] %s may hand over now (%d waiting)', nextUp, #dcQueue)
    pcall(function() peer_cmdf(nextUp, '/at_dcgo %s', myName) end)
end


-- single-item convenience (used by the Emerald buy hand-out)
local function give_item_to(receiver, item, qty)
    local m = give_items_to(receiver, { { item = item, qty = qty } })
    return m[item] or 0
end

-- Receiver side: if a trade window is open and we did NOT initiate it, accept it.
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

-- Buy up to `qty` of `item` onto US from `vendor`.
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

-- --------------------------------------------------------------------------- Distribution (driver):
-- for each item with a target, top everyone up to it from the biggest holder.
local uiStatus  = ''
local tributeRows = {}   -- { {name=, active=bool, favor=number}, ... } filled by refresh_tribute()
-- Per-character rez scope.
chainMode       = {}      -- [nameLower] = 'off' | 'raid'   (absent = group only)
function chain_mode(nm) return chainMode[(nm or ''):lower()] or 'group' end
function chain_off(nm)  return chain_mode(nm) == 'off' end
uiLocked        = false   -- lock both windows in place: no dragging, no resizing
-- Per pop-out panel, keyed by panel number. Separate from uiLocked on purpose: pinning the panel you
-- parked in a corner should not also pin the mini window you still want to move.
miniRaid        = false   -- the raid roster section
popLocked       = popLocked or {}   -- `or {}`, per the convention above: a plain assignment here would
                                    -- wipe the loaded value if this line ever moved below load_settings
miniMode        = false   -- compact window when minimized. NOT local: save_settings is defined
                          -- further up the file and would otherwise write a same-named global.
-- NOT local: save_settings/load_settings are defined further up the file, so a local declared here is
-- invisible to them - they would read and write a same-named GLOBAL while the UI used the local, and
-- the setting would silently never persist.
miniBurns       = true    -- show the burn dot matrix in the mini window
miniRunning     = false   -- show what is running right now, counting down (experimental)
miniRez         = true    -- show crown/token cooldowns in the mini window
miniDI          = false   -- show the tank save line + DI staff cooldowns in the mini window
miniPots        = false   -- show the group draught buttons in the mini window
miniClicks      = false   -- show the per-class MGB/group click buttons in the mini window
miniCombos      = false   -- show the combo buttons in the mini window
portProbeWant = nil      -- slots to probe on the next tick; set by /atportlist
miniInvisRows   = false   -- show the per-character Invis/ITU pick rows
raidFolded      = false   -- raid roster collapsed to just its header line
miniInvisCombo  = false   -- show the one-press Invis combo button
miniCures       = false   -- show the cure buttons (Radiant Cure etc) in the mini window
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
miniMagic       = false   -- show the magic protection clicky buttons in the mini window
miniBurnView    = 1       -- burns section: 0 = compact, 1 = tier matrix, 2 = full detail table
miniBurnTable   = false   -- LEGACY, kept only so an old settings file can be migrated below
-- Who appears first, left to right. Separate from rezPriority on purpose: that is who gets RESSED
-- first, which is a different question from who you want to read first. Empty = plain group order.
charOrder       = {}
miniBurnFilter  = 'All'   -- the mini burn view's own role filter, independent of the Burns tab
miniSizeWanted  = false   -- one-shot: resize the mini window next frame (set when detail turns on)
miniSizedOnce   = false   -- has the detail view been sized yet this session?
miniShapeKey    = nil     -- view|peers|on|filter; a change means the window needs re-fitting
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
    -- 300 PER CHARACTER WAS FOR THE FULL TABLE.
    if miniBurnView == 0 then
        local per = 46            -- a four-letter name plus padding and the column rule
        return math.min(1800, n * per + 110), 620
    end
    return math.min(1800, n * 300 + 60), 620   -- 300: comfortable, under the 400 ceiling
end
miniCoth        = false   -- show the CoTH Group button in the mini window
-- GLOBAL, not local: this chunk is at Lua's hard 200-local ceiling and one more would stop it
-- compiling. One table holds every section toggle rather than a local per setting.
showSec = { tribute = true, pots = true, burns = true, rez = true, misc = true }   -- section visibility (persisted)
local lastTributePoll = 0       -- gettime of last tribute refresh
local lastZoneID      = -1      -- detect zoning to force a refresh
local zoneSettleAt    = nil     -- refresh this long after a zone (let DanNet peers resync)
local shortfalls = {}   -- { "Item: Char short N", ... } from the last run
running    = true
local windowOpen = true
local distributing = false
local giveRequested = false   -- set by the button; the MAIN LOOP runs give_out (delays can't yield in render)
local closeAllRequested = false   -- set by the Close-all button; MAIN LOOP broadcasts and exits
updateLaunchRequested = false     -- set by the update button; MAIN LOOP closes peers and launches patcher
atExitWhy = nil                   -- set at whichever exit is taken, printed on the way out
local collectRequested = false   -- set by the Collect-all button; MAIN LOOP runs collect_all
local showStatus = false          -- toggle: show each toon's count per item (green if >= target, red if <)
local refreshRequested = false    -- set to re-read the group's counts for the status view
local statusResize = false        -- widen the window once when status is turned on
-- GLOBAL, NOT LOCAL.
statusCounts = {}                 -- peerlower -> { item -> count } (cached)
local statusNames = {}            -- ordered display names for the status columns


local function give_out()
    if distributing then return end
    distributing = true
    shortfalls = {}
    local full = group_members()
    if #full <= 1 then uiStatus = 'No group members found (are you grouped and on the network?).'; distributing = false; return end

    -- Count EVERYONE first, straight over DanNet - a peer does NOT need to be running AdventureTime
    -- just to report its counts, so there's no pinging the group here.
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

    -- PROTECTED.
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

-- --------------------------------------------------------------------------- UI
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

-- `altCurrency` draws one extra row INSIDE this table for a currency of the same name.
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
        -- currency row.
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
                    -- '?' not '0'.
                    if sc and sc.__unknown and sc.__unknown[it] then
                        ImGui.TextColored(0.95, 0.85, 0.30, 1.0, '?')
                        if ui_tip_hover() then
                            pcall(function() ImGui.SetTooltip(nm .. ': count timed out - skipped by Give out') end)
                        end
                    elseif ck and ((is_endurance(it) and not WANTS_ENDURANCE[ck])
                                or (is_mana(it) and not WANTS_MANA[ck])
                                or (is_ruby(it) and not WANTS_RUBY[ck])) then
                        ImGui.TextDisabled(tostring(n))   -- holds this many but won't use them (grey = not needed)
                    elseif n >= tgt then
                        ui_text(UI_READY, tostring(n))
                    else
                        ImGui.TextColored(0.93, 0.42, 0.42, 1.0, tostring(n))
                    end
                end
                -- GROUP TOTAL.
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
                -- WANTED IS PER USER, NOT PER CHARACTER.
                local wanted = tgt * users
                if missing > 0 then
                    -- Incomplete: cannot honestly call it either way, so neither green nor red.
                    ImGui.TextColored(0.95, 0.85, 0.30, 1.0, string.format('%d+', total))
                elseif wanted <= 0 then
                    -- No target set, or nobody in the group uses it. Nothing to be short OF.
                    ImGui.TextDisabled(tostring(total))
                elseif total >= wanted then
                    ui_text(UI_READY, tostring(total))
                else
                    ImGui.TextColored(0.93, 0.42, 0.42, 1.0, tostring(total))
                end
                if ui_tip_hover() then
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
            -- GIVE SITS NEXT TO THE NUMBER IT USES.
            if altCurrency == it then
                local q = target[it] or 0
                ImGui.SameLine()
                local dis = ui_disable_if(distributing)
                if ImGui.SmallButton('Give##dcgive_' .. it) then
                    dcGiveWant = { item = it, currency = altCurrency }
                end
                ui_enable(dis)
                if ui_tip_hover() then
                    pcall(function() ImGui.SetTooltip(string.format(
                        'Will give %d %s to each character,\nand pull from Alt Currency if short.', q, it)) end)
                end
                -- TRIBUTE READS THE SAME BOX.
                ImGui.SameLine()
                ImGui.TextDisabled('Tribute:')
                ImGui.SameLine()
                if ImGui.SmallButton('Me##trib_' .. it) then
                    tribWant = { item = it, qty = q }
                end
                if ui_tip_hover() then
                    pcall(function() ImGui.SetTooltip(string.format(
                        'Will walk to a tribute master and donate %d %s.\nYou are holding %d.',
                        q, it, (counts[myName:lower()] or {})[it] or 0)) end)
                end
                ImGui.SameLine()
                if ImGui.SmallButton('Group##tribg_' .. it) then
                    tribGroupWant = { item = it, qty = q }
                end
                if ui_tip_hover() then
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
                    if ui_tip_hover() then
                        pcall(function() ImGui.SetTooltip(nm .. '\nnever answered - press Counts again') end)
                    end
                elseif bal == 'shut' then
                    unknown = unknown + 1
                    ImGui.TextColored(0.90, 0.72, 0.35, 1.0, 'shut')
                    if ui_tip_hover() then
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
            -- WITHDRAW ALL, no quantity box.
            local anyBal = false
            for _, nm in ipairs(statusNames) do
                local b2 = (altCounts[nm:lower()] or {})[altCurrency]
                if type(b2) == 'number' and b2 > 0 then anyBal = true; break end
            end
            if anyBal then
                local dis = ui_disable_if(distributing)
                if ImGui.SmallButton('Withdraw All##altwall_' .. altCurrency) then
                    altWithdrawAllWant = { name = altCurrency }
                end
                ui_enable(dis)
                if ui_tip_hover() then
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
                local dis = ui_disable_if(distributing)
                if ImGui.SmallButton('Reclaim All##altrec_' .. altCurrency) then
                    altReclaimAllWant = { name = altCurrency }
                end
                ui_enable(dis)
                if ui_tip_hover() then
                    pcall(function() ImGui.SetTooltip(
                        'Will put all ' .. altCurrency .. ' in bags back into Alt Currency,\non every character holding any.') end)
                end
            else
                -- SAY THE SPACE IS EMPTY rather than drawing nothing.
                ImGui.TextDisabled('nothing to reclaim')
            end

        end
        ImGui.EndTable()
    end
    -- HAND-OFF TARGET, drawn AFTER the table rather than as a row in it.
    if altCurrency then
        ImGui.Spacing()
        ImGui.TextColored(0.62, 0.82, 0.95, 1.0, 'Claim all ' .. altCurrency .. ' and give to:')
        ImGui.SameLine()
        ImGui.SetNextItemWidth(150)
        local okI, nv = pcall(function()
            return ImGui.InputText('##at_dcgive_' .. altCurrency, dcGiveTo or '')
        end)
        if okI and nv ~= nil and nv ~= dcGiveTo then
            -- Clearing the queue on edit matters: retyping the name mid-run would otherwise leave turns
            -- outstanding against whoever it used to be.
            dcGiveTo = (nv:gsub('^%s+', ''):gsub('%s+$', ''))
            dcQueue, dcTurnHolder, dcHaveTurn = {}, nil, false
            save_settings()
        end
        ImGui.SameLine()
        if (dcGiveTo or '') == '' then
            ImGui.TextDisabled('off - blank means nobody claims or hands over')
        else
            -- GIVE ALL NOW.
            local dis = ui_disable_if(distributing)
            if ImGui.SmallButton('Claim + Give All##at_dcnow') then
                dcGiveNowWant = true
            end
            ui_enable(dis)
            if ui_tip_hover() then
                pcall(function() ImGui.SetTooltip(
                    'Every character claims its ' .. altCurrency .. ' into bags and hands it to '
                 .. dcGiveTo .. '.\nClaiming pauses at ' .. DC_MIN_FREE .. ' free slots, hands over, '
                 .. 'then carries on\nuntil the currency tab is empty.\n\n'
                 .. 'One at a time - they queue for the trade window.\n'
                 .. 'Nothing happens until you press this; the name alone does nothing.') end)
            end
            ImGui.SameLine()
            if dc_i_am_receiver() then
                ui_text({ 0.36, 0.80, 0.46 },
                        string.format('receiving - %d waiting, %s has the window',
                                      #dcQueue, dcTurnHolder or 'nobody'))
            elseif dcRunning then
                ui_text({ 0.90, 0.70, 0.30 },
                        string.format('running - %d free, %d on me', dc_free_slots(), dc_my_coins()))
            else
                ImGui.TextDisabled(string.format('idle - %d on me, press to start', dc_my_coins()))
            end
        end
    end
    pop_state_button(pushed)
    ImGui.Spacing()
end

local function fmt_favor(n)
    n = tonumber(n) or 0
    if n >= 1000 then return string.format('%.1fk', n / 1000) end
    return tostring(math.floor(n))
end

-- Query each group member's tribute over DanNet (self read directly).

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

-- The two-line cell grid (used by both the full window and the mini view).
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
    -- THE DRAW IS THE SIGNAL.
    tribDrawnAt = mq.gettime()
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
local ICONS_OK, ICO = pcall(require, 'mq.icons')
local BURN_DOT = '#'   -- the dot glyph; ASCII so it renders in any ImGui font. Swap freely.
                       -- Declared HERE, above burn_glyph: it used to sit below, so the 'or BURN_DOT'
                       -- fallback read a nil global and an unknown kind rendered nothing at all.
-- The pop-out glyph.
POP_ICON = (ICONS_OK and type(ICO) == 'table'
            and (ICO.FA_EXTERNAL_LINK or ICO.MD_OPEN_IN_NEW or ICO.FA_WINDOW_RESTORE)) or '>>'
-- The grab handle.

-- THE ICON'S OWN WIDTH, measured from the real button rather than guessed: pop_grip records
-- GetItemRectSize the first time it draws one and that measurement is used from then on.
POP_ICON_W = nil

-- HOW FAR RIGHT THE ICON MAY SIT, per window. Keyed by window ('mini', or the panel number) because
-- each one is a different width.
POP_RIGHT = {}; WIN_LATCH = {}

-- WIDTH THAT GROWS AT ONCE AND SHRINKS ON PURPOSE. The mini and the pop-outs size themselves to their
-- content, and their content changes width all the time: a timer appears and goes, a name button turns
-- into a countdown pill, a header line changes its words. Each of those moved the window edge, every
-- second. Now a window may grow the moment it needs to, but only gets narrower when its shape changes
-- (a section folded, opened, moved or switched view - everything that resets WIN_LATCH) or once every
-- UI_LATCH_RELEASE_MS, so it settles back after a fight without twitching during one.
WIN_LATCH = {}
UI_LATCH_RELEASE_MS = 30000
function ui_latch_before(key)
    local L = WIN_LATCH[key]
    if not L then WIN_LATCH[key] = { w = 0, rel = mq.gettime() }; return end
    if (mq.gettime() - L.rel) > UI_LATCH_RELEASE_MS then L.w, L.rel = 0, mq.gettime(); return end
    if L.w > 0 then pcall(function() ImGui.SetNextWindowSizeConstraints(L.w, 0, 100000, 100000) end) end
end
function ui_latch_after(key)
    local L = WIN_LATCH[key]
    if not L then return end
    local ok, w = pcall(function() return ImGui.GetWindowWidth() end)
    if ok and w and w > L.w then L.w = w end
end

-- RIGHT-ALIGN WITHOUT THE FEEDBACK LOOP.
function pop_align(win)
    ImGui.SameLine(0, 10)
end

POP_GRIP = (ICONS_OK and type(ICO) == 'table'
            and (ICO.FA_BARS or ICO.MD_DRAG_INDICATOR or ICO.FA_ELLIPSIS_V)) or '::'

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
-- The tiers actually being reported, ordered, as { key, label } entries.
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

    -- 2) Merge.
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
        -- Advance every list past this key AND past anything already emitted.
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

-- THE THIRD VIEW: ONE DOT PER TIER, not one per item.
RUN_ORDER, RUN_SWAP_SECS = {}, 3
function draw_burn_running()
    -- GROUPED BY CHARACTER.
    local byChar, order = {}, {}
    for _, c in ipairs(ordered_members()) do
        for it, st in pairs(burnState[c] or {}) do
            if st.active and (st.dsecs or 0) > 0 then
                local age  = math.floor((mq.gettime() - (st.updated or 0)) / 1000)
                local left = math.max(0, (st.dsecs or 0) - age)
                if left > 0 then
                    if not byChar[c] then byChar[c] = {}; order[#order + 1] = c end
                    byChar[c][#byChar[c] + 1] = { it = it, left = left, total = st.dsecs, st = st }
                end
            end
        end
        -- Draughts are not here any more: they have their own strip under the Draughts buttons.
    end
    if #order == 0 then
        -- Nothing running is the normal state, and it should read as calm rather than as an error.
        if BURNCHK then draw_burncheck() return end
        ImGui.TextDisabled('nothing running')
        return
    end

    -- A LIST, LIKE THE BURN CHECK BELOW IT (1.22.1: icon + name read better than the icon-only tiles). One column
    -- per character, one burn a line: the icon (darkening from the top as its time runs out, an orange edge in the
    -- last ten seconds), its short name, and the time left. Hover for the full name.
    local fs = 16
    pcall(function() fs = math.floor(ImGui.GetFontSize() or 16) end)
    local ts = math.max(12, math.floor(ui_icon_size() * 0.9))
    local flags = (ImGuiTableFlags.SizingFixedFit or 0) + (ImGuiTableFlags.BordersInnerV or 0)
    local padPushed = pcall(function() ImGui.PushStyleVar(ImGuiStyleVar.CellPadding, 6, 2) end)
    local opened = ImGui.BeginTable('##burnrun', #order, flags)
    if not opened then
        if padPushed then pcall(function() ImGui.PopStyleVar(1) end) end
        return
    end
    for _ = 1, #order do ImGui.TableSetupColumn('') end

    local function line(r, c, idx)
        local x, y = 0, 0
        pcall(function() x, y = ImGui.GetCursorScreenPos() end)
        local drew = ui_icon(r.it, nil, ts)
        if drew then
            pcall(function()
                local dl = ImGui.GetWindowDrawList()
                local frac = math.max(0, math.min(1, r.left / math.max(1, r.total)))
                local spent = math.floor(ts * (1 - frac))   -- spent time, darkening down from the top
                if spent > 0 then dl:AddRectFilled(ImVec2(x, y), ImVec2(x + ts, y + spent), IM_COL32(0, 0, 0, 165), 0) end
                if r.left <= 10 then dl:AddRect(ImVec2(x, y), ImVec2(x + ts, y + ts), IM_COL32(255, 170, 70, 235), 3, 0, 2) end
            end)
            ImGui.SameLine()
        end
        ImGui.Text(burn_short_name(r.it, BURNCHK_CHARS or 13))
        local hov = ui_tip_hover()
        ImGui.SameLine()
        ui_text((r.left <= 10) and UI_WAIT or UI_READY, string.format('%d:%02d', math.floor(r.left / 60), r.left % 60))
        if hov or ui_tip_hover() then
            pcall(function() ImGui.SetTooltip(string.format('%s\n%s - %d:%02d left', r.it, c,
                math.floor(r.left / 60), r.left % 60)) end)
        end
    end

    -- names across the top
    ImGui.TableNextRow()
    for _, c in ipairs(order) do
        ImGui.TableNextColumn()
        ui_text(UI_LABEL, c)
    end
    ImGui.TableNextRow()
    for _, c in ipairs(order) do
        ImGui.TableNextColumn()
        local rows = byChar[c]
        -- Shortest first, but STEADY: rows keep last frame's order and only pass each other when the
        -- gap is more than RUN_SWAP_SECS, so two burns a second apart do not keep trading places.
        do
            local rank = {}
            for i, n in ipairs(RUN_ORDER[c] or {}) do rank[n] = i end
            table.sort(rows, function(x, y)
                local rx, ry = rank[x.it] or 1e9, rank[y.it] or 1e9
                if rx ~= ry then return rx < ry end
                if x.left ~= y.left then return x.left < y.left end
                return x.it < y.it
            end)
            local moved = true
            while moved do
                moved = false
                for i = 1, #rows - 1 do
                    if rows[i + 1].left < rows[i].left - RUN_SWAP_SECS then
                        rows[i], rows[i + 1] = rows[i + 1], rows[i]
                        moved = true
                    end
                end
            end
            local names = {}
            for i, r in ipairs(rows) do names[i] = r.it end
            RUN_ORDER[c] = names
        end
        for k, r in ipairs(rows) do line(r, c, k) end
    end
    ImGui.EndTable()
    if padPushed then pcall(function() ImGui.PopStyleVar(1) end) end
    if BURNCHK then draw_burncheck() end
end


-- ===== WHO HAS IT RUNNING: a strip under the Draughts buttons and under the Nightveil rows =====
-- One short line per character with the effect up: the icon and the time left. It appears when a toon
-- has clicked (so you can see the bot did it) and goes when the effect fades (so you can see it is over),
-- and the section shrinks back with it, the way Pacify's queue does.
function toon_effects(c, kind)
    local out = {}
    local now = mq.gettime()
    if kind == 'pot' then
        for _, gp in ipairs(GROUP_POTS) do
            local ps = (potState[c] or {})[gp.key]
            if ps and (ps.up or 0) > 0 and (ps.dsecs or 0) > 0 then
                local left = (ps.dsecs or 0) - math.floor((now - (ps.updated or 0)) / 1000)
                if left > 0 then
                    local iname = (ICON.cache[gp.base .. ' II'] == false) and (gp.base .. ' I') or (gp.base .. ' II')
                    out[#out + 1] = { icon = iname, label = gp.label, left = left }
                end
            end
        end
    else
        local st = nvState[c]
        if st and st.ups then
            for i, u in pairs(st.ups) do
                local left = (u or 0) - math.floor((now - (st.updated or 0)) / 1000)
                if left > 0 and NV_SPLIT[i] then
                    out[#out + 1] = { icon = NV_SPLIT[i].item, label = NV_SPLIT[i].role, left = left }
                end
            end
        end
    end
    table.sort(out, function(a, b) return a.left < b.left end)
    return out
end
function draw_effect_strip(kind)
    local rows, nameW = {}, 0
    for _, c in ipairs(ordered_members()) do
        local fx = toon_effects(c, kind)
        if #fx > 0 then
            rows[#rows + 1] = { c = c, fx = fx }
            pcall(function() nameW = math.max(nameW, ImGui.CalcTextSize(c) or 0) end)
        end
    end
    if #rows == 0 then return end
    local fs = 16
    pcall(function() fs = math.floor(ImGui.GetFontSize()) end)
    for _, r in ipairs(rows) do
        local x0 = 0
        pcall(function() x0 = ImGui.GetCursorPosX() + 12 end)
        pcall(function() ImGui.SetCursorPosX(x0) end)
        ui_text(UI_OFF, r.c)
        for i, e in ipairs(r.fx) do
            ImGui.SameLine(0, 8)
            if i == 1 then pcall(function() ImGui.SetCursorPosX(x0 + nameW + 10) end) end
            local drew = ui_icon(e.icon, 'item', fs)
            if not drew then ui_text(UI_OFF, e.label) end
            local hov = ImGui.IsItemHovered and ImGui.IsItemHovered()
            ImGui.SameLine(0, 3)
            ui_text((e.left <= 30) and UI_WAIT or UI_READY,
                    string.format('%d:%02d', math.floor(e.left / 60), e.left % 60))
            hov = hov or (ImGui.IsItemHovered and ImGui.IsItemHovered())
            if hov then
                pcall(function() ImGui.SetTooltip(string.format('%s: %s, %d:%02d left', r.c, e.label,
                    math.floor(e.left / 60), e.left % 60)) end)
            end
        end
    end
end

function draw_burn_compact()
    local chars = {}
    for _, c in ipairs(ordered_members()) do
        if burnState[c] then chars[#chars + 1] = c end
    end
    if #chars == 0 then ImGui.TextDisabled('no burn reports yet'); return end
    local tiers = burn_tiers_present(chars)
    if #tiers == 0 then ImGui.TextDisabled('no burns configured'); return end

    -- A REAL TABLE AGAIN, names across the top.
    local tlabels = {}
    for i, t in ipairs(tiers) do
        tlabels[i] = (t.label:gsub('[Bb]urns?$', ''):gsub('%s+$', ''))
    end

    local fs = 16
    pcall(function() fs = ImGui.GetFontSize() or 16 end)
    local labelW, nameW = 0, 0
    pcall(function()
        for _, tl in ipairs(tlabels) do
            local w = ImGui.CalcTextSize(tl) or 0
            if w > labelW then labelW = w end
        end
        for _, c in ipairs(chars) do
            local w = ImGui.CalcTextSize(c) or 0
            if w > nameW then nameW = w end
        end
    end)
    labelW = math.ceil(labelW) + 8
    local colW = math.max(math.ceil(nameW), math.floor(fs * 1.2)) + 6

    local flags = (ImGuiTableFlags.BordersInnerV or 0) + (ImGuiTableFlags.RowBg or 0)
                + (ImGuiTableFlags.SizingFixedFit or 0)
    if not ImGui.BeginTable('##burncompact', 1 + #chars, flags) then return end
    ImGui.TableSetupColumn('', ImGuiTableColumnFlags.WidthFixed or 0, labelW)
    for _, c in ipairs(chars) do
        ImGui.TableSetupColumn(c, ImGuiTableColumnFlags.WidthFixed or 0, colW)
    end
    ImGui.TableHeadersRow()

    for _, t in ipairs(tiers) do
        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ui_text(UI_LABEL, (t.label:gsub('[Bb]urns?$', ''):gsub('%s+$', '')))
        for _, c in ipairs(chars) do
            ImGui.TableNextColumn()
            local names = {}
            for it, st in pairs(burnState[c] or {}) do
                if (st.tier or 0) > 0 and (st.tkey or '?') == t.key then names[#names + 1] = it end
            end
            if #names == 0 then
                ImGui.TextDisabled('-')
                if ui_tip_hover() then
                    pcall(function() ImGui.SetTooltip(c .. ' has nothing at ' .. t.label) end)
                end
            else
                table.sort(names)
                -- ONE TOOLTIP FOR THE WHOLE CELL. A mark is a small hover target and the size is the
                -- feature, so the whole list answers from wherever the cursor lands on it.
                local lines = { c .. '  ' .. t.label }
                local worstItem, worstLeft, anyReady = nil, -1, false
                for _, it in ipairs(names) do
                    local st = burnState[c][it]
                    local r  = burn_remain(st)
                    if st.active then      lines[#lines + 1] = '  ' .. it .. '  (running)'
                    elseif r == 0 then     lines[#lines + 1] = '  ' .. it .. '  ready'
                    elseif r < 0 then      lines[#lines + 1] = '  ' .. it
                    else lines[#lines + 1] = string.format('  %s  %d:%02d', it, math.floor(r / 60), r % 60) end
                    if st.active or (r or 0) == 0 then anyReady = true end
                    if (r or 0) > worstLeft then worstItem, worstLeft = it, (r or 0) end
                end
                local tip = table.concat(lines, '\n')
                local pid = 'burn:' .. c .. ':' .. t.key

                -- Always. This was a toggle and the alternative was never the better picture; made the
                -- only behaviour on 2026-08-24.
                if worstLeft > 0 then
                    ui_pulse_note(pid, false)
                    local segs = {}
                    for _, it in ipairs(names) do
                        local st2 = burnState[c][it]
                        local r2  = burn_remain(st2)
                        local br, bg, bb = burn_colour(st2)
                        local pk = math.max(burnPeak[it] or 0, r2 or 0, 1)
                        burnPeak[it] = pk
                        segs[#segs + 1] = {
                            rgb  = { math.floor(br * 255), math.floor(bg * 255), math.floor(bb * 255) },
                            fill = (st2.active or (r2 or 0) <= 0) and 1 or (1 - (r2 / pk)),
                        }
                    end
                    local d = math.floor(fs * 1.15)
                    ui_cell_centre(d)
                    ui_seg_ring(segs, d, 2.2)
                elseif worstLeft <= 0 then
                    local cr, cg, cb = burn_colour(burnState[c][names[1]])
                    local rgb = { math.floor(cr * 255), math.floor(cg * 255), math.floor(cb * 255) }
                    -- RUNNING SPINS, READY SITS STILL.
                    local anyActive = false
                    for _, it in ipairs(names) do
                        if burnState[c][it] and burnState[c][it].active then anyActive = true; break end
                    end
                    local d = math.floor(fs * (anyActive and 1.05 or 0.95))
                    ui_cell_centre(d)
                    if anyActive then ui_spinner(rgb, d) else ui_disc(rgb, d, pid) end
                else
                    ui_pulse_note(pid, false)
                    local stw = burnState[c][worstItem]
                    local cr, cg, cb = burn_colour(stw)
                    local rgb = { math.floor(cr * 255), math.floor(cg * 255), math.floor(cb * 255) }
                    burnPeak[worstItem] = math.max(burnPeak[worstItem] or 0, worstLeft, 1)
                    local d = math.floor(fs * 1.05)
                    ui_cell_centre(d)
                    ui_ring(worstLeft / burnPeak[worstItem], rgb, '', d, 2.0, anyReady)
                end
                if ui_tip_hover() then
                    pcall(function() ImGui.SetTooltip(tip) end)
                end
            end
        end
    end
    ImGui.EndTable()
end

-- Compact burn view: one row per character, one dot per burn item, colour carries the whole state.
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
        ui_text(UI_WAIT, string.format('Tribute ON  %d/%d', on, tot))
        if ui_tip_hover() then
            pcall(function() ImGui.SetTooltip('off: ' .. table.concat(off, ', ')) end)
        end
    end
end

-- Mini rez: just the crown/token cooldowns.
function rez_cell(base, updated, pid, placed)
    if (base or -1) < 0 then ImGui.TextDisabled('-'); return end
    local left = math.max(0, base - math.floor((mq.gettime() - (updated or 0)) / 1000))
    if left == 0 then
        local d = math.floor(ImGui.GetFontSize() * 0.95)
        if not placed then ui_cell_centre(d) end
        ui_disc({ 92, 204, 117 }, d, pid)
        if ui_tip_hover() then
            pcall(function() ImGui.SetTooltip('ready') end)
        end
    else
        ui_pulse_note(pid, false)
        local rgb
        if left < 60 then      rgb = { 242, 217,  77 }
        elseif left < 300 then rgb = { 242, 158,  64 }
        else                   rgb = { 217,  89,  89 } end
        if not placed then ui_cell_centre(46) end
        ui_pill(string.format('%d:%02d', math.floor(left / 60), left % 60), rgb, 46)
    end
end

-- DI staff, kept OUT of the crown/token table so that stays exactly as it was.
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
        -- NAME IT.
        local nm = tostring(ds.saveName or '')
        local short = (nm == 'Divine Intervention') and 'DI'
                   or (nm == 'Divine Redemption') and 'DR'
                   or (nm == 'Divine Guardian') and 'Guardian'
                   or (nm ~= '' and nm) or 'a save'
        ImGui.TextColored(0.35, 0.90, 1.00, 1.0, string.format('%s: %s', tank, short))
        if ui_tip_hover() and nm ~= '' then
            pcall(function() ImGui.SetTooltip(tank .. ' is carrying ' .. nm) end)
        end
    else
        ImGui.TextDisabled(tank .. ': no save')
    end
    -- OFF SWITCH, ON THE ROW YOU ALREADY WATCH.
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
    if ui_tip_hover() then
        pcall(function() ImGui.SetTooltip(DI.auto
            and 'DI is running - click to stop it asking for saves'
            or  'DI is OFF - nothing will be asked for or cast') end)
    end
end

function draw_di_mini()
    -- Drawn on the header now, so the panel does not repeat it.
    local cols = {}
    for _, nm in ipairs(rezPriority) do
        local ds = DI.state[nm]
        if ds and (ds.staff or -1) >= 0 then cols[#cols + 1] = nm end
    end
    if #cols == 0 then ImGui.TextDisabled('no DI staff reports'); return end

    local labelW, nameW = ui_fit_w('Staff', 40), 0
    pcall(function()
        for _, nm in ipairs(cols) do
            local w = ImGui.CalcTextSize(nm) or 0
            if w > nameW then nameW = w end
        end
    end)
    nameW = math.ceil(nameW) + 10

    local flags = (ImGuiTableFlags.BordersInnerV or 0) + (ImGuiTableFlags.RowBg or 0)
                + (ImGuiTableFlags.SizingFixedFit or 0)
    if not ImGui.BeginTable('##dimini', 1 + #cols, flags) then return end
    ImGui.TableSetupColumn('', ImGuiTableColumnFlags.WidthFixed or 0, labelW)
    for _, nm in ipairs(cols) do
        ImGui.TableSetupColumn(nm, ImGuiTableColumnFlags.WidthFixed or 0, nameW)
    end
    ImGui.TableHeadersRow()
    ImGui.TableNextRow()
    ImGui.TableNextColumn()
    ui_row_label('Staff', DI.STAFF, 'item')
    for _, nm in ipairs(cols) do
        ImGui.TableNextColumn()
        local ds = DI.state[nm]
        rez_cell(ds and ds.staff or -1, ds and ds.updated, 'di:' .. nm)
    end
    ImGui.EndTable()
end

-- --------------------------------------------------------------------------- Combos: one button that
-- presses several of the class buttons.
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

-- --------------------------------------------------------------------------- Cure clicks.
MAGIC_CLICKS = {
    -- ONE 'Boots' ROW FOR BOTH.
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
    -- group and appear as one row with two buttons rather than two near-identical rows.
    { key = 'echoancglyph', label = 'Echoes of the Ancient', group = 'Echoes', short = 'glyph',
      name = 'Imbued Glyph: Echoes of the Ancient' },
    { key = 'echoancient',  label = 'Echoes of the Ancient', group = 'Echoes', short = 'ancient',
      spell = 'Echoes of the Ancient' },
    -- INVIS AND INVIS-TO-UNDEAD, as AAs.
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
function magic_state(e)
    -- AA FIRST, because it is neither of the other two.
    if e.aa then
        local secs = 0
        pcall(function() secs = math.floor(tonumber(mq.TLO.Me.AltAbilityTimer(e.aa).TotalSeconds()) or 0) end)
        if secs <= 1 then secs = 0 end
        -- AN AA ENTRY IS OWNED IF THE AA IS. have_thing tried a bag search, the spellbook and four other
        -- lookups first, every recheck, for a name that can only ever be an AA.
        local rank, rdy = 0, false
        pcall(function() rank = tonumber(mq.TLO.Me.AltAbility(e.aa).Rank()) or 0 end)
        if rank <= 0 then pcall(function() rdy = tlo_true(mq.TLO.Me.AltAbilityReady(e.aa)()) end) end
        return ((rank > 0 or rdy) and 1 or 0), secs, 0, 0
    end
    if e.spell then
        -- NOT IN THE BOOK, NOT MEMMED. Asked once and kept for ten minutes; without it a spell this
        -- class does not have walked all fourteen gems by name on every recheck.
        magicBook = magicBook or {}
        local mb = magicBook[e.spell]
        if not mb or (mq.gettime() - mb.at) > 600000 then
            local inBook = false
            pcall(function() inBook = (tonumber(mq.TLO.Me.Book(e.spell)()) or 0) > 0 end)
            mb = { has = inBook, at = mq.gettime() }
            magicBook[e.spell] = mb
        end
        if not mb.has then return 0, -1, 0, 0 end
        -- Ask by name first, then fall back to walking the gems and comparing.
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
        local secs = 0
        pcall(function() secs = math.floor(tonumber(mq.TLO.Me.GemTimer(e.spell).TotalSeconds()) or 0) end)
        local rdy = (secs <= GEM_READY_SLACK)
        if rdy then secs = 0 end
        local rem = 0
        pcall(function() rem = tonumber(mq.TLO.Me.Song(e.spell).Duration.TotalSeconds()) or 0 end)
        if rem <= 0 then pcall(function() rem = tonumber(mq.TLO.Me.Buff(e.spell).Duration.TotalSeconds()) or 0 end) end
        return 1, secs, (rem > 0) and 1 or 0, math.floor(rem or 0)
    end

    local it, itemID = nil, 0
    pcall(function() it = mq.TLO.FindItem('=' .. e.name); itemID = tonumber(it.ID()) or 0 end)
    if itemID <= 0 then return 0, -1, 0, 0 end
    local t = 0
    pcall(function() t = tonumber(it.TimerReady()) or 0 end)
    local bn, rem = '', 0
    pcall(function() bn = tostring(it.Spell.Name() or '') end)
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
        -- STRAIGHT TO THE CLIENT FOR AN AA, not through E3.
        local aid = 0
        pcall(function() aid = tonumber(mq.TLO.Me.AltAbility(e.aa).ID()) or 0 end)
        if aid > 0 then
            pcall(function() mq.cmdf('/alt activate %d', aid) end)
        else
            at_cast(e.aa .. '/CastType|Alt')
        end
    elseif e.spell then
        at_cast(e.spell)
    else
        at_cast(e.name .. '/CastType|Item')
    end
    log('[magic] %s', e.label)
end

CURE_CLICKS = {
    -- LABEL is what the row is titled; NAME is the item the client looks up and must stay exact.
    -- Shortened because these titles sit in front of a row of names and were a third of its width.
    { key = 'radiant', label = 'Radiant',   name = 'Radiant Cure' },
    { key = 'band',    label = 'Cleansing', name = 'Cleansing Band of Twilight' },
}
cureState = {}   -- driver: cureState[char][key] = { have, secs, updated }
cureLast  = {}   -- worker: last-pushed key per source

function cure_source(key)
    for _, e in ipairs(CURE_CLICKS) do if e.key == key then return e end end
    return nil
end

-- Do I have this, and can I fire it?
function have_thing(name)
    local checks = {
        function() return tlo_true(mq.TLO.FindItem('=' .. name)()) end,
        function() return (tonumber(mq.TLO.Me.AltAbility(name).Rank()) or 0) > 0 end,
        function() return tlo_true(mq.TLO.Me.Book(name)()) end,
        -- A DISCIPLINE REPORTS ITS INDEX, not true/false.
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

-- BUCKET A COUNTDOWN BEFORE USING IT AS AN IDENTITY.
function push_bucket(secs)
    local n = tonumber(secs) or 0
    if n <= 0 then return n end          -- ready, or 'none' - exact states, sent at once
    return 1                             -- on cooldown; how long is the payload's business
end

-- SAME CACHE AS ability_state, for the same reason and on the same measurement.
function cure_state(name)
    abilityKind = abilityKind or {}
    local ck = abilityKind[name]
    local it, itemID = nil, 0
    if ck == nil or ck == 'i' then
        pcall(function() it = mq.TLO.FindItem('=' .. name); itemID = tonumber(it.ID()) or 0 end)
    end
    if itemID > 0 then
        abilityKind[name] = 'i'
        local t = 0
        pcall(function() t = tonumber(it.TimerReady()) or 0 end)
        return 1, (t > 0) and math.floor(t) or 0
    end
    local rank, rdy = 0, false
    pcall(function() rank = tonumber(mq.TLO.Me.AltAbility(name).Rank()) or 0 end)
    pcall(function() rdy  = tlo_true(mq.TLO.Me.AltAbilityReady(name)()) end)
    if (rank > 0) or rdy then
        abilityKind[name] = 'a'
        if rdy then return 1, 0 end
        local s = -1
        pcall(function() s = tonumber(mq.TLO.Me.AltAbilityTimer(name).TotalSeconds()) or -1 end)
        return 1, (s and s > 0) and math.floor(s) or 0
    end
    -- Not an item and not an AA - but it may still be mine as a spell, disc or skill.
    if have_thing(name) then abilityKind[name] = 'd'; return 1, 0 end
    -- NOT CACHED WHEN NOTHING OWNS IT. An unknown name may be an item the character has not looted yet,
    -- and caching 'not mine' would make it invisible forever.
    return 0, -1
end

function cure_click(key)
    local e = cure_source(key)
    if not e then return end
    -- Same two-way test MGB had, same consequence: Radiant Cure is an AA, and an AA with no CastType is
    -- treated as a spell and memorised. cast_opts answers all three.
    at_cast(e.name .. cast_opts(e.name))
    log('[cure] %s', e.label)
end

-- Mini: cures, grouped by source with one button per OWNER.
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
        -- INVIS AND ITU BELONG TO THE INVIS SECTION, not here.
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
            do
                local e1 = byGroup[g][1]
                ui_row_label(g, e1.name or e1.spell or e1.aa, e1.name and 'item' or (e1.spell and 'spell') or 'aa')
            end
            ui_row_reset()
            ImGui.SameLine()
            uiRowStarted = true
            for bi, b in ipairs(btns) do
                ui_row_item(ui_fit_w(b.nm .. ' 00:00', UI_BTN_W))
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
                -- SAME SHAPE AS REZ AND NIGHTVEIL.
                if b.st.up == 1 and left > 0 then
                    ui_drain_bar(string.format('%d:%02d', math.floor(left / 60), left % 60),
                                 left / math.max(1, b.st.dsecs or left), { 90, 210, 255 },
                                 ui_fit_w(b.nm .. ' 00:00', UI_BTN_W))
                elseif r <= 0 then
                    if ui_name_button(face, 'at_magic_' .. b.e.key .. '_' .. b.nm, UI_READY) then
                        magicWanted = { key = b.e.key, nm = b.nm }
                    end
                else
                    ui_pill(string.format('%d:%02d', math.floor(r / 60), r % 60), { 217, 89, 89 }, UI_BTN_W)
                end
                if ui_tip_hover() then
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
            ui_row_label(e.label, e.name)
            ui_row_reset()
            ImGui.SameLine()
            uiRowStarted = true   -- the label is already on this line
            for oi, o in ipairs(owners) do
                ui_row_item(ui_fit_w(o.nm, UI_BTN_W))
                local r = o.st.secs or -1
                if r > 0 then r = math.max(0, r - math.floor((mq.gettime() - (o.st.updated or 0)) / 1000)) end
                local cr, cg, cb
                if r <= 0 then          cr, cg, cb = 0.36, 0.80, 0.46   -- green: can fire now
                elseif r < 60 then      cr, cg, cb = 0.95, 0.85, 0.30
                elseif r < 300 then     cr, cg, cb = 0.95, 0.62, 0.25
                else                    cr, cg, cb = 0.85, 0.35, 0.35 end
                -- Same shape as the rest: a name while it can fire, a countdown pill while it cannot.
                if r <= 0 then
                    if ui_name_button(o.nm, 'at_cure_' .. e.key .. '_' .. o.nm, UI_READY) then
                        if o.nm:lower() == myName:lower() then cure_click(e.key)
                        else peer_cmdf(o.nm, '/at_cure %s', e.key) end
                    end
                else
                    local rgb
                    if r < 60 then      rgb = { 242, 217,  77 }
                    elseif r < 300 then rgb = { 242, 158,  64 }
                    else                rgb = { 217,  89,  89 } end
                    ui_pill(string.format('%d:%02d', math.floor(r / 60), r % 60), rgb, UI_BTN_W)
                end
                if ui_tip_hover() then
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

-- The per-character scope buttons, shared by the mini section and the Rez tab.
rezWipeFlipAt = 0
-- CLOSE ALL ASKS FIRST.
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
    if ui_tip_hover() then
        pcall(function() ImGui.SetTooltip(armed
            and 'Press again to shut down AdventureTime on EVERY character.'
            or  'Shuts down AdventureTime on every character in the group.\nAsks once more before it does.') end)
    end
end

function draw_wipe_button(tag)
    local settled = (mq.gettime() - (rezWipeFlipAt or 0)) > 500
    if rezWipe then
        local hit = ui_stop_button('##wipe' .. tag, true)
        if hit and settled then
            rezWipe, rezWipeFlipAt = false, mq.gettime()
            pcall(function() peer_bcast('/at_wipe off') end)
            rezlog('[rez] wipe cleared for the group')
        end
        if ui_tip_hover() then
            pcall(function() ImGui.SetTooltip(
                'Rezzes are HELD. Clears itself when this character zones,\nor press this to start again now.') end)
        end
        ImGui.SameLine()
        ui_text(UI_WAIT, 'WIPE - rezzes held')
    else
        -- TEXT WHEN IT IS OFF, the sign when it is on.
        if ImGui.SmallButton('Wipe##wipe' .. tag) and settled then
            rezWipe, rezWipeFlipAt = true, mq.gettime()
            pcall(function() peer_bcast('/at_wipe on') end)
            pcall(function() mq.cmd('/gsay AdventureTime: WIPE - holding rezzes until we zone') end)
            rezlog('\\ay[rez] WIPE called - the group will not rez until it zones\\ax')
        end
        if ui_tip_hover() then
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
        else                     ui_push_text(UI_READY) end
        -- AS MUCH NAME AS FITS IN THE MINI, NINE IN THE TAB.
        if ImGui.SmallButton(nm:sub(1, wide and 9 or (uiChainNameLen or 4)) .. '##skip_'
                             .. (wide and 'w' or 'm') .. nm) then
            local nxt = (md == 'group') and 'off' or ((md == 'off') and 'raid' or 'group')
            chainMode[nm:lower()] = (nxt ~= 'group') and nxt or nil
            save_settings()
            pcall(function() peer_bcast('/at_chainskip %s %s', nm, nxt) end)
            rezlog('[rez] %s: %s', nm, (nxt == 'off') and 'no rezzes'
                                    or (nxt == 'raid') and 'group AND raid' or 'group only')
        end
        ImGui.PopStyleColor(1)
        if ui_tip_hover() then
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
        -- divine belongs in this test.
        if rr and ((rr.crown or -1) >= 0 or (rr.token or -1) >= 0
                   or (rr.cotw or -1) >= 0 or (rr.divine or -1) >= 0) then cols[#cols + 1] = nm end
    end
    -- The wipe button used to sit here. It is on the section HEADER now, so it stays reachable when the
    -- section is folded - which is exactly when you would still want it. One button, one place.
    if #cols == 0 then ImGui.TextDisabled('rez: no crown/token reports'); return end
    local flags = (ImGuiTableFlags.BordersInnerV or 0) + (ImGuiTableFlags.RowBg or 0)
                + (ImGuiTableFlags.SizingFixedFit or 0)
    -- SAME TREATMENT AS BURNS.
    uiChainNameLen = 99            -- draw_chain_modes shows the whole name in the mini again
    local rLabelW = ui_fit_w('Crown', 44)
    local rNameW = 0
    pcall(function()
        for _, nm in ipairs(cols) do
            local w = ui_fit_w(nm, 0)
            if w > rNameW then rNameW = w end
        end
    end)
    if rNameW <= 0 then rNameW = 60 end
    if not ImGui.BeginTable('##rezmini', 1 + #cols, flags) then return end
    ImGui.TableSetupColumn('', ImGuiTableColumnFlags.WidthFixed or 0, rLabelW)
    for _, nm in ipairs(cols) do
        ImGui.TableSetupColumn('', ImGuiTableColumnFlags.WidthFixed or 0, rNameW)
    end
    -- Clickable scope buttons, one per character - see draw_chain_modes.
    ImGui.TableNextRow()
    ImGui.TableNextColumn()
    -- The 'click a name' hint is gone.
    for _, nm in ipairs(cols) do
        ImGui.TableNextColumn()
        draw_chain_modes({ nm }, false)
    end
    local function row(which, label)
        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ui_row_label(label, (which == 'token') and TOKEN_ITEM or CROWN_ITEM, 'item')
        for _, nm in ipairs(cols) do
            ImGui.TableNextColumn()
            local rr = rezReady[nm]
            rez_cell(rr and rr[which] or -1, rr and rr.updated, 'rez:' .. nm .. ':' .. which)
        end
    end
    -- CotW on top: it fires first, so it reads first.
    if rezDivine or rezCotw then
        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ui_text(UI_LABEL, 'AA')   -- 'Rez' on a row inside the Rez panel was saying it twice
        for _, nm in ipairs(cols) do
            ImGui.TableNextColumn()
            local rr = rezReady[nm]
            local dv = (rezDivine and rr and rr.divine) or -1
            local cw = (rezCotw   and rr and rr.cotw)   or -1
            local v  = (dv >= 0) and dv or cw
            rez_cell(v, rr and rr.updated)
            if ui_tip_hover() and v >= 0 then
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
    -- Same order as everywhere else.
    local chars = {}
    for _, c in ipairs(ordered_members()) do
        if burnState[c] then chars[#chars + 1] = c end
    end
    if #chars == 0 then ImGui.TextDisabled('no burn reports yet'); return end
    -- A TABLE, so every tier starts at the same x for every character - a tier with nothing in it shows
    -- as an empty cell rather than shifting everything after it leftwards.
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
                    if ui_tip_hover() then
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
            ui_text(UI_LABEL, 'Who rezzes')
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
               if ui_tip_hover() then
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
               if ui_tip_hover() then
                   pcall(function() ImGui.SetTooltip(
                       'Cleric Divine Resurrection, ahead of Call of the Wild and the clickies.\n' ..
                       'Renewable, costs nothing, and returns more experience.') end)
               end
               rezCotw = ImGui.Checkbox('Call of the Wild first', rezCotw)
               if ui_tip_hover() then
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
            ImGui.Spacing(); ui_text(UI_LABEL, 'Rezzer Order')
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
                ImGui.Spacing(); ui_text(UI_LABEL, 'Recent rezzes')
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

-- Mini: one button per healer CLASS present in the group.
function mgb_button_state(nm, cfg)
    local st = (healState[nm] or {})[cfg.key]
    if not st then return 'unknown', {} end
    local age  = math.floor((mq.gettime() - (st.updated or 0)) / 1000)
    local rows, down = {}, false
    -- THE LONGEST REMAINING AMONG THE THINGS THAT GATE THE PRESS.
    local worst = 0
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
                if gates then down = true; if r > worst then worst = r end end
            else
                txt = label .. '  ready'
            end
        end
        rows[#rows + 1] = txt .. (note or '')
    end
    add(MGB_AA, st.mgb or -1, st.raid, st.raid and '' or '   (unused - not in raid)')
    for i, ab in ipairs(cfg.abils) do add(ab, (st.aas or {})[i] or -1, true) end
    return (down and 'down' or 'ready'), rows, st.raid, worst
end

-- Mini: one button per configured combo. Colour is the WORST of its members - green only when every
-- one of them could actually fire, since a green button that half-works is worse than no button.
function draw_combo_buttons()
    local first = true
    for ci, c in ipairs(COMBOS) do
        if #(c.members or {}) > 0 then
            local worst, rows, present = 'ready', {}, 0
            local worstSecs = 0
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
                    local st, srows, _, ws = mgb_button_state(who, e)
                    if st == 'down' then worst = 'down'
                    elseif st == 'unknown' and worst ~= 'down' then worst = 'unknown' end
                    -- THE COMBO IS ONLY AS READY AS ITS SLOWEST MEMBER.
                    if (ws or 0) > worstSecs then worstSecs = ws end
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
            local clabel = combo_label(c)
            local cface = clabel
            if worstSecs > 0 then
                cface = string.format('%s %d:%02d', clabel, math.floor(worstSecs / 60), worstSecs % 60)
            end
            local pushed = push_state_button(cr, cg, cb)
            if ImGui.Button(cface .. '##at_combo_' .. ci, ui_fit_w(clabel .. ' 00:00', UI_BTN_W), 0)
               and present > 0 then combo_fire(c) end
            pop_state_button(pushed)
            if ui_tip_hover() then
                local lines = { combo_label(c) }
                for _, r in ipairs(rows) do lines[#lines + 1] = '  ' .. r end
                pcall(function() ImGui.SetTooltip(table.concat(lines, '\n')) end)
            end
        end
    end
end

function draw_mgb_buttons()
    -- One button per (character, ability).
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
                local state, rows, raiding, worst = mgb_button_state(nm, e)
                local cr, cg, cb
                if state == 'unknown'  then cr, cg, cb = 0.55, 0.55, 0.55
                elseif state == 'down' then cr, cg, cb = 0.85, 0.35, 0.35
                else                        cr, cg, cb = 0.36, 0.80, 0.46 end
                -- STAYS A BUTTON.
                local face = label
                if (worst or 0) > 0 then
                    face = string.format('%s %d:%02d', label, math.floor(worst / 60), worst % 60)
                end
                local pushed = push_state_button(cr, cg, cb)
                if ImGui.Button(face .. '##at_mgb_' .. nm .. '_' .. e.key,
                                ui_fit_w(label .. ' 00:00', UI_BTN_W), 0) then
                    if nm:lower() == myName:lower() then mgb_click(e.key)
                    else peer_cmdf(nm, '/at_mgbclick %s', e.key) end
                end
                pop_state_button(pushed)
                if ui_tip_hover() then
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
    -- ONE WIDTH FOR THE ROW, measured once from the widest label plus room for a timer.
    local potW = 0
    for _, p in ipairs(GROUP_POTS) do potW = ui_fit_w(p.label .. ' 00:00', potW) end
    ui_row_reset()
    local iconRow = uiIcons and not ICON.broken
    for i, p in ipairs(GROUP_POTS) do
        local iname = (ICON.cache[p.base .. ' II'] == false) and (p.base .. ' I') or (p.base .. ' II')
        ui_row_item((iconRow and at_icon(iname, 'item')) and math.floor(ui_icon_size() * 1.6) or potW)
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
        -- ONE BUTTON FOR THE WHOLE GROUP, so the readout has to be the whole group's answer.
        local face = p.label
        if total > 0 and (worst or 0) > 0 and readyN < total then
            face = string.format('%s %d:%02d', p.label, math.floor(worst / 60), worst % 60)
        end
        local cap = ''
        if total > 0 and (worst or 0) > 0 and readyN < total then
            cap = string.format('%d:%02d', math.floor(worst / 60), worst % 60)
        end
        local iconSz = math.floor(ui_icon_size() * 1.6)
        local hit, hov = ui_icon_button('##at_poti_' .. p.key, iname, 'item', iconSz,
                                        { cr, cg, cb }, cap, total == 0 or readyN == 0)
        if hit == nil then
            local pushed = push_state_button(cr, cg, cb)
            if ImGui.Button(face .. '##at_pot_' .. p.key, potW, 0) then group_pot(p.key) end
            pop_state_button(pushed)
            hov = ImGui.IsItemHovered and ImGui.IsItemHovered()
        elseif hit then
            group_pot(p.key)
        end
        if hov then
            local lines = { string.format('%s  %d/%d up, %d/%d can click', p.label, upN, total, readyN, total) }
            for _, r in ipairs(rows) do lines[#lines + 1] = '  ' .. r end
            if #unknown > 0 then lines[#lines + 1] = '  no report yet: ' .. table.concat(unknown, ', ') end
            if #none > 0 then lines[#lines + 1] = '  carries none: ' .. table.concat(none, ', ') end
            pcall(function() ImGui.SetTooltip(table.concat(lines, '\n')) end)
        end
    end
    draw_effect_strip('pot')
end

-- Mini: CoTH gather on its own row.

-- ===== ALT CURRENCY -> ITEMS =====
ALTCUR_WND     = 'InventoryWindow'
ALTCUR_LIST_C  = 'IW_AltCurr_PointList'            -- control name ALONE, for /notify
ALTCUR_CREATE_C= 'IW_AltCurr_CreateItemButton'
ALTCUR_LIST    = 'InventoryWindow/IW_AltCurr_PointList'   -- slash-joined, for Window() READS only
-- /notify TAKES THE WINDOW AND THE CONTROL AS SEPARATE ARGUMENTS.

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
            -- CONTAINS, not equals - matching altcur_balance.
            if txt ~= '' and txt:lower():find(want, 1, true) then return i, rows end
        end
    end
    return nil, rows
end

-- Pull `qty` of a currency out as items.
ALTCUR_TAB = 4

-- FIND THE TAB RATHER THAN GUESS IT.
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

-- The reverse of a pull, and far simpler than one: select the currency row, press Reclaim, and the game
-- converts EVERY stack of that item in bags back into currency in a single action.
ALTCUR_RECLAIM_C = 'IW_AltCurr_ReclaimButton'
function altcur_reclaim(name)
    -- NO CURSOR GUARD.
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
        -- NAME THE LIKELY CAUSE.
        log('\\ay[altcur] %s is not in the currency list (%d row(s) shown) - cannot reclaim.\\ax',
            name, rows or 0)
        log('\\ay[altcur]   If the inventory has "show only currency I own" ticked, a zero balance is '
            .. 'hidden - untick it and this works. %d %s are in bags waiting.\\ax', before, name)
        altcur_close_if(wasOpen)
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

    altcur_close_if(wasOpen)
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

    -- OPEN THE WINDOW AND SHOW THE TAB.
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

    -- ONE PRESS GIVES ONE STACK.
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
        -- QUANTITY, THE WAY LAZCRAFT DOES IT.
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

    -- STOW IT, AND STOP IF IT WILL NOT GO.
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
            altcur_close_if(wasOpen)
            local sofar = 0
            pcall(function() sofar = tonumber(mq.TLO.FindItemCount('=' .. name)()) or 0 end)
            return math.max(0, sofar - before)
        end
        break   -- no coins appeared: end the loop, the round-yield check below reports it
    end

    local held = ''
    pcall(function() held = tostring(mq.TLO.Cursor.Name() or '') end)
    -- RETRY THE STOW.
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
        -- COUNT THE FREE SLOTS rather than claim the bags are full.
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
        -- PUT IT BACK rather than leave it dangling.
        pcall(function() mq.cmdf('/notify %s IW_AltCurr_ReclaimButton leftmouseup', ALTCUR_WND) end)
        mq.delay(1200, function() return (mq.TLO.Cursor.ID() or 0) == 0 end)
        if (mq.TLO.Cursor.ID() or 0) == 0 then
            log('[altcur] put the stuck stack back into currency - cursor is clear')
        else
            log('\\ar[altcur] could not reclaim it either - %s is still on the cursor, clear it by hand\\ax',
                (held ~= '') and held or name)
        end
        altcurStuck = true
        altcur_close_if(wasOpen)
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
    altcur_close_if(wasOpen)

    local got = after - before
    altcur_announce(name)
    if got > 0 then log('\\ag[altcur] pulled %d %s (now %d in bags)\\ax', got, name, after)
    else          log('\\ay[altcur] pulled nothing - %s still reads %d in bags\\ax', name, after) end
    return got
end

-- ===== TRIBUTE =====
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
    -- on its own.
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

-- Donate `qty` of one named item.
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

        -- SELECT it.
        local confirm = ''
        pcall(function() confirm = tostring(mq.TLO.Me.Inventory('pack' .. bag).Item(sl).Name() or '') end)
        if confirm:lower() ~= item:lower() then
            log('\\ar[tribute] pack%d slot %d now holds "%s", not %s - NOT clicking it. Stopping.\\ax',
                bag, sl, (confirm ~= '') and confirm or 'nothing', item)
            break
        end
        mq.cmdf('/itemnotify in pack%d %d leftmouseup', bag, sl)
        -- WAIT FOR DONATE TO ENABLE, do not sleep a fixed 500ms and then test.
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

        -- WAIT FOR THE COUNT TO ACTUALLY DROP before scanning again.
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

    -- TIDY UP.
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

-- Give out ONE item, end to end, touching nothing else.
function give_out_one(item, currency)
    if distributing then log('[dc] busy - already distributing'); return end
    distributing = true
    local ok, err = pcall(function()
        local roster = group_members()
        if #roster <= 1 then log('\\ay[dc] no group members found\\ax'); return end
        local peers = {}
        for _, m in ipairs(roster) do if m:lower() ~= myName:lower() then peers[#peers + 1] = m end end

        -- READS EVERYTHING, same as any other refresh.
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
                    local askedAt = mq.gettime()
                    pcall(function() peer_cmdf(who, '/atpull %s %d', currency:gsub(' ', '_'), pull) end)
                    local deadline = mq.gettime() + math.min(180000, 6000 + math.ceil(pull / 200) * 2500)
                    -- WAIT FOR THE REPORT, NOT A QUERY SLOT.
                    while mq.gettime() < deadline do
                        mq.doevents(); mq.delay(500)
                        local c = counts[who:lower()]
                        if c and c.__altAt and c.__altAt >= askedAt then break end
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
                        -- /at_give_multi handoff and the wait-for-done.
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
-- After a /memspell, how long before the first cast.
EP_MEM_SETTLE = 1500
-- Consecutive failed memorise attempts before the pause is released.
EP_OPTS = '/NoInterrupt'
EP_FREE_RETRIES = 4
EP_MEM_TRIES = 3
-- Per attempt, not per memorise. Three of these is the same 7.5s of patience the single 10s block had,
-- minus the part where the whole script stopped for it.
EP_MEM_WAIT  = 2500
-- How long the gem must read READY CONTINUOUSLY after a memorise before the first cast. A single sample
-- can land in a gap where the timer reads 0 mid-settle; holding for this long cannot.
EP_GEM_STEADY = 750
epGemSteadyAt = nil
epMemFails = 0
epMemWaitSaid = 0
EP_CHECK_AFTER = 1000    -- pause after the cast completes before looking at the mob
-- How many ticks we will spend trying to get back onto a mob to READ it.
EP_CHECK_TRIES = 8
-- Longest a single placate cast may stay in flight before it is abandoned. Generous: the cast plus its
-- verification retries is a few seconds, and an emergency heal chain on top is a few more.
EP_CAST_HARD_MAX = 30000
-- How long to wait for the caster to be free before casting anyway. The placate caster is usually the
-- healer too, so an unbounded wait starves placate entirely in a zone that keeps it healing.
EP_BUSY_MAX = 3000
epBusySince = nil
EP_RETRY   = 3
EP_LINGER  = 8000

-- ONE PAUSE for the whole placate run: from before the memorise through to the gear going back on.
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
E3HOLD = {}
BOT_HOLD_MODE = BOT_HOLD_MODE or nil
function bot_control_valid(v)
    return v == 'auto' or v == 'e3' or v == 'rgmercs'
end

function bot_control_label(v)
    return BOT_CONTROL_LABEL[v or 'auto'] or BOT_CONTROL_LABEL.auto
end

function rgmercs_running()
    local ok, running = pcall(function()
        return mq.TLO.Lua.Script('rgmercs').Status.Equal('RUNNING')() == true
    end)
    return ok and running == true
end

function rgmercs_run_move_paused()
    if not rgmercs_running() then return false end
    local ok, val = pcall(function()
        return mq.TLO.RGMercs.Config('RunMovePaused')() == true
    end)
    return ok and val == true
end

function active_bot_control()
    -- rg.lua pins this: an RGMercs launch is RGMercs whatever the saved setting says.
    if bot_control_valid(AT_FORCE_BOT) and AT_FORCE_BOT ~= 'auto' then return AT_FORCE_BOT end
    if not bot_control_valid(botControl) then botControl = 'auto' end
    if botControl == 'auto' then
        return rgmercs_running() and 'rgmercs' or 'e3'
    end
    return botControl
end

function bot_pause_cmd()
    local mode = active_bot_control()
    if mode == 'rgmercs' then
        if not rgmercs_running() then
            rezlog('\\ar[bot] RGMercs bot control selected, but rgmercs is not running - cannot pause automation\\ax')
            return 'rgmercs', false
        end
        mq.cmd('/rgl pause')
        if rgmercs_run_move_paused() then
            rezlog('\\ay[bot] RGMercs Chase/Camp While Paused is ON. Turn off with /rgl set runmovepaused false\\ax')
        end
        return 'rgmercs', true
    end
    mq.cmd('/e3p on')
    return 'e3', true
end

function bot_resume_cmd(mode)
    mode = mode or BOT_HOLD_MODE or active_bot_control()
    if mode == 'rgmercs' then
        if not rgmercs_running() then
            rezlog('\\ay[bot] RGMercs bot control selected, but rgmercs is not running - nothing to resume\\ax')
            return 'rgmercs', false
        end
        mq.cmd('/rgl unpause')
        return 'rgmercs', true
    end
    mq.cmd('/e3p off')
    return 'e3', true
end

function bot_control_can_verify()
    return (BOT_HOLD_MODE or active_bot_control()) == 'e3'
end

-- IS E3 ACTUALLY PAUSED?
e3PausedSaidRaw = false
function e3_is_paused()
    local v
    pcall(function() v = mq.TLO.MQ2Mono.Query('e3', 'E3N.State.Basics.IsPaused')() end)
    local s = (v == nil) and '' or tostring(v):lower()
    -- SAY WHAT THE BRIDGE ACTUALLY RETURNS, once, the first time it is asked.
    if not e3PausedSaidRaw then
        e3PausedSaidRaw = true
        rezlog('[e3] pause probe returns "%s" (want true/false; anything else means the query did not '
            .. 'resolve and every pause check is blind)', s)
    end
    -- ONLY AN EXPLICIT TRUE OR FALSE IS AN ANSWER.
    if s == 'true' or s == '1' then return true end
    if s == 'false' or s == '0' then return false end
    return nil
end

local function e3_holders()
    local n = 0
    for _ in pairs(E3HOLD) do n = n + 1 end
    return n
end
-- nowait = send the pause and carry on, without waiting for E3 to confirm it.
function e3_hold(owner, nowait)
    owner = owner or 'unknown'
    if E3HOLD[owner] then return end          -- idempotent per owner: strip may ask after the mem did
    local was = e3_holders()
    E3HOLD[owner] = true
    if was == 0 then
        local mode, sent = bot_pause_cmd()
        if not sent then E3HOLD[owner] = nil; return end
        BOT_HOLD_MODE = mode
        if mode ~= 'e3' then return end
        if nowait then return end
        -- /e3p IS QUEUED, NOT IMMEDIATE.
        mq.delay(2500, function() return e3_is_paused() == true end)
        local st = e3_is_paused()
        if st == false then
            -- STILL CASTING?
            local casting = 0
            pcall(function() casting = tonumber(mq.TLO.Me.Casting.ID()) or 0 end)
            if casting > 0 then
                rezlog('[e3] pause is queued behind a cast in flight - waiting for it to finish')
                mq.delay(6000, function()
                    return (tonumber(mq.TLO.Me.Casting.ID()) or 0) == 0 and e3_is_paused() == true
                end)
                st = e3_is_paused()
            end
        end
        if st == false then
            -- It took the command and is still running. Say it plainly rather than carrying on and
            -- wondering later why E3 healed through a placate or stepped on a /nowcast.
            rezlog('\\ar[e3] asked E3 to pause and it reports it is still RUNNING - retrying once\\ax')
            bot_pause_cmd()
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
-- CALLED ON THE TICK WHILE WE HOLD IT.
function e3_assert_held()
    if e3_holders() == 0 then return end
    if not bot_control_can_verify() then return end
    if e3_is_paused() == false then
        rezlog('\\ar[e3] E3 came back up while %d hold(s) were still on it - pausing it again\\ax',
               e3_holders())
        bot_pause_cmd()
        mq.delay(2500, function() return e3_is_paused() == true end)
    end
end

function e3_release(owner)
    owner = owner or 'unknown'
    if not E3HOLD[owner] then return end
    E3HOLD[owner] = nil
    if e3_holders() == 0 then bot_resume_cmd(BOT_HOLD_MODE); BOT_HOLD_MODE = nil end
end
-- Unconditional: for the way out and for /atresume, where the point is to leave nothing held whatever
-- anyone thinks they own.
function e3_release_all()
    for k in pairs(E3HOLD) do E3HOLD[k] = nil end
    bot_resume_cmd(BOT_HOLD_MODE)
    BOT_HOLD_MODE = nil
end

-- STOW WHATEVER IS ON THE CURSOR.
function cursor_stow(tag)
    if (mq.TLO.Cursor.ID() or 0) == 0 then return true end
    local held = tostring(mq.TLO.Cursor.Name() or '?')
    pcall(function() mq.cmd('/autoinventory') end)
    mq.delay(600, function() return (mq.TLO.Cursor.ID() or 0) == 0 end)
    if (mq.TLO.Cursor.ID() or 0) == 0 then
        rezlog('[%s] stowed %s off the cursor', tag or 'cursor', held)
        return true
    end
    -- PUT IT IN A BAG BY HAND.
    for b = 1, 10 do
        local cont = 0
        pcall(function() cont = tonumber(mq.TLO.Me.Inventory('pack' .. b).Container()) or 0 end)
        for sl = 1, cont do
            local occupied = true
            pcall(function()
                occupied = (tonumber(mq.TLO.Me.Inventory('pack' .. b).Item(sl).ID()) or 0) > 0
            end)
            if not occupied then
                pcall(function() mq.cmdf('/itemnotify in pack%d %d leftmouseup', b, sl) end)
                mq.delay(600, function() return (mq.TLO.Cursor.ID() or 0) == 0 end)
                if (mq.TLO.Cursor.ID() or 0) == 0 then
                    rezlog('[%s] stowed %s into pack%d slot %d', tag or 'cursor', held, b, sl)
                    return true
                end
            end
        end
    end
    rezlog('\\ar[%s] %s will not leave the cursor and there is no free bag slot\\ax', tag or 'cursor', held)
    return false, held
end

-- WHAT TO CALL THE PAUSE IN A LOG LINE.
function e3_pause_note()
    if (BOT_HOLD_MODE or active_bot_control()) == 'rgmercs' then return 'RGMercs paused' end
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
    rezlog('[placate] bot control resumed (%s)', why or 'done')
end

-- WHO CAN WORK THE PLACATE QUEUE.
EP_CLASSES = { ENC = true, CLR = true, PAL = true, DRU = true }
-- WHO ACTUALLY WORKS THE QUEUE when more than one character can.
pacOff = pacOff or {}     -- [nameLower] = true when taken out of the rotation
-- PER CHARACTER GEM.
pacGem = pacGem or {}     -- [nameLower] = gem number
pacQueue = pacQueue or {}
function pac_find(id)
    for i, e in ipairs(pacQueue) do if e.id == id then return i, e end end
    return nil
end
-- Who the group has elected.
pacCap = {}   -- [char] = { cap, spell, range, kind, updated }

-- What I can pacify with, whatever class I am. Returns spell name, level cap, range - or nil.
function pac_self()
    local sp, kind, spID
    if ep_can_placate() then
        -- VALIDATE THE GEM, do not just read it.
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
        -- ONLY READ THE GEM'S ID IF THE GEM HOLDS A PLACATE.
        local gemID = 0
        if gemSp then pcall(function() gemID = tonumber(mq.TLO.Me.Gem(ep_gem_num()).ID()) or 0 end) end
        local gemCap, bookCap = capof(gemSp, gemID), capof(bookSp, epBestPlacateID)
        -- CARRY THE ID, not just the name.
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
    -- THE ANNOUNCED CEILING, read by ID when we have one.
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
    -- RANGE THROUGH THE EXISTING RESOLVERS, not a fresh MyRange read.
    local rng = 0
    if kind == 'placate' then rng = ep_range() or 0
    else                      rng = pw_range() or 0 end
    if rng <= 0 then
        pcall(function() rng = tonumber(mq.TLO.Spell(sp).MyRange()) or 0 end)
        if rng <= 0 then pcall(function() rng = tonumber(mq.TLO.Spell(sp).Range()) or 0 end) end
    end
    return sp, cap, rng, kind
end

-- Who should take a mob of this level.
function pac_announce()
    local sp, cap, rng, kind = pac_self()
    if not sp then return false end
    pacCap[myName] = { cap = cap, spell = sp, range = rng, kind = kind, updated = mq.gettime() }
    pcall(function() peer_bcast('/at_paccap %s %d %d %s', myName, cap or 0, rng or 0, kind or '?') end)
    log('[pacify] I can pacify with %s - caps at level %d, range %d', sp, cap or 0, rng or 0)
    -- ANNOUNCE AGAIN IF THE RANGE IS STILL THE FALLBACK.
    local resolved = (kind == 'placate') and (epRangeCache ~= nil) or (pwRangeCache ~= nil)
    if not resolved then
        pacAnnounceAt = mq.gettime() + 60000
        log('[pacify] range not resolved yet (using %d) - will re-check in a minute', rng)
    end
    return true
end

-- Who should take a mob of this level AT this distance.
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

-- WHAT THE LAST BATCH WAS.
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
            -- LEVEL CAP, checked here rather than in the casting queues.
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
                        -- everybody's queue by the manual button.
                        epQueue[#epQueue + 1] = { id = e.id, name = e.name, oor = false, farSince = nil,
                                                  mine = true }
                        -- HOLD E3 NOW, not at the mem a tick later.
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
function pac_rebalance()
    local moved = 0
    for _ = 1, 8 do          -- bounded: a pull is small and this runs on every add
        local pick
        for _, e in ipairs(pacQueue or {}) do
            -- not state: already done, failed or ruled too high - settled, leave it.
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
        -- NO STALENESS CHECK.
        local capOk = (c.cap or 0) >= (mobLevel or 0) and not pacOff[nm:lower()]
        -- No distance given means "do not filter on it" - the caller did not know, so neither do we.
        local rngOk = (not dist) or dist <= 0 or (c.range or 0) >= dist
        if capOk and rngOk then
            -- SPREAD THE WORK, THEN PREFER THE LOW CEILING.
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
function loot_my_corpse(wantID)
    local id = tonumber(wantID) or 0
    if id <= 0 then
        pcall(function() id = corpse_id_exact(myName) end)
    end
    if id <= 0 then return end

    -- STOP CASTING FIRST.
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

    -- NOTHING TO TAKE.

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

-- A character's class does not change, so it is read once. This ran twice a tick on every toon.
function at_my_class()
    if (AT_MY_CLASS or '') == '' then
        pcall(function() AT_MY_CLASS = tostring(mq.TLO.Me.Class.ShortName() or ''):upper() end)
    end
    return AT_MY_CLASS or ''
end
function ep_can_placate()
    return EP_CLASSES[at_my_class()] == true
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

-- IS THAT ACTUALLY A PLACATE?
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

-- THE BEST PLACATE THIS ENCHANTER OWNS.
epBestPlacate = nil     -- false = looked and found none, so we do not scan again every tick
epBestMissAt = 0        -- when the last fruitless scan ran, so a miss can be retried
epBestMissN  = 0        -- how many fruitless scans in a row, so the retry can back off

-- Tribute favor is a readout, not a decision.
if perfScale == nil then perfScale = 1 end   -- 1 normal, 3 for a machine that is struggling
function pace(ms) return math.floor((ms or 0) * (perfScale or 1)) end

REZ_PUSH_MS   = 1000    -- rez clicky timers; the driver counts them down itself
REZ_PUSH_IDLE_MS = 5000 -- the same, while no corpse is in the zone
UPKEEP_MS     = 1000    -- zone watch and background bookkeeping
lastRezPush   = 0
lastUpkeep    = 0
CLICK_POLL_MS = 5000    -- how often the whole click block is read; see the note at the poll
STATE_PUSH_MS = 2000    -- how often the invis + Nightveil push block is read; see the note there
lastStatePush = 0
CLICK_MISS_MS = 30000
clickOwn  = {}   -- key -> true once we have ever seen it owned
clickMiss = {}   -- key -> when we last checked something we do not own

function click_should_read(key)
    if clickOwn[key] then return true end
    local last = clickMiss[key] or 0
    if (mq.gettime() - last) < pace(CLICK_MISS_MS) then return false end
    -- STAGGERED, so every unowned entry does not come due on the same poll and spike it.
    clickMiss[key] = mq.gettime() + math.random(0, 10000)
    return true
end

function click_saw(key, owned)
    if owned then clickOwn[key] = true end
end

TRIB_KEEP_MS = 300000
-- The panel's own failsafe refresh.
TRIB_POLL_MS = 300000
-- How often a worker LOOKS at its own tribute state.
TRIB_WATCH_MS = 10000
lastTribPoll  = 0
-- Set when a peer's tribute report arrives; cleared by the tick after the rendered rows are rebuilt.
tribRowsDirty = false
tribKeepAt   = 0
tribDrawnAt  = 0        -- when the tribute panel last drew; the poll follows it
epCapSaid    = false    -- log the ceiling working once per session
epBestPlacateID = 0     -- the ID of the book spell we chose, so nothing re-looks it up by name
function ep_best_placate()
    if epBestPlacate then return epBestPlacate end
    -- A MISS IS NOT A FACT, IT IS A READING - and readings this early are unreliable.
    if epBestPlacate == false then
        local wait = math.min(300000, 30000 * (2 ^ math.min(epBestMissN or 0, 4)))
        if (mq.gettime() - (epBestMissAt or 0)) < wait then return nil end
    end
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
        pcall(function() sid = tonumber(mq.TLO.Me.Book(i).ID()) or 0 end)
        if nm ~= '' and nm ~= 'NULL' and sid > 0 then
            if ep_spell_ok(nm) then
                -- RANK BY MaxLevel, NOT BY THE SPELL'S OWN LEVEL.
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
    if best then epBestMissN = 0 end
    if best then
        -- Both numbers, because they differ and the difference is the whole point of this choice.
        -- ID included: if two spells share a name, this is the one that decided the ceiling.
        rezlog('[placate] best placate in my book: %s [id %d] (ceiling %d, spell level %d)',
               best, epBestPlacateID or 0, bestCap, bestLvl)
    else
        epBestMissAt = mq.gettime()
        epBestMissN  = (epBestMissN or 0) + 1
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
    -- PAUSE E3 FOR THE MEM.
    ep_pause()
    -- DO NOT MEM INTO A LIVE E3.
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
    -- WAIT SHORT, RETRY ACROSS TICKS.
    mq.delay(EP_MEM_WAIT, function() return (mq.TLO.Me.Gem(ep_gem_num()).Name() or '') == want end)
    local now = ''
    pcall(function() now = tostring(mq.TLO.Me.Gem(ep_gem_num()).Name() or '') end)
    if now ~= want then
        rezlog('\\ar[placate] could not mem %s into gem %d (it reads "%s")\\ax', want, ep_gem_num(), now)
        -- HOLD THE PAUSE ACROSS RETRIES.
        epMemFails = (epMemFails or 0) + 1
        if epMemFails >= EP_MEM_TRIES then
            rezlog('\\ar[placate] giving up on the gem after %d tries (%dms of waiting) - releasing E3\\ax',
                   epMemFails, epMemFails * EP_MEM_WAIT)
            epMemFails = 0
            ep_resume('mem failed repeatedly')
        end
        return false
    end
    epMemFails = 0
    -- STAND UP AND SHUT THE BOOK.
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
    -- LET THE CHARACTER SETTLE BEFORE THE FIRST CAST.
    epMemDoneAt = mq.gettime()
    -- E3 stays paused from here: the strip and the casting follow immediately, and ep_restore hands it
    -- back once the gear is on.
    rezlog('[placate] %s is memmed in gem %d', want, ep_gem_num())
    return true
end

-- CAST RANGE FOR PLACATE.
EP_RANGE_FALLBACK = 200
-- How long a mob may sit out of reach before it is given up on.
EP_FAR_MAX = 10000
epRangeCache = nil
function ep_range()
    if epRangeCache then
        if not epRangeCacheUntil or mq.gettime() < epRangeCacheUntil then return epRangeCache end
        epRangeCache, epRangeCacheUntil = nil, nil
    end
    -- TAKE THE RANGE STRAIGHT OFF A DETRIMENTAL SPELL.
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
                pcall(function() ben = tlo_true(mq.TLO.Spell(gn).Beneficial()) end)
            if not ben then
                local mr = 0
                pcall(function() mr = tonumber(mq.TLO.Spell(gn).MyRange()) or 0 end)
                if mr > best then best, from = mr, gn end
            end
        end
    end
    if best > 0 then
        epRangeCache, epRangeCacheUntil = best, nil
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
    if r <= 0 then r = EP_RANGE_FALLBACK end
    if r ~= epRangeSaid then
        epRangeSaid = r
        rezlog('[placate] no detrimental memmed to read a focused range from - using %d unfocused', r)
    end
    -- Cached for 30s rather than for good: a detrimental memmed later should still win.
    epRangeCache = r
    epRangeCacheUntil = mq.gettime() + 30000
    return r
end
-- BOTH THE GEM AND THE SPELL.
function ep_gem_ready()
    local t = -1
    pcall(function() t = tonumber(mq.TLO.Me.GemTimer(ep_gem_num()).TotalSeconds()) or -1 end)
    if t ~= 0 then return false end
    local sp, rdy = ep_spell(), false
    if not sp or sp == '' then return true end   -- nothing to ask about; the timer is all we have
    pcall(function() rdy = tlo_true(mq.TLO.Me.SpellReady(sp)()) end)
    return rdy
end

-- A ONE-LINE SNAPSHOT OF THE QUEUE, logged whenever it CHANGES.
epQueueSig = ''
function ep_queue_log(why)
    local parts = {}
    for i, e in ipairs(epQueue) do
        -- ID as well as name.
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
    -- Local only, same reason.
end

-- Strip the three slots.
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

-- RE-ENTRANT ON PURPOSE, up to EP_STRIP_PASSES.

-- =========================================================================== RAID MOVES - reorganise
-- groups without touching the window
-- =========================================================================== THERE IS NO COMMAND FOR
-- THIS.
RAID_WND   = 'RaidWindow'
RAID_LISTS = { 'RAID_PlayerList', 'RAID_NotInGroupPlayerList' }
-- How much of a name the roster shows. Names are cut, never abbreviated with dots: an ellipsis costs a
-- character's width to say 'there was more', which the reader can already tell.
RAID_NAME_CHARS = 8
function raid_short(name)
    name = tostring(name or '')
    if #name <= RAID_NAME_CHARS then return name end
    return name:sub(1, RAID_NAME_CHARS)
end
-- HOLD THE LOCK ACROSS MOVES, DO NOT CYCLE IT PER MOVE.
raidWeLocked, raidLockLinger, raidLockAt = false, 0, 0
RAID_LOCK_HOLD = 6000   -- quiet time before the lock goes back
-- How long after OUR lock the lists are assumed untrustworthy.
RAID_STALE_TRIES = 3
raidStaleTries = 0
raidMoveWant = nil

-- Which listbox holds this name, and on what row.
RAID_NAME_COL = 2

-- ASK THE BUTTONS, NOT THE TLO.
function raid_is_locked()
    local unlockOn, lockOn = nil, nil
    pcall(function() unlockOn = tlo_true(mq.TLO.Window(RAID_WND).Child('RAID_UnlockButton').Enabled()) end)
    pcall(function() lockOn   = tlo_true(mq.TLO.Window(RAID_WND).Child('RAID_LockButton').Enabled()) end)
    if unlockOn ~= nil and lockOn ~= nil and unlockOn ~= lockOn then return unlockOn end
    if unlockOn == true then return true end
    if lockOn == true then return false end
    local t = false
    pcall(function() t = tlo_true(mq.TLO.Raid.Locked()) end)
    return t
end

function raid_lock_report()
    local u, l, t = 'n/a', 'n/a', 'n/a'
    pcall(function() u = tostring(mq.TLO.Window(RAID_WND).Child('RAID_UnlockButton').Enabled()) end)
    pcall(function() l = tostring(mq.TLO.Window(RAID_WND).Child('RAID_LockButton').Enabled()) end)
    pcall(function() t = tostring(mq.TLO.Raid.Locked()) end)
    return string.format('UnlockBtn=%s LockBtn=%s Raid.Locked=%s -> locked=%s',
                         u, l, t, tostring(raid_is_locked()))
end

function raid_find_row_once(name)
    for _, lst in ipairs(RAID_LISTS) do
        local row = 0
        pcall(function()
            row = tonumber(mq.TLO.Window(RAID_WND).Child(lst).List(name .. ', ' .. RAID_NAME_COL)()) or 0
        end)
        if row > 0 then return lst, row end
        for c = 1, 6 do
            if c ~= RAID_NAME_COL then
                pcall(function()
                    row = tonumber(mq.TLO.Window(RAID_WND).Child(lst).List(name .. ', ' .. c)()) or 0
                end)
                if row > 0 then return lst, row end
            end
        end
    end
    return nil, 0
end

-- WALK THE ROWS OURSELVES when the by-name lookup comes up empty.
function raid_scan_rows(name)
    local want = name:lower()
    local function cell(lst, r, c)
        local v = ''
        pcall(function()
            v = tostring(mq.TLO.Window(RAID_WND).Child(lst).List(r .. ', ' .. c)() or '')
        end)
        if v == 'NULL' then v = '' end
        return v
    end
    for _, lst in ipairs(RAID_LISTS) do
        local rows = 0
        pcall(function() rows = tonumber(mq.TLO.Window(RAID_WND).Child(lst).Items()) or 0 end)
        for r = 1, rows do
            if cell(lst, r, RAID_NAME_COL):lower() == want then return lst, r end
            for c = 1, 6 do
                if c ~= RAID_NAME_COL and cell(lst, r, c):lower() == want then
                    rezlog('[raid] found %s in column %d, not %d - the name column moved',
                           name, c, RAID_NAME_COL)
                    return lst, r
                end
            end
        end
    end
    return nil, 0
end

-- OPENED ONCE, NOT KEPT OPEN.
raidPrimed = false
function raid_prime_window()
    if raidPrimed then return end
    -- NOT IN A RAID, NOTHING TO PRIME.
    local members = 0
    pcall(function() members = tonumber(mq.TLO.Raid.Members()) or 0 end)
    if members <= 0 then return end
    raidPrimed = true
    local wasOpen = false
    pcall(function() wasOpen = (mq.TLO.Window(RAID_WND).Open() == true) end)
    if not wasOpen then
        pcall(function() mq.TLO.Window(RAID_WND).DoOpen() end)
        mq.delay(800, function() return mq.TLO.Window(RAID_WND).Open() == true end)
    end
    -- Wait for ROWS, not a fixed nap: the point is that the roster filled, and how long that takes is
    -- the client's business.
    mq.delay(1200, function()
        local n = 0
        pcall(function() n = tonumber(mq.TLO.Window(RAID_WND).Child('RAID_PlayerList').Items()) or 0 end)
        return n > 0
    end)
    local rows = 0
    pcall(function() rows = tonumber(mq.TLO.Window(RAID_WND).Child('RAID_PlayerList').Items()) or 0 end)
    -- SHUT IT, AND CONFIRM IT SHUT.
    local left = 'open'
    if not wasOpen then
        for _ = 1, 3 do
            pcall(function() mq.TLO.Window(RAID_WND).DoClose() end)
            mq.delay(600, function() return mq.TLO.Window(RAID_WND).Open() ~= true end)
            local o = false
            pcall(function() o = (mq.TLO.Window(RAID_WND).Open() == true) end)
            if not o then left = 'shut again'; break end
        end
        if left ~= 'shut again' then
            rezlog('\\ay[raid] could not close the raid window again after priming - leaving it open\\ax')
            left = 'STILL OPEN'
        end
    end
    rezlog('[raid] primed the raid window (%s) - %d row(s), left %s',
           wasOpen and 'was already open' or 'opened it', rows, left)
end

function raid_find_row(name)
    -- Still called here as a backstop - the flag makes it free once it has run, and a re-arm on zoning
    -- lands here rather than costing a startup.
    raid_prime_window()
    -- 'empty' is the client's placeholder text for an unused group slot, and there are dozens of them.
    -- Matching one would select a slot rather than a player and hand a click to whatever is highlighted.
    if name:lower() == 'empty' then return nil, 0 end
    -- RETRY, BECAUSE THE LIST REBUILDS.
    for attempt = 1, 4 do
        local lst, row = raid_find_row_once(name)
        if lst then return lst, row end
        lst, row = raid_scan_rows(name)
        if lst then
            if attempt > 1 then rezlog('[raid] found %s by scanning rows, not by name lookup', name) end
            return lst, row
        end
        -- 400, not 250: the settle that was measured to work after a window re-flow.
        mq.delay(400)
    end
    -- Say what IS in the list, so a repeat of this is diagnosable from the log rather than from a
    -- separate command run afterwards when the state has moved on.
    local total, named = 0, 0
    for _, lst in ipairs(RAID_LISTS) do
        local rows = 0
        pcall(function() rows = tonumber(mq.TLO.Window(RAID_WND).Child(lst).Items()) or 0 end)
        total = total + rows
        local before = named
        -- EVERY ROW, NOT THE FIRST FORTY.
        local names, shown = {}, 0
        for r = 1, rows do
            local v = ''
            pcall(function()
                v = tostring(mq.TLO.Window(RAID_WND).Child(lst).List(r .. ', ' .. RAID_NAME_COL)() or '')
            end)
            if v ~= '' and v ~= 'NULL' and v ~= 'empty' then
                named = named + 1
                if shown < 12 then
                    shown = shown + 1
                    names[#names + 1] = r .. ':' .. v
                end
            end
        end
        -- PER LIST, not cumulative.
        local thisList = named - before
        if thisList > shown then names[#names + 1] = '(+' .. (thisList - shown) .. ' more)' end
        rezlog('[raid] %s holds %d row(s), %d named: %s', lst, rows, named - before,
               table.concat(names, ' '))
        -- WHEN NOTHING READ, SAY WHAT ROW 1 DOES HOLD, across every column.
        if rows > 0 and named == before then
            local cols = {}
            for c = 1, 6 do
                local v = ''
                pcall(function()
                    v = tostring(mq.TLO.Window(RAID_WND).Child(lst).List('1, ' .. c)() or '')
                end)
                cols[#cols + 1] = c .. '="' .. ((v ~= 'NULL') and v or '') .. '"'
            end
            rezlog('[raid]   row 1 by column: %s', table.concat(cols, ' '))
            -- And a row from further down, because row 1 being an unused slot says nothing about
            -- whether the roster is populated at all.
            if rows >= 45 then
                local c2 = {}
                for c = 1, 6 do
                    local v = ''
                    pcall(function()
                        v = tostring(mq.TLO.Window(RAID_WND).Child(lst).List('45, ' .. c)() or '')
                    end)
                    c2[#c2 + 1] = c .. '="' .. ((v ~= 'NULL') and v or '') .. '"'
                end
                rezlog('[raid]   row 45 by column: %s', table.concat(c2, ' '))
            end
        end
    end
    -- A BAD READ HAS TWO SHAPES AND THIS ONLY KNEW ONE.
    return nil, 0, (total == 0 or named == 0)
end

function raid_group_of(name)
    local n = 0
    pcall(function() n = tonumber(mq.TLO.Raid.Members()) or 0 end)
    for i = 1, n do
        local nm = ''
        pcall(function() nm = tostring(mq.TLO.Raid.Member(i).Name() or '') end)
        if nm:lower() == name:lower() then
            local g = -1
            pcall(function() g = tonumber(mq.TLO.Raid.Member(i).Group()) or -1 end)
            return g
        end
    end
    return nil
end

-- inner: called from raid_place, which runs up to four moves for one placement.
function raid_move(name, group, inner)
    if not win_exists_raw(RAID_WND) then
        log('\\ar[raid] the raid window has never been opened this session - open it once, then retry\\ax')
        return false
    end
    local was = raid_group_of(name)
    if was == nil then
        log('\\ar[raid] %s is not in the raid\\ax', name)
        return false
    end
    if was == group then
        log('[raid] %s is already in group %d', name, group)
        return true
    end
    -- THE GROUP BUTTONS ONLY WORK ON A LOCKED RAID.
    local wasLocked = raid_is_locked()
    rezlog('[raid] lock state before the move: %s', raid_lock_report())
    if not wasLocked then
        pcall(function() mq.cmdf('/nomodkey /notify %s RAID_LockButton leftmouseup', RAID_WND) end)
        mq.delay(1200, function() return raid_is_locked() end)
        if not raid_is_locked() then
            log('\\ar[raid] could not lock the raid - the group buttons stay disabled while unlocked, '
                .. 'so the move cannot go through. Are you the leader?\\ax')
            return false
        end
        -- OURS NOW, AND WE KEEP IT. Recorded on the module rather than in a local, because the unlock no
        -- longer happens in this call - the tick does it once the moves stop coming.
        raidWeLocked, raidLockAt = true, mq.gettime()
        rezlog('[raid] locked the raid (it was unlocked) - holding it for %dms of quiet', RAID_LOCK_HOLD)
        mq.delay(400)
    end
    -- Every move pushes the release out, so a batch runs under one lock.
    if raidWeLocked then raidLockLinger = mq.gettime() + RAID_LOCK_HOLD end
    -- The unlock used to live here. It does not any more: putting the lock back after each move meant the
    -- NEXT move paid the rebuild again, and the rebuild is the thing that breaks the lookup.
    local function done(ok) return ok end

    local lst, row, stale = raid_find_row(name)
    if not lst then
        -- STALE, NOT ABSENT.
        if stale then
            raidStaleTries = (raidStaleTries or 0) + 1
            if raidStaleTries <= RAID_STALE_TRIES then
                rezlog('[raid] both rosters empty but %s IS in the raid - stale window, requeuing (try %d of %d)',
                       name, raidStaleTries, RAID_STALE_TRIES)
                -- DROP THE LOCK SO THE NEXT TRY TAKES A FRESH ONE.
                if raidWeLocked then
                    raidWeLocked, raidLockLinger, raidLockAt = false, 0, 0
                    pcall(function() mq.cmdf('/nomodkey /notify %s RAID_UnlockButton leftmouseup', RAID_WND) end)
                    mq.delay(1200, function() return not raid_is_locked() end)
                    rezlog('[raid] dropped our lock before retrying (locked=%s)', tostring(raid_is_locked()))
                end
                raidBlindFail = true
                if not inner then raidMoveWant = { name = name, group = group } end
                return false
            end
            log('\\ar[raid] the raid roster has read unusable %d times running, across %d fresh lock(s) - '
                .. 'either no rows at all, or rows with no readable names. Open the raid window once so '
                .. 'the client fills it in, then retry.\\ax', raidStaleTries, raidStaleTries)
            raidStaleTries = 0
            return done(false)
        end
        log('\\ar[raid] %s is in the raid but not in either list - cannot select them\\ax', name)
        return done(false)
    end
    -- A good read clears the counter, so a later stale patch gets its full allowance.
    raidStaleTries = 0
    pcall(function() mq.cmdf('/nomodkey /notify %s %s listselect %d', RAID_WND, lst, row) end)
    -- WAIT FOR THE SELECTION, do not nap and hope.
    local sel = 0
    local function sel_now()
        local v = 0
        pcall(function() v = tonumber(mq.TLO.Window(RAID_WND).Child(lst).GetCurSel()) or 0 end)
        return v
    end
    mq.delay(1200, function() return sel_now() == row end)
    sel = sel_now()
    if sel ~= row then
        log('\\ar[raid] selected row %d but the list reports %d - not clicking\\ax', row, sel)
        return done(false)
    end
    local btn = (group == 0) and 'RAID_NoGroupButton' or ('RAID_Group' .. group .. 'Button')
    pcall(function() mq.cmdf('/nomodkey /notify %s %s leftmouseup', RAID_WND, btn) end)
    -- The server has to answer before Raid.Member reports the new group, so give it a beat rather than
    -- reading back instantly and calling a working move a failure.
    mq.delay(1200, function() return raid_group_of(name) == group end)
    local now = raid_group_of(name)
    if now == group then
        log('[raid] %s: group %d -> %d', name, was, group)
        -- Let the window re-flow before anybody looks at it again. A multi-step swap does three of these
        -- back to back and the second lookup was landing 48ms after the first move.
        mq.delay(400)
        -- REPAINT THE PANEL NOW, do not wait out the 2.5s poll.
        RAID.at = 0
        pcall(raid_poll)
        return done(true)
    end
    log('\\ay[raid] %s still reads group %s after the click (wanted %d) - the button was disabled. '
        .. 'Leader only, and the raid must be locked\\ax', name, tostring(now), group)
    return done(false)
end

-- =========================================================================== FEED GATING - do not
-- report what nobody is looking at
-- =========================================================================== ONLY FOR FEEDS NOTHING
-- DECIDES ON.
FEED_WANT = { burns = true, nv = true }

function feed_wanted(name)
    local v = FEED_WANT[name]
    if v == nil then return true end
    return v and true or false
end

-- Driver: what the panel currently needs. A section that is popped out still counts as visible.
function feed_state_now()
    return { burns = (miniBurns or popOut['burns']) and true or false,
             nv    = (miniNightveil or popOut['nightveil']) and true or false }
end

feedSentKey = ''
function feed_announce(force)
    if not SHOW_UI then return end
    local w = feed_state_now()
    local k = (w.burns and '1' or '0') .. (w.nv and '1' or '0')
    if not force and k == feedSentKey then return end
    feedSentKey = k
    FEED_WANT.burns, FEED_WANT.nv = w.burns, w.nv
    pcall(function()
        peer_bcast('/at_want %d %d', w.burns and 1 or 0, w.nv and 1 or 0)
    end)
    rezlog('[feed] wants: burns=%s nightveil=%s', tostring(w.burns), tostring(w.nv))
end

-- =========================================================================== RAID PLACEMENT - capacity
-- aware, and routed to whoever actually leads
-- =========================================================================== WHY A PLAIN MOVE IS NOT
-- ENOUGH.
RAID_GROUP_MAX = 6

-- ASK THE RIGHT CHARACTER.
function raid_request_place(name, group)
    local leader = raid_my_leader()
    if not leader then
        log('\\ay[raid] %s leads the raid - only the leader can move people between groups\\ax',
            (raid_leader_name() ~= '') and raid_leader_name() or 'nobody we control')
        return false
    end
    if leader:lower() == myName:lower() then
        raidMoveWant = { name = name, group = group, place = true }
    else
        pcall(function()
            peer_cmdf(leader, '/at_raidplace %s %d', name, group)
        end)
        log('[raid] asked %s to put %s in group %d', leader, name, group)
    end
    return true
end

-- Same routing as placements: only the leader's client has these buttons enabled, and the leader is
-- often a worker rather than the character showing the panel.
function raid_request_action(kind, name)
    local leader = raid_my_leader()
    if not leader then
        log('\\ay[raid] %s leads the raid - only the leader can do that\\ax',
            (raid_leader_name() ~= '') and raid_leader_name() or 'nobody we control')
        return false
    end
    if leader:lower() == myName:lower() then
        raidMoveWant = { name = name, action = kind }
    else
        pcall(function() peer_cmdf(leader, '/at_raidact %s %s', kind, name) end)
        log('[raid] asked %s to %s %s', leader, kind, name)
    end
    return true
end

function raid_leader_name()
    local l = ''
    pcall(function() l = tostring(mq.TLO.Raid.Leader() or '') end)
    if l == 'NULL' then l = '' end
    return l
end

-- Is the raid led by ME, or by one of my own characters? Returns the name, or nil if the raid is led by
-- somebody we cannot drive.
function raid_my_leader()
    local l = raid_leader_name()
    if l == '' then return nil end
    if l:lower() == myName:lower() then return l end
    for _, nm in ipairs(group_members()) do
        if nm:lower() == l:lower() then return l end
    end
    return nil
end

-- =========================================================================== EXPEDITIONS AND TASKS -
-- who of ours leads one ===========================================================================
-- SAME PROBLEM AS THE RAID BUTTONS, SAME ANSWER.

-- Is this name one of our characters? Pulled out of raid_my_leader, which asked the same question.
function one_of_ours(name)
    if name == nil or name == '' then return false end
    if name:lower() == myName:lower() then return true end
    for _, nm in ipairs(group_members()) do
        if nm:lower() == name:lower() then return true end
    end
    return false
end

-- tlo_str: read a TLO member and say WHICH kind of nothing came back.
function tlo_str(fn)
    local v
    local ok = pcall(function() v = fn() end)
    if not ok then return '', false end
    if v == nil then return '', true end
    local sv = tostring(v)
    if sv == 'NULL' then sv = '' end
    return sv, true
end

function dz_name()        return (tlo_str(function() return mq.TLO.DynamicZone.Name() end)) end
function dz_leader_name() return (tlo_str(function() return mq.TLO.DynamicZone.Leader() end)) end

-- TWO WAYS TO ASK, BECAUSE ONLY ONE OF THEM MAY EXIST.
function task_leader_name(idx)
    idx = idx or 1
    local l = tlo_str(function() return mq.TLO.Task(idx).Leader() end)
    if l ~= '' then return l end
    local n = tonumber((tlo_str(function() return mq.TLO.Task(idx).Members() end))) or 0
    for i = 1, n do
        local flag = tlo_str(function() return mq.TLO.Task(idx).Member(i).Leader() end)
        if flag:lower() == 'true' then
            return (tlo_str(function() return mq.TLO.Task(idx).Member(i).Name() end))
        end
    end
    return ''
end

function task_name(idx) return (tlo_str(function() return mq.TLO.Task(idx or 1).Title() end)) end

-- Returns the name of whichever of ours leads it, or nil. Mirrors raid_my_leader exactly.
function dz_my_leader()
    local l = dz_leader_name()
    if l ~= '' and one_of_ours(l) then return l end
    return nil
end

function task_my_leader(idx)
    local l = task_leader_name(idx)
    if l ~= '' and one_of_ours(l) then return l end
    return nil
end

-- Why the menu item is not offered, in the words the log should use. Says which of the three it is
-- rather than a flat 'cannot' - 'nobody is in one' and 'a stranger leads it' want different responses.
function dz_why_not()
    if dz_name() == '' then return 'not in an expedition' end
    local l = dz_leader_name()
    if l == '' then return 'cannot read who leads it' end
    return l .. ' leads it'
end

function task_why_not(idx)
    if task_name(idx) == '' then return 'not on a shared task' end
    local l = task_leader_name(idx)
    if l == '' then return 'cannot read who leads it' end
    return l .. ' leads it'
end

-- ASK THE HOLDER. Runs it here when we are the leader, relays when a worker is, and refuses out loud
-- rather than firing a command the client will silently drop.
function dz_request_add(name)
    local leader = dz_my_leader()
    if not leader then
        log('\\ay[dz] cannot add %s - %s\\ax', name, dz_why_not())
        return false
    end
    if leader:lower() == myName:lower() then
        pcall(function() mq.cmdf('/dzadd %s', name) end)
        log('[dz] /dzadd %s', name)
    else
        pcall(function() peer_cmdf(leader, '/at_dzadd %s', name) end)
        log('[dz] asked %s to /dzadd %s', leader, name)
    end
    return true
end

function task_request_add(name)
    local leader = task_my_leader()
    if not leader then
        log('\\ay[task] cannot add %s - %s\\ax', name, task_why_not())
        return false
    end
    if leader:lower() == myName:lower() then
        pcall(function() mq.cmdf('/taskadd %s', name) end)
        log('[task] /taskadd %s', name)
    else
        pcall(function() peer_cmdf(leader, '/at_taskadd %s', name) end)
        log('[task] asked %s to /taskadd %s', leader, name)
    end
    return true
end

-- Everyone currently in a group, from the raid roster.
function raid_members_in(group)
    local out = {}
    local n = 0
    pcall(function() n = tonumber(mq.TLO.Raid.Members()) or 0 end)
    for i = 1, n do
        local nm, g = '', -1
        pcall(function() nm = tostring(mq.TLO.Raid.Member(i).Name() or '') end)
        pcall(function() g  = tonumber(mq.TLO.Raid.Member(i).Group()) or -1 end)
        if nm ~= '' and g == group then out[#out + 1] = nm end
    end
    table.sort(out)
    return out
end

-- PUT name IN group, hopping through no-group only when the destination is actually full.
raidBlindFail = false
function raid_place_result(ok, name, group)
    if ok then return true end
    if raidBlindFail then
        raidBlindFail = false
        rezlog('[raid] placement of %s into group %d hit the blind window - requeuing the placement', name, group)
        raidMoveWant = { name = name, group = group, place = true }
    end
    return false
end

-- WHO COMES OUT OF A FULL GROUP: whoever the roster lists last, which is arbitrary but predictable.
function raid_place(name, group)
    -- Cleared here so the checks below only ever see a flag raised by THIS placement.
    raidBlindFail = false
    local was = raid_group_of(name)
    if was == nil then log('\\ar[raid] %s is not in the raid\\ax', name); return false end
    if was == group then log('[raid] %s is already in group %d', name, group); return true end

    local occupants = (group > 0) and raid_members_in(group) or {}
    local full = (group > 0) and (#occupants >= RAID_GROUP_MAX)
    if not full then
        -- Room at the destination, so this is one click and no shuffling.
        return raid_place_result(raid_move(name, group, true), name, group)
    end

    -- Full: pick who comes out. Last on the roster, skipping the traveller themselves.
    local out
    for i = #occupants, 1, -1 do
        if occupants[i]:lower() ~= name:lower() then out = occupants[i]; break end
    end
    if not out then
        log('\\ar[raid] group %d is full and there is nobody in it to move out\\ax', group)
        return false
    end
    log('[raid] group %d is full - swapping %s with %s', group, name, out)
    -- Traveller out first. This frees their old slot, which is where the displaced member will land, so
    -- the destination has a hole the moment we need one.
    if not raid_move(name, 0, true) then return raid_place_result(false, name, group) end
    if was > 0 then
        if not raid_move(out, was, true) then
            -- Put the traveller back rather than leaving them in no-group.
            raid_move(name, was, true)
            return raid_place_result(false, name, group)
        end
    else
        if not raid_move(out, 0, true) then return raid_place_result(false, name, group) end
    end
    return raid_place_result(raid_move(name, group, true), name, group)
end

-- SELECT A NAME AND CLICK A BUTTON, verified at both ends.
function raid_select(name)
    local lst, row, stale = raid_find_row(name)
    if not lst then
        -- 'Cannot find' is a claim about the roster. Do not make it when the roster did not load.
        if stale then
            log('\\ar[raid] both raid rosters read empty - the window has not filled in. Try again\\ax')
        else
            log('\\ar[raid] cannot find %s in the raid list\\ax', name)
        end
        return false
    end
    pcall(function() mq.cmdf('/nomodkey /notify %s %s listselect %d', RAID_WND, lst, row) end)
    -- Polled, for the reason spelled out in raid_move: a fixed nap was the difference between a move that
    -- worked and a move that reported the list empty.
    local function sel_now()
        local v = 0
        pcall(function() v = tonumber(mq.TLO.Window(RAID_WND).Child(lst).GetCurSel()) or 0 end)
        return v
    end
    mq.delay(1200, function() return sel_now() == row end)
    local sel = sel_now()
    if sel ~= row then
        log('\\ar[raid] selected row %d for %s but the list reports %d - not clicking\\ax', row, name, sel)
        return false
    end
    return true
end

-- TWO DIFFERENT ROLES, ONE BUTTON.
function raid_member_flags(name)
    local n = 0
    pcall(function() n = tonumber(mq.TLO.Raid.Members()) or 0 end)
    for i = 1, n do
        local nm = ''
        pcall(function() nm = tostring(mq.TLO.Raid.Member(i).Name() or '') end)
        if nm:lower() == name:lower() then
            local gl, rl = false, false
            pcall(function() gl = tlo_true(mq.TLO.Raid.Member(i).GroupLeader()) end)
            pcall(function() rl = tlo_true(mq.TLO.Raid.Member(i).RaidLeader()) end)
            return gl, rl
        end
    end
    return nil, nil
end

function raid_make_leader(name)
    local wasG, wasR = raid_member_flags(name)
    if wasG == nil then log('\\ar[raid] %s is not in the raid\\ax', name); return false end
    if not raid_select(name) then return false end
    pcall(function() mq.cmdf('/nomodkey /notify %s RAID_MakeLeaderButton leftmouseup', RAID_WND) end)
    mq.delay(2000, function()
        local g, r = raid_member_flags(name)
        return (g and not wasG) or (r and not wasR)
    end)
    local g, r = raid_member_flags(name)
    if r and not wasR then
        log('[raid] %s is now the RAID leader', name)
        return true
    end
    if g and not wasG then
        log('[raid] %s is now the GROUP leader of group %s', name, tostring(raid_group_of(name)))
        return true
    end
    log('\\ay[raid] nothing changed for %s (groupLeader=%s raidLeader=%s) - the button may be disabled\\ax',
        name, tostring(g), tostring(r))
    return false
end

-- THE OTHER ROUTE, and an honest unknown.
function raid_makeleader_cmd(name)
    local wasG = raid_member_flags(name)
    pcall(function() mq.cmdf('/makeleader %s', name) end)
    mq.delay(2000, function()
        local g = raid_member_flags(name)
        return g and not wasG
    end)
    local g, r = raid_member_flags(name)
    log('[raid] /makeleader %s -> groupLeader=%s raidLeader=%s', name, tostring(g), tostring(r))
    return (g and not wasG) or false
end

-- REMOVE SOMEBODY FROM THE RAID.
function raid_remove(name)
    if not raid_select(name) then return false end
    -- Confirm the highlighted row STILL names our target. Nothing should have changed in 250ms, and that
    -- is exactly why a change here means something is wrong and the click must not happen.
    local lst, row = raid_find_row(name)
    local sel = 0
    pcall(function() sel = tonumber(mq.TLO.Window(RAID_WND).Child(lst or '').GetCurSel()) or 0 end)
    if not lst or sel ~= row then
        log('\\ar[raid] the selection moved before the remove - aborting\\ax')
        return false
    end
    local before = 0
    pcall(function() before = tonumber(mq.TLO.Raid.Members()) or 0 end)
    pcall(function() mq.cmdf('/nomodkey /notify %s RAID_DisbandButton leftmouseup', RAID_WND) end)
    mq.delay(2000, function() return raid_group_of(name) == nil end)
    if raid_group_of(name) == nil then
        log('[raid] %s removed from the raid (%d -> %s)', name, before,
            tostring(mq.TLO.Raid.Members()))
        return true
    end
    log('\\ay[raid] %s is still in the raid - the button may be disabled (leader only)\\ax', name)
    return false
end

-- =========================================================================== WINDOW PROBE - what
-- controls does a UI window actually have?
WINPROBE_MAX_NODES = 600
WINPROBE_MAX_DEPTH = 8

function win_probe(root)
    local path = at_dir() .. 'AdventureTime_' .. myName .. '_window_' .. root .. '.txt'
    local fh = io.open(path, 'w')
    if not fh then log('\\ar[win] could not write %s\\ax', (path:gsub('\\', '/'))); return end
    fh:write(string.format('=== %s on %s - %s ===\n', root, myName, os.date('%Y-%m-%d %H:%M:%S')))
    local open = win_open_raw(root)
    fh:write(string.format('window open: %s\n\n', tostring(open)))
    local n = 0

    local function walk(w, depth)
        while w and n < WINPROBE_MAX_NODES do
            local nm, ty, tx, en = '', '', '', ''
            pcall(function() nm = tostring(w.Name() or '') end)
            pcall(function() ty = tostring(w.Type() or '') end)
            pcall(function() tx = tostring(w.Text() or '') end)
            pcall(function() en = tostring(w.Enabled() or '') end)
            -- A node with nothing at all means the walk has run off the end of the tree; the TLO returns
            -- an int 0 rather than nil there, which reads as an empty object instead of stopping.
            if nm == '' and ty == '' and tx == '' then return end
            n = n + 1
            -- Text is trimmed and newlines flattened: a chat-style control can hold a whole screenful
            -- and one control per line is what makes this readable.
            tx = tx:gsub('[\r\n]+', ' '):sub(1, 60)
            fh:write(string.format('%s%-28s %-18s enabled=%-5s %s\n',
                     string.rep('  ', depth), nm, ty, en, tx))
            if depth < WINPROBE_MAX_DEPTH then
                local c = nil
                pcall(function() c = w.FirstChild end)
                if c then pcall(function() walk(c, depth + 1) end) end
            end
            local nxt = nil
            pcall(function() nxt = w.Next end)
            w = nxt
        end
    end

    local first = nil
    pcall(function() first = mq.TLO.Window(root).FirstChild end)
    if first then pcall(function() walk(first, 1) end) end
    fh:write(string.format('\n%d control(s) listed%s\n', n,
             (n >= WINPROBE_MAX_NODES) and ' (CAPPED - there are more)' or ''))
    fh:close()
    -- FORWARD SLASHES WHEN PRINTING A PATH.
    log('[win] %s: %d control(s) written to %s', root, n, (path:gsub('\\', '/')))
    if not open then
        log('\\ay[win] note: %s is CLOSED - open it and run this again for the full tree\\ax', root)
    end
end

-- =========================================================================== RAID ROSTER - who is in
-- which group, read straight off the client
-- =========================================================================== CHEAP AND LOCAL.
RAID_MAX_GROUPS = 12
-- POLLED, NOT READ WHILE DRAWING.
RAID_POLL_MS = 8000
-- drawnAt: when draw_raid last ran, so polling follows the panel.
-- corpse:   carried between polls, because the corpse search is round-robinned.
RAID = { cache = nil, n = 0, at = 0, drawnAt = 0, corpse = {}, scanBudget = 0 }

RAID_SCAN_PER_POLL = 4   -- corpse searches allowed per poll; the rest wait their turn

-- DISTANCE BANDS. Green nearby, yellow drifting, red gone walkabout, grey not in the zone at all, and
-- orange for a corpse - which is the one you want to spot from across the panel, so it is the loudest.
RAID_NEAR = 250          -- under this is 'with the group'
RAID_FAR  = 500          -- over this is 'where have they gone'
RAID_COL_NEAR = { 115, 204, 128 }   -- green
RAID_COL_MID  = { 230, 200,  90 }   -- yellow
RAID_COL_FAR  = { 216,  90,  90 }   -- red
RAID_COL_GONE = { 140, 140, 148 }   -- grey: no spawn, another zone
RAID_COL_DEAD = { 255, 150,  40 }   -- orange

function raid_poll()
    RAID.corpse = RAID.corpse or {}
    RAID.scanBudget = RAID_SCAN_PER_POLL
    local n = 0
    pcall(function() n = tonumber(mq.TLO.Raid.Members()) or 0 end)
    if n <= 0 then RAID.cache, RAID.n, RAID.at = nil, 0, mq.gettime(); return end
    local groups = {}
    for i = 1, n do
        local nm, g, gl, cls, lvl = '', 0, false, '', 0
        -- ONE RESOLVE, NOT NINE.
        local M = mq.TLO.Raid.Member(i)
        pcall(function() nm  = tostring(M.Name() or '') end)
        pcall(function() g   = tonumber(M.Group()) or 0 end)
        pcall(function() gl  = tlo_true(M.GroupLeader()) end)
        pcall(function() cls = tostring(M.Class.ShortName() or '') end)
        pcall(function() lvl = tonumber(M.Level()) or 0 end)
        if nm ~= '' and nm ~= 'NULL' then
            -- Group 0 means unassigned - the raid window's holding area. It is a real state and worth
            -- seeing, so it gets a tile of its own rather than being dropped.
            g = (g >= 0 and g <= RAID_MAX_GROUPS) and g or 0
            groups[g] = groups[g] or {}
            -- THREE STATES, cheapest test first.
            local id, dist, dead = 0, -1, false
            local SP = M.Spawn
            pcall(function() id = tonumber(SP.ID()) or 0 end)
            if id > 0 then
                pcall(function() dist = tonumber(SP.Distance3D()) or -1 end)
                if dist < 0 then
                    pcall(function() dist = tonumber(SP.Distance()) or -1 end)
                end
                pcall(function() dead = tlo_true(SP.Dead()) end)
            else
                -- ROUND ROBIN, NOT EVERY ABSENT MEMBER EVERY POLL.
                if RAID.scanBudget > 0 then
                    RAID.scanBudget = RAID.scanBudget - 1
                    local c = 0
                    pcall(function() c = corpse_count_exact(nm) end)
                    RAID.corpse[nm] = (c > 0)
                end
                dead = RAID.corpse[nm] or false
            end
            table.insert(groups[g], { name = nm, leader = gl, cls = cls, lvl = lvl,
                                      here = (id > 0) or dead, dist = dist, dead = dead })
        end
    end
    for _, list in pairs(groups) do
        table.sort(list, function(a, b)
            if a.leader ~= b.leader then return a.leader end
            return a.name < b.name
        end)
    end
    RAID.cache, RAID.n, RAID.at = groups, n, mq.gettime()
end

-- Called from the main loop. Only pays when the section is actually being looked at.
function raid_tick()
    if not miniRaid then return end
    -- BEHIND THE CADENCE GATE, not in front of it.
    if (mq.gettime() - (RAID.drawnAt or 0)) > 3000 then return end
    if (mq.gettime() - (RAID.at or 0)) < pace(RAID_POLL_MS) then return end
    local n = 0
    pcall(function() n = tonumber(mq.TLO.Raid.Members()) or 0 end)
    if n <= 0 then
        RAID.at = mq.gettime()
        if RAID.cache then RAID.cache, RAID.n = nil, 0 end
        return
    end
    -- The cadence gate is at the top now, so there is nothing left to check here.
    raid_poll()
end

-- RIGHT-CLICK MENU ON A RAID PILL.

function raid_context_menu(m, canLead)
    local ok = pcall(function()
        if not ImGui.BeginPopupContextItem then return end
        if not ImGui.BeginPopupContextItem('##raidctx_' .. m.name) then return end
        ui_text(UI_HEAD, m.name)
        ImGui.Separator()

        if canLead then
            -- Groups 1-12 plus no-group. raid_place works out whether the destination has room and
            -- hops through 0 only when it has to.
            if ImGui.BeginMenu and ImGui.BeginMenu('Move to group') then
                for g = 1, RAID_MAX_GROUPS do
                    if g ~= m.group and ImGui.MenuItem(tostring(g)) then
                        raid_request_place(m.name, g)
                    end
                end
                ImGui.Separator()
                if ImGui.MenuItem('No group') then raid_request_place(m.name, 0) end
                ImGui.EndMenu()
            end
            if ImGui.MenuItem('Make leader (raid button)') then
                raid_request_action('leader', m.name)
            end
            -- Separate item because it is a DIFFERENT MECHANISM, not a nicer name for the same one. If
            -- the button turns out to set group leader and the command sets it too, one of these can go.
            if ImGui.MenuItem('Make group leader (/makeleader)') then
                raid_request_action('gleader', m.name)
            end
            ImGui.Separator()
            -- Named, not just 'Remove from raid' - the name on the item is what stops this being a blind
            -- click now that there is no second one.
            if ImGui.MenuItem('Remove ' .. m.name .. ' from raid') then
                raid_request_action('remove', m.name)
            end
            ImGui.Separator()
        end

        -- LEADER ONLY, AND NOT NECESSARILY THIS CHARACTER.
        local dzL, taskL = dz_my_leader(), task_my_leader()
        if dzL then
            if ImGui.MenuItem('Add to expedition  (' .. dzL .. ')') then
                dz_request_add(m.name)
            end
        else
            ImGui.TextDisabled('Add to expedition  -  ' .. dz_why_not())
        end
        if taskL then
            if ImGui.MenuItem('Add to task  (' .. taskL .. ')') then
                task_request_add(m.name)
            end
        else
            ImGui.TextDisabled('Add to task  -  ' .. task_why_not())
        end
        ImGui.EndPopup()
    end)
    if not ok and not RAID_SAID_POPUP then
        RAID_SAID_POPUP = true
        log('\\ar[raid] this ImGui binding has no right-click menu support, so the roster is read-only - '
            .. 'use /atraidmove <name> <group>\\ax')
    end
end

function draw_raid()
    -- THE DRAW IS THE SIGNAL, same as the tribute panel. A 36 person roster is hundreds of TLO reads;
    -- refreshing it while nobody is looking is the most expensive pointless thing in the file.
    RAID.drawnAt = mq.gettime()
    -- First look pays for itself rather than showing an empty panel for two and a half seconds.
    if not RAID.cache and (RAID.at or 0) == 0 then pcall(raid_poll) end
    local groups, n = RAID.cache, RAID.n
    if not groups then ImGui.TextDisabled('not in a raid'); return end
    local leader = raid_leader_name()
    -- COLLAPSIBLE, like every other panel.
    local okA = pcall(function()
        if ImGui.SmallButton((raidFolded and '[+]' or '[-]') .. '##raid_fold') then
            raidFolded = not raidFolded
            save_settings()
        end
    end)
    if okA then ImGui.SameLine(0, 4) end
    -- CAN WE ACTUALLY DRIVE THIS RAID?
    local canLead = raid_my_leader() ~= nil
    ui_text(UI_HEAD, string.format('%d in the raid%s', n,
            (leader ~= '') and ('  -  ' .. leader .. ' leads') or ''))
    if canLead and not raidFolded then
        ImGui.SameLine()
        ui_text({ 0.45, 0.80, 0.50 }, '  right-click a name')
    end
    -- Everything past here is the roster itself, which is the part worth folding away.
    if raidFolded then return end
    ImGui.Spacing()
    local keys = {}
    for g in pairs(groups) do keys[#keys + 1] = g end
    table.sort(keys)
    for _, g in ipairs(keys) do
        local list = groups[g]
        ui_text(UI_LABEL, (g == 0) and 'unassigned' or ('Group ' .. g))
        for _, m in ipairs(list) do
            ImGui.SameLine()
            -- GREY ELSEWHERE, RED DEAD, GREEN HERE - the three things a roster is checked for, in that
            -- order of importance.
            -- TANKS BY NAME, everyone else by class: the name is on hover.
            local cu = tostring(m.cls or ''):upper()
            local isTank = TANK_CLASS[cu] == true
            local rgb, label = RAID_COL_GONE, isTank and raid_short(m.name) or (cu ~= '' and cu or raid_short(m.name))
            if m.dead then
                rgb   = RAID_COL_DEAD
                label = (isTank and m.name or label) .. ' \226\128\160'          -- dagger, so it reads without the colour
            elseif m.here then
                local d = m.dist or -1
                rgb = (d < 0) and RAID_COL_NEAR
                   or (d < RAID_NEAR) and RAID_COL_NEAR
                   or (d < RAID_FAR) and RAID_COL_MID
                   or RAID_COL_FAR
            end
            ui_pill(m.leader and ('*' .. label) or label, rgb, 0)
            -- The menu attaches to the LAST ITEM DRAWN, so it has to come straight after the pill.
            m.group = g
            raid_context_menu(m, canLead)
            if ui_tip_hover() then
                -- string.format first: SetTooltip takes ONE string in this binding, and passing format
                -- arguments to it fails inside the pcall and silently shows no tooltip at all.
                local tip = string.format('%s  %s %d%s%s%s%s\n\n%s', m.name, m.cls, m.lvl,
                        m.leader and '\ngroup leader' or '',
                        ((m.dist or -1) >= 0) and string.format('\n%d away', m.dist) or '',
                        m.dead and '\nDEAD - corpse in this zone' or '',
                        (not m.here) and '\nnot in this zone' or '',
                        string.format('green under %d   yellow to %d   red beyond\ngrey another zone   orange a corpse',
                                      RAID_NEAR, RAID_FAR))
                pcall(function() ImGui.SetTooltip(tip) end)
            end
        end
        ImGui.Spacing()
    end
end

-- Re-running is safe as long as epSaved is not clobbered: a slot stripped on pass one now reads empty,
-- and overwriting its saved name with '' would lose the item's identity for the restore.
EP_STRIP_PASSES = 3
epStripPass     = 0
epStripDead     = false   -- a pickup exhausted its retries; abandon the strip instead of repeating it
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
        if epStripDead then
            rezlog('\\ar[placate] pickups are not taking at all on this character - abandoning the strip '
                .. 'rather than grinding through %d more pass(es)\\ax', EP_STRIP_PASSES - epStripPass)
            epStripDead, epStripPass = false, 0
            ep_restore('pickups not taking')
            return false
        end
        rezlog('[placate] a slot is still equipped - strip pass %d of %d', epStripPass, EP_STRIP_PASSES)
    else
        epSaved, epStripAt, epStripPass = {}, mq.gettime(), 1
    end
    -- PAUSE E3 FOR THE WHOLE RUN.
    ep_pause()
    -- REMEMBER THE TARGET ONCE, not per mob.
    epPrevTarget = 0
    pcall(function() epPrevTarget = tonumber(mq.TLO.Target.ID()) or 0 end)
    rezlog('[placate] %s; stripping weapons before the first cast...', e3_pause_note())
    -- Record BEFORE removing anything.
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
        -- SAY WHAT WE READ AND WHAT WE DID, per slot.
        if nm == '' then
            rezlog('[placate]   %s: reads empty - nothing to take off', slot)
        else
            -- VERIFY EVERY STEP, one slot at a time.
            clear_cursor()
            mq.delay(400, function() return (mq.TLO.Cursor.ID() or 0) == 0 end)
            if (mq.TLO.Cursor.ID() or 0) ~= 0 then
                rezlog('\\ar[placate]   %s: cursor will not clear before pickup - skipping this slot\\ax', slot)
                goto continue_slot
            end

            -- SIX, NOT THREE.
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
                -- SIX FAILURES RUNNING IS NOT FLAKY TIMING, it is a client that will not pick anything
                -- up - and the next two slots are about to find that out at the same price.
                epStripDead = true
                break
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
    elseif #kept == 0 then
        rezlog('[placate] nothing to strip - all three slots were already empty')
    end
    -- 'already empty' used to be a plain else, so a run where nothing came off and everything was still
    -- equipped printed 'all three slots were already empty' directly above 'could NOT remove: mainhand,
    -- offhand, ranged'. Both lines were about the same three slots.
    if #kept > 0 then
        rezlog('\\ar[placate] could NOT remove: %s - a proc from those may break the placate\\ax',
               table.concat(kept, ', '))
    end
    -- CONFIRM EACH ITEM IS FINDABLE BEFORE WE GO ANYWHERE.
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
    -- BAGS OPEN FOR THE WHOLE RESTORE.
    toggle_all_bags()
    for _, slot in ipairs(EP_SLOTS) do
        local original = epSaved[slot] or ''
        local now = ''
        pcall(function() now = tostring(mq.TLO.Me.Inventory(slot).Name() or '') end)
        if now ~= original then
            -- SAME VERIFY-EACH-STEP AS THE STRIP, in reverse.
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
    -- SECOND AND THIRD ATTEMPT.
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
        -- LOUD, and the file STAYS.
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

-- Runs on every toon; returns immediately on anyone who is not an enchanter.
epTestRuns = 0
epTestOK   = 0
function ep_soak_test(times)
    -- ENCHANTER ONLY, like the real thing.
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
    -- IDLE IS THE COMMON CASE: no queue, no cast in flight, no gear stripped, not paused.
    if #epQueue == 0 and not epCast and not epSaved and not epPaused then
        epBusySince = nil
        return
    end
    -- NOT WHILE SOMETHING ELSE IS CASTING - but only briefly.
    do
        local casting = 0
        pcall(function() casting = tonumber(mq.TLO.Me.Casting.ID()) or 0 end)
        -- ALREADY CASTING?
        if casting > 0 then
            epBusySince = epBusySince or mq.gettime()
            if (mq.gettime() - epBusySince) < EP_BUSY_MAX then return end
        else
            epBusySince = nil
        end
    end
    -- ANYTHING ON THE CURSOR STOPS THE WHOLE TICK.
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
    -- BACKSTOP FIRST, before anything else can return early.
    if epSaved and (mq.gettime() - epStripAt) > EP_STRIP_MAX then
        ep_restore('backstop - stripped too long')
    end
    -- SECOND BACKSTOP, for the pause without a strip.
    if epPaused and not epSaved and not epCast then
        local pending, casting = 0, false
        for _, q in ipairs(epQueue) do if not q.state then pending = pending + 1 end end
        -- Same reason as the queue-finished release: epCast being nil does not prove nothing is being
        -- cast, only that we have stopped tracking it.
        pcall(function() casting = (tonumber(mq.TLO.Me.Casting.ID()) or 0) > 0 end)
        if pending == 0 and not casting then ep_resume('nothing left to do') end
    end

    -- CLEARING IS THE TICK'S JOB, not the panel's - the same fault the phantom queue had.
    if #epQueue > 0 then
        local pend = 0
        for _, q in ipairs(epQueue) do if not q.state then pend = pend + 1 end end
        if pend == 0 then
            epDoneAt = epDoneAt or mq.gettime()
            local hold = (#epQueue == 1) and 10000 or EP_LINGER
            if (mq.gettime() - epDoneAt) > hold then
                epQueue, epDoneAt = {}, nil
                -- NOT BROADCAST ANY MORE.
                ep_queue_log('linger expired')
            end
        else
            epDoneAt = nil
        end
    end

    -- THE ELECTION IS GONE.

    -- HARD BACKSTOP ON A CAST THAT NEVER RESOLVED.
    if epCast and (mq.gettime() - (epCast.at or 0)) > EP_CAST_HARD_MAX then
        rezlog('\\ar[placate] cast on %s never resolved after %ds - clearing so placate can carry on\\ax',
               epCast.name or '?', EP_CAST_HARD_MAX / 1000)
        epCast = nil
    end
    if epCast then
        -- PLACATE HAS A CAST TIME, so nothing can be concluded while it is still going out.
        local casting = false
        pcall(function() casting = (tonumber(mq.TLO.Me.Casting.ID()) or 0) > 0 end)
        if casting then
            epCast.sawCast = true
            -- WATCH THE CURSOR THROUGH THE CAST, not only before it.
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

        -- Then LOOK.
        if (mq.gettime() - epCast.at) < EP_CHECK_AFTER then return end

        -- RE-TARGET IF IT MOVED, then read.
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
                        -- COMPLETED.
                        local casting = false
                        pcall(function() casting = (tonumber(mq.TLO.Me.Casting.ID()) or 0) > 0 end)
                        landed = epCast.sawCast and not casting
                    end
                end
            end
        else
            -- STILL NOT ON IT.
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
            -- A CAST THAT NEVER WENT OUT DOES NOT SPEND A RETRY, and sawCast is how we know: it is set
            -- when we watch ourselves casting, so false means the spell never started.
            epCast.freeUsed = epCast.freeUsed or 0
            if (epCast.freeRetry or not epCast.sawCast) and epCast.freeUsed < EP_FREE_RETRIES then
                epCast.freeUsed = epCast.freeUsed + 1
                epCast.freeRetry = false
            else
                epCast.freeRetry = false
                epCast.tries = epCast.tries + 1
            end
            epCast.at, epCast.sawCast, epCast.checkTries = mq.gettime(), false, 0
            -- NOTHING ON THE CURSOR, on a retry as much as on a first cast.
            cursor_stow('placate')
            if (mq.TLO.Cursor.ID() or 0) ~= 0 then
                rezlog('\\ay[placate] not retrying %s#%d - %s will not stow off the cursor\\ax',
                       epCast.name, epCast.id or 0, tostring(mq.TLO.Cursor.Name() or '?'))
                return
            end
            -- THE INPUTS, NOT JUST THE VERDICT.
            local casting, tlvl, tdist = 0, 0, 0
            pcall(function() casting = tonumber(mq.TLO.Me.Casting.ID()) or 0 end)
            pcall(function() tlvl = tonumber(mq.TLO.Spawn(epCast.id).Level()) or 0 end)
            pcall(function() tdist = math.floor(tonumber(mq.TLO.Spawn(epCast.id).Distance()) or 0) end)
            rezlog('[placate] did not land on %s#%d - retry %d of %d (sawCast=%s casting=%s lvl=%d cap=%d dist=%d)',
                   epCast.name, epCast.id or 0, epCast.tries, EP_RETRY,
                   tostring(epCast.sawCast), (casting > 0) and 'yes' or 'no',
                   tlvl, (pacCap[myName] or {}).cap or 0, tdist)
            if (tonumber(mq.TLO.Target.ID()) or 0) ~= epCast.id then
                pcall(function() mq.cmdf('/target id %d', epCast.id) end)
                mq.delay(400, function() return (tonumber(mq.TLO.Target.ID()) or 0) == epCast.id end)
            end
            at_cast((ep_spell() or '') .. EP_OPTS, epCast.id)
            return
        end
        rezlog('\\ay[placate] gave up on %s#%d after %d tries (%d cut before the cast started)\\ax',
               epCast.name, epCast.id or 0, epCast.tries, epCast.freeUsed or 0)
        -- Two different problems, two different words: a spell that lands and is resisted is a placate
        -- problem; a spell that never leaves is E3 taking the character back mid-cast.
        ep_mark(epCast.id, 'failed',
                ((epCast.freeUsed or 0) >= EP_FREE_RETRIES) and 'cast kept being interrupted'
                                                             or 'would not land')
        epCast = nil
        return
    end

    -- Anything left to do?
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
        -- NOT WHILE STILL CASTING.
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
    -- WRONG SPELL IN THE GEM?
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
    -- THE GEM COOLDOWN, SAID OUT LOUD.
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

    -- STRIP BEFORE THE FIRST CAST, not before each one.
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

    -- ep_strip returns false when something came off and cannot be found again.
    if not ep_strip() then return end

    local ready, why = ep_ready_to_cast()
    if not ready then
        -- THROTTLED, AND IT GIVES UP.
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
    -- DID IT ALREADY HAVE ONE, AND FOR HOW LONG?
    local hadBuff, preDur = false, 0
    pcall(function() hadBuff = (tonumber(mq.TLO.Target.Buff(sp).ID()) or 0) > 0 end)
    if hadBuff then
        pcall(function() preDur = tonumber(mq.TLO.Target.Buff(sp).Duration.TotalSeconds()) or 0 end)
    end
    -- The options are printed, because a string E3 rejects looks exactly like a cast that never fired.
    rezlog('[placate] %s%s on %s#%d%s', sp, EP_OPTS, next_e.name, next_e.id or 0,
           hadBuff and string.format(' (refresh - %ds left)', preDur) or '')
    at_cast(sp .. EP_OPTS, next_e.id)
    -- spell = WHAT we are casting, so an interrupt message can be matched against it. Without this the
    -- interrupt handler had no way to tell our cast from anyone else's and reacted to all of them.
    epCast = { id = next_e.id, name = next_e.name, at = mq.gettime(), tries = 1, sawCast = false,
               checkTries = 0, hadBuff = hadBuff, preDur = preDur, spell = ep_spell() }
end

-- ===== PHANTOM LINE (placate) =====
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

-- The highest phantom this character actually has.
function pw_disc()
    if pwDisc then return pwDisc end
    -- MONKS ONLY. Everyone else looked up seven combat abilities every five seconds, forever.
    if at_my_class() ~= 'MNK' and at_my_class() ~= '' then return nil end
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
-- RANGE IS ASKED FOR, NOT GUESSED.
PW_RANGE_FALLBACK = 200  -- only if the TLO gives nothing: the standard cast range
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
-- GIVE UP ON ONE THAT NEVER CLOSES, the same way the placate queue does (EP_FAR_MAX).
PW_FAR_MAX   = 45000
pwOorSaidAt  = 0         -- rate limit on the "everything is out of reach" line
pwCursorSaidAt = 0       -- rate limit on the stuck-cursor line
-- ENTRIES ARE MARKED, NOT REMOVED.
pwQueue = {}             -- { { id, name, oor, state } }  state: nil | 'done' | 'failed'
pwDoneAt = nil           -- when everything finished, for the linger before clearing
-- How long the finished list stays up, and it depends on how much there was to watch.
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
    -- CHECK THERE IS A TARGET FIRST.
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
    -- NOT BROADCAST.
    pac_reflect(id, state)
end

-- Runs on EVERY toon; returns immediately on anyone without the disc. Main loop only - it targets and
-- yields, neither of which belongs anywhere near an ImGui callback.
function pw_tick()
    local disc = pw_disc()
    if not disc then return end

    -- SAME CURSOR RULE AS PLACATE.
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

    -- THE SWEEP RUNS BEFORE THE RECAST AND READY GATES, not after.
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

    -- CLEARING IS THE TICK'S JOB, not the panel's.
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
    pwCast = { id = e.id, name = e.name, at = mq.gettime(), tries = 1, prevTarget = prev,
               spell = pwDisc }
end

-- NIGHTVEIL EMBLEMS, grouped by role.
uiDrawProbe = false

function ui_draw_probe()
    if not uiDrawProbe then return end
    uiDrawProbe = false
    local dl = nil
    local ok = pcall(function() dl = ImGui.GetWindowDrawList() end)
    if not ok or not dl then log('\\ar[draw] no draw list available in this binding\\ax'); return end
    local names = { 'AddLine', 'AddRect', 'AddRectFilled', 'AddCircle', 'AddCircleFilled',
                    'AddTriangle', 'AddTriangleFilled', 'AddQuad', 'AddQuadFilled',
                    'AddNgon', 'AddNgonFilled', 'AddText', 'AddBezierCubic', 'AddBezierQuadratic',
                    'AddPolyline', 'AddConvexPolyFilled', 'AddImage', 'AddImageRounded',
                    'PathClear', 'PathLineTo', 'PathArcTo', 'PathArcToFast', 'PathBezierCubicCurveTo',
                    'PathStroke', 'PathFillConvex', 'PathRect',
                    'PushClipRect', 'PopClipRect', 'AddRectFilledMultiColor' }
    local have, missing = {}, {}
    for _, n in ipairs(names) do
        local present = false
        pcall(function() present = (dl[n] ~= nil) end)
        if present then have[#have + 1] = n else missing[#missing + 1] = n end
    end
    log('\\ag[draw] AVAILABLE (%d): %s\\ax', #have, table.concat(have, ', '))
    log('\\ay[draw] missing (%d): %s\\ax', #missing, table.concat(missing, ', '))
    -- The arc is the one worth knowing about - a cooldown RING needs PathArcTo + PathStroke, and a
    -- present-but-broken binding is common enough that existing is not the same as working.
    local arcOK = false
    pcall(function()
        local cx, cy = ImGui.GetCursorScreenPos()
        dl:PathClear()
        dl:PathArcTo(ImVec2(cx + 30, cy + 30), 10, 0, 3.14159)
        dl:PathStroke(IM_COL32(120, 180, 255, 255), 0, 2)
        arcOK = true
    end)
    log('%s[draw] PathArcTo + PathStroke actually ran: %s\\ax', arcOK and '\\ag' or '\\ar', tostring(arcOK))
    -- Same question for ImVec2/IM_COL32 themselves, since a missing helper looks identical to a
    -- missing draw method from the caller's side.
    log('[draw] ImVec2=%s IM_COL32=%s GetFontSize=%s',
        tostring(ImVec2 ~= nil), tostring(IM_COL32 ~= nil), tostring(ImGui.GetFontSize ~= nil))
    -- EXERCISE THE LABEL PATH RATHER THAN WAITING FOR ONE.
    pcall(function() ui_pill('probe', { 120, 180, 255 }) end)
    log('[draw] label path: %s', uiDlTextOK == nil and 'not drawn yet'
        or (uiDlTextOK and 'draw list (AddText)' or 'FALLBACK - text widgets, labels count toward width'))
end

-- IS THERE A NIGHTVEIL SECTION TO DRAW AT ALL?
function nv_has_rows()
    local reporting = false
    for _, nm in ipairs(ordered_members()) do
        local st = nvState[nm]
        if st and st.items then
            reporting = true
            for i = 1, #NV_SPLIT do
                local s = st.items[i]
                if s ~= nil and s >= 0 then return true end
            end
        end
    end
    -- Nobody has reported: keep the section so its message can say which kind of empty this is.
    return not reporting
end

function draw_nightveil()
    -- FOUR FIXED ROWS, ONE PER ITEM.
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
            if ui_icon(e.item, 'item', ui_icon_size()) then ImGui.SameLine() end
            ui_text(UI_LABEL, e.role .. ':')
            ImGui.SameLine()
            local nReady = 0
            for _, nm in ipairs(holders) do if ready[nm] then nReady = nReady + 1 end end
            -- NO 'All' FOR A ROW OF ONE: it would be the same button twice, side by side.
            if #holders > 1 and nReady > 0 then
                if ImGui.SmallButton(string.format('All##nvall_%d', i)) then
                    for _, nm in ipairs(holders) do if ready[nm] then click(nm, i) end end
                end
                if ui_tip_hover() then
                    pcall(function() ImGui.SetTooltip(string.format('Click %s on all %d ready',
                                                       e.item, nReady)) end)
                end
                ImGui.SameLine()
            end
            for _, nm in ipairs(holders) do
                local rdy = nm and ready[nm]
                -- READY SHOWS THE NAME, WAITING SHOWS THE CLOCK.
                local face = nm
                if not rdy then
                    local left = nv_peer_secs(nm, i)
                    if (left or 0) > 0 then face = nv_hms(left) end
                end
                -- READY IS A BUTTON, WAITING IS A PILL.
                if rdy then
                    if ui_name_button(face, 'nv_' .. i .. '_' .. nm, UI_READY) then click(nm, i) end
                else
                    ui_pill(face, { 210, 140, 60 })
                end
                if ui_tip_hover() then
                    local s = nv_peer_secs(nm, i)
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
    draw_effect_strip('nv')
end

-- The pacify panel: who can do it, what each caps at, and the queue with each mob routed to a caster.
function pac_add_spawn(id)
    id = tonumber(id) or 0
    if id <= 0 then log('\\ay[pacify] target an NPC first\\ax'); return false end
    local nm, ty, hp, lvl, dist = '', '', 0, 0, 0
    pcall(function() nm   = tostring(mq.TLO.Spawn(id).CleanName() or '') end)
    pcall(function() ty   = tostring(mq.TLO.Spawn(id).Type() or '') end)
    pcall(function() hp   = tonumber(mq.TLO.Spawn(id).PctHPs()) or 0 end)
    pcall(function() lvl  = tonumber(mq.TLO.Spawn(id).Level()) or 0 end)
    pcall(function() dist = math.floor(tonumber(mq.TLO.Spawn(id).Distance()) or 0) end)
    if ty ~= 'NPC' or hp <= 0 then
        log('\\ay[pacify] %s is not a living NPC\\ax', (nm ~= '') and nm or ('id ' .. id))
        return false
    end
    if pac_find(id) then log('[pacify] %s is already queued', nm); return false end
    -- ROUTED AT ADD TIME, from the level the mob actually is.
    local who, cap, rng = pac_assign(lvl, dist)
    if not who then who, cap, rng = pac_assign(lvl) end   -- nobody in range: fall back on level
    pacQueue[#pacQueue + 1] = { id = id, name = nm, level = lvl, dist = dist, who = who,
                                assignedAt = mq.gettime() }
    if who then
        log('[pacify] %s (level %d, %dm) -> %s (caps %d, reach %d)', nm, lvl, dist, who, cap or 0, rng or 0)
        pcall(function() peer_bcast('/at_pacadd %d %s %d %s', id, nm:gsub(' ', '_'), lvl, who) end)
        -- Every add can change who should have what, so settle the list before anyone picks up.
        pac_rebalance()
        return true
    end
    log('\\ay[pacify] %s is level %d - nobody here can pacify that high\\ax', nm, lvl)
    return false
end

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
        -- CLICKABLE, like the rez chain: green in, red out.
        local off = pacOff[nm:lower()] and true or false
        if off then ImGui.PushStyleColor(ImGuiCol.Text, 0.90, 0.35, 0.35, 1.0)
        else        ui_push_text(UI_READY) end
        if ImGui.SmallButton(string.format('%s %d##pacoff_%s', nm:sub(1, 6), c.cap or 0, nm)) then
            pacOff[nm:lower()] = (not off) or nil
            save_settings()
            pcall(function() peer_bcast('/at_pacoff %s %d', nm, off and 0 or 1) end)
        end
        ImGui.PopStyleColor(1)
        if ui_tip_hover() then
            pcall(function() ImGui.SetTooltip(string.format('%s\n%s\ncaps at level %d, range %d\n\n%s',
                nm, c.spell or c.kind or '?', c.cap or 0, c.range or 0,
                off and 'OUT of the rotation - click to put back in'
                    or 'in the rotation - click to take out')) end)
        end
        -- The gem lives in SETTINGS, not here.
    end

    if ImGui.Button('Pacify target##pacadd', 150, 0) then
        local id = 0
        pcall(function() id = tonumber(mq.TLO.Target.ID()) or 0 end)
        pac_add_spawn(id)
    end
    ImGui.SameLine()
    if ImGui.SmallButton('Clear##pacclear') then
        pac_snapshot()
        pacQueue = {}
        pcall(function() peer_bcast('/at_pacclear') end)
    end
    -- REDO LAST.
    if pacRedo and #pacRedo > 0 then
        ImGui.SameLine()
        if ImGui.SmallButton(string.format('Redo last (%d)##pacredo', #pacRedo)) then pac_redo() end
        if ui_tip_hover() then
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
            -- REPORTED out of range by the caster that owns it, not inferred here.
            local secs = e.oorSince and math.floor((mq.gettime() - e.oorSince) / 1000) or 0
            ImGui.TextColored(0.90, 0.60, 0.30, 1.0,
                string.format('%s  %s - out of range%s', e.name, e.who,
                    (e.oorDist and e.oorDist > 0) and string.format(' (%dm)', e.oorDist) or ''))
            if ui_tip_hover() then
                pcall(function() ImGui.SetTooltip(string.format(
                    '%s\n%s has it queued but cannot reach it%s.\nSkipped for now - it goes back in the'
                    .. ' rotation as soon as it is in range.\nout of reach for %ds; given up on at %ds.',
                    e.name, e.who,
                    (e.oorDist and e.oorDist > 0) and string.format(' - %dm at the last check', e.oorDist) or '',
                    secs, PAC_OOR_MAX / 1000)) end)
            end
        elseif e.sent then
            -- Handed to that character's own queue, which owns it from here.
            ImGui.TextColored(0.62, 0.82, 0.95, 1.0,
                string.format('%s  lvl %d  %s is on it', e.name, e.level or 0, e.who))
        else
            ImGui.TextColored(0.80, 0.80, 0.80, 1.0,
                string.format('%s  lvl %d  -> %s', e.name, e.level or 0, e.who))
        end
        ImGui.SameLine()
        if ImGui.SmallButton('x##pacdel' .. i) then
            -- Remove it locally right away so the list responds, but let the tick tell the group:
            -- peer_bcast can fall through to channel detection, which waits.
            pacDelWanted = e.id
            table.remove(pacQueue, i)
            break
        end
    end
end




function draw_coth_mini()
    if COTH.active then
        -- NEVER FROM THE DRAW.
        if ImGui.SmallButton('Stop gather##at_coth_mini') then cothSetWanted = 'off' end
        -- BELOW, NOT BESIDE.
        ImGui.TextColored(0.36, 0.80, 0.46, 1.0,
            string.format('CoTH gathering - %s', coth_here() and 'I am there'
                          or (coth_dist_to_anchor() .. ' away')))
    else
        if ImGui.SmallButton('CoTH Group##at_coth_mini') then cothSetWanted = 'on' end
    end
end

-- EVERY COMMAND WORTH TYPING, in one place.

AT_COMMANDS = {
    { group = 'Windows' },
    { cmd = '/at',              desc = 'toggle the window' },
    { cmd = '/atui',            desc = 'open the mini window' },
    { cmd = '/atuie',           desc = 'open the full window' },
    { cmd = '/atui reset',      desc = 'put every popped-out section back in the mini' },
    { cmd = '/attab',           desc = 'switch the active tab' },
    { cmd = '/atcommand',       desc = 'print this list in the chat window' },

    { group = 'Group actions' },
    { cmd = '/atcoth',          desc = 'gather the group to where I am standing' },
    { cmd = '/atcoth off',      desc = 'stop the gather' },
    { cmd = '/atburncheck <burn>', desc = 'after /e3burns on the burn hotkey: show what has not fired yet' },
    { cmd = '/atburncheck off', desc = 'clear the burn check' },
    { cmd = '/atwipe',          desc = 'hold all rezzes until the group zones' },
    { cmd = '/atwipe off',      desc = 'release the hold' },
    { cmd = '/atresume',        desc = 'resume after a hold' },
    { cmd = '/atinvis',         desc = 'fire the invis combo' },
    { cmd = '/atshimmer',       desc = 'group Shimmering Reflection' },
    { cmd = '/atfleeting',      desc = 'group Fleeting Fortitude' },
    { cmd = '/atinferno',       desc = 'group Inferno Ward' },
    { cmd = '/atreclaim',       desc = 'reclaim currency from the group' },

    { group = 'Pacify' },
    { cmd = '/atpacify',        desc = 'add my target to the placate queue' },
    { cmd = '/atpacify <name>', desc = 'add a named mob to the placate queue' },
    { cmd = '/atpac',           desc = 're-announce my pacify ceiling after memming a new rank' },
    { cmd = '/atrezclear [id]', desc = 'let a retired corpse (or all) be rezzed again before 20 minutes' },
    { cmd = '/atrange',         desc = 'set the pacify range' },

    { group = 'Gear and buffs' },
    { cmd = '/atregear',        desc = 're-equip after a placate strip' },
    { cmd = '/atportlist',      desc = 'list the ports I can cast' },

    { group = 'Diagnostics' },
    { cmd = '/atburnpoll',      desc = 're-read my burn INI and report everything again' },
}

function draw_commands_tab()
    ImGui.Spacing()
    ImGui.TextDisabled('Click a command to copy it. Anything here can go on a hotkey.')
    -- SAY THAT THE LIST IS EDITED.
    ImGui.TextDisabled('The everyday ones. Diagnostics and probes still work but are not listed.')
    ImGui.Spacing()
    for _, e in ipairs(AT_COMMANDS) do
        if e.group then
            ImGui.Spacing()
            ui_text(UI_LABEL, e.group)
            ImGui.Separator()
        else
            -- The command IS the button. Clicking copies it, because the thing you want after finding a
            -- command is usually to put it somewhere - a hotkey, a social, a message to somebody else.
            if ImGui.SmallButton(e.cmd .. '##cmd_' .. e.cmd) then
                pcall(function() ImGui.SetClipboardText(e.cmd) end)
                log('[cmd] copied %s', e.cmd)
            end
            ImGui.SameLine(180)
            ImGui.TextDisabled(e.desc)
        end
    end
    ImGui.Spacing()
    ImGui.EndTabItem()
end

-- Mini section registry.
MINI_HELP = {
    coth = 'Uses Call of the Hero from the Wayfarers aug.\n' ..
           'Note: the aug needs to be in a charm to work.\n' ..
           'Use /atcoth to start a gather anchored on another character.',
    rez  = 'Configure the rez order under the Rez tab.',
    combos = 'Group MGB heals with class combinations,\nso you only need to click one button.',
    phantom = 'Monk placate line. Click mobs to queue them;\nthe monk works down the list.',
    placate = 'Enchanter or cleric placate. Strips weapons first so\naugment procs cannot break it, then puts them back.',
}

-- Which mini sections are folded shut.
miniFold = miniFold or {}
-- ONLY THE BULKY SECTIONS FOLD.
invisExpectItu, invisExpectInv, invisSelfCheckAt = false, false, 0
-- Per-character invis result, written once per combo. Nothing polls it and nothing refreshes it: it is a
-- record of how the last combo went, not a live reading, and the panel says how old it is.
invisState = {}
-- How long a result stays worth painting.
INVIS_ROW_MS  = 10000
invisRowUntil = 0
-- After the lead expires, how long to allow for both casts to land before reading. Both have a cast time
-- and the reading has to be of the settled state, not the mid-cast one.
INVIS_SELF_CHECK_MS = 4000
-- Ceiling on waiting for our own invis cast to finish before releasing E3. Exits as soon as the cast
-- clears; this only bounds a cast that never does.
INVIS_CAST_MAX = 3000
-- Least time E3 stays paused after the cast goes out, whatever Me.Casting says.
INVIS_HOLD_MIN = 2500
invisFiredAt   = 0
-- Vestigial: it was the change key for the push that no longer happens.
invisLast  = ''

-- Me.Invis[NORMAL] and Me.Invis[UNDEAD] return nothing on this build - only the bare Me.Invis answers.
INVIS_ALSO = {
    ['invisibility']                       = 'Invis',
    ['group invisibility']                 = 'Invis',
    ['improved invisibility']              = 'Invis',
    ['invisibility versus undead']         = 'ITU',
    ['group invisibility versus undead']   = 'ITU',
    ['invisibility to undead']             = 'ITU',
    ['superior camouflage']                = 'Invis',
    ['camouflage']                         = 'Invis',
    ['shroud of stealth']                  = 'Invis',
}
function invis_known(name)
    local low = tostring(name or ''):lower()
    if low == '' then return nil end
    for _, e in ipairs(MAGIC_CLICKS) do
        if (e.group == 'ITU' or e.group == 'Invis') and e.aa then
            if low == e.aa:lower() then return e.group end
        end
    end
    return INVIS_ALSO[low]
end
-- CHECK THE FLAG BEFORE WALKING FORTY BUFFS.
function invis_self()
    local anyInvis = false
    pcall(function() anyInvis = tlo_true(mq.TLO.Me.Invis()) end)
    -- MATCH THE REAL RETURN SHAPE: this function ends with `return n and 1 or 0, u and 1 or 0`, so it
    -- hands back NUMBERS and the caller concatenates them into a change key.
    if not anyInvis then return 0, 0 end
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
    -- SLOTS, NOT COUNT.
    pcall(function() nb = buff_slot_max(tonumber(mq.TLO.Me.CountBuffs()) or 0) end)
    pcall(function() ns = tonumber(mq.TLO.Me.CountSongs()) or 0 end)
    pcall(function() look(function(i) return mq.TLO.Me.Buff(i).Name() end, nb) end)
    pcall(function() look(function(i) return mq.TLO.Me.Song(i).Name() end, ns) end)
    -- THE BUFFS DECIDE, NOT Me.Invis.
    if anyInvis and not n and not u then
        invisSaidUnknown = invisSaidUnknown or {}
        local names = {}
        pcall(function()
            for i = 1, (nb or 0) do names[#names + 1] = tostring(mq.TLO.Me.Buff(i).Name() or '') end
            for i = 1, (ns or 0) do names[#names + 1] = tostring(mq.TLO.Me.Song(i).Name() or '') end
        end)
        local k = table.concat(names, '|')
        if not invisSaidUnknown[k] then
            invisSaidUnknown[k] = true
            log('\\ay[invis] the client says I am invisible but no buff I recognise is up - tell me which of these it is:\\ax')
            log('[invis]   %s', table.concat(names, ', '))
        end
    end
    return n and 1 or 0, u and 1 or 0
end

-- Two rows, ITU and Invis, and they are two rows on purpose: walking past undead with plain invis is
-- how somebody dies, so the choice is made deliberately rather than by whichever fired first.
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

-- HOW LONG THE CASTERS GET TO PREPARE before the coordinated fire.
INVIS_WAIT_HERE = 4000
-- THE LEAD HAS TO OUTLAST THE PREP, on the slowest client, or it is not a lead at all.
INVIS_LEAD = 3500
-- CLERIC FIRST, DRUID A QUARTER SECOND BEHIND.
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
function invis_arm(key, ms, arrivedAt)
    if not key or key == '' then return end
    local lead = tonumber(ms) or INVIS_LEAD
    -- FROM WHEN THE MESSAGE LANDED, not from now.
    local base = tonumber(arrivedAt) or mq.gettime()
    invisFireKey = key
    invisFireAt  = base + lead
    local lateBy = mq.gettime() - base
    local prepFrom = mq.gettime()
    -- ONE PREP, NOT TWO.
    invis_prep_self()
    -- The cast time is the number the offset has to be set against, so it goes in the log every time.
    local prepMs, leftMs = mq.gettime() - prepFrom, invisFireAt - mq.gettime()
    log('[invis] armed %s - msg picked up %dms late, prep took %dms, %dms left of the lead (casts in %ss)',
        key, lateBy, prepMs, leftMs, tostring(invis_cast_ms(key)))
    -- A negative remainder means this caster is already past the moment it was meant to fire, so it
    -- will go immediately and the other one will not.
    if leftMs < 0 then
        log('\\ar[invis] I am %dms LATE - the prep outlasted the lead, this cast will not line up\\ax',
            -leftMs)
    end

    -- HOLD RIGHT HERE UNTIL THE DEADLINE, do not go back to the main loop for it.
    invis_push_now()
    -- WAIT HERE, BUT ONLY IF THE DEADLINE IS CLOSE.
    local left = invisFireAt - mq.gettime()
    if left > INVIS_WAIT_HERE then
        log('[invis] armed - %dms to go, letting the loop run until then', left)
        return
    end
    if left > 0 then mq.delay(left) end
    invis_push_now()
    invis_fire_now()
end

-- The cast itself, split out so both the armed wait above and the tick backstop use one path.
function invis_push_now() end

function invis_fire_now()
    local key = invisFireKey
    invisFireKey, invisFireAt = nil, nil
    if not key then return end
    local n0, u0 = invis_self()
    log('[invis] FIRING %s at %d (before: invis=%d itu=%d)', key, mq.gettime(), n0, u0)
    pcall(function() magic_click(key) end)
    -- Target back, fire and forget - the readings do not need it and nothing waits on it.
    if invisPrevTarget and invisPrevTarget > 0 then
        local back = invisPrevTarget
        invisPrevTarget = nil
        pcall(function() mq.cmdf('/target id %d', back) end)
    end
    -- Tell the driver the exact instant, so a test run can measure the two casters against each other
    -- rather than us reading two logs side by side.
    if driverName then
        pcall(function() peer_cmdf(driverName, '/at_invisfired %s %d', myName, mq.gettime()) end)
    end
    -- THE WATCH IS GONE (2026-08-24), and it was the most expensive thing invis did.
    invisFiredAt = mq.gettime()
    -- WAIT FOR THE CAST TO FINISH BEFORE HANDING E3 BACK.
    mq.delay(INVIS_CAST_MAX, function() return (tonumber(mq.TLO.Me.Casting.ID()) or 0) == 0 end)
    -- AND THEN A FLOOR.
    local held = mq.gettime() - invisFiredAt
    if held < INVIS_HOLD_MIN then mq.delay(INVIS_HOLD_MIN - held) end
    -- Hand the group back. Everyone was held for this, so everyone gets released - and locally too, since
    -- a broadcast does not return to the sender.
    pcall(function() peer_bcast('/at_invisdone') end)
    -- ONE RELEASE, matching the one hold. The second was here to balance the arm's duplicate hold and
    -- would now hand E3 back while somebody else still wanted it held.
    if invisPrepped then invisPrepped = nil; e3_release('invis') end
    invisPrepAt = nil
end

-- Called from the tick.
function invis_fire_tick()
    -- Cheap: one comparison on a tick with nothing pending.
    invis_self_check()
    -- NOTHING ARMED, NOTHING TO DO.
    if not (invisPrepped or invisFireAt) then return end
    -- SAFETY RELEASE. If the group was quieted and no cast followed - a caster died, zoned, or the pick
    -- turned out to be unable - somebody has to hand E3 back or the whole group sits paused.
    if invisPrepped and not invisFireAt then
        -- Belt and braces: invis_prep_self stamps this now, so this only catches a prep that somehow
        -- set the flag without going through it.
        if not invisPrepAt then invisPrepAt = mq.gettime() end
        if (mq.gettime() - invisPrepAt) > INVIS_PREP_MAX then
            log('\\ay[invis] no cast followed the prep - releasing the group\\ax')
            invisPrepped, invisPrepAt = nil, nil
            pcall(function() peer_bcast('/at_invisdone') end)
            e3_release('invis')
        end
        return
    end
    invisPrepAt = nil
    if not invisFireAt then return end
    if mq.gettime() < invisFireAt then return end
    invis_fire_now()
end

-- A COUNTDOWN, NOT A COMMAND.
invisFireWanted = false   -- set by the combo button; the tick fires it, because the fire blocks
invisPrepWanted = false   -- set by /at_invisprep; the tick does it, for the same reason
invisTake = nil           -- set by /at_inviscast; the tick arms it, because arming blocks
invisPrepped, invisPrepAt = nil, nil
-- Longest the group may stay quieted with no cast following.
INVIS_PREP_MAX = 9000
-- PAUSE FIRST, THEN STOP THE CAST.
INVIS_PREP_DEAD = 8000
function invis_prep_self()
    if invisFiredAt and (mq.gettime() - invisFiredAt) < INVIS_PREP_DEAD then
        rezlog('[invis] prep arrived %dms after the cast - skipping it, /makemevis would strip what just '
            .. 'landed', mq.gettime() - invisFiredAt)
        invisPrepWanted = false
        return
    end
    -- ANY PENDING REQUEST IS SATISFIED BY THIS.
    invisPrepWanted = false
    if invisPrepped then return end
    -- STAMPED HERE, WHERE THE PREP ACTUALLY HAPPENS.
    invisPrepped = true
    invisPrepAt  = mq.gettime()
    -- CONFIRM THE PAUSE BEFORE TOUCHING ANYTHING.
    e3_hold('invis')
    -- CLEAR ANY INVIS WE ALREADY HAVE, before casting more at ourselves.
    pcall(function() mq.cmd('/makemevis') end)
    -- TARGET MYSELF.
    invisPrevTarget = 0
    pcall(function() invisPrevTarget = tonumber(mq.TLO.Target.ID()) or 0 end)
    local myId = 0
    pcall(function() myId = tonumber(mq.TLO.Me.ID()) or 0 end)
    if myId > 0 and invisPrevTarget ~= myId then
        pcall(function() mq.cmdf('/target id %d', myId) end)
        mq.delay(400, function() return (tonumber(mq.TLO.Target.ID()) or 0) == myId end)
    end
    -- UNCONDITIONAL.
    pcall(function() mq.cmd('/stopcast') end)
    pcall(function() mq.cmd('/stopsong') end)
    -- The WAIT is still conditional, because there is nothing to wait for when the read says idle - and
    -- on the class where the read lies, waiting on it would block for the full 400ms every single time.
    local casting = false
    pcall(function() casting = (tonumber(mq.TLO.Me.Casting.ID()) or 0) > 0 end)
    if casting then
        mq.delay(400, function() return (tonumber(mq.TLO.Me.Casting.ID()) or 0) == 0 end)
    end
    -- STRIP THE PROC BUFF THAT BREAKS INVIS.
    local nb, ns = 0, 0
    -- SLOTS, NOT COUNT.
    pcall(function() nb = buff_slot_max(tonumber(mq.TLO.Me.CountBuffs()) or 0) end)
    pcall(function() ns = tonumber(mq.TLO.Me.CountSongs()) or 0 end)
    local function strip(getName, count)
        for i = 1, (count or 0) do
            local nm = ''
            pcall(function() nm = tostring(getName(i) or '') end)
            if nm ~= '' and nm ~= 'NULL' and nm:lower():find('chaotic', 1, true) then
                pcall(function() mq.cmdf('/removebuff "%s"', nm) end)
                log('[invis] stripped %s - its proc breaks invis', nm)
            end
        end
    end
    pcall(function() strip(function(i) return mq.TLO.Me.Buff(i).Name() end, nb) end)
    pcall(function() strip(function(i) return mq.TLO.Me.Song(i).Name() end, ns) end)
    invis_push_now()      -- stopcast and the strip can both change what I am carrying
end

function invis_combo_fire()
    local parts = {}
    for _, grp in ipairs(INVIS_ROWS) do
        local pick = invisPick[grp]
        if not pick then
            -- SAY WHICH ROW IS EMPTY. A combo with only one row set looks identical to a combo where the
            -- second caster silently failed, and the two need completely different fixes.
            log('\\ay[invis] %s: nobody picked - that row will not be cast\\ax', grp)
        else
            local found
            for _, h in ipairs(invis_holders(grp)) do
                if h.nm == pick then found = h; break end
            end
            if found then
                parts[#parts + 1] = pick .. ':' .. found.e.key
            else
                -- PICKED BUT NOT AVAILABLE.
                local who = {}
                for _, h in ipairs(invis_holders(grp)) do who[#who + 1] = h.nm end
                log('\\ar[invis] %s: %s is picked but is not reporting the ability right now - skipping that row\\ax',
                    grp, pick)
                log('[invis]   %s available from: %s', grp,
                    (#who > 0) and table.concat(who, ', ') or 'nobody')
            end
        end
    end
    if #parts == 0 then
        log('\\ay[invis] nobody is picked - set who casts each row in Settings\\ax')
        return false
    end
    log('[invis] combo: %s', table.concat(parts, ', '))
    -- OPEN THE READOUT WINDOW.
    invisState = {}
    invisRowUntil = mq.gettime() + INVIS_LEAD + INVIS_SELF_CHECK_MS + INVIS_ROW_MS
    -- QUIET THE WHOLE GROUP FIRST, not just the two casters.
    pcall(function() peer_bcast('/at_invisprep') end)
    invis_prep_self()
    -- The lead has to cover the relay hop plus each caster pausing E3 and clearing any cast in flight.
    pcall(function() peer_bcast('/at_inviscast %d %s', INVIS_LEAD, table.concat(parts, ',')) end)
    -- And act on it locally too, since a broadcast does not come back to the sender.
    invis_combo_take(INVIS_LEAD, table.concat(parts, ','))
    return true
end

-- Am I one of the casters named in that message? Runs on every character; only the two named act.
function invis_combo_take(lead, blob, at)
    local ld = tonumber(lead) or INVIS_LEAD
    -- A NEW COMBO REOPENS THE PREP WINDOW.
    invisFiredAt = 0
    -- EVERY character notes what is coming, not just the two casters - the whole point is that the ones
    -- who are only receiving are the ones worth hearing from.
    invisExpectItu, invisExpectInv = false, false
    for chunk in tostring(blob or ''):gmatch('[^,]+') do
        local who, key = chunk:match('^(.-):(.+)$')
        if key then
            -- Resolve the key back to its row rather than matching on the key text: the keys are set in
            -- MAGIC_CLICKS and a new one added there should not silently stop being counted here.
            for _, e in ipairs(MAGIC_CLICKS) do
                if e.key == key then
                    if e.group == 'ITU'   then invisExpectItu = true end
                    if e.group == 'Invis' then invisExpectInv = true end
                    break
                end
            end
        end
        if who and who:lower() == myName:lower() then
            invis_arm(key, ld, at)
        end
    end
    if invisExpectItu or invisExpectInv then
        invisSelfCheckAt = (at or mq.gettime()) + ld + INVIS_SELF_CHECK_MS
    end
end

-- WHAT DID I NOT GET? Runs on every character, once per combo, and only speaks up when something is
-- missing - a group channel full of 'I am fine' is a group channel nobody reads.
function invis_self_check()
    if invisSelfCheckAt == 0 or mq.gettime() < invisSelfCheckAt then return end
    invisSelfCheckAt = 0
    local n, u = invis_self()
    -- ONLY CLAIM A MISS WE CAN ACTUALLY SEE.
    local anyInvis = false
    pcall(function() anyInvis = tlo_true(mq.TLO.Me.Invis()) end)
    local missItu = invisExpectItu and (u or 0) == 0
    local missInv = invisExpectInv and not anyInvis
    -- ONE REPORT, ONCE, AT THE MOMENT THE ANSWER IS SETTLED.
    if driverName and driverName:lower() ~= myName:lower() then
        pcall(function()
            peer_cmdf(driverName, '/at_invis %s %d %d %d',
                      myName, (n or 0), (u or 0), anyInvis and 1 or 0)
        end)
    elseif SHOW_UI then
        invisState[myName] = { norm = (n or 0), und = (u or 0),
                               anyInvis = anyInvis, updated = mq.gettime() }
    end
    local what
    if missItu and missInv then what = 'both ITU and invis'
    elseif missItu          then what = 'ITU'
    elseif missInv          then what = 'invis'
    end
    if not what then
        -- Worth a file line either way: 'covered' and 'could not tell' look identical from the group
        -- channel, and this is the only place the difference is recorded.
        if invisExpectInv and (n or 0) == 0 and anyInvis then
            rezlog('[invis] self check: invisible but the invis buff is not one I can name - '
                .. 'run /atinvisprobe here to identify it')
        end
        return
    end
    pcall(function() mq.cmdf('/gsay I missed %s', what) end)
    rezlog('[invis] self check: missed %s (invis=%d itu=%d anyInvis=%s)',
           what, n or 0, u or 0, tostring(anyInvis))
end


-- THE PICKS LIVE IN SETTINGS, not in the mini window. They are a set-once choice - who casts each row -
-- and a set-once choice does not need to occupy space next to the button you press every pull.
function draw_invis_picks()
    for _, grp in ipairs(INVIS_ROWS) do
        local hs = invis_holders(grp)
        if #hs > 0 then
            ImGui.TextDisabled('   ' .. grp .. ':')
            -- STACKED THREE PER LINE, not one long row.
            ImGui.SameLine()
            local perLine = 3
            for hi, h in ipairs(hs) do
                -- No SameLine on the first of each line; ImGui starts a new line by default.
                if hi > 1 and ((hi - 1) % perLine) ~= 0 then ImGui.SameLine(0, 6) end
                local picked = (invisPick[grp] == h.nm)
                local ready  = (h.secs or 0) <= 0
                -- SAME SHAPE AS NIGHTVEIL: a name you can press, or a pill counting down that you
                -- cannot.
                if ready then
                    if ui_name_button(h.nm, 'inv_' .. grp .. '_' .. h.nm,
                                      picked and UI_READY or nil) then
                        -- ONE PICK PER ROW. Clicking the picked one clears it, so a row can be left out
                        -- of the combo without having to pick somebody else instead.
                        invisPick[grp] = (picked and nil) or h.nm
                        save_settings()
                    end
                else
                    ui_pill(nv_hms(h.secs), { 150, 150, 158 })
                end
                if ui_tip_hover() then
                    pcall(function() ImGui.SetTooltip(string.format('%s - %s\n%s\nClick to %s',
                        h.nm, h.e.aa or h.e.name or h.e.spell or '?',
                        ready and 'ready' or (nv_hms(h.secs) .. ' left'),
                        picked and 'unpick' or 'pick for the combo')) end)
                end
                -- The trailing SameLine that used to sit here forced every button onto one line and
                -- would have defeated the wrap above.
            end
            ImGui.NewLine()
        end
    end
end

function draw_invis()
    local anyRow = true
    -- EVERY CHARACTER, COLOURED BY WHAT IT ACTUALLY HAS.
    if mq.gettime() < (invisRowUntil or 0) then
        local total, ok = 0, 0
        for _, nm in ipairs(group_members()) do
            total = total + 1
            local st = invisState[nm]
            if st and ((st.norm or 0) > 0 or st.anyInvis == true) and (st.und or 0) > 0 then
                ok = ok + 1
            end
        end
        local shown = 0
        for _, nm in ipairs(group_members()) do
            local st = invisState[nm]
            local rgb, word
            if not st then
                rgb, word = { 0.40, 0.40, 0.42 }, 'no report yet'
            else
                -- anyInvis covers the case invis_self cannot name: invisible, but by a buff this build
                -- does not recognise.
                local inv = (st.norm or 0) > 0 or (st.anyInvis == true)
                local itu = (st.und or 0) > 0
                if     inv and itu then rgb, word = { 0.72, 0.55, 0.90 }, 'invis and ITU'
                elseif itu         then rgb, word = { 0.88, 0.88, 0.90 }, 'ITU only - visible to the living'
                elseif inv         then rgb, word = { 0.45, 0.65, 0.95 }, 'invis only - VISIBLE TO UNDEAD'
                else                    rgb, word = { 0.85, 0.35, 0.35 }, 'NOTHING - fully visible'
                end
            end
            if shown > 0 then ImGui.SameLine(0, 6) end
            shown = shown + 1
            ui_text(rgb, raid_short(nm))
            if ui_tip_hover() then
                local age = (st and st.updated) and math.floor((mq.gettime() - st.updated) / 1000) or -1
                pcall(function() ImGui.SetTooltip(string.format('%s\n%s%s', nm, word,
                    (age >= 0) and string.format('\nreported %ds ago', age) or '')) end)
            end
        end
        if shown > 0 then ImGui.NewLine() end
        -- THE VERDICT UNDER THE NAMES, not above them.
        local left = math.max(0, math.ceil(((invisRowUntil or 0) - mq.gettime()) / 1000))
        ui_text((ok == total) and { 0.36, 0.80, 0.46 } or { 0.90, 0.70, 0.30 },
                string.format('%s %d/%d', (ok == total) and 'Cast successful' or 'Cast incomplete',
                              ok, total))
        ImGui.SameLine(0, 6)
        -- The timer stays dim whatever the verdict: it is about the row's lifetime, not about coverage,
        -- and colouring it green would make it look like part of the good news.
        ui_text({ 0.45, 0.45, 0.48 }, string.format('(%ds)', left))
    end
    if miniInvisCombo then
        local n = 0
        for _, grp in ipairs(INVIS_ROWS) do if invisPick[grp] then n = n + 1 end end
        if n > 0 then
            if ImGui.SmallButton(string.format('Invis combo (%d)##invcombo', n)) then
                -- ONE lead for both, so the two countdowns expire together.
                invisFireWanted = true
            end
            if ui_tip_hover() then
                local who = {}
                for _, grp in ipairs(INVIS_ROWS) do
                    if invisPick[grp] then who[#who + 1] = grp .. ': ' .. invisPick[grp] end
                end
                pcall(function() ImGui.SetTooltip('Cast both picks\n' .. table.concat(who, '\n')) end)
            end
            -- DELIBERATELY NOT ADJACENT.
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
            if ui_tip_hover() then
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
    -- DRAUGHTS FIRST.
    if not cm_hidden('Draughts') then draw_pot_buttons() end
    if not cm_hidden('Cures')    then draw_cure_buttons() end
    draw_magic_buttons()
end

-- Every row Countermeasures can draw, for the Settings list.
function cm_rows()
    local out, seen = { 'Draughts', 'Cures' }, { Draughts = true, Cures = true }
    for _, e in ipairs(MAGIC_CLICKS) do
        local g = e.group or e.label
        if g and g ~= 'Invis' and g ~= 'ITU' and not seen[g] then
            seen[g] = true; out[#out + 1] = g
        end
    end
    return out
end
-- MGB and the combo buttons, same reasoning: two rows, two separators, two settings entries, one job.
function draw_groupheal_buttons()
    -- TWO HALVES, TWO SWITCHES.
    if miniClicks then draw_mgb_buttons() end
    if miniCombos then draw_combo_buttons() end
end

-- FOLD WHERE FOLDING BUYS SOMETHING.
MINI_FOLDABLE = { rez = true, di = true, burns = true, protect = true, nightveil = true,
                  invis = true }

MINI_SECTIONS = {
    { key = 'rez',    label = 'Rez',                   draw = draw_rez_mini,
      get = function() return miniRez end,    set = function(v) miniRez = v end },
    { key = 'di',     label = 'DI staff',              draw = draw_di_mini,
      get = function() return miniDI end,     set = function(v) miniDI = v end },
    { key = 'raid',    label = 'Raid',             draw = draw_raid,
      get = function() return miniRaid end,     set = function(v) miniRaid = v end },
    { key = 'running', label = 'Running now',      draw = draw_burn_running,
      get = function() return miniRunning end,  set = function(v) miniRunning = v end },
    { key = 'burns',  label = 'Burns',
      draw = function()
          -- THREE VIEWS, smallest first: compact (name + ready count + dots), the tier matrix, then the
          -- full table.
          if miniBurnView == 0 then
              draw_burn_compact()
              return
          end
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
          draw_burn_table(miniBurnFilter)
      end,
      get = function() return miniBurns end,  set = function(v) miniBurns = v end },
    -- ON IF EITHER OF THE OLD FLAGS WAS ON.
    { key = 'groupheals', label = 'Group heals',       draw = draw_groupheal_buttons,
      get = function() return (miniClicks or miniCombos) and true or false end,
      set = function(v) miniClicks = v; miniCombos = v end },   -- master: both halves follow
    -- 'Countermeasures', not 'Magic protection': cures are not protection; everything in here is
    -- pressed BECAUSE something is being done to you.
    { key = 'invis',  label = 'Invis',                 draw = draw_invis,
      get = function() return miniInvisCombo and true or false end,
      set = function(v) miniInvisCombo = v end },
    { key = 'protect', label = 'Countermeasures',      draw = draw_protect_buttons,
      get = function() return (miniCures or miniMagic or miniPots) and true or false end,
      set = function(v) miniCures = v; miniMagic = v; miniPots = v end },
    { key = 'coth',   label = 'CoTH Group button',     draw = draw_coth_mini,
      get = function() return miniCoth end,   set = function(v) miniCoth = v end },
    { key = 'nightveil', label = 'Nightveil Emblems',    draw = draw_nightveil,
      get = function() return miniNightveil end, set = function(v) miniNightveil = v end,
      has = nv_has_rows },
    { key = 'pacify',  label = 'Pacify',                  draw = draw_pacify,
      get = function() return miniPacify end, set = function(v) miniPacify = v end },
}
miniOrder = {}   -- list of keys, in display order; rebuilt from settings, defaults to the list above
function mini_section(key)
    for _, s in ipairs(MINI_SECTIONS) do if s.key == key then return s end end
    return nil
end
function mini_order_normalise()
    -- Keep only keys we know, then append anything missing.
    local MERGED = { cures = 'protect', magic = 'protect', arcane = 'protect', pots = 'protect',
                     mgb = 'groupheals', combos = 'groupheals', placate = 'pacify',
                     -- 'track' was the merged burn axis, tried in 1.17.55 and reverted.
                     track = 'running',
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

-- Bring the group's picture back in step after a membership change.
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
    -- COTH.state IS DELIBERATELY NOT DROPPED HERE.
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
    -- A resync is also when a worker that has just come up learns what the panel wants. Forced, because
    -- the change gate would otherwise decide nothing had changed and tell the newcomer nothing.
    pcall(function() feed_announce(true) end)
    log('[sync] %d peer(s) resynced%s', #peers,
        dropped > 0 and string.format(', %d stale entr(ies) dropped', dropped) or '')
end

-- Bring back a group member whose worker has stopped talking - a crash, a manual /lua stop, or a reload
-- that did not take.
reviveAt     = {}   -- char -> gettime of the last relaunch attempt (cooldown)
reviveStrike = {}   -- char -> consecutive failed pings
reviveWait   = {}   -- char -> when a ping went out that has not been judged yet
reviveFirstSeen = {} -- char -> when first considered, so 'never reported yet' is not read as
                     -- 'silent since the epoch' and the worker killed before it can speak
-- HOW LONG A HEALTHY WORKER MAY REASONABLY SAY NOTHING.
function expected_gap()
    local g = 300000                             -- nothing unconditional: tribute keepalive, 5 minutes
    if rezAuto then g = math.min(g, 20000) end   -- rez heartbeat, idle cadence (20s - see the rez beat)
    if DI.auto then g = math.min(g, 6000) end    -- DI heartbeat, out-of-combat cadence
    return g
end
function revive_check()
    if not SHOW_UI then return end
    local now, limit = mq.gettime(), expected_gap() * 2 + 3000
    -- NOT OURS, LEFT ALONE (1.21.2): a group member the network does not see is somebody else's character -
    -- it was pinged every 2 minutes and told to start a worker it does not have (bring_up_group skips them too).
    local netSet = net_peer_set()
    for _, nm in ipairs(group_members()) do
        if nm:lower() ~= myName:lower() and net_is_peer(nm, netSet) then
            local last = 0
            for _, t in ipairs({ burnState[nm], potState[nm], healState[nm], cureState[nm],
                                 DI.state[nm], rezReady[nm], tributeState[nm], burnSumAt[nm] }) do
                if type(t) == 'table' then
                    if t.updated and t.updated > last then last = t.updated end
                    for _, v in pairs(t) do
                        if type(v) == 'table' and v.updated and v.updated > last then last = v.updated end
                    end
                end
            end
            -- NEVER HEARD FROM IS NOT THE SAME AS WENT SILENT.
            if last == 0 then last = reviveFirstSeen[nm] or now; reviveFirstSeen[nm] = last end
            if (now - last) <= limit then
                reviveStrike[nm] = 0                      -- talking: clear any strikes
                reviveWait[nm] = nil
            elseif reviveWait[nm] then
                -- THE ANSWER IS READ ON A LATER PASS, not waited for. This used to hold the loop up to 2s
                -- per quiet toon waiting on the pong (6s blocks in the logs); revive_check runs every 5s.
                if alive[nm:lower()] or (now - reviveWait[nm]) >= 2000 then
                    reviveWait[nm] = nil
                    if alive[nm:lower()] then
                        reviveStrike[nm] = 0              -- answered: alive, just had nothing to say
                    else
                        reviveStrike[nm] = (reviveStrike[nm] or 0) + 1
                        if reviveStrike[nm] >= 2 then
                            reviveStrike[nm] = 0
                            peer_cmdf(nm, '/lua run %s worker %s', AT_ENTRY, myName)
                            log('\\ay[sync] %s silent %ds and failed 2 pings - restarting its worker\\ax',
                                nm, math.floor((now - last) / 1000))
                        end
                    end
                end
            elseif (now - (reviveAt[nm] or 0)) > 120000 then
                alive[nm:lower()] = nil
                peer_cmdf(nm, '/at_ping %s', myName)
                reviveAt[nm] = now
                reviveWait[nm] = now
            end
        end
    end
end

-- The detailed burn table, lifted out of the Burns tab so BOTH windows can use it.
-- THE MINI'S BURN NAMES: the icon carries the identity, so the text only has to tell neighbours apart.
-- Filler prefixes and rank suffixes go, then a hard cap. The full name is always on hover.
MINI_BURN_CHARS, MINI_BURN_CHARS_NOICON = 10, 16
BURN_NAME_STRIP = { '^Draught of ', '^Glyph of ', '^Fundament: ', '^Improved ', '^Imbued ', '^Group ' }
burnShortCache = {}
function burn_short_name(it, cap)
    local k = it .. '#' .. cap
    local v = burnShortCache[k]
    if v then return v end
    local nm = it
    for _, pat in ipairs(BURN_NAME_STRIP) do nm = nm:gsub(pat, '') end
    nm = nm:gsub('%s+Rk%.?%s*%a+$', ''):gsub('%s+[IVX]+$', '')
    if #nm > cap then
        -- Whole first word, then as much of the next real word as fits (at least three letters).
        local words = {}
        for w in nm:gmatch('%S+') do
            local lw = w:lower()
            if lw ~= 'of' and lw ~= 'the' and lw ~= 'a' and lw ~= 'an'
               and lw ~= 'first' and lw ~= 'second' and lw ~= 'third' then words[#words + 1] = w end
        end
        local out = (words[1] or nm):sub(1, cap)
        local room = cap - #out - 1
        if words[2] and room >= 3 then out = out .. ' ' .. words[2]:sub(1, room) end
        nm = out
    end
    burnShortCache[k] = nm
    return nm
end
function draw_burn_table(filter)
    -- Called with a filter only from the mini, which wants it compact: columns sized to their content,
    -- icon + a short name + the timer.
    local compact = (filter ~= nil)
    -- Its OWN filter, not the tab's. Mini is where you sit on DPS all night; the tab is where you go
    -- to look at everyone. Sharing one filter would make each view keep changing the other.
    local flt = filter or burnFilter
        if next(burnState) == nil then
            ImGui.TextDisabled('waiting for reports...')
        else
            -- Driven by GROUP ORDER, not pairs(burnState) sorted alphabetically.
            local chars = {}
            for _, c in ipairs(ordered_members()) do
                if burnState[c] and (flt == 'All' or role_of(burnClass[c]) == flt) then
                    chars[#chars + 1] = c
                end
            end
            if #chars == 0 then ImGui.TextDisabled('no ' .. flt .. ' characters reporting') end
            -- Prefix strip only - NO character cap.
            local function short(nm) return (nm:gsub('^Draught of ', '')) end
            local function shortCap(nm)   -- fallback path only; it cannot measure
                nm = short(nm)
                if #nm > 18 then return nm:sub(1, 17) .. '...' end
                return nm
            end
            -- Seconds left on a report (-1 = permanently down, e.g. a disc with no timer read).
            local remain_of, sort_rank = burn_remain, burn_rank
            -- Name left, timer RIGHT-ALIGNED.
            local function cell(st, it)
                local r = remain_of(st)
                local compactCell = compact
                local stamp, cr, cg, cb
                if st.active then
                    -- RUNNING NOW.
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

                if compactCell then
                    local fsz = math.floor(ImGui.GetFontSize())
                    local hasIcon = ui_icon(it, nil, fsz)
                    if hasIcon then ImGui.SameLine(0, 3) end
                    ImGui.TextColored(cr, cg, cb, 1.0,
                        burn_short_name(it, hasIcon and MINI_BURN_CHARS or MINI_BURN_CHARS_NOICON))
                    local hov = ImGui.IsItemHovered and ImGui.IsItemHovered()
                    if not BURN_STAMP_W then
                        pcall(function() BURN_STAMP_W = math.ceil(ImGui.CalcTextSize('00:00') or 0) end)
                        BURN_STAMP_W = BURN_STAMP_W or 36
                    end
                    -- The timer slot is held open only in a column that has a timer somewhere in it; a
                    -- column of nothing but ready burns needs no room for one.
                    if stamp == '' and not burnColStamp then
                        if hov then pcall(function() ImGui.SetTooltip(it) end) end
                        return
                    end
                    ImGui.SameLine(0, 5)
                    if stamp ~= '' then
                        ImGui.TextColored(cr, cg, cb, 1.0, stamp)
                        hov = hov or (ImGui.IsItemHovered and ImGui.IsItemHovered())
                        local sw = BURN_STAMP_W
                        pcall(function() sw = ImGui.CalcTextSize(stamp) or sw end)
                        if sw < BURN_STAMP_W then ImGui.SameLine(0, 0); ImGui.Dummy(BURN_STAMP_W - sw, 1) end
                    else
                        ImGui.Dummy(BURN_STAMP_W, 1)
                    end
                    if hov then pcall(function() ImGui.SetTooltip(it) end) end
                    return
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
                    local iconW = 0
                    do
                        local fsz = math.floor(ImGui.GetFontSize())
                        if ui_icon(it, nil, fsz) then ImGui.SameLine(0, 4); iconW = fsz + 4 end
                    end
                    local budget = availW - stampW - 10 - iconW   -- 10px gutter between name and timer
                    -- Trim BEFORE measuring.
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
                if ui_tip_hover() then pcall(function() ImGui.SetTooltip(it) end) end   -- full name on hover
            end
            -- Each character's column flows independently: its own tier headings, its own items, no
            -- blank padding to line up with whoever has the most.
            local tflags = (ImGuiTableFlags.BordersInnerV or 0) + (ImGuiTableFlags.RowBg or 0)
                         + (compact and (ImGuiTableFlags.SizingFixedFit or 0)
                            or ((ImGuiTableFlags.Resizable or 0)
                                + (ImGuiTableFlags.SizingStretchSame or ImGuiTableFlags.SizingStretchProp or 0)))
            -- A per-column CEILING, not a target.
            local wantW = #chars * 400
            local okW, availW2 = pcall(function() return ImGui.GetContentRegionAvail() end)
            if okW and availW2 and availW2 > 0 then wantW = math.min(wantW, availW2) end
            local opened = false
            if #chars > 0 then
                -- The 5-argument form (with an outer size) is not in every ImGui binding, so try it and
                -- fall back.
                if compact then
                    burnPadPushed = pcall(function() ImGui.PushStyleVar(ImGuiStyleVar.CellPadding, 4, 1) end)
                    opened = ImGui.BeginTable('##burnsmini', #chars, tflags)
                    if not opened and burnPadPushed then pcall(function() ImGui.PopStyleVar(1) end); burnPadPushed = false end
                else
                    local ok, res = pcall(ImGui.BeginTable, '##burns', #chars, tflags, wantW, 0)
                    if ok then opened = res and true or false
                    else       opened = ImGui.BeginTable('##burns', #chars, tflags) end
                end
            end
            if opened then
                -- Equal real estate: every column the same width. (Weighting them by content
                -- made the widths jump around as names changed, which read worse than a plain grid.)
                for _, c in ipairs(chars) do
                    local ok = compact or pcall(function()
                        ImGui.TableSetupColumn(c, (ImGuiTableColumnFlags.WidthStretch or 0), 1.0)
                    end)
                    if compact or not ok then ImGui.TableSetupColumn(c) end
                end
                ImGui.TableHeadersRow()

                -- Which columns have any timer showing, for the compact cell's timer slot.
                local colStamp = {}
                for _, c in ipairs(chars) do
                    for _, st in pairs(burnState[c]) do
                        if (st.tier or 0) > 0 and (st.active or burn_remain(st) ~= 0) then colStamp[c] = true; break end
                    end
                end
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
                    elseif frac >= 0.33 then  ui_text(UI_WAIT, string.format('%d/%d ready', rdy, tot))
                    else                      ImGui.TextColored(0.85, 0.35, 0.35, 1.0, string.format('%d/%d ready', rdy, tot)) end
                end

                -- One row per tier, so the tier headings line up across every column and you can scan
                -- sideways.
                for _, tinfo in ipairs(burn_tiers_present(chars)) do
                    do
                        -- ONE tier heading, in the first column only.
                        ImGui.TableNextRow()
                        ImGui.TableNextColumn()
                        ui_text(UI_LABEL, tinfo.label)
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
                                burnColStamp = colStamp[c]
                                for _, it in ipairs(its) do cell(burnState[c][it], it) end
                            end
                        end
                    end
                end
                ImGui.EndTable()
                if compact and burnPadPushed then pcall(function() ImGui.PopStyleVar(1) end); burnPadPushed = false end
            end
        end
end

-- POP-OUTS.
popOut = {}          -- section key -> panel number, or nil for the mini
-- THE ORDER YOU BUILT IT IN.
popSeq = {}
popSeqN = 0
function pop_place(key, panel)
    popOut[key] = panel
    if panel then
        popSeqN = popSeqN + 1
        popSeq[key] = popSeqN
    else
        popSeq[key] = nil     -- back in the mini: it follows miniOrder again
    end
    -- Every window involved just changed what it contains, so the latched right edge is stale. Drop it
    -- all and let the next frame measure the real content again - see pop_align.
    POP_RIGHT = {}; WIN_LATCH = {}
end
POP_PANELS = 8       -- room to pop several out individually and still merge some together

-- DRAG A SECTION FROM ONE WINDOW TO ANOTHER, the way a browser tab moves between windows.
function pop_dragging()
    if not ImGui.GetDragDropPayload then return false end
    local ok, pl = pcall(function() return ImGui.GetDragDropPayload() end)
    return ok and pl ~= nil
end

-- A BIG, OBVIOUS PLACE TO LET GO.
function pop_drop_zone(panel, label)
    if not pop_dragging() then return end
    ImGui.PushStyleColor(ImGuiCol.Button, 0.20, 0.40, 0.25, 1.0)
    ImGui.Button((label or 'drop here') .. '##at_dz_' .. tostring(panel or 'mini'), -1, 22)
    ImGui.PopStyleColor()
    pop_drop_target(panel)
end

-- ONE ICON, TWO GESTURES.
function pop_grip(key, panel)
    local clicked = ImGui.SmallButton(POP_ICON .. '##grip_' .. tostring(key))
    -- Measure it once, here, where the real button exists. pop_align needs the exact footprint and
    -- guessing at the theme's frame padding is what a creeping panel is made of.
    if not POP_ICON_W then
        pcall(function()
            local iw = ImGui.GetItemRectSize()
            if iw and iw > 0 then POP_ICON_W = iw end
        end)
    end
    if ui_tip_hover() then
        pcall(function() ImGui.SetTooltip(panel
            and 'Click: send this back to the mini\nDrag: move it onto another window'
            or  'Click: give this its own window\nDrag: move it onto another window') end)
    end
    return clicked
end

-- PULL THE STRING OUT OF WHATEVER AcceptDragDropPayload RETURNS.
function pop_payload_key(payload)
    if payload == nil then return nil end
    if type(payload) == 'string' then return payload end
    local got
    pcall(function() got = payload.Data end)
    if type(got) ~= 'string' then pcall(function() got = payload.data end) end
    if type(got) ~= 'string' then pcall(function() got = payload.RawData end) end
    if type(got) == 'string' then return got end
    return nil
end

function pop_drag_source(key, label)
    -- SourceAllowNullID, because the thing being dragged is a Text item.
    local flags = (ImGuiDragDropFlags and ImGuiDragDropFlags.SourceAllowNullID) or 8
    if ImGui.BeginDragDropSource and ImGui.BeginDragDropSource(flags) then
        pcall(function() ImGui.SetDragDropPayload('AT_SECTION', key) end)
        ImGui.Text('move ' .. (label or key))
        ImGui.EndDragDropSource()
    end
end

-- REORDER A LIST BY DRAGGING, for the three places that had a pair of arrow buttons per row.
function drag_reorder(list, i, kind, label)
    local moved = false
    -- Same reason as pop_drag_source: these rows are dragged by a Text grip, which carries no id.
    local flags = (ImGuiDragDropFlags and ImGuiDragDropFlags.SourceAllowNullID) or 8
    if ImGui.BeginDragDropSource and ImGui.BeginDragDropSource(flags) then
        pcall(function() ImGui.SetDragDropPayload(kind, tostring(i)) end)
        ImGui.Text(tostring(label or list[i]))
        ImGui.EndDragDropSource()
    end
    if ImGui.BeginDragDropTarget and ImGui.BeginDragDropTarget() then
        local ok, payload = pcall(function() return ImGui.AcceptDragDropPayload(kind) end)
        if ok and payload then
            local from = tonumber(pop_payload_key(payload))
            if from and from ~= i and list[from] then
                local item = table.remove(list, from)
                table.insert(list, i, item)
                moved = true
            end
        end
        ImGui.EndDragDropTarget()
    end
    return moved
end

-- Called just after a window's contents. panel = the number to assign, or nil to send it to the mini.
function pop_drop_target(panel)
    if not ImGui.BeginDragDropTarget then return end
    if ImGui.BeginDragDropTarget() then
        local ok, payload = pcall(function() return ImGui.AcceptDragDropPayload('AT_SECTION') end)
        if ok and payload then
            -- WHATEVER SHAPE IT ARRIVES IN.
            local key = pop_payload_key(payload)
            if key and mini_section(key) then
                -- Through pop_place, so a dropped section is stamped and lands at the BOTTOM of the
                -- window it was dropped on - which is where the gesture pointed.
                pop_place(key, panel)
                save_settings()
                log('[pop] %s moved to %s', key, panel and ('panel ' .. panel) or 'the mini')
            elseif not POP_SAID_PAYLOAD then
                POP_SAID_PAYLOAD = true
                log('\\ay[pop] a drop arrived but the payload did not read as a section: %s (%s)\\ax',
                    tostring(key), type(payload))
            end
        end
        ImGui.EndDragDropTarget()
    end
end

local function draw_popouts()
    -- POP-OUTS WERE NEVER THEMED.
    local popC, popV = ui_push_chrome()
    for p = 1, POP_PANELS do
        -- Who lives here? In miniOrder order, so a panel reads the way the mini would.
        local mine = {}
        for _, k in ipairs(miniOrder) do
            local sec = mini_section(k)
            if sec and sec.draw and popOut[k] == p then
                mine[#mine + 1] = sec
                sec._seq = popSeq[k] or 0
            end
        end
        -- In the order they were placed here.
        table.sort(mine, function(a, b) return (a._seq or 0) < (b._seq or 0) end)
        if #mine > 0 then
            -- TITLED BY ITS CONTENTS. A window called 'Panel 2' tells you nothing once you have three of
            -- them; one called 'Pacify + Rez' is self-describing and updates itself as you move things.
            local names = {}
            for _, s in ipairs(mine) do names[#names + 1] = s.label end
            local title = table.concat(names, ' + ')
            -- ###at_panel_N and not the title: the id has to stay put or ImGui forgets the window's
            -- size and position the moment its contents change.
            local pflags = ImGuiWindowFlags.AlwaysAutoResize or 0
            local pinned = (popLocked or {})[p]
            if pinned then
                pflags = pflags + (ImGuiWindowFlags.NoMove or 0) + (ImGuiWindowFlags.NoResize or 0)
                -- NO TITLE BAR WHILE PINNED, and only while pinned.
                pflags = pflags + (ImGuiWindowFlags.NoTitleBar or 0)
            end
            ui_latch_before('panel' .. p)
            local show = ImGui.Begin(title .. '###at_panel_' .. p, true, pflags)
            if show then ui_latch_after('panel' .. p) end
            -- DOCKED IS NOT MERGED.
            if show and ImGui.IsWindowDocked and ImGui.IsWindowDocked() then
                if not POP_SAID_DOCK then
                    POP_SAID_DOCK = true
                    log('\\ay[pop] that window is DOCKED as a tab, not merged. To merge, drag a section by ' ..
                        'its %s handle onto another window instead of dragging the window itself.\\ax',
                        tostring(POP_GRIP))
                end
            end
            if not show then
                -- Closing a panel sends everything in it home, rather than leaving sections in a window
                -- that is not on screen - which would look exactly like they had vanished.
                for _, s in ipairs(mine) do pop_place(s.key, nil) end
                save_settings()
            else
                -- The zone sits at the TOP, where the cursor already is after dragging onto the window.
                popLocked = popLocked or {}
                if ui_lock_button('##at_panel_lock_' .. p, popLocked[p]) then
                    popLocked[p] = (not popLocked[p]) or nil
                    save_settings()
                end
                if ui_tip_hover() then
                    pcall(function() ImGui.SetTooltip(popLocked[p]
                            and 'Pinned - no title bar, cannot be moved or resized.\nClick to unpin.'
                            or  'Unpinned. Click to pin this panel where it is and drop the title bar.') end)
                end
                ImGui.SameLine()
                -- THE NAME GOES SOMEWHERE.
                pop_drop_zone(p, popLocked[p] and title or 'drop a section here to merge it in')
                for i, s in ipairs(mine) do
                    if i > 1 then ImGui.Spacing(); ImGui.Separator(); ImGui.Spacing() end
                    -- THE GRIP IS THE HANDLE, and it needs to look like one.
                    ImGui.TextDisabled(s.label)
                    pop_align(p)
                    if pop_grip(s.key, p) then
                        pop_place(s.key, nil)
                        save_settings()
                    end
                    pop_drag_source(s.key, s.label)
                    pop_drop_target(p)
                    pcall(s.draw)
                end
                -- WHOLE-WINDOW DROP ZONE.
                if pop_dragging() then
                    local availX, availY = ImGui.GetContentRegionAvail()
                    if availY and availY > 4 then
                        ImGui.InvisibleButton('##at_drop_' .. p, math.max(availX or 40, 40), availY)
                        pop_drop_target(p)
                    end
                end
            end
            ImGui.End()
        end
    end
    ui_pop_chrome(popC, popV)
end

local function render()
    -- NOT WHILE THE CLIENT IS ZONING.
    if client_ready and not client_ready() then return end
    -- The pop-outs stand on their own: they are drawn even when the main window is closed, which is the
    -- entire point of popping something out.
    draw_popouts()
    if not windowOpen then return end
    if miniMode then   -- compact tribute-only window (its own ###id so it keeps its own small size/pos)
        -- AlwaysAutoResize is right for the compact view, and WRONG once the detail burn table is on:
        -- auto-resize will not grow past what the rest of the content wants, and ImGui clamps a table's
        -- outer width to the available region - so the extra columns just got ...
        -- Since 1.20.34 the mini's burn table sizes its columns to their content, so the window can
        -- auto-resize around it like every other view and shrink back when a section closes.
        local mflags = (ImGuiWindowFlags.AlwaysAutoResize or 0) + (ImGuiWindowFlags.NoScrollbar or 0)
        -- LOCK. NoMove alone is not enough - a window you cannot drag but can still resize by the corner
        -- still wanders, and the reason to lock one is that a stray click while fighting moves it.
        if uiLocked then
            mflags = mflags + (ImGuiWindowFlags.NoMove or 0) + (ImGuiWindowFlags.NoResize or 0)
            -- AND NO TITLE BAR, same bargain as the pinned pop-outs.
            mflags = mflags + (ImGuiWindowFlags.NoTitleBar or 0)
        end
        -- Fires once per session as well as on the toggle: if detail was ALREADY on at load, the toggle
        -- never runs, and ImGui just restores the small size it remembered from when this was an
        -- auto-resizing window.
        if (miniBurns and miniBurnView == 2) and not miniSizedOnce then
            miniSizedOnce = true; miniSizeWanted = true
        end
        -- NO 'fit' BUTTON.
        do
            local n = 0
            for _, c in ipairs(ordered_members()) do
                if burnState[c] and (miniBurnFilter == 'All' or role_of(burnClass[c]) == miniBurnFilter) then
                    n = n + 1
                end
            end
            -- A SECTION APPEARING OR VANISHING IS A SHAPE CHANGE.
            local hidden = ''
            for _, s in ipairs(MINI_SECTIONS) do
                if s.has then hidden = hidden .. (s.has() and '1' or '0') end
            end
            local shape = string.format('%d|%d|%s|%s|%s', miniBurnView, n, tostring(miniBurns),
                                        miniBurnFilter, hidden)
            if shape ~= miniShapeKey then
                miniShapeKey = shape
                if miniShapeKey ~= nil then miniSizeWanted = true end
                POP_RIGHT = {}; WIN_LATCH = {}
            end
        end
        if miniSizeWanted then
            miniSizeWanted = false
            -- ONLY WHEN AUTO-RESIZE IS OFF.
            if false then   -- auto-resize does this now
                local w, h = mini_table_size()
                local okS = pcall(function() ImGui.SetNextWindowSize(w, h, ImGuiCond.Always or 1) end)
                if not okS then pcall(function() ImGui.SetNextWindowSize(w, h) end) end
            end
        end
        local chromeC, chromeV = ui_push_chrome()
        ui_latch_before('mini')
        local show = ImGui.Begin('AdventureTime ' .. VERSION .. '###advtime_mini', windowOpen, mflags)
        windowOpen = show
        if show then
            ui_latch_after('mini')
            ui_draw_probe()
            -- THE GROUP IN ONE LINE, above everything.
            if ui_lock_button('##at_lock', uiLocked) then
                uiLocked = not uiLocked
                save_settings()
            end
            if ui_tip_hover() then
                pcall(function() ImGui.SetTooltip(uiLocked
                        and 'Locked - no title bar, cannot be moved or resized.\nClick to unlock.'
                        or  'Unlocked. Click to pin it in place and drop the title bar.') end)
            end
            ImGui.SameLine()
            if ImGui.SmallButton('Expand') then miniMode = false; save_settings() end
            ImGui.SameLine()
            -- The same Close all that sits at the bottom of the expanded window, put where it can be
            -- reached without expanding first.
            draw_close_all('miniclose', false)
            ImGui.SameLine()
            at_draw_update_button('miniupdate')
            -- COTH ON THE HEADER, HARD RIGHT.
            if miniCoth then
                ImGui.SameLine(0, 12)
                draw_coth_mini()
            end
            -- The Burns and Rez toggles that used to sit here are gone.
            ImGui.Spacing()
            draw_tribute_mini()
            -- COLLAPSE PER SECTION.
            for _, k in ipairs(miniOrder) do
                local sec = mini_section(k)
                -- CoTH is drawn on the header row above, so it is skipped here.
                if k == 'coth' then sec = nil end
                -- POPPED OUT MEANS IT LIVES SOMEWHERE ELSE, so the mini does not draw it as well.
                if sec and popOut[k] then sec = nil end
                -- NOTHING TO SAY, SO NOTHING DRAWN - not even the title.
                if sec and sec.has and not sec.has() then sec = nil end
                if sec and sec.get and sec.get() and sec.draw then
                    -- The grey rule is gone. ui_section_head draws one in the section's own hue, and two
                    -- separators a line apart is just a thicker grey band with a title lost in it.
                    ImGui.Spacing()
                    local folded = false
                    if MINI_FOLDABLE[k] then
                        local sepc = (UI_SECTION[k] or {}).dot or { 90, 95, 110 }
                        local okS = pcall(function()
                            ImGui.PushStyleColor(ImGuiCol.Separator, IM_COL32(sepc[1], sepc[2], sepc[3], 90))
                            ImGui.Separator()
                            ImGui.PopStyleColor(1)
                        end)
                        if not okS then ImGui.Separator() end
                        ImGui.Spacing()
                        folded = miniFold[k] and true or false
                        -- The caret IS the button, so the title line is the hit target rather than a
                        -- separate widget crowding the row.
                        local sc = UI_SECTION[k]
                        if sc then ui_dot(sc.dot) end
                        ui_push_text(sc and sc.label or UI_HEAD)
                        local foldClicked = ImGui.SmallButton((folded and '> ' or 'v ') .. (sec.label or k) .. '##fold_' .. k)
                        pcall(function() ImGui.PopStyleColor(1) end)
                        if foldClicked then
                            miniFold[k] = (not folded) or nil
                            -- Folding usually removes the widest thing in the window, and the latched
                            -- right edge cannot see that on its own. Drop it - see pop_align.
                            POP_RIGHT = {}; WIN_LATCH = {}
                            save_settings()
                        end
                        if ui_tip_hover() then
                            pcall(function() ImGui.SetTooltip(folded
                                and 'Click to show this section'
                                or  'Click to fold it away - it stays on, just out of the way') end)
                        end
                        -- WIPE LIVES ON THE HEADER, always - not just when folded.
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
                    -- POP IT OUT FROM HERE.
                    if MINI_FOLDABLE[k] then
                        -- the fold caret was drawn above; stay on its line
                    else
                        ui_section_head(k, sec.label or k)
                    end
                    -- Over to the right of the labels, at a fixed column.
                    pop_align('mini')   -- SameLine is inside pop_align now; two would double the gap
                    if pop_grip(k) then
                        local used = {}
                        for _, v in pairs(popOut) do if type(v) == 'number' then used[v] = true end end
                        local slot
                        for pnum = 1, POP_PANELS do if not used[pnum] then slot = pnum; break end end
                        if slot then pop_place(k, slot); save_settings()
                        else log('\\ay[pop] all %d panels are in use - drag it onto one instead\\ax', POP_PANELS) end
                    end
                    pop_drag_source(k, sec.label)
                    pop_drop_target(nil)      -- drop onto a mini row to bring a section home
                    if not folded then sec.draw() end
                end
            end
            -- DROP ANYTHING HERE TO BRING IT HOME.
            pop_drop_zone(nil, 'drop here to put a section back in the mini')
        end
        ImGui.End()
        ui_pop_chrome(chromeC, chromeV)
        return
    end
    ImGui.SetNextWindowSize(560, 500, ImGuiCond.FirstUseEver)
    -- Same as the mini and the pinned pop-outs: locked means no drag and no close, so the bar carrying
    -- both is dead weight.
    local wflags = uiLocked
        and ((ImGuiWindowFlags.NoMove or 0) + (ImGuiWindowFlags.NoResize or 0)
             + (ImGuiWindowFlags.NoTitleBar or 0))
        or 0
    local chromeC, chromeV = ui_push_chrome()
    local show = ImGui.Begin('AdventureTime ' .. VERSION .. '###advtime', windowOpen, wflags)
    windowOpen = show
    if show then
        -- top strip: global controls + the tribute glance (always visible, above the tabs) Padlock:
        -- closed when locked, open when not.
        if ui_lock_button('##at_lock', uiLocked) then
            uiLocked = not uiLocked
            save_settings()
        end
        if ui_tip_hover() then
            pcall(function() ImGui.SetTooltip(uiLocked
                and 'Locked - the window cannot be moved or resized.\nClick to unlock.'
                or  'Unlocked. Click to pin it in place so a stray click cannot drag it.') end)
        end
        ImGui.SameLine()
        if ImGui.Button('Mini', 50, 0) then miniMode = true; save_settings() end
        -- CLOSE ALL MOVED UP HERE from the bottom of the window.
        ImGui.SameLine()
        draw_close_all('mainclose', true)   -- global: shuts every instance, asks first
        ImGui.SameLine()
        at_draw_update_button('mainupdate')
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
                local dis = ui_disable_if(distributing)
                if ImGui.Button('Collect all', 100, 0) then collectRequested = true end   -- pull everything to this toon
                ui_enable(dis)
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
                if BURN_FILE_USED then
                    ui_text(UI_OFF, 'Source: ' .. path_show(BURN_FILE_USED))
                else
                    ui_text(UI_WAIT, 'No burn list on this toon - see ' .. path_show(burn_file_path()))
                end
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
            if ImGui.BeginTabItem('Commands') then
                draw_commands_tab()
            end
            if ImGui.BeginTabItem('Settings') then
                ImGui.Spacing()
                ImGui.TextColored(0.45, 0.75, 0.95, 1.0,
                    'AdventureTime ' .. VERSION .. '   (build ' .. BUILD_TAG .. ')')
                do
                    local st = at_refresh_update_status(false)
                    ImGui.SameLine()
                    if st.available then
                        ui_text(UI_WAIT, 'Update available')
                    elseif st.status == 'up_to_date' then
                        ui_text(UI_READY, 'Up to date')
                    elseif st.error ~= '' then
                        ui_text(UI_WAIT, 'Update check failed')
                    else
                        ui_text(UI_OFF, 'Update status unknown')
                    end
                    if ui_tip_hover() then
                        pcall(function()
                            local latest = at_short_sha(st.latestSha)
                            local installed = at_short_sha(st.installedSha)
                            ImGui.SetTooltip(string.format(
                                'Installed: %s\nLatest: %s\nChecked: %s',
                                installed ~= '' and installed or 'unknown',
                                latest ~= '' and latest or 'unknown',
                                st.checkedAtUtc ~= '' and st.checkedAtUtc or 'never'))
                        end)
                    end
                end
                ImGui.Separator()
                ImGui.Spacing()
                -- SMART CAST GEMS.
                do
                    local casters = {}
                    for nm, c in pairs(pacCap) do
                        if c.kind == 'placate' then casters[#casters + 1] = nm end
                    end
                    if #casters > 0 then
                        table.sort(casters)
                        ui_heading('Pacify gems')
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
                            if ui_tip_hover() then
                                local c = pacCap[nm]
                                pcall(function() ImGui.SetTooltip(string.format('%s\n%s\ncaps at level %d',
                                    nm, (c and c.spell) or '?', (c and c.cap) or 0)) end)
                            end
                        end
                    end
                end
                ui_heading('Appearance')
                ImGui.Spacing()
                -- DRAWN TOGGLES rather than checkboxes. The knob moving is legible from further away
                -- than a tick mark, and this is the one panel where a wrong setting is easy to miss.
                do
                    if ui_toggle('##ui_chrome', UI_CHROME) then UI_CHROME = not UI_CHROME; save_settings() end
                    ImGui.SameLine(); ImGui.Text('Themed window')
                    if ui_tip_hover() then
                        pcall(function() ImGui.SetTooltip(
                            'Darker ground, rounded corners, coloured section bands.\nOff returns both windows to stock ImGui.') end)
                    end
                end
                if UI_CHROME then
                    -- Only shown when the chrome is on, because with it off the choice does nothing and a
                    -- control that does nothing is worse than one that is absent.
                    ImGui.SetNextItemWidth(140)
                    local ok = pcall(function()
                        if ImGui.BeginCombo('Theme##ui_theme', uiTheme) then
                            for _, t in ipairs(AT_THEMES) do
                                if ImGui.Selectable(t.name, t.name == uiTheme) and t.name ~= uiTheme then
                                    uiTheme = t.name
                                    save_settings()
                                end
                            end
                            ImGui.EndCombo()
                        end
                    end)
                    -- A binding without BeginCombo still gets to change it, one press at a time.
                    if not ok then
                        if ImGui.SmallButton('Theme: ' .. uiTheme .. '##ui_theme_cycle') then
                            local i = 1
                            for n, t in ipairs(AT_THEMES) do if t.name == uiTheme then i = n end end
                            uiTheme = AT_THEMES[(i % #AT_THEMES) + 1].name
                            save_settings()
                        end
                    end
                end
                do
                    if ui_toggle('##ui_pulse', UI_PULSE) then UI_PULSE = not UI_PULSE; save_settings() end
                    ImGui.SameLine(); ImGui.Text('Flash when something comes up')
                end
                do
                    if ui_toggle('##ui_wide', uiWideButtons) then
                        uiWideButtons = not uiWideButtons; save_settings(); POP_RIGHT = {}; WIN_LATCH = {}
                    end
                    ImGui.SameLine(); ImGui.Text('Line up name buttons')

                    if ui_tip_hover() then
                        pcall(function() ImGui.SetTooltip(
                            'Pads every name button to the same width so the rows read as columns.\nOff lets each button size to its own name.') end)
                    end
                end
                do
                    if ui_toggle('##ui_icons', uiIcons) then uiIcons = not uiIcons; save_settings(); POP_RIGHT = {}; WIN_LATCH = {} end
                    ImGui.SameLine(); ImGui.Text('EverQuest icons')
                    if ui_tip_hover() then
                        pcall(function() ImGui.SetTooltip(
                            'The game\'s own item and spell icons for draughts, countermeasures, emblems,\nrez and DI rows and burns. Off shows the text labels.') end)
                    end
                end
                ui_heading('Performance')
                do
                    -- TWO BUTTONS. Fast mode is MacroQuest's turbo (Lua steps per frame), set on every
                    -- toon: the rezzer and the DI holder are bots, and their passes stretch the same way.
                    -- Low spec is AT's own polling, local to this machine.
                    local fast = (AT_TURBO or -1) >= AT_TURBO_FAST
                    local lowOn = (perfScale or 1) > 1
                    local function perf_button(label, on, onCol, tip)
                        local pushed = 0
                        if ImGuiCol and ImGuiCol.Button then
                            local c = on and onCol or { 0.30, 0.30, 0.33 }
                            ImGui.PushStyleColor(ImGuiCol.Button, c[1], c[2], c[3], 1.0); pushed = 1
                            if ImGuiCol.ButtonHovered then
                                ImGui.PushStyleColor(ImGuiCol.ButtonHovered, c[1] + 0.12, c[2] + 0.12, c[3] + 0.12, 1.0)
                                pushed = 2
                            end
                        end
                        local hit = ImGui.Button(label, 170, 0)
                        if pushed > 0 then ImGui.PopStyleColor(pushed) end
                        ui_help(tip)
                        return hit
                    end
                    if perf_button(fast and 'Fast mode: ON##perf_fast' or 'Fast mode: OFF##perf_fast', fast,
                        { 0.18, 0.48, 0.24 },
                        'MacroQuest pauses Lua scripts after a set number of steps every frame (turbo).\n'
                     .. 'At the default 500, each AdventureTime pass gets paused several times, so rez,\n'
                     .. 'DI and everything else react later. Fast mode sets turbo to '
                     .. AT_TURBO_FAST .. ' on every toon in\nthe group: same total work, finished in a frame or two.\n'
                     .. 'It is a MacroQuest setting, so other Lua scripts get it too.\n'
                     .. 'Off puts everyone back to 500.') then
                        local v = fast and 500 or AT_TURBO_FAST
                        pcall(function() mq.cmdf('/lua conf turboNum %d', v) end)
                        for _, nm in ipairs(group_members()) do
                            if nm:lower() ~= myName:lower() then
                                pcall(function() peer_cmdf(nm, '/lua conf turboNum %d', v) end)
                            end
                        end
                        AT_TURBO = v
                        AT_DISP_TICKS, AT_DISP_AT, AT_DISP_WAIT_SUM, AT_DISP_WANT_SUM = 0, mq.gettime(), 0, 0
                        AT_DISP_FR_SUM, AT_DISP_FR_N, AT_DISP_RATE = 0, 0, 0
                        log('[perf] fast mode %s - MacroQuest turbo %d on the whole group', fast and 'off' or 'ON', v)
                    end
                    ImGui.SameLine()
                    if perf_button(lowOn and 'Low spec mode: ON##perf_low' or 'Low spec mode: OFF##perf_low', lowOn,
                        { 0.58, 0.38, 0.16 },
                        'For a slow machine. Polls everything 3x less often, cutting the work per pass\n'
                     .. 'by roughly the same. Readouts update more slowly.\n'
                     .. 'DI, CoTH and invis are unaffected - those act on message arrival.\n'
                     .. 'Rez steps once per pass, so the rez fast lane takes over while a corpse is up.\n'
                     .. 'This machine only.') then
                        perfScale = lowOn and 1 or 3
                        AT_LOWSPEC_STREAK = 0
                        save_settings()
                        log('[cpu] low spec mode %s - polls now run at %dx their interval',
                            (perfScale > 1) and 'ON' or 'off', perfScale)
                    end
                    -- THE NUMBER, ON SCREEN.
                    do
                        -- The wait the loop REALLY asked for, averaged over the window - which is not
                        -- pace(250) on any tick the fast lane was engaged.
                        local ideal = 60000 / math.max(1, (AT_DISP_WANT > 0) and AT_DISP_WANT or pace(250))
                        local pct = (AT_DISP_RATE / ideal) * 100
                        local col = (pct >= 80) and UI_READY or (pct >= 55) and UI_WAIT or { 0.85, 0.35, 0.35 }
                        ImGui.Spacing()
                        ui_text(UI_LABEL, 'Loop')
                        ImGui.SameLine()
                        if AT_DISP_RATE <= 0 then
                            ui_text(UI_OFF, 'measuring...')
                        else
                            ui_text(col, string.format('%.0f%%', pct))
                        end
                        if AT_DISP_RATE > 0 and ui_tip_hover() then
                            pcall(function()
                                local want = (AT_DISP_WANT > 0) and AT_DISP_WANT or pace(250)
                                ImGui.SetTooltip(string.format(
                                    'How often AdventureTime completes a pass, against the %dms wait it aims for.\n'
                                 .. 'Around 90%% is the practical ceiling. Rez and DI step once per pass,\n'
                                 .. 'so a slower loop means slower reactions.\n\n'
                                 .. '%.0f passes/min   work %.0fms a pass%s   game overshoot %.0fms%s',
                                    math.floor(want), AT_DISP_RATE, AT_DISP_WORK,
                                    (AT_DISP_FR >= 0) and string.format(' (%.1f frames)', AT_DISP_FR) or '',
                                    math.max(0, AT_DISP_WAIT - want),
                                    (AT_DISP_FPS > 0) and string.format('\n%.0f fps, turbo %d%s', AT_DISP_FPS, AT_TURBO,
                                        (AT_DISP_SHARE >= 0) and string.format(', AT uses %.0f%% of each second', AT_DISP_SHARE) or '') or ''))
                            end)
                        end
                    end
                    -- THE NUDGE, only while it matters. Fast mode first: until turbo is up, 'us' is mostly
                    -- MacroQuest's pauses and would point at the wrong fix.
                    if (AT_TURBO or -1) > 0 and AT_TURBO < 1000 then
                        ui_text(UI_WAIT, string.format('MacroQuest turbo is %d%s - turn on Fast mode for a faster loop.',
                            AT_TURBO, (AT_DISP_FR or -1) >= 2
                                and string.format(', so each pass is paused across %.0f frames', AT_DISP_FR) or ''))
                    elseif AT_LOWSPEC_STREAK >= AT_LOWSPEC_WINDOWS then
                        ui_text(UI_WAIT, string.format('This machine is at %.0f fps and AdventureTime uses %.0f%% of it - turn on Low spec mode.',
                            AT_DISP_FPS, AT_DISP_SHARE))
                    end
                end
                ui_heading('Peer transport')
                ui_help('How AdventureTime talks to other boxes.\nAuto prefers DanNet, then E3, then EQBC. Linux/Wine: use E3 or EQBC.')
                ImGui.SetNextItemWidth(150)
                if ImGui.BeginCombo('##at_peer_transport', peer_transport_label(peerTransport)) then
                    for _, key in ipairs({ 'auto', 'e3', 'eqbc', 'dannet' }) do
                        if ImGui.Selectable(peer_transport_label(key), key == peerTransport) and key ~= peerTransport then
                            peerTransport = key
                            peer_transport_reset()
                            save_settings()
                            log('[sync] peer transport setting: %s', peer_transport_label(peerTransport))
                        end
                    end
                    ImGui.EndCombo()
                end
                ImGui.SameLine()
                ui_text(peerChan and UI_READY or UI_WAIT, 'Active: ' .. (peerChan and peer_transport_label(peerChan) or 'detecting'))
                if ImGui.SmallButton('Re-detect##at_peer_transport_redetect') then
                    peer_transport_reset()
                end
                ImGui.SameLine()
                if ImGui.SmallButton('Test group##at_peer_transport_test') then
                    peerTransportTestAt = mq.gettime() + 1
                end
                ui_heading('Bot control')
                ImGui.SameLine()
                ui_text(UI_OFF, 'What AdventureTime pauses locally.')
                ImGui.SetNextItemWidth(150)
                if AT_FORCE_BOT then
                    ui_text(UI_READY, bot_control_label(AT_FORCE_BOT) .. ' (pinned by /lua run ' .. AT_ENTRY .. ')')
                elseif ImGui.BeginCombo('##at_bot_control', bot_control_label(botControl)) then
                    for _, key in ipairs({ 'auto', 'e3', 'rgmercs' }) do
                        if ImGui.Selectable(bot_control_label(key), key == botControl) and key ~= botControl then
                            botControl = key
                            save_settings()
                            log('[bot] bot control setting: %s', bot_control_label(botControl))
                        end
                    end
                    ImGui.EndCombo()
                end
                ImGui.SameLine()
                do
                    local activeBot = active_bot_control()
                    local col = (activeBot == 'rgmercs' and rgmercs_running()) and UI_READY
                        or (activeBot == 'e3' and UI_READY or UI_WAIT)
                    ui_text(col, 'Active: ' .. bot_control_label(activeBot))
                    if activeBot == 'rgmercs' and rgmercs_run_move_paused() then
                        ImGui.SameLine()
                        ui_text(UI_WAIT, 'Move while paused ON: /rgl set runmovepaused false')
                    end
                end
                ImGui.TextDisabled('Auto uses RGMercs if running, otherwise E3.')
                ui_heading('Call of the Hero')
                do
                    -- GROUP WIDE, not per character.
                    if ui_toggle('##coth_swap', cothSwap) then
                        cothSwap = not cothSwap
                        save_settings()
                        for _, nm in ipairs(group_members()) do
                            if nm:lower() ~= myName:lower() then
                                pcall(function()
                                    peer_cmdf(nm, '/at_cothswapset %s', cothSwap and 'on' or 'off')
                                end)
                            end
                        end
                    end
                    ImGui.SameLine(); ImGui.Text('Wear the emblem charm to summon')
                    if ui_tip_hover() then
                        pcall(function() ImGui.SetTooltip(
                            'Spell haste only applies to a clicky that is WORN, so each summoner puts the charm\n'
                         .. 'holding the emblem on for the gather and takes it off afterwards.\n'
                         .. 'Off clicks it straight out of the bag, unhasted - slower, but nothing is moved.') end)
                    end
                end
                ui_heading('Sections')
                ImGui.TextDisabled('Turn off anything you do not use - hidden sections stop rendering.')
                ImGui.Spacing()
                local dirty = false
                local function chk(key, label)
                    local prev = showSec[key]
                    showSec[key] = ui_check(label, showSec[key])
                    if prev ~= showSec[key] then dirty = true end
                end
                chk('tribute', 'Tribute panel')
                chk('pots',    'Pots tab')
                chk('burns',   'Burns tab')
                chk('rez',     'Rez tab')
                -- Was 'Raid chat', which named the MECHANISM of the one setting under it rather than the
                -- feature. Both settings here are about tank XTargets, so the heading says that.
                ui_heading('Auto-XTarget')
                ImGui.Spacing()
                do
                    -- MOVED OFF THE TOP BUTTON ROW.
                    local prev = autoXTank
                    autoXTank = ui_check('Keep tank XTargets up to date automatically', autoXTank)
                    if autoXTank ~= prev then
                        save_settings()
                        if autoXTank then xtankAutoRequested = true end
                    end
                    if ui_tip_hover() then
                        pcall(function() ImGui.SetTooltip(
                            'Healers put the raid\'s tanks on their XTarget list so E3 XTarget heals\n'
                            .. 'can reach them. On: rechecked periodically and after a roster change.') end)
                    end
                end
                do
                    local prev = xtankAnnounce
                    xtankAnnounce = ui_check('Announce tank swaps in /rsay', xtankAnnounce)
                    if xtankAnnounce ~= prev then
                        save_settings()
                        peer_bcast('/at_xtsay %s', xtankAnnounce and 'on' or 'off')
                    end
                end
                -- Auto-Rez and Auto-DI used to be duplicated here.
                ui_heading('Mini window')
                do
                    -- One row per section: arrows set the order, the checkbox sets visibility. Both
                    -- persist, so the mini window can be laid out without touching the code.
                    for i, k in ipairs(miniOrder) do
                        local sec = mini_section(k)
                        if sec then
                            -- GRAB HANDLE instead of two arrows.
                            ImGui.SmallButton(POP_GRIP .. '##gripsec_' .. k)
                            if drag_reorder(miniOrder, i, 'AT_SECORDER', sec.label) then dirty = true end
                            if ui_tip_hover() then
                                pcall(function() ImGui.SetTooltip('Drag to reorder') end)
                            end
                            ImGui.SameLine()
                            local was = sec.get() and true or false
                            local now = ui_check(sec.label .. '##at_sec_' .. k, was)
                            if now ~= was then sec.set(now); dirty = true end
                            -- The panel picker used to live here: M 1 2 3 4 5 6 7 8 on every row, nine
                            -- buttons per section for something the mini now does with one click and a
                            -- drag.
                            if MINI_HELP[k] then
                                ImGui.SameLine()
                                ImGui.TextDisabled('?')
                                if ui_tip_hover() then
                                    pcall(function() ImGui.SetTooltip(MINI_HELP[k]) end)
                                end
                            end
                            -- SHOWN ON EVERY TOON, NOT JUST THE ENCHANTER.
                            if k == 'protect' and (miniCures or miniMagic or miniPots) then
                                local n = 0
                                for _, g in ipairs(cm_rows()) do
                                    n = n + 1
                                    if n % 3 == 1 then ImGui.TextDisabled('     ') else ImGui.SameLine() end
                                    local was = not cm_hidden(g)
                                    local now = ui_check(g .. '##cmrow_' .. g, was)
                                    if now ~= was then
                                        cmOff[g] = (not now) or nil
                                        dirty = true
                                    end
                                end
                            end
                            -- The 'coverage' checkbox went with the row it controlled.
                            if k == 'invis' and miniInvisCombo then
                                ImGui.SameLine()
                                local wasC = miniInvisCombo
                                miniInvisCombo = ui_check('combo##at_inv_combo', miniInvisCombo)
                                if miniInvisCombo ~= wasC then dirty = true end
                                -- WHO CASTS EACH ROW, configured here rather than in the mini window.
                                if miniInvisCombo then draw_invis_picks() end
                            end
                            if k == 'groupheals' and (miniClicks or miniCombos) then
                                ImGui.SameLine()
                                local wasC = miniClicks
                                miniClicks = ui_check('class buttons##at_gh_mgb', miniClicks)
                                if miniClicks ~= wasC then dirty = true end
                                ImGui.SameLine()
                                local wasK = miniCombos
                                miniCombos = ui_check('combos##at_gh_combo', miniCombos)
                                if miniCombos ~= wasK then dirty = true end
                            end
                            -- The placate gem field used to sit here.
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
                                if ui_tip_hover() then
                                    pcall(function() ImGui.SetTooltip(
                                        'compact - one line each, ready count and dots\n' ..
                                        'matrix  - a column per burn tier\n' ..
                                        'full    - every item, timers and names') end)
                                end
                                local nowT = (miniBurnView == 2)
                                if miniBurnView ~= wasV then
                                    -- RESIZE ON EVERY SWITCH, not only on the way into detail.
                                    miniSizeWanted = true
                                    POP_RIGHT = {}; WIN_LATCH = {}
                                    dirty = true
                                end
                            end
                        end
                    end
                end
                -- Character order: who reads left-to-right in the burn views.
                ui_heading('Character order')
                ImGui.TextDisabled('Left to right in the burn views.')
                do
                    local ord = ordered_members()
                    for i, nm in ipairs(ord) do
                        ImGui.SmallButton(POP_GRIP .. '##gripchar_' .. nm)
                        if drag_reorder(ord, i, 'AT_CHARORDER', nm) then
                            charOrder = ord; dirty = true
                        end
                        if ui_tip_hover() then
                            pcall(function() ImGui.SetTooltip('Drag to reorder') end)
                        end
                        ImGui.SameLine()
                        ImGui.Text(string.format('%d. %s', i, nm))
                    end
                    if #ord > 1 and ImGui.SmallButton('Reset to group order##at_cord') then
                        charOrder = {}; dirty = true
                    end
                end
                -- Combo editor.
                ui_heading('Combos')
                ImGui.TextDisabled('One button that presses several class buttons.')
                -- Only classes actually in the group get a checkbox.
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
                            local now = ui_check(opt.label .. '##at_c' .. ci .. '_' .. opt.key, was)
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
                        -- WHAT EACH CHECKED HEAL SHOUTS.
                        for _, m in ipairs(c.members) do
                            local mcls, mkey = combo_parse(m)
                            local me = mkey and mgb_entry(mkey)
                            if mcls and me then
                                local sk  = mgb_say_key(mcls, me)
                                local cur = mgbSay[sk] or ''
                                -- The DEFAULT goes in the label, not as an InputText hint.
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
    ui_pop_chrome(chromeC, chromeV)
end

-- MUTE THE RELAY ECHO, AND KEEP TRYING UNTIL IT TAKES.
atMuted = false
function mute_relay_echo()
    if atMuted then return end
    -- Only touch DanNet's settings when DanNet is OUR transport.
    if not peerChan then peer_detect() end
    if not peerChan then return end
    if peerChan ~= 'dannet' then atMuted = true; return end   -- nothing to mute on E3/EQBC; stop retrying
    if not mq.TLO.Plugin('MQ2DanNet')() then return end
    pcall(function() mq.cmd('/squelch /dnet localecho off') end)
    pcall(function() mq.cmd('/squelch /dnet commandecho off') end)
    atMuted = true
    log('[sync] DanNet relay echo muted (localecho + commandecho off)')
end
-- Retried on the tick until it lands, then never again. The plugin can arrive seconds after we do, so
-- the first retry is quick; after that the tick spaces them out.
atMuteRetryAt = mq.gettime() + 1000
-- PRIME THE PEER TRANSPORT BEFORE THE UI EXISTS.
pcall(mute_relay_echo)
pcall(function() peer_cmdf(tostring(mq.TLO.Me.Name() or ''), '/echo') end)
if DI.ladderOff then
    log('\\ar*** CLERIC SAVE LADDER IS OFF *** every save must come from a DI staff. /atladder on to restore.\\ax')
end
-- MEASURE THE UI.
UI_FRAMES, UI_SAMPLED, UI_TIME = 0, 0, 0
if SHOW_UI then
    mq.imgui.init(scriptName, function()
        UI_FRAMES = UI_FRAMES + 1
        if (UI_FRAMES % 20) ~= 0 then return render() end
        local t0 = mq.gettime()
        local r = render()
        UI_TIME = UI_TIME + (mq.gettime() - t0)
        UI_SAMPLED = UI_SAMPLED + 1
        return r
    end)
end
pcall(function() mq.bind('/at', function() windowOpen = not windowOpen end) end)
-- HOTKEYABLE, because a floating box you have to open through a menu is barely better than a tab.
pcall(function() mq.bind('/atcommand', function(what)
    local all = what and tostring(what):lower() == 'all'
    printf('\ag[AdventureTime %s]\ax commands:', VERSION)
    for _, e in ipairs(AT_COMMANDS) do
        if e.group then printf('\ay%s\ax', e.group)
        else printf('   %-22s %s', e.cmd, e.desc) end
    end
    if not all then
        printf('   \ay/atcommand all\ax also lists the diagnostics and probes')
        return
    end
    -- EVERYTHING ELSE THAT IS BOUND, worked out from the bind list rather than a second hand-written
    -- table - a list of commands that can fall out of step with the commands is worse than none.
    printf('\ayDiagnostics and probes\ax')
    local shown = {}
    for _, e in ipairs(AT_COMMANDS) do
        if e.cmd then shown[(e.cmd:match('^(%S+)'))] = true end
    end
    table.sort(AT_ALL_BINDS)
    for _, c in ipairs(AT_ALL_BINDS) do
        if not shown[c] then printf('   %s', c) end
    end
end) end)

pcall(function() mq.bind('/atinvis',    function() invisFireWanted = true end) end)
pcall(function() mq.bind('/atshimmer',  function() potWanted = 'shimmer'   end) end)
pcall(function() mq.bind('/atfleeting', function() potWanted = 'fortitude' end) end)
pcall(function() mq.bind('/atinferno',  function() potWanted = 'inferno'   end) end)
-- /atpacify [name] - my target, or a named spawn, into the placate queue.
pcall(function() mq.bind('/atpacify', function(who)
    local id = 0
    if who and who ~= '' then
        pcall(function() id = tonumber(mq.TLO.Spawn('npc =' .. who).ID()) or 0 end)
    else
        pcall(function() id = tonumber(mq.TLO.Target.ID()) or 0 end)
    end
    if id <= 0 then
        log('\\ay[pacify] nothing targeted - use /atpacify with a target, or /atpacify <name>\\ax')
        return
    end
    pacAddWanted = { id = id }
end) end)

pcall(function()
    mq.bind('/atpop', function(key)
        if not key or key == '' then
            local names = {}
            for _, s in ipairs(MINI_SECTIONS) do names[#names + 1] = s.key end
            log('[pop] /atpop <name>: %s', table.concat(names, ', '))
            return
        end
        local k = tostring(key):lower()
        for _, s in ipairs(MINI_SECTIONS) do
            if s.key == k then
                pop_place(k, popOut[k] and nil or 1)
                save_settings()
                log('[pop] %s %s', s.label,
                    popOut[k] and ('moved to panel ' .. popOut[k]) or 'back in the mini')
                return
            end
        end
        log('\\ay[pop] no section called "%s" - /atpop on its own lists them\\ax', tostring(key))
    end)
end)
-- BRINGING IT BACK.
pcall(function() mq.bind('/atdraw', function()
    uiDrawProbe = true
    log('[draw] probing on the next frame - the mini window needs to be open')
end) end)

pcall(function() mq.bind('/atcothswap', function(a)
    local arg = a and tostring(a) or ''
    if arg:lower() == 'on' or arg:lower() == 'off' then
        cothSwap = (arg:lower() == 'on')
        save_settings()
        -- Group wide: a gather where half the characters swap and half do not is the worst of both, and
        -- this is a preference about how the group gathers rather than about one character.
        for _, nm in ipairs(group_members()) do
            if nm:lower() ~= myName:lower() then
                pcall(function() peer_cmdf(nm, '/at_cothswapset %s', arg:lower()) end)
            end
        end
        log('[coth] charm swapping %s for the group', cothSwap and 'ON' or 'off')
        return
    end
    if arg:lower() == 'back' then cothSwapWant = { back = true }; return end
    if arg ~= '' and arg:lower() ~= 'status' and arg:lower() ~= 'find' then
        cothSwapWant = { name = arg:gsub('_', ' ') }
        return
    end
    local now = ''
    pcall(function() now = tostring(mq.TLO.Me.Inventory('charm').Name() or '') end)
    log('[coth] charm slot: %s', (now ~= '') and now or '(empty)')
    log('[coth] saved original: %s', cothCharmSaved or coth_charm_recovery_read() or '(none)')
    -- Say what it FOUND, not just what is worn - the whole point is that nobody should have to know
    -- the charm's name, so the command has to prove it can work it out.
    local found, wornAlready = coth_find_charm()
    if found then
        log('[coth] %s holds the %s%s', found, COTH.ITEM, wornAlready and ' - already worn' or ' - in a bag')
    else
        log('\\ay[coth] no item in bags or the charm slot holds the %s\\ax', COTH.ITEM)
    end
    if arg:lower() == 'find' then return end
    -- Bare /atcothswap now DOES the swap when it found something, since there is nothing left to type.
    if found and not wornAlready then
        cothSwapWant = { name = found }
    else
        log('[coth] /atcothswap  |  /atcothswap <charm_name>  |  /atcothswap find  |  /atcothswap back')
    end
end) end)

-- WHAT DOES THE CLIENT THINK THIS CAST TAKES?
pcall(function() mq.bind('/atprofile', function(a)
    local want = tostring(a or ''):lower()
    if want == 'on' or want == 'off' then atProfile = (want == 'on'); AT_phaseAt = nil end
    -- ZERO THE COUNT WITH THE WINDOW.
    if AT_TICKS_AT == 0 then AT_TICKS, AT_TICKS_AT = 0, mq.gettime() end
    -- A SHORT WINDOW IS NOISE, NOT A MEASUREMENT.
    local held = mq.gettime() - AT_TICKS_AT
    if held < 20000 then
        log('[cpu] only %.0fs since the last check - let it run ~20s for a number worth reading', held / 1000)
        return
    end
    local mins = held / 60000
    local rate = AT_TICKS / mins
    log('[cpu] profiler %s - %.0f ticks/min over %.1f min (ideal 240; %.0f%% of ideal)',
        atProfile and 'ON' or 'off', rate, mins, (rate / 240) * 100)
    log('[cpu] %.0f ms per tick - %.0f ms of work on top of the 250ms wait',
        60000 / math.max(1, rate), math.max(0, (60000 / math.max(1, rate)) - 250))
    AT_TICKS, AT_TICKS_AT = 0, mq.gettime()
end) end)

pcall(function() mq.bind('/atcpu', function(a)
    if a and tostring(a):lower() == 'reset' then
        AT_CPU = { phase = {}, busy = 0, idle = 0, since = mq.gettime(), ticks = 0 }
        AT_TICKS, AT_TICKS_AT = 0, mq.gettime()
        UI_FRAMES, UI_SAMPLED, UI_TIME = 0, 0, 0
        log('[cpu] counters reset')
        return
    end
    local wall = math.max(1, mq.gettime() - (AT_CPU.since > 0 and AT_CPU.since or mq.gettime()))
    local mins = wall / 60000
    log('[cpu] %.1f min: busy %.1fs, idle %.1fs -> %.1f%% of the frame is us',
        mins, AT_CPU.busy / 1000, AT_CPU.idle / 1000, (AT_CPU.busy / wall) * 100)
    if AT_CPU.ticks > 0 then
        log('[cpu] %d tick(s), %.1f ms of work per tick', AT_CPU.ticks, AT_CPU.busy / AT_CPU.ticks)
        log('[cpu] MacroQuest Lua turbo %d instructions/frame; a pass of work spans ~%.1f frames',
            at_turbo(), AT_DISP_FR)
    -- THE WINDOW, WHICH IS NOT IN ANY OF THE ABOVE. Drawn by MacroQuest's frame loop, so it never
    -- appears as a phase and never counts as busy. Reported separately so it is not mistaken for either.
    if UI_SAMPLED > 0 then
        local per = UI_TIME / UI_SAMPLED
        local fps = UI_FRAMES / math.max(0.001, wall / 1000)
        log('[cpu] UI: %.2f ms per frame, ~%.0f frames/s -> ~%.0f ms/s drawing (%.0f%% of wall)',
            per, fps, per * fps, ((per * fps) / 1000) * 100)
    elseif SHOW_UI then
        log('[cpu] UI: no frames sampled yet (1 in 20 timed)')
    end
    end
    -- IS ANYTHING GROWING?
    do
        local function count(t)
            local n = 0
            if type(t) == 'table' then for _ in pairs(t) do n = n + 1 end end
            return n
        end
        local function deep(t)
            local n = 0
            if type(t) == 'table' then
                for _, v in pairs(t) do
                    n = n + 1
                    if type(v) == 'table' then for _ in pairs(v) do n = n + 1 end end
                end
            end
            return n
        end
        log('[cpu] tables: burn=%d pot=%d heal=%d cure=%d magic=%d di=%d rez=%d counts=%d',
            deep(burnState), deep(potState), deep(healState), deep(cureState),
            deep(magicState), count(DI.state), count(rezReady), deep(counts))
        log('[cpu]         coth=%d nv=%d trib=%d phases=%d',
            count(COTH.state), count(nvState),
            count(tributeState), count(AT_CPU.phase))
    end
    local rows, tot = {}, 0
    for n, ms in pairs(AT_CPU.phase) do
        if n ~= 'idle' then rows[#rows + 1] = { n = n, ms = ms }; tot = tot + ms end
    end
    if #rows == 0 then
        log('[cpu] no phase timings - /atprofile on to collect them')
        return
    end
    table.sort(rows, function(x, y) return x.ms > y.ms end)
    log('[cpu] phase shares (profiler ON - every tick timed, costs ~69ms/tick):')
    for i = 1, math.min(#rows, 14) do
        log('[cpu]   %-14s %5.1f%%', rows[i].n, (rows[i].ms / math.max(1, tot)) * 100)
    end
end) end)

-- A PEER REPORTING ITS OWN COUNTERS.
pcall(function() mq.bind('/at_net', function(who, sent, mins, top1, n1, top2, n2)
    if not who then return end
    netPeers = netPeers or {}
    netPeers[who] = { sent = tonumber(sent) or 0, mins = tonumber(mins) or 0.1,
                      top1 = top1 or '-', n1 = tonumber(n1) or 0,
                      top2 = top2 or '-', n2 = tonumber(n2) or 0, at = mq.gettime() }
end) end)

pcall(function() mq.bind('/at_netask', function(from, what)
    if what == 'reset' then
        NET.sent, NET.since, NET.byCmd = 0, mq.gettime(), {}
        return
    end
    if not from then return end
    local mins = math.max(0.1, (mq.gettime() - (NET.since > 0 and NET.since or mq.gettime())) / 60000)
    local rows = {}
    for c, n in pairs(NET.byCmd) do rows[#rows + 1] = { c = c, n = n } end
    table.sort(rows, function(x, y) return x.n > y.n end)
    local t1 = rows[1] and rows[1].c or '-'
    local c1 = rows[1] and rows[1].n or 0
    local t2 = rows[2] and rows[2].c or '-'
    local c2 = rows[2] and rows[2].n or 0
    pcall(function() peer_cmdf(from, '/at_net %s %d %.2f %s %d %s %d',
                               myName, NET.sent, mins, t1, c1, t2, c2) end)
end) end)

-- /atobsdrop - clear every observer now.
pcall(function() mq.bind('/atobsdrop', function()
    local n = dnet_drop_all('asked')
    if n == 0 then log('[obs] nothing subscribed from this client') end
    log('[obs] note: observers set by a PREVIOUS run are not in this registry - if the peers are still '
     .. 'slow, restart MQ2DanNet on them.')
end) end)

-- /atgrab [seconds] [command...] - write everything the MQ window prints into AT's log for a few
-- seconds.
pcall(function() mq.bind('/atpub', function(peer, key)
    if not peer or not key then
        log('[pub] usage: /atpub <peer> <key>   e.g. /atpub Antilerd RecourseUp')
        log('[pub] keys come from that character\'s [E3BotsPublishData (key/value)] ini section')
        return
    end
    local q = string.format('E3Bots(%s).Query(%s)', peer, key)
    for i = 1, 3 do
        local t0 = mq.gettime()
        local v
        pcall(function() v = mq.TLO.MQ2Mono.Query('e3', q)() end)
        local took = mq.gettime() - t0
        local sv = (v == nil) and '(nil)' or tostring(v)
        -- The resolver hands back unresolved text rather than erroring - the same trap documented on
        -- e3_is_paused, where a failed lookup read as a real answer.
        if sv:find('%$%{') or sv == q then sv = 'UNRESOLVED: ' .. sv end
        log('[pub] read %d: %s = %s   (%dms)', i, q, sv, took)
    end
    log('[pub] sub-millisecond and flat = local/cached, and worth using. Tens of ms or a first read '
     .. 'slower than the rest = a round trip, which is the model we already measured as worse.')
end) end)

-- /atheavy - which phase is the heaviest, over every tick since load. The answer to 'where does the
-- 78ms go', and unlike /atprofile it has been running the whole time.


pcall(function() mq.bind('/atheavy', function(a)
    if a and tostring(a):lower() == 'reset' then
        AT_HEAVY, AT_HEAVY_MS, AT_HEAVY_N = {}, {}, 0
        log('[heavy] counters reset')
        return
    end
    if AT_HEAVY_N == 0 then log('[heavy] nothing sampled yet'); return end
    local rows = {}
    for ph, n in pairs(AT_HEAVY) do
        rows[#rows + 1] = { ph = ph, n = n, ms = AT_HEAVY_MS[ph] or 0 }
    end
    -- Ordered by TOTAL time, not by how often it won: a phase that tops one tick in fifty at 200ms
    -- matters more than one that tops half of them at 3ms.
    table.sort(rows, function(x, y) return x.ms > y.ms end)
    local tot = 0
    for _, r in ipairs(rows) do tot = tot + r.ms end
    log('[heavy] heaviest phase per tick, %d tick(s) sampled, %.1fs of measured work:',
        AT_HEAVY_N, tot / 1000)
    for i = 1, math.min(#rows, 12) do
        local r = rows[i]
        log('[heavy]   %-14s topped %5d tick(s)  %7.2fs total  %6.2fms avg  %4.1f%%',
            r.ph, r.n, r.ms / 1000, r.ms / r.n, (tot > 0) and (r.ms * 100 / tot) or 0)
    end
    log('[heavy] this is the WINNER of each tick, not a full breakdown - a phase that is never the '
     .. 'heaviest will not appear, however steady its cost.')
end) end)

pcall(function() mq.bind('/ate3', function(...)
    local key = table.concat({...}, ' ')
    if key == '' then
        log('[e3] usage: /ate3 <key>   e.g. /ate3 State.Basics.RaidMembersLookup')
        log('[e3] /atgrab 15 /e3listexposeddata writes the full list of keys into this log')
        return
    end
    if not key:match('^E3N%.') then key = 'E3N.' .. key end
    local v
    local ok = pcall(function() v = mq.TLO.MQ2Mono.Query('e3', key)() end)
    local s2 = (v == nil) and '' or tostring(v)
    if not ok or s2 == '' then
        log('\\ay[e3] %s -> no answer (is MQ2Mono loaded and e3 running?)\\ax', key)
        return
    end
    -- A FAILED LOOKUP RETURNS THE KEY BACK.
    if s2:lower():find('%$%{') or s2:lower() == key:lower() then
        log('\\ay[e3] %s -> the bridge handed the key back unresolved: %s\\ax', key, s2)
        return
    end
    log('[e3] %s = %s', key, s2)
end) end)

pcall(function() mq.bind('/atgrab', function(a, ...)
    local secs = tonumber(a)
    local cmd
    if secs then cmd = table.concat({...}, ' ')
    else cmd = table.concat({a, ...}, ' '); secs = 10 end
    secs = math.max(1, math.min(60, secs))
    atGrabUntil, atGrabN = mq.gettime() + (secs * 1000), 0
    if not atGrabOn then
        atGrabOn = true
        pcall(function() mq.event('at_grab_all', '#1#', at_grab_line) end)
    end
    log('[grab] capturing window output for %ds (max %d lines) - it lands in the AT log as [grab] lines',
        secs, AT_GRAB_MAX)
    if cmd and cmd ~= '' then
        log('[grab] running: %s', cmd)
        pcall(function() mq.cmd(cmd) end)
    end
end) end)

pcall(function() mq.bind('/atnet', function(a)
    if a and tostring(a):lower() == 'reset' then
        NET.sent, NET.since, NET.byCmd = 0, mq.gettime(), {}
        NETIN.got, NETIN.since, NETIN.byCmd = 0, mq.gettime(), {}
        NETIN.tick, NETIN.worstTick, NETIN.worstAt = 0, 0, 0
        netPeers = {}
        -- Reset everyone, or the group total mixes a fresh local window with hours of peer history.
        for _, p in ipairs(group_members()) do
            if p:lower() ~= myName:lower() then
                pcall(function() peer_cmdf(p, '/at_netask %s reset', myName) end)
            end
        end
        log('[net] counters reset here and on every peer')
        return
    end
    -- Ask the peers, then print whatever has come back. Same two-call pattern as the other gathers:
    -- the replies land between invocations, so the first run shows only this client.
    netPeers = netPeers or {}
    for _, p in ipairs(group_members()) do
        if p:lower() ~= myName:lower() then
            pcall(function() peer_cmdf(p, '/at_netask %s', myName) end)
        end
    end
    local mins = math.max(0.1, (mq.gettime() - (NET.since > 0 and NET.since or mq.gettime())) / 60000)
    log('[net] SENT %d message(s) in %.1f min = %.1f/min', NET.sent, mins, NET.sent / mins)
    -- INBOUND, which on the driver is the number that matters. Every one of these fired a Lua bind
    -- inside a single doevents call.
    local imins = math.max(0.1, (mq.gettime() - (NETIN.since > 0 and NETIN.since or mq.gettime())) / 60000)
    log('[net] RECV %d message(s) in %.1f min = %.1f/min   worst single doevents: %d message(s)%s',
        NETIN.got, imins, NETIN.got / imins, NETIN.worstTick,
        (NETIN.worstAt > 0) and string.format(' (%ds ago)',
            math.floor((mq.gettime() - NETIN.worstAt) / 1000)) or '')
    local irows = {}
    for c, n in pairs(NETIN.byCmd) do irows[#irows + 1] = { c = c, n = n } end
    table.sort(irows, function(x, y) return x.n > y.n end)
    for i = 1, math.min(#irows, 6) do
        log('[net]   in  %-18s %5d  %.1f/min', irows[i].c, irows[i].n, irows[i].n / imins)
    end
    local rows = {}
    for c, n in pairs(NET.byCmd) do rows[#rows + 1] = { c = c, n = n } end
    table.sort(rows, function(x, y) return x.n > y.n end)
    for i = 1, math.min(#rows, 12) do
        log('[net]   %-18s %5d  %.1f/min', rows[i].c, rows[i].n, rows[i].n / mins)
    end
    -- THE GROUP TOTAL, which is the number that matters. What the driver RECEIVES is what every worker
    -- sends, so summing the peers is the honest figure for 'how much is this group talking'.
    local gs, any = NET.sent / mins, false
    for who, st in pairs(netPeers or {}) do
        any = true
        local r = st.sent / math.max(0.1, st.mins)
        gs = gs + r
        log('[net]   %-12s %5d in %.1f min = %5.1f/min   top: %s %d, %s %d',
            who, st.sent, st.mins, r, st.top1, st.n1, st.top2, st.n2)
    end
    if any then
        log('[net] GROUP TOTAL %.1f/min across %d character(s)', gs, 1 + (function()
            local n = 0; for _ in pairs(netPeers or {}) do n = n + 1 end; return n end)())
    else
        log('[net] no peer replies yet - run /atnet again in a second for the group total')
    end
end) end)

pcall(function() mq.bind('/at_want', function(b, n)
    FEED_WANT.burns = (tonumber(b) or 1) == 1
    FEED_WANT.nv    = (tonumber(n) or 1) == 1
end) end)

pcall(function() mq.bind('/at_raidact', function(kind, who)
    if not kind or not who then return end
    raidMoveWant = { name = tostring(who), action = tostring(kind) }
end) end)

pcall(function() mq.bind('/at_dzadd', function(who)
    if not who then return end
    pcall(function() mq.cmdf('/dzadd %s', tostring(who)) end)
    log('[dz] /dzadd %s (asked by the driver)', tostring(who))
end) end)

pcall(function() mq.bind('/at_taskadd', function(who)
    if not who then return end
    pcall(function() mq.cmdf('/taskadd %s', tostring(who)) end)
    log('[task] /taskadd %s (asked by the driver)', tostring(who))
end) end)

-- WHAT THIS CLIENT ACTUALLY ANSWERS.
pcall(function() mq.bind('/atdz', function()
    local function show(label, fn)
        local v, ok = tlo_str(fn)
        log('[dz] %-22s %s', label, (not ok) and '\\arno such member on this build\\ax'
                                     or ((v == '') and '(empty)' or v))
    end
    show('DynamicZone.Name',      function() return mq.TLO.DynamicZone.Name() end)
    show('DynamicZone.Leader',    function() return mq.TLO.DynamicZone.Leader() end)
    show('DynamicZone.Members',   function() return mq.TLO.DynamicZone.Members() end)
    show('DynamicZone.Timer',     function() return mq.TLO.DynamicZone.Timer() end)
    show('Task[1].Title',         function() return mq.TLO.Task(1).Title() end)
    show('Task[1].Leader',        function() return mq.TLO.Task(1).Leader() end)
    show('Task[1].Members',       function() return mq.TLO.Task(1).Members() end)
    show('Task[1].Member[1].Name',   function() return mq.TLO.Task(1).Member(1).Name() end)
    show('Task[1].Member[1].Leader', function() return mq.TLO.Task(1).Member(1).Leader() end)
    log('[dz] resolved: expedition -> %s | task -> %s',
        dz_my_leader() or ('none of ours (' .. dz_why_not() .. ')'),
        task_my_leader() or ('none of ours (' .. task_why_not() .. ')'))
end) end)

-- Third argument dropped with `displace` on 2026-08-21.
pcall(function() mq.bind('/at_raidplace', function(who, grp)
    if not who or not grp then return end
    raidMoveWant = { name = tostring(who), group = tonumber(grp) or 0, place = true }
end) end)

pcall(function() mq.bind('/atraidlist', function()
    if not win_exists_raw(RAID_WND) then
        log('\\ar[raid] open the raid window once first\\ax')
        return
    end
    log('[raid] %s', raid_lock_report())
    for _, lst in ipairs(RAID_LISTS) do
        local rows = 0
        pcall(function() rows = tonumber(mq.TLO.Window(RAID_WND).Child(lst).Items()) or 0 end)
        log('[raid] %s: %d row(s)', lst, rows)
        for r = 1, math.min(rows, 24) do
            local cells = {}
            for c = 1, 6 do
                local v = ''
                pcall(function()
                    v = tostring(mq.TLO.Window(RAID_WND).Child(lst).List(r .. ', ' .. c)() or '')
                end)
                if v ~= '' and v ~= 'NULL' then cells[#cells + 1] = c .. '="' .. v .. '"' end
            end
            log('[raid]   row %d: %s', r, (#cells > 0) and table.concat(cells, '  ') or '(no text)')
        end
    end
end) end)

pcall(function() mq.bind('/atraidmove', function(who, grp)
    if not who or not grp then
        log('[raid] /atraidmove <name> <group 0-12>')
        return
    end
    local g = tostring(grp):lower()
    g = (g == 'none' or g == 'no') and 0 or (tonumber(g) or -1)
    if g < 0 or g > RAID_MAX_GROUPS then
        log('\\ar[raid] group must be 0 (no group) through %d\\ax', RAID_MAX_GROUPS)
        return
    end
    raidMoveWant = { name = tostring(who), group = g }
end) end)

pcall(function() mq.bind('/atraidlock', function()
    pcall(function() mq.cmdf('/nomodkey /notify %s RAID_LockButton leftmouseup', RAID_WND) end)
    mq.delay(600)
    log('[raid] %s', raid_lock_report())
end) end)

pcall(function() mq.bind('/atraidunlock', function()
    -- Drop our claim too. Unlocking by hand while the tick still believes it holds the lock would leave
    -- it putting back a lock nobody asked for, six seconds later.
    raidWeLocked, raidLockLinger, raidLockAt = false, 0, 0
    pcall(function() mq.cmdf('/nomodkey /notify %s RAID_UnlockButton leftmouseup', RAID_WND) end)
    mq.delay(600)
    log('[raid] %s', raid_lock_report())
end) end)

pcall(function() mq.bind('/atwin', function(w)
    local root = (w and tostring(w) ~= '') and tostring(w) or 'RaidWindow'
    win_probe(root)
end) end)

pcall(function() mq.bind('/atcothcast', function()
    local it = '=' .. COTH.ITEM
    local f = {}
    local function get(label, fn)
        local v = 'n/a'
        pcall(function() v = tostring(fn() or 'NULL') end)
        f[#f + 1] = label .. '=' .. v
    end
    get('Clicky.CastTime',      function() return mq.TLO.FindItem(it).Clicky.CastTime.TotalSeconds() end)
    get('Spell.CastTime',       function() return mq.TLO.FindItem(it).Spell.CastTime.TotalSeconds() end)
    get('Spell.MyCastTime',     function() return mq.TLO.FindItem(it).Spell.MyCastTime.TotalSeconds() end)
    get('CastTime',             function() return mq.TLO.FindItem(it).CastTime.TotalSeconds() end)
    get('Spell.RecastTime',     function() return mq.TLO.FindItem(it).Spell.RecastTime.TotalSeconds() end)
    get('Me.CastTimeLeft',      function() return mq.TLO.Me.CastTimeLeft.TotalSeconds() end)
    get('Me.SpellHasteFocus',   function() return mq.TLO.Me.SpellHasteFocus() end)
    get('charm',                function() return mq.TLO.Me.Inventory('charm').Name() end)
    log('[coth] %s', table.concat(f, '  '))
    log('[coth] last measured cast: %s', COTH.castSecs and string.format('%.1fs', COTH.castSecs) or '(none yet)')
end) end)

pcall(function() mq.bind('/atcothslot', function()
    local f = {}
    local function get(label, fn)
        local v = 'n/a'
        pcall(function() v = tostring(fn() or 'NULL') end)
        f[#f + 1] = label .. '=' .. v
    end
    local it = '=' .. COTH.ITEM
    get('Name',       function() return mq.TLO.FindItem(it).Name() end)
    get('ID',         function() return mq.TLO.FindItem(it).ID() end)
    -- ItemSlot/ItemSlot2 say where it IS. Non-nil ItemSlot2 means it is inside a bag.
    get('ItemSlot',   function() return mq.TLO.FindItem(it).ItemSlot() end)
    get('ItemSlot2',  function() return mq.TLO.FindItem(it).ItemSlot2() end)
    -- WornSlot says where it MAY go. If this is NULL the emblem is not a worn item at all, which would
    -- mean the thing to equip is whatever it is socketed into and we are looking for the wrong name.
    get('WornSlot1',  function() return mq.TLO.FindItem(it).WornSlot(1)() end)
    get('WornSlots',  function() return mq.TLO.FindItem(it).WornSlots() end)
    get('Type',       function() return mq.TLO.FindItem(it).Type() end)
    get('AugType',    function() return mq.TLO.FindItem(it).AugType() end)
    get('Clicky',     function() return mq.TLO.FindItem(it).Clicky() end)
    get('CastTime',   function() return mq.TLO.FindItem(it).Clicky.CastTime.TotalSeconds() end)
    get('TimerReady', function() return mq.TLO.FindItem(it).TimerReady() end)
    -- The charm we would equip, and whether a dialog is in the way right now.
    do
        local c = coth_find_charm()
        if c then f[#f + 1] = 'charmItem=' .. c end
        f[#f + 1] = 'confirmBoxOpen=' .. tostring(win_open_raw(COTH_BOX))
    end
    log('[coth] %s', table.concat(f, '  '))
    -- And what is worn in the likely destination right now, so the save-and-restore has something real
    -- to record rather than a slot name someone typed from memory.
    for _, sl in ipairs({ 'charm', 'ranged', 'earring1', 'neck' }) do
        local w = ''
        pcall(function() w = tostring(mq.TLO.Me.Inventory(sl).Name() or '') end)
        log('[coth]   worn %-9s = %s', sl, (w ~= '') and w or '(empty)')
    end
end) end)

pcall(function() mq.bind('/atui', function(what)
    local arg = what and tostring(what):lower() or ''
    -- PUT IT ALL BACK.
    if arg == 'reset' then
        local n = 0
        for _ in pairs(popOut) do n = n + 1 end
        popOut = {}
        windowOpen = true
        -- ImGui remembers window positions, not us - so a panel dragged off-screen simply stops being
        -- drawn once it is empty, which is what fixes the worst case.
        save_settings()
        printf('\ag[AdventureTime]\ax %d section(s) put back in the mini window', n)
        return
    end
    -- WHERE IS EVERYTHING. A section that is not on screen is otherwise indistinguishable from one that
    -- has broken, and that is exactly when somebody needs to know which.
    if arg == 'where' then
        local home, panels = {}, {}
        for _, k in ipairs(miniOrder) do
            local sec = mini_section(k)
            if sec then
                local p = popOut[k]
                if p then
                    panels[p] = panels[p] or {}
                    panels[p][#panels[p] + 1] = sec.label
                else
                    home[#home + 1] = sec.label
                end
            end
        end
        printf('\ag[AdventureTime]\ax mini: %s', (#home > 0) and table.concat(home, ', ') or '(empty)')
        for p = 1, POP_PANELS do
            if panels[p] then printf('   panel %d: %s', p, table.concat(panels[p], ' + ')) end
        end
        printf('   \ay/atui reset\ax puts everything back')
        return
    end
    windowOpen = true
    miniMode = true
    save_settings()
    printf('\ag[AdventureTime]\ax mini window open (\ay/atuie\ax full, ' ..
           '\ay/atui where\ax layout, \ay/atui reset\ax undo it)')
end) end)
pcall(function() mq.bind('/atuie', function()
    windowOpen = true
    miniMode = false
    save_settings()
    printf('\ag[AdventureTime]\ax expanded window open (\ay/atui\ax for the mini one)')
end) end)
-- TOP LEVEL, NOT INSIDE `if SHOW_UI`.
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
    AT_TURBO = at_turbo()
    if AT_TURBO > 0 and AT_TURBO < 1000 then
        log('\\ay[perf] MacroQuest turbo is %d - Fast mode (Settings > Performance) makes AT react faster\\ax', AT_TURBO)
    end
    log('AdventureTime %s ready [%s] - \\ay/lua run %s\\ax on each toon; open \\ay/at\\ax here and Give out.',
        VERSION, BUILD_TAG, AT_ENTRY)
    if AT_FORCE_BOT then
        log('   RGMercs build: bot control pinned to \\ay%s\\ax, casts go out natively (/useitem, /alt activate, /cast).',
            bot_control_label(AT_FORCE_BOT))
    end
    log('   \\ay/atcoth\\ax starts the CoTH gather from any toon (\\ay/atcoth off\\ax to stop).')
    -- Said at startup because the moment you need it is the moment the window is gone, and a command
    -- you have never seen is no help then.
    log('   \\ay/atui\\ax reopens the mini window, \\ay/atuie\\ax the expanded one.')
    log('   \\ay/atpac\\ax re-announces my pacify ceiling (run it after memming a new rank).')
    log('   \\ay/atwipe\\ax holds all rezzes until the group zones (\\ay/atwipe off\\ax to release).')
    log('   \\ay/atburnaudit\\ax writes a file listing every burn, its real reuse, and whether its tier fits.')
    log('   \\ay/atburncheck <burn>\\ax after /e3burns on your burn hotkey: what has not fired yet shows under Running now.')

-- RECOVER STRIPPED GEAR AT STARTUP.
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
    -- FIND THE CURRENCY TAB ONCE, NOW, while nothing is waiting on an answer.
    pcall(function() altcur_show_tab(); altcur_done() end)
end
-- DRIVER ONLY.
if SHOW_UI then refreshRequested = true end
-- THE FIRST COUNT WAITS FOR THE PUSHES. Workers launched by this start need a few seconds to load and
-- report; counting straight away fell back to 36 DanNet queries and froze the loop ~4s. Hold until
-- every groupmate has pushed or REFRESH_HOLD_MS passes, whichever comes first.
REFRESH_HOLD_MS = 12000
refreshHoldUntil = SHOW_UI and (mq.gettime() + REFRESH_HOLD_MS) or 0
function counts_all_pushed()
    for _, m in ipairs(group_members()) do
        if m:lower() ~= myName:lower() then
            local pu = countsPush[m:lower()]
            if not (pu and (mq.gettime() - (pu.at or 0)) < COUNTS_FRESH) then return false end
        end
    end
    return true
end
DI.startedAt = mq.gettime()   -- clock the settling window from load, not from the first tick

-- Timed, because this was the multi-second startup gap and it took three attempts to find.
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
    if not peerChan then peer_detect() end
    if peerChan == 'e3' then
        -- No roster to read here: E3 reachability is proven by the /at_ping handshake in bring_up_group,
        -- which logs who did and did not answer.
        return
    end
    if peerChan == 'eqbc' and not eqbc_connected() then
        log('\\ar*** PEER NETWORK PROBLEM ***\\ax')
        log('\\arMQ2EQBC is loaded but NOT connected to an EQBC server - nothing can reach the group.\\ax')
        log('\\ayCheck /bccmd status here, then /bccmd connect (server and port in MQ2EQBC.ini). Every box')
        log('\\aymust connect to the SAME EQBCS server; /bccmd names shows who the server can see.\\ax')
        return
    end
    -- The transport's roster, as one lowercase set.
    local set = net_peer_set()
    if not set and peerChan == 'eqbc' then
        -- EQBC.Names is only filled in by a names reply from the server.
        pcall(function() mq.cmd('/squelch /bccmd names') end)
        log('[net] EQBC has not returned its names list yet - requested it; /at_ping decides who is reachable')
        return
    end
    set = set or {}
    -- A DEAD toon is off the network while it zones to bind, which looks exactly like a broken network -
    -- so this fired mid-wipe and told the user to go rewrite their MQ2DanNet.ini when nothing was wrong.
    -- A corpse in the zone is proof they are simply dead, not misconfigured.
    local missing, dead = {}, {}
    for _, m in ipairs(mine) do
        if not set[m:lower()] then
            if rez_corpse(m) > 0 then dead[#dead + 1] = m else missing[#missing + 1] = m end
        end
    end
    if #dead > 0 then
        log('[net] %s off the network, but dead - that is expected while they zone', table.concat(dead, ', '))
    end
    if #missing == 0 then return end
    -- SOME SEEN, SOME NOT (1.21.2): the network works, so the ones it does not see are somebody else's
    -- characters, not a broken setup - said plainly, without the fix-your-ini advice.
    if #missing + #dead < #mine then
        log('[net] not on %s - somebody else\'s character(s), left alone: %s',
            (peerChan == 'eqbc') and 'EQBC' or 'DanNet', table.concat(missing, ', '))
        return
    end
    log('\\ar*** PEER NETWORK PROBLEM ***\\ax')
    log('\\arCannot see %d of %d group member(s) on %s: %s\\ax', #missing, #mine,
        (peerChan == 'eqbc') and 'EQBC' or 'DanNet', table.concat(missing, ', '))
    log('\\ayNothing from those characters will arrive - no burns, no rez help, no potion counts.\\ax')
    if peerChan == 'eqbc' then
        log('\\ayCheck: /bccmd names here and /bccmd status on each missing toon. Every box must be')
        log('\\ayconnected to the SAME EQBCS server (same host and port in MQ2EQBC.ini), and a toon that')
        log('\\ayconnected under a different name (/bccmd connect <name>) will not match its character.\\ax')
    else
        log('\\ayCheck: /dnet info on each toon. If they only list themselves, they are on separate')
        log('\\ayDanNet islands - fix the Interface setting in MQ2DanNet.ini (config folder) so every')
        log('\\ayclient matches, then FULLY restart them. See the AdventureTime readme.\\ax')
    end
end

-- ===== WHERE STARTUP TIME GOES =====
boot_step('load settings', load_settings)
-- PRIME THE RAID WINDOW HERE, not inside the first move.
if SHOW_UI then boot_step('prime raid window', function() pcall(raid_prime_window) end) end
-- THE PERFORMANCE SETTINGS, IN THE LOG, ON EVERY START.
log('[perf] perfScale %d (tick %dms) | rez fast lane %s | log clock %s',
    perfScale or 1, pace(250),
    ((perfScale or 1) > 1) and 'ARMED' or 'idle (no effect at perfScale 1)',
    LOG_T0_SPUN and 'anchored to a second boundary' or 'NOT anchored - cross-character gaps under 1s are unreliable')
-- Say where they came from. On an upgrade this reads the old flat file once and then never again, and
-- "which file am I actually using" is the first question when something does not persist.
if SHOW_UI then
    log('[settings] %s', SETTINGS_LOADED_FROM and ('loaded from ' .. path_show(SETTINGS_LOADED_FROM))
        or 'no settings file found - starting from defaults')
    log('[settings] saving to %s', path_show(at_write(SETTINGS_NAME)))
end   -- restore persisted toggles before we talk to anyone
-- Announce what this character can pacify, once.
pacAnnounceAt = mq.gettime() + 8000
load_combos()
mini_order_normalise()   -- fills in defaults / drops unknown keys from a stale settings file
-- The peer check was written and then never wired in, so the one diagnostic aimed at split/broken
-- networks has never run.
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

-- Say what this character has and where it stands.
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

-- SKIP EVERYTHING WHILE THE CLIENT IS NOT IN A FIT STATE TO BE ASKED.
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
    -- TWO TIMESTAMPS A TICK, ALWAYS ON.
    AT_TICK_T0 = mq.gettime()
    AT_TICK_F0 = UI_FRAMES
    -- DECIDE AT THE TOP OF THE TICK, so a whole tick is either sampled or not.
    atphase('tick_start')
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
    if updateLaunchRequested then
        updateLaunchRequested = false
        if at_find_patcher() then
            atExitWhy = 'AdventureTime update launched'
            log('[update] closing AdventureTime on the group before launching patcher.')
            for _, m in ipairs(group_members()) do
                if m:lower() ~= myName:lower() then peer_cmdf(m, '/at_close') end
            end
            mq.delay(300)
            if at_launch_patcher() then
                running = false
                break
            end
        else
            at_launch_patcher()
        end
    end
    if peerCheckAt > 0 and mq.gettime() >= peerCheckAt then
        peerCheckAt = 0
        pcall(check_peer_network)
    end
    if peerTransportProbeAt > 0 and mq.gettime() >= peerTransportProbeAt then
        peerTransportProbeAt = 0
        pcall(peer_detect)
    end
    if peerTransportTestAt > 0 and mq.gettime() >= peerTransportTestAt then
        peerTransportTestAt = 0
        pcall(function()
            if not peerChan then peer_detect() end
            if peerChan then
                peer_bcast('/echo [AdventureTime] peer transport test from %s via %s',
                    myName, peer_transport_label(peerChan))
            else
                log('\\ar[sync] peer transport test failed - no active peer transport\\ax')
            end
        end)
    end
    -- Group changed since the last look? Re-test. A peer on ANOTHER machine can drop off DanNet without
    -- leaving the in-game group, and nothing else in here would ever notice - the reports just stop.
    do
        local now = group_members()
        local gk = table.concat(now, ',')
        if gk ~= lastGroupKey then
            local firstLook = (lastGroupKey == nil)
            -- Shut down the worker on anyone who LEFT.
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
                -- Read once for the sweep below rather than per character.
                local pset = net_peer_set()
                for _, m in ipairs(lastGroupList) do
                    -- A player leaving the group has no worker to close and no rows to clear.
                    if not stillHere[m:lower()] and m:lower() ~= myName:lower()
                       and net_is_peer(m, pset) then
                        -- NOT CLOSED ON THE SPOT.
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
            -- EVERY TOON, not just the driver: each one builds its own rez picture and pacify table from
            -- the roster, and a member who joined after startup was invisible to both until a restart.
            if not firstLook then
                pcall(rez_roster_sync)
                -- Say what I can pacify again, so a newcomer hears it and I hear theirs. Debounced by the
                -- one-shot timer: a churning roster pushes it out rather than sending one per change.
                pacAnnounceAt = mq.gettime() + 4000
            end
            if peerCheckAt == 0 then peerCheckAt = mq.gettime() + 8000 end
            -- Not on the first look: startup already brings the group up, and doing it twice would fire
            -- a second round of pings and launches for no reason.
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
            -- A FLOOR ON HOW OFTEN THIS CAN COST ANYTHING.
            if (mq.gettime() - lastResyncAt) >= RESYNC_MIN_GAP then
                lastResyncAt = mq.gettime()
                pcall(resync_group)
            else
                pcall(resync_prune_only)
                log('[sync] roster changed again within %ds - pruned locally, skipped the re-report',
                    math.floor(RESYNC_MIN_GAP / 1000))
            end
        end
        -- Crash watch every 5s.
        atphase('pots'); pcall(pot_retry_tick)
        atphase('phantom'); pcall(pw_tick)
        -- UNCONDITIONAL BOUNDARY.
        atphase('requests')
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
                    pcall(function() cid = corpse_id_exact(myName) end)
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
            -- EVERY character that has a balance, not just the richest.
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
        -- RE-READ BOTH SIDES.
        if altCurRefresh and mq.gettime() > altCurRefresh then
            altCurRefresh = nil
            local roster = group_members()
            local peers = {}
            for _, m in ipairs(roster) do if m:lower() ~= myName:lower() then peers[#peers + 1] = m end end
            -- ALL ITEMS, not just the alt one.
            pcall(function() query_all_counts(peers, all_items()) end)
            for _, it in ipairs(ALT_ITEMS) do pcall(function() query_alt_currency_async(roster, it) end) end
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
            atphase('port_probe')
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
        if portCastWanted then
            local sp = portCastWanted
            portCastWanted = nil
            atphase('port_cast')
            pcall(function() port_cast(sp) end)
        end
        if portScanWanted then
            portScanWanted = false
            atphase('port_scan')
            pcall(function()
                portBook[myName] = port_scan() or {}
                peer_bcast('/at_ports? %s', myName)
            end)
        end
        if portAskedBy then
            local who = portAskedBy
            portAskedBy = nil
            atphase('port_reply')
            pcall(function()
                local list = port_scan()
                if not list or #list == 0 then return end
                -- SMALL MESSAGES.
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
        -- EVERYTHING BELOW USED TO REPORT AS 'placate'.
        atphase('announce')
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
        atphase('di_landed')
        do
            local ok, err = pcall(di_check_landed)
            if not ok and (mq.gettime() - (DI.lastCheckErr or 0)) > 60000 then
                DI.lastCheckErr = mq.gettime()
                rezlog('\\ar[di] di_check_landed errored: %s\\ax', tostring(err))
            end
        end
        -- Corpse-keyed tables grow for the life of the session: every body ever targeted leaves an
        -- entry in rezSkip (up to one per slot), rezFirstSeen and rezPending, and nothing ever removed
        -- them.
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
            dropped = dropped + rez_retire_sweep()
            if dropped > 0 then rezdbg(string.format('swept %d retired corpse entr(ies)', dropped)) end
        end
        if SHOW_UI and (mq.gettime() - lastRevive) > 5000 then
            atphase('revive')
            lastRevive = mq.gettime()
            pcall(revive_check)
        end
    end
    atphase('giveout')
    if giveRequested and not distributing then
        giveRequested = false
        give_out()   -- runs HERE, not in the ImGui render, so its nav/trade/buy delays can yield
    end
    if collectRequested and not distributing then
        collectRequested = false
        collect_all()
    end
    -- Everything from here to counts_query was reporting as 'giveout' - the tribute refresh, the xtank
    -- maintenance and the roster bookkeeping, none of which is giving anything out.
    atphase('upkeep')
    if SHOW_UI and next(ICON.want) ~= nil then pcall(icon_resolve_tick) end
    if not SHOW_UI and driverName and (mq.gettime() - turboCheckAt) > 30000 then
        turboCheckAt = mq.gettime()
        local v = at_turbo()
        if v > 0 and v ~= turboLast then
            turboLast = v
            pcall(function() peer_cmdf(driverName, '/at_turbo %s %d', myName, v) end)
        end
    end
    if atGrabOn then at_grab_tick() end
    if next(altAsync) ~= nil then pcall(alt_async_tick) end
    if refreshRequested and not distributing and SHOW_UI
       and (mq.gettime() >= refreshHoldUntil or counts_all_pushed()) then   -- belt and braces: workers never refresh
        refreshRequested = false
        distributing = true
        uiStatus = 'Reading group counts...'
        local full = group_members()
        local peers = {}
        for _, m in ipairs(full) do if m:lower() ~= myName:lower() then peers[#peers + 1] = m end end
        -- ONE CALL WITH EVERYTHING.
        atphase('counts_query')
        query_all_counts(peers, all_items())
        for _, it in ipairs(ALT_ITEMS) do pcall(function() query_alt_currency_async(peers, it) end) end
        local roster = { myName }
        for _, p in ipairs(peers) do roster[#roster + 1] = p end
        statusCounts = {}
        for _, nm in ipairs(roster) do statusCounts[nm:lower()] = counts[nm:lower()] or {} end
        statusNames = roster
        uiStatus = 'Counts updated.'
        distributing = false
    end
    -- THE ZONE READ IS OUT OF THE PACED GATE, WHICH IS WHAT THE NOTE ALWAYS CLAIMED.
    do
        local z = mq.TLO.Zone.ID() or 0
        if z ~= lastZoneID then
            lastZoneID = z; zoneSettleAt = mq.gettime() + 3000
            -- Zoned: the wipe is over by definition. Cleared per character rather than broadcast, so a
            -- toon still standing in the zone stays held until it comes back too.
            if rezWipe then
                rezWipe = false
                rezlog('\\ag[rez] zoned - wipe mode cleared, rezzing again\\ax')
            end
            -- ZONING REBUILDS THE UI, so the roster this character primed at startup may be gone.
            raidPrimed = false
        end
    end
    if (mq.gettime() - (lastUpkeep or 0)) >= pace(UPKEEP_MS) then
    lastUpkeep = mq.gettime()
    do   -- timed background jobs: tribute refresh, and (if the toggle's on) auto tank-XTargets.
        local settled = false
        if zoneSettleAt and mq.gettime() >= zoneSettleAt then zoneSettleAt = nil; settled = true end
        if settled then tributeRequested = true end
        -- TRIBUTE IS EVENT DRIVEN.
        if windowOpen and (mq.gettime() - (tribDrawnAt or 0)) < 3000
           and (mq.gettime() - lastTributePoll) > TRIB_POLL_MS then
            tributeRequested = true
        end
        -- Local rebuild only while the panel is up; it is cheap but it is also pointless otherwise.
        -- Panel-driven rebuild kept for the driver's OWN row, which no /at_trib ever arrives for.
        if windowOpen and (mq.gettime() - (tribDrawnAt or 0)) < 3000 then rebuild_tribute_rows() end
        if autoXTank and iAmHealer then   -- each priest self-maintains; silent, no broadcast
            if settled then xtankAutoRequested = true end
            if xtankRecheckAt and mq.gettime() >= xtankRecheckAt then xtankRecheckAt = nil; xtankAutoRequested = true end   -- event debounce
            if (mq.gettime() - lastXTankPoll) > 60000 then xtankAutoRequested = true end   -- 60s failsafe
        end
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
    if SHOW_UI and BURNCHK then pcall(burncheck_tick) end
    if burnRefreshRequested then
        burnRefreshRequested = false
        burnState = {}; burnClass = {}          -- drop the whole table so stale toons/items clear out
        peer_bcast('/at_burnrefresh')
        mq.cmd('/at_burnrefresh')               -- and re-read my own
    end
    -- Burn reports are the ONLY bulk traffic here - everything else is a handful of small, latency-
    -- sensitive messages.
    if next(burnPending) ~= nil and not peer_quiet()
       and (mq.gettime() - lastBurnSend) >= (burnQueueLen() > 8 and 600 or 300) then
        lastBurnSend = mq.gettime()
        local sent = 0
        for nm, d in pairs(burnPending) do
            burnPending[nm] = nil
            if driverName then peer_cmdf(driverName, '/at_burn %s %s %d %d %d %d %s %d %s %s', myName, myClass, d.tier, d.secs, d.av, d.dsecs, d.kind or 'i', d.ord or 0, d.tkey or '?', nm)
            else peer_bcast('/at_burn %s %s %d %d %d %d %s %d %s %s', myName, myClass, d.tier, d.secs, d.av, d.dsecs, d.kind or 'i', d.ord or 0, d.tkey or '?', nm) end
            if d.expect then
                if driverName then peer_cmdf(driverName, '/at_burnexp %s %s', myName, nm)
                else peer_bcast('/at_burnexp %s %s', myName, nm) end
            end
            if d.warn then
                local w = (d.warn:gsub(' ', '~'))
                if driverName then peer_cmdf(driverName, '/at_burnwarn %s %s %s', myName, w, nm)
                else peer_bcast('/at_burnwarn %s %s %s', myName, w, nm) end
            end
            sent = sent + 1
            if sent >= 1 then break end
        end
    end
    if not SHOW_UI and driverName and burnPollOn and feed_wanted('burns') and next(burnPending) == nil
       and (mq.gettime() - lastBurnSend) > 3000 and (mq.gettime() - lastBurnSum) > BURN_SUM_MS
       and mq.gettime() > burnStartAt then
        lastBurnSum = mq.gettime()
        local n, h = burn_digest(burnLast)
        pcall(function() peer_cmdf(driverName, '/at_burnsum %s %d %s', myName, n, h) end)
    end
    -- TRIBUTE: READ OFTEN, SEND RARELY.
    if tribRowsDirty then
        tribRowsDirty = false
        rebuild_tribute_rows()
    end
    -- DIAMOND COINS.
    atphase('dc')
    -- THE BUTTON ONLY SETS A FLAG. Broadcasting from inside a draw callback would send once per frame,
    -- and the trade itself must never run on the ImGui thread - same separation the ports rescan uses.
    if dcGiveNowWant then
        dcGiveNowWant = false
        if (dcGiveTo or '') ~= '' then
            log('[dc] starting a claim-and-hand-over run for %s -> %s', DC_ITEM, dcGiveTo)
            pcall(function() peer_bcast('/at_dcnow') end)
            -- Locally too: a broadcast does not come back to the sender.
            if dc_active() then dcRunning, dcRunSaid = true, true end
        end
    end
    pcall(dc_receiver_tick)
    pcall(dc_giver_tick)
    atphase('trib_watch')
    if driverName and (mq.gettime() - (lastTribPoll or 0)) > TRIB_WATCH_MS then
        lastTribPoll = mq.gettime()
        local a = false; pcall(function() local v = mq.TLO.Me.TributeActive(); a = (v == true) or (tostring(v):upper() == 'TRUE') end)
        local f = 0; pcall(function() f = tonumber(mq.TLO.Me.CurrentFavor()) or 0 end)
        -- KEY ON THE STATE, NOT THE FAVOR. Favor DRAINS while tribute is running, so putting it in the
        -- key meant the key moved on every read. The only thing anyone acts on is on or off.
        local k = tostring(a and 1 or 0)
        local due = (mq.gettime() - (tribKeepAt or 0)) > TRIB_KEEP_MS
        if tribLast ~= k or due then
            tribLast = k
            if due then tribKeepAt = mq.gettime() end
            peer_cmdf(driverName, '/at_trib %s %d %d', myName, a and 1 or 0, f)
        end
    end
    -- OUTSIDE THE `if`. Conditional labels are why upkeep reads as 5% - it kept accruing across every
    -- tick where neither this nor counts_query ran. Fifth instance of the same fault tonight.
    atphase('disc_watch')   -- disc watcher: start/fade log, and catch discs cut short
    if (mq.gettime() - lastDiscPoll) > 1000 then
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
    -- The BUTTON reporters get their own, much shorter settle.
    if not SHOW_UI and (mq.gettime() - lastClickResync) > 90000 then
        lastClickResync = mq.gettime()
        potLast, healLast, cureLast, magicLast = {}, {}, {}, {}
    end
    -- OWN LABEL.
    atphase('click_poll')
    -- 5s, NOT 2s.
    if mq.gettime() > clickStartAt and (mq.gettime() - lastClickPoll) > pace(CLICK_POLL_MS) then
        lastClickPoll = mq.gettime()
        atphase('click_mgb')
        do   -- MGB clicks: one report per ability this class can use (a beastlord has two)
            local hcls = (mq.TLO.Me.Class.ShortName() or ''):upper()
            for _, he in ipairs(mgb_entries_for(hcls)) do
                if #he.abils > 0 then
                    local raiding = (tonumber(mq.TLO.Raid.Members()) or 0) > 0
                    local mgbSec = click_secs(MGB_AA)
                    local parts = { tostring(mgbSec) }
                    -- TWO LISTS ON PURPOSE.
                    local kparts = { tostring(push_bucket(mgbSec)) }
                    for _, ab in ipairs(he.abils) do
                        local sc = click_secs(ab)
                        parts[#parts + 1]  = tostring(sc)
                        kparts[#kparts + 1] = tostring(push_bucket(sc))
                    end
                    local k = he.key .. '/' .. (raiding and 1 or 0) .. '/' .. table.concat(kparts, '/')
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
        atphase('click_magic')
        for _, me2 in ipairs(MAGIC_CLICKS) do   -- magic protection: only owners report
          if click_should_read('m:' .. me2.key) then
            local have, secs, up, dsecs = magic_state(me2)
            click_saw('m:' .. me2.key, have == 1)
            local k = have .. '/' .. push_bucket(secs) .. '/' .. up .. '/' .. push_bucket(dsecs)
            -- Never announce that I do NOT have something.
            if have == 0 and magicLast[me2.key] == nil then magicLast[me2.key] = k end
            -- Only mark it sent if it ACTUALLY went.
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
        end
        atphase('click_cure')
        for _, ce in ipairs(CURE_CLICKS) do   -- cures: only owners ever report, so silence means "not mine"
          if click_should_read('c:' .. ce.key) then
            local have, secs = cure_state(ce.name)
            click_saw('c:' .. ce.key, have == 1)
            local k = have .. '/' .. push_bucket(secs)
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
        end
        -- ONCE EVERY POT_POLL_MS, not on every click poll. Buffs tick on the server's own schedule and
        -- reading them faster only produces the same answer more often.
        atphase('click_pot')
        if (mq.gettime() - lastPotPoll) > pace(POT_POLL_MS) then
          lastPotPoll = mq.gettime()
          for _, gp in ipairs(GROUP_POTS) do
           if click_should_read('p:' .. gp.key) then
            local carries, up, secs, dsecs = pot_state(gp.base)
            click_saw('p:' .. gp.key, (carries or 0) > 0)
            -- THE SAME KEY SHAPE AS BURNS: the flags, plus the LATCHED duration.
            local k = string.format('%d/%d/%s/%d', carries, up, (secs or -1) <= 0 and 'R' or 'd', dsecs)
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
        end
    end
    -- NO BLIND RE-SEND. Every 2 minutes this forgot what it had sent and pushed every burn again -
    -- 20-30 messages per toon carrying nothing new. A 60s digest (burn_sum_tick) catches a dropped
    -- report instead, and only a toon whose digest disagrees re-sends.
    -- OUTSIDE THE `if`, DELIBERATELY.
    atphase('burn_poll')
    if burnPollOn and mq.gettime() > burnStartAt and (mq.gettime() - lastBurnPoll) > 2000 then
        -- read MY watched item timers locally (cheap), push changes
        lastBurnPoll = mq.gettime()
        -- Group draughts ride the same local poll.
        if not feed_wanted('burns') then
            if next(burnLast) ~= nil then burnLast = {} end
        else
        for _ord, entry in ipairs(BURN_WATCH) do
            local name, tier = entry.name, entry.tier
            local have, ready, secs, active, dsecs, kind = ability_state(name)
            local ord = _ord
            if have then
                -- dsecs IS A LIVE COUNTDOWN AND MUST NOT BE IN THE KEY.
                local key = (ready and 'R' or 'd') .. (active and 'A' or '-')
                         .. ((math.floor(dsecs or 0) > 0) and 'e' or '-')   -- floored: what is SENT
                local prev = burnLast[name]
                if prev == nil or prev ~= key then   -- report on ready<->down OR active<->inactive flip
                    burnLast[name] = key
                    -- every burn it is listed under, lowest first, '+' between (1.21.3): the driver keeps the
                    -- first as the tier it shows and all of them for /atburncheck
                    local keyList = table.concat(entry.keys or { entry.tkey or '?' }, '+')
                    local warn = burn_target_warn(name, kind)
                    entry.expect = burn_expects_buff(name, kind)   -- a field, not a local: the main chunk is at Lua's 200-local ceiling
                    if SHOW_UI then   -- I'm the driver: update my own table directly, no network
                        burnClass[myName] = myClass
                        burnState[myName] = burnState[myName] or {}
                        burnState[myName][name] = { tier = tier, secs = secs, active = active, dsecs = dsecs or 0, kind = kind, ord = ord, tkey = (entry.tkey or '?'), keys = burn_key_set(keyList), updated = mq.gettime() }
                        burnWarn[myName] = burnWarn[myName] or {}
                        burnWarn[myName][name] = warn
                        burnExpect[myName] = burnExpect[myName] or {}
                        burnExpect[myName][name] = entry.expect or nil
                    else              -- queue it; the drain below spreads the burst over a second or so
                        burnPending[name] = { tier = tier, secs = secs, av = (active and 1 or 0), dsecs = math.floor(dsecs or 0), kind = kind, ord = ord, tkey = (keyList:gsub(' ', '~')),   -- '~' so 'Quick Burn' survives arg splitting
                                              warn = (prev == nil) and warn or nil,
                                              expect = (prev == nil) and entry.expect or nil }
                    end
                end
            end
        end
        end
    end
    -- CLOSE THE BURN LABEL.
    atphase('coth_push')
    -- The state push lives in coth_tick now.
        -- ARM BEFORE PREPPING.
        do
            local S = AT_SLOW_SUM
            if S.at == 0 then S.at = mq.gettime() end
            if (mq.gettime() - S.at) >= 60000 then
                if S.n > 0 then
                    local parts = {}
                    for ph, c in pairs(S.by) do parts[#parts + 1] = { ph, c } end
                    table.sort(parts, function(a, b) return a[2] > b[2] end)
                    local txt = {}
                    for i = 1, math.min(4, #parts) do txt[#txt + 1] = parts[i][1] .. ' ' .. parts[i][2] end
                    rezlog('[slow] last %ds: %d slow ticks (>=%dms), worst %dms in %s (%dms) | %s',
                           math.floor((mq.gettime() - S.at) / 1000), S.n, AT_SLOW_TICK_MS, S.worst,
                           S.worstPhase, math.floor(S.worstPhaseMs), table.concat(txt, ', '))
                end
                S.n, S.at, S.worst, S.worstPhase, S.worstPhaseMs, S.by = 0, mq.gettime(), 0, '?', 0, {}
            end
        end
        if AT_slowPending then
            local m = AT_slowPending
            local q = AT_slowQuiet
            AT_slowPending, AT_slowQuiet = nil, nil
            -- rezlog is file-only; log reaches the MQ window. Phase-level notices still speak up because
            -- those name something specific, but the bare tick timer stays on disk.
            if q then rezlog('[slow] %s', m) else log('\\ay[slow] %s\\ax', m) end
        end
        -- Same pattern, same reason: ui_push_chrome sits above `log` in the file and cannot reach it.
        if AT_chromeNote then
            local m = AT_chromeNote
            AT_chromeNote = nil
            log('%s', m)
        end
        -- The test loop presses the combo for us. On the tick, never from a bind: firing blocks.
        if INVT.checkAt and mq.gettime() >= INVT.checkAt then
            INVT.checkAt = nil
            pcall(invistest_check)
        end
        if INVT.on and mq.gettime() >= INVT.nextAt then
            if mq.gettime() >= INVT.until_ then
                INVT.on = false
                invistest_report()
            else
                INVT.nextAt = mq.gettime() + INVT.every
                INVT.seen = {}
                invisFireWanted = true
            end
        end
                -- PREP BEFORE ARM. THE ORDER IS THE WHOLE MECHANISM.
        -- /at_invisprep and /at_inviscast arrive in the same doevents batch and both set a flag, so
        -- whichever the tick reads first is the one that happens first.
        if invisPrepWanted then
            invisPrepWanted = false
            atphase('invis_prep')
            pcall(invis_prep_self)
        end
        if invisTake then
            local tk = invisTake
            invisTake = nil
            atphase('invis_arm')
            if tk.blob then pcall(function() invis_combo_take(tk.lead, tk.blob, tk.at) end)
            else pcall(function() invis_arm(tk.key, tk.lead, tk.at) end) end
        end
        if invisFireWanted then
            invisFireWanted = false
            atphase('invis_combo')
            pcall(invis_combo_fire)
        end
        if magicWanted then
            local w = magicWanted
            magicWanted = nil
            atphase('magic_click')
            if w.nm:lower() == myName:lower() then pcall(function() magic_click(w.key) end)
            else pcall(function() peer_cmdf(w.nm, '/at_magic %s', w.key) end) end
        end
        if pacDelWanted then
            local id = pacDelWanted
            pacDelWanted = nil
            pcall(function() peer_bcast('/at_pacdel %d', id) end)
        end
        if potWanted then
            local k = potWanted
            potWanted = nil
            atphase('group_pot')
            pcall(function() group_pot(k) end)
        end
        if pacAddWanted then
            local a = pacAddWanted
            pacAddWanted = nil
            atphase('pac_add')
            -- Straight into the same queue the Pacify panel fills, so it is routed, assigned and
            -- reported exactly as a mob added by any other route.
            pcall(function() pac_add_spawn(a.id) end)
        end
        -- CLOSE THE DISPATCH RUN.
        atphase('dispatch')
        if cothSetWanted then
            local w = cothSetWanted
            cothSetWanted = nil
            atphase('coth_set')
            pcall(function() coth_set(w == 'on') end)
        end

    -- THE GATHER GETS ITS OWN LABEL.
    atphase('coth_gather')
    if COTH.active and not distributing and (mq.gettime() - COTH.lastPoll) > 1000 then
        COTH.lastPoll = mq.gettime()
        local ok, err = pcall(coth_tick)
        if not ok then COTH.active = false; log('\\ar[coth] stopped after an error: %s\\ax', tostring(err)) end
    end
    -- REPORTING is not gated on `distributing`; only acting is.
    if not DI.auto and not DI.saidOff then
        DI.saidOff = true
        rezlog('[di] auto-DI is OFF here - I will not report my staff or save state to the group')
    end
    if DI.auto then
        DI.saidOff = false
        -- ONCE A SECOND, in combat or out. Combat only shortens the keepalive below.
        DI.selfGap = 1000
        if (mq.gettime() - (DI.lastSelfRead or 0)) < DI.selfGap then goto di_read_done end
        DI.lastSelfRead = mq.gettime()
        local ic = false
        pcall(function() ic = (tostring(mq.TLO.Me.CombatState() or ''):upper() == 'COMBAT') end)
        if ic ~= HB.diFast then HB.diFast = ic; DI.lastPush = 0 end   -- edge -> push now
        atphase('di_read_self')
        local a, b, c, d, e = di_read_self()   -- e = the save's NAME; dropping it left the wire arg nil
        -- MY STAFF CAME BACK - SAY SO, AND THE BATON COMES HOME.
        if a == 0 and DI.staffWasSpent then
            DI.staffWasSpent = false
            DI.saidStaffDown = false                -- re-arm the one-shot pass for the next cooldown
        elseif a > 0 then
            DI.staffWasSpent = true
            -- GIVE IT UP THE MOMENT MY STAFF IS DOWN, not when a save is finally needed.
            if not DI.watch then DI.saidStaffDown = true end
        end
        -- ON CHANGE, plus a keepalive.
        local key = string.format('%d/%d/%d/%d/%s', (a == 0) and 0 or 1, b, c, d, tostring(e or '-'))
        -- PUSH AFTER AN ACTION, WHATEVER THE READS SAY.
        if DI.pushNow or key ~= DI.key or (mq.gettime() - DI.lastPush) > (ic and 4000 or 20000) then
            DI.pushNow = nil
            DI.key, DI.lastPush = key, mq.gettime()
            -- saveName TOO.
            DI.state[myName] = { staff = a, emeralds = b, dgReady = c, saveUp = d,
                                 saveName = (e and e ~= '') and e or nil, updated = mq.gettime() }
            -- The save NAME goes last, so a peer on an older build simply reads nil and behaves as before.
            peer_bcast('/at_di %s %d %d %d %d %s', myName, a, b, c, d, (e and e ~= '') and e:gsub(' ', '_') or '-')
            -- Say it ONCE.
            if not DI.saidPush then
                DI.saidPush = true
                rezlog('[di] first state broadcast: staff=%d emeralds=%d dg=%d save=%d', a, b, c, d)
            end
            -- NAME THE RUNG.
            if DI.dgRung and DI.dgRung ~= DI.dgRungSaid then
                DI.dgRungSaid = DI.dgRung
                rezlog('[di] my save ladder: %s%s (dg=%d)', DI.dgRung,
                       DI.dgLatched and ' [latched]' or '', c)
            end
        end
        -- Label last in the block, so the skip above cannot jump into the scope of a local declared here.
        ::di_read_done::
    end
    DI.pollGap = 1000   -- DI decisions once a second, in combat or out
    -- NOT DI'S BUSINESS.
    atphase('feeds'); pcall(function()
        if SHOW_UI and (mq.gettime() - (feedAt or 0)) > 2000 then
            feedAt = mq.gettime()
            feed_announce(false)
        end
    end)
    atphase('raid'); pcall(raid_tick)
    atphase('raidmove'); pcall(function()
        if raidMoveWant then
            local w = raidMoveWant; raidMoveWant = nil
            if w.action == 'leader' then raid_make_leader(w.name)
            elseif w.action == 'gleader' then raid_makeleader_cmd(w.name)
            elseif w.action == 'remove' then raid_remove(w.name)
            elseif w.place then raid_place(w.name, w.group)
            else raid_move(w.name, w.group) end
            return
        end
        -- PUT THE LOCK BACK once the moves stop.
        if raidWeLocked and raidLockLinger > 0 and mq.gettime() > raidLockLinger then
            raidWeLocked, raidLockLinger, raidLockAt = false, 0, 0
            pcall(function() mq.cmdf('/nomodkey /notify %s RAID_UnlockButton leftmouseup', RAID_WND) end)
            mq.delay(1200, function() return not raid_is_locked() end)
            rezlog('[raid] unlocked again (locked=%s)', tostring(raid_is_locked()))
        end
    end)
    atphase('cothswap'); pcall(coth_swap_tick)
    atphase('cothg'); pcall(function()
        if cothgSetWanted then
            local w = cothgSetWanted; cothgSetWanted = nil
            cothg_set(w == 'on')
        end
        cothg_tick()
    end)
    atphase('cothwatch'); pcall(coth_watch_tick)
    if DIQ.pending then atphase('di_pend'); pcall(di_pend_tick) end
    if DI.auto and not distributing and (mq.gettime() - DI.lastPoll) > (DI.pollGap or 1000) then
        DI.lastPoll = mq.gettime()
        -- THE FAST PATH FIRST.
        atphase('di_verify'); pcall(di_rung_verify)
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
    -- Adaptive heartbeat.
    atphase('nv_push')
    local nvDue = (mq.gettime() - (lastStatePush or 0)) >= pace(STATE_PUSH_MS)
    if nvDue then
    lastStatePush = mq.gettime()
    local nvOk, nvErr = pcall(function()
        -- NO POKE HERE.
        if not feed_wanted('nv') then
            if nvLast ~= '' then nvLast = '' end
            return
        end
        -- ONE TIMER READ PER EMBLEM. Each one is a bag search, and it was done two or three times per push.
        local have, secsOf, upOf = nv_have(), {}, {}
        for _, i in ipairs(have) do
            secsOf[i] = nv_secs_at(i)
            upOf[i] = (secsOf[i] > 0) and nv_effect_secs(i) or 0
        end
        local parts = {}
        for _, i in ipairs(have) do
            parts[#parts + 1] = string.format('%d:%d:%d', i, secsOf[i], upOf[i])
        end
        local list = (#parts > 0) and table.concat(parts, ',') or '-'
        -- THE KEY IS BUCKETED, THE PAYLOAD IS NOT. 'u' while the effect runs, so its fading is a change.
        local kparts = {}
        for _, i in ipairs(have) do
            kparts[#kparts + 1] = string.format('%d:%s%s', i, (secsOf[i] > 0) and 'd' or 'r', (upOf[i] > 0) and 'u' or '')
        end
        local nk = (#kparts > 0) and table.concat(kparts, ',') or '-'
        -- ON CHANGE, PLUS A SLOW KEEPALIVE.
        if (mq.gettime() - (nvPushAt or 0)) > 300000 then nvLast = '' end
        if nvLast ~= nk then
            nvPushAt = mq.gettime()
            nvLast = nk
            if SHOW_UI then
                local items, ups = {}, {}
                for _, i in ipairs(have) do items[i] = secsOf[i]; ups[i] = upOf[i] end
                nvState[myName] = { items = items, ups = ups, updated = mq.gettime() }
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
    end
    -- UNCONDITIONAL BOUNDARY.
    atphase('rez_push')
    -- ON A CADENCE.
    -- Every second while a corpse is in the zone, every 5s otherwise: nothing to rez, nothing urgent to report.
    if rezAuto and not distributing
       and (mq.gettime() - (lastRezPush or 0)) >= pace(rez_event_now() and REZ_PUSH_MS or REZ_PUSH_IDLE_MS) then
        lastRezPush = mq.gettime()
        -- ON CHANGE, plus a slow keepalive.
        local cr, tk, cw = my_rez_secs(CROWN_ITEM), my_rez_secs(TOKEN_ITEM), my_cotw_secs()
        local dv = my_divine_secs()
        -- REPORT AS UNAVAILABLE WHILE FEIGNING, rather than leaving peers to discover it by timeout.
        if am_feigning() or am_invis() or died_recently(REZ_DOWN_MS) then cr, tk, cw, dv = -1, -1, -1, -1 end
        local dead = false; pcall(function() dead = tlo_true(mq.TLO.Me.Dead()) end)
        local zone = 0; pcall(function() zone = tonumber(mq.TLO.Zone.ID()) or 0 end)
        local al = dead and 0 or 1
        -- Buckets, not raw seconds: a ticking countdown changes every second and would defeat the whole
        -- point.
        local key = string.format('%d/%d/%d/%d/%d/%d', (cr == 0) and 0 or 1, (tk == 0) and 0 or 1,
                                  (cw < 0) and 2 or ((cw == 0) and 0 or 1), al, zone,
                                  (dv < 0) and 2 or ((dv == 0) and 0 or 1))
        -- 2s while a corpse is in the zone, 20s otherwise.
        local due = (mq.gettime() - lastRezReadyPoll) > (rez_event_now() and 2000 or 20000)
        if key ~= rezReadyKey or due then
            rezReadyKey = key
            lastRezReadyPoll = mq.gettime()
            rezReady[myName] = { crown = cr, token = tk, cotw = cw, divine = dv, alive = (al == 1), zone = zone, updated = mq.gettime() }
            -- cotw goes LAST on the wire on purpose: a toon still on the previous build sends five
            -- args, the new bind reads the sixth as nil, and it becomes -1 ("doesn't own").
            peer_bcast('/at_rezready %s %d %d %d %d %d %d', myName, cr, tk, al, zone, cw, dv)
        end
    end
    if distributing then
        wasDistributing = true
    elseif wasDistributing then           -- pass just ended: heartbeats were paused, so everyone looks stale.
        wasDistributing = false           -- hold the picker ~4s so peers re-report before staleness is trusted
        rezHoldUntil = mq.gettime() + 4000   -- (otherwise 'stale' reads as 'crashed' and several toons fire at once)
    end
    -- 250ms while a corpse is in the zone, 1000ms otherwise.
    if not distributing and mq.gettime() >= rezHoldUntil
       and (mq.gettime() - lastRezPoll) > (rez_event_now() and 250 or 1000) then
        atphase('rez_tick')
        lastRezPoll = mq.gettime(); rez_announce_ready(); rez_autoaccept(); rez_verify_tick(); rez_tick()
    end
    accept_incoming()
    -- A BURST IS THE THING TO CATCH. Total inbound per minute says how busy it is; the WORST single
    -- doevents says whether a lag spike and a pile of arrivals are the same event.
    NETIN.tick = 0
    atphase('doevents'); mq.doevents()
    -- doevents is timed into THIS tick (1.21.1): it was the last phase, recorded only after the slow check
    -- had read the tick and been reset, so the next tick's report named 'doevents' with this one's time.
    atphase('tick_end')
    if NETIN.tick > NETIN.worstTick then
        NETIN.worstTick, NETIN.worstAt = NETIN.tick, mq.gettime()
    end
    -- Flush FIRST, then mark idle.
    AT_TICKS = AT_TICKS + 1
    -- Rolling five second average for the Settings readout. Two integers and a subtraction per tick.
    AT_DISP_TICKS = AT_DISP_TICKS + 1
    if AT_DISP_AT == 0 then AT_DISP_AT = mq.gettime() end
    if (mq.gettime() - AT_DISP_AT) >= 5000 then
        local mins = (mq.gettime() - AT_DISP_AT) / 60000
        AT_DISP_RATE = AT_DISP_TICKS / mins
        AT_DISP_WANT = AT_DISP_WANT_SUM / math.max(1, AT_DISP_TICKS)
        AT_DISP_WAIT = AT_DISP_WAIT_SUM / math.max(1, AT_DISP_TICKS)
        -- WORK = the pass minus the time actually SLEPT, not minus the time ASKED for. Subtracting the
        -- request counted the client's overshoot twice: once here and again as 'client'.
        AT_DISP_WORK = math.max(0, (60000 / math.max(1, AT_DISP_RATE)) - AT_DISP_WAIT)
        AT_DISP_FR = (AT_DISP_FR_N > 0) and (AT_DISP_FR_SUM / AT_DISP_FR_N) or -1
        AT_DISP_FR_SUM, AT_DISP_FR_N = 0, 0
        AT_TURBO = at_turbo()
        if SHOW_UI then
            local secs = (mq.gettime() - AT_DISP_AT) / 1000
            AT_DISP_FPS = (UI_FRAMES >= AT_DISP_F_AT and secs > 0) and ((UI_FRAMES - AT_DISP_F_AT) / secs) or -1
            AT_DISP_F_AT = UI_FRAMES
            -- Only honest once turbo is up: below that, 'us' is mostly MacroQuest's pauses, not AT.
            AT_DISP_SHARE = (AT_TURBO >= 1000) and (AT_DISP_WORK * AT_DISP_RATE / 600) or -1
            if (perfScale or 1) == 1 and AT_DISP_FPS > 0 and AT_DISP_FPS < AT_LOWSPEC_FPS
               and AT_DISP_SHARE > AT_LOWSPEC_SHARE then
                AT_LOWSPEC_STREAK = AT_LOWSPEC_STREAK + 1
                if AT_LOWSPEC_STREAK == AT_LOWSPEC_WINDOWS then
                    log('\\ay[perf] %.0f fps and AdventureTime is using %.0f%% of it - Low spec mode (Settings > Performance) would help\\ax',
                        AT_DISP_FPS, AT_DISP_SHARE)
                end
            else
                AT_LOWSPEC_STREAK = 0
            end
        end
        AT_DISP_TICKS, AT_DISP_AT, AT_DISP_WAIT_SUM, AT_DISP_WANT_SUM = 0, mq.gettime(), 0, 0
    end
    -- Work for this tick ends here; everything after is the deliberate wait.
    do
        local w = mq.gettime() - (AT_TICK_T0 or mq.gettime())
        do
            if SHOW_UI and AT_TICK_F0 and UI_FRAMES >= AT_TICK_F0 then
                AT_DISP_FR_SUM, AT_DISP_FR_N = AT_DISP_FR_SUM + (UI_FRAMES - AT_TICK_F0), AT_DISP_FR_N + 1
            end
        end
        if AT_CPU.since == 0 then AT_CPU.since = mq.gettime() end
        AT_CPU.busy  = AT_CPU.busy + w
        AT_CPU.ticks = AT_CPU.ticks + 1
        -- EVERY SLOW TICK, NOT ONE IN TWENTY.
        if w >= AT_SLOW_TICK_MS then
            -- IT NAMES THE PHASE NOW.
            local wp = tostring(AT_tickWorst or '?')
            local floor = AT_SLOW_EXPECTED[wp]
            if not (floor and (AT_tickWorstMs or 0) < floor) then
                -- ONE LINE A MINUTE, not one per slow tick: these were 55-89% of every log. A multi-second
                -- block still gets its own line straight away.
                if w >= 3000 and (mq.gettime() - (AT_SLOW_TICK_AT or 0)) > 3000 then
                    AT_SLOW_TICK_AT = mq.gettime()
                    AT_slowPending = string.format('%dms tick - worst phase: %s (%dms)%s  <-- MULTI-SECOND BLOCK',
                                                   w, wp, math.floor(AT_tickWorstMs or 0),
                                                   floor and '  [over its expected cost]' or '')
                    AT_slowQuiet = true
                end
                local S = AT_SLOW_SUM
                S.n = S.n + 1
                S.by[wp] = (S.by[wp] or 0) + 1
                if w > S.worst then S.worst, S.worstPhase, S.worstPhaseMs = w, wp, AT_tickWorstMs or 0 end
            end
        end
    end
    -- RESET PER TICK, right after the check that reads them.
    if AT_tickWorst then
        AT_HEAVY[AT_tickWorst] = (AT_HEAVY[AT_tickWorst] or 0) + 1
        AT_HEAVY_MS[AT_tickWorst] = (AT_HEAVY_MS[AT_tickWorst] or 0) + (AT_tickWorstMs or 0)
        AT_HEAVY_N = AT_HEAVY_N + 1
    end
    AT_tickWorst, AT_tickWorstMs = nil, 0
    AT_phaseStart = nil   -- the bookkeeping after tick_end is not carried into the next tick's worst (1.21.1)
    atphase('idle')
    AT_phaseStart = nil
    -- THE TICK RATE IS THE REAL DIAL, and it was the one thing low spec mode never touched.
    do
        local d0 = mq.gettime()
        -- THE ONE LINE LOW SPEC WAS MISSING.
        local rezHot = rez_event_now()
        if rezHot and rezIdleAt > 0 and (mq.gettime() - rezIdleAt) > REZ_LANE_IDLE then rezHot = false end
        -- SAY SO, ONCE EACH WAY. Edge triggered, so a four second wipe is two lines rather than six.
        if rezHot ~= AT_LANE_ON then
            AT_LANE_ON = rezHot
            if rezHot then
                AT_LANE_AT, AT_LANE_TICKS = mq.gettime(), 0
                if (perfScale or 1) > 1 then
                    rezlog('[perf] rez fast lane ENGAGED - tick %dms -> 250ms while a corpse is up',
                           pace(250))
                end
            else
                if (perfScale or 1) > 1 and AT_LANE_AT > 0 then
                    rezlog('[perf] rez fast lane released after %dms over %d tick(s)',
                           mq.gettime() - AT_LANE_AT, AT_LANE_TICKS)
                end
                AT_LANE_AT = 0
            end
        end
        if rezHot then AT_LANE_TICKS = AT_LANE_TICKS + 1 end
        local want = rezHot and 250 or pace(250)
        mq.delay(want)
        local slept = mq.gettime() - d0
        AT_CPU.idle = AT_CPU.idle + slept
        AT_DISP_WAIT_SUM = AT_DISP_WAIT_SUM + slept
        AT_DISP_WANT_SUM = AT_DISP_WANT_SUM + want
    end
    -- Label goes LAST in the block so the client_ready skip at the top does not jump into the scope of
    -- any local declared in the body - Lua permits a goto to a label at the end of a block precisely
    -- for this pattern.
    ::continue_tick::
end

pcall(function() mq.unbind('/at') end)
pcall(function() mq.unbind('/atpop') end)
pcall(function() mq.unbind('/atui') end)
pcall(function() mq.unbind('/atinvis') end)
pcall(function() mq.unbind('/atshimmer') end)
pcall(function() mq.unbind('/atfleeting') end)
pcall(function() mq.unbind('/atinferno') end)
pcall(function() mq.unbind('/atpacify') end)
pcall(function() mq.unbind('/atuie') end)
pcall(function() mq.unbind('/at_dcnow') end)
pcall(function() mq.unbind('/at_dcwant') end)
pcall(function() mq.unbind('/at_dcgo') end)
pcall(function() mq.unbind('/at_dcdone') end)
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
pcall(function() mq.unbind('/at_burnsum') end)
pcall(function() mq.unbind('/at_burnresend') end)
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
pcall(function() mq.unbind('/at_cothwatch') end)
pcall(function() mq.unbind('/at_cothgo') end)
pcall(function() mq.unbind('/at_cotharrived') end)
pcall(function() mq.unbind('/at_cothhere') end)
pcall(function() mq.unbind('/at_cothcast') end)
pcall(function() mq.unbind('/at_cothat') end)
pcall(function() mq.unbind('/atcothwho') end)
pcall(function() mq.unbind('/atinvistest') end)
pcall(function() mq.unbind('/at_invisfired') end)
pcall(function() mq.unbind('/at_makemevis') end)
pcall(function() mq.unbind('/atmakemevis') end)
pcall(function() mq.unbind('/at_cothmine') end)
pcall(function() mq.unbind('/at_di') end)
pcall(function() mq.unbind('/at_diauto') end)
pcall(function() mq.unbind('/at_difired') end)
pcall(function() mq.unbind('/at_rezready') end)
pcall(function() mq.unbind('/at_rezclaim') end)
pcall(function() mq.unbind('/at_rezunclaim') end)
pcall(function() mq.unbind('/at_rezretire') end)
pcall(function() mq.unbind('/at_rezrdy?') end)
pcall(function() mq.unbind('/at_rezrdy!') end)
pcall(function() mq.unbind('/at_rezskip') end)
pcall(function() mq.unbind('/at_rezdone') end)
pcall(function() mq.unbind('/at_rezorder') end)
pcall(function() mq.unbind('/at_rezorder?') end)
-- SAY WHY IT ENDED, AND WHEN.
pcall(function() dnet_drop_all('script stopping') end)
pcall(function()
    log('=== AdventureTime stopping: %s ===', atExitWhy or '/lua stop, a reload, or the client closing')
end)
-- NEVER LEAVE THE ENCHANTER STRIPPED.
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
pcall(function() mq.unbind('/atburncheck') end)
pcall(function() mq.unbind('/at_burnwarn') end)
pcall(function() mq.unbind('/at_burnexp') end)
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
pcall(function() mq.unbind('/at_turbo') end)
pcall(function() mq.unbind('/at_iconq') end)
pcall(function() mq.unbind('/at_icon') end)
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
pcall(function() mq.unbind('/at_rezping') end)
pcall(function() mq.unbind('/at_rezpong') end)
pcall(function() mq.unbind('/atrezclear') end)
pcall(function() mq.unbind('/at_rezclear') end)
pcall(function() mq.unbind('/at_rezprobe') end)
pcall(function() mq.unbind('/at_rezwindows') end)
pcall(function() mq.unbind('/atcoth') end)
pcall(function() mq.unbind('/atsync') end)
pcall(function() mq.unbind('/at_corpseprobe') end)
pcall(function() mq.unbind('/atburnpoll') end)
pcall(function() mq.unbind('/at_burnpoll') end)
pcall(function() mq.unbind('/at_pwhave') end)
pcall(function() mq.unbind('/at_pwoor') end)
pcall(function() mq.unbind('/atpub') end)
pcall(function() mq.unbind('/atheavy') end)
pcall(function() mq.unbind('/ate3') end)
pcall(function() mq.unbind('/atgrab') end)
pcall(function() mq.unbind('/atobsdrop') end)
pcall(function() mq.unbind('/at_net') end)
pcall(function() mq.unbind('/at_netask') end)
pcall(function() mq.unbind('/at_pwmark') end)
pcall(function() mq.unbind('/at_pwclear') end)
pcall(function() mq.unbind('/at_pwdel') end)
pcall(function() mq.unbind('/at_pwadd') end)
-- A HELD LOCK MUST NOT OUTLIVE US. The lock now spans ticks rather than one call, so /lua stop or a
-- crash between moves would leave somebody else's raid locked with nothing left running to undo it.
pcall(function()
    if raidWeLocked then
        mq.cmdf('/nomodkey /notify %s RAID_UnlockButton leftmouseup', RAID_WND)
        raidWeLocked = false
    end
end)
pcall(function() e3_release_all() end)   -- always hand our toon back to E3 on the way out
if SHOW_UI then mq.imgui.destroy(scriptName) end
