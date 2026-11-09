#!/usr/bin/env swift
// SVG からアプリアイコン（.icns）を作る（phase7 design D2）。
//
//   swift scripts/generate-icon.swift Resources/icon.svg build/AppIcon.icns
//
// webtabinal `desktop/scripts/generate-icon.swift` からの移植。SVG を NSImage で読み、各サイズの
// ビットマップに描いて、ImageIO で .icns に書き出す（Xcode 本体も iconutil も要らない。CLT だけで動く）。
import AppKit
import Foundation
import ImageIO

guard CommandLine.arguments.count >= 3 else {
    fputs("usage: generate-icon.swift <icon.svg> <out.icns>\n", stderr)
    exit(2)
}

let svgURL = URL(fileURLWithPath: CommandLine.arguments[1])
let icnsURL = URL(fileURLWithPath: CommandLine.arguments[2])

guard let image = NSImage(contentsOf: svgURL), image.isValid else {
    fputs("generate-icon: SVG を読めません: \(svgURL.path)\n", stderr)
    exit(1)
}

// .icns に入れる大きさ（ピクセル）と解像度（72 dpi = @1x、144 dpi = @2x）。16〜512 pt の @1x と @2x。
let representations: [(pixels: Int, dpi: Int)] = [
    (16, 72),
    (32, 144),
    (32, 72),
    (64, 144),
    (128, 72),
    (256, 144),
    (256, 72),
    (512, 144),
    (512, 72),
    (1024, 144),
]

func renderIcon(size: Int) throws -> CGImage {
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "Tabghostty", code: 1, userInfo: [NSLocalizedDescriptionKey: "ビットマップを作れません（\(size) px）"])
    }
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.clear.setFill()
    rect.fill()
    image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()
    guard let cgImage = rep.cgImage else {
        throw NSError(domain: "Tabghostty", code: 1, userInfo: [NSLocalizedDescriptionKey: "アイコンを描けません（\(size) px）"])
    }
    return cgImage
}

guard let destination = CGImageDestinationCreateWithURL(
    icnsURL as CFURL,
    "com.apple.icns" as CFString,
    representations.count,
    nil
) else {
    fputs("generate-icon: .icns の書き出し先を作れません: \(icnsURL.path)\n", stderr)
    exit(1)
}
do {
    for representation in representations {
        let properties = [
            kCGImagePropertyDPIWidth: representation.dpi,
            kCGImagePropertyDPIHeight: representation.dpi,
        ] as CFDictionary
        CGImageDestinationAddImage(destination, try renderIcon(size: representation.pixels), properties)
    }
} catch {
    fputs("generate-icon: \(error.localizedDescription)\n", stderr)
    exit(1)
}
guard CGImageDestinationFinalize(destination) else {
    fputs("generate-icon: .icns を書き出せません: \(icnsURL.path)\n", stderr)
    exit(1)
}

print("generate-icon: \(icnsURL.path)")
