// Admin dashboard additions: QotW answers (feature, CSV), roster requests (status, CSV), overview
// counts, alert status and the owner's "Export everything". Permissions are enforced by the database.
(() => {
  "use strict";
  const STATUSES = ["received", "queued", "reviewed", "aired", "declined", "closed"];
  const STATUS_LABEL = { received: "Received", queued: "In the queue", reviewed: "Reviewed", aired: "Aired", declined: "Not selected", closed: "Closed" };

  // Overview counts (called by admin.js).
  window.HCAdminStats = async (client) => {
    const { data } = await client.rpc("admin_content_counts");
    if (!data) return [];
    return [["QotW answers", data.answers], ["Answers to the open question", data.answers_open_question],
            ["Open roster requests", data.roster_open], ["Requests to triage", data.roster_received]];
  };

  // CSV with formula-injection protection (cells starting with = + - @ are prefixed with ').
  function csv(rows, columns) {
    const cell = (value) => {
      let text = value === null || value === undefined ? "" : String(value);
      if (/^[=+\-@\t\r]/.test(text)) text = `'${text}`;
      return /[",\n\r]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text;
    };
    return [columns.map(([label]) => cell(label)).join(","), ...rows.map((row) => columns.map(([, get]) => cell(get(row))).join(","))].join("\r\n");
  }
  function download(name, text, type) {
    const blob = new Blob([text], { type });
    const link = document.createElement("a");
    link.href = URL.createObjectURL(blob);
    link.download = name;
    document.body.append(link);
    link.click();
    link.remove();
    setTimeout(() => URL.revokeObjectURL(link.href), 1000);
  }
  const stamp = () => new Date().toISOString().slice(0, 10);

  window.addEventListener("hc-admin-ready", () => {
    const { client, rpc, el, A, state, addTab } = window.HCAdmin;

    // ---------- overview additions ----------
    (async () => {
      const overview = document.getElementById("panel-overview");
      const { data: alerts } = await client.rpc("admin_alerts_configured");
      const extras = el("div", { className: "admin-subsection" }, [
        el("h3", { text: "Discord alerts" }),
        el("p", { className: "panel-lead", id: "admin-alerts-status", text: alerts
          ? "On: new answers and roster requests are posted to the admin channel."
          : "Off: no webhook is set yet, so new submissions aren't posted to Discord. Everything else works." }),
      ]);
      if (state.isOwner) {
        const status = el("p", { className: "save-status", role: "status", "aria-live": "polite" });
        extras.append(el("h3", { text: "Export everything" }),
          el("p", { className: "panel-lead", text: "One JSON file with everything the site stores (accounts, profiles, answers, requests, audit log). The moderation lists are never included. The export is recorded in the audit log." }),
          el("div", { className: "form-actions" }, [el("button", { type: "button", className: "button button-outline", id: "export-everything", text: "Export everything",
            onclick: async () => {
              const { ok, data } = await rpc("admin_export_everything");
              if (!ok) return;
              download(`holotable-chaos-export-${stamp()}.json`, JSON.stringify(data, null, 2), "application/json");
              status.textContent = "Export downloaded.";
              status.dataset.kind = "success";
            } }), status]));
      }
      overview.append(extras);
    })();

    // ---------- QotW answers ----------
    addTab("qotw", "QotW answers", async (panel) => {
      const { data: questions } = await client.from("qotw_questions").select("episode, question, closed_at").order("episode", { ascending: false });
      const picker = el("select", { id: "admin-qotw-question" }, [
        el("option", { value: "", text: "All questions" }),
        ...(questions || []).map((q) => el("option", { value: String(q.episode), text: `QotW #${q.episode}${q.closed_at ? "" : " (open)"}: ${q.question.slice(0, 60)}` })),
      ]);
      const list = el("ol", { className: "qotw-answer-list admin-answer-list", id: "admin-answer-list" });
      const status = el("p", { className: "save-status", role: "status", "aria-live": "polite" });
      let rows = [];
      async function load() {
        const episode = picker.value ? Number(picker.value) : null;
        const { ok, data } = await rpc("admin_answers_export", { p_episode: episode });
        if (!ok) return;
        rows = data || [];
        A.fill(list, ...(rows.length ? rows.map((row) => {
          const feature = el("button", { type: "button", className: `button button-outline${row.featured ? " is-active" : ""}`, "aria-pressed": String(row.featured),
            text: row.featured ? "Featured ✓" : "Feature",
            onclick: async () => {
              const result = await rpc("admin_feature_answer", { p_answer: row.id, p_featured: !row.featured });
              if (!result.ok) return;
              row.featured = !row.featured;
              feature.setAttribute("aria-pressed", String(row.featured));
              feature.textContent = row.featured ? "Featured ✓" : "Feature";
              feature.classList.toggle("is-active", row.featured);
              status.textContent = row.featured ? "Answer featured." : "Feature removed.";
              status.dataset.kind = "success";
            } });
          return el("li", { className: `qotw-answer-item${row.featured ? " is-featured" : ""}` }, [
            el("div", { className: "qotw-answer-head" }, [A.personChip(row.author, { size: 32 }),
              el("span", { className: "card-kicker", text: `QOTW #${row.episode}${row.open ? " · OPEN" : ""}` })]),
            el("p", { className: "qotw-answer-body", text: row.answer }),
            el("div", { className: "admin-row-actions" }, [el("span", { className: "field-help", text: `${row.votes} upvote${row.votes === 1 ? "" : "s"} · ${A.formatDate(row.updated_at)}` }), feature,
              el("button", { type: "button", className: "button button-outline button-danger", text: "Delete", "aria-label": `Delete ${A.displayName(row.author)}'s answer to QotW #${row.episode}`,
                onclick: async () => {
                  const go = await window.HCEdit.confirm({ title: "Delete this answer?", danger: true, confirmLabel: "Delete", cancelLabel: "Cancel",
                    message: `This permanently deletes ${A.displayName(row.author)}'s answer to QotW #${row.episode}, including its upvotes. It can't be undone, and nobody is notified.` });
                  if (!go) return;
                  const result = await rpc("admin_delete_answer", { p_answer: row.id });
                  if (!result.ok) return;
                  status.textContent = "Answer deleted.";
                  status.dataset.kind = "success";
                  load();
                } })]),
          ]);
        }) : [el("li", { className: "empty-note", text: "No answers yet." })]));
      }
      picker.addEventListener("change", load);
      A.fill(panel, 
        el("h2", { text: "QotW answers" }),
        el("p", { className: "panel-lead", text: "Admins can read answers to the open question; listeners see others' answers only after it closes. Featured answers show first and get a badge." }),
        el("div", { className: "roster-form-grid" }, [el("div", { className: "form-field" }, [el("label", { for: "admin-qotw-question", text: "Question" }), picker])]),
        el("div", { className: "form-actions" }, [el("button", { type: "button", className: "button button-outline", id: "admin-answers-csv", text: "Download CSV",
          onclick: () => download(`qotw-answers-${picker.value || "all"}-${stamp()}.csv`, csv(rows, [
            ["Question", (r) => `QotW #${r.episode}`], ["Question text", (r) => r.question], ["Listener", (r) => r.author.name], ["Answer", (r) => r.answer],
            ["Featured", (r) => (r.featured ? "yes" : "no")], ["Upvotes", (r) => r.votes], ["Created", (r) => r.created_at], ["Updated", (r) => r.updated_at],
          ]), "text/csv;charset=utf-8") }), status]),
        list,
      );
      await load();
    });

    // ---------- roster requests ----------
    addTab("roster", "Roster requests", async (panel) => {
      const filter = el("select", { id: "admin-roster-filter" }, [
        el("option", { value: "open", text: "Open (received, queued, reviewed)" }), el("option", { value: "", text: "All" }),
        ...STATUSES.map((s) => el("option", { value: s, text: STATUS_LABEL[s] })),
      ]);
      const list = el("ul", { className: "admin-list", id: "admin-roster-list" });
      const status = el("p", { className: "save-status", role: "status", "aria-live": "polite" });
      let rows = [];
      async function load() {
        const { ok, data } = await rpc("admin_roster_requests", { p_status: filter.value || null });
        if (!ok) return;
        rows = data || [];
        A.fill(list, ...(rows.length ? rows.map((row) => {
          const id = row.id.slice(0, 8);
          const select = el("select", { id: `rr-status-${id}`, "aria-label": "New status" }, STATUSES.map((s) => el("option", { value: s, text: STATUS_LABEL[s], selected: s === row.status })));
          const episode = el("input", { id: `rr-episode-${id}`, type: "number", min: "1", inputmode: "numeric", placeholder: "Episode", value: row.aired_episode || "", "aria-label": "Aired in episode" });
          return el("li", { className: "admin-row admin-roster-row" }, [
            el("div", { className: "admin-row-main" }, [
              A.personChip(row.author, { detail: `Sent ${A.formatDate(row.created_at)} · ${STATUS_LABEL[row.status]}${row.aired_episode ? ` in episode ${row.aired_episode}` : ""}` }),
              el("dl", { className: "detail-list" }, [
                el("dt", {}, ["Ally code", el("span", { className: "unverified-tag", text: "Self-reported" })]), el("dd", { text: A.formatAllyCode(row.ally_code) }),
                el("dt", { text: "SWGOH.GG" }), el("dd", {}, [row.swgoh_gg_url && A.isSwgohGgUrl(row.swgoh_gg_url)
                  ? el("a", { className: "card-link", href: row.swgoh_gg_url, target: "_blank", rel: "noopener noreferrer", text: row.swgoh_gg_url }) : "—"]),
                el("dt", { text: "In-game name" }), el("dd", { text: row.in_game_name || "—" }),
                el("dt", { text: "Goals" }), el("dd", { className: "detail-bio", text: row.goals }),
                el("dt", { text: "Current projects" }), el("dd", { className: "detail-bio", text: row.current_projects || "—" }),
              ]),
            ]),
            el("div", { className: "admin-roster-controls" }, [
              el("div", { className: "form-field" }, [el("label", { for: select.id, text: "Status" }), select]),
              el("div", { className: "form-field" }, [el("label", { for: episode.id, text: "Aired in episode" }), episode]),
              el("button", { type: "button", className: "button button-primary", text: "Update", onclick: async () => {
                const ep = Number.parseInt(episode.value, 10);
                const result = await rpc("admin_set_roster_status", { p_request: row.id, p_status: select.value, p_aired_episode: Number.isFinite(ep) ? ep : null });
                if (!result.ok) return;
                status.textContent = `Status updated to ${STATUS_LABEL[select.value]}.`;
                status.dataset.kind = "success";
                load();
              } }),
              el("button", { type: "button", className: "button button-outline button-danger", text: "Delete request", "aria-label": `Delete ${A.displayName(row.author)}'s roster request`,
                onclick: async () => {
                  const go = await window.HCEdit.confirm({ title: "Delete this roster request?", danger: true, confirmLabel: "Delete", cancelLabel: "Cancel",
                    message: `This permanently deletes ${A.displayName(row.author)}'s roster review request (status: ${STATUS_LABEL[row.status]}). It can't be undone, and nobody is notified.` });
                  if (!go) return;
                  const result = await rpc("admin_delete_roster_request", { p_request: row.id });
                  if (!result.ok) return;
                  status.textContent = "Request deleted.";
                  status.dataset.kind = "success";
                  load();
                } }),
            ]),
          ]);
        }) : [el("li", { className: "empty-note", text: "No requests here." })]));
      }
      filter.addEventListener("change", load);
      A.fill(panel, 
        el("h2", { text: "Roster requests" }),
        el("p", { className: "panel-lead", text: "Move requests through received, queued, reviewed and aired (with the episode number), or decline or close them. Listeners see the status on their account and the roster page. Every change is audited." }),
        el("div", { className: "roster-form-grid" }, [el("div", { className: "form-field" }, [el("label", { for: "admin-roster-filter", text: "Show" }), filter])]),
        el("div", { className: "form-actions" }, [el("button", { type: "button", className: "button button-outline", id: "admin-roster-csv", text: "Download CSV",
          onclick: () => download(`roster-requests-${filter.value || "all"}-${stamp()}.csv`, csv(rows, [
            ["Listener", (r) => r.author.name], ["Ally code (self-reported)", (r) => A.formatAllyCode(r.ally_code)], ["SWGOH.GG", (r) => r.swgoh_gg_url],
            ["In-game name", (r) => r.in_game_name], ["Goals", (r) => r.goals], ["Current projects", (r) => r.current_projects],
            ["Status", (r) => STATUS_LABEL[r.status]], ["Aired episode", (r) => r.aired_episode], ["Sent", (r) => r.created_at], ["Status changed", (r) => r.status_changed_at],
          ]), "text/csv;charset=utf-8") }), status]),
        list,
      );
      await load();
    });
  });
})();
