import os
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError as exc:
    sys.stderr.write(f"Pillow not available: {exc}\n")
    sys.exit(1)

ROOT = Path(__file__).resolve().parents[2]
ASSETS_DIR = ROOT / "assets"
OUT_DIR = ROOT / "windows" / "Resources"
OUT_DIR.mkdir(parents=True, exist_ok=True)

ICON_SIZES = [(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]


def make_ico(src_png: Path, dst_ico: Path) -> None:
    if not src_png.exists():
        raise FileNotFoundError(f"Missing icon source: {src_png}")
    img = Image.open(src_png).convert("RGBA")
    img.save(dst_ico, format="ICO", sizes=ICON_SIZES)
    print(f"Generated {dst_ico}")


def main() -> None:
    make_ico(ASSETS_DIR / "AppIcon-Default.png", OUT_DIR / "AppIcon-Default.ico")
    make_ico(ASSETS_DIR / "AppIcon-Dark.png", OUT_DIR / "AppIcon-Dark.ico")

    rc_path = OUT_DIR / "YacineTV.rc"
    rc_content = """1 ICON "AppIcon-Default.ico"

1 VERSIONINFO
FILEVERSION 1,0,0,0
PRODUCTVERSION 1,0,0,0
FILEOS 0x40004L
FILETYPE 0x1L
BEGIN
  BLOCK "StringFileInfo"
  BEGIN
    BLOCK "040904B0"
    BEGIN
      VALUE "CompanyName", "YacineTV"
      VALUE "FileDescription", "Yacine TV Desktop (Swift for Windows)"
      VALUE "FileVersion", "1.0.0.0"
      VALUE "InternalName", "YacineTV"
      VALUE "OriginalFilename", "YacineTV.exe"
      VALUE "ProductName", "Yacine TV"
      VALUE "ProductVersion", "1.0.0.0"
    END
  END
  BLOCK "VarFileInfo"
  BEGIN
    VALUE "Translation", 0x409, 1200
  END
END
"""
    rc_path.write_text(rc_content, encoding="utf-8")
    print(f"Wrote {rc_path}")


if __name__ == "__main__":
    main()
