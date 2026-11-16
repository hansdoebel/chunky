import io
import unittest
from unittest.mock import patch

import fastembed_daemon as daemon


class Vector(list):
    def tolist(self):
        return list(self)


class Encoder:
    instances = []

    @staticmethod
    def list_supported_models():
        return [{"model": daemon.MODEL, "dim": 512}]

    def __init__(self, **kwargs):
        self.options = kwargs
        self.calls = []
        self.instances.append(self)

    def passage_embed(self, texts, **kwargs):
        self.calls.append("document")
        return [Vector([1.0] * 512) for _ in texts]

    def query_embed(self, texts, **kwargs):
        self.calls.append("query")
        return [Vector([2.0] * 512) for _ in texts]


class RuntimeTests(unittest.TestCase):
    def request(self, **kw):
        return {"model": daemon.MODEL, "command": "embed", "texts": ["paper"], "query": False, **kw}

    def test_model_reused_and_document_query_paths_separate(self):
        runtime = daemon.Runtime(Encoder)
        document = runtime.handle(self.request())
        query = runtime.handle(self.request(query=True))
        self.assertEqual(runtime.encoder.calls, ["document", "query"])
        self.assertEqual(document["dimensions"], 512)
        self.assertEqual(document["vectors"][0][0], 1)
        self.assertEqual(query["vectors"][0][0], 2)
        self.assertTrue(runtime.encoder.options["local_files_only"])

    def test_prepare_is_only_downloading_operation(self):
        runtime = daemon.Runtime(Encoder)
        runtime.handle(self.request(command="prepare"))
        self.assertFalse(runtime.encoder.options["local_files_only"])

    def test_unknown_model_never_initializes(self):
        runtime = daemon.Runtime(Encoder)
        with self.assertRaises(ValueError):
            runtime.handle(self.request(model="stella"))
        self.assertIsNone(runtime.encoder)

    def test_empty_and_invalid_inputs(self):
        runtime = daemon.Runtime(Encoder)
        self.assertEqual(runtime.handle(self.request(texts=[]))["vectors"], [])
        for texts in ([""], ["   "], [4], None):
            with self.assertRaises(ValueError):
                runtime.handle(self.request(texts=texts))

    def test_invalid_vectors_rejected(self):
        runtime = daemon.Runtime(Encoder)
        encoder = runtime.load()
        for vector in ([0.0] * 511, [float("nan")] * 512):
            with patch.object(encoder, "passage_embed", return_value=[Vector(vector)]):
                with self.assertRaises(ValueError):
                    runtime.handle(self.request())

    def test_health_does_not_download(self):
        runtime = daemon.Runtime(Encoder)
        self.assertIn("Ready", runtime.handle(self.request(command="health"))["status"])
        self.assertTrue(runtime.encoder.options["local_files_only"])

    def test_health_failure_actionable(self):
        with patch.object(Encoder, "list_supported_models", return_value=[]):
            status = daemon.Runtime(Encoder).handle(self.request(command="health"))["status"]
            self.assertIn("make setup-venv", status)
            self.assertIn("Download model", status)

    def test_protocol_survives_bad_request(self):
        stdin = io.StringIO('not-json\n{"model":"wrong"}\n')
        stdout = io.StringIO()
        with patch("sys.stdin", stdin), patch("sys.stdout", stdout):
            daemon.main()
        self.assertEqual(len(stdout.getvalue().splitlines()), 2)
        self.assertIn('"error"', stdout.getvalue())


if __name__ == "__main__":
    unittest.main()
