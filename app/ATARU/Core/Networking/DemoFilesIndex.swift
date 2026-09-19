import Foundation
import UIKit

/// The files index, in process.
///
/// Sixty rows across every umbrella in `~/Projects`, with search, filtering,
/// facets, paging and a deterministic narrowing - so the whole Files
/// experience, including the conversational part, is reachable and testable on
/// a machine that has never seen the server.
///
/// NAMES ONLY. Every row here is a plausible filename and nothing else: there
/// are no account numbers, no lab values and no real correspondence anywhere
/// in this file. The bodies the viewer renders are generated on the spot and
/// say so. See PRIVACY.md.
enum DemoFilesIndex {

    // MARK: - The rows

    private struct Row {
        let name: String
        let umbrella: String
        let project: String?
        let pod: String?
        let kind: FileKind
        let daysAgo: Double
        let kilobytes: Int64
        let away: Bool

        init(_ name: String, _ umbrella: String, _ project: String?,
             pod: String? = nil, _ kind: FileKind, _ daysAgo: Double,
             _ kilobytes: Int64, away: Bool = false) {
            self.name = name
            self.umbrella = umbrella
            self.project = project
            self.pod = pod
            self.kind = kind
            self.daysAgo = daysAgo
            self.kilobytes = kilobytes
            self.away = away
        }
    }

