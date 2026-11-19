variable "aws_region" {
  type    = string
  default = "ap-south-1"
}

variable "deploy_services" {
  type        = bool
  default     = false
  description = "Start billable application tasks only after the immutable images are pushed."
}

variable "project_name" {
  type    = string
  default = "rcmca"
}

variable "vpc_cidr" {
  type    = string
  default = "10.42.0.0/16"
}

variable "container_image" {
  type        = string
  description = "Immutable ECR image URI including tag or digest."
  default     = "public.ecr.aws/docker/library/python:3.11-slim"
}

variable "osrm_image" {
  type        = string
  description = "OSRM image with the Hyderabad graph baked in."
  default     = "ghcr.io/project-osrm/osrm-backend:v5.27.1"
}

variable "vision_model_key" {
  type        = string
  description = "S3 object key containing road_damage.onnx."
  default     = "models/road_damage.onnx"
}

variable "acm_certificate_arn" {
  type        = string
  description = "Issued ACM certificate in the same region as the ALB."
  default     = ""
}

variable "allowed_ingress_cidrs" {
  type        = list(string)
  description = "Client CIDRs permitted to reach the unauthenticated API ALB. Set explicitly for authorized field trials."
  default     = []
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.medium"
}

variable "db_engine_version" {
  type        = string
  description = "Supported Amazon RDS for PostgreSQL 16 minor version in the target region."
  default     = "16.15"
}

variable "db_name" {
  type    = string
  default = "road_intelligence"
}

variable "db_username" {
  type    = string
  default = "rcmca_admin"
}

variable "bedrock_model_id" {
  type        = string
  default     = "qwen.qwen3-32b-v1:0"
  description = "Bedrock model ID enabled in the selected region."
}

variable "ghmc_feed_url" {
  type        = string
  default     = ""
  description = "Authorized GHMC CSV/JSON export URL, if available."
}

variable "prajavani_feed_url" {
  type        = string
  default     = ""
  description = "Authorized Prajavani CSV/JSON export URL, if available."
}

variable "upload_allowed_origins" {
  type        = list(string)
  description = "Explicit browser origins allowed to PUT evidence directly to S3."
  default     = ["https://localhost"]
}

variable "tags" {
  type = map(string)
  default = {
    Application = "RCMCA"
    ManagedBy   = "Terraform"
    Environment = "production"

  }
}
