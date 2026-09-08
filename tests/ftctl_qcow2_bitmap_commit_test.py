import importlib.util
import json
import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "qcow2_bitmap_commit", ROOT / "lib" / "ftctl" / "qcow2_bitmap_commit.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class FakeClient:
    def __init__(self, *args):
        self.calls = []

    def execute(self, command, arguments=None):
        self.calls.append((command, arguments))
        if command == "query-named-block-nodes":
            return [
                {"node-name": "disk-a", "drv": "qcow2", "active": True,
                 "image": {"filename": "/mnt/glue-gfs/a.qcow2"}},
                {"node-name": "disk-b", "drv": "qcow2", "active": True,
                 "image": {"filename": "/mnt/glue-gfs/b.qcow2"}},
            ]
        return {}


class CommitSetTest(unittest.TestCase):
    def test_complete_disk_set_is_one_qmp_transaction(self):
        original = MODULE.QmpClient
        client = FakeClient()
        MODULE.QmpClient = lambda *args: client
        try:
            MODULE.commit_set("i-2-234-VM", [
                {"sourcePath": "/mnt/glue-gfs/a.qcow2", "bitmap": "bitmap-a"},
                {"sourcePath": "/mnt/glue-gfs/b.qcow2", "bitmap": "bitmap-b"},
            ])
        finally:
            MODULE.QmpClient = original
        command, arguments = client.calls[-1]
        self.assertEqual("transaction", command)
        self.assertEqual(2, len(arguments["actions"]))
        self.assertEqual("disk-a", arguments["actions"][0]["data"]["node"])
        self.assertEqual("bitmap-b", arguments["actions"][1]["data"]["name"])


if __name__ == "__main__":
    unittest.main()
