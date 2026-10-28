#!/usr/bin/env python3
import json, sys, time
for line in sys.stdin:
    request = json.loads(line)
    if 'id' not in request: continue
    method=request['method']
    if method=='probe/provider':
        print(json.dumps({'id':request['id'],'result':{'officialProvider':'model_provider=\"openai\"' in sys.argv}}),flush=True); continue
    if method=='probe/timeout': continue
    if method=='probe/keychain':
        print(json.dumps({'id':request['id'],'error':{'code':-32603,'message':'Failed to load from keyring secret-must-not-escape'}}),flush=True); continue
    if method=='probe/error':
        print(json.dumps({'id':request['id'],'error':{'code':401,'message':'Unauthorized secret-must-not-escape'}}),flush=True); continue
    if method=='probe/disconnect': sys.exit(0)
    if method=='probe/fragment':
        text=json.dumps({'id':request['id'],'result':{'fragmented':True}})+'\n'
        sys.stdout.write(text[:8]);sys.stdout.flush();time.sleep(0.01);sys.stdout.write(text[8:]);sys.stdout.flush();continue
    if method=='probe/notify': print(json.dumps({'method':'account/rateLimits/updated','params':{'fixture':True}}),flush=True)
    print(json.dumps({'id':request['id'],'result':{'ok':True}}),flush=True)
