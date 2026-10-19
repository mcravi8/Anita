import importlib.util,json,sqlite3,sys,tempfile,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).parents[1]))   # install.py imports its sibling modules
spec=importlib.util.spec_from_file_location('install',Path(__file__).parents[1]/'install.py');install=importlib.util.module_from_spec(spec);spec.loader.exec_module(install)
SCHEMA="CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);CREATE TABLE tasks(seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT, workspace TEXT, archived INTEGER DEFAULT 0, body TEXT)"
class SavedQueueTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(suffix='.noindex');self.root=Path(self.temp.name);(self.root/'Worker').mkdir();self.saved=install.SUPPORT;install.SUPPORT=self.root
    def tearDown(self):
        install.SUPPORT=self.saved;self.temp.cleanup()
    def database(self,migrated=True,paused='0'):
        connection=sqlite3.connect(self.root/'Worker/operations.sqlite');connection.executescript(SCHEMA)
        if migrated:connection.execute("INSERT INTO meta VALUES('migration','{}'),('paused',?)",(paused,))
        for archived,status in [(0,'running'),(1,'completed'),(0,'queued')]:connection.execute('INSERT INTO tasks(id,workspace,archived,body) VALUES(?,?,?,?)',('x','w',archived,json.dumps({'status':status})))
        connection.commit();connection.close()
    def test_nothing_saved_yet(self):
        self.assertIsNone(install.saved_queue())
    def test_old_file_before_the_worker_has_made_its_database(self):
        (self.root/'Worker/tasks.json').write_text(json.dumps({'version':1,'paused':False,'tasks':[{'status':'running'}]}))
        self.assertEqual(install.saved_queue()['tasks'],[{'status':'running'}])
    def test_database_is_the_truth_once_it_exists(self):
        (self.root/'Worker/tasks.json').write_text(json.dumps({'version':1,'paused':False,'tasks':[{'status':'completed'}]}))
        self.database(paused='1');queue=install.saved_queue()
        self.assertTrue(queue['paused']);self.assertEqual([t['status'] for t in queue['tasks']],['running','queued'])
    def test_a_database_that_has_not_imported_yet_does_not_hide_the_old_file(self):
        (self.root/'Worker/tasks.json').write_text(json.dumps({'version':1,'paused':False,'tasks':[{'status':'running'}]}))
        self.database(migrated=False);self.assertEqual(install.saved_queue()['tasks'],[{'status':'running'}])
    def test_running_work_in_the_database_blocks_an_update(self):
        self.database();(self.root/'workspace.json').write_text('{}')
        with self.assertRaises(RuntimeError):install.ensure_idle()
if __name__=='__main__':unittest.main()
