// 文档页的交互：顶栏阴影、手机端目录抽屉、当前页高亮、站内搜索
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
  Array.prototype.forEach.call(document.querySelectorAll('.sidebar a'), function (a) {
    a.addEventListener('click', function () { setOpen(false); });
  });

  var here = location.pathname.split('/').pop() || 'index.html';
  Array.prototype.forEach.call(document.querySelectorAll('.sidebar a[href]'), function (a) {
    if (!document.querySelector('.sidebar a.active') && a.getAttribute('href') === here) {
      a.classList.add('active');
    }
  });

  // ---------- 搜索：第一次输入时才加载各页内容，不需要构建步骤 ----------
  var PAGES = [
    'index.html', 'install.html', 'first-run.html', 'versions.html',
    'resources.html', 'android.html', 'ai.html', 'troubleshooting.html', 'api.html', 'icons.html'
  ];
  var input = document.getElementById('q');
  var results = document.getElementById('results');
  var index = null;
  var timer = 0;

  function normalize(s) { return s.replace(/\s+/g, ' ').trim(); }

  function loadIndex() {
    if (index) return index;
    index = Promise.all(PAGES.map(function (page) {
      return fetch(page, { cache: 'force-cache' })
        .then(function (res) {
          if (!res.ok) throw new Error(res.status);
          return res.text();
        })
        .then(function (html) {
          var doc = new DOMParser().parseFromString(html, 'text/html');
          var article = doc.querySelector('article');
          if (!article) return [];
          var pageTitle = normalize((doc.querySelector('h1') || article).textContent);
          var sections = [];
          var current = { page: page, pageTitle: pageTitle, heading: '', anchor: '', text: '' };
          Array.prototype.forEach.call(article.children, function (el) {
            var tag = el.tagName.toLowerCase();
            if (tag === 'h2' || tag === 'h3') {
              if (current.heading || current.text) sections.push(current);
              current = {
                page: page, pageTitle: pageTitle,
                heading: normalize(el.textContent), anchor: el.getAttribute('id') || '', text: ''
              };
            } else if (tag === 'p' || tag === 'ul' || tag === 'ol' || tag === 'pre' ||
                       tag === 'table' || tag === 'div') {
              current.text += ' ' + normalize(el.textContent);
            }
          });
          if (current.heading || current.text) sections.push(current);
          return sections;
        })
        .catch(function () { return []; });
    })).then(function (groups) {
      return [].concat.apply([], groups);
    });
    return index;
  }

  function terms(q) {
    return q.toLowerCase().split(/\s+/).filter(Boolean);
  }

  function escapeHtml(s) {
    return s.replace(/[&<>"]/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c];
    });
  }

  // 先把查询词转义成正则，再按文本片段拼接高亮，避免破坏 HTML
  function highlight(s, ts) {
    if (!ts.length) return escapeHtml(s);
    var pattern = ts.slice().sort(function (a, b) { return b.length - a.length; })
      .map(function (t) { return t.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }).join('|');
    var re = new RegExp('(' + pattern + ')', 'gi');
    var out = '';
    var last = 0;
    var m;
    while ((m = re.exec(s)) !== null) {
      if (!m[0]) { re.lastIndex++; continue; }
      out += escapeHtml(s.slice(last, m.index)) + '<mark>' + escapeHtml(m[0]) + '</mark>';
      last = m.index + m[0].length;
    }
    return out + escapeHtml(s.slice(last));
  }

  function snippet(text, ts) {
    var lower = text.toLowerCase();
    var at = -1;
    ts.forEach(function (t) {
      var i = lower.indexOf(t);
      if (i >= 0 && (at < 0 || i < at)) at = i;
    });
    if (at < 0) at = 0;
    var start = Math.max(0, at - 32);
    var end = Math.min(text.length, at + 96);
    var part = (start > 0 ? '…' : '') + text.slice(start, end) + (end < text.length ? '…' : '');
    return highlight(part, ts);
  }

  function search(q) {
    var ts = terms(q);
    if (!ts.length) return Promise.resolve([]);
    return loadIndex().then(function (items) {
      var hits = [];
      items.forEach(function (it) {
        var head = (it.pageTitle + ' ' + it.heading).toLowerCase();
        var body = it.text.toLowerCase();
        var ok = ts.every(function (t) { return head.indexOf(t) >= 0 || body.indexOf(t) >= 0; });
        if (!ok) return;
        var score = 0;
        ts.forEach(function (t) {
          if (it.heading.toLowerCase().indexOf(t) >= 0) score += 10;
          else if (it.pageTitle.toLowerCase().indexOf(t) >= 0) score += 6;
          var pos = body.indexOf(t);
          if (pos >= 0) score += 3 - Math.min(2, pos / 400);
        });
        hits.push({ item: it, score: score });
      });
      hits.sort(function (a, b) { return b.score - a.score; });
      return hits.slice(0, 8).map(function (h) { return h.item; });
    });
  }

  function render(q, items) {
    var ts = terms(q);
    results.innerHTML = '';
    if (!items.length) {
      results.innerHTML = '<div class="search-empty">没有找到「' + escapeHtml(q) + '」</div>';
    } else {
      var count = document.createElement('div');
      count.className = 'search-empty';
      count.textContent = '找到 ' + items.length + ' 条结果';
      results.appendChild(count);
      items.forEach(function (it) {
        var a = document.createElement('a');
        a.href = it.page + (it.anchor ? '#' + it.anchor : '');
        var title = it.heading || it.pageTitle;
        var meta = it.heading ? escapeHtml(it.pageTitle) : '';
        if (it.text) meta += (meta ? ' · ' : '') + snippet(it.text, ts);
        a.innerHTML = '<span class="t">' + highlight(title, ts) + '</span>' +
          (meta ? '<span class="m">' + meta + '</span>' : '');
        results.appendChild(a);
      });
    }
    results.hidden = false;
  }

  function run() {
    var q = input.value.trim();
    if (!q) {
      results.hidden = true;
      results.innerHTML = '';
      document.body.classList.remove('searching');
      return;
    }
    document.body.classList.add('searching');
    results.hidden = false;
    results.innerHTML = '<div class="search-empty">搜索中…</div>';
    clearTimeout(timer);
    timer = setTimeout(function () {
      search(q).then(function (items) {
        if (input.value.trim() === q) render(q, items);
      }).catch(function () {
        results.innerHTML = '<div class="search-empty">搜索暂时不可用</div>';
      });
    }, 120);
  }

  if (input && results) {
    input.addEventListener('input', run);
    input.addEventListener('keydown', function (e) {
      if (e.key === 'Escape') {
        input.value = '';
        run();
        input.blur();
      } else if (e.key === 'Enter') {
        var first = results.querySelector('a');
        if (first) location.href = first.href;
      }
    });
    var params = new URLSearchParams(location.search);
    if (params.get('q')) {
      input.value = params.get('q');
      run();
    }
  }
})();
