import copy
import unittest
from helpers import load_script
m = load_script('wb-svc-spark')


class NativeHostInfo(unittest.TestCase):
    def test_native_readiness_requires_every_capability(self):
        ready = {'configuration': {'container': {'runtime': 'docker', 'buildtime': 'docker'}},
                 'hostState': {'gitVersion': '2', 'gitLFSVersion': '3', 'dockerClientVersion': '29',
                 'dockerServerVersion': '29', 'dockerIsRunning': True, 'needDockerGroupAddition': False,
                 'nvidiaRuntimeIsConfigured': True, 'containerToolkitVersion': '1.20',
                 'gpuDevices': [{'name': 'GB10'}], 'gpuDriverMissing': False}}
        self.assertTrue(m.native_ready(ready))
        for key in ready['hostState']:
            broken = copy.deepcopy(ready)
            del broken['hostState'][key]
            with self.subTest(missing=key): self.assertFalse(m.native_ready(broken))
        ready['configuration']['container']['runtime'] = 'podman'
        self.assertFalse(m.native_ready(ready))
