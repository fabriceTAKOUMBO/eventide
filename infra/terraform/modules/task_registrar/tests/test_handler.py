"""Unit tests of the task registrar (no AWS: the ECS client is a fake).

python3 -I -m unittest discover -s infra/terraform/modules/task_registrar/tests -v
"""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

HANDLER = Path(__file__).resolve().parents[1] / "files" / "handler.py"
spec = importlib.util.spec_from_file_location("registrar_handler", HANDLER)
registrar = importlib.util.module_from_spec(spec)
sys.modules["registrar_handler"] = registrar
spec.loader.exec_module(registrar)

REPO = "466494951409.dkr.ecr.us-east-1.amazonaws.com/ev-prod-api"
SHA = "0123456789abcdef0123456789abcdef01234567"
TASK_DEFINITION_ARN_PREFIX = "arn:aws:ecs:us-east-1:466494951409:task-definition/"


FAMILIES = ("api", "migrate", "jobs", "media")


def template(key: str) -> dict:
    request = {
        "family": f"ev-prod-{key}",
        "executionRoleArn": f"arn:aws:iam::466494951409:role/ev-prod-{key}-execution",
        "networkMode": "awsvpc",
        "requiresCompatibilities": ["FARGATE"],
        "cpu": "1024" if key == "media" else "256",
        "memory": "2048" if key == "media" else "512",
        "runtimePlatform": {"operatingSystemFamily": "LINUX", "cpuArchitecture": "ARM64"},
        "volumes": [{"name": "tmp"}],
        "containerDefinitions": [{"name": key, "image": f"{REPO}:bootstrap", "essential": True}],
    }
    # Same shape as modules/ecs: only api and media have a task role.
    if key in ("api", "media"):
        request["taskRoleArn"] = f"arn:aws:iam::466494951409:role/ev-prod-{key}-task"
    return request


def config() -> dict:
    return {
        "family_prefix": "ev-prod-",
        "image_repository": REPO,
        "templates": {k: template(k) for k in FAMILIES},
        "tags": {"Project": "eventide", "Environment": "prod"},
    }


class FakeEcs:
    def __init__(self, family_override: str | None = None):
        self.calls: list[dict] = []
        self.family_override = family_override

    def register_task_definition(self, **request):
        self.calls.append(request)
        family = self.family_override or request["family"]
        return {
            "taskDefinition": {
                "taskDefinitionArn": f"{TASK_DEFINITION_ARN_PREFIX}{family}:7",
                "family": family,
                "revision": 7,
            }
        }


