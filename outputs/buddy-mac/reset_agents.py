"""Explicit, offline removal of the active team; preserve files and account access."""
from pathlib import Path
import argparse,datetime,fcntl,json,os,subprocess,tempfile,uuid,zipfile

BOOTSTRAP='Learn the job the user wants help with through the setup conversation before beginning work.'
def stop_worker():
    if subprocess.run(['pgrep','-x','Buddy'],stdout=subprocess.DEVNULL).returncode==0:
        raise RuntimeError('Quit Buddy before removing its saved agents.')
    subprocess.run(['launchctl','bootout',f'gui/{os.getuid()}/app.buddy.worker'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    if subprocess.run(['pgrep','-x','BuddyWorker'],stdout=subprocess.DEVNULL).returncode==0:
        raise RuntimeError('Buddy’s worker is still stopping. Retry when it has exited.')

def reset(support,stop=stop_worker):
    support=Path(support);stop()
    with (support/'agent-reset.lock').open('a') as lock:
        os.chmod(lock.name,0o600);fcntl.flock(lock,fcntl.LOCK_EX)
        names=['workspace.json','agent-models.json','agent-interviews.json','agent-proposals.json','conversation-providers.json','Worker/tasks.json','Worker/routines.json']
        raw={name:(support/name).read_bytes() for name in names if (support/name).exists()}
        saved={name:json.loads(data) for name,data in raw.items()};state=saved['workspace.json'];workspace=state['conversationWorkspace'];uuid.UUID(workspace)
        if state.get('version')!=1 or not isinstance(state.get('agents'),list):raise RuntimeError('Could not verify the saved workspace.')
        count=len(state['agents']);state.update(agents=[],groups=[],tasks=[],messages={},drafts={},attachments={},proposals=[],runs={},agentSetup={},messagingRevision=2,lastView={'kind':'chat','target':None})
        state['onboarding']={'version':1,'status':'pending','registrationId':str(uuid.uuid4()),'draft':{'name':'Buddy','role':'Getting started','description':BOOTSTRAP,'avatarShape':'star','avatarColor':'lilac','tools':{'web':True,'projectFiles':True,'desktop':True},'groupIds':[]}}
        if 'agent-models.json' in saved:saved['agent-models.json']['workspaces'].pop(workspace,None)
        if 'agent-interviews.json' in saved:saved['agent-interviews.json']['records']={k:r for k,r in saved['agent-interviews.json']['records'].items() if r['workspace']!=workspace}
        if 'agent-proposals.json' in saved:saved['agent-proposals.json']=[r for r in saved['agent-proposals.json'] if r['workspace']!=workspace]
        if 'conversation-providers.json' in saved:saved['conversation-providers.json']={k:v for k,v in saved['conversation-providers.json'].items() if not k.startswith(workspace+':')}
        for name,field in [('Worker/tasks.json','tasks'),('Worker/routines.json','routines')]:
            if name in saved:saved[name][field]=[r for r in saved[name][field] if r['workspace']!=workspace]
        directory=support/'AgentArchives.noindex';directory.mkdir(mode=0o700,exist_ok=True)
        archive=directory/('agents-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S')+'-'+uuid.uuid4().hex[:6]+'.zip')
        with zipfile.ZipFile(archive,'w',compression=zipfile.ZIP_DEFLATED) as z:
            for name,data in raw.items():z.writestr(name,data)
        archive.chmod(0o600)
        with zipfile.ZipFile(archive) as z:
            if z.testzip():raise RuntimeError('Could not verify the recovery archive. Nothing was removed.')
        with tempfile.TemporaryDirectory(prefix='agent-reset-',suffix='.noindex',dir=support) as temp:
            staged=[]
            for i,(name,value) in enumerate(saved.items()):
                path=Path(temp)/str(i);path.write_text(json.dumps(value,ensure_ascii=False));path.chmod(0o600);staged.append((path,support/name))
            for source,target in staged:os.replace(source,target)
        return count,archive

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--confirm-remove-all-agents',action='store_true',required=True)
    parser.parse_args();count,archive=reset(Path.home()/'Library/Application Support/Buddy');print(f'Removed {count} saved agents. Files, connections, browser profiles and Keychain were preserved. Recovery archive: {archive}')
