# MoSCoW

The MoSCoW method is a prioritization technique used in management, business analysis, project management, and software development to reach a common understanding with stakeholders on the importance they place on the delivery of each requirement; it is also known as MoSCoW prioritization or MoSCoW analysis.

The term MoSCoW itself is an acronym derived from the first letter of each of four prioritization categories (Must have, Should have, Could have, and Won't have), with the interstitial Os added to make the word pronounceable. While the Os are usually in lower-case to indicate that they do not stand for anything, the all-capitals MOSCOW is also used.

## Must have

- nada

## Should have

- **Pin `ols` by default.** `scripts/fetch_ols.py` takes master head unless
  `OLS_COMMIT` names a sha, so two builds of the same `amber-ols` version can carry
  different servers — the compiler side is reproducible (a tagged, sha256-verified
  upstream release) and the server side is not. The sha is recorded in
  `build/ols-src/COMMIT` and in the changelog, so a built deb says what it carries;
  what is missing is a default that does not move. ols publishes tags, so following
  the newest tag rather than `master` would close the gap without pinning by hand.

## Could have

- **arm64 packages.** `ARCH` is threaded through the Makefile, `fetch_odin.py
  --arch` and both control templates, so the packaging is already
  architecture-agnostic; what is untested is whether upstream ships an arm64 asset
  for every tag, and ols would need building on an arm64 runner.

- **Publish the checks, not just the deb.** `make release` writes `RELEASE.md` with
  the version, size and SHA256, and the monthly workflow attaches only the debs.
  Attaching the manifest would let a downloader verify a package without
  rebuilding it.

## Won't have (this time)

- **A PPA.** The suite has its own apt archive (`amberlinux-apt`), which ingests
  this repo's debs via `make deb-path`. A second distribution channel would be a
  second thing to sign, mirror and keep current, for packages the archive already
  serves.
