// Account page "Your activity": Question of the Week stats and recent answers, plus the latest roster
// request's and feedback message's status. Called by account.js after sign-in; missing data just leaves the empty notes.
window.HCActivity = async function (client, state) {
  "use strict";
  const A = window.HCAccount;
  const el = A.el;
  const roster = document.getElementById("activity-roster");
  if (roster && state && state.user) {
    const LABELS = { received: "Received", queued: "In the queue", reviewed: "Reviewed", aired: "Aired", declined: "Not selected", closed: "Closed" };
    const { data: requests } = await client.from("roster_requests").select("status, aired_episode, created_at")
      .eq("user_id", state.user.id).order("created_at", { ascending: false }).limit(1);
    const latest = requests && requests[0];
    if (latest) {
      A.fill(roster, el("p", {}, [el("span", { className: "status-pill", text: LABELS[latest.status] }), ` · sent ${A.formatDate(latest.created_at)} `,
        latest.status === "aired" && latest.aired_episode
          ? el("a", { className: "card-link", href: `../podcast/episodes/episode-${latest.aired_episode}.html`, text: `Listen to episode ${latest.aired_episode}` })
          : el("a", { className: "card-link", href: "../roster-review/index.html", text: "View your request" })]));
    }
  }
  const feedback = document.getElementById("activity-feedback");
  if (feedback && state && state.user) {
    const LABELS = { received: "Received", read: "Read", resolved: "Resolved", archived: "Archived" };
    const { data: messages } = await client.from("feedback").select("status, message_type, created_at")
      .eq("user_id", state.user.id).order("created_at", { ascending: false }).limit(1);
    const latest = messages && messages[0];
    if (latest && LABELS[latest.status]) {
      A.fill(feedback, el("p", {}, [el("span", { className: "status-pill", text: LABELS[latest.status] }),
        ` · ${latest.message_type} · sent ${A.formatDate(latest.created_at)} `,
        el("a", { className: "card-link", href: "../community/index.html#general-questions-feedback", text: "View your message" })]));
    }
  }
  const target = document.getElementById("activity-qotw");
  if (!target) return;
  const [{ data: stats }, { data: answers }] = await Promise.all([client.rpc("my_qotw_stats"), client.rpc("my_qotw_answers")]);
  if (!stats || !stats.answers) return;
  A.fill(target, 
    el("p", { className: "field-help" }, [
      `${stats.answers} answer${stats.answers === 1 ? "" : "s"} · current streak ${stats.current_streak} · best ${stats.best_streak} `,
      stats.badge ? el("span", { className: "account-badge", text: `${stats.badge} badge` }) : null]),
    el("ul", { className: "account-list" }, (answers || []).slice(0, 3).map((a) => el("li", {}, [
      el("strong", { text: `QotW #${a.episode}${a.open ? " (open)" : ""}: ` }), a.body.length > 120 ? `${a.body.slice(0, 117)}…` : a.body]))),
    el("p", {}, [el("a", { className: "card-link", href: "../community/question-of-the-week.html", text: "All your answers" })]),
  );
};
