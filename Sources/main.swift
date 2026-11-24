// Pluck — pull every embedded image out of a PDF.
//
// Installed into ~/Library/PDF Services, it appears in every macOS Print dialog
// under the "PDF" menu as "Extract Images to Downloads". It can also be run
// directly (shows settings) or from the command line:
//
//   Pluck --extract file.pdf [more.pdf ...] [--out DIR]
//
// Output naming matches Stirling-PDF: "<name>_page_<p>_<n>.png".

import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Settings

enum Prefs {
    static let d = UserDefaults.standard
    static var outputMode: String { d.string(forKey: "outputMode") ?? "folder" }  // "folder" | "zip"
    static var keepJPEG: Bool { d.bool(forKey: "keepJPEG") }
    static var reveal: Bool { d.object(forKey: "revealInFinder") as? Bool ?? true }
}

// MARK: - Small CGPDF helpers

private func dName(_ d: CGPDFDictionaryRef, _ k: String) -> String? {
    var p: UnsafePointer<CChar>?
    guard CGPDFDictionaryGetName(d, k, &p), let p else { return nil }
    return String(cString: p)
}
private func dInt(_ d: CGPDFDictionaryRef, _ k: String) -> Int? {
    var v: CGPDFInteger = 0
    if CGPDFDictionaryGetInteger(d, k, &v) { return Int(v) }
    var r: CGPDFReal = 0
    if CGPDFDictionaryGetNumber(d, k, &r) { return Int(r) }
    return nil
}
private func dBool(_ d: CGPDFDictionaryRef, _ k: String) -> Bool {
    var b: CGPDFBoolean = 0
    return CGPDFDictionaryGetBoolean(d, k, &b) && b != 0
}
private func dArray(_ d: CGPDFDictionaryRef, _ k: String) -> CGPDFArrayRef? {
    var a: CGPDFArrayRef?
    return CGPDFDictionaryGetArray(d, k, &a) ? a : nil
}
private func dDict(_ d: CGPDFDictionaryRef, _ k: String) -> CGPDFDictionaryRef? {
    var a: CGPDFDictionaryRef?
    return CGPDFDictionaryGetDictionary(d, k, &a) ? a : nil
}
private func dStream(_ d: CGPDFDictionaryRef, _ k: String) -> CGPDFStreamRef? {
    var s: CGPDFStreamRef?
    return CGPDFDictionaryGetStream(d, k, &s) ? s : nil
}
private func dObject(_ d: CGPDFDictionaryRef, _ k: String) -> CGPDFObjectRef? {
    var o: CGPDFObjectRef?
    return CGPDFDictionaryGetObject(d, k, &o) ? o : nil
}
private func aNumbers(_ a: CGPDFArrayRef) -> [Double] {
    (0..<CGPDFArrayGetCount(a)).map { i in
        var r: CGPDFReal = 0
        return CGPDFArrayGetNumber(a, i, &r) ? Double(r) : 0
    }
}
private func aName(_ a: CGPDFArrayRef, _ i: Int) -> String? {
    var p: UnsafePointer<CChar>?
    guard CGPDFArrayGetName(a, i, &p), let p else { return nil }
    return String(cString: p)
}
private func streamData(_ s: CGPDFStreamRef) -> (Data, CGPDFDataFormat)? {
    var fmt = CGPDFDataFormat.raw
    guard let cf = CGPDFStreamCopyData(s, &fmt) else { return nil }
    return (cf as Data, fmt)
}

// MARK: - Color spaces

