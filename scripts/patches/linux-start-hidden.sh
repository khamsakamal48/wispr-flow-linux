#!/usr/bin/env bash
#===============================================================================
# linux-start-hidden.sh -- let `--hidden` skip the hub window at launch on
# Linux, in the Wispr Flow main bundle (.webpack/main/index.js).
#
# WHY: the launch-visibility check hides the hub only when
# app.getLoginItemSettings().wasOpenedAtLogin is true (macOS only) or when
# "launch at login" is on under a win32-only flag. On Linux the hub therefore
# opens on every launch, including autostart. With this patch an autostart
# entry can run `WisprFlow.AppImage --hidden` and the app starts in the tray;
# a plain launch still shows the hub. The launcher forwards "$@" to Electron.
#
# THE PATCH: anchored on the stable log string next to the check,
#   <r>.app.getLoginItemSettings().wasOpenedAtLogin?(<log>().info("Not showing
#   hub window at launch: app was opened at login")
# the condition is widened to
#   (process.argv.includes("--hidden")||<r>.app.getLoginItemSettings().wasOpenedAtLogin)
# mac/win32 behave the same unless they are also passed --hidden.
#
# Usage: linux-start-hidden.sh <path-to-.webpack/main/index.js>
#===============================================================================
set -euo pipefail

BUNDLE="${1:-}"
if [[ -z "$BUNDLE" || ! -f "$BUNDLE" ]]; then
	echo "usage: $0 <.webpack/main/index.js>" >&2
	exit 2
fi

MARKER="WISPR_LINUX_START_HIDDEN"

if grep -qF "$MARKER" "$BUNDLE"; then
	echo "Already patched ($MARKER present in $BUNDLE) - nothing to do."
	exit 0
fi

python3 - "$BUNDLE" "$MARKER" <<'PY'
import io, re, shutil, sys

path, marker = sys.argv[1], sys.argv[2]
with io.open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
	src = f.read()

anchor = re.compile(
	r'(?P<cond>[\w$]+\.app\.getLoginItemSettings\(\)\.wasOpenedAtLogin)\?'
	r'(?P<tail>\([\w$]+\(\)\.info\("Not showing hub window at launch: app was opened at login"\))'
)
matches = list(anchor.finditer(src))
if len(matches) != 1:
	sys.exit(
		f"ERROR: expected exactly 1 wasOpenedAtLogin launch check, found "
		f"{len(matches)}. Re-audit the 'Not showing hub window at launch' site."
	)

shutil.copyfile(path, path + ".starthidden.orig")
print("Backup written:", path + ".starthidden.orig")

patched = anchor.sub(
	lambda m: '(/*' + marker + '*/process.argv.includes("--hidden")||'
	+ m.group("cond") + ')?' + m.group("tail"),
	src, count=1,
)
with io.open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
	f.write(patched)
print("Patched: --hidden now skips the hub window at launch.")
PY

if ! grep -qF "$MARKER" "$BUNDLE"; then
	echo "ERROR: post-patch verification failed (marker not found). Restoring backup." >&2
	cp -p "$BUNDLE.starthidden.orig" "$BUNDLE"
	exit 1
fi

if command -v node >/dev/null; then
	if ! node --check "$BUNDLE"; then
		echo "ERROR: node --check failed on patched bundle. Restoring backup." >&2
		cp -p "$BUNDLE.starthidden.orig" "$BUNDLE"
		exit 1
	fi
	echo "node --check OK"
fi
echo "OK: --hidden launch supported in $BUNDLE"
