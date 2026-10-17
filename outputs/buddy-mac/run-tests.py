from pathlib import Path
import shutil,subprocess,tempfile
source=Path(__file__).resolve().parent
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

with tempfile.TemporaryDirectory(prefix='buddy-proposals-test-') as temp:
 binary=Path(temp)/'buddy-proposal-tests'
 subprocess.run(['xcrun','swiftc',str(source/'BuddyAgentProposals.swift'),str(source/'tests/Proposals.swift'),'-o',str(binary)],check=True)
 subprocess.run([str(binary)],check=True)

with tempfile.TemporaryDirectory(prefix='buddy-actions-test-') as temp:
 binary=Path(temp)/'buddy-action-tests'
 subprocess.run(['xcrun','swiftc',str(source/'ConversationService.swift'),str(source/'BuddyComputer.swift'),str(source/'BuddyTransport.swift'),str(source/'BuddyConnections.swift'),str(source/'BuddyToolInput.swift'),str(source/'BuddyTeam.swift'),str(source/'BuddyProjectFiles.swift'),str(source/'BuddyDocuments.swift'),str(source/'BuddyAgentProposals.swift'),str(source/'tests/Actions.swift'),'-o',str(binary)],check=True)
 subprocess.run([str(binary),str(source/'tests/action-server.py')],check=True)

with tempfile.TemporaryDirectory(prefix='buddy-computer-test-') as temp:
 binary=Path(temp)/'buddy-computer-tests'
 subprocess.run(['xcrun','swiftc',str(source/'BuddyComputer.swift'),str(source/'tests/Computer.swift'),'-o',str(binary)],check=True)
 subprocess.run([str(binary)],check=True)

with tempfile.TemporaryDirectory(prefix='buddy-computer-rpc-test-') as temp:
 binary=Path(temp)/'buddy-computer-rpc-tests'
 names=['ConversationService.swift','BuddyComputer.swift','BuddyTransport.swift','BuddyToolInput.swift','BuddyConnections.swift','BuddyTeam.swift','BuddyProjectFiles.swift','BuddyDocuments.swift','BuddyAgentProposals.swift','tests/ComputerIntegration.swift']
 subprocess.run(['xcrun','swiftc',*[str(source/name) for name in names],'-o',str(binary)],check=True)
 subprocess.run([str(binary),str(source/'tests/computer-server.py')],check=True)

with tempfile.TemporaryDirectory(prefix='buddy-documents-test-') as temp:
 binary=Path(temp)/'buddy-document-tests'
 subprocess.run(['xcrun','swiftc',str(source/'BuddyDocuments.swift'),str(source/'BuddyProjectFiles.swift'),str(source/'tests/Documents.swift'),'-o',str(binary)],check=True)
 subprocess.run([str(binary),str(Path(temp)/'fixtures')],check=True)
