#!/usr/bin/env python3
"""Render the Question of the Week page and its homepage/Community previews.

Questions come from two places, merged per episode:

1. The "Question of the Week:" line in each episode's show notes
   (content/episodes.json, kept up to date by sync_buzzsprout.py).
2. Hand-written entries in content/qotw.json, which always win. Use them for
   episodes whose show notes don't include the question, or to fix wording.

The newest episode with a question is the open question; every earlier one is
archived. Nothing is stored about which question is "current", so the build is
deterministic and safe to rerun: if no new episode has arrived, the output is
byte-for-byte unchanged.
"""

from __future__ import annotations

import argparse
import html
import json
import os
import re
import sys
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import quote

ROOT = Path(__file__).resolve().parents[1]
CONTENT_PATH = ROOT / "content" / "qotw.json"
EPISODES_PATH = ROOT / "content" / "episodes.json"
HOME_MARKERS = ("<!-- QOTW_HOME_START -->", "<!-- QOTW_HOME_END -->")
COMMUNITY_MARKERS = ("<!-- QOTW_COMMUNITY_START -->", "<!-- QOTW_COMMUNITY_END -->")
RECIPIENT = "holotablechaos@gmail.com"
DISPLAY_TIMEZONE = "America/New_York"

# Finding where the question ends must not depend on the wording of the show-notes
# footer, which can change at any time. So the question is taken from its label to:
#   1. the first line break, a known footer phrase, or an email/link (all hard stops);
#   2. then the first "?" (plus an immediately following "(…)" note such as "(Non-GL)"),
#      or, with no "?", the first sentence end.
# Anything that still looks like footer text is rejected, so the build warns and the
# question can be added by hand to content/qotw.json. Multi-sentence questions that
# continue past their first "?" also need a hand-written entry.
QUESTION_LABEL = re.compile(r"Question of the Week\s*:", re.IGNORECASE)
HARD_STOPS = re.compile(
    r"\n|want your roster reviewed|send (?:us )?your (?:ally code|answers?|questions)|check out the website|join (?:the|our) [\w ]*discord"
    r"|\S+@\S+|https?://",
    re.IGNORECASE,
)
QUESTION_END = re.compile(r"\?(?:\s*\([^()\n]{1,80}\))?")
SENTENCE_END = re.compile(r"[.!](?=\s|$)")
MAX_QUESTION_LENGTH = 300


class ContentError(ValueError):
    pass


@dataclass(frozen=True)
class Question:
    episode: int
    episode_title: str
    text: str
    published_at: str | None = None

    @property
    def id(self) -> str:
        return f"QotW #{self.episode}"


@dataclass(frozen=True)
class QotwState:
    current: Question | None
    archive: list[Question]  # newest first, excludes the current question
    without_question: list[tuple[int, str]]  # (episode, title), oldest first
    warnings: list[str]


# --------------------------------------------------------------------------- data


def _read_json(path: Path, label: str) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ContentError(f"Could not read {label}: {exc}") from exc
    if not isinstance(payload, dict):
        raise ContentError(f"{label} must be a JSON object.")
    return payload


def load_content(path: Path = CONTENT_PATH) -> dict[str, Any]:
    return _read_json(path, "Question of the Week content")


def load_episodes(path: Path = EPISODES_PATH) -> list[dict[str, Any]]:
    episodes = _read_json(path, "the episode catalog").get("episodes")
    if not isinstance(episodes, list):
        raise ContentError("The episode catalog must contain an episodes array.")
    return episodes


def extract_question(description: str | None) -> str | None:
    """Return the Question of the Week from an episode's show notes, if present."""
    label = QUESTION_LABEL.search(description or "")
    if not label:
        return None
    rest = (description or "")[label.end():].lstrip()
    stop = HARD_STOPS.search(rest)
    if stop:
        rest = rest[: stop.start()]
    end = QUESTION_END.search(rest) or SENTENCE_END.search(rest)
    if end:
        rest = rest[: end.end()]
    text = " ".join(rest.split())
    if not text or len(text) > MAX_QUESTION_LENGTH:
        return None
    return text


