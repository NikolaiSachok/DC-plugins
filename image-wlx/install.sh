#!/bin/zsh
# Install ImageView.wlx into a stable, update-proof location and register it in
# doublecmd.xml (before MacPreview, which otherwise claims every extension).
#
# Works in two layouts:
#   • source tree    — builds from ImageView.m (needs Xcode CLT)
#   • release bundle — a prebuilt ImageView.wlx sits next to this script
#                      (no Xcode required)
#
# Double Commander MUST be quit before running — it rewrites its config on exit.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/Library/Preferences/doublecmd/plugins/wlx/ImageView"
CONFIG="$HOME/Library/Preferences/doublecmd/doublecmd.xml"

if [ -f "$HERE/ImageView.wlx" ]; then
    WLX="$HERE/ImageView.wlx"             # prebuilt release bundle
else
    echo "==> Building from source"
    "$HERE/build.sh" >/dev/null
    WLX="$HERE/build/ImageView.wlx"
fi

echo "==> Installing files to $DEST"
mkdir -p "$DEST"
# Replace, never overwrite in place: a running Double Commander has the old
# binary mapped, and rewriting that file under it can crash it.
cp -f "$WLX" "$DEST/.ImageView.wlx.new"
mv -f "$DEST/.ImageView.wlx.new" "$DEST/ImageView.wlx"

if pgrep -f "MacOS/doublecmd" >/dev/null; then
    echo "!! Double Commander is running. Quit it, then re-run this script to register."
    exit 1
fi

echo "==> Registering in $CONFIG"
python3 "$HERE/register_plugin.py" "$CONFIG" "$DEST/ImageView.wlx"

echo "==> Done. Launch Double Commander and open any image (F3)."
