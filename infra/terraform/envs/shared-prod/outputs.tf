output "prod" {
  description = "Production : URL, variables GitHub, ressources utiles aux runbooks (aucun secret)."
  value = {
    api_url                         = module.prod.api_url
    web_url                         = module.prod.web_url
    github_deploy_role_arn          = module.prod.github_deploy_role_arn
    deploy_config_parameter         = module.prod.deploy_config_parameter
    ecr_repository_url              = module.prod.ecr_repository_url
    ecs_cluster_name                = module.prod.ecs_cluster_name
    ecs_task_families               = module.prod.ecs_task_families
    db_task_families                = module.prod.db_task_families
    ecs_api_security_group_id       = module.prod.ecs_api_security_group_id
    app_subnet_ids                  = var.app_subnet_ids
    jobs_log_group                  = module.prod.jobs_log_group
    db_bootstrap_master_secret_name = module.prod.db_bootstrap_master_secret_name
    db_connection_limits            = module.prod.db_connection_limits
    backup_bucket                   = module.prod.backup_bucket
    content                         = module.prod.content
    alerts_topic_arn                = module.prod.alerts_topic_arn
    secrets_to_fill                 = module.prod.secret_names
    shared_alb                      = module.prod.shared_alb
  }
}

output "preprod" {
  description = "Préproduction (null si preprod_enabled = false)."
  value = var.preprod_enabled ? {
    api_url                         = module.preprod[0].api_url
    github_deploy_role_arn          = module.preprod[0].github_deploy_role_arn
    deploy_config_parameter         = module.preprod[0].deploy_config_parameter
    ecs_cluster_name                = module.preprod[0].ecs_cluster_name
    db_task_families                = module.preprod[0].db_task_families
    ecs_api_security_group_id       = module.preprod[0].ecs_api_security_group_id
    db_bootstrap_master_secret_name = module.preprod[0].db_bootstrap_master_secret_name
    db_connection_limits            = module.preprod[0].db_connection_limits
    content                         = module.preprod[0].content
  } : null
}

output "shared_infrastructure" {
  description = "Infrastructure partagée LUE (contrôle du plan) : rien de ceci n'est modifié."
  value = {
    vpc_id                = data.aws_vpc.shared.id
    alb                   = data.aws_lb.shared.name
    https_listener        = data.aws_lb_listener.https.arn
    listener_ssl_policy   = data.aws_lb_listener.https.ssl_policy
    alb_idle_timeout      = data.aws_lb.shared.idle_timeout
    rds_instance          = data.aws_db_instance.shared.db_instance_identifier
    rds_engine_version    = data.aws_db_instance.shared.engine_version
    rds_security_group_id = data.aws_security_group.rds.id
    github_oidc_provider  = data.aws_iam_openid_connect_provider.github.arn
    route53_zone          = var.domain_name != "" ? one(data.aws_route53_zone.this[*].name) : null
  }
}
