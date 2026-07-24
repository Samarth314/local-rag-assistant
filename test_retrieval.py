"""Offline tests for the portable retrieval module (Item 3). Pure functions
over candidate dicts -- no vector DB. The headline is the recall test: on a
breadth query, whole-collection selection recovers every document where naive
top-k recovers only one. Run: `python -m unittest`."""

import unittest

from retrieval import (build_expansion_prompt, dedupe_by_text, is_breadth_query,
                       rrf_fuse, select_top_k, select_whole_collection,
                       supports_escalation)


def _row(path, chunk, dist=None, text=None):
    return {"path": path, "chunk_index": chunk, "_distance": dist,
            "text": text if text is not None else f"{path}#{chunk}"}


class TestFusion(unittest.TestCase):
    def test_rrf_rewards_agreement_across_signals(self):
        # doc found by BOTH rankings should beat one found by only one.
        vec = [_row("A", 0), _row("B", 0)]
        bm25 = [_row("B", 0), _row("C", 0)]
        fused = rrf_fuse([vec, bm25])
        self.assertEqual((fused[0]["path"], fused[0]["chunk_index"]), ("B", 0))

    def test_rrf_is_deterministic(self):
        lists = [[_row("A", 0), _row("B", 0)], [_row("B", 1), _row("A", 0)]]
        self.assertEqual([r["path"] for r in rrf_fuse(lists)],
                         [r["path"] for r in rrf_fuse(lists)])

    def test_dedupe_drops_identical_text(self):
        rows = [_row("A", 0, text="same body"), _row("B", 0, text="same body"),
                _row("C", 0, text="different")]
        out = dedupe_by_text(rows)
        self.assertEqual(len(out), 2)


class TestRecall(unittest.TestCase):
    """The top-k breadth gap and its fix, measured as document recall."""

    def setUp(self):
        # 6 fused chunks: 4 from A, 1 from B, 1 from C (the clustering that
        # made "summarize every document" silently drop B and C).
        self.rows = [_row("A", 0, .10), _row("A", 1, .15), _row("A", 2, .20),
                     _row("A", 3, .25), _row("B", 0, .30), _row("C", 0, .35)]
        self.all_docs = {"A", "B", "C"}

    def test_naive_topk_misses_documents(self):
        docs = {r["path"] for r in select_top_k(self.rows, 4)}
        self.assertEqual(docs, {"A"})                 # recall 1/3 -- the bug

    def test_whole_collection_recovers_every_document(self):
        docs = {r["path"] for r in select_whole_collection(self.rows)}
        self.assertEqual(docs, self.all_docs)         # recall 3/3 -- the fix

    def test_whole_collection_recall_beats_topk(self):
        k = 4
        topk_recall = len({r["path"] for r in select_top_k(self.rows, k)})
        whole_recall = len({r["path"] for r in select_whole_collection(self.rows)})
        self.assertGreater(whole_recall, topk_recall)

    def test_whole_collection_keeps_best_chunk_per_doc(self):
        # per_doc=1 keeps the highest-fused (first-seen) chunk of each document.
        out = select_whole_collection(self.rows)
        a = [r for r in out if r["path"] == "A"]
        self.assertEqual(len(a), 1)
        self.assertEqual(a[0]["chunk_index"], 0)      # A's best-ranked chunk


class TestBreadthDetection(unittest.TestCase):
    def test_breadth_queries_detected(self):
        for q in [
            "summarize every document in the collection",
            "summarize all the documents in one line each",
            "summarize all three documents in one paragraph each",
            "give me a rundown of every file",
            "list every ingredient across both recipes",
        ]:
            self.assertTrue(is_breadth_query(q), msg=q)

    def test_targeted_queries_not_flagged_breadth(self):
        for q in [
            "who founded robolabs",
            "walk me through the rasam recipe",
            "compare the full and reduced vex tracks",
            "what nvme drive does the orin use",
        ]:
            self.assertFalse(is_breadth_query(q), msg=q)


class TestEscalationAndExpansion(unittest.TestCase):
    def test_supports_escalation_thresholds(self):
        self.assertTrue(supports_escalation([_row("A", 0, .3)]))
        self.assertFalse(supports_escalation([_row("A", 0, .5)]))
        self.assertFalse(supports_escalation([]))

    def test_expansion_prompt_includes_question(self):
        self.assertIn("PHIL338", build_expansion_prompt("philosophy classes"))
        self.assertIn("philosophy classes", build_expansion_prompt("philosophy classes"))


if __name__ == "__main__":
    unittest.main()
