## Lazre AWS Deployment (Terraform, Fargate + EFS)

This document explains how to deploy the Lazre bot and indexer to AWS using Terraform and Amazon ECS Fargate.

The Terraform configuration in `main.tf` creates:

- **EFS** file system, with a logical root directory for this instance at `remont_pl_data`
- **ECS cluster** in `eu-central-1`
- **Bot service** (always on, small Fargate task)
- **Indexer task** (on demand, big Fargate task)
- **EventBridge schedule** to run the indexer every Sunday and Wednesday at 03:00 UTC
- **Security groups, IAM roles, and CloudWatch log groups** for the tasks

By default, all resource names are prefixed with `remont_pl_lazre`. In future you can duplicate this setup with a different `project_prefix` for another instance.

---

## Prerequisites

- AWS account and credentials configured locally (for example via `aws configure`)
- Terraform (`>= 1.5`)
- Permissions to create:
  - EFS
  - ECS (Fargate)
  - IAM roles and policies
  - CloudWatch Logs
  - EventBridge rules
  - EC2 instances and EBS volumes

- An **EC2 key pair** in `eu-central-1` for SSH access to the helper instance:
  1. In the AWS Console (EC2 → Key pairs), create a new key pair in `eu-central-1` (for example, `remont-pl-helper-key`) and download the `.pem` file to your laptop.
  2. Copy `terraform.tfvars.example` to `terraform.tfvars`:

     ```bash
     cp terraform.tfvars.example terraform.tfvars
     ```

  3. Edit `terraform.tfvars` and:
     - Set `helper_ssh_key_name` to your key pair name.
     - Set `helper_ssh_cidr` to your current public IP with `/32` (for example: `83.24.12.45/32`).
     - Optionally adjust `project_prefix` and `efs_root_directory` if you want different names/paths.

     When your IP changes in the future, update `helper_ssh_cidr` in `terraform.tfvars` and run `terraform apply` again to adjust the security group.

---

## 1. Initialize and apply Terraform

From the project root (where `main.tf` is located):

```bash
terraform init
terraform plan
terraform apply
```

Review the plan and confirm `apply`. This will:

- Create an EFS file system
- Create an ECS cluster
- Create task definitions for:
  - Bot (0.5 vCPU / 1 GB RAM)
  - Indexer (4 vCPU / 16 GB RAM)
- Create an ECS service for the bot (initially with `desired_count = 0`, see below)
- Configure an EventBridge rule to trigger the indexer task on schedule

After `terraform apply` finishes, note the outputs:

- `ecs_cluster_name`
- `efs_id`
- `project_prefix`

At this initial stage, the bot service is configured with `bot_desired_count = 0` (from `terraform.tfvars`), so **no bot tasks will be running yet**. This is intentional so you can prepare the app configs (in EFS) before starting the bot.

---

## 2. Prepare EFS contents (.env and config)

The tasks mount the EFS file system at `/var/lib/lazre` inside the containers. For this specific instance, Terraform sets the logical root directory to:

```text
/remont_pl_data
```

So, inside the EFS file system, the bot and indexer expect:

- `.env` at:

  ```text
  /remont_pl_data/.env
  ```

- Config files at:

  ```text
  /remont_pl_data/config/...
  ```

Terraform also creates a small EC2 helper instance for you, dedicated to managing EFS contents. It is configured to automatically mount the EFS file system and create the base directory structure (using `mkdir -p`, so it will not delete or overwrite any existing data under `/remont_pl_data`).

Terraform will create a small **t3.micro** EC2 instance in the default VPC, with:

- SSH access only from `helper_ssh_cidr`
- Security groups configured so it can reach the EFS file system

You can start/stop this instance manually in the EC2 Console. Terraform is configured so that if you shut it down from inside the instance, it will go into the **stopped** state (do not terminate it if you want to keep it managed by Terraform).

### Managing app configs in EFS volume

Once Terraform has created the helper instance, you can SSH into it:

```bash
ssh -i /path/to/your/key.pem ec2-user@<helper_public_ip>
```

You can find `<helper_public_ip>` either from the EC2 Console or by adding an output in Terraform for the helper instance’s public IP.

On the helper instance, EFS is automatically mounted at:

```text
/mnt/efs
```

And the logical root directory for this deployment is:

