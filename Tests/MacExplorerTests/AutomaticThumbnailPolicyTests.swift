import Foundation
import Testing
@testable import MacExplorer

@Suite("Automatic thumbnail policy")
struct AutomaticThumbnailPolicyTests {
    @Test("Only small local regular files receive automatic thumbnails")
    func eligibility() {
        let limit = AutomaticThumbnailPolicy.maximumFileSize

        #expect(AutomaticThumbnailPolicy.allows(
            isDirectory: false,
            isPackage: false,
            isOnLocalVolume: true,
            byteCount: limit
        ))
        #expect(!AutomaticThumbnailPolicy.allows(
            isDirectory: false,
            isPackage: false,
            isOnLocalVolume: true,
            byteCount: limit + 1
        ))
        #expect(!AutomaticThumbnailPolicy.allows(
            isDirectory: false,
            isPackage: false,
            isOnLocalVolume: false,
            byteCount: 1
        ))
        #expect(!AutomaticThumbnailPolicy.allows(
            isDirectory: true,
            isPackage: false,
            isOnLocalVolume: true,
            byteCount: 1
        ))
        #expect(!AutomaticThumbnailPolicy.allows(
            isDirectory: true,
            isPackage: true,
            isOnLocalVolume: true,
            byteCount: 1
        ))
        #expect(!AutomaticThumbnailPolicy.allows(
            isDirectory: false,
            isPackage: false,
            isOnLocalVolume: true,
            byteCount: nil
        ))
    }

    @Test("Quick Look generation is capped at two concurrent requests")
    func concurrencyLimit() {
        #expect(AutomaticThumbnailPolicy.maximumConcurrentRequests == 2)
    }

    @Test("Cloud placeholders never receive automatic thumbnails")
    func cloudPlaceholderEligibility() {
        let common = (
            isDirectory: false,
            isPackage: false,
            isOnLocalVolume: true,
            byteCount: Int64(1_024)
        )

        #expect(!AutomaticThumbnailPolicy.allows(
            isDirectory: common.isDirectory,
            isPackage: common.isPackage,
            isOnLocalVolume: common.isOnLocalVolume,
            byteCount: common.byteCount,
            isUbiquitousItem: true,
            ubiquitousItemDownloadingStatus: .notDownloaded
        ))

        // File Provider implementations do not all populate every ubiquity
        // key. A definitive not-downloaded status must win on its own.
        #expect(!AutomaticThumbnailPolicy.allows(
            isDirectory: common.isDirectory,
            isPackage: common.isPackage,
            isOnLocalVolume: common.isOnLocalVolume,
            byteCount: common.byteCount,
            isUbiquitousItem: nil,
            ubiquitousItemDownloadingStatus: .notDownloaded
        ))

        #expect(!AutomaticThumbnailPolicy.allows(
            isDirectory: common.isDirectory,
            isPackage: common.isPackage,
            isOnLocalVolume: common.isOnLocalVolume,
            byteCount: common.byteCount,
            isUbiquitousItem: true,
            ubiquitousItemDownloadingStatus: .downloaded,
            ubiquitousItemIsDownloading: true
        ))

        #expect(!AutomaticThumbnailPolicy.allows(
            isDirectory: common.isDirectory,
            isPackage: common.isPackage,
            isOnLocalVolume: common.isOnLocalVolume,
            byteCount: common.byteCount,
            isUbiquitousItem: true,
            ubiquitousItemDownloadingStatus: nil
        ))
    }

    @Test("Materialized cloud files and ordinary local files remain eligible")
    func materializedCloudEligibility() {
        for status in [
            URLUbiquitousItemDownloadingStatus.downloaded,
            URLUbiquitousItemDownloadingStatus.current
        ] {
            #expect(AutomaticThumbnailPolicy.allows(
                isDirectory: false,
                isPackage: false,
                isOnLocalVolume: true,
                byteCount: 1_024,
                isUbiquitousItem: true,
                ubiquitousItemDownloadingStatus: status,
                ubiquitousItemIsDownloading: false
            ))
        }

        #expect(AutomaticThumbnailPolicy.allows(
            isDirectory: false,
            isPackage: false,
            isOnLocalVolume: true,
            byteCount: 1_024,
            isUbiquitousItem: nil,
            ubiquitousItemDownloadingStatus: nil,
            ubiquitousItemIsDownloading: nil
        ))
    }
}
