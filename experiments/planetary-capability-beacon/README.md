# Planetary Capability Beacon

Status: experimental proof, 2026-10-07.

## The idea

What if a machine did not need a bespoke AI integration before an agent could understand what it can safely do?

This experiment publishes a small provider-neutral capability beacon describing:

- what abilities are available;
- the input schema;
- the safety class;
- the authority requirement;
- freshness and withdrawal rules;
- provenance;
- and the independent verification contract required before an agent may claim success.

The north star is an Internet-scale capability fabric in which machines, services, public institutions, laboratories and agents can publish revocable, verifiable abilities while the AI-facing interface remains small.

## Why this branch is unusual

This branch and the beacon were created remotely by RIGHTCLICK itself through the same seven-operation runtime interface.

RIGHTCLICK dynamically reflected a GitHub OpenAPI provider. The AI did not receive a permanent GitHub-specific top-level tool from RIGHTCLICK.

Sequence:

1. context_runtime attested RIGHTCLICK 0.2.2.
2. context_providers exposed the live GitHub OpenAPI provider.
3. context_actions on the provider identity discovered remote operations.
4. RIGHTCLICK read main remotely using Get a branch.
5. RIGHTCLICK created this experiment branch using Create a reference.
6. RIGHTCLICK published the beacon with Create or update file contents.
7. RIGHTCLICK independently read back the created Git blob using Get a blob.

Provider acknowledgement was not treated as semantic success.

## Evidence

Branch creation execution:

- 8B9DDB7A-EDF3-4E3D-B78C-A07308AEF42A
- provider response: HTTP 201

Beacon publication execution:

- 60344EE7-AECF-4DD5-A396-14CE7F0C3233
- commit: 75a96d3353d1e7f1531b24debbfc928653b8e6e0
- blob: 7cb2d0e1ea595b518e2c3382f33d44f624a46352
- provider response: HTTP 201

Independent blob read-back execution:

- 806E763D-81AA-41CC-99D3-9E04C4BEFDD3
- provider response: HTTP 200
- returned blob SHA: 7cb2d0e1ea595b518e2c3382f33d44f624a46352

## The deliberately failed frontier

RIGHTCLICK also discovered the generic remote capability Start a task and attempted to launch a cloud coding-agent task that would build this experiment recursively.

Execution:

- 2D59B435-5DEE-4B61-9409-8837436F63C7
- result: HTTP 412
- RIGHTCLICK state: rejected

That is recorded as a real boundary, not presented as success. The repository/account did not satisfy the remote agent-task precondition at the time of the experiment.

## What this proves

It proves a narrower but important statement:

A live AI session can discover a remote cloud capability at runtime, invoke it through a provider-neutral seven-operation interface, mutate durable remote state, and independently read that state back without RIGHTCLICK exposing a provider-specific GitHub tool.

It also publishes a concrete interoperability target for a future capability-beacon discovery source.

## What it does not prove

This branch does not claim:

- that current stable RIGHTCLICK automatically discovers arbitrary beacon documents;
- that the complete eleven-substrate universal runtime proof has passed;
- that the simulated mutating capability performs a real external action;
- that one JSON format should become an industry standard without review.

The next meaningful proof is to teach the universal runtime to ingest this beacon generically, then repeat the same flow across several independent providers and substrate types.

## Positive-outcome direction

A mature form could let emergency systems, research instruments, accessibility services, energy systems, civic infrastructure, robotics fleets and enterprise software publish safe machine-readable abilities with explicit authority and verification contracts.

The important property is not autonomous power. It is interoperable capability with least authority, revocation and evidence.
