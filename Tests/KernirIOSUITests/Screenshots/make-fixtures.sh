#!/bin/bash
# Builds the App Store screenshot fixtures next to this script:
#   Project.zip    a generic project tree (11 files in Design/, Docs/, Photos/ and the root)
#   Contracts.zip  a small encrypted zip (ZipCrypto), password "kernir"
#   Contracts.7z   the same files as an AES-256 7z with encrypted names, password "kernir"
# Every file is generated here: no personal data, no real names or brands, no __MACOSX or ._
# entries. Needs python3 (standard library only), sips, zip and 7zz; opens no app.
# Project.zip is byte-reproducible (fixed times, order and modes). Contracts.zip is not:
# ZipCrypto salts each entry's header with random bytes, so only its contents repeat.
#
# Usage: Tests/KernirIOSUITests/Screenshots/make-fixtures.sh
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export TZ=UTC LC_ALL=C

mkdir -p "$work/Project/Design" "$work/Project/Docs" "$work/Project/Photos" "$work/Contracts" "$work/raw"

# ---------------------------------------------------------------------------------------------
# Images and PDFs (python3, standard library only). Photos are drawn as PNG, then sips makes JPEGs.
python3 -I - "$work" <<'PY'
import math, struct, sys, zlib

work = sys.argv[1]

def write_png(path, width, height, pixel):
    """pixel(x, y) -> (r, g, b) floats 0...1. Writes an opaque 8-bit RGB PNG."""
    rows = bytearray()
    for y in range(height):
        rows.append(0)
        for x in range(width):
            r, g, b = pixel(x, y)
            rows += bytes((clamp(r), clamp(g), clamp(b)))
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(rows), 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)

def clamp(v):
    return max(0, min(255, int(round(v * 255))))

def mix(a, b, t):
    t = max(0.0, min(1.0, t))
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))

def hexc(s):
    return tuple(int(s[i:i + 2], 16) / 255 for i in (0, 2, 4))

def smooth(e0, e1, x):
    t = max(0.0, min(1.0, (x - e0) / (e1 - e0)))
    return t * t * (3 - 2 * t)

# --- Photos: three painted landscapes -----------------------------------------------------------
W, H = 1500, 1000

def ridge(x, base, amp, waves):
    return base + amp * sum(a * math.sin(f * x + p) for f, a, p in waves)

def landscape(sky_top, sky_mid, sky_low, sun, layers, water=None):
    """sun = (cx, cy, radius, color, glow). layers = [(base, amp, waves, near, far)], back to front.
    water = (horizon, top_color, bottom_color): a lake or sea below `horizon` that mirrors the sky."""
    sx, sy, sr, scol, glow = sun

    def sky(x, y):
        t = y / H
        c = mix(sky_top, sky_mid, t / 0.55) if t < 0.55 else mix(sky_mid, sky_low, (t - 0.55) / 0.45)
        d = math.hypot(x - sx, y - sy)
        c = mix(c, glow, 0.55 * math.exp(-d / (sr * 4.0)))
        if d < sr:
            c = mix(c, scol, smooth(sr, sr - 2.5, d))
        return c

    def land(x, y):
        for base, amp, waves, near, far in reversed(layers):
            top = ridge(x / W, base * H, amp * H, waves)
            if y >= top:
                return mix(far, near, (y - top) / (H - top + 1) * 1.6)
        return None

    def pixel(x, y):
        if water and y >= water[0] * H:
            horizon = water[0] * H
            depth = (y - horizon) / (H - horizon)
            mirrored = 2 * horizon - y
            c = land(x, mirrored) or sky(x, mirrored)
            c = mix(c, mix(water[1], water[2], depth), 0.45 + 0.4 * depth)
            shimmer = 0.04 * math.sin(y * 0.9 + 3 * math.sin(x * 0.013))
            return tuple(v + shimmer for v in c)
        return land(x, y) or sky(x, y)

    return pixel

