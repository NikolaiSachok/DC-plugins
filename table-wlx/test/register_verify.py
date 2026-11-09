#!/usr/bin/env python3
"""Registration uses the real binary's detection string and is idempotent."""
from pathlib import Path
import importlib.util, sys, tempfile, xml.etree.ElementTree as ET
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('register', Path(__file__).parents[1] / 'register_plugin.py')
register = importlib.util.module_from_spec(spec)
spec.loader.exec_module(register)
plugin = str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory() as directory:
    config = Path(directory) / 'doublecmd.xml'
    config.write_text('''<doublecmd><Other keep="yes"/><Plugins><WlxPlugins>
<WlxPlugin Enabled="True"><Name>Specific</Name><Path>specific.wlx</Path><DetectString>EXT="PDF"</DetectString></WlxPlugin>
<WlxPlugin Enabled="True"><Name>MacPreview</Name><Path>preview.wlx</Path><DetectString>(EXT!="")</DetectString></WlxPlugin>
</WlxPlugins></Plugins></doublecmd>''')
    for _ in range(2):
        register.main(str(config), plugin)
    root = ET.parse(config).getroot()
    entries = root.findall('Plugins/WlxPlugins/WlxPlugin')
    assert [e.findtext('Name') for e in entries] == ['Specific', 'TableView', 'MacPreview']
    detect = entries[1].findtext('DetectString')
    assert 'NUMBERS' in detect and 'ODS' in detect and 'XLSX' in detect
    assert root.find('Other').get('keep') == 'yes'
    assert len(list(Path(directory).glob('*.bak-*'))) == 2
print('PASS registration, catch-all order, backups and idempotence')
