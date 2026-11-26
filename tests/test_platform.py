import json
import runpy
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


review = runpy.run_path(str(Path(__file__).resolve().parents[1] / "scripts/platform.py"))["review"]


class TerraformPlanTests(unittest.TestCase):
    def run_review(self, actions, apply, destroy=False):
        commands = []
        def command(*args, **kwargs):
            commands.append(args)
            if "show" in args:
                return json.dumps({"resource_changes": [{"change": {"actions": actions}}]})
            return "{}" if "output" in args else ""
        with tempfile.TemporaryDirectory() as directory, patch.dict(review.__globals__, run=command):
            review(["terraform"], {}, apply, Path(directory), destroy)
        return commands

    def test_retirement_preview_never_applies(self):
        commands = self.run_review(["delete"], False, True)
        self.assertTrue(any("-destroy" in cmd for cmd in commands))
        self.assertFalse(any("apply" in cmd for cmd in commands))

    def test_setup_rejects_replacement(self):
        with self.assertRaises(ValueError):
            self.run_review(["delete", "create"], True)

    def test_retirement_rejects_creation(self):
        with self.assertRaises(ValueError):
            self.run_review(["create"], False, "retire")
