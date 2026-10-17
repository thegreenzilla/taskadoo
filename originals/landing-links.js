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
    else if (/^become an assembler/.test(t)) h = '#/signup/assembler';
    else if (/upload (your |a )?receipt|^upload receipt|have a receipt|^receipt quotation/.test(t)) h = '#/receipt';
    else { for (var k in CATS) { if (t.indexOf(k) === 0 && /items/.test(t)) { h = '#/shop/' + CATS[k]; break; } } }
    if (h) { e.preventDefault(); e.stopPropagation(); location.href = APP + h; }
  }, true);
})();
