# Règles sur l'écouteur PARTAGÉ : seulement la plage d'Eventide (400-409, préproduction 420-429),
# seulement nos noms d'hôte, notre certificat ajouté (SNI). Sans AWS (fournisseur simulé).

mock_provider "aws" {
  mock_data "aws_lb_listener" {
    defaults = {
      arn               = "arn:aws:elasticloadbalancing:us-east-1:466494951409:listener/app/cinaf-streaming-prod-alb/0123456789abcdef/fedcba9876543210"
      load_balancer_arn = "arn:aws:elasticloadbalancing:us-east-1:466494951409:loadbalancer/app/cinaf-streaming-prod-alb/0123456789abcdef"
      ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
    }
  }
  mock_data "aws_lb" {
    defaults = {
      arn_suffix      = "app/cinaf-streaming-prod-alb/0123456789abcdef"
      security_groups = ["sg-04bbc536ff0295918"]
      idle_timeout    = 60
      dns_name        = "cinaf-streaming-prod-alb-123.us-east-1.elb.amazonaws.com"
      zone_id         = "Z35SXDOTRQ7X7K"
    }
  }
}

variables {
  name               = "ev-prod"
  vpc_id             = "vpc-0fbfe87b34e2b3903"
  https_listener_arn = "arn:aws:elasticloadbalancing:us-east-1:466494951409:listener/app/cinaf-streaming-prod-alb/0123456789abcdef/fedcba9876543210"
  api_hostname       = "api.eventide.example"
  web_hostnames      = ["eventide.example", "www.eventide.example"]
  certificate_arn    = "arn:aws:acm:us-east-1:466494951409:certificate/00000000-0000-0000-0000-000000000000"
  zone_id            = "Z0EVENTIDETEST"
}

run "eventide_rules_match_only_our_hosts" {
  command = plan

  variables {
    listener_rule_priorities = { api = 400, web = 401 }
  }

  assert {
    condition     = aws_lb_listener_rule.api.priority == 400 && aws_lb_listener_rule.web[0].priority == 401
    error_message = "Priorités 400 (api) et 401 (domaine nu et www)."
  }
  assert {
    condition     = one(aws_lb_listener_rule.api.condition).host_header[0].values == toset(["api.eventide.example"])
    error_message = "La règle api ne correspond qu'à api.<domaine>."
  }
  assert {
    condition     = one(aws_lb_listener_rule.web[0].condition).host_header[0].values == toset(["eventide.example", "www.eventide.example"])
    error_message = "La règle web ne correspond qu'au domaine nu et à www."
  }
  assert {
    condition     = aws_lb_listener_certificate.this.listener_arn == var.https_listener_arn
    error_message = "Notre certificat est AJOUTÉ à l'écouteur partagé (SNI)."
  }
  assert {
    condition     = aws_lb_target_group.api.health_check[0].path == "/v1/health"
    error_message = "Contrôle de santé sans base de données (contrat § 10)."
  }
}

run "candidature_express_range_is_refused" {
  command = plan

  variables {
    listener_rule_priorities = { api = 300, web = 301 }
  }

  expect_failures = [var.listener_rule_priorities]
}

run "preprod_range_is_accepted" {
  command = plan

  variables {
    listener_rule_priorities = { api = 420, web = 421 }
  }
}
