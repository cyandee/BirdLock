import json,tempfile,unittest
from pathlib import Path
from birdlock.core.release_notice import ReleaseNotice

class ReleaseNoticeTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup);self.root=Path(self.temp.name)
    def test_first_install_is_silent_and_upgrade_shows_once(self):
        self.assertFalse(ReleaseNotice(self.root,'1.9.0').start())
        self.assertFalse(ReleaseNotice(self.root,'1.9.0').start())
        next=ReleaseNotice(self.root,'1.9.1');self.assertTrue(next.start());next.acknowledge()
        self.assertFalse(ReleaseNotice(self.root,'1.9.1').start())
    def test_15_settings_without_marker_resume_pending_until_read(self):
        (self.root/'settings.json').write_text(json.dumps({'agreementAccepted':'1.0'}))
        notice=ReleaseNotice(self.root,'1.9.0');self.assertTrue(notice.start())
        self.assertTrue(ReleaseNotice(self.root,'1.9.0').start());notice.acknowledge()
        self.assertFalse(ReleaseNotice(self.root,'1.9.0').start())
    def test_downgrade_and_later_created_settings_do_not_trigger(self):
        notice=ReleaseNotice(self.root,'1.9.0')
        (self.root/'settings.json').write_text(json.dumps({'agreementAccepted':'1.0'}))
        self.assertFalse(notice.start());self.assertFalse(ReleaseNotice(self.root,'1.8.1').start())
