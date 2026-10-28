"""Eventide task registrar (AWS Lambda, Python 3.12 runtime).

Registers a new revision of ONE of Eventide's own ECS task definition families, with a new
image, from the exact RegisterTaskDefinition input written by Terraform (config.json, packaged
with this file, never supplied by the caller).

Why: the AWS account is shared with CINAF, JobMinutes and Candidature Express. The GitHub deploy
role may only invoke this function. It never calls ecs:DescribeTaskDefinition (which only
accepts "*" and would let it read the task definitions of the other platforms, environment
variables included) nor ecs:RegisterTaskDefinition (whose restriction to a family is not
verified): it can neither read nor write a task definition outside Eventide. This function only
accepts a family key of its own configuration and a commit SHA.

Event:  {"family": "api" | "migrate" | "jobs", "image_tag": "<40 lowercase hex characters>"}
Result: {"taskDefinitionArn": "...", "family": "ev-<env>-<key>", "revision": <int>}
Any refusal raises RegistrationRefused (FunctionError for the caller); nothing is registered.
"""

from __future__ import annotations

import copy
import json
import re
from pathlib import Path
from typing import Any

IMAGE_TAG = re.compile(r"[0-9a-f]{40}")
OWN_PREFIX = re.compile(r"ev-[a-z0-9]+-")
EVENT_FIELDS = {"family", "image_tag"}


class RegistrationRefused(Exception):
    """The request does not designate one of our families and a commit SHA."""


def load_config(path: Path | None = None) -> dict[str, Any]:
    path = path or Path(__file__).with_name("config.json")
    return json.loads(path.read_text(encoding="utf-8"))


def build_request(event: Any, config: dict[str, Any]) -> dict[str, Any]:
    """Return the RegisterTaskDefinition input for the event, or raise RegistrationRefused."""
    if not isinstance(event, dict) or set(event) != EVENT_FIELDS:
        raise RegistrationRefused("event attendu : {family, image_tag}, rien d'autre")
    key, tag = event["family"], event["image_tag"]
    templates = config["templates"]
    if not isinstance(key, str) or key not in templates:
        raise RegistrationRefused(f"famille inconnue (attendu : {', '.join(sorted(templates))})")
    if not isinstance(tag, str) or not IMAGE_TAG.fullmatch(tag):
        raise RegistrationRefused("image_tag : SHA de commit complet (40 caracteres hexadecimaux)")

    prefix = config["family_prefix"]
    request = copy.deepcopy(templates[key])
    if not OWN_PREFIX.fullmatch(prefix) or request.get("family") != f"{prefix}{key}":
        raise RegistrationRefused("modele hors des familles d'Eventide")

    repository = config["image_repository"]
    replaced = 0
    for container in request.get("containerDefinitions", []):
        if str(container.get("image", "")).startswith(f"{repository}:"):
            container["image"] = f"{repository}:{tag}"
            replaced += 1
    if replaced == 0:
        raise RegistrationRefused("aucun conteneur de notre depot d'images dans le modele")

    request["tags"] = [{"key": k, "value": v} for k, v in sorted(config["tags"].items())]
    return request


def register(event: Any, ecs: Any, config: dict[str, Any]) -> dict[str, Any]:
    request = build_request(event, config)
    definition = ecs.register_task_definition(**request)["taskDefinition"]
    if definition["family"] != request["family"]:
        raise RegistrationRefused("famille enregistree inattendue")
    result = {
        "taskDefinitionArn": definition["taskDefinitionArn"],
        "family": definition["family"],
        "revision": definition["revision"],
    }
    print(json.dumps({"event": "task_definition_registered", **result}))  # noqa: T201 - Lambda log line
    return result


def handler(event: Any, context: Any) -> dict[str, Any]:
    import boto3  # provided by the Lambda runtime

    return register(event, boto3.client("ecs"), load_config())
