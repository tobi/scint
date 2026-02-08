# Minimal Gem Tree Plan

## Goal
Reduce what Scint installs under `.bundle/.../gems/*` for `git` and `path` sources to runtime-relevant files only:
- Ruby code
- native extension sources/artifacts needed to build/load
- obvious runtime data files (`.json`, `.yml`, `.yaml`, `.csv`, `.parquet`, `.db`, `.sqlite`, `.sqlite3`, `.sql`)

Exclude obvious non-runtime content:
- docs/tests/examples/CI metadata
- `.git` internals
- build/temp artifacts

## Non-Goals
- Do not change lockfile semantics.
- Do not change `rubygems` package extraction behavior yet.
- Do not remove files from user source trees; only affect staged/extracted copies.

## Current Behavior (Problem)
- Scint resolves source roots, then mostly clones full directories into extracted cache and into `.bundle`.
- For source gems, this can include docs, test files, git metadata, and unrelated artifacts.

## Strategy
Introduce a manifest-based staging step for source gems before linking:
1. Build a file manifest from gemspec/runtime heuristics.
2. Copy only manifest files into extracted cache.
3. Link/install from this minimal extracted tree.

## Design

### 1. New component: `SourceStager`
- New file: `lib/scint/installer/source_stager.rb`
- Responsibilities:
  - `build_manifest(src_root:, spec:, gemspec:) -> [relative_paths]`
  - `stage_minimal(src_root:, dst_root:, manifest:)`
  - `stage_full(...)` fallback mode

### 2. Manifest rules
- Always include:
  - `#{spec.name}.gemspec` (or selected gemspec path)
  - files under `gemspec.require_paths`
  - executables listed in `gemspec.executables` (in `bindir`, `bin`, `exe`)
  - extension sources referenced by `gemspec.extensions`
  - `ext/**` fallback for native gems
  - compiled extension artifacts if present (`*.so`, `*.bundle`, `*.dll`, `*.dylib`)
- Include runtime data extensions:
  - `*.json`, `*.yml`, `*.yaml`, `*.csv`, `*.parquet`, `*.db`, `*.sqlite`, `*.sqlite3`, `*.sql`
- Default excludes:
  - `.git/**`, `.github/**`, `docs/**`, `doc/**`, `test/**`, `spec/**`, `tmp/**`, `coverage/**`, `node_modules/**`
  - `*.o`, `*.a`, `*.log`, transient build/cache dirs

### 3. Git-aware filtering
- For git sources, use `git ls-files` to seed candidate files.
- Optionally include untracked-but-needed files only if explicitly referenced by gemspec/runtime rules.
- Do not parse `.gitignore` manually.

### 4. Path sources
- If path source is inside a git repo:
  - filter candidates using `git check-ignore` (or `git ls-files` + explicit extras).
- If not in git repo:
  - filesystem walk + include/exclude rules.

### 5. Integration points
- Replace full clone in:
  - `materialize_git_spec` (`lib/scint/cli/install.rb`)
- Add equivalent path-source materialization to use `SourceStager`.
- Keep `Installer::Linker` unchanged (it links from extracted path).

### 6. Cache invalidation
- Add stager metadata marker in extracted cache:
  - `stager_version`
  - source revision/path signature
  - mode (`minimal`/`full`)
- Re-stage when marker changes.

## Config / Escape Hatch
- Env var:
  - `SCINT_STAGE_MODE=minimal|full`
  - default `minimal`
- Optional future allowlist overrides for problematic gems.

## Test Plan

### Unit tests
- `test/installer/source_stager_test.rb`
  - includes runtime files + configured data extensions
  - excludes docs/tests/.git/artifacts
  - includes extension inputs/outputs
  - honors executables and bindir
  - path traversal safety

### CLI/install tests
- extend `test/cli/install_test.rb`
  - git source staging contains no `.git`
  - path source staging excludes docs/tests
  - runtime still resolves/loads with staged tree

### Regression matrix checks
- rails monorepo path source still installs correctly
- existing chatwoot/forem/mastodon failures unaffected unless directly related

## Rollout Plan
1. Add `SourceStager` + tests (no integration yet).
2. Integrate for git sources only, behind `SCINT_STAGE_MODE=minimal`.
3. Integrate for path sources.
4. Run matrix and compare `.bundle` size, file counts, and runtime parity.
5. Make minimal mode default (if not already), keep full fallback.

## Risks
- Over-pruning may remove runtime templates/data in unusual gems.
- Git/path repo layouts vary; glob + gemspec resolution must stay strict.
- Extension build flows must keep required sources.

## Success Criteria
- Significantly fewer files under `.bundle/.../gems` for source gems.
- No `.git`, docs, or obvious artifacts in staged source gems.
- No regressions in install/exec for known matrix projects that currently pass.
