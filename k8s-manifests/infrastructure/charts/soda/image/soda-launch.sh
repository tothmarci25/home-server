#!/bin/bash
# Auto-launch SODA Off-Road Racing in kiosk mode.
#
# Invoked by Selkies' SELKIES_RUN_AFTER_CONNECT hook (set in the StatefulSet),
# which fires after a client connects — NOT by XDG autostart. We run with the
# LXQt desktop dropped (START_LXQT=false), so there is no panel/terminal/file
# manager behind the game; the display server + Selkies are already up when this
# runs (so $DISPLAY should be set, but we still wait for it defensively below).
#
# RUN_AFTER_CONNECT re-runs each time a client connects while no others are
# connected, so this script can be invoked more than once per pod life — it is
# made idempotent below (a second connect must not spawn a second game).
#
# SODA is a 1997 title with a hard internal 640x480 cap, so we:
#   1. pin the Selkies desktop to 640x480 (resize is disabled via
#      SELKIES_ENABLE_RESIZE=false in the StatefulSet, so this stays put and the
#      single game window fills the browser instead of sitting tiny on a huge
#      desktop) — the browser upscales 640x480 to the viewport;
#   2. launch the game in a matching Wine virtual desktop so DirectDraw can set
#      its mode inside a window ("Can't open display mode" otherwise).
#
# Game files + Wine prefix live on the per-pod PVC at /home/ubuntu/soda (HOME
# itself is ephemeral — only this path persists).
set -u

# Idempotency: RUN_AFTER_CONNECT can fire again on reconnect. If the game is
# already running, re-pin the resolution (cheap, harmless) and bail so we never
# stack a second offroad.exe.
if pgrep -f "offroad.exe" >/dev/null 2>&1; then
  selkies-resize 640x480 || true
  exit 0
fi

GAME_DIR="/home/ubuntu/soda/game/soda_off_road_racing"
export WINEPREFIX="/home/ubuntu/soda/prefix"
export WINEARCH="win32"
# .cache under HOME is root-owned (ephemeral layer) → "Permission denied" and
# Mesa disables its shader cache. Point it at the writable PVC instead.
export MESA_SHADER_CACHE_DIR="/home/ubuntu/soda/.cache/mesa"
export XDG_CACHE_HOME="/home/ubuntu/soda/.cache"
mkdir -p "${MESA_SHADER_CACHE_DIR}"

# Wait for the X display the session set up (autostart can fire a touch early).
for _ in $(seq 1 60); do
  [ -n "${DISPLAY:-}" ] && xdpyinfo >/dev/null 2>&1 && break
  sleep 0.5
done

# Pin the stream to the game's native size (resize disabled in the StatefulSet).
selkies-resize 640x480 || true

# First boot on a fresh PVC: build the 32-bit Wine prefix once.
if [ ! -d "${WINEPREFIX}/drive_c" ]; then
  wineboot --init
  wineserver -w 2>/dev/null || true
fi

cd "${GAME_DIR}" || exit 0
# Virtual desktop matched to the game's resolution → fills the 640x480 stream.
exec wine explorer /desktop=soda,640x480 offroad.exe