    private static let rows: [Row] = [
        // Robolabs
        Row("Robolabs tournament 2025 run sheet.xlsx", "Robolabs", "Tournaments", .sheet, 34, 96),
        Row("Robolabs tournament 2024 run sheet.xlsx", "Robolabs", "Tournaments", .sheet, 402, 88, away: true),
        Row("VEX AI qualifier scoring rubric.pdf", "Robolabs", "Tournaments", .pdf, 61, 214),
        Row("Summer camp enrollment 2025.xlsx", "Robolabs", "Camps", .sheet, 120, 142),
        Row("Camp instructor handbook.docx", "Robolabs", "Camps", .doc, 210, 318),
        Row("Robolabs investor update Q2.pptx", "Robolabs", "Business", .slides, 88, 2_410),
        Row("Robolabs 2024 revenue summary.pdf", "Robolabs", "Business", .pdf, 268, 190),
        Row("Field setup diagram.png", "Robolabs", "Tournaments", .image, 47, 1_820),
        Row("Coach onboarding notes.md", "Robolabs", "Camps", .text, 12, 14),
        Row("Robolabs promo reel.mp4", "Robolabs", "Business", .video, 330, 486_000, away: true),

        // Career
        Row("Arya Sasikumar resume 2026.pdf", "Career", "Resumes", .pdf, 4, 168),
        Row("Robotics engineer resume variant.pdf", "Career", "Resumes", .pdf, 9, 164),
        Row("CV bank master.docx", "Career", "CV Bank", .doc, 22, 402),
        Row("Cover letter template.md", "Career", "Outreach", .text, 31, 9),
        Row("Outreach tracker.xlsx", "Career", "Outreach", .sheet, 6, 74),
        Row("Portfolio site screenshots.png", "Career", "Portfolio", .image, 58, 3_140),
        Row("Interview prep notes.md", "Career", "Interviews", .text, 17, 26),
        Row("Reference list.pdf", "Career", "Resumes", .pdf, 140, 82),

        // Graduate School
        Row("Berkeley Haas MBA admission letter.pdf", "Graduate School", "Admissions", .pdf, 2, 246),
        Row("Statement of purpose draft 4.docx", "Graduate School", "Applications", .doc, 26, 88),
        Row("LAMC transcript.pdf", "Graduate School", "Transcripts", .pdf, 190, 310),
        Row("Berkeley transcript.pdf", "Graduate School", "Transcripts", .pdf, 154, 288),
        Row("Program shortlist.xlsx", "Graduate School", "Applications", .sheet, 38, 61),
        Row("Recommendation request email draft.md", "Graduate School", "Applications", .text, 44, 7),
        Row("GRE score report.pdf", "Graduate School", "Applications", .pdf, 620, 122, away: true),

        // Research
        Row("Wind turbine warning gap draft.docx", "Research", "Wind turbine paper", .doc, 3, 540),
        Row("IEEE PES GM 2027 submission checklist.md", "Research", "Wind turbine paper", .text, 8, 11),
        Row("Outage dataset summary.xlsx", "Research", "Wind turbine paper", .sheet, 15, 1_340),
        Row("Construction injury rates by trade.xlsx", "Research", "Robot substitutability", .sheet, 72, 980),
        Row("Robot substitutability abstract.pdf", "Research", "Robot substitutability", .pdf, 69, 148),
        Row("Figure 3 turbine warning timeline.png", "Research", "Wind turbine paper", .image, 5, 740),

        // Book
        Row("Intro to VEX Robotics second edition outline.docx", "Book", "Seer", .doc, 11, 176),
        Row("Chapter 4 sensors draft.md", "Book", "Seer", .text, 7, 38),
        Row("Notebook scan batch 12.pdf", "Book", "Ingestion", .pdf, 19, 24_800),
        Row("Cover concept A.png", "Book", "Seer", .image, 40, 2_960),
        Row("Figure list.xlsx", "Book", "Seer", .sheet, 25, 44),

        // Robotics Startup
        Row("UMI-FT data collection protocol.docx", "Robotics Startup", "UMI-FT", .doc, 6, 224),
        Row("Renaissance Machines strategy deck.pptx", "Robotics Startup", "Strategy", .slides, 13, 5_620),
        Row("Gripper force sensor calibration.xlsx", "Robotics Startup", "UMI-FT", .sheet, 10, 168),
        Row("Teleop session 041 recording.mp4", "Robotics Startup", "UMI-FT", .video, 9, 1_240_000, away: true),
        Row("Market landscape notes.md", "Robotics Startup", "Strategy", .text, 21, 32),
        Row("Beachhead options one pager.pdf", "Robotics Startup", "Strategy", .pdf, 28, 132),
        Row("Rig assembly photos.png", "Robotics Startup", "UMI-FT", .image, 16, 4_480),

        // Quantum
        Row("Optics alignment agent architecture.md", "Quantum", "Alignment agent", .text, 14, 29),
        Row("Beam profile capture 2026-08.png", "Quantum", "Alignment agent", .image, 41, 1_980),
        Row("Lab automation milestones.xlsx", "Quantum", "Alignment agent", .sheet, 52, 58),
        Row("Sujay collaboration notes.md", "Quantum", nil, .text, 36, 18),
        Row("Cavity lock measurement log.csv", "Quantum", "Alignment agent", .sheet, 23, 420),

        // ATARU (the vault's own pods show up here)
        Row("Vault backup policy.md", "ATARU", "vault", pod: "work", .text, 33, 9),
        Row("Amex statement 2026-08.pdf", "ATARU", "vault", pod: "finances", .pdf, 30, 264),
        Row("Capital One statement 2026-08.pdf", "ATARU", "vault", pod: "finances", .pdf, 27, 188),
        Row("Routine lab panel 2026-07.pdf", "ATARU", "vault", pod: "health", .pdf, 62, 204),
        Row("Follow-ups snapshot.md", "ATARU", "vault", pod: "communications", .text, 1, 6),
        Row("openGym deployment notes.md", "ATARU", "vault", pod: "work", .text, 2, 21),
        Row("Kiosk dashboard mockup.png", "ATARU", "build", pod: "work", .image, 74, 2_140),

        // Experiments
        Row("Isaac Sim scene notes.md", "Experiments", "Isaac Sim", .text, 18, 15),
        Row("Isaac Sim warehouse capture.mp4", "Experiments", "Isaac Sim", .video, 20, 318_000),
        Row("Reinforcement baseline results.xlsx", "Experiments", "RL", .sheet, 57, 96),
        Row("Diffusion policy paper annotated.pdf", "Experiments", "RL", .pdf, 96, 3_120),
        Row("Scratch audio memo.m4a", "Experiments", nil, .audio, 65, 1_460)
    ]

