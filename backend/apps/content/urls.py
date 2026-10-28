from django.urls import path

from .views import ContentUrlsView

urlpatterns = [path("content/urls", ContentUrlsView.as_view(), name="content-urls")]
