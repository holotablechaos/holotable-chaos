#!/usr/bin/env python3
"""Build the allowlisted, static GitHub Pages site in _site/."""

from __future__ import annotations

import argparse
import os
import posixpath
import re
import shutil
import sys
import tempfile
from dataclasses import dataclass
from html.parser import HTMLParser
from pathlib import Path, PurePosixPath
from urllib.parse import unquote

MAX_PAGES_BYTES = 1_000_000_000
MARKER = ".nojekyll"

PAGES = (
    "index.html",
    "about/index.html",
    "community/index.html",
    "community/question-of-the-week.html",
    "community/chaos-of-the-week.html",
    "resources/index.html",
    "roster-review/index.html",
    "podcast/index.html",
    *(f"podcast/episodes/episode-{n}.html" for n in range(1, 18)),
)
ASSETS = (
    "styles.css",
    "New Logo.JPG",
    "community/chaos-of-the-week.js",
    "community/general-feedback.js",
    "podcast/playback-progress.js",
    "roster-review/form.js",
)
AUDIO_FILES = (
    "Holotable Chaos/Ep. 1 - Intro to Holotable Chaos/Episode 1 - Intro to Holotable Chaos.mp3",
    "Holotable Chaos/Ep. 2 - Best Early Game Farms/Episode 2 - Best Early Game Farms.mp3",
    "Holotable Chaos/Ep. 3 - How I Would Have Started/Episode 3 - How I Would Have Started.mp3",
    "Holotable Chaos/Ep. 4 - Finding a Good Guild/Episode 4 - Finding a Good Guild.mp3",
    "Holotable Chaos/Ep. 5 - Carson Teva First Impressions/Episode 5 - Carson Teva First Impressions.mp3",
    "Holotable Chaos/Ep. 6 - Overrated & Underrated Teams/Ep.6_Overrated Underrated Teams.mp3",
    "Holotable Chaos/Ep. 7 - State of the Game July 2026/Ep.7_State_of_the_Game_July2026.mp3",
    "Holotable Chaos/Ep. 8 - 10 Characters Who NEED a Rework/Ep. 8_10 Characters Who NEED a Rework.mp3",
    "Holotable Chaos/Ep. 9 - Legends Are Finally Here! Breaking Down the Era of Myths and Legends/Ep. 9.mp3",
    "Holotable Chaos/Ep. 10 - Mara Jade Skywalker is No Joke, Breaking Down Her Kit & More/Ep. 10.mp3",
    "Holotable Chaos/Ep. 11 - Your First Galactic Legend, Which One Should You Choose/Ep. 11.mp3",
    "Holotable Chaos/Ep. 12 - Ships 101, Stop Ignoring Fleets/Holotable Chaos Episode 12.mp3",
    "Holotable Chaos/Ep. 13 - Interview With theothersean!/Holotable Chaos Episode 13_final.mp3",
    "Holotable Chaos/Ep. 14 - SWGoH This or That/Holotable Chaos Episode 14_final.mp3",
    "Holotable Chaos/Ep. 15 - Embo & Keibu, Are They Built For Baylan Skoll/HC Episode 15 - Audio.mp3",
    "Holotable Chaos/Ep. 16 - The GAC Guide, How to Approach Grand Arena/HC Episode 16 - Audio.mp3",
    "Holotable Chaos/Ep. 17 - Droid Destruction, What We Know So Far/HC Episode 17 - Audio.mp3",
)
PUBLISH_FILES = (*PAGES, *ASSETS, *AUDIO_FILES)


class AudioSourceParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.sources: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag.lower() != "source":
            return
        src = dict(attrs).get("src")
        if src:
            self.sources.append(src)


@dataclass(frozen=True)
class StagePlan:
    root: Path
    output: Path
    files: tuple[str, ...]
    total_bytes: int