```text
/mnt/efs/remont_pl_data
```

If `/remont_pl_data` already exists on EFS, the helper’s startup script will **not** delete it; `mkdir -p` only ensures the directory exists.

Now copy your local files into the mounted EFS:

```bash
cp /path/to/local/.env "${MOUNT_POINT}${INSTANCE_ROOT_DIR}/.env"
cp /path/to/local/config/*.json "${MOUNT_POINT}${INSTANCE_ROOT_DIR}/config/"
```

When you are not using the helper instance, you can simply **stop** it from the EC2 Console (do not terminate it if you plan to reuse it). Stopping the instance stops compute charges, but:

- The root EBS volume (8 GB gp3) continues to incur a small **per GB-month** storage cost while it exists.
- EFS storage continues to be billed independently of the helper instance state.

In `eu-central-1`, 8 GB of gp3 is typically **well under 1 USD per month** as long as the volume exists, regardless of whether the instance is running or stopped.

Once this is done, both the bot and indexer tasks will see the same `.env` and `config` when they run.

To actually start the bot, update `terraform.tfvars` and set:

```hcl
bot_desired_count = 1
```

Then run:

```bash
terraform apply
```

Terraform will update the ECS service, and ECS will start one bot task (and keep it running).

---

## 3. Bot service behavior

The ECS service:

- Runs the container image `ghcr.io/nullptre/lazre-box:latest`
- Uses the default entrypoint/command of the image to start the Telegram bot
- Mounts EFS at `/var/lib/lazre`
- Has outbound internet access to:
  - Telegram API
  - OpenAI API
  - External URLs for content fetching

The service keeps `desired_count = 1`, so one bot task will always be running.

---

## 4. Indexing task behavior

The indexer task definition:

- Uses the same image `ghcr.io/nullptre/lazre-box:latest`
- Overrides the command to:

  ```text
  python lazre/util_index_topics.py
  ```

- Mounts the same EFS volume at `/var/lib/lazre`
- Requests 4 vCPU and 16 GB memory

The EventBridge rule created by Terraform:

- Runs this indexer task **twice per week**:
  - Every **Sunday at 03:00 UTC**
  - Every **Wednesday at 03:00 UTC**

The indexer task runs to completion and exits.

---

## 5. Manually triggering the indexer

You can also run the indexer manually in addition to the scheduled runs.

First, get the cluster name and indexer task definition ARN (from Terraform outputs or AWS Console). Then run:

```bash
aws ecs run-task \
  --cluster "<ecs_cluster_name>" \
  --launch-type FARGATE \
  --task-definition "<indexer_task_definition_arn>" \
  --network-configuration "awsvpcConfiguration={subnets=[subnet-1,subnet-2],securityGroups=[sg-...],assignPublicIp=ENABLED}"
```

If you want an exact CLI with concrete subnet and security group IDs, you can copy them from the Terraform state or AWS Console:

- Subnets: the same subnets attached to the ECS service
- Security group: `${project_prefix}-tasks-sg`

Alternatively, you can start the task directly from the ECS section in the AWS Console (Run new task → use existing task definition → same cluster and networking configuration).

---

## 6. Logs

In addition to any file-based logs your app writes inside the container, ECS sends container stdout/stderr to CloudWatch Logs, under a dedicated path:

- Bot logs: `/remont_pl_lazre/cloud-watch-logs/bot`
- Indexer logs: `/remont_pl_lazre/cloud-watch-logs/indexer`

Retention is set to 30 days by default. CloudWatch Logs is not entirely free, but at the low volume expected for this bot, the cost is typically very small.

---

## 7. Customizing for another instance

If you want to run another copy of this setup with different config and workdir (for another project or environment):

1. Copy `main.tf` to another Terraform project directory, or keep it in the same directory but use different workspaces or variables.
2. Change:

   ```hcl
   variable "project_prefix" {
     default = "another_prefix_here"
   }

   variable "efs_root_directory" {
     default = "/another_instance_data"
   }
   ```

3. Run `terraform init` (if needed) and `terraform apply` again.
4. Prepare a separate directory tree on EFS for the new instance (matching the new `efs_root_directory`) with its own `.env` and `config` files.

This way, you can run multiple independent Lazre deployments on the same AWS account, each with its own data and configuration.


