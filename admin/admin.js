// Admin dashboard. The page only shows controls; every permission is enforced by the database.
(() => {
  "use strict";
  const A = window.HCAccount;
  const client = A && A.createClient();
  const $ = (id) => document.getElementById(id);
  if (!client) return;

  const el = A.el;
  let me = null;
  let isOwner = false;
  let names = new Map();

  function reportError(error) {
    const node = $("admin-error");
    node.textContent = error ? A.friendlyError(error) : "";
    node.hidden = !error;
  }

  async function call(fn, args) {
    reportError(null);
    const { data, error } = await client.rpc(fn, args);
    if (error) {
      reportError(error);
      return null;
    }
    await loadAll();
    return data === null ? true : data;
  }

  function shortId(id) {
    return id ? `${id.slice(0, 8)}…` : "—";
  }

  function who(id) {
    if (!id) return "System";
    return names.get(id) || shortId(id);
  }

  // ---------- accounts ----------
  function accountActions(account) {
    const actions = [];
    const self = account.id === me.id;
    if (isOwner && !self && account.role !== "owner") {
      actions.push(account.role === "admin"
        ? el("button", { type: "button", className: "edit-application-link", text: "Remove admin",
            onclick: () => window.confirm("Remove this admin?") && call("admin_revoke_admin", { p_target: account.id }) })
        : el("button", { type: "button", className: "edit-application-link", text: "Make admin",
            onclick: () => window.confirm("Make this account an admin?") && call("admin_grant_admin", { p_target: account.id }) }));
    }
    const canBan = !self && account.role !== "owner" && (account.role !== "admin" || isOwner);
    if (canBan) {
      actions.push(account.banned
        ? el("button", { type: "button", className: "edit-application-link", text: "Lift ban",
            onclick: () => call("admin_unban", { p_target: account.id }) })
        : el("button", { type: "button", className: "edit-application-link", text: "Ban",
            onclick: () => {
              const reason = window.prompt("Reason for the ban (shown to admins only):", "");
              if (reason === null) return;
              const days = window.prompt("Ban for how many days? Leave empty for no end date.", "");
              if (days === null) return;
              const n = Number.parseInt(days, 10);
              const expires = Number.isFinite(n) && n > 0 ? new Date(Date.now() + n * 86400000).toISOString() : null;
              call("admin_ban", { p_target: account.id, p_reason: reason, p_expires_at: expires });
            } }));
    }
    return actions;
  }

  async function loadAccounts() {
    const { data, error } = await client.rpc("admin_list_accounts");
    if (error) {
      reportError(error);
      return;
    }
    names = new Map(data.map((a) => [a.id, a.display_name || (a.email && isOwner ? a.email : shortId(a.id))]));
    $("account-count").textContent = `(${data.length})`;
    $("account-note").textContent = isOwner
      ? "As the owner you also see email addresses. Admins don't."
      : "Email addresses are visible to the owner only.";
    $("accounts-table").tBodies[0].replaceChildren(...data.map((account) => el("tr", {}, [
      el("td", {}, [
        el("strong", { text: A.displayName(account) }),
        account.email ? el("div", { className: "field-help", text: account.email }) : null,
        el("div", { className: "field-help", text: `ID ${account.id}` }),
      ]),
      el("td", { text: (account.providers || []).map(A.providerLabel).join(", ") || "—" }),
      el("td", { text: A.formatDate(account.created_at) }),
      el("td", { text: A.formatDate(account.last_sign_in_at) }),
      el("td", { text: account.role ? account.role[0].toUpperCase() + account.role.slice(1) : "Listener" }),
      el("td", { text: account.banned ? "Banned" : "Active" }),
      el("td", {}, accountActions(account)),
    ])));
  }

  // ---------- invites (owner) ----------
  async function loadInvites() {
    $("invites-card").hidden = !isOwner;
    if (!isOwner) return;
    const { data, error } = await client.from("admin_invites").select("id, kind, value, created_at").order("created_at");
    if (error) {
      reportError(error);
      return;
    }
    $("invite-list").replaceChildren(...(data.length ? data.map((invite) => el("li", {}, [
      `${invite.kind === "discord" ? "Discord ID" : "Email"}: ${invite.value} · ${A.formatDate(invite.created_at)} `,
      el("button", { type: "button", className: "edit-application-link", text: "Cancel invite",
        onclick: () => call("admin_delete_invite", { p_invite: invite.id }) }),
    ])) : [el("li", { className: "field-help", text: "No pending invites." })]));
  }

  $("invite-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    const value = $("invite-value").value.trim();
    if (!value) return;
    if (await call("admin_create_invite", { p_kind: $("invite-kind").value, p_value: value })) $("invite-value").value = "";
  });

  // ---------- blocked words ----------
  async function loadWords() {
    const { data, error } = await client.rpc("admin_list_blocked_words");
    if (error) {
      reportError(error);
      return;
    }
    $("word-list").replaceChildren(...(data.length ? data.map((word) => el("li", {}, [
      word, " ",
      el("button", { type: "button", className: "edit-application-link", text: "remove", "aria-label": `Remove ${word}`,
        onclick: () => call("admin_remove_blocked_word", { p_word: word }) }),
    ])) : [el("li", { className: "field-help", text: "No blocked words yet." })]));
  }

  $("word-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    const word = $("word-value").value.trim();
    if (word && await call("admin_add_blocked_word", { p_word: word })) $("word-value").value = "";
  });

  // ---------- audit log ----------
  async function loadAudit() {
    const { data, error } = await client.from("audit_log")
      .select("created_at, action, actor_id, target_id, details").order("created_at", { ascending: false }).limit(100);
    if (error) {
      reportError(error);
      return;
    }
    $("audit-table").tBodies[0].replaceChildren(...data.map((row) => el("tr", {}, [
      el("td", { text: new Date(row.created_at).toLocaleString() }),
      el("td", { text: row.action.replace(/_/g, " ") }),
      el("td", { text: who(row.actor_id) }),
      el("td", { text: row.target_id ? who(row.target_id) : "—" }),
    ])));
  }

  async function loadAll() {
    await loadAccounts();
    await Promise.all([loadInvites(), loadWords(), loadAudit()]);
  }

  async function start() {
    const { data } = await client.auth.getUser();
    if (!data || !data.user) return;
    me = data.user;
    const [{ data: admin }, { data: owner }] = await Promise.all([client.rpc("is_admin"), client.rpc("is_owner")]);
    if (!admin) {
      $("admin-gate").querySelector("h2").textContent = "This page is for admins only.";
      return;
    }
    isOwner = owner === true;
    $("admin-gate").hidden = true;
    $("admin-panel").hidden = false;
    await loadAll();
  }

  start();
})();
