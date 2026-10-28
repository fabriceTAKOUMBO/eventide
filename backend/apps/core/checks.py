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
    if (
        settings.VOICE_ROUTER == "gemini"
        and settings.GEMINI_MODEL not in settings.VOICE_PRICE_TABLE
    ):
        warnings.append(Warning("GEMINI_MODEL has no price.", id="eventide.W002"))
    return warnings
