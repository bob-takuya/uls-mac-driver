#!/usr/bin/env python3
"""
ULS Laser Control - App Icon Generator
Generates macOS .iconset PNG files without any third-party dependencies.

Usage: python3 gen_icon.py <output_iconset_dir>
"""

import struct, zlib, os, sys, math

def create_png(size, filename):
    """Create a laser cutter icon PNG at the given size."""
    w = h = size
    cx, cy = w / 2.0, h / 2.0
    r = w * 0.38

    pixels = []
    for y in range(h):
        for x in range(w):
            dx = x - cx
            dy = y - cy
            dist = math.sqrt(dx*dx + dy*dy)

            border_thick = max(2, size // 32)
            beam_h = max(1, size // 36)
            beam_w = r * 1.5
            ch = max(1, size // 52)
            arm = r * 0.55

            if abs(dist - r) < border_thick:
                # Circle border - metallic grey
                t = abs(dist - r) / border_thick
                v = int(160 - 60 * t)
                pixels.extend([v, v, v, 255])
            elif dist > r + border_thick:
                # Outside - dark
                pixels.extend([22, 22, 22, 255])
            else:
                # Inside circle
                if abs(dy) <= beam_h and abs(dx) <= beam_w:
                    # Laser beam - red glow
                    t = max(0.0, 1.0 - abs(dx) / beam_w)
                    s = max(0.0, 1.0 - abs(dy) / max(1, beam_h))
                    intensity = t * s
                    red = int(180 + 75 * intensity)
                    green = int(30 * intensity)
                    blue = int(20 * intensity)
                    alpha = int(180 + 75 * intensity)
                    pixels.extend([red, green, blue, alpha])
                elif (abs(dy) <= ch and abs(dx) <= arm) or (abs(dx) <= ch and abs(dy) <= arm):
                    # Crosshair
                    t = max(abs(dx), abs(dy)) / max(arm, 1)
                    v = int(200 - 80 * t)
                    pixels.extend([v, v, v, 220])
                else:
                    # Background inside circle
                    shade = int(38 + 8 * (1.0 - dist / r))
                    pixels.extend([shade, shade, shade, 255])

    raw_rows = []
    for row in range(h):
        row_bytes = b'\x00'
        for col in range(w):
            idx = (row * w + col) * 4
            row_bytes += bytes(pixels[idx:idx+4])
        raw_rows.append(row_bytes)

    raw = b''.join(raw_rows)
    compressed = zlib.compress(raw, 9)

    def chunk(tag, data):
        crc = zlib.crc32(tag + data) & 0xffffffff
        return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', crc)

    png = b'\x89PNG\r\n\x1a\n'
    png += chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0))
    png += chunk(b'IDAT', compressed)
    png += chunk(b'IEND', b'')

    with open(filename, 'wb') as f:
        f.write(png)


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <output_iconset_dir>", file=sys.stderr)
        sys.exit(1)

    out_dir = sys.argv[1]
    os.makedirs(out_dir, exist_ok=True)

    sizes = [16, 32, 64, 128, 256, 512]
    for sz in sizes:
        create_png(sz,    os.path.join(out_dir, f"icon_{sz}x{sz}.png"))
        create_png(sz*2,  os.path.join(out_dir, f"icon_{sz}x{sz}@2x.png"))
        print(f"  {sz}x{sz} and @2x generated")

    print(f"Iconset written to: {out_dir}")


if __name__ == "__main__":
    main()
