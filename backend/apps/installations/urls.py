from django.urls import path

from .views import InstallationsView

urlpatterns = [path("installations", InstallationsView.as_view(), name="installations")]
