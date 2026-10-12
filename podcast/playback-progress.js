(() => {
  const storagePrefix = "holotable-chaos:episode-progress:v1:";

  document.querySelectorAll("audio.episode-audio").forEach((player) => {
    const episodeMatch = player.getAttribute("aria-label")?.match(/episode\s+(\d+)/i);
    if (!episodeMatch) return;

    const storageKey = `${storagePrefix}${episodeMatch[1]}`;
    let restored = false;
    let lastSavedAt = 0;

    player.addEventListener("loadedmetadata", () => {
      if (restored) return;
      restored = true;

      try {
        const savedTime = Number(localStorage.getItem(storageKey));
        if (Number.isFinite(savedTime) && savedTime > 2 && savedTime < player.duration - 5) {
          player.currentTime = savedTime;
        } else if (savedTime > 0) {
          localStorage.removeItem(storageKey);
        }
      } catch {
        // Playback still works if browser storage is unavailable.
      }
    });

    const saveProgress = () => {
      if (!Number.isFinite(player.currentTime) || player.currentTime < 2) return;
      if (Number.isFinite(player.duration) && player.currentTime >= player.duration - 2) return;

      try {
        localStorage.setItem(storageKey, String(Math.floor(player.currentTime)));
      } catch {
        // Ignore storage errors so they cannot interrupt playback.
      }
    };

    player.addEventListener("timeupdate", () => {
      if (player.currentTime - lastSavedAt >= 5) {
        lastSavedAt = player.currentTime;
        saveProgress();
      }
    });
    player.addEventListener("pause", saveProgress);
    player.addEventListener("ended", () => {
      try {
        localStorage.removeItem(storageKey);
      } catch {
        // Ignore storage errors so they cannot interrupt playback.
      }
    });
    window.addEventListener("pagehide", saveProgress);
  });
})();
