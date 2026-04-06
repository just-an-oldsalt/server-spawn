data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_security_group" "minecraft" {
  name        = "${var.project_name}-server"
  description = "Allow Minecraft Java traffic inbound; all outbound"

  ingress {
    description = "Minecraft Java"
    from_port   = 25565
    to_port     = 25565
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  dynamic "ingress" {
    for_each = var.key_name != "" ? [1] : []
    content {
      description = "SSH"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "minecraft" {
  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = var.instance_type
  iam_instance_profile   = aws_iam_instance_profile.ec2.name
  vpc_security_group_ids = [aws_security_group.minecraft.id]
  key_name               = var.key_name != "" ? var.key_name : null

  # IMDSv2 required (more secure than v1)
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size_gb
    delete_on_termination = true
    encrypted             = true
  }

  dynamic "instance_market_options" {
    for_each = var.spot_instance ? [1] : []
    content {
      market_type = "spot"
      spot_options {
        instance_interruption_behavior = "stop"
        spot_instance_type             = "persistent"
      }
    }
  }

  user_data = base64encode(templatefile("${path.module}/../scripts/user_data.sh", {
    minecraft_version    = var.minecraft_version
    minecraft_memory_mb  = var.minecraft_memory_mb
    inactivity_minutes   = var.inactivity_minutes
    domain_name          = var.domain_name
    hosted_zone_id       = local.hosted_zone_id
    aws_region           = var.aws_region
    artifacts_bucket     = aws_s3_bucket.artifacts.id
  }))

  # Don't replace the instance when user_data changes — world data must persist
  lifecycle {
    ignore_changes = [user_data, ami]
  }

  tags = {
    Name = "${var.project_name}-server"
  }
}

# Separate data volume — survives instance replacement
resource "aws_ebs_volume" "world_data" {
  availability_zone = aws_instance.minecraft.availability_zone
  size              = var.data_volume_size_gb
  type              = "gp3"
  encrypted         = true

  tags = {
    Name = "${var.project_name}-world-data"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_volume_attachment" "world_data" {
  device_name  = "/dev/xvdf"
  volume_id    = aws_ebs_volume.world_data.id
  instance_id  = aws_instance.minecraft.id
  force_detach = false
}
