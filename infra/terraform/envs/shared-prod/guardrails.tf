# Garde-fous de coût d'Eventide, filtrés sur l'étiquette de répartition des coûts
# Project = eventide (clé Project déjà active dans Billing pour CINAF, JobMinutes et Candidature
# Express ; la valeur eventide apparaît jusqu'à 24 h après les premières ressources).
# Sans étiquette active, le budget reste à 0 et le moniteur ne voit rien.

resource "aws_budgets_budget" "monthly" {
  count        = var.cost_guardrails_enabled ? 1 : 0
  name         = "eventide-mensuel"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = ["user:Project$eventide"]
  }

  dynamic "notification" {
    for_each = [
      { type = "ACTUAL", threshold = 50 },
      { type = "ACTUAL", threshold = 80 },
      { type = "ACTUAL", threshold = 100 },
      { type = "FORECASTED", threshold = 100 },
    ]
    content {
      comparison_operator        = "GREATER_THAN"
      notification_type          = notification.value.type
      threshold                  = notification.value.threshold
      threshold_type             = "PERCENTAGE"
      subscriber_email_addresses = var.budget_emails
    }
  }
}

resource "aws_ce_anomaly_monitor" "project" {
  count        = var.cost_guardrails_enabled ? 1 : 0
  name         = "eventide"
  monitor_type = "CUSTOM"

  # Forme exacte relue par AWS (clé préfixée « user: », expressions vides à null) : sinon chaque
  # plan remplace le moniteur (constat de Candidature Express).
  monitor_specification = jsonencode({
    And            = null
    CostCategories = null
    Dimensions     = null
    Not            = null
    Or             = null
    Tags = {
      Key          = "user:Project"
      Values       = ["eventide"]
      MatchOptions = ["EQUALS"]
    }
  })
}

resource "aws_ce_anomaly_subscription" "project" {
  count            = var.cost_guardrails_enabled ? 1 : 0
  name             = "eventide-anomalies"
  frequency        = "DAILY"
  monitor_arn_list = [aws_ce_anomaly_monitor.project[0].arn]

  dynamic "subscriber" {
    for_each = var.budget_emails
    content {
      type    = "EMAIL"
      address = subscriber.value
    }
  }

  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      match_options = ["GREATER_THAN_OR_EQUAL"]
      values        = [tostring(var.anomaly_threshold_usd)]
    }
  }
}