    /// The fixture, built once. Dates are relative to first use, so the rows
    /// never age into "two years ago" while the simulator sits open.
    static let hits: [FileHit] = {
        let now = Date()
        return rows.enumerated().map { index, row in
            let folder = [row.umbrella, row.project].compactMap { $0 }.joined(separator: "/")
            return FileHit(
                id: String(format: "file-%03d", index + 1),
                path: "Projects/\(folder)/\(row.name)",
                name: row.name,
                title: (row.name as NSString).deletingPathExtension,
                ext: (row.name as NSString).pathExtension.lowercased(),
                kind: row.kind,
                pod: row.pod,
                umbrella: row.umbrella,
                project: row.project,
                mtime: now.addingTimeInterval(-row.daysAgo * 86_400),
                size: row.kilobytes * 1_024,
                location: row.away ? .nasAway : .local,
                snippet: nil,
                score: nil,
                // An away file's text was extracted before it was tiered out,
                // which is exactly why it is still findable by name.
                hasText: row.kind != .image && row.kind != .video && row.kind != .audio
            )
        }
    }()

    // MARK: - Search

    static func search(_ request: FileSearchRequest) -> FileSearchResult {
        let matched = matches(request)
        let facets = facets(for: matched)
        let ordered = sort(matched, by: request.sort, searching: request.isSearching)
        let size = max(1, request.pageSize)
        let start = max(0, (max(1, request.page) - 1) * size)
        let page = start >= ordered.count
            ? []
            : Array(ordered[start..<min(start + size, ordered.count)])
        return FileSearchResult(total: ordered.count, page: max(1, request.page),
                                pageSize: size, hits: page, facets: facets)
    }

