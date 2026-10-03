#!/usr/bin/env python3
"""Builds docs/assets/banner.jpg, the wide banner of README and website:
the wordmark taken from docs/Images/logo.PNG next to the device photo.
Needs tools/.venv with Pillow and numpy:  tools/.venv/bin/python tools/gen_banner.py"""
from PIL import Image, ImageFilter, ImageDraw, ImageFont
import numpy as np
import os
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
FONT = os.environ.get('MONTSERRAT_TTF', os.path.expanduser('~/Documents/Arduino/libraries/lvgl/scripts/generators/built_in_font/Montserrat-Medium.ttf'))
logo = Image.open('docs/Images/logo.PNG').convert('RGB')
a = np.asarray(logo).astype(float)
lum = a.mean(axis=2)
band = lum[500:760, 150:1104]
ys, xs = np.where(band > 120)
y0, y1 = ys.min() + 500 - 6, ys.max() + 500 + 6
x0, x1 = xs.min() + 150 - 6, xs.max() + 150 + 6
crop = a[y0:y1, x0:x1]
cl = crop.mean(axis=2)
bg = np.median(cl[cl < 60])
alpha = np.clip((cl - bg - 8) / (200 - bg), 0, 1)
word = Image.fromarray(np.dstack([crop, alpha * 255]).astype('uint8'), 'RGBA')

W, H = 2400, 800
banner = Image.new('RGB', (W, H), (8, 8, 10))
glow = Image.new('L', (W, H), 0)
ImageDraw.Draw(glow).ellipse((-200, 80, 1300, 760), fill=60)
glow = glow.filter(ImageFilter.GaussianBlur(160))
banner = Image.composite(Image.new('RGB', (W, H), (40, 30, 18)), banner, glow)

photo = Image.open('docs/Images/device.jpg').convert('RGB')
pw = int(photo.width * H / photo.height)
photo = photo.resize((pw, H), Image.LANCZOS)
fade = np.ones((H, pw))
ramp = int(pw * 0.55)
fade[:, :ramp] = np.linspace(0, 1, ramp) ** 1.6
v = np.ones(H); e = 60
v[:e] = np.linspace(0.6, 1, e); v[-e:] = np.linspace(1, 0.6, e)
fade *= v[:, None]
banner.paste(photo, (W - pw, 0), Image.fromarray((fade * 255).astype('uint8'), 'L'))

tw = 980
word = word.resize((tw, int(word.height * tw / word.width)), Image.LANCZOS)
wx, wy = 150, 270
banner.paste(word, (wx, wy), word)
d = ImageDraw.Draw(banner)
ty = wy + word.height + 50
d.text((wx + 6, ty), 'A rotary controller for Lightroom Classic', font=ImageFont.truetype(FONT, 46), fill=(205, 205, 210))
d.text((wx + 6, ty + 76), 'Develop  ·  Cull  ·  Track your time', font=ImageFont.truetype(FONT, 30), fill=(255, 159, 10))
banner.save('docs/assets/banner.jpg', quality=88)
print('wrote docs/assets/banner.jpg')
