# Ember's Apple TV home screen art: the top shelf (shown when Ember is selected in the top row) and the layered icon.
import json, math, os, random, sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageChops
ROOT = sys.argv[1]
BA = os.path.join(ROOT, "App Icon & Top Shelf Image.brandassets")
INFO = {"author": "xcode", "version": 1}
ACC = (240, 160, 75)
F_BOLD = "/usr/share/fonts/opentype/inter/InterDisplay-Bold.otf"
F_LIGHT = "/usr/share/fonts/opentype/inter/InterDisplay-Light.otf"

def wjson(p, o):
    os.makedirs(os.path.dirname(p), exist_ok=True); json.dump(o, open(p, "w"), indent=2)

def lerp(a, b, t): return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

def sky(w, h, seed=7, stars=True):
    rnd = random.Random(seed)
    im = Image.new("RGB", (w, h))
    d = ImageDraw.Draw(im)
    top, mid, bot = (8, 10, 24), (16, 13, 22), (30, 16, 9)
    for y in range(h):
        t = y / (h - 1)
        c = lerp(top, mid, t / 0.6) if t < 0.6 else lerp(mid, bot, (t - 0.6) / 0.4)
        d.line([(0, y), (w, y)], fill=c)
    def glow(cx, cy, r, col, a):
        g = Image.new("L", (w, h), 0); ImageDraw.Draw(g).ellipse([cx - r, cy - r * 0.7, cx + r, cy + r * 0.7], fill=a)
        g = g.filter(ImageFilter.GaussianBlur(r * 0.45))
        return Image.composite(Image.new("RGB", (w, h), col), im, g)
    im = glow(w * 0.12, h * 1.05, h * 0.9, (240, 110, 35), 120)     # embers' fire, bottom left
    im = glow(w * 0.88, -h * 0.05, h * 0.8, (90, 110, 190), 60)      # cool moonlight, top right
    if stars:
        layer = Image.new("RGBA", (w, h), (0, 0, 0, 0)); sd = ImageDraw.Draw(layer)
        n = int(w * h / 9000)
        for _ in range(n):
            x, y = rnd.random() * w, (rnd.random() ** 1.4) * h * 0.78
            r = (rnd.random() ** 3) * h * 0.0042 + h * 0.0009
            a = int(90 + rnd.random() * 165)
            col = (235, 238, 255) if rnd.random() > 0.15 else (255, 226, 190)
            sd.ellipse([x - r, y - r, x + r, y + r], fill=col + (a,))
        # a few bright ones with a soft halo and a sparkle
        for _ in range(max(6, n // 70)):
            x, y = rnd.random() * w, (rnd.random() ** 1.6) * h * 0.65
            r = h * (0.003 + rnd.random() * 0.003)
            halo = Image.new("RGBA", (w, h), (0, 0, 0, 0)); hd = ImageDraw.Draw(halo)
            hd.ellipse([x - r * 6, y - r * 6, x + r * 6, y + r * 6], fill=(220, 228, 255, 70))
            layer = Image.alpha_composite(layer, halo.filter(ImageFilter.GaussianBlur(r * 3)))
            sd = ImageDraw.Draw(layer)
            sd.ellipse([x - r, y - r, x + r, y + r], fill=(255, 255, 255, 255))
            L = r * 7
            sd.line([(x - L, y), (x + L, y)], fill=(255, 255, 255, 120), width=max(1, int(r * 0.35)))
            sd.line([(x, y - L), (x, y + L)], fill=(255, 255, 255, 120), width=max(1, int(r * 0.35)))
        im = Image.alpha_composite(im.convert("RGBA"), layer).convert("RGB")
    return im

def embers(w, h, seed=11, count=None, spread=0.55):
    """Sparks rising from the bottom left, drifting right, fading as they climb."""
    rnd = random.Random(seed)
    layer = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    glowl = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d, gd = ImageDraw.Draw(layer), ImageDraw.Draw(glowl)
    for _ in range(count or int(w * h / 16000)):
        life = rnd.random() ** 0.8                      # 0 = just born at the bottom, 1 = high up
        x0 = (rnd.random() ** 1.7) * w * spread
        x = x0 + life * w * 0.28 + math.sin(life * 9 + rnd.random() * 6) * w * 0.015
        y = h * (1.02 - life * 0.95)
        r = h * (0.0018 + (rnd.random() ** 2) * 0.006) * (1 - life * 0.55)
        a = int(255 * (1 - life) ** 1.3)
        col = lerp((255, 214, 120), (240, 96, 30), rnd.random())
        # a short streak in the direction it's moving
        # a faint tapering trail behind it (below left), then the spark with a hot centre
        for k in range(1, 7):
            tx, ty = x - w * 0.0011 * k, y + h * 0.0045 * k
            tr = r * (1 - k / 8)
            d.ellipse([tx - tr, ty - tr, tx + tr, ty + tr], fill=col + (int(a * 0.32 * (1 - k / 7)),))
        d.ellipse([x - r, y - r, x + r, y + r], fill=col + (a,))
        d.ellipse([x - r * 0.45, y - r * 0.45, x + r * 0.45, y + r * 0.45], fill=(255, 244, 220, a))
        gd.ellipse([x - r * 3, y - r * 3, x + r * 3, y + r * 3], fill=col + (int(a * 0.28),))
    glowl = glowl.filter(ImageFilter.GaussianBlur(h * 0.006))
    return Image.alpha_composite(glowl, layer)

def flame(size_h, ss=4):
    H = size_h * ss; W = int(H * 0.72)
    im = Image.new("RGBA", (W, H), (0, 0, 0, 0)); d = ImageDraw.Draw(im)
    r = W * 0.49; cy = H - r - 1; a0 = math.asin(r / cy)
    pts = [(W / 2, 0)] + [(W / 2 + r * math.cos(-a0 + (math.pi + 2 * a0) * k / 120), cy + r * math.sin(-a0 + (math.pi + 2 * a0) * k / 120)) for k in range(121)]
    # warm gradient inside the flame: light at the core, deep orange at the edges
    grad = Image.new("RGBA", (W, H))
    gd = ImageDraw.Draw(grad)
    for y in range(H):
        t = y / H
        gd.line([(0, y), (W, y)], fill=lerp((255, 196, 110), (236, 132, 52), min(1, t * 1.15)) + (255,))
    mask = Image.new("L", (W, H), 0); ImageDraw.Draw(mask).polygon(pts, fill=255)
    im.paste(grad, (0, 0), mask)
    core = Image.new("L", (W, H), 0)
    ImageDraw.Draw(core).ellipse([W / 2 - r * 0.52, cy - r * 0.30, W / 2 + r * 0.52, cy + r * 0.62], fill=255)
    core = core.filter(ImageFilter.GaussianBlur(r * 0.06))
    im.paste(Image.new("RGBA", (W, H), (255, 236, 200, 255)), (0, 0), ImageChops.multiply(core, mask))
    return im.resize((W // ss, H // ss), Image.LANCZOS)

def with_glow(canvas, sprite, xy, radius, alpha=0.9, col=ACC):
    w, h = canvas.size
    a = Image.new("L", (w, h), 0); a.paste(sprite.split()[3], xy)
    a = a.filter(ImageFilter.GaussianBlur(radius)).point(lambda v: int(min(255, v * alpha)))
    canvas = Image.alpha_composite(canvas, Image.composite(Image.new("RGBA", (w, h), col + (255,)), Image.new("RGBA", (w, h), (0, 0, 0, 0)), a))
    canvas.alpha_composite(sprite, xy)
    return canvas

def text_img(txt, font, fill, tracking=0):
    f = ImageFont.truetype(font[0], font[1])
    widths = [f.getbbox(ch)[2] for ch in txt]
    W = int(sum(widths) + tracking * (len(txt) - 1)) + 4
    asc, desc = f.getmetrics()
    im = Image.new("RGBA", (W, asc + desc + 4), (0, 0, 0, 0)); d = ImageDraw.Draw(im)
    x = 0
    for ch, cw in zip(txt, widths):
        d.text((x, 0), ch, font=f, fill=fill); x += cw + tracking
    return im.crop(im.getbbox())

def shelf(w, h):
    base = sky(w, h).convert("RGBA")
    base = Image.alpha_composite(base, embers(w, h))
    # the logo: flame + Ember, centred; the joke underneath, barely there
    fl = flame(int(h * 0.42))
    word = text_img("Ember", (F_BOLD, int(h * 0.27)), ACC + (255,), tracking=int(h * 0.004))
    # a touch of light across the word
    shine = Image.new("L", word.size, 0); ImageDraw.Draw(shine).rectangle([0, 0, word.width, word.height * 0.45], fill=60)
    word = Image.composite(Image.new("RGBA", word.size, (255, 222, 170, 255)), word, ImageChops.multiply(shine.filter(ImageFilter.GaussianBlur(word.height * 0.2)), word.split()[3]))
    gap = int(h * 0.06)
    total = fl.width + gap + word.width
    x0 = (w - total) // 2; cy = int(h * 0.47)
    base = with_glow(base, fl, (x0, cy - fl.height // 2), h * 0.07, 0.95)
    wy = cy - word.height // 2 + int(h * 0.02)
    base = with_glow(base, word, (x0 + fl.width + gap, wy), h * 0.035, 0.45)
    tag = text_img("A LUCA JORGENSON EXPERIENCE", (F_LIGHT, int(h * 0.034)), (255, 236, 214, 95), tracking=int(h * 0.011))
    base.alpha_composite(tag, (x0 + fl.width + gap + word.width - tag.width, wy + word.height + int(h * 0.05)))
    return base.convert("RGB")

def icon_layers(w, h):
    back = sky(w, h, seed=3).convert("RGBA")
    mid = embers(w, h, seed=5, count=int(w * h / 2600), spread=0.9)
    front = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    fl = flame(int(h * 0.62))
    front = with_glow(front, fl, ((w - fl.width) // 2, (h - fl.height) // 2), h * 0.09, 0.9)
    return back, mid, front

# --- write the asset catalog
wjson(os.path.join(BA, "Contents.json"), {"assets": [
    {"filename": "App Icon - App Store.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"},
    {"filename": "App Icon.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"},
    {"filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"},
    {"filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"}], "info": INFO})

def write_shelf(name, w, h):
    d = os.path.join(BA, name); os.makedirs(d, exist_ok=True)
    for f in os.listdir(d): os.remove(os.path.join(d, f))
    big = shelf(w * 2, h * 2)
    big.save(os.path.join(d, "shelf@2x.png"))
    big.resize((w, h), Image.LANCZOS).save(os.path.join(d, "shelf.png"))
    wjson(os.path.join(d, "Contents.json"), {"images": [{"filename": "shelf.png", "idiom": "tv", "scale": "1x"},
                                                       {"filename": "shelf@2x.png", "idiom": "tv", "scale": "2x"}], "info": INFO})
    return big

def write_stack(name, w, h, scales):
    sd = os.path.join(BA, name)
    import shutil; shutil.rmtree(sd, ignore_errors=True)
    wjson(os.path.join(sd, "Contents.json"), {"layers": [{"filename": "Front.imagestacklayer"}, {"filename": "Middle.imagestacklayer"},
                                                         {"filename": "Back.imagestacklayer"}], "info": INFO})
    hi = max(scales)
    b, m, f = icon_layers(w * hi, h * hi)
    for lname, img in (("Front", f), ("Middle", m), ("Back", b)):
        ld = os.path.join(sd, lname + ".imagestacklayer"); wjson(os.path.join(ld, "Contents.json"), {"info": INFO})
        imgs = []
        for sc in scales:
            fn = f"{lname.lower()}{'' if sc == 1 else '@%dx' % sc}.png"
            out = img if sc == hi else img.resize((w * sc, h * sc), Image.LANCZOS)
            os.makedirs(os.path.join(ld, "Content.imageset"), exist_ok=True)
            (out.convert("RGB") if lname == "Back" else out).save(os.path.join(ld, "Content.imageset", fn))
            imgs.append({"filename": fn, "idiom": "tv", "scale": f"{sc}x"})
        wjson(os.path.join(ld, "Content.imageset", "Contents.json"), {"images": imgs, "info": INFO})
    return Image.alpha_composite(Image.alpha_composite(b.convert("RGBA"), m), f)

prev = sys.argv[2]
write_shelf("Top Shelf Image.imageset", 1920, 720).resize((1920, 720), Image.LANCZOS).save(prev + "/shelf_prev.png")
write_shelf("Top Shelf Image Wide.imageset", 2320, 720)
write_stack("App Icon.imagestack", 400, 240, (1, 2)).save(prev + "/icon_prev.png")
write_stack("App Icon - App Store.imagestack", 1280, 768, (1,))
print("ok")
