// Original AgentBar mark for Omnigent: a geometric ring around a hub — an "O"
// that holds other agents (not Omnigent's own artwork).
// Solid alpha shape, tinted at runtime via .tintedMark.
import AppKit

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let N = 144
let c = CGContext(data: nil, width: N, height: N, bitsPerComponent: 8, bytesPerRow: 0,
                  space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
c.clear(CGRect(x: 0, y: 0, width: N, height: N))
c.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1))

let s = CGFloat(N)
func disc(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: (cx - r) * s, y: (cy - r) * s, width: 2 * r * s, height: 2 * r * s),
           transform: nil)
}

// Thick ring (even-odd: outer disc minus inner disc)…
let ring = CGMutablePath()
ring.addPath(disc(0.5, 0.5, 0.42))
ring.addPath(disc(0.5, 0.5, 0.27))
c.addPath(ring)
c.fillPath(using: .evenOdd)
// …and a hub in the middle.
c.addPath(disc(0.5, 0.5, 0.12))
c.fillPath()

let img = c.makeImage()!
let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1
              ? CommandLine.arguments[1] : "omnigent_mark.png")
try! png.write(to: out)
