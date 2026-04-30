# server-spawn

> An on-demand Minecraft Java server on AWS that wakes up when someone tries to join, and shuts itself off when nobody's playing.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![OpenTofu](https://img.shields.io/badge/OpenTofu-%E2%89%A51.6-7B42BC)](https://opentofu.org/)
[![AWS](https://img.shields.io/badge/AWS-EC2%20%7C%20Lambda%20%7C%20Route53-FF9900)](https://aws.amazon.com/)
[![Minecraft](https://img.shields.io/badge/Minecraft-Java-62B47A)](https://www.minecraft.net/)

Pay only for the minutes your friends actually play. No control panel, no
"start server" button — just connect to your domain and the server boots
itself. After a configurable idle window, it shuts back down.

---

## How it works

```
                       ┌──────────────────┐
   player connects ──▶ │     Route53      │ ──┐
                       └──────────────────┘   │ DNS query logged
                                              ▼
                       ┌──────────────────────────────────┐
                       │ CloudWatch Logs (us-east-1)      │
                       └──────────────────────────────────┘
                                              │ subscription filter
                                              ▼
                       ┌──────────────────────────────────┐
                       │ Lambda (start_server.py)         │
                       └──────────────────────────────────┘
                                              │ ec2:StartInstances
                                              ▼
                       ┌──────────────────────────────────┐
                       │ EC2 — Minecraft + watchdog       │
                       │   • watchdog updates A record    │
                       │   • polls player count every 60s │
                       │   • stops EC2 after N idle min   │
                       └──────────────────────────────────┘
```

World data lives on a dedicated EBS volume (separate from the root disk) and
persists across restarts. The instance can be terminated and recreated without
losing your world.

---

## Prerequisites

- [OpenTofu](https://opentofu.org/) ≥ 1.6 (or Terraform ≥ 1.6)
- AWS credentials configured (`aws configure` or environment variables)
- A domain name you can point at Route53 nameservers (or an existing hosted zone)

---

## Quick start

```bash
git clone https://github.com/just-an-oldsalt/server-spawn.git
cd server-spawn/tofu

cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — at minimum set domain_name and availability_zone

tofu init
tofu apply
```

If OpenTofu created a new Route53 hosted zone for you, point your domain's
nameservers at the values in the `nameservers` output. Then connect to your
domain from Minecraft — the first connection will trigger the boot (allow ~60s
for the server to start).

---

## Configuration

| Variable              | Default       | Description                                                |
| --------------------- | ------------- | ---------------------------------------------------------- |
| `domain_name`         | _required_    | Full domain, e.g. `mc.example.com`                         |
| `availability_zone`   | _required_    | AZ for the EC2 instance and world EBS volume (must match)  |
| `hosted_zone_id`      | `""`          | Existing zone ID, or empty to create a new one             |
| `aws_region`          | `eu-west-1`   | Region for EC2 and most resources                          |
| `instance_type`       | `t3.medium`   | EC2 instance type                                          |
| `inactivity_minutes`  | `20`          | Minutes of zero players before automatic shutdown          |
| `minecraft_version`   | `latest`      | Server version, e.g. `1.20.4` or `latest`                  |
| `minecraft_memory_mb` | `2048`        | JVM heap size (`-Xms` / `-Xmx`)                            |
| `spot_instance`       | `false`       | Use Spot pricing — cheaper, may be interrupted             |
| `key_name`            | `""`          | EC2 key pair name for SSH; omit to keep port 22 closed     |
| `root_volume_size_gb` | `30`          | Root volume (OS + Java + jar)                              |
| `data_volume_size_gb` | `10`          | World data volume                                          |
| `server_properties`   | `{}`          | Extra `server.properties` overrides (map of strings)       |
| `ops`                 | `[]`          | Operator list — see `terraform.tfvars.example`             |
| `whitelist`           | `[]`          | Whitelist — any entry sets `white-list=true`               |
| `banned`              | `[]`          | Banned players written to `banned-players.json`            |

> **Heads up:** changes to `user_data.sh`, the AMI, or the AZ are intentionally
> ignored on the running instance — the world EBS volume is the durable store,
> not the instance. To pick up `user_data.sh` changes, taint the instance:
> `tofu taint aws_instance.minecraft && tofu apply`. The world volume has
> `prevent_destroy = true`, so it survives.

---

## What gets deployed

| Resource           | Where           | Purpose                                                  |
| ------------------ | --------------- | -------------------------------------------------------- |
| EC2 instance       | `var.aws_region`| Runs Minecraft + watchdog                                |
| EBS volume (world) | `var.aws_region`| Persistent world data, `prevent_destroy = true`          |
| Security group     | `var.aws_region`| Opens TCP 25565 (and 22 only if `key_name` is set)       |
| Route53 zone       | global          | Optional — created if `hosted_zone_id` is empty          |
| Route53 A record   | global          | Updated by the watchdog at boot                          |
| Lambda function    | `us-east-1`     | Triggered by DNS query log; starts EC2                   |
| Route53 query log  | `us-east-1`     | DNS lookups land in CloudWatch                           |
| S3 bucket          | `var.aws_region`| Holds `watchdog.py` for the EC2 to fetch on boot         |

> **Why us-east-1?** Route53 query logging only ships to CloudWatch in
> `us-east-1`. The Lambda and its log group are pinned there regardless of
> `aws_region`.

---

## Operating

### Logs

```bash
# Lambda start events
aws logs tail /aws/lambda/server-spawn --region us-east-1 --follow

# Watchdog and Minecraft (requires SSH access — set key_name)
ssh ec2-user@<instance-ip>
journalctl -u minecraft-watchdog -f
journalctl -u minecraft -f
sudo cat /var/log/user_data.log   # Boot-time log
```

### World backups

The world EBS volume ID is in the `world_data_volume_id` output. Take manual
snapshots, or configure [AWS Backup](https://aws.amazon.com/backup/) with that
volume as the target.

### Updating Minecraft

Bump `minecraft_version` in `terraform.tfvars`, then taint and apply:

```bash
tofu taint aws_instance.minecraft
tofu apply
```

The world volume detaches cleanly, the new instance attaches it, and your
world comes along for the ride.

---

## Security notes

- IMDSv2 is required on the EC2 instance.
- IAM policies are scoped to specific resource ARNs:
  - Lambda may only `StartInstances` on the Minecraft instance.
  - The EC2 instance may only `StopInstances` on itself, and may only mutate
    the specific Route53 A record for `domain_name`.
- The S3 artifacts bucket has all public access blocked and uses SSE-S3.
- Root EBS and world EBS volumes are encrypted.
- Port 22 is only opened in the security group when `key_name` is set.

---

## Cost

You pay for:

- EC2 compute while the server is awake (Spot keeps this small).
- Two EBS volumes (root + world) — always-on but tiny.
- A few cents/month of Route53, CloudWatch Logs, Lambda invocations.

A small group on `t3.medium` Spot, idle most of the week, generally lands in
single-digit USD/month.

---

## Project layout

```
server-spawn/
├── lambda/
│   └── start_server.py     # Triggered by DNS query log
├── watchdog/
│   ├── watchdog.py         # Updates DNS, polls players, self-stops
│   └── requirements.txt
├── scripts/
│   └── user_data.sh        # First-boot bootstrap (templated by OpenTofu)
└── tofu/
    ├── main.tf             # Providers
    ├── variables.tf        # Input variables
    ├── outputs.tf          # Outputs
    ├── ec2.tf              # Instance, security group, EBS world volume
    ├── iam.tf              # Lambda + EC2 roles, scoped to specific ARNs
    ├── lambda.tf           # Lambda function + CloudWatch subscription filter
    ├── route53.tf          # Hosted zone, A record, query logging
    ├── s3.tf               # Artifacts bucket for watchdog.py
    └── terraform.tfvars.example
```

---

## License

[MIT](LICENSE) — do whatever you like, no warranty.
