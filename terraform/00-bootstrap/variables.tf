variable "region" {
  description = "AWS region hosting the remote state bucket. Must match the region the cluster is built in."
  type        = string
  default     = "us-east-1"

  nullable = false
}

variable "project" {
  description = "Project slug used as a name prefix and as the cost-allocation tag value."
  type        = string
  default     = "llm-d-on-eks"

  validation {
    condition     = can(regex("^[a-z0-9-]{3,32}$", var.project))
    error_message = "Project must be 3-32 chars of lowercase letters, digits, or hyphens."
  }

  nullable = false
}

variable "state_bucket_name" {
  description = "Globally unique S3 bucket name for Terraform state. Leave null to derive one from the project and account ID."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to every resource. The Project tag is what makes `make cost` able to attribute spend."
  type        = map(string)

  default = {
    Project   = "llm-d-on-eks"
    ManagedBy = "terraform"
  }

  nullable = false
}
