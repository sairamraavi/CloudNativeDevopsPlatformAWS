# Terraform infrastructure

This folder will contain the infrastructure-as-code configuration for the StreamingApp capstone project. The initial scaffold provides separate environment folders, reusable module folders, and a location for Terraform backend bootstrap configuration.

## Folder structure

```text
Terraform/
├── README.md
├── bootstrap/           # Initial Terraform state-backend setup
├── environments/
│   ├── dev/             # Development environment configuration
│   ├── staging/         # Staging environment configuration
│   └── prod/            # Production environment configuration
└── modules/
    ├── networking/      # VPC, subnets, gateways, routes, and network controls
    ├── eks/             # EKS cluster and managed node groups
    ├── ecr/             # Container image repositories
    ├── iam/             # IAM roles and policies
    ├── jenkins/         # Jenkins EC2 infrastructure
    └── storage/         # Application S3 storage
```

The environment folders will compose the reusable modules. The `bootstrap` folder is reserved for the initial state-backend setup, separate from application storage.

## Current status

This is a folder scaffold only. The `.gitkeep` files allow Git to track empty directories. Terraform configuration, backend settings, variables, outputs, and resource definitions will be added during implementation; there is nothing to provision yet.

Do not commit credentials, secret values, Terraform state, or generated plans. Follow the repository's existing Terraform ignore rules.

## Project documentation

- [Project overview](../README.md)
- [Architecture and implementation approach](../Docs/architecture.md)
- [Step-by-step setup guide](../Docs/setup-process.md)
