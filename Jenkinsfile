pipeline {
    agent any

    options {
        skipDefaultCheckout(true)
        disableConcurrentBuilds()
        timeout(time: 10, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '10'))
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

                    test "$account" = "175200623108"
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
    }
}