class RegistrarTest(unittest.TestCase):
    def test_registers_our_family_with_the_new_image_and_our_tags(self):
        ecs = FakeEcs()
        result = registrar.register({"family": "api", "image_tag": SHA}, ecs, config())
        self.assertEqual(result["family"], "ev-prod-api")
        self.assertEqual(len(ecs.calls), 1)
        sent = ecs.calls[0]
        self.assertEqual(sent["family"], "ev-prod-api")
        self.assertEqual(sent["containerDefinitions"][0]["image"], f"{REPO}:{SHA}")
        self.assertIn({"key": "Project", "value": "eventide"}, sent["tags"])
        # Everything else is the Terraform template, untouched.
        expected = template("api")
        for field in ("executionRoleArn", "cpu", "memory", "volumes", "runtimePlatform"):
            self.assertEqual(sent[field], expected[field])

    def test_registers_the_media_family_with_its_own_roles(self):
        ecs = FakeEcs()
        result = registrar.register({"family": "media", "image_tag": SHA}, ecs, config())
        self.assertEqual(result["family"], "ev-prod-media")
        sent = ecs.calls[0]
        self.assertEqual(sent["containerDefinitions"][0]["image"], f"{REPO}:{SHA}")
        self.assertEqual(sent["taskRoleArn"], "arn:aws:iam::466494951409:role/ev-prod-media-task")
        self.assertEqual(
            sent["executionRoleArn"], "arn:aws:iam::466494951409:role/ev-prod-media-execution"
        )
        self.assertEqual((sent["cpu"], sent["memory"]), ("1024", "2048"))

    def test_families_without_a_task_role_get_none(self):
        ecs = FakeEcs()
        registrar.register({"family": "jobs", "image_tag": SHA}, ecs, config())
        self.assertNotIn("taskRoleArn", ecs.calls[0])

    def test_refuses_a_key_outside_the_closed_list_even_if_configured(self):
        cfg = config()
        cfg["templates"]["worker"] = {**template("jobs"), "family": "ev-prod-worker"}
        ecs = FakeEcs()
        with self.assertRaises(registrar.RegistrationRefused):
            registrar.register({"family": "worker", "image_tag": SHA}, ecs, cfg)
        self.assertEqual(ecs.calls, [])

    def test_refuses_a_template_naming_a_role_outside_eventide(self):
        for field, role in (
            ("taskRoleArn", "arn:aws:iam::466494951409:role/cinaf-streaming-task"),
            ("taskRoleArn", "arn:aws:iam::466494951409:role/ce-prod-api-task"),
            ("taskRoleArn", "arn:aws:iam::466494951409:role/ev-preprod-media-task"),
            ("executionRoleArn", "arn:aws:iam::466494951409:role/jobminutes-execution"),
            ("executionRoleArn", "arn:aws:iam::466494951409:role/aws-reserved/x/ev-prod-a"),
        ):
            cfg = config()
            cfg["templates"]["media"][field] = role
            ecs = FakeEcs()
            with self.assertRaises(registrar.RegistrationRefused, msg=role):
                registrar.register({"family": "media", "image_tag": SHA}, ecs, cfg)
            self.assertEqual(ecs.calls, [], role)

    def test_refuses_a_template_without_execution_role(self):
        cfg = config()
        del cfg["templates"]["jobs"]["executionRoleArn"]
        with self.assertRaises(registrar.RegistrationRefused):
            registrar.register({"family": "jobs", "image_tag": SHA}, FakeEcs(), cfg)

    def test_templates_are_not_mutated(self):
        cfg = config()
        registrar.register({"family": "jobs", "image_tag": SHA}, FakeEcs(), cfg)
        self.assertEqual(
            cfg["templates"]["jobs"]["containerDefinitions"][0]["image"], f"{REPO}:bootstrap"
        )

    def test_refuses_a_family_outside_its_configuration(self):
        for family in ("cinaf-api", "ce-prod-api", "ev-prod-api", "ev-prod-media", "", None, 3):
            ecs = FakeEcs()
            with self.assertRaises(registrar.RegistrationRefused):
                registrar.register({"family": family, "image_tag": SHA}, ecs, config())
            self.assertEqual(ecs.calls, [], family)

    def test_refuses_anything_but_a_full_commit_sha(self):
        for tag in ("latest", SHA[:7], SHA.upper(), f"{SHA}\n", f"{SHA}@sha256:x", "", None):
            ecs = FakeEcs()
            with self.assertRaises(registrar.RegistrationRefused):
                registrar.register({"family": "api", "image_tag": tag}, ecs, config())
            self.assertEqual(ecs.calls, [])

    def test_refuses_extra_fields_so_the_caller_cannot_override_the_template(self):
        for extra in (
            {"executionRoleArn": "arn:aws:iam::466494951409:role/cinaf"},
            {"family_name": "x"},
        ):
            with self.assertRaises(registrar.RegistrationRefused):
                registrar.register(
                    {"family": "api", "image_tag": SHA, **extra}, FakeEcs(), config()
                )
        with self.assertRaises(registrar.RegistrationRefused):
            registrar.register(["api", SHA], FakeEcs(), config())

    def test_refuses_a_template_outside_our_families(self):
        cfg = config()
        cfg["templates"]["api"]["family"] = "cinaf-streaming-api"
        with self.assertRaises(registrar.RegistrationRefused):
            registrar.register({"family": "api", "image_tag": SHA}, FakeEcs(), cfg)
        cfg = config()
        cfg["family_prefix"] = "cinaf-"
        cfg["templates"]["api"]["family"] = "cinaf-api"
        with self.assertRaises(registrar.RegistrationRefused):
            registrar.register({"family": "api", "image_tag": SHA}, FakeEcs(), cfg)

    def test_refuses_a_template_without_our_image(self):
        cfg = config()
        cfg["templates"]["api"]["containerDefinitions"][0]["image"] = "public.ecr.aws/x/y:1"
        with self.assertRaises(registrar.RegistrationRefused):
            registrar.register({"family": "api", "image_tag": SHA}, FakeEcs(), cfg)

    def test_unexpected_registered_family_is_reported(self):
        with self.assertRaises(registrar.RegistrationRefused):
            registrar.register({"family": "api", "image_tag": SHA}, FakeEcs("other"), config())

    def test_load_config_reads_the_packaged_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.json"
            path.write_text(json.dumps(config()), encoding="utf-8")
            self.assertEqual(registrar.load_config(path)["family_prefix"], "ev-prod-")


if __name__ == "__main__":
    unittest.main()
