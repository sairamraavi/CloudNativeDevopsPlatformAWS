#!/usr/bin/env python3
"""Plan or set up the dev, staging and production platform from the workstation."""
import argparse
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import re
import runpy
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
ops = runpy.run_path(str(ROOT / "scripts/dev-session.py"))
run, aws, wait = (ops[n] for n in ("run", "aws", "wait_for"))
ENVS = ("dev", "staging", "prod")
DATA = {"dev": ("persistent", "persistent"), "staging": ("staging-data", "persistent/staging"),
        "prod": ("prod-data", "prod-data")}
NS = {"dev": "streaming-app-dev", "staging": "streaming-app-stg", "prod": "streaming-app-prod"}


def need(ok, msg):
    if not ok:
        raise ValueError(msg)


def private_file(name):
    path = Path(name).expanduser().resolve()
    need(path.is_file() and path.stat().st_mode & 0o077 == 0, f"Expected private file (chmod 600): {path}")
    return path


def inputs(c):
    need(re.fullmatch(r"[0-9]{12}", c["account"]), "Set the intended account ID")
    need(c["region"] == "ap-south-1", "Existing Jenkins and monitoring configurations target Mumbai")
    need(len(set(c["zones"])) == len(c["zones"]) == 2, "Supply two distinct availability zones")
    need(ipaddress.IPv4Network(c["admin_cidr"]).prefixlen == 32, "Supply an administrator IPv4 /32")
    need(len({c[e]["domain"] for e in ENVS}) == 3, "Use separate application hostnames")
    for e in ENVS:
        need(re.fullmatch(r"[a-z0-9.-]+\.[a-z]{2,}", c[e]["domain"]), f"Invalid {e} domain")
    need(re.fullmatch(r"[\w][\w.-]{0,127}", c["release_tag"], re.ASCII), "Invalid ECR release tag")


def tfstack(root, key, variables, apply, bucket, base, tmp, destroy=False):
    os.environ["TF_DATA_DIR"] = str(base / key / "cache")
    Path(os.environ["TF_DATA_DIR"]).mkdir(parents=True, exist_ok=True)
    tf = ["terraform", f"-chdir={root}"]
    run(*tf, "init", "-reconfigure", "-input=false", "-lockfile=readonly",
        f"-backend-config=bucket={bucket}", f"-backend-config=key={key}/terraform.tfstate",
        f"-backend-config=region={os.environ['AWS_REGION']}", "-backend-config=encrypt=true",
        "-backend-config=use_lockfile=true", capture=False)
    if destroy == "inspect":
        return {k:v["value"] for k,v in json.loads(run(*tf,"output","-json")).items()}
    return review(tf, variables, apply, tmp, destroy)


def review(tf, variables, apply, tmp, destroy=False):
    vf = tmp / "input.tfvars.json"
    vf.write_text(json.dumps(variables))
    plan = tmp / "current.tfplan"
    run(*tf, "plan", *(["-destroy"] if destroy else []), "-input=false", "-lock-timeout=60s", f"-var-file={vf}", f"-out={plan}", capture=False)
    changes = json.loads(run(*tf, "show", "-json", plan)).get("resource_changes", [])
    if destroy:
        need(all(set(r["change"]["actions"]) <= {"delete","read","no-op"} for r in changes),
             "Unexpected changes in retirement plan")
        if destroy == "retire":
            run(*tf, "apply", "-input=false", plan, capture=False)
            need(not run(*tf, "state", "list"), "Environment still has managed state")
            return {}
        need(not apply, "A teardown preview must never apply a plan")
        print("Reviewed destroy preview; no resources changed.")
        return {}
    need(not any("delete" in r["change"]["actions"] for r in changes),
         "Setup plan includes deletion/replacement. Inspect drift before proceeding.")
    if apply:
        run(*tf, "apply", "-input=false", plan, capture=False)
    return {k: v["value"] for k, v in json.loads(run(*tf, "output", "-json")).items()}


