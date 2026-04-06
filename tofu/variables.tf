variable "aws_region" {
  description = "AWS region to deploy the Minecraft server"
  type        = string
  default     = "eu-west-1"
}

variable "domain_name" {
  description = "Full domain name for the Minecraft server (e.g. mc.example.com)"
  type        = string
}

variable "hosted_zone_id" {
  description = "Route53 hosted zone ID. If empty, a new hosted zone will be created."
  type        = string
  default     = ""
}

variable "instance_type" {
  description = "EC2 instance type for the Minecraft server"
  type        = string
  default     = "t3.medium"
}

variable "inactivity_minutes" {
  description = "Minutes of zero players before the server shuts down"
  type        = number
  default     = 20
}

variable "minecraft_version" {
  description = "Minecraft Java server version (e.g. 1.20.4 or 'latest')"
  type        = string
  default     = "latest"
}

variable "spot_instance" {
  description = "Use EC2 Spot instance to reduce cost (may be interrupted)"
  type        = bool
  default     = false
}

variable "root_volume_size_gb" {
  description = "Size of root EBS volume in GB (OS + Java + Minecraft jar)"
  type        = number
  default     = 30
}

variable "data_volume_size_gb" {
  description = "Size of data EBS volume in GB (world data, persists between restarts)"
  type        = number
  default     = 10
}

variable "project_name" {
  description = "Name prefix for all resources"
  type        = string
  default     = "server-spawn"
}

variable "minecraft_memory_mb" {
  description = "Memory allocated to the Minecraft JVM in MB"
  type        = number
  default     = 2048
}

variable "availability_zone" {
  description = "Availability zone for the EC2 instance and world data EBS volume. Must match — changing this requires migrating the EBS volume."
  type        = string
  default     = ""
}

variable "key_name" {
  description = "EC2 key pair name for SSH access. Leave empty to disable SSH."
  type        = string
  default     = ""
}
