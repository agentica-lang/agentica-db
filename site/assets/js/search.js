const MIN_QUERY_LENGTH = 2;
const MAX_RESULTS = 12;
const MAX_PER_PAGE = 4;
const SNIPPET_BEFORE = 50;
const SNIPPET_LENGTH = 160;

const root = document.querySelector(".site-search");
const input = document.getElementById("search-input");
const panel = root && root.querySelector(".search-panel");
const status = document.getElementById("search-status");
const message = root && root.querySelector(".search-message");
const list = document.getElementById("search-results");

let entries = null;
let loading = null;
let results = [];
let active = -1;
let closings = 0;

function loadIndex() {
  if (entries) return Promise.resolve(true);
  if (!loading) {
    loading = fetch(root.dataset.index)
      .then((response) => {
        if (!response.ok) throw new Error(`search index: HTTP ${response.status}`);
        return response.json();
      })
      .then((index) => {
        entries = buildEntries(index);
        return true;
      })
      .catch((error) => {
        console.error(error);
        return false;
      })
      .finally(() => {
        loading = null;
      });
  }
  return loading;
}

function buildEntries(index) {
  const pages = Array.isArray(index && index.pages) ? index.pages : [];
  const built = [];
  for (const page of pages) {
    const sections = Array.isArray(page.sections) ? page.sections : [];
    if (!sections.length || sections[0].id) sections.unshift({ id: "", heading: "", text: "" });
    for (const section of sections) {
      const text = section.text || (section.id ? "" : page.summary || "");
      built.push({
        page,
        id: section.id || "",
        heading: section.heading || "",
        text,
        lowTitle: String(page.title || "").toLowerCase(),
        lowHeading: String(section.heading || "").toLowerCase(),
        lowText: text.toLowerCase(),
      });
    }
  }
  return built;
}

function terms(query) {
  return [...new Set(query.toLowerCase().split(/\s+/).filter((word) => word.length >= MIN_QUERY_LENGTH))].sort((a, b) => b.length - a.length);
}

function wordStart(text, at) {
  return at === 0 || !/[a-z0-9_]/.test(text[at - 1]);
}

function fieldScore(text, term, weight) {
  const at = text.indexOf(term);
  if (at < 0) return 0;
  let score = weight;
  if (wordStart(text, at)) score += weight;
  if (text === term) score += weight * 2;
  return score;
}

function scoreEntry(entry, words, phrase) {
  let score = 0;
  const intro = entry.id === "";
  for (const word of words) {
    const title = fieldScore(entry.lowTitle, word, intro ? 15 : 3);
    const heading = fieldScore(entry.lowHeading, word, 8);
    let count = 0;
    for (let at = entry.lowText.indexOf(word); at >= 0 && count < 5; at = entry.lowText.indexOf(word, at + word.length)) count++;
    if (!title && !heading && !count) return 0;
    score += title + heading + count;
  }
  if (phrase) {
    if (phrase.test(entry.lowHeading)) score += 10;
    if (phrase.test(entry.lowText)) score += 6;
  }
  return score;
}

function search(query) {
  const words = terms(query);
  const ordered = query.toLowerCase().split(/\s+/).filter(Boolean);
  const phrase = ordered.length > 1 ? new RegExp(ordered.map(escapeRegex).join("[\\s._:/()-]*")) : null;
  const scored = [];
  for (const entry of entries) {
    const score = scoreEntry(entry, words, phrase);
    if (score > 0) scored.push({ entry, score });
  }
  scored.sort((a, b) => b.score - a.score);
  const perPage = new Map();
  const picked = [];
  for (const { entry } of scored) {
    const count = perPage.get(entry.page) || 0;
    if (count >= MAX_PER_PAGE) continue;
    perPage.set(entry.page, count + 1);
    picked.push(entry);
    if (picked.length === MAX_RESULTS) break;
  }
  return picked;
}

function escapeHtml(text) {
  return String(text).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
}

