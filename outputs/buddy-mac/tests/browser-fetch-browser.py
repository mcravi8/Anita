#!/usr/bin/env python3
"""Stand-in for the one shared private browser (browser.mjs) for tests/BrowserFetch.swift, with the same JSONL protocol. It logs every
command it gets (session, scope, account, url, page, dir, saveAs, token) to BUDDY_FETCH_BROWSER_LOG; a typed value only as its SHA-256.

fetch: an address with "captcha" in it shows a CAPTCHA, and one with "members" a sign-in form, until the person has finished that page in
their Chrome window (a `manual` for it followed by `finishManual`); any other address gives a PDF fixture, written where Buddy says. Its
reply also carries a cookie and a header the website sent, which Buddy must never pass on.
Sign-in: the site's password field takes the password whose SHA-256 is BUDDY_FETCH_RIGHT_SHA256; anything else is wrong."""
import sys,json,os,hashlib
log=os.environ.get('BUDDY_FETCH_BROWSER_LOG');right=os.environ.get('BUDDY_FETCH_RIGHT_SHA256','')
PDF=b'%PDF-1.7\n% fixture: the published article ac498c\n%%EOF\n'
origin='https://shop.example';account='ada@example.com';n=0;tokens={};manual=None;solved=set()
def sha(data):return hashlib.sha256(data).hexdigest()
def record(value):
 if log:
  with open(log,'a') as f:f.write(json.dumps(value)+'\n')
def token(kind):
 global n
 n+=1;return kind+'-'+str(n)
def page(text,url=origin+'/account'):return {'url':url,'title':'Fixture','text':text,'controls':[],'snapshotId':'snapshot-'+str(n)}
for line in sys.stdin:
 x=json.loads(line);command=x.get('command');session=x.get('session');result=None;error=None
 entry={k:x.get(k) for k in ['command','session','scope','account','url','page','dir','saveAs','maxBytes','token']}
 if 'value' in x:entry['valueSHA256']=sha(x['value'].encode())
 record(entry)
 if command=='fetch':
  url=x.get('url') or '';site='https://'+url.split('/')[2] if url.count('/')>=2 else ''
  if 'captcha' in url and url not in solved:
   result={'saved':False,'challenge':{'kind':'captcha','title':'Radware Captcha Page','status':403,'url':url,'page':url,'origin':site}}
  elif 'members' in url and url not in solved:
   result={'saved':False,'challenge':{'kind':'signin','title':'Log in','status':200,'url':url,'page':url,'origin':site}}
  else:
   name=x.get('saveAs') or '';folder=x.get('dir') or ''
   if not os.path.isabs(folder) or '/' in name or name.startswith('.'):error='Choose the folder Buddy saves the file in.'
   else:
    with open(os.path.join(folder,name),'xb') as f:f.write(PDF)
    result={'saved':True,'path':name,'bytes':len(PDF),'sha256':sha(PDF),'contentType':'application/pdf','url':url,'finalURL':url+'?token=[private]','via':'page',
            'cookie':'member=SECRET-COOKIE-7781','headers':{'set-cookie':'member=SECRET-COOKIE-7781','x-private':'SECRET-HEADER-5521'}}
 elif command in ['open','read']:result=page('Fixture page',x.get('url') or origin+'/account')
 elif command=='prepareSignIn':result={'token':token('auth'),'origin':origin,'mode':x.get('mode'),'accountEmail':account,'filled':False,'googleAvailable':False,'private':True}
 elif command=='useSaved':result={'needsUser':True,'reason':'Chrome has not filled a saved login. Open privately to choose a saved account or unlock Password Manager.'}
 elif command=='secretPlan':
  t=token('secret');tokens[session]=t;result={'token':t,'origin':origin,'field':'password','account':account,'private':True}
 elif command=='fillSecret':
  if tokens.pop(session,None)!=x.get('token'):error='This sign-in request was already used or replaced. Nothing was typed.'
  elif entry['valueSHA256']==right:result={'signedIn':True,'performed':True,'page':page('Signed in fixture: your orders')}
  else:
   t=token('secret');tokens[session]=t;result={'signedIn':False,'next':{'token':t,'field':'password','origin':origin,'account':account},'kind':'signin'}
 elif command=='recheck':result={'signedIn':False,'unknown':True}
 elif command in ['manual','manualGoogle']:manual=x.get('page') or x.get('url');result={'opened':True,'private':True}
 elif command=='finishManual':
  if manual:solved.add(manual)
  manual=None;result={'closed':True,'url':None}
 elif command=='closeSession':tokens.pop(session,None);result={'closed':True,'remaining':0}
 elif command=='sessions':result={'sessions':[],'pages':[],'manual':manual is not None}
 elif command=='close':result={'closed':True}
 else:error='Unexpected browser fixture command: '+str(command)
 print(json.dumps({'id':x.get('id'),**({'error':error} if error else {'result':result})}),flush=True)
