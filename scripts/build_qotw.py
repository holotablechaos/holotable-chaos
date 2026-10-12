#!/usr/bin/env python3
"""Render the static Question of the Week pages from content/qotw.json."""

from __future__ import annotations

import argparse
import html
import json
import os
import re
import sys
import tempfile
from pathlib import Path
from urllib.parse import quote
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
CONTENT_PATH = ROOT / "content" / "qotw.json"
QUESTION_PAGE = ROOT / "community" / "question-of-the-week.html"
OUTPUTS = {
    ROOT / "index.html": ("<!-- QOTW_HOME_START -->", "<!-- QOTW_HOME_END -->"),
    ROOT / "community" / "index.html": ("<!-- QOTW_COMMUNITY_START -->", "<!-- QOTW_COMMUNITY_END -->"),
}
RECIPIENT = "holotablechaos@gmail.com"


class ContentError(ValueError):
    pass


def load_content(path: Path = CONTENT_PATH) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ContentError(f"Could not read Question of the Week content: {exc}") from exc
    if not isinstance(payload, dict) or not isinstance(payload.get("questions"), list):
        raise ContentError("Content must contain a questions array.")
    return payload


def validate_content(payload: dict[str, Any]) -> tuple[list[dict[str, Any]], dict[str, Any] | None]:
    questions = payload.get("questions")
    if not isinstance(questions, list):
        raise ContentError("Content must contain a questions array.")
    known_statuses = {"current", "closed", "draft"}
    seen_ids: set[str] = set()
    currents = []
    normalized = []
    for index, entry in enumerate(questions):
        if not isinstance(entry, dict):
            raise ContentError(f"Question record {index + 1} must be an object.")
        identifier = entry.get("id")
        text = entry.get("text")
        status = entry.get("status")
        if not isinstance(identifier, str) or not identifier.strip():
            raise ContentError(f"Question record {index + 1} needs a permanent ID.")
        if identifier in seen_ids:
            raise ContentError(f"Duplicate permanent question ID: {identifier}")
        seen_ids.add(identifier)
        if not isinstance(text, str):
            raise ContentError(f"Question {identifier} must have a text string; use an empty string while it is unknown.")
        if status not in known_statuses:
            raise ContentError(f"Question {identifier} has invalid status {status!r}; use current, closed, or draft.")
        if entry.get("episode") is not None and (not isinstance(entry["episode"], int) or entry["episode"] < 1):
            raise ContentError(f"Question {identifier} has invalid episode metadata.")
        if entry.get("episode") is not None and identifier != f"QotW #{entry['episode']}":
            raise ContentError(f"Question {identifier} must retain the permanent ID QotW #{entry['episode']} for its episode.")
        if entry.get("episode_title") is not None and not isinstance(entry["episode_title"], str):
            raise ContentError(f"Question {identifier} has invalid episode title metadata.")
        if entry.get("date") is not None and not isinstance(entry["date"], str):
            raise ContentError(f"Question {identifier} has invalid date metadata.")
        normalized.append(entry)
        if status == "current":
            currents.append(entry)
    if len(currents) > 1:
        raise ContentError("More than one question is marked current. Choose one current question before building the site.")
    no_question_episodes = payload.get("episode_history", [])
    if not isinstance(no_question_episodes, list):
        raise ContentError("Episode history must be a list.")
    seen_episodes = {entry.get("episode") for entry in normalized if entry.get("episode") is not None}
    for entry in no_question_episodes:
        if not isinstance(entry, dict) or not isinstance(entry.get("episode"), int) or entry["episode"] < 1:
            raise ContentError("Each episode history entry needs a positive episode number.")
        if not isinstance(entry.get("title"), str) or not entry["title"].strip():
            raise ContentError(f"Episode {entry['episode']} needs a title.")
        if entry.get("qotw_id") is not None:
            raise ContentError(f"Episode {entry['episode']} is listed as no-question but has a QotW ID.")
        if entry["episode"] in seen_episodes:
            raise ContentError(f"Episode {entry['episode']} appears more than once in the QotW history.")
        seen_episodes.add(entry["episode"])
    return normalized, currents[0] if currents else None


