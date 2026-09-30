import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("evaluation", Path(__file__).with_name("evaluate-analysis.py"))
evaluation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evaluation)


class EvaluationTests(unittest.TestCase):
    def case(self):
        return {"id": "conflicting-doc-video", "expected_requirement_ids": ["A", "B"],
                "critical_requirement_ids": ["B"], "runs": [{"model": "fixture", "effort": "high",
                "covered_requirement_ids": ["A"], "unsupported_requirements": 1,
                "citation_count": 4, "invalid_citations": 1, "duplicate_tasks": 2,
                "review_corrections": 1, "latency_seconds": 4.5,
                "input_tokens": None, "output_tokens": 9}]}

    def test_missing_critical_requirements_and_unknown_usage_are_preserved(self):
        result = evaluation.summarize({"cases": [self.case()]})["results"][0]
        self.assertEqual(result["missed_critical_requirements"], 1)
        self.assertEqual(result["citation_accuracy"], 0.75)
        self.assertIsNone(result["input_tokens"])
        self.assertEqual(result["duplicate_tasks"], 2)

    def test_unknown_gold_requirement_cannot_inflate_coverage(self):
        case = self.case()
        case["runs"][0]["covered_requirement_ids"] = ["fabricated"]
        with self.assertRaises(ValueError):
            evaluation.summarize({"cases": [case]})

    def test_incomplete_candidate_is_not_treated_as_comparable(self):
        first, second = self.case(), self.case()
        second["id"] = "ocr-disagreement"
        second["runs"] = []
        result = evaluation.summarize({"cases": [first, second]})["results"][0]
        self.assertFalse(result["comparable_full_dataset"])


if __name__ == "__main__":
    unittest.main()
