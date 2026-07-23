"""Offline tests for the privacy gate (Task B). Pure functions, no network.
Run: `python -m unittest`."""

import unittest

from privacy import (_luhn_ok, detect_pii, sanitize_for_cloud, scan_output,
                     summarize)


class TestCredentialRedaction(unittest.TestCase):
    def test_api_key_stripped(self):
        clean, counts = sanitize_for_cloud("key sk-ant-api03-ABCDEFGHIJKLMNOP here")
        self.assertNotIn("sk-ant", clean)
        self.assertIn("api_key", counts)

    def test_aws_and_github_stripped(self):
        clean, counts = sanitize_for_cloud(
            "AKIAIOSFODNN7EXAMPLE and ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ123456"
        )
        self.assertNotIn("AKIA", clean)
        self.assertNotIn("ghp_", clean)


class TestPIIDetection(unittest.TestCase):
    def test_email_detected_and_stripped(self):
        clean, counts = sanitize_for_cloud("reach me at jane.doe@example.com ok")
        self.assertNotIn("jane.doe@example.com", clean)
        self.assertEqual(counts.get("email"), 1)
        self.assertIn(" ok", clean)  # surrounding prose survives

    def test_phone_and_ssn_stripped(self):
        clean, _ = sanitize_for_cloud("call (415) 555-0132, ssn 123-45-6789")
        self.assertNotIn("555-0132", clean)
        self.assertNotIn("123-45-6789", clean)

    def test_valid_credit_card_stripped(self):
        clean, counts = sanitize_for_cloud("card 4111 1111 1111 1111 on file")
        self.assertNotIn("4111", clean)
        self.assertEqual(counts.get("credit_card"), 1)

    def test_luhn_filters_non_card_digit_run(self):
        # A 16-digit run that FAILS the Luhn checksum must not be flagged.
        self.assertTrue(_luhn_ok("4111111111111111"))   # real test card
        self.assertFalse(_luhn_ok("4111111111111112"))  # last digit broken
        labels = [lbl for lbl, _ in detect_pii("ref 4111111111111112 zz")]
        self.assertNotIn("credit_card", labels)

    def test_ipv4_stripped(self):
        clean, _ = sanitize_for_cloud("server at 192.168.1.42 responds")
        self.assertNotIn("192.168.1.42", clean)

    def test_plain_prose_untouched(self):
        text = "The dosa batter needs rice and dal, fermented overnight."
        clean, counts = sanitize_for_cloud(text)
        self.assertEqual(clean, text)
        self.assertEqual(counts, {})


class TestPluggableNER(unittest.TestCase):
    def test_ner_hook_contributes_findings(self):
        # The GLiNER/Presidio slot: an injected callable adds findings.
        def fake_ner(_text):
            return [("person", "Arya Sasikumar")]
        clean, counts = sanitize_for_cloud("meeting with Arya Sasikumar", ner=fake_ner)
        self.assertNotIn("Arya Sasikumar", clean)
        self.assertEqual(counts.get("person"), 1)

    def test_failing_ner_never_breaks_the_gate(self):
        def broken_ner(_text):
            raise RuntimeError("model unavailable")
        # Must still redact structured PII and not raise.
        clean, _ = sanitize_for_cloud("email x@y.com", ner=broken_ner)
        self.assertNotIn("x@y.com", clean)


class TestOutputScan(unittest.TestCase):
    def test_scan_output_catches_regurgitated_pii(self):
        clean, counts = scan_output("The answer includes bob@corp.com for contact.")
        self.assertNotIn("bob@corp.com", clean)
        self.assertTrue(counts)

    def test_summarize_formats_counts(self):
        self.assertEqual(summarize({"email": 2, "ssn": 1}), "2 email, 1 ssn")


if __name__ == "__main__":
    unittest.main()
