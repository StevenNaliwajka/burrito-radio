# gmod-radio: Naliwajka Radio

A Garry's Mod radio you can put anywhere: a **Crosley Cooper** (the blue
CR1121A-EB) that plays **YouTube videos and playlists**, direct `.mp3/.ogg`
links, and the **server owner's preloaded music**. Everyone near it hears it,
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
| `lua/` | `garrysmod/addons/naliwajka_radio` | The radio entity, queue, menu, 3D audio, the model |
| `relay/` | `/opt/naliwajka-radio`, systemd `naliwajka-radio` | YouTube → small mono MP3, cached; serves them with Range |

## Using it

* **Spawn** (sandbox / BMX mode): Spawn menu → Entities → Naliwajka → *Radio (Crosley Cooper)*.
  One per player (`nradio_max_per_player`). Admins in any mode: look at a spot and run
  `nradio_place` in console for a **pinned** radio (stays through rounds, map changes, restarts).
* **Press E on it** for the menu:
  * paste a YouTube **video or playlist** link, an `.mp3` link, or just type a song name;
    **Add** puts it at the end, **Play next** (owner/admins) right after the current song
  * **Queue** tab: remove songs (yours; the owner/admins remove any), move to top, clear
  * **Skip**: the owner, admins and whoever added the song skip at once; anyone else votes,
    and the skip passes at half the players in earshot (`nradio_vote_ratio`)
  * **Pause/Play, Stop, Radio volume**, click the progress bar to seek (owner/admins)
  * **Library** tab: the server's preloaded music and saved playlists; queue some or all
  * **Radio** tab: range, loop, shuffle, autoplay-from-library, pin (admins), remove
  * **Mute for me** silences that radio for just you
* Your own volume for all radios: `nradio_volume 0-1`; off: `nradio_enabled 0`.

## Preloading music (server owner)

Three ways, all end up in the relay's **library** (pinned on disk, never evicted, and what
**autoplay** picks from when a radio's queue runs out, so a pinned radio plays all day):

1. **Import a YouTube playlist** in the menu (Library tab, admins) — every song is downloaded.
2. **Save playing song to library** (Queue tab, admins) — keep a song someone queued.
3. **Drop files** (mp3, ogg, m4a, flac, wav, opus…) into `/var/lib/naliwajka-radio/library/`
   on the server (subfolders become the album), then **Rescan files** in the menu.

**Saved playlists**: admins save the current queue under a name (Library tab); anyone can
queue a saved playlist. Stored in `garrysmod/data/naliwajka_radio/playlists.json`.
Pinned radios and their queues: `data/naliwajka_radio/maps/<map>.json`.

## Server settings (server.cfg / rcon)

| Convar | Default | |
|---|---|---|
| `nradio_relay_url` | `http://127.0.0.1:8090/radio` | where the server reaches the relay |
| `nradio_public_url` | `https://www.naliwajka.com/radio` | where players' games download the audio |
| `nradio_relay_key` | *(empty)* | the relay's `RADIO_KEY`, only when it runs on another box |
| `nradio_add` | `0` | `1` = only the radio's owner and admins may queue |
| `nradio_user_tracks` | `25` | most songs one player may have queued on a radio |
| `nradio_max_queue` | `300` | queue length cap |
| `nradio_spawn` | `0` | `1` = only admins spawn radios |
| `nradio_max_per_player` | `1` | radios one player may have out |
| `nradio_vote_ratio` | `0.5` | share of listeners needed to vote-skip |

Admin console: `nradio_status`, `nradio_place [0]`, `nradio_play "<link or words>" [stationId]`.
"Admin" is the CAMI privilege `nradio_admin` (ULX: admin and up), else `IsAdmin()`.

**`-allowlocalhttp`**: GMod refuses `HTTP()` to 127.0.0.1 and private addresses unless srcds
is started with it. Petopia's `bin/ttt-server` passes it. Without it the menu says the
relay is not answering, and `nradio_status` shows why.

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

## The model

There is no `.mdl`. The radio is built from Lua at load (`sh_model.lua`): a rounded case,
the perforated grille, the brass-lettered CROSLEY badge, the display, the four buttons,
the ridged knob with its brass cap, the telescopic antenna and feet. Measured off the
product photos, 5.25 x 3.25 x 3.25 inches, drawn at 2.5x (`NRadio.Scale`). Textures are
draw-ops run into render targets, so the addon ships no content files and players
download nothing but Lua. The display is live: the song's time in blue LED digits with the
title scrolling under it, or a clock when it is idle.

Preview without the game (what `docs/preview.png` is):

    docker run --rm -v "$PWD:/w:ro" -w /w nickblah/lua:5.1-luarocks-alpine lua tools/preview/export.lua > /tmp/model.json
    python3 tools/preview/render.py /tmp/model.json /tmp/radio-preview

## Deploying

    tests/run.sh                         # offline: Lua server side, relay, syntax
    tools/deploy.sh 10.9.1.13            # relay + addon to Petopia (gmod.naliwajka.com)
    tools/deploy.sh 10.9.1.13 --addon    # Lua only (autorefresh picks it up live)

The first install of the addon needs a server restart to mount the folder. EdgeGate routes
`naliwajka.com/radio` to `10.9.1.13:8090` (MGMT `Config/edgegate.json`).
