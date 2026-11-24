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
      return h('div', { style: { padding: '2px 0 8px' } },
        h('div', { style: {
          display: 'flex', alignItems: 'center', gap: 12, padding: 16,
          border: '1px solid var(--dsw-alias-border-l2)', borderRadius: 14,
          background: 'var(--dsw-alias-bg-l1)'
        } },
          h('div', { style: {
            width: 46, height: 46, flex: '0 0 46px', borderRadius: 12,
            display: 'flex', alignItems: 'center', justifyContent: 'center',
            background: 'linear-gradient(135deg,#0B5D52,#1C9A83)', color: '#F6F3E8',
            fontSize: 13, fontWeight: 700
          } }, 'DSH'),
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
            multiple: false,
            keepMounted: true,
            title: function () { return '终端'; },
            guide: [{
              id: 'new', order: 20,
              title: function () { return '原生终端'; },
              description: function () { return '在侧栏运行 shell，画面由系统原生绘制'; }
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

        ctx.effect(function () {
          return ctx.slots.inject('settings.section', function () {
            return ctx.slots.register({
              name: 'settings.section', id: 'harmony-about', order: 100,
              label: function () { return '关于'; }
            }, About);
          });
        }, 'dsh-hos.about');

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
