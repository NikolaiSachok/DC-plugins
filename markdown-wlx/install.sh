#!/bin/zsh
# Install MarkdownView.wlx into a stable, update-proof location and register it
# in doublecmd.xml (before MacPreview, which otherwise claims every extension).
#
# Works in two layouts:
#   • source tree    — builds from MarkdownView.m (needs Xcode CLT)
#   • release bundle — a prebuilt MarkdownView.wlx sits next to this script
#                      (no Xcode required)
#
# Double Commander MUST be quit before running — it rewrites its config on exit.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/Library/Preferences/doublecmd/plugins/wlx/MarkdownView"
CONFIG="$HOME/Library/Preferences/doublecmd/doublecmd.xml"

if [ -f "$HERE/MarkdownView.wlx" ]; then
    WLX="$HERE/MarkdownView.wlx"          # prebuilt release bundle
    ASSETS="$HERE/assets"
else
    echo "==> Building from source"
    "$HERE/build.sh" >/dev/null
    WLX="$HERE/build/MarkdownView.wlx"
    ASSETS="$HERE/assets"
fi

echo "==> Installing files to $DEST"
mkdir -p "$DEST"
cp -f "$WLX" "$DEST/MarkdownView.wlx"
rm -rf "$DEST/assets"
cp -R "$ASSETS" "$DEST/assets"
# Ship a sample config without clobbering an existing one.
[ -f "$HERE/MarkdownView.ini.sample" ] && cp -f "$HERE/MarkdownView.ini.sample" "$DEST/MarkdownView.ini.sample"

if pgrep -f "MacOS/doublecmd" >/dev/null; then
    echo "!! Double Commander is running. Quit it, then re-run this script to register."
    exit 1
fi

echo "==> Registering in $CONFIG"
python3 "$HERE/register_plugin.py" "$CONFIG" "$DEST/MarkdownView.wlx"

echo "==> Done. Launch Double Commander and open any .md file (F3)."
echo "    Optional settings: copy $DEST/MarkdownView.ini.sample to MarkdownView.ini and edit."
