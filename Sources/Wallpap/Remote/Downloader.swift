import Foundation

enum Downloader {
    /// Downloads `url` into a private temp folder, keeping `fileName`, and reports progress 0…1.
    static func download(_ url: URL, fileName: String,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let delegate = ProgressDelegate(progress)
        let (tmp, resp) = try await HTTP.session.download(for: URLRequest(url: url), delegate: delegate)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: tmp)
            throw RemoteError.unavailable("Сервер вернул \(http.statusCode) при загрузке файла.")
        }
        let dir = FileManager.default.temporaryDirectory.appending(path: "Wallpap-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appending(path: sanitize(fileName))
        try FileManager.default.moveItem(at: tmp, to: dest)
        progress(1)
        return dest
    }

    static func sanitize(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>").union(.newlines).union(.controlCharacters)
        let cleaned = name.components(separatedBy: bad).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return String((cleaned.isEmpty ? "wallpaper" : cleaned).prefix(120))
    }

    private final class ProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let onProgress: @Sendable (Double) -> Void
        private var observation: NSKeyValueObservation?

        init(_ onProgress: @escaping @Sendable (Double) -> Void) { self.onProgress = onProgress }

        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
            observation = task.progress.observe(\.fractionCompleted) { [onProgress] p, _ in
                onProgress(p.fractionCompleted)
            }
        }
    }
}
