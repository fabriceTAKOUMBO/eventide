from django.urls import path

from .views import ShareDetailView, SharesView

urlpatterns = [
    path("shares", SharesView.as_view(), name="shares"),
    path("shares/<str:code>", ShareDetailView.as_view(), name="share-detail"),
]
