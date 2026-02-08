# AGENTS.md

This file defines the install pipeline contract for contributors and coding agents.

## Core Goal

`scint install` should be fully Bundler-compatible while using a global cache to make repeated installs fast and predictable.

## Install Phase Contract

Do not reorder or blur these phases:

1. Fetch
   Download index/source payloads into global cache (`~/.cache/scint/inbound`).
2. Source Assembly (when needed)
   Assemble source trees that need extra prep (for example git repos with submodules).
3. Extract
   Expand gem payloads into global extracted cache (`~/.cache/scint/extracted`).
4. Cache Assembly
   Normalize assembled/extracted artifacts into reusable global-cache form.
5. Compile (when needed)
   Build native extensions into global extension cache (`~/.cache/scint/ext/<abi>/...`).
6. Install/Materialize
   Materialize into destination (`.bundle` or `BUNDLE_PATH`) using fast filesystem primitives (hardlink/clonefile/reflink/copy fallback).

## Warm Cache Invariants

These are required behaviors:

1. With warm global caches, runs should skip fetch/extract/compile whenever validity allows.
2. If only `.bundle` is removed, rerun should mainly redo phase 6.
3. Install/materialize should be near IO-bound and as close to instantaneous as the host FS allows.

## Scheduler Rules

The scheduler is the session object and owns phase sequencing.

1. Workers execute tasks; they do not decide global strategy.
2. Phase transitions must be explicit and dependency-safe.
3. Use queue/event-driven coordination; avoid busy polling loops.
4. Fail fast on hard errors and surface actionable diagnostics.

## Performance Direction

When optimizing, prioritize:

1. Reducing repeated filesystem scans in phase 6.
2. Reusing compiled extension outputs across projects/runs.
3. Keeping git/source assembly deterministic and cache-safe.
4. Maintaining high parallelism in fetch/extract/install while capping compile concurrency for machine stability.

## Primary Benchmark KPI

The most important benchmark signal is install runtime, reported in minutes/seconds, with this baseline model:

1. `bundler cold` is the reference baseline (`1.00x`).
2. Always report:
   - `bundler warm`
   - `scint cold`
   - `scint warm`
3. For each non-baseline timing, report relative factor vs `bundler cold`:
   - `relative_speedup = bundler_cold_seconds / phase_seconds`
4. Success criteria emphasize reducing `scint warm` first, then `scint cold`, while preserving correctness and lockfile parity.

### Comparison Table Rules

When rendering benchmark comparison tables:

1. Use concise human time formatting:
   - examples: `57s`, `3.2s`, `1m 11s`
   - avoid padded clock formatting like `00:57.08`
2. Keep `bundler cold` as baseline (`1.00x`).
3. Show relative performance as "higher is faster" vs baseline:
   - `speedup = bundler_cold_seconds / phase_seconds`
   - display as `N.NNx faster` when `speedup >= 1`
   - display as `N.NNx slower` when `speedup < 1` (using inverse)
4. Exclude rows where any required benchmark phase failed:
   - `bundler cold`, `bundler warm`, `scint cold`, `scint warm` must all have `rc=0`
5. Do not mix failed runs into the main comparison table.
