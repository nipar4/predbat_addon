# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

This is `nipar4`'s fork of the Predbat Home Assistant add-on. It does **not** contain the Predbat
application logic itself (that lives upstream at `springfall2008/batpred`). Instead it packages that
upstream code into installable artifacts:

- A Home Assistant **add-on** (`predbat/config.yaml`, `predbat/build.yaml`) built from `predbat/Dockerfile*`.
- Standalone **Docker images** (Alpine/Slim/Noble variants) pushed to Docker Hub as `nipar44/predbat_addon`,
  for running Predbat outside of Home Assistant Supervisor.

Two version numbers are tracked independently in `versions.env`:
- `PREDBAT_VERSION` — the upstream `springfall2008/batpred` release tag to fetch/build against.
- `ADDON_VERSION` — the version of upstream `springfall2008/predbat_addon` this fork is synced to
  (also mirrored in `predbat/config.yaml`'s `version:` field).

There is no application source code to build/lint/test locally — almost all of the real work in this
repo is Dockerfile/CI/packaging changes. Validate changes by reasoning through the Dockerfiles/workflows
and, where possible, a local `docker build`, rather than looking for a test suite.

## Repository layout

```
versions.env              # single source of truth for PREDBAT_VERSION / ADDON_VERSION
repository.yaml            # HA add-on repository metadata
archive/                   # files pulled out of the build tree because nothing references them anymore,
                             # kept (not deleted) in case that turns out to be wrong — see each subdir's README
predbat/
  config.yaml               # HA add-on manifest (slug, ports, options schema, version) — synced from upstream, not fork-maintained
  build.yaml                 # base images per arch for the HAOS add-on build — synced from upstream, not fork-maintained
  Dockerfile                  # the actual HAOS add-on Dockerfile (BUILD_FROM from build.yaml) — synced from upstream, not fork-maintained
  Dockerfile.old               # legacy Ubuntu-noble-based image with apt-installed python deps
  Dockerfile.noble               # ubuntu:latest based, fetches Predbat via `ADD <git-url>` — fork-original
  Dockerfile.alpine                # multi-stage: python:3.13-alpine + s6-overlay, fetches Predbat via `ADD <git-url>` — fork-original
  Dockerfile.slim                   # multi-stage: python:3.13-slim-bookworm + s6-overlay, same pattern as alpine — fork-original
  Dockerfile.standalone              # standalone (non-HAOS) Dockerfile — synced from upstream, not fork-maintained
  requirements.txt                    # Python deps installed into the image (independent of Predbat's own reqs)
  rootfs/                              # files copied/ADDed into images; several parallel variants exist:
    startup.py, run.sh, run.csh          # used by Dockerfile / Dockerfile.old (legacy, non-s6 paths)
    addon/{run.sh,startup.py}             # legacy HA add-on entrypoint
    noble/{startup.py,run.standalone.sh}   # Dockerfile.noble entrypoint
    alpine/{startup.py,run.docker.sh,run.standalone.sh}  # shared by Dockerfile.alpine/.slim
    test/{startup.py,run.docker.sh,run.standalone.sh}     # a WIP/scratch variant, keep in sync manually
    docker/s6-rc/                           # s6 service definitions used ONLY by Dockerfile.alpine/.slim:
      predbat/                                # main "predbat" service (runs after wait-for-ha)
      wait-for-ha/                             # optional service that polls HA and can force-restart the container
    etc/s6-overlay/s6-rc.d/                    # s6 service (init-predbat) used by the HAOS add-on image: Dockerfile
                                                # does `ADD rootfs requirements.txt /`, which lands this at
                                                # /etc/s6-overlay/s6-rc.d/ where the HAOS base image's s6-overlay
                                                # picks it up — this is the primary Supervisor-install entrypoint,
                                                # not legacy/unused
.github/workflows/
  sync-predbat.yml           # hourly: checks upstream batpred releases and bumps PREDBAT_VERSION unconditionally, but only
                               # builds+pushes all 3 image variants and cuts a GitHub release if ADDON_VERSION is already
                               # current with upstream predbat_addon (addon_current) AND PREDBAT_VERSION actually changed —
                               # otherwise the bump (or an unrelated versions.env edit, e.g. an S6_VERSION bump) lands with
                               # no build. A manual workflow_dispatch bypasses all of that gating and always builds+pushes+
                               # releases — this is also how sync-addon.yml requests a rebuild after merging upstream (it
                               # calls `gh workflow run sync-predbat.yml`, a workflow_dispatch, rather than relying on its
                               # own push), and the way to force a rebuild of the current versions.env on demand.
  sync-addon.yml              # daily: merges upstream springfall2008/predbat_addon main, bumps ADDON_VERSION, triggers sync-predbat.yml
  lint-workflows.yml              # runs actionlint against .github/workflows/*.yml on push and PR
  dependabot.yml
```

## Workflow conventions (established during a workflow security review)

- **Third-party actions are pinned to commit SHAs**, not floating tags, with a trailing `# vX.Y.Z` comment
  for readability, e.g. `actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # v7.0.0`. This guards
  against a tag being force-moved to different code. Dependabot's `github-actions` ecosystem (configured
  in `dependabot.yml`) still resolves and updates SHA-pinned actions — it updates both the SHA and the
  version comment in its PRs, so update PRs keep working as before. When adding a new third-party action,
  look up its SHA via the GitHub API (`api.github.com/repos/<owner>/<repo>/tags`) rather than using a tag
  directly, and follow the same pattern.