    /// Filtering and scoring, pure. Shared with the tests.
    static func matches(_ request: FileSearchRequest) -> [FileHit] {
        let filters = request.filters
        let needle = (request.q ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return hits.compactMap { hit in
            if !filters.umbrellas.isEmpty,
               !filters.umbrellas.contains(where: { $0.caseInsensitiveCompare(hit.umbrella ?? "") == .orderedSame }) {
                return nil
            }
            if !filters.pods.isEmpty,
               !filters.pods.contains(where: { $0.caseInsensitiveCompare(hit.pod ?? "") == .orderedSame }) {
                return nil
            }
            if !filters.projects.isEmpty,
               !filters.projects.contains(where: { $0.caseInsensitiveCompare(hit.project ?? "") == .orderedSame }) {
                return nil
            }
            if !filters.kinds.isEmpty, !filters.kinds.contains(hit.kind) { return nil }
            if !filters.exts.isEmpty, !filters.exts.contains(hit.ext) { return nil }
            if let location = filters.location, hit.location != location { return nil }
            if let since = filters.since, let bound = ISO8601Time.parse(since),
               let mtime = hit.mtime, mtime < bound { return nil }
            if let until = filters.until, let bound = ISO8601Time.parse(until),
               let mtime = hit.mtime,
               // `until` is a day, and a day includes itself.
               mtime > bound.addingTimeInterval(86_399) { return nil }

            guard !needle.isEmpty else { return hit }
            let haystack = "\(hit.name) \(hit.path) \(hit.project ?? "") \(hit.umbrella ?? "")"
                .lowercased()
            // Every word has to land somewhere, so "robolabs 2025" does not
            // match every Robolabs file ever written.
            let words = needle.split(separator: " ").map(String.init)
            guard words.allSatisfy({ haystack.contains($0) }) else { return nil }
            let inName = words.filter { hit.name.lowercased().contains($0) }.count
            let score = Double(inName) / Double(max(1, words.count))
            return FileHit(id: hit.id, path: hit.path, name: hit.name, title: hit.title,
                           ext: hit.ext, kind: hit.kind, pod: hit.pod,
                           umbrella: hit.umbrella, project: hit.project,
                           mtime: hit.mtime, size: hit.size, location: hit.location,
                           snippet: snippet(for: hit, needle: needle),
                           score: score, hasText: hit.hasText)
        }
    }

    private static func snippet(for hit: FileHit, needle: String) -> String {
        "Matched on the file name and its folder in \(hit.umbrella ?? "Projects"). "
            + "Demo rows carry no extracted text."
    }

    static func facets(for hits: [FileHit]) -> FileFacets {
        var pod: [String: Int] = [:]
        var umbrella: [String: Int] = [:]
        var kind: [String: Int] = [:]
        var year: [String: Int] = [:]
        let calendar = Calendar(identifier: .gregorian)
        for hit in hits {
            if let value = hit.pod, !value.isEmpty { pod[value, default: 0] += 1 }
            if let value = hit.umbrella, !value.isEmpty { umbrella[value, default: 0] += 1 }
            kind[hit.kind.rawValue, default: 0] += 1
            if let mtime = hit.mtime {
                year[String(calendar.component(.year, from: mtime)), default: 0] += 1
            }
        }
        return FileFacets(pod: pod, umbrella: umbrella, kind: kind, year: year)
    }

    static func sort(_ hits: [FileHit], by order: FileSort, searching: Bool) -> [FileHit] {
        switch order {
        case .relevance:
            guard searching else { return sort(hits, by: .mtimeDesc, searching: false) }
            return hits.sorted {
                let left = $0.score ?? 0, right = $1.score ?? 0
                if left != right { return left > right }
                return ($0.mtime ?? .distantPast) > ($1.mtime ?? .distantPast)
            }
        case .mtimeDesc:
            return hits.sorted { ($0.mtime ?? .distantPast) > ($1.mtime ?? .distantPast) }
        case .mtimeAsc:
            return hits.sorted { ($0.mtime ?? .distantFuture) < ($1.mtime ?? .distantFuture) }
        case .name:
            return hits.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .sizeDesc:
            return hits.sorted { ($0.size ?? 0) > ($1.size ?? 0) }
        }
    }

    // MARK: - Detail and bytes

    static func hit(id: String) -> FileHit? { hits.first { $0.id == id } }

    static func detail(id: String) throws -> FileDetail {
        guard let hit = hit(id: id) else { throw APIError.notFound }
        // An away file has no bytes on this host, so it has no viewer. That
        // is the whole point of the badge.
        guard !hit.location.isAway else {
            return FileDetail(file: hit, textChars: nil, extractedAt: nil,
                              previewable: false, viewer: .none)
        }
        let viewer: FileViewerKind
        switch hit.kind {
        case .pdf: viewer = .pdf
        case .image: viewer = .image
        case .video, .audio: viewer = .none
        // Demo has no originals, only generated text - so it reports the
        // viewer it can actually honour rather than promising QuickLook an
        // .xlsx that does not exist.
        default: viewer = .text
        }
        return FileDetail(file: hit, textChars: hit.hasText ? 4_200 : nil,
                          extractedAt: hit.mtime,
                          previewable: viewer != .none, viewer: viewer)
    }

    /// Bytes for the viewer, generated here. Named for what they are.
    static func content(id: String) throws -> (data: Data, name: String) {
        guard let hit = hit(id: id) else { throw APIError.notFound }
        guard !hit.location.isAway else { throw APIError.notFound }
        let stem = (hit.name as NSString).deletingPathExtension
        switch hit.kind {
        case .pdf:
            return (pdf(for: hit), "\(stem).pdf")
        case .image:
            return (image(for: hit), "\(stem).png")
        default:
            return (Data(body(for: hit).utf8), "\(stem).txt")
        }
    }

    static func body(for hit: FileHit) -> String {
        """
        \(hit.title)

        \(hit.path)

        This is Demo mode. The file browser is showing a synthetic index of
        sixty rows so every state of the Files screen - browsing, searching,
        narrowing, paging, the NAS badge, the viewer - can be reached without
        a server. Nothing here came from a real project folder.

        Kind: \(hit.kind.rowTitle)
        Where: \(hit.placeLine)
        Connect your ATARU server in Settings to browse your own files.
        """
    }

    private static func pdf(for hit: FileHit) -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        return renderer.pdfData { context in
            context.beginPage()
            let title = NSAttributedString(
                string: hit.title,
                attributes: [.font: UIFont.boldSystemFont(ofSize: 22),
                             .foregroundColor: UIColor.black])
            title.draw(in: CGRect(x: 56, y: 72, width: 500, height: 80))
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 5
            let body = NSAttributedString(
                string: body(for: hit),
                attributes: [.font: UIFont.systemFont(ofSize: 12),
                             .foregroundColor: UIColor.darkGray,
                             .paragraphStyle: paragraph])
            body.draw(in: CGRect(x: 56, y: 160, width: 500, height: 560))
        }
    }

