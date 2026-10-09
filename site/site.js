// Each language is its own page (script/build_site.py builds them from site-src/). The language switch
// links between them; remembering the choice keeps the English page, the default, from sending this
// visitor to the Chinese one (the script in each page's <head>).
(function () {
  var root = document.documentElement;

  document.addEventListener("click", function (event) {
    var link = event.target.closest && event.target.closest(".lang-switch a[hreflang]");
    if (!link) return;
    try { localStorage.setItem("pc-lang", link.getAttribute("hreflang") === "en" ? "en" : "zh"); } catch (e) {}
  });

  // Scroll reveal. The head script set .motion before the first paint, which keeps each .reveal hidden
  // until it comes into view; marking the page ready stops that script from taking .motion back.
  if (root.classList.contains("motion")) {
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
