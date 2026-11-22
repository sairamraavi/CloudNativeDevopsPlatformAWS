# Cloud Native DevOps Platform on AWS | StreamingApp Capstone

**End-to-end DevOps engineering capstone:** a five-service streaming platform containerized with Docker, deployed to private Amazon EKS worker nodes using Terraform and Helm, released through Jenkins CI/CD, and operated with monitoring, security controls and recovery procedures.

[![AWS](https://img.shields.io/badge/Cloud-AWS%20ap--south--1-orange)](https://aws.amazon.com/eks/) [![Kubernetes](https://img.shields.io/badge/Orchestration-Amazon%20EKS-blue)](https://aws.amazon.com/eks/) [![IaC](https://img.shields.io/badge/IaC-Terraform-purple)](Terraform/) [![CI/CD](https://img.shields.io/badge/CI%2FCD-Jenkins-red)](Jenkinsfile) [![Documentation](https://img.shields.io/badge/Documentation-Runbooks-green)](Docs/setup-process.md)

**Project:** StreamingApp · **Region:** `ap-south-1` (Mumbai) · **Repository:** [CloudNativeDevopsPlatformAWS](https://github.com/sairamraavi/CloudNativeDevopsPlatformAWS) · **Implementation branch:** [`feature/capstone-end-to-end`](https://github.com/sairamraavi/CloudNativeDevopsPlatformAWS/tree/feature/capstone-end-to-end) · **Submission branch:** [`develop`](https://github.com/sairamraavi/CloudNativeDevopsPlatformAWS/tree/develop)

> **Verification scope:** Development deployment, functional application tests, Jenkins-driven releases, core monitoring and a development rebuild have historical evidence. Staging infrastructure and a promotion attempt were demonstrated, but staging acceptance remains blocked by backend database connectivity/readiness. A fully approved and verified production rollout, rollback and isolated database recovery drill are **not claimed**. Screenshot artifacts document multiple sessions and AWS accounts; they are not proof that the services are running now.

## Contents

- [Overview and objectives](#overview-and-objectives)
- [Architecture](#architecture)
- [Application services and technical stack](#application-services-and-technical-stack)
- [Implementation journey and evidence](#implementation-journey-and-evidence)
- [CI/CD and environment strategy](#cicd-and-environment-strategy)
- [Quick start and deployment](#quick-start-and-deployment)
- [Validation and operational checks](#validation-and-operational-checks)
- [Backup, recovery and cost management](#backup-recovery-and-cost-management)
- [Completed work and remaining verification](#completed-work-and-remaining-verification)
- [Documentation and repository map](#documentation-and-repository-map)

## Overview and objectives

This project takes a working video application from local development to a production-oriented AWS delivery platform. A viewer can register, sign in, browse and play uploaded videos, and exchange real-time chat messages. An administrator can upload media and manage content. The platform combines application delivery with infrastructure-as-code, least-privilege access, observability and environment lifecycle practices.

**Engineering goals:**

1. Package a React frontend and four Node.js APIs into reproducible containers.
2. Provision AWS networking, identity, persistent resources and EKS using Terraform with protected remote state.
3. Deploy the application through Helm behind an HTTPS Application Load Balancer; use MongoDB Atlas for records and S3 for media.
4. Automate unit tests, code-quality checks, image builds, ECR publishing and dev rollouts using GitHub and Jenkins.
5. Prove health, access controls, scaling, metrics, logs and alert delivery; document recovery and teardown.
6. Introduce reproducible staging/production foundations and promote image digests without rebuilding artifacts, while accurately recording incomplete acceptance checks.

## Architecture

![StreamingApp AWS platform architecture — delivery, network, EKS, security, telemetry and recovery](Architecture/StreamingApp-Production-DevOps-Architecture.png)

[View full-size architecture](Architecture/StreamingApp-Production-DevOps-Architecture.png) · [Editable draw.io diagram](Architecture/StreamingApp-Production-DevOps-Architecture.drawio) · [Detailed architecture and connector register](Docs/architecture.md)

**Request path:** Cloudflare DNS → internet-facing AWS Application Load Balancer with ACM TLS → Kubernetes Ingress → frontend and four backend workloads on private EKS workers in two Availability Zones. The AWS Load Balancer Controller manages the ALB configuration. Backend pods access MongoDB Atlas through NAT gateways; S3 stores video media. AWS Secrets Manager and External Secrets supply application secrets. IAM roles control workload access to AWS services.

**Delivery path:** Developer Git push → GitHub webhook → Jenkins on EC2 (exposed separately via Cloudflare Tunnel) → tests / SonarQube quality gate → five `linux/amd64` Docker builds → Amazon ECR → Helm on EKS → rollout and HTTP verification. A subsequent staging promotion resolves deployed image digests to identify exactly what is promoted.

**Operations path:** Metrics Server → HPAs for pod scaling; Cluster Autoscaler for node capacity; Prometheus → Grafana / Alertmanager → Amazon SES email; Fluent Bit and CloudWatch Agent → CloudWatch Logs; ALB access logs → S3. The drawing also contains production **design targets**, which should not be mistaken for completed deployments.

## Application services and technical stack

| Service | Technology / container port | Main responsibility |
| --- | --- | --- |
| Frontend | React built with Node.js, served by Nginx / `80` | Login, catalogue, video player and administrative UI |
| Auth | Node.js / `3001` | Registration, authentication and JWT issuance |
| Streaming | Node.js / `3002` | Video catalogue, featured videos and playback information |
| Admin | Node.js / `3003` | Restricted metadata management and S3 uploads |
| Chat | Node.js, Socket.IO / `3004` | Live messaging and persistent chat history |

| Layer | Implemented or documented technologies |
| --- | --- |
| Source and CI/CD | Git, GitHub, GitHub webhooks, Jenkins, SonarQube |
| Containers and deployment | Docker, Docker Compose, Amazon ECR, Helm, Kubernetes, Amazon EKS |
| Infrastructure and configuration | Terraform, S3 state backend with locking, Ansible, Amazon VPC, EC2, IAM |
| Routing and security | AWS ALB, AWS Load Balancer Controller, ACM, Cloudflare DNS/Tunnel, Secrets Manager, External Secrets, Kubernetes RBAC, workload IAM roles |
| Application data | MongoDB Atlas, Amazon S3 media storage |
| Visibility and scaling | Metrics Server, HPA, Cluster Autoscaler, Prometheus, Grafana, Alertmanager, SES, CloudWatch, Fluent Bit |
| Continuity | Versioned infrastructure resources, backup scripts, snapshots, verified dev recovery steps, controlled teardown |

## Implementation journey and evidence

Screenshots are embedded with standard GitHub Markdown so they render directly in the README when the referenced paths exist in the repository. See the [illustrated submission walkthrough](Docs/submission-walkthrough.md) for additional commands and evidence.

### 1. Application development and local Docker validation

Docker Compose runs MongoDB, the frontend and four APIs. Local acceptance covered login, nested-route refresh, service health and application persistence. Docker images were built for the target EKS worker architecture (`linux/amd64`).

![Docker Compose services running locally](Docs/screenshots/local-validation/01-containers-running.png)

![Successful application login in local environment](Docs/screenshots/local-validation/02-login-success.png)

**Reproduce:** [Local environment, AWS profile and container validation](Docs/01-local-and-account.md) · [Application code](StreamingApp/) · [Docker Compose](StreamingApp/docker-compose.yml)

#### Building and testing the application

Node.js builds the React frontend, and Nginx serves the finished site. Docker packages each backend API separately so Jenkins can tag and publish all five images from the same commit. Before release, the frontend tests check who can open a protected page, and the backend tests check who can perform an admin action.

![Frontend container built with Node.js 24](Docs/screenshots/local-validation/23-frontend-node24-build.png)

![Backend tests checking admin authorization](Docs/screenshots/eks/48-admin-authorization-tests-passed.png)

**Reproduce:** [Run the application locally](StreamingApp/README.md) · [Run the frontend tests](StreamingApp/frontend/README.md) · [Test and build stages](Jenkinsfile)

### 2. AWS foundation: Terraform remote state, persistent storage and images

The Terraform structure separates **bootstrap**, **persistent services** and **replaceable development infrastructure**, preventing routine dev teardown from accidentally removing registry images, media and state. AWS resources were recreated in a personal account after earlier development in a lab account.

![Terraform remote state verified](Docs/screenshots/local-validation/12-remote-state-verified.png)

![AWS VPC subnet and route overview](Docs/screenshots/local-validation/15-vpc-resource-map.png)

![Application images published to ECR](Docs/screenshots/local-validation/27-ecr-published-images.png)

**Reproduce:** [Remote state, Terraform, Atlas and ECR](Docs/02-terraform-and-images.md) · [Terraform roots](Terraform/README.md)

### 3. Amazon EKS application deployment and functional acceptance

Terraform provisioned VPC networking, private EKS workers across two zones and a Jenkins host. External Secrets synchronized the app secrets. Helm installed five services behind HTTPS. Functional checks covered registration/login, admin uploads, playback, two-user live chat, persisted chat history and rejected unauthorized admin requests.

![Admin video upload succeeded on the deployed application](Docs/screenshots/eks/20-admin-video-upload-success.png)

![Video playback succeeded](Docs/screenshots/eks/21-video-playback-success.png)

![Live chat between two users](Docs/screenshots/eks/22-live-chat-two-users.png)

**Reproduce:** [EKS, networking, IAM, secrets, Helm and DNS](Docs/03-cluster-and-application.md) · [Helm chart](helm/streamingapp/) · [Application verification](Docs/operations.md)

#### Cloudflare DNS and the application hostname

We added two DNS records at different points in the setup. First, we copied the validation CNAME from AWS Certificate Manager into Cloudflare so AWS could issue the HTTPS certificate. Later, when Kubernetes created the load balancer, we pointed the application hostname to its DNS name. After a rebuild, check the application record against the new load balancer and keep the certificate validation record for renewal.

![Cloudflare CNAME used to validate the ACM certificate](Docs/screenshots/security/03-cloudflare-acm-validation-cname.png)

![Cloudflare application CNAME pointing to the load balancer](Docs/screenshots/security/05-cloudflare-application-cname.png)

**Reproduce:** [Validate the certificate in step 6](Docs/02-terraform-and-images.md) · [Connect the website in step 14](Docs/03-cluster-and-application.md)

### 4. CI/CD automation and secure releases

Ansible provisioned the Jenkins EC2 tooling. A GitHub push triggered Jenkins; the pipeline ran application tests and SonarQube checks, published images to ECR, deployed to dev through Helm and checked the running release. Its specific stages and switches are defined by the version-controlled [`Jenkinsfile`](Jenkinsfile), rather than a fixed stage count in this README.

![GitHub webhook delivered successfully](Docs/screenshots/eks/60-github-webhook-delivery-success.png)

![Jenkins pipeline built, published and deployed application images](Docs/screenshots/eks/57-jenkins-build-push-deploy-success.png)

![Deployment image verification after Jenkins release](Docs/screenshots/eks/58-jenkins-deployed-image-verification.png)

**Reproduce:** [Jenkins, Ansible, webhook, quality gate and logging](Docs/05-jenkins-and-logs.md) · [Release trace](Docs/delivery.md) · [Ansible](Ansible/)

#### SonarQube code checks in Jenkins

We started SonarQube and its PostgreSQL database on the Jenkins host using Docker Compose. In SonarQube we created the project, then saved its analysis token as a Jenkins credential. During a build, the scanner submits the source code and Jenkins waits for the **quality gate**, SonarQube’s pass/fail result, before building the release images.

![StreamingApp project created in SonarQube](Docs/screenshots/eks/53-sonarqube-project-created.png)

![Jenkins received the SonarQube quality gate result](Docs/screenshots/eks/56-jenkins-sonarqube-quality-gate.png)

**Reproduce:** [Connect Jenkins and SonarQube in step 21](Docs/05-jenkins-and-logs.md) · [SonarQube Compose file](Monitoring/sonarqube/compose.yaml) · [Scanner settings](sonar-project.properties)

#### Cloudflare Tunnel for Jenkins and SonarQube

The tunnel connects the tools on EC2 to their public hostnames. On the host, Nginx forwards the Jenkins hostname to Jenkins and the SonarQube hostname to SonarQube. GitHub sends a push event to the Jenkins hostname at `/github-webhook/`. We checked both ends: the connector was running, and Jenkins recorded a build started by the push.

![Cloudflare Tunnel ready on the Jenkins host](Docs/screenshots/eks/59-jenkins-webhook-tunnel-ready.png)

![Jenkins build started by a GitHub push](Docs/screenshots/eks/61-jenkins-github-triggered-build.png)

**Reproduce:** [Configure the tunnel and webhook in step 23](Docs/05-jenkins-and-logs.md)

### 5. Scaling, monitoring, logs and alerts

Per-service HPAs support CPU-based scaling. Prometheus scrapes cluster/application metrics; Grafana dashboards expose resource and Jenkins activity. A controlled test alert reached email and generated a resolved notification. CloudWatch ingested application and Jenkins logs; ALB request logs were observed in S3.

![Frontend HPA scale-up evidence](Docs/screenshots/eks/26-frontend-hpa-scale-up.png)

![Grafana application resource dashboard](Docs/screenshots/eks/32-grafana-application-resource-dashboard.png)

![Resolved alert notification](Docs/screenshots/eks/38-outlook-alert-resolved.png)

**Reproduce:** [Autoscaling, monitoring, dashboards and alerts](Docs/04-monitoring.md) · [Operational validation and troubleshooting](Docs/operations.md)

#### Prometheus target checks and email delivery

After installing the monitoring stack with Helm, we opened **Status → Target health** in Prometheus to see which endpoints it could read. For Jenkins, we ran `up{job="jenkins"}`: a value of `1` means the latest scrape succeeded. Grafana uses those measurements for its Jenkins dashboard.

![Prometheus target health showing successful scrapes](Docs/screenshots/eks/34b-prometheus-target-health.png)

![Prometheus collecting metrics from Jenkins](Docs/screenshots/eks/64-prometheus-jenkins-target-up.png)

To check email delivery, we made the test rule fire, opened Alertmanager and checked that it selected the Outlook receiver. The resolved email shown above arrived after we returned the rule to its inactive setting.

![Alertmanager routed the firing test alert to the email receiver](Docs/screenshots/eks/36-alertmanager-test-alert.png)

**Reproduce:** [Install monitoring and test the alert](Docs/04-monitoring.md) · [Connect Jenkins metrics in step 24](Docs/05-jenkins-and-logs.md) · [Grafana dashboard definition](Monitoring/dashboards/jenkins-monitoring.json)

### 6. Teardown, backup and recovery

The dev lifecycle documents a private checkpoint of Jenkins, SonarQube and monitoring data, controlled removal of billable dev resources and recreation of the deployment. Historical evidence includes successful playback after rebuilding dev and restoration of Jenkins job history. This **does not** establish that an isolated MongoDB Atlas restore or a fully unattended end-to-end recovery test has passed.

![Playback succeeded after the development infrastructure was recreated](Docs/screenshots/eks/73-public-playback-after-recreation.png)

![Jenkins job restored after development rebuild](Docs/screenshots/eks/74-jenkins-job-restored.png)

**Reproduce:** [Backup and rebuild](Docs/06-backup-and-rebuild.md) · [Dev session lifecycle](Docs/dev-lifecycle.md) · [Full teardown](Docs/teardown-end-to-end.md)

## CI/CD and environment strategy

```text
GitHub push
    │
    ▼
Jenkins: checkout → tests → SonarQube quality gate → container builds
    │
    ▼
Amazon ECR: immutable image digests / traceable build tags
    │
    ▼
Development EKS: Helm deployment → rollout checks → application health
    │
    ▼
Staging: promote the same image digests → integration / acceptance checks
    │
    ▼
Production: authorized operator approves → Helm promotes staging-tested images → running image digests checked
```

| Environment | Kubernetes namespace | Documented state |
| --- | --- | --- |
| Development | `streaming-app-dev` | **Validated historically:** application, CI/CD, telemetry, alerts and recovery checks |
| Staging | `streaming-app-stg` | Verified deployment and HTTPS playback with build #22; build #23 passed staging before production approval. |
| Production | `streaming-app-prod` | Initial installation and playback verified with build #22. Build #23 completed the approval-gated production promotion. |

The original branch model associates `feature/*` with development, `develop` with staging and `main` with approved production releases. The documented Jenkins job, however, deploys dev and supports approved promotion through staging to production; the actual SCM branch and deployment switches must be checked in the configured Jenkins job. **Branch names alone do not automatically enforce an environment deployment.** See [release delivery and blockers](Docs/delivery.md).

## Staging deployment verified

After the earlier database login failure described above, Jenkins build **#22** promoted release `96a8a19cf9f4-22` to staging. All five services had a ready replica, and each ran the image digest selected for that release. The featured-video API returned HTTP 200. We also verified playback through `staging.sairamraavi.com` and confirmed admin access after signing in again.

![Successful Jenkins promotion of the release to staging](Docs/evidence/staging-02-release-promotion.png)

![Video playback on the staging HTTPS website](Docs/evidence/staging-03-https-playback.png)

### Staging evidences

![alt text](Docs/evidence/deployment/alb_s3_cloudwatch.png)
![alt text](Docs/evidence/deployment/api.png)
![alt text](Docs/evidence/deployment/app-admin-video.png)
![alt text](Docs/evidence/deployment/app-video_chat.png)
![alt text](Docs/evidence/deployment/application.png)
![alt text](Docs/evidence/deployment/cloudwatch.png)
![alt text](Docs/evidence/deployment/config1.png)
![alt text](Docs/evidence/deployment/ecr_alb_s3.png)
![alt text](Docs/evidence/deployment/ecr_alb.png)
![alt text](Docs/evidence/deployment/eks_cloudwatch.png)
![alt text](Docs/evidence/deployment/eks.png)

## Production installation and playback verified

Two EKS workers were Ready across the Mumbai availability zones. The first production Helm installation ran all five image digests from staging build **#22**. After registering a production user and granting the application admin role, we tested upload and playback on the production hostname.

![Production EKS workers ready in two availability zones](Docs/evidence/prod-01-eks-foundation.png)

![Video playback through the production HTTPS hostname](Docs/evidence/prod-03-https-playback.png)

### Production evidence 

![alt text](Docs/evidence/deployment/app-dashboard.png)
![alt text](Docs/evidence/deployment/app-profile.png)
![alt text](Docs/evidence/deployment/gateway_route_jenkins.png)
![alt text](Docs/evidence/deployment/helm.png)
![alt text](Docs/evidence/deployment/jenkins_ecr.png)
![alt text](Docs/evidence/deployment/jenkins_service.png)
![alt text](Docs/evidence/deployment/pod_alb_ebs_eks.png)
![alt text](Docs/evidence/deployment/secret-mgr_cloudwatch-log.png)
![alt text](Docs/evidence/deployment/subnet_route1.png)
![alt text](Docs/evidence/deployment/subnet_route2.png)
![alt text](Docs/evidence/deployment/subnet_route3.png)
![alt text](Docs/evidence/deployment/vpc_subnets_gateway.png)


#### Jenkins-approved production release

Build **#22** established the production release from the workstation. In build **#23**, Jenkins paused after staging and asked whether to promote release `cc27dd7fa32b-23`. The first screenshot shows **Promote** selected before the operator clicked **Proceed**.

![Build 23 awaiting operator approval to promote the staging-tested release to production](Docs/evidence/prod-04-jenkins-approved-popup-promotion.png)

After approval, the same build upgraded the existing production release. Jenkins shows **Success** for the production stage and a green result for build **#23**.

![Jenkins production approval stage succeeded and build 23 finished green](Docs/evidence/prod-04-jenkins-approved-promotion.png)

## Quick start and deployment

> **Prerequisites:** AWS account and correctly authenticated profile, AWS CLI, Docker / Compose, Terraform, kubectl, Helm, Ansible, Python, domain/Cloudflare access, MongoDB Atlas access and required private secrets. Cloud provisioning creates chargeable resources. Read the full instructions before applying or deleting infrastructure.

### A. Run the application locally

```bash
git clone https://github.com/sairamraavi/CloudNativeDevopsPlatformAWS.git
cd CloudNativeDevopsPlatformAWS
# Use the branch that contains the complete implementation and documentation.
git switch feature/capstone-end-to-end

test -f StreamingApp/.env || cp StreamingApp/.env.example StreamingApp/.env
# Set a private JWT_SECRET in StreamingApp/.env; do not commit it.
docker compose -f StreamingApp/docker-compose.yml config --quiet
docker compose -f StreamingApp/docker-compose.yml up -d --build
docker compose -f StreamingApp/docker-compose.yml ps
```

Open `http://localhost:3000` and test the login flow. Follow [Chapter 1](Docs/01-local-and-account.md) for service-by-service checks and AWS profile setup.

### B. Provision the cloud foundation safely

```bash
export AWS_PROFILE=streamingapp
export AWS_REGION=ap-south-1
export AWS_DEFAULT_REGION="$AWS_REGION"
export AWS_PAGER=''

# Authenticate with the method configured for this profile (AWS login or SSO).
aws sts get-caller-identity --profile "$AWS_PROFILE"
```

After verifying the **intended AWS account**, follow the [six-chapter setup guide](Docs/setup-process.md) in order. Do not copy a state backend, IAM ARN, cluster name, DNS target or NAT access-list entry from an older account/session. Chapter 2 explains first-time state creation versus reconnecting to an existing backend, and Chapter 3 covers EKS deployment and required Atlas access-list updates.

### C. Recreate dev, staging and production from a prepared private backup

The combined workflow is **not a zero-input, proven unattended deployment**. It needs a valid private configuration and existing Jenkins backup. Read [the full prerequisites and environment runner instructions](Docs/setup-dev-stage-prod.md) before executing:

```bash
python3 scripts/platform.py outline
python3 scripts/platform.py plan "$HOME/.capstone-inputs/platform.json"
# Only after reviewing the plan and confirming the cost / target account:
python3 scripts/platform.py up "$HOME/.capstone-inputs/platform.json"
```

**Important:** The `up` command can provision resources for **three EKS environments** and incur significant AWS and Atlas costs. Its full multi-environment live validation is still outstanding.

## Validation and operational checks

With `kubectl` configured for the appropriate **dev** cluster and the deployment still running:

```bash
kubectl --context streamingapp-capstone-dev -n streaming-app-dev get deployments,svc,ingress,hpa
kubectl --context streamingapp-capstone-dev -n streaming-app-dev rollout status deployment/frontend
kubectl --context streamingapp-capstone-dev get nodes -L topology.kubernetes.io/zone
kubectl --context streamingapp-capstone-dev top nodes
```

For application-level tests, open the configured HTTPS hostname and verify login, catalogue, admin upload, playback, chat in two browsers and denial of admin access without privilege. Verify release image tags/digests against the Jenkins build; check Prometheus targets and Grafana dashboards before claiming monitoring success. Full evidence, log tracing and troubleshooting: [Operations](Docs/operations.md) · [Evidence index](Docs/evidence-index.md).

## Backup, recovery and cost management

[Production rollback rehearsal](Docs/production-rollback.md) — check the running build, roll back five services and restore the original release.

Helm rolled all five production services back from build **#23** to **#22**, then restored **#23**. After each change, the deployment checks matched all five image digests and the public catalogue returned JSON.

![Production rollback to build 22 and recovery to build 23, with five ready deployments and a JSON catalogue response after each change](Docs/evidence/prod-05-rollback-and-recovery.png)

**Before teardown:** Stop builds/uploads, protect private Jenkins and SonarQube archives, verify `SHA256SUMS`, preserve required S3 objects / image digests and record the existing Terraform state backend. Backup archives and state files can contain secrets: **never commit them**.

```bash
# Development only: inspect/check the previously configured environment.
python3 scripts/dev-session.py configure
python3 scripts/dev-session.py check

# Preview an all-environment teardown; do not execute destructive actions casually.
python3 scripts/platform.py teardown-plan "$HOME/.capstone-inputs/platform.json"
```

Do **not** execute `down`, `terraform destroy` or the full platform retirement command until backups and the expected deletion scope have been reviewed. Development shutdown may leave persistent ECR, S3, remote state, Atlas and separate staging resources accruing charges. The full process and confirmation requirements are in [Dev lifecycle](Docs/dev-lifecycle.md), [End-to-end teardown](Docs/teardown-end-to-end.md) and [Costs and retained resources](Docs/dev-cost-and-scope.md).


## Documentation and repository map

The README provides the executive overview and evidence highlights; the linked guides preserve **step-by-step commands**, decisions and recovery procedures without making the main submission unreadably long.

| Read in order | Detailed guide | What it covers |
| --- | --- | --- |
| 1 | [Setup overview](Docs/setup-process.md) | Six-chapter end-to-end implementation route |
| 2 | [Local and account](Docs/01-local-and-account.md) | Tool versions, local Docker, AWS identity |
| 3 | [Terraform and images](Docs/02-terraform-and-images.md) | Bootstrap state, persistent resources, ECR, Atlas |
| 4 | [EKS and application](Docs/03-cluster-and-application.md) | Private networking, IAM, secrets, Helm, HTTPS |
| 5 | [Monitoring](Docs/04-monitoring.md) | HPA, Cluster Autoscaler, Prometheus/Grafana, SES |
| 6 | [Jenkins and logs](Docs/05-jenkins-and-logs.md) | Ansible, CI/CD, SonarQube, webhook, CloudWatch |
| 7 | [Backup and rebuild](Docs/06-backup-and-rebuild.md) | Checkpoints, teardown and recovery proof |
| — | [Illustrated walkthrough](Docs/submission-walkthrough.md) | Long-form, screenshot-led submission story and commands |
| — | [Architecture](Docs/architecture.md) | Data path, diagram and editable source |
| — | [Delivery](Docs/delivery.md) | Release trace, staging promotion and production prerequisites |
| — | [Operations](Docs/operations.md) | Runbook, checks, observed faults and mitigations |
| — | [Evidence index](Docs/evidence-index.md) | Selected evidence with embedded screenshots |
| — | [Documentation review](Docs/documentation-validation.md) | Checks completed, review scope and precautions before sharing |
| — | [Dev lifecycle](Docs/dev-lifecycle.md) | Checkpoint, dev down/up, recovery verification |
| — | [Cost and resource scope](Docs/dev-cost-and-scope.md) | Billable resources retained after dev teardown |
| — | [Multi-environment setup](Docs/setup-dev-stage-prod.md) | Prepared private-input automation across environments |
| — | [Full teardown](Docs/teardown-end-to-end.md) | Ordered retirement of production, staging, dev |

**Key repository paths:** [`StreamingApp/`](StreamingApp/) application and Compose · [`Terraform/`](Terraform/) infrastructure · [`Ansible/`](Ansible/) host configuration · [`helm/streamingapp/`](helm/streamingapp/) Kubernetes chart · [`Monitoring/`](Monitoring/) monitoring · [`scripts/`](scripts/) lifecycle and promotion tools · [`Jenkinsfile`](Jenkinsfile) delivery pipeline · [`Architecture/`](Architecture/) diagrams · [`Docs/screenshots/`](Docs/screenshots/) and [`Docs/evidence/`](Docs/evidence/) submission evidence.

### Evidence and privacy notes

Screenshots represent separate sessions and sometimes different AWS accounts, hosts and build numbers. Use each image as historical evidence of the stated test only. The files referenced above must exist in the repository at the indicated **case-sensitive relative paths** for GitHub to display them. Before publishing, inspect screenshots and Markdown for access tokens, passwords, account-specific identifiers, private database URLs, email contents and browser details; redact where appropriate. Do not commit `.env`, credentials, `*.tfstate`, backup archives, private Terraform plans or secret-bearing logs.

---

**Capstone outcome:** StreamingApp was deployed on EKS, tested in staging and promoted to production through an approved Jenkins release. The production release was rolled back and restored successfully. An isolated Atlas database restore remains pending.
