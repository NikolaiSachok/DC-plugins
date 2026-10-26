#!/usr/bin/env python3
"""Register the ImageView WLX plugin in doublecmd.xml.

Inserts a <WlxPlugin> entry into <WlxPlugins>, placed BEFORE any catch-all
plugin (e.g. MacPreview with DetectString (EXT!="")) so Double Commander picks
it for image files. Idempotent: updates the existing entry if already present.
Makes a timestamped backup first.

The DetectString is read from the plugin itself (ListGetDetectString), so the
list of extensions has one source of truth: ImageView.m.
"""
import ctypes, sys, shutil, datetime
import xml.etree.ElementTree as ET

NAME = "ImageView"


def detect_string(wlx_path):
    lib = ctypes.CDLL(wlx_path)
    buf = ctypes.create_string_buffer(2048)
    lib.ListGetDetectString(buf, ctypes.c_int(len(buf)))
    value = buf.value.decode("utf-8")
    if not value:
        sys.exit(f"{wlx_path} returned an empty DetectString")
    return value


def main(config_path, wlx_path):
    detect = detect_string(wlx_path)

    backup = f"{config_path}.bak-{datetime.datetime.now():%Y%m%d-%H%M%S}"
    shutil.copy2(config_path, backup)
    print(f"   backup: {backup}")

    tree = ET.parse(config_path)
    root = tree.getroot()

    plugins = root.find("Plugins")
    if plugins is None:
        plugins = ET.SubElement(root, "Plugins")
    wlx = plugins.find("WlxPlugins")
    if wlx is None:
        wlx = ET.SubElement(plugins, "WlxPlugins")

    # Remove any prior ImageView entry (idempotent re-install).
    for el in list(wlx):
        name_el = el.find("Name")
        if name_el is not None and name_el.text == NAME:
            wlx.remove(el)

    entry = ET.Element("WlxPlugin")
    entry.set("Enabled", "True")
    ET.SubElement(entry, "Name").text = NAME
    ET.SubElement(entry, "Path").text = wlx_path
    ET.SubElement(entry, "DetectString").text = detect

    # Insert before the first catch-all plugin so we win for image files.
    insert_at = len(list(wlx))
    for i, el in enumerate(list(wlx)):
        ds = el.find("DetectString")
        if ds is not None and ds.text and 'EXT!=""' in ds.text.replace(" ", ""):
            insert_at = i
            break
    wlx.insert(insert_at, entry)

    tree.write(config_path, encoding="UTF-8", xml_declaration=True)
    print(f"   registered '{NAME}' at position {insert_at} -> {wlx_path}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: register_plugin.py <doublecmd.xml> <ImageView.wlx>")
    main(sys.argv[1], sys.argv[2])
