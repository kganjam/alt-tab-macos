#!/bin/bash
# ws-mem-watch.sh — one line per run logging WindowServer / replayd / AltTab
# memory + AltTab's cumulative capture counters, to diagnose whether AltTab's
# SCK thumbnail captures drive WindowServer memory growth.
#
# Background: 2026-06-15 ~10:01 the GUI froze ~5 min — WindowServer had bloated
# to 30 GB and its main thread spun in SkyLight until the userspace watchdog
# killed it (a HANG, not the IOSurface-tally abort). replayd crashed in the SCK
# screenshot path (SLContentStream createScreenshot) AltTab now drives. AltTab's
# own process was clean (liveSurfaces=0) so this is server-side accumulation.
# Watch whether WS_rss climbs unboundedly toward tens of GB and whether it
# tracks AltTab's sckCaptures rate. Run via the com.kganjam.ws-mem-watch
# LaunchAgent (every 5 min). Inspect: tail -f /tmp/ws-mem-watch.log
OUT=/tmp/ws-mem-watch.log
ts=$(date '+%Y-%m-%d %H:%M:%S')
rss() { ps -o rss= -p "${1:-0}" 2>/dev/null | tr -d ' '; }
wspid=$(pgrep -x WindowServer | head -1)
rppid=$(pgrep -x replayd | head -1)
atpid=$(pgrep -f 'AltTab\.app/Contents/MacOS/AltTab' | head -1)
log=$(readlink /tmp/alttab/latest.log 2>/dev/null)
counters=$(grep -a 'THUMBCACHE' "$log" 2>/dev/null | tail -1 \
  | grep -oE 'liveSurfaces=[0-9]+|cgsCaptures=[0-9]+|sckCaptures=[0-9]+|inFlight=[0-9]+|timingOut=[0-9]+|quarantined=[0-9]+|captureLatencyMs=[0-9]+|expired=[0-9]+|recentExpiries=[0-9]+' | tr '\n' ' ')
printf '%s WS=%dMB(pid %s,up %s) replayd=%dMB AltTab=%dMB(pid %s) %s\n' \
  "$ts" "$(( $(rss "$wspid")/1024 ))" "${wspid:-?}" "$(ps -o etime= -p "${wspid:-0}" 2>/dev/null | tr -d ' ')" \
  "$(( $(rss "$rppid")/1024 ))" "$(( $(rss "$atpid")/1024 ))" "${atpid:-?}" "$counters" >> "$OUT"
