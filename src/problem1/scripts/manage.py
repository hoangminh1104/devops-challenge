"""Deployment helpers. Credentials are written only to git-ignored .local/."""
import json
import os
from pathlib import Path
import secrets
import re
import subprocess
import sys
import time
import uuid
import zipfile
import urllib.request
import urllib.error
from functools import lru_cache
from datetime import datetime

ROOT = Path(__file__).resolve().parents[1]
REGION = "ap-southeast-1"
PREFIX = "dom7hc-practice"
ACCOUNT = "730335245469"
PROFILE = "AWSAdministratorAccess-730335245469"
LOCAL = ROOT / ".local" / ACCOUNT
BUCKET = f"{PREFIX}-state-{ACCOUNT}"
LOAD_IMAGE_TAG = 'load-v5'
APP_IMAGE_TAG = 'v6'
os.environ.setdefault('PYTHONIOENCODING','utf-8')
os.environ.setdefault('PYTHONUTF8','1')
os.environ.setdefault('AWS_CLI_FILE_ENCODING','UTF-8')
os.environ['AWS_PROFILE'] = PROFILE
os.environ['AWS_DEFAULT_PROFILE'] = PROFILE
os.environ['TF_DATA_DIR'] = str(LOCAL / 'terraform-data')
sys.stdout.reconfigure(encoding='utf-8')
sys.stderr.reconfigure(encoding='utf-8')


def run(args, cwd=ROOT, input=None):
    result = subprocess.run(args, cwd=cwd, input=input, capture_output=True, text=True, encoding="utf-8")
    if result.returncode:
        # Do not echo the command: authentication commands can contain credentials.
        raise RuntimeError(result.stderr.strip() or f"Command failed with exit {result.returncode}")
    return result.stdout


def aws(*args):
    return json.loads(run(["aws", *args, "--profile", PROFILE, "--region", REGION, "--output", "json"]) or "{}")


@lru_cache(maxsize=1)
def outputs():
    return {k: v["value"] for k, v in json.loads(run(["terraform", "output", "-json"], ROOT / "infra")).items()}


def save(name, value):
    LOCAL.mkdir(parents=True, exist_ok=True)
    path = LOCAL / name
    path.write_text(json.dumps(value, indent=2), encoding="utf-8")
    return path


def api(service, operation, payload):
    path = save(f"{service}-{operation}-{uuid.uuid4()}.json", payload)
    try:
        return aws(service, operation, "--cli-input-json", f"file://{path}")
    finally:
        path.unlink(missing_ok=True)


def evidence(name, value):
    target = ROOT / "evidence"
    target.mkdir(exist_ok=True)
    if isinstance(value,dict):
        value = {'account_id':ACCOUNT,'aws_profile':PROFILE,'region':REGION,**value}
    (target / name).write_text(json.dumps(value, indent=2), encoding="utf-8")


