from pathlib import Path
import shutil,subprocess,tempfile,sys
source=Path(__file__).resolve().parent
worker=source.parent/'buddy-worker'
import os
os.environ['CLANG_MODULE_CACHE_PATH'] = str(source.parent.parent / 'work/background-worker/test-module-cache')
# No test may start the real Codex, which is signed in to the person's ChatGPT account (ConversationService refuses under this flag).
os.environ['BUDDY_TEST_NO_REAL_CODEX'] = '1'
# Nor may any test reach a real outside service: a connected service is only ever a stand-in on this Mac's loopback address (BuddyConnectedServices).
os.environ['BUDDY_TEST_LOOPBACK_ONLY'] = '1'
snapshot=tempfile.TemporaryDirectory(prefix='buddy-test-source-')
shutil.copytree(source,Path(snapshot.name)/'Source',ignore=shutil.ignore_patterns('__pycache__'))
source=Path(snapshot.name)/'Source'
with tempfile.TemporaryDirectory(prefix='buddy-agent-setup-',suffix='.noindex') as temp:
 binary=Path(temp)/'buddy-agent-setup-tests'
 names=['BuddyAgentMemory.swift','BuddyAgentSetup.swift','BuddyAISettings.swift','BuddyWorkerProcess.swift','BuddyWorkerCore.swift','BuddyOperationsDB.swift','ConversationService.swift','BuddyInboxReview.swift','BuddyMailVerification.swift','BuddyComputer.swift','BuddyTransport.swift','BuddyToolInput.swift','BuddyConnections.swift','BuddyTeam.swift','BuddyProjectFiles.swift','BuddyDocuments.swift','BuddyAgentProposals.swift','tests/AgentSetup.swift']
 subprocess.run(['xcrun','swiftc',*[str(source/name) for name in names],'-o',str(binary)],check=True)
 subprocess.run([str(binary),str(source/'tests/agent-setup-claude.py'),shutil.which('python3')],check=True)
with tempfile.TemporaryDirectory(prefix='buddy-team-monitor-',suffix='.noindex') as temp:
 binary=Path(temp)/'buddy-team-monitor-tests'
 names=['BuddyTeamMonitor.swift','BuddyTeamMonitorStore.swift','BuddyAgentMemory.swift','BuddyWorkerClient.swift','BuddyAISettings.swift','BuddyWorkerProcess.swift','BuddyWorkerCore.swift','BuddyOperationsDB.swift','ConversationService.swift','BuddyInboxReview.swift','BuddyMailVerification.swift','BuddyComputer.swift','BuddyTransport.swift','BuddyToolInput.swift','BuddyConnections.swift','BuddyTeam.swift','BuddyProjectFiles.swift','BuddyDocuments.swift','BuddyAgentProposals.swift','tests/TeamMonitor.swift']
 subprocess.run(['xcrun','swiftc',*[str(source/name) for name in names],'-o',str(binary)],check=True)
 subprocess.run([str(binary),str(source/'tests/team-monitor-claude.py'),shutil.which('python3'),str(source/'tests/team-monitor-gpt.py')],check=True)
with tempfile.TemporaryDirectory(prefix='buddy-transport-test-') as temp:
 binary=Path(temp)/'buddy-transport-tests'
 subprocess.run(['xcrun','swiftc',str(source/'BuddyTransport.swift'),str(source/'BuddyConnections.swift'),str(source/'tests/main.swift'),'-o',str(binary)],check=True)
 subprocess.run([str(binary),shutil.which('python3')],check=True)
with tempfile.TemporaryDirectory(prefix='buddy-teamwork-test-') as temp:
 binary=Path(temp)/'buddy-teamwork-tests'
 subprocess.run(['xcrun','swiftc',str(source/'BuddyTeam.swift'),str(source/'BuddyAgentProposals.swift'),str(source/'BuddyProjectFiles.swift'),str(source/'BuddyDocuments.swift'),str(source/'BuddyTeamService.swift'),str(source/'tests/Teamwork.swift'),'-o',str(binary)],check=True)
 subprocess.run([str(binary)],check=True)

