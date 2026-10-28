import unittest
from concurrent.futures import ThreadPoolExecutor
import numpy as np
from birdlock.core.render import apply_gains, _SRGB2LIN, _LIN2SRGB

class ColorGainTests(unittest.TestCase):
    def test_lookup_matches_original_formula_for_all_input_values(self):
        img=np.tile(np.arange(256,dtype=np.uint8)[None,:,None],(3,1,3))
        for gains in ((.5,1,2),(4,.25,.75),(.01,8,1),(-1,0,2),(1,1,1)):
            expected=_LIN2SRGB[np.clip(_SRGB2LIN[img]*np.asarray(gains,np.float32)[::-1]*4095+.5,0,4095).astype(np.intp)]
            self.assertTrue(np.array_equal(apply_gains(img,gains),expected))
    def test_nonfinite_gains_are_bounded_and_repeatable(self):
        img=np.full((40,32,3),128,np.uint8)
        out=apply_gains(img,(float('nan'),float('inf'),float('-inf')))
        self.assertEqual(out.dtype,np.uint8);self.assertEqual(out.shape,img.shape)
        self.assertTrue(np.array_equal(out,apply_gains(img,(1,16,0))))
    def test_concurrent_portrait_images_remain_identical(self):
        img=np.random.default_rng(42).integers(0,256,(1368,1024,3),np.uint8)
        expected=apply_gains(img,(1.2,.8,2.4))
        with ThreadPoolExecutor(4) as pool:
            for result in pool.map(lambda _:apply_gains(img,(1.2,.8,2.4)),range(12)):
                self.assertTrue(np.array_equal(result,expected))
        self.assertFalse(_SRGB2LIN.flags.writeable);self.assertFalse(_LIN2SRGB.flags.writeable)
