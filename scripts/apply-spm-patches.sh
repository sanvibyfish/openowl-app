#!/bin/bash
# Re-apply local fixes to SPM checkouts (run after package resolve / clean).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$ROOT/build/DerivedData/SourcePackages/checkouts/CodeEditTextView/Sources/CodeEditTextView/TextLine/Typesetter/Typesetter.swift"
# Also try default DerivedData location
if [ ! -f "$TARGET" ]; then
  TARGET=$(find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/SourcePackages/checkouts/CodeEditTextView/*/Typesetter.swift" 2>/dev/null | head -1 || true)
fi
if [ -z "${TARGET:-}" ] || [ ! -f "$TARGET" ]; then
  echo "[patch] CodeEditTextView Typesetter.swift not found — resolve packages first"
  exit 0
fi
if grep -q "ABSOLUTE end index" "$TARGET" 2>/dev/null; then
  echo "[patch] Typesetter wrap-range fix already applied"
  exit 0
fi
chmod u+w "$TARGET" || true
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
