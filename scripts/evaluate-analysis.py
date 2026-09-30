#!/usr/bin/env python3
"""Score saved, human-reviewed analysis runs. This command never calls a provider.

Input: {"cases": [{"id": str, "expected_requirement_ids": [str],
"critical_requirement_ids": [str], "runs": [{"model": str, "effort": str,
"covered_requirement_ids": [str], "unsupported_requirements": int,
"citation_count": int, "invalid_citations": int, "duplicate_tasks": int,
"review_corrections": int, "latency_seconds": float,
"input_tokens": int|null, "output_tokens": int|null}]}]}

Requirement coverage and semantic defects must be annotated by a human who has
checked the original evidence. A model's own quality score is not a gold label.
"""
import argparse
import json
from collections import defaultdict
from pathlib import Path


def summarize(dataset):
    groups = defaultdict(list)
    case_ids = set()
    for case in dataset["cases"]:
        if case["id"] in case_ids:
            raise ValueError("Duplicate case ID")
        case_ids.add(case["id"])
        expected = set(case["expected_requirement_ids"])
        critical = set(case.get("critical_requirement_ids", []))
        if not critical <= expected:
            raise ValueError("Critical requirements must belong to the expected set")
        candidates = set()
        for run in case["runs"]:
            key = (run["model"], run["effort"])
            if key in candidates:
                raise ValueError("Duplicate model/effort run in a case")
            candidates.add(key)
            covered = set(run["covered_requirement_ids"])
            if not covered <= expected:
                raise ValueError("Coverage contains unknown requirement IDs")
            for field in ("unsupported_requirements", "citation_count", "invalid_citations", "duplicate_tasks", "review_corrections"):
                if type(run[field]) is not int or run[field] < 0:
                    raise ValueError(f"{field} must be a nonnegative integer")
            if run["invalid_citations"] > run["citation_count"]:
                raise ValueError("Invalid citation count exceeds total citations")
            for field in ("input_tokens", "output_tokens"):
                if run.get(field) is not None and (type(run[field]) is not int or run[field] < 0):
                    raise ValueError(f"{field} must be a nonnegative integer or null")
            latency = run["latency_seconds"]
            if type(latency) not in (int, float) or not 0 <= latency < float("inf"):
                raise ValueError("latency_seconds must be finite and nonnegative")
            groups[key].append((case["id"], expected - covered, critical - covered, run))
    results = []
    for (model, effort), runs in sorted(groups.items()):
        citations = sum(r[3]["citation_count"] for r in runs)
        invalid = sum(r[3]["invalid_citations"] for r in runs)
        total = lambda field: sum(r[3][field] for r in runs)
        tokens = lambda field: None if any(r[3].get(field) is None for r in runs) else total(field)
        results.append({
            "model": model, "effort": effort, "case_ids": sorted(r[0] for r in runs),
            "comparable_full_dataset": len(runs) == len(case_ids),
            "missed_requirements": sum(len(r[1]) for r in runs),
            "missed_critical_requirements": sum(len(r[2]) for r in runs),
            "unsupported_requirements": total("unsupported_requirements"),
            "citation_accuracy": None if not citations else (citations - invalid) / citations,
            "invalid_citations": invalid, "duplicate_tasks": total("duplicate_tasks"),
            "review_corrections": total("review_corrections"),
            "latency_seconds": total("latency_seconds"),
            "input_tokens": tokens("input_tokens"), "output_tokens": tokens("output_tokens"),
        })
    return {"case_count": len(case_ids), "results": results}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dataset", type=Path)
    args = parser.parse_args()
    print(json.dumps(summarize(json.loads(args.dataset.read_text())), indent=2, allow_nan=False))
