--[[--------------------------------------------------------------------------
    naliwajka_radio/sv_relay.lua  -- the server's side of relay/radio_relay.py

    The relay runs next to the game server and answers on two addresses:
      nradio_relay_url   what THIS server calls (resolve, fetch, library);
                         default http://127.0.0.1:8090/radio
      nradio_public_url  what PLAYERS' games download the MP3s from;
                         default https://www.naliwajka.com/radio

    GMod refuses HTTP() to 127.0.0.1 and private addresses unless srcds was
    started with -allowlocalhttp. Without it every request fails with
    "invalid url"; NRadio.Relay.Problem says so in the menu.

    When the relay is on another box, set nradio_relay_key to its RADIO_KEY.
----------------------------------------------------------------------------]]

NRadio.Relay = NRadio.Relay or {}
local R = NRadio.Relay

local cvRelay = CreateConVar("nradio_relay_url", "http://127.0.0.1:8090/radio", FCVAR_ARCHIVE,
    "Radio: where the server reaches the relay")
local cvPublic = CreateConVar("nradio_public_url", "https://www.naliwajka.com/radio", FCVAR_ARCHIVE,
    "Radio: where players download the audio from")
local cvKey = CreateConVar("nradio_relay_key", "", bit.bor(FCVAR_ARCHIVE, FCVAR_PROTECTED, FCVAR_DONTRECORD),
    "Radio: the relay's RADIO_KEY (only when it is on another box)")

R.Problem = nil   -- the last connection failure, shown to admins in the menu

function R.PublicURL() return (cvPublic:GetString():gsub("/+$", "")) end

local function urlencode(s)
    return (tostring(s):gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", string.byte(c)) end))
end
R.URLEncode = urlencode

-- GET <relay><path>?<query>; cb(ok, tableOrError)
function R.Get(path, query, cb)
    local parts = {}
    for k, v in pairs(query or {}) do parts[#parts + 1] = k .. "=" .. urlencode(v) end
    table.sort(parts)
    local url = cvRelay:GetString():gsub("/+$", "") .. path .. (#parts > 0 and ("?" .. table.concat(parts, "&")) or "")
    local headers = {}
    if cvKey:GetString() ~= "" then headers["X-Radio-Key"] = cvKey:GetString() end
    local ok = HTTP({
        url = url, method = "GET", headers = headers, timeout = 120,
        success = function(code, body)
            local t = util.JSONToTable(body or "") or {}
            if code == 200 then
                R.Problem = nil
                cb(true, t)
            elseif code == 403 then
                R.Problem = "the relay refused this server (set nradio_relay_key)"
                cb(false, R.Problem)
            else
                cb(false, t.error or ("relay HTTP " .. tostring(code)))
            end
        end,
        failed = function(reason)
            R.Problem = "can't reach the relay at " .. cvRelay:GetString() .. " (" .. tostring(reason) .. ")"
            if tostring(reason):find("invalid url", 1, true) then
                R.Problem = R.Problem .. "; a local relay needs srcds started with -allowlocalhttp"
            end
            cb(false, "the radio service is not answering")
        end,
    })
    if ok == false then cb(false, "the radio service is not answering") end
end

function R.Resolve(q, cb) R.Get("/resolve", { q = q }, cb) end
function R.Fetch(key, cb) R.Get("/fetch", { key = key }, cb) end
function R.Library(cb) R.Get("/library", nil, cb) end
function R.Save(key, cb) R.Get("/library/save", { key = key }, cb) end
function R.Unsave(key, cb) R.Get("/library/remove", { key = key }, cb) end
function R.Rescan(cb) R.Get("/library/rescan", nil, cb) end
