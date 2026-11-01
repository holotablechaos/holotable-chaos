import json
import shutil
import sys
import tempfile
import unittest
from unittest import mock
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import sync_buzzsprout as syncer


PROJECT_ROOT = Path(__file__).resolve().parents[2]
FIXTURES = Path(__file__).resolve().parents[1] / "fixtures"
PROMO_COPY = (
    "Want your roster reviewed, have a Question of the Week answer, or a Chaos of the Week submission? "
    "Send your ally code, questions, and stories to holotablechaos@gmail.com, check out the website for "
    "SWGoH resources and past episodes, or join the Holotable Chaos Discord."
)


class BuzzsproutSyncTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parent)
        self.work = Path(self.temp.name)
        self.archive = self.work / "episodes.json"
        self.index = self.work / "podcast-index.html"
        self.pages = self.work / "episodes"
        source_archive = syncer.read_archive(PROJECT_ROOT / "content" / "episodes.json")
        source_archive["episodes"] = [
            entry for entry in source_archive["episodes"] if int(entry.get("episode_number", 0)) <= 17
        ]
        self.archive.write_text(json.dumps(source_archive, ensure_ascii=False, indent=2), encoding="utf-8")
        self.index.write_text(
            '<div class="episode-grid">\n'
            f"{syncer.MANAGED_START}{syncer.MANAGED_END}"
            '<article class="episode-card">manual episode</article>\n</div>',
            encoding="utf-8",
        )

    def tearDown(self):
        self.temp.cleanup()

    def run_fixture(self, name):
        return syncer.sync(
            feed_file=FIXTURES / name,
            archive_path=self.archive,
            index_path=self.index,
            episodes_dir=self.pages,
        )

    def test_import_duplicate_detection_and_manual_content_preservation(self):
        before = json.loads(self.archive.read_text(encoding="utf-8"))
        manual_17 = next(entry for entry in before["episodes"] if entry["episode_number"] == 17)
        result = self.run_fixture("buzzsprout-sample.xml")
        archive = json.loads(self.archive.read_text(encoding="utf-8"))
        new_items = [entry for entry in archive["episodes"] if entry["guid"] == "buzzsprout-18000018"]
        self.assertEqual(result["added"], 2)
        self.assertEqual(len(new_items), 1)
        self.assertEqual(new_items[0]["episode_number"], 18)
        self.assertEqual(new_items[0]["published_at"], "2026-10-08T16:00:00Z")
        self.assertEqual(new_items[0]["audio_url"], "https://www.buzzsprout.com/2606659/episodes/18000018-a-sample-new-holotable.mp3")
        minimal = next(entry for entry in archive["episodes"] if entry["guid"] == "buzzsprout-19000019")
        self.assertEqual(minimal["episode_number"], 19)
        self.assertEqual(minimal["audio_url"], "")
        updated_17 = next(entry for entry in archive["episodes"] if entry["episode_number"] == 17)
        self.assertEqual(updated_17["description"], manual_17["description"])
        self.assertEqual(updated_17["audio_url"], manual_17["audio_url"])
        self.assertIn("buzzsprout-17000017", updated_17["alternate_guids"])
        self.assertTrue((self.pages / "episode-18.html").exists())
        self.assertTrue((self.pages / "episode-19.html").exists())
        rendered_index = self.index.read_text(encoding="utf-8")
        self.assertLess(rendered_index.index("EPISODE 19"), rendered_index.index("EPISODE 18"))
        self.assertIn('href="episodes/episode-18.html"', rendered_index)
        before_repeat = self.archive.read_bytes()
        index_before_repeat = self.index.read_bytes()
        repeated = self.run_fixture("buzzsprout-sample.xml")
        self.assertEqual(repeated["added"], 0)
        self.assertEqual(self.archive.read_bytes(), before_repeat)
        self.assertEqual(self.index.read_bytes(), index_before_repeat)

    def test_rss_disappearance_does_not_remove_saved_episodes(self):
        self.run_fixture("buzzsprout-sample.xml")
        # A valid feed with no items must not remove feed-imported or manual history.
        empty_feed = self.work / "empty.xml"
        empty_feed.write_text('<rss version="2.0"><channel><title>Holotable Chaos</title></channel></rss>', encoding="utf-8")
        syncer.sync(feed_file=empty_feed, archive_path=self.archive, index_path=self.index, episodes_dir=self.pages)
        archive = json.loads(self.archive.read_text(encoding="utf-8"))
        numbers = {entry["episode_number"] for entry in archive["episodes"]}
        self.assertEqual(numbers, set(range(1, 20)))
        self.assertIn('href="episodes/episode-18.html"', self.index.read_text(encoding="utf-8"))

    def test_malformed_feed_and_network_failure_leave_outputs_unchanged(self):
        bad_feed = self.work / "bad.xml"
        bad_feed.write_text("<rss><channel>", encoding="utf-8")
        before = {path: path.read_bytes() for path in (self.archive, self.index)}
        with self.assertRaises(syncer.FeedError):
            syncer.sync(feed_file=bad_feed, archive_path=self.archive, index_path=self.index, episodes_dir=self.pages)
        after = {path: path.read_bytes() for path in (self.archive, self.index)}
        self.assertEqual(before, after)
        self.assertFalse(self.pages.exists())
        with mock.patch("urllib.request.urlopen", side_effect=syncer.urllib.error.URLError("offline")):
            with self.assertRaises(syncer.FeedError):
                syncer.sync(archive_path=self.archive, index_path=self.index, episodes_dir=self.pages)
        self.assertEqual(before, {path: path.read_bytes() for path in (self.archive, self.index)})

    def test_navigation_is_generated_and_updates_as_archive_grows(self):
        # Retain representative older pages, including their manually maintained copy.
        self.pages.mkdir(parents=True)
        for number in (1, 17):
            shutil.copyfile(PROJECT_ROOT / "podcast" / "episodes" / f"episode-{number}.html",
                            self.pages / f"episode-{number}.html")
        ep17_before = (self.pages / "episode-17.html").read_text(encoding="utf-8")
        result = self.run_fixture("buzzsprout-sample.xml")
        self.assertEqual(result["added"], 2)
        ep19 = (self.pages / "episode-19.html").read_text(encoding="utf-8")
        ep18 = (self.pages / "episode-18.html").read_text(encoding="utf-8")
        ep17 = (self.pages / "episode-17.html").read_text(encoding="utf-8")
        ep1 = (self.pages / "episode-1.html").read_text(encoding="utf-8")
        self.assertIn('href="episode-18.html">Older episode →', ep19)
        self.assertNotIn("Newer episode", ep19)
        self.assertLess(ep19.index("</article>"), ep19.index('class="episode-notes"'))
        self.assertIn("Listen to the", ep19)
        self.assertIn("fleet plans", ep18)
        self.assertIn('src="https://www.buzzsprout.com/2606659/episodes/18000018-a-sample-new-holotable.mp3"', ep18)
        self.assertIn('href="episode-19.html">← Newer episode', ep18)
        self.assertIn('href="episode-17.html">Older episode →', ep18)
        self.assertIn('href="episode-18.html">← Newer episode', ep17)
        self.assertIn('href="episode-16.html">Older episode →', ep17)
        self.assertIn('href="episode-2.html">← Newer episode', ep1)
        self.assertNotIn("Older episode", ep1)
        self.assertIn("Droid Destruction", ep17)
        self.assertEqual(ep17.count("Droid Destruction"), ep17_before.count("Droid Destruction"))

        newest = self.work / "episode-20.xml"
        newest.write_text('''<rss version="2.0"><channel><item><title>Episode 20: Newest</title>
          <guid>buzzsprout-20000020</guid><pubDate>Sat, 10 Oct 2026 16:00:00 GMT</pubDate>
          <enclosure url="https://example.test/20.mp3" type="audio/mpeg" /></item></channel></rss>''', encoding="utf-8")
        syncer.sync(feed_file=newest, archive_path=self.archive, index_path=self.index, episodes_dir=self.pages)
        ep20 = (self.pages / "episode-20.html").read_text(encoding="utf-8")
        ep19 = (self.pages / "episode-19.html").read_text(encoding="utf-8")
        ep18 = (self.pages / "episode-18.html").read_text(encoding="utf-8")
        self.assertIn('href="episode-19.html">Older episode →', ep20)
        self.assertNotIn("Newer episode", ep20)
        self.assertLess(ep20.index("</article>"), ep20.index('class="episode-notes"'))
        self.assertIn('src="https://example.test/20.mp3"', ep20)
        self.assertIn("Listen to the latest Holotable Chaos episode.", ep20)
        self.assertIn('href="episode-20.html">← Newer episode', ep19)
        self.assertIn('href="episode-18.html">Older episode →', ep19)
        self.assertIn('href="episode-19.html">← Newer episode', ep18)
        self.assertIn('href="episode-17.html">Older episode →', ep18)

    def test_existing_imported_page_is_repaired_without_losing_audio_or_description(self):
        archive = json.loads(self.archive.read_text(encoding="utf-8"))
        archive["episodes"].append({
            "guid": "buzzsprout-18000018", "alternate_guids": [], "episode_number": 18,
            "title": "A Preserved Episode 18", "description": "Hand-maintained full description.",
            "summary": "Hand-maintained summary", "published_at": "2026-10-08T16:00:00Z",
            "audio_url": "https://audio.example.test/episode-18.mp3", "audio_type": "audio/mpeg",
            "source": "buzzsprout",
        })
        self.archive.write_text(json.dumps(archive), encoding="utf-8")
        self.pages.mkdir(parents=True)
        old_page = '''<html><body><main>
          <section class="page-intro"><h1>Episode 18</h1><p>Hand-maintained full description.</p>
            <p><a href="../index.html">Back to all episodes</a></p></section>
          <section class="page-content"><article class="episode-card"><audio controls>
            <source src="https://audio.example.test/episode-18.mp3" type="audio/mpeg" /></audio></article></section>
          </main></body></html>'''
        (self.pages / "episode-18.html").write_text(old_page, encoding="utf-8")
        self.run_fixture("buzzsprout-sample.xml")
        repaired = (self.pages / "episode-18.html").read_text(encoding="utf-8")
        self.assertLess(repaired.index("</article>"), repaired.index('class="episode-notes"'))
        self.assertIn("Hand-maintained full description.", repaired)
        self.assertIn('src="https://audio.example.test/episode-18.mp3"', repaired)
        self.assertIn('href="episode-19.html">← Newer episode', repaired)
        self.assertIn('href="episode-17.html">Older episode →', repaired)
        self.assertIn("Back to all episodes", repaired)

    def test_unwanted_about_episode_15_is_excluded_narrowly_and_permanently(self):
        archive = json.loads(self.archive.read_text(encoding="utf-8"))
        archive["episodes"].append({
            "guid": "unwanted-about-15-guid", "episode_number": 99,
            "title": "About Episode 15...", "description": "Auto-generated item",
            "source": "buzzsprout", "published_at": "2026-10-10T00:00:00Z",
        })
        self.archive.write_text(json.dumps(archive), encoding="utf-8")
        feed = self.work / "exclusion.xml"
        feed.write_text('''<rss version="2.0"><channel>
          <item><title>About Episode 15...</title><guid>unwanted-about-15-guid</guid>
            <pubDate>Sat, 10 Oct 2026 16:00:00 GMT</pubDate></item>
          <item><title>What We Learned from Episode 15</title><guid>legitimate-episode-20</guid>
            <description>This discussion mentions Episode 15 in the description.</description>
            <pubDate>Sun, 11 Oct 2026 16:00:00 GMT</pubDate></item>
        </channel></rss>''', encoding="utf-8")
        first = syncer.sync(feed_file=feed, archive_path=self.archive, index_path=self.index, episodes_dir=self.pages)
        saved = json.loads(self.archive.read_text(encoding="utf-8"))["episodes"]
        self.assertEqual(first["added"], 1)
        self.assertNotIn("unwanted-about-15-guid", {entry.get("guid") for entry in saved})
        self.assertIn("What We Learned from Episode 15", {entry["title"] for entry in saved})
        listing = self.index.read_text(encoding="utf-8")
        self.assertNotIn("About Episode 15", listing)
        self.assertIn("What We Learned from Episode 15", listing)
        second = syncer.sync(feed_file=feed, archive_path=self.archive, index_path=self.index, episodes_dir=self.pages)
        self.assertEqual(second["added"], 0)
        self.assertEqual(len([entry for entry in json.loads(self.archive.read_text(encoding="utf-8"))["episodes"]
                              if entry.get("guid") == "legitimate-episode-20"]), 1)

    def test_guid_anchor_corrects_episode_numbers_and_new_import_continues_sequentially(self):
        archive = json.loads(self.archive.read_text(encoding="utf-8"))
        zeta = {
            "guid": "Buzzsprout-19951449", "alternate_guids": [], "episode_number": 18,
            "title": "The Zeta Guide | Stop Wasting Your Zetas",
            "description": "Manually preserved Zeta description", "summary": "Manual Zeta summary",
            "published_at": "2026-10-12T21:00:00Z", "audio_url": "https://audio.example/zeta.mp3",
            "audio_type": "audio/mpeg", "source": "buzzsprout",
        }
        mini = {
            "guid": "Buzzsprout-20003110", "alternate_guids": [], "episode_number": 19,
            "title": "The Mini Era | Who Gets Left Behind?",
            "description": "Manually preserved Mini Era description", "summary": "Manual Mini summary",
            "published_at": "2026-10-22T12:00:00Z", "audio_url": "https://audio.example/mini.mp3",
            "audio_type": "audio/mpeg", "source": "buzzsprout",
        }
        archive["episodes"].extend([zeta, mini, {
            "guid": "Buzzsprout-19836447", "episode_number": 20,
            "title": "About Episode 15...", "source": "buzzsprout",
        }])
        feed = self.work / "anchored-renumbering.xml"
        feed.write_text('''<rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel>
          <item><title>The Zeta Guide | Stop Wasting Your Zetas</title><guid>Buzzsprout-19951449</guid>
            <pubDate>Mon, 12 Oct 2026 17:00:00 -0400</pubDate><itunes:episode>19</itunes:episode></item>
          <item><title>The Mini Era | Who Gets Left Behind?</title><guid>Buzzsprout-20003110</guid>
            <pubDate>Thu, 22 Oct 2026 08:00:00 -0400</pubDate><itunes:episode>20</itunes:episode></item>
          <item><title>About Episode 15...</title><guid>Buzzsprout-19836447</guid>
            <pubDate>Mon, 21 Sep 2026 08:00:00 -0400</pubDate><itunes:episode>18</itunes:episode></item>
          <item><title>Next Legitimate Episode</title><guid>Buzzsprout-20100000</guid>
            <pubDate>Sun, 01 Nov 2026 08:00:00 -0500</pubDate><itunes:episode>21</itunes:episode>
            <enclosure url="https://audio.example/next.mp3" type="audio/mpeg" /></item>
        </channel></rss>''', encoding="utf-8")
        merged, additions, _ = syncer.merge_items(archive, syncer.parse_feed(feed.read_bytes()))
        by_guid = {entry["guid"]: entry for entry in merged["episodes"]}
        self.assertEqual(by_guid["Buzzsprout-19951449"]["episode_number"], 18)
        self.assertEqual(by_guid["Buzzsprout-20003110"]["episode_number"], 19)
        self.assertEqual(by_guid["Buzzsprout-20100000"]["episode_number"], 20)
        self.assertEqual(by_guid["Buzzsprout-19951449"]["description"], "Manually preserved Zeta description")
        self.assertEqual(by_guid["Buzzsprout-19951449"]["audio_url"], "https://audio.example/zeta.mp3")
        self.assertEqual(by_guid["Buzzsprout-20003110"]["description"], "Manually preserved Mini Era description")
        self.assertNotIn("Buzzsprout-19836447", by_guid)
        self.assertEqual([entry["episode_number"] for entry in additions], [20])

    def test_navigation_uses_permanent_archive_order_not_episode_numbers(self):
        episodes = [
            {"episode_number": 42}, {"episode_number": 9}, {"episode_number": 15},
        ]
        middle = syncer._episode_navigation(episodes[1], episodes)
        self.assertIn('href="episode-42.html">← Newer episode', middle)
        self.assertIn('href="episode-15.html">Older episode →', middle)
        self.assertNotIn('episode-10.html', middle)

    def test_episode_generator_removes_only_the_standard_promotional_footer(self):
        page = syncer._episode_page({
            "episode_number": 20,
            "title": "A New Episode",
            "description": f"The full episode description stays. {PROMO_COPY}",
            "audio_url": "https://example.test/new-episode.mp3",
        })
        self.assertIn("The full episode description stays.", page)
        self.assertNotIn("Want your roster reviewed", page)
        self.assertNotIn("check out the website for SWGoH resources", page)
        self.assertIn('src="https://example.test/new-episode.mp3"', page)

    def test_existing_episode_page_cleanup_preserves_description_and_navigation(self):
        self.pages.mkdir(parents=True)
        path = self.pages / "episode-18.html"
        path.write_text(f'''<html><body><main>
          <section class="page-content"><article class="episode-card"><audio controls><source src="https://example.test/18.mp3" /></audio></article>
          <section class="episode-notes"><p>Manually maintained description. {PROMO_COPY}</p></section>
          <nav class="episode-navigation" aria-label="Episode navigation"><a href="episode-19.html">← Newer episode</a><a href="episode-17.html">Older episode →</a></nav></section>
          </main></body></html>''', encoding="utf-8")
        episodes = [
            {"episode_number": 19, "source": "buzzsprout"},
            {"episode_number": 18, "source": "buzzsprout"},
            {"episode_number": 17, "source": "manual"},
        ]
        self.assertEqual(syncer.update_episode_navigation(episodes, self.pages), 1)
        updated = path.read_text(encoding="utf-8")
        self.assertIn("Manually maintained description.", updated)
        self.assertNotIn("Want your roster reviewed", updated)
        self.assertIn('href="episode-19.html"', updated)
        self.assertIn('href="episode-17.html"', updated)

    def test_all_existing_episode_pages_are_free_of_the_promotional_footer(self):
        pages = sorted((PROJECT_ROOT / "podcast" / "episodes").glob("episode-*.html"))
        matching = [page.name for page in pages if "Want your roster reviewed, have a Question of the Week answer" in page.read_text(encoding="utf-8")]
        self.assertEqual(matching, [])

    def test_same_date_new_import_numbering_is_independent_of_feed_position(self):
        base = json.loads(self.archive.read_text(encoding="utf-8"))
        base["episodes"].extend([
            {"guid": "Buzzsprout-19951449", "episode_number": 18, "title": "The Zeta Guide", "source": "buzzsprout"},
            {"guid": "Buzzsprout-20003110", "episode_number": 19, "title": "The Mini Era", "source": "buzzsprout"},
        ])
        entries = [
            {"guid": "guid-b", "title": "Episode B", "episode_number": 88, "published_at": "2026-11-01T12:00:00Z", "_position": 0},
            {"guid": "guid-a", "title": "Episode A", "episode_number": 87, "published_at": "2026-11-01T12:00:00Z", "_position": 1},
        ]
        first, _, _ = syncer.merge_items(json.loads(json.dumps(base)), entries)
        second, _, _ = syncer.merge_items(json.loads(json.dumps(base)), list(reversed(entries)))
        first_numbers = {item["guid"]: item["episode_number"] for item in first["episodes"]}
        second_numbers = {item["guid"]: item["episode_number"] for item in second["episodes"]}
        self.assertEqual(first_numbers["guid-a"], 20)
        self.assertEqual(first_numbers["guid-b"], 21)
        self.assertEqual(first_numbers, second_numbers)


if __name__ == "__main__":
    unittest.main()
