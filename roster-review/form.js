(() => {
  const form = document.getElementById("roster-review-form");
  if (!form) return;

  const confirmation = document.getElementById("roster-confirmation");
  const summary = document.getElementById("form-error-summary");
  const applicationCopy = document.getElementById("application-copy");
  const emailLink = document.getElementById("open-email-draft");
  const recipient = "holotablechaos@gmail.com";
  const subject = "Holotable Chaos Roster Review Application";
  const requiredFields = Array.from(form.querySelectorAll("[required]"));

  const fieldLabels = {
    "in-game-name": "In-game name",
    "ally-code": "Ally Code",
    "galactic-power": "Galactic Power",
    goals: "Goals",
    "next-major-goal": "Next major goal",
  };

  function isFieldValid(field) {
    if (field.type === "number") {
      return field.value.trim() !== "" && field.validity.valid;
    }
    return field.value.trim() !== "";
  }

  function updateFieldError(field) {
    const error = document.getElementById(`${field.id}-error`);
    const valid = isFieldValid(field);

    field.setAttribute("aria-invalid", String(!valid));
    if (error) {
      error.textContent = valid
        ? ""
        : field.type === "number" && field.value.trim() !== ""
          ? "Enter GP in millions, greater than 0, with up to two decimal places."
          : `${fieldLabels[field.id] || "This field"} is required.`;
      error.hidden = valid;
    }

    return valid;
  }

  requiredFields.forEach((field) => {
    field.addEventListener("input", () => {
      if (field.getAttribute("aria-invalid") === "true") updateFieldError(field);
    });
    field.addEventListener("blur", () => updateFieldError(field));
  });

  function readValue(name) {
    return form.elements.namedItem(name).value.trim();
  }

  function formatApplication() {
    const galacticPower = `${Number(readValue("galacticPower")).toLocaleString("en-US", { maximumFractionDigits: 2 })}M`;
    return [
      "Holotable Chaos Roster Review Application",
      "",
      `In-game name: ${readValue("inGameName")}`,
      `Ally Code: ${readValue("allyCode")}`,
      `Galactic Power: ${galacticPower}`,
      "",
      "Goals:",
      readValue("goals"),
      "",
      "Current projects:",
      readValue("currentProjects") || "Not provided",
      "",
      "Next major goal:",
      readValue("nextMajorGoal"),
      "",
      "Additional context:",
      readValue("additionalContext") || "Not provided",
    ].join("\n");
  }

  form.addEventListener("submit", (event) => {
    event.preventDefault();

    const invalidFields = requiredFields.filter((field) => !updateFieldError(field));
    if (invalidFields.length > 0) {
      summary.textContent = `Please fix the ${invalidFields.length} required field${invalidFields.length === 1 ? "" : "s"} marked below.`;
      summary.hidden = false;
      invalidFields[0].focus();
      return;
    }

    summary.hidden = true;
    const body = formatApplication();
    applicationCopy.value = body;
    emailLink.href = `mailto:${recipient}?subject=${encodeURIComponent(subject)}&body=${encodeURIComponent(body)}`;
    form.hidden = true;
    confirmation.hidden = false;
    confirmation.focus();

    // Open the draft separately so the copyable fallback stays available here.
    emailLink.click();
  });

  document.getElementById("edit-application").addEventListener("click", () => {
    confirmation.hidden = true;
    form.hidden = false;
    form.querySelector("[required]").focus();
  });

  document.getElementById("copy-application").addEventListener("click", async () => {
    const status = document.getElementById("copy-status");
    try {
      if (navigator.clipboard?.writeText) {
        await navigator.clipboard.writeText(applicationCopy.value);
        status.textContent = "Application details copied. Paste them into an email to holotablechaos@gmail.com.";
        return;
      }
    } catch {
      // Use the selection fallback below when clipboard access is unavailable.
    }

    applicationCopy.focus();
    applicationCopy.select();
    applicationCopy.setSelectionRange(0, applicationCopy.value.length);
    const copied = document.execCommand?.("copy");
    status.textContent = copied
      ? "Application details copied. Paste them into an email to holotablechaos@gmail.com."
      : "Select the application text above and copy it into an email to holotablechaos@gmail.com.";
  });
})();
