// Admin dashboard. The page only shows controls; every permission is enforced by the database.
// Sections are tabs; later features register extra tabs through window.HCAdmin.addTab().
(() => {
  "use strict";
  const A = window.HCAccount;
  const client = A && A.createClient();
  const $ = (id) => document.getElementById(id);
  if (!client) return;

  const el = A.el;
  const state = { me: null, card: null, isOwner: false, accounts: [], cards: new Map(), loaders: {} };

  // ---------- helpers shared with feature modules ----------
  function reportError(error) {
    const node = $("admin-error");
    node.textContent = error ? A.friendlyError(error) : "";
    node.hidden = !error;
    if (error) node.scrollIntoView({ block: "nearest" });
  }
  async function rpc(fn, args) {
    reportError(null);
    const { data, error } = await client.rpc(fn, args);
    if (error) { reportError(error); return { ok: false, data: null }; }
    return { ok: true, data };
  }
  function cardFor(id) {
    if (!id) return { id: null, name: "System", avatar_url: null };
    return state.cards.get(id) || { id, name: `Account ${id.slice(0, 8)}`, avatar_url: null };
  }
  async function ensureCards(ids) {
    const missing = [...new Set(ids.filter((id) => id && !state.cards.has(id)))];
    if (!missing.length) return;
    const { data } = await client.rpc("admin_member_cards", { p_ids: missing });
    (data || []).forEach((card) => state.cards.set(card.id, card));
  }

  // ---------- tabs (WAI-ARIA tabs pattern) ----------
  const tablist = $("admin-tabs");
  function tabs() { return Array.from(tablist.querySelectorAll('[role="tab"]')); }
  function selectTab(tab, focus) {
    tabs().forEach((item) => {
      const selected = item === tab;
      item.setAttribute("aria-selected", String(selected));
      item.tabIndex = selected ? 0 : -1;
      $(item.getAttribute("aria-controls")).hidden = !selected;
    });
    if (focus) tab.focus();
    const loader = state.loaders[tab.id];
    if (loader) loader();
    try { history.replaceState(null, "", `#${tab.id.replace(/^tab-/, "")}`); } catch { /* ignore */ }
  }
  tablist.addEventListener("click", (event) => {
    const tab = event.target.closest('[role="tab"]');
    if (tab) selectTab(tab, false);
  });
  tablist.addEventListener("keydown", (event) => {
    const list = tabs();
    const index = list.indexOf(document.activeElement);
    if (index < 0) return;
    const next = { ArrowRight: index + 1, ArrowLeft: index - 1, Home: 0, End: list.length - 1 }[event.key];
    if (next === undefined) return;
    event.preventDefault();
    selectTab(list[(next + list.length) % list.length], true);
  });
  function addTab(id, label, render) {
    const tab = el("button", { type: "button", role: "tab", id: `tab-${id}`, "aria-controls": `panel-${id}`, "aria-selected": "false", tabindex: "-1", text: label });
    const panel = el("section", { className: "panel admin-tabpanel", role: "tabpanel", id: `panel-${id}`, "aria-labelledby": `tab-${id}` });
    panel.hidden = true;
    const audit = $("tab-audit");
    tablist.insertBefore(tab, audit);
    $("panel-audit").before(panel);
    state.loaders[tab.id] = () => render(panel);
    return panel;
  }

  // ---------- overview ----------
  async function loadOverview() {
    await loadAccounts(false);
    const stats = [
      ["Accounts", state.accounts.length],
      ["Admins", state.accounts.filter((a) => a.role).length],
      ["With a profile", state.accounts.filter((a) => a.has_profile).length],
      ["Banned", state.accounts.filter((a) => a.banned).length],
      ...(window.HCAdminStats ? await window.HCAdminStats(client) : []),
    ];
    A.fill($("stat-grid"), ...stats.map(([label, value]) => el("div", { className: "stat-tile" }, [
      el("span", { className: "stat-value", text: String(value ?? 0) }), el("span", { className: "stat-label", text: label }),
    ])));
  }
  state.loaders["tab-overview"] = loadOverview;

  // ---------- accounts ----------
  function accountActions(account) {
    const actions = [];
    const self = account.id === state.me.id;
    if (state.isOwner && !self && account.role !== "owner") {
      actions.push(account.role === "admin"
        ? el("button", { type: "button", className: "button button-outline", text: "Remove admin",
            onclick: async () => { if (window.confirm(`Remove ${A.displayName(account)} as admin?`) && (await rpc("admin_revoke_admin", { p_target: account.id })).ok) loadAccounts(true); } })
        : el("button", { type: "button", className: "button button-outline", text: "Make admin",
            onclick: async () => { if (window.confirm(`Make ${A.displayName(account)} an admin?`) && (await rpc("admin_grant_admin", { p_target: account.id })).ok) loadAccounts(true); } }));
    }
    if (!self && account.role !== "owner" && (account.role !== "admin" || state.isOwner)) {
      actions.push(account.banned
        ? el("button", { type: "button", className: "button button-outline", text: "Lift ban",
            onclick: async () => { if ((await rpc("admin_unban", { p_target: account.id })).ok) loadAccounts(true); } })
        : el("button", { type: "button", className: "button button-outline button-danger", text: "Ban", onclick: () => openBan(account) }));
    }
    return actions;
  }

  function renderAccounts() {
    const query = $("account-search").value.trim().toLowerCase();
    const rows = state.accounts.filter((a) => !query || [a.display_name, a.email, a.id].some((v) => v && v.toLowerCase().includes(query)));
    $("account-count").textContent = `(${state.accounts.length})`;
    A.fill($("account-list"), ...(rows.length ? rows.map((account) => {
      const detail = [(account.providers || []).map(A.providerLabel).join(" + ") || "No sign-in",
                      `joined ${A.formatDate(account.created_at)}`, `last seen ${A.formatDate(account.last_sign_in_at)}`].join(" · ");
      return el("li", { className: "admin-row" }, [
        el("div", { className: "admin-row-main" }, [
          A.personChip({ id: account.id, name: account.display_name, avatar_url: account.avatar_url, role: account.role }, { detail }),
          account.email ? el("span", { className: "field-help admin-row-email", text: account.email }) : null,
          el("span", { className: "field-help admin-row-id", text: `ID ${account.id}` }),
        ]),
        el("span", { className: `status-pill${account.banned ? " is-banned" : ""}`, text: account.banned ? "Banned" : "Active" }),
        el("div", { className: "admin-row-actions" }, accountActions(account)),
      ]);
    }) : [el("li", { className: "empty-note", text: "No accounts match." })]));
  }

  async function loadAccounts(render) {
    const result = await rpc("admin_list_accounts");
    if (!result.ok) return;
    state.accounts = result.data || [];
    state.accounts.forEach((a) => state.cards.set(a.id, { id: a.id, name: a.display_name, avatar_url: a.avatar_url, role: a.role }));
    $("account-note").textContent = state.isOwner ? "As the owner you also see email addresses. Admins don't." : "Email addresses are visible to the owner only.";
    if (render !== false) renderAccounts();
  }
  $("account-search").addEventListener("input", renderAccounts);
  state.loaders["tab-accounts"] = async () => { await loadAccounts(true); await loadInvites(); };

  // Ban dialog (a real dialog instead of browser prompts).
  let banTarget = null;
  function openBan(account) {
    banTarget = account;
    $("ban-name").textContent = A.displayName(account);
    $("ban-reason").value = "";
    $("ban-length").value = "7";
    $("ban-dialog").showModal();
  }
  $("ban-dialog").addEventListener("close", async () => {
    if ($("ban-dialog").returnValue !== "ban" || !banTarget) return;
    const days = Number.parseInt($("ban-length").value, 10);
    const expires = Number.isFinite(days) ? new Date(Date.now() + days * 86400000).toISOString() : null;
    if ((await rpc("admin_ban", { p_target: banTarget.id, p_reason: $("ban-reason").value, p_expires_at: expires })).ok) loadAccounts(true);
    banTarget = null;
  });

  // ---------- invites (owner) ----------
  async function loadInvites() {
    $("invites-card").hidden = !state.isOwner;
    if (!state.isOwner) return;
    const { data, error } = await client.from("admin_invites").select("id, kind, value, created_at").order("created_at");
    if (error) { reportError(error); return; }
    A.fill($("invite-list"), ...(data.length ? data.map((invite) => el("li", {}, [
      `${invite.kind === "discord" ? "Discord ID" : "Email"}: ${invite.value} · ${A.formatDate(invite.created_at)} `,
      el("button", { type: "button", className: "edit-application-link", text: "Cancel invite",
        onclick: async () => { if ((await rpc("admin_delete_invite", { p_invite: invite.id })).ok) loadInvites(); } }),
    ])) : [el("li", { className: "field-help", text: "No pending invites." })]));
  }
  $("invite-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    const value = $("invite-value").value.trim();
    if (!value) return;
    if ((await rpc("admin_create_invite", { p_kind: $("invite-kind").value, p_value: value })).ok) {
      $("invite-value").value = "";
      await loadAccounts(true);
      loadInvites();
    }
  });

  // ---------- moderation (blocked words; extended by the moderation module) ----------
  async function loadModeration() {
    const panel = $("moderation-tools");
    if (window.HCModeration) { window.HCModeration(panel, { client, rpc, el, A, state, reportError }); return; }
    const result = await rpc("admin_list_blocked_words");
    if (!result.ok) return;
    A.fill(panel, el("p", { className: "panel-lead", text: `${result.data.length} blocked words.` }));
  }
  state.loaders["tab-moderation"] = loadModeration;

  // ---------- audit log ----------
  async function loadAudit() {
    const { data, error } = await client.from("audit_log")
      .select("created_at, action, actor_id, target_id").order("created_at", { ascending: false }).limit(200);
    if (error) { reportError(error); return; }
    await ensureCards(data.flatMap((row) => [row.actor_id, row.target_id]));
    A.fill($("audit-list"), ...(data.length ? data.map((row) => el("li", { className: "audit-row" }, [
      el("time", { datetime: row.created_at, text: new Date(row.created_at).toLocaleString() }),
      el("span", { className: "audit-action", text: row.action.replace(/_/g, " ") }),
      el("span", { className: "audit-people" }, [
        A.personChip(cardFor(row.actor_id), { size: 24, showRole: false }),
        row.target_id ? el("span", { className: "audit-arrow", "aria-hidden": "true", text: "→" }) : null,
        row.target_id ? A.personChip(cardFor(row.target_id), { size: 24, showRole: false }) : null,
      ]),
    ])) : [el("li", { className: "empty-note", text: "Nothing logged yet." })]));
  }
  state.loaders["tab-audit"] = loadAudit;

  // ---------- start ----------
  async function start() {
    const { data } = await client.auth.getUser();
    if (!data || !data.user) return;
    state.me = data.user;
    const [{ data: admin }, { data: owner }, { data: card }] = await Promise.all([
      client.rpc("is_admin"), client.rpc("is_owner"), client.rpc("my_member_card")]);
    if (card) { A.saveSummary(card); window.dispatchEvent(new Event("hc-account-changed")); }
    if (!admin) {
      $("admin-gate").querySelector("h2").textContent = "This page is for admins only.";
      return;
    }
    state.isOwner = owner === true;
    state.card = card;
    $("admin-gate").hidden = true;
    $("admin-panel").hidden = false;
    A.fill($("admin-whoami"), A.personChip(card, { detail: state.isOwner ? "Signed in as the owner" : "Signed in as an admin" }));
    window.HCAdmin = { client, rpc, el, A, state, addTab, reportError, ensureCards, cardFor };
    window.dispatchEvent(new Event("hc-admin-ready"));
    const fromHash = () => {
      const wanted = $(`tab-${(window.location.hash || "").replace(/^#/, "")}`);
      return wanted && wanted.getAttribute("role") === "tab" ? wanted : null;
    };
    selectTab(fromHash() || $("tab-overview"), false);
    window.addEventListener("hashchange", () => { const tab = fromHash(); if (tab && tab.getAttribute("aria-selected") !== "true") selectTab(tab, false); });
  }
  start();
})();
