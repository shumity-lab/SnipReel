// 使い方: swift scripts/make-icon.swift <元画像.png> <出力.icns>
// 白背景の角丸アイコン画像から、角丸を切り抜いて macOS 規格(1024 キャンバスに 824 の本体 + 影)の .icns を作る
import AppKit
import CoreGraphics

let args = CommandLine.arguments
guard args.count == 3,
      let src = NSImage(contentsOfFile: args[1])?.cgImage(forProposedRect: nil, context: nil, hints: nil)
else {
    fputs("usage: make-icon.swift <source.png> <output.icns>\n", stderr)
    exit(1)
}

// 1. 白以外のピクセルの範囲(= アイコン本体)を探す
let w = src.width, h = src.height
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
var minX = w, minY = h, maxX = 0, maxY = 0
for y in 0..<h {
    for x in 0..<w {
        let i = (y * w + x) * 4
        if px[i] < 235 || px[i + 1] < 235 || px[i + 2] < 235 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
}
// メモリ上は上から下の順(CGContext のデータは上端が先頭行)
// 下側には元画像の影が含まれるので、幅を基準に上から正方形で切り出す
let side = maxX - minX + 1
let crop = CGRect(x: minX, y: minY, width: side, height: min(side, h - minY))
print("detected body: \(crop)")
let body = src.cropping(to: crop)!

// 2. 1024 キャンバスに 824 の本体を配置し、角丸で切り抜いて影を付ける
func render(size: Int) -> CGImage {
    let s = CGFloat(size) / 1024
    let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    let rect = CGRect(x: 100 * s, y: 100 * s + 10 * s, width: 824 * s, height: 824 * s)
    let radius = 185 * s
    // 本体の縁の白い隙間を消すため、少し内側で切り抜く
    let inset = 824 * s * 0.004
    let path = CGPath(roundedRect: rect.insetBy(dx: inset, dy: inset),
                      cornerWidth: radius, cornerHeight: radius, transform: nil)
    // 影
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 20 * s,
                color: CGColor(gray: 0, alpha: 0.28))
    c.addPath(path)
    c.setFillColor(CGColor(gray: 1, alpha: 1))
    c.fillPath()
    c.restoreGState()
    // 本体
    c.saveGState()
    c.addPath(path)
    c.clip()
    c.draw(body, in: rect)
    c.restoreGState()
    return c.makeImage()!
}

// 3. iconset を作って iconutil で .icns に変換
let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon-\(getpid()).iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let rep = NSBitmapImageRep(cgImage: render(size: base * scale))
        try! rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
// プレビュー用に 1024 も出力
let previewURL = URL(fileURLWithPath: args[2]).deletingPathExtension().appendingPathExtension("png")
try! NSBitmapImageRep(cgImage: render(size: 1024)).representation(using: .png, properties: [:])!.write(to: previewURL)

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", args[2]]
try! p.run()
p.waitUntilExit()
try? fm.removeItem(at: iconset)
print(p.terminationStatus == 0 ? "wrote \(args[2]), \(previewURL.path)" : "iconutil failed")
