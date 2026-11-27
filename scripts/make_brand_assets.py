#!/usr/bin/env python3
"""
Membuat aset logo NeuroN Engine dari satu sumber PNG (transparan).

Keluaran (relatif terhadap root repo):
  branding/neuron_logo.png                                   logo penuh (mark + tulisan), untuk dokumentasi
  flutter_app/assets/images/neuron_mark.png                  mark "NE" untuk header UI (ikut APK)
  flutter_app/android/app/src/main/res/mipmap-*/ic_launcher.png            ikon launcher (API < 26)
  flutter_app/android/app/src/main/res/mipmap-*/ic_launcher_foreground.png ikon adaptif (API >= 26)

Pemakaian (dari root repo):
  python3 scripts/make_brand_assets.py --src /path/ke/logo.png

Butuh: Pillow (pip install pillow). Palet 256 warna dengan alpha dipakai untuk menekan ukuran.
"""
import argparse
import os

from PIL import Image

R = Image.Resampling.LANCZOS
MARK_BOX_PAD = 12  # piksel padding di sekitar mark dan logo


def quantize(img: Image.Image) -> Image.Image:
    """Palet 256 warna (PNG-8 dengan alpha): jauh lebih kecil dari RGBA 32-bit."""
    return img.quantize(colors=256, method=Image.Quantize.FASTOCTREE, dither=Image.Dither.NONE)


def save_png(img: Image.Image, path: str, root: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path, optimize=True)
    print(f"{os.path.relpath(path, root):75s} {img.size[0]}x{img.size[1]:<5d} {os.path.getsize(path):>8,d} B")


def fit_mark(mark: Image.Image, canvas_px: int, ratio: float) -> Image.Image:
    """Mark di tengah kanvas transparan persegi; ratio = lebar mark / lebar kanvas."""
    mw = round(canvas_px * ratio)
    m = mark.resize((mw, round(mark.height * mw / mark.width)), R)
    canvas = Image.new("RGBA", (canvas_px, canvas_px), (0, 0, 0, 0))
    canvas.alpha_composite(m, ((canvas_px - m.width) // 2, (canvas_px - m.height) // 2))
    return canvas


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--src", required=True, help="PNG logo sumber (transparan)")
    ap.add_argument("--root", default=os.path.abspath(os.path.join(os.path.dirname(__file__), "..")),
                    help="root repo (default: folder di atas scripts/)")
    args = ap.parse_args()
    root = os.path.abspath(args.root)

    src = Image.open(args.src).convert("RGBA")
    alpha_box = src.getchannel("A").getbbox()  # area yang tidak transparan

    # 1. Logo penuh: dipangkas ke area konten, diperkecil ke 640 px
    x0, y0, x1, y1 = alpha_box
    full = src.crop((x0 - MARK_BOX_PAD, y0 - MARK_BOX_PAD, x1 + MARK_BOX_PAD, y1 + MARK_BOX_PAD))
    full = full.resize((640, round(full.height * 640 / full.width)), R)
    save_png(quantize(full), os.path.join(root, "branding", "neuron_logo.png"), root)

    # 2. Mark "NE": baris atas logo (sebelum celah tulisan). Cari celah baris transparan terpanjang.
    a = src.getchannel("A")
    W, H = src.size
    row_has_ink = [a.crop((0, y, W, y + 1)).getbbox() is not None for y in range(H)]
    bands, start = [], None
    for y, on in enumerate(row_has_ink + [False]):
        if on and start is None:
            start = y
        elif not on and start is not None:
            bands.append((start, y))
            start = None
    mark_y0, mark_y1 = bands[0]                  # pita pertama = mark
    mark_x0, _, mark_x1, _ = a.crop((0, mark_y0, W, mark_y1)).getbbox()
    mark = src.crop((mark_x0 - MARK_BOX_PAD, mark_y0 - MARK_BOX_PAD,
                     mark_x1 + MARK_BOX_PAD, mark_y1 + MARK_BOX_PAD))
    mark_small = mark.resize((256, round(mark.height * 256 / mark.width)), R)
    save_png(quantize(mark_small), os.path.join(root, "flutter_app", "assets", "images", "neuron_mark.png"), root)

    # 3. Ikon launcher
    res = os.path.join(root, "flutter_app", "android", "app", "src", "main", "res")
    legacy = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
    foreground = {"mdpi": 108, "hdpi": 162, "xhdpi": 216, "xxhdpi": 324, "xxxhdpi": 432}
    for dpi, px in legacy.items():
        icon = Image.new("RGBA", (px, px), (255, 255, 255, 255))   # latar putih, tanpa alpha
        icon.alpha_composite(fit_mark(mark, px, 0.74))
        save_png(icon.convert("RGB"), os.path.join(res, f"mipmap-{dpi}", "ic_launcher.png"), root)
    for dpi, px in foreground.items():
        # Ikon adaptif: mark di dalam safe zone 66dp dari 108dp
        save_png(quantize(fit_mark(mark, px, 0.60)),
                 os.path.join(res, f"mipmap-{dpi}", "ic_launcher_foreground.png"), root)


if __name__ == "__main__":
    main()
