pipeline {
    agent any

    options {
        skipDefaultCheckout(true)
        disableConcurrentBuilds()
        timeout(time: 55, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '10'))
    }

    parameters {
        booleanParam(name: 'DEPLOY_TO_DEV', defaultValue: true,
            description: 'Deploy the images from this build to dev and verify the rollout. Clear to build, test, scan with SonarQube, and publish images only.')
    }

    triggers {
        githubPush()
    }

    environment {
        AWS_REGION = 'ap-south-1'
        AWS_DEFAULT_REGION = 'ap-south-1'
        AWS_PAGER = ''
        KUBECONFIG = '/var/lib/jenkins/.kube/config'
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
                sh 'git log -1 --format="%h %s"'
            }
        }

        stage('Install Dependencies and Run Tests') {
            steps {
                sh '''
                    set -eu

                    docker run --rm \
                    --mount "type=bind,source=$WORKSPACE/StreamingApp/backend/adminService,target=/source,readonly" \
                    --workdir /work \
                    node:24-alpine \
                    sh -ec '
                        cp /source/package.json /source/package-lock.json .
                        npm ci
                        cp -R /source/middleware /source/test .
                        npm test
                    '

                    docker run --rm \
                    --mount "type=bind,source=$WORKSPACE/StreamingApp/frontend,target=/source,readonly" \
                    --workdir /work \
                    --env CI=true \
                    node:24-alpine \
                    sh -ec '
                        cp /source/package.json /source/package-lock.json .
                        npm ci
                        cp -R /source/src /source/public .
                        npm test -- --watchAll=false --runInBand
                    '
                '''
            }
        }

        stage('SonarQube Analysis and Quality Gate') {
            steps {
                script {
                    def scannerHome = tool 'capstone-sonar-scanner'

                    withEnv(["SONAR_SCANNER_HOME=${scannerHome}"]) {
                        withSonarQubeEnv('capstone-sonarqube') {
                            sh '''
                                set +x
                                set -eu
                                export SONAR_TOKEN="$SONAR_AUTH_TOKEN"
                                "$SONAR_SCANNER_HOME/bin/sonar-scanner"
                            '''
                        }
                    }
                }
            }
        }

        stage('Verify Build Tools') {
            steps {
                sh '''
                    set -eu
                    git --version
                    docker version
                    docker buildx version
                    aws --version
                    terraform version
                    kubectl version --client
                    helm version --short
                '''
            }
        }

        stage('Verify AWS Identity') {
            steps {
                sh '''
                    set -eu
                    aws sts get-caller-identity \
                      --query '{Account:Account,Arn:Arn}' \
                      --output json

                    account="$(aws sts get-caller-identity \
                      --query Account --output text)"

                    configured_cluster="$(kubectl config view --context streamingapp-capstone-dev --minify -o jsonpath='{.contexts[0].context.cluster}')"
                    test "$configured_cluster" = "arn:aws:eks:$AWS_REGION:$account:cluster/streamingapp-capstone-dev-eks"
                '''
            }
        }

        stage('Verify Deployment Access') {
            steps {
                sh '''
                    set -eu
                    kubectl --context streamingapp-capstone-dev \
                      get deployments -n streaming-app-dev

                    kubectl --context streamingapp-capstone-dev \
                      auth can-i patch deployments \
                      -n streaming-app-dev
                '''
            }
        }

        stage('Prepare Image Version') {
            steps {
                script {
                    def commit = sh(
                        script: 'git rev-parse --short=12 HEAD',
                        returnStdout: true
                    ).trim()

                    env.IMAGE_TAG = "${commit}-${env.BUILD_NUMBER}"
                    def account = sh(script: 'aws sts get-caller-identity --query Account --output text', returnStdout: true).trim()
                    env.ECR_REGISTRY = "${account}.dkr.ecr.${env.AWS_REGION}.amazonaws.com"
                    env.APP_HOST = sh(script: "kubectl --context streamingapp-capstone-dev -n streaming-app-dev get ingress streamingapp -o jsonpath='{.spec.rules[0].host}'", returnStdout: true).trim()
                    if (!env.APP_HOST) { error('Missing streamingapp ingress hostname') }
                }
            }
        }

        stage('Build Docker Images') {
            steps {
                sh '''
                    set -eu

                    docker build --pull --platform linux/amd64 \
                    -t "$ECR_REGISTRY/streamingapp-capstone-auth:$IMAGE_TAG" \
                    StreamingApp/backend/authService

                    for service in streaming admin chat; do
                    docker build --pull --platform linux/amd64 \
                        -f "StreamingApp/backend/${service}Service/Dockerfile" \
                        -t "$ECR_REGISTRY/streamingapp-capstone-$service:$IMAGE_TAG" \
                        StreamingApp/backend
                    done

                    docker build --pull --platform linux/amd64 \
                    --build-arg REACT_APP_AUTH_API_URL=/api \
                    --build-arg REACT_APP_STREAMING_API_URL=/api \
                    --build-arg REACT_APP_ADMIN_API_URL=/api/admin \
                    --build-arg REACT_APP_CHAT_API_URL=/api/chat \
                    -t "$ECR_REGISTRY/streamingapp-capstone-frontend:$IMAGE_TAG" \
                    StreamingApp/frontend

                    docker run --rm \
                    "$ECR_REGISTRY/streamingapp-capstone-frontend:$IMAGE_TAG" \
                    nginx -t
                '''
            }
        }

        stage('Push Images to ECR') {
            steps {
                sh '''
                    set +x
                    set -eu

                    export DOCKER_CONFIG="$(mktemp -d)"
                    trap 'rm -rf "$DOCKER_CONFIG"' EXIT

                    aws ecr get-login-password --region "$AWS_REGION" |
                    docker login --username AWS --password-stdin "$ECR_REGISTRY"

                    for service in auth streaming admin chat frontend; do
                    docker push \
                        "$ECR_REGISTRY/streamingapp-capstone-$service:$IMAGE_TAG"

                    aws ecr describe-images \
                        --region "$AWS_REGION" \
                        --repository-name "streamingapp-capstone-$service" \
                        --image-ids "imageTag=$IMAGE_TAG" \
                        --query 'imageDetails[0].{Digest:imageDigest,Tags:imageTags}' \
                        --output json
                    done
                '''
            }
        }

        stage('Deploy to EKS') {
            when { expression { params.DEPLOY_TO_DEV } }
            steps {
                sh '''
                    set -eu

                    helm get values streamingapp --kube-context streamingapp-capstone-dev --namespace streaming-app-dev -o yaml |
                    helm lint helm/streamingapp -f - --set-string image.registry="$ECR_REGISTRY" --set-string image.tag="$IMAGE_TAG" --set-string frontend.tag="$IMAGE_TAG"

                    helm upgrade streamingapp helm/streamingapp \
                    --kube-context streamingapp-capstone-dev \
                    --namespace streaming-app-dev \
                    --reuse-values \
                    --set-string image.registry="$ECR_REGISTRY" \
                    --set-string image.tag="$IMAGE_TAG" \
                    --set-string frontend.tag="$IMAGE_TAG" \
                    --rollback-on-failure \
                    --wait \
                    --timeout 10m
                '''
            }
        }

        stage('Post-Deployment Verification') {
            when { expression { params.DEPLOY_TO_DEV } }
            steps {
                sh '''
                    set -eu

                    for service in auth streaming admin chat frontend; do
                    kubectl --context streamingapp-capstone-dev \
                        rollout status "deployment/$service" \
                        -n streaming-app-dev --timeout=180s

                    actual="$(kubectl --context streamingapp-capstone-dev \
                        get deployment "$service" -n streaming-app-dev \
                        -o jsonpath='{.spec.template.spec.containers[0].image}')"

                    expected="$ECR_REGISTRY/streamingapp-capstone-$service:$IMAGE_TAG"
                    test "$actual" = "$expected"
                    printf '%s: deployed %s\\n' "$service" "$actual"
                    done

                    status="$(curl --silent --show-error \
                    --max-time 30 --output /dev/null \
                    --write-out '%{http_code}' \
                    "https://$APP_HOST/")"

                    test "$status" = "200"

                    kubectl --context streamingapp-capstone-dev \
                    get deployments,pods,hpa -n streaming-app-dev
                '''
            }
        }
        stage('Promote to Staging') {
            when { expression { params.DEPLOY_TO_DEV } }
            steps {
                withEnv(["RELEASE_TAG=${env.IMAGE_TAG}"]) {
                    sh 'bash scripts/staging/promote.sh'
                }
            }
        }

    }
}
