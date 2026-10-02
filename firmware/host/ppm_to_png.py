"""Converts the snapshot PPMs to PNGs with the round display mask, plus one
contact sheet (snapshots/_sheet.png)."""
import sys
from pathlib import Path

from PIL import Image, ImageDraw

folder = Path(sys.argv[1])
files = sorted(folder.glob("*.ppm"))
size = 360
mask = Image.new("L", (size * 4, size * 4), 0)
ImageDraw.Draw(mask).ellipse((0, 0, size * 4 - 1, size * 4 - 1), fill=255)
mask = mask.resize((size, size), Image.LANCZOS)

columns = 4
rows = (len(files) + columns - 1) // columns
sheet = Image.new("RGB", (columns * (size + 20) + 20, rows * (size + 20) + 20), (48, 48, 54))
for i, path in enumerate(files):
    image = Image.open(path).convert("RGB")
    round_image = Image.new("RGB", (size, size), (48, 48, 54))
    round_image.paste(image, (0, 0), mask)
    round_image.save(path.with_suffix(".png"))
    sheet.paste(round_image, (20 + (i % columns) * (size + 20), 20 + (i // columns) * (size + 20)))
    path.unlink()
sheet.save(folder / "_sheet.png")
print(f"{len(files)} snapshots in {folder}")