indirect enum PDFColorSpace {
    case gray, rgb, cmyk
    case icc(CGColorSpace, Int)
    case indexed(PDFColorSpace, Int, [UInt8])
    case separation          // 1 tint component, rendered as gray ink
    case deviceN(Int)
    case lab([Double])       // Range [amin amax bmin bmax]

    var components: Int {
        switch self {
        case .gray, .separation: return 1
        case .rgb, .lab: return 3
        case .cmyk: return 4
        case .icc(_, let n): return n
        case .indexed: return 1
        case .deviceN(let n): return n
        }
    }

    /// Default Decode ranges for one component index.
    func defaultDecode(bpc: Int) -> [Double] {
        switch self {
        case .indexed: return [0, Double((1 << bpc) - 1)]
        case .lab(let r): return [0, 100, r[0], r[1], r[2], r[3]]
        default: return Array(repeating: [0.0, 1.0], count: components).flatMap { $0 }
        }
    }

    static func parse(_ obj: CGPDFObjectRef, cs: CGPDFContentStreamRef?, depth: Int = 0) -> PDFColorSpace? {
        guard depth < 8 else { return nil }
        switch CGPDFObjectGetType(obj) {
        case .name:
            var p: UnsafePointer<CChar>?
            guard CGPDFObjectGetValue(obj, .name, &p), let p else { return nil }
            return named(String(cString: p), cs: cs, depth: depth)
        case .array:
            var a: CGPDFArrayRef?
            guard CGPDFObjectGetValue(obj, .array, &a), let a else { return nil }
            return fromArray(a, cs: cs, depth: depth)
        default:
            return nil
        }
    }

    static func named(_ n: String, cs: CGPDFContentStreamRef?, depth: Int) -> PDFColorSpace? {
        switch n {
        case "DeviceGray", "G", "CalGray": return .gray
        case "DeviceRGB", "RGB", "CalRGB": return .rgb
        case "DeviceCMYK", "CMYK": return .cmyk
        default:
            // A named resource in the page/form /ColorSpace dictionary.
            guard let cs, let o = n.withCString({ CGPDFContentStreamGetResource(cs, "ColorSpace", $0) }) else { return nil }
            return parse(o, cs: cs, depth: depth + 1)
        }
    }

    static func fromArray(_ a: CGPDFArrayRef, cs: CGPDFContentStreamRef?, depth: Int) -> PDFColorSpace? {
        guard CGPDFArrayGetCount(a) > 0, let family = aName(a, 0) else { return nil }
        switch family {
        case "DeviceGray", "CalGray", "G": return .gray
        case "DeviceRGB", "CalRGB", "RGB": return .rgb
        case "DeviceCMYK", "CMYK": return .cmyk
        case "Lab":
            var d: CGPDFDictionaryRef?
            var range: [Double] = [-100, 100, -100, 100]
            if CGPDFArrayGetDictionary(a, 1, &d), let d, let r = dArray(d, "Range") {
                let v = aNumbers(r); if v.count == 4 { range = v }
            }
            return .lab(range)
        case "ICCBased":
            var s: CGPDFStreamRef?
            guard CGPDFArrayGetStream(a, 1, &s), let s, let sd = CGPDFStreamGetDictionary(s) else { return nil }
            let n = dInt(sd, "N") ?? 3
            if let (data, _) = streamData(s), let space = CGColorSpace(iccData: data as CFData),
               space.numberOfComponents == n {
                return .icc(space, n)
            }
            if let alt = dObject(sd, "Alternate"), let p = parse(alt, cs: cs, depth: depth + 1) { return p }
            return n == 1 ? .gray : n == 4 ? .cmyk : .rgb
        case "Indexed", "I":
            var baseObj: CGPDFObjectRef?
            guard CGPDFArrayGetObject(a, 1, &baseObj), let baseObj,
                  let base = parse(baseObj, cs: cs, depth: depth + 1) else { return nil }
            var hival: CGPDFInteger = 0
            _ = CGPDFArrayGetInteger(a, 2, &hival)
            var table = [UInt8]()
            var str: CGPDFStringRef?
            var st: CGPDFStreamRef?
            if CGPDFArrayGetString(a, 3, &str), let str, let bp = CGPDFStringGetBytePtr(str) {
                table = Array(UnsafeBufferPointer(start: bp, count: CGPDFStringGetLength(str)))
            } else if CGPDFArrayGetStream(a, 3, &st), let st, let (d, _) = streamData(st) {
                table = [UInt8](d)
            }
            return .indexed(base, Int(hival), table)
        case "Separation":
            return .separation
        case "DeviceN":
            var names: CGPDFArrayRef?
            let n = CGPDFArrayGetArray(a, 1, &names) && names != nil ? CGPDFArrayGetCount(names!) : 1
            return .deviceN(max(1, n))
        case "Pattern":
            return nil
        default:
            return nil
        }
    }
}

