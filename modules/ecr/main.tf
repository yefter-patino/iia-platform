# ---------------------------------------------------------------------------
# ECR MODULE  (Phase 6)
#
# A private registry for the service image.
#
# Two settings here are not defaults and are the difference between a registry
# that stays cheap and safe and one that does not:
#
#   image_tag_mutability = IMMUTABLE
#     A tag, once pushed, cannot be moved. Without this, `:latest` means
#     something different tomorrow and a rollback rolls back to whatever
#     happens to be there now. Immutable tags are what make a deploy
#     reproducible.
#
#   lifecycle_policy
#     ECR bills per GB-month and images are hundreds of MB. Without expiry,
#     every build ever made is kept forever.
# ---------------------------------------------------------------------------

locals {
  name = "${var.name_prefix}-${var.environment}"
}

resource "aws_ecr_repository" "this" {
  name = "${local.name}-api"

  image_tag_mutability = var.image_tag_mutability

  # Scan on push finds known CVEs in the image's OS packages. Basic scanning
  # is free; there is no reason to leave it off.
  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  # A lab repo should be deletable without emptying it by hand first.
  force_delete = var.force_delete

  tags = merge(var.tags, {
    Name = "${local.name}-api"
  })
}

resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep only the most recent ${var.keep_last_images} images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.keep_last_images
        }
        action = { type = "expire" }
      }
    ]
  })
}
