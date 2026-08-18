PACKAGE = amber-odin
VERSION ?= 2026.06+dev
REVISION ?= 1
ARCH ?= amd64
SOURCE_DIR ?= $(shell dirname "$$(command -v odin 2>/dev/null)")
BRANCH ?= main
REMOTE ?= origin

# After a fetch, its VERSION/SOURCE_DIR become the defaults, so a plain
# `make deb` (e.g. from amberlinux-apt's build-suite) rebuilds the
# fetched upstream release instead of whatever odin is on PATH.
# Command-line arguments still override.
-include build/upstream/make_args

DEB = dist/$(PACKAGE)_$(VERSION)-$(REVISION)_$(ARCH).deb
OLS_DEB = dist/amber-ols_$(VERSION)-$(REVISION)_$(ARCH).deb
RELEASE_FILE = RELEASE.md
ROOT_COMMIT_MSG ?= Initial amber-odin

.PHONY: install deps release-check check-release fetch deb deb-upstream build check ci lint deb-path release push force-push deb-install deb-remove clean fetch-ols deb-ols check-ols check-no-agent-files

# System dependencies for building the .deb. The Odin compiler itself is
# repackaged from SOURCE_DIR so we do not rely on Ubuntu's unrelated odin package.
install:
	sudo apt install dpkg-dev clang shellcheck

release-check check-release:
	python3 scripts/check_odin_release.py --current '$(VERSION)'

# Fetch the latest compiled upstream release (or TAG=dev-YYYY-MM),
# sha256-verified against the GitHub API, then build and check the deb
# from it. This is the path CI runs monthly; VERSION/SOURCE_DIR come
# from the fetch, not from a local odin install.
fetch:
	python3 scripts/fetch_odin.py --dest build/upstream $(if $(TAG),--tag $(TAG)) --arch $(ARCH)

deb-upstream: fetch
	$(MAKE) check check-ols $$(cat build/upstream/make_args)

# ols (Odin Language Server) rides the same monthly release as a second
# package, compiled from source with the exact compiler in SOURCE_DIR so
# the pair cannot skew. The ols master commit is the pin (recorded in
# build/ols-src/COMMIT and the package changelog).
fetch-ols:
	python3 scripts/fetch_ols.py --dest build/ols-src $(if $(OLS_COMMIT),--commit $(OLS_COMMIT))

deb-ols: fetch-ols
	@test -x "$(SOURCE_DIR)/odin" || { echo "SOURCE_DIR must contain an executable odin binary"; exit 1; }
	# Keeps the throwaway build/ols-src path out of the .deb.
	cd build/ols-src && PATH="$(abspath $(SOURCE_DIR)):$$PATH" \
	    odin build src/ -collection:src=src -out:ols -o:speed -source-code-locations:filename -define:VERSION=$(VERSION)
	rm -rf out/ols-deb out/shlibwork-ols
	mkdir -p out/ols-deb/usr/lib/amber-ols
	install -m755 build/ols-src/ols out/ols-deb/usr/lib/amber-ols/ols
	# ols is a language server run by an editor, not from autostart: no crash log
	# depends on its symbols, so unlike the suite's apps it is stripped.
	strip --strip-unneeded out/ols-deb/usr/lib/amber-ols/ols
	cp -a build/ols-src/builtin out/ols-deb/usr/lib/amber-ols/builtin
	install -d out/ols-deb/usr/bin
	ln -s ../lib/amber-ols/ols out/ols-deb/usr/bin/ols
	install -D -m644 packaging/copyright-ols out/ols-deb/usr/share/doc/amber-ols/copyright
	install -D -m644 packaging/lintian-overrides-ols \
		out/ols-deb/usr/share/lintian/overrides/amber-ols
	# Wrapped: lintian caps a changelog line at 80 and the commit alone is 40.
	printf 'amber-ols (%s-%s) noble; urgency=medium\n\n  * ols commit %s,\n    built with the matching amber-odin compiler.\n\n -- Hyperquader <hyperquader@gmail.com>  %s\n' \
		'$(VERSION)' '$(REVISION)' "$$(cat build/ols-src/COMMIT)" "$$(date -R)" \
		| gzip -9n > out/ols-deb/usr/share/doc/amber-ols/changelog.Debian.gz
	mkdir -p out/ols-deb/DEBIAN
	find out/ols-deb -type d -exec chmod 755 {} +
	find out/ols-deb -type f ! -perm -111 -exec chmod 644 {} +
	cd out/ols-deb && find . -type f -not -path './DEBIAN/*' -printf '%P\n' | sort | xargs md5sum > DEBIAN/md5sums
	mkdir -p out/shlibwork-ols/debian
	printf 'Source: amber-ols\n\nPackage: amber-ols\nArchitecture: $(ARCH)\n' > out/shlibwork-ols/debian/control
	cd out/shlibwork-ols && dpkg-shlibdeps -O ../ols-deb/usr/lib/amber-ols/ols > deps.txt
	deps="$$(sed 's/^shlibs:Depends=//' out/shlibwork-ols/deps.txt)"; \
	if [ -n "$$deps" ]; then depends="$$deps, amber-odin (>= $(VERSION))"; else depends="amber-odin (>= $(VERSION))"; fi; \
	sed -e 's/@VERSION@/$(VERSION)/' \
		-e 's/@REVISION@/$(REVISION)/' \
		-e 's/@ARCH@/$(ARCH)/' \
		-e "s/@SIZE@/$$(du -sk out/ols-deb --exclude=DEBIAN | cut -f1)/" \
		-e "s|@DEPENDS@|$$depends|" \
		packaging/control-ols.in > out/ols-deb/DEBIAN/control
	mkdir -p dist
	dpkg-deb --build --root-owner-group out/ols-deb $(OLS_DEB)