// MARK: - Image decoding

struct DecodeError: Error {}

/// A decoded image: 8-bit RGBA, non-premultiplied, row-major.
struct RGBAImage {
    var width: Int, height: Int
    var pixels: [UInt8]
}

enum ImageDecoder {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Returns (encoded file bytes, file extension).
    static func extract(_ stream: CGPDFStreamRef, cs: CGPDFContentStreamRef, keepJPEG: Bool) throws -> (Data, String) {
        guard let dict = CGPDFStreamGetDictionary(stream), let (data, fmt) = streamData(stream) else { throw DecodeError() }
        let hasMask = dStream(dict, "SMask") != nil || dObject(dict, "Mask") != nil

        if fmt == .jpegEncoded && keepJPEG && !hasMask {
            return (data, "jpg")
        }
        if fmt == .JPEG2000 && keepJPEG && !hasMask {
            return (data, "jp2")
        }
        var img = try decode(dict: dict, data: data, format: fmt, cs: cs)
        try applyMasks(&img, dict: dict, cs: cs)
        guard let png = encodePNG(img) else { throw DecodeError() }
        return (png, "png")
    }

    /// Decodes any image stream (no masks applied) to RGBA.
    static func decode(dict: CGPDFDictionaryRef, data: Data, format: CGPDFDataFormat,
                       cs: CGPDFContentStreamRef?) throws -> RGBAImage {
        if format == .jpegEncoded || format == .JPEG2000 {
            guard let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw DecodeError() }
            return try render(cg)
        }
        guard let w = dInt(dict, "Width"), let h = dInt(dict, "Height"), w > 0, h > 0, w * h < 400_000_000 else {
            throw DecodeError()
        }
        let isStencil = dBool(dict, "ImageMask")
        let bpc = isStencil ? 1 : (dInt(dict, "BitsPerComponent") ?? 8)
        guard [1, 2, 4, 8, 16].contains(bpc) else { throw DecodeError() }

        let space: PDFColorSpace
        if isStencil {
            space = .gray
        } else if let o = dObject(dict, "ColorSpace"), let s = PDFColorSpace.parse(o, cs: cs) {
            space = s
        } else {
            space = .gray  // e.g. soft masks; best guess otherwise
        }
        let n = space.components
        var decodeArr = space.defaultDecode(bpc: bpc)
        if let da = dArray(dict, "Decode") {
            let v = aNumbers(da); if v.count >= 2 * n { decodeArr = Array(v.prefix(2 * n)) }
        }
        if isStencil {
            // Stencil: sample 0 = paint (black) with default Decode [0 1].
            decodeArr = (decodeArr.first ?? 0) == 1 ? [1, 0] : [0, 1]
        }

        // Color-key masking: Mask is an array of [min max] per component (raw sample values).
        var colorKey: [Int]? = nil
        if let o = dObject(dict, "Mask"), CGPDFObjectGetType(o) == .array {
            var a: CGPDFArrayRef?
            if CGPDFObjectGetValue(o, .array, &a), let a {
                let v = aNumbers(a).map { Int($0) }
                if v.count >= 2 * n { colorKey = v }
            }
        }

        let rowBytes = (w * n * bpc + 7) / 8
        var bytes = [UInt8](data)
        if bytes.count < rowBytes * h { bytes += [UInt8](repeating: 0, count: rowBytes * h - bytes.count) }

        let maxv = Double((1 << bpc) - 1)
        var out = [UInt8](repeating: 255, count: w * h * 4)
        var comps = [Double](repeating: 0, count: n)
        var raw = [Int](repeating: 0, count: n)

        // Precompute 8-bit lookups per component for speed when not indexed/lab.
        let lutSize = 1 << min(bpc, 8)
        var luts = [[UInt8]]()
        for c in 0..<n {
            let dmin = decodeArr[2 * c], dmax = decodeArr[2 * c + 1]
            let lm = Double(lutSize - 1)
            luts.append((0..<lutSize).map { v in
                let x = dmin + Double(v) * (dmax - dmin) / lm
                return UInt8(max(0, min(255, (x * 255).rounded())))
            })
        }

