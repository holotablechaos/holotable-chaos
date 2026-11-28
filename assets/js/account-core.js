// Shared account helpers for the account and admin pages.
// Pure helpers are exported for Node tests; browser-only helpers need window.supabase.
(function (root) {
  "use strict";

  const PROVIDERS = {
    discord: "Discord",
    google: "Google",
  };

  function clean(value) {
    return typeof value === "string" ? value.trim() : "";
  }

  function normalizeAllyCode(value) {
    return clean(value).replace(/[^0-9]/g, "");
  }

  function formatAllyCode(value) {
    const digits = normalizeAllyCode(value);
    return digits.length === 9 ? `${digits.slice(0, 3)}-${digits.slice(3, 6)}-${digits.slice(6)}` : digits;
  }

  function isSwgohGgUrl(value) {
    return /^https:\/\/swgoh\.gg\/p\/[0-9]{9}\/?$/.test(clean(value));
  }

  // Every field is optional. Returns the row to save (empty text becomes null) and any errors.
  function validateProfile(values) {
    const input = values || {};
    const errors = {};
    const displayName = clean(input.displayName);
    const bio = clean(input.bio);
    const inGameName = clean(input.inGameName);
    const allyCode = normalizeAllyCode(input.allyCode);
    const swgohGgUrl = clean(input.swgohGgUrl);

    if (displayName.length > 40) errors.displayName = "Display names can be up to 40 characters.";
    if (bio.length > 500) errors.bio = "The bio can be up to 500 characters.";
    if (inGameName.length > 40) errors.inGameName = "In-game names can be up to 40 characters.";
    if (clean(input.allyCode) && allyCode.length !== 9) errors.allyCode = "Ally codes have 9 digits, like 123-456-789.";
    if (swgohGgUrl && !isSwgohGgUrl(swgohGgUrl)) {
      errors.swgohGgUrl = "Use your SWGOH.GG profile link, like https://swgoh.gg/p/123456789/.";
    }

    return {
      ok: Object.keys(errors).length === 0,
      errors,
      row: {
        display_name: displayName || null,
        bio: bio || null,
        in_game_name: inGameName || null,
        ally_code: allyCode || null,
        swgoh_gg_url: swgohGgUrl || null,
      },
    };
  }

  function displayName(profile) {
    const name = profile && clean(profile.display_name || profile.name);
    return name || "Listener";
  }

  // ---------- avatars and people ----------
  // The same allowlist the database uses: only Discord's and Google's picture hosts.
  function safeAvatarUrl(url) {
    const value = typeof url === "string" ? url : "";
    if (/^https:\/\/cdn\.discordapp\.com\/(avatars|embed\/avatars)\/[A-Za-z0-9_./-]+$/.test(value)) return value;
    if (/^https:\/\/lh[0-9]\.googleusercontent\.com\/[A-Za-z0-9_./=-]+$/.test(value)) return value;
    return null;
  }

  function providerAvatar(identities, provider) {
    const identity = (identities || []).find((item) => item.provider === provider);
    const data = (identity && identity.identity_data) || {};
    return safeAvatarUrl(data.avatar_url || data.picture);
  }

  // Mirrors private.avatar_url_for(): a chosen provider, initials, or Discord then Google.
  function resolveAvatar(identities, source) {
    if (source === "initials") return null;
    if (source === "discord" || source === "google") return providerAvatar(identities, source);
    return providerAvatar(identities, "discord") || providerAvatar(identities, "google");
  }

  function initials(name) {
    const words = clean(name).replace(/[^\p{L}\p{N} ]/gu, " ").split(/\s+/).filter(Boolean);
    if (!words.length) return "L";
    const letters = words.length === 1 ? [...words[0]].slice(0, 2) : [[...words[0]][0], [...words[words.length - 1]][0]];
    return letters.join("").toUpperCase();
  }

  // Deterministic colour from the account id, from a palette that keeps white initials readable.
  const AVATAR_COLOURS = ["#1f6fb2", "#7a3fb8", "#b23a48", "#1d7f68", "#a8611a", "#3b5bc4", "#8c2f7a", "#2c7d99"];
  function avatarColour(id) {
    let hash = 0;
    for (const char of String(id || "listener")) hash = (hash * 31 + char.codePointAt(0)) >>> 0;
    return AVATAR_COLOURS[hash % AVATAR_COLOURS.length];
  }

  // <span class="avatar"> with the picture, or initials if there is none or it fails to load.
  function avatar(person, size) {
    const name = displayName(person);
    const px = size || 32;
    const node = el("span", { className: "avatar", "aria-hidden": "true", style: `--avatar-size:${px}px;--avatar-bg:${avatarColour(person && person.id)}` },
      [el("span", { className: "avatar-initials", text: initials(name) })]);
    const url = safeAvatarUrl(person && person.avatar_url);
    if (url) {
      const img = el("img", { src: url, alt: "", width: px, height: px, loading: "lazy", decoding: "async", referrerpolicy: "no-referrer" });
      img.addEventListener("error", () => img.remove());
      node.append(img);
    }
    return node;
  }

  // Avatar + name (+ optional badge and detail line). Reused for headers, admin lists, answers.
  function personChip(person, options) {
    const opts = options || {};
    const role = person && person.role;
    return el("span", { className: `person-chip${opts.large ? " person-chip-large" : ""}` }, [
      avatar(person, opts.size || (opts.large ? 72 : 32)),
      el("span", { className: "person-chip-text" }, [
        el("span", { className: "person-chip-name" }, [
          el("span", { text: displayName(person) }),
          opts.showRole !== false && role ? el("span", { className: "account-badge", text: role === "owner" ? "Owner" : "Admin" }) : null,
        ]),
        opts.detail ? el("span", { className: "person-chip-detail", text: opts.detail }) : null,
      ]),
    ]);
  }

  // ---------- signed-in summary for the header (no network, no library) ----------
  const SUMMARY_KEY = "hc-member-v1";
  function storage() {
    try { return root.localStorage; } catch { return null; }
  }
  function sessionStorageKey(config) {
    try { return `sb-${new URL(config.url).hostname.split(".")[0]}-auth-token`; } catch { return null; }
  }
  // The session supabase-js keeps in localStorage, or null. Never throws.
  function storedSession(config) {
    const store = storage();
    const key = config && sessionStorageKey(config);
    if (!store || !key) return null;
    try {
      const session = JSON.parse(store.getItem(key) || "null");
      return session && session.user && session.user.id ? session : null;
    } catch { return null; }
  }
  function saveSummary(card) {
    const store = storage();
    if (!store || !card || !card.id) return;
    try {
      store.setItem(SUMMARY_KEY, JSON.stringify({ id: card.id, name: card.name || null, avatar_url: safeAvatarUrl(card.avatar_url), role: card.role || null }));
    } catch { /* storage full or blocked: the header falls back to the session */ }
  }
  function clearSummary() {
    const store = storage();
    try { if (store) store.removeItem(SUMMARY_KEY); } catch { /* ignore */ }
  }
  // Best available card for the signed-in visitor: the cached summary for this user, else the
  // provider details inside the stored session.
  function headerCard(config) {
    const session = storedSession(config);
    if (!session) return null;
    const user = session.user;
    let cached = null;
    try { cached = JSON.parse((storage() && storage().getItem(SUMMARY_KEY)) || "null"); } catch { cached = null; }
    if (cached && cached.id === user.id) return cached;
    const meta = user.user_metadata || {};
    const claims = meta.custom_claims || {};
    return { id: user.id, name: clean(claims.global_name || meta.full_name || meta.name) || "Listener",
             avatar_url: resolveAvatar(user.identities || [], null) || safeAvatarUrl(meta.avatar_url), role: null };
  }

  function providerLabel(provider) {
    return PROVIDERS[provider] || provider;
  }

  function missingProviders(identities) {
    const linked = new Set((identities || []).map((identity) => identity.provider));
    return Object.keys(PROVIDERS).filter((provider) => !linked.has(provider));
  }

  function friendlyError(error) {
    const message = (error && (error.message || error.error_description)) || "";
    if (/rate_limited|Too many changes/i.test(message)) return "Too many changes in a short time. Please wait a little and try again.";
    if (/isn.t allowed|blocked_text|blocked_word/i.test(message)) return "That text isn't allowed. Please reword it.";
    if (/already taken|name_taken|profiles_display_name_key_unique/i.test(message)) return "That name is already taken. Please choose another.";
    if (/once every 30 days/i.test(message)) return message;
    if (/question is closed|question_closed/i.test(message)) return "This question has closed, so answers can no longer be changed.";
    if (/own answer/i.test(message)) return "You can't vote for your own answer.";
    if (/once a question has closed/i.test(message)) return "You can vote once the question has closed.";
    if (/row-level security|permission denied|42501/i.test(message)) return "You don't have permission to do that.";
    if (/manual linking/i.test(message)) return "Connecting another sign-in method isn't switched on yet.";
    if (/already.*linked|identity_already_exists/i.test(message)) return "That account is already connected to a different Holotable Chaos account.";
    if (/Failed to fetch|NetworkError|network/i.test(message)) return "We couldn't reach the server. Check your connection and try again.";
    return message || "Something went wrong. Please try again.";
  }

  function isConfigured(config) {
    return Boolean(config && /^https:\/\/[a-z0-9-]+\.supabase\.co$|^http:\/\/(127\.0\.0\.1|localhost):\d+$/.test(config.url || "")
      && typeof config.publishableKey === "string" && config.publishableKey.length > 20);
  }

  // The pinned Supabase library (same version and integrity hash as the account pages). Pages that
  // only need it for signed-in visitors load it on demand, so signed-out visitors never fetch it.
  const SUPABASE_SRC = "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.119.0/dist/umd/supabase.js";
  const SUPABASE_SRI = "sha384-uteMfOloLDGt042uDz+xHGF3ym63/WQ6rFq7murQRG8Ih7QrXGEGNtWd8688sb4O";
  function loadSupabase() {
    if (root.supabase && typeof root.supabase.createClient === "function") return Promise.resolve(true);
    if (!root.__hcSupabaseLoading) {
      root.__hcSupabaseLoading = new Promise((resolve) => {
        const script = root.document.createElement("script");
        script.src = SUPABASE_SRC;
        script.integrity = SUPABASE_SRI;
        script.crossOrigin = "anonymous";
        script.onload = () => resolve(true);
        script.onerror = () => resolve(false);
        root.document.head.append(script);
      });
    }
    return root.__hcSupabaseLoading;
  }

  // Returns a Supabase client, or null when accounts aren't configured or the library didn't load.
  function createClient() {
    const config = root.HC_SUPABASE_CONFIG;
    if (!isConfigured(config) || !root.supabase || typeof root.supabase.createClient !== "function") return null;
    if (!root.__hcSupabaseClient) {
      root.__hcSupabaseClient = root.supabase.createClient(config.url, config.publishableKey, {
        auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true, flowType: "pkce" },
      });
    }
    return root.__hcSupabaseClient;
  }

  // Where sign-in providers send people back to: the current page, without query or hash.
  function returnUrl(location) {
    const loc = location || root.location;
    return `${loc.origin}${loc.pathname}`;
  }

  function el(tag, attributes, children) {
    const node = root.document.createElement(tag);
    Object.entries(attributes || {}).forEach(([key, value]) => {
      if (value === null || value === undefined || value === false) return;
      if (key === "text") node.textContent = value;
      else if (key === "className") node.className = value;
      else if (key.startsWith("on") && typeof value === "function") node.addEventListener(key.slice(2), value);
      else node.setAttribute(key, value === true ? "" : String(value));
    });
    (children || []).forEach((child) => {
      if (child === null || child === undefined || child === false) return;
      node.append(typeof child === "string" ? root.document.createTextNode(child) : child);
    });
    return node;
  }

  function formatDate(value) {
    if (!value) return "—";
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return "—";
    return date.toLocaleDateString("en-US", { year: "numeric", month: "short", day: "numeric" });
  }

  const api = {
    PROVIDERS,
    normalizeAllyCode,
    formatAllyCode,
    isSwgohGgUrl,
    validateProfile,
    displayName,
    safeAvatarUrl,
    resolveAvatar,
    initials,
    avatarColour,
    avatar,
    personChip,
    storedSession,
    saveSummary,
    clearSummary,
    headerCard,
    providerLabel,
    missingProviders,
    friendlyError,
    isConfigured,
    createClient,
    loadSupabase,
    SUPABASE_SRC,
    SUPABASE_SRI,
    returnUrl,
    el,
    formatDate,
  };

  if (typeof module === "object" && module.exports) module.exports = api;
  else root.HCAccount = api;
})(typeof window !== "undefined" ? window : globalThis);
