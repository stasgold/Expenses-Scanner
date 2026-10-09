#!/usr/bin/env python3
"""Draws the app icon: a receipt inside camera-scan brackets on a teal field.

    python3 tools/make_app_icon.py    # needs: pip install pillow

Writes ExpensesScanner/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png (1024 × 1024, no alpha).
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
SCALE = 4  # draw large, then downsample for smooth edges
OUT = Path(__file__).resolve().parent.parent / "ExpensesScanner/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"

TOP = (0x00, 0x8A, 0x7E)
BOTTOM = (0x00, 0x4F, 0x5C)
PAPER = (0xFF, 0xFF, 0xFF)
INK = (0x9A, 0xA7, 0xAB)
TOTAL = (0x00, 0x5F, 0x63)
BRACKET = (0xE6, 0xFF, 0xFA)


def s(value: float) -> int:
    return round(value * SCALE)


def main() -> None:
    size = s(SIZE)
    image = Image.new("RGB", (size, size))
    pixels = ImageDraw.Draw(image)
    for y in range(size):
        t = y / (size - 1)
        pixels.line([(0, y), (size, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(TOP, BOTTOM)))

    # Receipt with a torn (zigzag) bottom edge, and a soft shadow under it.
    left, right, top, bottom = 322, 702, 236, 736
    teeth = 8
    tooth = (right - left) / teeth
    outline = [(left, top), (right, top), (right, bottom)]
    for i in range(teeth):
        x = right - (i + 0.5) * tooth
        outline += [(x, bottom + 30), (right - (i + 1) * tooth, bottom)]
    outline = [(s(x), s(y)) for x, y in outline]

    shadow = Image.new("L", (size, size), 0)
    ImageDraw.Draw(shadow).polygon([(x, y + s(18)) for x, y in outline], fill=110)
    shadow = shadow.filter(ImageFilter.GaussianBlur(s(18)))
    image.paste((0, 0, 0), mask=shadow)

    draw = ImageDraw.Draw(image)
    draw.polygon(outline, fill=PAPER)

    # Item lines: a name on the left, a price on the right.
    for row, (name, price) in enumerate([(150, 70), (190, 60), (120, 80), (170, 64)]):
        y = top + 76 + row * 66
        draw.rounded_rectangle([s(left + 48), s(y), s(left + 48 + name), s(y + 26)], radius=s(13), fill=INK)
        draw.rounded_rectangle([s(right - 48 - price), s(y), s(right - 48), s(y + 26)], radius=s(13), fill=INK)
    # Divider and the total.
    draw.rounded_rectangle([s(left + 48), s(top + 344), s(right - 48), s(top + 352)], radius=s(4), fill=INK)
    draw.rounded_rectangle([s(left + 48), s(top + 388), s(left + 178), s(top + 432)], radius=s(22), fill=TOTAL)
    draw.rounded_rectangle([s(right - 168), s(top + 388), s(right - 48), s(top + 432)], radius=s(22), fill=TOTAL)

    # Scan brackets in the four corners around the receipt.
    inset, arm, width = 168, 140, 40
    for cx, cy, dx, dy in [(inset, inset, 1, 1), (SIZE - inset, inset, -1, 1), (inset, SIZE - inset, 1, -1), (SIZE - inset, SIZE - inset, -1, -1)]:
        draw.line([(s(cx), s(cy + dy * arm)), (s(cx), s(cy))], fill=BRACKET, width=s(width), joint="curve")
        draw.line([(s(cx), s(cy)), (s(cx + dx * arm), s(cy))], fill=BRACKET, width=s(width), joint="curve")
        for x, y in [(cx, cy + dy * arm), (cx + dx * arm, cy), (cx, cy)]:
            r = width / 2
            draw.ellipse([s(x - r), s(y - r), s(x + r), s(y + r)], fill=BRACKET)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    image.resize((SIZE, SIZE), Image.LANCZOS).save(OUT, optimize=True)
    print(f"Wrote {OUT}")


if __name__ == "__main__":
    main()
