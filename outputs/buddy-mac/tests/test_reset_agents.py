import importlib.util,json,sqlite3,tempfile,unittest,uuid,zipfile
from pathlib import Path
spec=importlib.util.spec_from_file_location('reset_agents',Path(__file__).parents[1]/'reset_agents.py');reset=importlib.util.module_from_spec(spec);spec.loader.exec_module(reset)
class ResetTests(unittest.TestCase):
    def test_removes_active_team_and_routines_preserving_connections_and_recoverable_data(self):
        with tempfile.TemporaryDirectory(suffix='.noindex') as tmp:
            root=Path(tmp);w=str(uuid.uuid4());a=str(uuid.uuid4());(root/'Worker').mkdir()
            state={'version':1,'conversationWorkspace':w,'agents':[{'id':a,'name':'Old Buddy'}],'files':[{'name':'keep.md'}],'groups':[{'members':[a]}],'messages':{a:[{'body':'Old chat'}]}}
            for name,value in {'workspace.json':state,'agent-models.json':{'version':1,'workspaces':{w:{a:{'provider':'claude'}}}},'Worker/tasks.json':{'version':1,'paused':True,'tasks':[{'workspace':w,'agentId':a}]},'Worker/routines.json':{'version':1,'routines':[{'workspace':w,'agentId':a}]}}.items():(root/name).write_text(json.dumps(value))
            (root/'ai-providers.json').write_text('unchanged-provider');(root/'connected-folders.json').write_text('unchanged-folders')
            other=str(uuid.uuid4());(root/'agent-memory.json').write_text(json.dumps({'version':1,'records':{w+':'+a:{'workspace':w},other+':'+a:{'workspace':other}}}))
            (root/'team-monitor.json').write_text(json.dumps({'version':1,'settings':{w:{},other:{}},'checks':[{'workspace':w},{'workspace':other}],'updates':[{'workspace':w}],'observed':{w+':'+a:{'workspace':w}},'daily':{'2026-10-17':{'reserved':0.1}}}))
            (root/'team-plans.json').write_text(json.dumps([{'workspace':w,'id':'old-team'},{'workspace':other,'id':'keep-team'}]))
            count,archive=reset.reset(root,stop=lambda:None);saved=json.loads((root/'workspace.json').read_text())
            self.assertEqual(count,1);self.assertEqual(saved['agents'],[]);self.assertEqual(saved['messages'],{});self.assertEqual(saved['files'],state['files']);self.assertEqual(saved['onboarding']['status'],'pending');self.assertEqual(saved['conversationWorkspace'],w)
            self.assertEqual(json.loads((root/'Worker/tasks.json').read_text())['tasks'],[]);self.assertTrue(json.loads((root/'Worker/tasks.json').read_text())['paused']);self.assertEqual((root/'ai-providers.json').read_text(),'unchanged-provider');self.assertEqual((root/'connected-folders.json').read_text(),'unchanged-folders')
            with zipfile.ZipFile(archive) as z:self.assertEqual(json.loads(z.read('workspace.json'))['agents'][0]['name'],'Old Buddy')
            self.assertEqual(list(json.loads((root/'agent-memory.json').read_text())['records']),[other+':'+a]);journal=json.loads((root/'team-monitor.json').read_text());self.assertEqual(journal['checks'],[{'workspace':other}]);self.assertEqual(journal['updates'],[]);self.assertEqual(journal['observed'],{});self.assertEqual(journal['daily']['2026-10-17']['reserved'],0.1)
            self.assertEqual(json.loads((root/'team-plans.json').read_text()),[{'workspace':other,'id':'keep-team'}])
    def test_removes_tasks_and_routines_from_the_worker_database_and_keeps_them_in_the_recovery_archive(self):
        with tempfile.TemporaryDirectory(suffix='.noindex') as tmp:
            root=Path(tmp);w=str(uuid.uuid4());other=str(uuid.uuid4());a=str(uuid.uuid4());(root/'Worker').mkdir()
            (root/'workspace.json').write_text(json.dumps({'version':1,'conversationWorkspace':w,'agents':[{'id':a,'name':'Old Buddy'}],'groups':[],'messages':{}}))
            connection=sqlite3.connect(root/'Worker/operations.sqlite')
            connection.executescript("CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);CREATE TABLE tasks(seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT, workspace TEXT, archived INTEGER DEFAULT 0, body TEXT);CREATE TABLE routines(seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT, workspace TEXT, body TEXT)")
            connection.execute("INSERT INTO meta VALUES('migration','{}'),('paused','1')")
            for workspace,archived,title in [(w,0,'mine'),(w,1,'mine archived'),(other,0,'theirs')]:connection.execute('INSERT INTO tasks(id,workspace,archived,body) VALUES(?,?,?,?)',(str(uuid.uuid4()),workspace,archived,json.dumps({'title':title,'workspace':workspace})))
            for workspace,title in [(w,'mine'),(other,'theirs')]:connection.execute('INSERT INTO routines(id,workspace,body) VALUES(?,?,?)',(str(uuid.uuid4()),workspace,json.dumps({'title':title})))
            connection.commit();connection.close()
            count,archive=reset.reset(root,stop=lambda:None)
            connection=sqlite3.connect(root/'Worker/operations.sqlite')
            self.assertEqual([json.loads(r[0])['title'] for r in connection.execute('SELECT body FROM tasks')],['theirs'])
            self.assertEqual([json.loads(r[0])['title'] for r in connection.execute('SELECT body FROM routines')],['theirs'])
            self.assertEqual(connection.execute("SELECT value FROM meta WHERE key='paused'").fetchone()[0],'1');connection.close()
            with zipfile.ZipFile(archive) as z:
                saved=json.loads(z.read('Worker/operations-export.json'))
                self.assertEqual(sorted(t['task']['title'] for t in saved['tasks']),['mine','mine archived','theirs']);self.assertTrue(saved['paused']);self.assertEqual(len(saved['routines']),2)

    def test_removes_what_belonged_to_the_removed_agents_but_keeps_the_money_record(self):
        with tempfile.TemporaryDirectory(suffix='.noindex') as tmp:
            root=Path(tmp);w=str(uuid.uuid4());other=str(uuid.uuid4());a=str(uuid.uuid4());(root/'Worker').mkdir()
            (root/'workspace.json').write_text(json.dumps({'version':1,'conversationWorkspace':w,'agents':[{'id':a,'name':'Old Buddy'}],'groups':[],'messages':{}}))
            connection=sqlite3.connect(root/'Worker/operations.sqlite')
            connection.executescript("""CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);CREATE TABLE tasks(seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT, workspace TEXT, archived INTEGER DEFAULT 0, body TEXT);CREATE TABLE routines(seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT, workspace TEXT, body TEXT);
              CREATE TABLE decisions(id TEXT PRIMARY KEY, workspace TEXT);CREATE TABLE notification_state(workspace TEXT, id TEXT);CREATE TABLE rules(id TEXT PRIMARY KEY, workspace TEXT);CREATE TABLE rule_approvals(rule_id TEXT, review_id TEXT);CREATE TABLE setting_changes(id TEXT PRIMARY KEY, workspace TEXT);
              CREATE TABLE limits(workspace TEXT, scope TEXT, scope_id TEXT);CREATE TABLE budget_entries(workspace TEXT, amount_usd TEXT)""")
            connection.execute("INSERT INTO meta VALUES('migration','{}')")
            for workspace in (w,other):
                rule=str(uuid.uuid4())
                connection.execute('INSERT INTO rules VALUES(?,?)',(rule,workspace));connection.execute('INSERT INTO rule_approvals VALUES(?,?)',(rule,'review'))
                connection.execute('INSERT INTO decisions VALUES(?,?)',(str(uuid.uuid4()),workspace));connection.execute('INSERT INTO notification_state VALUES(?,?)',(workspace,'x'));connection.execute('INSERT INTO setting_changes VALUES(?,?)',(str(uuid.uuid4()),workspace))
                connection.execute("INSERT INTO limits VALUES(?, 'agent', ?)",(workspace,a));connection.execute("INSERT INTO limits VALUES(?, 'workspace', '')",(workspace,));connection.execute("INSERT INTO budget_entries VALUES(?, '1.5')",(workspace,))
            connection.commit();connection.close()
            reset.reset(root,stop=lambda:None)
            connection=sqlite3.connect(root/'Worker/operations.sqlite')
            count=lambda table,where='':connection.execute(f'SELECT COUNT(*) FROM {table} '+where).fetchone()[0]
            for table in ('rules','decisions','notification_state','setting_changes'):self.assertEqual(count(table),1,table+' keeps only the other workspace')
            self.assertEqual(count('rule_approvals'),1,'approvals counted for removed rules go with them')
            self.assertEqual(connection.execute("SELECT workspace,scope FROM limits ORDER BY workspace,scope").fetchall().__len__(),3,'agent limits go; workspace limits stay')
            self.assertEqual(count('limits',f"WHERE workspace='{w}' AND scope='agent'"),0)
            self.assertEqual(count('budget_entries'),2,'money already spent is a record, not a setting');connection.close()
if __name__=='__main__':unittest.main()
