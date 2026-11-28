// General questions & feedback with an account. The email route on this page keeps working for
// everyone; signed-out visitors keep the static "Signed in?" note and never load the Supabase library.
(async () => {
  "use strict";
  const A = window.HCAccount;
  const config = window.HC_SUPABASE_CONFIG;
  const helper = window.HCGeneralFeedback;
  const panel = document.getElementById("feedback-account");
  const note = document.getElementById("feedback-account-note");
  const emailForm = document.getElementById("general-feedback-form");
  if (!A || !helper || !panel || !emailForm || !A.isConfigured(config)) return;
  if (!A.storedSession(config)) return;
  if (!(await A.loadSupabase())) return;
  const client = A.createClient();
  if (!client) return;
  const { data: auth } = await client.auth.getUser();
  if (!auth || !auth.user) return;
  const me = auth.user;
  const el = A.el;
  const STATUS = {
    received: ["Received", "The crew hasn't opened it yet, so you can still edit it."],
    read: ["Read", "The crew has read your message."],
    resolved: ["Resolved", "The crew has dealt with your message."],
    archived: ["Archived", "This message has been filed away."],
  };
  const MAX_SUBJECT = 180;
  const MAX_MESSAGE = 1000;
  const REPLY_NOTE = "We read everything, but we can't reply here. Include a Discord name if you want an answer.";

  const [{ data: card }, { data: banned }, { data: mine }] = await Promise.all([
    client.rpc("my_member_card"),
    client.rpc("is_banned"),
    client.from("feedback").select("id, message_type, subject, message, status, created_at, status_changed_at")
      .eq("user_id", me.id).order("created_at", { ascending: false }).limit(1),
  ]);
  let latest = (mine && mine[0]) || null;
  if (note) note.hidden = true;

  // ---------- "Send with my account" on the existing form ----------
  const fields = {
    messageType: emailForm.elements.namedItem("messageType"),
    subject: emailForm.elements.namedItem("subject"),
    message: emailForm.elements.namedItem("message"),
  };
  const error = document.getElementById("feedback-form-error");
  const sendButton = el("button", { type: "button", className: "button button-outline feedback-send-account", id: "feedback-send-account", text: "Send with my account" });
  const prepareButton = emailForm.querySelector('button[type="submit"]');
  prepareButton.after(sendButton);
  sendButton.disabled = banned === true;

  const confirmation = el("section", { className: "roster-confirmation", id: "feedback-account-confirmation", tabindex: "-1",
    "aria-labelledby": "feedback-account-confirmation-title", "aria-live": "polite", hidden: true }, [
    el("p", { className: "eyebrow", text: "SENT WITH YOUR ACCOUNT" }),
    el("h2", { id: "feedback-account-confirmation-title", text: "Thanks, your message is with the crew." }),
    el("p", { text: `${REPLY_NOTE} You can follow its status here and on your account page.` }),
    el("button", { type: "button", className: "edit-application-link", id: "feedback-send-another", text: "Send another message",
      onclick: () => { confirmation.hidden = true; emailForm.hidden = false; fields.messageType.focus(); } }),
  ]);
  emailForm.after(confirmation);

  function showError(message, field) {
    error.textContent = message;
    error.hidden = false;
    if (field) { field.setAttribute("aria-invalid", "true"); field.focus(); }
  }
  function check(type, subject, message) {
    if (!helper.messageTypes.includes(type)) return ["Choose a message type.", "messageType"];
    if (!subject) return ["Enter a subject.", "subject"];
    if (subject.length > MAX_SUBJECT) return [`Subjects can be up to ${MAX_SUBJECT} characters.`, "subject"];
    if (!message) return ["Enter a message.", "message"];
    if (message.length > MAX_MESSAGE) {
      return [`Messages sent with your account can be up to ${MAX_MESSAGE.toLocaleString("en-US")} characters (yours has ${message.length.toLocaleString("en-US")}). Shorten it, or use Prepare email for a longer message.`, "message"];
    }
    return null;
  }

  let sending = false;
  sendButton.addEventListener("click", async () => {
    if (sending) return;
    Object.values(fields).forEach((field) => field.removeAttribute("aria-invalid"));
    error.hidden = true;
    const type = fields.messageType.value;
    const subject = fields.subject.value.trim();
    const message = fields.message.value.trim();
    const problem = check(type, subject, message);
    if (problem) { showError(problem[0], fields[problem[1]]); return; }
    sending = true;
    sendButton.disabled = true;
    sendButton.textContent = "Sending…";
    const { data, error: failure } = await client.from("feedback")
      .insert({ user_id: me.id, message_type: type, subject, message })
      .select("id, message_type, subject, message, status, created_at, status_changed_at").single();
    sending = false;
    sendButton.disabled = banned === true;
    sendButton.textContent = "Send with my account";
    if (failure) { showError(A.friendlyError(failure)); return; }
    latest = data;
    emailForm.reset();  // clear the draft
    renderView();
    emailForm.hidden = true;
    confirmation.hidden = false;
    confirmation.focus();
  });

  // ---------- who it's from, the reply note, and the latest message ----------
  const view = el("div", { className: "edit-view", id: "feedback-latest-view" });
  const status = el("p", { className: "save-status", id: "feedback-latest-status", role: "status", "aria-live": "polite" });
  const announcer = el("p", { className: "sr-only", "aria-live": "polite" });
  const editButton = el("button", { type: "button", className: "button button-outline edit-button", id: "feedback-edit-latest", text: "Edit message" });
  const edit = {
    type: el("select", { id: "fb-edit-type" }, helper.messageTypes.map((t) => el("option", { value: t, text: t }))),
    subject: el("input", { id: "fb-edit-subject", type: "text", maxlength: String(MAX_SUBJECT) }),
    message: el("textarea", { id: "fb-edit-message", rows: "5", maxlength: String(MAX_MESSAGE) }),
  };
  const editStatus = el("p", { className: "save-status", id: "fb-edit-status", role: "status", "aria-live": "polite" });
  const cancel = el("button", { type: "button", className: "button button-outline", id: "fb-edit-cancel", text: "Cancel" });
  const editField = (input, label) => el("div", { className: "form-field form-field-full" }, [el("label", { for: input.id, text: label }), input]);
  const editForm = el("form", { className: "edit-form", id: "fb-edit-form", novalidate: true, hidden: true }, [
    el("div", { className: "roster-form-grid" }, [editField(edit.type, "Message type"), editField(edit.subject, "Subject"), editField(edit.message, "Message")]),
    el("div", { className: "form-actions" }, [el("button", { type: "submit", className: "button button-primary", id: "fb-edit-save", text: "Save changes" }), cancel, editStatus]),
  ]);

  function renderView() {
    const latestBlock = latest ? el("div", { className: "feedback-latest" }, [
      el("div", { className: "community-card-heading" }, [
        el("span", { className: "card-kicker", text: "YOUR LATEST MESSAGE" }),
        el("span", { className: "qotw-status", text: STATUS[latest.status][0].toUpperCase() }),
      ]),
      el("p", { className: "roster-status-line", text: STATUS[latest.status][1] }),
      el("dl", { className: "detail-list" }, [
        el("dt", { text: "Type" }), el("dd", { text: latest.message_type }),
        el("dt", { text: "Subject" }), el("dd", { text: latest.subject }),
        el("dt", { text: "Message" }), el("dd", { className: "detail-bio", text: latest.message }),
        el("dt", { text: "Sent" }), el("dd", { text: A.formatDate(latest.created_at) }),
      ]),
      latest.status === "received" && banned !== true ? el("div", { className: "form-actions" }, [editButton]) : null,
    ]) : null;
    A.fill(view,
      el("p", { className: "card-kicker", text: "SEND WITH YOUR ACCOUNT" }),
      A.personChip(card || {}, { detail: "Messages you send with your account come from this name." }),
      el("p", { className: "panel-lead", text: "Choose a message type and write a subject and message in the form below, then select Send with my account. Name and email aren't needed. Only you and the show's admins can read it." }),
      el("p", { className: "field-help", id: "feedback-reply-note", text: REPLY_NOTE }),
      banned === true ? el("p", { className: "account-error", text: "Your account is suspended, so you can't send messages with it right now. You can still use email." }) : null,
      latestBlock);
  }

  window.HCEdit.create({
    name: "feedback message", view, form: editForm, editButton, cancelButton: cancel, announcer,
    onOpen() {
      edit.type.value = latest.message_type;
      edit.subject.value = latest.subject;
      edit.message.value = latest.message;
      editStatus.textContent = "";
      status.textContent = "";
    },
    isDirty: () => latest && (edit.type.value !== latest.message_type || edit.subject.value !== latest.subject || edit.message.value !== latest.message),
    async onSave() {
      const problem = check(edit.type.value, edit.subject.value.trim(), edit.message.value.trim());
      if (problem) { editStatus.textContent = problem[0]; editStatus.dataset.kind = "error"; return false; }
      const { data, error: failure } = await client.from("feedback")
        .update({ message_type: edit.type.value, subject: edit.subject.value.trim(), message: edit.message.value.trim() })
        .eq("id", latest.id).select("id, message_type, subject, message, status, created_at, status_changed_at").single();
      if (failure) { editStatus.textContent = A.friendlyError(failure); editStatus.dataset.kind = "error"; return false; }
      latest = data;
      renderView();
      status.textContent = "Changes saved.";
      status.dataset.kind = "success";
      return true;
    },
  });

  renderView();
  A.fill(panel, view, editForm, status, announcer);
  panel.hidden = false;
})();