    private static func image(for hit: FileHit) -> Data {
        let size = CGSize(width: 900, height: 600)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor(red: 0.05, green: 0.08, blue: 0.11, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor(red: 0.16, green: 0.78, blue: 0.85, alpha: 1).setStroke()
            let path = UIBezierPath(roundedRect: CGRect(x: 60, y: 60,
                                                        width: size.width - 120,
                                                        height: size.height - 120),
                                    cornerRadius: 18)
            path.lineWidth = 3
            path.stroke()
            NSAttributedString(
                string: hit.title,
                attributes: [.font: UIFont.boldSystemFont(ofSize: 30),
                             .foregroundColor: UIColor.white]
            ).draw(in: CGRect(x: 100, y: 240, width: size.width - 200, height: 120))
        }
        return image.pngData() ?? Data()
    }

    // MARK: - Narrowing, deterministically

    /// The same job the server's model does, done by table lookup.
    ///
    /// Words that name a KIND, a YEAR, an UMBRELLA or a location become
    /// filters; whatever is left over becomes the query. Nothing here guesses:
    /// a sentence with no recognised term narrows nothing and says so, which
    /// is the honest demo behaviour and is exactly what the tests pin.
    static func narrow(q: String, filters: FileFilters,
                       history: [FileNarrowStep]) -> FilesNarrowing {
        var applied = filters
        var added: [String] = []
        let lowered = q.lowercased()

        // Multi-word umbrellas first, and against the whole sentence, because
        // "graduate school" is two tokens and neither of them alone is one.
        for name in FileFacets.umbrellaOrder
        where lowered.contains(name.lowercased()) && !applied.umbrellas.contains(name) {
            applied.umbrellas.append(name)
            added.append(name)
        }

        var residue: [String] = []
        for rawToken in lowered.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let token = String(rawToken)
            if consumedByUmbrella(token, applied.umbrellas) { continue }
            if let kind = kindWords[token] {
                if !applied.kinds.contains(kind) {
                    applied.kinds.append(kind)
                    added.append(kind.title)
                }
                continue
            }
            if token.count == 4, let year = Int(token), (1990...2100).contains(year) {
                applied.setYear(year)
                added.append(String(year))
                continue
            }
            if token == "nas" || token == "away" || token == "archived" {
                applied.location = .nasAway
                added.append("on the NAS")
                continue
            }
            if token == "local" {
                applied.location = .local
                added.append("on this host")
                continue
            }
            if stopWords.contains(token) { continue }
            residue.append(token)
        }

