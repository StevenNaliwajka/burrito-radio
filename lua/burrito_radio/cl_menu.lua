--[[--------------------------------------------------------------------------
    burrito_radio/cl_menu.lua  -- the menu you get pressing E on a radio

      top      what is playing, how far in, play/pause, skip (or vote to skip),
               stop, the radio's volume, and your own mute
      add      paste a YouTube video or playlist link, a direct .mp3/.ogg link,
               or just type a song name (the first YouTube hit)
      Queue    what is coming up; remove songs (yours, or any if you run the
               radio), move one to the top, save one to the library
      Library  the server owner's preloaded music and saved playlists
      Radio    range, loop, shuffle, autoplay, pin to the map, remove it

    Buttons you may not use are greyed out; the server checks again anyway.
----------------------------------------------------------------------------]]

local CL = BRadio.CL
local Menu = BRadio.Menu or {}
BRadio.Menu = Menu

local BLUE = Color(121, 153, 194)
local BLUE_DK = Color(52, 70, 98)
local BLUE_DKR = Color(34, 46, 66)
local INK = Color(240, 244, 250)
local SUB = Color(185, 200, 225)
local BRASS = Color(222, 186, 118)

surface.CreateFont("BRadioMenuTitle", { font = "Roboto", size = 24, weight = 800, extended = true })
surface.CreateFont("BRadioMenuSong", { font = "Roboto", size = 20, weight = 700, extended = true })
surface.CreateFont("BRadioMenu", { font = "Roboto", size = 16, weight = 500, extended = true })
surface.CreateFont("BRadioMenuSmall", { font = "Roboto", size = 14, weight = 500, extended = true })

local function send(op, args)
    args = args or {}
    args.id = Menu.id
    BRadio.Send(op, args)
end

local function station() return Menu.id and CL.Stations[Menu.id] end

local function button(parent, text, fn, w)
    local b = vgui.Create("DButton", parent)
    b:SetText(text)
    b:SetFont("BRadioMenu")
    b:SetTextColor(INK)
    b:SetTall(30)
    if w then b:SetWide(w) end
    b.Paint = function(s, pw, ph)
        local c = s:GetDisabled() and Color(70, 80, 96) or (s:IsHovered() and Color(96, 128, 172) or Color(74, 100, 140))
        draw.RoundedBox(6, 0, 0, pw, ph, c)
    end
    b.UpdateColours = function(s) s:SetTextStyleColor(s:GetDisabled() and Color(150, 156, 166) or INK) end
    b.DoClick = function() if not b:GetDisabled() then fn(b) end end
    return b
end

local function check(parent, text, fn)
    local c = vgui.Create("DCheckBoxLabel", parent)
    c:SetText(text)
    c:SetFont("BRadioMenu")
    c:SetTextColor(INK)
    c.OnChange = function(s, v) if not s.quiet then fn(v) end end
    return c
end

local function setCheck(c, v)
    c.quiet = true
    c:SetChecked(v and true or false)
    c.quiet = false
end

local function slider(parent, text, min, max, dec, fn, preview)
    local s = vgui.Create("DNumSlider", parent)
    s:SetText(text)
    s:SetMinMax(min, max)
    s:SetDecimals(dec)
    s.Label:SetTextColor(INK)
    s.Label:SetFont("BRadioMenu")
    s.TextArea:SetTextColor(INK)
    -- quick: at most one send per THROTTLE while dragging, and the last value
    -- always goes (a trailing send), so where you let go is where it stays
    local THROTTLE = 0.1
    s.OnValueChanged = function(self, v)
        if self.quiet then return end
        if preview then preview(v) end
        local now = RealTime()
        local id = "bradio_slider_" .. text
        if now - (self.lastSend or 0) >= THROTTLE then
            self.lastSend = now
            timer.Remove(id)
            fn(v)
        else
            timer.Create(id, THROTTLE, 1, function() self.lastSend = RealTime() fn(v) end)
        end
    end
    return s
end

local function setSlider(s, v)
    if s:IsEditing() then return end
    s.quiet = true
    s:SetValue(v)
    s.quiet = false
end

local function list(parent, cols)
    local l = vgui.Create("DListView", parent)
    l:SetMultiSelect(true)
    for _, c in ipairs(cols) do
        local col = l:AddColumn(c[1])
        if c[2] then col:SetFixedWidth(c[2]) end
    end
    l.Paint = function(_, pw, ph) draw.RoundedBox(4, 0, 0, pw, ph, Color(236, 241, 248)) end
    return l
