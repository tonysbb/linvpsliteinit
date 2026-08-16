# Changelog

All commit summaries recorded by deploy.sh.

## [Unreleased]

- Add minimal capability-checked ZRAM and optional Chrony integration.
- Preserve existing swap and avoid logging the generated SSH private key.
- Size ZRAM in 64–4096 MiB binary tiers, capped at half normalized RAM and 4 GiB.
- Separate disk SWAP accounting and recommendations from ZRAM.
- Add guarded removal for `/swapfile_by_script` and linvpsliteinit-managed ZRAM.

## [2026-03-30 00:32:00]

```text
refactor: streamline prompts and align docs
```

## [2026-03-27 19:06:22]

```text
fix: avoid final summary printf errors and exit hang
```

## [2026-03-27 18:52:27]

```text
fix: keep interactive prompts visible while logging
```

## [2026-03-23 20:35:59]

```text
feat: add Alpine compatibility support
```