def bootstrap(c, base, common, tmp, apply):
    marker = base / "state-bucket"
    bucket = c.get("state_bucket") or (marker.read_text().strip() if marker.exists() else "")
    if not bucket:
        need(c.get("new_account") is True, "Supply the existing state bucket, or explicitly select new_account")
        local = base / "initial-bootstrap"
        local.mkdir(exist_ok=True)
        for f in (ROOT / "Terraform/bootstrap").glob("*.tf"):
            if f.name != "backend.tf":
                shutil.copyfile(f, local / f.name)
        shutil.copyfile(ROOT / "Terraform/bootstrap/.terraform.lock.hcl", local / ".terraform.lock.hcl")
        tf = ["terraform", f"-chdir={local}"]
        os.environ["TF_DATA_DIR"] = str(local / "cache")
        if not (local / "backend.tf").exists():
            run(*tf, "init", "-input=false", "-lockfile=readonly", capture=False)
            out = review(tf, common, apply, tmp)
            if not apply:
                return None
            bucket = out["terraform_state_bucket_name"]
            (local / "migration-bucket").write_text(bucket)
            shutil.copyfile(ROOT / "Terraform/bootstrap/backend.tf", local / "backend.tf")
        bucket = (local / "migration-bucket").read_text().strip()
        if not apply:
            return None
        run(*tf, "init", "-migrate-state", "-force-copy", f"-backend-config=bucket={bucket}",
            "-backend-config=key=bootstrap/terraform.tfstate", f"-backend-config=region={c['region']}",
            "-backend-config=encrypt=true", "-backend-config=use_lockfile=true", capture=False)
        marker.write_text(bucket)
    aws("s3api", "head-bucket", "--bucket", bucket, "--expected-bucket-owner", c["account"])
    aws("s3api", "head-object", "--bucket", bucket, "--key", "bootstrap/terraform.tfstate")
    out = tfstack(ROOT / "Terraform/bootstrap", "bootstrap", common, apply, bucket, base, tmp)
    need(out.get("terraform_state_bucket_name") == bucket, "Unexpected bootstrap state output")
    return bucket


def cname(zone, name, target, previous=None):
    name, target = name.rstrip("."), target.rstrip(".")
    found = ops["records"](zone, name)
    payload = dict(type="CNAME", name=name, content=target, ttl=60, proxied=False)
    if not found:
        ops["dns"]("POST", zone, payload=payload)
        return
    need(len(found) == 1 and found[0]["type"] == "CNAME", f"DNS ownership conflict: {name}")
    current = found[0]["content"].rstrip(".")
    if current != target:
        need(current == previous, f"Existing {name} points elsewhere. Verify and set previous_cname.")
        ops["dns"]("PUT", zone, "/" + found[0]["id"], payload)


def release(c, data):
    registry = data["repository_urls"]["auth"].split("/")[0]
    digests = {}
    for svc, repo in data["repository_names"].items():
        r = aws("ecr", "batch-get-image", "--repository-name", repo, "--image-ids", "imageTag="+c["release_tag"])
        if not r["images"]:
            need(c.get("build_missing_images") is True and
                 all(f["failureCode"] == "ImageNotFound" for f in r["failures"]),
                 f"Release missing in {repo}; publish the approved release first")
            need(run("git", "rev-parse", "HEAD") == c["source_commit"] and not run("git","status","--porcelain","--","StreamingApp"),
                 "Build inputs must match the approved source commit")
            with tempfile.TemporaryDirectory() as docker:
                login = ["docker", "--config", docker]
                run(*login, "login", "--username", "AWS", "--password-stdin", registry,
                    data=run("aws", "ecr", "get-login-password"), capture=False)
                path = Path("StreamingApp/frontend" if svc == "frontend" else f"StreamingApp/backend/{svc}Service")
                args = []
                if svc == "frontend":
                    for key, val in {"AUTH":"/api","STREAMING":"/api","ADMIN":"/api/admin","CHAT":"/api/chat"}.items():
                        args += ["--build-arg", f"REACT_APP_{key}_API_URL={val}"]
                run(*login, "buildx", "build", "--platform", "linux/amd64", "--push", *args,
                    "-t", data["repository_urls"][svc]+":"+c["release_tag"], "-f", path/"Dockerfile",
                    path if svc in ("frontend","auth") else path.parent, capture=False)
            r = aws("ecr","batch-get-image","--repository-name",repo,"--image-ids","imageTag="+c["release_tag"])
        digests[svc] = r["images"][0]["imageId"]["imageDigest"]
    return registry, digests


