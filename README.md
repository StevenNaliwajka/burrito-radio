# Burrito Radio

Public: https://github.com/StevenNaliwajka/burrito-radio (developed on GitLab `gmod/gmod-radio`; push both).

*The mod is Burrito's: its name, category (Spawn menu → Burrito), author, entity class
(`burrito_radio`) and convars (`bradio_*`). "Naliwajka" appears only in server addresses
(www.naliwajka.com, gmod.naliwajka.com) and the relay's system paths and service names.*

A Garry's Mod radio you can put anywhere: a **Crosley Cooper** (the blue
CR1121A-EB) that plays **YouTube videos and playlists**, Spotify links (matched to
the same song on YouTube), and the **server owner's preloaded music**. Everyone near it hears it,
positioned in 3D, fading out with distance and muffled behind walls.
That gives you music going off in the distance on gmod.naliwajka.com.

```
 player's game  ──GET https://www.naliwajka.com/radio/a/yt-<id>.mp3──▶ EdgeGate ──▶ relay :8090
       ▲                                                                         ▲
       │ state (net): what plays, since when                                     │ resolve / fetch
 GMod server (addon) ─────────────── http://127.0.0.1:8090/radio ────────────────┘ (yt-dlp + ffmpeg)
```

| Piece | Where | What |
|---|---|---|
| `lua/` | `garrysmod/addons/burrito_radio` | The radio entity, queue, menu, 3D audio, the model |
| `relay/` | `/opt/naliwajka-radio`, systemd `naliwajka-radio` | YouTube → small mono MP3, cached; serves them with Range |

## Using it

* **Spawn** (sandbox / BMX mode): Spawn menu → Entities → Burrito → *Radio (Crosley Cooper)*.
  One per player (`bradio_max_per_player`). Admins in any mode: look at a spot and run
  `bradio_place` in console for a **pinned** radio (stays through rounds, map changes, restarts).
* **Press E on it** for the menu:
  * paste a YouTube **video or playlist** or a **Spotify** song/album/playlist link, or just type a song name (only YouTube and Spotify are accepted);
    **Add** puts it at the end, **Play next** (owner/admins) right after the current song
  * **Queue** tab: remove songs (yours; the owner/admins remove any), move to top, clear
  * **Skip**: the owner, admins and whoever added the song skip at once; anyone else votes,
    and the skip passes at half the players in earshot (`bradio_vote_ratio`)
  * **Pause/Play, Stop, Radio volume**, click the progress bar to seek (owner/admins)
  * **Library** tab: the server's preloaded music and saved playlists; queue some or all
  * **Radio** tab: range, loop, shuffle, autoplay-from-library, pin (admins), remove
  * **Mute for me** silences that radio for just you
* Your own volume for all radios: `bradio_volume 0-1`; off: `bradio_enabled 0`.

## Preloading music (server owner)

Three ways, all end up in the relay's **library** (pinned on disk, never evicted, and what
**autoplay** picks from when a radio's queue runs out, so a pinned radio plays all day):

1. **Import a YouTube playlist** in the menu (Library tab, admins) — every song is downloaded.
2. **Save playing song to library** (Queue tab, admins) — keep a song someone queued.
3. **Drop files** (mp3, ogg, m4a, flac, wav, opus…) into `/var/lib/naliwajka-radio/library/`
   on the server (subfolders become the album), then **Rescan files** in the menu.

**Saved playlists**: admins save the current queue under a name (Library tab); anyone can
queue a saved playlist. Stored in `garrysmod/data/burrito_radio/playlists.json`.
Pinned radios and their queues: `data/burrito_radio/maps/<map>.json`.

## Server settings (server.cfg / rcon)

| Convar | Default | |
|---|---|---|
| `bradio_relay_url` | `http://127.0.0.1:8090/radio` | where the server reaches the relay |
| `bradio_public_url` | `https://www.naliwajka.com/radio` | where players' games download the audio |
| `bradio_relay_key` | *(empty)* | the relay's `RADIO_KEY`, only when it runs on another box |
| `bradio_add` | `0` | `1` = only the radio's owner and admins may queue |
| `bradio_user_tracks` | `25` | most songs one player may have queued on a radio |
| `bradio_max_queue` | `300` | queue length cap |
| `bradio_spawn` | `0` | `1` = only admins spawn radios |
| `bradio_max_per_player` | `1` | radios one player may have out |
| `bradio_vote_ratio` | `0.5` | share of listeners needed to vote-skip |

On a game server that is NOT the relay's box (the BMX test server), put the settings in
`garrysmod/cfg/burrito_radio.cfg`; the addon runs it at load:

    bradio_relay_url "http://10.9.1.13:8090/radio"
    bradio_relay_key "<RADIO_KEY from /etc/naliwajka-radio/relay.env on 10.9.1.13>"

