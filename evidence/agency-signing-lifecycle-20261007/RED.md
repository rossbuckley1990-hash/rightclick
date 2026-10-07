Frozen source: e95497e41ca04e441f317e01f343ad0b86e2c63b (integrated runtime and proof lab), before the repair.

Actual A2A agent and separate read-only observer processes: five tests, four failures. Deleting the protected provisioned key, replacing its bytes at the same path, changing the current host key reference, and withdrawing the key after a real effect plus provider loss each still emit a valid original-key signature. The unchanged-key positive control passes. Each test records exactly one request and one actual effect; configuration change/provider loss remain honestly unknown. An independent strict Python canonical decoder and separately pinned Ed25519 verification confirm every stale signature is valid. Public receipts and public pins only; no private key or bearer is archived.

Offline authenticated relay-envelope controls: eight tests, four failures. Malformed, absent, null and numeric expiry values pass the old Date.parse comparison and release private credential references. Real Node crypto generates synthetic encrypted fixtures in private temporary directories and removes all keys/tokens afterward. Finite future expiry, genuinely expired authority, wrong source SHA and tampered GCM ciphertext are controls. Evidence contains only acceptance/file-existence booleans.

The cleanup callback test is separately being frozen; its results are not covered by these two confirmed REDs.

These are generic retained signing-authority and typed-expiry failures, not evidence of native Windows, distributed trust-root revocation or production key rotation acceptance. No public relay was started.