photos = {
    "sunset": landscape(
        hexc("2a3a7a"), hexc("e0806a"), hexc("f6c27a"),
        (980, 560, 70, hexc("fff2c8"), hexc("ffd38a")),
        [(0.52, 0.035, [(5.0, 1.0, 0.3), (11.0, 0.4, 1.7)], hexc("3b3355"), hexc("6d5070"))],
        water=(0.6, hexc("6a5a8a"), hexc("1f2547"))),
    "mountain-lake": landscape(
        hexc("5a8fd0"), hexc("a9cbe8"), hexc("e8eef0"),
        (320, 210, 55, hexc("fffdf2"), hexc("ffffff")),
        [(0.30, 0.10, [(6.0, 1.0, 0.0), (13.0, 0.35, 2.1), (2.5, 0.6, 1.0)], hexc("7f93a8"), hexc("b6c4d2")),
         (0.42, 0.07, [(8.0, 1.0, 1.3), (17.0, 0.3, 0.4)], hexc("3e5f57"), hexc("6f8c80"))],
        water=(0.62, hexc("6f9fb8"), hexc("24485a"))),
    "coastline": landscape(
        hexc("3f86c6"), hexc("8cc3e6"), hexc("d9eef5"),
        (1180, 180, 48, hexc("ffffff"), hexc("fff6dc")),
        [(0.47, 0.03, [(3.0, 1.0, 0.8), (9.0, 0.3, 0.2)], hexc("5c7d6a"), hexc("8aa596")),
         (0.70, 0.06, [(2.0, 1.0, 2.4), (7.0, 0.25, 0.9)], hexc("d8c49a"), hexc("ecdcb6"))],
        water=(0.5, hexc("3b8fb0"), hexc("1d5a7a"))),
}
for name, pixel in photos.items():
    write_png(f"{work}/raw/{name}.png", W, H, pixel)

# --- Design: a colour palette and a logo concept ------------------------------------------------
swatches = [hexc(c) for c in ("1f3b57", "2f7f8a", "8cc0a6", "f2d39b", "e07a5f")]
paper = hexc("f7f5f0")

def palette(x, y):
    w, h, pad = 1200, 600, 60
    col = (x - pad) / ((w - 2 * pad) / len(swatches))
    i = int(col)
    inside = pad <= x < w - pad and 120 <= y < 480 and 0 <= i < len(swatches) and (col - i) < 0.86
    return swatches[i] if inside else paper

write_png(f"{work}/Project/Design/Color Palette.png", 1200, 600, palette)

def logo(x, y):
    cx, cy = 400, 400
    d = math.hypot(x - cx, y - cy)
    a = math.atan2(y - cy, x - cx)
    c = paper
    if d < 260:
        c = mix(swatches[0], swatches[1], (y - 140) / 520)
    if d < 170 and math.cos(3 * a) > -0.2:
        c = mix(swatches[3], swatches[4], (d / 170))
    if d < 60:
        c = paper
    edge = smooth(258, 262, d)
    return mix(c, paper, edge) if d > 250 else c

write_png(f"{work}/Project/Design/Logo Concept.png", 800, 800, logo)

# --- PDFs ---------------------------------------------------------------------------------------
def write_pdf(path, content):
    """A one-page US Letter PDF with Helvetica as /F1; content is the page's drawing operators."""
    stream = content.encode("latin-1")
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        b"<< /Length " + str(len(stream)).encode() + b" >>\nstream\n" + stream + b"\nendstream",
    ]
    out = bytearray(b"%PDF-1.4\n")
    offsets = []
    for n, body in enumerate(objects, 1):
        offsets.append(len(out))
        out += f"{n} 0 obj\n".encode() + body + b"\nendobj\n"
    xref = len(out)
    out += f"xref\n0 {len(objects) + 1}\n0000000000 65535 f \n".encode()
    for o in offsets:
        out += f"{o:010d} 00000 n \n".encode()
    out += f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode()
    with open(path, "wb") as f:
        f.write(out)

def text(x, y, size, s):
    return f"BT /F1 {size} Tf {x} {y} Td ({s}) Tj ET\n"

wireframe = "0.2 0.23 0.3 RG 0.2 0.23 0.3 rg\n" + text(72, 720, 22, "Home screen wireframe")
wireframe += text(72, 698, 11, "Draft 2 - layout only, no final copy")
wireframe += "1.2 w 72 120 468 560 re S\n"            # page frame
wireframe += "0.9 0.92 0.95 rg 72 620 468 60 re f\n"   # header bar
wireframe += "0.2 0.23 0.3 rg\n" + text(90, 645, 14, "Header")
wireframe += "0.82 0.86 0.9 rg 92 420 428 180 re f\n"  # hero
wireframe += "0.2 0.23 0.3 rg\n" + text(270, 505, 14, "Hero image")
for i in range(3):                                      # three cards
    wireframe += f"0.9 0.92 0.95 rg {92 + i * 148} 220 132 170 re f\n"
    wireframe += "0.2 0.23 0.3 rg\n" + text(120 + i * 148, 300, 12, f"Card {i + 1}")
