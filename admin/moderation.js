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
        data.categories.length ? `Category: ${data.categories.map(pretty).join(", ")}` : null,
        data.reserved_name ? "Matches a reserved name (allowed only for the owner, admins and excepted accounts)" : null,
        data.name_taken ? "As a display name: already taken" : null,
      ].filter(Boolean);
      testResult.replaceChildren(
        el("p", { className: `status-pill${data.blocked ? " is-banned" : ""}`, text: data.blocked ? "Would be blocked" : "Allowed" }),
        reasons.length ? el("ul", { className: "account-list" }, reasons.map((r) => el("li", { text: r }))) : null,
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

    // ---------- lists (write-only: entries are never shown, only counts) ----------
    const listTabs = el("div", { className: "section-tabs mod-list-tabs", role: "group", "aria-label": "Which list" });
    const entries = el("textarea", { id: "mod-entries", rows: "4", autocomplete: "off", spellcheck: "false",
      placeholder: "Type or paste entries, one per line" });
    const matchField = el("div", { className: "form-field" });
    const categoryField = el("div", { className: "form-field" });
    const listStatus = el("p", { className: "save-status", id: "mod-list-status", role: "status", "aria-live": "polite" });
    const value = (id) => { const node = document.getElementById(id); return node && node.value ? node.value : null; };
    function typedEntries() {
      return entries.value.split("\n").map((line) => line.trim()).filter(Boolean);
    }
    function report(text, kind) {
      listStatus.textContent = text;
      listStatus.dataset.kind = kind || "";
    }
    function drawListControls() {
      const spec = LISTS[current];
      listTabs.replaceChildren(...Object.entries(LISTS).map(([key, list]) => el("button", {
        type: "button", className: key === current ? "is-active" : "", "aria-pressed": String(key === current), text: list.label,
        onclick: () => { current = key; drawListControls(); } })));
      matchField.replaceChildren(...(spec.matchTypes ? [el("label", { for: "mod-match", text: "Match type" }),
        select("mod-match", spec.matchTypes, true)] : []));
      categoryField.replaceChildren(...(spec.categories ? [el("label", { for: "mod-category", text: "Category" }),
        select("mod-category", CATEGORIES, true)] : []));
      document.getElementById("mod-change")?.toggleAttribute("hidden", current === "allowed");
      report("");
    }
    async function act(kind) {
      const terms = typedEntries();
      if (!terms.length) { report("Type at least one entry first.", "error"); return; }
      let result;
      if (kind === "add") {
        result = await rpc("admin_add_terms", { p_list: current, p_terms: terms, p_match_type: value("mod-match"), p_category: value("mod-category") });
        if (result.ok) report(`Added ${result.data}.${result.data < terms.length ? ` ${terms.length - result.data} already there.` : ""}`, "success");
      } else if (kind === "remove") {
        if (!window.confirm(`Remove the ${terms.length} typed entr${terms.length === 1 ? "y" : "ies"} from ${LISTS[current].label.toLowerCase()}?`)) return;
        result = await rpc("admin_remove_terms", { p_list: current, p_terms: terms, p_match_type: null });
        if (result.ok) report(`Removed ${result.data.removed}.${result.data.not_found ? ` Not found: ${result.data.not_found}.` : ""}`, result.data.removed ? "success" : "error");
      } else {
        if (!value("mod-match") && !value("mod-category")) { report("Choose a match type or category to change to.", "error"); return; }
        result = await rpc("admin_update_terms", { p_list: current, p_terms: terms, p_match_type: value("mod-match"), p_category: value("mod-category") });
        if (result.ok) report(`Changed ${result.data.changed}.${result.data.not_found ? ` Not found: ${result.data.not_found}.` : ""}`, result.data.changed ? "success" : "error");
      }
      if (result && result.ok) { entries.value = ""; loadCounts(); }
    }

    const lists = el("section", { className: "admin-subsection mod-section", "aria-labelledby": "mod-lists-title" }, [
      el("h3", { id: "mod-lists-title", text: "Edit the lists" }),
      el("p", { className: "panel-lead", text: "The lists are never shown on the site, to anyone. Type or paste entries to add, remove or change them; you'll only see counts. Word entries match whole words; substring entries match inside words (only for terms that never appear in ordinary words); phrases match word sequences. The allowlist is removed before matching. Reserved names apply to display and in-game names." }),
      listTabs,
      el("div", { className: "form-field" }, [el("label", { for: "mod-entries", text: "Entries" }), entries]),
      el("div", { className: "roster-form-grid" }, [matchField, categoryField]),
      el("p", { className: "field-help", text: "Match type and category apply when adding or changing. Removing matches the exact entry, ignoring case, accents and spacing." }),
      el("div", { className: "form-actions" }, [
        el("button", { type: "button", className: "button button-primary", text: "Add", onclick: () => act("add") }),
        el("button", { type: "button", className: "button button-outline", id: "mod-change", text: "Change", onclick: () => act("change") }),
        el("button", { type: "button", className: "button button-outline button-danger", text: "Remove", onclick: () => act("remove") }),
      ]),
      listStatus,
    ]);

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
    loadCounts();
  };
})();
