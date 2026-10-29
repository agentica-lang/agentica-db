# agentica-db docs site: design

The agentica-db site uses the design of the Agentica docs site. The rules,
tokens, components and accessibility notes are in
[site/DESIGN.md of Agentica][agentica-design].
The theme files in `site/layouts/` and `site/assets/` are copies of that site
(by way of the Bond site), and a change to the theme is ported from there.
This file lists only what differs. If it and the code disagree, the code is
right: fix this file in the same change.

## Differences

- Title and voice: "agentica-db", the docs of a database package for
  Agentica. `site/hugo.toml` has the title, the description and the base URL
  (`https://agentica-lang.github.io/agentica-db/`).
- Icon: the favicon is a "D" cut out of an accent-colored rounded square. It
  has the same light and dark mechanism as Agentica (the colors are `--accent`
  of both themes), but its own shape. It is in `site/layouts/baseof.html`.
- Trimmed features, which agentica-db does not need:
  - no version in the header or footer, and no release links (agentica-db
    has no release yet);
  - no tour and no language specification (no grammar mount);
  - no `llms.txt` or `llms-full.txt` output. Every page is still published as
    Markdown for the page actions, and search stays.
- Header and footer: a link to the agentica-db repository in both, and the
  footer links to the changelog and to the Agentica site.
- Highlighter: `site/highlight/` is the Agentica one. It fails when a scope
  that the samples use stops matching, and a few scopes that the samples do
  not use are optional (`OPTIONAL` in `highlight.mjs`).
- Samples: every `agentica` block of `site/content/` is a whole program, run
  through `agentica check` by `tools/check-site-samples.sh` (`make
  site-samples`), and run when an `output` block follows it. The blocks take
  no attributes.
- Build: `make site` (Hugo, Dart Sass, the highlighter) and the Pages workflow
  as in Agentica, except that a pull request builds without `configure-pages`.

[agentica-design]: https://github.com/agentica-lang/agentica/blob/master/site/DESIGN.md
