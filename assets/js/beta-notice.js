// Beta notice for listener accounts: ONE place for the wording and the on/off switches.
//
//   enabled: false          -> every beta notice disappears (banner, inline notes, header tag, and
//                              the plain-HTML notes on the sign-in view, Terms and Privacy are hidden)
//   alertsComingSoon: false -> the "alerts are coming soon" note next to the alert switches disappears
//                              (switch it off when Discord alerts launch in Phase 5)
//
// The sign-in view, Terms and Privacy also carry a plain-HTML copy (marked data-beta-notice) so
// they read correctly without JavaScript; this script rewords them from the text below.
window.HC_BETA = {
  enabled: true,
  text: "Accounts are in beta. Listener accounts are still being built and tested. Some features aren't finished, things may break or change, and accounts or data may be reset. Found a problem? Email holotablechaos@gmail.com.",
  short: "Accounts are in beta: features may change and data may be reset. Found a problem? Email holotablechaos@gmail.com.",
  legal: "The listener accounts system is in beta: features may change, and accounts or data may be reset while it is being built and tested.",
  alertsComingSoon: true,
  alertsText: "Alerts are coming soon. These switches save your choice, but no alerts are sent yet.",
};

(() => {
  "use strict";
  const config = window.HC_BETA;
  const doc = document;
  const EMAIL = "holotablechaos@gmail.com";
  const DISMISS_KEY = "hc-beta-banner-dismissed";

  // Text with the contact address as a link. Built with DOM nodes, never HTML strings.
  function richText(text) {
    const fragment = doc.createDocumentFragment();
    String(text).split(EMAIL).forEach((part, index) => {
      if (index > 0) {
        const link = doc.createElement("a");
        link.className = "card-link";
        link.href = `mailto:${EMAIL}`;
        link.textContent = EMAIL;
        fragment.append(link);
      }
      if (part) fragment.append(doc.createTextNode(part));
    });
    return fragment;
  }
  function note(className, text) {
    const node = doc.createElement("div");
    node.className = className;
    node.setAttribute("role", "note");
    const label = doc.createElement("strong");
    label.className = "beta-label";
    label.textContent = "Beta";
    const body = doc.createElement("span");
    body.append(richText(text));
    node.append(label, body);
    return node;
  }
  function sessionGet(key) { try { return window.sessionStorage.getItem(key); } catch { return null; } }
  function sessionSet(key, value) { try { window.sessionStorage.setItem(key, value); } catch { /* ignore */ } }

  function apply() {
    // Plain-HTML copies: reword or hide.
    doc.querySelectorAll("[data-beta-notice]").forEach((node) => {
      const kind = node.getAttribute("data-beta-notice");
      if (kind === "alerts") {
        node.hidden = !config.alertsComingSoon;
        const target = node.querySelector("[data-beta-text]") || node;
        if (config.alertsComingSoon) target.replaceChildren(richText(config.alertsText));
        return;
      }
      node.hidden = !config.enabled;
      const target = node.querySelector("[data-beta-text]");
      if (config.enabled && target) target.replaceChildren(richText(kind === "legal" ? config.legal : config.text));
    });
    if (!config.enabled) return;

    // Header tag beside "Sign in" or the avatar (the header script keeps it when it re-renders).
    const slot = doc.querySelector(".account-slot");
    if (slot && !slot.querySelector(".beta-tag")) {
      // A small badge pinned to the corner of "Sign in" / the avatar: it takes no header width.
      const tag = doc.createElement("span");
      tag.className = "beta-tag";
      tag.textContent = "Beta";
      tag.title = config.short;
      slot.append(tag);
    }

    // Signed-in account page: dismissible for this browser session only.
    const bannerSlot = doc.getElementById("beta-banner");
    if (bannerSlot && sessionGet(DISMISS_KEY) !== "1") {
      const banner = note("beta-notice beta-banner", config.text);
      const close = doc.createElement("button");
      close.type = "button";
      close.className = "beta-dismiss";
      close.setAttribute("aria-label", "Hide the beta notice for this visit");
      close.textContent = "×";
      close.addEventListener("click", () => {
        sessionSet(DISMISS_KEY, "1");
        bannerSlot.replaceChildren();
        const focusTarget = doc.getElementById("account-signed-in");
        if (focusTarget) { focusTarget.setAttribute("tabindex", "-1"); focusTarget.focus(); }
      });
      banner.append(close);
      bannerSlot.replaceChildren(banner);
    }

    // One-line notes above the QotW answer form and the roster review form.
    [doc.querySelector(".qotw-answer-slot"), doc.getElementById("roster-account")].forEach((target) => {
      if (!target || (target.previousElementSibling && target.previousElementSibling.classList.contains("beta-inline"))) return;
      target.before(note("beta-notice beta-inline", config.short));
    });
  }

  if (doc.readyState === "loading") doc.addEventListener("DOMContentLoaded", apply);
  else apply();
})();
