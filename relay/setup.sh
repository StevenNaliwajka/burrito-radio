#!/usr/bin/env bash
# Install (or update) the radio relay on a Debian box, usually the GMod server itself.
# Idempotent. Run as root from a copy of this folder:
#     ./setup.sh                 install/update, start, check /radio/health
# Settings live in /etc/naliwajka-radio/relay.env (written once, never overwritten).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP=/opt/naliwajka-radio
DATA=/var/lib/naliwajka-radio
ETC=/etc/naliwajka-radio
say() { echo "== $*"; }

say "packages"
need=()
for p in python3 ffmpeg curl ca-certificates; do dpkg -s "$p" >/dev/null 2>&1 || need+=("$p"); done
if [ ${#need[@]} -gt 0 ]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends "${need[@]}" >/dev/null
fi

say "user and folders"
id radio >/dev/null 2>&1 || useradd --system --home-dir "$DATA" --shell /usr/sbin/nologin radio
install -d -m 0755 "$APP" "$APP/bin"
install -d -o radio -g radio -m 0755 "$DATA" "$DATA/cache"
# the library is where the owner drops music: group-writable for the admins' group
install -d -o radio -g radio -m 0775 "$DATA/library"
install -d -m 0750 -g radio "$ETC"

say "code"
install -m 0644 "$HERE/radio_relay.py" "$APP/radio_relay.py"
install -m 0755 "$HERE/update-tools.sh" "$APP/update-tools.sh"
install -m 0644 "$HERE/naliwajka-radio.service" "$HERE/naliwajka-radio-update.service" \
  "$HERE/naliwajka-radio-update.timer" /etc/systemd/system/

if [ ! -f "$ETC/relay.env" ]; then
  say "config (first install)"
  key="$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 32)"
  cat > "$ETC/relay.env" <<CONF
# Naliwajka Radio relay. Restart after editing: systemctl restart naliwajka-radio
RADIO_LISTEN=0.0.0.0:8090
RADIO_PREFIX=/radio
RADIO_DATA=$DATA
# A game server on ANOTHER box sends this as X-Radio-Key (its nradio_relay_key).
# The server on this box talks over 127.0.0.1 and needs no key.
RADIO_KEY=$key
RADIO_MAX_SECONDS=10800
RADIO_CACHE_MB=6000
RADIO_BITRATE=96k
RADIO_WORKERS=2
CONF
  chmod 0640 "$ETC/relay.env"
  chgrp radio "$ETC/relay.env"
fi

say "yt-dlp + deno"
if [ ! -x "$APP/bin/yt-dlp" ] || [ ! -x "$APP/bin/deno" ]; then "$APP/update-tools.sh"; fi

systemctl daemon-reload
systemctl enable --now naliwajka-radio-update.timer >/dev/null
systemctl enable naliwajka-radio >/dev/null
systemctl restart naliwajka-radio

say "health"
for _ in $(seq 1 20); do
  if curl -fsS -m 3 http://127.0.0.1:8090/radio/health; then echo; exit 0; fi
  python3 -c 'import time; time.sleep(0.5)'
done
echo "relay did not answer on :8090" >&2
journalctl -u naliwajka-radio -n 30 --no-pager >&2
exit 1
