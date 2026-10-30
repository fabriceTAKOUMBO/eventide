// Full Relax — lien de partage autonome : https://<domaine>/s#<base64url(JSON compact de la scène)>.
// Le fragment ne quitte jamais le navigateur ; ce script l'affiche avec les noms du catalogue.
(function () {
  "use strict";
  var catalogue = JSON.parse(document.getElementById("catalogue").textContent);
  var fragment = window.location.hash.slice(1);
  if (!fragment || fragment.length > 4096) { return; }

  function decode(text) {
    var b64 = text.replace(/-/g, "+").replace(/_/g, "/");
    while (b64.length % 4) { b64 += "="; }
    var bytes = Uint8Array.from(atob(b64), function (c) { return c.charCodeAt(0); });
    return JSON.parse(new TextDecoder().decode(bytes));
  }

  var scene;
  try { scene = decode(fragment); } catch (e) { return; }
  if (!scene || scene.version !== 1 || !catalogue.paysages[scene.paysage]) { return; }

  var sections = [["sons", "sons", "Sons"], ["musique", "musiques", "Musique"], ["decor", "decors", "Décor"]];
  var paysage = catalogue.paysages[scene.paysage];
  document.getElementById("mix-paysage").textContent = paysage.nom + (paysage.gratuit ? "" : " (Premium)");
  var list = document.getElementById("mix-couches");
  sections.forEach(function (s) {
    (Array.isArray(scene[s[0]]) ? scene[s[0]] : []).forEach(function (item) {
      var entry = item && catalogue[s[1]][item.id];
      var level = item && Number.isInteger(item.niveau) ? item.niveau : null;
      if (!entry || level === null || level < 0 || level > 100) { return; }
      var li = document.createElement("li");
      li.textContent = s[2] + " : " + entry.nom + " " + level + " %" + (entry.gratuit ? "" : " (Premium)");
      list.appendChild(li);
    });
  });
  document.getElementById("mix").hidden = false;
  document.getElementById("mix-absent").hidden = true;
})();
