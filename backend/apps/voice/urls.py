from django.urls import path

from .views import VoiceView

urlpatterns = [path("voice", VoiceView.as_view(), name="voice")]
