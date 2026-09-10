#!/usr/bin/env python3
"""No-GUI regression: supervisor interruption must reap its own real child."""
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('streaming', Path(__file__).with_name('benchmark-streaming-core.py'))
streaming = importlib.util.module_from_spec(spec)
spec.loader.exec_module(streaming)


class SupervisorTests(unittest.TestCase):
    def test_interrupt_and_unexpected_exception_reap_exact_owned_child(self):
        for failure in [KeyboardInterrupt, RuntimeError]:
            with self.subTest(failure=failure.__name__), tempfile.TemporaryDirectory() as directory:
                log = Path(directory) / 'child.log'
                owned = []
                real_popen = subprocess.Popen
                def start(*args, **kwargs):
                    child = real_popen(*args, **kwargs)
                    owned.append(child)
                    real_wait = child.wait
                    def interrupted_wait(*args, **kwargs):
                        child.wait = real_wait
                        raise failure('synthetic supervisor interruption')
                    child.wait = interrupted_wait
                    return child
                try:
                    with patch.object(streaming.subprocess, 'Popen', side_effect=start):
                        with self.assertRaises(failure):
                            streaming.run_child([sys.executable, '-c', 'import time; time.sleep(60)'], log, 10)
                    self.assertEqual(len(owned), 1)
                    self.assertIsNotNone(owned[0].poll(), 'interrupted supervisor left its exact owned child alive')
                    status = json.loads(log.with_suffix(log.suffix + '.status.json').read_text())
                    self.assertEqual(status['interrupted'], failure.__name__)
                    self.assertTrue(status['reaped'])
                    self.assertTrue(log.exists(), 'partial log must remain')
                finally:
                    # Red-run cleanup is restricted to the child spawned in this test.
                    for child in owned:
                        if child.poll() is None:
                            os.killpg(child.pid, signal.SIGKILL)
                            child.wait()


if __name__ == '__main__':
    unittest.main()
