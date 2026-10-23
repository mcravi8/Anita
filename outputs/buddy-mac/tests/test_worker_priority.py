import importlib.util,os,plistlib,sys,tempfile,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).parents[1]))   # install.py imports its sibling modules
spec=importlib.util.spec_from_file_location('install',Path(__file__).parents[1]/'install.py');install=importlib.util.module_from_spec(spec);spec.loader.exec_module(install)
# An update restarts the worker from the launch settings already on the Mac, which an earlier Buddy wrote as a launchd "Background" job: every
# program an agent ran inherited background priority (the user's S02a computation ran on the efficiency cores with a third of the Mac idle).
# The update takes that setting out before it starts the worker again; nothing else in the file changes.
class WorkerPriorityTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(suffix='.noindex');self.agent=Path(self.temp.name)/'app.buddy.worker.plist'
    def tearDown(self):self.temp.cleanup()
    def write(self,values):
        self.agent.write_bytes(plistlib.dumps(values));os.chmod(self.agent,0o600)
    def test_background_setting_is_taken_out(self):
        values={'Label':'app.buddy.worker','ProgramArguments':['/Applications/Buddy.app/Contents/Helpers/Buddy Worker.app/Contents/MacOS/BuddyWorker','--worker'],'ProcessType':'Background','Umask':63}
        self.write(values)
        self.assertTrue(install.full_priority(self.agent))
        after=plistlib.loads(self.agent.read_bytes());del values['ProcessType']
        self.assertEqual(after,values);self.assertEqual(self.agent.stat().st_mode&0o777,0o600)
    def test_settings_without_it_are_left_alone(self):
        self.write({'Label':'app.buddy.worker','Umask':63});before=self.agent.read_bytes()
        self.assertFalse(install.full_priority(self.agent));self.assertEqual(self.agent.read_bytes(),before)
    def test_no_settings_file_yet(self):
        self.assertFalse(install.full_priority(self.agent));self.assertFalse(self.agent.exists())
if __name__=='__main__':unittest.main()