def workloads(c, e, d, o, registry, digests, tmp):
    settings, ns = c[e], NS[e]
    ctx = "streamingapp-capstone-"+e
    os.environ["KUBECONFIG"] = str(tmp / (e+".kubeconfig"))
    run("aws","eks","update-kubeconfig","--name",o["eks_cluster_name"],"--alias",ctx,
        "--role-arn",c["admin_role_arn"], capture=False)
    def k(*args, **kw):
        return run("kubectl","--context",ctx,*args,**kw)
    def install(name,chart,namespace,*args):
        run("helm","upgrade","--install",name,chart,"--kube-context",ctx,"-n",namespace,
            "--create-namespace","--wait","--timeout","12m",*args,capture=False)
    def obj(resource):
        k("apply","-f","-",data=json.dumps(resource))
    role_key = "eks\\.amazonaws\\.com/role-arn"
    sec = d[f"application_{e}_secret_name"]
    credentials = private_file(settings["application_json"])
    secret = json.loads(credentials.read_text())
    need(all(secret.get(key) for key in ("MONGO_URI","JWT_SECRET")), f"Missing {e} application keys")
    versions = aws("secretsmanager","list-secret-version-ids","--secret-id",sec)["Versions"]
    if not any("AWSCURRENT" in v.get("VersionStages",[]) for v in versions):
        run("aws","secretsmanager","put-secret-value","--secret-id",sec,"--secret-string","file://"+str(credentials))
    for rec in d["application_certificate_dns_records"]:
        cname(c["cloudflare_zone"],rec["name"],rec["value"])
    run("aws","acm","wait","certificate-validated","--certificate-arn",d["application_certificate_arn"])
    entries = ops["atlas_entries"](settings["atlas_project"])
    for ip in o["nat_public_ips"].values():
        if ip not in entries:
            ops["atlas"](settings["atlas_project"],"create",ip,"--type","ipAddress","--comment","Capstone "+e)
    install("external-secrets","external-secrets/external-secrets","external-secrets","--version","2.14.0")
    install("application-secrets","helm/application-secrets",ns,"--set-string","remoteSecretName="+sec,
            "--set-string","awsRegion="+c["region"],"--set-string","secretReader.roleArn="+o["secret_reader_role_arn"])
    k("-n",ns,"wait","--for=condition=Ready","externalsecret/streamingapp-application","--timeout=180s")
    install("aws-load-balancer-controller","eks/aws-load-balancer-controller","kube-system","--version","1.14.1",
            "--set-string","clusterName="+o["eks_cluster_name"],"--set-string","region="+c["region"],
            "--set-string","vpcId="+o["vpc_id"],"--set-string","serviceAccount.name=aws-load-balancer-controller",
            "--set-string","serviceAccount.annotations."+role_key+"="+o["load_balancer_controller_role_arn"])
    install("cluster-autoscaler","autoscaler/cluster-autoscaler","kube-system","--version","9.59.0",
            "-f","Monitoring/cluster-autoscaler-values.yaml","--set-string","autoDiscovery.clusterName="+o["eks_cluster_name"],
            "--set-string","rbac.serviceAccount.annotations."+role_key+"="+o["autoscaler_role_arn"])
    url = "https://"+settings["domain"]
    values = dict(image=dict(registry=registry,tag=c["release_tag"]),frontend=dict(tag=c["release_tag"],digest=digests["frontend"]),
                  services={s:dict(digest=h) for s,h in digests.items() if s!="frontend"},
                  ingress=dict(enabled=True,host=settings["domain"],certificateArn=d["application_certificate_arn"]),
                  app=dict(clientUrls=url,streamingPublicUrl=url,s3Bucket=d["media_bucket_name"],awsRegion=c["region"]))
    for s, arn in o["media_workload_role_arns"].items():
        values["services"][s]["roleArn"]=arn
    if e=="dev":
        # Existing Jenkins dev verification compares registry/repo:tag.
        for v in [values["frontend"],*values["services"].values()]:
            v.pop("digest")
        values["ingress"]["loadBalancerAttributes"]="idle_timeout.timeout_seconds=120,access_logs.s3.enabled=true,access_logs.s3.bucket="+d["alb_logs_bucket_name"]+",access_logs.s3.prefix=alb"
    if e=="staging":
        # Jenkins promotion supplies image digests itself.
        obj(dict(apiVersion="v1",kind="ConfigMap",metadata=dict(name="streamingapp-promotion-values",namespace=ns),
                 data={"values.json":json.dumps(values)}))
    vf=tmp/(e+".json")
    vf.write_text(json.dumps(values))
    install("streamingapp","helm/streamingapp",ns,"-f",vf)
    for svc in digests:
        k("-n",ns,"rollout","status","deployment/"+svc,"--timeout=3m")
    host=wait("ALB hostname",lambda:k("-n",ns,"get","ingress","streamingapp","-o","jsonpath={.status.loadBalancer.ingress[0].hostname}"))
    cname(c["cloudflare_zone"],settings["domain"],host,settings.get("previous_cname"))
    def healthy():
        result=subprocess.run(["curl","-fsS","--max-time","15",url+"/api/streaming/videos/featured"],capture_output=True)
        if result.returncode: return False
        try: return isinstance(json.loads(result.stdout), (dict,list))
        except ValueError: return False
    wait(e+" public catalogue JSON",healthy)
    k("apply","-f","Monitoring/storage/gp3-encrypted.yaml")
    obj(dict(apiVersion="v1",kind="Namespace",metadata=dict(name="monitoring")))
    obj(dict(apiVersion="v1",kind="Secret",metadata=dict(name="grafana-admin",namespace="monitoring"),
             stringData={"admin-user":"admin","admin-password":private_file(settings["grafana_password_file"]).read_text().strip()}))
    monitor = ["--version","92.16.1","-f","Monitoring/kube-prometheus-stack-values.yaml",
               "--set","alertmanager.alertmanagerSpec.alertmanagerConfiguration=null"]
    if e=="dev":
        monitor+=["--set-string","prometheus.prometheusSpec.additionalScrapeConfigs[0].static_configs[0].targets[0]="+o["jenkins_private_ip"]+":8082"]
    else:
        monitor+=["--set","prometheus.prometheusSpec.additionalScrapeConfigs=[]"]
    install("monitoring","prometheus-community/kube-prometheus-stack","monitoring",*monitor)
    smtp=json.loads(private_file(c["smtp_json"]).read_text())
    obj(dict(apiVersion="v1",kind="Secret",metadata=dict(name="alertmanager-ses-smtp",namespace="monitoring"),
             stringData={key:smtp[key] for key in ("username","password")}))
    template=Path("Monitoring/alertmanager-email.yaml").read_text()
    template=re.sub(r'(?m)^(\s*- to: ).*$',lambda m:m[1]+json.dumps(c["email_to"]),template)
    template=re.sub(r'(?m)^(\s*from: ).*$',lambda m:m[1]+json.dumps(c["email_from"]),template)
    k("-n","monitoring","apply","-f","-",data=template.replace('"__SES_SMTP_USERNAME__"',json.dumps(smtp["username"])))
    install("monitoring","prometheus-community/kube-prometheus-stack","monitoring","--version","92.16.1","--reuse-values",
            "--set-string","alertmanager.alertmanagerSpec.alertmanagerConfiguration.name=capstone-email")
    if e=="dev":
        dashboard = json.loads(Path("Monitoring/dashboards/jenkins-monitoring.json").read_text())
        obj(dict(apiVersion="v1",kind="ConfigMap",metadata=dict(name="jenkins-dashboard",namespace="monitoring",
                 labels={"grafana_dashboard":"1"}),data={"jenkins.json":json.dumps(dashboard)}))
        install("fluent-bit","fluent/fluent-bit","monitoring","--version",c["fluent_bit_version"],
                "-f","Monitoring/cloudwatch/fluent-bit-values.yaml","--set-string","serviceAccount.annotations."+role_key+"="+o["application_logs_role_arn"])


