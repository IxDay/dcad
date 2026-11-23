#!/usr/bin/env swift
// Extract the icon assets used by dcad-gui from a local Visual Studio Code
// installation. Requires Swift/AppKit; run from the repository root:
//
//   swift gui/assets/extract-vscode-icons.swift
//
// Output goes to gui/assets/icons/. VSCODE_APP can override the app path.

import AppKit
import CoreText
import Foundation

let fileManager = FileManager.default
let env = ProcessInfo.processInfo.environment
let vscodeApp = env["VSCODE_APP"] ?? "/Applications/Visual Studio Code.app"
let resources = vscodeApp + "/Contents/Resources/app"
let codiconFont = resources + "/out/media/codicon.ttf"
let setiFont = "gui/assets/Seti.ttf"
let setiTheme = resources + "/extensions/theme-seti/icons/vs-seti-icon-theme.json"
let outDir = "gui/assets/icons"

try? fileManager.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func registerFont(_ path: String) {
    let url = URL(fileURLWithPath: path)
    var error: Unmanaged<CFError>?
    CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
    if let error = error?.takeRetainedValue() {
        // 4 and 105 both mean "already registered" in this scope; that is fine
        // because we only need NSFont(name:) to find the face afterwards.
        let code = CFErrorGetCode(error)
        if code != 4 && code != 105 {
            print("warning: font registration for \(path): \(error)")
        }
    }
}

func rasterGlyph(_ fontPath: String, _ fontName: String, _ codepoint: UInt32,
                 _ outName: String, _ hex: String) throws {
    registerFont(fontPath)
    let font = CTFontCreateWithName(fontName as CFString, 56, nil)
    let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    let r = CGFloat(Int(h.prefix(2), radix: 16)!) / 255
    let g = CGFloat(Int(h.dropFirst(2).prefix(2), radix: 16)!) / 255
    let b = CGFloat(Int(h.dropFirst(4).prefix(2), radix: 16)!) / 255

    let size = 72
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(data: nil, width: size, height: size,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: colorSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.clear(CGRect(x: 0, y: 0, width: size, height: size))
    context.setFillColor(CGColor(colorSpace: colorSpace,
                                 components: [r, g, b, 1])!)

    var character = UniChar(codepoint)
    var glyph: CGGlyph = 0
    guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1) else {
        fatalError("no glyph for U+\(String(codepoint, radix: 16)) in \(fontName)")
    }
    var position = CGPoint(x: 4, y: 4)
    CTFontDrawGlyphs(font, [glyph], &position, 1, context)

    guard let image = context.makeImage() else { fatalError("render failed") }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not encode \(outName)")
    }
    let path = outDir + "/" + outName + ".png"
    try png.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

// File icons: use the exact *light* variants from VS Code's built-in Seti
// icon theme (the `vs-seti` theme selected in the user's VS Code), including
// its font characters and colours.
let themeData = try Data(contentsOf: URL(fileURLWithPath: setiTheme))
let theme = try JSONSerialization.jsonObject(with: themeData) as! [String: Any]
let definitions = theme["iconDefinitions"] as! [String: [String: Any]]

func setiIcon(_ definition: String, _ outName: String) throws {
    guard let def = definitions[definition],
          let character = def["fontCharacter"] as? String,
          let color = def["fontColor"] as? String else {
        fatalError("Seti theme is missing \(definition)")
    }
    let hex = character.replacingOccurrences(of: "\\", with: "")
    guard let codepoint = UInt32(hex, radix: 16) else {
        fatalError("bad Seti font character \(character)")
    }
    try rasterGlyph(setiFont, "Seti", codepoint, outName, color)
}

try setiIcon("_d_light", "file-d")
try setiIcon("_json_light", "file-json")
try setiIcon("_markdown_light", "file-markdown")
try setiIcon("_shell_light", "file-shell")
try setiIcon("_default_light", "file")
try setiIcon("_config_light", "file-config")
try setiIcon("_image_light", "file-image")

// The Seti theme leaves folders to VS Code's generic codicon folder icons.
try rasterGlyph(codiconFont, "codicon", 0xEA83, "folder", "#c09553")
try rasterGlyph(codiconFont, "codicon", 0xEAF7, "folder-open", "#c09553")

// Toolbar/part icons: VS Code's codicon font, tinted like the light theme text.
let codicons: [UInt32: String] = [
    0xEBF8: "fit", 0xEA8B: "iso", 0xEBFF: "up", 0xEBFC: "down",
    0xEA70: "front", 0xEAE7: "back", 0xEBFE: "right", 0xEBFD: "left",
    0xEB37: "refresh", 0xEBD5: "axes", 0xEBB7: "grid", 0xEBD2: "wire",
    0xEA72: "ortho", 0xEAB2: "check", 0xEB2C: "play", 0xEAD1: "pause",
    0xEAD2: "restart", 0xEB4B: "save",
]
for (codepoint, name) in codicons.sorted(by: { $0.value < $1.value }) {
    try rasterGlyph(codiconFont, "codicon", codepoint, name, "#383838")
}