with tempfile.TemporaryDirectory(prefix='buddy-files-test-') as temp:
 binary=Path(temp)/'buddy-files-tests'
 subprocess.run(['xcrun','swiftc',str(source/'BuddyProjectFiles.swift'),str(source/'BuddyDocuments.swift'),str(source/'tests/Files.swift'),'-o',str(binary)],check=True)
 subprocess.run([str(binary)],check=True)

with tempfile.TemporaryDirectory(prefix='buddy-markdown-preview-',suffix='.noindex') as temp:
 binary=Path(temp)/'buddy-markdown-preview-tests'
 shutil.copytree(source/'MarkdownViewer',Path(temp)/'MarkdownViewer')
 names=['BuddyMarkdownRenderer.swift','BuddyMarkdownPreview.swift','BuddyDocuments.swift','BuddyProjectFiles.swift','tests/MarkdownPreview.swift']
 subprocess.run(['xcrun','swiftc','-framework','JavaScriptCore',*[str(source/name) for name in names],'-o',str(binary)],check=True)
 subprocess.run([str(binary)],check=True)

with tempfile.TemporaryDirectory(prefix='buddy-proposals-test-') as temp:
 binary=Path(temp)/'buddy-proposal-tests'
 subprocess.run(['xcrun','swiftc',str(source/'BuddyAgentProposals.swift'),str(source/'tests/Proposals.swift'),'-o',str(binary)],check=True)
 subprocess.run([str(binary)],check=True)
with tempfile.TemporaryDirectory(prefix='buddy-team-builder-',suffix='.noindex') as temp:
 binary=Path(temp)/'buddy-team-builder-tests'
 subprocess.run(['xcrun','swiftc',str(source/'BuddyAgentProposals.swift'),str(source/'tests/TeamBuilder.swift'),'-o',str(binary)],check=True)
 subprocess.run([str(binary)],check=True)

with tempfile.TemporaryDirectory(prefix='buddy-actions-test-') as temp:
 binary=Path(temp)/'buddy-action-tests'
 subprocess.run(['xcrun','swiftc',str(source/'ConversationService.swift'),str(source/'BuddyInboxReview.swift'),str(source/'BuddyOperationsDB.swift'),str(source/'BuddyMailVerification.swift'),str(source/'BuddyComputer.swift'),str(source/'BuddyTransport.swift'),str(source/'BuddyConnections.swift'),str(source/'BuddyToolInput.swift'),str(source/'BuddyTeam.swift'),str(source/'BuddyProjectFiles.swift'),str(source/'BuddyDocuments.swift'),str(source/'BuddyAgentProposals.swift'),str(source/'tests/Actions.swift'),'-o',str(binary)],check=True)
 subprocess.run([str(binary),str(source/'tests/action-server.py')],check=True)

with tempfile.TemporaryDirectory(prefix='buddy-computer-test-') as temp:
 binary=Path(temp)/'buddy-computer-tests'
 subprocess.run(['xcrun','swiftc',str(source/'BuddyComputer.swift'),str(source/'tests/Computer.swift'),'-o',str(binary)],check=True)
 subprocess.run([str(binary)],check=True)

with tempfile.TemporaryDirectory(prefix='buddy-computer-rpc-test-') as temp:
 binary=Path(temp)/'buddy-computer-rpc-tests'
 names=['ConversationService.swift','BuddyInboxReview.swift','BuddyOperationsDB.swift','BuddyMailVerification.swift','BuddyComputer.swift','BuddyTransport.swift','BuddyToolInput.swift','BuddyConnections.swift','BuddyTeam.swift','BuddyProjectFiles.swift','BuddyDocuments.swift','BuddyAgentProposals.swift','tests/ComputerIntegration.swift']
 subprocess.run(['xcrun','swiftc',*[str(source/name) for name in names],'-o',str(binary)],check=True)
 subprocess.run([str(binary),str(source/'tests/computer-server.py')],check=True)

