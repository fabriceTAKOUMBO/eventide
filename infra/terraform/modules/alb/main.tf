# Entrée publique d'Eventide sur l'ALB PARTAGÉ de CINAF (hébergement mutualisé).
#
# Aucun équilibreur, écouteur, groupe de sécurité ni bucket n'est créé ou modifié. Le module
# AJOUTE seulement, sur l'écouteur HTTPS existant : notre groupe cible, nos règles par nom
# d'hôte (priorités réservées à Eventide : 400 à 409 en production, 420 à 429 en
# préproduction), notre certificat (aws_lb_listener_certificate, choix par SNI) et nos
# enregistrements DNS dans NOTRE zone. Ni l'action par défaut de l'écouteur, ni ses autres
# règles, ni les attributs ou le groupe de sécurité de l'équilibreur ne sont touchés.
#
# Hôtes : api.<domaine> -> API ; <domaine> et www.<domaine> -> le même service API, qui sert
# les pages web du contrat § 9 (partage, assetlinks.json, confidentialité).

data "aws_lb_listener" "shared" {
  arn = var.https_listener_arn
}

data "aws_lb" "shared" {
  arn = data.aws_lb_listener.shared.load_balancer_arn
}

resource "aws_lb_target_group" "api" {
  name                 = "${var.name}-api"
  port                 = var.api_port
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = var.vpc_id
  deregistration_delay = 30

  health_check {
    path                = var.health_check_path
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

# Point de contact n° 1 (ADR) : règles autonomes sur l'écouteur 443 partagé, qui ne
# correspondent qu'à NOS noms d'hôte.
resource "aws_lb_listener_rule" "api" {
  listener_arn = var.https_listener_arn
  priority     = var.listener_rule_priorities.api

  condition {
    host_header {
      values = [var.api_hostname]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}

resource "aws_lb_listener_rule" "web" {
  count        = length(var.web_hostnames) > 0 ? 1 : 0
  listener_arn = var.https_listener_arn
  priority     = var.listener_rule_priorities.web

  condition {
    host_header {
      values = var.web_hostnames
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}

# Point de contact n° 2 (ADR) : notre certificat AJOUTÉ à la liste de l'écouteur (SNI), sans
# changer son certificat par défaut.
resource "aws_lb_listener_certificate" "this" {
  listener_arn    = var.https_listener_arn
  certificate_arn = var.certificate_arn
}

# Enregistrements dans NOTRE zone (alias vers l'ALB partagé).
resource "aws_route53_record" "hosts" {
  for_each = toset(concat([var.api_hostname], var.web_hostnames))
  zone_id  = var.zone_id
  name     = each.key
  type     = "A"

  alias {
    name                   = data.aws_lb.shared.dns_name
    zone_id                = data.aws_lb.shared.zone_id
    evaluate_target_health = true
  }
}
