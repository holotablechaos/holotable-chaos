(() => {
  const recipient = "holotablechaos@gmail.com";
  const subject = "Holotable Chaos — Chaos of the Week Submission";

  function encodeMailto(value) {
    return encodeURIComponent(value).replace(/[!'()*]/g, (character) => `%${character.charCodeAt(0).toString(16).toUpperCase()}`);
  }

  function validateSubmission(values) {
    return typeof values.idea === "string" && values.idea.trim().length > 0;
  }

  function formatSubmission(values) {
    return [
      "Holotable Chaos — Chaos of the Week Submission",
      "",
      `In-game name: ${values.inGameName.trim() || "Not provided"}`,
      "",
      "Submission title or idea:",
      values.idea.trim(),
      "",
      "Explanation / details:",
      values.details.trim() || "Not provided",
    ].join("\n");
  }

  function buildMailto(values) {
    const body = formatSubmission(values);
    return `mailto:${recipient}?subject=${encodeMailto(subject)}&body=${encodeMailto(body)}`;
  }

  function init(document) {
    const form = document.getElementById("chaos-of-the-week-form");
    if (!form) return;

    const idea = document.getElementById("chaos-idea");
    const error = document.getElementById("chaos-form-error");
    const confirmation = document.getElementById("chaos-confirmation");
    const copyField = document.getElementById("chaos-email-copy");
    const emailDraft = document.getElementById("chaos-email-draft");
    const status = document.getElementById("chaos-copy-status");

    form.addEventListener("submit", (event) => {
      event.preventDefault();
      const values = {
        inGameName: form.elements.namedItem("inGameName").value,
        idea: form.elements.namedItem("idea").value,
        details: form.elements.namedItem("details").value,
      };
      if (!validateSubmission(values)) {
        idea.setAttribute("aria-invalid", "true");
        error.textContent = "Add a title or idea before preparing your email.";
        error.hidden = false;
        idea.focus();
        return;
      }

      idea.removeAttribute("aria-invalid");
      error.hidden = true;
      copyField.value = formatSubmission(values);
      emailDraft.href = buildMailto(values);
      form.hidden = true;
      confirmation.hidden = false;
      confirmation.focus();
      emailDraft.click();
    });

    idea.addEventListener("input", () => {
      if (idea.value.trim()) {
        idea.removeAttribute("aria-invalid");
        error.hidden = true;
      }
    });

    document.getElementById("chaos-edit-submission").addEventListener("click", () => {
      confirmation.hidden = true;
      form.hidden = false;
      idea.focus();
    });

    document.getElementById("chaos-copy-button").addEventListener("click", async () => {
      try {
        if (navigator.clipboard?.writeText) {
          await navigator.clipboard.writeText(copyField.value);
          status.textContent = "Email body copied. Paste it into a message to holotablechaos@gmail.com.";
          return;
        }
      } catch {
        // Use selection fallback if clipboard permission is unavailable.
      }
      copyField.focus();
      copyField.select();
      copyField.setSelectionRange(0, copyField.value.length);
      const copied = document.execCommand?.("copy");
      status.textContent = copied
        ? "Email body copied. Paste it into a message to holotablechaos@gmail.com."
        : "Select and copy the email body into a message to holotablechaos@gmail.com.";
    });
  }

  const api = { recipient, subject, validateSubmission, formatSubmission, buildMailto, init };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  if (typeof document !== "undefined") init(document);
})();
