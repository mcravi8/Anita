import sys,unittest
from pathlib import Path
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import signing

class SigningTests(unittest.TestCase):
 def test_adhoc_cannot_regress_permissions(self):
  with patch.object(signing,'requirement',side_effect=['identifier "app.buddy.desktop"','cdhash H"new"']):
   with self.assertRaises(RuntimeError):signing.verify_update('old','new')
 def test_legacy_migrates_to_stable_identity(self):
  with patch.object(signing,'requirement',side_effect=['cdhash H"old"','identifier "app.buddy.desktop" and anchor apple generic']),patch.object(signing.subprocess,'run') as run:
   signing.verify_update('old','new');run.assert_not_called()
 def test_later_updates_must_satisfy_old_requirement(self):
  requirement='identifier "app.buddy.desktop" and anchor apple generic'
  with patch.object(signing,'requirement',return_value=requirement),patch.object(signing.subprocess,'run') as run:
   signing.verify_update('old','new');run.assert_called_once_with(['codesign','--verify','--strict','-R','='+requirement,'new'],check=True)
if __name__=='__main__':unittest.main()
