import Foundation

protocol FileSink: Sendable {
    func begin(requiredBytes: Int64) throws -> FileWriter
}

/// Writes to a hidden temp file, then renames, so a half-received file never shows up.
struct FolderSink: FileSink {
    let folder: URL

    func begin(requiredBytes: Int64) throws -> FileWriter {
        let free = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        if let free, free < requiredBytes { throw AirSlideError.noSpace }
        return try FileWriter(tempURL: folder.appendingPathComponent(".airslide-\(UUID().uuidString).part"), folder: folder)
    }
}

final class FileWriter {
    let tempURL: URL
    let folder: URL
    private let handle: FileHandle

    init(tempURL: URL, folder: URL) throws {
        guard FileManager.default.createFile(atPath: tempURL.path, contents: nil),
              let h = try? FileHandle(forWritingTo: tempURL) else { throw AirSlideError.noTempFile }
        self.tempURL = tempURL; self.folder = folder; self.handle = h
    }

    func write(_ data: Data) throws {
        do { try handle.write(contentsOf: data) } catch { throw AirSlideError.saveFailed }
    }

    func finish(as name: String) throws -> URL {
        try? handle.close()
        let clean = (name as NSString).lastPathComponent
        let base = ((clean.isEmpty ? "AirSlide File" : clean) as NSString)
        let stem = base.deletingPathExtension, ext = base.pathExtension
        let fm = FileManager.default
        for n in 1...1000 {
            let candidate = n == 1 ? base as String : "\(stem) \(n)" + (ext.isEmpty ? "" : ".\(ext)")
            let dest = folder.appendingPathComponent(candidate)
            if fm.fileExists(atPath: dest.path) { continue }
            do { try fm.moveItem(at: tempURL, to: dest); return dest } catch { throw AirSlideError.saveFailed }
        }
        throw AirSlideError.noFreeName
    }

    func discard() {
        try? handle.close()
        try? FileManager.default.removeItem(at: tempURL)
    }
}
