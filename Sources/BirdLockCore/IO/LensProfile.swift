import Foundation
import CoreImage

public enum VideoImportError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}

/// The static OpenCV subset of Gyroflow's JSON format. Does not read gyro samples.
public struct LensProfile: Sendable {
    public let name: String
    public let width: Int
    public let height: Int
    public let matrix: [[Double]]
    public let coefficients: [Double]
    public let model: String
    public let raw: Data

    public static func load(_ url: URL) throws -> LensProfile {
        if url.pathExtension.lowercased() == "xml" {
            let match = try LensCatalog.importXML(url)
            guard let profile = match.selectedURL else { throw VideoImportError.invalid("已读取索尼 XML。" + match.message) }
            return try load(profile)
        }
        let data = try Data(contentsOf: url)
        guard data.count <= 1_048_576 else { throw VideoImportError.invalid("镜头配置文件过大（上限 1 MB）") }
        guard let d = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let size = d["calib_dimension"] as? [String: Int], let w = size["w"], let h = size["h"],
              let params = d["fisheye_params"] as? [String: Any],
              let k = params["camera_matrix"] as? [[Double]], let c = params["distortion_coeffs"] as? [Double]
        else { throw VideoImportError.invalid("不是有效的 Gyroflow 镜头 JSON 配置") }
        let model = d["distortion_model"] as? String ?? "opencv_fisheye"
        guard ["opencv_fisheye", "opencv_standard"].contains(model) else { throw VideoImportError.invalid("暂不支持此镜头畸变模型：" + model) }
        let digital = d["digital_lens"] as? String ?? ""
        let interpolated = (d["interpolations"] as? [String: Any])?.isEmpty == false || (d["interpolations"] as? [Any])?.isEmpty == false
        guard digital.isEmpty, !interpolated,
              ["input_horizontal_stretch", "input_vertical_stretch"].allSatisfy({ [0.0, 1.0].contains(d[$0] as? Double ?? 1) })
        else { throw VideoImportError.invalid("暂不支持数字镜头、变焦插值或非等比拉伸配置") }
        guard (2...32768).contains(w), (2...32768).contains(h), k.count == 3, k.allSatisfy({ $0.count == 3 }),
              k.flatMap({ $0 }).allSatisfy(\.isFinite), c.allSatisfy(\.isFinite),
              abs(k[2][0]) < 1e-9, abs(k[2][1]) < 1e-9, abs(k[2][2] - 1) < 1e-9,
              abs(k[0][1]) < 1e-9, abs(k[1][0]) < 1e-9, k[0][0] > 0, k[1][1] > 0,
              k[0][2] >= 0, k[0][2] < Double(w), k[1][2] >= 0, k[1][2] < Double(h),
              (model == "opencv_fisheye" ? [4] : [4, 5, 8]).contains(c.count)
        else { throw VideoImportError.invalid("镜头矩阵或畸变系数无效 / 暂不支持") }
        let title = d["name"] as? String ?? ["camera_brand", "camera_model", "lens_model"].compactMap { d[$0] as? String }.joined(separator: " ")
        return LensProfile(name: title.isEmpty ? url.deletingPathExtension().lastPathComponent : title,
                           width: w, height: h, matrix: k, coefficients: c, model: model, raw: data)
    }

    public func validate(width w: Int, height h: Int) throws {
        guard abs((Double(w) / Double(h)) / (Double(width) / Double(height)) - 1) <= 0.002 else {
            throw VideoImportError.invalid("镜头配置与视频宽高比不一致；请选择相同拍摄模式的配置")
        }
    }

    private static let kernel = CIWarpKernel(source: """
        kernel vec2 lensMap(vec4 intrinsics, vec4 a, vec4 b, float height, float fish) {
            vec2 p = destCoord();
            vec2 n = (vec2(p.x - 0.5, height - p.y - 0.5) - intrinsics.zw) / intrinsics.xy;
            float r2 = dot(n, n);
            vec2 q;
            if (fish > 0.5) {
                float r = sqrt(r2);
                float theta = atan(r);
                float t2 = theta * theta;
                float td = theta * (1.0 + a.x*t2 + a.y*t2*t2 + a.z*t2*t2*t2 + a.w*t2*t2*t2*t2);
                q = n * (r > 0.00000001 ? td / r : 1.0);
            } else {
                float radial = (1.0 + a.x*r2 + a.y*r2*r2 + b.x*r2*r2*r2) / (1.0 + b.y*r2 + b.z*r2*r2 + b.w*r2*r2*r2);
                q.x = n.x*radial + 2.0*a.z*n.x*n.y + a.w*(r2 + 2.0*n.x*n.x);
                q.y = n.y*radial + a.z*(r2 + 2.0*n.y*n.y) + 2.0*a.w*n.x*n.y;
            }
            vec2 uv = q * intrinsics.xy + intrinsics.zw;
            return vec2(uv.x + 0.5, height - uv.y - 0.5);
        }
        """)

    public func correct(_ image: CIImage) throws -> CIImage {
        let w = Int(image.extent.width), h = Int(image.extent.height)
        try validate(width: w, height: h)
        let sx = Double(w) / Double(width), sy = Double(h) / Double(height)
        let intrinsics = CIVector(x: matrix[0][0]*sx, y: matrix[1][1]*sy, z: matrix[0][2]*sx, w: matrix[1][2]*sy)
        let c = coefficients + Array(repeating: 0.0, count: 8 - coefficients.count)
        guard let kernel = Self.kernel, let result = kernel.apply(extent: image.extent, roiCallback: { _, _ in image.extent }, image: image,
            arguments: [intrinsics, CIVector(x:c[0],y:c[1],z:c[2],w:c[3]), CIVector(x:c[4],y:c[5],z:c[6],w:c[7]), Double(h), model == "opencv_fisheye" ? 1.0 : 0.0])
        else { throw VideoImportError.invalid("当前系统无法执行镜头校正") }
        return result
    }
}
