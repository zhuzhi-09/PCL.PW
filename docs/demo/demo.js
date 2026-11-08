/* Pixel World 网页演示：纯前端复刻启动器界面，所有数据都是假的，不会真正执行任何操作。 */
(function () {
  'use strict';
  var host = document.getElementById('pcl-demo');
  if (!host) return;
  try { start(host); } catch (e) {
    if (window.console) console.error(e);
    host.innerHTML = '<p class="pd-noscript">演示加载失败，请刷新页面重试。</p>';
  }

  function start(host) {
    var W = 1100, H = 700;
    var REPO = 'https://github.com/zhuzhi-09/PixelWorld';

    /* ---------- 假数据 ---------- */
    var VERSIONS = [
      { id: '1.21.4', desc: '原版 · 1.21.4', icon: 'view_in_ar', mc: '1.21.4', type: '原版', mod: false },
      { id: 'Fabric 1.21.1', desc: 'Fabric 0.16.9 · 1.21.1', icon: 'extension', mc: '1.21.1', type: 'Fabric 0.16.9', mod: true },
      { id: 'Forge 1.20.1', desc: 'Forge 47.3.0 · 1.20.1', icon: 'construction', mc: '1.20.1', type: 'Forge 47.3.0', mod: true },
      { id: 'NeoForge 1.21.1', desc: 'NeoForge 21.1.172 · 1.21.1', icon: 'extension', mc: '1.21.1', type: 'NeoForge 21.1.172', mod: true },
      { id: '1.12.2 OptiFine', desc: 'OptiFine HD U G5 · 1.12.2', icon: 'light_mode', mc: '1.12.2', type: 'OptiFine HD U G5', mod: false }
    ];
    var FOLDERS = [
      { n: '启动器默认文件夹', p: 'D:\\Minecraft\\.minecraft' },
      { n: '官方启动器文件夹', p: 'C:\\Users\\Steve\\AppData\\Roaming\\.minecraft' }
    ];
    var NEWS = [
      { k: '快照', id: '26.4-snapshot-7', d: '2026-11-03', t: '这是一条示例动态：新快照加入了一些方块与音乐唱片，调整了部分生物的行为，并修复了若干漏洞。', c: 'linear-gradient(180deg,#5b87c9 0 52%,#5e9c42 52% 60%,#7a5535 60%)' },
      { k: '正式版', id: '1.21.4', d: '2024-12-03', t: '这是一条示例动态：正式版更新带来了新的群系氛围与方块外观，并优化了游戏性能。', c: 'linear-gradient(180deg,#d8a35a 0 40%,#a4723b 40% 58%,#6b4a2f 58%)' },
      { k: '快照', id: '26.4-snapshot-6', d: '2026-10-27', t: '这是一条示例动态：上一个快照调整了部分合成配方，并改进了光照与渲染表现。', c: 'linear-gradient(180deg,#2d3552 0 45%,#3f6b4a 45% 62%,#4a3a2c 62%)' }
    ];
    var DL = {
      release: [['1.21.4', '2024-12-03', 1], ['1.21.3', '2024-10-23'], ['1.21.1', '2024-08-08'], ['1.20.6', '2024-04-29'], ['1.20.1', '2023-06-12'], ['1.19.4', '2023-03-14'], ['1.16.5', '2021-01-15'], ['1.12.2', '2017-09-18'], ['1.8.9', '2015-12-09'], ['1.7.10', '2014-06-26']],
      snapshot: [['26.4-snapshot-7', '2026-11-03', 1], ['26.4-snapshot-6', '2026-10-27'], ['26.4-snapshot-5', '2026-10-20']],
      old: [['b1.7.3', '2011-07-08'], ['a1.2.6', '2010-12-03'], ['c0.30', '2009-07-02']],
      fool: [['25w14craftmine', '2025-04-01'], ['24w14potato', '2024-04-01'], ['23w13a_or_b', '2023-03-31']]
    };
    var RES = {
      mods: [['Sodium', '现代化的渲染引擎，大幅提升帧率', '2400 万'], ['Lithium', '优化游戏逻辑与服务端性能', '1900 万'], ['Iris Shaders', '兼容 OptiFine 光影包的光影加载器', '1600 万']],
      modpacks: [['Fabulously Optimized', '以性能优化为主的轻量整合包', '850 万'], ['Simply Optimized', '精简的性能整合包', '120 万'], ['Adventure Pack', '示例整合包：探索与冒险', '40 万']],
      resourcePacks: [['Faithful 32x', '保持原版风格的高清材质', '1200 万'], ['Vanilla Tweaks', '原版风格的小改动合集', '500 万'], ['Fresh Animations', '为生物添加更细腻的动画', '700 万']],
      shaders: [['Complementary Reimagined', '画面自然、性能友好的光影', '1100 万'], ['BSL Shaders', '经典的高画质光影', '900 万'], ['Photon', '示例光影：柔和的色调', '60 万']],
      datapacks: [['Terralith', '重塑地形与群系的数据包', '1500 万'], ['Incendium', '重制下界的数据包', '600 万'], ['Tectonic', '示例数据包：高耸的山脉', '300 万']]
    };

    var S = {
      page: 'home', sub: null, ver: 1, inst: 1, folder: 0, secDl: 'minecraft', secSet: 'launch', secTool: 'toolbox',
      secInst: 'overview', filt: 'release', q: '', sw: {}, seg: {}, txt: {}
    };

    /* ---------- 小工具 ---------- */
    function esc(s) { return String(s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); }
    function ic(n, c) { return '<span class="ic' + (c ? ' ' + c : '') + '" aria-hidden="true">' + n + '</span>'; }
    function btn(kind, label, act, icon) {
      return '<button type="button" class="b hv ' + kind + (icon ? ' ico' : '') + '" data-a="tip" data-v="' + esc(act) + '">' + (icon ? ic(icon) : '') + esc(label) + '</button>';
    }
    function lnk(kind, label, url, icon) {
      return '<a class="b hv ' + kind + (icon ? ' ico' : '') + '" href="' + url + '" target="_blank" rel="noopener noreferrer">' + (icon ? ic(icon) : '') + esc(label) + '</a>';
    }
    function swOn(k, d) { return k in S.sw ? S.sw[k] : d; }
    function sw(k, d) { return '<button type="button" class="sw" role="switch" aria-checked="' + swOn(k, d) + '" data-a="sw" data-k="' + k + '" data-d="' + (d ? 1 : 0) + '"></button>'; }
    function segOf(k, d) { return k in S.seg ? S.seg[k] : d; }
    function seg(k, opts, d) {
      var cur = segOf(k, d);
      return '<div class="seg" role="group">' + opts.map(function (o) {
        return '<button type="button" class="' + (cur === o[0] ? 'on' : '') + '" data-a="seg" data-k="' + k + '" data-v="' + o[0] + '">' + (cur === o[0] ? ic('check') : '') + o[1] + '</button>';
      }).join('') + '</div>';
    }
    function tf(k, ph, def, w) {
      var v = k in S.txt ? S.txt[k] : (def || '');
      return '<input class="tf" type="text" data-t="' + k + '" placeholder="' + esc(ph || '') + '" value="' + esc(v) + '" autocomplete="off" readonly data-a="tip" data-v="输入内容" style="cursor:default;width:' + (w || 300) + 'px">';
    }
    function row(icon, title, sub, trail, attrs) {
      return '<div class="lt p20' + (sub ? ' two' : '') + '"' + (attrs || '') + '>' + (icon ? ic(icon) : '') + '<div class="t"><div class="t1">' + title + '</div>' + (sub ? '<div class="t2">' + sub + '</div>' : '') + '</div>' + (trail || '') + '</div>';
    }
    function grp(title, rows) { return '<div class="grp"><h3>' + title + '</h3><div class="gc">' + rows.join('') + '</div></div>'; }
    function snav(groups, cur, key, cls) {
      return '<nav class="snav' + (cls ? ' ' + cls : '') + '">' + groups.map(function (g) {
        return (g.t ? '<div class="sgt">' + g.t + '</div>' : '') + g.items.map(function (it) {
          return '<button type="button" class="si hv' + (it.v === cur ? ' on' : '') + '" data-a="sec" data-k="' + key + '" data-v="' + it.v + '">' + ic(it.i) + '<span class="l">' + it.l + '</span>' + (it.tr ? '<span class="tr">' + it.tr + '</span>' : '') + '</button>';
        }).join('');
      }).join('') + '</nav>';
    }
    function panel(inner, cls) { return '<div class="panel"><div class="scr' + (cls ? ' ' + cls : '') + '">' + inner + '</div></div>'; }
    function emptyPanel(icon, title, sub, extra) {
      return '<div class="panel"><div class="empty">' + ic(icon) + '<div class="tt">' + title + '</div>' + (sub ? '<div class="sub">' + sub + '</div>' : '') + (extra || '') + '</div></div>';
    }
    function cur() { return VERSIONS[S.ver]; }

    /* ---------- 标题栏 ---------- */
    var NAV = [['home', '启动', 'rocket_launch'], ['download', '下载', 'download'], ['settings', '设置', 'settings'], ['tools', '工具', 'handyman'], ['ai', 'AI', 'auto_awesome']];
    var SUBT = { versions: '版本选择', log: '游戏日志', tasks: '任务' };
    function titlebar() {
      var h = '<div class="tb"><div class="lights">' +
        '<button type="button" class="light r" aria-label="关闭" data-a="tip" data-v="关闭窗口">×</button>' +
        '<button type="button" class="light y" aria-label="最小化" data-a="tip" data-v="最小化窗口">−</button>' +
        '<button type="button" class="light g" aria-label="缩放" data-a="tip" data-v="最大化窗口">+</button></div>';
      if (S.sub) {
        var t = S.sub === 'instance' ? '版本设置 - ' + VERSIONS[S.inst].id : SUBT[S.sub];
        h += '<button type="button" class="ibtn hv back" data-a="back" aria-label="返回">' + ic('arrow_back') + '</button><div class="subt">' + esc(t) + '</div>';
      } else {
        h += '<div class="brand"><img src="icon.png" alt="">Pixel World</div><div class="navp" role="tablist">' + NAV.map(function (n) {
          return '<button type="button" role="tab" aria-selected="' + (S.page === n[0]) + '" class="pill hv' + (S.page === n[0] ? ' on' : '') + '" data-a="nav" data-v="' + n[0] + '">' + ic(n[2]) + n[1] + '</button>';
        }).join('') + '</div>';
      }
      return h + '<button type="button" class="ibtn hv tasks" data-a="sub" data-v="tasks" aria-label="任务">' + ic('download', '') .replace('class="ic"', 'class="ic" style="font-size:20px"') + '</button></div>';
    }

    /* ---------- 启动页 ---------- */
    function greeting() {
      var h = new Date().getHours();
      return (h < 5 ? '夜深了' : h < 11 ? '早上好' : h < 13 ? '中午好' : h < 18 ? '下午好' : '晚上好') + '，Steve';
    }
    function home() {
      var v = cur();
      var left = '<div class="hl"><div class="sp"></div>' +
        '<button type="button" class="acc hv" data-a="tip" data-v="管理账户"><div class="avatar">S</div><span class="n" style="display:block">Steve</span><span class="small" style="display:block">离线账户</span></button>' +
        '<div class="sp"></div>' +
        '<button type="button" class="launch hv" data-a="tip" data-v="启动游戏">' + ic('play_arrow') + '<span class="t"><span class="t1" style="display:block">开始游戏</span><span class="t2" style="display:block">' + esc(v.id) + '</span></span></button>' +
        '<div class="two-b"><button type="button" class="b hv out" data-a="sub" data-v="versions">版本选择</button><button type="button" class="b hv out" data-a="inst" data-v="' + S.ver + '">版本设置</button></div></div>';
      var r = '<div class="hero"><img src="icon.png" alt=""><div><div class="g">' + greeting() + '</div><div class="tt">Pixel World</div><div class="ss">第三方基于 PCL 二次创作的跨平台 Minecraft 启动器</div></div></div>' +
        '<button type="button" class="card lt two hv mt16" data-a="sub" data-v="versions"><span class="tile">' + ic(v.icon) + '</span><span class="t"><span class="t1" style="display:block">' + esc(v.id) + '</span><span class="t2" style="display:block">' + esc(v.desc) + '</span></span>' + ic('chevron_right') + '</button>' +
        '<div class="mt12"><button type="button" class="b txt ico hv" data-a="sub" data-v="log">' + ic('article') + '游戏日志</button></div>';
      if (swOn('hints', true)) {
        r += '<div class="hint">' + ic('info') + '<div class="x">你正在使用 Pixel World 0.3.0 测试版。这是第三方 Minecraft 启动器，功能还在完善中，遇到问题请到 GitHub 反馈。</div>' + lnk('txt', '反馈问题', REPO + '/issues') + '</div>' +
          '<div class="hint">' + ic('volunteer_activism', '').replace('class="ic"', 'class="ic" style="color:var(--err)"') + '<div class="x">本软件完全免费、开源。如果你是付费购买或下载的，那么你可能被骗了，请向卖家申请退款，并从 GitHub 获取正版。</div>' + lnk('txt', '获取正版', REPO + '/releases') + '</div>';
      }
      if (swOn('news', true)) {
        r += '<div class="nh"><span class="a">Minecraft 版本动态</span><span class="c">来自 Minecraft Wiki</span><span class="sp"></span><button type="button" class="ibtn sm hv" data-a="refresh" aria-label="刷新">' + ic('refresh') + '</button></div>' +
          NEWS.map(function (n) {
            var inner = '<span class="cv" style="background:' + (n.img ? 'var(--sc) url(&quot;' + esc(n.img) + '&quot;) center/cover no-repeat' : n.c) + '"></span><span class="tx"><span class="hd"><span class="badge' + (n.k === '正式版' ? ' pr' : '') + '">' + n.k + '</span><b>' + esc(n.id) + '</b><i>' + esc(n.d) + '</i></span><span class="sm" style="display:-webkit-box">' + esc(n.t) + '</span></span>';
            return n.url
              ? '<a class="card news hv" href="' + esc(n.url) + '" target="_blank" rel="noopener" style="text-decoration:none;color:inherit">' + inner + '</a>'
              : '<button type="button" class="card news hv" data-a="tip" data-v="打开 Wiki 页面">' + inner + '</button>';
          }).join('');
      }
      return left + panel(r);
    }

    /* ---------- 版本选择 / 版本设置 ---------- */
    function versions() {
      var nav = '<nav class="snav w260"><div class="sgt">游戏文件夹</div>' + FOLDERS.map(function (f, i) {
        return '<button type="button" class="frow hv' + (i === S.folder ? ' on' : '') + '" data-a="folder" data-v="' + i + '">' + ic('folder_open') + '<span class="t"><span class="t1" style="display:block">' + f.n + '</span><span class="t2" style="display:block">' + esc(f.p) + '</span></span></button>';
      }).join('') + '<div class="mt8">' + btn('out', '添加文件夹', '添加文件夹', 'create_new_folder') + '</div></nav>';
      if (S.folder !== 0) return nav + emptyPanel('folder_open', '这个文件夹中还没有版本', '可以到「下载」页安装');
      var r = '<div class="rowh"><div class="t1" style="flex:1;font-size:14px;font-weight:500;letter-spacing:.1px">' + VERSIONS.length + ' 个版本</div><button type="button" class="ibtn hv" data-a="refresh" aria-label="刷新">' + ic('refresh') + '</button></div><div class="mt8"></div>';
      r += VERSIONS.map(function (v, i) {
        var sel = i === S.ver;
        return '<div class="vrow card' + (sel ? ' sel' : '') + '"><button type="button" class="lt two hv" data-a="ver" data-v="' + i + '" style="flex:1">' + ic(v.icon, 'pri') + '<span class="t"><span class="t1" style="display:block">' + esc(v.id) + '</span><span class="t2" style="display:block">' + esc(v.desc) + '</span></span>' + (sel ? ic('check') : '') + '</button>' +
          '<button type="button" class="ibtn hv" data-a="inst" data-v="' + i + '" aria-label="版本设置" style="align-self:center;margin-right:8px">' + ic('settings') + '</button></div>';
      }).join('');
      return nav + panel(r, 'p20');
    }

    var INST_NAV = function () {
      var items = [{ v: 'saves', l: '存档', i: 'public' }, { v: 'screenshots', l: '截图', i: 'photo_library' }];
      if (VERSIONS[S.inst].mod) items.push({ v: 'mods', l: '模组', i: 'extension' });
      items.push({ v: 'resourcepacks', l: '资源包', i: 'layers' }, { v: 'shaderpacks', l: '光影', i: 'auto_awesome' }, { v: 'schematics', l: '投影', i: 'view_in_ar' }, { v: 'servers', l: '服务器', i: 'dns' });
      return [{ t: null, items: [{ v: 'overview', l: '概览', i: 'dashboard' }, { v: 'setup', l: '设置', i: 'tune' }] }, { t: '资源', items: items }];
    };
    function instance() {
      var v = VERSIONS[S.inst], nav = snav(INST_NAV(), S.secInst, 'secInst');
      var sec = S.secInst;
      if (sec === 'overview') {
        var curr = S.inst === S.ver;
        var kv = function (k, x) { return '<div class="kv"><span>' + k + '</span><span>' + esc(x) + '</span></div>'; };
        return nav + panel(
          '<div class="rowh"><div class="h5" style="flex:1">' + esc(v.id) + '</div>' +
          (curr ? '<span class="chip">' + ic('check').replace('class="ic"', 'class="ic" style="color:var(--p)"') + '当前版本</span>' : '<button type="button" class="b tonal hv" data-a="setcur">设为当前版本</button>') + '</div>' +
          '<div class="card mt16" style="padding:12px 20px">' + kv('类型', v.desc) + kv('游戏版本', v.mc) + kv('版本隔离', '已开启') + kv('运行目录', 'D:\\Minecraft\\.minecraft\\versions\\' + v.id) + '</div>' +
          '<div class="sub mt24" style="font-weight:500">快捷方式</div><div class="wrapf mt12">' +
          btn('out', '版本文件夹', '打开文件夹', 'folder_open') + btn('out', '存档文件夹', '打开文件夹', 'folder') + btn('out', '模组文件夹', '打开文件夹', 'folder') + btn('out', '资源包文件夹', '打开文件夹', 'folder') + btn('out', '截图文件夹', '打开文件夹', 'folder') + '</div>' +
          '<div class="sub mt24" style="font-weight:500">管理</div><div class="card mt12">' +
          row('delete', '删除这个版本', '移到回收站；开启版本隔离时，其中的存档和模组也会一并删除', btn('out err', '删除', '删除版本')).replace('<span class="ic"', '<span style="color:var(--err)" class="ic"') + '</div>');
      }
      if (sec === 'setup') {
        return nav + panel(
          grp('启动', [
            row(null, '版本隔离', null, seg('iso', [['on', '开启'], ['off', '关闭']], 'on')),
            row(null, 'Java', '自动选择', btn('tonal', '更改', '选择 Java')),
            row(null, '渲染器', '跟随全局设置', seg('rend', [['g', '跟随全局'], ['a', '自动']], 'g'))
          ]) +
          grp('游戏内存', [row(null, '分配方式', null, seg('imem', [['global', '跟随全局'], ['auto', '自动'], ['custom', '自定义']], 'global'))]) +
          grp('高级', [row(null, 'JVM 参数', null, tf('ijvm', '留空使用全局设置', '', 320)), row(null, '游戏参数', null, tf('iarg', '留空使用全局设置', '', 320))]));
      }
      var lab = { saves: '存档', screenshots: '截图', mods: '模组', resourcepacks: '资源包', shaderpacks: '光影', schematics: '投影', servers: '服务器' }[sec];
      return nav + emptyPanel('folder_open', lab, '这里还没有' + lab, '<div class="mt12">' + btn('tonal', '打开文件夹', '打开文件夹', 'folder_open') + '</div>');
    }

    /* ---------- 下载 ---------- */
    var DL_NAV = [
      { t: null, items: [{ v: 'minecraft', l: 'Minecraft', i: 'view_in_ar' }] },
      { t: '加载器', items: ['Forge', 'NeoForge', 'Cleanroom', 'OptiFine', 'LabyMod', 'Fabric', 'Quilt', 'Legacy Fabric', 'LiteLoader'].map(function (n) { return { v: n, l: n, i: n === 'Legacy Fabric' ? 'history' : n === 'Quilt' ? 'grid_view' : n === 'LiteLoader' ? 'light_mode' : 'extension' }; }) },
      { t: '社区资源', items: [{ v: 'mods', l: '模组', i: 'extension' }, { v: 'modpacks', l: '整合包', i: 'inventory_2' }, { v: 'resourcePacks', l: '资源包', i: 'layers' }, { v: 'shaders', l: '光影包', i: 'wb_sunny' }, { v: 'datapacks', l: '数据包', i: 'data_object' }] },
      { t: null, items: [{ v: 'favorites', l: '收藏夹', i: 'favorite' }] }
    ];
    function dlList() {
      var sec = S.secDl, preset = sec !== 'minecraft' && !RES[sec] && sec !== 'favorites';
      var src = DL[preset ? 'release' : S.filt], q = S.q.trim().toLowerCase();
      return src.filter(function (x) { return !q || x[0].toLowerCase().indexOf(q) >= 0; }).map(function (x) {
        var snap = !preset && S.filt !== 'release';
        return '<button type="button" class="card lt hv" style="margin-bottom:6px;min-height:64px" data-a="tip" data-v="下载 ' + esc(x[0]) + '">' + ic(snap ? 'science' : 'view_in_ar').replace('class="ic"', 'class="ic" style="color:var(--p)"') +
          '<span class="t"><span class="t1" style="display:flex;align-items:center;gap:8px">' + esc(x[0]) + (x[2] ? '<span class="badge pr" style="background:var(--pc)">最新</span>' : '') + '</span><span class="t2" style="display:block">发布于 ' + esc(x[1]) + '</span></span>' + ic('download') + '</button>';
      }).join('') || '<div class="sub" style="padding:24px;text-align:center">没有匹配的版本</div>';
    }
    function download() {
      var sec = S.secDl, nav = snav(DL_NAV, sec, 'secDl'), r;
      if (sec === 'favorites') return nav + emptyPanel('favorite', '收藏夹', '还没有收藏的资源');
      var search = '<div class="fld" style="width:240px"><span class="ic">search</span><input class="tf rnd" id="pd-q" type="text" placeholder="搜索" value="' + esc(S.q) + '" autocomplete="off"></div>';
      if (RES[sec]) {
        var lab = { mods: '模组', modpacks: '整合包', resourcePacks: '资源包', shaders: '光影包', datapacks: '数据包' }[sec];
        r = '<div class="rowh"><div class="h5" style="flex:1">' + lab + '</div>' + search + '</div><div class="sub mt8">资源来自 Modrinth（演示数据）</div><div class="mt16">' +
          RES[sec].map(function (x) {
            return '<div class="card lt" style="margin-bottom:8px"><span class="tile">' + x[0].charAt(0) + '</span><span class="t"><span class="t1" style="display:block">' + x[0] + '</span><span class="t2" style="display:block">' + x[1] + ' · ' + x[2] + ' 下载</span></span>' + btn('tonal sm', '下载', '下载' + lab) + '</div>';
          }).join('') + '</div>';
        return nav + panel(r, 'p20').replace('class="scr p20"', 'class="scr" style="padding:20px 24px"');
      }
      var preset = sec !== 'minecraft';
      r = '<div class="rowh"><div class="h5" style="flex:1">' + (preset ? '安装 ' + sec : 'Minecraft') + '</div>' + search + '</div>';
      r += preset ? '<div class="sub mt8">选择要安装 ' + sec + ' 的 Minecraft 版本</div>' :
        '<div class="wrapf mt16">' + [['release', '正式版'], ['snapshot', '快照'], ['old', '远古版'], ['fool', '愚人节']].map(function (f) {
          return '<button type="button" class="chip hv' + (S.filt === f[0] ? ' on' : '') + '" data-a="filt" data-v="' + f[0] + '">' + (S.filt === f[0] ? ic('check') : '') + f[1] + '</button>';
        }).join('') + '</div>';
      r += '<div class="mt16" id="pd-list">' + dlList() + '</div>';
      return nav + panel(r).replace('class="scr"', 'class="scr" style="padding:20px 24px"');
    }

    /* ---------- 设置 ---------- */
    var SET_NAV = [
      { t: '游戏', items: [{ v: 'launch', l: '启动', i: 'rocket_launch' }, { v: 'java', l: 'Java', i: 'coffee' }, { v: 'manage', l: '游戏管理', i: 'folder' }] },
      { t: '启动器', items: [{ v: 'appearance', l: '个性化', i: 'palette' }, { v: 'ai', l: 'AI 排障', i: 'auto_awesome' }, { v: 'misc', l: '其他', i: 'tune' }] },
      { t: '关于', items: [{ v: 'about', l: '关于与致谢', i: 'info' }] }
    ];
    function aboutLink(icon, t, s, url, a) {
      return row(icon, t, s, lnk('txt', a || '查看', url));
    }
    function settings() {
      var sec = S.secSet, nav = snav(SET_NAV, sec, 'secSet'), r = '';
      if (sec === 'launch') {
        r = grp('启动', [
          row(null, '版本隔离', '新版本首次启动时按此规则决定，之后在版本设置中单独修改', seg('iso', [['on', '开启'], ['off', '关闭']], 'on')),
          row(null, '游戏窗口', null, seg('win', [['def', '默认'], ['max', '最大化'], ['full', '全屏']], 'def')),
          row(null, '进程优先级', null, seg('prio', [['low', '低'], ['mid', '中'], ['high', '高']], 'mid')),
          row(null, '自动设置游戏语言', '新版本或没有存档时，把游戏语言设为与启动器一致', sw('lang', true))
        ]) + grp('高级', [
          row(null, 'JVM 参数', null, tf('jvm', '例如 -XX:+UseG1GC')),
          row(null, '游戏参数', null, tf('args', '')),
          row(null, '启动前执行命令', '在游戏文件夹中执行', tf('pre', '')),
          row(null, '使用高性能显卡', '仅 Windows：让 Java 使用独立显卡', sw('gpu', false))
        ]);
      } else if (sec === 'java') {
        var j = segOf('java', 'auto'), rd = function (k, t, s, extra) {
          return row(null, t, s, extra || '', ' data-a="seg" data-k="java" data-v="' + k + '" style="cursor:pointer"').replace('<div class="t">', '<span class="rd' + (j === k ? ' on' : '') + '"></span><div class="t">');
        };
        r = grp('Java', [
          rd('auto', '自动选择', '按版本要求选择，找不到时自动下载 Mojang 提供的 Java'),
          rd('manual', '手动指定', 'Java 21.0.5（演示）· C:\\Program Files\\Java\\jdk-21\\bin\\javaw.exe'),
          row(null, '', null, btn('tonal', '手动选择', '选择 Java 文件', 'folder_open') + btn('tonal', '重新检测', '检测 Java', 'refresh')).replace('<div class="t"><div class="t1"></div></div>', '<div class="t"></div>')
        ]) + grp('游戏内存', [
          row(null, '分配方式', null, seg('mem', [['auto', '自动'], ['custom', '自定义']], 'auto')),
          row(null, '锁定内存', '初始内存与最大内存相同（-Xms 等于 -Xmx）', sw('lock', false))
        ]);
      } else if (sec === 'manage') {
        r = grp('游戏文件夹', [
          row('folder', '当前游戏文件夹', 'D:\\Minecraft\\.minecraft', btn('tonal', '打开文件夹', '打开文件夹', 'folder_open')),
          row('create_new_folder', '添加或切换文件夹', '可在「版本选择」页管理多个游戏文件夹', '<button type="button" class="b hv tonal" data-a="sub" data-v="versions">版本选择</button>')
        ]);
      } else if (sec === 'appearance') {
        r = grp('个性化', [row('dark_mode', '颜色模式', '主题色固定为 PCL 主题蓝', seg('theme', [['system', '跟随系统'], ['light', '浅色'], ['dark', '深色']], 'system'))]) +
          grp('首页', [
            row('info', '显示使用提示', '正在使用的版本与免费声明', sw('hints', true)),
            row('newspaper', '显示 Minecraft 版本动态', '最新的正式版与快照，简介来自中文 Minecraft Wiki', sw('news', true))
          ]);
      } else if (sec === 'ai') {
        r = grp('AI 排障', [
          '<div class="lt p20" style="display:block"><div class="t2" style="padding-top:8px">游戏崩溃后，可以把截取的日志发送给你自己的 AI 服务分析原因。支持 OpenAI 兼容接口（DeepSeek、通义千问、Kimi、OpenRouter、本机 Ollama 等）和 Anthropic 接口；费用由你的 AI 服务商收取。</div></div>',
          row(null, '接口类型', null, seg('aitype', [['oa', 'OpenAI 兼容'], ['an', 'Anthropic']], 'oa')),
          row(null, '接口地址', null, tf('aiurl', 'https://')),
          row(null, '模型', null, tf('aimodel', '例如 gpt-4o-mini')),
          row(null, '', null, btn('tonal', '测试连接', '测试 AI 连接')).replace('<div class="t"><div class="t1"></div></div>', '<div class="t"></div>')
        ]);
      } else if (sec === 'misc') {
        r = grp('PCL-CE', [row('download', '从 PCL-CE 导入', '导入启动设置、游戏文件夹与账户；版本独立设置两者直接共用', btn('tonal', '导入', '导入 PCL-CE 设置'))]) +
          grp('下载', [
            row(null, '下载源', null, seg('src', [['auto', '自动'], ['off', '官方源'], ['bm', 'BMCLAPI']], 'auto')),
            row(null, '同时下载的文件数', null, '<input type="range" min="1" max="64" value="' + (S.txt.threads || 16) + '" data-t="threads" aria-label="同时下载的文件数">')
          ]) +
          grp('正版登录', [row(null, 'Azure 应用 Client ID', '微软登录需要在 Azure 注册一个「个人 Microsoft 账户」类型的公共客户端应用，并开启“允许公共客户端流”', tf('azure', '', '', 280))]);
      } else {
        r = grp('关于', [
          row('favorite', 'Paper.Zhu', 'Pixel World 的开发者', lnk('fill', '赞助作者', 'https://afdian.com/a/Paper_Zhu', 'volunteer_activism')).replace('<span class="ic" aria-hidden="true">favorite</span>', '<span class="ava">' + ic('favorite') + '</span>'),
          row(null, 'Pixel World 0.3.0', 'Pixel World 是第三方 Minecraft 启动器，本项目为轻度使用 PCL 仓储库，界面布局参考 PCL 社区版（PCL-CE）。PCL 由龙腾猫跃开发，本软件与 PCL 及其作者无关，也不代表 PCL 官方。请勿就本软件的问题打扰 PCL 作者。').replace('<div class="t">', '<img class="logo40" src="icon.png" alt=""><div class="t">'),
          aboutLink('code', '源代码', 'Pixel World 以 Apache-2.0 协议开源', REPO, '打开'),
          aboutLink('gavel', 'PCL 存储库合理使用指南', '本项目遵循的命名、署名与使用规则，随源代码一同发布', REPO + '/blob/main/PCL-GUIDE.md')
        ]) + grp('致谢', [
          aboutLink('groups', 'PCL Community', 'PCL 社区版（PCL-CE）的开发者们，本软件与 PCL-CE 的数据兼容', 'https://github.com/PCL-Community/PCL-CE'),
          aboutLink('android', '安卓版游戏运行时', '基于 Amethyst-Android（LGPL-3.0）、MobileGlues、LWJGL 与 OpenJDK，单独以 LGPL-3.0 开源', REPO + '/blob/main/android/runtime/NOTICE.md'),
          aboutLink('flutter_dash', 'Flutter', '跨平台界面框架', 'https://flutter.dev'),
          aboutLink('palette', 'Material Design 3', '界面设计语言与配色算法', 'https://m3.material.io')
        ]) + '<div class="small">Minecraft 是 Mojang Studios 的商标。本软件不是官方 Minecraft 产品，未经 Mojang 或 Microsoft 批准，也与其无关。</div>';
      }
      return nav + panel(r);
    }

    /* ---------- 工具 ---------- */
    var TOOL_NAV = [
      { t: '联机', items: [{ v: 'lobby', l: '联机大厅', i: 'lan', tr: '规划中' }, { v: 'transfer', l: '局域网互传', i: 'sync_alt' }] },
      { t: '实用工具', items: [{ v: 'diagnose', l: '错误分析', i: 'troubleshoot' }, { v: 'toolbox', l: '百宝箱', i: 'handyman' }, { v: 'download', l: '自定义下载', i: 'download_for_offline' }, { v: 'skin', l: '皮肤与头像', i: 'face' }, { v: 'server', l: '服务器查询', i: 'dns' }, { v: 'achievement', l: '成就图片', i: 'emoji_events' }] }
    ];
    function tool(icon, t, s, a, act) { return row(icon, t, s, a ? btn('tonal', a, act) : ''); }
    function form(title, sub, fields, bt, act) {
      return '<div class="h5">' + title + '</div><div class="sub mt8">' + sub + '</div><div class="fl mt24">' + fields.map(function (f) {
        return '<input class="tf" type="text" data-t="' + f[0] + '" placeholder="' + esc(f[1]) + '" value="' + esc(S.txt[f[0]] || '') + '" autocomplete="off" readonly data-a="tip" data-v="输入内容" style="cursor:default" aria-label="' + esc(f[1]) + '">';
      }).join('') + '<div>' + btn('fill', bt, act) + '</div></div>';
    }
    function tools() {
      var sec = S.secTool, nav = snav(TOOL_NAV, sec, 'secTool'), r;
      if (sec === 'lobby') return nav + emptyPanel('lan', '联机大厅', '让几位玩家组成虚拟局域网一起游戏，正在规划中');
      if (sec === 'transfer') return nav + emptyPanel('sync_alt', '局域网互传', '输入地址和配对码，在电脑和手机之间传版本、模组、配置和存档', '<div class="mt12">' + btn('fill', '开始互传', '局域网互传') + '</div>');
      if (sec === 'diagnose') {
        r = grp('错误分析', [
          tool('history', '最近一次游戏', '分析本次打开启动器后最近一次运行的游戏', '分析', '分析日志'),
          tool('description', '日志文件', '选择崩溃报告（crash-reports）或日志文件（logs）', '选择', '选择日志文件'),
          tool('content_paste', '粘贴日志', '粘贴别人发给你的崩溃报告或日志', '粘贴', '分析日志')
        ]) + '<div class="sub">启动器先用本地规则匹配常见问题；在「设置 → AI 排障」填写自己的 AI 服务后，还可以让 AI 分析日志。游戏崩溃时会自动弹出提示。</div>';
      } else if (sec === 'toolbox') {
        r = grp('百宝箱', [
          tool('cleaning_services', '清理游戏垃圾', '删除日志、崩溃报告与解压出的本地库，不影响存档和模组', '清理', '清理游戏垃圾'),
          tool('auto_awesome', '今日人品', '看看今天的运气，每人每天固定', '查看', '查看今日人品'),
          tool('shortcut', '创建桌面快捷方式', '在桌面创建启动器的快捷方式', '创建', '创建快捷方式'),
          tool('rocket_launch', '启动次数', '已经通过启动器启动了 12 次游戏', '', '')
        ]);
      } else if (sec === 'download') {
        r = form('自定义下载', '下载任意文件，进度显示在任务页', [['dlurl', '下载地址 https://'], ['dlname', '文件名（可选）']], '开始下载', '下载文件');
      } else if (sec === 'skin') {
        r = form('正版皮肤', '输入正版玩家名获取皮肤，也可以从皮肤截取头像', [['skin', '正版玩家名']], '获取', '获取皮肤');
      } else if (sec === 'server') {
        r = form('服务器查询', '查询服务器的在线人数、版本和延迟', [['srv', 'mc.example.com 或 1.2.3.4:25565']], '查询', '查询服务器');
      } else {
        r = form('成就图片', '生成 Minecraft 风格的成就提示图片', [['ach1', '标题（获得成就！）'], ['ach2', '第一行'], ['ach3', '第二行（可选）']], '生成', '生成图片');
      }
      return nav + panel(r);
    }

    /* ---------- AI ---------- */
    function ai() {
      var nav = '<nav class="snav w260"><button type="button" class="b hv tonal ico" style="width:100%;margin:8px 0 4px" data-a="tip" data-v="新建对话">' + ic('add') + '新对话</button><div class="sgt">历史对话</div><div class="sub" style="padding:8px 16px">还没有对话</div></nav>';
      var chips = ['游戏崩溃了怎么办？', '如何安装 Fabric 模组？', '内存应该分配多少？'].map(function (q) { return '<button type="button" class="chip hv" data-a="fill" data-v="' + q + '">' + q + '</button>'; }).join('');
      return nav + '<div class="panel"><div class="empty" style="padding-bottom:96px"><div class="h5">有什么可以帮你？</div>' +
        '<div class="card lt two mt16" style="width:460px;text-align:left"><span class="t"><span class="t1" style="display:block">先设置 AI 服务</span><span class="t2" style="display:block">这是网页演示，无法与 AI 对话</span></span><button type="button" class="b tonal hv" data-a="goset">设置</button></div>' +
        '<div class="wrapf mt12" style="justify-content:center">' + chips + '</div></div>' +
        '<div class="aib"><textarea data-ai="1" id="pd-ai" readonly data-a="tip" data-v="输入内容" style="cursor:default" placeholder="输入问题，Enter 发送，Shift + Enter 换行" aria-label="输入问题"></textarea><button type="button" class="b fill hv" data-a="tip" data-v="与 AI 对话" aria-label="发送">' + ic('send') + '</button></div></div>';
    }

    /* ---------- 子页面 ---------- */
    function sublog() {
      return panel('<div class="rowh"><div class="h5" style="flex:1">游戏日志</div>' + btn('tonal sm', '复制', '复制日志') + btn('tonal sm', '清空', '清空日志') + '</div><div class="card mt16 log">[演示] 还没有启动过游戏。<br>启动游戏后，这里会实时显示游戏输出。</div>');
    }
    function subpage() {
      if (S.sub === 'versions') return versions();
      if (S.sub === 'instance') return instance();
      if (S.sub === 'log') return sublog();
      return emptyPanel('download', '没有任务', '下载与安装任务会显示在这里');
    }
    function pageHtml() {
      if (S.sub) return subpage();
      return { home: home, download: download, settings: settings, tools: tools, ai: ai }[S.page]();
    }

    /* ---------- 渲染 ---------- */
    var stage = document.createElement('div'); stage.className = 'pd-stage';
    var scale = document.createElement('div'); scale.className = 'pd-scale';
    var root = document.createElement('div'); root.className = 'pd';
    root.setAttribute('role', 'application'); root.setAttribute('aria-label', 'Pixel World 启动器网页演示');
    root.innerHTML = '<div class="app" style="position:absolute;inset:0"></div><div class="toast" role="status" aria-live="polite"></div>';
    scale.appendChild(root); stage.appendChild(scale); host.innerHTML = ''; host.appendChild(stage);
    var app = root.firstChild, toast = root.lastChild;

    /* 和启动器一样：取 Mojang 版本列表中最新的几个正式版与快照，再从中文 Minecraft Wiki 读取简介与配图；
       同时更新下载页的版本列表。失败时保留示例数据。 */
    function loadNews() {
      var WIKI = 'https://zh.minecraft.wiki';
      fetch('https://piston-meta.mojang.com/mc/game/version_manifest_v2.json')
        .then(function (r) { if (!r.ok) throw r.status; return r.json(); })
        .then(function (m) {
          // 下载页的版本列表也用真实数据（愚人节版本仍用示例，官方列表不区分）
          var latest = m.latest || {};
          function pick(types, max) {
            return m.versions.filter(function (v) { return types.indexOf(v.type) >= 0; }).slice(0, max).map(function (v) {
              return [v.id, (v.releaseTime || '').slice(0, 10), v.id === latest.release || v.id === latest.snapshot ? 1 : 0];
            });
          }
          DL.release = pick(['release'], 200);
          DL.snapshot = pick(['snapshot'], 60);
          DL.old = pick(['old_beta', 'old_alpha'], 200);
          if (S.page === 'download' && !S.sub) {
            var l = app.querySelector('#pd-list');
            if (l) l.innerHTML = dlList();
          }
          var list = m.versions.filter(function (v) { return v.type === 'release' || v.type === 'snapshot'; }).slice(0, 4);
          var titles = list.map(function (v) { return 'Java版' + v.id; });
          var q = 'action=query&prop=extracts|pageimages&exintro=1&explaintext=1&exsentences=3&exlimit=max&piprop=thumbnail' +
            '&pithumbsize=640&pilimit=max&redirects=1&format=json&origin=*&titles=' + encodeURIComponent(titles.join('|'));
          return fetch(WIKI + '/api.php?' + q)
            .then(function (r) { return r.ok ? r.json() : {}; })
            .catch(function () { return {}; })
            .then(function (w) {
              var query = w.query || {}, from = {}, pages = {};
              (query.redirects || []).forEach(function (x) { from[x.to] = x.from; });
              Object.keys(query.pages || {}).forEach(function (k) {
                var p = query.pages[k];
                if (p.missing === undefined) pages[from[p.title] || p.title] = p;
              });
              return list.map(function (v, i) {
                var p = pages[titles[i]] || {};
                return {
                  k: v.type === 'release' ? '正式版' : '快照',
                  id: v.id,
                  d: (v.releaseTime || '').slice(0, 10),
                  t: (p.extract || '').trim() || 'Wiki 页面还在编写中。',
                  img: p.thumbnail && p.thumbnail.source,
                  url: WIKI + '/w/' + encodeURIComponent(titles[i]),
                  c: NEWS[i % NEWS.length].c
                };
              });
            });
        })
        .then(function (items) {
          if (!items.length) return;
          NEWS = items;
          if (S.page === 'home' && !S.sub) render(false);
        })
        .catch(function () { /* 网络不可用时保留示例动态 */ });
    }

    function render(anim) {
      var old = app.querySelector('.scr'), top = old ? old.scrollTop : 0;
      app.innerHTML = titlebar() + '<div class="body' + (anim ? ' in' : '') + '">' + pageHtml() + '</div>';
      if (!anim) { var n = app.querySelector('.scr'); if (n) n.scrollTop = top; }
    }
    function fit() {
      var w = stage.clientWidth || W, s = Math.min(1, w / W);
      scale.style.transform = 'scale(' + s + ')';
      scale.style.left = Math.max(0, (w - W * s) / 2) + 'px';
      stage.style.height = Math.round(H * s) + 'px';
    }
    var timer;
    function tip(act) {
      toast.textContent = '这是网页演示，无法' + (act || '执行此操作') + '。请下载启动器体验完整功能。';
      toast.classList.add('show');
      clearTimeout(timer);
      timer = setTimeout(function () { toast.classList.remove('show'); }, 3000);
    }
    function applyTheme() { var t = segOf('theme', 'system'); if (t === 'system') root.removeAttribute('data-theme'); else root.setAttribute('data-theme', t); }

    /* ---------- 事件 ---------- */
    root.addEventListener('click', function (e) {
      var el = e.target.closest ? e.target.closest('[data-a]') : null;
      if (!el || !root.contains(el)) return;
      var a = el.getAttribute('data-a'), v = el.getAttribute('data-v'), k = el.getAttribute('data-k');
      switch (a) {
        case 'tip': tip(v); break;
        case 'nav': S.page = v; S.sub = null; render(true); break;
        case 'sub': S.sub = v; render(true); break;
        case 'back': S.sub = null; render(true); break;
        case 'inst': S.inst = +v; S.secInst = 'overview'; S.sub = 'instance'; render(true); break;
        case 'ver': S.ver = +v; S.sub = null; render(true); break;
        case 'setcur': S.ver = S.inst; render(false); break;
        case 'folder': S.folder = +v; render(false); break;
        case 'sec': S[k] = v; S.q = ''; render(true); break;
        case 'filt': S.filt = v; render(false); break;
        case 'refresh': if (S.page === 'home' && !S.sub) loadNews(); else render(false); break;
        case 'goset': S.page = 'settings'; S.secSet = 'ai'; render(true); break;
        case 'fill': var ta = app.querySelector('#pd-ai'); if (ta) { ta.value = v; ta.focus(); } break;
        case 'sw':
          S.sw[k] = !swOn(k, el.getAttribute('data-d') === '1');
          el.setAttribute('aria-checked', S.sw[k]);
          break;
        case 'seg': S.seg[k] = v; if (k === 'theme') applyTheme(); render(false); break;
      }
    });
    root.addEventListener('input', function (e) {
      var t = e.target;
      if (t.id === 'pd-q') { S.q = t.value; var l = app.querySelector('#pd-list'); if (l) l.innerHTML = dlList(); }
      else if (t.getAttribute && t.getAttribute('data-t')) S.txt[t.getAttribute('data-t')] = t.value;
    });
    root.addEventListener('keydown', function (e) {
      if (e.target.id === 'pd-ai' && e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); tip('与 AI 对话'); }
    });

    render(false);
    fit();
    loadNews();
    if (window.ResizeObserver) new ResizeObserver(fit).observe(stage);
    window.addEventListener('resize', fit);
  }
})();
