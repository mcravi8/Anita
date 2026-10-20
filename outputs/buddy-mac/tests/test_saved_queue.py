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
    def idle(self):
        # The last step, "is Buddy itself still open", reads the process list; these fixtures are about the saved queue only.
        saved=install.subprocess.check_output;install.subprocess.check_output=lambda *a,**k:''
        try:return install.ensure_idle()
        finally:install.subprocess.check_output=saved
    def tasks(self,bodies,paused='0'):
        connection=sqlite3.connect(self.root/'Worker/operations.sqlite');connection.executescript(SCHEMA)
        connection.execute("INSERT INTO meta VALUES('migration','{}'),('paused',?)",(paused,))
        for body in bodies:connection.execute('INSERT INTO tasks(id,workspace,archived,body) VALUES(?,?,?,?)',('x','w',0,json.dumps(body)))
        connection.commit();connection.close();(self.root/'workspace.json').write_text('{}')
    def test_running_queued_and_waiting_work_no_longer_blocks_an_update(self):
        # The update restarts the worker, which carries this work on; nothing has to be paused first, and nothing stays parked afterwards.
        self.tasks([{'status':'running','title':'Research'},{'status':'queued'},{'status':'waiting_user'},{'status':'waiting_review','reviews':[{'status':'pending'}]},{'status':'running','reviews':[{'status':'completed'},{'status':'uncertain'}]}])
        self.idle()
    def test_an_action_being_sent_blocks_an_update(self):
        self.tasks([{'status':'running','title':'Reply to Acme','reviews':[{'status':'completed'},{'status':'dispatched'}]}])
        with self.assertRaises(RuntimeError) as raised:self.idle()
        self.assertEqual(str(raised.exception),'An approved action is being sent right now (Reply to Acme). Try the update again in a minute.')
    def test_an_action_being_sent_blocks_in_the_old_file_too(self):
        (self.root/'Worker/tasks.json').write_text(json.dumps({'version':1,'paused':False,'tasks':[{'status':'running','title':'Post the reply','reviews':[{'status':'dispatched'}]}]}))
        with self.assertRaisesRegex(RuntimeError,r'being sent right now \(Post the reply\)'):self.idle()
    def test_private_sign_in_and_active_chats_still_block(self):
        self.tasks([{'status':'running'}]);(self.root/'Worker/PrivateSignIn.json').write_text('{}')
        with self.assertRaisesRegex(RuntimeError,'private sign-in'):self.idle()
        (self.root/'Worker/PrivateSignIn.json').unlink();(self.root/'workspace.json').write_text(json.dumps({'runs':{'r':{'status':'answering'}}}))
        with self.assertRaisesRegex(RuntimeError,'active conversations'):self.idle()
if __name__=='__main__':unittest.main()
