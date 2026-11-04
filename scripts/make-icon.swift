#!/usr/bin/env swift
// Builds the Wallpap app icon in the macOS 26 / iOS 26 layered format.
//
//   swift scripts/make-icon.swift
//
// Produces:
//   Resources/AppIcon.icon/            Icon Composer document (layers + icon.json), editable in Icon Composer
//   Resources/Assets.car, AppIcon.icns compiled by actool: the system derives Default, Dark,
//                                      Clear (white/black glass) and Tinted appearances from the layers
//   Resources/IconPreviews/*.png       renders of every appearance (ictool)
import AppKit
import CoreGraphics

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let res = root.appending(path: "Resources")
let doc = res.appending(path: "AppIcon.icon")
let assets = doc.appending(path: "Assets")
let previews = res.appending(path: "IconPreviews")
let fm = FileManager.default

let S: CGFloat = 1024
let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

/// Draws one transparent 1024² layer. `draw` gets a context with a top-left origin.
/// `original`: draw in the old flat icon's coordinates (body 100…924), stretched to the full layer canvas.
func layer(_ name: String, original: Bool = true, _ draw: (CGContext) -> Void) {
    let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: S); ctx.scaleBy(x: 1, y: -1) // top-left origin, like the design grid
    ctx.setShouldAntialias(true)
    if original { ctx.scaleBy(x: S / 824, y: S / 824); ctx.translateBy(x: -100, y: -100) }
    draw(ctx)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: assets.appending(path: "\(name).png"))
}

/// One wave band: a thick round-capped stroke along a gentle sine.
func wave(_ ctx: CGContext, y: CGFloat, width: CGFloat, amplitude: CGFloat, thickness: CGFloat, phase: CGFloat) {
    let p = CGMutablePath()
    let x0 = (S - width) / 2
    for i in 0...160 {
        let t = CGFloat(i) / 160
        let pt = CGPoint(x: x0 + t * width, y: y + amplitude * sin(t * .pi * 2 + phase))
        i == 0 ? p.move(to: pt) : p.addLine(to: pt)
    }
    ctx.addPath(p)
    ctx.setStrokeColor(white)
    ctx.setLineWidth(thickness)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()
}

try? fm.removeItem(at: doc)
try! fm.createDirectory(at: assets, withIntermediateDirectories: true)
try! fm.createDirectory(at: previews, withIntermediateDirectories: true)

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

/// Hill silhouette like the original icon: two summed sines, filled down past the bottom edge.
func hill(_ ctx: CGContext, base: CGFloat, amp: CGFloat, phase: CGFloat, freq: CGFloat, top: UInt32, bottom: UInt32) {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: -20, y: S + 20))
    for i in 0...200 {
        let t = CGFloat(i) / 200
        // Original was drawn bottom-up; flip to the top-left grid.
        let y = base + amp * sin(t * .pi * freq + phase) + amp * 0.35 * sin(t * .pi * freq * 2.3 + phase * 1.7)
        p.addLine(to: CGPoint(x: -20 + t * (S + 40), y: S - y))
    }
    p.addLine(to: CGPoint(x: S + 20, y: S + 20))
    p.closeSubpath()
    ctx.saveGState()
    ctx.addPath(p); ctx.clip()
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                       colors: [rgb(top), rgb(bottom)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: S - (base + amp)), end: CGPoint(x: 0, y: S),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

// Sunset over layered hills (the original Wallpap picture), one glass layer per element.
layer("glow") { ctx in
    let c = CGPoint(x: 512, y: S - 470)
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                       colors: [CGColor(srgbRed: 1, green: 0.89, blue: 0.69, alpha: 0.85),
                                CGColor(srgbRed: 1, green: 0.70, blue: 0.48, alpha: 0.35),
                                CGColor(srgbRed: 1, green: 0.70, blue: 0.48, alpha: 0)] as CFArray,
                       locations: [0, 0.45, 1])!
    ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: 360, options: [])
}
layer("stars") { ctx in
    let stars: [(CGFloat, CGFloat, CGFloat)] = [(250, 820, 6), (360, 860, 4.5), (700, 840, 5.5), (800, 760, 4),
                                                (610, 880, 4), (180, 720, 4), (860, 870, 4.5), (470, 800, 3.5)]
    ctx.setFillColor(white)
    for (x, y, r) in stars { ctx.fillEllipse(in: CGRect(x: x - r, y: S - y - r, width: r * 2, height: r * 2)) }
}
layer("sun") { ctx in
    let c = CGPoint(x: 512, y: S - 470), r: CGFloat = 132
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)); ctx.clip()
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                       colors: [rgb(0xFFF1C9), rgb(0xFF9C78)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: c.y - r), end: CGPoint(x: 0, y: c.y + r), options: [])
    ctx.restoreGState()
}
layer("hill-1") { hill($0, base: 470, amp: 40, phase: 2.9, freq: 2.0, top: 0xB2479B, bottom: 0x7A2E8C) }
layer("hill-2") { hill($0, base: 395, amp: 52, phase: 2.4, freq: 1.8, top: 0x6E2C93, bottom: 0x47207A) }
layer("hill-3") { hill($0, base: 315, amp: 58, phase: 4.1, freq: 1.5, top: 0x3A1C6E, bottom: 0x261552) }
layer("hill-4") { hill($0, base: 225, amp: 44, phase: 1.2, freq: 1.3, top: 0x1F1248, bottom: 0x120B30) }

