from django.apps import AppConfig


class CoreConfig(AppConfig):
    name = "apps.core"
    label = "core"
    verbose_name = "Eventide core"

    def ready(self) -> None:
        from . import checks  # noqa: F401  (registers the system checks)
