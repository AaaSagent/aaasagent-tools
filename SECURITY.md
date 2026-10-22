# Security Policy

## Reporting a vulnerability

Please email **contact@aaasagent.xyz** with:
- affected tool and version/commit
- a minimal reproduction
- impact assessment

We aim to acknowledge within 3 business days. Please do not open a public issue for
security reports.

## Scope

These tools are **read-only diagnostics and build helpers**. They are not part of the
AaaSagent service runtime. In scope: command injection, unsafe temp files, credential
leakage in output, path traversal from user-supplied arguments.

Out of scope: vulnerabilities in the target systems these tools inspect.

## Safe defaults

- `rce-scan` performs no writes on the inspected host and removes its temporary files.
- No tool prints secrets; all reporting values pass through redaction.
- Do not run these tools against systems you are not authorised to inspect.
