(() => {
  const recipient = "holotablechaos@gmail.com";
  const emailSubject = "Holotable Chaos — General Questions & Feedback";
  const messageTypes = ["General Question", "Podcast Feedback", "Website Feedback", "Suggestion", "Other"];

  function encodeMailto(value) {
    return encodeURIComponent(value).replace(/[!'()*]/g, (character) => `%${character.charCodeAt(0).toString(16).toUpperCase()}`);
  }

  function validateMessage(values) {
    return messageTypes.includes(values.messageType)
      && typeof values.subject === "string" && values.subject.trim().length > 0
      && typeof values.message === "string" && values.message.trim().length > 0
      && (!values.email || /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(values.email.trim()));
  }

  function formatMessage(values) {
    return [
      "Holotable Chaos — General Questions & Feedback",
      "",
      `Name or in-game name: ${values.name.trim() || "Not provided"}`,
      `Email address: ${values.email.trim() || "Not provided"}`,
      `Message type: ${values.messageType}`,
      `Subject: ${values.subject.trim()}`,
      "",
      "Message:",
      values.message.trim(),
    ].join("\n");
  }

  function buildMailto(values) {
    return `mailto:${recipient}?subject=${encodeMailto(emailSubject)}&body=${encodeMailto(formatMessage(values))}`;
  }

  function init(document) {
    const form = document.getElementById("general-feedback-form");
    if (!form) return;

    const fields = {
      name: form.elements.namedItem("name"),
      email: form.elements.namedItem("email"),
      messageType: form.elements.namedItem("messageType"),
      subject: form.elements.namedItem("subject"),
      message: form.elements.namedItem("message"),
    };
    const error = document.getElementById("feedback-form-error");
    const confirmation = document.getElementById("feedback-confirmation");
    const copyField = document.getElementById("feedback-email-copy");
    const emailDraft = document.getElementById("feedback-email-draft");
    const status = document.getElementById("feedback-copy-status");

    form.addEventListener("submit", (event) => {
      event.preventDefault();
      const values = Object.fromEntries(Object.entries(fields).map(([key, field]) => [key, field.value]));
      if (!validateMessage(values)) {
        error.textContent = "Choose a message type and enter a subject and message. Check the email address if you provided one.";
        error.hidden = false;
        const firstInvalid = !fields.messageType.value ? fields.messageType
          : !fields.subject.value.trim() ? fields.subject
            : !fields.message.value.trim() ? fields.message
              : !fields.email.checkValidity() ? fields.email : null;
        firstInvalid?.focus();
        return;
      }

      error.hidden = true;
      copyField.value = formatMessage(values);
      emailDraft.href = buildMailto(values);
      form.hidden = true;
      confirmation.hidden = false;
      confirmation.focus();
      emailDraft.click();
    });

    document.getElementById("feedback-edit-message").addEventListener("click", () => {
      confirmation.hidden = true;
      form.hidden = false;
      fields.subject.focus();
    });

    document.getElementById("feedback-copy-button").addEventListener("click", async () => {
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

  const api = { recipient, emailSubject, messageTypes, validateMessage, formatMessage, buildMailto, init };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  if (typeof document !== "undefined") init(document);
})();
