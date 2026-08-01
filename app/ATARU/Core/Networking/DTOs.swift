import Foundation

/// Wire types for the ATARU backend.
///
/// Kept separate from the domain models so a server-side rename is absorbed
/// here rather than across every view. The server speaks snake_case and Unix
/// timestamps; the app speaks camelCase and `Date`. This file is the only
/// place that knows both.
enum DTO {

    // MARK: Documents

    struct DocumentSummary: Decodable {
        let id: String
        let title: String
        let path: String
        let category: String
        let fileType: String
        let sizeBytes: Int64?
        let modifiedAt: Double?
        let indexedAt: Double?
        let excerpt: String?
        let chunkCount: Int?
        let tags: [String]?
        let previewable: Bool?

        enum CodingKeys: String, CodingKey {
            case id, title, path, category, excerpt, tags, previewable
            case fileType = "file_type"
            case sizeBytes = "size_bytes"
            case modifiedAt = "modified_at"
            case indexedAt = "indexed_at"
            case chunkCount = "chunk_count"
        }

        var domain: IndexedDocument {
            IndexedDocument(
                id: id,
                title: title,
                category: DocumentCategory(serverValue: category),
                path: path,
                fileType: fileType.lowercased(),
                sizeBytes: sizeBytes,
                modifiedAt: Self.date(modifiedAt),
                indexedAt: Self.date(indexedAt),
                excerpt: excerpt ?? "",
                chunkCount: chunkCount,
                tags: tags ?? [],
                previewable: previewable ?? false
            )
        }

        /// Timestamps are optional throughout: state entries written by older
        /// indexer builds genuinely have no ingest time, and that must render
        /// as "unknown" rather than 1 January 1970.
        private static func date(_ value: Double?) -> Date? {
            guard let value, value > 0 else { return nil }
            return Date(timeIntervalSince1970: value)
        }
    }

    struct DocumentList: Decodable {
        let documents: [DocumentSummary]
        let total: Int
        let indexedTotal: Int
        let categories: [String: Int]

        enum CodingKeys: String, CodingKey {
            case documents, total, categories
            case indexedTotal = "indexed_total"
        }

        var domain: DocumentLibraryPage {
            var counts: [DocumentCategory: Int] = [:]
            for (raw, count) in categories {
                // An unrecognised category from a newer server folds into the
                // bucket it would be displayed in, rather than being dropped.
                counts[DocumentCategory(serverValue: raw), default: 0] += count
            }
            counts[.all] = indexedTotal
            return DocumentLibraryPage(
                documents: documents.map(\.domain),
                total: total,
                indexedTotal: indexedTotal,
                categoryCounts: counts
            )
        }
    }

    // MARK: Voice

    struct VoiceAnswer: Decodable {
        let text: String
        let source: String?
        let model: String?
    }

    // MARK: Health

    struct Health: Decodable {
        let status: String
    }
}

/// JSON decoding for this API.
///
/// The backend sends numeric Unix timestamps, not ISO-8601 strings, and every
/// timestamp is nullable — so dates are converted per-field in the DTOs above
/// rather than by a global `dateDecodingStrategy`.
enum ATARUCoding {
    static var decoder: JSONDecoder { JSONDecoder() }
    static var encoder: JSONEncoder { JSONEncoder() }
}
