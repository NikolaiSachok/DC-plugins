#!/bin/zsh
# Install EpubView.wlx into a stable, update-proof location and register it in
# doublecmd.xml (before MacPreview, which otherwise claims every extension).
#
# Works in two layouts:
#   • source tree    — builds from EpubView.m (needs Xcode CLT)
#   • release bundle — a prebuilt EpubView.wlx sits next to this script
#                      (no Xcode required)
#
# Double Commander MUST be quit before running — it rewrites its config on exit.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/Library/Preferences/doublecmd/plugins/wlx/EpubView"
CONFIG="$HOME/Library/Preferences/doublecmd/doublecmd.xml"

if [ -f "$HERE/EpubView.wlx" ]; then
    WLX="$HERE/EpubView.wlx"              # prebuilt release bundle
    ASSETS="$HERE/assets"
else
    echo "==> Building from source"
    "$HERE/build.sh" >/dev/null
    WLX="$HERE/build/EpubView.wlx"
    ASSETS="$HERE/assets"
fi

echo "==> Installing files to $DEST"
mkdir -p "$DEST"
cp -f "$WLX" "$DEST/EpubView.wlx"
rm -rf "$DEST/assets"
cp -R "$ASSETS" "$DEST/assets"
# Ship a sample config without clobbering an existing one.
[ -f "$HERE/EpubView.ini.sample" ] && cp -f "$HERE/EpubView.ini.sample" "$DEST/EpubView.ini.sample"

if pgrep -f "MacOS/doublecmd" >/dev/null; then
    echo "!! Double Commander is running. Quit it, then re-run this script to register."
    exit 1
fi

echo "==> Registering in $CONFIG"
python3 "$HERE/register_plugin.py" "$CONFIG" "$DEST/EpubView.wlx"

echo "==> Done. Launch Double Commander and open any .epub file (F3)."
echo "    Optional settings: copy $DEST/EpubView.ini.sample to EpubView.ini and edit."
