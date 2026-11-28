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
        ...CATEGORIES.map((key) => [pretty(key), (data.blocked_by_category || {})[key] || 0]),
        ["allowlist", data.allowed], ["reserved names", data.reserved], ["name exceptions", data.name_exceptions],
      ];
      counts.replaceChildren(...tiles.map(([label, value]) => el("div", { className: "stat-tile" }, [
        el("span", { className: "stat-value", text: String(value) }), el("span", { className: "stat-label", text: label })])));
    }

    // ---------- blind list management: type entries in, get counts out. Nothing is ever displayed. ----------
    const value = (id) => { const node = document.getElementById(id); return node && node.value ? node.value : null; };
    const listPicker = (id, lists) => el("div", { className: "form-field" }, [
      el("label", { for: id, text: "List" }),
      el("select", { id }, lists.map((key) => el("option", { value: key, text: LISTS[key].label }))),
    ]);
    const typedEntries = (id) => (document.getElementById(id).value || "").split("\n").map((line) => line.trim()).filter(Boolean);
    const plural = (n) => `${n} entr${n === 1 ? "y" : "ies"}`;
    function say(statusId, text, kind) {
      const node = document.getElementById(statusId);
      node.textContent = text;
      node.dataset.kind = kind || "";
    }
    // Match type and category fields follow the chosen list (allowlist has neither; reserved has match only).
    function syncFields(listId, matchWrapId, categoryWrapId, keepOption) {
      const spec = LISTS[value(listId)];
      document.getElementById(matchWrapId).replaceChildren(...(spec.matchTypes
        ? [el("label", { for: `${matchWrapId}-select`, text: "Match type" }), select(`${matchWrapId}-select`, spec.matchTypes, keepOption)] : []));
      document.getElementById(categoryWrapId).replaceChildren(...(spec.categories
        ? [el("label", { for: `${categoryWrapId}-select`, text: "Category" }), select(`${categoryWrapId}-select`, CATEGORIES, keepOption)] : []));
    }
    function box(title, id, lead, controls, button, statusId) {
      return el("section", { className: "admin-subsection mod-section", "aria-labelledby": `${id}-title` }, [
        el("h3", { id: `${id}-title`, text: title }),
        el("p", { className: "panel-lead", text: lead }),
        ...controls,
        el("div", { className: "form-actions" }, [button]),
        el("p", { className: "save-status", id: statusId, role: "status", "aria-live": "polite" }),
      ]);
    }
    const entriesField = (id, label) => el("div", { className: "form-field" }, [
      el("label", { for: id, text: label }),
      el("textarea", { id, rows: "3", autocomplete: "off", spellcheck: "false", placeholder: "One per line" }),
    ]);

    const addBox = box("Add terms", "mod-add",
      "Type one entry or paste many, one per line. Word entries match whole words; substring entries match inside words (only for terms that never appear in ordinary words); phrases match word sequences. Allowlist entries are removed before matching; reserved names apply to display and in-game names.",
      [el("div", { className: "roster-form-grid" }, [listPicker("mod-add-list", ["blocked", "allowed", "reserved"]),
        el("div", { id: "mod-add-match", className: "form-field" }), el("div", { id: "mod-add-category", className: "form-field" })]),
       entriesField("mod-add-entries", "Entries to add")],
      el("button", { type: "button", className: "button button-primary", id: "mod-add-button", text: "Add", onclick: async () => {
        const list = value("mod-add-list");
        const terms = typedEntries("mod-add-entries");
        if (!terms.length) { say("mod-add-status", "Type at least one entry first.", "error"); return; }
        const { ok, data } = await rpc("admin_add_terms", { p_list: list, p_terms: terms,
          p_match_type: value("mod-add-match-select"), p_category: value("mod-add-category-select") });
        if (!ok) return;
        document.getElementById("mod-add-entries").value = "";
        say("mod-add-status", `Added ${plural(data)}.${data < terms.length ? ` ${terms.length - data} already there.` : ""}`, "success");
        loadCounts();
      } }), "mod-add-status");

    const removeBox = box("Remove terms", "mod-remove",
      "Type the exact entries to remove, one per line (case, accents and spacing are ignored). You'll only see how many were removed or not found.",
      [listPicker("mod-remove-list", ["blocked", "allowed", "reserved"]), entriesField("mod-remove-entries", "Entries to remove")],
      el("button", { type: "button", className: "button button-outline button-danger", id: "mod-remove-button", text: "Remove", onclick: async () => {
        const list = value("mod-remove-list");
        const terms = typedEntries("mod-remove-entries");
        if (!terms.length) { say("mod-remove-status", "Type at least one entry first.", "error"); return; }
        if (!window.confirm(`Remove ${plural(terms.length)} from ${LISTS[list].label.toLowerCase()}?`)) return;
        const { ok, data } = await rpc("admin_remove_terms", { p_list: list, p_terms: terms, p_match_type: null });
        if (!ok) return;
        document.getElementById("mod-remove-entries").value = "";
        say("mod-remove-status", `Removed ${data.removed}. Not found ${data.not_found}.`, data.removed ? "success" : "error");
        loadCounts();
      } }), "mod-remove-status");

    const changeBox = box("Change type or category", "mod-change",
      "Type the exact entries to change, one per line, and choose the new match type and/or category.",
      [el("div", { className: "roster-form-grid" }, [listPicker("mod-change-list", ["blocked", "reserved"]),
        el("div", { id: "mod-change-match", className: "form-field" }), el("div", { id: "mod-change-category", className: "form-field" })]),
       entriesField("mod-change-entries", "Entries to change")],
      el("button", { type: "button", className: "button button-outline", id: "mod-change-button", text: "Change", onclick: async () => {
        const list = value("mod-change-list");
        const terms = typedEntries("mod-change-entries");
        if (!terms.length) { say("mod-change-status", "Type at least one entry first.", "error"); return; }
        const matchType = value("mod-change-match-select");
        const category = value("mod-change-category-select");
        if (!matchType && !category) { say("mod-change-status", "Choose a new match type or category.", "error"); return; }
        const { ok, data } = await rpc("admin_update_terms", { p_list: list, p_terms: terms, p_match_type: matchType, p_category: category });
        if (!ok) return;
        document.getElementById("mod-change-entries").value = "";
        say("mod-change-status", `Changed ${data.changed}. Not found ${data.not_found}.`, data.changed ? "success" : "error");
        loadCounts();
      } }), "mod-change-status");

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

    panel.replaceChildren(counts, tester, addBox, removeBox, changeBox, names);
    syncFields("mod-add-list", "mod-add-match", "mod-add-category", false);
    syncFields("mod-change-list", "mod-change-match", "mod-change-category", true);
    document.getElementById("mod-add-list").addEventListener("change", () => syncFields("mod-add-list", "mod-add-match", "mod-add-category", false));
    document.getElementById("mod-change-list").addEventListener("change", () => syncFields("mod-change-list", "mod-change-match", "mod-change-category", true));
    loadCounts();
  };
})();
