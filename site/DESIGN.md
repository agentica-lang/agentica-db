# agentica-db docs site: design

The look, the layouts, the search tags, the favicon and the highlighter come
from the docs theme, the submodule `site/themes/docs-theme`
(agentica-lang/docs-theme); its README lists the params and its `DESIGN.md`
has the design rules. A change of style is a docs-theme PR, then a submodule
bump here. This file lists only what differs. If it and the code disagree, the
code is right: fix this file in the same change.

## Differences

- Title and voice: "agentica-db", the docs of a database package for
  Agentica. `site/hugo.toml` has the title, the tagline, the description and
  the base URL (`https://www.agentica-lang.com/agentica-db/`).
- Trimmed features, which agentica-db does not need:
  - no version in the header or footer;
  - no `llms.txt` or `llms-full.txt` output (`[outputs]` of `site/hugo.toml`).
    Every page is still published as Markdown for the page actions, and
    search stays.
- Footer: `site/layouts/_partials/footer.html` is the theme's (all releases,
  page source, the repository, the org home) plus the changelog and the
  Agentica site. It is the only layout of the site's own.
- Links between pages name the `.md` file: with `repoPublic`, a relative link
  that Hugo cannot resolve becomes a link to the source on GitHub, and `make
  site` fails on one.
- Samples: every `agentica` block of `site/content/` is a whole program, run
  through `agentica check` by `tools/check-site-samples.sh` (`make
  site-samples`), and run when an `output` block follows it. The blocks take
  no attributes.
- Build: `make site` (Hugo, Dart Sass, the theme's highlighter) and the Pages
  workflow, which checks out the theme and the whole history (the sitemap
  dates come from Git); a pull request builds without `configure-pages`.