with tempfile.TemporaryDirectory(prefix='buddy-documents-test-') as temp:
 binary=Path(temp)/'buddy-document-tests'
 subprocess.run(['xcrun','swiftc',str(source/'BuddyDocuments.swift'),str(source/'BuddyProjectFiles.swift'),str(source/'tests/Documents.swift'),'-o',str(binary)],check=True)
 subprocess.run([str(binary),str(Path(temp)/'fixtures')],check=True)

with tempfile.TemporaryDirectory(prefix='buddy-worker-test-') as temp:
 binary=Path(temp)/'buddy-worker-tests'
 names=['BuddyWorkerCore.swift','BuddyOperationsDB.swift','BuddyConnections.swift','BuddyProjectFiles.swift','BuddyDocuments.swift','tests/Worker.swift']
 subprocess.run(['xcrun','swiftc',*[str(source/name) for name in names],'-o',str(binary)],check=True)
 subprocess.run([str(binary)],check=True)

with tempfile.TemporaryDirectory(prefix='buddy-worker-integration-') as temp:
 binary=Path(temp)/'buddy-worker-integration'
 names=['BuddyWorkerCore.swift','BuddyOperationsDB.swift','BuddyWorkerProcess.swift','BuddyWorkerHost.swift','BuddyCodexCoding.swift','BuddyPlan.swift','BuddySupervisor.swift','BuddyMigrations.swift','BuddyWorkerClient.swift','BuddyAgentMemory.swift','BuddyTeamMonitorStore.swift','BuddyTeamMonitor.swift','BuddyAISettings.swift','ConversationService.swift','BuddyInboxReview.swift','BuddyMailVerification.swift','BuddyComputer.swift','BuddyTransport.swift','BuddyToolInput.swift','BuddyConnections.swift','BuddyTeam.swift','BuddyProjectFiles.swift','BuddyDocuments.swift','BuddyAgentProposals.swift','BuddyCredentials.swift','BuddyChromeAccounts.swift','BuddyCommandReview.swift','BuddyConnectedServices.swift','BuddyLeases.swift','tests/WorkerIntegration.swift']
 subprocess.run(['xcrun','swiftc',*[str(source/name) for name in names],'-o',str(binary)],check=True)
 subprocess.run([str(binary),str(source/'tests/worker-server.py'),str(source/'tests/coding-claude.py'),shutil.which('python3'),str(worker/'coding-shell.mjs'),shutil.which('node'),str(worker/'test/native-worker-session.mjs'),str(source/'tests/signin-browser.py'),str(source/'tests/process-timeout.py')],check=True)

with tempfile.TemporaryDirectory(prefix='buddy-provider-test-') as temp:
 binary=Path(temp)/'buddy-provider-tests'
 names=['BuddyWorkerClient.swift','BuddyAISettings.swift','BuddyAIRouter.swift','BuddyClaudeConversations.swift','BuddyWorkerProcess.swift','BuddyWorkerCore.swift','BuddyOperationsDB.swift','ConversationService.swift','BuddyInboxReview.swift','BuddyMailVerification.swift','BuddyComputer.swift','BuddyTransport.swift','BuddyToolInput.swift','BuddyConnections.swift','BuddyTeam.swift','BuddyProjectFiles.swift','BuddyDocuments.swift','BuddyAgentProposals.swift','tests/Providers.swift']
 subprocess.run(['xcrun','swiftc',*[str(source/name) for name in names],'-o',str(binary)],check=True)
 subprocess.run([str(binary),str(source/'tests/provider-server.py'),str(source/'tests/provider-claude.py'),shutil.which('python3')],check=True)
