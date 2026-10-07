"""RED/GREEN regression gates for Generation 7's failed cloud observer."""
import unittest
from asr_observer import compare_caption, extract_transcript

CAPTION = "Caption A man is sitting in the ocean fully clothed holding a fishing pole in his hand."
ASR = "Caption a man is sitting in the ocean fully clothed holding a fishing pole in his hand."
STATUS = "Done · audio 0:05 · processed in 40.7s · Cortiq 0.8.4 / Whisper large-v3-turbo Q4TP mixed"
CONTRACT = {"returns": [
    {"name": "Transcript", "type": {"type": "string"}},
    {"name": "value_9", "type": {"type": "string"}},
]}


class ASRObserverTests(unittest.TestCase):
    def test_real_gradio_named_outputs_choose_transcript_not_longer_status(self):
        response = {"Transcript": ASR, "value_9": STATUS}
        result = extract_transcript(response, CONTRACT)
        self.assertEqual(result["text"], ASR)
        self.assertEqual(result["source"], "field:Transcript")
        self.assertTrue(compare_caption(CAPTION, result["text"])["observed"])

    def test_declared_order_list_and_data_arrays(self):
        for response in ([ASR, STATUS], {"data": [ASR, STATUS]}):
            with self.subTest(response=response):
                result = extract_transcript(response, CONTRACT)
                self.assertEqual(result["text"], ASR)

    def test_not_cherry_pick_based_on_caption(self):
        result = extract_transcript({"Transcript": STATUS, "value_9": ASR}, CONTRACT)
        self.assertEqual(result["text"], STATUS)
        self.assertFalse(compare_caption(CAPTION, result["text"])["observed"])

    def test_ambiguous_generic_fields_fail_closed(self):
        contract = {"returns": [{"name": "value_0", "type": {"type": "string"}},
                                {"name": "value_9", "type": {"type": "string"}}]}
        self.assertIsNone(extract_transcript({"value_0": ASR, "value_9": STATUS}, contract)["text"])

    def test_status_only_does_not_prove_transcription(self):
        contract = {"returns": [{"name": "status", "type": {"type": "string"}}]}
        self.assertIsNone(extract_transcript({"status": ASR}, contract)["text"])

    def test_single_text_output_is_supported_without_caption(self):
        contract = {"returns": [{"name": "output", "type": {"type": "string"}}]}
        self.assertEqual(extract_transcript({"output": ASR}, contract)["text"], ASR)
        self.assertEqual(extract_transcript({"data": [ASR]}, contract)["text"], ASR)

    def test_no_contract_or_nonstring_contract_fail_closed(self):
        self.assertIsNone(extract_transcript({"Transcript": ASR}, {})["text"])
        self.assertIsNone(extract_transcript({"Transcript": ASR},
                          {"returns": [{"name": "Transcript", "type": {"type": "file"}}]})["text"])

    def test_independent_comparison_rejects_unrelated_utterance(self):
        self.assertFalse(compare_caption(CAPTION, "The weather will be sunny tomorrow.")["observed"])

    def test_independent_comparison_rejects_insufficient_evidence(self):
        self.assertFalse(compare_caption("Hello", "Hello")["observed"])


if __name__ == "__main__":
    unittest.main()