def _expected_source_for_episode(root: Path, episode: int) -> str:
    page = root / "podcast" / "episodes" / f"episode-{episode}.html"
    parser = AudioSourceParser()
    try:
        parser.feed(page.read_text(encoding="utf-8"))
    except (OSError, UnicodeError) as exc:
        raise ValueError(f"Cannot read episode {episode} page: {exc}") from exc
    if len(parser.sources) != 1:
        raise ValueError(
            f"{page.relative_to(root).as_posix()} must contain exactly one audio source; found {len(parser.sources)}"
        )
    raw = parser.sources[0]
    if re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*:", raw) or raw.startswith(("/", "\\")):
        raise ValueError(f"Episode {episode} audio must be a local relative file path")
    joined = PurePosixPath("podcast/episodes") / unquote(raw).replace("\\", "/")
    normalized = PurePosixPath(posixpath.normpath(joined.as_posix())).as_posix()
    if normalized.startswith("../") or normalized == "..":
        raise ValueError(f"Episode {episode} audio path escapes the project: {raw}")
    return normalized


def make_plan(root: Path, output: Path) -> StagePlan:
    root = root.resolve()
    output = output.resolve()
    if output != (root / "_site").resolve():
        raise ValueError("Output must be the project-root _site/ directory")

    required = (*PAGES, *ASSETS, *AUDIO_FILES)
    missing = [name for name in required if not (root / Path(name)).is_file()]
    if missing:
        raise FileNotFoundError("Required website file(s) are missing:\n  - " + "\n  - ".join(missing))

    allowed_audio = set(AUDIO_FILES)
    for episode in range(1, 18):
        actual = _expected_source_for_episode(root, episode)
        if actual not in allowed_audio:
            raise ValueError(
                f"Episode {episode} references audio outside the explicit MP3 allowlist: {actual}"
            )
        expected = AUDIO_FILES[episode - 1]
        if actual != expected:
            raise ValueError(
                f"Episode {episode} references {actual!r}, but the approved path is {expected!r}"
            )

    total = sum((root / Path(name)).stat().st_size for name in required)
    if total >= MAX_PAGES_BYTES:
        raise ValueError(
            f"Staged site would be {total:,} bytes, over GitHub Pages' 1 GB published-site limit"
        )
    if output.exists():
        if output.is_symlink() or not output.is_dir():
            raise ValueError("Refusing to replace _site/: it is not a regular generated directory")
        prior = {p.relative_to(output).as_posix() for p in output.rglob("*") if p.is_file()}
        expected_prior = set(required) | {MARKER}
        if prior != expected_prior or (output / MARKER).read_bytes() != b"":
            raise ValueError("Refusing to replace _site/: contents do not match this helper's prior output")
        if any(p.is_symlink() for p in output.rglob("*")):
            raise ValueError("Refusing to replace _site/: it contains a symbolic link")
    return StagePlan(root, output, required, total)


def stage(plan: StagePlan) -> int:
    parent = plan.output.parent
    temp_path: Path | None = None
    try:
        with tempfile.TemporaryDirectory(prefix="_site-staging-", dir=parent) as temp_name:
            temp_path = Path(temp_name) / "site"
            temp_path.mkdir()
            for relative in plan.files:
                source = plan.root / Path(relative)
                destination = temp_path / Path(relative)
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, destination)
            (temp_path / MARKER).write_bytes(b"")
            if plan.output.exists():
                shutil.rmtree(plan.output)
            os.replace(temp_path, plan.output)
    except Exception:
        # TemporaryDirectory cleans up its own staging directory; never touch source files.
        raise
    return len(plan.files) + 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="validate and report without writing _site/")
    args = parser.parse_args(argv)
    root = Path(__file__).resolve().parent.parent
    output = root / "_site"
    try:
        plan = make_plan(root, output)
        count = len(plan.files) + 1
        if args.check:
            print(f"Check passed: {len(PAGES)} HTML pages, {len(ASSETS)} runtime assets, {len(AUDIO_FILES)} episode MP3s")
            print(f"Planned output: {count} files, {plan.total_bytes:,} bytes ({plan.total_bytes / 1024**2:.2f} MiB)")
            print("No files written.")
        else:
            written = stage(plan)
            print(f"Built {plan.output}: {written} files, {plan.total_bytes:,} bytes ({plan.total_bytes / 1024**2:.2f} MiB)")
            print("Included exactly 17 allowlisted episode MP3s; maintenance and editing files were excluded.")
        return 0
    except (OSError, ValueError) as exc:
        print(f"Staging failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
