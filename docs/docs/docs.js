// 文档页的少量交互：顶栏阴影、手机端目录抽屉、当前页高亮
(function () {
  var appBar = document.getElementById('appbar');
  function onScroll() {
    appBar.classList.toggle('scrolled', window.scrollY > 4);
  }
  window.addEventListener('scroll', onScroll, { passive: true });
  onScroll();

  var menu = document.getElementById('menu');
  var scrim = document.getElementById('scrim');
  function setOpen(open) {
    document.body.classList.toggle('nav-open', open);
    if (menu) menu.setAttribute('aria-expanded', open ? 'true' : 'false');
  }
  if (menu) {
    menu.addEventListener('click', function () {
      setOpen(!document.body.classList.contains('nav-open'));
    });
  }
  if (scrim) scrim.addEventListener('click', function () { setOpen(false); });
  window.addEventListener('keydown', function (e) {
    if (e.key === 'Escape') setOpen(false);
  });
  // 点击目录里的链接后收起抽屉
  Array.prototype.forEach.call(document.querySelectorAll('.sidebar a'), function (a) {
    a.addEventListener('click', function () { setOpen(false); });
  });

  // 没有在 HTML 里标 active 时，按文件名兜底
  var here = location.pathname.split('/').pop() || 'index.html';
  Array.prototype.forEach.call(document.querySelectorAll('.sidebar a[href]'), function (a) {
    if (!document.querySelector('.sidebar a.active') && a.getAttribute('href') === here) {
      a.classList.add('active');
    }
  });
})();
