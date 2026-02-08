# Scint Cache Goal

## Desired Outcome

`scint install` should be effectively instant on warm cache when only `.bundle/` is missing.

To get there, Scint should treat cache state as a deterministic artifact pipeline:

1. `inbound` stores fetched raw inputs.
2. `assembling` is the only place where extraction + compile happen.
3. `cached/<ruby-abi>/<full_name>/` is the promoted, ready-to-materialize artifact.
4. install materialization copies/clones/links from `cached` into `.bundle`.

## Canonical Layout

```text
~/.cache/scint/
  inbound/
    gems/<full_name>.gem
    gits/<deterministic_repo_slug>/
  assembling/<ruby-abi>/<full_name>/
  cached/<ruby-abi>/<full_name>/
  cached/<ruby-abi>/<full_name>.spec.marshal
  cached/<ruby-abi>/<full_name>.manifest
  index/
```

## Pipeline Contract

1. Fetch
   - Download gem payloads to `inbound/gems`.
   - Clone/fetch git repos in `inbound/gits`.
2. Assemble
   - `.gem`: unpack to `assembling/<abi>/<full_name>`.
   - `git`: checkout/submodules/export to `assembling/<abi>/<full_name>`.
3. Compile
   - Build native extensions inside the assembling directory.
4. Promote
   - Atomic move from assembling to `cached/<abi>/<full_name>`.
   - Write `.spec.marshal` and manifest.
5. Materialize
   - Fast filesystem copy from `cached` to `.bundle` (`clonefile`/reflink/hardlink/copy fallback).

## Required Invariants

1. No fetch/extract/compile when `cached/<abi>/<full_name>` is valid.
2. Deleting `.bundle` alone should not trigger recompilation.
3. Failed builds never pollute `cached`; only successful assemblies are promoted.
4. Git cache naming is deterministic and human-decodable.
5. Scheduler remains event-driven; no busy polling.

## Known Pain to Eliminate

Current behavior can still trigger large compile sets on runs expected to be warm.
The new structure must make warm/cold state obvious from cache contents and avoid split-brain between extracted trees and extension cache.

## Implementation Phases

1. Add `cached/` and `assembling/` layout APIs.
2. Teach preparer/installer to write assembled+compiled output into `assembling`.
3. Promote to `cached` atomically.
4. Switch warm checks/planner decisions to `cached`.
5. Add manifests for fast materialization.
6. Keep temporary read-compat for old caches, then remove legacy paths.

## Migration Plan

1. Introduce `cached/` as the canonical artifact store and keep existing `extracted/` + `ext/` as compatibility read-only fallback during migration.
2. Route all new installs through `assembling/<abi>/<full_name>` and atomic promote to `cached/`.
3. Move compile output ownership from separate `ext/` cache into the assembled gem tree before promotion.
4. Add deterministic git repo slugs in `inbound/gits/` and normalize git export flow (`fetch -> checkout/submodules -> export to assembling`).
5. Add per-gem manifest metadata to avoid repeated file scans in materialization.
6. Switch planner warm checks to `cached/` existence/validity as first-class signal.
7. Remove legacy cache paths once read-compat telemetry shows no regressions.

## Legacy Removals (After Rollout)

After the new cache pipeline is fully adopted, remove these legacy paths and code paths:

1. Global `extracted/` tree as a first-class install source.
2. Global `ext/` tree as a separate extension cache.
3. Planner warm checks that key off `extracted/` + `ext/` presence instead of `cached/<abi>/<full_name>`.
4. Preparer fallback paths that load gem metadata from `inbound/*.gem` when cached assembled artifacts exist.
5. Legacy read-compat fallback from old `extracted/*.spec.marshal` locations.
6. Split `link -> build_ext -> relink` behavior that assumes extension outputs live outside the cached gem artifact.
7. Per-gem extension relink logic that copies from legacy `ext/` into bundle installs.
8. Old git cache shape under `inbound/git/repos` + `inbound/git/checkouts` once deterministic `inbound/gits/<repo-slug>` is canonical.
9. Git checkout marker compatibility files that only exist to bridge old checkout/extracted behavior.
10. Any install decisions that treat ABI cache misses as recoverable from legacy cache roots rather than rebuilding through `assembling`.
11. Any UI/status counters that are derived from mixed legacy/new cache states.
12. Any maintenance scripts that clear/inspect old `extracted/` and `ext/` trees as primary storage.

## Acceptance Checks

1. Cold install populates `cached/<abi>` for all resolved gems.
2. Warm install after `rm -rf .bundle` compiles `0` gems.
3. Warm install runtime is dominated by materialization, not compile.
4. Git gems with submodules are reproducible across repeated runs.
5. `scint-vs-bundler` on Shopify shows major warm speedup without recompilation.
