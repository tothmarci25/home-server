#!/bin/bash
# Auto-launch SODA Off-Road Racing inside the Selkies desktop.
#
# Started by the XDG autostart entry (/etc/xdg/autostart/soda.desktop) once the
# LXQt session is up, so $DISPLAY is set and the compositor is running.
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
