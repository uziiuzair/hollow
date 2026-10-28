import CoreGraphics

/// Squarified treemap tiling: Bruls, Huizing, van Wijk (2000).
public enum Squarify {
    /// `sizes` are sorted descending and all > 0. Returns one tile per size, in the same order,
    /// tiling `rect` exactly. Coordinates are points with a top-left origin.
    public static func tiles(_ sizes: [Double], in rect: CGRect) -> [CGRect] {
        let total = sizes.reduce(0, +)
        guard total > 0, rect.width > 0, rect.height > 0 else { return sizes.map { _ in .zero } }
        let scale = Double(rect.width * rect.height) / total
        var free = rect, result: [CGRect] = [], i = 0
        result.reserveCapacity(sizes.count)
        while i < sizes.count {
            let side = Double(min(free.width, free.height))
            func worst(_ sum: Double, _ lo: Double, _ hi: Double) -> Double {
                max(side * side * hi / (sum * sum), sum * sum / (side * side * lo))
            }
            var sum = 0.0, lo = Double.infinity, hi = 0.0, j = i
            while j < sizes.count {
                let a = sizes[j] * scale
                if j > i, worst(sum + a, min(lo, a), max(hi, a)) > worst(sum, lo, hi) { break }
                sum += a; lo = min(lo, a); hi = max(hi, a); j += 1
            }
            let thickness = sum / side, column = free.width >= free.height
            var offset = 0.0
            for k in i..<j {
                let length = sizes[k] * scale / thickness
                result.append(column ? CGRect(x: free.minX, y: free.minY + offset, width: thickness, height: length)
                                     : CGRect(x: free.minX + offset, y: free.minY, width: length, height: thickness))
                offset += length
            }
            free = column ? CGRect(x: free.minX + thickness, y: free.minY, width: free.width - thickness, height: free.height)
                          : CGRect(x: free.minX, y: free.minY + thickness, width: free.width, height: free.height - thickness)
            i = j
        }
        return result
    }
}
