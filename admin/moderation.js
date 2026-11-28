// Moderation tab: filter tester, list management (blocked terms, allowlist, reserved names) and,
// for the owner, display-name lookup/reclaim and reserved-name exceptions. Every change is audited
// by the database functions; this file only draws the controls.
(() => {
  "use strict";
  const CATEGORIES = ["profanity", "slur", "sexual", "sexual_violence", "harassment", "self_harm", "hate_symbol", "other"];
  const LISTS = {
    blocked: { label: "Blocked terms", matchTypes: ["word", "substring", "phrase"], categories: true },
    allowed: { label: "Allowlist", matchTypes: null, categories: false },
    reserved: { label: "Reserved names", matchTypes: ["word", "contains"], categories: false },
  };
  const pretty = (value) => String(value || "").replace(/_/g, " ");

  window.HCModeration = async function render(panel, ctx) {
    const { client, rpc, el, A, state } = ctx;
    let current = "blocked";
    let rows = [];

    const select = (id, values, includeKeep) => el("select", { id }, [
      includeKeep ? el("option", { value: "", text: "Keep as is" }) : null,
      ...values.map((value) => el("option", { value, text: pretty(value) })),
    ]);

    // ---------- tester ----------
    const testInput = el("textarea", { id: "mod-test-text", rows: "3", placeholder: "Paste any text to see whether it would be blocked" });
    const asName = el("input", { type: "checkbox", id: "mod-test-name" });
    const testResult = el("div", { className: "mod-test-result", role: "status", "aria-live": "polite" });
    async function runTest() {
      const text = testInput.value;
      if (!text.trim()) { testResult.replaceChildren(); return; }
      const { ok, data } = await rpc("admin_test_text", { p_text: text, p_as_name: asName.checked });
      if (!ok) return;
      const reasons = [
        ...data.blocked_terms.map((m) => `Blocked term "${m.term}" (${pretty(m.match_type)}, ${pretty(m.category)})`),
        data.reserved_name ? "Matches a reserved name (allowed only for the owner, admins and excepted accounts)" : null,
        data.name_taken ? "As a display name: already taken" : null,
      ].filter(Boolean);
      testResult.replaceChildren(
        el("p", { className: `status-pill${data.blocked ? " is-banned" : ""}`, text: data.blocked ? "Would be blocked" : "Allowed" }),
        reasons.length ? el("ul", { className: "account-list" }, reasons.map((r) => el("li", { text: r }))) : null,
        el("p", { className: "field-help", text: `Normalised: "${data.normalized || ""}" · name key: "${data.name_key || ""}"` }),
      );
    }
    const tester = el("section", { className: "admin-subsection mod-section", "aria-labelledby": "mod-test-title" }, [
      el("h3", { id: "mod-test-title", text: "Test the filter" }),
      el("div", { className: "form-field" }, [el("label", { for: "mod-test-text", text: "Text" }), testInput]),
      el("label", { className: "mod-check" }, [asName, " Check it as a display or in-game name (reserved names, already taken)"]),
      el("div", { className: "form-actions" }, [el("button", { type: "button", className: "button button-primary", text: "Test", onclick: runTest })]),
      testResult,
    ]);

    // ---------- counts ----------
    const counts = el("div", { className: "stat-grid" });
    async function loadCounts() {
      const { ok, data } = await rpc("admin_moderation_counts");
      if (!ok) return;
      const tiles = [
        ...Object.entries(data.blocked_by_category || {}).map(([k, v]) => [pretty(k), v]),
        ["allowlist", data.allowed], ["reserved names", data.reserved], ["name exceptions", data.name_exceptions],
      ];
      counts.replaceChildren(...tiles.map(([label, value]) => el("div", { className: "stat-tile" }, [
        el("span", { className: "stat-value", text: String(value) }), el("span", { className: "stat-label", text: label })])));
    }

    // ---------- lists ----------
    const listTabs = el("div", { className: "section-tabs mod-list-tabs", role: "group", "aria-label": "Which list" });
    const filter = el("input", { type: "search", id: "mod-filter", placeholder: "Filter this list", autocomplete: "off" });
    const tableBody = el("tbody");
    const table = el("table", { className: "admin-table mod-table" }, [
      el("thead", {}, [el("tr", {}, [
        el("th", { scope: "col" }, [el("input", { type: "checkbox", id: "mod-select-all", "aria-label": "Select all shown" })]),
        el("th", { scope: "col", text: "Entry" }), el("th", { scope: "col", text: "Match" }), el("th", { scope: "col", text: "Category" }),
        el("th", { scope: "col", text: "Source" })])]),
      tableBody]);
    const bulkMatch = el("div", { className: "form-field" });
    const bulkCategory = el("div", { className: "form-field" });
    const bulkStatus = el("p", { className: "save-status", role: "status" });
    const addText = el("textarea", { id: "mod-add-text", rows: "4", placeholder: "One entry per line" });
    const addMatch = el("div", { className: "form-field" });
    const addCategory = el("div", { className: "form-field" });

    function selectedIds() {
      return Array.from(tableBody.querySelectorAll("input[type=checkbox]:checked")).map((box) => Number(box.value));
    }
    function renderRows() {
      const query = filter.value.trim().toLowerCase();
      const shown = rows.filter((r) => !query || r.term.toLowerCase().includes(query) || (r.category || "").includes(query));
      tableBody.replaceChildren(...(shown.length ? shown.map((r) => el("tr", {}, [
        el("td", {}, [el("input", { type: "checkbox", value: String(r.id), "aria-label": `Select ${r.term}` })]),
        el("td", { text: r.term }), el("td", { text: pretty(r.match_type) || "—" }), el("td", { text: pretty(r.category) || "—" }),
        el("td", { text: r.source === "list" ? "loaded list" : "dashboard" }),
      ])) : [el("tr", {}, [el("td", { colspan: "5", className: "empty-note", text: "Nothing here yet." })])]));
      document.getElementById("mod-select-all").checked = false;
    }
    async function loadList() {
      const { ok, data } = await rpc("admin_list_terms", { p_list: current });
      if (!ok) return;
      rows = data || [];
      renderRows();
      loadCounts();
    }
    function drawListControls() {
      const spec = LISTS[current];
      listTabs.replaceChildren(...Object.entries(LISTS).map(([key, list]) => el("button", {
        type: "button", className: key === current ? "is-active" : "", "aria-pressed": String(key === current), text: list.label,
        onclick: () => { current = key; drawListControls(); loadList(); } })));
      bulkMatch.replaceChildren(...(spec.matchTypes ? [el("label", { for: "mod-bulk-match", text: "Match type" }), select("mod-bulk-match", spec.matchTypes, true)] : []));
      bulkCategory.replaceChildren(...(spec.categories ? [el("label", { for: "mod-bulk-category", text: "Category" }), select("mod-bulk-category", CATEGORIES, true)] : []));
      addMatch.replaceChildren(...(spec.matchTypes ? [el("label", { for: "mod-add-match", text: "Match type" }), select("mod-add-match", spec.matchTypes, false)] : []));
      addCategory.replaceChildren(...(spec.categories ? [el("label", { for: "mod-add-category", text: "Category" }), select("mod-add-category", CATEGORIES, false)] : []));
      bulkStatus.textContent = "";
    }
    const value = (id) => { const node = document.getElementById(id); return node && node.value ? node.value : null; };

    const lists = el("section", { className: "admin-subsection mod-section", "aria-labelledby": "mod-lists-title" }, [
      el("h3", { id: "mod-lists-title", text: "Lists" }),
      el("p", { className: "panel-lead", text: "Word entries match whole words; substring entries match inside words (use only for terms that never appear in ordinary words); phrases match word sequences. Allowlist entries are removed before matching. Reserved names apply to display and in-game names." }),
      listTabs,
      el("div", { className: "form-field admin-search" }, [el("label", { for: "mod-filter", text: "Filter" }), filter]),
      el("div", { className: "admin-table-wrap" }, [table]),
      el("div", { className: "mod-bulk" }, [
        bulkMatch, bulkCategory,
        el("div", { className: "form-actions" }, [
          el("button", { type: "button", className: "button button-outline", text: "Change selected", onclick: async () => {
            const ids = selectedIds();
            if (!ids.length) { bulkStatus.textContent = "Select entries first."; return; }
            const { ok, data } = await rpc("admin_update_terms", { p_list: current, p_ids: ids, p_match_type: value("mod-bulk-match"), p_category: value("mod-bulk-category") });
            if (ok) { bulkStatus.textContent = `${data} changed.`; bulkStatus.dataset.kind = "success"; loadList(); }
          } }),
          el("button", { type: "button", className: "button button-outline button-danger", text: "Remove selected", onclick: async () => {
            const ids = selectedIds();
            if (!ids.length) { bulkStatus.textContent = "Select entries first."; return; }
            if (!window.confirm(`Remove ${ids.length} entr${ids.length === 1 ? "y" : "ies"}?`)) return;
            const { ok, data } = await rpc("admin_remove_terms", { p_list: current, p_ids: ids });
            if (ok) { bulkStatus.textContent = `${data} removed.`; bulkStatus.dataset.kind = "success"; loadList(); }
          } }),
        ]),
        bulkStatus,
      ]),
      el("div", { className: "mod-add" }, [
        el("div", { className: "form-field" }, [el("label", { for: "mod-add-text", text: "Add entries" }), addText]),
        el("div", { className: "roster-form-grid" }, [addMatch, addCategory]),
        el("div", { className: "form-actions" }, [el("button", { type: "button", className: "button button-primary", text: "Add to this list", onclick: async () => {
          const terms = addText.value.split("\n").map((t) => t.trim()).filter(Boolean);
          if (!terms.length) return;
          const { ok, data } = await rpc("admin_add_terms", { p_list: current, p_terms: terms, p_match_type: value("mod-add-match"), p_category: value("mod-add-category") });
          if (ok) { addText.value = ""; bulkStatus.textContent = `${data} added${data < terms.length ? " (the rest were already there)" : ""}.`; bulkStatus.dataset.kind = "success"; loadList(); }
        } })]),
      ]),
    ]);
    filter.addEventListener("input", renderRows);
    table.addEventListener("change", (event) => {
      if (event.target.id === "mod-select-all") tableBody.querySelectorAll("input[type=checkbox]").forEach((box) => { box.checked = event.target.checked; });
    });

    // ---------- owner: names ----------
    let names = null;
    if (state.isOwner) {
      const lookupInput = el("input", { id: "mod-name-lookup", autocomplete: "off", placeholder: "Display name" });
      const lookupResult = el("div", { role: "status", "aria-live": "polite" });
      const exceptionList = el("ul", { className: "admin-list" });
      const exceptionId = el("input", { id: "mod-exception-id", autocomplete: "off", placeholder: "Account ID from the Accounts tab" });
      const exceptionNote = el("input", { id: "mod-exception-note", autocomplete: "off", maxlength: "200", placeholder: "e.g. co-host" });
      async function loadExceptions() {
        const { ok, data } = await rpc("admin_list_name_exceptions");
        if (!ok) return;
        exceptionList.replaceChildren(...(data.length ? data.map((card) => el("li", { className: "admin-row" }, [
          el("div", { className: "admin-row-main" }, [A.personChip(card, { detail: card.note || "No note" })]),
          el("div", { className: "admin-row-actions" }, [el("button", { type: "button", className: "button button-outline", text: "Remove exception",
            onclick: async () => { if ((await rpc("admin_remove_name_exception", { p_user: card.id })).ok) { loadExceptions(); loadCounts(); } } })]),
        ])) : [el("li", { className: "empty-note", text: "No exceptions." })]));
      }
      names = el("section", { className: "admin-subsection mod-section", "aria-labelledby": "mod-names-title" }, [
        el("h3", { id: "mod-names-title" }, ["Display names ", el("span", { className: "account-badge", text: "Owner only" })]),
        el("p", { className: "panel-lead", text: "Look up who holds a name (lookalikes count as the same name). Reclaiming clears it without notifying anyone; they can choose a new name straight away. Every reclaim is audited." }),
        el("div", { className: "account-actions" }, [
          el("div", { className: "form-field" }, [el("label", { for: "mod-name-lookup", text: "Name" }), lookupInput]),
          el("button", { type: "button", className: "button button-outline", text: "Look up", onclick: async () => {
            const { ok, data } = await rpc("admin_lookup_name", { p_name: lookupInput.value });
            if (!ok) return;
            lookupResult.replaceChildren(data
              ? el("div", { className: "admin-row" }, [
                  el("div", { className: "admin-row-main" }, [A.personChip(data, { detail: `ID ${data.id}` })]),
                  el("div", { className: "admin-row-actions" }, [el("button", { type: "button", className: "button button-outline button-danger", text: "Reclaim name",
                    onclick: async () => {
                      if (!window.confirm(`Clear the display name "${data.name}"? The listener isn't notified.`)) return;
                      if ((await rpc("admin_reclaim_name", { p_user: data.id })).ok) lookupResult.replaceChildren(el("p", { className: "save-status", "data-kind": "success", text: "Name reclaimed." }));
                    } })]),
                ])
              : el("p", { className: "empty-note", text: "Nobody holds that name." }));
          } }),
        ]),
        lookupResult,
        el("h3", { text: "Reserved-name exceptions" }),
        el("p", { className: "panel-lead", text: "Accounts here may use reserved names (for example a co-host who isn't an admin). The owner and admins can always use them." }),
        exceptionList,
        el("div", { className: "roster-form-grid" }, [
          el("div", { className: "form-field" }, [el("label", { for: "mod-exception-id", text: "Account ID" }), exceptionId]),
          el("div", { className: "form-field" }, [el("label", { for: "mod-exception-note", text: "Note" }), exceptionNote]),
        ]),
        el("div", { className: "form-actions" }, [el("button", { type: "button", className: "button button-primary", text: "Add exception", onclick: async () => {
          const id = exceptionId.value.trim();
          if (!/^[0-9a-f-]{36}$/i.test(id)) { ctx.reportError({ message: "Paste the account ID from the Accounts tab." }); return; }
          if ((await rpc("admin_add_name_exception", { p_user: id, p_note: exceptionNote.value })).ok) { exceptionId.value = ""; exceptionNote.value = ""; loadExceptions(); loadCounts(); }
        } })]),
      ]);
      loadExceptions();
    }

    panel.replaceChildren(counts, tester, lists, names);
    drawListControls();
    loadList();
  };
})();
