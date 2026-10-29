import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import oniguruma from "vscode-oniguruma";
import textmate from "vscode-textmate";

const here = dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);
const BLOCK = /<div class="?agc-code"?>(<div class="?highlight"?><pre[^>]*><code)[^>]*>([\s\S]*?)(<\/code><\/pre><\/div>)<\/div>/g;
const CLASSES = [
  ["comment", "c"],
  ["constant.character.escape", "se"],
  ["punctuation.section.interpolation", "si"],
  ["string", "s"],
  ["punctuation.definition.string", "s"],
  ["constant.numeric", "m"],
  ["constant.language", "kc"],
  ["keyword.operator.logical", "k"],
  ["keyword.control", "k"],
  ["storage.type", "k"],
  ["entity.name.function", "nf"],
  ["entity.name", "nc"],
  ["support.type", "nc"],
  ["variable.other.constant", "no"],
  ["variable.other.enummember", "no"],
];

const OPTIONAL = new Set([
  "comment",
  "constant.character.escape",
  "constant.language",
  "keyword.operator.logical",
  "variable.other.enummember",
]);
const ENTITIES = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'" };

function decode(html) {
  return html
    .replace(/<[^>]*>/g, "")
    .replace(/&(#x[0-9a-f]+|#[0-9]+|[a-z]+);/gi, (entity, name) => {
      if (name[0] !== "#") {
        if (!(name in ENTITIES)) throw new Error(`unknown entity ${entity}`);
        return ENTITIES[name];
      }
      return String.fromCodePoint(name[1] === "x" || name[1] === "X" ? parseInt(name.slice(2), 16) : Number(name.slice(1)));
    });
}

function escape(text) {
  return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

const used = new Set();

function classOf(scopes) {
  for (let i = scopes.length - 1; i >= 0; i--) {
    if (scopes[i].startsWith("meta.embedded")) return null;
    const found = CLASSES.find(([prefix]) => scopes[i] === prefix || scopes[i].startsWith(`${prefix}.`));
    if (found) {
      used.add(found[0]);
      return found[1];
    }
  }
  return null;
}

function render(grammar, source) {
  let state = textmate.INITIAL;
  const lines = source.replace(/\n$/, "").split("\n");
  return lines
    .map((line) => {
      const result = grammar.tokenizeLine(line, state);
      state = result.ruleStack;
      return result.tokens
        .map((token) => {
          const text = escape(line.slice(token.startIndex, token.endIndex));
          const name = classOf(token.scopes);
          return name ? `<span class=${name}>${text}</span>` : text;
        })
        .join("");
    })
    .join("\n");
}

function htmlFiles(directory) {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) return htmlFiles(path);
    return entry.name.endsWith(".html") ? [path] : [];
  });
}

async function loadGrammar() {
  const wasm = readFileSync(require.resolve("vscode-oniguruma/release/onig.wasm"));
  await oniguruma.loadWASM(wasm.buffer.slice(wasm.byteOffset, wasm.byteOffset + wasm.byteLength));
  const registry = new textmate.Registry({
    onigLib: Promise.resolve({
      createOnigScanner: (patterns) => new oniguruma.OnigScanner(patterns),
      createOnigString: (text) => new oniguruma.OnigString(text),
    }),
    loadGrammar: async () => JSON.parse(readFileSync(join(here, "agentica.tmLanguage.json"), "utf8")),
  });
  return registry.loadGrammar("source.agentica");
}

const site = process.argv[2];
if (!site) {
  console.error("usage: node highlight.mjs SITE_DIR");
  process.exit(2);
}
const grammar = await loadGrammar();
function fail(message) {
  console.error(`highlight: ${message}`);
  process.exit(1);
}

let blocks = 0;
for (const file of htmlFiles(site)) {
  const html = readFileSync(file, "utf8");
  let index = 0;
  const out = html.replace(BLOCK, (_match, open, body, close) => {
    blocks++;
    index++;
    let source;
    try {
      source = decode(body);
    } catch (error) {
      fail(`${file}: block ${index}: ${error.message}`);
    }
    const colored = render(grammar, source);
    if (decode(colored) !== source.replace(/\n$/, "")) fail(`${file}: block ${index} changed its text`);
    return `${open} class=language-agentica data-lang=agentica>${colored}${close}`;
  });
  if (/class="?agc-code"?/.test(out)) fail(`${file}: an agentica block has an unexpected shape`);
  if (out !== html) writeFileSync(file, out);
}
if (blocks === 0) fail(`no agentica code blocks found in ${site}`);
// A scope of CLASSES that the grammar renamed would color nothing, so the scopes that the samples of the site use must
// still match; OPTIONAL are the ones that the samples do not use at the moment.
const unused = CLASSES.filter(([prefix]) => !used.has(prefix) && !OPTIONAL.has(prefix)).map(([prefix]) => prefix);
if (unused.length > 0) fail(`no token matched ${unused.join(", ")}: check the scope names in CLASSES`);
console.log(`highlight: ${blocks} agentica code blocks`);
