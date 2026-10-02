#!/usr/bin/env swift
// Renders Foldera's app icon (a 1024×1024 PNG) with Core Graphics.
// Usage: swift scripts/make-icon.swift <output.png>
//
// Design: macOS squircle in Foldera blue, holding a Windows-style yellow folder whose
// front panel carries a row of tabs — a folder you browse in tabs.

import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.dropFirst().first ?? "AppIcon-1024.png"

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func linearGradient(_ ctx: CGContext, in path: CGPath, colors: [CGColor], from start: CGPoint, to end: CGPoint) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(gradient, start: start, end: end, options: [])
    ctx.restoreGState()
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(
    data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
// Core Graphics' origin is bottom-left; flip so the drawing reads top-down.
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

// MARK: Background squircle (Apple's macOS icon grid: 824pt body, centered, soft drop shadow)

let body = CGRect(x: 100, y: 92, width: 824, height: 824)
let bodyPath = roundedRect(body, 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.30))
ctx.addPath(bodyPath)
ctx.setFillColor(color(0x0B5CB8))
ctx.fillPath()
ctx.restoreGState()
linearGradient(ctx, in: bodyPath, colors: [color(0x3FA9F5), color(0x0067C0), color(0x0A3F8F)],
               from: CGPoint(x: body.minX, y: body.minY), to: CGPoint(x: body.maxX, y: body.maxY))
// Soft top sheen.
linearGradient(ctx, in: bodyPath, colors: [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)],
               from: CGPoint(x: 512, y: body.minY), to: CGPoint(x: 512, y: body.midY))

// MARK: Folder

let folder = CGRect(x: 214, y: 268, width: 596, height: 470)
let radius: CGFloat = 46

// Shadow under the folder.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 22), blur: 40, color: color(0x001A40, 0.45))
ctx.addPath(roundedRect(folder.offsetBy(dx: 0, dy: 30), radius))
ctx.setFillColor(color(0xD9952B))
ctx.fillPath()
ctx.restoreGState()

// Back panel with its tab.
let back = CGMutablePath()
back.addPath(roundedRect(CGRect(x: folder.minX, y: folder.minY, width: 250, height: 120), 38))
back.addPath(roundedRect(CGRect(x: folder.minX, y: folder.minY + 60, width: folder.width, height: folder.height - 60), radius))
linearGradient(ctx, in: back, colors: [color(0xF2B23E), color(0xD98E1F)],
               from: CGPoint(x: 512, y: folder.minY), to: CGPoint(x: 512, y: folder.maxY))

// Paper peeking out of the folder.
let paper = roundedRect(CGRect(x: folder.minX + 44, y: folder.minY + 100, width: folder.width - 88, height: 200), 22)
ctx.addPath(paper)
ctx.setFillColor(color(0xFFFFFF, 0.95))
ctx.fillPath()

// Front panel.
let frontRect = CGRect(x: folder.minX, y: folder.minY + 168, width: folder.width, height: folder.height - 138)
let front = roundedRect(frontRect, radius)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: color(0x8A5200, 0.35))
ctx.addPath(front)
ctx.setFillColor(color(0xFFC94A))
ctx.fillPath()
ctx.restoreGState()
linearGradient(ctx, in: front, colors: [color(0xFFDA6B), color(0xFFC23A), color(0xF5A922)],
               from: CGPoint(x: 512, y: frontRect.minY), to: CGPoint(x: 512, y: frontRect.maxY))

// MARK: Tabs on the folder front — the Foldera idea.

let tabTop = frontRect.minY + 70
let tabHeight: CGFloat = 92
let tabWidth: CGFloat = 150
let tabGap: CGFloat = 18
let tabsX = frontRect.minX + 58
for index in 0..<3 {
    let rect = CGRect(x: tabsX + CGFloat(index) * (tabWidth + tabGap), y: tabTop, width: tabWidth, height: tabHeight)
    let path = CGMutablePath()
    // Rounded top corners, square bottom: a browser tab.
    let r: CGFloat = 22
    path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
    path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
    path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r), control: CGPoint(x: rect.maxX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
    path.closeSubpath()
    ctx.addPath(path)
    ctx.setFillColor(index == 0 ? color(0xFFFFFF) : color(0xFFFFFF, 0.45))
    ctx.fillPath()
}
// The strip the active tab joins, like Foldera's toolbar.
let strip = CGRect(x: tabsX - 18, y: tabTop + tabHeight, width: frontRect.width - 80, height: 20)
ctx.addPath(roundedRect(strip, 10))
ctx.setFillColor(color(0xFFFFFF))
ctx.fillPath()

// Content lines below the tabs (a file list).
for (index, width) in [380.0, 270.0].enumerated() {
    let line = CGRect(x: tabsX, y: strip.maxY + 44 + CGFloat(index) * 50, width: width, height: 22)
    ctx.addPath(roundedRect(line, 11))
    ctx.setFillColor(color(0xB86A00, 0.55))
    ctx.fillPath()
}

// MARK: Write PNG

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("Wrote \(output)")
