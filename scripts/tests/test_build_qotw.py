import copy
import html
import json
import re
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build_qotw as builder


ROOT = Path(__file__).resolve().parents[2]
CTA = "Want your roster reviewed, have a Question of the Week answer, or a Chaos of the Week submission? Send your ally code to holotablechaos@gmail.com."


def episode(number, question=None, title=None, published_at=None):
    notes = f"Episode {number} notes."
    if question:
        notes += f" Question of the Week: {question}"
    return {
        "episode_number": number,
        "title": title or f"Episode title {number}",
        "description": f"{notes} {CTA}",
        "published_at": published_at,
    }


def submission_href(page):
    return html.unescape(re.search(r'href="(mailto:[^"]+)"', page).group(1))


class ExtractionTests(unittest.TestCase):
    def test_reads_question_up_to_the_call_to_action(self):
        notes = "We talk raids. Question of the Week: What are your thoughts on Droid Destruction so far? " + CTA
        self.assertEqual(builder.extract_question(notes), "What are your thoughts on Droid Destruction so far?")

    def test_question_without_question_mark_and_at_end_of_notes(self):
        self.assertEqual(builder.extract_question("Intro. Question of the Week:  Tell us your   favorite mod set."), "Tell us your favorite mod set.")

    def test_call_to_action_alone_is_not_a_question(self):
        self.assertIsNone(builder.extract_question("Show notes. " + CTA))
        self.assertIsNone(builder.extract_question(None))

    def test_a_reworded_footer_is_never_swallowed(self):
        question = "Which raid team surprised you most?"
        footers = [
            CTA,
            "Got a roster you want us to look at? Email holotablechaos@gmail.com and join our Discord!",
            "Send us your answers at holotablechaos@gmail.com.",
            "Reach us at https://holotablechaos.com/ for more.",
            "Thanks for listening! See you next week.",
            "Want your roster reviewed or have a Question of the Week answer? Send your ally code over.",
            "",
        ]
        for footer in footers:
            for separator in (" ", "\n", "\n\n"):
                with self.subTest(footer=footer, separator=repr(separator)):
                    notes = f"We break down the raid. Question of the Week: {question}{separator}{footer}"
                    self.assertEqual(builder.extract_question(notes), question)

    def test_question_endings(self):
        cases = {
            "Question of the Week: What is your Defensive MVP? (Non-GL) Thanks for listening!": "What is your Defensive MVP? (Non-GL)",
            "question of the week : Name your favorite ship. Email holotablechaos@gmail.com.": "Name your favorite ship.",
            "Question of the Week: Who is the best tank\nThanks for listening": "Who is the best tank",
            "Question of the Week: Which mod set would you send your guild? Want your roster reviewed?": "Which mod set would you send your guild?",
            "Question of the Week: Should Era Arena replace Squad Arena?Got feedback? Email us.": "Should Era Arena replace Squad Arena?",
        }
        for notes, expected in cases.items():
            with self.subTest(notes=notes):
                self.assertEqual(builder.extract_question(notes), expected)

    def test_footer_text_without_a_clear_end_is_rejected(self):
        self.assertIsNone(builder.extract_question("Question of the Week: holotablechaos@gmail.com"))
        self.assertIsNone(builder.extract_question("Question of the Week: " + "very long " * 40))

    def test_real_show_notes_still_produce_the_same_questions(self):
        expected = {
            21: "Do you think Era Arena will be a better game mode than Squad Arena was?",
            22: "With Rogue One celebrating its 10th anniversary, what is your favorite moment from the movie?",
            23: "What are your thoughts on Droid Destruction so far?",
        }
        notes = {e["episode_number"]: e.get("description") for e in builder.load_episodes()}
        for number, question in expected.items():
            self.assertEqual(builder.extract_question(notes[number]), question)


