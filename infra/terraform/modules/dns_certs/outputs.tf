output "certificate_arn" {
  description = "Certificat ACM validé."
  value       = aws_acm_certificate_validation.this.certificate_arn
}
