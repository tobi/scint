# Scint Matrix Issues (Current)

Date: 2026-02-08

Latest matrix run:
- Summary: `/home/tobi/src/ruby-tests/logs/postfix-matrix-fast-20260208-021843/summary.log`
- Result: `8 passed, 2 failed`
- Passing: `fizzy`, `discourse`, `liquid`, `rails`, `spree`, `redmine`, `mastodon`, `solidus`
- Failing: `chatwoot`, `forem`

## Remaining failures

### 1) Chatwoot: native extension compile failures
- Scint log: `/home/tobi/src/ruby-tests/logs/postfix-matrix-fast-20260208-021843/chatwoot.install.log`
- Current failing gem under scint: `commonmarker` (native compile error)
- Bundler comparison: also fails (`bootsnap` compile in this environment)
  - `/tmp/chatwoot.bundle.verify.log`
- Conclusion: environment/toolchain + upstream gem compatibility issue, not a scint lock/runtime resolver issue.

### 2) Forem: native extension compile failures
- Scint log: `/home/tobi/src/ruby-tests/logs/postfix-matrix-fast-20260208-021843/forem.install.log`
- Current failing gem under scint: `ddtrace`
- Bundler comparison: also fails (`ddtrace`, `jaro_winkler`, `ruby-prof`)
  - `/tmp/forem.bundle.verify.log`
- Conclusion: environment/toolchain + upstream gem compatibility issue, not a scint lock/runtime resolver issue.

## Fixed in scint during this pass

### 1) `scint exec` PATH precedence
- `#!/usr/bin/env ruby` scripts could pick a gem-provided `ruby` executable from `.bundle/bin`.
- Fixed by prioritizing interpreter bin path ahead of `.bundle/bin`.

### 2) Large-app runtime exec env size
- Very large RUBYLIB payloads could trigger exec arg/env limits.
- Fixed by keeping only shim path in `RUBYLIB` and relying on runtime lock setup via `bundler/setup`.

### 3) Bundler shim LoadError handling
- Shim could swallow nested `LoadError`s and incorrectly fall back to fuzzy basename requires.
- Fixed to retry only for missing-target load errors and propagate nested dependency errors.

### 4) Runtime lock load-path poisoning by nested lib dirs
- Nested `lib/*` paths (e.g. `lib/premailer`) could shadow core requires like `rails`.
- Removed nested lib path auto-injection from install-time/runtime-lock rebuild paths.

### 5) Native extension artifact availability in gem lib
- Some gems (`ox`) needed `.so` in gem `lib/` and failed when artifact existed only under `extensions/`.
- `ExtensionBuilder` now syncs built shared objects from extension cache/install dir into gem `lib/`.
