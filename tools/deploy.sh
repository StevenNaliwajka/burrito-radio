#!/usr/bin/env bash
# Deploy the radio to a GMod box over ssh (root): the relay service and the addon.
#
#   tools/deploy.sh gmod.lan              both (relay first)
#   tools/deploy.sh 10.9.1.13 --addon     just the Lua addon
#   tools/deploy.sh 10.9.1.13 --relay     just the relay
#
# The addon goes to /opt/gmod/garrysmod/addons/burrito_radio from `git archive`
# of REF (default HEAD, so commit first), staged OUTSIDE addons/ and swapped in
# with one rename. A Lua change on a running server is picked up by GMod's
# autorefresh; a FIRST install needs a server restart or map change to mount the
# folder. This script never restarts the game server.
set -euo pipefail
HOST="${1:?usage: tools/deploy.sh <host> [--addon|--relay]}"
WHAT="${2:-all}"
REF="${REF:-HEAD}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GM="${GM:-/opt/gmod/garrysmod}"
SSH=(ssh -o ConnectTimeout=10 "root@$HOST")

if [ "$WHAT" = all ] || [ "$WHAT" = --relay ]; then
  echo "== relay -> $HOST"
  tar -C "$ROOT" -czf - relay | "${SSH[@]}" 'set -e; rm -rf /root/naliwajka-radio-src; mkdir -p /root/naliwajka-radio-src; tar -xzf - -C /root/naliwajka-radio-src; /root/naliwajka-radio-src/relay/setup.sh'
fi

if [ "$WHAT" = all ] || [ "$WHAT" = --addon ]; then
  sha="$(git -C "$ROOT" rev-parse --short "$REF")"
  echo "== addon $sha -> $HOST:$GM/addons/burrito_radio"
  git -C "$ROOT" archive "$REF" lua addon.json | "${SSH[@]}" "set -e
    stage=$GM/../.burrito_radio.stage
    rm -rf \"\$stage\"; mkdir -p \"\$stage\"
    tar -xf - -C \"\$stage\"
    echo $sha > \"\$stage/.deployed-sha\"
    chown -R gmod:gmod \"\$stage\"
    old=$GM/../.burrito_radio.old
    rm -rf \"\$old\"
    [ -d $GM/addons/burrito_radio ] && mv $GM/addons/burrito_radio \"\$old\"
    mv \"\$stage\" $GM/addons/burrito_radio
    rm -rf \"\$old\"
    # the addon was called naliwajka_radio before it became Burrito's
    rm -rf $GM/addons/naliwajka_radio
    echo deployed \$(cat $GM/addons/burrito_radio/.deployed-sha)"
fi
