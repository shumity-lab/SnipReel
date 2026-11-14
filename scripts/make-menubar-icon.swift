// 使い方: swift scripts/make-menubar-icon.swift <元画像.png> <出力先ディレクトリ>
// 暗い背景に白い線のアイコン画像から、メニューバー用のテンプレート画像(透過・黒一色)を作る
// 出力: MenuBarIcon.png (18px), MenuBarIcon@2x.png (36px)
import AppKit
import CoreGraphics

let args = CommandLine.arguments
guard args.count == 3,
      let src = NSImage(contentsOfFile: args[1])?.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
    fputs("usage: make-menubar-icon.swift <source.png> <outdir>\n", stderr)
    exit(1)
}

let w = src.width, h = src.height
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
let px = ctx.data!.assumingMemoryBound(to: UInt8.self)

func lum(_ i: Int) -> Double { 0.299 * Double(px[i]) + 0.587 * Double(px[i + 1]) + 0.114 * Double(px[i + 2]) }

// 背景の明るさ(四隅の平均)
let corners = [0, w - 1, (h - 1) * w, h * w - 1].map { lum($0 * 4) }
let bg = corners.reduce(0, +) / Double(corners.count)

// 明るさ → 不透明度(背景=透明、白=不透明)。線の範囲も求める
var alpha = [UInt8](repeating: 0, count: w * h)
var minX = w, minY = h, maxX = 0, maxY = 0
for y in 0..<h {
    for x in 0..<w {
        let a = max(0, min(1, (lum((y * w + x) * 4) - bg) / (255 - bg)))
        // 背景のノイズを消し、線の芯はしっかり不透明に
        let v = a < 0.15 ? 0 : min(1, (a - 0.15) / 0.7)
        alpha[y * w + x] = UInt8(v * 255)
        if v > 0 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
}
print("glyph bounds: x \(minX)...\(maxX), y \(minY)...\(maxY)")

// 黒 + 不透明度のマスク画像
var rgba = [UInt8](repeating: 0, count: w * h * 4)
for i in 0..<(w * h) { rgba[i * 4 + 3] = alpha[i] }
let maskCtx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let glyphFull = maskCtx.makeImage()!
// 線の範囲で切り出し、正方形の中央に配置
let glyph = glyphFull.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))!

func render(_ size: Int) -> Data {
    let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    let gw = CGFloat(glyph.width), gh = CGFloat(glyph.height)
    let box = CGFloat(size) * 0.94 // わずかに余白
    let s = box / max(gw, gh)
    let rect = CGRect(x: (CGFloat(size) - gw * s) / 2, y: (CGFloat(size) - gh * s) / 2,
                      width: gw * s, height: gh * s)
    c.draw(glyph, in: rect)
    let rep = NSBitmapImageRep(cgImage: c.makeImage()!)
    rep.size = NSSize(width: 18, height: 18)
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: args[2])
try! render(18).write(to: out.appendingPathComponent("MenuBarIcon.png"))
try! render(36).write(to: out.appendingPathComponent("MenuBarIcon@2x.png"))
print("wrote MenuBarIcon.png, MenuBarIcon@2x.png to \(out.path)")
