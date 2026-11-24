/**
 * DSH HOS 侧栏终端插件（自研）。
 *
 * 页面只负责把一个透明 stage 的矩形、可见性、工作目录和关闭动作告诉 ArkTS 壳层；
 * 终端画面和 shell 全部由壳层绘制/托管。通信使用 console 前缀 + 启动 nonce。
 */
window.__ModuleLoader__.load({
  id: '@local/dsh-harmony-terminal',
  factory(require) {
    const React = require('react');
    const h = React.createElement;
    const TAB_ID = 'harmony-native-terminal';
    const TAB_KIND = 'terminal-harmony';
    const OWNER = TAB_ID;
    const SITE = 'https://github.com/Jerrylee2044/dsh-hos';

    function post(op, data) {
      try {
        if (window.top !== window) { return; }
        const nonce = window.__dshNonce;
        if (typeof nonce !== 'string' || nonce === '') { return; }
        console.log('DSH_TERM:' + nonce + ':' + JSON.stringify(Object.assign({ op: op }, data || {})));
      } catch (error) { /* 控制台不可用时静默 */ }
    }

    function currentSession() {
      try {
        const node = document.querySelector('[data-conversation-session]');
        return node ? (node.getAttribute('data-conversation-session') || '') : '';
      } catch (error) { return ''; }
    }

    async function sessionList() {
      try {
        const response = await fetch('/api/session/list', {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({
            type: 'client-request',
            rpcId: String(Date.now()) + Math.random().toString(16).slice(2),
            method: 'session/list',
            payload: { args: { _request: {} } }
          })
        });
        const data = await response.json();
        const items = data && data.result && data.result.value && data.result.value.items;
        return Array.isArray(items) ? items : [];
      } catch (error) { return []; }
    }

    function cwdOf(item) {
      if (!item) { return ''; }
      if (item.cwd) { return item.cwd; }
      const values = item.projections && item.projections.values;
      return values && values.workingDirectory ? values.workingDirectory : '';
    }

    async function currentCwd() {
      const items = await sessionList();
      if (items.length === 0) { return ''; }
      const id = currentSession();
      const active = id === '' ? null : items.find(function (item) { return item.sessionId === id; });
      if (active) { return cwdOf(active); }
      const sorted = items.slice().sort(function (a, b) { return (b.updatedAt || 0) - (a.updatedAt || 0); });
      return cwdOf(sorted[0]);
    }

    function followSession() {
      if (window.__dshHosFollowSession) { return; }
      window.__dshHosFollowSession = true;
      let last = '';
      setInterval(function () {
        const id = currentSession();
        if (id === '' || id === last) { return; }
        last = id;
        currentCwd().then(function (cwd) { if (cwd) { post('cwd', { owner: OWNER, cwd: cwd }); } });
      }, 1500);
    }

    function Stage() {
      const ref = React.useRef(null);
      React.useEffect(function () {
        const element = ref.current;
        if (element === null) { return undefined; }
        post('open', { owner: OWNER, cols: 80, rows: 24 });
        currentCwd().then(function (cwd) { if (cwd) { post('cwd', { owner: OWNER, cwd: cwd }); } });

        let previous = '';
        function report() {
          const rect = element.getBoundingClientRect();
          const visible = document.visibilityState !== 'hidden' && rect.width > 1 && rect.height > 1
            && rect.bottom > 0 && rect.right > 0
            && rect.left < window.innerWidth && rect.top < window.innerHeight;
          const signature = [Math.round(rect.left), Math.round(rect.top),
            Math.round(rect.width), Math.round(rect.height), visible ? 1 : 0].join(',');
          if (signature === previous) { return; }
          previous = signature;
          post('bounds', {
            owner: OWNER, left: rect.left, top: rect.top,
            width: rect.width, height: rect.height, visible: visible
          });
        }

        const observer = typeof ResizeObserver === 'undefined' ? null : new ResizeObserver(report);
        if (observer !== null) { observer.observe(element); }
        window.addEventListener('resize', report);
        document.addEventListener('visibilitychange', report);
        const timer = setInterval(report, 500);
        report();
        return function () {
          clearInterval(timer);
          if (observer !== null) { observer.disconnect(); }
          window.removeEventListener('resize', report);
          document.removeEventListener('visibilitychange', report);
          post('close', { owner: OWNER });
        };
      }, []);
      return h('div', {
        ref: ref,
        style: { width: '100%', height: '100%', background: 'transparent', pointerEvents: 'none' }
      });
    }

    function Section(props) {
      return h('div', { style: { marginTop: 16 } },
        h('div', { style: { fontSize: 12, color: 'var(--dsw-alias-label-secondary)', margin: '0 0 6px 2px' } }, props.title),
        h('div', { style: {
          border: '1px solid var(--dsw-alias-border-l2)', borderRadius: 12,
          background: 'var(--dsw-alias-bg-l1)', overflow: 'hidden'
        } }, props.children));
    }

    function LinkRow(props) {
      return h('button', {
        type: 'button',
        onClick: function () { post('openExternal', { url: props.url }); },
        style: {
          appearance: 'none', display: 'flex', alignItems: 'center', gap: 12,
          width: '100%', padding: '12px 14px', border: 0,
          borderTop: props.first ? '0' : '1px solid var(--dsw-alias-border-l2)',
          background: 'transparent', color: 'var(--dsw-alias-label-primary)',
          font: 'inherit', textAlign: 'left', cursor: 'pointer'
        }
      },
      h('div', { style: { flex: 1, minWidth: 0 } },
        h('div', { style: { fontSize: 13, lineHeight: '20px', fontWeight: 500 } }, props.title),
        h('div', { style: {
          marginTop: 2, fontSize: 11, color: 'var(--dsw-alias-label-tertiary)',
          overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap'
        } }, props.hint)),
      h('span', { style: { color: 'var(--dsw-alias-label-tertiary)' } }, '↗'));
    }

    function About() {
      try { console.log('DSH_ABOUT_RENDER'); } catch (e) {}
      return h('div', { style: { padding: '2px 0 8px' } },
        h('div', { style: {
          display: 'flex', alignItems: 'center', gap: 12, padding: 16,
          border: '1px solid var(--dsw-alias-border-l2)', borderRadius: 14,
          background: 'var(--dsw-alias-bg-l1)'
        } },
          h('img', { src: 'data:image/png;base64,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', width: 46, height: 46,
            style: { flex: '0 0 46px', objectFit: 'contain' } }),
          h('div', { style: { flex: 1 } },
            h('div', { style: { fontSize: 18, fontWeight: 600 } }, 'DSH HOS'),
            h('div', { style: { marginTop: 2, fontSize: 12, color: 'var(--dsw-alias-label-secondary)' } },
              '第三方 DSH 鸿蒙客户端 · 非官方'))),
        h('p', { style: { margin: '14px 2px 0', fontSize: 12, lineHeight: 1.7, color: 'var(--dsw-alias-label-secondary)' } },
          'DSH HOS 是独立社区项目，与 DeepSeek 没有隶属或背书关系。界面与引擎来自上游 DeepSeek Harness（MIT）；鸿蒙壳层、终端和运行时由本项目提供。'),
        h(Section, { title: '项目' },
          h(LinkRow, { title: 'DSH HOS 仓库', hint: 'github.com/Jerrylee2044/dsh-hos', url: SITE, first: true }),
          h(LinkRow, { title: 'DeepSeek Harness 上游', hint: 'github.com/deepseek-ai/deepseek-harness', url: 'https://github.com/deepseek-ai/deepseek-harness' })),
        h(Section, { title: '许可与源码' },
          h(LinkRow, { title: '第三方软件声明', hint: 'THIRD_PARTY_NOTICES.md', url: SITE + '/blob/main/THIRD_PARTY_NOTICES.md', first: true }),
          h(LinkRow, { title: '许可证全文', hint: 'LICENSES/', url: SITE + '/tree/main/LICENSES' }),
          h(LinkRow, { title: 'GNU Bash 5.3 对应源码', hint: 'ftp.gnu.org · bash-5.3.tar.gz', url: 'https://ftp.gnu.org/gnu/bash/bash-5.3.tar.gz' })));
    }

    return {
      inject: ['slots', 'sidebarRight', 'sidebarRightTabs'],
      apply(ctx) {
        window.__dshHarmonyTerminalApply = true;
        ctx.effect(function () {
          return ctx.sidebarRightTabs.register({
            id: TAB_ID,
            kind: TAB_KIND,
            priority: 'extension',
            multiple: true,
            keepMounted: true,
            title: function () { return '终端'; },
            guide: [{
              id: 'new', order: 20,
              title: function () { return '新建终端'; },
              description: function () { return '新建原生终端标签，运行 bash'; }
            }]
          });
        }, 'dsh-hos.terminal.type');

        ctx.effect(function () {
          return ctx.sidebarRight.registerCloseHandler(TAB_KIND, function () {
            post('close', { owner: OWNER });
          });
        }, 'dsh-hos.terminal.close');

        ctx.effect(function () {
          return ctx.slots.inject('sidebar.right.pane.tab', function () {
            return ctx.slots.register({ name: 'sidebar.right.pane.tab', key: TAB_ID }, Stage);
          });
        }, 'dsh-hos.terminal.body');

        try { console.log('DSH_ABOUT_REGISTER'); } catch (e) {}
        window.__dshCollapseRightSidebar = function () {
          try {
            if (ctx.sidebarRight && ctx.sidebarRight.isExpanded && ctx.sidebarRight.isExpanded()) {
              ctx.sidebarRight.toggleExpanded();
              return true;
            }
          } catch (error) { /* 服务未就绪 */ }
          return false;
        };
        window.__dshHarmonyTerminalReady = true;
        followSession();
      }
    };
  }
});
