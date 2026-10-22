#!/usr/bin/env python3
"""Stand-in for the one shared private browser (browser.mjs) for tests/WebsiteAccounts.swift, with the same JSONL protocol. It logs every
command it gets (session, account, url, email, token) to BUDDY_ACCOUNTS_BROWSER_LOG; a password, typed value or code only as its SHA-256.

Sites, by the host of the page a session opened:
  jobs.ubs.example, second.example  a sign-up form; created, then a confirmation link in the email (jobs) or signed in (second)
  trial.example                     a sign-up that starts a free trial that becomes paid (seen before anything is sent)
  payafter.example                  a clean form whose submit leads to a card form (nothing created)
  captcha.example                   a CAPTCHA on the form until the person finished that page in their Chrome window; then a code by email
  nomail.example                    created, a confirmation link that never arrives
  sms.example                       created, then a code texted to the phone
  reset.example                     a sign-in (both fields) whose password is BUDDY_ACCOUNTS_RESET_SHA256 until Buddy sets a new one through
                                    the reset link"""
import sys,json,os,hashlib
log=os.environ.get('BUDDY_ACCOUNTS_BROWSER_LOG');reset_sha=os.environ.get('BUDDY_ACCOUNTS_RESET_SHA256','')
n=0;pages={};plans={};secrets={};resets={};solved=set();manual=None;passwords={'https://reset.example':reset_sha}
def sha(text):return hashlib.sha256(text.encode()).hexdigest()
def record(value):
 if log:
  with open(log,'a') as f:f.write(json.dumps(value)+'\n')
def token(kind):
 global n
 n+=1;return kind+'-'+str(n)
def origin_of(url):
 parts=(url or '').split('/')
 return parts[0]+'//'+parts[2] if len(parts)>2 else ''
def host(url):return origin_of(url).split('//')[-1]
def view(url,text):return {'url':url,'title':'Fixture','text':text,'controls':[],'snapshotId':'snapshot-'+str(n)}
for line in sys.stdin:
 x=json.loads(line);command=x.get('command');session=x.get('session');result=None;error=None
 entry={k:x.get(k) for k in ['command','session','scope','account','url','page','email','token','username']}
 for k in ['value','password']:
  if k in x:entry[k+'SHA256']=sha(x[k])
 record(entry)
 here=pages.get(session,'');site=host(here);origin=origin_of(here)
 if command=='open':
  pages[session]=x.get('url') or '';result=view(pages[session],'Private sign-in')
 elif command=='read':result=view(here or 'about:blank','Fixture page')
 elif command=='signupPlan':
  if not here.endswith('/join'):result={'found':False,'origin':origin,'reason':'There is no sign-up form on this page.'}
  else:
   t=token('signup');plans[session]=t
   result={'found':True,'token':t,'origin':origin,'ready':True,'missing':[],'terms':['I agree to the Terms of Use and Privacy Policy'],'optional':['Send me job alerts'],'fills':[],
           'captcha':site=='captcha.example' and here not in solved,'money':{'kind':'trial','what':'free trial'} if site=='trial.example' else None,'page':here}
 elif command=='signup':
  if plans.pop(session,None)!=x.get('token'):error='This sign-up request was already used or replaced. Ask again; nothing was sent.'
  elif x.get('email')!=x.get('account') and x.get('account'):error='This task must use another account. Nothing was sent.'
  elif site=='payafter.example':result={'created':False,'money':{'kind':'payment','what':'card details'},'page':origin+'/billing'}
  elif site in ['jobs.ubs.example','nomail.example']:result={'created':True,'verify':'link','page':origin+'/check-email'}
  elif site=='captcha.example':
   t=token('secret');secrets[session]=('code',t);result={'created':True,'verify':'code','channel':'email','next':{'token':t,'field':'code','origin':origin},'page':origin+'/code'}
  elif site=='sms.example':
   t=token('secret');secrets[session]=('code',t);result={'created':True,'verify':'code','channel':'sms','next':{'token':t,'field':'code','origin':origin},'page':origin+'/code'}
  else:result={'created':True,'signedIn':True,'page':origin+'/home','view':view(origin+'/home','Welcome')}
 elif command=='openLink':
  link=x.get('url') or ''
  if host(link)!=site:error='The link in the email leads to another website, so Buddy didn’t open it.'
  else:
   pages[session]=link
   result={'opened':True,'private':'/reset' in link,'kind':'security' if '/reset' in link else 'signin','page':view(link,'Email confirmed') if '/reset' not in link else {'url':origin,'title':'Private sign-in'}}
 elif command=='secretPlan':
  if site in ['reset.example']:
   t=token('secret');secrets[session]=('login',t);result={'token':t,'origin':origin,'field':'login','account':x.get('account') or None,'private':True}
  elif session in secrets and secrets[session][0]=='code':
   t=token('secret');secrets[session]=('code',t);result={'token':t,'origin':origin,'field':'code','account':None,'private':True}
  else:result={'field':None,'origin':origin,'waiting':True}
 elif command=='fillSecret':
  kind,t=secrets.pop(session,(None,None))
  if t!=x.get('token'):error='This sign-in request was already used or replaced. Nothing was typed.'
  elif kind=='code':result={'signedIn':True,'performed':True,'page':view(origin+'/home','Welcome')}
  elif kind=='login':
   if x.get('username')!=x.get('account') and x.get('account'):error='This task must use another account. Nothing was typed.'
   elif entry['valueSHA256']==passwords.get(origin):result={'signedIn':True,'performed':True,'page':view(origin+'/home','Your applications')}
   else:
    t=token('secret');secrets[session]=('login',t);result={'signedIn':False,'next':{'token':t,'field':'login','origin':origin,'account':x.get('account') or None},'kind':'signin'}
 elif command=='prepareSignIn':result={'token':token('auth'),'origin':origin,'mode':x.get('mode'),'accountEmail':'','filled':False,'googleAvailable':False,'private':True}
 elif command=='useSaved':result={'needsUser':True,'reason':'Chrome has not filled a saved login.'}
 elif command=='resetPlan':
  if site=='reset.example':t=token('reset');resets[session]=t;result={'available':True,'token':t,'origin':origin,'signInURL':here}
  else:result={'available':False,'origin':origin}
 elif command=='resetStart':
  if resets.pop(session,None)!=x.get('token'):error='This reset request was already used or expired. Nothing was sent.'
  else:pages[session]=origin+'/forgot';result={'requested':True,'page':origin+'/forgot'}
 elif command=='resetFinish':
  if '/reset' not in here:result={'changed':False,'reason':'This page doesn’t ask for a new password.'}
  else:passwords[origin]=entry['passwordSHA256'];pages[session]=origin+'/login';result={'changed':True,'page':origin+'/login'}
 elif command=='recheck':
  if x.get('url'):pages[session]=x.get('url')
  result={'signedIn':False,'next':None,'waiting':True,'kind':'signin'}
 elif command in ['manual','manualGoogle']:manual=x.get('page') or x.get('url');result={'opened':True,'private':True}
 elif command=='finishManual':
  if manual:solved.add(manual)
  manual=None;result={'closed':True,'url':None}
 elif command=='closeSession':result={'closed':True,'remaining':0}
 elif command=='sessions':result={'sessions':[],'pages':[],'manual':manual is not None}
 elif command=='close':result={'closed':True}
 else:error='Unexpected browser fixture command: '+str(command)
 print(json.dumps({'id':x.get('id'),**({'error':error} if error else {'result':result})}),flush=True)
