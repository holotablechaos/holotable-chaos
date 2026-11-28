// Shared "read-only until you choose Edit" pattern for self-editable details (profile, alerts,
// and later the QotW answer and roster request forms).
//
//   const section = HCEdit.create({
//     name: "profile",                       // used in announcements ("Editing profile")
//     view: viewElement, form: formElement,  // the read-only view and the edit form (initially hidden)
//     editButton, cancelButton,              // buttons (the form's Save is its submit button)
//     announcer,                             // an aria-live element
//     onOpen() {}, onCancel() {},            // fill the form / discard edits
//     isDirty() { return bool },             // unsaved edits?
//     async onSave() { return true },        // validate + save; return true to go back to view mode
//   });
//
// Escape cancels, Enter in single-line fields never submits, focus moves to the first field when
// editing starts and back to the Edit button afterwards, and leaving the page with unsaved edits
// asks for confirmation.
(function (root) {
  "use strict";
  const openSections = new Set();

  function anyDirty() {
    for (const section of openSections) if (section.isDirty()) return true;
    return false;
  }
  // Discard every open edit with unsaved changes (used when the listener chooses to leave them).
  function discardAll() {
    for (const section of Array.from(openSections)) if (section.isDirty()) section.cancel();
  }
  if (root.addEventListener) {
    root.addEventListener("beforeunload", (event) => {
      if (!anyDirty()) return undefined;
      event.preventDefault();
      event.returnValue = "";
      return "";
    });
  }

  function firstField(form) {
    return Array.from(form.querySelectorAll("input, textarea, select")).find((el) =>
      !el.disabled && !el.readOnly && el.type !== "hidden" && el.offsetParent !== null);
  }

  function create(options) {
    const { name, view, form, editButton, cancelButton, announcer } = options;
    let editing = false;
    let saving = false;
    const announce = (text) => { if (announcer) { announcer.textContent = ""; setTimeout(() => { announcer.textContent = text; }, 30); } };

    const section = {
      get editing() { return editing; },
      isDirty: () => editing && Boolean(options.isDirty && options.isDirty()),
      open() {
        if (editing) return;
        if (options.onOpen) options.onOpen();
        editing = true;
        openSections.add(section);
        view.hidden = true;
        form.hidden = false;
        editButton.setAttribute("aria-expanded", "true");
        announce(`Editing ${name}. Press Escape to cancel.`);
        const field = firstField(form);
        if (field) field.focus();
      },
      close(message) {
        editing = false;
        openSections.delete(section);
        form.hidden = true;
        view.hidden = false;
        editButton.setAttribute("aria-expanded", "false");
        editButton.focus();
        announce(message);
      },
      cancel() {
        if (!editing || saving) return;
        if (options.onCancel) options.onCancel();
        section.close(`Changes to ${name} discarded.`);
      },
    };

    editButton.setAttribute("aria-expanded", "false");
    editButton.addEventListener("click", () => section.open());
    if (cancelButton) cancelButton.addEventListener("click", () => section.cancel());
    form.addEventListener("keydown", (event) => {
      if (event.key === "Escape") { event.preventDefault(); section.cancel(); return; }
      // Enter in a single-line field must not submit; Save is an explicit button.
      if (event.key === "Enter" && event.target.tagName === "INPUT" && !["submit", "button", "checkbox", "radio"].includes(event.target.type)) {
        event.preventDefault();
      }
    });
    form.addEventListener("submit", async (event) => {
      event.preventDefault();
      if (!editing || saving) return;
      saving = true;
      let done = false;
      try { done = await options.onSave(); } finally { saving = false; }
      if (done) section.close(`${name[0].toUpperCase()}${name.slice(1)} saved.`);
    });
    return section;
  }

  // A small accessible confirmation dialog with custom button labels. Resolves true or false.
  function confirmDialog({ title, message, confirmLabel = "Save", cancelLabel = "Cancel", danger = false }) {
    const doc = root.document;
    return new Promise((resolve) => {
      const dialog = doc.createElement("dialog");
      dialog.className = "admin-dialog confirm-dialog";
      dialog.setAttribute("aria-labelledby", "confirm-dialog-title");
      dialog.setAttribute("aria-describedby", "confirm-dialog-message");
      const form = doc.createElement("form");
      form.method = "dialog";
      const heading = doc.createElement("h2");
      heading.id = "confirm-dialog-title";
      heading.textContent = title;
      const text = doc.createElement("p");
      text.id = "confirm-dialog-message";
      text.className = "panel-lead";
      text.textContent = message;
      const actions = doc.createElement("div");
      actions.className = "form-actions";
      const cancel = doc.createElement("button");
      cancel.value = "cancel";
      cancel.className = "button button-outline";
      cancel.textContent = cancelLabel;
      const ok = doc.createElement("button");
      ok.value = "ok";
      ok.className = danger ? "button button-danger-solid" : "button button-primary";
      ok.textContent = confirmLabel;
      actions.append(cancel, ok);
      form.append(heading, text, actions);
      dialog.append(form);
      doc.body.append(dialog);
      dialog.addEventListener("close", () => { resolve(dialog.returnValue === "ok"); dialog.remove(); });
      dialog.showModal();
      cancel.focus();
    });
  }

  const api = { create, anyDirty, discardAll, confirm: confirmDialog };
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.HCEdit = api;
})(typeof window !== "undefined" ? window : globalThis);
