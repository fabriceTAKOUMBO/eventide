#!/usr/bin/env bash
# Attend la fin du déploiement ECS d'un service et vérifie qu'il a bien abouti sur la
# définition de tâche attendue.
#
# `aws ecs wait services-stable` réussit aussi quand le disjoncteur de déploiement a fait
# revenir le service sur l'ancienne révision : on contrôle donc explicitement que le
# déploiement PRIMARY porte la nouvelle révision et que son rolloutState vaut COMPLETED.
#
# Usage : ecs-wait-deployment.sh <cluster> <service> <task-definition-arn> [timeout-secondes]
set -euo pipefail

cluster="$1"
service="$2"
expected_taskdef="$3"
timeout="${4:-1200}"
interval=15
elapsed=0

while :; do
  state=$(aws ecs describe-services --cluster "$cluster" --services "$service" --output json \
    | jq -c '.services[0] | {
        primary: (.deployments[] | select(.status == "PRIMARY") | {taskDefinition, rolloutState, rolloutStateReason, runningCount, desiredCount}),
        deployments: (.deployments | length)
      }')
  taskdef=$(echo "$state" | jq -r '.primary.taskDefinition')
  rollout=$(echo "$state" | jq -r '.primary.rolloutState')
  running=$(echo "$state" | jq -r '.primary.runningCount')
  desired=$(echo "$state" | jq -r '.primary.desiredCount')
  count=$(echo "$state" | jq -r '.deployments')

  if [ "$taskdef" != "$expected_taskdef" ]; then
    echo "::error::$service : le déploiement PRIMARY porte $taskdef au lieu de $expected_taskdef (retour arrière automatique du disjoncteur ?)."
    echo "$state" | jq .
    exit 1
  fi

  case "$rollout" in
    COMPLETED)
      if [ "$count" = "1" ]; then
        echo "$service : déploiement terminé ($running/$desired tâches sur $taskdef)."
        exit 0
      fi
      ;;
    FAILED)
      echo "::error::$service : déploiement en échec : $(echo "$state" | jq -r '.primary.rolloutStateReason')"
      aws ecs describe-services --cluster "$cluster" --services "$service" \
        --query 'services[0].events[:10].[createdAt,message]' --output text || true
      exit 1
      ;;
  esac

  if [ "$elapsed" -ge "$timeout" ]; then
    echo "::error::$service : délai de ${timeout}s dépassé (état $rollout, $running/$desired tâches, $count déploiements)."
    aws ecs describe-services --cluster "$cluster" --services "$service" \
      --query 'services[0].events[:10].[createdAt,message]' --output text || true
    exit 1
  fi

  echo "$service : $rollout, $running/$desired tâches, $count déploiement(s) actifs... (${elapsed}s)"
  sleep "$interval"
  elapsed=$((elapsed + interval))
done