def _validate_manual(payload: dict[str, Any]) -> tuple[dict[int, dict[str, Any]], set[int]]:
    entries = payload.get("questions", [])
    if not isinstance(entries, list):
        raise ContentError("content/qotw.json: questions must be a list.")
    manual: dict[int, dict[str, Any]] = {}
    for index, entry in enumerate(entries, start=1):
        if not isinstance(entry, dict):
            raise ContentError(f"content/qotw.json: question {index} must be an object.")
        episode = entry.get("episode")
        if not isinstance(episode, int) or isinstance(episode, bool) or episode < 1:
            raise ContentError(f"content/qotw.json: question {index} needs a positive episode number.")
        if episode in manual:
            raise ContentError(f"content/qotw.json: episode {episode} has more than one question.")
        text = entry.get("text")
        if not isinstance(text, str) or not text.strip():
            raise ContentError(f"content/qotw.json: episode {episode} needs the question text.")
        title = entry.get("episode_title")
        if title is not None and not isinstance(title, str):
            raise ContentError(f"content/qotw.json: episode {episode} has an invalid episode_title.")
        manual[episode] = entry
    no_question = payload.get("no_question_episodes", [])
    if not isinstance(no_question, list) or not all(isinstance(n, int) and not isinstance(n, bool) and n > 0 for n in no_question):
        raise ContentError("content/qotw.json: no_question_episodes must be a list of episode numbers.")
    overlap = sorted(set(no_question) & set(manual))
    if overlap:
        raise ContentError(f"content/qotw.json: episode {overlap[0]} is listed both with and without a question.")
    return manual, set(no_question)


def resolve(payload: dict[str, Any], episodes: list[dict[str, Any]]) -> QotwState:
    """Merge show notes with hand-written entries and decide the open question."""
    manual, no_question = _validate_manual(payload)
    catalog: dict[int, dict[str, Any]] = {}
    for record in episodes:
        number = record.get("episode_number") if isinstance(record, dict) else None
        if isinstance(number, int) and number > 0:
            catalog[number] = record

    questions: list[Question] = []
    without_question: list[tuple[int, str]] = []
    for number in sorted(set(catalog) | set(manual)):
        record = catalog.get(number, {})
        entry = manual.get(number)
        title = ((entry or {}).get("episode_title") or record.get("title") or f"Episode {number}").strip()
        text = entry["text"].strip() if entry else (None if number in no_question else extract_question(record.get("description")))
        if text:
            questions.append(Question(number, title, text, record.get("published_at") or None))
        else:
            without_question.append((number, title))

    current = questions[-1] if questions else None
    warnings: list[str] = []
    latest = max(catalog) if catalog else None
    if latest is not None and (current is None or latest > current.episode) and latest not in no_question:
        still = f"The site is still showing {current.id}." if current else "There is no open question."
        warnings.append(
            f"Episode {latest} has no 'Question of the Week:' line in its show notes. {still} "
            f"Add the question to content/qotw.json (or list {latest} in no_question_episodes if it had none)."
        )
    archive = list(reversed(questions[:-1]))
    return QotwState(current, archive, without_question, warnings)


# ------------------------------------------------------------------------ render


def email_body(question: Question) -> str:
    return (
        f"Permanent question ID: {question.id}\n\n"
        f"Question:\n{question.text}\n\n"
        "In-game name (optional):\n\n\n"
        "Your answer:\n"
    )


def email_subject(question: Question) -> str:
    return f"Holotable Chaos {question.id} Submission"


def mailto_url(question: Question) -> str:
    return f"mailto:{RECIPIENT}?subject={quote(email_subject(question), safe='')}&body={quote(email_body(question), safe='')}"


