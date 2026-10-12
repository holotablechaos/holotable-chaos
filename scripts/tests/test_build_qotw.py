import copy
import html
import json
import sys
import tempfile
import unittest
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build_qotw as builder


ROOT = Path(__file__).resolve().parents[2]


class QuestionOfTheWeekTests(unittest.TestCase):
    def setUp(self):
        self.payload = json.loads((ROOT / "content" / "qotw.json").read_text(encoding="utf-8"))

    def test_episode_18_is_the_open_question_with_complete_wording(self):
        questions, current = builder.validate_content(self.payload)
        page = builder.render_page(questions, current)
        self.assertIn("QotW #18", page)
        self.assertIn("OPEN", page)
        self.assertEqual(current["episode"], 18)
        self.assertEqual(current["episode_title"], "The Zeta Guide | Stop Wasting Your Zetas")
        self.assertIn("If you could get a refund on one zeta ability upgrade whose would it be?", page)
        self.assertIn("Submit Your Answer", page)
        self.assertIn("mailto:holotablechaos@gmail.com", page)
        href = html.unescape(__import__("re").search(r'href="(mailto:[^"]+)"', page).group(1))
        parsed = parse_qs(urlparse(href).query)
        self.assertEqual(parsed["subject"], ["Holotable Chaos QotW #18 Submission"])
        self.assertIn("Permanent question ID: QotW #18", parsed["body"][0])
        self.assertIn(current["text"], parsed["body"][0])

    def test_all_episode_questions_keep_exact_text_titles_ids_and_status(self):
        questions, current = builder.validate_content(self.payload)
        expected = [
            (3, "How I Would Have Started", "Who should the next GL be after GL Mando?"),
            (4, "Finding a Good Guild", "What is the most important guild event?"),
            (5, "Carson Teva First Impressions", "If you could relic an entire faction as a new player, which one would it be?"),
            (6, "Overrated/Underrated Teams + Hello People Joins the Show!", "If CG gave you a Relic 10 LST, who would you use it on? Zetas and Omicrons included. No Journey Guide, Galactic Legend, Territory Battle, or Conquest units allowed."),
            (7, "State of the Game: July 2026", "If you could unlock any Journey Guide character as a new player, who would it be? Seven stars, Gear 13, and Zetas; no Omicrons."),
            (8, "10 Characters Who NEED a Rework", "Which character needs a rework the most? It can be from our list or somebody else we didn't talk about. If you have an idea for how they should be reworked or a team they could fit on, share it."),
            (9, "Legends are Finally Here! | Breaking Down the Era of Myths and Legends", "Which Era of Myths and Legends character are you most excited for?"),
            (10, "Mara Jade is No Joke! | Breaking Down Her Kit & More", "Which character/team did you underestimate the most?"),
            (11, "Your First Galactic Legend: Which One Should You Choose?", "What was your first GL?"),
            (12, "Ships 101: Stop Ignoring Fleets", "What do you think the most important ship to farm is?"),
            (13, "Interview With theothersean!", "What is the most underrated investment in SWGoH?"),
            (14, "SWGoH This or That", "What is one piece of SWGoH advice you wish you had ignored?"),
            (15, "Embo & Keibu: Are They Built For Baylan Skoll?", "What are your thoughts on Embo & Keibu?"),
            (16, "The GAC Guide | How to Approach Grand Arena", "What is your Defensive MVP for Grand Arena? (Non-GL)"),
            (17, "Droid Destruction | What We Know So Far", "What do you think will be the best undersize team besides Rotta?"),
            (18, "The Zeta Guide | Stop Wasting Your Zetas", "If you could get a refund on one zeta ability upgrade whose would it be?"),
        ]
        actual = [(item["episode"], item["episode_title"], item["text"]) for item in questions]
        self.assertEqual(actual, expected)
        self.assertEqual([item["id"] for item in questions], [f"QotW #{n}" for n in range(3, 19)])
        self.assertEqual([item["status"] for item in questions], ["closed"] * 15 + ["current"])
        self.assertEqual(current["id"], "QotW #18")

    def test_episodes_one_and_two_are_explicitly_without_questions(self):
        page = builder.render_page(self.payload["questions"], next(item for item in self.payload["questions"] if item["status"] == "current"), episode_history=self.payload["episode_history"])
        self.assertIn("Episode 1 — Intro to Holotable Chaos · No QotW", page)
        self.assertIn("Episode 2 — Best Early Game Farms · No QotW", page)
        self.assertEqual([entry["qotw_id"] for entry in self.payload["episode_history"]], [None, None])

    def test_archive_shows_each_episode_title_and_archived_questions_have_no_submission(self):
        closed = [entry for entry in self.payload["questions"] if entry["status"] == "closed"]
        page = html.unescape(builder.render_archive(closed, None, None))
        for entry in closed:
            self.assertIn(entry["id"], page)
            self.assertIn(entry["episode_title"], page)
            self.assertIn(entry["text"], page)
        self.assertNotIn("mailto:", page)
        self.assertNotIn("Submit Your Answer", page)

    def test_mailto_encodes_qotw_id_punctuation_and_line_breaks(self):
        question = {
            "id": "QotW #18",
            "text": "Which squad is your favorite?\nTell us why: does it hold up?",
        }
        parsed = parse_qs(urlparse(builder.mailto_url(question)).query)
        self.assertEqual(parsed["subject"], ["Holotable Chaos QotW #18 Submission"])
        self.assertIn("Permanent question ID: QotW #18", parsed["body"][0])
        self.assertIn("favorite?\nTell us why: does it hold up?", parsed["body"][0])
        self.assertIn("In-game name (optional):", parsed["body"][0])
        self.assertIn("Your answer:", parsed["body"][0])

    def test_rendered_current_question_generates_correct_submission_email(self):
        question = {"id": "QotW #18", "text": "What's your plan?\nWhich squad—dark side or light side?", "status": "current", "episode": None, "date": None}
        page = builder.render_page([question], question)
        href = html.unescape(__import__("re").search(r'href="(mailto:[^"]+)"', page).group(1))
        parsed = parse_qs(urlparse(href).query)
        self.assertEqual(parsed["subject"], ["Holotable Chaos QotW #18 Submission"])
        self.assertIn("What's your plan?\nWhich squad—dark side or light side?", parsed["body"][0])
        self.assertEqual(unquote(href.split("?", 1)[0]), "mailto:holotablechaos@gmail.com")

    def test_email_fallback_shows_recipient_subject_and_copyable_body(self):
        question = {"id": "QotW #18", "text": "What's your plan?\nWhich squad?", "status": "current", "episode": None, "date": None}
        page = builder.render_page([question], question)
        self.assertIn("If you don’t have an email app configured", page)
        self.assertIn("To: <strong>holotablechaos@gmail.com</strong>", page)
        self.assertIn("Holotable Chaos QotW #18 Submission", page)
        self.assertIn('readonly aria-label="Copyable answer email"', page)
        self.assertIn("Your answer:", page)

    def test_archived_questions_are_closed_and_have_no_submission_links(self):
        closed = [entry for entry in self.payload["questions"] if entry["status"] == "closed"]
        page = builder.render_page(closed, None)
        self.assertGreater(len(closed), 0)
        self.assertIn("CLOSED", page)
        self.assertIn("ARCHIVE ID:", page)
        self.assertNotIn("Submit Your Answer", page)
        self.assertNotIn("mailto:", page)

    def test_activating_a_draft_closes_previous_current_and_preserves_history(self):
        payload = copy.deepcopy(self.payload)
        old = next(question for question in payload["questions"] if question["id"] == "QotW #18")
        old["text"] = "The existing question text remains unchanged."
        payload["questions"].append({"id": "QotW #19", "episode": 19, "episode_title": "A New Episode", "text": "What is your next farming target?", "status": "draft", "date": None})
        builder.activate_draft(payload, "QotW #19")
        self.assertEqual(old["status"], "closed")
        self.assertEqual(old["id"], "QotW #18")
        self.assertEqual(old["text"], "The existing question text remains unchanged.")
        self.assertEqual(old["episode"], 18)
        self.assertEqual(old["episode_title"], "The Zeta Guide | Stop Wasting Your Zetas")
        self.assertEqual(sum(item["status"] == "current" for item in payload["questions"]), 1)
        new = next(item for item in payload["questions"] if item["id"] == "QotW #19")
        self.assertEqual(new["status"], "current")
        self.assertEqual(new["episode_title"], "A New Episode")
        current = next(item for item in payload["questions"] if item["status"] == "current")
        rendered = builder.render_page(payload["questions"], current)
        self.assertIn("ARCHIVE ID: QotW #18", rendered)
        self.assertIn("QotW #19 Submission", rendered)

    def test_multiple_current_questions_render_a_safe_configuration_error(self):
        payload = copy.deepcopy(self.payload)
        payload["questions"].append({"id": "QotW #19", "text": "Second question", "status": "current", "episode": None, "date": None})
        with tempfile.TemporaryDirectory(dir=ROOT / "scripts" / "tests") as temp_dir:
            temp_root = Path(temp_dir)
            (temp_root / "community").mkdir()
            for relative in ("index.html", "community/index.html"):
                source = (ROOT / relative).read_text(encoding="utf-8")
                (temp_root / relative).write_text(source, encoding="utf-8")
            error = builder.build_site(payload, project_root=temp_root)
            self.assertIn("More than one question is marked current", error)
            page = (temp_root / "community" / "question-of-the-week.html").read_text(encoding="utf-8")
            self.assertIn("CONFIGURATION ERROR", page)
            self.assertNotIn("mailto:", page)

    def test_no_active_question_state_has_no_submission_email(self):
        questions = [entry for entry in self.payload["questions"] if entry["status"] == "closed"]
        page = builder.render_page(questions, None)
        self.assertIn("NO ACTIVE QUESTION", page)
        self.assertNotIn("mailto:", page)

    def test_home_and_community_cards_link_to_the_question_page(self):
        home = (ROOT / "index.html").read_text(encoding="utf-8")
        community = (ROOT / "community" / "index.html").read_text(encoding="utf-8")
        self.assertIn("QOTW_HOME_START", home)
        self.assertIn("community/question-of-the-week.html", home)
        self.assertIn("QOTW_COMMUNITY_START", community)
        self.assertIn('href="question-of-the-week.html"', community)


if __name__ == "__main__":
    unittest.main()
