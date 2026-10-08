// Language switch. The page holds both languages; <html data-lang> picks one (set early by the
// inline script in <head> from ?lang=, the saved choice, or the browser's first language).
(function () {
  var root = document.documentElement;
  var titles = { zh: root.getAttribute("data-title-zh"), en: root.getAttribute("data-title-en") };

  function apply(lang) {
    root.setAttribute("data-lang", lang);
    root.lang = lang === "zh" ? "zh-Hans" : "en";
    if (titles[lang]) document.title = titles[lang];
    var buttons = document.querySelectorAll("[data-set-lang]");
    for (var i = 0; i < buttons.length; i++) {
      buttons[i].setAttribute("aria-pressed", buttons[i].getAttribute("data-set-lang") === lang ? "true" : "false");
    }
  }

  apply(root.getAttribute("data-lang") === "en" ? "en" : "zh");
  document.addEventListener("click", function (event) {
    var button = event.target.closest && event.target.closest("[data-set-lang]");
    if (!button) return;
    var lang = button.getAttribute("data-set-lang");
    try { localStorage.setItem("pc-lang", lang); } catch (e) {}
    // a ?lang= in the address would win on reload, so it follows the choice
    try {
      var url = new URL(location.href);
      if (url.searchParams.has("lang")) { url.searchParams.set("lang", lang); history.replaceState(null, "", url); }
    } catch (e) {}
    apply(lang);
  });
})();
