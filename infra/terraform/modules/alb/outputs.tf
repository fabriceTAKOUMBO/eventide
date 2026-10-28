# Le groupe cible n'est rendu qu'une fois les règles d'écouteur créées : un service ECS attaché
# à un groupe cible relié à aucun équilibreur échoue à la création.
output "target_group_arn" {
  description = "Groupe cible de l'API (disponible après la création des règles d'écouteur)."
  value       = aws_lb_target_group.api.arn
  depends_on  = [aws_lb_listener_rule.api, aws_lb_listener_rule.web]
}

output "target_group_arn_suffix" {
  description = "Suffixe d'ARN du groupe cible (dimension CloudWatch TargetGroup)."
  value       = aws_lb_target_group.api.arn_suffix
  depends_on  = [aws_lb_listener_rule.api, aws_lb_listener_rule.web]
}

output "arn_suffix" {
  description = "Suffixe d'ARN de l'ALB partagé (dimension CloudWatch LoadBalancer)."
  value       = data.aws_lb.shared.arn_suffix
}

output "security_group_id" {
  description = "Groupe de sécurité de l'ALB partagé (lu, cité comme source par nos groupes ; jamais modifié)."
  value       = one(data.aws_lb.shared.security_groups)
}

output "idle_timeout" {
  description = "Délai d'inactivité de l'ALB partagé (s) : le keep-alive de gunicorn doit le dépasser."
  value       = data.aws_lb.shared.idle_timeout
}

output "listener_ssl_policy" {
  description = "Politique TLS de l'écouteur partagé (non modifiable par nous)."
  value       = data.aws_lb_listener.shared.ssl_policy
}

output "listener_rules" {
  description = "Nos règles sur l'écouteur partagé : priorité et noms d'hôte (contrôle du plan)."
  value = merge(
    { api = { priority = aws_lb_listener_rule.api.priority, hosts = sort(tolist(one(aws_lb_listener_rule.api.condition).host_header[0].values)) } },
    { for r in aws_lb_listener_rule.web : "web" => { priority = r.priority, hosts = sort(tolist(one(r.condition).host_header[0].values)) } },
  )
}