with tempfile.TemporaryDirectory(prefix='buddy-team-routing-',suffix='.noindex') as temp:
 binary=Path(temp)/'buddy-team-routing-tests'
 names=['BuddyAISettings.swift','BuddyClaudeConversations.swift','BuddyWorkerProcess.swift','BuddyWorkerCore.swift','BuddyOperationsDB.swift','ConversationService.swift','BuddyInboxReview.swift','BuddyMailVerification.swift','BuddyComputer.swift','BuddyTransport.swift','BuddyToolInput.swift','BuddyConnections.swift','BuddyTeam.swift','BuddyProjectFiles.swift','BuddyDocuments.swift','BuddyAgentProposals.swift','tests/TeamBuilderRouting.swift']
 subprocess.run(['xcrun','swiftc',*[str(source/name) for name in names],'-o',str(binary)],check=True)
 subprocess.run([str(binary),str(source/'tests/provider-server.py'),str(source/'tests/provider-claude.py'),shutil.which('python3')],check=True)

with tempfile.TemporaryDirectory(prefix='buddy-model-test-') as temp:
 binary=Path(temp)/'buddy-model-tests'
 names=['BuddyWorkerClient.swift','BuddyAISettings.swift','BuddyAIRouter.swift','BuddyClaudeConversations.swift','BuddyWorkerProcess.swift','BuddyWorkerCore.swift','BuddyOperationsDB.swift','ConversationService.swift','BuddyInboxReview.swift','BuddyMailVerification.swift','BuddyComputer.swift','BuddyTransport.swift','BuddyToolInput.swift','BuddyConnections.swift','BuddyTeam.swift','BuddyProjectFiles.swift','BuddyDocuments.swift','BuddyAgentProposals.swift','tests/Models.swift']
 subprocess.run(['xcrun','swiftc',*[str(source/name) for name in names],'-o',str(binary)],check=True)
 subprocess.run([str(binary),str(source/'tests/model-server.py'),str(source/'tests/model-claude.py'),shutil.which('python3')],check=True)

with tempfile.TemporaryDirectory(prefix='buddy-mail-test-') as temp:
 binary=Path(temp)/'buddy-mail-tests'
 names=['ConversationService.swift','BuddyInboxReview.swift','BuddyOperationsDB.swift','BuddyMailVerification.swift','BuddyComputer.swift','BuddyTransport.swift','BuddyToolInput.swift','BuddyConnections.swift','BuddyTeam.swift','BuddyProjectFiles.swift','BuddyDocuments.swift','BuddyAgentProposals.swift','tests/MailVerification.swift']
 subprocess.run(['xcrun','swiftc',*[str(source/name) for name in names],'-o',str(binary)],check=True)
 subprocess.run([str(binary),str(source/'tests/mail-server.py')],check=True)

with tempfile.TemporaryDirectory(prefix='buddy-signin-integration-') as temp:
 binary=Path(temp)/'buddy-signin-integration'
 names=['BuddyWorkerCore.swift','BuddyOperationsDB.swift','BuddyWorkerProcess.swift','BuddyWorkerHost.swift','BuddyCodexCoding.swift','BuddyPlan.swift','BuddySupervisor.swift','BuddyMigrations.swift','BuddyWorkerClient.swift','BuddyAgentMemory.swift','BuddyTeamMonitorStore.swift','BuddyTeamMonitor.swift','BuddyAISettings.swift','ConversationService.swift','BuddyInboxReview.swift','BuddyMailVerification.swift','BuddyComputer.swift','BuddyTransport.swift','BuddyToolInput.swift','BuddyConnections.swift','BuddyTeam.swift','BuddyProjectFiles.swift','BuddyDocuments.swift','BuddyAgentProposals.swift','BuddyCredentials.swift','BuddyChromeAccounts.swift','BuddyCommandReview.swift','BuddyConnectedServices.swift','BuddyLeases.swift','tests/SignInIntegration.swift']
 subprocess.run(['xcrun','swiftc',*[str(source/name) for name in names],'-o',str(binary)],check=True)
 subprocess.run([str(binary),str(source/'tests/signin-server.py'),str(source/'tests/signin-browser.py'),shutil.which('python3')],check=True)

