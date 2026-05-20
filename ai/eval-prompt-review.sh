#!/usr/bin/env bash
set -euo pipefail

MARKER=${1:-}
OUT=${OUT:-/tmp/alttab-focus-llm-review-${MARKER:-manual}-$(date +%Y%m%d-%H%M%S).md}
LOG=${LOG:-/tmp/alttab-run.log}
shift || true
ARTIFACTS=("$@")

if [ -z "$MARKER" ]; then
  echo "usage: $0 MARKER [artifact ...]" >&2
  exit 2
fi

python3 - "$LOG" "$MARKER" "$OUT" "${ARTIFACTS[@]}" <<'PY'
import sys
from pathlib import Path
log, marker, out = sys.argv[1:4]
artifacts = sys.argv[4:]
text = Path(log).read_bytes().decode('utf-8', 'replace') if Path(log).exists() else ''
lines = text.splitlines()
idxs = [i for i, line in enumerate(lines) if marker in line]
excerpt = lines[idxs[-1] + 1:] if idxs else lines[-400:]
excerpt = excerpt[-500:]
template = Path('ai/prompts/focus-log-review.md').read_text()
parts = [template, '\n# Run Context\n', f'- Marker: `{marker}`\n', f'- Log: `{log}`\n']
if artifacts:
    parts.append('- Artifacts:\n')
    for artifact in artifacts:
        parts.append(f'  - `{artifact}`\n')
parts.append('\n# Log Excerpt\n\n```text\n')
parts.append('\n'.join(excerpt))
parts.append('\n```\n')
for artifact in artifacts:
    path = Path(artifact)
    if path.exists() and path.is_file():
        data = path.read_text(errors='replace')
        parts.append(f'\n# Artifact `{artifact}`\n\n```text\n{data[-12000:]}\n```\n')
Path(out).write_text(''.join(parts))
print(out)
PY
