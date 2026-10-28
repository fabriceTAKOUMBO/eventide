from django.urls import path

from .views import AccountExportView, AccountView, GoogleLinkView

urlpatterns = [
    path("account/google", GoogleLinkView.as_view(), name="account-google"),
    path("account/export", AccountExportView.as_view(), name="account-export"),
    path("account", AccountView.as_view(), name="account"),
]
