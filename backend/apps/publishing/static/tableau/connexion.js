// Full Relax — tableau de bord : bouton « Se connecter avec Google » (Google Identity Services).
// Le jeton d'identité reçu part dans un formulaire de la même origine, avec le jeton CSRF
// (POST /tableau/connexion) : le serveur vérifie la signature, l'audience et l'adresse.
(function () {
  "use strict";

  function start() {
    var container = document.getElementById("connexion-google");
    var form = document.getElementById("connexion-form");
    if (!container || !form || !window.google || !google.accounts || !google.accounts.id) { return; }
    google.accounts.id.initialize({
      client_id: container.getAttribute("data-client-id"),
      callback: function (response) {
        if (!response || !response.credential) { return; }
        form.elements.credential.value = response.credential;
        form.submit();
      },
      auto_select: false,
      cancel_on_tap_outside: true,
      ux_mode: "popup",
      context: "signin"
    });
    google.accounts.id.renderButton(container, {
      type: "standard",
      theme: "filled_black",
      size: "large",
      text: "signin_with",
      shape: "pill",
      locale: "fr"
    });
  }

  // Google's script (loaded after this one, async) calls this hook once it is ready.
  window.onGoogleLibraryLoad = start;
  if (window.google && window.google.accounts) { start(); }
})();
