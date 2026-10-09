// Language switch. The page holds both languages; <html data-lang> picks one (set early by the
// inline script in <head> from ?lang=, the saved choice, or the browser's first language).
(function () {
  var root = document.documentElement;
  var titles = { zh: root.getAttribute("data-title-zh"), en: root.getAttribute("data-title-en") };
  var motion = root.classList.contains("motion");

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
    // the newly shown language fades in
    var main = document.querySelector("main");
    if (motion && main) {
      main.classList.remove("lang-fade");
      void main.offsetWidth;
      main.classList.add("lang-fade");
    }
  });

  // Scroll reveal. The head script set .motion before the first paint, which keeps each .reveal hidden
  // until it comes into view; marking the page ready stops that script from taking .motion back.
  if (motion) {
    root.setAttribute("data-motion-ready", "");
    var observer = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (!entry.isIntersecting) return;
        entry.target.classList.add("in");
        observer.unobserve(entry.target);
      });
    }, { rootMargin: "0px 0px -8% 0px", threshold: 0.12 });
    var targets = document.querySelectorAll(".reveal");
    for (var i = 0; i < targets.length; i++) observer.observe(targets[i]);
  }
})();
