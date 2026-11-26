#!/bin/bash
# Builds WindowStrip.app into ~/Applications, signs it and restarts it.
#   ./build.sh            build, and restart it if its login agent is loaded
#   ./build.sh --install  build, then start it now and at every login
#   ./build.sh --legacy   the first, polling version, kept as a timing baseline
#
# Signing: with an Apple Development certificate in the keychain, the
# Accessibility and browser permissions survive rebuilds. With several, it
# takes the first one `security find-identity -v -p codesigning` lists, and
# SIGN_IDENTITY=<SHA-1 or full name> picks another. Without one it signs ad
# hoc, and macOS treats each rebuild as a new app.
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/WindowStrip.app"
LABEL="dev.windowstrip"
MODE="${1:-}"

[[ $# -le 1 ]] || { echo "usage: ./build.sh [--install | --legacy]" >&2; exit 2; }
case "$MODE" in
  ""|--install|--legacy) ;;
  *) echo "usage: ./build.sh [--install | --legacy]" >&2; exit 2 ;;
esac

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  identities=$(security find-identity -v -p codesigning 2>/dev/null || true)
  SIGN_IDENTITY=$(awk '/"Apple Development/ {print $2; exit}' <<<"$identities")
  if [[ -n "$SIGN_IDENTITY" ]]; then
    echo "signing with the Apple Development certificate whose SHA-1 starts ${SIGN_IDENTITY:0:8}" >&2
  else
    SIGN_IDENTITY="-"
    echo "no Apple Development certificate, signing ad hoc" >&2
  fi
fi

if [[ "$MODE" == "--legacy" ]]; then
  FILES=("$SRC/legacy/main.swift" "$SRC/Sources/Log.swift" "$SRC/Sources/Support.swift")
else
  FILES=("$SRC"/Sources/*.swift "$SRC/Shared/Spaces.swift")
fi

mkdir -p "$APP/Contents/MacOS"
cp "$SRC/Info.plist" "$APP/Contents/Info.plist"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
       -o "$APP/Contents/MacOS/WindowStrip.new" "${FILES[@]}"
mv -f "$APP/Contents/MacOS/WindowStrip.new" "$APP/Contents/MacOS/WindowStrip"
if [[ "$MODE" != "--legacy" ]]; then
  # The window-list helper (Helper/main.swift), signed before the bundle.
  swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
         -o "$APP/Contents/MacOS/wslist.new" "$SRC/Helper/main.swift" "$SRC/Shared/Spaces.swift"
  mv -f "$APP/Contents/MacOS/wslist.new" "$APP/Contents/MacOS/wslist"
  codesign --force --sign "$SIGN_IDENTITY" --identifier "$LABEL.wslist" "$APP/Contents/MacOS/wslist"
fi
codesign --force --sign "$SIGN_IDENTITY" --identifier "$LABEL" "$APP"

if [[ "$MODE" == "--install" ]]; then
  # A login agent: starts it at login, and again if it ever exits.
  PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>AssociatedBundleIdentifiers</key>
	<array>
		<string>$LABEL</string>
	</array>
	<key>ProgramArguments</key>
	<array>
		<string>$APP/Contents/MacOS/WindowStrip</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
</dict>
</plist>
PLIST
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  err=""
  for _ in 1 2 3 4 5; do
    if err=$(launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>&1); then err=""; break; fi
    sleep 1
  done
  if ! launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
    echo "could not load the login agent: ${err:-unknown error}" >&2
    exit 1
  fi
  echo "installed $PLIST"
elif launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
  launchctl kickstart -k "gui/$(id -u)/$LABEL"
fi
echo "built $APP (${MODE:-current})"
