"""Schema-directed text observer. Never rank ASR strings by expected caption."""
import re

STOP = {
    "the", "and", "that", "this", "with", "from", "into", "over",
    "under", "above", "below", "there", "their", "his", "her",
    "its", "are", "was", "were", "has", "have", "had", "for",
    "you", "your", "but", "image", "photo", "picture",
}


def _string_type(descriptor):
    if isinstance(descriptor, str):
        return descriptor.lower() in {"string", "str", "text"}
    if isinstance(descriptor, dict):
        return _string_type(descriptor.get("type", descriptor.get("name")))
    return False


def _text(value):
    if isinstance(value, str):
        txt = re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", value)).strip()
        if len(txt) >= 5 and not txt.lower().startswith(("http://", "https://", "/", "file:")):
            return txt
    elif isinstance(value, dict):
        for key in ("transcript", "transcription", "text", "value"):
            if key in value:
                return _text(value[key])
    return None


def extract_transcript(returned, contract):
    """Return (text, declared source) or (None, reason), never status/log text."""
    if not isinstance(contract, dict):
        return None, "invalid_contract"
    outputs = contract.get("returns")
    if not isinstance(outputs, list) or not outputs:
        return None, "no_declared_returns"
    indices = [i for i, o in enumerate(outputs) if isinstance(o, dict) and _string_type(o.get("type"))]
    if not indices:
        return None, "no_declared_text_return"
    if len(indices) > 1:
        named = [i for i in indices if str(outputs[i].get("name", "")).lower() in (
            "transcript", "transcription", "text", "result"
        )]
        if len(named) != 1:
            return None, "ambiguous_text_returns"
        indices = named
    idx = indices[0]
    data = returned
    if isinstance(returned, dict):
        for key in ("data", "result", "output", "outputs"):
            if key in returned:
                data = returned[key]
                break
        else:
            name = outputs[idx].get("name")
            if isinstance(name, str) and name in returned:
                data = returned[name]
            else:
                return None, "missing_declared_result"
    if isinstance(data, list):
        if idx >= len(data):
            return None, "declared_result_missing"
        value = data[idx]
    elif idx == 0 and len(outputs) == 1:
        value = data
    else:
        return None, "invalid_return_shape"
    candidate = _text(value)
    if candidate is None:
        return None, "declared_result_not_text"
    return candidate, "declared_return[%d]" % idx


def compare_caption_transcript(caption, transcript):
    def tokens(s):
        return {w for w in re.findall(r"[a-z0-9]+", (s or "").lower())
                if len(w) >= 4 and w not in STOP}
    a, b = tokens(caption), tokens(transcript)
    shared = a & b
    coverage = len(shared) / len(a) if a else 0.0
    precision = len(shared) / len(b) if b else 0.0
    jaccard = len(shared) / len(a | b) if a or b else 0.0
    return {
        "rule": "at least 3 shared meaningful tokens and >=80% caption-token coverage",
        "caption_tokens": sorted(a),
        "transcript_tokens": sorted(b),
        "overlap_tokens": sorted(shared),
        "caption_coverage": coverage,
        "transcript_precision": precision,
        "jaccard": jaccard,
        "observed": bool(transcript) and len(shared) >= 3 and coverage >= 0.80,
        "limitations": "lexical preservation through audio; does not establish visual-caption accuracy",
    }
