import CryptoKit
import Foundation

/// A fingerprint of what a project package contains: the manifest and every asset, byte for byte. A package that
/// was only touched (a sync client rewriting metadata, a permission change, the same bytes saved again) has the
/// same digest as before, so it is not treated as a change.
nonisolated struct ProjectDigest: Equatable, Sendable {
    let value: Data

    /// Reads the package outside file coordination on purpose: it is called after a change was already seen and
    /// it must never wait on a writer. A package caught half written yields a digest that matches nothing, or an
    /// error; both make the caller wait for the next change.
    static func compute(for url: URL) throws -> ProjectDigest {
        var hasher = SHA256()
        let manifest = try Data(contentsOf: url.appendingPathComponent("manifest.json"))
        hasher.update(data: manifest)
        let images = url.appendingPathComponent("images", isDirectory: true)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: images.path)) ?? []).sorted()
        for name in names {
            let file = images.appendingPathComponent(name)
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            hasher.update(data: Data(name.utf8))
            let data = try Data(contentsOf: file, options: .mappedIfSafe)
            var count = UInt64(data.count)
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: &count, count: MemoryLayout<UInt64>.size))
            hasher.update(data: data)
        }
        return ProjectDigest(value: Data(hasher.finalize()))
    }
}
