import Foundation

/// Per-frame pixel statistics over the frame minus a border.
public struct FrameStats: Equatable, Sendable, Codable {
    /// Mean of 8-bit encoded values / 255 (Rec.709-weighted luma of encoded RGB).
    public var meanEncodedLuma: Double
    /// Mean linear R, G, B (sRGB inverse transfer), 0…1.
    public var meanLinearR: Double
    public var meanLinearG: Double
    public var meanLinearB: Double
    /// Fraction of sampled pixels with any channel ≥ 250.
    public var saturatedFraction: Double
    public var sampleCount: Int

    public init(
        meanEncodedLuma: Double, meanLinearR: Double, meanLinearG: Double, meanLinearB: Double,
        saturatedFraction: Double, sampleCount: Int
    ) {
        self.meanEncodedLuma = meanEncodedLuma
        self.meanLinearR = meanLinearR
        self.meanLinearG = meanLinearG
        self.meanLinearB = meanLinearB
        self.saturatedFraction = saturatedFraction
        self.sampleCount = sampleCount
    }

    /// Rec.709 luminance of the linear means.
    public var meanLinearLuma: Double {
        0.2126 * meanLinearR + 0.7152 * meanLinearG + 0.0722 * meanLinearB
    }
}

public enum FrameAnalyzer {
    /// sRGB inverse transfer, indexed by 8-bit code value.
    public static let linearLUT: [Double] = (0..<256).map { code in
        let v = Double(code) / 255
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    /// Half-open pixel rectangle [x0, x1) × [y0, y1).
    public struct PixelRect: Equatable, Sendable {
        public var x0: Int, y0: Int, x1: Int, y1: Int
    }

    /// Crop rectangle excluding `border` fraction on each side.
    public static func cropRect(width: Int, height: Int, border: Double) -> PixelRect {
        let bx = Int((Double(width) * border).rounded())
        let by = Int((Double(height) * border).rounded())
        return PixelRect(x0: bx, y0: by, x1: max(bx, width - bx), y1: max(by, height - by))
    }

    /// Analyse a BGRA8 buffer. `step` samples every `step`-th pixel in both directions.
    public static func analyzeBGRA(
        base: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int,
        border: Double, step: Int = 4
    ) -> FrameStats {
        let r = cropRect(width: width, height: height, border: border)
        let lut = linearLUT
        var sumR = 0.0, sumG = 0.0, sumB = 0.0, sumEnc = 0.0
        var saturated = 0, n = 0
        let px = base.assumingMemoryBound(to: UInt8.self)
        var y = r.y0
        while y < r.y1 {
            let row = px + y * bytesPerRow
            var x = r.x0
            while x < r.x1 {
                let p = row + x * 4
                let b = Int(p[0]), g = Int(p[1]), rr = Int(p[2])
                sumB += lut[b]; sumG += lut[g]; sumR += lut[rr]
                sumEnc += 0.2126 * Double(rr) + 0.7152 * Double(g) + 0.0722 * Double(b)
                if rr >= 250 || g >= 250 || b >= 250 { saturated += 1 }
                n += 1
                x += step
            }
            y += step
        }
        guard n > 0 else {
            return FrameStats(
                meanEncodedLuma: 0, meanLinearR: 0, meanLinearG: 0, meanLinearB: 0, saturatedFraction: 0, sampleCount: 0
            )
        }
        let d = Double(n)
        return FrameStats(
            meanEncodedLuma: sumEnc / d / 255,
            meanLinearR: sumR / d, meanLinearG: sumG / d, meanLinearB: sumB / d,
            saturatedFraction: Double(saturated) / d, sampleCount: n)
    }
}
