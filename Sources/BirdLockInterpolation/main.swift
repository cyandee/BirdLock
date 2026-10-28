import Foundation
import CoreImage
import BirdLockCore

Diagnostics.start(role: "flow")
@available(macOS 15.4, *)
func run() throws {
guard CommandLine.arguments.count == 3, let width = Int(CommandLine.arguments[1]),
      let height = Int(CommandLine.arguments[2]), width >= 16, height >= 16,
      width <= 8192, height <= 4320 else { exit(2) }
guard AIInterpolator.isSupported else { exit(3) }
let context = CIContext(options: [.cacheIntermediates: false])
guard let ai = AIInterpolator(width: width,height: height,context: context) else { exit(4) }
let input = FileHandle.standardInput, output = FileHandle.standardOutput
try output.write(contentsOf: Data("BLFLOW1\n".utf8))
let count = width*height*4
while let phaseBytes = try FlowWorkerIO.read(input, count: 8) {
    let phase = phaseBytes.withUnsafeBytes { $0.loadUnaligned(as: Double.self) }
    guard phase.isFinite, phase > 0, phase < 1,
          let first = try FlowWorkerIO.read(input, count: count),
          let second = try FlowWorkerIO.read(input, count: count) else { exit(5) }
    let result: Data? = autoreleasepool {
        let a = CIImage(bitmapData: first,bytesPerRow: width*4,size: CGSize(width: width,height: height),format: .BGRA8,colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        let b = CIImage(bitmapData: second,bytesPerRow: width*4,size: CGSize(width: width,height: height),format: .BGRA8,colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        guard let image = ai.interpolate(a,b,phase: phase) else { return nil }
        var pixels = Data(count: count)
        pixels.withUnsafeMutableBytes { bytes in
            context.render(image,toBitmap: bytes.baseAddress!,rowBytes: width*4,bounds: CGRect(x: 0,y: 0,width: width,height: height),format: .BGRA8,colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
        return pixels
    }
    guard let result else { Diagnostics.record("interpolation failed"); try output.write(contentsOf: Data([0])); exit(6) }
    try output.write(contentsOf: Data([1])); try output.write(contentsOf: result)
}
Diagnostics.finish()

}
if #available(macOS 15.4, *) { try run() } else { exit(3) }
