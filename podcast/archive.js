(() => {
  const form = document.querySelector("#episode-filters");
  const search = document.querySelector("#episode-search");
  const topic = document.querySelector("#episode-topic");
  const clear = document.querySelector("#episode-filter-clear");
  const status = document.querySelector("#episode-filter-status");
  const cards = Array.from(document.querySelectorAll(".episode-grid > .episode-card"));

  if (!form || !search || !topic || !clear || !status || cards.length === 0) return;

  const filterEpisodes = () => {
    const query = search.value.trim().toLocaleLowerCase();
    const selectedTopic = topic.value;
    let visible = 0;

    for (const card of cards) {
      const topics = (card.dataset.topics || "").split(/\s+/).filter(Boolean);
      const searchable = `${card.dataset.search || ""} ${card.textContent} ${topics.join(" ").replace(/-/g, " ")}`.toLocaleLowerCase();
      const matchesQuery = !query || searchable.includes(query);
      const matchesTopic = !selectedTopic || topics.includes(selectedTopic);
      const show = matchesQuery && matchesTopic;
      card.hidden = !show;
      if (show) visible += 1;
    }

    status.textContent = visible === cards.length && !query && !selectedTopic
      ? `Showing all ${cards.length} episodes.`
      : `Showing ${visible} of ${cards.length} episodes.`;
  };

  form.addEventListener("submit", (event) => event.preventDefault());
  search.addEventListener("input", filterEpisodes);
  topic.addEventListener("change", filterEpisodes);
  clear.addEventListener("click", () => {
    form.reset();
    filterEpisodes();
    search.focus();
  });
  filterEpisodes();
})();
