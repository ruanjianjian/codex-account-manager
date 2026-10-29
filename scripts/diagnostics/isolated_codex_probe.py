import argparse,asyncio,base64,hashlib,json,os,pathlib,secrets,socket,time

parser=argparse.ArgumentParser(description="Isolated official Codex app-server regression. Does not operate the desktop GUI or modify the source auth file.")
parser.add_argument('--source-auth',type=pathlib.Path,required=True,help='Existing own-account auth.json; never paste a token into arguments')
parser.add_argument('--cli',required=True,help='Official Codex CLI executable')
parser.add_argument('--gateway-helper',required=True,help='Built AccountsGateway executable')
parser.add_argument('--output',type=pathlib.Path,required=True,help='Dedicated private local output directory outside the repository')
parser.add_argument('--port',type=int,default=19457)
args=parser.parse_args()
H=pathlib.Path.home()
ROOT=args.output.expanduser().resolve()
HOME=ROOT/'codex-home'
WORK=ROOT/'workspace'
GW=ROOT/'gateway'
CLI=str(pathlib.Path(args.cli).expanduser().resolve())
HELPER=str(pathlib.Path(args.gateway_helper).expanduser().resolve())
SOURCE=args.source_auth.expanduser().resolve()
PORT=args.port
STATE={'state':'starting','phases':[],'production_changed':False}
def write_private(p,value):
 data=value if isinstance(value,bytes) else value.encode()
 p.write_bytes(data);p.chmod(0o600)
def emit(label,**data):
 entry={'phase':label,'time':time.time(),**data};STATE['phases'].append(entry)
 write_private(ROOT/'status.json',json.dumps(STATE,indent=2));print(json.dumps(entry),flush=True)
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()

class Client:
 def __init__(self):self.seq=0;self.pending={};self.notes=asyncio.Queue();self.proc=None
 async def start(self):
  env={k:v for k,v in os.environ.items() if k in ['HOME','USER','LOGNAME','PATH','TMPDIR','LANG','LC_ALL','SSL_CERT_FILE','SSL_CERT_DIR','HTTPS_PROXY','HTTP_PROXY','ALL_PROXY','NO_PROXY']}
  env['CODEX_HOME']=str(HOME)
  self.err=open(ROOT/'client-stderr.log','ab');os.chmod(ROOT/'client-stderr.log',0o600)
  self.proc=await asyncio.create_subprocess_exec(CLI,'app-server','--stdio',cwd=WORK,env=env,stdin=asyncio.subprocess.PIPE,stdout=asyncio.subprocess.PIPE,stderr=self.err)
  self.reader=asyncio.create_task(self.read())
  await self.rpc('initialize',{'clientInfo':{'name':'isolated_gateway_acceptance','version':'1.0'},'capabilities':{'experimentalApi':True}})
  await self.send({'method':'initialized','params':{}})
  info=await self.rpc('account/read',{'refreshToken':False})
  if not info.get('account'):raise RuntimeError('isolated account did not load')
  emit('client_started',pid=self.proc.pid,account_loaded=True)
 async def send(self,data):self.proc.stdin.write((json.dumps(data)+'\n').encode());await self.proc.stdin.drain()
 async def read(self):
  try:
   while line:=await self.proc.stdout.readline():
    try:m=json.loads(line)
    except:continue
    if 'method' in m:
     if 'id' in m:await self.send({'id':m['id'],'error':{'code':-32601,'message':'No external actions allowed in acceptance test'}})
     else:await self.notes.put(m)
    elif m.get('id') in self.pending:
     f=self.pending.pop(m['id']);
     if not f.done():f.set_result(m)
  finally:
   for f in self.pending.values():
    if not f.done():f.set_exception(RuntimeError('client disconnected'))
 async def rpc(self,method,params):
  self.seq+=1;seq=self.seq;f=asyncio.get_running_loop().create_future();self.pending[seq]=f
  await self.send({'id':seq,'method':method,'params':params});m=await asyncio.wait_for(f,60)
  if 'error' in m:
   # Keep raw diagnostics local. Never echo RPC payloads or tokens.
   write_private(ROOT/'last-rpc-error.json',json.dumps(m));raise RuntimeError('RPC '+method+' failed; private diagnostic retained')
  return m['result']
 async def thread(self):
  r=await self.rpc('thread/start',{'cwd':str(WORK),'sandbox':'read-only','approvalPolicy':'never','baseInstructions':'This is an isolated connectivity test. Answer the test prompt exactly. Never call tools or access files.','serviceTier':'priority'})
  emit('thread_started',model=r['model'],provider=r['modelProvider'],service_tier=r.get('serviceTier'))
  return r['thread']['id']
 async def resume(self,tid):
  r=await self.rpc('thread/resume',{'threadId':tid,'cwd':str(WORK),'sandbox':'read-only','approvalPolicy':'never'})
  emit('thread_resumed',provider=r['modelProvider'],service_tier=r.get('serviceTier'))
 async def turn(self,tid,text,expected,label):
  r=await self.rpc('turn/start',{'threadId':tid,'input':[{'type':'text','text':text,'text_elements':[]}]})
  turn=r['turn']['id'];output='';errors=[]
  async def follow():
   nonlocal output
   while True:
    m=await self.notes.get();p=m.get('params',{})
    if p.get('threadId')!=tid:continue
    if m['method']=='item/agentMessage/delta' and p.get('turnId')==turn:output+=p.get('delta','')
    if m['method']=='error':errors.append(p)
    if m['method']=='turn/completed' and p['turn']['id']==turn:return p['turn']
  done=await asyncio.wait_for(follow(),150)
  passed=done['status']=='completed' and expected in output
  emit(label,passed=passed,turn_status=done['status'],expected_reply_seen=expected in output,error_notifications=len(errors))
  if not passed:
   write_private(ROOT/'last-turn-error.json',json.dumps({'turn':done,'errors':errors,'test_reply':output}));raise RuntimeError(label+' failed')
 async def stop(self):
  if self.proc and self.proc.returncode is None:
   self.proc.stdin.close()
   try:await asyncio.wait_for(self.proc.wait(),10)
   except asyncio.TimeoutError:self.proc.terminate();await self.proc.wait()
  if hasattr(self,'reader'):await self.reader
  if hasattr(self,'err'):self.err.close()