def activate_draft(payload: dict[str, Any], identifier: str) -> dict[str, Any]:
    """Publish a draft and close the previous current question in one content update."""
    questions, current = validate_content(payload)
    target = next((entry for entry in questions if entry["id"] == identifier), None)
    if target is None:
        raise ContentError(f"No question with ID {identifier!r} exists.")
    if target.get("status") != "draft":
        raise ContentError("Only a draft can be activated; closed questions are never reopened by the publish command.")
    if not target.get("text", "").strip():
        raise ContentError("Add the full question text before publishing this draft.")
    if current:
        current["status"] = "closed"
    target["status"] = "current"
    return payload


def email_body(question: dict[str, Any]) -> str:
    return (
        f"Permanent question ID: {question['id']}\n\n"
        f"Question:\n{question['text'].strip()}\n\n"
        "In-game name (optional):\n\n\n"
        "Your answer:\n"
    )


def mailto_url(question: dict[str, Any]) -> str:
    subject = f"Holotable Chaos {question['id']} Submission"
    return f"mailto:{RECIPIENT}?subject={quote(subject, safe='')}&body={quote(email_body(question), safe='')}"


def _excerpt(value: str, limit: int = 160) -> str:
    text = " ".join(value.split())
    if len(text) <= limit:
        return text
    return text[: limit - 1].rsplit(" ", 1)[0].rstrip(" .,;:") + "…"


def _status_text(current: dict[str, Any] | None, error: str | None) -> tuple[str, str]:
    if error:
        return "Configuration issue", "QotW is unavailable until the content is corrected."
    if current is None:
        return "No active question", "There is no open Question of the Week right now."
    if not current.get("text", "").strip():
        return "Question text needed", f"Add the full question text for {current['id']} in content/qotw.json."
    return current["id"], current["text"]


def render_home_card(current: dict[str, Any] | None, error: str | None = None) -> str:
    label, preview = _status_text(current, error)
    state = "CONFIGURATION ISSUE" if error else ("OPEN" if current else "CLOSED")
    if current and not current.get("text", "").strip() and not error:
        state = "OPEN · TEXT NEEDED"
    return (
        '<article class="community-card qotw-community-card">'
        '<div class="community-card-heading"><span class="card-kicker">QUESTION OF THE WEEK</span>'
        f'<span class="qotw-status">{html.escape(state)}</span></div>'
        f'<h3>{html.escape(label)}</h3><p>{html.escape(_excerpt(preview))}</p>'
        '<a class="card-link" href="community/question-of-the-week.html">View the question and archive <span>↗</span></a>'
        '</article>'
    )


def render_community_card(current: dict[str, Any] | None, error: str | None = None) -> str:
    label, preview = _status_text(current, error)
    state = "CONFIGURATION ISSUE" if error else ("OPEN" if current else "NO ACTIVE QUESTION")
    if current and not current.get("text", "").strip() and not error:
        state = "OPEN · TEXT NEEDED"
    return (
        '<article class="community-card qotw-community-card" id="question-of-the-week">'
        '<div class="community-card-heading"><span class="card-kicker">LISTENER QUESTION</span>'
        f'<span class="qotw-status">{html.escape(state)}</span></div>'
        f'<h2>Question of the Week</h2><p class="qotw-preview"><strong>{html.escape(label)}</strong><br />{html.escape(_excerpt(preview))}</p>'
        '<a class="card-link" href="question-of-the-week.html">View the question and archive <span>↗</span></a>'
        '</article>'
    )


def render_archive(questions: list[dict[str, Any]], current: dict[str, Any] | None, error: str | None) -> str:
    archived = [entry for entry in questions if entry.get("status") == "closed"]
    if not archived:
        return '<p class="qotw-empty-archive">Past questions will appear here when they are added to the content archive.</p>'
    cards = []
    for entry in archived:
        identifier = html.escape(entry["id"])
        episode = entry.get("episode")
        episode_title = entry.get("episode_title")
        episode_note = (
            f'<p class="qotw-metadata">Episode {int(episode)} · <a href="../podcast/episodes/episode-{int(episode)}.html">{html.escape(episode_title or f"Episode {int(episode)}")}</a></p>'
            if episode
            else (f'<p class="qotw-metadata">Date: {html.escape(entry["date"])}</p>' if entry.get("date") else "")
        )
        cards.append(
            '<article class="qotw-archive-card">'
            f'<div class="community-card-heading"><span class="card-kicker">ARCHIVE ID: {identifier}</span><span class="qotw-status qotw-status-closed">CLOSED</span></div>'
            f'<h3 class="qotw-archive-title">{html.escape(episode_title or "")}</h3>'
            f'<p class="qotw-archive-question">{html.escape(entry["text"])}</p>{episode_note}'
            '</article>'
        )
    return "\n        ".join(cards)


