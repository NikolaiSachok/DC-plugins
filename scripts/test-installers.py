#!/usr/bin/env python3
"""Run shipped installers in disposable release bundles with isolated destinations.

Only the two user-directory paths are redirected in the copied scripts. No user
config or environment HOME is modified. A stub pgrep controls host-running state.
"""
import mmap
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
for folder, name, kind in [
    ('book-wlx', 'BookView', 'wlx'),
    ('markdown-wlx', 'MarkdownView', 'wlx'),
    ('media-info-wdx', 'MediaInfo', 'wdx'),
]:
    with tempfile.TemporaryDirectory(prefix='dc-installer-') as tmp:
        base = Path(tmp)
        bundle = base / 'bundle'
        bundle.mkdir()
        prefs = base / 'preferences'
        dest = prefs / f'plugins/{kind}/{name}'
        dest.mkdir(parents=True)
        installed = dest / f'{name}.{kind}'
        installed.write_bytes(b'old binary contents')
        (dest / 'assets').mkdir()
        (dest / 'assets/old').write_text('old asset')
        config = prefs / 'doublecmd.xml'
        config.write_text('original config')
        source = (ROOT / folder / 'install.sh').read_text()
        source = source.replace('$HOME/Library/Preferences/doublecmd', str(prefs))
        script = bundle / 'install.sh'
        script.write_text(source)
        (bundle / f'{name}.{kind}').write_bytes(b'new binary contents')
        (bundle / 'assets').mkdir()
        (bundle / 'assets/new').write_text('new asset')
        (bundle / 'register_plugin.py').write_text(
            'import pathlib,sys\npathlib.Path(sys.argv[1]).write_text("registered")\n')
        bin_dir = base / 'bin'
        bin_dir.mkdir()
        pgrep = bin_dir / 'pgrep'
        pgrep.write_text('#!/bin/sh\nexit 0\n')
        pgrep.chmod(0o755)
        env = dict(os.environ, PATH=f'{bin_dir}:{os.environ["PATH"]}')
        with installed.open('rb') as old_file, mmap.mmap(old_file.fileno(), 0, access=mmap.ACCESS_READ) as mapped:
            old_inode = installed.stat().st_ino
            result = subprocess.run(['zsh', str(script)], env=env, capture_output=True, text=True)
            assert result.returncode != 0, result.stdout
            assert installed.stat().st_ino == old_inode
            assert mapped[:] == b'old binary contents'
            assert (dest / 'assets/old').exists()
            assert config.read_text() == 'original config'
            pgrep.write_text('#!/bin/sh\nexit 1\n')
            for _ in range(2):  # Repeat installation must be harmless.
                result = subprocess.run(['zsh', str(script)], env=env, capture_output=True, text=True)
                assert result.returncode == 0, result.stderr
                assert installed.stat().st_ino != old_inode
                assert installed.read_bytes() == b'new binary contents'
                assert mapped[:] == b'old binary contents'
                assert config.read_text() == 'registered'
                assert not list(dest.glob(f'.{name}.{kind}.*'))
        print(f'PASS {folder}: running-host refusal, mapped inode preserved, repeat install')
