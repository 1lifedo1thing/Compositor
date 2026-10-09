import Foundation

/// Camera Raw's per-pixel Light and Color sliders as Photoshop's own Camera Raw Filter draws them: color tables
/// measured from it (Resources/CameraRawTables.bin), each the colors of a 17³ grid after one slider at one value.
/// A value in between blends the two nearest tables. Temperature and Tint, which Camera Raw turns into one white
/// point together, come from a grid of both and blend four.
nonisolated enum CameraRawTables {
    static let size = 17
    /// The grid the stages are composed onto, finer than the tables so composing adds little blur.
    static let grid = 33
    private static let entries = size * size * size * 3
    /// White balance: a 9 × 9 grid, Temperature by rows and Tint across, each −100…100 by 25. Then Exposure −5…5 by
    /// 0.5, and Contrast, Whites, Blacks, Saturation and Vibrance, each −100…100 by 25.
    private static let exposureStart = 81, contrastStart = 102, whitesStart = 111, blacksStart = 120
    private static let saturationStart = 129, vibranceStart = 138, count = 147

    /// Every table, red slowest then green then blue, 3 bytes a color. Read once and kept for the app's life.
    static let tables: UnsafeMutablePointer<UInt8>? = load()

    /// The file holds, for each table and channel in turn, each entry's difference from no change, as a running
    /// difference from the entry before: the tables move smoothly, so this packs small.
    private static func load() -> UnsafeMutablePointer<UInt8>? {
        guard let url = Bundle.main.url(forResource: "CameraRawTables", withExtension: "bin"),
              let file = try? Data(contentsOf: url), file.count > 8, file.prefix(4) == Data("CRT2".utf8),
              Int(file[4]) | Int(file[5]) << 8 == size, Int(file[6]) | Int(file[7]) << 8 == count,
              let planes = try? (file.dropFirst(8) as NSData).decompressed(using: .zlib) as Data,
              planes.count == count * entries else { return nil }
        let tables = UnsafeMutablePointer<UInt8>.allocate(capacity: count * entries)
        let cells = size * size * size
        let level = (0..<size).map { UInt8((Double($0) * 255 / Double(size - 1)).rounded()) }
        planes.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for table in 0..<count {
                for channel in 0..<3 {
                    let base = (table * 3 + channel) * cells
                    var running: UInt8 = 0
                    for cell in 0..<cells {
                        running &+= bytes[base + cell]
                        let axis = channel == 0 ? cell / (size * size) : channel == 1 ? (cell / size) % size : cell % size
                        tables[table * entries + cell * 3 + channel] = running &+ level[axis]
                    }
                }
            }
        }
        return tables
    }

    private static func table(_ index: Int) -> UnsafePointer<UInt8>? {
        tables.map { UnsafePointer($0 + index * entries) }
    }

    /// The two tables either side of `value` on a run of tables `step` apart from `low`, and how far it is between.
    private static func between(_ value: Double, low: Double, step: Double, tables: Int) -> (Int, Double) {
        let position = min(Double(tables - 1), max(0, (value - low) / step))
        let index = min(tables - 2, Int(position))
        return (index, position - Double(index))
    }

    private static func stage(_ start: Int, _ value: Double, low: Double, step: Double, tables: Int) -> CameraRawStage {
        let (index, fraction) = between(value, low: low, step: step, tables: tables)
        return CameraRawStage(table: (table(start + index), table(start + index + 1), nil, nil),
                              weight: (Float(1 - fraction), Float(fraction), 0, 0))
    }

    /// Temperature and Tint: the four grid tables around them, blended.
    static func whiteBalance(temperature: Double, tint: Double) -> CameraRawStage {
        let (row, down) = between(temperature, low: -100, step: 25, tables: 9)
        let (column, across) = between(tint, low: -100, step: 25, tables: 9)
        return CameraRawStage(table: (table(row * 9 + column), table(row * 9 + column + 1),
                                      table((row + 1) * 9 + column), table((row + 1) * 9 + column + 1)),
                              weight: (Float((1 - down) * (1 - across)), Float((1 - down) * across),
                                       Float(down * (1 - across)), Float(down * across)))
    }

    /// The stages before Highlights and Shadows (Exposure, white balance, Contrast) and after them (Whites, Blacks,
    /// Saturation, Vibrance), in Camera Raw's order, leaving out sliders at zero.
    static func stages(for settings: CameraRawSettings) -> (before: [CameraRawStage], after: [CameraRawStage]) {
        var before: [CameraRawStage] = [], after: [CameraRawStage] = []
        if settings.exposure != 0 { before.append(stage(exposureStart, settings.exposure, low: -5, step: 0.5, tables: 21)) }
        if settings.temperature != 0 || settings.tint != 0 {
            before.append(whiteBalance(temperature: settings.temperature, tint: settings.tint))
        }
        if settings.contrast != 0 { before.append(stage(contrastStart, settings.contrast, low: -100, step: 25, tables: 9)) }
        if settings.whites != 0 { after.append(stage(whitesStart, settings.whites, low: -100, step: 25, tables: 9)) }
        if settings.blacks != 0 { after.append(stage(blacksStart, settings.blacks, low: -100, step: 25, tables: 9)) }
        if settings.saturation != 0 { after.append(stage(saturationStart, settings.saturation, low: -100, step: 25, tables: 9)) }
        if settings.vibrance != 0 { after.append(stage(vibranceStart, settings.vibrance, low: -100, step: 25, tables: 9)) }
        return (before, after)
    }

    /// The stages run over the composing grid, or nil when there are none.
    static func compose(_ stages: [CameraRawStage]) -> [Float]? {
        guard !stages.isEmpty, tables != nil else { return nil }
        var out = [Float](repeating: 0, count: grid * grid * grid * 3)
        stages.withUnsafeBufferPointer { camera_raw_compose(&out, Int32(grid), $0.baseAddress, Int32($0.count), Int32(size)) }
        return out
    }

    /// The Temperature and Tint that turn a straight sRGB color (0…1) most nearly gray: a coarse search over both
    /// sliders, then a finer one around the best. Nil when the tables aren't there or the color has no channel to
    /// balance from.
    static func neutralize(red: Double, green: Double, blue: Double) -> (temperature: Double, tint: Double)? {
        guard tables != nil, min(red, green, blue) > 1e-4 else { return nil }
        func cast(_ temperature: Double, _ tint: Double) -> Double {
            var stage = whiteBalance(temperature: temperature, tint: tint)
            var color = [red, green, blue]
            camera_raw_stage_color(&stage, Int32(size), &color)
            return color.max()! - color.min()!
        }
        var best = (temperature: 0.0, tint: 0.0, cast: cast(0, 0))
        for (step, reach) in [(10.0, 100.0), (2.0, 10.0), (0.5, 2.0)] {
            let center = best
            for temperature in stride(from: center.temperature - reach, through: center.temperature + reach, by: step) {
                for tint in stride(from: center.tint - reach, through: center.tint + reach, by: step) {
                    guard abs(temperature) <= 100, abs(tint) <= 100 else { continue }
                    let found = cast(temperature, tint)
                    if found < best.cast { best = (temperature, tint, found) }
                }
            }
        }
        return (best.temperature, best.tint)
    }
}