def render_page(questions: list[dict[str, Any]], current: dict[str, Any] | None, error: str | None = None, episode_history: list[dict[str, Any]] | None = None) -> str:
    archive = render_archive(questions, current, error)
    no_question_history = episode_history or []
    no_question_html = ""
    if no_question_history:
        no_question_html = '<div class="qotw-no-question-history"><h3>Episodes without a Question of the Week</h3>' + "".join(
            f'<p>Episode {int(entry["episode"])} — {html.escape(entry["title"])} · No QotW</p>'
            for entry in sorted(no_question_history, key=lambda item: item["episode"])
        ) + "</div>"
    if error:
        prompt = (
            '<section class="qotw-current qotw-error" aria-labelledby="current-question-title">'
            '<span class="qotw-status qotw-status-closed">CONFIGURATION ERROR</span>'
            '<h2 id="current-question-title">Question settings need attention</h2>'
            f'<p>{html.escape(error)}</p><p>No answer email link is available while the settings are ambiguous.</p></section>'
        )
    elif current is None:
        prompt = (
            '<section class="qotw-current" aria-labelledby="current-question-title">'
            '<span class="qotw-status qotw-status-closed">NO ACTIVE QUESTION</span>'
            '<h2 id="current-question-title">Check back for the next question.</h2>'
            '<p>There is no open Question of the Week right now. Previously featured questions remain below for browsing.</p></section>'
        )
    else:
        identifier = html.escape(current["id"])
        text = current.get("text", "").strip()
        if text:
            submission = (
                f'<a class="button button-primary qotw-submit" href="{html.escape(mailto_url(current), quote=True)}">'
                'Submit Your Answer <span aria-hidden="true">→</span></a>'
                '<p class="qotw-send-note">This opens your email application. Review the message and send it yourself; answers are not submitted automatically.</p>'
                f'<details class="qotw-email-fallback"><summary>If you don’t have an email app configured</summary>'
                f'<p>To: <strong>{RECIPIENT}</strong><br />Subject: <strong>Holotable Chaos {identifier} Submission</strong></p>'
                '<p>Copy the message below into a new email to the address above with the subject shown.</p>'
                f'<textarea rows="10" readonly aria-label="Copyable answer email">{html.escape(email_body(current))}</textarea></details>'
            )
            question_content = html.escape(text)
        else:
            submission = (
                '<button class="button button-primary qotw-submit" type="button" disabled>Submit Your Answer</button>'
                f'<p class="qotw-send-note">The question text for {identifier} has not been added yet. The answer button will be available after you fill in its <code>text</code> field in <code>content/qotw.json</code>.</p>'
            )
            question_content = (
                f'<p class="qotw-question-needed"><strong>Question text needed.</strong> Add the full wording for {identifier} in <code>content/qotw.json</code>.</p>'
            )
        metadata = []
        if current.get("episode"):
            episode_title = html.escape(current.get("episode_title", ""))
            metadata.append(f'<span>Episode {int(current["episode"])} · {episode_title}</span>')
        if current.get("date"):
            metadata.append(f'<time datetime="{html.escape(current["date"], quote=True)}">{html.escape(current["date"])}</time>')
        metadata_html = f'<p class="qotw-current-metadata">{" · ".join(metadata)}</p>' if metadata else ""
        prompt = (
            '<section class="qotw-current" aria-labelledby="current-question-title">'
            f'<div class="community-card-heading"><span class="card-kicker">PERMANENT ID: {identifier}</span><span class="qotw-status">OPEN</span></div>'
            f'<h2 id="current-question-title">{identifier}</h2><div class="qotw-question-text">{question_content}</div>'
            f'{metadata_html}<p class="qotw-feature-note">Your answer may be discussed or featured in a future Holotable Chaos podcast episode.</p>{submission}</section>'
        )
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
      <a class="discord-link" href="https://discord.gg/4HNxXZBkbf" target="_blank" rel="noopener noreferrer">Join our Discord <span aria-hidden="true">↗</span></a>
    </header>
    <main>
      <section class="page-intro"><p class="eyebrow"><span></span> THE COMMUNITY / LISTENER QUESTION</p><h1>Question of the <em>week.</em></h1><p>Answer the open question or browse past prompts from the show. Closed questions remain here as an archive and are no longer accepting answers through this page.</p></section>
      <section class="qotw-page-content" aria-label="Question of the Week">{prompt}
        <section class="qotw-archive" aria-labelledby="qotw-archive-title"><div class="section-heading"><div><p class="eyebrow">FROM THE ARCHIVE</p><h2 id="qotw-archive-title">Past <em>questions.</em></h2></div><p>Past questions are available to browse, but are no longer accepting submissions through the website.</p></div><div class="qotw-archive-list">{archive}</div>{no_question_html}</section>
      </section>
    </main>
    <footer><a class="brand" href="../index.html"><span class="brand-mark" aria-hidden="true">HC</span><span class="brand-name">HOLOTABLE <b>CHAOS</b></span></a><span>Because Nothing Ever Goes to Plan</span><span>© 2026 Holotable Chaos</span></footer>
  </body>