def bootstrap():
    if aws("sts", "get-caller-identity")["Account"] != ACCOUNT:
        raise RuntimeError("Unexpected AWS account; refusing deployment")
    LOCAL.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(["aws", "s3api", "head-bucket", "--bucket", BUCKET, "--expected-bucket-owner", ACCOUNT, "--profile", PROFILE, "--region", REGION], capture_output=True)
    if result.returncode:
        aws("s3api", "create-bucket", "--bucket", BUCKET, "--create-bucket-configuration", f"LocationConstraint={REGION}")
    aws("s3api", "put-public-access-block", "--bucket", BUCKET, "--public-access-block-configuration", "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true")
    aws("s3api", "put-bucket-versioning", "--bucket", BUCKET, "--versioning-configuration", "Status=Enabled")
    encryption = save("encryption.json", {"Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]})
    aws("s3api", "put-bucket-encryption", "--bucket", BUCKET, "--server-side-encryption-configuration", f"file://{encryption}")
    policy = save("state-policy.json", {"Version": "2012-10-17", "Statement": [{"Sid": "RequireTLS", "Effect": "Deny", "Principal": "*", "Action": "s3:*", "Resource": [f"arn:aws:s3:::{BUCKET}", f"arn:aws:s3:::{BUCKET}/*"], "Condition": {"Bool": {"aws:SecureTransport": "false"}}}]})
    aws("s3api", "put-bucket-policy", "--bucket", BUCKET, "--policy", f"file://{policy}")
    print(f"State bucket ready: {BUCKET}")
    print(run(["terraform", "init", "-input=false", "-reconfigure", f"-backend-config=bucket={BUCKET}", "-backend-config=key=problem1/terraform.tfstate", f"-backend-config=region={REGION}", f"-backend-config=profile={PROFILE}", "-backend-config=encrypt=true", "-backend-config=use_lockfile=true"], ROOT / "infra"))


def initial_plan():
    run(['terraform','fmt','-check'],ROOT/'infra')
    validation=json.loads(run(['terraform','validate','-json'],ROOT/'infra'))
    if not validation['valid']:
        raise RuntimeError('Terraform validation failed')
    plan=LOCAL/'bootstrap.tfplan'
    text=run(['terraform','plan','-input=false','-no-color','-var=running=false',f'-out={plan}'],ROOT/'infra')
    (LOCAL/'bootstrap-plan.txt').write_text(text,encoding='utf-8')
    details=json.loads(run(['terraform','show','-json',str(plan)],ROOT/'infra'))
    managed=[{'resource':change['address'],'actions':change['change']['actions']} for change in details.get('resource_changes',[]) if change['mode']=='managed']
    if any(change['actions'] not in [['create'],['no-op']] for change in managed):
        raise RuntimeError('Initial sandbox plan includes modification/deletion of existing resources; refusing automatic provisioning')
    result={'account':ACCOUNT,'profile':PROFILE,'region':REGION,'state_bucket':BUCKET,
            'creates':sum(change['actions']==['create'] for change in managed),'updates':0,'deletes':0,'plan_file':str(plan),'validation_valid':True}
    evidence('initial-plan.json',result)
    print(json.dumps(result,indent=2))


def apply_initial():
    plan=LOCAL/'bootstrap.tfplan'
    if not plan.exists():
        raise RuntimeError('Run initial-plan before provisioning')
    result=subprocess.run(['terraform','apply','-input=false','-no-color',str(plan)],cwd=ROOT/'infra',stdin=subprocess.DEVNULL,stdout=sys.stdout,stderr=sys.stderr)
    if result.returncode:
        raise RuntimeError('Initial provisioning failed; inspect this account-specific state and logs')


def build(tag=APP_IMAGE_TAG, load=False):
    repo = aws("ecr", "describe-repositories", "--repository-names", f"{PREFIX}-app")["repositories"][0]["repositoryUri"]
    password = run(["aws", "ecr", "get-login-password", "--region", REGION, "--profile", PROFILE])
    run(["docker", "login", "--username", "AWS", "--password-stdin", repo.split('/')[0]], input=password)
    source = ROOT / ("load" if load else "app")
    print(run(["docker", "build", "-t", f"{repo}:{tag}", "."], source))
    print(run(["docker", "push", f"{repo}:{tag}"]))
    print(f"Published {repo}:{tag}")


def cloud_build(tag=APP_IMAGE_TAG,load_only=False):
    LOCAL.mkdir(parents=True, exist_ok=True)
    source = LOCAL / "source.zip"
    with zipfile.ZipFile(source, "w", zipfile.ZIP_DEFLATED) as archive:
        for folder in ["app", "load"]:
            for path in (ROOT / folder).rglob('*'):
                if path.is_file() and not set(path.relative_to(ROOT).parts).intersection({"node_modules", ".local"}) and not path.name.startswith('.env'):
                    archive.write(path, path.relative_to(ROOT).as_posix())
    uploaded = aws("s3api", "put-object", "--bucket", BUCKET, "--key", "build/source.zip", "--body", str(source))
    spec=(ROOT / 'buildspec.yml').read_text(encoding='utf-8')
    if load_only:
        spec=json.dumps({'version':0.2,'phases':{'pre_build':{'commands':['aws ecr get-login-password --region "$AWS_DEFAULT_REGION" | docker login --username AWS --password-stdin "${ECR_REPO%/*}"']},'build':{'commands':[
            f'docker build -t "$ECR_REPO:{LOAD_IMAGE_TAG}" load',
            f'docker run --rm --entrypoint k6 -e "TOKENS=[]" "$ECR_REPO:{LOAD_IMAGE_TAG}" inspect --include-system-env-vars=true /scripts/scenario.js',
            f'docker push "$ECR_REPO:{LOAD_IMAGE_TAG}"'
        ]}}})
    started = api("codebuild", "start-build", {"projectName": f"{PREFIX}-build", "sourceVersion": uploaded["VersionId"], "buildspecOverride":spec, "environmentVariablesOverride": [{"name":"APP_TAG", "value":tag, "type":"PLAINTEXT"}]})
    build_id = started["build"]["id"]
    print(f"CodeBuild started: {build_id}", flush=True)
    for _ in range(120):
        current = aws("codebuild", "batch-get-builds", "--ids", build_id)["builds"][0]
        if current["buildStatus"] != "IN_PROGRESS":
            evidence("load-build-latest.json" if load_only else "build-latest.json", {"id":build_id,"status":current["buildStatus"],"image_tag":LOAD_IMAGE_TAG if load_only else tag,"source_version":uploaded["VersionId"],"logs":current.get("logs",{})})
            print(json.dumps({"id":build_id,"status":current["buildStatus"],"logs":current.get("logs",{})}, indent=2))
            if current["buildStatus"] != "SUCCEEDED":
                raise RuntimeError("CodeBuild failed; inspect the build log")
            return
        time.sleep(10)
    raise RuntimeError(f"Build still running: {build_id}")


def users():
    path = LOCAL / "credentials.json"
    if path.exists():
        return json.loads(path.read_text(encoding="utf-8"))
    try:
        stored = aws("secretsmanager", "get-secret-value", "--secret-id", f"{PREFIX}-demo-accounts")
        data = json.loads(stored["SecretString"])
        save("credentials.json", data)
        return data
    except RuntimeError as exc:
        if "ResourceNotFoundException" not in str(exc):
            raise
        return []


def seed_users():
    out = outputs()
    credentials = users()
    for index in range(8):
        username = f"{PREFIX}-demo-{index + 1:02d}"
        existing = next((u for u in credentials if u["username"] == username), None)
        if existing:
            continue
        try:
            response = aws("cognito-idp", "admin-get-user", "--user-pool-id", out["user_pool_id"], "--username", username)
        except RuntimeError as exc:
            if "UserNotFoundException" not in str(exc):
                raise
            created = api("cognito-idp", "admin-create-user", {"UserPoolId": out["user_pool_id"], "Username": username, "MessageAction": "SUPPRESS"})
            response = {"UserAttributes": created["User"]["Attributes"]}
        password = secrets.token_urlsafe(32) + "aA1!"
        api("cognito-idp", "admin-set-user-password", {"UserPoolId": out["user_pool_id"], "Username": username, "Password": password, "Permanent": True})
        sub = next(a["Value"] for a in response["UserAttributes"] if a["Name"] == "sub")
        credentials.append({"username": username, "password": password, "sub": sub})
        save("credentials.json", credentials)
    api("secretsmanager", "put-secret-value", {"SecretId": out["demo_secret_arn"], "SecretString": json.dumps(credentials)})
    print(f"Provisioned {len(credentials)} demo accounts. Passwords are only in Secrets Manager and git-ignored .local/.")


def tokens():
    out = outputs()
    result = []
    for user in users():
        response = api("cognito-idp", "initiate-auth", {"ClientId": out["client_id"], "AuthFlow": "USER_PASSWORD_AUTH", "AuthParameters": {"USERNAME": user["username"], "PASSWORD": user["password"]}})
        result.append({"sub": user["sub"], "token": response["AuthenticationResult"]["AccessToken"]})
    if len(result) < 2:
        raise RuntimeError("Run seed-users first")
    save("tokens.json", result)
    return result


def wait_task(arn, out, container="worker", prefix="worker", timeout=600):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        task = aws("ecs", "describe-tasks", "--cluster", out["cluster"], "--tasks", arn)["tasks"][0]
        if task["lastStatus"] == "STOPPED":
            task_id = arn.rsplit('/', 1)[-1]
            time.sleep(3)  # allow the final CloudWatch log batch to arrive
            try:
                logs = aws("logs", "get-log-events", "--log-group-name", f"/{PREFIX}/app", "--log-stream-name", f"{prefix}/{container}/{task_id}", "--start-from-head")["events"]
            except RuntimeError:
                logs = []
            return task, logs
        time.sleep(5)
    raise RuntimeError(f"Timed out waiting for task {arn}; inspect and stop it if necessary")


def admin(command):
    out = outputs()
    env = []
    if command in ["seed","seed-book"]:
        env = [{"name": "SEED_ACCOUNTS", "value": json.dumps([u["sub"] for u in users()])}]
    invocation=['node','src/admin.js',command]
    if command=='seed-book':
        invocation=['node','--input-type=module','-e',(ROOT/'scripts'/'seed-book.mjs').read_text(encoding='utf-8')]
    response = api("ecs", "run-task", {
        "cluster": out["cluster"], "taskDefinition": out["worker_task_definition"], "launchType": "FARGATE",
        "networkConfiguration": {"awsvpcConfiguration": {"subnets": out["private_subnets"], "securityGroups": [out["app_security_group"]], "assignPublicIp": "DISABLED"}},
        "overrides": {"containerOverrides": [{"name": "worker", "command": invocation, "environment": env}]},
        "tags": [{"key": "Application", "value": PREFIX}],
    })
    if response.get("failures") or not response.get("tasks"):
        raise RuntimeError(json.dumps(response.get("failures", response)))
    task, logs = wait_task(response["tasks"][0]["taskArn"], out)
    for item in logs:
        print(item["message"])
    if task["containers"][0].get("exitCode") != 0:
        raise RuntimeError(f"Admin task failed: {task.get('stoppedReason')}; {task['containers'][0].get('reason')}")
    if command=='seed-book':
        for item in logs:
            value=json.loads(item['message'])
            if value.get('event')=='book_seeded':
                value['checked_at_epoch']=time.time()
                evidence('book-fixture.json',value)
    if command == "audit":
        for item in logs:
            try:
                report = json.loads(item["message"])
                if report.get("event") == "audit":
                    report['checked_at_epoch'] = time.time()
                    evidence("audit-latest.json", report)
                    evidence(f"audit-{int(time.time())}.json", report)
                    if any(report[key] for key in ['negative_balances','unbalanced_events','unreconciled_balances']):
                        raise RuntimeError('Financial audit failed; evidence retained')
                    return report
            except ValueError:
                pass


def request(path, token=None, method="GET", body=None, key=None, expected=200, extra_headers=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if key:
        headers["Idempotency-Key"] = key
    headers.update(extra_headers or {})
    target = outputs()["api_url"] + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(target, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=12) as response:
            status, result = response.status, json.loads(response.read())
    except urllib.error.HTTPError as exc:
        status, result = exc.code, json.loads(exc.read())
    if status != expected:
        raise RuntimeError(f"{method} {path}: expected {expected}, got {status}: {result}")
    return result


def verify():
    auth = tokens()
    a, b = auth[0]["token"], auth[1]["token"]
    passed = []
    request("/v1/markets"); passed.append("public markets HTTPS")
    request("/v1/balances", expected=401); passed.append("missing JWT rejected")
    request("/v1/balances", expected=401, extra_headers={"x-user-sub": auth[0]["sub"]}); passed.append("spoofed identity rejected at gateway")
    request("/v1/balances", a); passed.append("Cognito access token authorized")
    first_user = users()[0]
    auth_response = api('cognito-idp','initiate-auth',{'ClientId':outputs()['client_id'],'AuthFlow':'USER_PASSWORD_AUTH','AuthParameters':{'USERNAME':first_user['username'],'PASSWORD':first_user['password']}})
    request('/v1/balances',auth_response['AuthenticationResult']['IdToken'],expected=403)
    passed.append('ID token rejected because access-token scope is required')
    sell_body = {"market": "BTC-USDT", "side": "SELL", "price": "60123", "quantity": "0.001"}
    sell = request("/v1/orders", b, "POST", sell_body, str(uuid.uuid4()), 202)
    time.sleep(2)
    key = str(uuid.uuid4())
    buy_body = {**sell_body, "side": "BUY", "price": "60124"}
    buy = request("/v1/orders", a, "POST", buy_body, key, 202)
    retry = request("/v1/orders", a, "POST", buy_body, key, 202)
    assert retry["id"] == buy["id"], "Retry created another order"
    request("/v1/orders", a, "POST", {**buy_body, "price": "60125"}, key, 409)
    passed.append("durable acceptance and idempotency")
    for _ in range(20):
        order = request(f"/v1/orders/{buy['id']}", a)
        if order["status"] == "FILLED":
            break
        time.sleep(0.5)
    assert order["status"] == "FILLED", "Matching did not complete"
    passed.append("asynchronous matching completed")
    request(f"/v1/orders/{sell['id']}", a, expected=404); passed.append("cross-account ownership enforced")
    request(f"/v1/orders/{sell['id']}",a,expected=404,extra_headers={'x-user-sub':auth[1]['sub']})
    passed.append('authenticated caller cannot override gateway identity')
    cancel_order = request("/v1/orders", a, "POST", {**buy_body, "price": "1", "quantity": "1"}, str(uuid.uuid4()), 202)
    request(f"/v1/orders/{cancel_order['id']}", a, "DELETE", expected=202)
    for _ in range(20):
        order = request(f"/v1/orders/{cancel_order['id']}", a)
        if order["status"] == "CANCELLED":
            break
        time.sleep(0.5)
    assert order["status"] == "CANCELLED", "Cancellation did not complete"
    passed.append("cancellation processed")
    result = {"api_url": outputs()["api_url"], "passed": passed, "checked_at_epoch": time.time()}
    evidence("functional.json", result)
    print(json.dumps(result, indent=2))


def prepare_live_demo():
    verify()
    admin('seed-book')
    result=admin('audit')
    if not result or result['pending_commands']!=0:
        raise RuntimeError('Demo queue has not drained after preparation; inspect the audit')
    inventory()
    public_config()
    print(json.dumps({'event':'live_demo_ready','account_id':ACCOUNT,'api_url':outputs()['api_url']}),flush=True)


def load(rate=500, duration="180s", profile="mixed"):
    parsed_duration = re.fullmatch(r'(\d+)(s|m|h)', duration)
    if not parsed_duration or not 1 <= rate <= 1000 or profile not in ['mixed','write-heavy']:
        raise ValueError('Expected rate 1–1000, duration such as 180s, and profile mixed or write-heavy')
    duration_seconds = int(parsed_duration[1]) * {'s':1,'m':60,'h':3600}[parsed_duration[2]]
    if duration_seconds < 30 or duration_seconds > 600:
        raise ValueError('Load duration must be 30–600 seconds')
    out = outputs()
    auth = tokens()
    api("secretsmanager", "put-secret-value", {"SecretId": out["load_tokens_secret_arn"], "SecretString": json.dumps(auth)})
    run_id = f"{int(time.time())}-{profile}"
    definition = api("ecs", "register-task-definition", {
        "family": f"{PREFIX}-load", "networkMode": "awsvpc", "requiresCompatibilities": ["FARGATE"],
        "cpu": "2048", "memory": "8192", "executionRoleArn": out["execution_role"], "taskRoleArn": out["task_role"],
        "containerDefinitions": [{
            "name": "load", "image": f"{out['repository_url']}:{LOAD_IMAGE_TAG}", "essential": True,
            "secrets": [{"name": "TOKENS", "valueFrom": out["load_tokens_secret_arn"]}],
            "environment": [{"name": name, "value": str(value)} for name, value in {"TARGET": out["api_url"], "RATE": rate, "DURATION": duration, "PROFILE": profile, "RUN_ID": run_id, "GOMAXPROCS":2, "PREALLOCATED_VUS":500}.items()],
            "logConfiguration": {"logDriver": "awslogs", "options": {"awslogs-group": f"/{PREFIX}/app", "awslogs-region": REGION, "awslogs-stream-prefix": "load"}},
        }], "tags": [{"key": "Application", "value": PREFIX}],
    })
    response = api("ecs", "run-task", {
        "cluster": out["cluster"], "taskDefinition": definition["taskDefinition"]["taskDefinitionArn"], "launchType": "FARGATE",
        "networkConfiguration": {"awsvpcConfiguration": {"subnets": [out["test_subnet"]], "securityGroups": [out["test_security_group"]], "assignPublicIp": "ENABLED"}},
        "tags": [{"key": "Application", "value": PREFIX}],
    })
    if response.get("failures") or not response.get("tasks"):
        raise RuntimeError(json.dumps(response.get("failures", response)))
    arn = response["tasks"][0]["taskArn"]
    print(f"Load task started: {arn}; run {run_id}", flush=True)
    task, logs = wait_task(arn, out, "load", "load", timeout=1200)
    save(f"load-{run_id}-logs.json", logs)
    summary = None
    for item in logs:
        text = item["message"]
        if text.startswith('{'):
            try:
                value = json.loads(text)
                if value.get("event") == "load_summary":
                    summary = value
            except ValueError:
                pass
    if summary:
        summary["task_arn"] = arn
        summary['api_task_definition'] = out['api_task_definition']
        summary['worker_task_definition'] = out['worker_task_definition']
        summary['load_image_tag'] = LOAD_IMAGE_TAG
        summary['generator_vcpu'] = 2
        summary['generator_memory_mb'] = 8192
        summary['preallocated_vus'] = 500
        summary['achieved_main_rps'] = summary.get('metrics',{}).get('main_requests',{}).get('values',{}).get('count',0) / duration_seconds
        summary['expected_main_requests'] = rate*duration_seconds
        summary['main_request_count_tolerance'] = max(2,round(rate*0.01))
        summary['main_request_count_valid'] = abs(summary.get('metrics',{}).get('main_requests',{}).get('values',{}).get('count',0)-rate*duration_seconds)<=summary['main_request_count_tolerance']
        summary['dropped_iteration_scope'] = 'entire continuous run, including warm-up'
        summary["exit_code"] = task["containers"][0].get("exitCode")
        attach_queue_samples(summary,task)
        evidence(f"load-{run_id}.json", summary)
        print(json.dumps(summary, indent=2))
    else:
        for item in logs:
            print(item["message"])
    if task["containers"][0].get("exitCode") != 0:
        raise RuntimeError(f"Load task failed or thresholds were not met: {task.get('stoppedReason')}")
    if not summary or not summary.get('main_request_count_valid'):
        raise RuntimeError('Measured request volume does not cover the declared interval; inspect generator evidence')


def attach_queue_samples(summary,task=None):
    if task is None:
        found=aws('ecs','describe-tasks','--cluster',f'{PREFIX}-cluster','--tasks',summary['task_arn'])['tasks']
        task=found[0] if found else {}
    start=int(datetime.fromisoformat(task['startedAt']).timestamp()*1000) if task.get('startedAt') else int(summary['run_id'].split('-')[0])*1000
    end=int(datetime.fromisoformat(task['stoppedAt']).timestamp()*1000) if task.get('stoppedAt') else start+600000
    messages=aws('logs','filter-log-events','--log-group-name',f'/{PREFIX}/app','--filter-pattern','worker_progress','--start-time',str(start),'--end-time',str(end))['events']
    samples=[]
    for message in messages:
        value=json.loads(message['message'])
        samples.append({'at_epoch_ms':message['timestamp'],**{k:value[k] for k in ['pending_commands','oldest_command_seconds','batch_size','max_batch_ms'] if k in value}})
    summary['task_started_at']=task.get('startedAt')
    summary['task_stopped_at']=task.get('stoppedAt')
    summary['queue_samples']=samples
    summary['queue_peak_pending_sampled']=max((s['pending_commands'] for s in samples),default=None)
    summary['queue_peak_age_seconds_sampled']=max((s['oldest_command_seconds'] for s in samples),default=None)


def collect_load(run_id):
    if not re.fullmatch(r'\d+-(mixed|write-heavy)',run_id):
        raise ValueError('Invalid run ID')
    path=ROOT/'evidence'/f'load-{run_id}.json'
    summary=json.loads(path.read_text(encoding='utf-8'))
    attach_queue_samples(summary)
    evidence(path.name,summary)
    print(json.dumps({k:summary.get(k) for k in ['run_id','queue_peak_pending_sampled','queue_peak_age_seconds_sampled']},indent=2))


def collect_drain(run_id):
    if not re.fullmatch(r'\d+-(mixed|write-heavy)',run_id):
        raise ValueError('Invalid run ID')
    path=ROOT/'evidence'/f'load-{run_id}.json'
    summary=json.loads(path.read_text(encoding='utf-8'))
    if not summary.get('task_stopped_at'):
        raise RuntimeError('Collect task timestamps first')
    stopped=int(datetime.fromisoformat(summary['task_stopped_at']).timestamp()*1000)
    events=aws('logs','filter-log-events','--log-group-name',f'/{PREFIX}/app','--filter-pattern','worker_progress','--start-time',str(stopped),'--end-time',str(int(time.time()*1000)))['events']
    samples=[]
    for event in events:
        value=json.loads(event['message'])
        samples.append({'at_epoch_ms':event['timestamp'],'pending_commands':value['pending_commands'],'oldest_command_seconds':value['oldest_command_seconds']})
    empty=next((sample['at_epoch_ms'] for sample in sorted(samples,key=lambda x:x['at_epoch_ms']) if sample['pending_commands']==0),None)
    summary['post_load_queue_samples']=samples
    summary['queue_peak_age_seconds_during_drain_sampled']=max((s['oldest_command_seconds'] for s in samples),default=None)
    summary['observed_empty_queue_seconds_after_task_stop']=None if empty is None else (empty-stopped)/1000
    audit_file=ROOT/'evidence'/'audit-latest.json'
    if audit_file.exists():
        audit=json.loads(audit_file.read_text(encoding='utf-8'))
        if audit.get('checked_at_epoch',0)*1000>=stopped:
            summary['post_run_audit']=audit
    evidence(path.name,summary)
    print(json.dumps({key:summary.get(key) for key in ['run_id','queue_peak_age_seconds_during_drain_sampled','observed_empty_queue_seconds_after_task_stop','post_run_audit']},indent=2))


def report():
    rows=[]
    for path in sorted((ROOT/'evidence').glob('load-*.json')):
        if not re.fullmatch(r'load-\d+-(mixed|write-heavy)\.json',path.name):
            continue
        data=json.loads(path.read_text(encoding='utf-8'))
        metrics=data['metrics']
        duration_match=re.fullmatch(r'(\d+)(s|m|h)',data['duration'])
        seconds=int(duration_match[1])*{'s':1,'m':60,'h':3600}[duration_match[2]]
        values=lambda key:metrics.get(key,{}).get('values',{})
        count=values('main_requests').get('count',0)
        aggregate=values('end_to_end_ms{phase:main}').get('p(99)')
        routes={route:values(f'end_to_end_ms{{phase:main,route:{route}}}').get('p(99)') for route in ['book','balances','history','place','trades']}
        dropped=values('dropped_iterations{scenario:main}').get('count',0)
        error_rate=values('unexpected_status{phase:main}').get('rate')
        expected=data['offered_rps']*seconds
        passed=(data.get('exit_code')==0 and abs(count-expected)<=data.get('main_request_count_tolerance',1) and dropped==0 and error_rate is not None and error_rate<0.001
                and aggregate is not None and aggregate<100 and routes['place'] is not None and routes['place']<100)
        rows.append({'run_id':data['run_id'],'evidence':path.name,'profile':data['profile'],'offered_rps':data['offered_rps'],
                     'measured_seconds':seconds,'main_requests':count,'achieved_main_rps':count/seconds,'aggregate_p99_ms':aggregate,
                     'route_p99_ms':routes,'unexpected_status_rate':error_rate,'dropped_main_iterations':dropped,'all_acceptance_checks_passed':passed,
                     'dropped_iteration_scope':data.get('dropped_iteration_scope','measured scenario' if 'warmup_seconds' not in data else 'entire continuous run, including warm-up'),
                     'queue_peak_pending_sampled':data.get('queue_peak_pending_sampled'),'queue_peak_age_seconds_sampled':data.get('queue_peak_age_seconds_sampled'),
                     'observed_empty_queue_seconds_after_task_stop':data.get('observed_empty_queue_seconds_after_task_stop'),
                     'queue_peak_age_seconds_during_drain_sampled':data.get('queue_peak_age_seconds_during_drain_sampled'),
                     'api_task_definition':data.get('api_task_definition'),'worker_task_definition':data.get('worker_task_definition')})
    result={'generated_at_epoch':time.time(),'runs':rows}
    evidence('results-summary.json',result)
    print(json.dumps(result,indent=2))


def running(tag=APP_IMAGE_TAG):
    variables = save("deployment.tfvars.json", {"running": True, "image_tag": tag})
    result = subprocess.run(["terraform", "apply", "-input=false", "-auto-approve", f"-var-file={variables}"], cwd=ROOT / "infra",stdin=subprocess.DEVNULL,stdout=sys.stdout,stderr=sys.stderr)
    if result.returncode:
        raise RuntimeError("Terraform deployment failed; inspect partial state before retry")
    run(['aws','ecs','wait','services-stable','--cluster',f'{PREFIX}-cluster','--services',f'{PREFIX}-api',f'{PREFIX}-worker','--region',REGION,'--profile',PROFILE])
    print('API and worker services reached steady state',flush=True)


def inventory():
    out = outputs()
    arns = aws('ecs','list-tasks','--cluster',out['cluster'])['taskArns']
    tasks = aws('ecs','describe-tasks','--cluster',out['cluster'],'--tasks',*arns)['tasks'] if arns else []
    db = aws('rds','describe-db-instances','--db-instance-identifier',f'{PREFIX}-postgres')['DBInstances'][0]
    images = aws('ecr','describe-images','--repository-name',f'{PREFIX}-app')['imageDetails']
    result = {
        'checked_at_epoch':time.time(), 'region':REGION, 'api_url':out['api_url'],
        'tasks':[{'arn':t['taskArn'],'service':t.get('group'),'az':t.get('availabilityZone'),'status':t['lastStatus'],'health':t.get('healthStatus'),'started_at':t.get('startedAt'),
                  'definition':t['taskDefinitionArn'],'images':[{'name':c['name'],'digest':c.get('imageDigest')} for c in t['containers']]} for t in tasks],
        'database':{k:db.get(k) for k in ['DBInstanceIdentifier','DBInstanceStatus','DBInstanceClass','Engine','EngineVersion','MultiAZ','AvailabilityZone','SecondaryAvailabilityZone','PubliclyAccessible','StorageEncrypted','BackupRetentionPeriod']},
        'images':[{'tags':i.get('imageTags'),'digest':i['imageDigest']} for i in images],
    }
    evidence('deployment.json',result)
    print(json.dumps(result,indent=2))


def public_config():
    out=outputs()
    result={'api_url':out['api_url'],'region':REGION,'user_pool_id':out['user_pool_id'],'client_id':out['client_id'],
            'issuer':f"https://cognito-idp.{REGION}.amazonaws.com/{out['user_pool_id']}",
            'auth_flow':'USER_PASSWORD_AUTH','credentials':'Share the demo username/password privately; no IAM credentials are needed for this client auth flow.'}
    evidence('public-config.json',result)
    print(json.dumps(result,indent=2))


def pricing():
    queries = {
        'fargate_vcpu':('AmazonECS',{'usagetype':'APS1-Fargate-vCPU-Hours:perCPU'}),
        'fargate_gb':('AmazonECS',{'usagetype':'APS1-Fargate-GB-Hours'}),
        'http_api':('AmazonApiGateway',{'usagetype':'APS1-ApiGatewayHttpRequest'}),
        'endpoint_az_hour':('AmazonVPC',{'usagetype':'APS1-VpcEndpoint-Hours'}),
        'rds_multiaz':('AmazonRDS',{'instanceType':'db.t4g.medium','databaseEngine':'PostgreSQL','deploymentOption':'Multi-AZ'}),
        'alb_hour':('AWSELB',{'usagetype':'APS1-LoadBalancerUsage','operation':'LoadBalancing:Application'}),
    }
    result = {'checked_at_epoch':time.time(),'region':REGION,'catalog':{}}
    for label,(service,attributes) in queries.items():
        filters=[f'Type=TERM_MATCH,Field={key},Value={value}' for key,value in {'regionCode':REGION,**attributes}.items()]
        response=json.loads(run(['aws','pricing','get-products','--service-code',service,'--region','us-east-1','--filters',*filters,'--profile',PROFILE,'--output','json']))
        prices=[]
        for text in response.get('PriceList',[]):
            product=json.loads(text)
            for term in product.get('terms',{}).get('OnDemand',{}).values():
                for dim in term.get('priceDimensions',{}).values():
                    prices.append({'description':dim['description'],'unit':dim['unit'],'usd':dim['pricePerUnit']['USD'],'begin':dim.get('beginRange'),'end':dim.get('endRange')})
        result['catalog'][label]=prices
    evidence('pricing.json',result)
    print(json.dumps(result,indent=2))


def ci_evidence():
    build=json.loads((ROOT/'evidence'/'build-latest.json').read_text(encoding='utf-8'))
    info=aws('codebuild','batch-get-builds','--ids',build['id'])['builds'][0]
    logs=aws('logs','get-log-events','--log-group-name',info['logs']['groupName'],'--log-stream-name',info['logs']['streamName'],'--start-from-head')['events']
    lines=[e['message'].strip() for e in logs if re.search(r'ℹ\s+(tests|pass|fail|duration_ms)\s+',e['message']) or e['message'].startswith('✔')]
    combined='\n'.join(lines)
    counts={name:int(re.search(rf'ℹ\s+{name}\s+(\d+)',combined)[1]) for name in ['tests','pass','fail']}
    if info['buildStatus']!='SUCCEEDED' or counts['tests']!=counts['pass'] or counts['fail']!=0:
        raise RuntimeError('CI tests did not pass')
    result={'build_id':build['id'],'image_tag':build['image_tag'],'source_version':build['source_version'],'status':info['buildStatus'],
            'database_fixture':'isolated PostgreSQL 18 container inside CodeBuild','counts':counts,'test_output':lines,'checked_at_epoch':time.time()}
    evidence('correctness-tests.json',result)
    print(json.dumps(result,indent=2,ensure_ascii=True))



def infra_check():
    run(['terraform','fmt','-check'],ROOT/'infra')
    validation=json.loads(run(['terraform','validate','-json'],ROOT/'infra'))
    plan=subprocess.run(['terraform','plan','-input=false','-no-color','-detailed-exitcode'],cwd=ROOT/'infra',capture_output=True,text=True,encoding='utf-8')
    result={'checked_at_epoch':time.time(),'format_passed':True,'validation_valid':validation['valid'],
            'validation_errors':validation['error_count'],'validation_warnings':validation['warning_count'],
            'plan_exit_code':plan.returncode,'no_infrastructure_changes':plan.returncode==0,'plan_tail':plan.stdout[-1600:]}
    evidence('infrastructure-check.json',result)
    print(json.dumps(result,indent=2))
    if plan.returncode!=0 or not validation['valid']:
        raise RuntimeError('Infrastructure does not match configuration; inspect the saved check before changing resources')


def recovery(kind):
    out = outputs()
    token = tokens()[0]["token"]
    body = {"market":"BTC-USDT","side":"BUY","price":"1","quantity":"1"}
    key = str(uuid.uuid4())
    original = request('/v1/orders',token,'POST',body,key,202)
    request('/v1/balances',token)
    before = aws("rds","describe-db-instances","--db-instance-identifier",f"{PREFIX}-postgres")["DBInstances"][0]
    started = time.monotonic()
    if kind == "database":
        aws("rds","reboot-db-instance","--db-instance-identifier",f"{PREFIX}-postgres","--force-failover")
        trigger = {"database":f"{PREFIX}-postgres","force_failover":True,"original_az":before["AvailabilityZone"]}
        duration = 300
    elif kind == "task":
        tasks = aws("ecs","list-tasks","--cluster",out["cluster"],"--service-name",f"{PREFIX}-api")["taskArns"]
        if len(tasks)<2:
            raise RuntimeError("Need two healthy API tasks before replacement test")
        aws("ecs","stop-task","--cluster",out["cluster"],"--task",tasks[0],"--reason","dom7hc-practice isolated recovery verification")
        trigger = {"stopped_task":tasks[0]}
        duration = 75
    else:
        raise ValueError("Expected task or database")
    samples = []
    first_failure = last_failure = None
    consecutive_ok = 0
    while time.monotonic()-started < duration:
        elapsed = time.monotonic()-started
        try:
            request('/v1/balances',token)
            ok = True
            consecutive_ok += 1
        except Exception:
            ok = False
            consecutive_ok = 0
            first_failure = elapsed if first_failure is None else first_failure
            last_failure = elapsed
        samples.append({"elapsed_seconds":round(elapsed,3),"ok":ok})
        if kind == "database" and first_failure is not None and consecutive_ok>=10:
            break
        time.sleep(0.5)
    replay = request('/v1/orders',token,'POST',body,key,202)
    assert replay['id'] == original['id'], 'Recovery retry created a duplicate order'
    request(f"/v1/orders/{original['id']}",token,'DELETE',expected=202)
    after = aws("rds","describe-db-instances","--db-instance-identifier",f"{PREFIX}-postgres")["DBInstances"][0]
    result = {"kind":kind,"trigger":trigger,"samples":samples,"first_failed_probe_seconds":first_failure,"last_failed_probe_seconds":last_failure,
              "observed_failed_probe_span_seconds":None if first_failure is None else round(last_failure-first_failure,3),
              "final_db_az":after["AvailabilityZone"],"idempotent_replay_same_order":True,"interpretation":"Client probes include operator network; this is recovery evidence, not a steady-state regional latency test."}
    evidence(f"recovery-{kind}.json",result)
    print(json.dumps({k:v for k,v in result.items() if k!='samples'},indent=2))


def confirm_recovery():
    path=ROOT/'evidence'/'recovery-database.json'
    result=json.loads(path.read_text(encoding='utf-8'))
    db=aws('rds','describe-db-instances','--db-instance-identifier',f'{PREFIX}-postgres')['DBInstances'][0]
    events=aws('rds','describe-events','--source-identifier',f'{PREFIX}-postgres','--source-type','db-instance','--duration','60')['Events']
    result['confirmed_final_db_az']=db['AvailabilityZone']
    result['confirmed_final_db_status']=db['DBInstanceStatus']
    result['confirmed_at_epoch']=time.time()
    result['aws_failover_events']=[{'at':event['Date'],'message':event['Message']} for event in events]
    result['metadata_note']='The immediate post-probe AZ field can lag promotion. Confirmed fields and AWS events were collected after the database returned to available.'
    evidence(path.name,result)
    print(json.dumps({k:v for k,v in result.items() if k!='samples'},indent=2))


if __name__ == "__main__":
    try:
        command = sys.argv[1]
        if command != 'report' and aws('sts','get-caller-identity')['Account'] != ACCOUNT:
            raise RuntimeError('Unexpected AWS account; refusing this stack operation')
        if command == "build": build(sys.argv[2] if len(sys.argv)>2 else APP_IMAGE_TAG)
        elif command == "cloud-build": cloud_build(sys.argv[2] if len(sys.argv)>2 else APP_IMAGE_TAG)
        elif command == "cloud-build-load": cloud_build(load_only=True)
        elif command == "build-load": build(LOAD_IMAGE_TAG, load=True)
        elif command == "admin": admin(sys.argv[2])
        elif command == "load": load(int(sys.argv[2]) if len(sys.argv)>2 else 500, sys.argv[3] if len(sys.argv)>3 else "180s", sys.argv[4] if len(sys.argv)>4 else "mixed")
        elif command == "running": running(sys.argv[2] if len(sys.argv)>2 else APP_IMAGE_TAG)
        elif command == "recovery": recovery(sys.argv[2])
        elif command == "collect-load": collect_load(sys.argv[2])
        elif command == "collect-drain": collect_drain(sys.argv[2])
        elif command == 'terraform':
            result=subprocess.run(['terraform',*sys.argv[2:]],cwd=ROOT/'infra',stdin=sys.stdin,stdout=sys.stdout,stderr=sys.stderr)
            sys.exit(result.returncode)
        else: {"bootstrap": bootstrap, "initial-plan":initial_plan, "apply-initial":apply_initial, "seed-users": seed_users, "verify": verify, "prepare-live-demo":prepare_live_demo, "inventory": inventory, "public-config":public_config, "pricing": pricing, "ci-evidence": ci_evidence, "report": report, "confirm-recovery":confirm_recovery, "infra-check":infra_check, "outputs": lambda: print(json.dumps(outputs(), indent=2))}[command]()
    except Exception as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)
