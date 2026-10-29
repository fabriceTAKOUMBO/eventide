"""System checks run by ``manage.py check --deploy`` (CI, prod settings)."""

from django.conf import settings
from django.core.checks import Tags, Warning, register


@register(Tags.security, deploy=True)
def eventide_deploy_checks(app_configs, **kwargs):
    warnings = []
    if not settings.PLAY_INTEGRITY_ENFORCED:
        warnings.append(
            Warning(
                "PLAY_INTEGRITY_ENFORCED=false: POST /installations accepts any device.",
                hint="Development only (contract § 4).",
                id="eventide.W001",
            )
        )
    return warnings
