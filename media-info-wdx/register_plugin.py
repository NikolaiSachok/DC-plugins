#!/usr/bin/env python3
"""Register the MediaInfo WDX content plugin in doublecmd.xml.

Inserts (or replaces) a <WdxPlugin> entry under <Plugins>/<WdxPlugins>. Content
plugins don't compete for files the way listers do — Double Commander merges the
fields of every WDX whose DetectString matches, namespaced by plugin name — so
ordering is irrelevant and this simply upserts our entry. Makes a timestamped
backup first.
"""
import sys, shutil, datetime
import xml.etree.ElementTree as ET

NAME = "MediaInfo"
# Only extensions a macOS system framework can actually read (ImageIO /
# AVFoundation / CGPDF), so no column is silently blank for a "supported" type.
DETECT = "|".join('(EXT="%s")' % e for e in [
    "JPG", "JPEG", "PNG", "GIF", "TIFF", "TIF", "BMP", "WEBP", "HEIC", "HEIF",
    "AVIF", "ICO", "ICNS", "PSD", "JP2", "DNG", "CR2", "CR3", "NEF", "ARW",
    "ORF", "RW2", "RAF", "SR2", "PEF",
    "MP3", "M4A", "AAC", "WAV", "AIFF", "AIF", "AIFC", "CAF",
    "MP4", "MOV", "M4V", "3GP", "3G2", "AVI",
    "PDF",
])


def main(config_path, wdx_path):
    backup = f"{config_path}.bak-{datetime.datetime.now():%Y%m%d-%H%M%S}"
    shutil.copy2(config_path, backup)
    print(f"   backup: {backup}")

    tree = ET.parse(config_path)
    root = tree.getroot()

    plugins = root.find("Plugins")
    if plugins is None:
        plugins = ET.SubElement(root, "Plugins")
    wdx = plugins.find("WdxPlugins")
    if wdx is None:
        wdx = ET.SubElement(plugins, "WdxPlugins")

    # Remove any prior MediaInfo entry (idempotent re-install).
    for el in list(wdx):
        name_el = el.find("Name")
        if name_el is not None and name_el.text == NAME:
            wdx.remove(el)

    entry = ET.SubElement(wdx, "WdxPlugin")
    ET.SubElement(entry, "Name").text = NAME
    ET.SubElement(entry, "Path").text = wdx_path
    ET.SubElement(entry, "DetectString").text = DETECT

    tree.write(config_path, encoding="UTF-8", xml_declaration=True)
    print(f"   registered '{NAME}' -> {wdx_path}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: register_plugin.py <doublecmd.xml> <MediaInfo.wdx>")
    main(sys.argv[1], sys.argv[2])
