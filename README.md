# Setup Configuration

This repo has scripts to set up your development computer fast.

## What is in here

| Directory | What it does |
|---|---|
| `docker/` | Scripts to install Docker on Ubuntu or Red Hat Linux |
| `k8s/` | Script to create a local Kubernetes cluster using Kind |
| `terraform/` | Script to install AWS CLI and Terraform on Ubuntu |

## How to use

### Docker

Run the right script for your system:

```bash
# For Ubuntu or Debian
bash docker/ubuntu-setup.sh

# For CentOS or Rocky Linux
bash docker/redhat-setup.sh
```

### Kubernetes (Kind)

Run the setup script. It will install kubectl and Kind, then create a local cluster:

```bash
bash k8s/setup.sh
```

### Terraform + AWS CLI

Run the script on Ubuntu:

```bash
bash terraform/aws-terraform-setup.sh
```

## Requirements

- A Linux computer
- Internet connection
- `curl` installed
- `git` installed
