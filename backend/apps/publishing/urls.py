"""Dashboard pages (contract § 14), under /tableau/ on the domain host."""

from django.urls import path
from django.views.generic import RedirectView

from . import views

urlpatterns = [
    path("tableau", RedirectView.as_view(url="/tableau/", permanent=False)),
    path("tableau/", views.catalogue, name="tableau-catalogue"),
    path("tableau/connexion", views.login, name="tableau-connexion"),
    path("tableau/deconnexion", views.logout, name="tableau-deconnexion"),
    path("tableau/elements/nouveau", views.new_element, name="tableau-nouveau"),
    path("tableau/elements/<uuid:pk>", views.element, name="tableau-element"),
    path("tableau/elements/<uuid:pk>/etat", views.element_state, name="tableau-etat"),
    path("tableau/elements/<uuid:pk>/envoi", views.upload_start, name="tableau-envoi"),
    path("tableau/elements/<uuid:pk>/envoi-termine", views.upload_done, name="tableau-envoi-fini"),
    path("tableau/elements/<uuid:pk>/publier", views.publish, name="tableau-publier"),
    path("tableau/elements/<uuid:pk>/retirer", views.withdraw, name="tableau-retirer"),
    path("tableau/elements/<uuid:pk>/modifier", views.edit, name="tableau-modifier"),
    path("tableau/utilisateurs", views.users, name="tableau-utilisateurs"),
    path("tableau/journal", views.journal, name="tableau-journal"),
]
