"""Fail-closed selection for evidence-preserving CI cancellation. No network I/O."""
import copy
import re

ACTIVE = frozenset({"queued", "in_progress", "waiting", "pending", "requested"})


def valid_sha(value):
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{40}", value) is not None


def same_identity(value, expected):
    """JSON booleans and floats must never count as integer resource identities."""
    return type(value) is int and value > 0 and value == expected


def is_superseded(run, pulls, repository_id):
    """Only select an old PR head; preserve ambiguous, shared, fork and manual runs."""
    try:
        if type(repository_id) is not int or repository_id <= 0:
            return False
        if not isinstance(run, dict) or not isinstance(pulls, dict):
            return False
        if run.get("event") != "pull_request" or run.get("status") not in ACTIVE:
            return False
        if not same_identity(run["repository"]["id"], repository_id):
            return False
        if not same_identity(run["head_repository"]["id"], repository_id):
            return False
        sha, branch = run["head_sha"], run["head_branch"]
        if not valid_sha(sha) or not isinstance(branch, str) or not branch:
            return False
        associations = run["pull_requests"]
        if not isinstance(associations, list) or not 1 <= len(associations) <= 100:
            return False
        seen = set()
        for association in associations:
            number = association["number"]
            if type(number) is not int or number <= 0 or number in seen:
                return False
            seen.add(number)
            pull = pulls[number]
            if not same_identity(pull["number"], number) or pull["state"] != "open":
                return False
            if not same_identity(pull["base"]["repo"]["id"], repository_id):
                return False
            head = pull["head"]
            if not same_identity(head["repo"]["id"], repository_id) or head["ref"] != branch:
                return False
            if not valid_sha(head["sha"]) or head["sha"] == sha:
                return False
        return True
    except (KeyError, TypeError, AttributeError):
        return False


def self_test():
    run = {"event": "pull_request", "status": "in_progress", "repository": {"id": 1},
           "head_repository": {"id": 1}, "head_sha": "a" * 40, "head_branch": "feature/test",
           "pull_requests": [{"number": 10}]}
    pull = {"number": 10, "state": "open", "base": {"repo": {"id": 1}},
            "head": {"repo": {"id": 1}, "ref": "feature/test", "sha": "b" * 40}}
    cases = [("superseded", run, {10: pull}, True)]
    for event in ("push", "workflow_dispatch", "schedule", "pull_request_target"):
        item = copy.deepcopy(run)
        item["event"] = event
        cases.append((event, item, {10: pull}, False))
    for key, value in (("status", "completed"), ("head_sha", "bad"), ("head_branch", ""),
                       ("pull_requests", []), ("pull_requests", [{"number": True}]),
                       ("head_repository", {"id": 2}), ("repository", {"id": 2})):
        item = copy.deepcopy(run)
        item[key] = value
        cases.append((key, item, {10: pull}, False))
    for key, value in (("sha", "a" * 40), ("sha", "bad"), ("ref", "other"), ("repo", {"id": 2})):
        item = copy.deepcopy(pull)
        item["head"][key] = value
        cases.append(("head_" + key, run, {10: item}, False))
    closed = copy.deepcopy(pull)
    closed["state"] = "closed"
    cases.extend([("closed", run, {10: closed}, False), ("missing", run, {}, False)])
    shared = copy.deepcopy(run)
    shared["pull_requests"].append({"number": 11})
    current = copy.deepcopy(pull)
    current["number"] = 11
    current["head"]["sha"] = "a" * 40
    cases.append(("shared_current_head", shared, {10: pull, 11: current}, False))

    # Retain the original 19 scenarios and add malformed-identity regressions.
    for location in ("repository", "head_repository", "base", "head"):
        for value in (True, 1.0, "1", None):
            candidate_run, candidate_pull = copy.deepcopy(run), copy.deepcopy(pull)
            if location in ("repository", "head_repository"):
                candidate_run[location]["id"] = value
            else:
                candidate_pull[location]["repo"]["id"] = value
            cases.append(("strict_" + location + "_" + repr(value), candidate_run,
                          {10: candidate_pull}, False))
    for value in (True, 10.0, "10", None):
        item = copy.deepcopy(pull)
        item["number"] = value
        cases.append(("strict_pull_number_" + repr(value), run, {10: item}, False))
    duplicate = copy.deepcopy(run)
    duplicate["pull_requests"].append({"number": 10})
    cases.append(("duplicate_association", duplicate, {10: pull}, False))
    oversized = copy.deepcopy(run)
    oversized["pull_requests"] = [{"number": 10}] * 101
    cases.append(("oversized_associations", oversized, {10: pull}, False))
    for malformed in (None, [], "run", 1):
        cases.append(("malformed_run_" + repr(malformed), malformed, {10: pull}, False))
    for label, candidate, pulls, expected in cases:
        actual = is_superseded(candidate, pulls, 1)
        if actual is not expected:
            raise AssertionError("Failed cancellation policy case: " + label)
    count = len(cases)
    for repository_id in (True, 1.0, "1", None, 0, -1):
        if is_superseded(run, {10: pull}, repository_id) is not False:
            raise AssertionError("Invalid repository identity was accepted")
        count += 1
    print("PASS: " + str(count) + " cancellation-policy cases")
    return count


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true", required=True)
    parser.parse_args()
    self_test()
