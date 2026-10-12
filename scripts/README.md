# Buzzsprout episode sync

The sync uses only the Python standard library. From the project root, preview the feed without changing files:

```powershell
python scripts/sync_buzzsprout.py --dry-run
```

Run the actual import after reviewing the preview:

```powershell
python scripts/sync_buzzsprout.py
```

The script reads the Buzzsprout RSS feed, merges items into `content/episodes.json`, adds new cards inside the marked RSS-managed area in `podcast/index.html`, and creates a page only for a new episode whose page does not already exist. Offline fixture mode is available with:

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

Question records and episode titles live in `content/qotw.json`. Episodes 1 and 2 are listed in `episode_history` with `qotw_id: null`; questions #3–#17 are closed, and #18 is current. The permanent ID must match the episode number. Build the page and its homepage/Community previews after editing the data:

```powershell
python scripts/build_qotw.py
```

To add next week's question, append a record with a new permanent `id`, its exact `text`, `status: "draft"`, the episode number, `episode_title`, and any known date metadata. Activate and render it with:

```powershell
python scripts/build_qotw.py --activate "QotW #19"
```

The activation command changes the prior current record to `closed`, makes the draft current, and rebuilds the three static views. It does not reopen closed records, renumber IDs, or edit episode pages. If two records are manually marked current, a normal build writes a configuration-error page with no answer email link and exits with an error; zero current records displays a no-active-question state. Closed questions keep their IDs, wording, episode association, and episode title in the archive.

Run QotW checks with:

```powershell
python -m unittest discover -s scripts/tests -v
```

## SWGoH events calendar

The calendar importer reads the publicly documented SWGoH Events iCalendar feed (`https://swgohevents.com/ical`) using Python's standard library. It updates `content/events.json` and only the marked calendar section of `resources/index.html`. It displays the last successful feed refresh time. The existing hand-maintained snapshot is retained until a complete usable feed has been processed successfully.

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

Events are identified by their iCalendar UID (and recurrence ID when present), sorted by start date, and updated in place when dates change. Empty, malformed, incomplete, or unreachable feeds leave both the saved event catalog and Resources page unchanged and report a clear error. The importer is hosting-independent. After the hosting platform is selected, its scheduler can run the refresh and pass updated static files through that site's normal publishing process; no scheduler or deployment workflow is configured now.
