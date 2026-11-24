<p align="center"><img src="Resources/AppIcon.png" width="128" alt="Pluck icon"></p>

# Pluck — extract images from any PDF, straight from the Print dialog

Pluck adds **Extract Images to Downloads** to the **PDF ▾** menu of every macOS Print dialog.
Print anything (a web page, a return label, an invoice), pick it, and every embedded image lands in
`~/Downloads/<document name> images/` — no Stirling-PDF round trip.

Output matches Stirling-PDF's *Extract Images*: one PNG per image, named
`<document name>_page_<page>_<n>.png`, at the image's native resolution.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/au12/PDFIMGMAC/main/get.sh | bash
```

Or build from source (needs Xcode Command Line Tools):

```bash
git clone https://github.com/au12/PDFIMGMAC && cd PDFIMGMAC && ./install.sh
```

Requires macOS 13+ on Apple Silicon. The first run asks for access to **Downloads** — click Allow.

## Use

1. **⌘P** in any app
2. Click the **PDF ▾** button at the bottom-left of the Print dialog
3. Choose **Extract Images to Downloads**

Finder opens with the new folder selected.

**Tip — make it ⌘P ⌘P:** System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ App Shortcuts ▸ **+** ▸
*All Applications*, Menu title `Extract Images to Downloads`, shortcut **⌘P**. Pressing ⌘P inside the Print
dialog then fires Pluck directly.

## Settings

Open the app directly to change settings (they apply to the Print menu too):

```bash
open ~/Library/PDF\ Services/Extract\ Images\ to\ Downloads.app
```

- **Folder or .zip** in Downloads
- **Keep JPEG photos as original .jpg** — writes JPEG/JPEG 2000 streams byte-for-byte instead of re-encoding to PNG
- **Show in Finder** when done

The settings window also has **Extract from PDF…** for files already on disk.

## Command line

The installer links `~/.local/bin/pluck`:

```bash
pluck --extract file.pdf [more.pdf…] [--out DIR] [--zip] [--keep-jpeg]
```

## What it handles

Uses Quartz's PDF parser (no dependencies) and walks each page's content stream in drawing order, including
images nested in Form XObjects, deduplicating repeats per page.

| Encoding | Support |
|---|---|
| Flate / LZW / RunLength / ASCII filters | ✓ |
| JPEG (DCT), JPEG 2000 | ✓ (or pass-through with *Keep JPEG*) |
| CCITT G3/G4, JBIG2 | ✓ where Quartz decodes them |
| DeviceGray / RGB / CMYK, ICCBased, CalGray/CalRGB, Lab | ✓ (CMYK & ICC color-managed via ColorSync) |
| Indexed (string or stream palette), Separation, DeviceN | ✓ (spot colors rendered as ink density) |
| 1/2/4/8/16 bits per component, `/Decode` arrays | ✓ |
| Soft masks (`/SMask`, incl. `/Matte`), stencil masks, color-key masks | ✓ → PNG alpha |
| Image masks (`/ImageMask`) | ✓ black on white |
| Inline images (`BI … EI`) | ✗ skipped (Stirling skips these too) |

## Why a PDF Service and not a "real" printer?

macOS has no supported way for a third-party app to add a virtual printer anymore: CUPS backends live on the
read-only system volume and run sandboxed as `_lp`, which can't write to your Downloads folder.
`~/Library/PDF Services` is Apple's own mechanism for "print to something" workflows — it's how
*Open in Preview* and *Save as PDF* work — and it's available in every app's Print dialog.

## Uninstall

`./uninstall.sh` from a checkout, or:

```bash
rm -rf ~/Library/PDF\ Services/Extract\ Images\ to\ Downloads.app ~/.local/bin/pluck
```

## Development

```bash
./build.sh                                   # → build/Pluck.app
python3 tests/make_fixture.py                # synthetic PDF covering every encoding above
build/Pluck.app/Contents/MacOS/Pluck --extract tests/fixture.pdf --out out
python3 tests/verify.py "out/fixture images"
```

CI (`.github/workflows/build.yml`) builds on an Apple Silicon runner, runs the fixture tests in PNG, keep-JPEG
and zip modes, and publishes `Pluck.zip` to the rolling `latest` release used by `get.sh`.
