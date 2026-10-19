import json
import unittest
from birdlock.core.subjects import SubjectProfile,presets
from birdlock.core.settings import LockPoint,FocusMarkColor


class SubjectProfileTests(unittest.TestCase):
    def test_aircraft_defaults_keep_independent_bird_colors_and_shutter_choices(self):
        bird=SubjectProfile();bird.presetID='lead';bird.composition.anchorX=.36
        bird.export.focusMark.captureFlash=True;bird.export.focusMark.captureColor=FocusMarkColor.WHITE
        bird.export.focusMark.headColor=FocusMarkColor.ORANGE;bird.selection.trimStart=8
        plane=SubjectProfile.initial_aircraft(bird)
        self.assertEqual(plane.composition.lockPoint,LockPoint.HEAD_CENTER)
        self.assertAlmostEqual(plane.export.aspect.w/plane.export.aspect.h,16/9)
        self.assertFalse(plane.export.focusMark.showEye);self.assertTrue(plane.export.focusMark.showHead)
        self.assertTrue(plane.export.focusMark.showBody);self.assertTrue(plane.export.focusMark.captureFlash)
        self.assertEqual(plane.export.focusMark.captureColor,FocusMarkColor.WHITE)
        self.assertEqual((plane.selection.trimStart,plane.selection.trimEnd),(0,-1))
        plane.export.focusMark.headColor=FocusMarkColor.BLACK;plane.composition.anchorX=.8
        self.assertEqual(bird.export.focusMark.headColor,FocusMarkColor.ORANGE)
        self.assertEqual(bird.composition.anchorX,.36);self.assertEqual(bird.selection.trimStart,8)

    def test_profile_json_restores_nested_values_and_tolerates_legacy_missing_fields(self):
        profile=SubjectProfile();profile.export.focusMark.bodySize=2.1
        restored=SubjectProfile.from_dict(json.loads(json.dumps(profile.to_dict())))
        self.assertEqual(restored.export.focusMark.bodySize,2.1)
        old=SubjectProfile.from_dict({'composition':{'anchorX':.4},'export':{'focusMark':{'color':'white'}}})
        self.assertEqual(old.composition.anchorX,.4);self.assertEqual(old.export.focusMark.headColor,FocusMarkColor.WHITE)

    def test_presets_match_subject_and_keep_bird_registry(self):
        self.assertEqual(presets('bird')[0].id,'center')
        self.assertEqual(presets('aircraft')[1].id,'aircraft-lead')
        self.assertTrue(all(p.composition.lockPoint==LockPoint.HEAD_CENTER for p in presets('aircraft')))


if __name__=='__main__':unittest.main()
