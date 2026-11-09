#!/bin/zsh
# Install a self-contained prebuilt plugin, or build it from this source tree.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/Library/Preferences/doublecmd/plugins/wlx/TableView"
CONFIG="$HOME/Library/Preferences/doublecmd/doublecmd.xml"
if pgrep -f 'MacOS/doublecmd' >/dev/null; then
    echo 'Quit Double Commander, then re-run this installer (it saves its config on exit).'
    exit 1
fi
if [ -f "$HERE/TableView.wlx" ]; then
    WLX="$HERE/TableView.wlx"
else
    "$HERE/build.sh"
    WLX="$HERE/build/TableView.wlx"
fi
mkdir -p "$DEST"
cp "$WLX" "$DEST/.TableView.wlx.new"
mv -f "$DEST/.TableView.wlx.new" "$DEST/TableView.wlx"
python3 "$HERE/register_plugin.py" "$CONFIG" "$DEST/TableView.wlx"
echo 'Done. Open a CSV, Excel, Numbers or OpenDocument spreadsheet with F3 or Quick View.'
