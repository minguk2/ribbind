#!/usr/bin/env swift
// Draws the Ribbind icon at every size macOS app bundles ship, emits a .icns at
// AppBundleResources/AppIcon.icns, and also emits a template PDF for the menu-bar
// extra. Run from repo root: `swift scripts/icon_gen/generate_icons.swift`.
//
// Design: a ribbon-bow silhouette — two inward-facing triangles meeting at a small
// central knot. Reads as a ribbon/bowtie at 16pt and as a flat-design bow at 1024pt.
// App icon adds a blue→purple gradient on a rounded-square macOS-convention base;
// menu-bar template is the same silhouette rendered in pure alpha so macOS can
// tint it for light/dark menu bars.

import AppKit
import Foundation
import CoreGraphics

// MARK: - Paths

let repoRoot = FileManager.default.currentDirectoryPath
let iconsetDir = "\(repoRoot)/scripts/icon_gen/AppIcon.iconset"
let icnsOut = "\(repoRoot)/AppBundleResources/AppIcon.icns"
let menuPDFOut = "\(repoRoot)/Sources/Ribbind/Resources/MenuBarIcon.pdf"
let previewPNGOut = "\(repoRoot)/scripts/icon_gen/preview_1024.png"

// MARK: - Geometry

/// A stylised keycap monogram. The outer shape is a rounded-square keycap (stroked),
/// and inside sits a bold ">" chevron — the universal "shortcut / next" glyph.
/// Picked for max legibility at 16pt: the stroke weight keeps the keycap readable
/// and the chevron gives a unique, action-oriented mark that stays distinct from
/// the generic `keyboard` SF Symbol.
func iconPath(size: CGFloat, insetFraction: CGFloat = 0.12) -> (cap: CGPath, chevron: CGPath) {
    let inset = size * insetFraction
    let capRect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let capRadius = capRect.width * 0.22
    let capOuter = CGPath(roundedRect: capRect, cornerWidth: capRadius, cornerHeight: capRadius, transform: nil)

    // Stroke the keycap by subtracting an inner rounded rect from the outer one.
    let strokeW = size * 0.085
    let innerRect = capRect.insetBy(dx: strokeW, dy: strokeW)
    let innerRadius = max(1, innerRect.width * 0.18)
    let capInner = CGPath(roundedRect: innerRect, cornerWidth: innerRadius, cornerHeight: innerRadius, transform: nil)
    let ring = CGMutablePath()
    ring.addPath(capOuter)
    ring.addPath(capInner)     // using even-odd fill rule punches this out

    // The chevron: a thick ">" sitting centered inside the keycap.
    let cx = capRect.midX
    let cy = capRect.midY
    let chW = capRect.width * 0.30
    let chH = capRect.height * 0.36
    let thick = size * 0.085

    let chevron = CGMutablePath()
    // Top arm (top-left → apex)
    chevron.move(to: CGPoint(x: cx - chW / 2,          y: cy + chH / 2))
    chevron.addLine(to: CGPoint(x: cx - chW / 2 + thick, y: cy + chH / 2))
    chevron.addLine(to: CGPoint(x: cx + chW / 2,       y: cy))
    chevron.addLine(to: CGPoint(x: cx - chW / 2 + thick, y: cy - chH / 2))
    chevron.addLine(to: CGPoint(x: cx - chW / 2,       y: cy - chH / 2))
    chevron.addLine(to: CGPoint(x: cx + chW / 2 - thick * 0.9, y: cy))
    chevron.closeSubpath()

    return (cap: ring, chevron: chevron)
}

