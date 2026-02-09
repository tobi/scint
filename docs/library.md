# Library API

Scint can be used as a library via `Scint::Bundle`. No scheduler, progress bar, or IO — just parsing, resolution, and planning.

```ruby
require "scint"

bundle = Scint::Bundle.new("/path/to/project")

bundle.gemfile   # => Gemfile::ParseResult  (dependencies, sources, platforms, ...)
bundle.lockfile  # => Lockfile::LockfileData or nil
bundle.cache     # => Cache::Layout

resolved = bundle.resolve  # => [ResolvedSpec, ...]
plan     = bundle.plan     # => [PlanEntry, ...]
```

All accessors are lazy and memoized. `resolve` fetches indexes and runs PubGrub (or takes the lockfile fast path when the lock is current). `plan` diffs resolved specs against what's already installed.

## Group filtering

```ruby
bundle = Scint::Bundle.new(".", without: [:development, :test])
resolved = bundle.resolve  # development/test gems excluded

bundle.excluded_gem_names  # => Set["minitest", "debug", ...]
```

## Credentials

Credentials for private sources are picked up automatically from `~/.gem/credentials`, `BUNDLE_*` env vars, and netrc. You can also inject a pre-built credential store:

```ruby
creds = Scint::Credentials.new
bundle = Scint::Bundle.new(".", credentials: creds)
```

## Return types

| Method | Returns |
|--------|---------|
| `gemfile` | `Gemfile::ParseResult` — dependencies, sources, ruby_version, platforms, optional_groups |
| `lockfile` | `Lockfile::LockfileData` — specs, dependencies, platforms, sources, checksums — or `nil` |
| `cache` | `Cache::Layout` — paths into `~/.cache/scint` |
| `resolve` | `Array<ResolvedSpec>` — name, version, platform, dependencies, source, checksum |
| `plan` | `Array<PlanEntry>` — spec, action (`:link`, `:download`, `:skip`, ...), cached_path, gem_path |
| `excluded_gem_names` | `Set<String>` |

## Skipping network access

When indexes are already fetched (e.g. by the CLI scheduler), pass `fetch_indexes: false`:

```ruby
resolved = bundle.resolve(fetch_indexes: false)
```

Resolution will still work if a current lockfile exists (lockfile fast path).
