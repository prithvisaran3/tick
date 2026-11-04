"""Playwright helper: launch the pre-installed Chromium regardless of Playwright version."""
import glob
def chrome_path():
    c = sorted(glob.glob("/opt/pw-browsers/chromium-*/chrome-linux*/chrome"))
    return c[-1] if c else None
def launch(p):
    return p.chromium.launch(executable_path=chrome_path(), args=["--no-sandbox", "--font-render-hinting=none"])