class RotationTests(unittest.TestCase):
    def setUp(self):
        self.payload = {
            "no_question_episodes": [1],
            "questions": [{"episode": 2, "episode_title": "Curated title", "text": "Manual question two?"}],
        }
        self.episodes = [episode(1), episode(2), episode(3, "Feed question three?")]

    def test_newest_episode_with_a_question_is_open_and_older_ones_are_archived(self):
        state = builder.resolve(self.payload, self.episodes)
        self.assertEqual(state.current.id, "QotW #3")
        self.assertEqual(state.current.text, "Feed question three?")
        self.assertEqual([q.id for q in state.archive], ["QotW #2"])
        self.assertEqual(state.archive[0].episode_title, "Curated title")
        self.assertEqual(state.without_question, [(1, "Episode title 1")])
        self.assertEqual(state.warnings, [])

    def test_manual_entry_overrides_show_notes(self):
        self.payload["questions"].append({"episode": 3, "text": "Corrected wording?"})
        state = builder.resolve(self.payload, self.episodes)
        self.assertEqual(state.current.text, "Corrected wording?")
        self.assertEqual(state.current.episode_title, "Episode title 3")

    def test_empty_queue_keeps_the_current_question_and_warns(self):
        self.episodes.append(episode(4))  # new episode, no question in its notes
        state = builder.resolve(self.payload, self.episodes)
        self.assertEqual(state.current.id, "QotW #3")
        self.assertEqual(len(state.warnings), 1)
        self.assertIn("Episode 4", state.warnings[0])
        self.assertIn("still showing QotW #3", state.warnings[0])
        self.assertIn((4, "Episode title 4"), state.without_question)
        page = builder.render_page(state)
        self.assertIn("Feed question three?", page)
        self.assertIn("Submit Your Answer", page)

    def test_episode_marked_as_having_no_question_does_not_warn(self):
        self.episodes.append(episode(4))
        self.payload["no_question_episodes"].append(4)
        state = builder.resolve(self.payload, self.episodes)
        self.assertEqual(state.current.id, "QotW #3")
        self.assertEqual(state.warnings, [])

    def test_no_questions_at_all_shows_no_active_question(self):
        state = builder.resolve({"no_question_episodes": [], "questions": []}, [episode(1)])
        self.assertIsNone(state.current)
        self.assertEqual(len(state.warnings), 1)
        page = builder.render_page(state)
        self.assertIn("NO ACTIVE QUESTION", page)
        self.assertNotIn("mailto:", page)

    def test_first_run_after_a_long_gap_opens_only_the_newest_and_archives_the_rest(self):
        for number in range(4, 9):
            self.episodes.append(episode(number, f"Gap question {number}?"))
        self.episodes.insert(0, self.episodes.pop())  # catalog order must not matter
        state = builder.resolve(self.payload, self.episodes)
        self.assertEqual(state.current.id, "QotW #8")
        self.assertEqual([q.episode for q in state.archive], [7, 6, 5, 4, 3, 2])
        page = builder.render_page(state)
        self.assertEqual(page.count("Submit Your Answer"), 1)
        for number in range(4, 8):
            self.assertEqual(page.count(f"Gap question {number}?"), 1)

    def test_rebuilding_with_no_new_episode_changes_nothing(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            (root / "community").mkdir()
            for relative in ("index.html", "community/index.html"):
                shutil.copy(ROOT / relative, root / relative)
            state, changed = builder.build_site(self.payload, self.episodes, project_root=root)
            self.assertEqual(len(changed), 4)  # home card, community card, QotW page, public feed
            snapshot = {p: p.read_bytes() for p in root.rglob("*.html")}
            _, changed_again = builder.build_site(self.payload, self.episodes, project_root=root)
            self.assertEqual(changed_again, [])
            self.assertEqual(snapshot, {p: p.read_bytes() for p in root.rglob("*.html")})
            self.episodes.append(episode(4, "Next week?"))
            state, changed = builder.build_site(self.payload, self.episodes, project_root=root)
            self.assertEqual(state.current.id, "QotW #4")
            self.assertEqual(len(changed), 4)
            feed = json.loads((root / "community" / "qotw.json").read_text(encoding="utf-8"))
            self.assertEqual(feed["current_episode"], 4)
            self.assertEqual({key for q in feed["questions"] for key in q}, {"episode", "episode_title", "text", "published_at"})
            page = (root / "community" / "question-of-the-week.html").read_text(encoding="utf-8")
            self.assertIn('class="qotw-answer-slot" data-episode="4" hidden', page)
            self.assertIn('class="qotw-answers-slot" data-episode="3" hidden', page)
            self.assertIn('id="qotw-email-answer"', page)  # the email fallback stays
            self.assertIn("QotW #4", (root / "index.html").read_text(encoding="utf-8"))

    def test_missing_markers_change_no_files(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            (root / "community").mkdir()
            (root / "index.html").write_text("<p>no markers</p>", encoding="utf-8")
            shutil.copy(ROOT / "community" / "index.html", root / "community" / "index.html")
            before = (root / "community" / "index.html").read_bytes()
            with self.assertRaises(builder.ContentError):
                builder.build_site(self.payload, self.episodes, project_root=root)
            self.assertEqual((root / "community" / "index.html").read_bytes(), before)
            self.assertFalse((root / "community" / "question-of-the-week.html").exists())

    def test_invalid_manual_entries_are_rejected(self):
        bad_payloads = [
            {"questions": [{"episode": 2, "text": "A?"}, {"episode": 2, "text": "B?"}]},
            {"questions": [{"episode": 2, "text": "  "}]},
            {"questions": [{"episode": 0, "text": "A?"}]},
            {"questions": [{"episode": 2, "text": "A?"}], "no_question_episodes": [2]},
            {"questions": [], "no_question_episodes": ["1"]},
        ]
        for payload in bad_payloads:
            with self.subTest(payload=payload), self.assertRaises(builder.ContentError):
                builder.resolve(payload, self.episodes)


class RenderingTests(unittest.TestCase):
    def setUp(self):
        self.question = builder.Question(18, "The Zeta Guide", "What's your plan?\nWhich squad—dark side or light side?", "2026-10-12T21:00:00Z")

    def test_mailto_encodes_id_punctuation_and_line_breaks(self):
        parsed = parse_qs(urlparse(builder.mailto_url(self.question)).query)
        self.assertEqual(parsed["subject"], ["Holotable Chaos QotW #18 Submission"])
        body = parsed["body"][0]
        self.assertIn("Permanent question ID: QotW #18", body)
        self.assertIn("What's your plan?\nWhich squad—dark side or light side?", body)
        self.assertIn("In-game name (optional):", body)
        self.assertIn("Your answer:", body)

    def test_current_question_page_has_submission_fallback_and_episode_link(self):
        state = builder.QotwState(self.question, [], [], [])
        page = builder.render_page(state)
        href = submission_href(page)
        self.assertEqual(unquote(href.split("?", 1)[0]), "mailto:holotablechaos@gmail.com")
        self.assertIn("If you don’t have an email app configured", page)
        self.assertIn("To: <strong>holotablechaos@gmail.com</strong>", page)
        self.assertIn('readonly aria-label="Copyable answer email"', page)
        self.assertIn('href="../podcast/episodes/episode-18.html"', page)
        self.assertIn("Asked Oct 12, 2026", page)

    def test_archive_has_no_submission_links(self):
        state = builder.QotwState(None, [self.question], [], [])
        archive = builder.render_archive(state.archive)
        self.assertIn("QotW #18", archive)
        self.assertIn("CLOSED", archive)
        self.assertNotIn("mailto:", archive)


class LiveContentTests(unittest.TestCase):
    """Checks against the real content files, so a bad hand edit fails CI."""

    def setUp(self):
        self.payload = builder.load_content()
        self.episodes = builder.load_episodes()
        self.state = builder.resolve(self.payload, self.episodes)

    def test_hand_written_history_is_preserved(self):
        manual = {entry["episode"]: entry for entry in self.payload["questions"]}
        self.assertLessEqual(set(range(3, 19)), set(manual))
        self.assertEqual(manual[18]["text"], "If you could get a refund on one zeta ability upgrade whose would it be?")
        self.assertEqual(manual[6]["episode_title"], "Overrated/Underrated Teams + Hello People Joins the Show!")
        by_episode = {q.episode: q for q in self.state.archive}
        for number, entry in manual.items():
            self.assertEqual(by_episode[number].text, entry["text"])

    def test_every_question_appears_exactly_once(self):
        ids = [q.id for q in self.state.archive] + ([self.state.current.id] if self.state.current else [])
        self.assertEqual(len(ids), len(set(ids)))

    def test_episodes_one_and_two_are_marked_without_a_question(self):
        self.assertEqual(self.payload["no_question_episodes"], [1, 2])
        numbers = [number for number, _ in self.state.without_question]
        self.assertIn(1, numbers)
        self.assertIn(2, numbers)

    def test_home_and_community_previews_link_to_the_question_page(self):
        home = (ROOT / "index.html").read_text(encoding="utf-8")
        community = (ROOT / "community" / "index.html").read_text(encoding="utf-8")
        self.assertIn("QOTW_HOME_START", home)
        self.assertIn('href="community/question-of-the-week.html"', home)
        self.assertIn("QOTW_COMMUNITY_START", community)
        self.assertIn('id="question-of-the-week"', community)
        self.assertIn('href="question-of-the-week.html"', community)


if __name__ == "__main__":
    unittest.main()
