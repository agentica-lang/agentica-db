# `make check` checks the code of the package; the rest is the documentation site (Hugo) and the check of its samples.

DART_SASS ?= $(HOME)/.local/opt/dart-sass

# The paths of the package that hold .agc files: the modules at the root and the folders (not properties/, site/ or
# tools/).
DB_PATHS = *.agc sqlite postgres mysql support orm examples specs test

.PHONY: check fmt-check site site-serve site-sass site-samples

# Runs `agentica check` on every .agc file of the db package (the root: its modules, the folders of the adapters, orm/,
# support/, examples/, specs/ and test/) and of the property tests in properties/, a project of its own (CI on macOS
# and Windows, which has no make, runs the same commands; `agentica install` fetches the pool of the package and the
# prop and pool of properties/ into their deps/).
# Needs agentica on PATH.
check:
	agentica install && agentica check $(DB_PATHS)
	cd properties && agentica install && agentica check *.agc test

# `agentica fmt --check` on the files of `check`.
fmt-check:
	agentica fmt --check $(DB_PATHS)
	cd properties && agentica fmt --check *.agc test

site site-serve site-sass: export PATH := $(DART_SASS):$(PATH)

THEME := site/themes/docs-theme

site-sass:
	@test -e $(THEME)/hugo.toml || { echo "The site needs its theme: git submodule update --init $(THEME)" >&2; exit 1; }
	@command -v sass >/dev/null || { \
		echo "The site needs Dart Sass: put its sass on PATH or in $(DART_SASS)" \
			"(pinned version in .github/workflows/pages.yml)" >&2; \
		exit 1; \
	}

$(THEME)/highlight/node_modules: $(THEME)/highlight/package.json $(THEME)/highlight/package-lock.json
	npm ci --prefix $(THEME)/highlight --ignore-scripts --no-audit --no-fund
	touch $@

# Builds the site into site/public with the docs theme. HUGO_FLAGS="--baseURL URL" sets the address.
site: site-sass $(THEME)/highlight/node_modules
	hugo --cleanDestinationDir --source site --panicOnWarning $(HUGO_FLAGS)
	node $(THEME)/highlight/highlight.mjs site/public
	@# A relative link to no page becomes a link to its source on GitHub (repoPublic): to a content file or to a
	@# folder. Only the footer's "Page source" may be one; link a page by its .md file.
	@if grep -roE 'blob/[^/"]+/(site/content/[^ >"]*|([^ >"/]+/)*[^ >"/.]+/?)"?>[^<]*' site/public \
		| grep -v '>Page source$$'; then echo "a link points at the source on GitHub, not the page" >&2; exit 1; fi
	@# The layouts print the title of a home or a list page, so its content must not start with the same heading.
	@# The redirect page of an alias has no heading, so it is skipped.
	@bad=0; for f in $$(find site/public -name index.html); do \
		grep -q 'http-equiv=refresh' $$f && continue; \
		n=$$(grep -o '<h1' $$f | wc -l); \
		[ $$n -eq 1 ] || { echo "$$f has $$n h1" >&2; bad=1; }; \
	done; [ $$bad -eq 0 ]

site-serve: site-sass
	hugo server --source site

# Runs `agentica check` on every agentica block of site/content (needs agentica on PATH).
site-samples:
	tools/check-site-samples.sh
