terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }

  # Uncomment and configure for remote state:
  # backend "s3" {
  #   bucket = "your-tofu-state-bucket"
  #   key    = "server-spawn/terraform.tfstate"
  #   region = "eu-west-1"
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "opentofu"
    }
  }
}

# Lambda must invoke Route53 query logs, which only ship to us-east-1
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "opentofu"
    }
  }
}

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}
