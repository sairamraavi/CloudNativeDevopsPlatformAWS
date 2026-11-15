# StreamingApp | Production-oriented delivery platform on Amazon EKS

[GitHub repository](https://github.com/sairamraavi/CloudNativeDevopsPlatformAWS) · [Setup runbook](Docs/setup-process.md) · [Submission evidence and completion checklist](Docs/evidence-index.md)

StreamingApp is a five-service video platform with authenticated playback, administrative uploads and real-time chat. Its AWS architecture separates public traffic, private workloads, persistent data and the CI controller. The release workflow builds versioned artifacts once and promotes those artifacts across environment boundaries. This repository contains the platform implementation, the production rollout design, and the procedures for operating and retiring an environment.

## Objectives and implementation journey

| Milestone | Engineering decision and result |
| --- | --- |
| Design and source control | The architecture diagram and connector register preceded provisioning. PRs 1–3 integrated architecture, scaffolding and the sprint3-ansible work. Later delivery work used feature/capstone-end-to-end. Git history records integration order; sprint estimates and individual assignments are unavailable. |
| Local baseline | Compose brought up MongoDB, four APIs and the frontend. Tests covered nested-route refresh, service health, authentication and data persistence. Linux/amd64 builds matched the EKS worker architecture. |
| Provision AWS | Terraform separated bootstrap state, persistent ECR/media/secret/certificate resources and replaceable dev infrastructure. The personal-account deployment used a new state bucket, regional resources and rebuilt images. |
| Deploy and validate | Helm deployed five workloads behind HTTPS. Operators verified login, upload/playback, persistent chat and restricted admin APIs. Per-service CPU HPAs scaled application replicas. |
| Automate and observe | Ansible prepared the EC2 controller. The GitHub webhook, Jenkins, SonarQube, Docker, ECR and Helm delivered dev releases. Operators verified Prometheus targets, Grafana dashboards, SES alerts, CloudWatch logs and S3 access logs. |
| Recover and promote | Dev teardown and manual recovery were demonstrated. The pipeline subsequently gained automatic digest-pinned staging promotion. Staging build 17 reached Helm install and stopped on backend readiness. |

## Architecture and application

![AWS infrastructure, delivery path, workloads, telemetry and recovery design](Architecture/StreamingApp-Production-DevOps-Architecture.png)

The original diagram includes production design targets. In the implemented application path, Cloudflare DNS points to an internet-facing AWS ALB in Mumbai. ACM provides TLS. The Kubernetes controller configures the ALB, which sends requests to workloads on private EKS worker nodes across two zones. NAT provides outbound access to Atlas. Cloudflare Tunnel separately publishes the Jenkins and SonarQube origins on EC2. [Design register and editable diagram](Docs/architecture.md)

| Workload | Stack / container port | Responsibility |
| --- | --- | --- |
| Frontend | React built with Node, served by Nginx / 80 | Login, catalogue, player and administration UI |
| Auth | Node.js / 3001 | Registration, login and JWT issuance |
| Streaming | Node.js / 3002 | Catalogue, featured videos and media access |
| Admin | Node.js / 3003 | Privileged metadata changes and S3 media uploads |
| Chat | Node.js and Socket.IO / 3004 | Live conversation and persisted chat history |

![Application playback in the browser with the video playing and the chat panel open](Docs/screenshots/eks/21-video-playback-success.png)

## Delivery, security and operational acceptance

The Jenkins job reads the root Jenkinsfile from SCM. It builds a commit-plus-build-number tag, obtains its AWS identity from the instance profile, checks namespace permissions and verifies all five running image references. Dev verification precedes staging promotion. A successful GitHub webhook delivery, a successful dev rollout and a healthy staging application are three separately verifiable results. [Stage-by-stage delivery guide](Docs/delivery.md)

The application receives its JWT signing secret and Atlas URI through External Secrets. Workload roles scope media access, ECR retains release artifacts, and operator access uses account-specific state and EKS identities. Known security follow-ups include removing full URI startup logging and rescanning the actual deployed image digests. [Terraform and IAM](Terraform/README.md) · [Operational verification](Docs/operations.md)

Three encrypted monitoring volumes support Prometheus, Grafana and Alertmanager. Operators correlated a unique HTTP request with its CloudWatch event and checked ALB log objects separately in S3. A synthetic alert demonstrated email delivery and recovery. A recurring lesson was to test the last hop: a Ready secret can still contain an invalid database credential, and an active logging agent does not establish log delivery.

## Release progression and production acceptance

| Environment | Release policy and current milestone |
| --- | --- |
| Development | GitHub triggers tests, SonarQube analysis, image publication and deployment. Jenkins verifies five workload image references and the public HTTP response. |
| Staging | The same pipeline promotes the verified release by digest to a separate EKS cluster. The foundation and certificate are provisioned. Application acceptance is open after the last recorded Atlas authentication failure. |
| Production | Plan-only infrastructure configuration is available; production deployment is pending. Promote the staging-approved digests after explicit approval, using production-scoped deployment access, database credentials, media storage, certificate and DNS. Production rollout and rollback validation are upcoming milestones. |

**Production release criteria.** Record the commit, five image digests, scan findings and quality gate. Exercise login, upload, playback and two-client chat against staging data. Validate rollback to a known release, restore the database into an isolated target, and confirm alert delivery and log access. Before enabling production traffic, review replica placement and capacity for a zone loss, remove credential-bearing startup logging, and assign operators for approval, rollback and incident response. The two-zone network supports this design; application availability also depends on replicas, data connectivity and a tested recovery procedure.

## Repository map for reviewers

| Start here | What to inspect |
| --- | --- |
| [Terraform roots and modules](Terraform/) | [Bootstrap state](Terraform/bootstrap/), [retained data and registries](Terraform/persistent/), [dev](Terraform/environments/dev/), [staging](Terraform/environments/staging/), [staging data](Terraform/staging-data/) and the [production cluster configuration](Terraform/environments/prod/) and [production data configuration](Terraform/prod-data/). |
| [Jenkinsfile](Jenkinsfile) | SCM trigger, tests, scanner, platform checks, image tagging, ECR publish, Helm deploy and promotion. The [promotion script](scripts/staging/promote.sh) checks the five digests. |
| [Ansible controller playbook](Ansible/playbooks/jenkins.yml) | Host provisioning order and [roles](Ansible/roles/) for Java, Docker, Jenkins, AWS tooling, nginx, log collection and the tunnel. |
| [Application source](StreamingApp/) | [Frontend](StreamingApp/frontend/), [backend services and common code](StreamingApp/backend/) and [local Compose stack](StreamingApp/docker-compose.yml). |
| [Application chart](helm/streamingapp/) | [Values](helm/streamingapp/values.yaml) and [templates](helm/streamingapp/templates/) for service accounts, workloads, routing and autoscaling. The [secret chart](helm/application-secrets/) connects workloads to Secrets Manager. |
| [Observability](Monitoring/) | [Prometheus stack values](Monitoring/kube-prometheus-stack-values.yaml), [Grafana dashboards](Monitoring/dashboards/), [email routing](Monitoring/alertmanager-email.yaml) and [CloudWatch collectors](Monitoring/cloudwatch/). |
| [Operational scripts](scripts/) | [Dev lifecycle runner](scripts/dev-session.py), [host recovery](scripts/recover-dev-tools.sh), [staging prerequisites](scripts/staging/) and [validation fixtures](tests/). |

## Production configuration preview

The [production planning guide](scripts/prod/README.md) describes two isolated Terraform roots. The provisional baseline starts with two workers across two zones and per-zone NAT. Run the [plan-only script](scripts/prod/plan.sh) with `data` or `cluster` when the production inputs are available. These estimates require workload validation before rollout.

## When an environment is no longer needed

**Generate a preview before scheduling retirement.** From the repository root, with the environment's original inputs and backend selected, run `bash Terraform/teardown/plan.sh dev` or `bash Terraform/teardown/plan.sh staging`. The script saves a private destroy plan for review. See the [Terraform teardown plan and checklist](Terraform/teardown/README.md) for the optional tfvars argument, backup sequence, controller cleanup and post-teardown checks.

For recurring dev sessions, use the [checkpoint-aware lifecycle workflow](Docs/dev-lifecycle.md). Stopping Jenkins alone leaves EKS, NAT gateways and load balancers running. Preserve state, release images, media and required snapshots, and account for the shared Jenkins dependency before retiring dev while staging is in use. [Retained resources and cost checks](Docs/dev-cost-and-scope.md)

## Documentation index

| Guide | Contents |
| --- | --- |
| [Architecture](Docs/architecture.md) | Design history, components, network/control relationships |
| [Setup and command reference](Docs/setup-process.md) | Prerequisites and 29 ordered steps from workstation setup to dev recovery |
| [Terraform](Terraform/README.md) | Account isolation, root ownership, VPC, IAM and state |
| [Ansible](Ansible/README.md) | Inventory, Ubuntu host, roles and Jenkins service validation |
| [Application](StreamingApp/README.md) | Local stack, service settings, dependencies and smoke checks |
| [Delivery](Docs/delivery.md) | Docker/ECR, Jenkins stages, testing, SonarQube, webhook and staging |
| [Operations](Docs/operations.md) | EKS, Atlas, telemetry, acceptance and incident lessons |
| [Dev lifecycle](Docs/dev-lifecycle.md) | Checkpoint, shutdown, restore, backup contents and limitations |
| [Cost and scope](Docs/dev-cost-and-scope.md) | Destruction boundaries, retained resources and billing checks |
| [Evidence and submission status](Docs/evidence-index.md) | Historical screenshots, missing proof and next acceptance criteria |
| [Documentation validation](Docs/documentation-validation.md) | Scope, checks, security findings and evidence limitations |
