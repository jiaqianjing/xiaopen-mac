#!/usr/bin/env python3
"""Real CLI subprocesses against disposable Git and file-backed fake services.

Nothing in this module contacts GitHub, Apple or a real distribution service.
The only fake Git operation redirects fetch to a real local bare repository.
"""
import copy
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

import release_evidence as evidence

SOURCE = Path(__file__).resolve().parent
REAL_GIT = shutil.which('git')

FAKE_TOOL = r'''#!PYTHON
import hashlib,json,os,shutil,subprocess,sys,urllib.parse
from pathlib import Path
name=Path(sys.argv[0]).name
args=sys.argv[1:]
model_path=Path(os.environ['CLI_FIXTURE_MODEL'])
def load(): return json.loads(model_path.read_text())
def save(d): model_path.write_text(json.dumps(d))
def stop(text,code=1): print(text,file=sys.stderr); raise SystemExit(code)
def event(d,kind,**fields): d['calls'].append(dict(kind=kind,**fields))
if name=='git':
 if 'fetch' in args:
  i=args.index('fetch')+1
  if i>=len(args) or args[i]!='origin': stop('Unexpected fixture Git fetch')
  args[i]=os.environ['CLI_FIXTURE_BARE']
 raise SystemExit(subprocess.run([os.environ['CLI_FIXTURE_REAL_GIT'],*args]).returncode)
d=load()
if name=='swift':
 d['swiftCalls']+=1; save(d)
 print('Synthetic Swift fixture tests; no compiler or microphone used')
 raise SystemExit(1 if d.get('failSwift') else 0)
if name=='xcrun':
 if len(args)==2 and args[0]=='--find': print('/fixture/'+args[1]); raise SystemExit(0)
 stop('Unexpected xcrun fixture invocation')
if name=='curl':
 url=urllib.parse.urlsplit(args[-1]); parts=url.path.split('/'); filename=parts[-1]; tag=parts[-2]
 anonymous='-q' in args and '--no-netrc' in args and 'Authorization:' in args and 'Cookie:' in args
 event(d,'download',filename=filename,anonymous=anonymous)
 if not anonymous: save(d); stop('Anonymous curl policy missing')
 if d.get('failDownloads',0): d['failDownloads']-=1; save(d); stop('Synthetic public download failure',22)
 release=next((r for r in d['releases'] if r['tag_name']==tag and not r['draft']),None)
 if not release: save(d); stop('Synthetic public asset not found',22)
 asset=next((a for a in release['assets'] if a['name']==filename),None)
 if not asset: save(d); stop('Synthetic public asset not found',22)
 target=Path(args[args.index('--output')+1]); shutil.copyfile(asset['fixtureBlob'],target)
 if d.get('corruptDownload')==filename: target.write_bytes(b'wrong public fixture bytes')
 save(d); print('200',end=''); raise SystemExit(0)
if name!='gh': stop('Unexpected fake executable')
if args[:2]==['release','upload']:
 tag,path=args[2],Path(args[3]); release=next(r for r in d['releases'] if r['tag_name']==tag)
 if any(a['name']==path.name for a in release['assets']): stop('Fixture refuses clobber')
 aid=d['nextAssetID']; d['nextAssetID']+=1; blob=model_path.parent/('asset-'+str(aid)); shutil.copyfile(path,blob)
 release['assets'].append({'id':aid,'name':path.name,'state':'uploaded','size':path.stat().st_size,'digest':'sha256:'+hashlib.sha256(path.read_bytes()).hexdigest(),'fixtureBlob':str(blob)})
 event(d,'upload',filename=path.name)
 if d.get('interruptAfterMetadataUpload') and path.name=='verification.json':
  d['interruptAfterMetadataUpload']=False; d['failNextReleaseRead']=True
 save(d); print('fixture uploaded'); raise SystemExit(0)
if not args or args[0]!='api': stop('Unexpected gh fixture invocation')
endpoint=args[1].split('/',3)[3]; endpoint=urllib.parse.unquote(endpoint)
method=args[args.index('--method')+1] if '--method' in args else 'GET'
body=json.loads(sys.stdin.read()) if '--input' in args else None
if '--hostname' not in args or args[args.index('--hostname')+1]!='github.com': stop('Expected explicit github.com')
event(d,'api',endpoint=endpoint,method=method)
response=None
if endpoint.startswith('actions/workflows/ci.yml/runs'):
 response={'workflow_runs':[{'id':90,'head_sha':d['sourceCommit'],'status':d.get('ciStatus','completed'),'conclusion':d.get('ciConclusion','success'),'created_at':'2030-01-01T00:00:00Z','updated_at':'2030-01-01T00:00:00Z','html_url':'https://github.com/example/xiaopen/actions/runs/90'}] if not d.get('missingCI') else []}
elif endpoint=='git/ref/heads/main': response={'object':{'type':'commit','sha':d['mainCommit']}}
elif endpoint.startswith('git/ref/tags/'):
 tag=endpoint[len('git/ref/tags/'):]
 if tag not in d['tags']: save(d); stop('HTTP 404: fixture tag missing')
 response={'object':{'type':'commit','sha':d['tags'][tag]}}
elif endpoint=='releases/latest': response=next(r for r in d['releases'] if r['id']==d['latestID'])
elif endpoint.startswith('releases/tags/'):
 tag=endpoint[len('releases/tags/'):]; response=next((r for r in d['releases'] if r['tag_name']==tag),None)
 if response is None: save(d); stop('HTTP 404: fixture release missing')
elif endpoint.startswith('releases?'): response=d['releases']
elif endpoint=='releases' and method=='POST':
 response=dict(body,id=d['nextReleaseID'],assets=[],html_url='https://github.com/example/xiaopen/releases/tag/'+body['tag_name'],published_at=None)
 d['nextReleaseID']+=1; d['releases'].append(response); event(d,'create-draft')
elif endpoint.startswith('releases/assets/') and method=='DELETE':
 aid=int(endpoint.split('/')[-1]);
 for release in d['releases']: release['assets']=[a for a in release['assets'] if a['id']!=aid]
 event(d,'delete-asset',assetID=aid)
 if d.get('interruptAfterMetadataDelete'):
  d['interruptAfterMetadataDelete']=False; save(d); stop('HTTP 503: synthetic lost delete response')
elif endpoint.startswith('releases/') and endpoint.split('/')[-1].isdigit():
 rid=int(endpoint.split('/')[-1]); response=next(r for r in d['releases'] if r['id']==rid)
 if method=='GET' and d.get('failNextReleaseRead'):
  d['failNextReleaseRead']=False; save(d); stop('HTTP 503: synthetic interrupted metadata readback')
 if method=='PATCH':
  if body.get('draft') is False:
   event(d,'publish'); d['publishCalls']+=1; d['latestID']=rid; d['tags'][response['tag_name']]=response['target_commitish']; response['published_at']='2030-01-01T00:00:00Z'
  response.update({k:v for k,v in body.items() if k!='make_latest'})
else: save(d); stop('Unhandled fixture API: '+method+' '+endpoint)
save(d)
if response is not None: print(json.dumps(response))
'''

