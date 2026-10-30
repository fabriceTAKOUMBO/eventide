// Full Relax — tableau de bord, page d'un élément :
//  * envoi du fichier source directement du navigateur vers le stockage (formulaire signé par
//    le serveur), avec une barre de progression, puis lancement du traitement ;
//  * pendant le traitement, l'état est relu toutes les 4 s (même origine, session) et la page
//    se recharge quand il change ;
//  * un seul traitement à la fois : si un autre fichier est en cours, le lancement est retenté
//    toutes les 15 s tant que la page est ouverte (bouton « Lancer le traitement » sinon).
(function () {
  "use strict";
  var POLL_MS = 4000;
  var RETRY_MS = 15000;
  var etat = document.getElementById("etat");
  var envoi = document.getElementById("envoi");

  function post(url, data, csrf) {
    return fetch(url, {
      method: "POST",
      credentials: "same-origin",
      cache: "no-store",
      headers: { "X-CSRFToken": csrf, "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams(data).toString()
    }).then(function (response) {
      return response.json().catch(function () { return {}; }).then(function (body) {
        return { ok: response.ok, body: body };
      });
    });
  }

  function follow() {
    if (!etat || etat.getAttribute("data-suivre") !== "1") { return; }
    var url = etat.getAttribute("data-url");
    var timer = window.setInterval(function () {
      if (document.hidden) { return; }
      fetch(url, { credentials: "same-origin", cache: "no-store" })
        .then(function (response) { return response.ok ? response.json() : null; })
        .then(function (body) {
          if (body && body.etat !== "traitement") {
            window.clearInterval(timer);
            window.location.reload();
          }
        })
        .catch(function () { /* next tick */ });
    }, POLL_MS);
  }

  function sendToStorage(form, file, bar, status) {
    return new Promise(function (resolve, reject) {
      var data = new FormData();
      Object.keys(form.fields).forEach(function (name) { data.append(name, form.fields[name]); });
      data.append("file", file); // the file comes last: S3 ignores fields after it
      var xhr = new XMLHttpRequest();
      xhr.open("POST", form.url);
      xhr.upload.onprogress = function (event) {
        if (!event.lengthComputable) { return; }
        var percent = Math.round((100 * event.loaded) / event.total);
        bar.hidden = false;
        bar.value = percent;
        status.textContent = "Envoi : " + percent + " %";
      };
      xhr.onload = function () {
        if (xhr.status >= 200 && xhr.status < 300) { resolve(); return; }
        reject(new Error("Le stockage a refusé le fichier (" + xhr.status + ")."));
      };
      xhr.onerror = function () {
        reject(new Error("Envoi interrompu : vérifiez la connexion, puis réessayez."));
      };
      xhr.send(data);
    });
  }

  function upload() {
    var input = document.getElementById("fichier");
    var button = document.getElementById("envoyer");
    var bar = document.getElementById("progression");
    var status = document.getElementById("envoi-statut");
    if (!envoi || !input || !button) { return; }
    var csrf = envoi.getAttribute("data-csrf");
    var maxMo = Number(envoi.getAttribute("data-max"));

    button.addEventListener("click", function () {
      var file = input.files && input.files[0];
      if (!file) { status.textContent = "Choisissez d'abord un fichier."; return; }
      if (file.size > maxMo * 1000000) {
        status.textContent = "Fichier trop lourd : " + maxMo + " Mo au plus.";
        return;
      }
      var extension = (file.name.split(".").pop() || "").toLowerCase();
      button.disabled = true;
      input.disabled = true;
      status.textContent = "Préparation de l'envoi…";
      var uploadId = null;
      post(envoi.getAttribute("data-envoi"), { extension: extension }, csrf)
        .then(function (res) {
          if (!res.ok) { throw new Error(res.body.detail || "Envoi refusé."); }
          uploadId = res.body.upload_id;
          return sendToStorage(res.body, file, bar, status);
        })
        .then(function () {
          status.textContent = "Fichier reçu. Lancement du traitement…";
          launch(uploadId, status);
        })
        .catch(function (error) {
          status.textContent = error.message;
          button.disabled = false;
          input.disabled = false;
          bar.hidden = true;
        });
    });
  }

  // One media task at a time: while another file is processed, the source waits on the
  // storage and the launch is tried again every 15 s as long as the page is open.
  function launch(uploadId, status) {
    var csrf = envoi.getAttribute("data-csrf");
    post(envoi.getAttribute("data-fini"), { upload_id: uploadId }, csrf)
      .then(function (res) {
        if (res.ok) { window.location.reload(); return; }
        if (res.body.error === "busy") {
          status.textContent = (res.body.detail || "") + " Nouvel essai automatique dans 15 s.";
          window.setTimeout(function () { launch(uploadId, status); }, RETRY_MS);
          return;
        }
        status.textContent = res.body.detail || "Le traitement n'a pas démarré.";
      })
      .catch(function () {
        status.textContent = "Connexion perdue : rechargez la page.";
      });
  }

  function relaunch() {
    var button = document.getElementById("lancer");
    var status = document.getElementById("lancer-statut");
    if (!envoi || !button) { return; }
    button.addEventListener("click", function () {
      button.disabled = true;
      status.textContent = "Lancement du traitement…";
      launch(button.getAttribute("data-upload"), status);
    });
  }

  follow();
  upload();
  relaunch();
})();
