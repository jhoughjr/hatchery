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
        <style>
          :root {
            color-scheme: light dark;
            --bg: #fbfbfa; --fg: #1a1a18; --dim: #6b6b66; --line: #e3e3df;
            --card: #ffffff; --ready: #2f7a48; --responding: #7a6a2f;
            --degraded: #9a5a1f; --unreachable: #9a2f2f; --accent: #3a5a9a;
          }
          @media (prefers-color-scheme: dark) {
            :root {
              --bg: #16161a; --fg: #e8e8e4; --dim: #9a9a94; --line: #2c2c32;
              --card: #1e1e23; --ready: #6ec48a; --responding: #cbb46a;
              --degraded: #d99a5a; --unreachable: #e07a7a; --accent: #8aa8e0;
            }
          }
          * { box-sizing: border-box; }
          body {
            margin: 0; padding: 2rem 1rem; background: var(--bg); color: var(--fg);
            font: 15px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace;
          }
          main { max-width: 60rem; margin: 0 auto; }
          h1 { font-size: 1.1rem; margin: 0 0 0.25rem; font-weight: 600; }
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
          .stack-actions {
            padding: 0.6rem 1rem; border-top: 1px solid var(--line);
            display: flex; gap: 0.5rem;
          }
        </style>
        </head>
        <body>
        <main>
          <h1>hatchery</h1>
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
        let busy = false;

        function log(message, isError) {
          const stamp = new Date().toLocaleTimeString();
          $('log').innerHTML = '<span class="' + (isError ? 'err' : '') + '">'
            + stamp + '  ' + escapeHTML(message) + '</span>\\n' + $('log').innerHTML;
        }

        function escapeHTML(s) {
          return String(s).replace(/[&<>"']/g, c => ({
            '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
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
          }
        });

        function render(stacks) {
          lastStacks = stacks;
          if (!stacks.length) {
            $('stacks').innerHTML = '<div class="empty">'
              + '<h2>Nothing declared yet</h2>'
              + '<p>Create a stack, add a service, and hatchery will write the tofu,'
              + ' mint what it can, and tell you what it cannot.</p>'
              + button('new-stack', 'Create a stack', null, null, 'primary') + '</div>';
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
                +   button('restart', 'restart', stack.name, svc.name)
                +   ' '
                +   button('deploy', 'deploy', stack.name, svc.name)
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
        }

        function restart(stack, service) {
          act('/api/lifecycle', {stack, service, action: 'restart', confirm: service},
              service, 'Restart ' + service);
        }

        function deploy(stack, service) {
          act('/api/deploy', {stack, service, apply: false, confirm: service},
              service, 'Plan a deploy of ' + service + ' (nothing is applied)');
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
        let meta = {kinds: [], backends: ['dokku'], environments: ['dev','staging','prod']};
        fetch('/api/kinds', {headers}).then(r => r.json()).then(m => { meta = m; }).catch(() => {});

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
          const ok = await step('New stack', 'Step 1 of 2 — where it lives',
              field('w-name', 'Name', '', 'lowercase, dashes allowed')
            + field('w-host', 'SSH target', 'dokku@192.168.0.103', 'user@host for the box')
            + field('w-dir', 'Tofu directory', '~/infra-state/', 'must be empty or new')
            + select('w-env', 'Environment', meta.environments, 'prod requires the CLI to apply'));
          if (!ok) { log('cancelled'); return; }

          const name = $('w-name').value.trim();
          const body = {name, host: $('w-host').value.trim(), tofuDir: $('w-dir').value.trim(),
                        environment: $('w-env').value, confirm: name};
          busy = true;
          const res = await send('/api/stacks/new', body);
          busy = false;
          log(res.data.message || res.data.error, !res.ok);
          if (!res.ok) return;
          await refresh();
          newService(name);
        }

        async function newService(stack) {
          const ok = await step('New service in ' + stack, 'Step 2 of 2 — what runs',
              field('s-name', 'Name', '', 'also names its config file')
            + select('s-kind', 'Kind', meta.kinds)
            + field('s-image', 'Image', '', 'a tag already built on the host')
            + field('s-domains', 'Domains', '', 'comma separated')
            + field('s-network', 'Docker network', 'macworkstack-infra_default',
                    'how it reaches its database; blank for none')
            + field('s-port', 'Container port', '8080'),
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

        refresh();
        setInterval(() => { if (!busy) refresh(); }, 10000);
        </script>
        </body>
        </html>
        """
}
