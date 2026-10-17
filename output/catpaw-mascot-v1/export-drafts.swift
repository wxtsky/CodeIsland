import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let source = CGImageSourceCreateWithURL(root.appendingPathComponent("design-sheet.png") as CFURL, nil)!
let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
let colorSpace = CGColorSpaceCreateDeviceRGB()
let info = CGImageAlphaInfo.premultipliedLast.rawValue
let bitmap = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: colorSpace, bitmapInfo: info)!
bitmap.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
let data = bitmap.data!.assumingMemoryBound(to: UInt8.self)
var minY = image.height, maxY = 0
for y in 0..<image.height {
 for x in 0..<image.width where data[(y * image.width + x) * 4 + 3] > 128 { minY = min(minY, y); maxY = max(maxY, y) }
}
// CGContext's row coordinates and CGImage crop coordinates share the raster order.
let states = ["idle", "processing", "running", "waiting-approval", "waiting-question"]
let palette: [[Int]] = [[48,27,52],[78,41,66],[255,247,224],[255,231,195],[242,211,173],[255,146,132],[247,125,117],[255,180,159],[217,103,104],[108,108,134],[166,175,195],[244,192,51],[255,220,88],[74,188,218],[111,225,244],[255,255,255]]
for (index, name) in states.enumerated() {
 let x = image.width * index / 5
 let right = image.width * (index + 1) / 5
 let crop = image.cropping(to: CGRect(x: x, y: minY, width: right-x, height: maxY-minY+1))!
 let base = CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 160, space: colorSpace, bitmapInfo: info)!
 base.interpolationQuality = .none
 let scale = min(36.0 / Double(crop.width), 36.0 / Double(crop.height))
 let width = Double(crop.width) * scale, height = Double(crop.height) * scale
 base.draw(crop, in: CGRect(x: (40-width)/2, y: (40-height)/2, width: width, height: height))
 let pixels = base.data!.assumingMemoryBound(to: UInt8.self)
 for n in 0..<1600 {
  let k = n*4
  if pixels[k+3] < 128 { pixels[k] = 0; pixels[k+1] = 0; pixels[k+2] = 0; pixels[k+3] = 0; continue }
  let a = Double(pixels[k+3]) / 255
  let rgb = (0..<3).map { min(255, Int(Double(pixels[k+$0])/a)) }
  var best = palette[0]
  var score = Int.max
  for candidate in palette {
   let dr = candidate[0] - rgb[0], dg = candidate[1] - rgb[1], db = candidate[2] - rgb[2]
   let distance = dr*dr + dg*dg + db*db
   if distance < score { score = distance; best = candidate }
  }
  for c in 0..<3 { pixels[k+c] = UInt8(best[c]) }; pixels[k+3] = 255
 }
 let sprite = base.makeImage()!
 let target = CGImageDestinationCreateWithURL(root.appendingPathComponent("catpaw-\(name).gif") as CFURL, UTType.gif.identifier as CFString, 32, nil)!
 CGImageDestinationSetProperties(target, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
 for frame in 0..<32 {
  let phase = Double(frame) / 32 * .pi * 2
  let ctx = CGContext(data: nil, width: 160, height: 160, bitsPerComponent: 8, bytesPerRow: 640, space: colorSpace, bitmapInfo: info)!
  ctx.interpolationQuality = .none; ctx.setShouldAntialias(false); ctx.scaleBy(x: 4,y: 4)
  let bounce = name == "running" ? (frame % 2 == 0 ? 1.0 : -1.0) : sin(phase) * (1.0)
  ctx.translateBy(x: 20, y: 20 + bounce.rounded())
  if name == "waiting-question" { ctx.rotate(by: sin(phase) * .pi / 60) }
  ctx.draw(sprite, in: CGRect(x: -20, y: -20, width: 40, height: 40))
  CGImageDestinationAddImage(target, ctx.makeImage()!, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: frame % 2 == 0 ? 0.12 : 0.13, kCGImagePropertyGIFUnclampedDelayTime: frame % 2 == 0 ? 0.12 : 0.13]] as CFDictionary)
 }
 guard CGImageDestinationFinalize(target) else { fatalError("GIF export failed") }
 let png = CGImageDestinationCreateWithURL(root.appendingPathComponent("\(name)-preview.png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
 CGImageDestinationAddImage(png, sprite, nil); CGImageDestinationFinalize(png)
 print(name, "160x160, 32 frames, 4 seconds, transparent, looping")
}