let json = """
{
  "fill-specializations" : [
    {
      "value" : {
        "linear-gradient" : [
          "display-p3:0.10980,0.07843,0.32157,1.00000",
          "display-p3:0.94118,0.38431,0.49412,1.00000"
        ],
        "orientation" : { "start" : { "x" : 0.5, "y" : 0 }, "stop" : { "x" : 0.5, "y" : 0.55 } }
      }
    },
    {
      "appearance" : "dark",
      "value" : {
        "linear-gradient" : [
          "display-p3:0.16078,0.13333,0.30588,1.00000",
          "display-p3:0.05098,0.04706,0.10196,1.00000"
        ],
        "orientation" : { "start" : { "x" : 0.5, "y" : 0 }, "stop" : { "x" : 0.5, "y" : 1 } }
      }
    }
  ],
  "groups" : [
    {
      "layers" : [ { "image-name" : "hill-4.png", "name" : "hill-4", "glass" : true } ],
      "shadow" : { "kind" : "layer-color", "opacity" : 0.45 },
      "translucency" : { "enabled" : true, "value" : 0.2 },
      "specular" : true
    },
    {
      "layers" : [ { "image-name" : "hill-3.png", "name" : "hill-3", "glass" : true } ],
      "shadow" : { "kind" : "layer-color", "opacity" : 0.45 },
      "translucency" : { "enabled" : true, "value" : 0.2 },
      "specular" : true
    },
    {
      "layers" : [ { "image-name" : "hill-2.png", "name" : "hill-2", "glass" : true } ],
      "shadow" : { "kind" : "layer-color", "opacity" : 0.45 },
      "translucency" : { "enabled" : true, "value" : 0.2 },
      "specular" : true
    },
    {
      "layers" : [ { "image-name" : "hill-1.png", "name" : "hill-1", "glass" : true } ],
      "shadow" : { "kind" : "layer-color", "opacity" : 0.45 },
      "translucency" : { "enabled" : true, "value" : 0.2 },
      "specular" : true
    },
    {
      "layers" : [ { "image-name" : "sun.png", "name" : "sun", "glass" : true } ],
      "shadow" : { "kind" : "layer-color", "opacity" : 0.3 },
      "translucency" : { "enabled" : true, "value" : 0.1 },
      "specular" : true
    },
    {
      "layers" : [ { "image-name" : "stars.png", "name" : "stars", "glass" : true } ],
      "shadow" : { "kind" : "layer-color", "opacity" : 0.0 },
      "translucency" : { "enabled" : true, "value" : 0.0 },
      "specular" : true
    },
    {
      "layers" : [ { "image-name" : "glow.png", "name" : "glow", "glass" : false } ]
    }
  ],
  "supported-platforms" : { "squares" : "shared" }
}
"""
try! json.write(to: doc.appending(path: "icon.json"), atomically: true, encoding: .utf8)

@discardableResult
func run(_ tool: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    try! p.run(); p.waitUntilExit()
    return p.terminationStatus
}

// Previews of every appearance.
let ictool = "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
if fm.fileExists(atPath: ictool) {
    for r in ["Default", "Dark", "ClearLight", "ClearDark", "TintedLight", "TintedDark"] {
        var args = [doc.path, "--export-image", "--output-file", previews.appending(path: "\(r).png").path,
                    "--platform", "macOS", "--rendition", r, "--width", "512", "--height", "512", "--scale", "1"]
        if r.hasPrefix("Tinted") { args += ["--tint-color", "0.58", "--tint-strength", "0.8"] }
        print("\(r): \(run(ictool, args) == 0 ? "ok" : "failed")")
    }
}

// Compile: Assets.car (layered, all appearances) + AppIcon.icns (flat fallback).
let out = fm.temporaryDirectory.appending(path: "wallpap-actool")
try? fm.removeItem(at: out)
try! fm.createDirectory(at: out, withIntermediateDirectories: true)
let status = run("/usr/bin/xcrun", ["actool", doc.path, "--compile", out.path, "--app-icon", "AppIcon",
                                    "--platform", "macosx", "--minimum-deployment-target", "26.0",
                                    "--target-device", "mac", "--output-partial-info-plist",
                                    out.appending(path: "partial.plist").path])
for f in ["Assets.car", "AppIcon.icns"] {
    let src = out.appending(path: f), dst = res.appending(path: f)
    guard fm.fileExists(atPath: src.path) else { print("actool (\(status)): нет \(f)"); continue }
    try? fm.removeItem(at: dst)
    try! fm.copyItem(at: src, to: dst)
    print("OK: Resources/\(f)")
}
try? fm.removeItem(at: res.appending(path: "AppIcon-1024.png"))
