from django.urls import path

from . import views

urlpatterns = [
    path("m/<str:code>", views.share_page, name="share-page"),
    path("s", views.standalone_share_page, name="standalone-share-page"),
    path(".well-known/assetlinks.json", views.assetlinks, name="assetlinks"),
    path("confidentialite", views.privacy, name="privacy"),
]
