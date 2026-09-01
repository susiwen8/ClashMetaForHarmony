# Harmony Proxy Delay Device Proof

Persisted proof schema version: `1.0.0`

Persisted fields:

- `schemaVersion`
- `result`
- `packageSha256`
- `measurement`
- `cancellationState`

Command:

```sh
node harmony/tests/bin/run-proxy-delay-device-proof.mjs --production-hap harmony/entry/build/default/outputs/default/entry-default-signed.hap --out harmony/artifacts/proxy-delay-device-proof.json
```

Package:

- Variant: `default`
- Versioned artifact path: `harmony/entry/build/default/outputs/default/entry-default-signed.hap`
- Expected package SHA-256: `e5365cbdc7188d7c4ddf7e7937c94a952dbfe6740c0549ee10feb5470059420d`

Proof document path:

- `harmony/artifacts/proxy-delay-device-proof.json`

Privacy guarantee:

- The persisted proof contains zero private data.
- No private identifiers, node labels, raw layout content, URL strings, timestamps, or certificate details are written to the proof.
- If the run cannot be fully proven, the runner writes the canonical `incomplete` shape with zeroed aggregate measurement and `NOT_PROVEN`.