# The check speaks real LSP to the packaged binary: an initialize request
# must draw a JSON-RPC response announcing the version we claim to ship.
check-ols: deb-ols
	dpkg-deb -f $(OLS_DEB) Package | grep -qx 'amber-ols'
	dpkg-deb -f $(OLS_DEB) Version | grep -qx '$(VERSION)-$(REVISION)'
	dpkg-deb -f $(OLS_DEB) Depends | grep -qw 'amber-odin'
	dpkg-deb -c $(OLS_DEB) | grep './usr/bin/ols -> ../lib/amber-ols/ols' >/dev/null
	dpkg-deb -c $(OLS_DEB) | grep './usr/lib/amber-ols/builtin/' >/dev/null
	rm -rf /tmp/amber-ols-check
	mkdir -p /tmp/amber-ols-check
	dpkg-deb -x $(OLS_DEB) /tmp/amber-ols-check
	@body='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":null,"capabilities":{}}}'; \
	len=$$(printf '%s' "$$body" | wc -c); \
	{ printf 'Content-Length: %d\r\n\r\n' "$$len"; printf '%s' "$$body"; } \
	    | timeout 15 /tmp/amber-ols-check/usr/bin/ols > build/ols-check.out 2>/dev/null || true; \
	grep -q '"jsonrpc"' build/ols-check.out || { echo "check-ols: no JSON-RPC response"; exit 1; }; \
	grep -q 'Starting Odin Language Server $(VERSION)' build/ols-check.out \
	    || { echo "check-ols: version banner mismatch"; exit 1; }; \
	echo "check-ols: LSP handshake OK ($(VERSION))"

# deb produces BOTH packages (like amberlin-runtime's deb target does):
# the compiler deb below plus amber-ols via the prerequisite.
deb: deb-ols
	@test -n "$(SOURCE_DIR)" || { echo "odin not found on PATH; set SOURCE_DIR=/path/to/odin-install"; exit 1; }
	@test -x "$(SOURCE_DIR)/odin" || { echo "SOURCE_DIR must contain an executable odin binary"; exit 1; }
	rm -rf out/deb out/shlibwork
	mkdir -p out/deb/usr/lib/$(PACKAGE)
	cp -a "$(SOURCE_DIR)"/. out/deb/usr/lib/$(PACKAGE)/
	install -d out/deb/usr/bin
	ln -s ../lib/$(PACKAGE)/odin out/deb/usr/bin/odin
	install -D -m644 packaging/lintian-overrides out/deb/usr/share/lintian/overrides/$(PACKAGE)
	install -D -m644 packaging/debian/copyright out/deb/usr/share/doc/$(PACKAGE)/copyright
	printf 'amber-odin (%s-%s) noble; urgency=medium\n\n  * Repackaging of the upstream Odin compiler release.\n\n -- Hyperquader <hyperquader@gmail.com>  %s\n' \
		'$(VERSION)' '$(REVISION)' "$$(date -R)" \
		| gzip -9n > out/deb/usr/share/doc/$(PACKAGE)/changelog.Debian.gz
	mkdir -p out/deb/DEBIAN
	find out/deb -type d -exec chmod 755 {} +
	find out/deb -type f ! -perm -111 -exec chmod 644 {} +
	cd out/deb && find . -type f -not -path './DEBIAN/*' -printf '%P\n' | sort | xargs md5sum > DEBIAN/md5sums
	mkdir -p out/shlibwork/debian
	printf 'Source: $(PACKAGE)\n\nPackage: $(PACKAGE)\nArchitecture: $(ARCH)\n' > out/shlibwork/debian/control
	cd out/shlibwork && dpkg-shlibdeps -O ../deb/usr/lib/$(PACKAGE)/odin > deps.txt
	deps="$$(sed 's/^shlibs:Depends=//' out/shlibwork/deps.txt)"; \
	if [ -n "$$deps" ]; then depends="$$deps, clang"; else depends="clang"; fi; \
	sed -e 's/@VERSION@/$(VERSION)/' \
		-e 's/@REVISION@/$(REVISION)/' \
		-e 's/@ARCH@/$(ARCH)/' \
		-e "s/@SIZE@/$$(du -sk out/deb --exclude=DEBIAN | cut -f1)/" \
		-e "s|@DEPENDS@|$$depends|" \
		packaging/control.in > out/deb/DEBIAN/control
	mkdir -p dist
	dpkg-deb --build --root-owner-group out/deb $(DEB)

