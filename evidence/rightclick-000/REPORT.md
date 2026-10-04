# RIGHTCLICK-000 probe report

Generated: 2026-10-04T20:21:06Z
macOS: 26.4.1 (25E253)

## Gates

```text
SHARING
Discovery: PASS
Execution: FAIL
Support level: PUBLIC_DEPRECATED

SERVICES
Discovery: PASS
Execution: FAIL
Support level: PUBLIC_SUPPORTED

QUICK ACTIONS
Discovery: PASS
Execution: FAIL
Support level: PUBLIC_SUPPORTED discovery, execution UNAVAILABLE

RIGHTCLICK-000: PARTIAL
```

## Reasons

- Sharing sets for JPG, PDF, and URL differ and were returned by macOS sharing APIs.
- Sharing execution did not run.
- Discovered 53 services from NSServices Info.plist metadata.
- NSPerformService did not return an observable result. Last error: none.
- Discovered 1 content-specific action extensions from appex metadata. Invocation remains unsupported.
- Quick Action execution is FAIL because no public direct invocation API succeeded. Discovery and execution are separate.

## Sharing titles by input

### jpg

- AirDrop
- Mail
- Messages
- Notes
- Add to Photos
- Freeform
- Simulator
- Journal
- Reminders

Errors:
- Picker UI skipped by flag.

### pdf

- AirDrop
- Mail
- Messages
- Notes
- Freeform
- Simulator

Errors:
- Picker UI skipped by flag.

### txt

- AirDrop
- Mail
- Messages
- Notes
- Freeform
- Simulator
- Journal
- Reminders

Errors:
- Picker UI skipped by flag.

### mov

- AirDrop
- Mail
- Messages
- Notes
- Add to Photos
- Freeform
- Simulator
- Journal

Errors:
- Picker UI skipped by flag.

### url

- Add to Reading List
- AirDrop
- Mail
- Messages
- Notes
- Open in News
- Freeform
- Simulator
- Journal
- Reminders

Errors:
- Picker UI skipped by flag.

### plain-text

- Mail
- Messages
- Notes
- Freeform
- Journal
- Reminders

Errors:
- Picker UI skipped by flag.

## Service execution

(none)

## Quick action applicability

- Markup [predicate] ["txt": "doesNotApply", "jpg": "applies", "url": "doesNotApply", "pdf": "applies", "mov": "doesNotApply"]
- ShareSheetUI [true_predicate] ["jpg": "unknown", "txt": "unknown", "pdf": "unknown", "url": "unknown", "mov": "unknown"]
