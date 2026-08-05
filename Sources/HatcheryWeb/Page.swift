import Foundation

/// The dashboard, as one self-contained page.
///
/// Inline rather than a bundle: no build step, no asset pipeline, and nothing to serve but this
/// string. It also means the page cannot silently drift from the binary that serves it.
enum Page {
    static let markup = """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>hatchery</title>
        <link rel="icon" href="data:image/svg+xml,%3Csvg%20xmlns%3D%27http%3A//www.w3.org/2000/svg%27%20viewBox%3D%270%200%2064%2064%27%20fill%3D%27%23C4602A%27%3E%20%20%3Cpath%20d%3D%27M46%2022%20L42%2026%20L38%2022%20L34%2026%20L30%2022%20L26%2026%20L22%2022%20L20%2024%20C20%2014%2025%204%2033%204%20C41%204%2047%2014%2047%2024%20Z%27/%3E%20%20%3Ccircle%20cx%3D%2733%27%20cy%3D%2731%27%20r%3D%274.4%27/%3E%20%20%3Cpath%20d%3D%27M37%2030%20L43%2032%20L37%2034%20Z%27/%3E%20%20%3Cpath%20d%3D%27M18%2034%20L22%2030%20L26%2034%20L30%2030%20L34%2034%20L38%2030%20L42%2034%20L46%2030%20C46%2042%2040%2050%2032%2050%20C24%2050%2018%2042%2018%2034%20Z%27/%3E%20%20%3Crect%20x%3D%2724.6%27%20y%3D%2749%27%20width%3D%272.6%27%20height%3D%276%27%20rx%3D%271.3%27/%3E%20%20%3Crect%20x%3D%2736.8%27%20y%3D%2749%27%20width%3D%272.6%27%20height%3D%276%27%20rx%3D%271.3%27/%3E%20%20%3Crect%20x%3D%277%27%20y%3D%2754.5%27%20width%3D%2750%27%20height%3D%273%27%20rx%3D%271.5%27/%3E%3C/svg%3E">
        <style>
          :root {
            color-scheme: light dark;
            --bg: #fbfbfa; --fg: #1a1a18; --dim: #6b6b66; --line: #e3e3df;
            --card: #ffffff; --ready: #2f7a48; --responding: #7a6a2f;
            --degraded: #9a5a1f; --unreachable: #9a2f2f; --accent: #C4602A;
            --brand: #C4602A;
          }
          @media (prefers-color-scheme: dark) {
            :root {
              --bg: #16161a; --fg: #e8e8e4; --dim: #9a9a94; --line: #2c2c32;
              --card: #1e1e23; --ready: #6ec48a; --responding: #cbb46a;
              --degraded: #d99a5a; --unreachable: #e07a7a; --accent: #E08A4F;
              --brand: #E08A4F;
            }
          }
          * { box-sizing: border-box; }
          body {
            margin: 0; padding: 2rem 1rem; background: var(--bg); color: var(--fg);
            font: 15px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace;
          }
          main { max-width: 60rem; margin: 0 auto; }
          h1 { font-size: 1.1rem; margin: 0; font-weight: 600; letter-spacing: 0.02em; }
          .brandbar { display: flex; align-items: center; gap: 0.6rem; margin-bottom: 0.15rem; }
          .mark { width: 28px; height: 28px; color: var(--brand); flex: none; }
          .brandbar .sib { margin-left: auto; font-size: 0.7rem; color: var(--dim); }
          .empty .mark { width: 56px; height: 56px; opacity: 0.55; margin-bottom: 0.75rem; }
          .sub { color: var(--dim); font-size: 0.85rem; margin-bottom: 1.5rem; }
          .stack {
            background: var(--card); border: 1px solid var(--line);
            border-radius: 8px; margin-bottom: 1rem; overflow: hidden;
          }
          .stack > header {
            display: flex; align-items: baseline; gap: 0.75rem;
            padding: 0.75rem 1rem; border-bottom: 1px solid var(--line);
          }
          .stack h2 { font-size: 0.95rem; margin: 0; font-weight: 600; }
          .meta { color: var(--dim); font-size: 0.8rem; }
          .prod {
            color: var(--degraded); border: 1px solid currentColor;
            border-radius: 3px; padding: 0 0.35rem; font-size: 0.7rem;
          }
          table { width: 100%; border-collapse: collapse; }
          td { padding: 0.5rem 1rem; border-top: 1px solid var(--line); vertical-align: top; }
          tr:first-child td { border-top: 0; }
          .name { font-weight: 600; }
          .kind { color: var(--dim); font-size: 0.8rem; }
          .state { font-weight: 600; }
          .ready { color: var(--ready); }
          .responding { color: var(--responding); }
          .degraded { color: var(--degraded); }
          .unreachable { color: var(--unreachable); }
          .reason { color: var(--dim); font-size: 0.8rem; }
          .num { color: var(--dim); text-align: right; white-space: nowrap; }
          .actions { text-align: right; white-space: nowrap; }
          button {
            font: inherit; font-size: 0.8rem; padding: 0.2rem 0.6rem; cursor: pointer;
            background: transparent; color: var(--accent);
            border: 1px solid var(--line); border-radius: 4px;
          }
          button:hover { border-color: var(--accent); }
          button:disabled { opacity: 0.4; cursor: default; }
          dialog {
            background: var(--card); color: var(--fg); border: 1px solid var(--line);
            border-radius: 8px; padding: 1.25rem; max-width: 26rem; font: inherit;
          }
          dialog::backdrop { background: rgba(0,0,0,0.45); }
          dialog p { margin: 0 0 0.75rem; font-size: 0.9rem; }
          dialog input {
            font: inherit; width: 100%; padding: 0.4rem; margin-bottom: 0.75rem;
            background: var(--bg); color: var(--fg);
            border: 1px solid var(--line); border-radius: 4px;
          }
          .row { display: flex; gap: 0.5rem; justify-content: flex-end; }
          #log {
            margin-top: 1.5rem; white-space: pre-wrap; font-size: 0.8rem;
            color: var(--dim); border-top: 1px solid var(--line); padding-top: 0.75rem;
          }
          .err { color: var(--unreachable); }
          .empty { text-align: center; padding: 3rem 1rem; color: var(--dim); }
          .empty h2 { color: var(--fg); font-size: 1rem; margin: 0 0 0.5rem; }
          .empty p { margin: 0 0 1.25rem; font-size: 0.85rem; }
          .primary { border-color: var(--accent); }
          dialog h3 { margin: 0 0 0.25rem; font-size: 0.95rem; }
          .steps { color: var(--dim); font-size: 0.75rem; margin-bottom: 0.9rem; }
          label { display: block; font-size: 0.75rem; color: var(--dim); margin-bottom: 0.15rem; }
          .field { margin-bottom: 0.6rem; }
          .hint { font-size: 0.7rem; color: var(--dim); margin-top: 0.15rem; }
          select {
            font: inherit; width: 100%; padding: 0.4rem; background: var(--bg); color: var(--fg);
            border: 1px solid var(--line); border-radius: 4px;
          }
          .origins { font-size: 0.75rem; margin: 0.5rem 0 0.75rem; }
          .origins div { display: flex; justify-content: space-between; gap: 1rem; }
          .origins .val { color: var(--dim); }
          .needs { color: var(--degraded); }
          .add { font-size: 0.75rem; }
          .last { margin-left: auto; }
          .detail {
            background: var(--bg); border-top: 1px solid var(--line);
            padding: 0.75rem 1rem; font-size: 0.8rem;
          }
          .detail dl { display: grid; grid-template-columns: 7rem 1fr; gap: 0.15rem 0.75rem; margin: 0 0 0.75rem; }
          .detail dt { color: var(--dim); }
          .detail dd { margin: 0; word-break: break-all; }
          .kv { display: grid; grid-template-columns: minmax(8rem, auto) 1fr; gap: 0.1rem 0.75rem; }
          .kv .k { color: var(--dim); }
          .kv .v { word-break: break-all; }
          .kv .sec { color: var(--degraded); }
          .issue { margin-top: 0.4rem; }
          .issue.error { color: var(--unreachable); }
          .issue.warning { color: var(--degraded); }
          pre.out {
            margin: 0; max-height: 22rem; overflow: auto; font-size: 0.75rem;
            background: var(--bg); border: 1px solid var(--line); border-radius: 4px;
            padding: 0.5rem; line-height: 1.4;
          }
          pre.out div { white-space: pre-wrap; }
          .l-error { color: var(--unreachable); }
          .l-warning { color: var(--degraded); }
          .l-info { color: var(--dim); }
          .d-add { color: var(--ready); }
          .d-remove { color: var(--unreachable); }
          .d-change { color: var(--degraded); }
          .d-header { color: var(--fg); font-weight: 600; }
          dialog.wide { max-width: 52rem; width: 90vw; }
          .tally { margin: 0.25rem 0 0.75rem; font-size: 0.8rem; }
          .stack-actions {
            padding: 0.6rem 1rem; border-top: 1px solid var(--line);
            display: flex; gap: 0.5rem;
          }
        </style>
        </head>
        <body>
        <main>
          <div class="brandbar">
            <svg class="mark" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" fill="currentColor" aria-hidden="true">
            <path d="M46 22 L42 26 L38 22 L34 26 L30 22 L26 26 L22 22 L20 24 C20 14 25 4 33 4 C41 4 47 14 47 24 Z"/>
            <circle cx="33" cy="31" r="4.4"/>
            <path d="M37 30 L43 32 L37 34 Z"/>
            <path d="M18 34 L22 30 L26 34 L30 30 L34 34 L38 30 L42 34 L46 30 C46 42 40 50 32 50 C24 50 18 42 18 34 Z"/>
            <rect x="24.6" y="49" width="2.6" height="6" rx="1.3"/>
            <rect x="36.8" y="49" width="2.6" height="6" rx="1.3"/>
            <rect x="7" y="54.5" width="50" height="3" rx="1.5"/>
            </svg>
            <h1>hatchery</h1>
            <span class="sib">roost owns machines · hatchery owns stacks</span>
          </div>
          <div class="sub" id="sub">loading…</div>
          <div id="stacks"></div>
          <div id="log"></div>
        </main>

        <dialog id="wizard">
          <form method="dialog" id="wizard-form">
            <h3 id="wiz-title"></h3>
            <div id="wiz-body"></div>
            <div class="row">
              <button value="cancel" type="submit">cancel</button>
              <button value="ok" type="submit" id="wiz-ok">continue</button>
            </div>
          </form>
        </dialog>

        <dialog id="confirm">
          <form method="dialog">
            <p id="confirm-text"></p>
            <input id="confirm-input" autocomplete="off" spellcheck="false">
            <div class="row">
              <button value="cancel">cancel</button>
              <button value="ok" id="confirm-ok">confirm</button>
            </div>
          </form>
        </dialog>

        <script>
        const token = new URLSearchParams(location.search).get('token') || '';
        const headers = token ? {'X-Hatchery-Token': token, 'Content-Type': 'application/json'}
                              : {'Content-Type': 'application/json'};
        const $ = (id) => document.getElementById(id);
        const MARK = document.querySelector('.brandbar .mark').outerHTML;
        let busy = false;

        function log(message, isError) {
          const stamp = new Date().toLocaleTimeString();
          $('log').innerHTML = '<span class="' + (isError ? 'err' : '') + '">'
            + stamp + '  ' + escapeHTML(message) + '</span>\\n' + $('log').innerHTML;
        }

        // Written with split/join rather than a regex on purpose. A character class holding
        // quote characters is indistinguishable from an unterminated string to anything reading
        // this file line by line — including the test that checks exactly that.
        function escapeHTML(s) {
          return String(s)
            .split('&').join('&amp;')
            .split('<').join('&lt;')
            .split('>').join('&gt;')
            .split('"').join('&quot;')
            .split("'").join('&#39;');
        }

        // The dialog requires the target's name typed out. The server checks it too — this is
        // the convenience, not the control.
        function confirmNamed(name, what) {
          return new Promise(resolve => {
            $('confirm-text').textContent = what + ' — type "' + name + '" to confirm.';
            $('confirm-input').value = '';
            const dialog = $('confirm');
            dialog.onclose = () => resolve(dialog.returnValue === 'ok'
              && $('confirm-input').value === name);
            dialog.showModal();
            $('confirm-input').focus();
          });
        }

        async function act(path, body, name, what) {
          if (busy) return;
          if (!(await confirmNamed(name, what))) { log('cancelled'); return; }
          busy = true;
          render(lastStacks);
          try {
            const res = await fetch(path, {method: 'POST', headers, body: JSON.stringify(body)});
            const data = await res.json();
            log(data.message || data.error || res.status, !res.ok);
            if (data.detail) log(data.detail, !res.ok);
          } catch (e) {
            log(String(e), true);
          } finally {
            busy = false;
            refresh();
          }
        }

        let lastStacks = [];

        // Buttons carry their target in data attributes and are dispatched by one delegated
        // listener below. An inline onclick would mean a JS string inside an HTML attribute
        // inside a Swift string literal, and getting a quote wrong there is a *parse* error —
        // which kills the whole script, not just the button. That is exactly what happened.
        function button(action, label, stack, service, extraClass) {
          return '<button data-action="' + action + '"'
            + (stack ? ' data-stack="' + escapeHTML(stack) + '"' : '')
            + (service ? ' data-service="' + escapeHTML(service) + '"' : '')
            + (extraClass ? ' class="' + extraClass + '"' : '')
            + (busy ? ' disabled' : '') + '>' + escapeHTML(label) + '</button>';
        }

        document.addEventListener('click', event => {
          const target = event.target.closest('button[data-action]');
          if (!target) return;
          const stack = target.dataset.stack;
          const service = target.dataset.service;
          switch (target.dataset.action) {
            case 'restart': restart(stack, service); break;
            case 'deploy': deploy(stack, service); break;
            case 'new-service': newService(stack); break;
            case 'new-stack': newStack(); break;
            case 'apply': applyStack(stack); break;
            case 'logs': showLogs(stack, service); break;
            case 'config': showConfig(stack, service); break;
            case 'edit-config': editConfig(stack, service); break;
            case 'setup': showSetup(); break;
          }
        });

        // A refresh rebuilds the stack markup, which would throw away any panel you had open —
        // and a log panel that vanishes every ten seconds is worse than no log panel. So the
        // open ones are captured first and put back afterwards, scroll position included.
        function capturePanels() {
          const open = {};
          document.querySelectorAll('.detail').forEach(box => {
            if (box.hidden) return;
            const pre = box.querySelector('pre.out');
            open[box.id] = {html: box.innerHTML, kind: box.dataset.kind || '',
                            scroll: pre ? pre.scrollTop : 0};
          });
          return open;
        }

        function restorePanels(open) {
          Object.keys(open).forEach(id => {
            const box = $(id);
            if (!box) return;   // the service is gone from the manifest; nothing to restore into
            box.innerHTML = open[id].html;
            box.dataset.kind = open[id].kind;
            box.hidden = false;
            const pre = box.querySelector('pre.out');
            if (pre) pre.scrollTop = open[id].scroll;
          });
        }

        function render(stacks) {
          const open = capturePanels();
          lastStacks = stacks;
          if (!stacks.length) {
            $('stacks').innerHTML = '<div class="empty">' + MARK
              + '<h2>Nothing declared yet</h2>'
              + '<p>Create a stack, add a service, and hatchery will write the tofu,'
              + ' mint what it can, and tell you what it cannot.</p>'
              + button('new-stack', 'Create a stack', null, null, 'primary')
              + ' ' + button('setup', 'No box yet?', null, null, 'add') + '</div>';
            return;
          }

          $('stacks').innerHTML = stacks.map(stack => {
            const rows = stack.services.map(svc => {
              const state = svc.state || 'unknown';
              const reasons = (svc.reasons || []).map(r =>
                '<div class="reason">' + escapeHTML(r) + '</div>').join('');
              const latency = svc.latencyMs == null ? '' : svc.latencyMs + 'ms';
              return '<tr>'
                + '<td><div class="name">' + escapeHTML(svc.name) + '</div>'
                +   '<div class="kind">' + escapeHTML(svc.kind) + '</div></td>'
                + '<td><span class="state ' + escapeHTML(state) + '">' + escapeHTML(state)
                +   '</span>' + reasons + '</td>'
                + '<td class="num">' + latency + '</td>'
                + '<td class="actions">'
                +   button('logs', 'logs', stack.name, svc.name)
                +   ' '
                +   button('config', 'config', stack.name, svc.name)
                +   ' '
                +   button('restart', 'restart', stack.name, svc.name)
                +   ' '
                +   button('deploy', 'deploy', stack.name, svc.name)
                + '</td></tr>'
                + '<tr><td colspan="4" style="padding:0;border-top:0">'
                +   '<div class="detail" id="d-' + escapeHTML(stack.name) + '-'
                +     escapeHTML(svc.name) + '" hidden></div>'
                + '</td></tr>';
            }).join('');
            const badge = stack.isProduction ? '<span class="prod">prod</span>' : '';
            return '<section class="stack"><header>'
              + '<h2>' + escapeHTML(stack.name) + '</h2>'
              + '<span class="meta">' + escapeHTML(stack.backend) + ' · '
              + escapeHTML(stack.environment) + '</span>' + badge
              + '<span class="meta state ' + escapeHTML(stack.state || '')
              + '" style="margin-left:auto">' + escapeHTML(stack.state || '') + '</span>'
              + '</header><table>' + rows + '</table>'
              + '<div class="stack-actions">'
              +   button('new-service', '+ service', stack.name, null, 'add')
              +   button('apply', 'apply', stack.name, null, 'add')
              +   button('new-stack', '+ stack', null, null, 'add last')
              + '</div></section>';
          }).join('');
          restorePanels(open);
        }

        function restart(stack, service) {
          act('/api/lifecycle', {stack, service, action: 'restart', confirm: service},
              service, 'Restart ' + service);
        }

        // Plans, renders the diff into the service's own panel, and only then offers to apply.
        // Reading the plan before applying is the whole reason the deploy path goes through
        // tofu rather than around it.
        async function deploy(stack, service) {
          if (!(await confirmNamed(service, 'Plan a deploy of ' + service + ' — nothing is applied yet')))
            { log('cancelled'); return; }

          const box = togglePanel(stack, service, {kind: 'plan', body: 'planning…'});
          busy = true;
          const res = await send('/api/deploy', {stack, service, apply: false, confirm: service});
          busy = false;
          log(res.data.message || res.data.error, !res.ok);

          const target = panel(stack, service);
          if (!target) return;
          if (!res.data.summary) {
            target.innerHTML = '<span class="err">' + escapeHTML(res.data.error || 'no plan') + '</span>';
            target.hidden = false;
            return;
          }
          target.dataset.kind = 'plan';
          target.innerHTML = renderPlan(res.data.summary)
            + (res.data.summary.parsed && !(res.data.summary.add === 0
                 && res.data.summary.change === 0 && res.data.summary.destroy === 0)
               ? '<div style="margin-top:0.6rem">'
                 + button('apply', 'apply this stack', stack, null, 'add') + '</div>'
               : '');
          target.hidden = false;
        }

        async function refresh() {
          try {
            const res = await fetch('/api/status', {headers});
            if (!res.ok) {
              const data = await res.json().catch(() => ({}));
              $('sub').textContent = data.error || ('HTTP ' + res.status);
              return;
            }
            render(await res.json());
            $('sub').textContent = 'updated ' + new Date().toLocaleTimeString();
          } catch (e) {
            $('sub').textContent = String(e);
          }
        }

        // ---- wizard ----------------------------------------------------------
        // Each step only opens once the one before it succeeded, so a half-made stack is
        // never left looking finished.
        // Loaded once, and awaited before any step that needs it. Rendering a menu from a
        // fetch that has not landed yet gives an empty dropdown with nothing to pick, and
        // swallowing the failure leaves it empty forever with no sign of why.
        let meta = null;
        const metaReady = fetch('/api/kinds', {headers})
          .then(r => r.ok ? r.json() : Promise.reject(new Error('HTTP ' + r.status)))
          .then(m => { meta = m; return m; });

        async function ensureMeta() {
          if (meta) return meta;
          try {
            return await metaReady;
          } catch (e) {
            log('could not load service kinds: ' + e.message, true);
            return null;
          }
        }

        function field(id, label, value, hint, type) {
          return '<div class="field"><label for="' + id + '">' + escapeHTML(label) + '</label>'
            + '<input id="' + id + '" value="' + escapeHTML(value || '') + '"'
            + (type ? ' type="' + type + '"' : '') + ' autocomplete="off" spellcheck="false">'
            + (hint ? '<div class="hint">' + escapeHTML(hint) + '</div>' : '') + '</div>';
        }

        function select(id, label, options, hint) {
          return '<div class="field"><label for="' + id + '">' + escapeHTML(label) + '</label>'
            + '<select id="' + id + '">'
            + options.map(o => '<option>' + escapeHTML(o) + '</option>').join('')
            + '</select>'
            + (hint ? '<div class="hint">' + escapeHTML(hint) + '</div>' : '') + '</div>';
        }

        function step(title, steps, bodyHTML, okLabel) {
          return new Promise(resolve => {
            $('wiz-title').textContent = title;
            $('wiz-body').innerHTML = '<div class="steps">' + escapeHTML(steps) + '</div>' + bodyHTML;
            $('wiz-ok').textContent = okLabel || 'continue';
            const dialog = $('wizard');
            dialog.onclose = () => resolve(dialog.returnValue === 'ok');
            dialog.showModal();
            const first = $('wiz-body').querySelector('input, select');
            if (first) first.focus();
          });
        }

        async function send(path, body) {
          const res = await fetch(path, {method: 'POST', headers, body: JSON.stringify(body)});
          const data = await res.json().catch(() => ({}));
          return {ok: res.ok, data};
        }

        async function newStack() {
          if (!(await ensureMeta())) return;
          // Only backends hatchery can actually author are offered. Listing one it would refuse
          // turns a menu into a dead end you discover after filling the form in.
          const authorable = meta.backends.filter(b => b.authorable).map(b => b.name);
          const blocked = meta.backends.filter(b => !b.authorable);
          if (!authorable.length) { log('no backend can be created by this build', true); return; }

          const ok = await step('New stack', 'Step 1 of 3 — where it lives',
              field('w-name', 'Name', '',
                    'Identifies the stack in hatchery. Lowercase, dashes allowed.')
            + select('w-backend', 'Backend', authorable,
                     'What runs the services. '
                     + (blocked.length
                        ? blocked.map(b => b.note).join('; ') + '.'
                        : 'Every backend this build supports is listed.'))
            + field('w-host', 'SSH target', 'dokku@192.168.0.103',
                    'How hatchery reaches the box to create and manage apps. The user must be '
                    + 'dokku — that account is what turns an SSH command into a dokku command — '
                    + 'and your key must already be authorized for it. Checked in the next step.')
            + field('w-dir', 'Tofu directory', '~/infra-state/',
                    'Where the generated tofu configuration and the config file for each service are '
                    + 'written. Must be empty or not exist. Keep it somewhere durable and backed '
                    + 'up: it holds the state that maps tofu to the running apps.')
            + select('w-env', 'Environment', meta.environments,
                     'Labels the stack. A prod stack refuses to apply from the browser.'));
          if (!ok) { log('cancelled'); return; }

          const name = $('w-name').value.trim();
          const host = $('w-host').value.trim();
          const dir = $('w-dir').value.trim();
          const env = $('w-env').value;
          const backend = $('w-backend').value;

          // Check before creating rather than after. These failures otherwise surface halfway
          // through `tofu init`, as a provider error that never mentions the real cause.
          if (!(await preflight(host))) return;

          busy = true;
          const res = await send('/api/stacks/new',
            {name, host, tofuDir: dir, environment: env, backend, confirm: name});
          busy = false;
          log(res.data.message || res.data.error, !res.ok);
          if (!res.ok) return;
          await refresh();
          newService(name);
        }

        async function preflight(host) {
          $('wiz-title').textContent = 'Checking prerequisites';
          $('wiz-body').innerHTML = '<div class="steps">Step 2 of 3 — can we reach it?</div>'
            + '<div id="pf">checking ' + escapeHTML(host) + '…</div>';
          $('wiz-ok').textContent = 'continue';
          const dialog = $('wizard');
          const done = new Promise(resolve => { dialog.onclose = () => resolve(dialog.returnValue === 'ok'); });
          dialog.showModal();

          const res = await get('/api/preflight?host=' + encodeURIComponent(host));
          const checks = res.ok ? res.data : [];
          const failed = checks.some(c => c.status === 'failed');
          $('pf').innerHTML = checks.map(c => {
            const cls = c.status === 'ok' ? 'd-add' : (c.status === 'failed' ? 'err' : 'hint');
            const mark = c.status === 'ok' ? 'ok' : (c.status === 'failed' ? 'FAIL' : '--');
            return '<div class="' + cls + '">' + mark + '  ' + escapeHTML(c.name) + ': '
              + escapeHTML(c.detail) + '</div>'
              + (c.remedy ? '<div class="hint">&nbsp;&nbsp;&nbsp;&rarr; ' + escapeHTML(c.remedy)
                            + '</div>' : '');
          }).join('');
          if (failed) {
            $('pf').innerHTML += '<div class="hint" style="margin-top:0.6rem">'
              + 'Fix these and try again — creating the stack now would fail partway through. '
              + 'If the box has no dokku on it yet, close this and use "No box yet?".</div>';
            $('wiz-ok').textContent = 'create anyway';
          }
          const proceed = await done;
          if (!proceed) log('cancelled at prerequisites');
          return proceed;
        }

        async function newService(stack) {
          if (!(await ensureMeta())) return;
          if (!meta.kinds.length) { log('no service kinds available', true); return; }

          const ok = await step('New service in ' + stack, 'Step 3 of 3 — what runs',
              field('s-name', 'Name', '',
                    'Becomes the dokku app name and names its config file.')
            + select('s-kind', 'Kind',  meta.kinds,
                     'Decides which environment contract applies — what it needs to boot, '
                     + 'and which of those hatchery can supply for you.')
            + field('s-image', 'Image', '',
                    'A tag that already exists on the host. hatchery does not build images; '
                    + 'build it on the box first, then name it here.')
            + field('s-domains', 'Domains', '',
                    'Comma separated. The first is what health checks are sent to.')
            + field('s-network', 'Docker network', 'macworkstack-infra_default',
                    'The docker network holding the database. Without it the app starts and '
                    + 'then cannot reach postgres. Blank if it needs no database.')
            + field('s-port', 'Container port', '8080',
                    'The port inside the container. Dokku maps 80 to it.'),
            'create');
          if (!ok) { log('cancelled'); return; }

          const name = $('s-name').value.trim();
          const body = {
            stack, name, kind: $('s-kind').value, image: $('s-image').value.trim(),
            domains: $('s-domains').value.split(',').map(d => d.trim()).filter(Boolean),
            network: $('s-network').value.trim() || null,
            port: parseInt($('s-port').value, 10) || 8080, confirm: name};

          busy = true;
          const res = await send('/api/services/new', body);
          busy = false;
          log(res.data.message || res.data.error, !res.ok);
          if (!res.ok) return;

          (res.data.origins || []).forEach(o => log('  ' + o.key + '  ' + o.origin));
          await refresh();
          if ((res.data.missing || []).length) {
            fillSecrets(stack, name, res.data.missing);
          } else {
            log('nothing left to fill in — apply when ready');
          }
        }

        // Values are posted straight to the server and never rendered back.
        async function fillSecrets(stack, service, missing) {
          const body = missing.map(m =>
            field('k-' + m.key, m.key, '', m.reason, m.secret ? 'password' : null)).join('');
          const ok = await step('Values hatchery cannot invent',
            missing.length + ' key(s) for ' + service, body, 'save');
          if (!ok) { log('skipped — ' + service + ' will not boot until these are set'); return; }

          const values = {};
          missing.forEach(m => {
            const v = $('k-' + m.key).value;
            if (v) values[m.key] = v;
          });
          if (!Object.keys(values).length) { log('nothing entered'); return; }

          busy = true;
          const res = await send('/api/config/set', {stack, service, values, confirm: service});
          busy = false;
          log(res.data.message || res.data.error, !res.ok);
        }

        async function applyStack(stack) {
          if (!(await confirmNamed(stack, 'Apply ' + stack + ' — this changes running infrastructure')))
            { log('cancelled'); return; }
          busy = true; render(lastStacks);
          const res = await send('/api/apply', {stack, confirm: stack});
          busy = false;
          log(res.data.message || res.data.error, !res.ok);
          if (res.data.detail) log(res.data.detail, !res.ok);
          refresh();
        }

        // The half `doctor` cannot do for you: getting dokku onto a box in the first place.
        // Shown rather than run — these steps touch a package manager and an SSH config.
        async function showSetup() {
          const res = await get('/api/setup');
          if (!res.ok) { log('could not load the setup guide', true); return; }
          const body = res.data.map((step, i) =>
            '<div class="field"><label>' + (i + 1) + '. ' + escapeHTML(step.title)
            + '  · on the ' + escapeHTML(step.on) + '</label>'
            + '<div class="hint">' + escapeHTML(step.why) + '</div>'
            + '<pre class="out">' + step.commands.map(escapeHTML).join('\\n') + '</pre>'
            + (step.verify ? '<div class="hint">check: ' + escapeHTML(step.verify) + '</div>' : '')
            + '</div>').join('');
          await step('Getting a box ready', 'hatchery manages stacks; this puts dokku under them',
                     body, 'done');
        }

        // ---- detail, logs, config, diffs ------------------------------------
        // The detail panel lives under its service row and toggles, so opening one does not
        // navigate away from everything else that is currently degraded.
        function panel(stack, service) { return $('d-' + stack + '-' + service); }

        function togglePanel(stack, service, html) {
          const box = panel(stack, service);
          if (!box) return null;
          if (!box.hidden && box.dataset.kind === html.kind) { box.hidden = true; return null; }
          box.dataset.kind = html.kind;
          box.innerHTML = html.body;
          box.hidden = false;
          return box;
        }

        async function get(path) {
          const res = await fetch(path, {headers});
          const data = await res.json().catch(() => ({}));
          return {ok: res.ok, data};
        }

        function query(stack, service, extra) {
          return '?stack=' + encodeURIComponent(stack)
            + '&service=' + encodeURIComponent(service) + (extra || '');
        }

        async function showLogs(stack, service) {
          const box = togglePanel(stack, service, {kind: 'logs', body: 'reading logs…'});
          if (!box) return;
          const res = await get('/api/logs' + query(stack, service, '&lines=200'));
          if (!res.ok) { box.innerHTML = '<span class="err">' + escapeHTML(res.data.error) + '</span>'; return; }
          const lines = res.data.lines || [];
          // Stamped because the panel survives a refresh but its contents do not update with
          // it — without this you cannot tell a quiet service from a stale panel.
          const stamp = '<div class="hint">' + lines.length + ' line(s), read '
            + new Date().toLocaleTimeString() + ' — click logs again to re-read</div>';
          box.innerHTML = lines.length
            ? stamp + '<pre class="out">' + lines.map(l =>
                '<div class="l-' + l.level + '">' + escapeHTML(l.text) + '</div>').join('') + '</pre>'
            : stamp + '<span class="hint">no output</span>';
        }

        async function showConfig(stack, service) {
          const box = togglePanel(stack, service, {kind: 'config', body: 'reading config…'});
          if (!box) return;
          const res = await get('/api/config' + query(stack, service));
          if (!res.ok) { box.innerHTML = '<span class="err">' + escapeHTML(res.data.error) + '</span>'; return; }
          const c = res.data;
          const secret = new Set(c.secretKeys || []);
          const keys = Object.keys(c.declared || {}).sort();

          const rows = keys.map(k =>
            '<div class="k' + (secret.has(k) ? ' sec' : '') + '">' + escapeHTML(k) + '</div>'
            + '<div class="v">' + escapeHTML(c.declared[k]) + '</div>').join('');

          const issues = (c.issues || []).map(i =>
            '<div class="issue ' + i.severity + '">' + escapeHTML(i.severity) + ': '
            + escapeHTML(i.key) + ' — ' + escapeHTML(i.message) + '</div>').join('');

          box.innerHTML = '<dl>'
            + '<dt>image</dt><dd>' + escapeHTML(c.image) + '</dd>'
            + '<dt>kind</dt><dd>' + escapeHTML(c.kind) + '</dd>'
            + '<dt>domains</dt><dd>' + escapeHTML((c.domains || []).join(', ')) + '</dd>'
            + '<dt>source</dt><dd>' + escapeHTML(c.source)
            +   (c.source === 'live' ? ' (what it is running with)' : ' (the file; the box was unreachable)')
            + '</dd></dl>'
            + '<div class="kv">' + rows + '</div>' + issues
            + '<div style="margin-top:0.6rem">'
            + button('edit-config', 'edit', stack, service, 'add') + '</div>';
        }

        // Secret values are shown as a fingerprint, never the value, so a field left untouched
        // must not be posted back — that would write the fingerprint over the real secret.
        async function editConfig(stack, service) {
          const res = await get('/api/config' + query(stack, service));
          if (!res.ok) { log(res.data.error, true); return; }
          const c = res.data;
          const secret = new Set(c.secretKeys || []);
          const keys = Object.keys(c.declared || {}).sort();

          const body = keys.map(k => field('c-' + k, k,
            secret.has(k) ? '' : c.declared[k],
            secret.has(k) ? 'secret — leave blank to keep it unchanged' : null)).join('')
            + '<div class="field"><label>Add a key</label>'
            + '<input id="c-new-key" placeholder="KEY" autocomplete="off">'
            + '<input id="c-new-val" placeholder="value" autocomplete="off"></div>';

          const ok = await step('Config for ' + service, keys.length + ' key(s)', body, 'save');
          if (!ok) { log('cancelled'); return; }

          const values = {};
          keys.forEach(k => {
            const v = $('c-' + k).value;
            if (secret.has(k)) { if (v) values[k] = v; }
            else if (v !== c.declared[k]) { values[k] = v; }
          });
          const newKey = $('c-new-key').value.trim();
          if (newKey) values[newKey] = $('c-new-val').value;

          if (!Object.keys(values).length) { log('nothing changed'); return; }
          busy = true;
          const out = await send('/api/config/set', {stack, service, values, confirm: service});
          busy = false;
          log(out.data.message || out.data.error, !out.ok);
          if (out.data.detail) log(out.data.detail, !out.ok);
        }

        function renderPlan(summary) {
          const lines = (summary.lines || []).map(l =>
            '<div class="d-' + l.kind + '">' + escapeHTML(l.text) + '</div>').join('');
          const tally = summary.parsed
            ? '<div class="tally"><span class="d-add">+' + summary.add + ' add</span>  '
              + '<span class="d-change">~' + summary.change + ' change</span>  '
              + '<span class="d-remove">-' + summary.destroy + ' destroy</span></div>'
            : '';
          return tally + '<pre class="out">' + lines + '</pre>';
        }

        // A poll that fires while a dialog is open steals focus and re-renders under you.
        function anyDialogOpen() {
          return document.querySelector('dialog[open]') !== null;
        }

        refresh();
        setInterval(() => { if (!busy && !anyDialogOpen()) refresh(); }, 10000);
        </script>
        </body>
        </html>
        """
}
