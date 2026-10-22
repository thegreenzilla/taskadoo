/* Taskadoo landing page → app links. Added to the exported design by build.py; the design file itself is unchanged. */
(function () {
  var APP = 'app/';
  var CATS = { 'bedroom': 'bedroom', 'storage & shelving': 'storage', 'office': 'office', 'living room': 'living', 'tv & wall mounting': 'tv', 'dining': 'dining' };
  document.addEventListener('click', function (e) {
    var el = e.target && e.target.closest ? e.target.closest('a,button') : null;
    if (!el) return;
    var t = (el.textContent || '').replace(/\s+/g, ' ').trim().toLowerCase(), h = null;
    if (/^browse items/.test(t)) { var sel = document.querySelector('select'); h = '#/shop/' + (sel && sel.value ? sel.value : 'bedroom'); }
    else if (/^(book now|book an assembler|browse the catalog|see all categories|furniture assembly)\b/.test(t) || /^request /.test(t)) h = '#/book';
    else if (/^tv mounting$/.test(t)) h = '#/shop/tv';
    else if (/^(log in|sign in to your portal)/.test(t)) h = '#/login';
    else if (/^for business|taskadoo for business|create an enterprise account/.test(t)) h = '#/signup/enterprise';
    else if (/^become an assembler/.test(t)) { e.preventDefault(); e.stopPropagation(); location.href = 'assembler/#/join'; return; }   // the Taskadooer sign-up in the assembler app
    else if (/upload (your |a )?receipt|^upload receipt|have a receipt|^receipt quotation/.test(t)) h = '#/receipt';
    else { for (var k in CATS) { if (t.indexOf(k) === 0 && /items/.test(t)) { h = '#/shop/' + CATS[k]; break; } } }
    if (h) { e.preventDefault(); e.stopPropagation(); location.href = APP + h; }
  }, true);
  // hidden staff link: the "© 2026 Taskadoo" line in the footer opens the staff portal (looks unchanged)
  document.addEventListener('click', function (e) {
    var n = e.target; if (!n || el(n)) return;
    var s = (n.textContent || '').trim();
    if (/^© 20\d\d Taskadoo/.test(s) && s.length < 60) location.href = 'staff/';
    function el(x) { return x.closest && x.closest('a,button'); }
  }, true);
})();

/* Hero photo: if staging/hero.jpg exists, it fills the "Photo of an assembler" box. No photo = the design's placeholder stays. */
(function () {
  var img = new Image();
  img.onload = function () {
    var tries = 0, t = setInterval(function () {
      var all = [].slice.call(document.querySelectorAll('div,span,p')).filter(function (n) { return /^Photo of an assembler/.test((n.textContent || '').trim()); });
      var el = all[all.length - 1];   // the innermost element holding the placeholder text
      if (el || ++tries > 40) clearInterval(t);
      if (!el) return;
      var box = el.parentElement; while (box && box.offsetHeight < 200) box = box.parentElement;   // the 4:5 picture frame
      if (!box) return;
      el.style.display = 'none';
      box.style.backgroundImage = 'url(hero.jpg)'; box.style.backgroundSize = 'cover'; box.style.backgroundPosition = 'center';
    }, 150);
  };
  img.src = 'hero.jpg?v=' + Date.now().toString().slice(0, 7);
})();