function escapeRegex(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function highlight(text, words) {
  if (!words.length) return escapeHtml(text);
  const pattern = new RegExp(`(${words.map(escapeRegex).join("|")})`, "gi");
  return text
    .split(pattern)
    .map((part, i) => (i % 2 ? `<mark>${escapeHtml(part)}</mark>` : escapeHtml(part)))
    .join("");
}

function snippet(entry, words) {
  const text = entry.text;
  let at = -1;
  for (const word of words) {
    const found = entry.lowText.indexOf(word);
    if (found >= 0 && (at < 0 || found < at)) at = found;
  }
  let start = at > SNIPPET_BEFORE ? at - SNIPPET_BEFORE : 0;
  if (start > 0) {
    const space = text.indexOf(" ", start);
    if (space >= 0 && space < at) start = space + 1;
  }
  let end = Math.min(text.length, start + SNIPPET_LENGTH);
  if (end < text.length) {
    const space = text.lastIndexOf(" ", end);
    if (space > start) end = space;
  }
  return (start > 0 ? "… " : "") + highlight(text.slice(start, end), words) + (end < text.length ? " …" : "");
}

function setOpen(open) {
  panel.hidden = !open;
  input.setAttribute("aria-expanded", String(open && results.length > 0));
  if (!open) {
    closings++;
    setActive(-1);
  }
}

function setStatus(text) {
  status.textContent = text;
  message.textContent = text;
}

function setActive(index) {
  const options = list.children;
  if (active >= 0 && options[active]) options[active].setAttribute("aria-selected", "false");
  active = index;
  if (active >= 0 && options[active]) {
    options[active].setAttribute("aria-selected", "true");
    options[active].scrollIntoView({ block: "nearest" });
    input.setAttribute("aria-activedescendant", options[active].id);
  } else {
    input.removeAttribute("aria-activedescendant");
  }
}

function render(query) {
  const words = terms(query);
  list.innerHTML = results
    .map((entry, i) => {
      const href = entry.id ? `${entry.page.url}#${entry.id}` : entry.page.url;
      const title = entry.heading
        ? `${highlight(entry.page.title, words)} <span class="search-sep">›</span> ${highlight(entry.heading, words)}`
        : highlight(entry.page.title, words);
      const body = entry.text ? `<span class="search-snippet">${snippet(entry, words)}</span>` : "";
      return `<li id="search-option-${i}" role="option" aria-selected="false"><a href="${escapeHtml(href)}" tabindex="-1"><span class="search-title">${title}</span>${entry.page.section ? `<span class="search-section">${escapeHtml(entry.page.section)}</span>` : ""}${body}</a></li>`;
    })
    .join("");
  active = -1;
  input.removeAttribute("aria-activedescendant");
}

async function update() {
  const query = input.value.trim();
  if (!terms(query).length) {
    results = [];
    list.innerHTML = "";
    setStatus(query ? `Type a word of at least ${MIN_QUERY_LENGTH} characters.` : "");
    setOpen(query.length > 0);
    return;
  }
  if (!entries) {
    setStatus("Loading…");
    setOpen(true);
    const opened = closings;
    const ready = await loadIndex();
    if (opened !== closings || query !== input.value.trim() || document.activeElement !== input) return;
    if (!ready) {
      results = [];
      list.innerHTML = "";
      setStatus("Search could not load. Type again to retry.");
      return;
    }
  }
  results = search(query);
  render(query);
  setStatus(results.length ? `${results.length} result${results.length === 1 ? "" : "s"}` : "No results.");
  setOpen(true);
}

function openResult(index) {
  const link = list.children[index] && list.children[index].querySelector("a");
  if (link) window.location.href = link.href;
}

function isTyping(target) {
  return target instanceof HTMLElement && (target.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(target.tagName));
}

if (root && input && panel && status && message && list) {
  input.addEventListener("focus", () => {
    void loadIndex();
    if (input.value.trim()) void update();
  });
  input.addEventListener("input", () => void update());
  input.addEventListener("keydown", (event) => {
    if (event.isComposing) return;
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      if (panel.hidden) {
        void update();
        return;
      }
      if (!results.length) return;
      event.preventDefault();
      const step = event.key === "ArrowDown" ? 1 : -1;
      setActive((active + step + results.length + (active < 0 && step < 0 ? 1 : 0)) % results.length);
    } else if (event.key === "Enter") {
      event.preventDefault();
      if (!panel.hidden && results.length) openResult(active >= 0 ? active : 0);
    } else if (event.key === "Escape") {
      if (!panel.hidden) {
        event.stopPropagation();
        event.preventDefault();
        setOpen(false);
      } else if (input.value) {
        event.stopPropagation();
        input.value = "";
      } else {
        input.blur();
      }
    }
  });
  panel.addEventListener("mousedown", (event) => event.preventDefault());
  list.addEventListener("mousemove", (event) => {
    const option = event.target.closest("[role=option]");
    if (option) setActive([...list.children].indexOf(option));
  });
  root.addEventListener("focusout", (event) => {
    if (!root.contains(event.relatedTarget)) setOpen(false);
  });
  document.addEventListener("pointerdown", (event) => {
    if (!root.contains(event.target)) setOpen(false);
  });
  document.addEventListener("keydown", (event) => {
    if (event.isComposing) return;
    const shortcut = (event.key === "k" || event.key === "K") && (event.ctrlKey || event.metaKey) && !event.altKey && !event.shiftKey;
    const slash = event.key === "/" && !event.ctrlKey && !event.metaKey && !event.altKey && !isTyping(event.target);
    if (shortcut || slash) {
      event.preventDefault();
      input.focus();
      input.select();
    }
  });
}