        // Indexed images: expand the palette once.
        var palette = [UInt8]()
        if case .indexed(let base, let hival, let table) = space {
            let bn = base.components
            for idx in 0...max(0, hival) {
                var bc = [Double](repeating: 0, count: bn)
                for k in 0..<bn {
                    let ti = idx * bn + k
                    bc[k] = ti < table.count ? Double(table[ti]) / 255 : 0
                }
                let (r, g, b) = toRGB(base, bc)
                palette += [r, g, b]
            }
        }
        let isIndexed = !palette.isEmpty
        let paletteMax = palette.count / 3 - 1
        let isLab: Bool = { if case .lab = space { return true }; return false }()

        bytes.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h {
                    let rowBase = y * rowBytes
                    for x in 0..<w {
                        // read n samples
                        for c in 0..<n {
                            let sampleIndex = x * n + c
                            let v: Int
                            switch bpc {
                            case 8: v = Int(src[rowBase + sampleIndex])
                            case 16: v = Int(src[rowBase + sampleIndex * 2]) << 8 | Int(src[rowBase + sampleIndex * 2 + 1])
                            default:
                                let bit = sampleIndex * bpc
                                let byte = Int(src[rowBase + (bit >> 3)])
                                let shift = 8 - bpc - (bit & 7)
                                v = (byte >> shift) & ((1 << bpc) - 1)
                            }
                            raw[c] = v
                        }
                        let o = (y * w + x) * 4
                        var r: UInt8 = 0, g: UInt8 = 0, b: UInt8 = 0, a: UInt8 = 255

                        if isIndexed {
                            let idx = min(max(0, raw[0]), paletteMax) * 3
                            r = palette[idx]; g = palette[idx + 1]; b = palette[idx + 2]
                        } else if isLab {
                            for c in 0..<n {
                                let dmin = decodeArr[2 * c], dmax = decodeArr[2 * c + 1]
                                comps[c] = dmin + Double(raw[c]) * (dmax - dmin) / maxv
                            }
                            (r, g, b) = labToRGB(comps[0], comps[1], comps[2])
                        } else {
                            for c in 0..<n {
                                let v8 = bpc == 16 ? raw[c] >> 8 : raw[c]
                                comps[c] = Double(luts[c][v8]) / 255
                            }
                            (r, g, b) = toRGB(space, comps)
                        }

                        if let ck = colorKey {
                            var inside = true
                            for c in 0..<n where raw[c] < ck[2 * c] || raw[c] > ck[2 * c + 1] { inside = false; break }
                            if inside { a = 0 }
                        }
                        dst[o] = r; dst[o + 1] = g; dst[o + 2] = b; dst[o + 3] = a
                    }
                }
            }
        }

        // ICC / CMYK need a real color conversion: let Quartz do it.
        switch space {
        case .cmyk, .icc:
            if let converted = convertThroughQuartz(bytes: bytes, w: w, h: h, bpc: bpc, rowBytes: rowBytes,
                                                    space: space, decode: decodeArr) {
                // keep alpha from color key
                var c = converted
                for i in stride(from: 3, to: c.pixels.count, by: 4) { c.pixels[i] = out[i] }
                return c
            }
        default: break
        }
        return RGBAImage(width: w, height: h, pixels: out)
    }

    /// Approximate conversion used for the fast path (and as a fallback).
    static func toRGB(_ space: PDFColorSpace, _ c: [Double]) -> (UInt8, UInt8, UInt8) {
        func u(_ v: Double) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        switch space {
        case .gray: return (u(c[0]), u(c[0]), u(c[0]))
        case .rgb: return (u(c[0]), u(c[1]), u(c[2]))
        case .cmyk:
            let k = c[3]
            return (u((1 - c[0]) * (1 - k)), u((1 - c[1]) * (1 - k)), u((1 - c[2]) * (1 - k)))
        case .icc(_, let n):
            if n == 1 { return (u(c[0]), u(c[0]), u(c[0])) }
            if n == 4 { return toRGB(.cmyk, c) }
            return (u(c[0]), u(c[1]), u(c[2]))
        case .separation: return (u(1 - c[0]), u(1 - c[0]), u(1 - c[0]))
        case .deviceN: let m = c.max() ?? 0; return (u(1 - m), u(1 - m), u(1 - m))
        case .lab: return labToRGB(c[0] * 100, c[1], c[2])
        case .indexed: return (0, 0, 0)
        }
    }

    static func labToRGB(_ L: Double, _ A: Double, _ B: Double) -> (UInt8, UInt8, UInt8) {
        // Lab (D50) -> XYZ -> linear sRGB (Bradford-adapted to D65) -> sRGB
        let fy = (L + 16) / 116, fx = fy + A / 500, fz = fy - B / 200
        func finv(_ t: Double) -> Double { t > 6.0 / 29 ? t * t * t : 3 * (6.0 / 29) * (6.0 / 29) * (t - 4.0 / 29) }
        let X = 0.9642 * finv(fx), Y = finv(fy), Z = 0.8249 * finv(fz)
        var r = 3.1338561 * X - 1.6168667 * Y - 0.4906146 * Z
        var g = -0.9787684 * X + 1.9161415 * Y + 0.0334540 * Z
        var b = 0.0719453 * X - 0.2289914 * Y + 1.4052427 * Z
        func gam(_ v: Double) -> Double { v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055 }
        r = gam(r); g = gam(g); b = gam(b)
        func u(_ v: Double) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        return (u(r), u(g), u(b))
    }

    /// Builds a CGImage in the source color space (CMYK / ICC) and lets Quartz convert it to sRGB.
    static func convertThroughQuartz(bytes: [UInt8], w: Int, h: Int, bpc: Int, rowBytes: Int,
                                     space: PDFColorSpace, decode: [Double]) -> RGBAImage? {
        let cgSpace: CGColorSpace
        switch space {
        case .cmyk: cgSpace = CGColorSpaceCreateDeviceCMYK()
        case .icc(let s, _): cgSpace = s
        default: return nil
        }
        guard bpc == 8 || bpc == 16 || bpc == 1 || bpc == 2 || bpc == 4 else { return nil }
        let decodeCG = decode.map { CGFloat($0) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: bpc,
                               bitsPerPixel: bpc * cgSpace.numberOfComponents, bytesPerRow: rowBytes,
                               space: cgSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                               provider: provider, decode: decodeCG, shouldInterpolate: false,
                               intent: .defaultIntent) else { return nil }
        return try? render(cg)
    }

    /// Renders any CGImage to non-premultiplied 8-bit RGBA (sRGB).
    static func render(_ cg: CGImage, width: Int? = nil, height: Int? = nil) throws -> RGBAImage {
        let w = width ?? cg.width, h = height ?? cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let hasAlpha: Bool = {
            switch cg.alphaInfo { case .none, .noneSkipFirst, .noneSkipLast: return false; default: return true }
        }()
        let info = hasAlpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        let ok: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: sRGB, bitmapInfo: info) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { throw DecodeError() }
        if hasAlpha {
            for i in stride(from: 0, to: px.count, by: 4) {
                let a = Int(px[i + 3])
                if a > 0 && a < 255 {
                    for k in 0..<3 { px[i + k] = UInt8(min(255, Int(px[i + k]) * 255 / a)) }
                }
            }
        } else {
            for i in stride(from: 3, to: px.count, by: 4) { px[i] = 255 }
        }
        return RGBAImage(width: w, height: h, pixels: px)
    }

    /// Decodes a mask stream to a single gray channel at the target size.
    static func maskChannel(_ s: CGPDFStreamRef, w: Int, h: Int, cs: CGPDFContentStreamRef) throws -> ([UInt8], CGPDFDictionaryRef) {
        guard let md = CGPDFStreamGetDictionary(s), let (data, fmt) = streamData(s) else { throw DecodeError() }
        var m = try decode(dict: md, data: data, format: fmt, cs: cs)
        if m.width != w || m.height != h {
            // resample via Quartz
            guard let cg = makeCGImage(m) else { throw DecodeError() }
            m = try render(cg, width: w, height: h)
        }
        var ch = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) { ch[i] = m.pixels[i * 4] }  // gray → R channel
        return (ch, md)
    }

    static func applyMasks(_ img: inout RGBAImage, dict: CGPDFDictionaryRef, cs: CGPDFContentStreamRef) throws {
        let w = img.width, h = img.height
        if let sm = dStream(dict, "SMask"), let (alpha, md) = try? maskChannel(sm, w: w, h: h, cs: cs) {
            let matte: [Double]? = dArray(md, "Matte").map { aNumbers($0).map { $0 * 255 } }
            for i in 0..<(w * h) {
                let a = alpha[i]
                img.pixels[i * 4 + 3] = min(img.pixels[i * 4 + 3], a)
                if let matte, matte.count >= 3, a > 0 {
                    let af = Double(a) / 255
                    for k in 0..<3 {
                        let c = Double(img.pixels[i * 4 + k])
                        img.pixels[i * 4 + k] = UInt8(max(0, min(255, ((c - matte[k]) / af + matte[k]).rounded())))
                    }
                }
            }
        } else if let mo = dObject(dict, "Mask"), CGPDFObjectGetType(mo) == .stream {
            var ms: CGPDFStreamRef?
            if CGPDFObjectGetValue(mo, .stream, &ms), let ms, let (ch, _) = try? maskChannel(ms, w: w, h: h, cs: cs) {
                // Stencil decodes to black (0) where the image is painted.
                for i in 0..<(w * h) { img.pixels[i * 4 + 3] = min(img.pixels[i * 4 + 3], 255 - ch[i]) }
            }
        }
    }

    static func makeCGImage(_ img: RGBAImage) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(img.pixels) as CFData) else { return nil }
        return CGImage(width: img.width, height: img.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: img.width * 4, space: sRGB,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    static func encodePNG(_ img: RGBAImage) -> Data? {
        guard let cg = makeCGImage(img) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}

// MARK: - Walking the PDF

struct ExtractedImage { let page: Int; let index: Int; let data: Data; let ext: String }

final class Extractor {
    private(set) var images: [ExtractedImage] = []
    private(set) var failures = 0
    private let keepJPEG: Bool
    private var page = 0
    private var pageCount = 0
    private var seen = Set<UnsafeRawPointer>()
    private var formStack = Set<UnsafeRawPointer>()

    init(keepJPEG: Bool) { self.keepJPEG = keepJPEG }

    func run(_ url: URL) throws {
        guard let doc = CGPDFDocument(url as CFURL) else { throw DecodeError() }
        if doc.isEncrypted && !doc.isUnlocked { _ = doc.unlockWithPassword("") }
        guard doc.numberOfPages > 0 else { return }
        for p in 1...doc.numberOfPages {
            guard let pg = doc.page(at: p) else { continue }
            page = p; pageCount = 0; seen.removeAll()
            let cs = CGPDFContentStreamCreateWithPage(pg)
            scan(cs)
            CGPDFContentStreamRelease(cs)
        }
    }

    fileprivate func scan(_ cs: CGPDFContentStreamRef) {
        guard let table = CGPDFOperatorTableCreate() else { return }
        CGPDFOperatorTableSetCallback(table, "Do", doCallback)
        let scanner = CGPDFScannerCreate(cs, table, Unmanaged.passUnretained(self).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFOperatorTableRelease(table)
    }

    fileprivate func handleXObject(_ stream: CGPDFStreamRef, cs: CGPDFContentStreamRef) {
        guard let dict = CGPDFStreamGetDictionary(stream) else { return }
        let key = UnsafeRawPointer(stream)
        switch dName(dict, "Subtype") {
        case "Form":
            guard !formStack.contains(key) else { return }
            formStack.insert(key); defer { formStack.remove(key) }
            let res = dDict(dict, "Resources") ?? dict
            let fcs = CGPDFContentStreamCreateWithStream(stream, res, cs)
            scan(fcs)
            CGPDFContentStreamRelease(fcs)
        case "Image":
            guard !seen.contains(key) else { return }
            seen.insert(key)
            do {
                let (data, ext) = try ImageDecoder.extract(stream, cs: cs, keepJPEG: keepJPEG)
                pageCount += 1
                images.append(ExtractedImage(page: page, index: pageCount, data: data, ext: ext))
            } catch {
                failures += 1
            }
        default:
            return
        }
    }
}

private let doCallback: CGPDFOperatorCallback = { scanner, info in
    guard let info else { return }
    let ex = Unmanaged<Extractor>.fromOpaque(info).takeUnretainedValue()
    var name: UnsafePointer<CChar>?
    guard CGPDFScannerPopName(scanner, &name), let name else { return }
    let cs = CGPDFScannerGetContentStream(scanner)
    guard let obj = CGPDFContentStreamGetResource(cs, "XObject", name) else { return }
    var stream: CGPDFStreamRef?
    guard CGPDFObjectGetValue(obj, .stream, &stream), let stream else { return }
    ex.handleXObject(stream, cs: cs)
}

// MARK: - Output

struct JobResult { let output: URL?; let count: Int; let failures: Int; let name: String }

enum Job {
    static func baseName(for pdf: URL, title: String?) -> String {
        var candidates = [String]()
        if let title, !title.isEmpty { candidates.append(title) }
        candidates.append(pdf.deletingPathExtension().lastPathComponent)
        if let doc = CGPDFDocument(pdf as CFURL), let info = doc.info {
            var s: CGPDFStringRef?
            if CGPDFDictionaryGetString(info, "Title", &s), let s, let t = CGPDFStringCopyTextString(s) {
                candidates.append(t as String)
            }
        }
        func looksGeneric(_ s: String) -> Bool {
            let t = s.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.lowercased().hasPrefix("untitled") { return true }
            // UUID-ish / job-id-ish names from the print spooler
            if t.range(of: "^[0-9A-Fa-f-]{16,}$", options: .regularExpression) != nil { return true }
            return false
        }
        let pick = candidates.first { !looksGeneric($0) } ?? "PDF"
        var clean = pick.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasSuffix(".pdf") { clean = String(clean.dropLast(4)) }
        if clean.count > 120 { clean = String(clean.prefix(120)) }
        return clean.isEmpty ? "PDF" : clean
    }

    static func uniqueURL(in dir: URL, name: String, ext: String?) -> URL {
        let fm = FileManager.default
        func make(_ n: String) -> URL {
            ext.map { dir.appendingPathComponent(n).appendingPathExtension($0) } ?? dir.appendingPathComponent(n, isDirectory: true)
        }
        var u = make(name), i = 2
        while fm.fileExists(atPath: u.path) { u = make("\(name) \(i)"); i += 1 }
        return u
    }

    static func run(pdf: URL, title: String?, outDir: URL? = nil, mode: String = Prefs.outputMode,
                    keepJPEG: Bool = Prefs.keepJPEG) throws -> JobResult {
        let ex = Extractor(keepJPEG: keepJPEG)
        try ex.run(pdf)
        let base = baseName(for: pdf, title: title)
        guard !ex.images.isEmpty else { return JobResult(output: nil, count: 0, failures: ex.failures, name: base) }

        let fm = FileManager.default
        let dest = outDir ?? fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)

        let staging: URL
        if mode == "zip" {
            let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            staging = tmp.appendingPathComponent("\(base) images", isDirectory: true)
        } else {
            staging = uniqueURL(in: dest, name: "\(base) images", ext: nil)
        }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        for img in ex.images {
            let f = staging.appendingPathComponent("\(base)_page_\(img.page)_\(img.index).\(img.ext)")
            try img.data.write(to: f)
        }

        var output = staging
        if mode == "zip" {
            let zip = uniqueURL(in: dest, name: "\(base) images", ext: "zip")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-c", "-k", "--keepParent", staging.path, zip.path]
            try p.run(); p.waitUntilExit()
            try? fm.removeItem(at: staging.deletingLastPathComponent())
            guard p.terminationStatus == 0 else { throw DecodeError() }
            output = zip
        }
        return JobResult(output: output, count: ex.images.count, failures: ex.failures, name: base)
    }
}

// MARK: - Command line mode (used for testing / scripting)

func runCLI(_ args: [String]) -> Int32 {
    var pdfs = [String](), out: String? = nil, mode = "folder", keep = false
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--out": i += 1; out = i < args.count ? args[i] : nil
        case "--zip": mode = "zip"
        case "--keep-jpeg": keep = true
        default: pdfs.append(args[i])
        }
        i += 1
    }
    var status: Int32 = 0
    for p in pdfs {
        let url = URL(fileURLWithPath: p)
        do {
            let r = try Job.run(pdf: url, title: nil, outDir: out.map { URL(fileURLWithPath: $0) }, mode: mode, keepJPEG: keep)
            print("\(p): \(r.count) image(s), \(r.failures) failed -> \(r.output?.path ?? "(nothing written)")")
            if r.failures > 0 { status = 2 }
        } catch {
            print("\(p): could not read PDF"); status = 1
        }
    }
    return status
}

