from django.urls import path

from .views import EntitlementsView, PurchasesView, RtdnView

urlpatterns = [
    path("entitlements", EntitlementsView.as_view(), name="entitlements"),
    path("purchases", PurchasesView.as_view(), name="purchases"),
    path("play/rtdn", RtdnView.as_view(), name="play-rtdn"),
]
