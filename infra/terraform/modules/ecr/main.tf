# Dépôt ECR de l'image de l'API : tags immuables (un tag = un commit), scan à l'envoi, cycle de
# vie (images non taguées purgées, N dernières images conservées pour les retours arrière).

resource "aws_ecr_repository" "this" {
  for_each = toset(var.repositories)

  name                 = "${var.name}-${each.key}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = var.force_delete

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each   = aws_ecr_repository.this
  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Images non taguees : supprimees apres 7 jours"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Conserver les ${var.keep_last_images} dernieres images (retours arriere)"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.keep_last_images
        }
        action = { type = "expire" }
      },
    ]
  })
}
