"""URL map: API under /v1/ (contract), web pages of contract § 9 at the root, administration
dashboard under /tableau/ (contract § 14)."""

from django.urls import include, path

from apps.publishing.api import CatalogView

urlpatterns = [
    path("v1/", include("apps.installations.urls")),
    path("v1/", include("apps.accounts.urls")),
    path("v1/", include("apps.entitlements.urls")),
    path("v1/", include("apps.shares.urls")),
    path("v1/", include("apps.content.urls")),
    path("v1/catalog", CatalogView.as_view(), name="catalog"),
    path("", include("apps.web.urls")),
    path("", include("apps.publishing.urls")),
]

handler404 = "apps.core.errors.json_404"
handler500 = "apps.core.errors.json_500"
