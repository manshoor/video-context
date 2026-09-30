# Evidence-grounded analysis evaluation

The accuracy profile is a starting configuration, not a measured model ranking.
No live model benchmark is implied by the automated tests.

## Prepare the same evidence for every candidate

Use a separate test library containing consented recordings and documentation.
Select the same original recordings, reviewed product documents, imported repository
files, and current requests for each run. Keep all revisions fixed. Use cases with:

- A clear request supported by the original recording and documentation.
- A request that conflicts with a reviewed requirement.
- A newer repository file whose imported snapshot has not been refreshed.
- Missing or unreadable original footage.
- Small UI labels, incorrect OCR, and visually ambiguous text.
- Repeated feedback expressing one issue in different words.
- Requirements spread across several transcript and document batches.
- A confirmed decision that resolves a previous conflict.

A human must label the expected requirements and critical requirements, their
supporting citations, and the expected conflict behavior before scoring runs.
Treat document-only background information as context unless the current request
asks for it to become work. Do not use a model's self-assessed confidence as truth.

## Candidates

Compare `gpt-5.6-terra`, `gpt-6-sol`, and `gpt-6-astra` at `high` using the same
task-generation inputs. On difficult cases also compare `high` and `max` for
the same model. Keep the reviewer (`claude-opus-5-5`, `high`) fixed when comparing
analysis models. Record analysis-only and reviewed results separately if evaluating
the benefit of review. Never compare a candidate with fewer test cases as a winner.

Live runs require explicit authorization, configured API credentials, and confirmed
account access. Changing settings does not authorize an evaluation or reprocess
completed recordings. Inspect the usage run for actual counts and latency; leave
missing provider usage as `null`.

## Score saved runs

Create a JSON dataset with one case per fixture. Requirement IDs refer to the
human-reviewed expected list, not generated task IDs. Mark which requirements each
run actually covers; manually count unsupported requirements, incorrect citations,
duplicate tasks, and review corrections. Both legitimate evidence and semantic
support matter: a valid ID alone does not make a claim supported.

```json
{
  "cases": [
    {
      "id": "conflicting-doc-video",
      "expected_requirement_ids": ["requirement-A", "requirement-B"],
      "critical_requirement_ids": ["requirement-B"],
      "runs": []
    }
  ]
}
```

For each authorized run, append an object to `runs` containing `model`, `effort`,
`covered_requirement_ids`, `unsupported_requirements`, `citation_count`,
`invalid_citations`, `duplicate_tasks`, `review_corrections`, `latency_seconds`,
`input_tokens`, and `output_tokens`. All defect counts are nonnegative integers.

Run `python3 scripts/evaluate-analysis.py /absolute/path/to/reviewed-runs.json`.
The scorer makes no network calls. It preserves unknown token counts and flags
incomplete candidate coverage. Its own verification is
`python3 scripts/test-evaluate-analysis.py`.

Choose a default only after checking the actual failed cases. Require no newly
missed critical requirements, no unsupported requirements accepted for implementation,
valid citations, and conflicts held for a human decision. Report cost and latency
alongside quality; do not infer monetary totals when pricing or usage is unavailable.
