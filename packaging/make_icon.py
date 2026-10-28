"""Builds the app icon from Roland's: the dark background turns slate grey, so the port stands apart from the original.

python packaging/make_icon.py <Roland's AppIcon.icns> <output.icns>
"""

import sys

from PIL import Image

ORIGINAL_BACKGROUND = (36, 36, 36)
NEW_BACKGROUND = (92, 99, 112)
TOLERANCE = 48  # how far from the background a pixel may be and still shift (anti-aliased edges shift partly)


def recolor(pixel):
    *rgb, alpha = pixel
    distance = max(abs(c - b) for c, b in zip(rgb, ORIGINAL_BACKGROUND, strict=True))
    weight = max(0.0, 1 - distance / TOLERANCE)
    shifted = (round(c + weight * (n - b)) for c, n, b in zip(rgb, NEW_BACKGROUND, ORIGINAL_BACKGROUND, strict=True))
    return (*shifted, alpha)


def main(source, target):
    image = Image.open(source).convert("RGBA")
    image.putdata([recolor(pixel) for pixel in image.get_flattened_data()])
    image.save(target, format="ICNS")


if __name__ == "__main__":
    main(*sys.argv[1:])
