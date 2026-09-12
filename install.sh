#!/bin/sh
# One command, from nothing to a running router:
#   curl -fsSL https://raw.githubusercontent.com/sjdonado/browser-router/main/install.sh | sh
#
# Builds from source into ~/Applications/BrowserRouter.app, seeds a config if
# there is none, and asks macOS to make it the default browser. No DMG, no
# notarization, no background process: the app is 90KB and only runs while a link
# is being routed.
set -eu

# --no-default-prompt: build and register, but do not ask to become the default
# browser. Provisioning scripts re-run this on every pass and the prompt is modal.
if [ "${1:-}" = "--no-default-prompt" ]; then PROMPT=0; else PROMPT=1; fi

REPO="https://github.com/sjdonado/browser-router.git"
APP="$HOME/Applications/BrowserRouter.app"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/browser-router/config.json"

command -v xcrun >/dev/null 2>&1 || {
  echo "error: the Xcode command line tools are needed to compile. Run: xcode-select --install" >&2
  exit 1
}

# Run from a clone if there is one, otherwise fetch a throwaway copy.
if [ -f "$(dirname "$0")/main.swift" ]; then
  SRC="$(cd "$(dirname "$0")" && pwd)"
else
  SRC="$(mktemp -d)"
  trap 'rm -rf "$SRC"' EXIT INT TERM
  git clone --depth 1 "$REPO" "$SRC" >/dev/null 2>&1
fi

echo "Building BrowserRouter..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
xcrun swiftc -O -framework AppKit -o "$APP/Contents/MacOS/BrowserRouter" "$SRC/main.swift"
cp "$SRC/Info.plist" "$APP/Contents/Info.plist"
# Editing Info.plist invalidates a signature, so sign the assembled bundle.
codesign --force --sign - "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"

if [ ! -e "$CONFIG" ] && [ ! -L "$CONFIG" ]; then
  mkdir -p "$(dirname "$CONFIG")"
  cp "$SRC/config.example.json" "$CONFIG"
  echo "Wrote a starting config to $CONFIG"
fi

echo "Installed $APP"
if [ "$PROMPT" = 1 ]; then
  echo "macOS will now ask whether to make BrowserRouter the default browser. Say yes."
  open "$APP"
fi