- **Any job that writes with `git push` should `git pull --rebase` immediately before pushing.** Both
  `sync-predbat.yml` (the `check-and-sync` job) and `sync-addon.yml` (the `check-and-merge` job) can run
  close together and both write to `versions.env` on different lines — the rebase avoids a non-fast-forward
  push failure if the other workflow lands a commit in between.
- **GitHub Actions job `permissions:` blocks are all-or-nothing once declared** — any scope you don't list
  is set to `none`, not the default `read`/`write`. If a step needs a new capability (e.g. `gh workflow run`
  needs `actions: write`, `softprops/action-gh-release` needs `contents: write`), the job's `permissions:`
  block must explicitly list it or the step silently 403s. `sync-addon.yml`'s `check-and-merge` job hit this
  exact bug (missing `actions: write` for its "Trigger predbat sync build" step) before it was fixed.
- **Issues are intentionally disabled on this fork** — user-facing bug reports should go to upstream
  `springfall2008/predbat_addon`/`batpred`, not here. `sync-addon.yml` has no issue-filing steps for merge
  conflicts or other failures; a failed scheduled run just relies on GitHub's default failed-workflow email
  notification. Don't reintroduce `github.rest.issues.create()` calls in this repo's workflows — they'll
  fail with `HttpError: Issues has been disabled in this repository.`
- **`gh workflow run` needs an explicit `-R <owner>/<repo>` when the job has more than one GitHub remote
  configured.** `sync-addon.yml`'s `check-and-merge` job adds an `upstream` remote (pointing at
  `springfall2008/predbat_addon`) to merge from it, which confuses `gh`'s repo auto-detection — its
  "Trigger predbat sync build" step (`gh workflow run sync-predbat.yml`) once silently dispatched against
  `springfall2008/predbat_addon` instead of the fork and failed with `HTTP 404: workflow ... not found on
  the default branch`. Always pass `-R ${{ github.repository }}` explicitly in that job.
- **`sync-addon.yml`'s "Detect if update available" step must check ancestry, not SHA equality.** This fork
  is permanently ahead of `springfall2008/predbat_addon` (it carries its own commits — `versions.env` bumps,
  `CLAUDE.md`, workflow fixes — that never merge back upstream), so a plain `git rev-parse main` vs.
  `git rev-parse upstream/main` comparison is essentially always unequal and reports `changed=true` on
  nearly every run, even when upstream added nothing. Since `changed=true` unconditionally triggers
  `gh workflow run sync-predbat.yml`, and that dispatch's `workflow_dispatch` event bypasses
  `sync-predbat.yml`'s own `addon_current`/`version_changed` build gating, this caused a full image
  build+push+release on every run regardless of whether anything actually changed — masked until the
  `-R` fix above made the dispatch start succeeding. The check now uses
  `git merge-base --is-ancestor upstream/main main` (true = upstream has no commits main doesn't already
  have = no real update) instead.

## Key mechanics worth understanding before editing

- **Not everything under `predbat/` is fork-maintained.** `Dockerfile`, `Dockerfile.standalone`,
  `config.yaml`, and `build.yaml` come from the upstream `springfall2008/predbat_addon` repo and are kept
  current purely by `sync-addon.yml`'s daily merge — if upstream bumps the HAOS base image in `build.yaml`,
  it lands here automatically, no manual tracking or Dependabot entry needed for those files. By contrast,
  `Dockerfile.noble`/`.alpine`/`.slim` (and their `rootfs/{noble,alpine}/*` support files) are original to
  this fork — upstream has no equivalent, so nothing merges in to keep them current; any base image or
  tooling bump in those has to be done here.
