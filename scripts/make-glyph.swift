// Cuts the duck out of its gray background into a transparent PNG for inline
// use (pill, header, menu bar). Uses Vision's foreground-instance mask.
// Run: swift scripts/make-glyph.swift
import Vision
import AppKit
import CoreImage

let root = FileManager.default.currentDirectoryPath
let inputURL = URL(fileURLWithPath: root).appendingPathComponent("Resources/duck-source.png")
let outputURL = URL(fileURLWithPath: root).appendingPathComponent("Resources/DuckGlyph.png")

guard let ciImage = CIImage(contentsOf: inputURL) else {
    FileHandle.standardError.write(Data("cannot load \(inputURL.path)\n".utf8)); exit(1)
}

let request = VNGenerateForegroundInstanceMaskRequest()
let handler = VNImageRequestHandler(ciImage: ciImage)
do {
    try handler.perform([request])
    guard let result = request.results?.first else {
        FileHandle.standardError.write(Data("no foreground subject found\n".utf8)); exit(1)
    }
    let buffer = try result.generateMaskedImage(
        ofInstances: result.allInstances,
        from: handler,
        croppedToInstancesExtent: true
    )
    let masked = CIImage(cvPixelBuffer: buffer)
    let context = CIContext()
    guard let cg = context.createCGImage(masked, from: masked.extent) else {
        FileHandle.standardError.write(Data("render failed\n".utf8)); exit(1)
    }
    let rep = NSBitmapImageRep(cgImage: cg)
    guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
    try png.write(to: outputURL)
    print("wrote \(outputURL.path) (\(cg.width)x\(cg.height))")
} catch {
    FileHandle.standardError.write(Data("vision error: \(error)\n".utf8)); exit(1)
}