FAKE_BUILD = r'''#!PYTHON
import hashlib,json,os,plistlib,subprocess
from pathlib import Path
root=Path.cwd(); model=Path(os.environ['CLI_FIXTURE_MODEL']); d=json.loads(model.read_text()); d['buildCalls']+=1; model.write_text(json.dumps(d))
info=plistlib.loads((root/'Resources/Info.plist').read_bytes()); v,b=info['CFBundleShortVersionString'],info['CFBundleVersion']
source=subprocess.check_output([os.environ['CLI_FIXTURE_REAL_GIT'],'rev-parse','HEAD'],text=True).strip()
e=root/'build/notarization'/('fixture-'+str(d['buildCalls'])); e.mkdir(parents=True)
artifact=root/'build'/('XiaoPen-'+v+'.dmg'); artifact.write_bytes(b'Synthetic notarized DMG fixture; not an installer\x00')
(e/'release-summary.txt').write_text('Source commit: '+source+'\nVersion: '+v+' ('+b+')\nTeam: TESTTEAM01\nIdentity: Developer ID Application: Fixture (TESTTEAM01)\n')
(e/'SHA256SUMS').write_text(hashlib.sha256(artifact.read_bytes()).hexdigest()+'  '+artifact.name+'\n')
(e/'gatekeeper-status.log').write_text('assessments enabled\n')
(e/'signatures.log').write_text('Executable=/fixture/XiaoPen.app/Contents/MacOS/XiaoPen\nCDHash='+('a'*40)+'\nTeamIdentifier=TESTTEAM01\nExecutable=/fixture/'+artifact.name+'\nCDHash='+('b'*40)+'\nTeamIdentifier=TESTTEAM01\n')
for name in ('app-entitlements.plist','app-entitlements-lint.log','app-codesign-stapled.log','app-stapler-validate.log','app-gatekeeper.log','dmg-codesign-stapled.log','dmg-stapler-validate.log','dmg-gatekeeper.log','dmg-integrity.log','mounted-app-codesign.log','mounted-app-stapler.log','mounted-app-gatekeeper.log'):
 (e/name).write_text('Synthetic successful check fixture only\n')
for kind,job,cdhash,path in [('app','11111111-1111-1111-1111-111111111111','a'*40,'Payload.zip/XiaoPen.app'),('dmg','22222222-2222-2222-2222-222222222222','b'*40,'Carrier.zip/XiaoPen.app/Contents/Resources/Distribution/'+artifact.name)]:
 (e/(kind+'-notary-log.json')).write_text(json.dumps({'jobId':job,'status':'Accepted','statusCode':0,'issues':None,'ticketContents':[{'path':path,'cdhash':cdhash,'digestAlgorithm':'SHA-256'}]}))
print('Release evidence: '+str(e))
'''


