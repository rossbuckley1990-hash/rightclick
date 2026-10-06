# Capability scalability census — summary

Full machine report: [`REPORT.md`](REPORT.md) / [`REPORT.json`](REPORT.json)

| Metric | Value |
|---|---:|
| Object types tested | 16 |
| Unique capabilities | 59 |
| Unique providers | 39 |
| Third-party providers | 10 |
| Previously unseen third-party providers | 3 (Claude Automator workflows; 0 applicable actions) |
| Invocable (direct) | 5 |
| Discovery-only | 54 |
| Apple/system unique caps | 45 |
| Known third-party unique caps | 14 |
| Unseen third-party unique caps (actions) | 0 |

Coverage (unique caps by bucket): text 45 · URL 51 · image 12 · PDF 6 · audio 6 · video 8 · archive 5 · folder 7 · code 47

Bottlenecks: interactive skew; thin PDF/audio/archive; Claude workflows in providers but 0 fixture matches; share targets often lack bundle IDs.
