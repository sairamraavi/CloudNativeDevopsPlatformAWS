# Repeat the setup for dev, staging and production

Use this after you have the project's private inputs and a verified Jenkins/SonarQube backup. If this is your first installation and you have no backup, start with the [first-time guide](setup-process.md). The runner restores the existing Jenkins job, credentials and tunnel. A fresh clone cannot supply those private files.

## 1. Prepare the workstation

Open the repository root on the Mac. Use the account where you want to create **all three** environments. This can start three EKS control planes, worker groups, NAT gateways, load balancers and a Jenkins instance. Check your account quotas and available budget before deployment.

Install Python 3.9+, AWS CLI, Terraform, Helm 4, kubectl, Atlas CLI, Ansible, SSH, curl and shasum. If you will build missing images, start Docker with Buildx. Sign in to AWS and Atlas. Check the account number:

```bash
aws sts get-caller-identity --profile streamingapp --query Account --output text
python3 scripts/platform.py outline
```

## 2. Fill in one private configuration file

```bash
mkdir -p -m 700 "$HOME/.capstone-inputs"
cp -n scripts/platform.example.json "$HOME/.capstone-inputs/platform.json"
chmod 600 "$HOME/.capstone-inputs/platform.json"
```

Open that copy in an editor. Use the [example](../scripts/platform.example.json) for the exact field names.

| Fill in | Where to get it |
| --- | --- |
| Account, region, zones, admin role, current public IPv4 with /32, Ubuntu amd64 AMI | Your AWS account and [cluster preparation](03-cluster-and-application.md). Keep the Jenkins SSH key pair in ~/.ssh under the name streamingapp-capstone-jenkins. |
| State bucket | Use the existing bucket for that account. Only for a brand-new bootstrap, remove the state_bucket field and set new_account to true. |
| Cloudflare zone and three distinct hostnames | Your domain's Cloudflare settings. Export CLOUDFLARE_API_TOKEN privately with permission to manage DNS in that zone. For an existing traffic record, supply previous_cname only after verifying its old target. |
| Atlas project, application credentials and Grafana password for each environment | Create separate database users with access to their own database. Each application JSON file needs MONGO_URI and JWT_SECRET. Each Grafana file holds its password as plain text. Restrict the files to mode 600. Authenticate Atlas CLI with access-list permissions. |
| SMTP file, sender and recipient | Use the SES SMTP username and password for the deployment region. Store them under username and password in a private JSON file. Complete SES identity verification first. |
| Jenkins backup directory | Use the directory with four archives and SHA256SUMS from [chapter 6](06-backup-and-rebuild.md). Keep the webhook, tunnel and Access settings aligned with this backup. Pause incoming builds during setup. |
| Release tag and Fluent Bit chart version | Use an approved tag present in all five ECR repositories and the tested chart version. To build missing images, enable build_missing_images and set source_commit to the exact checked-out commit. Use a clean application tree and a fresh tag. |

## 3. Preview, then create the environments

```bash
python3 scripts/platform.py plan "$HOME/.capstone-inputs/platform.json"
```

Read the account and planned resources. On a new account some plans will be deferred until the previous step creates its outputs. When you are ready, run:

```bash
python3 scripts/platform.py up "$HOME/.capstone-inputs/platform.json"
```

The runner creates the state and retained resources, brings up dev and restores Jenkins, then provisions staging and production. In each cluster it connects secrets and Atlas, installs the controllers, deploys the app, connects DNS and sets up monitoring and email routing. Dev also gets application log forwarding, ALB access logs and Jenkins monitoring. A current secret version is preserved; changing a local file alone will not rotate an existing secret.

## 4. Check the result before accepting a release

The runner waits for five deployment rollouts and checks the public featured-video API in each environment. Open each hostname, sign in and play a video. Check upload, two-user chat, dashboards and an alert email. The workstation command provisions production; the regular Jenkins push workflow promotes through staging. The combined live setup and recovery drill still needs verification.

If a step fails, keep the same configuration, fix the reported dependency and rerun. Terraform state and Helm releases let the runner pick up existing resources. Keep the private metadata under ~/.capstone/ACCOUNT/REGION/platform. When you finish, follow [teardown and recovery](teardown-end-to-end.md).
