import * as params from "@params";

const navButton = document.querySelector(".nav-toggle");
const sidebar = document.getElementById("sidebar");
if (navButton && sidebar) {
  const narrow = window.matchMedia(`(max-width: ${params.narrow})`);
  const behind = [document.getElementById("main"), document.querySelector(".site-footer")].filter(Boolean);
  const setOpen = (open) => {
    sidebar.classList.toggle("open", open);
    document.documentElement.classList.toggle("nav-open", open);
    navButton.setAttribute("aria-expanded", String(open));
    const trap = open && narrow.matches;
    for (const element of behind) element.inert = trap;
    if (trap) {
      // Move focus into the drawer and show where the reader is in the tree.
      sidebar.focus({ preventScroll: true });
      sidebar.querySelector('[aria-current="page"]')?.scrollIntoView({ block: "center" });
    }
  };
  const close = () => {
    setOpen(false);
    navButton.focus();
  };
  navButton.addEventListener("click", () => {
    setOpen(!sidebar.classList.contains("open"));
  });
  sidebar.addEventListener("click", (event) => {
    if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    if (event.target.closest("a")) setOpen(false);
  });
  document.querySelector(".scrim")?.addEventListener("click", close);
  document.addEventListener("keydown", (event) => {
    // Escape in the search box belongs to the search (search.js).
    if (event.key === "Escape" && sidebar.classList.contains("open") && !event.target.closest?.(".site-search")) close();
  });
  narrow.addEventListener("change", (event) => {
    if (!event.matches) setOpen(false);
  });
}
