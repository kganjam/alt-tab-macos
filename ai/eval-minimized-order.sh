#!/usr/bin/env bash
set -euo pipefail

APP=${ALTTAB_APP:-/Applications/AltTab.app/Contents/MacOS/AltTab}
PROFILES=${PROFILES:-"0 1"}
if [ -z "${ALTTAB_DYLIB_OVERRIDE:-}" ] && [ -f "$(pwd)/dev/AltTabCore.dylib" ]; then
  export ALTTAB_DYLIB_OVERRIDE="$(pwd)/dev/AltTabCore.dylib"
fi

alttab() {
  local output status
  set +e
  output=$("$APP" "$@" 2>&1)
  status=$?
  set -e
  printf '%s\n' "$output" | sed -n '/^[[:space:]]*[{[]/,$p'
  return "$status"
}

for profile in $PROFILES; do
  alttab --show="$profile" >/dev/null
  sleep 0.2
  state="$(alttab --selection-state)"
  alttab --hide >/dev/null || true
  jq -e --argjson profile "$profile" '
    .windows
    | map(select(.isDisplayable))
    | . as $windows
    | ($windows | map(select(.isMinimized)) | length) as $minimizedCount
    | ($windows | map(.isMinimized)) as $flags
    | ($flags | index(true)) as $firstMinimized
    | ($flags | rindex(false)) as $lastNonMinimized
    | if $minimizedCount == 0 then
        {profile: $profile, status: "skip-no-minimized-displayable", displayable: ($windows | length), minimized: 0}
      elif ($firstMinimized != null and $lastNonMinimized != null and $firstMinimized < $lastNonMinimized) then
        error("profile=\($profile) minimized window appears before non-minimized window")
      else
        {profile: $profile, status: "pass", displayable: ($windows | length), minimized: $minimizedCount, firstMinimized: $firstMinimized}
      end
  ' <<<"$state"
done
