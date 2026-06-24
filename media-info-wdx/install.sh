#!/bin/zsh
# Install MediaInfo.wdx into a stable, update-proof location and register it as a
# content plugin in doublecmd.xml.
#
# Works in two layouts:
#   • source tree    — builds from MediaInfo.m (needs Xcode CLT)
#   • release bundle — a prebuilt MediaInfo.wdx sits next to this script
#                      (no Xcode required)
#
# Double Commander MUST be quit before running — it rewrites its config on exit.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/Library/Preferences/doublecmd/plugins/wdx/MediaInfo"
CONFIG="$HOME/Library/Preferences/doublecmd/doublecmd.xml"

if [ -f "$HERE/MediaInfo.wdx" ]; then
    WDX="$HERE/MediaInfo.wdx"             # prebuilt release bundle
else
    echo "==> Building from source"
    "$HERE/build.sh" >/dev/null
    WDX="$HERE/build/MediaInfo.wdx"
fi

echo "==> Installing to $DEST"
mkdir -p "$DEST"
cp -f "$WDX" "$DEST/MediaInfo.wdx"

if pgrep -f "MacOS/doublecmd" >/dev/null; then
    echo "!! Double Commander is running. Quit it, then re-run this script to register."
    exit 1
fi

echo "==> Registering in $CONFIG"
python3 "$HERE/register_plugin.py" "$CONFIG" "$DEST/MediaInfo.wdx"

cat <<'EOF'
==> Done. Launch Double Commander, then add a column:
      right-click the column header -> Configure / Columns...
      add a column, field source "MediaInfo", pick "Summary"
      (or Dimensions / Duration / Page count for a dedicated column).
EOF