wireframe += text(92, 150, 10, "Footer: links, contact, newsletter sign-up")
write_pdf(f"{work}/Project/Design/Wireframe.pdf", wireframe)

agreement = "0.1 0.1 0.12 rg\n" + text(72, 710, 20, "Service Agreement (Draft)")
lines = [
    "Between the Client and the Studio, for the spring website refresh.",
    "",
    "1. Scope: design and build of five pages, as listed in the project brief.",
    "2. Schedule: kickoff in March, launch in May.",
    "3. Payment: in two parts, at kickoff and at launch.",
    "4. Changes: requests outside the scope are quoted separately.",
]
for i, line in enumerate(lines):
    agreement += text(72, 670 - i * 20, 12, line)
write_pdf(f"{work}/Contracts/Service Agreement.pdf", agreement)
PY

for name in sunset mountain-lake coastline; do
  sips -s format jpeg -s formatOptions 80 "$work/raw/$name.png" --out "$work/raw/$name.jpg" >/dev/null
done
mv "$work/raw/sunset.jpg" "$work/Project/Photos/Sunset.jpg"
mv "$work/raw/mountain-lake.jpg" "$work/Project/Photos/Mountain Lake.jpg"
mv "$work/raw/coastline.jpg" "$work/Project/Photos/Coastline.jpg"

# ---------------------------------------------------------------------------------------------
# Text files.
cat > "$work/Project/README.md" <<'EOF'
# Spring Website Refresh

Shared files for the spring refresh of the studio website.

- **Design/**: palette, logo concept and the home screen wireframe
- **Docs/**: roadmap, meeting notes and the budget
- **Photos/**: candidate header images

Questions go in the weekly meeting notes.
EOF

cat > "$work/Project/Checklist.txt" <<'EOF'
Launch checklist

[x] Pick the colour palette
[x] Approve the logo concept
[ ] Final copy for the home page
[ ] Choose the header photo
[ ] Test on phone and tablet
[ ] Launch
EOF

cat > "$work/Project/Docs/Roadmap.md" <<'EOF'
# Roadmap

## March
- Kickoff and brief
- Palette and logo concept

## April
- Wireframes for all five pages
- First round of copy

## May
- Build and review
- Launch
EOF

cat > "$work/Project/Docs/Meeting Notes.md" <<'EOF'
# Weekly meeting notes

## Week 3
- The palette is approved; the coral accent stays.
- Two header photos are in the running: Coastline and Mountain Lake.
- Next: the card layout on the home page.

## Week 2
- Reviewed three logo concepts and picked the circular one.
- The wireframe needs a smaller hero on phones.
EOF

cat > "$work/Project/Docs/Budget.csv" <<'EOF'
Item,Hours,Rate,Total
Design,40,80,3200
Copy,16,70,1120
Build,60,85,5100
Photography,8,90,720
Total,124,,10140
EOF

cat > "$work/Contracts/Notes.txt" <<'EOF'
Notes on the draft agreement

- Confirm the launch date before signing.
- Add the hosting hand-off to the scope.
EOF

# ---------------------------------------------------------------------------------------------
# Zip with fixed times, modes and order, without extra attributes (-X).
find "$work/Project" "$work/Contracts" -type d -exec chmod 755 {} +
find "$work/Project" "$work/Contracts" -type f -exec chmod 644 {} +
find "$work/Project" "$work/Contracts" -exec touch -t 202603160930 {} +

make_zip() { # make_zip <output> <source dir> [zip options...]
  local out="$1" src="$2"; shift 2
  rm -f "$out"
  ( cd "$src" && find . -mindepth 1 | sed 's|^\./||' | sort | zip -q -X "$@" "$out" -@ )
}
make_zip "$here/Project.zip" "$work/Project"
make_zip "$here/Contracts.zip" "$work/Contracts" -P kernir
rm -f "$here/Contracts.7z"
( cd "$work/Contracts" && 7zz a -bso0 -bsp0 -t7z -mhe=on -pkernir "$here/Contracts.7z" Notes.txt "Service Agreement.pdf" )

zipinfo -1 "$here/Project.zip"
zipinfo -1 "$here/Contracts.zip"
7zz l -slt -pkernir "$here/Contracts.7z" | awk -F' = ' '$1 == "Path" && NR > 10 { print $2 }'
ls -l "$here/Project.zip" "$here/Contracts.zip" "$here/Contracts.7z"