def display_date(published_at: str | None) -> str | None:
    if not published_at:
        return None
    try:
        moment = datetime.fromisoformat(published_at.replace("Z", "+00:00"))
    except ValueError:
        return None
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=timezone.utc)
    try:
        from zoneinfo import ZoneInfo

        moment = moment.astimezone(ZoneInfo(DISPLAY_TIMEZONE))
    except Exception:  # Missing tz database: fall back to the UTC date.
        moment = moment.astimezone(timezone.utc)
    return f"{moment:%b} {moment.day}, {moment.year}"


def _excerpt(value: str, limit: int = 160) -> str:
    text = " ".join(value.split())
    if len(text) <= limit:
        return text
    return text[: limit - 1].rsplit(" ", 1)[0].rstrip(" .,;:") + "…"


def _episode_link(question_or_number: Question | int, title: str | None = None, prefix: str = "../") -> str:
    if isinstance(question_or_number, Question):
        number, title = question_or_number.episode, question_or_number.episode_title
    else:
        number = question_or_number
    href = f"{prefix}podcast/episodes/episode-{number}.html"
    return f'Episode {number} · <a href="{href}">{html.escape(title or "")}</a>'


def _metadata(question: Question) -> str:
    parts = [_episode_link(question)]
    date = display_date(question.published_at)
    if date:
        parts.append(f"Asked {html.escape(date)}")
    return " · ".join(parts)


def render_home_card(current: Question | None) -> str:
    label = current.id if current else "No active question"
    preview = current.text if current else "There is no open Question of the Week right now."
    state = "OPEN" if current else "CLOSED"
    return (
        '<article class="community-card qotw-community-card">'
        '<div class="community-card-heading"><span class="card-kicker">QUESTION OF THE WEEK</span>'
        f'<span class="qotw-status">{state}</span></div>'
        f'<h3>{html.escape(label)}</h3><p>{html.escape(_excerpt(preview))}</p>'
        '<a class="card-link" href="community/question-of-the-week.html">Answer the question or browse the archive <span>↗</span></a>'
        '</article>'
    )


def render_community_card(current: Question | None) -> str:
    label = current.id if current else "No active question"
    preview = current.text if current else "There is no open Question of the Week right now."
    state = "OPEN" if current else "NO ACTIVE QUESTION"
    return (
        '<article class="community-card qotw-community-card" id="question-of-the-week">'
        '<div class="community-card-heading"><span class="card-kicker">LISTENER QUESTION</span>'
        f'<span class="qotw-status">{state}</span></div>'
        f'<h2>Question of the Week</h2><p class="qotw-preview"><strong>{html.escape(label)}</strong><br />{html.escape(_excerpt(preview))}</p>'
        '<a class="card-link" href="question-of-the-week.html">Answer the question or browse the archive <span>↗</span></a>'
        '</article>'
    )


def render_current(current: Question | None) -> str:
    if current is None:
        return (
            '<section class="qotw-current" aria-labelledby="current-question-title">'
            '<span class="qotw-status qotw-status-closed">NO ACTIVE QUESTION</span>'
            '<h2 id="current-question-title" class="qotw-question">Check back for the next question.</h2>'
            '<p class="qotw-send-note">A new Question of the Week is asked in each episode. Past questions remain below.</p></section>'
        )
    identifier = html.escape(current.id)
    return (
        f'<section class="qotw-current" aria-labelledby="current-question-title" data-episode="{current.episode}">'
        f'<div class="community-card-heading"><span class="card-kicker">THIS WEEK’S QUESTION · {identifier}</span><span class="qotw-status">OPEN</span></div>'
        f'<h2 id="current-question-title" class="qotw-question">{html.escape(current.text)}</h2>'
        f'<p class="qotw-current-metadata">{_metadata(current)}</p>'
        '<p class="qotw-feature-note">Your answer may be discussed or featured in a future Holotable Chaos podcast episode.</p>'
        f'<div class="qotw-answer-slot" data-episode="{current.episode}" hidden></div>'
        f'<a class="button button-primary qotw-submit" id="qotw-email-answer" href="{html.escape(mailto_url(current), quote=True)}">Submit Your Answer <span aria-hidden="true">→</span></a>'
        '<p class="qotw-send-note">This opens your email application. Review the message and send it yourself; answers are not submitted automatically.</p>'
        '<details class="qotw-email-fallback"><summary>If you don’t have an email app configured</summary>'
        f'<p>To: <strong>{RECIPIENT}</strong><br />Subject: <strong>{html.escape(email_subject(current))}</strong></p>'
        '<p>Copy the message below into a new email to the address above with the subject shown.</p>'
        f'<textarea rows="10" readonly aria-label="Copyable answer email">{html.escape(email_body(current))}</textarea></details>'
        '</section>'
    )


