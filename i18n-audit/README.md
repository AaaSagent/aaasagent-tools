# i18n-audit

Find "should have been translated but wasn't" text on a bilingual site.

## Usage

```bash
BASE=https://example.com node i18n-audit.mjs
```

Exit code `1` when an English page still contains Chinese characters (hard error),
`0` otherwise.

## Rules

| Rule | Level |
|---|---|
| English page contains Chinese characters | **error** |
| Chinese page contains 4+ English words and fewer Chinese characters | warn |
| Same text appears in both zh and en builds unchanged | warn ("probably untranslated") |

Exemptions live in the `ALLOW` array: legal names, ICP filing numbers, the language
switcher label, brand and technical terms.

## Why HTTP and not a headless browser

If your pages are server-rendered, the HTML already contains every visible string.
Parsing it is faster, lighter, and immune to "Chrome won't start" failures on a busy
laptop. Use a real browser only when content is client-rendered.

## Tuning

Start with a manual run, add your own exemptions, then wire it into a pre-commit hook
or CI. A pre-commit example is in the comments at the top of the script.
