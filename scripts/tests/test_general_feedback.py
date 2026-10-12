import json
import shutil
import subprocess
import unittest
from pathlib import Path
from urllib.parse import parse_qs, urlparse


ROOT = Path(__file__).resolve().parents[2]
NODE = shutil.which("node")


@unittest.skipUnless(NODE, "Node.js is required to test the General Questions & Feedback helpers.")
class GeneralFeedbackTests(unittest.TestCase):
    def run_helper(self, values):
        script = (
            'const feedback=require("./community/general-feedback.js");'
            f'const values={json.dumps(values, ensure_ascii=False)};'
            'console.log(JSON.stringify({valid:feedback.validateMessage(values),body:feedback.formatMessage(values),mailto:feedback.buildMailto(values)}));'
        )
        result = subprocess.run([NODE, "-e", script], cwd=ROOT, capture_output=True, text=True, check=True)
        return json.loads(result.stdout)

    def test_required_type_subject_message_and_optional_email_validation(self):
        base = {"name": "", "email": "", "messageType": "General Question", "subject": "Subject", "message": "Message"}
        for key in ("messageType", "subject", "message"):
            missing = dict(base)
            missing[key] = "  " if key != "messageType" else ""
            self.assertFalse(self.run_helper(missing)["valid"], key)
        self.assertTrue(self.run_helper(base)["valid"])
        invalid_email = dict(base, email="not-an-email")
        self.assertFalse(self.run_helper(invalid_email)["valid"])

    def test_all_required_message_categories_are_supported(self):
        self.assertEqual(
            self.run_helper({"name": "", "email": "", "messageType": "General Question", "subject": "s", "message": "m"})["valid"],
            True,
        )
        script = 'console.log(JSON.stringify(require("./community/general-feedback.js").messageTypes))'
        result = subprocess.run([NODE, "-e", script], cwd=ROOT, capture_output=True, text=True, check=True)
        self.assertEqual(json.loads(result.stdout), ["General Question", "Podcast Feedback", "Website Feedback", "Suggestion", "Other"])

    def test_mailto_encodes_subject_body_punctuation_and_line_breaks(self):
        result = self.run_helper({
            "name": "Jon?",
            "email": "jon@example.com",
            "messageType": "Podcast Feedback",
            "subject": "Audio & pacing?",
            "message": "Great episode!\nOne thought: use more examples (maybe).",
        })
        parsed = parse_qs(urlparse(result["mailto"]).query)
        self.assertEqual(parsed["subject"], ["Holotable Chaos — General Questions & Feedback"])
        self.assertEqual(urlparse(result["mailto"]).path, "holotablechaos@gmail.com")
        self.assertIn("Name or in-game name: Jon?", parsed["body"][0])
        self.assertIn("Email address: jon@example.com", parsed["body"][0])
        self.assertIn("Message type: Podcast Feedback", parsed["body"][0])
        self.assertIn("Subject: Audio & pacing?", parsed["body"][0])
        self.assertIn("Great episode!\nOne thought: use more examples (maybe).", parsed["body"][0])

    def test_fallback_instructions_mobile_styles_navigation_and_existing_features(self):
        page = (ROOT / "community" / "index.html").read_text(encoding="utf-8")
        home = (ROOT / "index.html").read_text(encoding="utf-8")
        styles = (ROOT / "styles.css").read_text(encoding="utf-8")
        self.assertIn("If your email app didn’t open", page)
        self.assertIn("holotablechaos@gmail.com", page)
        self.assertIn("readonly", page)
        self.assertIn('id="general-questions-feedback"', page)
        self.assertIn('href="community/index.html#general-questions-feedback"', home)
        self.assertIn('href="question-of-the-week.html"', page)
        self.assertIn('href="chaos-of-the-week.html"', page)
        self.assertIn('href="../roster-review/index.html"', page)
        self.assertIn("@media(max-width:760px)", styles)
        self.assertIn(".community-feedback-section", styles)
        self.assertIn(".form-field select", styles)
        self.assertIn("position:absolute;top:24px;right:24px", styles)
        self.assertIn("<span class=\"community-signal\" aria-hidden=\"true\">01</span>", page)
        self.assertTrue((ROOT / "community" / "chaos-of-the-week.html").is_file())
        self.assertTrue((ROOT / "community" / "question-of-the-week.html").is_file())
        self.assertTrue((ROOT / "roster-review" / "index.html").is_file())


if __name__ == "__main__":
    unittest.main()