def render_archive(archive: list[Question]) -> str:
    if not archive:
        return '<p class="qotw-empty-archive">Past questions will appear here once the next question is asked.</p>'
    return "\n        ".join(
        f'<article class="qotw-archive-card" data-episode="{question.episode}">'
        f'<div class="community-card-heading"><span class="card-kicker">{html.escape(question.id)}</span><span class="qotw-status qotw-status-closed">CLOSED</span></div>'
        f'<h3 class="qotw-archive-title">{html.escape(question.text)}</h3>'
        f'<p class="qotw-metadata">{_metadata(question)}</p>'
        f'<div class="qotw-answers-slot" data-episode="{question.episode}" hidden></div>'
        '</article>'
        for question in archive
    )


def render_without_question(entries: list[tuple[int, str]]) -> str:
    if not entries:
        return ""
    rows = "".join(f"<p>{_episode_link(number, title)}</p>" for number, title in entries)
    return f'<div class="qotw-no-question-history"><h3>Episodes without a question on record</h3>{rows}</div>'


def render_page(state: QotwState) -> str:
    return f'''<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <meta name="theme-color" content="#07111f" />
    <meta name="description" content="Read the current Holotable Chaos Question of the Week and browse past questions." />
    <title>Question of the Week — Holotable Chaos</title>
    <link rel="stylesheet" href="../styles.css" />
  </head>
  <body>
    <header class="site-header">
      <a class="brand" href="../index.html" aria-label="Holotable Chaos home"><span class="brand-mark" aria-hidden="true">HC</span><span class="brand-name">HOLOTABLE <b>CHAOS</b></span></a>
      <nav aria-label="Main navigation"><a href="../podcast/index.html">Podcast</a><a href="../resources/index.html">SWGoH Resources</a><a href="index.html">Community</a><a href="../about/index.html">About</a></nav>
      <a class="discord-link" href="https://discord.gg/4HNxXZBkbf" target="_blank" rel="noopener noreferrer"><span class="discord-link-extra">Join our </span>Discord <span aria-hidden="true">↗</span></a><div class="account-slot" data-admin-href="../admin/index.html"><a class="account-link" href="../account/index.html">Sign in</a></div>
    </header>
    <main>
      <section class="page-intro"><p class="eyebrow"><span></span> THE COMMUNITY / LISTENER QUESTION</p><h1>Question of the <em>week.</em></h1><p>Every episode ends with a new question for listeners. Answer this week’s question below, or browse the questions from past episodes.</p></section>
      <section class="qotw-page-content" aria-label="Question of the Week">{render_current(state.current)}
        <section class="qotw-me" id="qotw-me" aria-labelledby="qotw-me-title" hidden></section>
        <section class="qotw-archive" aria-labelledby="qotw-archive-title"><div class="section-heading"><div><p class="eyebrow">FROM THE ARCHIVE</p><h2 id="qotw-archive-title">Past <em>questions.</em></h2></div><p>Newest first. Past questions are closed to new answers through the website.</p></div><div class="qotw-archive-list">{render_archive(state.archive)}</div>{render_without_question(state.without_question)}</section>
      </section>
    </main>
    <footer><a class="brand" href="../index.html"><span class="brand-mark" aria-hidden="true">HC</span><span class="brand-name">HOLOTABLE <b>CHAOS</b></span></a><span>Because Nothing Ever Goes to Plan</span><span class="footer-links"><a href="../privacy/index.html">Privacy</a> · <a href="../terms/index.html">Terms</a></span><span>© 2026 Holotable Chaos</span></footer>
    <script src="../assets/js/supabase-config.js" defer></script><script src="../assets/js/account-core.js" defer></script><script src="../assets/js/site-header.js" defer></script><script src="../assets/js/beta-notice.js" defer></script>
    <script src="../assets/js/edit-mode.js" defer></script><script src="qotw.js" defer></script>
  </body>
</html>
'''


