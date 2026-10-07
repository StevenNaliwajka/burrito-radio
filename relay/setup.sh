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
# Burrito Radio relay. Restart after editing: systemctl restart naliwajka-radio
RADIO_LISTEN=0.0.0.0:8090
RADIO_PREFIX=/radio
RADIO_DATA=$DATA
# A game server on ANOTHER box sends this as X-Radio-Key (its bradio_relay_key).
# The server on this box talks over 127.0.0.1 and needs no key.
RADIO_KEY=$key
RADIO_MAX_SECONDS=10800
RADIO_CACHE_MB=6000
RADIO_BITRATE=96k
RADIO_WORKERS=2
RADIO_CACHE_TTL=1800
# Internal addresses (besides this box, loopback and its DNS) the relay may talk to:
# the reverse proxy in front of it and any OTHER game server using it. Every other
# private network is blocked, so a hostile download cannot reach the LAN.
RADIO_TRUSTED_IPS=
CONF
  chmod 0640 "$ETC/relay.env"
  chgrp radio "$ETC/relay.env"
fi

# settings added in later versions, for a relay.env written by an older one
grep -q '^RADIO_CACHE_TTL=' "$ETC/relay.env" || echo 'RADIO_CACHE_TTL=1800' >> "$ETC/relay.env"
grep -q '^RADIO_TRUSTED_IPS=' "$ETC/relay.env" || echo 'RADIO_TRUSTED_IPS=' >> "$ETC/relay.env"

say "network allowlist"
trusted="$(sed -n 's/^RADIO_TRUSTED_IPS=//p' "$ETC/relay.env" | tr -d '"')"
dns="$(awk '/^nameserver/{print $2}' /etc/resolv.conf | tr '\n' ' ')"
self="$(hostname -I 2>/dev/null)"
install -d -m 0755 /etc/systemd/system/naliwajka-radio.service.d
cat > /etc/systemd/system/naliwajka-radio.service.d/network.conf <<NET
# Written by relay/setup.sh. The relay may reach the internet (YouTube, Spotify) and
# only these internal addresses: loopback, this box, its DNS, RADIO_TRUSTED_IPS.
[Service]
IPAddressDeny=10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 100.64.0.0/10 fc00::/7 fe80::/10
IPAddressAllow=localhost $self $dns $trusted
NET
cat /etc/systemd/system/naliwajka-radio.service.d/network.conf | tail -1

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