Admin console: `bradio_status`, `bradio_place [0]`, `bradio_play "<link or words>" [stationId]`.
"Admin" is the CAMI privilege `bradio_admin` (ULX: admin and up), else `IsAdmin()`.

**`-allowlocalhttp`**: GMod refuses `HTTP()` to 127.0.0.1 and private addresses unless srcds
is started with it. Petopia's `bin/ttt-server` passes it. Without it the menu says the
relay is not answering, and `bradio_status` shows why.

## The relay

`relay/radio_relay.py`: Python stdlib, `yt-dlp` (+ `deno`, its JavaScript runtime for
YouTube) and `ffmpeg`. Public half: `GET /radio/a/<key>.mp3` (only files already on disk;
nobody on the internet can make it download anything) and `/radio/health`. Control half
(resolve, fetch, library): from 127.0.0.1, or with `X-Radio-Key`. Tracks are mono 96 kbps
MP3 (positional audio is mono anyway), about 0.7 MB a minute; the cache is capped at
`RADIO_CACHE_MB` (least recently used first, library never). Max track length 3 h.
yt-dlp updates itself daily (`naliwajka-radio-update.timer`), because YouTube breaks old
versions every few weeks.

Settings: `/etc/naliwajka-radio/relay.env`. Logs: `journalctl -u naliwajka-radio`.

## Security

* **Only YouTube and Spotify.** Players can paste YouTube videos/playlists or Spotify
  songs/albums/playlists, or type words (a YouTube search). Anything else (a direct
  file link, another site, an internal address, `file://`) is refused, so a player
  can never make the server fetch a URL of their choosing. Spotify audio is DRM'd,
  so a Spotify link plays the same song's YouTube upload (first search hit).
* **The tools are fenced in.** Every URL handed to yt-dlp is built by the relay from a
  validated id; yt-dlp may only use its YouTube extractors and loads no config or
  plugins; typed words can never become options. ffmpeg may only open the local file
  yt-dlp wrote and re-encodes it into a fresh MP3 (no metadata, no attachments), so
  players only ever download a plain MP3 the relay made, never a file from the web.
* **The relay is boxed in** (systemd): its own user, no capabilities, read-only system
  except its data folder, no devices, IP sockets only, and a network allowlist: it can
  reach the internet but no internal address except loopback, its DNS, and
  `RADIO_TRUSTED_IPS` (the reverse proxy and other game servers).
* **The public side serves files only**: `/radio/a/<key>.mp3` for songs already on
  disk, `/radio/health`. Lookups and downloads need the game server's own box or
  `X-Radio-Key` (compared in constant time). Long requests, other HTTP methods, too
  many connections and too many lookups at once are refused; slow clients time out.
* **In game**: every menu command is checked on the server (permissions, distance,
  per-player rate limits, a hard queue cap, malformed messages dropped).
* **Cache**: songs nobody has used for 30 minutes are deleted (`RADIO_CACHE_TTL`); a
  song still playing is kept alive by the game server. The owner's library stays.

## The model

There is no `.mdl`. The radio is built from Lua at load (`sh_model.lua`): a rounded case,
the perforated grille, the brass-lettered CROSLEY badge, the display, the four buttons,
the ridged knob with its brass cap, the telescopic antenna and feet. Measured off the
product photos, 5.25 x 3.25 x 3.25 inches, drawn at 2.5x (`BRadio.Scale`). Textures are
draw-ops run into render targets, so the addon ships no content files and players
download nothing but Lua. The display is live: the song's time in blue LED digits with the
title scrolling under it, or a clock when it is idle.

Preview without the game (what `docs/preview.png` is):

    docker run --rm -v "$PWD:/w:ro" -w /w nickblah/lua:5.1-luarocks-alpine lua tools/preview/export.lua > /tmp/model.json
    python3 tools/preview/render.py /tmp/model.json /tmp/radio-preview

## Deploying

    tests/run.sh                         # offline: everything below (needs Lua 5.1 or Docker)
    # tests/FEATURES.txt lists every feature and the test that proves it;
    # tests/test_features.py fails when a feature has no test or a test no feature.
    LIVE_HOST=10.9.1.13 LIVE_PORT=27015 RCON_PASSWORD=... python3 -m unittest tests/test_live.py
                                         # on a real server: plays a real YouTube song
    RCON_PASSWORD=... tools/hotload.py <host> <port>   # reload a running server + its players
    tools/deploy.sh 10.9.1.13            # relay + addon to Petopia (gmod.naliwajka.com)
    tools/deploy.sh 10.9.1.13 --addon    # Lua only (autorefresh picks it up live)

The first install of the addon needs a server restart to mount the folder. EdgeGate routes
`naliwajka.com/radio` to `10.9.1.13:8090` (MGMT `Config/edgegate.json`).
