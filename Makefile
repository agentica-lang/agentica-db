# `make check` checks the code of the package; the rest is the documentation site (Hugo) and the check of its samples.

DART_SASS ?= $(HOME)/.local/opt/dart-sass

.PHONY: check site site-serve site-sass site-samples

# Runs `agentica check` on every .agc file of the package, its orm/, examples/, specs/ and test/ folders, and stops at
# the first failure. Needs agentica on PATH.
check:
	@for file in *.agc */*.agc specs/fixtures/*/*.agc; do \
		case $$file in deps/*|build/*) continue;; esac; \
		agentica check "$$file" || exit 1; \
	done

site site-serve site-sass: export PATH := $(DART_SASS):$(PATH)

site-sass:
	@command -v sass >/dev/null || { echo "The site needs Dart Sass: put its sass on PATH or in $(DART_SASS) (pinned version in .github/workflows/pages.yml)" >&2; exit 1; }

site/highlight/node_modules: site/highlight/package.json site/highlight/package-lock.json
	npm ci --prefix site/highlight --ignore-scripts --no-audit --no-fund
	touch $@

# Builds the site into site/public. HUGO_FLAGS="--baseURL URL" sets the address.
site: site-sass site/highlight/node_modules
	hugo --cleanDestinationDir --source site --panicOnWarning $(HUGO_FLAGS)
	node site/highlight/highlight.mjs site/public
	@# The layouts print the title of a home or a list page, so its content must not start with the same heading.
	@bad=0; for f in $$(find site/public -name index.html); do n=$$(grep -o '<h1' $$f | wc -l); [ $$n -eq 1 ] || { echo "$$f has $$n h1" >&2; bad=1; }; done; [ $$bad -eq 0 ]

site-serve: site-sass
	hugo server --source site

# Runs `agentica check` on every agentica block of site/content (needs agentica on PATH).
site-samples:
	tools/check-site-samples.sh