        // Nothing left to search by means the standing query stands. The
        // request carries only the new utterance, so the previous one is read
        // back off the history - which is what the history is for.
        let query = residue.isEmpty ? (history.last?.q ?? "") : residue.joined(separator: " ")
        let request = FileSearchRequest(q: query.isEmpty ? nil : query,
                                        filters: applied,
                                        sort: query.isEmpty ? .mtimeDesc : .relevance,
                                        page: 1, pageSize: 30)
        let result = search(request)
        return FilesNarrowing(query: query, filters: applied,
                              explanation: explain(added: added, query: query,
                                                   total: result.total),
                              result: result)
    }

    private static func consumedByUmbrella(_ token: String, _ umbrellas: [String]) -> Bool {
        umbrellas.contains { name in
            name.lowercased().split(separator: " ").contains { $0 == token }
        }
    }

    private static func explain(added: [String], query: String, total: Int) -> String {
        let count = total == 1 ? "1 file" : "\(total) files"
        if added.isEmpty && query.isEmpty {
            return "Nothing in that to narrow by, so the list is unchanged. \(count)."
        }
        var parts: [String] = []
        if !added.isEmpty { parts.append("Narrowed to \(list(added))") }
        if !query.isEmpty { parts.append("searching for \u{201C}\(query)\u{201D}") }
        return parts.joined(separator: ", ") + ". \(count)."
    }

    private static func list(_ values: [String]) -> String {
        switch values.count {
        case 0: return ""
        case 1: return values[0]
        case 2: return "\(values[0]) and \(values[1])"
        default:
            return values.dropLast().joined(separator: ", ") + " and " + values[values.count - 1]
        }
    }

    // MARK: - Answering a spoken turn

    /// Turns a question about files into the payload a live server would send.
    ///
    /// Two shapes, and the choice between them is the same one the router
    /// makes: a request that resolves to exactly ONE file opens the viewer, and
    /// anything broader opens the browser. Nil means this is not a question
    /// about files at all, and the ordinary demo answer stands.
    static func fileIntent(for question: String) -> SpokenAnswer? {
        let lowered = question.lowercased()
        guard intentVerbs.contains(where: { lowered.contains($0) }) else { return nil }
        let narrowing = narrow(q: question, filters: .none, history: [])
        let result = narrowing.result
        guard result.total > 0 else {
            return SpokenAnswer(text: "I couldn't find any files matching that.",
                                source: nil, audioURL: nil)
        }
        // One hit, and he asked to open something: that is a viewer request.
        if result.total == 1, let hit = result.hits.first,
           openVerbs.contains(where: { lowered.contains($0) }) {
            return SpokenAnswer(
                text: "Opening \(hit.title).", source: hit.path, audioURL: nil,
                document: DocumentRef(id: hit.id, title: hit.title,
                                      fileType: hit.ext,
                                      previewable: !hit.location.isAway,
                                      source: .files))
        }
        let count = result.total == 1 ? "1 file" : "\(result.total) files"
        return SpokenAnswer(
            text: "\(count). They're in Files.", source: nil, audioURL: nil,
            files: FilesPayload(query: narrowing.query, filters: narrowing.filters,
                                total: result.total))
    }

    private static let intentVerbs = ["file", "files", "narrow", "show me",
                                      "pull up", "find", "open", "browse",
                                      "spreadsheet", "deck", "pdf"]

    private static let openVerbs = ["pull up", "open", "show me"]

    private static let kindWords: [String: FileKind] = [
        "pdf": .pdf, "pdfs": .pdf,
        "doc": .doc, "docs": .doc, "document": .doc, "documents": .doc, "word": .doc,
        "docx": .doc,
        "slide": .slides, "slides": .slides, "deck": .slides, "decks": .slides,
        "presentation": .slides, "presentations": .slides, "pptx": .slides,
        "sheet": .sheet, "sheets": .sheet, "spreadsheet": .sheet,
        "spreadsheets": .sheet, "excel": .sheet, "xlsx": .sheet, "csv": .sheet,
        "note": .text, "notes": .text, "markdown": .text, "md": .text, "text": .text,
        "image": .image, "images": .image, "photo": .image, "photos": .image,
        "picture": .image, "pictures": .image, "png": .image, "jpg": .image,
        "video": .video, "videos": .video, "clip": .video, "clips": .video,
        "audio": .audio, "recording": .audio, "recordings": .audio
    ]

    /// Words that are grammar rather than subject.
    ///
    /// The interrogatives are here for the same reason the articles are:
    /// "what's on the NAS" leaves "what" behind otherwise, and a residue
    /// becomes the SEARCH QUERY - so the one word that carried no information
    /// would have been the thing every result had to match.
    private static let stopWords: Set<String> = [
        "show", "me", "just", "only", "the", "my", "from", "in", "for", "and",
        "narrow", "to", "filter", "file", "files", "find", "search", "all",
        "of", "on", "please", "that", "those", "these", "it", "a", "an",
        "with", "any", "down", "up", "s",
        "what", "whats", "which", "where", "who", "how", "many", "much",
        "is", "are", "was", "were", "be", "there", "here", "do", "does",
        "i", "we", "you", "your", "am", "have", "got", "give", "list",
        // Placeholders for the noun the sentence never says: "just the 2025
        // ones" means the same as "just 2025", and letting "ones" through
        // makes it a search term every result would have to match.
        "one", "ones", "thing", "things", "stuff", "some"
    ]
}
