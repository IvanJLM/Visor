import Foundation
import UniformTypeIdentifiers

/// Lists the images in a folder in Finder's name order.
enum FolderScanner {
    static func isImage(_ url: URL) -> Bool {
        guard let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension) else { return false }
        return isDecodableImage(type)
    }

    private static let decodableUTTypes = ImageDecoder.decodableTypes.compactMap { UTType($0) }

    static func isDecodableImage(_ type: UTType) -> Bool {
        ImageDecoder.decodableTypes.contains(type.identifier) || decodableUTTypes.contains { type.conforms(to: $0) }
    }

    static func images(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.contentTypeKey, .isRegularFileKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        var cache: [String: Bool] = [:]
        let images = entries.filter { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let type = values.contentType else { return false }
            if let known = cache[type.identifier] { return known }
            let ok = isDecodableImage(type)
            cache[type.identifier] = ok
            return ok
        }
        return images.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    static func modificationDate(of folder: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: folder.path)[.modificationDate] as? Date
    }
}
