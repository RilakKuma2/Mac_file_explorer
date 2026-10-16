import CryptoKit
import Foundation

enum ChecksumService {
    static func sha256(for urls: [URL]) throws -> [(url: URL, digest: String)] {
        try urls.map { url in
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                hasher.update(data: data)
            }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            return (url, digest)
        }
    }
}
