#!/bin/zsh
# Install MarkdownView.wlx into a stable, update-proof location and register it
# in doublecmd.xml (before MacPreview, which otherwise claims every extension).
#
# Double Commander MUST be quit before running this — it rewrites its config on
# exit and would clobber our edit otherwise.
set -e
cd "$(dirname "$0")"

DEST="$HOME/Library/Preferences/doublecmd/plugins/wlx/MarkdownView"
CONFIG="$HOME/Library/Preferences/doublecmd/doublecmd.xml"

echo "==> Building"
./build.sh >/dev/null

echo "==> Installing files to $DEST"
mkdir -p "$DEST"
cp -f build/MarkdownView.wlx "$DEST/MarkdownView.wlx"
rm -rf "$DEST/assets"
cp -R assets "$DEST/assets"

if pgrep -f "MacOS/doublecmd" >/dev/null; then
    echo "!! Double Commander is running. Quit it, then re-run this script to register."
    exit 1
fi

echo "==> Registering in $CONFIG"
python3 register_plugin.py "$CONFIG" "$DEST/MarkdownView.wlx"

echo "==> Done. Launch Double Commander and open any .md file (F3)."
