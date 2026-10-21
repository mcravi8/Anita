#!/usr/bin/env python3
"""An inert RPC peer that deliberately never answers its first request."""
import json,sys
pending=None
for line in sys.stdin:
 x=json.loads(line)
 if x['command']=='silent':pending=x['id'];continue
 if pending is not None:
  print(json.dumps({'id':pending,'result':{'late':True}}),flush=True);pending=None
 print(json.dumps({'id':x['id'],'result':{'pong':True}}),flush=True)
