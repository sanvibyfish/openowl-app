#!/bin/bash
# Re-apply local fixes to SPM checkouts (run after package resolve / clean).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Patch EVERY checkout that could feed a build, not just the first hit. Xcode
# GUI builds use the default DerivedData while xcodebuild may use the in-repo
# one; patching a single match is how this fix silently missed GUI builds and
# left the soft-wrap redraw bug live for anyone hitting Cmd+R.
TARGETS=()
IN_REPO="$ROOT/build/DerivedData/SourcePackages/checkouts/CodeEditTextView/Sources/CodeEditTextView/TextLine/Typesetter/Typesetter.swift"
if [ -f "$IN_REPO" ]; then
  TARGETS+=("$IN_REPO")
fi
while IFS= read -r found; do
  if [ -n "$found" ]; then
    TARGETS+=("$found")
  fi
done < <(find "$HOME/Library/Developer/Xcode/DerivedData" \
  -path "*/SourcePackages/checkouts/CodeEditTextView/*/Typesetter/Typesetter.swift" \
  2>/dev/null || true)

if [ ${#TARGETS[@]} -eq 0 ]; then
  echo "[patch] no CodeEditTextView checkout found — resolve packages first" >&2
  exit 1
fi

for TARGET in "${TARGETS[@]}"; do
if grep -q "ABSOLUTE end index" "$TARGET"; then
  echo "[patch] already applied: $TARGET"
  continue
fi
chmod u+w "$TARGET"
python3 - "$TARGET" << 'PY'
import re, sys
from pathlib import Path
path = Path(sys.argv[1])
text = path.read_text()
new = '''let substring = string.attributedSubstring(from: range)

        // Layout as many fragments as possible in this content run
        while context.currentPosition < range.max {
            let relativeStart = context.currentPosition - range.location
            let remaining = range.length - relativeStart
            guard remaining > 0 else { break }

            let availableWidth = displayData.maxWidth - context.fragmentContext.width
            if availableWidth <= 0 {
                context.popCurrentData()
                continue
            }

            // suggestLineBreak returns an ABSOLUTE end index in `substring`
            // (typesetter string), not a length. Using it as NSRange.length made
            // every fragment after the first typeset from the wrong range — soft
            // wrap could re-draw earlier characters (e.g. "...AppKi" + "AppKit...").
            let breakEnd = typesetter.suggestLineBreak(
                using: substring,
                strategy: displayData.breakStrategy,
                subrange: NSRange(location: relativeStart, length: remaining),
                constrainingWidth: availableWidth
            )
            let breakLength = max(0, breakEnd - relativeStart)
            let fragmentLength = max(breakLength, 1)
            let typesetSubrange = NSRange(location: relativeStart, length: fragmentLength)
            let typesetData = typesetLine(typesetter: typesetter, range: typesetSubrange)

            if fragmentLength == 1
                && context.fragmentContext.width > 0
                && context.fragmentContext.width + typesetData.width > displayData.maxWidth {
                context.popCurrentData()
                continue
            }

            let absoluteEndInSubstring = relativeStart + fragmentLength
            context.appendText(
                typesettingRange: range,
                lineBreak: absoluteEndInSubstring,
                typesetData: typesetData
            )

            if context.currentPosition != range.max {
                context.popCurrentData()
            }
        }
    }'''
pat = re.compile(
    r"let substring = string\.attributedSubstring\(from: range\)\n\n"
    r"        // Layout as many fragments as possible in this content run\n"
    r"        while context\.currentPosition < range\.max \{.*?"
    r"if context\.currentPosition != range\.max \{\n"
    r"                context\.popCurrentData\(\)\n"
    r"            \}\n"
    r"        \}\n"
    r"    \}",
    re.S,
)
m = pat.search(text)
if not m:
    print("[patch] pattern not found — Typesetter.swift may have changed upstream")
    sys.exit(1)
path.write_text(text[:m.start()] + new + text[m.end():])
print(f"[patch] applied wrap-range fix to {path}")
PY
done
