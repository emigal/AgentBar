// Original AgentBar mark for Pi: a geometric π (not Pi's own artwork).
// Solid alpha shape, tinted at runtime via .tintedMark.
import AppKit

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let N = 144
let c = CGContext(data: nil, width: N, height: N, bitsPerComponent: 8, bytesPerRow: 0,
                  space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
c.clear(CGRect(x: 0, y: 0, width: N, height: N))
let ink = CGColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1)
c.setFillColor(ink)

let s = CGFloat(N)
func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
    c.fill(CGRect(x: x * s, y: y * s, width: w * s, height: h * s))
}

// Top bar with small downward ticks at the ends — the π crossbar.
rect(0.10, 0.70, 0.80, 0.16)
rect(0.10, 0.60, 0.12, 0.12)
rect(0.78, 0.60, 0.12, 0.12)
// Two legs. The right one is a hair shorter, the way a written π leans.
rect(0.28, 0.12, 0.14, 0.74)
rect(0.58, 0.18, 0.14, 0.68)

let img = c.makeImage()!
let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1
              ? CommandLine.arguments[1] : "pi_mark.png")
try! png.write(to: out)
print("wrote \(out.path) (\(png.count) bytes)")
print(png.base64EncodedString())
