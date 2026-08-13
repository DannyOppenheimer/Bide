#!/usr/bin/env python3
"""Generates web/og.png for invitation link previews.

The per-invite text is provided separately by functions/trip.js. This shared
image contains the horizontal logo and wordmark on the brand background.
Geometry follows MainLogo_Horizontal.svg and is rendered at 3x before downsampling
for smooth edges.

    python3 design/company_style/make-og-image.py
"""

from PIL import Image, ImageDraw, ImageFont

OUTPUT = "web/og.png"

# Standard Open Graph preview dimensions.
WIDTH, HEIGHT = 1200, 630
SCALE = 3

BACKGROUND = (0x1D, 0x1D, 0x1F)   # BideColor.background
FOREGROUND = (0xFF, 0xFF, 0xFF)   # BideColor.primaryText

# Logo geometry in the source SVG's coordinate system.
VIEWBOX_WIDTH = 112.0
DOT_RADIUS = 5.0
DOT_CENTRES = (5.0, 39.0, 73.0, 107.0)
RULE_WIDTH = 2.0
CENTRE_Y = 6.0

MARK_WIDTH = 560          # on the unscaled canvas
WORDMARK_SIZE = 92
WORDMARK_TRACKING = -0.035    # em, matching the landing page's tight wordmark
GAP = 58                      # between the mark and the wordmark

FONT_PATH = "/System/Library/Fonts/SFNS.ttf"   # SF Pro, the brand face


def load_wordmark_font(size):
    font = ImageFont.truetype(FONT_PATH, size)
    try:
        font.set_variation_by_name("Bold")
    except Exception:
        # Fall back to the regular SF Pro weight when font variations are unavailable.
        pass
    return font


def draw_mark(draw, centre_x, centre_y, width):
    """Draws the four-dot mark centered at the requested size."""
    unit = width / VIEWBOX_WIDTH
    left = centre_x - width / 2

    def x_at(value):
        return left + value * unit

    rule_half = RULE_WIDTH * unit / 2
    draw.rectangle(
        [x_at(DOT_CENTRES[0]), centre_y - rule_half, x_at(DOT_CENTRES[-1]), centre_y + rule_half],
        fill=FOREGROUND,
    )

    radius = DOT_RADIUS * unit
    for centre in DOT_CENTRES:
        x = x_at(centre)
        draw.ellipse([x - radius, centre_y - radius, x + radius, centre_y + radius], fill=FOREGROUND)


def measure_tracked(draw, text, font, tracking):
    widths = [draw.textlength(character, font=font) for character in text]
    return sum(widths) + tracking * (len(text) - 1)


def draw_tracked(draw, text, font, tracking, left, top):
    """Draws one glyph at a time because Pillow has no letter-spacing option."""
    x = left
    for character in text:
        draw.text((x, top), character, font=font, fill=FOREGROUND)
        x += draw.textlength(character, font=font) + tracking


def main():
    image = Image.new("RGB", (WIDTH * SCALE, HEIGHT * SCALE), BACKGROUND)
    draw = ImageDraw.Draw(image)

    font = load_wordmark_font(WORDMARK_SIZE * SCALE)
    tracking = WORDMARK_TRACKING * WORDMARK_SIZE * SCALE

    text = "Bide"
    text_width = measure_tracked(draw, text, font, tracking)
    # Center the visible glyph bounds rather than the font's larger line box.
    _, top_bearing, _, bottom = draw.textbbox((0, 0), text, font=font)
    text_height = bottom - top_bearing

    mark_diameter = 2 * DOT_RADIUS * (MARK_WIDTH * SCALE / VIEWBOX_WIDTH)
    block_height = mark_diameter + GAP * SCALE + text_height
    block_top = (HEIGHT * SCALE - block_height) / 2

    draw_mark(
        draw,
        centre_x=WIDTH * SCALE / 2,
        centre_y=block_top + mark_diameter / 2,
        width=MARK_WIDTH * SCALE,
    )
    draw_tracked(
        draw,
        text,
        font,
        tracking,
        left=(WIDTH * SCALE - text_width) / 2,
        top=block_top + mark_diameter + GAP * SCALE - top_bearing,
    )

    image.resize((WIDTH, HEIGHT), Image.LANCZOS).save(OUTPUT, optimize=True)
    print(f"wrote {OUTPUT} ({WIDTH}x{HEIGHT})")


if __name__ == "__main__":
    main()
