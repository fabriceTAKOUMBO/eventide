output "state_bucket" {
  description = "Bucket à renseigner dans envs/shared-prod/backend.hcl (bucket)."
  value       = aws_s3_bucket.state.id
}

output "state_kms_key_arn" {
  description = "Clé KMS à renseigner dans envs/shared-prod/backend.hcl (kms_key_id)."
  value       = aws_kms_key.state.arn
}

output "state_access_principal_arns" {
  description = "Seuls principaux autorisés à lire, écrire et déchiffrer l'état (motifs StringLike)."
  value       = local.state_access_principal_arns
}

output "backend_hcl" {
  description = "Contenu prêt à copier dans envs/shared-prod/backend.hcl."
  value       = <<-EOT
    bucket     = "${aws_s3_bucket.state.id}"
    kms_key_id = "${aws_kms_key.state.arn}"
  EOT
}
