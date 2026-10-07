"""Contract-derived ASR extraction and independent semantic verification.

This module deliberately never receives the expected caption while selecting a
transcript. A model status, debug log, or provider acknowledgment is not ASR.
"""
from __future__ import annotations

import re
from typing import Any

TRANSCRIPT_NAMES = frozenset({"transcript", "transcription", "recognized_text", "recognised_text", "recognizedtext", "recognized text", "speech_text"})
STATUS_NAMES = frozenset({"status", "message", "log", "logs", "details", "error", "warning", "debug", "duration", "metadata"})
STOPWORDS = frozenset({
    "the", "and", "that", "this", "with", "from", "into", "over", "under",
    "above", "below", "there", "their", "his", "her", "its", "are", "was",
    "were", "has", "have", "had", "for", "you", "your", "but", "image",
    "photo", "picture", "caption",
})


def clean(value: str) -> str:
    return re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", value)).strip()


def _is_text(spec: Any) -> bool:
    typ = spec.get("type", spec) if isinstance(spec, dict) else spec
    return typ == "string" or (isinstance(typ, dict) and typ.get("type") == "string")


def extract_transcript(result: Any, contract: dict[str, Any]) -> dict[str, Any]:
    """Select a transcription solely from declared output names and positions.

    If a multi-output response cannot unambiguously identify a transcript, fail
    closed instead of choosing the longest or most caption-like string.
    """
    outputs = contract.get("returns")
    if not isinstance(outputs, list) or not outputs:
        return {"text": None, "source": None, "reason": "missing_output_contract"}

    candidates: list[tuple[str, str, str]] = []
    if isinstance(result, dict) and isinstance(result.get("result"), (dict, list)):
        result = result["result"]

    if isinstance(result, dict) and isinstance(result.get("data"), list):
        values = result["data"]
        for index, field in enumerate(outputs):
            if _is_text(field) and index < len(values) and isinstance(values[index], str):
                candidates.append((str(field.get("name", index)), clean(values[index]), f"data[{index}]"))
    elif isinstance(result, list):
        for index, field in enumerate(outputs):
            if _is_text(field) and index < len(result) and isinstance(result[index], str):
                candidates.append((str(field.get("name", index)), clean(result[index]), f"list[{index}]"))
    elif isinstance(result, dict):
        for index, field in enumerate(outputs):
            name = field.get("name") if isinstance(field, dict) else None
            if _is_text(field) and isinstance(name, str):
                value = result.get(name)
                if isinstance(value, str):
                    candidates.append((name, clean(value), f"field:{name}"))
        # A named transcription is also allowed when providers wrap one result
        # but the declared output has a generic key (e.g. value_9).
        if not candidates and len(outputs) == 1 and _is_text(outputs[0]):
            for key in TRANSCRIPT_NAMES:
                if isinstance(result.get(key), str):
                    candidates.append((key, clean(result[key]), f"field:{key}"))
    elif isinstance(result, str) and len(outputs) == 1 and _is_text(outputs[0]):
        candidates.append((str(outputs[0].get("name", "result")), clean(result), "scalar"))

    candidates = [(name, value, source) for name, value, source in candidates if value]
    named = [(name, value, source) for name, value, source in candidates if name.lower().strip() in TRANSCRIPT_NAMES]
    if len(named) == 1:
        name, value, source = named[0]
        return {"text": value, "source": source, "reason": "named_transcript_output"}
    if len(named) > 1:
        return {"text": None, "source": None, "reason": "ambiguous_named_transcripts"}
    if len(candidates) == 1:
        name, value, source = candidates[0]
        if name.lower().strip() not in STATUS_NAMES and len(outputs) == 1:
            return {"text": value, "source": source, "reason": "sole_declared_text_output"}
    return {"text": None, "source": None, "reason": "ambiguous_or_status_only_output"}


def meaningful_tokens(value: str | None) -> set[str]:
    return {word for word in re.findall(r"[a-z0-9]+", (value or "").lower())
            if len(word) >= 4 and word not in STOPWORDS}


def compare_caption(caption: str, transcript: str | None) -> dict[str, Any]:
    """Independent semantic score, never used in transcript selection."""
    c, t = meaningful_tokens(caption), meaningful_tokens(transcript)
    overlap = c & t
    coverage = len(overlap) / len(c) if c else 0.0
    precision = len(overlap) / len(t) if t else 0.0
    success = bool(transcript) and len(c) >= 4 and len(t) >= 4 and coverage >= 0.8 and precision >= 0.8
    return {
        "rule": "at least four meaningful tokens per side; >=80% caption coverage and >=80% ASR precision",
        "caption_tokens": sorted(c), "transcript_tokens": sorted(t),
        "overlap_tokens": sorted(overlap), "caption_coverage": coverage,
        "transcript_precision": precision, "observed": success,
    }