def retire_cluster(c, e, o, base, tmp):
    """Checkpoint monitoring disks before uninstalling releases in this environment."""
    ctx = "streamingapp-capstone-" + e
    ns = NS[e]
    os.environ["KUBECONFIG"] = str(tmp / (e + ".kubeconfig"))
    run("aws", "eks", "update-kubeconfig", "--name", o["eks_cluster_name"], "--alias", ctx,
        "--role-arn", c["admin_role_arn"])
    def k(*args):
        return run("kubectl", "--context", ctx, *args)
    def uninstall(name, namespace):
        run("helm", "uninstall", name, "-n", namespace, "--kube-context", ctx,
            "--ignore-not-found", "--wait", "--timeout", "10m", capture=False)

    journal = base / ("retire-" + o["vpc_id"] + ".json")
    if journal.exists():
        m = json.loads(journal.read_text())
    else:
        ing = json.loads(k("-n", ns, "get", "ingress", "streamingapp", "-o", "json"))
        host = ing["status"]["loadBalancer"]["ingress"][0]["hostname"]
        domain = c[e]["domain"]
        need(ing["spec"]["rules"][0]["host"] == domain, "Unexpected ingress hostname")
        records = ops["records"](c["cloudflare_zone"], domain)
        need(len(records) == 1 and records[0]["type"] == "CNAME" and records[0]["content"].rstrip(".") == host,
             "Unexpected traffic DNS record")
        pvs = json.loads(k("get", "pv", "-o", "json"))["items"]
        disks = {}
        for pv in pvs:
            spec = pv["spec"]
            claim = spec.get("claimRef", {})
            need(claim.get("namespace") == "monitoring" and spec["storageClassName"] == "capstone-gp3-encrypted"
                 and spec["persistentVolumeReclaimPolicy"] == "Delete" and spec["csi"]["driver"] == "ebs.csi.aws.com",
                 "Unexpected persistent volume; review its owner before retirement")
            disks[claim["name"]] = spec["csi"]["volumeHandle"]
        need(len(disks) == 3, "Expected the three monitoring claims")
        m = dict(host=host, domain=domain, dns_id=records[0]["id"], volumes=disks, snapshots={})
        ops["save"](journal, m)
    for pv in json.loads(k("get","pv","-o","json"))["items"]:
        spec=pv["spec"]
        ref=spec.get("claimRef",{})
        volume=spec.get("csi",{}).get("volumeHandle")
        need(ref.get("namespace")=="monitoring" and volume and m["volumes"].get(ref.get("name"))==volume,
             "Volume ownership changed since capture; review before retirement")
    observed=k("-n",ns,"get","ingress","streamingapp","--ignore-not-found","-o","json")
    if observed:
        current=json.loads(observed)
        need(current["spec"]["rules"][0]["host"]==m["domain"] and
             current["status"]["loadBalancer"]["ingress"][0]["hostname"]==m["host"],"Ingress changed since capture")
    for claim, vol in m["volumes"].items():
        if claim not in m["snapshots"]:
            snap = aws("ec2", "create-snapshot", "--volume-id", vol, "--description", f"Capstone {e} {claim}")
            m["snapshots"][claim] = snap["SnapshotId"]
            ops["save"](journal, m)
    run("aws", "ec2", "wait", "snapshot-completed", "--snapshot-ids", *m["snapshots"].values())
    foreign = [lb for lb in ops["vpc_lbs"](o["vpc_id"]) if lb["DNSName"] != m["host"]]
    need(not foreign, "Unexpected load balancer in environment VPC")
    uninstall("streamingapp", ns)
    wait("ALB deletion", lambda: not ops["vpc_lbs"](o["vpc_id"]))
    uninstall("monitoring", "monitoring")
    for claim in m["volumes"]:
        k("-n","monitoring","delete","pvc",claim,"--ignore-not-found","--timeout=5m")
    wait("EBS deletion", lambda: not aws("ec2","describe-volumes","--filters",
         "Name=volume-id,Values="+",".join(m["volumes"].values()))["Volumes"])
    records = ops["records"](c["cloudflare_zone"], m["domain"])
    if records:
        need(len(records)==1 and records[0]["id"]==m["dns_id"] and records[0]["content"].rstrip(".")==m["host"],
             "DNS changed since checkpoint")
        ops["dns"]("DELETE", c["cloudflare_zone"], "/" + m["dns_id"])
    project = c[e]["atlas_project"]
    entries = ops["atlas_entries"](project)
    for ip in o["nat_public_ips"].values():
        if ip in entries:
            ops["atlas"](project, "delete", entries[ip].get("ipAddress") or entries[ip]["cidrBlock"], "--force")
    m["cleanup_complete"] = True
    ops["save"](journal, m)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action",choices=("outline","plan","up","teardown-plan","down"))
    parser.add_argument("config",nargs="?")
    parser.add_argument("--confirm-retire", metavar="ACCOUNT", help="For down: confirm retirement of prod, staging and dev in this account")
    args=parser.parse_args()
    if args.action=="outline":
        print("Bootstrap → persistent data → dev EKS + Jenkins + shared images → staging → prod.\n"
              "Each cluster: secrets → controllers → app → HTTPS → monitoring. Dev also restores CI tools and installs Fluent Bit.")
        return
    need(args.config,"Supply the private setup JSON path")
    c=json.loads(private_file(args.config).read_text())
    inputs(c)
    os.chdir(ROOT)
    os.umask(0o077)
    os.environ.update(AWS_PROFILE=c["profile"],AWS_REGION=c["region"],AWS_DEFAULT_REGION=c["region"],AWS_PAGER="",TF_WORKSPACE="default")
    apply=args.action=="up"
    retiring=args.action=="down"
    preview=args.action=="teardown-plan"
    if retiring:
        need(args.confirm_retire==c["account"], "down requires --confirm-retire with the configured account")
        need(os.environ.get("CLOUDFLARE_API_TOKEN"), "Export CLOUDFLARE_API_TOKEN")
    need(aws("sts","get-caller-identity")["Account"]==c["account"],"Profile/account mismatch")
    base=Path.home()/".capstone"/c["account"]/c["region"]/"platform"
    base.mkdir(parents=True,exist_ok=True)
    lock=(base/"operator.lock").open("a")
    fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    common=dict(expected_account_id=c["account"],aws_region=c["region"])
    if apply:
        need(ops["SSH_KEY"].is_file() and Path(str(ops["SSH_KEY"])+".pub").is_file(), "Missing Jenkins SSH key pair")
        need(c.get("fluent_bit_version") and c.get("email_from") and c.get("email_to"), "Supply the chart version and SES identities")
        if c.get("build_missing_images"):
            need(shutil.which("docker") and c.get("source_commit"), "Supply Docker and source_commit to build missing images")
        for tool in ("helm","kubectl","atlas","ansible","ansible-playbook","curl","shasum"):
            need(shutil.which(tool),f"Install {tool}")
        need(os.environ.get("CLOUDFLARE_API_TOKEN"),"Export CLOUDFLARE_API_TOKEN")
        for e in ENVS:
            secret=json.loads(private_file(c[e]["application_json"]).read_text())
            need(all(secret.get(key) for key in ("JWT_SECRET","MONGO_URI")),f"Incomplete application secret: {e}")
            need(private_file(c[e]["grafana_password_file"]).read_text().strip(),f"Missing Grafana password: {e}")
        smtp=json.loads(private_file(c["smtp_json"]).read_text())
        need(smtp.get("username") and smtp.get("password"),"Incomplete SMTP credentials")
        backup=Path(c["jenkins_backup"]).expanduser().resolve()
        for name in ("SHA256SUMS","jenkins-home.tar.gz","sonarqube.dump","sonarqube-extensions.tar.gz","host-private-config.tar.gz"):
            need((backup/name).is_file() and (backup/name).stat().st_size>0, f"Missing backup file: {name}")
        subprocess.run(["shasum","-a","256","-c","SHA256SUMS"],cwd=backup,check=True)
        for e in ENVS:
            ops["records"](c["cloudflare_zone"],c[e]["domain"])
            ops["atlas_entries"](c[e]["atlas_project"])
        for name,url in ops["REPOS"].items():
            run("helm","repo","add",name,url,"--force-update")
    with tempfile.TemporaryDirectory(dir=base) as temp:
        tmp=Path(temp)
        bucket=bootstrap(c,base,common,tmp,apply)
        if not bucket:
            print("Dependent plans deferred until the state bucket exists.")
            return
        dev_ready = False
        for e in (reversed(ENVS) if retiring or preview else ENVS):
            name,key=DATA[e]
            data_inputs=dict(common,application_domain=c[e]["domain"])
            if e=="dev": data_inputs["media_allowed_origins"]=["https://"+c[e]["domain"]]
            d=tfstack(ROOT/"Terraform"/name,key,data_inputs,apply,bucket,base,tmp, destroy="inspect" if retiring or preview else False)
            if not d.get("media_bucket_arn"):
                need(not retiring and not preview, "Missing retained data outputs for "+e)
                print(e+": cluster plan deferred until data outputs exist")
                continue
            variables=dict(common,availability_zones=c["zones"],eks_admin_role_arn=c["admin_role_arn"],
                           eks_public_access_cidrs=[c["admin_cidr"]],nat_mode="per_az",
                           media_bucket_arn=d["media_bucket_arn"],application_secret_arn=d[f"application_{e}_secret_arn"])
            if e=="dev":
                variables.update(jenkins_public_key_path=str(ops["SSH_KEY"])+".pub",jenkins_admin_cidr=c["admin_cidr"],jenkins_ami_id=c["jenkins_ami"])
            if e=="staging" and not apply and args.action == "plan" and not dev_ready:
                print("Staging cluster plan deferred until the dev Jenkins host exists.")
                continue
            if retiring:
                env_root=ROOT/"Terraform/environments"/e
                key="environments/"+e
                current=tfstack(env_root,key,variables,False,bucket,base,tmp,destroy="inspect")
                if not current:
                    need(not run("terraform",f"-chdir={env_root}","state","list"), "Partial state requires operator review")
                    continue
                if e=="dev":
                    os.environ.update(CAPSTONE_PLATFORM_CACHE=str(base), CAPSTONE_EKS_ADMIN_ROLE_ARN=c["admin_role_arn"],
                                      CLOUDFLARE_ZONE_ID=c["cloudflare_zone"], ATLAS_PROJECT_ID=c["dev"]["atlas_project"])
                    run(sys.executable,"scripts/dev-session.py","down","--yes",capture=False)
                else:
                    journal=base/("retire-"+current["vpc_id"]+".json")
                    if not (journal.exists() and json.loads(journal.read_text()).get("cleanup_complete")):
                        retire_cluster(c,e,current,base,tmp)
                    tfstack(env_root,key,variables,False,bucket,base,tmp,destroy="retire")
                continue
            o=tfstack(ROOT/"Terraform/environments"/e,"environments/"+e,variables,apply,bucket,base,tmp, destroy=args.action=="teardown-plan")
            if e=="dev": dev_ready=bool(o.get("jenkins_instance_id"))
            if not apply: continue
            if e=="dev":
                registry,digests=release(c,d)
                ops["verify_ssh"](o,tmp)
                run("bash","scripts/recover-dev-tools.sh",backup,capture=False)
            workloads(c,e,d,o,registry,digests,tmp)
        print("Environment retirement complete; persistent data retained." if retiring else "Setup and catalogue checks completed." if apply else "Plan pass complete. No infrastructure applied.")


if __name__=="__main__":
    try: main()
    except (ValueError,KeyError,OSError,subprocess.CalledProcessError) as err:
        sys.exit(f"Stopped: {err}")
