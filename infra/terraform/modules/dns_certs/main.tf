# Certificat ACM (validation DNS) des noms d'Eventide, dans la zone Route 53 EXISTANTE du
# domaine (créée à l'achat du domaine, lue par la racine) ; CAA facultatif. Rien d'autre.

resource "aws_route53_record" "caa" {
  count   = length(var.caa_issuers) > 0 ? 1 : 0
  zone_id = var.zone_id
  name    = var.zone_name
  type    = "CAA"
  ttl     = 3600
  records = concat(
    [for issuer in var.caa_issuers : "0 issue \"${issuer}\""],
    ["0 issuewild \";\""],
  )
}

resource "aws_acm_certificate" "this" {
  domain_name               = var.certificate_domains[0]
  subject_alternative_names = slice(var.certificate_domains, 1, length(var.certificate_domains))
  validation_method         = "DNS"
  key_algorithm             = "RSA_2048"

  options {
    certificate_transparency_logging_preference = "ENABLED"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "validation" {
  for_each = {
    for dvo in aws_acm_certificate.this.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  zone_id         = var.zone_id
  name            = each.value.name
  type            = each.value.type
  ttl             = 300
  records         = [each.value.record]
}

resource "aws_acm_certificate_validation" "this" {
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for r in aws_route53_record.validation : r.fqdn]

  timeouts {
    create = "2h"
  }
}
