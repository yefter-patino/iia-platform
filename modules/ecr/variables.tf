variable "name_prefix" {
  description = "Prefix for the repository name."
  type        = string
}

variable "environment" {
  description = "Environment name."
  type        = string
}

variable "image_tag_mutability" {
  description = "IMMUTABLE stops a pushed tag being moved, which is what makes a deploy reproducible and a rollback meaningful."
  type        = string
  default     = "IMMUTABLE"

  validation {
    condition     = contains(["MUTABLE", "IMMUTABLE"], var.image_tag_mutability)
    error_message = "Must be MUTABLE or IMMUTABLE."
  }
}

variable "keep_last_images" {
  description = "How many images to retain. ECR bills per GB-month and images are hundreds of MB each."
  type        = number
  default     = 5

  validation {
    condition     = var.keep_last_images >= 1
    error_message = "Must keep at least one image."
  }
}

variable "force_delete" {
  description = "Allow terraform destroy to delete the repository while it still holds images."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
