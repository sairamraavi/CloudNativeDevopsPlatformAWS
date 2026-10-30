pipeline {
    agent any

    triggers {
        pollSCM('H/5 * * * *')
    }

    options {
        timestamps()
        disableConcurrentBuilds()
        timeout(time: 60, unit: 'MINUTES')
    }

    environment {
        AWS_REGION       = 'ap-south-1'
        AWS_ACCOUNT_ID   = '706016980205'
        ECR_REGISTRY     = '706016980205.dkr.ecr.ap-south-1.amazonaws.com'
        EKS_CLUSTER_NAME = 'streamingapp-capstone-dev-eks'
        K8S_NAMESPACE    = 'streamingapp'
        HELM_RELEASE     = 'streamingapp'
        CHART_PATH       = 'helm/streamingapp'
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
                script {
                    env.IMAGE_TAG = sh(
                        script: 'git rev-parse --short=12 HEAD',
                        returnStdout: true
                    ).trim()
                }
                echo "Building application commit: ${IMAGE_TAG}"
            }
        }

        stage('Configure AWS and EKS') {
            steps {
                sh '''
                    set -eu
                    aws sts get-caller-identity
                    aws eks update-kubeconfig \
                      --region "$AWS_REGION" \
                      --name "$EKS_CLUSTER_NAME"
                    kubectl get nodes
                '''
            }
        }

        stage('Install NGINX Ingress') {
            steps {
                sh '''
                    set -eu
                    helm repo add ingress-nginx \
                      https://kubernetes.github.io/ingress-nginx
                    helm repo update
                    helm upgrade --install ingress-nginx \
                      ingress-nginx/ingress-nginx \
                      --namespace ingress-nginx \
                      --create-namespace \
                      --set controller.service.type=LoadBalancer \
                      --set-string 'controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-type=nlb' \
                      --set-string 'controller.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-scheme=internet-facing' \
                      --wait \
                      --timeout 10m
                '''

                script {
                    env.LB_HOST = sh(
                        script: '''
                            set -eu
                            for attempt in $(seq 1 60); do
                              HOST=$(kubectl get service ingress-nginx-controller \
                                -n ingress-nginx \
                                -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' \
                                2>/dev/null || true)
                              if [ -n "$HOST" ]; then
                                echo "$HOST"
                                exit 0
                              fi
                              sleep 10
                            done
                            echo "Ingress load balancer hostname was not assigned" >&2
                            exit 1
                        ''',
                        returnStdout: true
                    ).trim()

                    env.APP_URL = "http://${env.LB_HOST}"
                    echo "Application URL: ${env.APP_URL}"
                }
            }
        }

        stage('Build Docker Images') {
            steps {
                sh '''
                    set -eu
                    docker build \
                      -t "$ECR_REGISTRY/streamingapp-capstone-frontend:$IMAGE_TAG" \
                      --build-arg REACT_APP_AUTH_API_URL=/api \
                      --build-arg REACT_APP_STREAMING_API_URL=/api \
                      --build-arg REACT_APP_STREAMING_PUBLIC_URL="$APP_URL" \
                      --build-arg REACT_APP_ADMIN_API_URL=/api/admin \
                      --build-arg REACT_APP_CHAT_API_URL=/api/chat \
                      --build-arg REACT_APP_CHAT_SOCKET_URL="$APP_URL" \
                      StreamingApp/frontend

                    docker build \
                      -t "$ECR_REGISTRY/streamingapp-capstone-auth:$IMAGE_TAG" \
                      -f StreamingApp/backend/authService/Dockerfile \
                      StreamingApp/backend/authService

                    docker build \
                      -t "$ECR_REGISTRY/streamingapp-capstone-streaming:$IMAGE_TAG" \
                      -f StreamingApp/backend/streamingService/Dockerfile \
                      StreamingApp/backend

                    docker build \
                      -t "$ECR_REGISTRY/streamingapp-capstone-admin:$IMAGE_TAG" \
                      -f StreamingApp/backend/adminService/Dockerfile \
                      StreamingApp/backend

                    docker build \
                      -t "$ECR_REGISTRY/streamingapp-capstone-chat:$IMAGE_TAG" \
                      -f StreamingApp/backend/chatService/Dockerfile \
                      StreamingApp/backend
                '''
            }
        }

        stage('Push Images to ECR') {
            steps {
                sh '''
                    set -eu
                    aws ecr get-login-password --region "$AWS_REGION" |
                      docker login --username AWS --password-stdin "$ECR_REGISTRY"
                    for SERVICE in frontend auth streaming admin chat; do
                      docker push "$ECR_REGISTRY/streamingapp-capstone-$SERVICE:$IMAGE_TAG"
                    done
                '''
            }
        }

        stage('Create Kubernetes Secret') {
            steps {
                withCredentials([
                    string(
                        credentialsId: 'streamingapp-jwt-secret',
                        variable: 'JWT_SECRET'
                    )
                ]) {
                    sh '''
                        set +x
                        set -eu
                        kubectl create namespace "$K8S_NAMESPACE" \
                          --dry-run=client -o yaml | kubectl apply -f -
                        printf '%s' "$JWT_SECRET" |
                          kubectl create secret generic streamingapp-secrets \
                            --namespace "$K8S_NAMESPACE" \
                            --from-file=jwt-secret=/dev/stdin \
                            --dry-run=client -o yaml |
                          kubectl apply -f -
                    '''
                }
            }
        }

        stage('Deploy Application with Helm') {
            steps {
                sh '''
                    set -eu
                    helm lint "$CHART_PATH" \
                      --set-string image.registry="$ECR_REGISTRY" \
                      --set-string image.tag="$IMAGE_TAG" \
                      --set-string frontend.repository=streamingapp-capstone-frontend \
                      --set-string services.auth.repository=streamingapp-capstone-auth \
                      --set-string services.streaming.repository=streamingapp-capstone-streaming \
                      --set-string services.admin.repository=streamingapp-capstone-admin \
                      --set-string services.chat.repository=streamingapp-capstone-chat \
                      --set-string app.awsRegion="$AWS_REGION" \
                      --set-string app.s3Bucket=streamingapp-capstone-dev \
                      --set-string app.clientUrls="$APP_URL" \
                      --set-string app.streamingPublicUrl="$APP_URL" \
                      --set-string ingress.host="$LB_HOST"

                    helm upgrade --install "$HELM_RELEASE" "$CHART_PATH" \
                      --namespace "$K8S_NAMESPACE" \
                      --create-namespace \
                      --set-string image.registry="$ECR_REGISTRY" \
                      --set-string image.tag="$IMAGE_TAG" \
                      --set-string frontend.repository=streamingapp-capstone-frontend \
                      --set-string services.auth.repository=streamingapp-capstone-auth \
                      --set-string services.streaming.repository=streamingapp-capstone-streaming \
                      --set-string services.admin.repository=streamingapp-capstone-admin \
                      --set-string services.chat.repository=streamingapp-capstone-chat \
                      --set-string app.awsRegion="$AWS_REGION" \
                      --set-string app.s3Bucket=streamingapp-capstone-dev \
                      --set-string app.clientUrls="$APP_URL" \
                      --set-string app.streamingPublicUrl="$APP_URL" \
                      --set-string ingress.host="$LB_HOST" \
                      --wait \
                      --timeout 15m
                '''
            }
        }

        stage('Verify Deployment') {
            steps {
                sh '''
                    set -eu
                    DEPLOYMENTS=$(kubectl get deployments \
                      --namespace "$K8S_NAMESPACE" \
                      -o name)

                    if [ -z "$DEPLOYMENTS" ]; then
                      echo "ERROR: No application deployments found in namespace $K8S_NAMESPACE"
                      exit 1
                    fi

                    for deployment in $DEPLOYMENTS; do
                      kubectl rollout status "$deployment" \
                        --namespace "$K8S_NAMESPACE" \
                        --timeout=5m
                    done

                    kubectl get pods -n "$K8S_NAMESPACE" -o wide
                    kubectl get services -n "$K8S_NAMESPACE"
                    kubectl get ingress -n "$K8S_NAMESPACE"

                    curl --fail --silent --show-error \
                      --retry 10 \
                      --retry-delay 10 \
                      --retry-connrefused \
                      --max-time 20 \
                      "$APP_URL/"
                '''
                echo "Application endpoint: ${APP_URL}"
            }
        }
    }

    post {
        always {
            sh '''
                docker logout "$ECR_REGISTRY" || true
            '''
        }
        success {
            echo 'StreamingApp deployment pipeline completed successfully.'
        }
        failure {
            echo 'Pipeline failed. Review the stage logs before retrying.'
        }
    }
}
