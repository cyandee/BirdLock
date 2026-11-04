import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import onnxruntime as ort
from birdlock.core.aircraft import AircraftPartsModel


class AircraftGPUTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.model=AircraftPartsModel(Path(self.temp.name),device='gpu:1');self.addCleanup(self.model.close)
        self.meta=dict(file='fixture.onnx',token_ids=list(range(8)))
        self.calls=[]

    def factory(self,*,init_fail=False,run_fail=False,cpu_only=False):
        model=self.model;calls=self.calls
        class Session:
            def __init__(self,path,sess_options,providers):
                calls.append((sess_options,providers));self.providers=[p[0] if isinstance(p,tuple) else p for p in providers]
                if init_fail and 'DmlExecutionProvider' in self.providers:raise RuntimeError('unsupported device')
            def disable_fallback(self):pass
            def get_providers(self):return self.providers
            def run(self,names,inputs):
                if run_fail and 'DmlExecutionProvider' in self.providers:raise RuntimeError('GPU kernel failed')
                return ['logits','boxes']
            def end_profiling(self):
                path=Path(model._profile.name)/'first.json'
                providers=['CPUExecutionProvider'] if cpu_only else self.providers
                path.write_text(json.dumps([dict(cat='Node',args=dict(provider=p)) for p in providers]),encoding='utf-8');return str(path)
        return Session

    def context(self,factory):
        from contextlib import ExitStack
        stack=ExitStack();self.addCleanup(stack.close)
        stack.enter_context(patch('birdlock.core.aircraft.IS_WINDOWS',True))
        stack.enter_context(patch('birdlock.core.aircraft.verify_model',return_value=self.meta))
        stack.enter_context(patch('birdlock.core.aircraft.gpu.onnx_providers',return_value=[('DmlExecutionProvider',dict(device_id=1)),'CPUExecutionProvider']))
        stack.enter_context(patch('onnxruntime.InferenceSession',side_effect=factory))

    def test_selected_gpu_directml_options_and_actual_mixed_execution(self):
        self.context(self.factory());self.model._load()
        options,providers=self.calls[0]
        self.assertFalse(options.enable_mem_pattern);self.assertEqual(options.execution_mode,ort.ExecutionMode.ORT_SEQUENTIAL)
        self.assertEqual(providers[0],('DmlExecutionProvider',dict(device_id=1)))
        self.assertIn('待验证',self.model.device_description)
        self.model._run({})
        self.assertEqual(self.model.execution,dict(DmlExecutionProvider=1,CPUExecutionProvider=1))
        self.assertIn('混合',self.model.device_description);self.assertIsNone(self.model._profile)

    def test_provider_registration_without_gpu_nodes_does_not_claim_gpu_execution(self):
        self.context(self.factory(cpu_only=True));self.model._load();self.model._run({})
        self.assertEqual(self.model.device_description,'CPU')

    def test_initialization_and_runtime_failures_retry_cpu_once(self):
        for init_fail,run_fail in ((True,False),(False,True)):
            with self.subTest(initialization=init_fail):
                self.model.close();self.calls.clear()
                with patch('birdlock.core.aircraft.IS_WINDOWS',True),patch('birdlock.core.aircraft.verify_model',return_value=self.meta),patch('birdlock.core.aircraft.gpu.onnx_providers',return_value=[('DmlExecutionProvider',dict(device_id=1)),'CPUExecutionProvider']),patch('onnxruntime.InferenceSession',side_effect=self.factory(init_fail=init_fail,run_fail=run_fail)):
                    self.model._load();self.model._run({});self.model._run({})
                    self.assertEqual(len(self.calls),2);self.assertEqual(self.model.providers,['CPUExecutionProvider'])
                    self.assertIn('回退',self.model.device_description)

if __name__=='__main__':unittest.main()