# Service sign-ins for commands (WRDS) and the supervisor answering routine coding command reviews, through the real worker, Buddy's command
# runner and stand-ins for Claude, Codex and the supervisor. Sign-ins are a fake account in memory; the Keychain check uses a test-only service.
with tempfile.TemporaryDirectory(prefix='buddy-signin-command-',suffix='.noindex') as temp:
 binary=Path(temp)/'buddy-signin-command'
 names=['BuddyWorkerCore.swift','BuddyOperationsDB.swift','BuddyWorkerProcess.swift','BuddyWorkerHost.swift','BuddyCodexCoding.swift','BuddyPlan.swift','BuddySupervisor.swift','BuddyMigrations.swift','BuddyWorkerClient.swift','BuddyAgentMemory.swift','BuddyTeamMonitorStore.swift','BuddyTeamMonitor.swift','BuddyAISettings.swift','ConversationService.swift','BuddyInboxReview.swift','BuddyMailVerification.swift','BuddyComputer.swift','BuddyTransport.swift','BuddyToolInput.swift','BuddyConnections.swift','BuddyTeam.swift','BuddyProjectFiles.swift','BuddyDocuments.swift','BuddyAgentProposals.swift','BuddyCredentials.swift','BuddyChromeAccounts.swift','BuddyCommandReview.swift','BuddyConnectedServices.swift','BuddyLeases.swift','tests/SignInCommand.swift']
 subprocess.run(['xcrun','swiftc',*[str(source/name) for name in names],'-o',str(binary)],check=True)
 subprocess.run([str(binary),str(source/'tests/signin-command-claude.py'),shutil.which('python3'),str(worker/'coding-shell.mjs'),shutil.which('node'),str(source/'tests/codex-coding-server.py')],check=True)

# Several background tasks at once, through the real worker, Buddy's command runner and the Claude coding stand-in, which holds an attempt
# open until the test releases it.
with tempfile.TemporaryDirectory(prefix='buddy-parallel-tasks-',suffix='.noindex') as temp:
 binary=Path(temp)/'buddy-parallel-tasks'
 names=['BuddyWorkerCore.swift','BuddyOperationsDB.swift','BuddyWorkerProcess.swift','BuddyWorkerHost.swift','BuddyCodexCoding.swift','BuddyPlan.swift','BuddySupervisor.swift','BuddyMigrations.swift','BuddyWorkerClient.swift','BuddyAgentMemory.swift','BuddyTeamMonitorStore.swift','BuddyTeamMonitor.swift','BuddyAISettings.swift','ConversationService.swift','BuddyInboxReview.swift','BuddyMailVerification.swift','BuddyComputer.swift','BuddyTransport.swift','BuddyToolInput.swift','BuddyConnections.swift','BuddyTeam.swift','BuddyProjectFiles.swift','BuddyDocuments.swift','BuddyAgentProposals.swift','BuddyCredentials.swift','BuddyChromeAccounts.swift','BuddyCommandReview.swift','BuddyConnectedServices.swift','BuddyLeases.swift','tests/ParallelTasks.swift']
 subprocess.run(['xcrun','swiftc',*[str(source/name) for name in names],'-o',str(binary)],check=True)
 subprocess.run([str(binary),str(source/'tests/coding-claude.py'),shutil.which('python3'),str(worker/'coding-shell.mjs'),shutil.which('node')],check=True)

with tempfile.TemporaryDirectory(prefix='buddy-inbox-review-') as temp:
 binary=Path(temp)/'inbox-tests'
 subprocess.run(['xcrun','swiftc',str(source/'BuddyInboxReview.swift'),str(source/'BuddyOperationsDB.swift'),str(source/'tests/InboxReview.swift'),'-o',str(binary)],check=True)
 subprocess.run([str(binary)],check=True)

with tempfile.TemporaryDirectory(prefix='buddy-incremental-inbox-',suffix='.noindex') as temp:
 binary=Path(temp)/'buddy-incremental-inbox-tests'
 subprocess.run(['xcrun','swiftc',str(source/'BuddyInboxReview.swift'),str(source/'BuddyOperationsDB.swift'),str(source/'tests/IncrementalInbox.swift'),'-o',str(binary)],check=True)
 subprocess.run([str(binary)],check=True)

