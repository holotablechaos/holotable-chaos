import re
import shutil
import subprocess
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import sync_buzzsprout as syncer


ROOT = Path(__file__).resolve().parents[2]
NODE = shutil.which("node")


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
        self.assertIn("form.reset()", script)
        self.assertIn("Showing all ${cards.length} episodes.", script)
        self.assertIn("card.dataset.search", script)
        self.assertIn("card.dataset.topics", script)

    @unittest.skipUnless(NODE, "Node.js is required to exercise the archive filter controls.")
    def test_clear_filters_restores_all_cards_after_each_filter_combination(self):
        harness = r'''const fs = require("fs");
const vm = require("vm");
class Control {
  constructor(value = "") { this.value = value; this.defaultValue = value; this.handlers = {}; this.focused = false; }
  addEventListener(name, callback) { this.handlers[name] = callback; }
  focus() { this.focused = true; }
}
const form = new Control();
const search = new Control();
const topic = new Control();
const clear = new Control();
const status = {textContent: ""};
const cards = [
  {dataset: {topics: "game-modes", search: "Grand Arena gac"}, textContent: "Grand Arena", hidden: false},
  {dataset: {topics: "roster-farming", search: "Zeta upgrades"}, textContent: "Zeta upgrades", hidden: false},
];
form.reset = () => { search.value = search.defaultValue; topic.value = topic.defaultValue; };
const controls = {"#episode-filters": form, "#episode-search": search, "#episode-topic": topic, "#episode-filter-clear": clear, "#episode-filter-status": status};
const document = {querySelector: (selector) => controls[selector], querySelectorAll: () => cards};
vm.runInNewContext(fs.readFileSync("podcast/archive.js", "utf8"), {document});
function assertReset(label) {
  clear.handlers.click();
  if (search.value !== "" || topic.value !== "") throw new Error(`${label}: controls did not reset`);
  if (cards.some((card) => card.hidden)) throw new Error(`${label}: cards remained hidden`);
  if (status.textContent !== "Showing all 2 episodes.") throw new Error(`${label}: count was ${status.textContent}`);
  if (!search.focused) throw new Error(`${label}: search focus was not restored`);
}
search.value = "grand";
search.handlers.input();
if (!cards[0].hidden || cards[1].hidden || status.textContent !== "Showing 1 of 2 episodes.") throw new Error("search-only filtering failed");
assertReset("search-only");
topic.value = "roster-farming";
topic.handlers.change();
if (cards[0].hidden || !cards[1].hidden || status.textContent !== "Showing 1 of 2 episodes.") throw new Error("topic-only filtering failed");
assertReset("topic-only");
search.value = "grand";
topic.value = "roster-farming";
search.handlers.input();
topic.handlers.change();
if (cards.some((card) => !card.hidden) || status.textContent !== "Showing 0 of 2 episodes.") throw new Error("combined filtering failed");
assertReset("combined filters");
console.log("clear-filter interaction checks passed");'''
        result = subprocess.run([NODE, "-e", harness], cwd=ROOT, check=True, capture_output=True, text=True)
        self.assertIn("clear-filter interaction checks passed", result.stdout)


if __name__ == "__main__":
    unittest.main()