# ------------------------------------------------------------------------- write


def _write_if_changed(path: Path, text: str) -> bool:
    if path.exists() and path.read_text(encoding="utf-8") == text:
        return False
    temporary_name: str | None = None
    try:
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", newline="\n", dir=path.parent, delete=False) as temporary:
            temporary.write(text)
            temporary_name = temporary.name
        os.replace(temporary_name, path)
    except OSError:
        if temporary_name:
            try:
                os.unlink(temporary_name)
            except OSError:
                pass
        raise
    return True


def _with_marker_block(path: Path, markers: tuple[str, str], content: str) -> str:
    source = path.read_text(encoding="utf-8")
    start_marker, end_marker = markers
    if source.count(start_marker) != 1 or source.count(end_marker) != 1 or source.index(end_marker) < source.index(start_marker):
        raise ContentError(f"{path.name} needs exactly one correctly ordered pair of QotW markers.")
    start = source.index(start_marker) + len(start_marker)
    end = source.index(end_marker)
    return source[:start] + "\n          " + content + "\n          " + source[end:]


def render_feed(state: QotwState) -> str:
    """Public question feed (community/qotw.json) that the database syncs from. Public data only."""
    questions = ([state.current] if state.current else []) + list(state.archive)
    feed = {
        "schema": 1,
        "current_episode": state.current.episode if state.current else None,
        "questions": [
            {"episode": q.episode, "episode_title": q.episode_title, "text": q.text, "published_at": q.published_at}
            for q in sorted(questions, key=lambda q: q.episode)
        ],
    }
    return json.dumps(feed, ensure_ascii=False, indent=2) + "\n"


def build_site(payload: dict[str, Any], episodes: list[dict[str, Any]], project_root: Path = ROOT) -> tuple[QotwState, list[Path]]:
    """Write the page and both previews. Returns the state and the files that changed."""
    state = resolve(payload, episodes)
    home = project_root / "index.html"
    community = project_root / "community" / "index.html"
    # Render everything before writing anything, so a marker problem changes no files.
    outputs = {
        home: _with_marker_block(home, HOME_MARKERS, render_home_card(state.current)),
        community: _with_marker_block(community, COMMUNITY_MARKERS, render_community_card(state.current)),
        project_root / "community" / "question-of-the-week.html": render_page(state),
        project_root / "community" / "qotw.json": render_feed(state),
    }
    changed = [path for path, text in outputs.items() if _write_if_changed(path, text)]
    return state, changed


def _report_warnings(warnings: list[str]) -> None:
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    for warning in warnings:
        print(f"Warning: {warning}", file=sys.stderr)
        if os.environ.get("GITHUB_ACTIONS") == "true":
            print(f"::warning title=Question of the Week::{warning}")
    if summary_path and warnings:
        with open(summary_path, "a", encoding="utf-8") as summary:
            summary.write("### ⚠️ Question of the Week\n\n" + "".join(f"- {warning}\n" for warning in warnings) + "\n")


def main() -> int:
    argparse.ArgumentParser(description=__doc__.splitlines()[0]).parse_args()
    try:
        state, changed = build_site(load_content(), load_episodes())
    except (ContentError, OSError) as exc:
        print(f"QotW build failed; no files were changed: {exc}", file=sys.stderr)
        return 1
    _report_warnings(state.warnings)
    current = f"{state.current.id} (episode {state.current.episode})" if state.current else "none"
    status = "Updated " + ", ".join(str(p.relative_to(ROOT)) for p in changed) if changed else "No changes"
    print(f"Open question: {current}. {status}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
