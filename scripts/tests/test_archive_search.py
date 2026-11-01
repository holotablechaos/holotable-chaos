import re
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import sync_buzzsprout as syncer


ROOT = Path(__file__).resolve().parents[2]


class ArchiveSearchTests(unittest.TestCase):
    def test_episode_archive_has_search_filter_clear_and_live_count_controls(self):
        page = (ROOT / "podcast" / "index.html").read_text(encoding="utf-8")
        for expected in (
            'id="episode-filters"', 'id="episode-search"', 'id="episode-topic"',
            'id="episode-filter-clear"', 'id="episode-filter-status"',
            "Showing all available episodes.", 'src="archive.js"',
        ):
            self.assertIn(expected, page)
        self.assertIn('option value="getting-started"', page)
        self.assertIn('option value="roster-farming"', page)

    def test_all_manual_archive_cards_have_topic_classifications(self):
        page = (ROOT / "podcast" / "index.html").read_text(encoding="utf-8")
        page = re.sub(
            r"<!-- BUZZSPROUT_IMPORTS_START -->.*?<!-- BUZZSPROUT_IMPORTS_END -->",
            "",
            page,
            flags=re.DOTALL,
        )
        cards = re.findall(r'<article class="episode-card"([^>]*)>', page)
        self.assertEqual(len(cards), 17)
        self.assertTrue(all(re.search(r'data-topics="[^"]+"', attributes) for attributes in cards))

    def test_new_rss_cards_include_full_search_text_and_topic_filters(self):
        feed = syncer.parse_feed((ROOT / "scripts" / "fixtures" / "buzzsprout-sample.xml").read_bytes())
        archive = syncer.read_archive(ROOT / "content" / "episodes.json")
        archive["episodes"] = [entry for entry in archive["episodes"] if int(entry.get("episode_number", 0)) <= 17]
        merged, _, _ = syncer.merge_items(archive, feed)
        cards = syncer.render_archive_cards(merged["episodes"])
        episode18 = next(card for card in cards.split("\n          ") if "EPISODE 18" in card)
        self.assertIn('data-topics="roster-farming updates community"', episode18)
        self.assertIn("fleet plans", episode18)
        self.assertIn("community questions", episode18)
        self.assertIn('href="episodes/episode-18.html"', episode18)

    def test_standard_rss_contact_footer_does_not_tag_every_episode_as_community(self):
        topics = syncer._episode_topics(
            "The Zeta Guide | Stop Wasting Your Zetas",
            "A guide to zeta upgrades. Want your roster reviewed? Join the community.",
        )
        self.assertIn("roster-farming", topics)
        self.assertNotIn("community", topics)

    def test_filter_logic_combines_search_and_topic_and_clear_resets_both(self):
        script = (ROOT / "podcast" / "archive.js").read_text(encoding="utf-8")
        self.assertIn("matchesQuery && matchesTopic", script)
        self.assertIn("search.value = \"\"", script)
        self.assertIn("topic.value = \"\"", script)
        self.assertIn("Showing all ${cards.length} episodes.", script)
        self.assertIn("card.dataset.search", script)
        self.assertIn("card.dataset.topics", script)


if __name__ == "__main__":
    unittest.main()
