#!/usr/bin/env python3
"""Generate tests/fixture.pdf: one PDF exercising every image encoding Pluck handles,
plus tests/expected.json describing what extraction must produce.

Run: python3 tests/make_fixture.py   (needs Pillow)
"""
import io, json, os, struct, zlib
from PIL import Image, ImageCms

HERE = os.path.dirname(os.path.abspath(__file__))
W, H = 64, 32

objs = {}          # num -> bytes (full object body without "n 0 obj")
next_num = [1]

def alloc():
    n = next_num[0]; next_num[0] += 1; return n

def put(n, body: bytes):
    objs[n] = body

def stream(d: str, data: bytes, flate=True):
    if flate:
        data = zlib.compress(data)
        d += " /Filter /FlateDecode"
    return f"<< {d} /Length {len(data)} >>\nstream\n".encode() + data + b"\nendstream"

def image_obj(d, data, flate=True):
    n = alloc(); put(n, stream(f"/Type /XObject /Subtype /Image /Width {W} /Height {H} {d}", data, flate)); return n

def halves(left: bytes, right: bytes):
    row = left * (W // 2) + right * (W // 2)
    return row * H

def pack_bits(rows_of_samples, bpc):
    out = bytearray()
    for row in rows_of_samples:
        acc, nbits = 0, 0
        for s in row:
            acc = (acc << bpc) | s; nbits += bpc
            while nbits >= 8:
                nbits -= 8; out.append((acc >> nbits) & 0xFF)
        if nbits: out.append((acc << (8 - nbits)) & 0xFF)
    return bytes(out)

expected = []   # list of (page, checks, w, h)
def expect(page, checks, w=W, h=H, ext="png", jpeg=False):
    expected.append(dict(page=page, w=w, h=h, ext=ext, checks=checks, jpeg=jpeg))

L, R = (8, 16), (56, 16)   # sample points in left / right halves

# --- page 1 images ---------------------------------------------------------
im_rgb = image_obj("/ColorSpace /DeviceRGB /BitsPerComponent 8", halves(b"\xff\x00\x00", b"\x00\x00\xff"))
expect(1, [[*L, [255, 0, 0, 255], 2], [*R, [0, 0, 255, 255], 2]])

buf = io.BytesIO(); Image.new("RGB", (40, 40), (0, 200, 0)).save(buf, "JPEG", quality=95)
n = alloc(); jw = 40
put(n, stream(f"/Type /XObject /Subtype /Image /Width {jw} /Height {jw} /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode", buf.getvalue(), flate=False).replace(b" /Filter /FlateDecode", b""))
im_jpeg = n
expect(1, [[20, 20, [0, 200, 0, 255], 12]], w=40, h=40, jpeg=True)

smask = image_obj("/ColorSpace /DeviceGray /BitsPerComponent 8", halves(b"\x00", b"\xff"))
im_gray_sm = image_obj(f"/ColorSpace /DeviceGray /BitsPerComponent 8 /SMask {smask} 0 R", bytes([128]) * (W * H))
expect(1, [[*L, [None, None, None, 0], 2], [*R, [128, 128, 128, 255], 3]])

pal = bytes([0, 0, 0, 255, 255, 0, 0, 255, 255])
pal_hex = pal.hex().upper()
im_idx = image_obj(f"/ColorSpace [/Indexed /DeviceRGB 2 <{pal_hex}>] /BitsPerComponent 4",
                   pack_bits([[1] * (W // 2) + [2] * (W // 2)] * H, 4))
expect(1, [[*L, [255, 255, 0, 255], 2], [*R, [0, 255, 255, 255], 2]])

im_stencil = image_obj("/ImageMask true", pack_bits([[0] * (W // 2) + [1] * (W // 2)] * H, 1))
expect(1, [[*L, [0, 0, 0, 255], 2], [*R, [255, 255, 255, 255], 2]])

im_cmyk = image_obj("/ColorSpace /DeviceCMYK /BitsPerComponent 8", halves(b"\xff\x00\x00\x00", b"\x00\x00\x00\x00"))
# Pure cyan through a CMYK profile: low red, high blue; white stays white.
expect(1, [[*L, ["<90", None, ">170", 255], 0], [*R, [">245", ">245", ">245", 255], 0]])

icc = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
n_icc = alloc(); put(n_icc, stream("/N 3", icc))
im_icc = image_obj("/ColorSpace /CS0 /BitsPerComponent 8", bytes([10, 200, 30]) * (W * H))
expect(1, [[*L, [10, 200, 30, 255], 6]])

im_bw_inv = image_obj("/ColorSpace /DeviceGray /BitsPerComponent 1 /Decode [1 0]", pack_bits([[1] * W] * H, 1))
form = alloc()
form_content = b"q 64 0 0 32 0 0 cm /ImF Do Q"
put(form, stream(f"/Type /XObject /Subtype /Form /BBox [0 0 64 32] /Resources << /XObject << /ImF {im_bw_inv} 0 R >> >>", form_content))
expect(1, [[*L, [0, 0, 0, 255], 2]])

im_ck = image_obj("/ColorSpace /DeviceRGB /BitsPerComponent 8 /Mask [250 255 0 5 0 5]", halves(b"\xff\x00\x00", b"\xff\xff\xff"))
expect(1, [[*L, [None, None, None, 0], 0], [*R, [255, 255, 255, 255], 2]])

fn = alloc(); put(fn, b"<< /FunctionType 2 /Domain [0 1] /C0 [1] /C1 [0] /N 1 >>")
im_sep = image_obj(f"/ColorSpace [/Separation /Spot /DeviceGray {fn} 0 R] /BitsPerComponent 8", halves(b"\xff", b"\x00"))
expect(1, [[*L, [0, 0, 0, 255], 2], [*R, [255, 255, 255, 255], 2]])

im_16 = image_obj("/ColorSpace /DeviceRGB /BitsPerComponent 16", struct.pack(">HHH", 0xFFFF, 0, 0x8000) * (W * H))
expect(1, [[*L, [255, 0, 128, 255], 2]])

# --- page 2 images ---------------------------------------------------------
im_lab = image_obj("/ColorSpace [/Lab << /WhitePoint [0.9642 1 0.8249] /Range [-128 127 -128 127] >>] /BitsPerComponent 8",
                   bytes([128, 128, 128]) * (W * H))   # L≈50, a≈0, b≈0 -> mid gray
expect(2, [[*L, [119, 119, 119, 255], 8]])

lut = alloc(); put(lut, stream("", bytes([255, 255, 255, 200, 0, 100])))
im_idx_stream = image_obj(f"/ColorSpace [/Indexed /DeviceRGB 1 {lut} 0 R] /BitsPerComponent 1",
                          pack_bits([[0] * (W // 2) + [1] * (W // 2)] * H, 1))
expect(2, [[*L, [255, 255, 255, 255], 2], [*R, [200, 0, 100, 255], 2]])

# --- pages -------------------------------------------------------------------
def draw(names):
    parts = []
    for i, nm in enumerate(names):
        x, y = 20 + (i % 4) * 140, 700 - (i // 4) * 90
        parts.append(f"q 128 0 0 64 {x} {y} cm /{nm} Do Q")
    return " ".join(parts).encode()

p1_x = {"Im1": im_rgb, "Im2": im_jpeg, "Im3": im_gray_sm, "Im4": im_idx, "Im5": im_stencil,
        "Im6": im_cmyk, "Im7": im_icc, "Fm1": form, "Im9": im_ck, "Im10": im_sep, "Im11": im_16}
p1_order = ["Im1", "Im2", "Im3", "Im4", "Im5", "Im6", "Im7", "Fm1", "Im9", "Im10", "Im11", "Im1"]  # Im1 twice: dedupe
p2_x = {"ImA": im_lab, "ImB": im_idx_stream}
p2_order = ["ImA", "ImB"]

pages = alloc()
kids = []
for xo, order in ((p1_x, p1_order), (p2_x, p2_order)):
    c = alloc(); put(c, stream("", draw(order)))
    pg = alloc(); kids.append(pg)
    xd = " ".join(f"/{k} {v} 0 R" for k, v in xo.items())
    put(pg, f"<< /Type /Page /Parent {pages} 0 R /MediaBox [0 0 612 792] /Contents {c} 0 R "
            f"/Resources << /XObject << {xd} >> /ColorSpace << /CS0 [/ICCBased {n_icc} 0 R] >> >> >>".encode())
put(pages, f"<< /Type /Pages /Count {len(kids)} /Kids [{' '.join(f'{k} 0 R' for k in kids)}] >>".encode())
cat = alloc(); put(cat, f"<< /Type /Catalog /Pages {pages} 0 R >>".encode())
info = alloc(); put(info, b"<< /Title (Pluck Test Fixture) >>")

out = bytearray(b"%PDF-1.7\n%\xe2\xe3\xcf\xd3\n")
offsets = {}
for num in sorted(objs):
    offsets[num] = len(out)
    out += f"{num} 0 obj\n".encode() + objs[num] + b"\nendobj\n"
xref = len(out)
total = max(objs) + 1
out += f"xref\n0 {total}\n0000000000 65535 f \n".encode()
for num in range(1, total):
    out += f"{offsets[num]:010d} 00000 n \n".encode()
out += f"trailer\n<< /Size {total} /Root {cat} 0 R /Info {info} 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode()

with open(os.path.join(HERE, "fixture.pdf"), "wb") as f:
    f.write(out)

# number images per page in draw order
files, counters = [], {}
for e in expected:
    counters[e["page"]] = counters.get(e["page"], 0) + 1
    e["file"] = f"fixture_page_{e['page']}_{counters[e['page']]}"
    files.append(e)
with open(os.path.join(HERE, "expected.json"), "w") as f:
    json.dump(files, f, indent=1)
print(f"wrote fixture.pdf ({len(out)} bytes) with {len(files)} expected images")
