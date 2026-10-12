# GitHub Pages publishing preparation

This site is static HTML, CSS, browser JavaScript, content files, and local MP3s. It has no package installation or framework build step. `index.html` is the homepage, and the site uses relative paths, so keep the current names and directory layout intact.

## Build the publishable folder locally

From the project root, run:

```powershell
python scripts/stage_pages.py --check
python scripts/stage_pages.py
```

The first command validates the required pages and assets, confirms every episode page points at its expected local MP3, and reports the output size without writing files. The second builds `_site/` from the explicit allowlist. Re-running it replaces `_site/` only when that folder still exactly matches the helper's prior output. `_site/` is ignored by Git because it is generated.

Only the 25 website HTML pages, `styles.css`, the four browser JavaScript files, root `New Logo.JPG`, and the 17 MP3 files referenced by Episodes 1–17 are copied. The helper adds an empty `.nojekyll` file. Content data and maintenance tools remain in the repository for editing and maintenance but are not published as site files.

## GitHub Pages workflow

`.github/workflows/pages.yml` runs on pushes to `main`, can be started manually, and refreshes the SWGoH events calendar daily at 10:23 UTC. The scheduled and manual runs test the calendar importer, fetch the documented SWGoH Events iCalendar feed, and commit only `content/events.json` and the marked calendar section in `resources/index.html`. The same workflow then stages `_site/`, uploads it as a Pages artifact, and deploys it. If the importer fails, deployment is skipped. The Buzzsprout importer is not scheduled or run by this workflow. If the repository uses a default branch with a name other than `main`, update the workflow branch and refresh checkout references before relying on automatic updates.

The public GitHub repository and Pages deployment are already active. The calendar refresh uses the workflow's built-in repository token and needs no additional credential. The existing Pages deployment configuration is retained; the new refresh job receives only `contents: write`, while the deployment job keeps the existing Pages permissions.

## Public-repository exclusions

The `.gitignore` keeps `sources/`, local references, editing/production media, the unused MP3 `rubyzephyr-fleets-under-a-dying-star-446045.mp3`, duplicate artwork in the production-media tree, local environments, credentials, private keys, Python caches, and generated `_site/` out of Git. The media tree is ignored by default; only the 17 website episode MP3 paths are unignored. Original WAV, MOV, MP4, FLAC, Audacity, Reaper, and other masters remain in place on the local computer.

Review Git's untracked/ignored-file list before the first public commit. Never force-add `sources/`, editing media, credentials, private keys, local reference material, or unrelated personal files. The publishing helper uses its own runtime allowlist as a second boundary; it does not copy scripts, tests, fixtures, content data, or ignored editing assets into `_site/`.
