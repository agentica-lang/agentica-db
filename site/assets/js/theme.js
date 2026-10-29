const button = document.querySelector(".theme-toggle");
if (button) {
  const root = document.documentElement;
  const system = window.matchMedia("(prefers-color-scheme: dark)");
  // The head script sets data-theme from a saved choice; without one the
  // system preference decides.
  const current = () => root.dataset.theme || (system.matches ? "dark" : "light");
  const label = () => {
    button.setAttribute("aria-label", current() === "dark" ? "Switch to light theme" : "Switch to dark theme");
  };
  button.addEventListener("click", () => {
    const next = current() === "dark" ? "light" : "dark";
    root.dataset.theme = next;
    try {
      localStorage.setItem("theme", next);
    } catch (e) {
      // Storage can be blocked; the choice then lasts until the page closes.
    }
    label();
  });
  system.addEventListener("change", label);
  label();
}
