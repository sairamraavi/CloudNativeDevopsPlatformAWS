# Cloud Native DevOps Platform AWS

A capstone project to build an automated AWS DevOps platform for **StreamingApp**, a microservices application with a frontend, authentication, streaming, administration, and real-time chat. The goal is to take application changes from source control through infrastructure provisioning, testing, container delivery, deployment, and operational monitoring.

## Architecture — start here

![StreamingApp architecture showing Jenkins CI/CD, AWS networking, EKS microservices, autoscaling, storage, monitoring, and security](Architecture/StreamingApp-Production-DevOps-Architecture.png)

[Open the full-size diagram](Architecture/StreamingApp-Production-DevOps-Architecture.png) · [Download the editable draw.io source](Architecture/StreamingApp-Production-DevOps-Architecture.drawio)

The design places the platform in AWS Region **`ap-south-1`**, with a **`10.0.0.0/16` VPC**, public and private subnets across two Availability Zones, and application workloads on Amazon EKS. Jenkins coordinates delivery, while the surrounding services provide infrastructure automation, storage, scaling, security, and observability.

**Read more:** [Architecture design, creation steps, and connection details](Docs/architecture.md). This guide explains how the diagram was created, documents all 55 connectors, and records the implementation approach and decisions still to confirm.

### How to read the diagram

- **Top and centre — application access:** users reach the application through the load-balancing and ingress design, which routes requests to the five services.
- **Left and bottom — delivery automation:** GitHub triggers Jenkins; Terraform and Ansible prepare infrastructure and hosts; Docker images are published to ECR and deployed to EKS.
- **Beside the workloads — scaling:** Metrics Server and per-service HPAs support pod scaling; the optional Cluster Autoscaler handles worker-capacity needs.
- **Right — operations and security:** Prometheus, Grafana, Alertmanager, and CloudWatch support visibility and notifications; IAM, secrets, encryption, and access controls protect the platform.
- **Below the workloads — data and recovery:** MongoDB Atlas stores application data, S3 stores media, and the recovery design includes database backups and S3 versioning/backup.

Some arrows describe logical or control relationships rather than literal network hops. The [connection explanations](Docs/architecture.md#4-connection-design-and-visual-conventions) clarify load balancer controller behaviour, ingress, scaling, and telemetry flows.

## What we are building

The platform is intended to make application delivery repeatable, observable, and controlled across development, staging, and production.

| Capability | Planned tools and approach |
| --- | --- |
| Infrastructure as code | Terraform for AWS networking, EKS, IAM, and supporting resources; an encrypted, versioned S3 state backend with locking |
| Host configuration | Ansible to configure Jenkins EC2 and supporting tools |
| Continuous integration and delivery | GitHub and Jenkins for checkout, dependency installation, tests, SonarQube analysis, provisioning, image publishing, deployment, and verification |
| Containers and orchestration | Docker images stored in Amazon ECR and application workloads deployed to Amazon EKS using Helm or manifests |
| Application routing | Application Load Balancer and Kubernetes ingress, with optional Route 53 and AWS WAF; controller ownership and routing configuration remain design decisions |
| Scaling | Metrics Server and Horizontal Pod Autoscalers, with optional Cluster Autoscaler for worker nodes |
| Data and media | MongoDB Atlas for application data and Amazon S3 for videos, thumbnails, and images |
| Monitoring and notifications | Prometheus, Grafana, Alertmanager, CloudWatch, and configured Slack/email notifications |
| Security and recovery | IAM, Secrets Manager, KMS, network controls, Kubernetes RBAC/Secrets, backups, and documented restore procedures |

### Application services

| Service | Stack shown in the architecture | Purpose |
| --- | --- | --- |
| Frontend | React + Nginx | User interface |
| Auth | Node.js, port `3001` | Authentication functions |
| Streaming | Node.js, port `3002` | Streaming functions and media access |
| Admin | Node.js, port `3003` | Administration functions |
| Chat | Node.js, port `3004`, Socket.IO | Real-time chat |

### Environment promotion

The planned release progression is **DEV → STAGING → PRODUCTION**.

| Environment | Namespace | Branch association |
| --- | --- | --- |
| DEV | `streaming-app-dev` | `feature/*` |
| STAGING | `streaming-app-stg` | `develop` |
| PRODUCTION | `streaming-app-prod` | `main`, with manual approval |

## Current progress

The first milestone is complete: the editable architecture diagram, image preview, and architecture documentation are available in this repository. Infrastructure provisioning, pipeline implementation, application deployment, and operational validation are planned next; the diagram is a design target, not evidence of a running production deployment.

Follow the [implementation sequence and evidence plan](Docs/architecture.md#6-proposed-implementation-order-and-evidence-log) to track the next stages of the capstone.

## Documentation and navigation

| Resource | What you will find |
| --- | --- |
| [Architecture folder](Architecture/) | Editable diagram and PNG preview |
| [Detailed architecture guide](Docs/architecture.md) | Design overview, diagram creation steps, connection approach, pipeline stages, and implementation plan |
| [Complete connection register](Docs/architecture.md#9-complete-connection-register) | Every connector and its intended meaning |
| [Design decisions to confirm](Docs/architecture.md#7-design-decisions-still-to-confirm) | Open choices to resolve before completing implementation |
| [Step-by-step setup guide](Docs/setup-process.md) | Ordered setup, verification, backup and teardown instructions |