</html>
'''


def _write_atomic(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
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


def _replace_marker_block(path: Path, start_marker: str, end_marker: str, content: str) -> None:
    current = path.read_text(encoding="utf-8")
    if current.count(start_marker) != 1 or current.count(end_marker) != 1:
        raise ContentError(f"{path.relative_to(ROOT)} needs exactly one pair of QotW content markers.")
    start = current.index(start_marker) + len(start_marker)
    end = current.index(end_marker)
    if end < start:
        raise ContentError(f"QotW content markers are out of order in {path.relative_to(ROOT)}.")
    _write_atomic(path, current[:start] + "\n          " + content + "\n          " + current[end:])


def build_site(payload: dict[str, Any], project_root: Path = ROOT) -> str | None:
    """Generate three static views; invalid current state is rendered safely and returned as an error."""
    try:
        questions, current = validate_content(payload)
        error = None
        episode_history = payload.get("episode_history", [])
    except ContentError as exc:
        questions = [entry for entry in payload.get("questions", []) if isinstance(entry, dict) and entry.get("status") == "closed" and isinstance(entry.get("id"), str) and isinstance(entry.get("text"), str)]
        current = None
        error = str(exc)
        episode_history = payload.get("episode_history", []) if isinstance(payload.get("episode_history", []), list) else []
    output_paths = {
        project_root / "index.html": OUTPUTS[ROOT / "index.html"],
        project_root / "community" / "index.html": OUTPUTS[ROOT / "community" / "index.html"],
    }
    # Validate every destination before writing any generated output.
    for path, markers in output_paths.items():
        source = path.read_text(encoding="utf-8")
        if source.count(markers[0]) != 1 or source.count(markers[1]) != 1 or source.index(markers[1]) < source.index(markers[0]):
            raise ContentError(f"{path.relative_to(project_root)} needs one correctly ordered QotW marker pair.")
    _replace_marker_block(project_root / "index.html", *OUTPUTS[ROOT / "index.html"], render_home_card(current, error))
    _replace_marker_block(project_root / "community" / "index.html", *OUTPUTS[ROOT / "community" / "index.html"], render_community_card(current, error))
    _write_atomic(project_root / "community" / "question-of-the-week.html", render_page(questions, current, error, episode_history))
    return error


def save_payload(payload: dict[str, Any], path: Path = CONTENT_PATH) -> None:
    _write_atomic(path, json.dumps(payload, ensure_ascii=False, indent=2) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser(description="Build the static Holotable Chaos Question of the Week pages.")
    parser.add_argument("--activate", metavar="ID", help="Activate a draft ID and automatically close the previous current question.")
    args = parser.parse_args()
    try:
        payload = load_content()
        if args.activate:
            payload = activate_draft(payload, args.activate)
            save_payload(payload)
        error = build_site(payload)
    except (ContentError, OSError) as exc:
        print(f"QotW build failed safely: {exc}", file=sys.stderr)
        return 1
    if error:
        print(f"QotW build wrote a safe configuration-error state: {error}", file=sys.stderr)
        return 1
    print("Generated the Question of the Week page and refreshed its homepage and Community cards.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