/// Rounded-square background the way macOS app icons expect. The corner-radius
/// ratio (0.225 of the side) is the long-standing macOS "squircle" convention.
func roundedSquarePath(size: CGFloat) -> CGPath {
    let radius = size * 0.225
    return CGPath(roundedRect: CGRect(x: 0, y: 0, width: size, height: size),
                  cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// MARK: - Colored app-icon PNG

func drawAppIconPNG(size: Int) -> Data {
    let s = CGFloat(size)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: 0, space: colorSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

    // 1. Rounded-square clipping region.
    ctx.addPath(roundedSquarePath(size: s))
    ctx.clip()

    // 2. Background gradient (blue → violet, top-to-bottom).
    let top = CGColor(red: 0.33, green: 0.55, blue: 1.00, alpha: 1.0)         // #547AFF-ish
    let bottom = CGColor(red: 0.55, green: 0.36, blue: 0.93, alpha: 1.0)      // #8D5CEC-ish
    let gradient = CGGradient(colorsSpace: colorSpace, colors: [top, bottom] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: s),
                           end: CGPoint(x: 0, y: 0),
                           options: [])

    // 3. Subtle inner sheen — a soft highlight arc in the upper-left.
    ctx.saveGState()
    ctx.addPath(roundedSquarePath(size: s))
    ctx.clip()
    let sheen = CGGradient(colorsSpace: colorSpace,
                           colors: [CGColor(gray: 1.0, alpha: 0.18),
                                    CGColor(gray: 1.0, alpha: 0.0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawRadialGradient(sheen,
                           startCenter: CGPoint(x: s * 0.3, y: s * 0.85), startRadius: 0,
                           endCenter: CGPoint(x: s * 0.3, y: s * 0.85), endRadius: s * 0.7,
                           options: [])
    ctx.restoreGState()

    // 4. Draw the keycap ring + chevron, white on the gradient, with a soft shadow
    //    so the mark lifts off the background.
    let (cap, chevron) = iconPath(size: s)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01),
                  blur: s * 0.025,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.28))
    ctx.setFillColor(CGColor(gray: 1.0, alpha: 1.0))
    ctx.addPath(cap)
    ctx.fillPath(using: .evenOdd)           // ring: outer minus inner
    ctx.restoreGState()

    ctx.saveGState()
    ctx.setFillColor(CGColor(gray: 1.0, alpha: 1.0))
    ctx.addPath(chevron)
    ctx.fillPath()
    ctx.restoreGState()

    let image = ctx.makeImage()!
    let nsImage = NSImage(cgImage: image, size: NSSize(width: size, height: size))
    guard let tiff = nsImage.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("Failed to encode \(size) PNG")
    }
    return png
}

// MARK: - Template PDF for the menu-bar

func drawMenuBarTemplatePDF() -> Data {
    // 18pt canvas — macOS MenuBarExtra default draws at 18pt; template images scale.
    let size: CGFloat = 18
    let data = NSMutableData()
    var mediaBox = CGRect(x: 0, y: 0, width: size, height: size)
    let consumer = CGDataConsumer(data: data)!
    let pdfCtx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
    pdfCtx.beginPDFPage(nil)
    pdfCtx.setFillColor(CGColor(gray: 0.0, alpha: 1.0))   // template: pure alpha, macOS tints
    let (cap, chevron) = iconPath(size: size, insetFraction: 0.06)
    pdfCtx.addPath(cap)
    pdfCtx.fillPath(using: .evenOdd)
    pdfCtx.addPath(chevron)
    pdfCtx.fillPath()
    pdfCtx.endPDFPage()
    pdfCtx.closePDF()
    return data as Data
}

// MARK: - Driver

try? FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)
try? FileManager.default.createDirectory(
    atPath: (menuPDFOut as NSString).deletingLastPathComponent,
    withIntermediateDirectories: true)

// macOS iconset convention: emit both @1x and @2x for every logical size up to 512.
let sizes: [(Int, String)] = [
    (16,  "icon_16x16.png"),
    (32,  "icon_16x16@2x.png"),
    (32,  "icon_32x32.png"),
    (64,  "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024,"icon_512x512@2x.png"),
]

for (px, filename) in sizes {
    let png = drawAppIconPNG(size: px)
    try png.write(to: URL(fileURLWithPath: "\(iconsetDir)/\(filename)"))
    print("  \(filename) — \(px)×\(px)  (\(png.count) B)")
}

// Retain a 1024 standalone for README / website use.
try drawAppIconPNG(size: 1024).write(to: URL(fileURLWithPath: previewPNGOut))
print("preview: \(previewPNGOut)")

// iconutil compiles the .iconset into a .icns.
let task = Process()
task.launchPath = "/usr/bin/iconutil"
task.arguments = ["-c", "icns", "-o", icnsOut, iconsetDir]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { fatalError("iconutil failed") }
print("icns: \(icnsOut)")

// Menu-bar template PDF.
try drawMenuBarTemplatePDF().write(to: URL(fileURLWithPath: menuPDFOut))
print("menu pdf: \(menuPDFOut)")
print("✓ done")
