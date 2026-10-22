# AaaSagent Tools

Small, focused operations tools we use in production. Apache-2.0.

| Tool | What it answers |
|---|---|
| [`rce-scan/`](rce-scan/) | "A runtime just got a critical CVE — are we exposed?" One command, read-only, five checks (host, containers, entry points, listeners, non-resident assets), layered verdict `EXPOSED / REACHABLE_INTERNAL / LATENT / PRESENT / NONE`. |
| [`i18n-audit/`](i18n-audit/) | "Our English pages still show Chinese somewhere — where?" Pure HTTP audit of server-rendered pages; errors on Chinese text in the English build, flags untranslated strings. |
| [`deploy/`](deploy/) | A deploy wrapper that fails closed: type check → tests → i18n audit → deploy → **verify live**. Written for a Cloudflare Workers + D1 project behind a flaky network. |

## Why these exist

Each one was written after a real incident:

- `rce-scan` — after a PHP core RCE disclosure, we needed evidence in minutes, not a guess. Our first version reported a false "clean" because a relative config path vanished when the same script ran remotely. That bug is now a regression test of the design.
- `i18n-audit` — a footer shipped with mixed Chinese/English for weeks. Code review missed it; a rendered-page diff did not.
- `deploy/` — six failed deploys in one night, all blamed on "the network". The real cause: the CDN API needs an explicit proxy while everything else worked fine.

## Usage

See each tool's own README. All are dependency-light: `bash`, `python3`, and (optionally) `node`.

## Licence

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
