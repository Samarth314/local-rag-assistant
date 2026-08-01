import XCTest
@testable import ATARU

/// Filtering and sorting are pure, so they are tested directly rather than
/// through the UI. These are the rules the library's correctness rests on.
final class DocumentQueryTests: XCTestCase {

    private func document(id: String,
                          title: String,
                          category: DocumentCategory = .work,
                          path: String = "records/work/file.md",
                          modified: Date? = nil,
                          indexed: Date? = nil,
                          excerpt: String = "",
                          tags: [String] = []) -> IndexedDocument {
        IndexedDocument(id: id, title: title, category: category, path: path,
                        fileType: "md", sizeBytes: 100, modifiedAt: modified,
                        indexedAt: indexed, excerpt: excerpt, chunkCount: 1,
                        tags: tags, previewable: true)
    }

    // MARK: Filtering

    func testQueryMatchesTitleCaseInsensitively() {
        let documents = [document(id: "1", title: "Tax Return.pdf"),
                         document(id: "2", title: "Recipes.md")]
        let found = DocumentQuery.filter(documents, query: "TAX", category: .all)
        XCTAssertEqual(found.map(\.id), ["1"])
    }

    func testQueryMatchesPathAndExcerptAndTags() {
        let documents = [
            document(id: "path", title: "a", path: "records/health/panel.md"),
            document(id: "excerpt", title: "b", excerpt: "mentions haemoglobin"),
            document(id: "tag", title: "c", tags: ["quarterly"])
        ]
        XCTAssertEqual(DocumentQuery.filter(documents, query: "health", category: .all).map(\.id), ["path"])
        XCTAssertEqual(DocumentQuery.filter(documents, query: "haemo", category: .all).map(\.id), ["excerpt"])
        XCTAssertEqual(DocumentQuery.filter(documents, query: "quarter", category: .all).map(\.id), ["tag"])
    }

    func testWhitespaceOnlyQueryIsNotAFilter() {
        // Typing a space must not empty the library.
        let documents = [document(id: "1", title: "a"), document(id: "2", title: "b")]
        XCTAssertEqual(DocumentQuery.filter(documents, query: "   ", category: .all).count, 2)
        XCTAssertEqual(DocumentQuery.filter(documents, query: nil, category: .all).count, 2)
    }

    func testAllCategoryIsNotAFilter() {
        let documents = [document(id: "1", title: "a", category: .health),
                         document(id: "2", title: "b", category: .work)]
        XCTAssertEqual(DocumentQuery.filter(documents, query: nil, category: .all).count, 2)
        XCTAssertEqual(DocumentQuery.filter(documents, query: nil, category: .health).map(\.id), ["1"])
    }

    func testQueryAndCategoryAreCombinedNotAlternatives() {
        let documents = [document(id: "1", title: "tax", category: .finances),
                         document(id: "2", title: "tax", category: .health)]
        XCTAssertEqual(DocumentQuery.filter(documents, query: "tax", category: .health).map(\.id), ["2"])
    }

    // MARK: Sorting

    func testSortByModifiedDatePutsNewestFirst() {
        let old = document(id: "old", title: "old", modified: Date(timeIntervalSince1970: 100))
        let new = document(id: "new", title: "new", modified: Date(timeIntervalSince1970: 900))
        XCTAssertEqual(DocumentQuery.sort([old, new], by: .documentDate).map(\.id), ["new", "old"])
    }

    func testDocumentsWithNoDateSortLastRatherThanFirst() {
        // A nil date must not read as "very old but present" and float to the
        // top of a descending sort; unknown belongs at the bottom.
        let dated = document(id: "dated", title: "a", modified: Date(timeIntervalSince1970: 100))
        let undated = document(id: "undated", title: "b", modified: nil)
        XCTAssertEqual(DocumentQuery.sort([undated, dated], by: .documentDate).map(\.id),
                       ["dated", "undated"])
    }

    func testSortByTitleIsCaseInsensitive() {
        let documents = [document(id: "b", title: "banana.md"),
                         document(id: "A", title: "Apple.md")]
        XCTAssertEqual(DocumentQuery.sort(documents, by: .title).map(\.id), ["A", "b"])
    }

    // MARK: Counts

    func testCountsIncludeEveryCategoryEvenWhenEmpty() {
        // The filter row must not reflow as the vault changes, so absent
        // categories still report zero.
        let counts = DocumentQuery.counts([document(id: "1", title: "a", category: .work)])
        for category in DocumentCategory.allCases {
            XCTAssertNotNil(counts[category], "missing count for \(category)")
        }
        XCTAssertEqual(counts[.work], 1)
        XCTAssertEqual(counts[.health], 0)
        XCTAssertEqual(counts[.all], 1)
    }
}
