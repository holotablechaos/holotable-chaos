// Account page: sign in with Discord or Google, edit an optional profile, connect another
// sign-in method, download data, delete the account. Nothing is created until the listener saves.
(() => {
  "use strict";
  const A = window.HCAccount;
  const client = A && A.createClient();
  const $ = (id) => document.getElementById(id);
  if (!client) return; // "Accounts aren't available" stays visible.

  const views = {
    unavailable: $("account-unavailable"),
    signedOut: $("account-signed-out"),
    signedIn: $("account-signed-in"),
  };
  const fields = {
    displayName: $("display-name"),
    allyCode: $("ally-code"),
    swgohGgUrl: $("swgoh-gg-url"),
    bio: $("bio"),
  };
  const errorIds = {
    displayName: "display-name-error",
    allyCode: "ally-code-error",
    swgohGgUrl: "swgoh-gg-url-error",
    bio: "bio-error",
  };
  let currentUser = null;

  function show(view) {
    Object.entries(views).forEach(([name, node]) => { node.hidden = name !== view; });
  }

  function setMessage(node, text) {
    node.textContent = text || "";
    node.hidden = !text;
  }

  // ---------- signing in ----------
  document.querySelectorAll("[data-sign-in]").forEach((button) => {
    button.addEventListener("click", async () => {
      setMessage($("sign-in-error"), "");
      button.disabled = true;
      const { error } = await client.auth.signInWithOAuth({
        provider: button.dataset.signIn,
        options: { redirectTo: A.returnUrl() },
      });
      if (error) {
        button.disabled = false;
        setMessage($("sign-in-error"), A.friendlyError(error));
      }
    });
  });

  $("sign-out").addEventListener("click", async () => {
    await client.auth.signOut();
    window.location.replace(A.returnUrl());
  });

  // ---------- signed-in view ----------
  async function loadAccount(user) {
    currentUser = user;
    show("signedIn");
    $("account-email").textContent = user.email || "";

    const [profileResult, roleResult, banResult] = await Promise.all([
      client.from("profiles").select("display_name, bio, ally_code, swgoh_gg_url").eq("id", user.id).maybeSingle(),
      client.from("user_roles").select("role").eq("user_id", user.id).maybeSingle(),
      client.rpc("is_banned"),
    ]);

    const profile = profileResult.data || null;
    $("account-name").textContent = A.displayName(profile);
    fields.displayName.value = (profile && profile.display_name) || "";
    fields.allyCode.value = profile && profile.ally_code ? A.formatAllyCode(profile.ally_code) : "";
    fields.swgohGgUrl.value = (profile && profile.swgoh_gg_url) || "";
    fields.bio.value = (profile && profile.bio) || "";

    const role = roleResult.data && roleResult.data.role;
    const badge = $("account-role");
    badge.textContent = role === "owner" ? "Owner" : role === "admin" ? "Admin" : "";
    badge.hidden = !role;
    $("admin-link").hidden = !role;

    setMessage($("account-ban"), banResult.data === true
      ? "Your account is suspended, so you can't make changes right now. You can still download or delete your data."
      : "");

    renderIdentities(user);
  }

  function renderIdentities(user) {
    const identities = user.identities || [];
    const list = $("identity-list");
    list.replaceChildren(...identities.map((identity) => A.el("li", {}, [
      A.el("strong", { text: A.providerLabel(identity.provider) }),
      identity.identity_data && identity.identity_data.email ? ` · ${identity.identity_data.email}` : "",
    ])));
    const actions = $("link-actions");
    actions.replaceChildren(...A.missingProviders(identities).map((provider) => A.el("button", {
      type: "button",
      className: "button button-outline",
      text: `Connect ${A.providerLabel(provider)}`,
      onclick: async () => {
        setMessage($("link-error"), "");
        const { error } = await client.auth.linkIdentity({ provider, options: { redirectTo: A.returnUrl() } });
        if (error) setMessage($("link-error"), A.friendlyError(error));
      },
    })));
  }

  // ---------- profile ----------
  $("profile-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    const status = $("profile-status");
    const result = A.validateProfile({
      displayName: fields.displayName.value,
      allyCode: fields.allyCode.value,
      swgohGgUrl: fields.swgohGgUrl.value,
      bio: fields.bio.value,
    });
    Object.entries(errorIds).forEach(([key, id]) => {
      setMessage($(id), result.errors[key]);
      fields[key].setAttribute("aria-invalid", result.errors[key] ? "true" : "false");
    });
    if (!result.ok) {
      status.textContent = "Please fix the highlighted fields.";
      return;
    }
    $("profile-save").disabled = true;
    status.textContent = "Saving…";
    const { error } = await client.from("profiles").upsert({ id: currentUser.id, ...result.row });
    $("profile-save").disabled = false;
    if (error) {
      status.textContent = A.friendlyError(error);
      return;
    }
    status.textContent = "Saved.";
    $("account-name").textContent = A.displayName(result.row);
    fields.allyCode.value = result.row.ally_code ? A.formatAllyCode(result.row.ally_code) : "";
  });

  // ---------- data download and deletion ----------
  $("download-data").addEventListener("click", async () => {
    const { data, error } = await client.rpc("export_my_data");
    if (error) {
      window.alert(A.friendlyError(error));
      return;
    }
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
        ? "The owner account can't be deleted from the site. Transfer ownership first."
        : A.friendlyError(error));
      return;
    }
    await client.auth.signOut({ scope: "local" });
    window.location.replace(A.returnUrl());
  });

  // ---------- start ----------
  const params = new URLSearchParams(window.location.search + window.location.hash.replace(/^#/, "&"));
  const returnedError = params.get("error_description");

  async function refresh() {
    const { data } = await client.auth.getUser();
    if (data && data.user) {
      await loadAccount(data.user);
    } else {
      show("signedOut");
      if (returnedError) setMessage($("sign-in-error"), returnedError);
    }
    if (params.has("code") || params.has("error") || window.location.hash) {
      window.history.replaceState(null, "", A.returnUrl());
    }
  }

  client.auth.onAuthStateChange((event) => {
    if (event === "SIGNED_IN" || event === "USER_UPDATED") setTimeout(refresh, 0);
    if (event === "SIGNED_OUT") show("signedOut");
  });
  refresh();
})();
