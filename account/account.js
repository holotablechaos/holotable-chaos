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
  const state = { user: null, card: null, profile: null, banned: false };

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
    $("profile-card").replaceChildren(A.personChip(card, { large: true }));
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
    $("avatar-options").replaceChildren(...choices.map((choice) => A.el("label", { className: "avatar-option" }, [
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
    $("display-name-default").textContent = state.card.provider_name ? `"${state.card.provider_name}"` : '"Listener"';
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

  Object.entries(fields).forEach(([key, input]) => {
    input.addEventListener("blur", () => showErrors(A.validateProfile(formValues()).errors, key));
    input.addEventListener("input", () => {
      setStatus($("profile-status"), "");
      if (input.getAttribute("aria-invalid") === "true") showErrors(A.validateProfile(formValues()).errors, key);
    });
  });
  fields.bio.addEventListener("input", updateBioCount);

  $("profile-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    const status = $("profile-status");
    const result = A.validateProfile(formValues());
    showErrors(result.errors);
    if (!result.ok) {
      setStatus(status, "Please fix the highlighted fields.", "error");
      const firstBad = Object.keys(errorIds).find((key) => result.errors[key]);
      if (firstBad) fields[firstBad].focus();
      return;
    }
    const chosen = document.querySelector('input[name="avatarSource"]:checked');
    const row = { id: state.user.id, ...result.row, avatar_source: chosen ? chosen.value : null };
    $("profile-save").disabled = true;
    setStatus(status, "Saving…", "");
    const { error } = await client.from("profiles").upsert(row);
    $("profile-save").disabled = false;
    if (error) {
      setStatus(status, A.friendlyError(error), "error");
      return;
    }
    state.profile = row;
    fields.allyCode.value = row.ally_code ? A.formatAllyCode(row.ally_code) : "";
    setStatus(status, "Saved. Your profile is up to date.", "success");
    await refreshCard();
    renderAvatarOptions();
  });

  // ---------- sign-in methods ----------
  function renderMethods() {
    const identities = state.user.identities || [];
    $("method-list").replaceChildren(...Object.keys(A.PROVIDERS).map((provider) => {
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

  // ---------- alert switches ----------
  const switches = Array.from(document.querySelectorAll("#alert-switches input[data-pref]"));
  function renderPrefs(prefs) {
    switches.forEach((input) => {
      input.checked = Boolean(prefs && prefs[input.dataset.pref]);
      input.disabled = state.banned;
    });
  }
  switches.forEach((input) => input.addEventListener("change", async () => {
    const row = { user_id: state.user.id };
    switches.forEach((item) => { row[item.dataset.pref] = item.checked; });
    setStatus($("alerts-status"), "Saving…", "");
    const { error } = await client.from("notification_prefs").upsert(row);
    if (error) {
      input.checked = !input.checked;
      setStatus($("alerts-status"), A.friendlyError(error), "error");
    } else {
      setStatus($("alerts-status"), "Saved.", "success");
    }
  }));

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
    const [cardResult, profileResult, banResult, prefsResult] = await Promise.all([
      client.rpc("my_member_card"),
      client.from("profiles").select("display_name, bio, in_game_name, ally_code, swgoh_gg_url, avatar_source").eq("id", state.user.id).maybeSingle(),
      client.rpc("is_banned"),
      client.from("notification_prefs").select("episode_alerts, qotw_alerts, roster_aired_dm, weekly_digest").eq("user_id", state.user.id).maybeSingle(),
    ]);
    state.card = cardResult.data || { id: state.user.id, name: "Listener", avatar_url: null, role: null };
    state.profile = profileResult.data || null;
    state.banned = banResult.data === true;
    show("signedIn");
    $("account-intro-text").hidden = true;
    renderHeader();
    announceHeader(state.card);
    fillForm();
    renderMethods();
    renderPrefs(prefsResult.data);
    $("profile-save").disabled = state.banned;
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
