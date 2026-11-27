"""OptiCensus icon: WorkFlow's three arrow-topped bars, flat, in OptiCensus
colours (off-white tile, charcoal bars, the tallest one red). The two apps
belong together, so the icon is WorkFlow's shape in a different colour.

    python3 site/make_icon.py site/assets    # icon.png 1024, icon-512.png, icon-192.png
"""
import sys
from PIL import Image, ImageDraw

S = 4096                    # draw big, downsample for clean edges
k = S / 1024                # design units are a 1024 tile

TILE = (246, 245, 242, 255)
BARS = [(95, 95, 95, 255), (40, 40, 40, 255), (235, 64, 52, 255)]
# x0, x1, roof peak, bottom: WorkFlow's proportions, centred on the tile
GEOMETRY = [(232, 392, 520, 812), (432, 592, 372, 812), (632, 792, 212, 812)]


def bar(d, x0, x1, peak, bottom, fill, roof=0.33):
    w = x1 - x0
    shoulder = peak + w * roof
    r = w * 0.13
    # rounded bottom corners only; square where the body meets the roof
    d.rounded_rectangle([x0 * k, shoulder * k, x1 * k, bottom * k], radius=r * k, fill=fill)
    d.rectangle([x0 * k, shoulder * k, x1 * k, (shoulder + 2 * r) * k], fill=fill)
    d.polygon([(x0 * k, shoulder * k + 1), ((x0 + x1) / 2 * k, peak * k), (x1 * k, shoulder * k + 1)], fill=fill)


img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(img)
d.rounded_rectangle([0, 0, S - 1, S - 1], radius=int(S * 0.225), fill=TILE)
for (x0, x1, peak, bottom), colour in zip(GEOMETRY, BARS):
    bar(d, x0, x1, peak, bottom, colour)

out = sys.argv[1]
for size, name in [(1024, "icon.png"), (512, "icon-512.png"), (192, "icon-192.png")]:
    img.resize((size, size), Image.LANCZOS).save(f"{out}/{name}")
