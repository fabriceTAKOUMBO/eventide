"""URL map: API under /v1/ (contract), web pages of contract § 9 at the root."""

from django.urls import include, path

urlpatterns = [
    path("v1/", include("apps.installations.urls")),
    path("v1/", include("apps.accounts.urls")),
    path("v1/", include("apps.entitlements.urls")),
    path("v1/", include("apps.shares.urls")),
    path("v1/", include("apps.content.urls")),
    path("", include("apps.web.urls")),
]

handler404 = "apps.core.errors.json_404"
handler500 = "apps.core.errors.json_500"