check: deb
	dpkg-deb -f $(DEB) Package | grep -qx '$(PACKAGE)'
	dpkg-deb -f $(DEB) Version | grep -qx '$(VERSION)-$(REVISION)'
	dpkg-deb -f $(DEB) Provides | grep -qw 'odin-compiler'
	dpkg-deb -f $(DEB) Conflicts | grep -qw 'odin'
	dpkg-deb -c $(DEB) | grep -q './usr/bin/odin -> ../lib/$(PACKAGE)/odin'
	rm -rf /tmp/$(PACKAGE)-check
	mkdir -p /tmp/$(PACKAGE)-check
	dpkg-deb -x $(DEB) /tmp/$(PACKAGE)-check
	/tmp/$(PACKAGE)-check/usr/bin/odin version

release: check
	python3 scripts/write_release.py \
		--package '$(PACKAGE)' \
		--version '$(VERSION)-$(REVISION)' \
		--arch '$(ARCH)' \
		--deb '$(DEB)' \
		--source-dir '$(SOURCE_DIR)' \
		--output '$(RELEASE_FILE)'

push:
	git push "$(REMOTE)" "$(BRANCH)"

# Agent files are never published. Two ways they get in: already tracked, or
# present-and-unignored when `git add -A` below sweeps the whole tree. Both are
# checked here, because a squashed history shows no file being added — a stray
# path simply appears in the root commit as though it always belonged.
check-no-agent-files:
	@bad=$$(git ls-files | grep -E '(^|/)(\.mcp\.json|\.claude/|\.claude-amber/)' || true); \
	if [ -n "$$bad" ]; then \
		echo "agent files are tracked and must not be published:"; \
		printf '  %s\n' $$bad; \
		echo "fix: git rm -r --cached <path>, then add it to .gitignore"; \
		exit 2; \
	fi
	@for p in .mcp.json .claude .claude-amber; do \
		if [ -e "$$p" ] && ! git check-ignore -q "$$p"; then \
			echo "$$p exists and is not gitignored — 'git add -A' would publish it"; \
			echo "fix: add $$p to .gitignore"; \
			exit 2; \
		fi; \
	done
	@echo "no agent files staged for publication"

force-push: release-check check-no-agent-files
	@test -z "$$(git status --porcelain)" || { \
		echo "Working tree is dirty. Commit, stash, or revert changes first."; \
		exit 2; \
	}
	@orig_branch="$$(git branch --show-current)"; \
	tmp_branch="root-squash-$$(date +%s)"; \
	git checkout --orphan "$$tmp_branch"; \
	git add -A; \
	git commit -S -m "$(ROOT_COMMIT_MSG)"; \
	git branch -D "$(BRANCH)" 2>/dev/null || true; \
	git branch -m "$(BRANCH)"; \
	git push --force --set-upstream "$(REMOTE)" "$(BRANCH)"; \
	echo "Rewrote $$orig_branch as signed root commit on $(REMOTE)/$(BRANCH)."

# Suite Makefile contract (see amberlinux-apt/docs/PACKAGING.md):
# deps/build/ci aliases, and deb-path printing the newest built deb --
# the seam amberlinux-apt's add-suite ingests through.
deps: install
build: deb
ci: check
lint: deb
	@python3 -m py_compile scripts/*.py && echo "lint: OK"
	@if command -v shellcheck >/dev/null; then \
		git ls-files | while read -r f; do \
			case "$$f" in *.sh|*.bash) echo "$$f";; \
			*) head -1 "$$f" 2>/dev/null | grep -q '^#!.*sh' && echo "$$f";; esac; \
		done | xargs -r shellcheck --severity=warning && echo "shellcheck OK"; \
	else echo "shellcheck not installed — skipping (apt install shellcheck)"; fi
	@if command -v lintian >/dev/null; then lintian --no-tag-display-limit -L '>=pedantic' $(DEB) $(OLS_DEB); \
	else echo "lintian not installed — skipping (apt install lintian)"; fi
deb-path:
	@for p in $(PACKAGE) amber-ols; do \
	    ls -1t $(abspath dist)/$${p}_*_$(ARCH).deb 2>/dev/null | head -1; \
	done | grep . \
	    || { echo "no debs in dist/ -- run make deb-upstream" >&2; exit 1; }

deb-install: deb
	sudo apt install --reinstall ./$(DEB)

deb-remove:
	sudo apt remove $(PACKAGE)

clean:
	rm -rf build out dist