end

-- --------------------------------------------------------------- building
function Menu.Open(id, canControl, isAdmin, canAdd)
    if IsValid(Menu.frame) then Menu.frame:Remove() end
    Menu.id, Menu.canControl, Menu.isAdmin, Menu.canAdd = id, canControl, isAdmin, canAdd

    local f = vgui.Create("DFrame")
    Menu.frame = f
    f:SetSize(math.min(820, ScrW() - 40), math.min(640, ScrH() - 40))
    f:Center()
    f:SetTitle("")
    f:MakePopup()
    f:SetSizable(false)
    f.Paint = function(_, pw, ph)
        draw.RoundedBox(10, 0, 0, pw, ph, BLUE_DKR)
        draw.RoundedBoxEx(10, 0, 0, pw, 54, BLUE_DK, true, true, false, false)
        draw.SimpleText("CROSLEY", "BRadioMenuTitle", 16, 27, BRASS, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        local st = station()
        local sub = st and (st.pinned and "Pinned by the server" or ("Owner: " .. tostring(st.owner))) or ""
        draw.SimpleText("Cooper Radio", "BRadioMenuSong", 130, 27, INK, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        draw.SimpleText(sub, "BRadioMenuSmall", pw - 50, 27, SUB, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
    end

    -- now playing ------------------------------------------------------
    local np = vgui.Create("DPanel", f)
    np:Dock(TOP)
    np:DockMargin(6, 28, 6, 6)
    np:SetTall(132)
    np.Paint = function(_, pw, ph)
        draw.RoundedBox(8, 0, 0, pw, ph, BLUE_DK)
        local st = station()
        local title, by, pos, dur, state = "Nothing playing", "", 0, 0, st and st.state or "idle"
        if st and st.cur then
            title = st.cur.t or st.cur.k
            by = "added by " .. tostring(st.cur.b or "?")
            pos = math.max(0, BRadio.Position(st))
            dur = st.cur.d or 0
        end
        if state == "loading" then by = "downloading... " .. by end
        if state == "paused" then by = "paused · " .. by end
        draw.SimpleText(title, "BRadioMenuSong", 12, 18, INK, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        draw.SimpleText(by, "BRadioMenuSmall", 12, 40, SUB, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        -- progress
        local bx, by2, bw = 12, 58, pw - 24
        draw.RoundedBox(3, bx, by2, bw, 6, BLUE_DKR)
        if dur > 0 then draw.RoundedBox(3, bx, by2, math.Clamp(pos / dur, 0, 1) * bw, 6, BRASS) end
        draw.SimpleText(BRadio.FormatTime(pos) .. (dur > 0 and (" / " .. BRadio.FormatTime(dur)) or ""),
            "BRadioMenuSmall", pw - 12, 40, SUB, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
        if st and (st.votes or 0) > 0 then
            draw.SimpleText("skip votes: " .. st.votes, "BRadioMenuSmall", pw - 12, 18, BRASS, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
        end
    end
    -- click the bar to seek (controllers)
    np.OnMousePressed = function(s)
        local st = station()
        if not (Menu.canControl and st and st.cur and (st.cur.d or 0) > 0) then return end
        local x, y = s:CursorPos()
        if y < 50 or y > 72 then return end
        send("seek", { t = math.Clamp((x - 12) / (s:GetWide() - 24), 0, 1) * st.cur.d })
    end

    local row = vgui.Create("DPanel", np)
    row:SetPos(10, 82)
    row:SetSize(f:GetWide() - 32, 40)
    row.Paint = nil
    Menu.bPlay = button(row, "Pause", function() send("pause") end, 90)
    Menu.bPlay:Dock(LEFT)
    Menu.bSkip = button(row, "Skip", function() send("skip") end, 110)
    Menu.bSkip:Dock(LEFT) Menu.bSkip:DockMargin(6, 0, 0, 0)
    Menu.bStop = button(row, "Stop", function() send("stop") end, 70)
    Menu.bStop:Dock(LEFT) Menu.bStop:DockMargin(6, 0, 0, 0)
    Menu.mute = check(row, "Mute for me", function(v) CL.Muted[Menu.id] = v or nil end)
    Menu.mute:Dock(RIGHT) Menu.mute:DockMargin(10, 8, 4, 0)
    -- the knob: you hear it move at once (local preview), everyone else ~0.1 s later
    Menu.vol = slider(row, "Radio volume", 0, 100, 0, function(v) send("volume", { v = v / 100 }) end, function(v)
        local st = station()
        if not st or not Menu.canControl then return end
        st.vol = v / 100
        CL.LocalVol[st.id] = { v = v / 100, untilT = CurTime() + 0.8 }
    end)
    Menu.vol:Dock(FILL) Menu.vol:DockMargin(14, 0, 0, 0)

    -- add ---------------------------------------------------------------
    local add = vgui.Create("DPanel", f)
    add:Dock(TOP)
    add:DockMargin(6, 0, 6, 6)
    add:SetTall(36)
    add.Paint = nil
    local entry = vgui.Create("DTextEntry", add)
    entry:Dock(FILL)
    entry:SetFont("BRadioMenu")
    entry:SetPlaceholderText("Paste a YouTube video or playlist link, an .mp3 link, or type a song name")
    Menu.entry = entry
    local function doAdd(nextUp)
        local q = string.Trim(entry:GetValue())
        if q == "" then return end
        send("add", { q = q, next = nextUp })
        entry:SetValue("")
    end
    entry.OnEnter = function() doAdd(false) end
    Menu.bNext = button(add, "Play next", function() doAdd(true) end, 100)
    Menu.bNext:Dock(RIGHT) Menu.bNext:DockMargin(6, 0, 0, 0)
    Menu.bAdd = button(add, "Add", function() doAdd(false) end, 90)
    Menu.bAdd:Dock(RIGHT) Menu.bAdd:DockMargin(6, 0, 0, 0)

    -- status line --------------------------------------------------------
    local status = vgui.Create("DLabel", f)
    status:Dock(BOTTOM)
    status:DockMargin(10, 4, 10, 2)
    status:SetFont("BRadioMenuSmall")
    status:SetTextColor(SUB)
    status:SetText("Tip: anyone near the radio hears it. Range and volume fade with distance and walls.")
    Menu.status = status

    -- tabs ---------------------------------------------------------------
    local sheet = vgui.Create("DPropertySheet", f)
    sheet:Dock(FILL)
    sheet:DockMargin(6, 0, 6, 0)
    Menu.sheet = sheet

    Menu.BuildQueue(sheet)
    Menu.BuildLibrary(sheet)
    Menu.BuildSettings(sheet)

    Menu.Refresh()
    Menu.RefreshLibrary()
end

function Menu.BuildQueue(sheet)
    local p = vgui.Create("DPanel", sheet)
    p.Paint = nil
    local bar = vgui.Create("DPanel", p)
    bar:Dock(BOTTOM)
    bar:SetTall(34)
    bar:DockMargin(0, 6, 0, 0)
    bar.Paint = nil
    local l = list(p, { { "#", 34 }, { "Title" }, { "Length", 64 }, { "Added by", 140 } })
    l:Dock(FILL)
    Menu.queue = l
    local function selected()
        local out = {}
        for _, line in ipairs(l:GetSelected()) do out[#out + 1] = line end
        table.sort(out, function(a, b) return a.idx > b.idx end)  -- remove from the bottom up
        return out
    end
    Menu.bRemove = button(bar, "Remove selected", function()
        for _, line in ipairs(selected()) do send("remove", { i = line.idx, k = line.key }) end
    end, 150)
    Menu.bRemove:Dock(LEFT)
    Menu.bTop = button(bar, "Move to top", function()
        local s = selected()
        if s[1] then send("move", { i = s[1].idx, k = s[1].key, to = 1 }) end
    end, 120)
    Menu.bTop:Dock(LEFT) Menu.bTop:DockMargin(6, 0, 0, 0)
    Menu.bClear = button(bar, "Clear queue", function() send("clear") end, 110)
    Menu.bClear:Dock(RIGHT)
    Menu.bSaveNow = button(bar, "Save playing song to library", function() send("libsave") end, 220)
    Menu.bSaveNow:Dock(RIGHT) Menu.bSaveNow:DockMargin(0, 0, 6, 0)
    l.OnRowRightClick = function(_, _, line)
        local m = DermaMenu()
        m:AddOption("Remove", function() send("remove", { i = line.idx, k = line.key }) end):SetIcon("icon16/delete.png")
        if Menu.canControl then
            m:AddOption("Move to top", function() send("move", { i = line.idx, k = line.key, to = 1 }) end):SetIcon("icon16/arrow_up.png")
        end
        if Menu.isAdmin then
            m:AddOption("Save to library", function() send("libsave", { k = line.key }) end):SetIcon("icon16/disk.png")
        end
        m:AddOption("Copy YouTube link", function()
            local id = tostring(line.key):match("^yt%-(.+)$")
            SetClipboardText(id and ("https://youtu.be/" .. id) or line.key)
        end):SetIcon("icon16/page_copy.png")
        m:Open()
    end
    sheet:AddSheet("Queue", p, "icon16/text_list_numbers.png")
end

function Menu.BuildLibrary(sheet)
    local p = vgui.Create("DPanel", sheet)
    p.Paint = nil

    local right = vgui.Create("DPanel", p)
    right:Dock(RIGHT)
    right:SetWide(250)
    right:DockMargin(6, 0, 0, 0)
    right.Paint = function(_, pw, ph) draw.RoundedBox(6, 0, 0, pw, ph, BLUE_DK) end
    local plTitle = vgui.Create("DLabel", right)
    plTitle:Dock(TOP) plTitle:DockMargin(8, 6, 8, 2)
    plTitle:SetFont("BRadioMenu") plTitle:SetTextColor(INK)
    plTitle:SetText("Saved playlists")
    local pls = list(right, { { "Name" }, { "Songs", 50 } })
    pls:SetMultiSelect(false)
    pls:Dock(FILL) pls:DockMargin(6, 0, 6, 0)
    Menu.playlists = pls
    local plBar = vgui.Create("DPanel", right)
    plBar:Dock(BOTTOM) plBar:SetTall(108) plBar:DockMargin(6, 6, 6, 6)
    plBar.Paint = nil
    local function selPl() local s = pls:GetSelectedLine() return s and pls:GetLine(s).plname end
    Menu.bPlLoad = button(plBar, "Queue playlist", function() local n = selPl() if n then send("plload", { name = n }) end end)
    Menu.bPlLoad:Dock(TOP)
    Menu.bPlDel = button(plBar, "Delete playlist", function() local n = selPl() if n then send("pldelete", { name = n }) end end)
    Menu.bPlDel:Dock(TOP) Menu.bPlDel:DockMargin(0, 4, 0, 0)
    local saveRow = vgui.Create("DPanel", plBar)
    saveRow:Dock(TOP) saveRow:SetTall(30) saveRow:DockMargin(0, 4, 0, 0)
    saveRow.Paint = nil
    local plName = vgui.Create("DTextEntry", saveRow)
    plName:Dock(FILL) plName:SetPlaceholderText("name for the current queue")
    Menu.plName = plName
    Menu.bPlSave = button(saveRow, "Save", function()
        send("plsave", { name = plName:GetValue() }) plName:SetValue("")
    end, 56)
    Menu.bPlSave:Dock(RIGHT) Menu.bPlSave:DockMargin(4, 0, 0, 0)

    local top = vgui.Create("DPanel", p)
    top:Dock(TOP) top:SetTall(30) top:DockMargin(0, 0, 0, 6)
    top.Paint = nil
    local search = vgui.Create("DTextEntry", top)
    search:Dock(FILL)
    search:SetPlaceholderText("Search the library")
    search:SetUpdateOnType(true)
    search.OnValueChange = function() Menu.RefreshLibrary() end
    Menu.search = search
    Menu.bLibAll = button(top, "Queue all (shuffled)", function() send("libadd", { all = true }) end, 170)
    Menu.bLibAll:Dock(RIGHT) Menu.bLibAll:DockMargin(6, 0, 0, 0)
    Menu.bLibAdd = button(top, "Queue selected", function()
        local keys = {}
        for _, line in ipairs(Menu.lib:GetSelected()) do keys[#keys + 1] = line.key end
        if #keys > 0 then send("libadd", { keys = keys }) end
    end, 140)
    Menu.bLibAdd:Dock(RIGHT) Menu.bLibAdd:DockMargin(6, 0, 0, 0)

    local adm = vgui.Create("DPanel", p)
    adm:Dock(BOTTOM) adm:SetTall(34) adm:DockMargin(0, 6, 0, 0)
    adm.Paint = nil
    Menu.libAdmin = adm
    local imp = vgui.Create("DTextEntry", adm)
    imp:Dock(FILL)
    imp:SetPlaceholderText("Admins: a YouTube playlist or video to download into the library")
    Menu.bImport = button(adm, "Import", function()
        local q = string.Trim(imp:GetValue())
        if q ~= "" then send("libimport", { q = q }) imp:SetValue("") end
    end, 80)
    Menu.bImport:Dock(RIGHT) Menu.bImport:DockMargin(6, 0, 0, 0)
    Menu.bLibDel = button(adm, "Remove selected", function()
        for _, line in ipairs(Menu.lib:GetSelected()) do send("libremove", { k = line.key }) end
    end, 140)
    Menu.bLibDel:Dock(RIGHT) Menu.bLibDel:DockMargin(6, 0, 0, 0)
    Menu.bRescan = button(adm, "Rescan files", function() send("librescan") end, 110)
    Menu.bRescan:Dock(RIGHT) Menu.bRescan:DockMargin(6, 0, 0, 0)

    local l = list(p, { { "Album", 140 }, { "Title" }, { "Length", 64 } })
    l:Dock(FILL)
    l.DoDoubleClick = function(_, _, line) send("libadd", { keys = { line.key } }) end
    Menu.lib = l
    sheet:AddSheet("Library", p, "icon16/music.png")
end

function Menu.BuildSettings(sheet)
    local p = vgui.Create("DScrollPanel", sheet)
    local function line(text)
        local lb = vgui.Create("DLabel", p)
        lb:Dock(TOP) lb:DockMargin(8, 8, 8, 0)
        lb:SetFont("BRadioMenuSmall") lb:SetTextColor(SUB)
        lb:SetWrap(true) lb:SetAutoStretchVertical(true)
        lb:SetText(text)
        return lb
    end
    Menu.range = slider(p, "Range (how far it carries)", BRadio.MinRange, BRadio.MaxRange, 0, function(v) send("range", { v = v }) end,
        function(v) local st = station() if st and Menu.canControl then st.range = v end end)
    Menu.range:Dock(TOP) Menu.range:DockMargin(8, 8, 8, 0)
    line("About 50 units is a metre. The default, " .. BRadio.DefaultRange .. ", carries across a big room and fades out down the street.")
    Menu.cLoop = check(p, "Loop the queue (finished songs go back to the end)", function(v) send("loop", { on = v }) end)
    Menu.cLoop:Dock(TOP) Menu.cLoop:DockMargin(8, 12, 8, 0)
    Menu.cShuffle = check(p, "Shuffle", function(v) send("shuffle", { on = v }) end)
    Menu.cShuffle:Dock(TOP) Menu.cShuffle:DockMargin(8, 8, 8, 0)
    Menu.cAuto = check(p, "When the queue runs out, play from the server's library", function(v) send("autoplay", { on = v }) end)
    Menu.cAuto:Dock(TOP) Menu.cAuto:DockMargin(8, 8, 8, 0)
    Menu.cPin = check(p, "Admins: pin this radio here (it stays through rounds, map changes and restarts)", function(v) send("pin", { on = v }) end)
    Menu.cPin:Dock(TOP) Menu.cPin:DockMargin(8, 16, 8, 0)
    Menu.bDelete = button(p, "Remove this radio", function()
        Derma_Query("Remove this radio for good?", "Radio", "Remove", function() send("delete") if IsValid(Menu.frame) then Menu.frame:Remove() end end, "Cancel")
    end, 180)
    Menu.bDelete:Dock(TOP) Menu.bDelete:DockMargin(8, 16, 0, 0)
    Menu.problem = line("")
    Menu.problem:SetTextColor(Color(255, 170, 120))
    line("Your volume for every radio: bradio_volume 0-1 in the console. bradio_enabled 0 turns radios off for you.")
    sheet:AddSheet("Radio", p, "icon16/cog.png")
end

-- --------------------------------------------------------------- refreshing
function Menu.Refresh()
    if not IsValid(Menu.frame) then return end
    local st = station()
    if not st then Menu.frame:Remove() return end
    local ctl, adm, add = Menu.canControl, Menu.isAdmin, Menu.canAdd
    local me = LocalPlayer():SteamID64()
    Menu.bPlay:SetText(st.state == "playing" and "Pause" or "Play")
    Menu.bPlay:SetDisabled(not ctl)
    local mine = st.cur and st.cur.s == me
    Menu.bSkip:SetText((ctl or mine) and "Skip" or "Vote skip")
    Menu.bSkip:SetDisabled(not st.cur)
    Menu.bStop:SetDisabled(not ctl)
    Menu.vol:SetEnabled(ctl)
    setSlider(Menu.vol, math.Round((st.vol or 0) * 100))
    setCheck(Menu.mute, CL.Muted[st.id])
    Menu.bAdd:SetDisabled(not add)
    Menu.bNext:SetDisabled(not ctl)
    Menu.entry:SetEnabled(add)
    Menu.bTop:SetDisabled(not ctl)
    Menu.bClear:SetDisabled(not ctl)
    Menu.bSaveNow:SetVisible(adm)
    Menu.bSaveNow:SetDisabled(not st.cur)
    Menu.bLibAll:SetDisabled(not add)
    Menu.bLibAdd:SetDisabled(not add)
    Menu.bPlLoad:SetDisabled(not add)
    Menu.bPlDel:SetVisible(adm)
    Menu.bPlSave:SetDisabled(not adm)
    Menu.plName:SetEnabled(adm)
    Menu.libAdmin:SetVisible(adm)
    Menu.range:SetEnabled(ctl)
    setSlider(Menu.range, st.range or BRadio.DefaultRange)
    for _, c in ipairs({ { Menu.cLoop, "loop" }, { Menu.cShuffle, "shuffle" }, { Menu.cAuto, "auto" } }) do
        setCheck(c[1], st[c[2]])
        c[1]:SetEnabled(ctl)
    end
    setCheck(Menu.cPin, st.pinned)
    Menu.cPin:SetEnabled(adm)
    Menu.bDelete:SetDisabled(not ctl)

    -- the queue, keeping the selection by key
    local l = Menu.queue
    local sel = {}
    for _, line in ipairs(l:GetSelected()) do sel[line.key] = true end
    local scroll = l.VBar and l.VBar:GetScroll() or 0
    l:Clear()
    for i, t in ipairs(st.q or {}) do
        local line = l:AddLine(i, t.t or t.k, (t.d or 0) > 0 and BRadio.FormatTime(t.d) or "?", t.b or "")
        line.idx, line.key = i, t.k
        if sel[t.k] then line:SetSelected(true) end
        if t.s == me then
            for _, col in ipairs(line.Columns) do col:SetTextColor(Color(30, 70, 140)) end
        end
    end
    if l.VBar then l.VBar:SetScroll(scroll) end
    local mineQueued = false
    for _, t in ipairs(st.q or {}) do if t.s == me then mineQueued = true break end end
    Menu.bRemove:SetDisabled(not (ctl or mineQueued))
end

function Menu.RefreshLibrary()
    if not IsValid(Menu.frame) then return end
    local lib = CL.Library or {}
    local q = string.lower(string.Trim(Menu.search and Menu.search:GetValue() or ""))
    local l = Menu.lib
    l:Clear()
    for _, t in ipairs(lib.tracks or {}) do
        local hay = string.lower((t.album or "") .. " " .. (t.title or ""))
        if q == "" or hay:find(q, 1, true) then
            local line = l:AddLine(t.album or "", t.title or t.key, (t.duration or 0) > 0 and BRadio.FormatTime(t.duration) or "...")
            line.key = t.key
        end
    end
    local pls = Menu.playlists
    pls:Clear()
    for _, p in ipairs(lib.playlists or {}) do
        local line = pls:AddLine(p.name, p.n)
        line.plname = p.name
    end
    if Menu.problem then
        Menu.problem:SetText(lib.problem and ("Relay problem: " .. lib.problem) or "")
    end
    if #(lib.tracks or {}) == 0 then
        Menu.status:SetText(Menu.isAdmin and "The library is empty: import a playlist below, save songs from the queue, or drop files into the relay's library/ folder."
            or "The server's library is empty.")
    end
end

-- --------------------------------------------------------------- events
net.Receive(BRadio.Net.Open, function()
    local id = net.ReadString()
    local canControl, isAdmin, canAdd = net.ReadBool(), net.ReadBool(), net.ReadBool()
    Menu.Open(id, canControl, isAdmin, canAdd)
end)

hook.Add("BRadioState", "bradio_menu", function(id, st)
    if not IsValid(Menu.frame) or id ~= Menu.id then return end
    if not st then Menu.frame:Remove() return end
    -- a pinned radio changes its id when it is pinned; follow it
    Menu.Refresh()
end)

hook.Add("BRadioLibrary", "bradio_menu", function() Menu.RefreshLibrary() end)

hook.Add("BRadioNotice", "bradio_menu", function(msg)
    if IsValid(Menu.frame) and IsValid(Menu.status) then Menu.status:SetText(msg) end
end)

-- close the menu when you walk away
hook.Add("Think", "bradio_menu", function()
    if not IsValid(Menu.frame) then return end
    local st = station()
    local ent = BRadio.EntityFor(st)
    if IsValid(ent) and not Menu.isAdmin and LocalPlayer():GetPos():Distance(ent:GetPos()) > 450 then
        Menu.frame:Remove()
    end
end)