with tempfile.TemporaryDirectory(prefix='buddy-prepared-inbox-') as temp:
 binary=Path(temp)/'prepared-tests'
 subprocess.run(['xcrun','swiftc',str(source/'BuddyInboxReview.swift'),str(source/'BuddyOperationsDB.swift'),str(source/'tests/PreparedInbox.swift'),'-o',str(binary)],check=True)
 subprocess.run([str(binary)],check=True)

with tempfile.TemporaryDirectory(prefix='buddy-process-crash-') as temp:
 binary=Path(temp)/'process-crash-tests'
 subprocess.run(['xcrun','swiftc',str(source/'BuddyWorkerCore.swift'),str(source/'BuddyOperationsDB.swift'),str(source/'BuddyWorkerProcess.swift'),str(source/'BuddyTransport.swift'),str(source/'tests/ProcessCrash.swift'),'-o',str(binary)],check=True)
 subprocess.run([str(binary)],check=True)

with tempfile.TemporaryDirectory(prefix='buddy-task-archive-') as temp:
 binary=Path(temp)/'task-archive-tests'
 subprocess.run(['xcrun','swiftc',str(source/'BuddyWorkerCore.swift'),str(source/'BuddyOperationsDB.swift'),str(source/'tests/TaskArchive.swift'),'-o',str(binary)],check=True)
 subprocess.run([str(binary)],check=True)

with tempfile.TemporaryDirectory(prefix='buddy-decisions-') as temp:
 binary=Path(temp)/'decisions-tests'
 subprocess.run(['xcrun','swiftc',str(source/'BuddyWorkerCore.swift'),str(source/'BuddyOperationsDB.swift'),str(source/'tests/Decisions.swift'),'-o',str(binary)],check=True)
 subprocess.run([str(binary)],check=True)

with tempfile.TemporaryDirectory(prefix='buddy-budget-') as temp:
 binary=Path(temp)/'budget-tests'
 subprocess.run(['xcrun','swiftc',str(source/'BuddyWorkerCore.swift'),str(source/'BuddyOperationsDB.swift'),str(source/'tests/Budget.swift'),'-o',str(binary)],check=True)
 subprocess.run([str(binary)],check=True)

with tempfile.TemporaryDirectory(prefix='buddy-action-records-') as temp:
 binary=Path(temp)/'action-records-tests'
 subprocess.run(['xcrun','swiftc',str(source/'BuddyWorkerCore.swift'),str(source/'BuddyOperationsDB.swift'),str(source/'tests/ActionRecords.swift'),'-o',str(binary)],check=True)
 subprocess.run([str(binary)],check=True)

with tempfile.TemporaryDirectory(prefix='buddy-settings-rules-') as temp:
 binary=Path(temp)/'settings-rules-tests'
 subprocess.run(['xcrun','swiftc',str(source/'BuddyWorkerCore.swift'),str(source/'BuddyOperationsDB.swift'),str(source/'BuddyAgentProposals.swift'),str(source/'tests/SettingsRules.swift'),'-o',str(binary)],check=True)
 subprocess.run([str(binary)],check=True)

with tempfile.TemporaryDirectory(prefix='buddy-operations-db-') as temp:
 binary=Path(temp)/'operations-db-tests'
 subprocess.run(['xcrun','swiftc',str(source/'BuddyWorkerCore.swift'),str(source/'BuddyOperationsDB.swift'),str(source/'tests/OperationsDB.swift'),'-o',str(binary)],check=True)
 subprocess.run([str(binary)],check=True)

with tempfile.TemporaryDirectory(prefix='buddy-record-limits-') as temp:
 binary=Path(temp)/'record-limit-tests'
 subprocess.run(['xcrun','swiftc',str(source/'BuddyTeam.swift'),str(source/'BuddyAgentProposals.swift'),str(source/'BuddyProjectFiles.swift'),str(source/'BuddyDocuments.swift'),str(source/'tests/RecordLimits.swift'),'-o',str(binary)],check=True)
 subprocess.run([str(binary)],check=True)