- **`S6_VERSION` (used by `Dockerfile.alpine`/`.slim`) is not tracked by Dependabot.** It's consumed inside a
  `RUN`/`ADD` download URL rather than a `FROM` line, so Dependabot's `docker` ecosystem (which only parses
  `FROM image:tag`, or an `ARG` with a literal default feeding a `FROM`) never sees it. It lives in
  `versions.env` (same as `PREDBAT_VERSION`/`ADDON_VERSION`) and is passed through as a build-arg by
  `sync-predbat.yml`, so there's one place to bump it by hand — the Dockerfiles' own
  `ARG S6_VERSION=v3.2.2.0` default is only a fallback for building without CI/`versions.env` and should be
  kept in sync manually if bumped. Check https://github.com/just-containers/s6-overlay/releases periodically.
- **No app code is vendored.** `Dockerfile.noble`/`.alpine`/`.slim` pull Predbat straight from GitHub with
  Docker's `ADD https://github.com/springfall2008/batpred.git#$PREDBAT_VERSION:apps/predbat/ ...` syntax —
  changing `PREDBAT_VERSION` and rebuilding is how the app itself gets updated, not editing files in this repo.
- **Startup flow (alpine/slim, s6-based):** `wait-for-ha` service (optional, only if `WAIT_FOR_HA_HOST`/`_PORT`
  env vars are set) polls Home Assistant over TCP and force-restarts the container via
  `s6-linux-init-shutdown -r now` after `WAIT_FOR_HA_MAX_FAILS` consecutive failures. The `predbat` service
  depends on it and does its own separate initial wait for HA to become reachable, then execs
  `rootfs/alpine/run.docker.sh` — **not** `startup.py` — which copies `apps.yaml` into `/config` on first
  run and blocks until the user removes `template: true` from it, then execs `python3 /addon/startup.py`.
  `startup.py`'s own logic is mostly a fallback that re-downloads a Predbat release zip from GitHub if
  `apps.yaml` is missing (dead code on this path, since `run.docker.sh` already guarantees it exists) —
  it finishes by running `python3 /addon/hass.py` via `os.system` (not `exec`), then sleeps 20s.
- **Multiple near-duplicate startup scripts exist** (`rootfs/{addon,noble,alpine,test}/startup.py` and the
  various `run*.sh`). They differ subtly (e.g. `hass.py` vs `/addon/hass.py`, `template: True` vs
  `template: true` casing, restart-loop vs single-shot). When fixing a bug in one, check whether the same
  bug exists in the sibling copies under the other variant directories — there is no shared/templated source.
- **`versions.env` is the trigger for CI.** Both sync workflows watch/write this file; hand-editing
  `PREDBAT_VERSION` or `ADDON_VERSION` here (or a push touching `predbat/requirements.txt`) can kick off a
  scheduled build via the `paths:` filters in `sync-predbat.yml`.
- Image tags follow `nipar44/predbat_addon:<variant-><PREDBAT_VERSION|latest>` where `<variant->` is empty for
  noble, `alpine-` for alpine, `slim-` for slim.

## Working with GitHub Actions changes

- Validate workflow YAML with `actionlint` locally before pushing (CI runs it on every push and PR touching
  `.github/workflows/*.yml` via `lint-workflows.yml`, which downloads a specific checksum-verified
  actionlint release rather than piping an unpinned installer script):
  ```bash
  ACTIONLINT_VERSION="1.7.12"
  curl -sSfLO "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz"
  tar xzf "actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz" actionlint
  ./actionlint .github/workflows/*.yml
  ```
- The build workflows require `DOCKERHUB_USERNAME`/`DOCKERHUB_TOKEN` secrets and push multi-arch
  (`linux/amd64,linux/arm64`) images — don't expect a full build to succeed in a sandbox without those
  secrets and QEMU/buildx set up.

## Testing a Dockerfile change locally

There's no test suite; the closest thing to validation is building an image, e.g.:
```bash
docker build -f predbat/Dockerfile.alpine --build-arg PREDBAT_VERSION=v8.42.5 --build-arg ADDON_VERSION=1.7.1 predbat/
```
