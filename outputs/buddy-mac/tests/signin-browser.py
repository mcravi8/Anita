#!/usr/bin/env python3
import sys,json,uuid
for line in sys.stdin:
 x=json.loads(line);command=x['command'];result={}
 if command=='prepareSignIn':result={'token':str(uuid.uuid4()),'origin':'https://example.com','mode':x['mode'],'private':True}
 elif command in ['manual','manualGoogle']:result={'opened':True,'private':True}
 elif command=='finishManual':result={'closed':True}
 elif command=='open':result={'url':'https://example.com','text':'Fixture signed-in session','controls':[]}
 elif command=='read':result={'url':'https://example.com/apply','text':'Application form','controls':[],'snapshotId':'snapshot-1'}
 elif command=='prepare':result={'token':str(uuid.uuid4()),'preview':{'name':'Browser: fill','service':'Buddy private browser','arguments':{'page':'https://example.com/apply','action':'fill','targets':[{'control':'Name','value':'Ada'}]}}}
 elif command=='commit':result={'performed':True,'action':'fill'}
 else:raise AssertionError('Unexpected private browser fixture command: '+command)
 print(json.dumps({'id':x['id'],'result':result}),flush=True)
