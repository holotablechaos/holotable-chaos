# Buzzsprout episode sync

The sync uses only the Python standard library. From the project root, preview the feed without changing files:

```powershell
python scripts/sync_buzzsprout.py --dry-run
```

Run the actual import after reviewing the preview:

```powershell
python scripts/sync_buzzsprout.py
```

The script reads the Buzzsprout RSS feed, merges items into `content/episodes.json`, adds new cards inside the marked RSS-managed area in `podcast/index.html`, and creates a page only for a new episode whose page does not already exist. It also regenerates the homepage "Start here" latest-episode card between the `LATEST_EPISODE_HOME_START`/`LATEST_EPISODE_HOME_END` markers in `index.html`: the episode with the highest number, its title, a short footer-free description and a link to its episode page. The file is only rewritten when the card changes, so a run with no new episode leaves it untouched. `--dry-run` never touches it. Offline fixture mode is available with:

```powershell
python scripts/sync_buzzsprout.py --dry-run --feed-file scripts/fixtures/buzzsprout-sample.xml
```

Run the safety tests with:

```powershell
python -m unittest discover -s scripts/tests -v
```

## Archive protections

- The JSON catalog is the permanent inventory. Items missing from a later RSS response are retained.
- Existing episodes are seeded as manually maintained records. The importer uses RSS GUIDs and a title/episode match to associate feed metadata with them, and only fills fields that are blank.
- Existing episode pages are never regenerated or overwritten. New episode pages use the same navigation, audio player, playback-progress script, and shared styles.
- Repeated runs deduplicate by GUID. Existing pages outside the catalog cause a safe stop instead of being overwritten.
- Network, XML, archive, and marker validation happens before output changes; files are replaced atomically one at a time.

The command is hosting independent. After the repository and hosting provider are chosen, a scheduled job can run this command and pass the resulting static-file changes through the selected site's normal review and publishing process. No schedule or deployment workflow is enabled in this project.

## Question of the Week

The Question of the Week rotates automatically with each new episode. Every 15 minutes, `.github/workflows/update-episodes.yml` imports any new Buzzsprout episode, then runs `scripts/build_qotw.py`. That script reads the `Question of the Week:` line from each episode's show notes in `content/episodes.json`. The newest episode with a question becomes the open question on the Question of the Week page and in the homepage and Community previews. Every earlier question moves to the archive, newest first. If anything changed, the workflow commits it and starts the Pages deploy.

Nothing records which question is "current"; it is worked out from the episodes on every run. So reruns are safe: when no new episode has arrived, the build reports `No changes` and nothing is committed.

To make a question appear automatically, put a line like this in the episode's Buzzsprout description, before the usual "Want your roster reviewed…" text:

```
Question of the Week: What are your thoughts on Droid Destruction so far?
```

`content/qotw.json` is only for exceptions:

- **The show notes don't include the question, or the wording needs fixing.** Add `{"episode": 24, "text": "Your question?"}` to `questions`. An entry here always wins over the show notes. `episode_title` is optional and defaults to the episode's title.
- **An episode had no question.** Add its number to `no_question_episodes`.

Then rebuild and check the result:

```powershell
python scripts/build_qotw.py
```

The importer only fills in show notes the first time it sees an episode, so editing a description in Buzzsprout after the episode was imported won't reach the site. Use a `content/qotw.json` entry in that case.

If the newest episode has no question, the site keeps showing the previous question, the build prints a warning, and the workflow adds that warning to its run summary. The deploy still runs. Episodes with no question on record are listed at the bottom of the archive.

The answer email subject stays `Holotable Chaos QotW #<episode> Submission`, where the number is the episode number.

Run the QotW checks with:

```powershell
python -m unittest discover -s scripts/tests -p test_build_qotw.py -v
```

## SWGoH events calendar

The calendar importer reads the publicly documented SWGoH Events iCalendar feed (`https://swgohevents.com/ical`) using Python's standard library. SWGoH Events documents this URL for subscribing to upcoming events in calendar applications. The importer updates `content/events.json` and only the marked calendar section of `resources/index.html`. The page displays the last successful feed refresh time. The existing saved snapshot remains unchanged if the feed is unavailable, malformed, incomplete, or has no usable upcoming events.

Preview a live refresh without changing files, then run the actual refresh when desired:

```powershell
python scripts/sync_events_calendar.py --dry-run
python scripts/sync_events_calendar.py
```

Offline fixture checks and saved-page rendering are available with:

```powershell
python scripts/sync_events_calendar.py --dry-run --feed-file scripts/fixtures/swgohevents-sample.ics
python scripts/sync_events_calendar.py --render-saved
python -m unittest discover -s scripts/tests -v
```

Events are identified by their iCalendar UID (and recurrence ID when present), sorted by start date, and updated in place when titles or dates change. Empty, malformed, incomplete, or unreachable feeds leave both saved files unchanged and report a clear error. The importer remains hosting-independent.

The GitHub Pages workflow runs a refresh daily at 10:23 UTC and also refreshes before a manually started workflow run. It runs the offline calendar tests before making a live request. On success it commits only `content/events.json` and `resources/index.html`, then the same workflow deploys the refreshed site. A failed test, fetch, parse, or commit prevents the deploy step, leaving the currently published site untouched. No additional secret is needed by the calendar importer; the refresh job uses GitHub's repository token with `contents: write`, while Pages deployment keeps its existing permissions and configuration.