class ReleaseCLITests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.repo = self.root / 'repo'
        self.repo.mkdir()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.model_path = self.root / 'github.json'
        self.bare = self.root / 'remote.git'
        self.env = dict(os.environ, PATH=str(self.bin)+os.pathsep+os.environ['PATH'],
                        CLI_FIXTURE_MODEL=str(self.model_path), CLI_FIXTURE_BARE=str(self.bare),
                        CLI_FIXTURE_REAL_GIT=REAL_GIT)
        for key in ('GH_TOKEN','GITHUB_TOKEN','GH_ENTERPRISE_TOKEN','GITHUB_ENTERPRISE_TOKEN'):
            self.env.pop(key,None)
        tool = self.bin / 'fixture-tool'
        tool.write_text(FAKE_TOOL.replace('#!PYTHON','#!'+sys.executable,1)); tool.chmod(0o755)
        for name in ('git','gh','swift','xcrun','curl'):
            (self.bin/name).symlink_to(tool)
        (self.repo/'scripts').mkdir(); (self.repo/'Resources').mkdir()
        for name in ('release.py','release_policy.py','release_evidence.py'):
            shutil.copyfile(SOURCE/name,self.repo/'scripts'/name)
        build = self.repo/'scripts/build_app.sh'
        build.write_text(FAKE_BUILD.replace('#!PYTHON','#!'+sys.executable,1)); build.chmod(0o755)
        (self.repo/'scripts/test_release_fixture.py').write_text('import unittest\nclass Fixture(unittest.TestCase):\n def test_fixture(self): self.assertTrue(True)\n')
        (self.repo/'.gitignore').write_text('build/\n__pycache__/\n')
        self.write_info('1.1.1','12')
        (self.repo/'CHANGELOG.md').write_text('## 1.1.1\nBaseline fixture.\n')
        self.git('init','-b','main')
        for key,value in (('user.name','CLI Fixture'),('user.email','fixture@example.invalid'),('commit.gpgsign','false'),('tag.gpgsign','false'),('core.hooksPath',str(self.root/'no-hooks'))):
            self.git('config',key,value)
        self.git('add','.'); self.git('commit','-m','baseline fixture')
        self.base = self.git('rev-parse','HEAD').stdout.strip()
        self.git('tag','v1.1.1')
        self.write_info('1.1.2','13')
        (self.repo/'CHANGELOG.md').write_text('## 1.1.2\nCandidate fixture.\n\n## 1.1.1\nBaseline fixture.\n')
        self.git('add','.'); self.git('commit','-m','version fixture')
        self.source = self.git('rev-parse','HEAD').stdout.strip()
        subprocess.run([REAL_GIT,'init','--bare',str(self.bare)],check=True,capture_output=True)
        self.git('push',str(self.bare),'main','--tags')
        self.git('remote','add','origin','https://github.com/example/xiaopen.git')
        self.session=self.repo/'build/releases/v1.1.2'
        self.save_model({'baselineCommit':self.base,'sourceCommit':self.source,'mainCommit':self.source,'tags':{'v1.1.1':self.base},'latestID':1,'nextReleaseID':2,'nextAssetID':100,'publishCalls':0,'buildCalls':0,'swiftCalls':0,'calls':[],'releases':[{'id':1,'tag_name':'v1.1.1','draft':False,'prerelease':False,'target_commitish':self.base,'body':'Published fixture baseline','assets':[],'html_url':'https://github.com/example/xiaopen/releases/tag/v1.1.1','published_at':'2029-01-01T00:00:00Z'}]})

    def git(self,*args):
        return subprocess.run([REAL_GIT,*args],cwd=self.repo,text=True,capture_output=True,check=True)

    def write_info(self,version,build):
        (self.repo/'Resources/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'example.xiaopen','CFBundleShortVersionString':version,'CFBundleVersion':build}))

    def model(self): return json.loads(self.model_path.read_text())
    def save_model(self,value): self.model_path.write_text(json.dumps(value))
    def state(self): return json.loads((self.session/'state.json').read_text())

    def cli(self,*args,ok=True):
        result=subprocess.run([sys.executable,str(self.repo/'scripts/release.py'),*map(str,args)],cwd=self.repo,env=self.env,text=True,capture_output=True,timeout=30)
        if ok: self.assertEqual(result.returncode,0,result.stdout+'\n'+result.stderr)
        else: self.assertNotEqual(result.returncode,0,result.stdout+'\n'+result.stderr)
        return result

    def prepare(self,ok=True):
        return self.cli('prepare','--base','v1.1.1','--notary-via-xcode',ok=ok)

    def fill_template(self):
        bundle=json.loads((self.session/'manual-checks.json').read_text())
        frame=self.root/'fixture-observation.txt'; frame.write_text('Synthetic test evidence, not physical acceptance.\n')
        for record in bundle['results']:
            record.update(result='pass',tester='CLI fixture operator',note='Synthetic integration fixture observations only',environment='Disposable fixture environment',evidence=[str(frame)])
            for key,expected in evidence.CHECKS[record['check']]['observed'].items():
                record['observed'][key]=self.state()['artifact']['sha256'] if expected=='$ARTIFACT_SHA256' else '1.1.2' if expected=='$VERSION' else self.state()['build'] if expected=='$BUILD' else '1.1.1' if expected=='$NONEMPTY' else expected
        path=self.root/'filled-checks.json'; path.write_text(json.dumps(bundle)); return path

    def confirm_all(self):
        self.cli('confirm','--from',self.fill_template())

    def publish(self,ok=True):
        return self.cli('publish','--approve-sha',self.state()['artifact']['sha256'],'--approver','CLI fixture operator',ok=ok)

    def test_standard_happy_path_and_repeated_prepare_publish(self):
        self.prepare()
        self.assertEqual(self.state()['plan']['tier'],'standard')
        self.assertEqual(self.model()['buildCalls'],1)
        self.publish(ok=False)
        self.assertEqual(self.model()['publishCalls'],0)
        self.prepare()
        self.assertEqual(self.model()['buildCalls'],1)
        self.assertEqual(self.model()['swiftCalls'],1)
        self.confirm_all()
        self.publish()
        self.assertTrue(self.state()['publication']['complete'])
        self.assertEqual(self.model()['publishCalls'],1)
        downloaded=self.session/'public-download'/self.state()['artifact']['filename']
        self.assertEqual(hashlib.sha256(downloaded.read_bytes()).hexdigest(),self.state()['artifact']['sha256'])
        self.assertEqual((self.session/'public-download/SHA256SUMS').read_text(),self.state()['artifact']['sha256']+'  '+downloaded.name+'\n')
        self.assertTrue(all(c['anonymous'] for c in self.model()['calls'] if c['kind']=='download'))
        self.publish()
        self.assertEqual(self.model()['publishCalls'],1)
        self.assertEqual(self.model()['buildCalls'],1)

    def test_foreign_draft_is_never_adopted_or_overwritten(self):
        model=self.model()
        model['releases'].append({'id':2,'tag_name':'v1.1.2','draft':True,'prerelease':False,'target_commitish':self.source,'body':'Someone else owns this draft','assets':[]})
        self.save_model(model)
        result=self.prepare(ok=False)
        self.assertIn('refusing adoption',result.stderr)
        self.assertEqual(self.model()['buildCalls'],0)
        self.assertFalse(any(c['kind']=='create-draft' for c in self.model()['calls']))

    def test_changed_remote_dmg_blocks_publish_without_clobber(self):
        self.prepare(); self.confirm_all()
        model=self.model(); release=next(r for r in model['releases'] if r['tag_name']=='v1.1.2')
        dmg=next(a for a in release['assets'] if a['name'].endswith('.dmg'))
        dmg['digest']='sha256:'+('f'*64)
        self.save_model(model)
        before_uploads=sum(c['kind']=='upload' for c in model['calls'])
        result=self.publish(ok=False)
        self.assertIn('Remote asset differs',result.stderr)
        self.assertEqual(self.model()['publishCalls'],0)
        self.assertEqual(sum(c['kind']=='upload' for c in self.model()['calls']),before_uploads)

    def test_source_change_invalidates_candidate(self):
        self.prepare(); self.confirm_all()
        self.git('commit','--allow-empty','-m','later source fixture')
        result=self.publish(ok=False)
        self.assertIn('Source commit changed',result.stderr)
        self.assertEqual(self.model()['publishCalls'],0)
        self.assertEqual(self.model()['buildCalls'],1)

    def test_changed_local_artifact_invalidates_candidate(self):
        self.prepare(); self.confirm_all()
        Path(self.state()['artifact']['path']).write_bytes(b'changed candidate fixture')
        self.publish(ok=False)
        self.assertEqual(self.model()['publishCalls'],0)

    def test_latest_ci_failure_blocks_publish(self):
        self.prepare(); self.confirm_all()
        model=self.model(); model['ciConclusion']='failure'; self.save_model(model)
        result=self.publish(ok=False)
        self.assertIn('CI for this exact source has not passed',result.stderr)
        self.assertEqual(self.model()['publishCalls'],0)

    def test_remote_baseline_tag_mismatch_blocks_prepare(self):
        model=self.model(); model['tags']['v1.1.1']=self.source; self.save_model(model)
        result=self.prepare(ok=False)
        self.assertIn('Local baseline tag differs',result.stderr)
        self.assertEqual(self.model()['buildCalls'],0)

    def test_half_invalid_confirmation_batch_is_atomic(self):
        self.prepare()
        template=self.fill_template(); bundle=json.loads(template.read_text())
        bundle['results'][1]['tester']=None
        template.write_text(json.dumps(bundle))
        state_path=self.session/'state.json'; before=state_path.read_bytes()
        self.cli('confirm','--from',template,ok=False)
        self.assertEqual(state_path.read_bytes(),before)
        self.assertEqual(self.state()['confirmations'],{})

    def test_public_download_failure_resumes_without_second_publication(self):
        self.prepare(); self.confirm_all()
        model=self.model(); model['failDownloads']=1; self.save_model(model)
        self.publish(ok=False)
        self.assertEqual(self.model()['publishCalls'],1)
        self.assertTrue(self.state()['publication']['published'])
        self.assertFalse(self.state()['publication']['publicDownloadsVerified'])
        self.publish()
        self.assertTrue(self.state()['publication']['complete'])
        self.assertEqual(self.model()['publishCalls'],1)
        self.assertEqual(self.model()['buildCalls'],1)

    def test_missing_verification_metadata_is_repaired(self):
        self.prepare(); self.confirm_all()
        model=self.model(); release=next(r for r in model['releases'] if r['tag_name']=='v1.1.2')
        release['assets']=[a for a in release['assets'] if a['name']!='verification.json']
        self.save_model(model)
        self.publish()
        self.assertTrue(self.state()['publication']['complete'])
        self.assertEqual(self.model()['publishCalls'],1)

    def test_metadata_delete_response_loss_is_resumable(self):
        self.prepare(); self.confirm_all()
        model=self.model(); model['interruptAfterMetadataDelete']=True; self.save_model(model)
        self.publish(ok=False)
        self.assertEqual(self.model()['publishCalls'],0)
        self.publish()
        self.assertTrue(self.state()['publication']['complete'])
        self.assertEqual(self.model()['publishCalls'],1)

    def test_metadata_upload_success_before_state_write_is_resumable(self):
        self.prepare()
        model=self.model(); model['interruptAfterMetadataUpload']=True; self.save_model(model)
        template=self.fill_template()
        self.cli('confirm','--from',template,ok=False)
        self.assertTrue(self.state()['confirmations'])
        self.prepare()
        self.publish()
        self.assertEqual(self.model()['buildCalls'],1)
        self.assertEqual(self.model()['publishCalls'],1)
        self.assertTrue(self.state()['publication']['complete'])

    def test_public_confirmation_rejected_without_clearing_approval(self):
        self.prepare(); self.confirm_all(); self.publish()
        state_path=self.session/'state.json'; before=state_path.read_bytes()
        approval=copy.deepcopy(self.state()['approval'])
        self.cli('confirm','--from',self.fill_template(),ok=False)
        self.assertEqual(state_path.read_bytes(),before)
        self.assertEqual(self.state()['approval'],approval)
        self.assertEqual(self.model()['publishCalls'],1)


if __name__=='__main__': unittest.main()
