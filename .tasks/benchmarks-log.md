# Benchmarks Log

## 2026-02-08

Baseline model:
- `bundler cold` = `1.00x baseline`
- Relative values are shown as `x faster` / `x slower` vs `bundler cold`
- Rows include only projects where all four phases succeeded (`bundler cold/warm`, `scint cold/warm`)

| Project | Bundler Cold | Bundler Warm | Scint Cold | Scint Warm |
|---|---:|---:|---:|---:|
| fizzy | 57.1s (1.00x baseline) | 49.4s (1.15x faster) | 40.9s (1.40x faster) | 3.2s (18.12x faster) |
| discourse | 37s (1.00x baseline) | 37.1s (1.00x slower) | 1m 11.2s (1.93x slower) | 3.9s (9.55x faster) |
| liquid | 19.3s (1.00x baseline) | 18.1s (1.07x faster) | 17.6s (1.10x faster) | 2s (9.68x faster) |
| rails | 23s (1.00x baseline) | 22.4s (1.03x faster) | 39.7s (1.73x slower) | 2.9s (8.00x faster) |
| mastodon | 39.3s (1.00x baseline) | 39.4s (1.00x slower) | 47.4s (1.21x slower) | 3.4s (11.54x faster) |
