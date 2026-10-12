import json
import shutil
import subprocess
import unittest
from pathlib import Path
from urllib.parse import parse_qs, urlparse


ROOT = Path(__file__).resolve().parents[2]
NODE = shutil.which("node")


@unittest.skipUnless(NODE, "Node.js is required to exercise the Chaos of the Week form helpers.")
class ChaosOfTheWeekTests(unittest.TestCase):
    def run_helper(self, values):
        script = (
            'const chaos=require("./community/chaos-of-the-week.js");'
            f'const values={json.dumps(values, ensure_ascii=False)};'
            'console.log(JSON.stringify({valid:chaos.validateSubmission(values),body:chaos.formatSubmission(values),mailto:chaos.buildMailto(values)}));'
        )
        result = subprocess.run([NODE, "-e", script], cwd=ROOT, capture_output=True, text=True, check=True)
        return json.loads(result.stdout)

    def test_required_idea_rejects_empty_and_whitespace(self):
        self.assertFalse(self.run_helper({"inGameName": "", "idea": "", "details": ""})["valid"])
        self.assertFalse(self.run_helper({"inGameName": "", "idea": "  \n ", "details": ""})["valid"])
        self.assertTrue(self.run_helper({"inGameName": "", "idea": "A chaotic GAC defense", "details": ""})["valid"])

    def test_mailto_has_encoded_subject_and_labeled_fields(self):
        result = self.run_helper({"inGameName": "Jedi?", "idea": "Oops!—lost to a Jawa team", "details": "It was 3/3; all punctuation.\nRound two."})
        parsed = parse_qs(urlparse(result["mailto"]).query)
        self.assertEqual(parsed["subject"], ["Holotable Chaos — Chaos of the Week Submission"])
        self.assertIn("In-game name: Jedi?", parsed["body"][0])
        self.assertIn("Submission title or idea:\nOops!—lost to a Jawa team", parsed["body"][0])
        self.assertIn("Explanation / details:\nIt was 3/3; all punctuation.\nRound two.", parsed["body"][0])
        self.assertEqual(urlparse(result["mailto"]).path, "holotablechaos@gmail.com")

    def test_optional_fields_are_labeled_when_not_provided(self):
        body = self.run_helper({"inGameName": "", "idea": "Tiny chaos", "details": ""})["body"]
        self.assertIn("In-game name: Not provided", body)
        self.assertIn("Explanation / details:\nNot provided", body)

    def test_page_fallback_navigation_and_responsive_styles(self):
        page = (ROOT / "community" / "chaos-of-the-week.html").read_text(encoding="utf-8")
        community = (ROOT / "community" / "index.html").read_text(encoding="utf-8")
        home = (ROOT / "index.html").read_text(encoding="utf-8")
        styles = (ROOT / "styles.css").read_text(encoding="utf-8")
        self.assertIn("holotablechaos@gmail.com", page)
        self.assertIn("Holotable Chaos — Chaos of the Week Submission", page)
        self.assertIn("If your email app didn’t open", page)
        for href in ("../index.html", "../podcast/index.html", "../resources/index.html", "index.html", "../about/index.html"):
            self.assertIn(f'href="{href}"', page)
        self.assertEqual(page.count("discord.gg/4HNxXZBkbf"), 1)
        self.assertIn('href="chaos-of-the-week.html"', community)
        self.assertIn('href="community/chaos-of-the-week.html"', home)
        self.assertIn('id="chaos-of-the-week-form"', page)
        self.assertIn('name="idea"', page)
        self.assertIn("@media(max-width:760px)", styles)
        self.assertIn("chaos-form-layout", styles)
        self.assertNotIn("Coming Soon", community[community.index('id="chaos-of-the-week"'):])
        self.assertIn('href="question-of-the-week.html"', community)
        self.assertIn('href="../roster-review/index.html"', community)
        self.assertTrue((ROOT / "roster-review" / "index.html").is_file())
        self.assertTrue((ROOT / "community" / "question-of-the-week.html").is_file())


if __name__ == "__main__":
    unittest.main()
