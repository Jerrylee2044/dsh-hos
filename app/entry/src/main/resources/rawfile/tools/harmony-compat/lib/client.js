window.__ModuleLoader__.load({
  id: "@deepseek-ai/dsh-harmony-compat",
  factory: (require) => {
    const exports = {};
    const React = require("react");
    const primitives = require("@deepseek-ai/dsh-client-ui-primitives");
    const Switch = primitives.Switch;

    const styleId = "dshhos-harmony-settings";
    if (typeof document !== "undefined" && document.querySelector("style[data-dshhos=" + JSON.stringify(styleId) + "]") === null) {
      const style = document.createElement("style");
      style.dataset.dshhos = styleId;
      style.textContent = [
        ".dshhos-setting-row{display:flex;align-items:center;justify-content:space-between;gap:24px;padding:16px 0;border-bottom:.5px solid var(--dsw-alias-border-l2)}",
        ".dshhos-setting-copy{min-width:0}",
        ".dshhos-setting-title{color:var(--dsw-alias-label-primary);font-size:14px;line-height:22px}",
        ".dshhos-setting-desc{margin-top:4px;color:var(--dsw-alias-label-secondary);font-size:12px;line-height:18px}"
      ].join("");
      document.head.appendChild(style);
    }

    const copy = {
      zh: {
        keepTitle: "后台保活",
        keepDesc: "使用定位类连续任务，降低切到后台后被系统冻结的概率。需要定位与后台定位权限；仍可能被低内存或省电策略回收。"
      },
      en: {
        keepTitle: "Background keep-alive",
        keepDesc: "Runs a location continuous task to reduce background freezing. Needs location and background-location permission; low memory or battery policy can still stop it."
      }
    };

    function SwitchRow(props) {
      const formState = props.useConfig((value) => value);
      const checked = formState?.value?.[props.field] === true;
      const disabled = formState?.status !== "ready" || formState?.writable !== true;
      return React.createElement("div", { className: "dshhos-setting-row" },
        React.createElement("div", { className: "dshhos-setting-copy" },
          React.createElement("div", { className: "dshhos-setting-title" }, props.t(props.titleKey)),
          React.createElement("div", { className: "dshhos-setting-desc" }, props.t(props.descKey))),
        React.createElement(Switch, {
          checked: checked,
          label: props.t(props.titleKey),
          disabled: disabled,
          onChange: (enabled) => props.onChange(enabled)
        }));
    }

    function KeepAliveRow(props) {
      return React.createElement(SwitchRow, {
        t: props.t, useConfig: props.useConfig, field: "keepAlive",
        titleKey: "keepTitle", descKey: "keepDesc", onChange: props.setKeepAlive
      });
    }


    const inject = ["slots", "locale", "configForms"];

    function apply(ctx) {
      const locale = "settings.dshhos";
      const namespace = "harmony-native";
      ctx.effect(() => ctx.locale.register(locale, copy), "dshhos: settings copy");
      const form = ctx.configForms.get(namespace);

      const keepFace = () => ({
        hooks: { config: form },
        setKeepAlive: (enabled) => { void form.set("keepAlive", enabled); }
      });

      ctx.effect(() => ctx.configForms.whileServed([namespace], () => ctx.slots.inject(
        "settings.general.item",
        () => ctx.slots.register({
          name: "settings.general.item",
          id: namespace + "-keepalive",
          order: 95,
          locale,
          inject: keepFace
        }, KeepAliveRow)
      )), "dshhos: keepalive row");
    }

    // 页面状态上报：壳层用这些消息处理返回手势和终端浮层。
    (function installShellBridge() {
      if (window.__dshhosBridgeInstalled) return;
      window.__dshhosBridgeInstalled = true;
      let previous = "";
      const emit = (payload) => {
        try {
          if (window.top !== window) return;
          const nonce = window.__dshNonce;
          if (typeof nonce !== "string" || nonce === "") return;
          console.log("DSH_TERM:" + nonce + ":" + JSON.stringify(Object.assign({ op: "ui" }, payload)));
        } catch (error) { /* page not ready */ }
      };
      const readState = () => {
        try {
          const navigation = document.querySelector("[role=dialog][aria-label=\"导航\"]");
          const dialog = document.querySelector("[role=dialog]:not([aria-label=\"导航\"])") !== null;
          const menu = document.querySelector("[role=menu]") !== null;
          const collapse = document.querySelector("[aria-label=\"收起右侧边栏\"]");
          const right = collapse !== null && getComputedStyle(collapse).visibility !== "hidden"
            && collapse.getBoundingClientRect().width > 0;
          return {
            nav: navigation !== null && navigation.getAttribute("aria-modal") === "true",
            dialog: dialog, menu: menu, right: right
          };
        } catch (error) { return { nav: false, dialog: false, menu: false, right: false }; }
      };
      const sample = () => {
        const state = readState();
        const key = JSON.stringify(state);
        if (key !== previous) { previous = key; emit(state); }
      };
      new MutationObserver(sample).observe(document.documentElement, {
        subtree: true, childList: true, attributes: true,
        attributeFilter: ["aria-modal", "aria-expanded", "aria-hidden", "class", "style", "role"]
      });
      window.setInterval(sample, 350);
      sample();
    })();

    exports.apply = apply;
    exports.inject = inject;
    return exports;
  }
});
