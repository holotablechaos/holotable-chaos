// Header account control on every page.
// Without JavaScript, or for signed-out visitors, the plain "Sign in" link in the HTML stays as is
// and no avatar is loaded. When a sign-in session is stored in this browser, the link becomes an
// avatar-and-name button that opens a small menu: Profile, Admin dashboard (admins only), Sign out.
// It reads the stored session directly, so pages don't load the Supabase library or call the server.
(() => {
  "use strict";
  const A = window.HCAccount;
  const slot = document.querySelector(".account-slot");
  if (!A || !slot || !A.isConfigured(window.HC_SUPABASE_CONFIG)) return;
  const link = slot.querySelector(".account-link");
  if (!link) return;
  let closeCurrent = () => {};
  document.addEventListener("click", (event) => { if (!slot.contains(event.target)) closeCurrent(false); });

  function render() {
    closeCurrent = () => {};
    const card = A.headerCard(window.HC_SUPABASE_CONFIG);
    slot.querySelectorAll(".account-menu-button, .account-menu").forEach((node) => node.remove());
    if (!card) {
      link.hidden = false;
      return;
    }
    link.hidden = true;
    const accountHref = link.getAttribute("href");
    const adminHref = slot.dataset.adminHref;
    const menuId = "account-menu";
    const button = A.el("button", {
      type: "button", className: "account-menu-button", "aria-haspopup": "menu", "aria-expanded": "false",
      "aria-controls": menuId, "aria-label": `Account menu for ${A.displayName(card)}`,
    }, [A.avatar(card, 30), A.el("span", { className: "account-menu-name", text: A.displayName(card) }),
        A.el("span", { className: "account-menu-caret", "aria-hidden": "true", text: "▾" })]);
    const items = [
      A.el("a", { role: "menuitem", href: accountHref, text: "Profile" }),
      card.role ? A.el("a", { role: "menuitem", href: adminHref, text: "Admin dashboard" }) : null,
      A.el("a", { role: "menuitem", href: `${accountHref}?signout=1`, text: "Sign out" }),
    ].filter(Boolean);
    items.forEach((item) => item.setAttribute("tabindex", "-1"));
    const menu = A.el("div", { className: "account-menu", id: menuId, role: "menu", "aria-label": "Account" }, items);
    menu.hidden = true;
    slot.append(button, menu);

    const open = (focusIndex) => {
      menu.hidden = false;
      button.setAttribute("aria-expanded", "true");
      if (typeof focusIndex === "number") items[(focusIndex + items.length) % items.length].focus();
    };
    const close = (returnFocus) => {
      if (menu.hidden) return;
      menu.hidden = true;
      button.setAttribute("aria-expanded", "false");
      if (returnFocus) button.focus();
    };
    button.addEventListener("click", () => (menu.hidden ? open(0) : close(false)));
    button.addEventListener("keydown", (event) => {
      if (event.key === "ArrowDown") { event.preventDefault(); open(0); }
      if (event.key === "ArrowUp") { event.preventDefault(); open(items.length - 1); }
    });
    menu.addEventListener("keydown", (event) => {
      const index = items.indexOf(document.activeElement);
      if (event.key === "ArrowDown") { event.preventDefault(); items[(index + 1) % items.length].focus(); }
      else if (event.key === "ArrowUp") { event.preventDefault(); items[(index - 1 + items.length) % items.length].focus(); }
      else if (event.key === "Home") { event.preventDefault(); items[0].focus(); }
      else if (event.key === "End") { event.preventDefault(); items[items.length - 1].focus(); }
      else if (event.key === "Escape") { event.preventDefault(); close(true); }
      else if (event.key === "Tab") close(false);
    });
    closeCurrent = close;
  }

  render();
  // Stay in step when the visitor signs in or out in another tab, or the account page updates it.
  window.addEventListener("storage", render);
  window.addEventListener("hc-account-changed", render);
})();