// MARK: - App

struct SettingsView: View {
    @AppStorage("outputMode") var outputMode = "folder"
    @AppStorage("keepJPEG") var keepJPEG = false
    @AppStorage("revealInFinder") var reveal = true
    var onPick: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Pluck").font(.title2.bold())
                    Text("In any app: File ▸ Print ▸ PDF ▾ ▸ Extract Images to Downloads")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Picker("Save to Downloads as:", selection: $outputMode) {
                Text("A new folder").tag("folder")
                Text("A .zip file").tag("zip")
            }.pickerStyle(.radioGroup)
            Toggle("Keep JPEG photos as the original .jpg (smaller, no re-encode)", isOn: $keepJPEG)
            Toggle("Show the result in Finder when done", isOn: $reveal)
            Divider()
            HStack {
                Text("Settings apply to the Print menu too.").font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button("Extract from PDF…", action: onPick).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 470)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var gotFiles = false
    var window: NSWindow?

    func application(_ sender: NSApplication, open urls: [URL]) {
        gotFiles = true
        process(urls, titles: [:])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched by the Print dialog as a tool: argv = [exe, title, options, pdfPath]
        let a = CommandLine.arguments
        if a.count >= 4, FileManager.default.fileExists(atPath: a[3]) {
            gotFiles = true
            process([URL(fileURLWithPath: a[3])], titles: [a[3]: a[1]])
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            if !self.gotFiles { self.showSettings() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func process(_ urls: [URL], titles: [String: String]) {
        var outputs = [URL]()
        var problems = [String]()
        for url in urls {
            do {
                let r = try Job.run(pdf: url, title: titles[url.path])
                if let o = r.output { outputs.append(o) }
                if r.count == 0 {
                    problems.append(r.failures > 0
                        ? "“\(r.name)” has \(r.failures) image(s), but none could be decoded."
                        : "No images were found in “\(r.name)”.")
                } else if r.failures > 0 {
                    problems.append("“\(r.name)”: saved \(r.count) image(s); \(r.failures) used an unsupported encoding and were skipped.")
                }
            } catch {
                problems.append("Couldn’t read “\(url.lastPathComponent)”.")
            }
        }
        if Prefs.reveal && !outputs.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
        if !problems.isEmpty {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Pluck"
            alert.informativeText = problems.joined(separator: "\n")
            alert.runModal()
        }
        if window == nil { NSApp.terminate(nil) }
    }

    func showSettings() {
        let view = SettingsView { [weak self] in self?.pickPDF() }
        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Pluck"
        w.contentView = NSHostingView(rootView: view)
        w.setContentSize(w.contentView!.fittingSize)
        w.center()
        w.isReleasedWhenClosed = false
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func pickPDF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        process(panel.urls, titles: [:])
    }
}

// MARK: - Entry point

let cliArgs = Array(CommandLine.arguments.dropFirst())
if cliArgs.first == "--extract" {
    exit(runCLI(Array(cliArgs.dropFirst())))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
