"""OptiCensus icon (concept e6): white four-point sparkle + red change dot on black. Flat, no gradients."""
import sys
from PIL import Image, ImageDraw
S = 4096                                   # draw big, downsample for clean edges
def P(x, y): return (x * S, y * S)
def quad(p0, c, p1, n=64):
    return [((1-t)**2*p0[0] + 2*(1-t)*t*c[0] + t*t*p1[0], (1-t)**2*p0[1] + 2*(1-t)*t*c[1] + t*t*p1[1])
            for t in (i / n for i in range(n + 1))]
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(img)
d.rounded_rectangle([0, 0, S - 1, S - 1], radius=int(S * 0.225), fill=(17, 17, 17, 255))
cx, cy = 0.46, 0.54                        # sparkle centre, nudged down-left to leave room for the dot
up, down, side = 0.33, 0.33, 0.29
w = 0.045                                  # waist: how far the curve control sits from the centre
T, R, B, L = (cx, cy-up), (cx+side, cy), (cx, cy+down), (cx-side, cy)
pts = []
for a, b, sx, sy in [(T, R, 1, -1), (R, B, 1, 1), (B, L, -1, 1), (L, T, -1, -1)]:
    pts += quad(a, (cx + sx*w, cy + sy*w), b)
d.polygon([P(*p) for p in pts], fill=(255, 255, 255, 255))
dx, dy, r = 0.725, 0.275, 0.085            # the "something changed" dot
d.ellipse([*P(dx-r, dy-r), *P(dx+r, dy+r)], fill=(235, 64, 52, 255))
out = sys.argv[1]
for size, name in [(1024, "icon.png"), (512, "icon-512.png"), (192, "icon-192.png")]:
    img.resize((size, size), Image.LANCZOS).save(f"{out}/{name}")
