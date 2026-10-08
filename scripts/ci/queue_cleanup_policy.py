"""Fail-closed selection for evidence-preserving CI cancellation. No network I/O."""
import copy
import re

ACTIVE = frozenset({"queued", "in_progress", "waiting", "pending", "requested"})


def valid_sha(value):
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{40}", value) is not None


def is_superseded(run, pulls, repository_id):
    """Only cancel an old PR head; preserve ambiguous, shared, fork and manual runs."""
    try:
        if type(repository_id) is not int or repository_id <= 0:
            return False
        if run.get("event") != "pull_request" or run.get("status") not in ACTIVE:
            return False
        if run["repository"]["id"] != repository_id:
            return False
        if run["head_repository"]["id"] != repository_id:
            return False
        sha, branch = run["head_sha"], run["head_branch"]
        if not valid_sha(sha) or not isinstance(branch, str) or not branch:
            return False
        associations = run["pull_requests"]
        if not isinstance(associations, list) or not associations:
            return False
        for association in associations:
            number = association["number"]
            if type(number) is not int or number <= 0:
                return False
            pull = pulls[number]
            if pull["number"] != number or pull["state"] != "open":
                return False
            if pull["base"]["repo"]["id"] != repository_id:
                return False
            head = pull["head"]
            if head["repo"]["id"] != repository_id or head["ref"] != branch:
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
    for label, candidate, pulls, expected in cases:
        actual = is_superseded(candidate, pulls, 1)
        if actual is not expected:
            raise AssertionError("Failed cancellation policy case: " + label)
    print("PASS: " + str(len(cases)) + " cancellation-policy cases")
    return len(cases)


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true", required=True)
    parser.parse_args()
    self_test()
