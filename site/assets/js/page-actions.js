const root = document.querySelector(".page-actions");
if (root) {
  const toggle = root.querySelector(".page-actions-toggle");
  const menu = root.querySelector(".page-actions-menu");
  const text = root.querySelector(".page-actions-text");
  const status = root.querySelector("[role=status]");
  const setOpen = (open) => {
    menu.hidden = !open;
    toggle.setAttribute("aria-expanded", String(open));
  };
  toggle.addEventListener("click", () => setOpen(menu.hidden));
  menu.addEventListener("click", (event) => {
    if (event.target.closest("a")) setOpen(false);
  });
  document.addEventListener("click", (event) => {
    if (!root.contains(event.target)) setOpen(false);
  });
  root.addEventListener("focusout", (event) => {
    if (event.relatedTarget && !root.contains(event.relatedTarget)) setOpen(false);
  });
  document.addEventListener("keydown", (event) => {
    if (event.key !== "Escape" || menu.hidden) return;
    const inside = root.contains(document.activeElement);
    setOpen(false);
    if (inside) toggle.focus();
  });

  const clipboard = window.isSecureContext ? navigator.clipboard : undefined;
  if (!clipboard || !clipboard.writeText) {
    root.classList.add("no-copy");
    for (const element of root.querySelectorAll("[data-copy]")) (element.closest("li") ?? element).remove();
    toggle.setAttribute("aria-label", "Page actions");
  } else {
    let timer;
    const show = (message) => {
      text.textContent = message;
      status.textContent = message;
      clearTimeout(timer);
      timer = setTimeout(() => {
        text.textContent = "Copy page";
        status.textContent = "";
      }, 2000);
    };
    const copy = () => {
      const markdown = fetch(root.dataset.markdown).then((response) => {
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        return response.text();
      });
      const fallback = () => markdown.then((value) => clipboard.writeText(value));
      if (typeof ClipboardItem !== "function" || !clipboard.write) return fallback();
      const blob = markdown.then((value) => new Blob([value], { type: "text/plain" }));
      return clipboard.write([new ClipboardItem({ "text/plain": blob })]).catch(fallback);
    };
    for (const button of root.querySelectorAll("[data-copy]")) {
      button.addEventListener("click", () => {
        if (!menu.hidden) {
          setOpen(false);
          toggle.focus();
        }
        copy().then(() => show("Copied"), () => show("Copy failed"));
      });
    }
  }
  root.classList.add("ready");
}
