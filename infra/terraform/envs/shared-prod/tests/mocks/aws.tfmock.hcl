# Valeurs simulées des sources de données AWS (aucun appel réseau), partagées par la
# configuration par défaut et la configuration « preprod » du fournisseur.

mock_data "aws_caller_identity" {
  defaults = {
    account_id = "466494951409"
    arn        = "arn:aws:sts::466494951409:assumed-role/AWSReservedSSO_AdministratorAccess_0123456789abcdef/TAKOUMBO"
  }
}
mock_data "aws_region" {
  defaults = { region = "us-east-1", name = "us-east-1" }
}
mock_data "aws_partition" {
  defaults = { partition = "aws" }
}
mock_data "aws_iam_policy_document" {
  defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
}
mock_data "aws_iam_session_context" {
  defaults = { issuer_arn = "arn:aws:iam::466494951409:role/aws-reserved/sso.amazonaws.com/eu-north-1/AWSReservedSSO_AdministratorAccess_0123456789abcdef" }
}
mock_data "aws_vpc" {
  defaults = { id = "vpc-0fbfe87b34e2b3903", cidr_block = "10.20.0.0/16" }
}
mock_data "aws_subnet" {
  defaults = { vpc_id = "vpc-0fbfe87b34e2b3903", available_ip_address_count = 200 }
}
mock_data "aws_lb" {
  defaults = {
    arn                        = "arn:aws:elasticloadbalancing:us-east-1:466494951409:loadbalancer/app/cinaf-streaming-prod-alb/0123456789abcdef"
    arn_suffix                 = "app/cinaf-streaming-prod-alb/0123456789abcdef"
    name                       = "cinaf-streaming-prod-alb"
    vpc_id                     = "vpc-0fbfe87b34e2b3903"
    internal                   = false
    xff_header_processing_mode = "append"
    enable_xff_client_port     = false
    security_groups            = ["sg-04bbc536ff0295918"]
    idle_timeout               = 60
    dns_name                   = "cinaf-streaming-prod-alb-123.us-east-1.elb.amazonaws.com"
    zone_id                    = "Z35SXDOTRQ7X7K"
  }
}
mock_data "aws_lb_listener" {
  defaults = {
    arn               = "arn:aws:elasticloadbalancing:us-east-1:466494951409:listener/app/cinaf-streaming-prod-alb/0123456789abcdef/fedcba9876543210"
    load_balancer_arn = "arn:aws:elasticloadbalancing:us-east-1:466494951409:loadbalancer/app/cinaf-streaming-prod-alb/0123456789abcdef"
    ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  }
}
mock_data "aws_db_instance" {
  defaults = {
    db_instance_identifier = "cinaf-streaming-prod-postgres"
    address                = "cinaf-streaming-prod-postgres.abcdefghijkl.us-east-1.rds.amazonaws.com"
    port                   = 5432
    engine_version         = "16.3"
    master_username        = "app_admin"
    vpc_security_groups    = ["sg-070b4372d5a95ad2d"]
  }
}
mock_data "aws_security_group" {
  defaults = { id = "sg-070b4372d5a95ad2d" }
}
mock_data "aws_route53_zone" {
  defaults = { zone_id = "Z0EVENTIDETEST", name = "eventide.example." }
}
mock_data "aws_iam_openid_connect_provider" {
  defaults = { arn = "arn:aws:iam::466494951409:oidc-provider/token.actions.githubusercontent.com" }
}
