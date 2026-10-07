"""Offline RED/GREEN tests for ASR observer and workflow."""
import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("alien_observer", ROOT / "observer.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

CAPTION = "A man is sitting in the ocean fully clothed holding a fishing pole in his hand."
CONTRACT = {"returns": [{"name": "transcript", "type": {"type": "string"}}]}


class ObserverTests(unittest.TestCase):
    def test_status_longer_than_transcript_is_ignored(self):
        returned = {
            "data": ["Caption a man is sitting in the ocean fully clothed holding a fishing pole in his hand."],
            "status": "TRANSCRIPTION COMPLETE " + ("unrelated progress text " * 60),
        }
        text, source = mod.extract_transcript(returned, CONTRACT)
        self.assertTrue(text.startswith("Caption a man"))
        self.assertEqual(source, "declared_return[0]")
        self.assertTrue(mod.compare_caption_transcript(CAPTION, text)["observed"])

    def test_empty_declared_data_does_not_use_success_message(self):
        text, reason = mod.extract_transcript({"data": [None], "status": "transcription complete successful"}, CONTRACT)
        self.assertIsNone(text)
        self.assertEqual(reason, "declared_result_not_text")

    def test_does_not_optimise_selection_for_caption_similarity(self):
        unrelated = "The observed speaker said something entirely different."
        candidate, _ = mod.extract_transcript(
            {"data": [unrelated], "status": "A man sitting in the ocean holding a fishing pole"},
            CONTRACT,
        )
        self.assertEqual(candidate, unrelated)
        self.assertFalse(mod.compare_caption_transcript(CAPTION, candidate)["observed"])

    def test_declared_index_controls_selection(self):
        c = {"returns": [
            {"name": "audio", "type": {"type": "filepath"}},
            {"name": "transcript", "type": {"type": "string"}},
        ]}
        candidate, source = mod.extract_transcript(
            {"data": ["/tmp/audio.wav", "The actual spoken transcript"], "status": "long status"},
            c,
        )
        self.assertEqual(candidate, "The actual spoken transcript")
        self.assertEqual(source, "declared_return[1]")

    def test_ambiguous_declared_text_returns_fail_closed(self):
        c = {"returns": [
            {"name": "message", "type": "string"},
            {"name": "status", "type": "string"},
        ]}
        self.assertEqual(mod.extract_transcript(["hi there", "something else"], c)[1],
                         "ambiguous_text_returns")

    def test_string_payload_requires_unambiguous_single_return(self):
        self.assertEqual(
            mod.extract_transcript("This is a valid transcript", CONTRACT)[0],
            "This is a valid transcript",
        )
        self.assertIsNone(mod.extract_transcript({"status": "long status"}, CONTRACT)[0])

    def test_empty_and_short_caption_cannot_succeed(self):
        self.assertFalse(mod.compare_caption_transcript("", "a random transcript")["observed"])
        self.assertFalse(mod.compare_caption_transcript("Ocean fishing", "Ocean fishing")["observed"])

    def test_roundtrip_preserves_all_caption_tokens(self):
        transcript = "Caption a man is sitting in the ocean fully clothed holding a fishing pole in his hand."
        proof = mod.compare_caption_transcript(CAPTION, transcript)
        self.assertTrue(proof["observed"])
        self.assertEqual(len(proof["overlap_tokens"]), 8)
        self.assertEqual(proof["caption_coverage"], 1.0)
        self.assertLess(proof["transcript_precision"], 1.0)

    def test_workflow_does_not_patch_python_at_runtime(self):
        workflow = (ROOT.parents[1] / ".github/workflows/alien-relay.yml").read_text()
        self.assertNotIn("generation7_retry.py", workflow)
        self.assertNotIn("s.replace(old1", workflow)
        self.assertIn("py_compile", workflow)


if __name__ == "__main__":
    unittest.main()