async def gateway():
 log=open(ROOT/'gateway-events.jsonl','ab');os.chmod(ROOT/'gateway-events.jsonl',0o600)
 p=await asyncio.create_subprocess_exec(HELPER,'--config',str(GW/'pool.json'),'--listen',f'127.0.0.1:{PORT}','--desktop-auth',str(HOME/'auth.json'),stdout=log,stderr=log)
 for _ in range(100):
  if p.returncode is not None:raise RuntimeError('isolated gateway exited')
  try:
   reader,writer=await asyncio.open_connection('127.0.0.1',PORT);writer.close();await writer.wait_closed()
   emit('gateway_listening',pid=p.pid,port=PORT);return p,log
  except OSError:await asyncio.sleep(.1)
 p.terminate();await p.wait();log.close();raise RuntimeError('gateway startup timeout')
async def stop_gateway(p,log):p.terminate();await p.wait();log.close()

async def main():
 for p in [ROOT,HOME,WORK,GW]:p.mkdir(exist_ok=True,parents=True);p.chmod(0o700)
 original=[H/'.codex/config.toml',H/'.codex/auth.json',SOURCE]
 before={str(p):sha(p) for p in original}
 if (HOME/'auth.json').exists():raise RuntimeError('test home already initialized; use resume or inspect first')
 auth=json.loads(original[2].read_text());auth['tokens']['refresh_token']='' # no authority to rotate the live account refresh token
 write_private(HOME/'auth.json',json.dumps(auth))
 access=auth['tokens']['access_token'];payload=access.split('.')[1];claims=json.loads(base64.urlsafe_b64decode(payload+'='*(-len(payload)%4)))
 c={'key':secrets.token_hex(32),'preferred':'test-account','clients':[{'id':'test-account','accountID':auth['tokens']['account_id']}],'accounts':[{'id':'test-account','accountID':auth['tokens']['account_id'],'access':'stale-pool-token-for-isolated-reproduction','expires':claims['exp'],'available':True,'reset':0}]}
 write_private(GW/'pool.json',json.dumps(c))
 base='model_provider = "openai"\ncli_auth_credentials_store = "file"\nservice_tier = "priority"\napproval_policy = "never"\nsandbox_mode = "read-only"\n[analytics]\nenabled = false\n'
 routed=f'openai_base_url = "http://127.0.0.1:{PORT}/backend-api/codex"\n'+base
 write_private(HOME/'config.toml',base)
 client=Client();gw=None;log=None
 try:
  await client.start();old=await client.thread()
  await client.turn(old,'Remember marker RIVER-6284. Reply only READY.','READY','direct_old_thread_created')
  await client.stop()
  gw,log=await gateway();write_private(HOME/'config.toml',routed)
  client=Client();await client.start();await client.resume(old)
  await client.turn(old,'What marker did I ask you to remember? Reply only the marker.','RIVER-6284','old_thread_via_gateway')
  new=await client.thread();await client.turn(new,'Reply only ROUTED_READY.','ROUTED_READY','new_thread_via_gateway')
  await stop_gateway(gw,log);gw=None;gw,log=await gateway()
  await client.turn(old,'Repeat the remembered marker only.','RIVER-6284','old_thread_after_gateway_restart')
  await client.stop();client=Client();await client.start();await client.resume(new)
  await client.turn(new,'Reply only CLIENT_RESTART_READY.','CLIENT_RESTART_READY','resume_after_client_restart')
  await client.stop();write_private(HOME/'config.toml',base);await stop_gateway(gw,log);gw=None
  client=Client();await client.start();await client.resume(old)
  await client.turn(old,'Repeat the remembered marker only.','RIVER-6284','restore_direct_old_thread')
  STATE['state']='passed'
 except Exception as e:
  STATE['state']='failed';emit('failure',category=type(e).__name__,message=str(e)[:180])
 finally:
  await client.stop()
  if gw:await stop_gateway(gw,log)
  STATE['production_changed']=any(sha(pathlib.Path(p))!=v for p,v in before.items())
  STATE['production_file_checks']={pathlib.Path(p).parent.name+'/'+pathlib.Path(p).name:sha(pathlib.Path(p))==v for p,v in before.items()}
  emit('finished',result=STATE['state'],production_unchanged=not STATE['production_changed'])

if __name__ == '__main__':
 asyncio.run(main())
