// Question of the Week on the site. The page works without this script (the email button stays).
// Signed-out visitors get a "sign in to answer" link and never load the Supabase library.
// Signed-in listeners can answer the open question (read-only until Edit), see their stats and
// past answers, and read and upvote answers to closed questions.
(async () => {
  "use strict";
  const A = window.HCAccount;
  const config = window.HC_SUPABASE_CONFIG;
  if (!A || !A.isConfigured(config)) return;
  const el = A.el;
  const answerSlot = document.querySelector(".qotw-answer-slot");
  const currentEpisode = answerSlot ? Number(answerSlot.dataset.episode) : null;
  const archiveSlots = Array.from(document.querySelectorAll(".qotw-answers-slot"));
  const archiveList = document.querySelector(".qotw-archive-list");
  const accountHref = "../account/index.html";

  function signedOutView() {
    if (answerSlot) {
      answerSlot.hidden = false;
      A.fill(answerSlot, el("p", { className: "qotw-signin-note" }, [
        "Have a Holotable Chaos account? ", el("a", { className: "card-link", href: accountHref, text: "Sign in to answer here on the site" }),
        ". Or email your answer below.",
      ]));
    }
    if (archiveList && archiveSlots.length) {
      archiveList.before(el("p", { className: "qotw-signin-note qotw-archive-note" }, [
        el("a", { className: "card-link", href: accountHref, text: "Sign in" }), " to read listeners' answers to past questions.",
      ]));
    }
  }

  if (!A.storedSession(config)) { signedOutView(); return; }
  if (!(await A.loadSupabase())) return;            // library blocked: the email button still works
  const client = A.createClient();
  if (!client) return;
  const { data: auth } = await client.auth.getUser();
  if (!auth || !auth.user) { signedOutView(); return; }
  const me = auth.user;

  // ---------- the open question ----------
  async function mountAnswer() {
    if (!answerSlot || !currentEpisode) return;
    const [{ data: question }, { data: mine }, { data: banned }] = await Promise.all([
      client.from("qotw_questions").select("episode, closed_at").eq("episode", currentEpisode).maybeSingle(),
      client.from("qotw_answers").select("id, body, updated_at").eq("episode", currentEpisode).eq("user_id", me.id).maybeSingle(),
      client.rpc("is_banned"),
    ]);
    answerSlot.hidden = false;
    const email = document.getElementById("qotw-email-answer");
    if (!question || question.closed_at) {
      A.fill(answerSlot, el("p", { className: "qotw-signin-note" },
        ["Answering on the site opens shortly for this question. You can email your answer meanwhile."]));
      return;
    }
    if (email) {
      email.classList.remove("button-primary");
      email.classList.add("button-outline");
      email.firstChild.textContent = "Email your answer instead ";
    }
    let saved = mine || null;
    const view = el("div", { className: "edit-view qotw-my-answer" });
    const textarea = el("textarea", { id: "qotw-answer-text", rows: "5", maxlength: "1000", "aria-describedby": "qotw-answer-count qotw-answer-error" });
    const count = el("span", { className: "optional-label", id: "qotw-answer-count" });
    const error = el("p", { className: "field-error", id: "qotw-answer-error", hidden: true });
    const status = el("p", { className: "save-status", id: "qotw-answer-status", role: "status", "aria-live": "polite" });
    const announcer = el("p", { className: "sr-only", "aria-live": "polite" });
    const editButton = el("button", { type: "button", className: "button button-primary edit-button", id: "qotw-answer-edit" });
    const cancel = el("button", { type: "button", className: "button button-outline", id: "qotw-answer-cancel", text: "Cancel" });
    const form = el("form", { className: "edit-form qotw-answer-form", id: "qotw-answer-form", novalidate: true, hidden: true }, [
      el("div", { className: "form-field" }, [el("label", { for: "qotw-answer-text" }, ["Your answer ", count]), textarea, error]),
      el("div", { className: "form-actions" }, [
        el("button", { type: "submit", className: "button button-primary", id: "qotw-answer-save", text: "Save answer" }), cancel]),
    ]);
    const updateCount = () => { count.textContent = `${textarea.value.length} / 1000`; };
    textarea.addEventListener("input", updateCount);
    function renderView() {
      A.fill(view, 
        el("h3", { text: "Your answer" }),
        saved ? el("p", { className: "qotw-answer-body", text: saved.body })
              : el("p", { className: "empty-note", text: "You haven't answered yet." }),
        saved ? el("p", { className: "field-help", text: "You can edit it until the question closes. Other listeners see answers once it closes." }) : null,
        el("div", { className: "form-actions" }, [editButton]),
      );
      editButton.textContent = saved ? "Edit answer" : "Answer on the site";
      editButton.disabled = banned === true;
      if (banned === true) view.append(el("p", { className: "account-error", text: "Your account is suspended, so you can't answer right now." }));
    }
    let snapshot = "";
    window.HCEdit.create({
      name: "answer", view, form, editButton, cancelButton: cancel, announcer,
      onOpen() { textarea.value = saved ? saved.body : ""; snapshot = textarea.value; updateCount(); error.hidden = true; status.textContent = ""; },
      onCancel() { error.hidden = true; },
      isDirty: () => textarea.value !== snapshot,
      async onSave() {
        const body = textarea.value.trim();
        if (!body) { error.textContent = "Write an answer first."; error.hidden = false; textarea.focus(); return false; }
        if (body.length > 1000) { error.textContent = "Answers can be up to 1000 characters."; error.hidden = false; return false; }
        const request = saved
          ? client.from("qotw_answers").update({ body }).eq("id", saved.id).select("id, body, updated_at").single()
          : client.from("qotw_answers").insert({ episode: currentEpisode, user_id: me.id, body }).select("id, body, updated_at").single();
        const { data, error: saveError } = await request;
        if (saveError) { error.textContent = A.friendlyError(saveError); error.hidden = false; return false; }
        saved = data;
        renderView();
        status.textContent = "Saved. Your answer may be featured on the show.";
        status.dataset.kind = "success";
        loadMine();
        return true;
      },
    });
    renderView();
    A.fill(answerSlot, view, form, status, announcer);
  }

  // ---------- your answers, streak and badge ----------
  const mySection = document.getElementById("qotw-me");
  async function loadMine() {
    if (!mySection) return;
    const [{ data: stats }, { data: answers }] = await Promise.all([client.rpc("my_qotw_stats"), client.rpc("my_qotw_answers")]);
    if (!stats) return;
    mySection.hidden = false;
    const tiles = [["Answers", stats.answers], ["Current streak", stats.current_streak], ["Best streak", stats.best_streak]];
    A.fill(mySection, 
      el("div", { className: "section-heading" }, [el("div", {}, [
        el("p", { className: "eyebrow", text: "YOUR QUESTION OF THE WEEK" }),
        el("h2", { id: "qotw-me-title" }, ["Your ", el("em", { text: "answers." })]),
      ]), stats.badge ? el("p", {}, [el("span", { className: "account-badge qotw-badge", text: `${stats.badge} badge` })]) : null]),
      el("div", { className: "stat-grid" }, tiles.map(([label, value]) => el("div", { className: "stat-tile" }, [
        el("span", { className: "stat-value", text: String(value ?? 0) }), el("span", { className: "stat-label", text: label })]))),
      el("p", { className: "field-help", text: "Streaks count consecutive questions you answered; an open question doesn't break a streak until it closes." }),
      answers && answers.length
        ? el("ol", { className: "qotw-mine-list" }, answers.map((a) => el("li", { className: "qotw-mine-item" }, [
            el("p", { className: "card-kicker", text: `QOTW #${a.episode}${a.open ? " · OPEN" : ""}` }),
            el("p", { className: "qotw-mine-question", text: a.question }),
            el("p", { className: "qotw-answer-body", text: a.body }),
            el("p", { className: "field-help" }, [a.featured ? el("span", { className: "account-badge", text: "Featured" }) : null,
              a.open ? "" : ` ${a.votes} upvote${a.votes === 1 ? "" : "s"}`]),
          ])))
        : el("p", { className: "empty-note", text: "Your answers will appear here." }),
    );
  }

  // ---------- answers to closed questions ----------
  async function mountArchive() {
    if (!archiveSlots.length) return;
    const { data: counts } = await client.rpc("qotw_answer_counts");
    const byEpisode = new Map((counts || []).map((row) => [Number(row.episode), Number(row.answers)]));
    archiveSlots.forEach((slot) => {
      const episode = Number(slot.dataset.episode);
      const total = byEpisode.get(episode) || 0;
      if (!total) return;  // most older questions predate answering on the site; keep them uncluttered
      slot.hidden = false;
      const list = el("ol", { className: "qotw-answer-list", id: `qotw-answers-${episode}`, hidden: true });
      const toggle = el("button", { type: "button", className: "button button-outline qotw-show-answers", "aria-expanded": "false",
        "aria-controls": list.id, text: `Show answers (${total})` });
      toggle.addEventListener("click", async () => {
        const open = toggle.getAttribute("aria-expanded") === "true";
        if (open) { list.hidden = true; toggle.setAttribute("aria-expanded", "false"); toggle.textContent = `Show answers (${total})`; return; }
        await renderAnswers(episode, list);
        list.hidden = false;
        toggle.setAttribute("aria-expanded", "true");
        toggle.textContent = "Hide answers";
      });
      A.fill(slot, toggle, list);
    });
  }

  async function renderAnswers(episode, list) {
    const { data, error } = await client.rpc("qotw_answers_for", { p_episode: episode });
    if (error) { A.fill(list, el("li", { className: "account-error", text: A.friendlyError(error) })); return; }
    A.fill(list, ...data.map((answer) => {
      const voteButton = answer.mine ? null : el("button", {
        type: "button", className: `qotw-vote${answer.voted ? " is-voted" : ""}`, "aria-pressed": String(answer.voted),
        "aria-label": `Upvote this answer (${answer.votes} so far)`,
      }, [el("span", { "aria-hidden": "true", text: "▲ " }), String(answer.votes)]);
      if (voteButton) {
        voteButton.addEventListener("click", async () => {
          voteButton.disabled = true;
          const voted = voteButton.getAttribute("aria-pressed") === "true";
          const { error: voteError } = voted
            ? await client.from("qotw_answer_votes").delete().eq("answer_id", answer.id).eq("user_id", me.id)
            : await client.from("qotw_answer_votes").insert({ answer_id: answer.id, user_id: me.id });
          voteButton.disabled = false;
          if (voteError) { window.alert(A.friendlyError(voteError)); return; }
          answer.voted = !voted;
          answer.votes += voted ? -1 : 1;
          voteButton.setAttribute("aria-pressed", String(answer.voted));
          voteButton.classList.toggle("is-voted", answer.voted);
          voteButton.setAttribute("aria-label", `Upvote this answer (${answer.votes} so far)`);
          voteButton.lastChild.textContent = String(answer.votes);
        });
      }
      return el("li", { className: `qotw-answer-item${answer.featured ? " is-featured" : ""}` }, [
        el("div", { className: "qotw-answer-head" }, [
          A.personChip(answer.author, { size: 32 }),
          answer.featured ? el("span", { className: "account-badge", text: "Featured" }) : null,
          answer.mine ? el("span", { className: "account-badge qotw-mine-tag", text: "Your answer" }) : null,
        ]),
        el("p", { className: "qotw-answer-body", text: answer.body }),
        el("div", { className: "qotw-answer-foot" }, [voteButton || el("span", { className: "field-help", text: `${answer.votes} upvote${answer.votes === 1 ? "" : "s"}` })]),
      ]);
    }));
  }

  await Promise.all([mountAnswer(), loadMine(), mountArchive()]);
})();
