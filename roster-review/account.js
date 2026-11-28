// Roster review with an account. The email form on this page keeps working without it.
// Signed-out visitors get a short note and never load the Supabase library.
(async () => {
  "use strict";
  const A = window.HCAccount;
  const config = window.HC_SUPABASE_CONFIG;
  const panel = document.getElementById("roster-account");
  if (!A || !panel || !A.isConfigured(config)) return;
  const el = A.el;
  const STATUS = {
    received: ["Received", "We've got your request."],
    queued: ["In the queue", "The crew plans to review your roster."],
    reviewed: ["Reviewed", "The crew has reviewed your roster; it may air soon."],
    aired: ["Aired", "Your review is on the show."],
    declined: ["Not selected", "This one wasn't picked for the show. You can apply again."],
    closed: ["Closed", "This request is closed. You can apply again."],
  };
  const OPEN = ["received", "queued", "reviewed"];

  function signedOut() {
    panel.hidden = false;
    A.fill(panel, el("div", { className: "roster-form-card roster-account-card" }, [
      el("p", { className: "card-kicker", text: "APPLY WITH YOUR ACCOUNT" }),
      el("p", { className: "qotw-signin-note" }, ["Have a Holotable Chaos account? ",
        el("a", { className: "card-link", href: "../account/index.html", text: "Sign in to apply on the site and follow your request" }),
        ". Or use the email form below."]),
    ]));
  }
  if (!A.storedSession(config)) { signedOut(); return; }
  if (!(await A.loadSupabase())) return;
  const client = A.createClient();
  if (!client) return;
  const { data: auth } = await client.auth.getUser();
  if (!auth || !auth.user) { signedOut(); return; }
  const me = auth.user;

  const emailKicker = document.querySelector(".roster-form-layout:not(#roster-account) .card-kicker");
  if (emailKicker) emailKicker.textContent = "APPLY BY EMAIL INSTEAD";

  const [{ data: requests }, { data: profile }, { data: banned }] = await Promise.all([
    client.from("roster_requests").select("id, ally_code, swgoh_gg_url, in_game_name, goals, current_projects, status, aired_episode, created_at, status_changed_at")
      .eq("user_id", me.id).order("created_at", { ascending: false }),
    client.from("profiles").select("ally_code, swgoh_gg_url, in_game_name").eq("id", me.id).maybeSingle(),
    client.rpc("is_banned"),
  ]);
  let all = requests || [];
  let open = all.find((r) => OPEN.includes(r.status)) || null;

  // ---------- form (shared edit pattern) ----------
  const field = (id, label, input, extra) => el("div", { className: `form-field${extra ? " form-field-full" : ""}` },
    [el("label", { for: id }, label), input, el("p", { className: "field-error", id: `${id}-error`, hidden: true })]);
  const unverified = () => el("span", { className: "unverified-tag", text: "Self-reported · unverified" });
  const inputs = {
    ally: el("input", { id: "rr-ally-code", inputmode: "numeric", maxlength: "11", placeholder: "123-456-789", autocomplete: "off" }),
    gg: el("input", { id: "rr-swgoh-gg", type: "url", inputmode: "url", placeholder: "https://swgoh.gg/p/123456789/" }),
    ign: el("input", { id: "rr-in-game-name", maxlength: "40", autocomplete: "off" }),
    goals: el("textarea", { id: "rr-goals", rows: "4", maxlength: "1000" }),
    projects: el("textarea", { id: "rr-projects", rows: "3", maxlength: "1000" }),
  };
  const formStatus = el("p", { className: "save-status", id: "rr-form-status", role: "status", "aria-live": "polite" });
  const cancel = el("button", { type: "button", className: "button button-outline", id: "rr-cancel", text: "Cancel" });
  const form = el("form", { className: "edit-form roster-account-form", id: "rr-form", novalidate: true, hidden: true }, [
    el("div", { className: "roster-form-grid" }, [
      field("rr-ally-code", ["Ally code ", el("span", { "aria-hidden": "true", text: "*" }), " ", unverified()], inputs.ally),
      field("rr-swgoh-gg", ["SWGOH.GG link ", el("span", { className: "optional-label", text: "(optional)" }), " ", unverified()], inputs.gg),
      field("rr-in-game-name", ["In-game name ", el("span", { className: "optional-label", text: "(optional)" })], inputs.ign),
      field("rr-goals", ["Your goals ", el("span", { "aria-hidden": "true", text: "*" })], inputs.goals, true),
      field("rr-projects", ["Current projects ", el("span", { className: "optional-label", text: "(optional)" })], inputs.projects, true),
    ]),
    el("div", { className: "form-actions" }, [el("button", { type: "submit", className: "button button-primary", id: "rr-save", text: "Send request" }), cancel, formStatus]),
    el("p", { className: "field-help", text: "No screenshots needed: the crew looks up your roster from your ally code." }),
  ]);
  const view = el("div", { className: "edit-view", id: "rr-view" });
  const status = el("p", { className: "save-status", id: "rr-status", role: "status", "aria-live": "polite" });
  const announcer = el("p", { className: "sr-only", "aria-live": "polite" });
  const editButton = el("button", { type: "button", className: "button button-primary edit-button", id: "rr-edit" });
  const history = el("div", { className: "roster-history" });

  function setError(id, message) {
    const node = document.getElementById(`${id}-error`);
    node.textContent = message || "";
    node.hidden = !message;
    document.getElementById(id).setAttribute("aria-invalid", message ? "true" : "false");
  }
  function values() {
    return { ally: A.normalizeAllyCode(inputs.ally.value), gg: inputs.gg.value.trim(), ign: inputs.ign.value.trim(),
             goals: inputs.goals.value.trim(), projects: inputs.projects.value.trim() };
  }
  let snapshot = "";
  const snapshotNow = () => JSON.stringify(values());

  function renderView() {
    const summary = open
      ? [el("div", { className: "community-card-heading" }, [el("span", { className: "card-kicker", text: "YOUR ROSTER REVIEW REQUEST" }),
           el("span", { className: "qotw-status", text: STATUS[open.status][0].toUpperCase() })]),
         el("p", { className: "roster-status-line", text: STATUS[open.status][1] }),
         el("dl", { className: "detail-list" }, [
           el("dt", {}, ["Ally code", unverified()]), el("dd", { text: A.formatAllyCode(open.ally_code) }),
           el("dt", {}, ["SWGOH.GG link", unverified()]), el("dd", {}, [open.swgoh_gg_url ? el("a", { className: "card-link", href: open.swgoh_gg_url, target: "_blank", rel: "noopener noreferrer", text: open.swgoh_gg_url }) : el("span", { className: "empty-note", text: "Not given" })]),
           el("dt", { text: "In-game name" }), el("dd", { text: open.in_game_name || "—" }),
           el("dt", { text: "Goals" }), el("dd", { className: "detail-bio", text: open.goals }),
           el("dt", { text: "Current projects" }), el("dd", { className: "detail-bio", text: open.current_projects || "—" }),
           el("dt", { text: "Sent" }), el("dd", { text: A.formatDate(open.created_at) }),
         ])]
      : [el("p", { className: "card-kicker", text: "APPLY WITH YOUR ACCOUNT" }),
         el("h2", { text: "Request a roster review" }),
         el("p", { className: "panel-lead", text: "We'll fill in what we can from your profile. You can follow your request's status here." })];
    const actions = el("div", { className: "form-actions" }, [editButton]);
    if (open && open.status === "received") {
      actions.append(el("button", { type: "button", className: "button button-outline button-danger", id: "rr-withdraw", text: "Withdraw request",
        onclick: async () => {
          const go = await window.HCEdit.confirm({ title: "Withdraw your request?", message: "Your request will be closed. You can apply again any time.",
            confirmLabel: "Withdraw", cancelLabel: "Keep it" });
          if (!go) return;
          const { data, error } = await client.from("roster_requests").update({ status: "closed" }).eq("id", open.id).select().single();
          if (error) { status.textContent = A.friendlyError(error); status.dataset.kind = "error"; return; }
          all = all.map((r) => (r.id === data.id ? data : r));
          open = null;
          status.textContent = "Request withdrawn.";
          status.dataset.kind = "success";
          renderView();
        } }));
    }
    editButton.textContent = open ? "Edit request" : "Apply on the site";
    editButton.hidden = Boolean(open && open.status !== "received");
    editButton.disabled = banned === true;
    A.fill(view, ...summary, actions,
      banned === true ? el("p", { className: "account-error", text: "Your account is suspended, so you can't send requests right now." }) : null,
      open && open.status !== "received" ? el("p", { className: "field-help", text: "Your request is with the crew, so it can't be edited now." }) : null);
    renderHistory();
  }

  function renderHistory() {
    const past = all.filter((r) => !open || r.id !== open.id);
    A.fill(history, ...(past.length ? [el("h3", { text: "Earlier requests" }), el("ul", { className: "account-list" }, past.map((r) => el("li", {}, [
      el("strong", { text: `${STATUS[r.status][0]} ` }), `· sent ${A.formatDate(r.created_at)} `,
      r.status === "aired" && r.aired_episode ? el("a", { className: "card-link", href: `../podcast/episodes/episode-${r.aired_episode}.html`, text: `Listen to episode ${r.aired_episode}` }) : null,
    ])))] : []));
  }

  window.HCEdit.create({
    name: "roster request", view, form, editButton, cancelButton: cancel, announcer,
    onOpen() {
      const source = open || profile || {};
      inputs.ally.value = source.ally_code ? A.formatAllyCode(source.ally_code) : "";
      inputs.gg.value = source.swgoh_gg_url || "";
      inputs.ign.value = source.in_game_name || "";
      inputs.goals.value = open ? open.goals : "";
      inputs.projects.value = open ? open.current_projects || "" : "";
      ["rr-ally-code", "rr-swgoh-gg", "rr-in-game-name", "rr-goals", "rr-projects"].forEach((id) => setError(id, ""));
      formStatus.textContent = "";
      status.textContent = "";
      document.getElementById("rr-save").textContent = open ? "Save changes" : "Send request";
      snapshot = snapshotNow();
    },
    isDirty: () => snapshotNow() !== snapshot,
    async onSave() {
      const v = values();
      let ok = true;
      setError("rr-ally-code", v.ally.length === 9 ? "" : "Ally codes have 9 digits, like 123-456-789."); ok = ok && v.ally.length === 9;
      const ggOk = !v.gg || A.isSwgohGgUrl(v.gg);
      setError("rr-swgoh-gg", ggOk ? "" : "Use your SWGOH.GG profile link, like https://swgoh.gg/p/123456789/."); ok = ok && ggOk;
      setError("rr-goals", v.goals ? "" : "Tell the crew what you're working toward."); ok = ok && Boolean(v.goals);
      if (!ok) { formStatus.textContent = "Please fix the highlighted fields."; formStatus.dataset.kind = "error"; return false; }
      const row = { ally_code: v.ally, swgoh_gg_url: v.gg || null, in_game_name: v.ign || null, goals: v.goals, current_projects: v.projects || null };
      const { data, error } = open
        ? await client.from("roster_requests").update(row).eq("id", open.id).select().single()
        : await client.from("roster_requests").insert({ ...row, user_id: me.id }).select().single();
      if (error) { formStatus.textContent = A.friendlyError(error); formStatus.dataset.kind = "error"; return false; }
      const wasNew = !open;
      open = data;
      all = [data, ...all.filter((r) => r.id !== data.id)];
      renderView();
      status.textContent = wasNew ? "Request sent. You'll see its status here." : "Changes saved.";
      status.dataset.kind = "success";
      return true;
    },
  });

  renderView();
  panel.hidden = false;
  A.fill(panel, el("div", { className: "roster-form-card roster-account-card" }, [view, form, status, announcer, history]));
})();
