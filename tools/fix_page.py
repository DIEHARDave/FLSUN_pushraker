"""Fixes a bug in pushraker's settings page, if the installed version has it.

pushraker 0.3.6 hides the Filament change row on printers other than the
Snapmaker U1 (the T1 Pro is one), but collect() still reads its checkboxes,
so Save & Apply and Send Test stop with "Cannot read properties of null
(reading 'checked')". Sent upstream as a PR; once a pushraker release has
the fix, the pattern below isn't found and this does nothing.

Usage: python -I fix_page.py <path to pushraker/web/index.html>
Prints "fixed" when it changed the file.
"""

import sys

OLD = "filter(e => el('nt-fc-' + e).checked)"
NEW = ("filter(e => el('nt-fc-' + e) ? el('nt-fc-' + e).checked"
       " : String(state.filament_change_events || '').includes(e))")


def main(path):
    with open(path, encoding="utf-8", newline="") as f:
        text = f.read()
    if OLD not in text:
        return 0
    with open(path + ".tmp", "w", encoding="utf-8", newline="") as f:
        f.write(text.replace(OLD, NEW))
    import os
    os.replace(path + ".tmp", path)
    print("fixed")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
