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
        </style>
        </head>
        <body>
        <main>
          <h1>hatchery</h1>
          <div class="sub" id="sub">loading…</div>
          <div id="stacks"></div>
          <div id="log"></div>
        </main>

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

        function render(stacks) {
          lastStacks = stacks;
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
                +   '<button ' + (busy ? 'disabled' : '') + ' onclick="restart(\\''
                +     escapeHTML(stack.name) + '\\',\\'' + escapeHTML(svc.name)
                +     '\\')">restart</button> '
                +   '<button ' + (busy ? 'disabled' : '') + ' onclick="deploy(\\''
                +     escapeHTML(stack.name) + '\\',\\'' + escapeHTML(svc.name)
                +     '\\')">deploy</button>'
                + '</td></tr>';
            }).join('');
            const badge = stack.isProduction ? '<span class="prod">prod</span>' : '';
            return '<section class="stack"><header>'
              + '<h2>' + escapeHTML(stack.name) + '</h2>'
              + '<span class="meta">' + escapeHTML(stack.backend) + ' · '
              + escapeHTML(stack.environment) + '</span>' + badge
              + '<span class="meta state ' + escapeHTML(stack.state || '')
              + '" style="margin-left:auto">' + escapeHTML(stack.state || '') + '</span>'
              + '</header><table>' + rows + '</table></section>';
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

        refresh();
        setInterval(() => { if (!busy) refresh(); }, 10000);
        </script>
        </body>
        </html>
        """
}
