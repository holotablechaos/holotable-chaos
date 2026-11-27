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
    const allyCode = normalizeAllyCode(input.allyCode);
    const swgohGgUrl = clean(input.swgohGgUrl);

    if (displayName.length > 40) errors.displayName = "Display names can be up to 40 characters.";
    if (bio.length > 500) errors.bio = "The bio can be up to 500 characters.";
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
        ally_code: allyCode || null,
        swgoh_gg_url: swgohGgUrl || null,
      },
    };
  }

  function displayName(profile) {
    const name = profile && clean(profile.display_name);
    return name || "Listener";
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
    if (/not allowed here|blocked_word/i.test(message)) return "Please choose different wording; part of that text is not allowed here.";
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
    providerLabel,
    missingProviders,
    friendlyError,
    isConfigured,
    createClient,
    returnUrl,
    el,
    formatDate,
  };

  if (typeof module === "object" && module.exports) module.exports = api;
  else root.HCAccount = api;
})(typeof window !== "undefined" ? window : globalThis);
