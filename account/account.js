// Account page: sign in with Discord or Google, edit an optional profile, choose a picture,
// connect or disconnect sign-in methods, set alert switches, see activity, download or delete.
// Nothing is stored until the listener saves; empty fields never break anything.
(() => {
  "use strict";
  const A = window.HCAccount;
  const client = A && A.createClient();
  const $ = (id) => document.getElementById(id);
  if (!client) return; // "Accounts aren't available" stays visible.

  const views = { unavailable: $("account-unavailable"), signedOut: $("account-signed-out"), signedIn: $("account-signed-in") };
  const fields = { displayName: $("display-name"), inGameName: $("in-game-name"), allyCode: $("ally-code"), swgohGgUrl: $("swgoh-gg-url"), bio: $("bio") };
  const errorIds = { displayName: "display-name-error", inGameName: "in-game-name-error", allyCode: "ally-code-error", swgohGgUrl: "swgoh-gg-url-error", bio: "bio-error" };
  const PREFS = ["episode_alerts", "qotw_alerts", "roster_aired_dm", "weekly_digest"];
  const state = { user: null, card: null, profile: null, banned: false, nameLockedUntil: null };

  function show(view) {
    Object.entries(views).forEach(([name, node]) => { node.hidden = name !== view; });
  }
  function setMessage(node, text) {
    node.textContent = text || "";
    node.hidden = !text;
  }
  function setStatus(node, text, kind) {
    node.textContent = text || "";
    node.dataset.kind = kind || "";
  }
  function announceHeader(card) {
    if (card) A.saveSummary(card); else A.clearSummary();
    window.dispatchEvent(new Event("hc-account-changed"));
  }

  // ---------- signing in and out ----------
  document.querySelectorAll("[data-sign-in]").forEach((button) => {
    button.addEventListener("click", async () => {
      setMessage($("sign-in-error"), "");
      button.disabled = true;
      const { error } = await client.auth.signInWithOAuth({ provider: button.dataset.signIn, options: { redirectTo: A.returnUrl() } });
      if (error) {
        button.disabled = false;
        setMessage($("sign-in-error"), A.friendlyError(error));
      }
    });
  });

  async function signOut() {
    await client.auth.signOut();
    announceHeader(null);
    window.location.replace(A.returnUrl());
  }
  $("sign-out").addEventListener("click", signOut);

  // ---------- profile header ----------
  function renderHeader() {
    const card = state.card;
    A.fill($("profile-card"), A.personChip(card, { large: true }));
    $("account-member-since").textContent = card.member_since ? `Member since ${A.formatDate(card.member_since)}` : "";
    $("account-email").textContent = state.user.email || "";
    $("admin-link").hidden = !card.role;
    setMessage($("account-ban"), state.banned
      ? "Your account is suspended, so you can't make changes right now. You can still download or delete your data."
      : "");
  }

  async function refreshCard() {
    const { data } = await client.rpc("my_member_card");
    if (data) {
      state.card = data;
      renderHeader();
      announceHeader(data);
    }
  }

  // ---------- avatar picker ----------
  function avatarChoices() {
    const identities = state.user.identities || [];
    const choices = [];
    ["discord", "google"].forEach((provider) => {
      const url = A.resolveAvatar(identities, provider);
      if (url) choices.push({ value: provider, label: `${A.providerLabel(provider)} picture`, url });
    });
    choices.push({ value: "initials", label: "Initials", url: null });
    return choices;
  }

  function renderAvatarOptions() {
    const choices = avatarChoices();
    const saved = state.profile && state.profile.avatar_source;
    const current = choices.some((c) => c.value === saved) ? saved : (choices[0] && choices[0].value);
    A.fill($("avatar-options"), ...choices.map((choice) => A.el("label", { className: "avatar-option" }, [
      A.el("input", { type: "radio", name: "avatarSource", value: choice.value, checked: choice.value === current }),
      A.avatar({ id: state.user.id, name: fields.displayName.value || state.card.name, avatar_url: choice.url }, 48),
      A.el("span", { text: choice.label }),
    ])));
  }

  // ---------- profile form ----------
  function fillForm() {
    const p = state.profile || {};
    fields.displayName.value = p.display_name || "";
    fields.inGameName.value = p.in_game_name || "";
    fields.allyCode.value = p.ally_code ? A.formatAllyCode(p.ally_code) : "";
    fields.swgohGgUrl.value = p.swgoh_gg_url || "";
    fields.bio.value = p.bio || "";
    $("display-name-default").textContent = state.card.provider_name ? `"${state.card.provider_name}" with a short number` : '"Listener" with a short number';
    const locked = Boolean(state.nameLockedUntil);
    fields.displayName.readOnly = locked;
    fields.displayName.setAttribute("aria-readonly", String(locked));
    setMessage($("display-name-lock"), locked ? `You can change your display name again on ${A.formatDate(state.nameLockedUntil)}.` : "");
    updateBioCount();
    renderAvatarOptions();
  }

  function formValues() {
    return { displayName: fields.displayName.value, inGameName: fields.inGameName.value, allyCode: fields.allyCode.value,
             swgohGgUrl: fields.swgohGgUrl.value, bio: fields.bio.value };
  }

  function showErrors(errors, onlyKey) {
    Object.entries(errorIds).forEach(([key, id]) => {
      if (onlyKey && key !== onlyKey) return;
      setMessage($(id), errors[key]);
      fields[key].setAttribute("aria-invalid", errors[key] ? "true" : "false");
    });
  }

  function updateBioCount() {
    $("bio-count").textContent = `${fields.bio.value.length} / 500`;
  }

  // Display name: also ask the server whether it's free and allowed (never says who has it).
  let nameCheck = 0;
  async function checkDisplayName() {
    const value = fields.displayName.value.trim();
    const current = (state.profile && state.profile.display_name) || "";
    if (!value || value === current || fields.displayName.readOnly) return true;
    const ticket = ++nameCheck;
    const { data, error } = await client.rpc("check_display_name", { p_name: value });
    if (ticket !== nameCheck || error) return true; // a newer check is running, or let the save report it
    const message = data === "taken" ? "That name is already taken. Please choose another."
      : data === "not_allowed" ? "That text isn't allowed. Please reword it." : "";
    setMessage($("display-name-error"), message);
    fields.displayName.setAttribute("aria-invalid", message ? "true" : "false");
    return !message;
  }

  Object.entries(fields).forEach(([key, input]) => {
    input.addEventListener("blur", () => {
      showErrors(A.validateProfile(formValues()).errors, key);
      if (key === "displayName" && !A.validateProfile(formValues()).errors.displayName) checkDisplayName();
    });
    input.addEventListener("input", () => {
      setStatus($("profile-form-status"), "");
      if (input.getAttribute("aria-invalid") === "true") showErrors(A.validateProfile(formValues()).errors, key);
    });
  });
  fields.bio.addEventListener("input", updateBioCount);

  // ---------- read-only profile view ----------
  function detail(label, valueNode, extra) {
    return [A.el("dt", {}, [label, extra || null]), A.el("dd", {}, [valueNode])];
  }
  const empty = (text) => A.el("span", { className: "empty-note", text });
  function renderProfileView() {
    const p = state.profile || {};
    const choices = avatarChoices();
    const chosen = choices.find((c) => c.value === p.avatar_source) || choices[0];
    const unverified = () => A.el("span", { className: "unverified-tag", text: "Self-reported · unverified" });
    A.fill($("profile-details"), 
      ...detail("Picture", A.el("span", { className: "detail-picture" }, [
        A.avatar({ id: state.user.id, name: state.card.name, avatar_url: chosen && chosen.url }, 40),
        A.el("span", { text: chosen ? chosen.label : "Initials" })])),
      ...detail("Display name", p.display_name ? A.el("span", { text: p.display_name })
        : empty(`Add a display name (you're shown as "${state.card.name}")`)),
      ...(state.nameLockedUntil ? detail("", A.el("span", { className: "field-help", text: `Display name locked until ${A.formatDate(state.nameLockedUntil)}.` })) : []),
      ...detail("In-game name", p.in_game_name ? A.el("span", { text: p.in_game_name }) : empty("Add your in-game name")),
      ...detail("Ally code", p.ally_code ? A.el("span", { text: A.formatAllyCode(p.ally_code) }) : empty("Add your ally code"), unverified()),
      ...detail("SWGOH.GG link", p.swgoh_gg_url && A.isSwgohGgUrl(p.swgoh_gg_url)
        ? A.el("a", { className: "card-link", href: p.swgoh_gg_url, target: "_blank", rel: "noopener noreferrer", text: p.swgoh_gg_url })
        : empty("Add your SWGOH.GG link"), unverified()),
      ...detail("About you", p.bio ? A.el("span", { className: "detail-bio", text: p.bio }) : empty("Add a short bio")),
    );
    $("profile-edit").disabled = state.banned;
  }

  // ---------- profile edit mode ----------
  let profileSnapshot = "";
  const profileSnapshotNow = () => JSON.stringify({ ...formValues(),
    avatar: (document.querySelector('input[name="avatarSource"]:checked') || {}).value || null });
  async function saveProfile() {
    const status = $("profile-form-status");
    const result = A.validateProfile(formValues());
    showErrors(result.errors);
    if (!result.ok) {
      setStatus(status, "Please fix the highlighted fields.", "error");
      const firstBad = Object.keys(errorIds).find((key) => result.errors[key]);
      if (firstBad) fields[firstBad].focus();
      return false;
    }
    if (!(await checkDisplayName())) {
      setStatus(status, "Please fix the highlighted fields.", "error");
      fields.displayName.focus();
      return false;
    }
    const nameChanged = (result.row.display_name || "") !== ((state.profile && state.profile.display_name) || "");
    if (nameChanged) {
      const until = A.formatDate(new Date(Date.now() + 30 * 86400000).toISOString());
      const go = await window.HCEdit.confirm({
        title: "Lock your display name?",
        message: `Saving this locks your display name until ${until} (30 days). Save?`,
        confirmLabel: "Save", cancelLabel: "Cancel" });
      if (!go) { fields.displayName.focus(); return false; }
    }
    const chosen = document.querySelector('input[name="avatarSource"]:checked');
    const row = { id: state.user.id, ...result.row, avatar_source: chosen ? chosen.value : null };
    $("profile-save").disabled = true;
    setStatus(status, "Saving…", "");
    const { error } = await client.from("profiles").upsert(row);
    $("profile-save").disabled = false;
    if (error) {
      const message = A.friendlyError(error);
      setStatus(status, message, "error");
      if (/taken|isn't allowed|30 days/.test(message) && /display_name|taken|30 days/i.test(`${error.message} ${error.details || ""} ${error.hint || ""}`)) {
        setMessage($("display-name-error"), message);
        fields.displayName.setAttribute("aria-invalid", "true");
      }
      return false;
    }
    state.profile = row;
    if (nameChanged) {
      const { data: until } = await client.rpc("my_name_change_available_at");
      state.nameLockedUntil = until || null;
    }
    await refreshCard();
    setStatus(status, "");
    renderProfileView();
    setStatus($("profile-status"), "Saved. Your profile is up to date.", "success");
    return true;
  }
  const profileEditor = window.HCEdit.create({
    name: "profile", view: $("profile-view"), form: $("profile-form"),
    editButton: $("profile-edit"), cancelButton: $("profile-cancel"), announcer: $("profile-announce"),
    onOpen() {
      setStatus($("profile-status"), "");
      setStatus($("profile-form-status"), "");
      showErrors({});
      fillForm();
      profileSnapshot = profileSnapshotNow();
    },
    onCancel() { fillForm(); showErrors({}); setStatus($("profile-form-status"), ""); },
    isDirty: () => profileSnapshotNow() !== profileSnapshot,
    onSave: saveProfile,
  });

  // ---------- sign-in methods ----------
  function renderMethods() {
    const identities = state.user.identities || [];
    A.fill($("method-list"), ...Object.keys(A.PROVIDERS).map((provider) => {
      const identity = identities.find((item) => item.provider === provider);
      const email = identity && identity.identity_data && identity.identity_data.email;
      const action = identity
        ? A.el("button", { type: "button", className: "button button-outline", text: "Disconnect", disabled: identities.length < 2,
            title: identities.length < 2 ? "Connect another method first; you need at least one." : null,
            onclick: async () => {
              if (!window.confirm(`Disconnect ${A.providerLabel(provider)}? You can connect it again later.`)) return;
              setMessage($("link-error"), "");
              const { error } = await client.auth.unlinkIdentity(identity);
              if (error) { setMessage($("link-error"), A.friendlyError(error)); return; }
              await client.auth.refreshSession();
              await load();
            } })
        : A.el("button", { type: "button", className: "button button-primary", text: `Connect ${A.providerLabel(provider)}`,
            onclick: async () => {
              setMessage($("link-error"), "");
              const { error } = await client.auth.linkIdentity({ provider, options: { redirectTo: A.returnUrl() } });
              if (error) setMessage($("link-error"), A.friendlyError(error));
            } });
      return A.el("li", { className: `method-row${identity ? " is-connected" : ""}` }, [
        A.el("span", { className: `method-icon method-icon-${provider}`, "aria-hidden": "true", text: provider === "discord" ? "D" : "G" }),
        A.el("span", { className: "method-text" }, [
          A.el("strong", { text: A.providerLabel(provider) }),
          A.el("span", { className: "field-help", text: identity ? (email ? `Connected · ${email}` : "Connected") : "Not connected" }),
        ]),
        action,
      ]);
    }));
  }

  // ---------- alert switches (read-only until "Edit alerts") ----------
  const switches = Array.from(document.querySelectorAll("#alert-switches input[data-pref]"));
  const PREF_LABELS = { episode_alerts: "New episodes", qotw_alerts: "New Question of the Week",
                        roster_aired_dm: "Your roster review aired", weekly_digest: "Weekly digest" };
  function renderAlertsView() {
    const prefs = state.prefs || {};
    A.fill($("alerts-summary"), ...PREFS.map((key) => A.el("li", { className: "alert-summary-row" }, [
      A.el("span", { text: PREF_LABELS[key] }),
      A.el("span", { className: `status-pill${prefs[key] ? "" : " is-off"}`, text: prefs[key] ? "On" : "Off" }),
    ])));
    $("alerts-edit").disabled = state.banned;
  }
  const alertsNow = () => switches.map((input) => input.checked).join(",");
  let alertsSnapshot = "";
  window.HCEdit.create({
    name: "alerts", view: $("alerts-view"), form: $("alerts-form"),
    editButton: $("alerts-edit"), cancelButton: $("alerts-cancel"), announcer: $("alerts-announce"),
    onOpen() {
      setStatus($("alerts-status"), "");
      switches.forEach((input) => { input.checked = Boolean(state.prefs && state.prefs[input.dataset.pref]); });
      alertsSnapshot = alertsNow();
    },
    onCancel() { setStatus($("alerts-status"), ""); },
    isDirty: () => alertsNow() !== alertsSnapshot,
    async onSave() {
      const row = { user_id: state.user.id };
      switches.forEach((item) => { row[item.dataset.pref] = item.checked; });
      setStatus($("alerts-status"), "Saving…", "");
      const { error } = await client.from("notification_prefs").upsert(row);
      if (error) { setStatus($("alerts-status"), A.friendlyError(error), "error"); return false; }
      state.prefs = row;
      renderAlertsView();
      setStatus($("alerts-status"), "Saved.", "success");
      return true;
    },
  });

  // ---------- data download and deletion ----------
  $("download-data").addEventListener("click", async () => {
    const { data, error } = await client.rpc("export_my_data");
    if (error) { window.alert(A.friendlyError(error)); return; }
    const blob = new Blob([JSON.stringify(data, null, 2)], { type: "application/json" });
    const link = A.el("a", { href: URL.createObjectURL(blob), download: "holotable-chaos-my-data.json" });
    document.body.append(link);
    link.click();
    link.remove();
    setTimeout(() => URL.revokeObjectURL(link.href), 1000);
  });
  $("delete-confirm").addEventListener("input", (event) => {
    $("delete-account").disabled = event.target.value.trim() !== "DELETE";
  });
  $("delete-account").addEventListener("click", async () => {
    setMessage($("delete-error"), "");
    $("delete-account").disabled = true;
    const { error } = await client.rpc("delete_my_account");
    if (error) {
      $("delete-account").disabled = false;
      setMessage($("delete-error"), /owner/i.test(error.message)
        ? "The owner account can't be deleted from the site. Transfer ownership first." : A.friendlyError(error));
      return;
    }
    await client.auth.signOut({ scope: "local" });
    announceHeader(null);
    window.location.replace(A.returnUrl());
  });

  // ---------- activity (filled in by later features when present) ----------
  async function loadActivity() {
    if (typeof window.HCActivity === "function") await window.HCActivity(client, state);
  }

  // ---------- load ----------
  async function load() {
    const { data } = await client.auth.getUser();
    if (!data || !data.user) {
      show("signedOut");
      announceHeader(null);
      return false;
    }
    state.user = data.user;
    const [cardResult, profileResult, banResult, prefsResult, lockResult] = await Promise.all([
      client.rpc("my_member_card"),
      client.from("profiles").select("display_name, bio, in_game_name, ally_code, swgoh_gg_url, avatar_source").eq("id", state.user.id).maybeSingle(),
      client.rpc("is_banned"),
      client.from("notification_prefs").select("episode_alerts, qotw_alerts, roster_aired_dm, weekly_digest").eq("user_id", state.user.id).maybeSingle(),
      client.rpc("my_name_change_available_at"),
    ]);
    state.nameLockedUntil = lockResult.data || null;
    state.card = cardResult.data || { id: state.user.id, name: "Listener", avatar_url: null, role: null };
    state.profile = profileResult.data || null;
    state.banned = banResult.data === true;
    show("signedIn");
    $("account-intro-text").hidden = true;
    renderHeader();
    announceHeader(state.card);
    state.prefs = prefsResult.data || null;
    if (!profileEditor.editing) { fillForm(); renderProfileView(); }
    renderMethods();
    renderAlertsView();
    loadActivity();
    return true;
  }

  const params = new URLSearchParams(window.location.search + window.location.hash.replace(/^#/, "&"));
  if (params.get("signout") === "1") {
    signOut();
    return;
  }
  const returnedError = params.get("error_description");

  async function start() {
    const signedIn = await load();
    if (!signedIn && returnedError) setMessage($("sign-in-error"), returnedError);
    if (params.has("code") || params.has("error")) window.history.replaceState(null, "", A.returnUrl());
  }
  client.auth.onAuthStateChange((event) => {
    if (event === "SIGNED_IN" || event === "USER_UPDATED") setTimeout(load, 0);
    if (event === "SIGNED_OUT") { show("signedOut"); announceHeader(null); }
  });
  start();
})();
