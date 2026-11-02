# The Mailbridge image (ARCHITECTURE.md §3). app pulls it by digest with its
# instance role (granted in 1.14). Lives here, not in lab, so a lab teardown
# never deletes images; no force_delete, so even this stack can't delete a
# repository that still holds images (decision 53).
resource "aws_ecr_repository" "mailbridge" {
  name = "mailbridge"

  # A pushed tag can never be moved to another image, so a tag in a log or a
  # commit always names one image, matching the digest pin on app.
  image_tag_mutability = "IMMUTABLE"

  # Basic scanning: free, checks each push against a CVE database.
  image_scanning_configuration {
    scan_on_push = true
  }

  # KMS with the AWS-managed aws/ecr key (no kms_key given): free, unlike a
  # customer-managed key.
  encryption_configuration {
    encryption_type = "KMS"
  }
}

# Keeps storage under ECR's free 500 MB a month. Rules run in priority order.
resource "aws_ecr_lifecycle_policy" "mailbridge" {
  repository = aws_ecr_repository.mailbridge.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Untagged leftovers from rebuilds expire after a day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the last 5 tagged images"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["*"]
          countType      = "imageCountMoreThan"
          countNumber    = 5
        }
        action = { type = "expire" }
      },
    ]
  })
}
