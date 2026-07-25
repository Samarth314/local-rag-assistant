"""Tests for the document-library read side.

Everything here runs against an in-memory state dict, so none of it needs
LanceDB, a model, or a filesystem -- the same property the rest of the offline
suite has.
"""

import unittest

import documents


def state(**entries) -> dict:
    """index_state.json in the shape the indexer writes it."""
    return dict(entries)


class TestDocumentIdentity(unittest.TestCase):
    def test_id_is_stable_and_path_specific(self):
        self.assertEqual(documents.doc_id("/docs/a.pdf"), documents.doc_id("/docs/a.pdf"))
        self.assertNotEqual(documents.doc_id("/docs/a.pdf"), documents.doc_id("/docs/b.pdf"))

    def test_id_does_not_leak_the_path(self):
        # Ids end up in URLs and therefore in access logs; directory names in a
        # personal vault are themselves sensitive.
        opaque = documents.doc_id("/docs/health/hiv-results.pdf")
        self.assertNotIn("health", opaque)
        self.assertNotIn("hiv", opaque)

    def test_unknown_id_does_not_resolve(self):
        rows = state(**{"/docs/a.pdf": {"fp": "10-1700000000.0"}})
        self.assertIsNone(documents.find("deadbeefdeadbeef", rows))
        # The property that matters: a path is not a usable handle.
        self.assertIsNone(documents.find("/etc/passwd", rows))


class TestCategorisation(unittest.TestCase):
    def test_directory_names_drive_the_category(self):
        self.assertEqual(documents.categorize("/docs/finances/2025/taxes.pdf"), "finances")
        self.assertEqual(documents.categorize("/docs/health/labs/panel.pdf"), "health")
        self.assertEqual(documents.categorize("/docs/work/projects/spec.md"), "work")
        self.assertEqual(documents.categorize("/docs/communications/thread.md"), "communications")

    def test_filename_never_overrides_the_directory(self):
        # A receipt filed under finances stays in finances even though its name
        # says "health insurance" -- otherwise one word in a title relocates it.
        self.assertEqual(
            documents.categorize("/docs/finances/health insurance receipt.pdf"),
            "finances",
        )

    def test_unrecognised_paths_get_a_default_not_an_error(self):
        self.assertEqual(documents.categorize("/docs/misc/thing.txt"),
                         documents.DEFAULT_CATEGORY)
        self.assertIn(documents.DEFAULT_CATEGORY, documents.CATEGORIES)


class TestFingerprintParsing(unittest.TestCase):
    def test_parses_size_and_mtime(self):
        self.assertEqual(documents.parse_fingerprint("2048-1700000000.0"),
                         (2048, 1700000000.0))

    def test_tolerates_legacy_and_malformed_entries(self):
        # A library listing must not blow up on one odd row written by an
        # older build.
        for bad in (None, "", "nonsense", 42, "abc-def"):
            self.assertEqual(documents.parse_fingerprint(bad), (None, None))


class TestListing(unittest.TestCase):
    def setUp(self):
        self.rows = state(**{
            "/docs/work/spec.md": {"fp": "100-300.0", "indexed_at": 900.0},
            "/docs/health/panel.pdf": {"fp": "200-100.0", "indexed_at": 901.0},
            "/docs/finances/tax.pdf": {"fp": "300-200.0"},
        })

    def test_newest_first(self):
        titles = [d.title for d in documents.list_documents(self.rows)]
        self.assertEqual(titles, ["spec.md", "tax.pdf", "panel.pdf"])

    def test_duplicates_are_omitted(self):
        rows = dict(self.rows)
        rows["/docs/copy/spec.md"] = {"fp": "100-300.0", "dup_of": "/docs/work/spec.md"}
        paths = [d.path for d in documents.list_documents(rows)]
        self.assertNotIn("/docs/copy/spec.md", paths)
        self.assertEqual(len(paths), 3)

    def test_missing_mtime_sorts_last_rather_than_raising(self):
        rows = dict(self.rows)
        rows["/docs/work/broken.md"] = {"fp": "garbage"}
        docs = documents.list_documents(rows)
        self.assertEqual(docs[-1].title, "broken.md")

    def test_metadata_is_carried_through(self):
        doc = documents.find(documents.doc_id("/docs/health/panel.pdf"), self.rows)
        self.assertEqual(doc.category, "health")
        self.assertEqual(doc.file_type, "pdf")
        self.assertEqual(doc.size_bytes, 200)
        self.assertEqual(doc.indexed_at, 901.0)

    def test_indexed_at_absent_on_older_entries(self):
        doc = documents.find(documents.doc_id("/docs/finances/tax.pdf"), self.rows)
        self.assertIsNone(doc.indexed_at)


class TestFiltering(unittest.TestCase):
    def setUp(self):
        self.docs = documents.list_documents(state(**{
            "/docs/work/spec.md": {"fp": "100-300.0"},
            "/docs/health/panel.pdf": {"fp": "200-100.0"},
            "/docs/finances/tax return.pdf": {"fp": "300-200.0"},
        }))

    def test_query_matches_title_case_insensitively(self):
        found = documents.filter_documents(self.docs, query="TAX")
        self.assertEqual([d.title for d in found], ["tax return.pdf"])

    def test_query_matches_path(self):
        found = documents.filter_documents(self.docs, query="health")
        self.assertEqual([d.title for d in found], ["panel.pdf"])

    def test_category_filter(self):
        found = documents.filter_documents(self.docs, category="finances")
        self.assertEqual(len(found), 1)

    def test_all_category_is_not_a_filter(self):
        self.assertEqual(len(documents.filter_documents(self.docs, category="all")),
                         len(self.docs))

    def test_query_and_category_are_combined(self):
        self.assertEqual(documents.filter_documents(self.docs, query="tax",
                                                    category="health"), [])

    def test_counts_include_empty_categories(self):
        counts = documents.category_counts(self.docs)
        for name in documents.CATEGORIES:
            self.assertIn(name, counts)
        self.assertEqual(counts["work"], 1)
        self.assertEqual(counts["communications"], 0)


class TestExcerpt(unittest.TestCase):
    def test_collapses_whitespace_onto_one_line(self):
        self.assertEqual(documents.excerpt_of("a\n\n  b\tc"), "a b c")

    def test_truncates_on_a_word_boundary(self):
        text = " ".join(["word"] * 200)
        out = documents.excerpt_of(text, limit=20)
        self.assertLessEqual(len(out), 21)      # + the ellipsis
        self.assertTrue(out.endswith("…"))
        self.assertNotIn("wor…", out)           # never mid-word

    def test_short_text_is_returned_whole_and_unmarked(self):
        self.assertEqual(documents.excerpt_of("short"), "short")


class TestContentTypes(unittest.TestCase):
    def test_known_types(self):
        self.assertEqual(documents.content_type_for("pdf"), "application/pdf")
        self.assertTrue(documents.content_type_for("md").startswith("text/markdown"))

    def test_case_insensitive(self):
        self.assertEqual(documents.content_type_for("PDF"), "application/pdf")

    def test_unknown_falls_back_to_octet_stream(self):
        self.assertEqual(documents.content_type_for("xyz"), "application/octet-stream")

    def test_previewable_reflects_what_ios_can_actually_show(self):
        self.assertTrue(documents.is_previewable("pdf"))
        self.assertTrue(documents.is_previewable("MOV"))
        self.assertFalse(documents.is_previewable("xlsx"))


if __name__ == "__main__":
    unittest.main()
