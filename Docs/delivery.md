# How a commit becomes a running release

**Dev delivery — implemented and verified. Staging delivery — partially implemented.** The same application pipeline builds five images once, verifies the release in dev, then uses their ECR digests in a separate staging cluster. A Git branch selects the Jenkinsfile revision; the deployment target is selected by pipeline configuration. A branch named staging does not provision a cluster.

## Operator prerequisites

On the workstation complete [setup steps 8–14 and 19–24](setup-process.md): publish the initial images, install the dev Helm release, configure the EC2 controller, set up the SCM job and provision its kubeconfig. Jenkins requires the Docker socket, scoped instance profile, a working SonarQube project and the scanner tool. On EC2, nginx forwards the GitHub POST to Jenkins; Cloudflare Tunnel publishes that origin. Verify both GitHub delivery success and a build whose cause is a push. A manually successful job demonstrates only the downstream pipeline.

![Jenkins build triggered by a GitHub push](screenshots/eks/61-jenkins-github-triggered-build.png)

## Build and release specification

Every command and its environment are in the [root Jenkinsfile](../Jenkinsfile). The rows below follow execution order. Commands run on the Jenkins agent in its checked-out workspace. AWS credentials come from the instance profile. KUBECONFIG points to the Jenkins user's dev configuration. The job serializes builds, keeps ten and has a 55-minute timeout.

| Stage | Operation and acceptance condition |
| --- | --- |
| Checkout | Check out SCM, then record the commit with `git log -1 --format="%h %s"`. |
| Install Dependencies and Run Tests | Mount sources read-only in two temporary Node 24 containers. Copy lockfiles and sources under /work, run npm ci and execute admin middleware tests and frontend route tests (Jest runInBand, watch disabled). Historical results were six backend and seven frontend tests passing. |
| SonarQube Analysis and Quality Gate | Run the configured capstone-sonar-scanner through the capstone-sonarqube server binding. The [scanner properties](../sonar-project.properties) specify source and test scopes and wait up to 300 seconds for the gate. Keep analysis tokens in Jenkins Secret Text credentials. |
| Verify Build Tools | Check Git, Docker, Buildx, AWS CLI, Terraform, kubectl and Helm versions. This stage checks availability; infrastructure provisioning happens separately. |
| Verify AWS Identity | Compare the STS account and region with the cluster ARN in the dev kubeconfig. |
| Verify Deployment Access | List dev deployments and check permission to patch them in streaming-app-dev. Historical negative test: the controller could not delete cluster nodes. |
| Prepare Image Version | Combine the 12-character Git commit with BUILD_NUMBER. Derive ECR_REGISTRY from STS and region, and APP_HOST from the dev Ingress. |
| Build Docker Images | Build linux/amd64 with --pull. Auth uses its service directory; streaming, admin and chat use the backend context to include common code. React builds against same-origin API paths; Nginx serves the output. Run nginx -t inside the frontend image. |
| Push Images to ECR | Authenticate using get-login-password piped to docker login --password-stdin and a temporary Docker config. Push all five immutable tags, then describe each image. |
| Deploy to EKS | With DEPLOY_TO_DEV enabled, lint with current values, then run helm upgrade against the existing dev release with the new image tag, --reuse-values, --rollback-on-failure and --wait. |
| Post-Deployment Verification | Wait for each rollout, compare the deployed image with the release tag, require HTTP 200 from the public dev root and list deployments, pods and HPAs. |
| Promote to Staging | After verified dev deployment, pass IMAGE_TAG as RELEASE_TAG to the [promotion script](../scripts/staging/promote.sh). The active job automatically promotes; clearing DEPLOY_TO_DEV skips deployment stages. |

![Historical dev build, push, deploy and verification stages](screenshots/eks/57-jenkins-build-push-deploy-success.png)

ECR scanning is a separate release inspection. With Buildx, a tag can identify an OCI index that also contains an attestation. Use the Linux amd64 child digest when querying scan findings, as shown in setup step 8. A past frontend scan had six critical findings; a later scan of a different image reported one. A successful push or SonarQube gate cannot establish a clean container scan.

## Staging bootstrap and first rollout

The workstation must already have the staging-data and staging Terraform backends initialized, a separate Atlas database user and secret, an issued certificate, and the ALB controller. Use the personal account's streamingapp profile in Mumbai. These are **operator procedures**, not new executions:

| Where and command (repository root) | Effect and expected result |
| --- | --- |
| Mac: `bash scripts/staging/verify-foundation.sh` | Refreshes local kubeconfig; reads EKS status, Ready nodes in two zones and six managed add-ons. |
| Mac: `bash scripts/staging/sync-application-secret.sh` | Changes Helm releases on staging. Installs External Secrets and explicitly targets the staging remote secret. Waits for SecretStore and ExternalSecret Ready and prints key names only. |
| Mac: `bash scripts/staging/prepare-promotion.sh` | Reuses saved foundation inputs, plans and applies scoped Jenkins access and prepares Helm values in a staging ConfigMap. Verify the target account and saved workloads plan before running. |
| Jenkins: `bash scripts/staging/promote.sh` | Requires AWS_REGION and RELEASE_TAG. Creates a temporary kubeconfig, checks required secret keys, checks dev rollouts and tag matches, resolves ECR digests, and performs helm upgrade --install in streaming-app-stg. Then verifies all five image references. |

Build 17 reached staging Helm install; four backends failed readiness. The [incident record](operations.md) explains why secret synchronization and a healthy frontend were insufficient to certify staging. The separate [staging job definition](../Jenkinsfile.staging) is in Git; build 17 ran the root job.
