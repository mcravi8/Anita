import importlib.util,json,tempfile,unittest,uuid,zipfile
from pathlib import Path
spec=importlib.util.spec_from_file_location('reset_agents',Path(__file__).parents[1]/'reset_agents.py');reset=importlib.util.module_from_spec(spec);spec.loader.exec_module(reset)
class ResetTests(unittest.TestCase):
    def test_removes_active_team_and_routines_preserving_connections_and_recoverable_data(self):
        with tempfile.TemporaryDirectory(suffix='.noindex') as tmp:
            root=Path(tmp);w=str(uuid.uuid4());a=str(uuid.uuid4());(root/'Worker').mkdir()
            state={'version':1,'conversationWorkspace':w,'agents':[{'id':a,'name':'Old Buddy'}],'files':[{'name':'keep.md'}],'groups':[{'members':[a]}],'messages':{a:[{'body':'Old chat'}]}}
            for name,value in {'workspace.json':state,'agent-models.json':{'version':1,'workspaces':{w:{a:{'provider':'claude'}}}},'Worker/tasks.json':{'version':1,'paused':True,'tasks':[{'workspace':w,'agentId':a}]},'Worker/routines.json':{'version':1,'routines':[{'workspace':w,'agentId':a}]}}.items():(root/name).write_text(json.dumps(value))
            (root/'ai-providers.json').write_text('unchanged-provider');(root/'connected-folders.json').write_text('unchanged-folders')
            count,archive=reset.reset(root,stop=lambda:None);saved=json.loads((root/'workspace.json').read_text())
            self.assertEqual(count,1);self.assertEqual(saved['agents'],[]);self.assertEqual(saved['messages'],{});self.assertEqual(saved['files'],state['files']);self.assertEqual(saved['onboarding']['status'],'pending');self.assertEqual(saved['conversationWorkspace'],w)
            self.assertEqual(json.loads((root/'Worker/tasks.json').read_text())['tasks'],[]);self.assertTrue(json.loads((root/'Worker/tasks.json').read_text())['paused']);self.assertEqual((root/'ai-providers.json').read_text(),'unchanged-provider');self.assertEqual((root/'connected-folders.json').read_text(),'unchanged-folders')
            with zipfile.ZipFile(archive) as z:self.assertEqual(json.loads(z.read('workspace.json'))['agents'][0]['name'],'Old Buddy')
if __name__=='__main__':unittest.main()
