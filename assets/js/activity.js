// Account page "Your activity": Question of the Week stats and recent answers (and, later, roster
// request status). Called by account.js after sign-in; missing data just leaves the empty notes.
window.HCActivity = async function (client) {
  "use strict";
  const A = window.HCAccount;
  const el = A.el;
  const target = document.getElementById("activity-qotw");
  if (!target) return;
  const [{ data: stats }, { data: answers }] = await Promise.all([client.rpc("my_qotw_stats"), client.rpc("my_qotw_answers")]);
  if (!stats || !stats.answers) return;
  target.replaceChildren(
    el("p", { className: "field-help" }, [
      `${stats.answers} answer${stats.answers === 1 ? "" : "s"} · current streak ${stats.current_streak} · best ${stats.best_streak} `,
      stats.badge ? el("span", { className: "account-badge", text: `${stats.badge} badge` }) : null]),
    el("ul", { className: "account-list" }, (answers || []).slice(0, 3).map((a) => el("li", {}, [
      el("strong", { text: `QotW #${a.episode}${a.open ? " (open)" : ""}: ` }), a.body.length > 120 ? `${a.body.slice(0, 117)}…` : a.body]))),
    el("p", {}, [el("a", { className: "card-link", href: "../community/question-of-the-week.html", text: "All your answers" })]),
  );
};