with tempfile.TemporaryDirectory(prefix='buddy-routines-') as temp:
 binary=Path(temp)/'routine-tests'
 subprocess.run(['xcrun','swiftc',str(source/'BuddyWorkerCore.swift'),str(source/'BuddyOperationsDB.swift'),str(source/'tests/Routines.swift'),'-o',str(binary)],check=True)
 subprocess.run([str(binary)],check=True)

with tempfile.TemporaryDirectory(prefix='buddy-inbox-rpc-') as temp:
 binary=Path(temp)/'inbox-rpc-tests'
 names=['ConversationService.swift','BuddyInboxReview.swift','BuddyOperationsDB.swift','BuddyMailVerification.swift','BuddyComputer.swift','BuddyTransport.swift','BuddyToolInput.swift','BuddyConnections.swift','BuddyTeam.swift','BuddyProjectFiles.swift','BuddyDocuments.swift','BuddyAgentProposals.swift','tests/InboxIntegration.swift']
 subprocess.run(['xcrun','swiftc',*[str(source/name) for name in names],'-o',str(binary)],check=True)
 subprocess.run([str(binary),str(source/'tests/inbox-server.py')],check=True)

with tempfile.TemporaryDirectory(prefix='buddy-direct-services-') as temp:
 binary=Path(temp)/'direct-tests'
 names=['ConversationService.swift','BuddyInboxReview.swift','BuddyOperationsDB.swift','BuddyMailVerification.swift','BuddyComputer.swift','BuddyTransport.swift','BuddyConnections.swift','BuddyToolInput.swift','BuddyTeam.swift','BuddyProjectFiles.swift','BuddyDocuments.swift','BuddyAgentProposals.swift','tests/DirectServices.swift']
 subprocess.run(['xcrun','swiftc',*[str(source/name) for name in names],'-o',str(binary)],check=True)
 subprocess.run([str(binary),str(source/'tests/direct-server.py')],check=True)

# A Swift test whose first line is `// run-tests: <sources relative to this folder> [-- <args>]` is found and run here. An argument
# `src:<path>` is a file in this folder, `which:<tool>` a program on PATH, anything else is passed as written.
import re
for test in sorted((source/'tests').glob('*.swift')):
 m=re.match(r'//\s*run-tests:\s*(.*)$',test.read_text().split('\n',1)[0])
 if not m: continue
 part=m.group(1).split(' -- ',1); names=part[0].split(); extra=part[1].split() if len(part)>1 else []
 # The worker host's coding sessions on ChatGPT, its saved sign-ins and its command review classifier live beside it, so every header that
 # compiles the host gets those files too.
 for companion in ['BuddyCodexCoding.swift','BuddyCredentials.swift','BuddyChromeAccounts.swift','BuddyCommandReview.swift','BuddyConnectedServices.swift','BuddyLeases.swift']:
  if 'BuddyWorkerHost.swift' in names and companion not in names: names.append(companion)
 args=[str(source/a[4:]) if a.startswith('src:') else (shutil.which(a[6:]) if a.startswith('which:') else a) for a in extra]
 with tempfile.TemporaryDirectory(prefix='buddy-'+test.stem.lower()+'-',suffix='.noindex') as temp:
  binary=Path(temp)/test.stem
  subprocess.run(['xcrun','swiftc',*[str(source/n) for n in names],str(test),'-o',str(binary)],check=True)
  subprocess.run([str(binary),*args],check=True)

subprocess.run([sys.executable,str(source/'tests/test_signing.py')],check=True)

subprocess.run([sys.executable,'-m','unittest','discover','-s',str(source/'tests'),'-p','test_reset_agents.py'],check=True)
subprocess.run([sys.executable,'-m','unittest','discover','-s',str(source/'tests'),'-p','test_saved_queue.py'],check=True)
subprocess.run([sys.executable,'-m','unittest','discover','-s',str(source/'tests'),'-p','test_worker_priority.py'],check=True)
