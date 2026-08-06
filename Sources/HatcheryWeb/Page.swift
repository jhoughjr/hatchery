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
          .warn { color: var(--degraded); cursor: help; margin-left: 0.35rem; }
          .warn-line { color: var(--degraded); font-size: 0.8rem; }
          .l-error { color: var(--unreachable); }
          .l-warning { color: var(--degraded); }
          .l-info { color: var(--dim); }
          .d-add { color: var(--ready); }
          .d-remove { color: var(--unreachable); }
          .d-change { color: var(--degraded); }
          .d-header { color: var(--fg); font-weight: 600; }
          dialog.wide { max-width: 52rem; width: 90vw; }
          .tally { margin: 0.25rem 0 0.75rem; font-size: 0.8rem; }
          .backends { margin-bottom: 1.5rem; }
          .section > h2, .backends > h2 {
            font-size: 0.75rem; text-transform: uppercase; letter-spacing: 0.08em;
            color: var(--dim); margin: 0 0 0.5rem; font-weight: 600;
          }
          .bk {
            display: flex; align-items: center; gap: 0.75rem; padding: 0.6rem 1rem;
            background: var(--card); border: 1px solid var(--line);
            border-radius: 8px; margin-bottom: 0.5rem;
          }
          .bk .ico { width: 22px; height: 22px; flex: none; }
          .stack > header .ico { width: 18px; height: 18px; flex: none; }
          .group > h3 {
            display: flex; align-items: center; gap: 0.5rem;
            font-size: 0.8rem; color: var(--dim); font-weight: 600;
            margin: 1rem 0 0.5rem;
          }
          .group > h3 .ico { width: 16px; height: 16px; }
          .group:first-child > h3 { margin-top: 0; }
          .bk .nm { font-weight: 600; min-width: 11rem; }
          .ico.self { color: var(--ready); }
          .ico.ocean { color: #3a7ad9; }
          .ico.amzn { color: #d98f2a; }
          .ico.goog { color: #4a9a6a; }
          .bk .rd { font-size: 0.8rem; min-width: 10rem; }
          .bk .ct { color: var(--dim); font-size: 0.8rem; }
          .bk { flex-wrap: wrap; }
          .bk .btns { margin-left: auto; white-space: nowrap; }
          .bk-checks {
            flex-basis: 100%; margin-top: 0.6rem; padding-top: 0.6rem;
            border-top: 1px solid var(--line); font-size: 0.8rem;
          }
          .bk-checks .row2 { display: grid; grid-template-columns: 4rem 12rem 1fr; gap: 0.15rem 0.6rem; }
          .bk-checks .fix { grid-column: 2 / -1; color: var(--dim); margin-bottom: 0.3rem; }
          .st-ok { color: var(--ready); }
          .st-failed { color: var(--unreachable); }
          .st-skipped { color: var(--dim); }
          .state-card { padding: 0.7rem 1rem; }
          .state-line { display: flex; align-items: center; gap: 0.4rem; }
          .state-line button { margin-left: auto; }
          .state-card .checks { margin-top: 0.5rem; font-size: 0.75rem; }
          .state-card .why { color: var(--dim); }
          .cmd {
            margin: 0.4rem 0; padding: 0.45rem 0.6rem; background: var(--bg);
            border: 1px solid var(--line); border-radius: 4px; font-size: 0.72rem;
            overflow-x: auto; white-space: pre;
          }
          .dot { display: inline-block; width: 0.55rem; height: 0.55rem; border-radius: 50%;
                 margin-right: 0.4rem; vertical-align: baseline; }
          .dot.ok { background: var(--ready); }
          .dot.no { background: var(--unreachable); }
          .dot.pend { background: var(--line); }
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
          <div class="backends" id="backends"></div>
          <div id="state"></div>
          <div class="section"><h2 id="stacks-heading">Stacks</h2></div>
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
            loadBackends();
          }
        }

        let lastStacks = [];

        // Buttons carry their target in data attributes and are dispatched by one delegated
        // listener below. An inline onclick would mean a JS string inside an HTML attribute
        // inside a Swift string literal, and getting a quote wrong there is a *parse* error —
        // which kills the whole script, not just the button. That is exactly what happened.
        // What each button does, said in full. The labels are terse to keep a row readable;
        // the tooltip is where the consequence goes, especially for the ones that change things.
        const TIPS = {
          logs: 'Read the last 200 lines this service logged',
          config: 'Show what it is running with, secrets redacted, and the contract issues',
          'edit-config': 'Change config values. Secrets left blank keep their current value',
          restart: 'Restart this service. Asks you to type its name first',
          deploy: 'Plan a deploy and show the diff. Applies nothing on its own',
          apply: 'Apply the pending plan to this stack. Refused for production',
          'new-service': 'Add a service to this stack: writes its declaration and config',
          'new-stack': 'Create a stack on a provider, from nothing',
          'new-stack-on': 'Create a stack on this provider',
          setup: 'What this provider needs before hatchery can use it',
          checks: 'Show each prerequisite check and how to fix the ones failing',
          seal: 'Re-encrypt the backup so it matches the secrets on disk. Only ever adds a backup',
        };

        function button(action, label, stack, service, extraClass, backend) {
          return '<button data-action="' + action + '"'
            + (TIPS[action] ? ' title="' + escapeHTML(TIPS[action]) + '"' : '')
            + (stack ? ' data-stack="' + escapeHTML(stack) + '"' : '')
            + (service ? ' data-service="' + escapeHTML(service) + '"' : '')
            + (backend ? ' data-backend="' + escapeHTML(backend) + '"' : '')
            + (extraClass ? ' class="' + extraClass + '"' : '')
            + (busy ? ' disabled' : '') + '>' + escapeHTML(label) + '</button>';
        }

        // ---- providers, as the top level ------------------------------------
        // Which backends exist and whether this machine can use them is the first question, and
        // it is asked before anything defaults to one. Readiness is fetched per provider after
        // the rows are drawn, because each check shells out and one slow box should not hold up
        // the rest of the page.
        let backends = [];

        async function loadBackends() {
          const res = await get('/api/backends');
          if (!res.ok) { $('backends').innerHTML = ''; return; }
          backends = res.data;
          renderBackends();
          backends.forEach(b => checkBackend(b.name));
        }

        // hatchery's own glyphs, not vendor logos: a box for a machine you own, a droplet, a
        // cube, a cloud. Drawn in the same flat geometry as the hatchery mark so the row reads
        // as one design rather than four pasted brands.
        const ICONS = {
          dokku: ['self',
            '<rect x="10" y="14" width="44" height="12" rx="2"/>'
            + '<rect x="10" y="30" width="44" height="12" rx="2"/>'
            + '<circle cx="17" cy="20" r="2.4" fill="var(--bg)"/>'
            + '<circle cx="17" cy="36" r="2.4" fill="var(--bg)"/>'
            + '<rect x="16" y="48" width="32" height="3" rx="1.5"/>'],
          appPlatform: ['ocean',
            '<path d="M32 6 C44 22 50 30 50 38 A18 18 0 0 1 14 38 C14 30 20 22 32 6 Z"/>'],
          aws: ['amzn',
            '<path d="M32 6 L54 18 L54 44 L32 56 L10 44 L10 18 Z" '
            + 'fill="none" stroke="currentColor" stroke-width="5"/>'
            + '<path d="M32 24 L42 30 L42 40 L32 46 L22 40 L22 30 Z"/>'],
          cloudRun: ['goog',
            '<path d="M20 44 A12 12 0 0 1 21 21 A15 15 0 0 1 48 26 A10 10 0 0 1 46 44 Z"/>'
            + '<path d="M28 28 L40 34.5 L28 41 Z" fill="var(--bg)"/>'],
        };

        function icon(name) {
          const spec = ICONS[name];
          if (!spec) return '<span class="ico"></span>';
          return '<svg class="ico ' + spec[0] + '" viewBox="0 0 64 64" fill="currentColor"'
            + ' aria-hidden="true">' + spec[1] + '</svg>';
        }

        // The encrypted backup of the state directory. Shown whether or not it is healthy: a
        // backup nobody looks at is how a minted key spent a day existing on one disk.
        function renderState(s) {
          const box = $('state');
          if (!s || s.configured === false) {
            box.innerHTML = '<div class="section"><h2>State backup</h2></div>'
              + '<div class="card state-card">'
              + '<div class="state-line"><span class="dot pend"></span>'
              + '<span>not set up — secrets here are stored in plaintext only</span></div>'
              + '<div class="hint">Set one up, then this panel tracks it:</div>'
              + '<pre class="cmd">hatchery state init --directory &lt;dir&gt; --remote &lt;owner/name&gt;</pre>'
              + '<div class="hint">Generating the key stays on the command line on purpose. '
              + 'It is the one step where clicking past a warning loses everything the archive '
              + 'holds, and it must be copied to a password manager before anything depends on it.'
              + '</div></div>';
            return;
          }
          const ok = s.sealed === true;
          const when = s.sealedAt ? escapeHTML(s.sealedAt) : 'never';
          let detail = '';
          if (!ok) {
            const rows = (s.unsealed || []).map(p =>
              '<div class="st-failed"><code>' + escapeHTML(p) + '</code>'
              + ' <span class="why">only on this machine</span></div>').join('')
              + (s.stale || []).map(p =>
                '<div class="st-skipped"><code>' + escapeHTML(p) + '</code>'
                + ' <span class="why">in the backup, gone from disk</span></div>').join('');
            detail = '<div class="checks">' + rows + '</div>';
          }
          box.innerHTML = '<div class="section"><h2>State backup</h2></div>'
            + '<div class="card state-card">'
            + '<div class="state-line"><span class="dot ' + (ok ? 'ok' : 'no') + '"></span>'
            + '<span>' + (ok ? 'every secret is in the encrypted backup'
                             : escapeHTML(s.summary || 'not fully backed up')) + '</span>'
            + button('seal', 'seal now') + '</div>'
            + '<div class="hint"><code>' + escapeHTML(s.root || '') + '</code> · last sealed '
            + when + '</div>'
            + detail
            + '<div class="hint">Committing and pushing the archive is still a git operation on '
            + 'your own repository.</div></div>';
        }

        // Not confirmed, unlike the other mutations. Sealing only ever writes a backup of what
        // is already on disk — there is no state it can destroy, so a dialog would be friction
        // in front of the one action that is always safe to take.
        function sealState() {
          log('sealing…');
          fetch('/api/state/seal', {method: 'POST', headers, body: '{}'})
            .then(r => r.json())
            .then(r => { log(r.message || 'sealed', !r.ok); loadState(); })
            .catch(e => log(String(e), true));
        }

        function loadState() {
          fetch('/api/state').then(r => r.json()).then(renderState)
            .catch(() => renderState(null));
        }

        function renderBackends() {
          $('backends').innerHTML = '<h2>Providers</h2>' + backends.map(b => {
            const r = b.readiness;
            const dot = r === undefined ? 'pend' : (r.ok ? 'ok' : 'no');
            // Name the first thing that failed. "2 of 4 failing" is a number; "aws cli" is a
            // thing to go and fix.
            const text = r === undefined ? 'checking…'
              : (r.ok ? 'configured here'
                      : r.first + (r.failing > 1 ? ' +' + (r.failing - 1) + ' more' : ''));
            const stacks = b.stackCount === 1 ? '1 stack' : b.stackCount + ' stacks';
            return '<div class="bk">'
              + icon(b.name)
              + '<span class="nm">' + escapeHTML(b.label) + '</span>'
              + '<span class="rd"><span class="dot ' + dot + '"></span>' + escapeHTML(text) + '</span>'
              + '<span class="ct">' + stacks + '</span>'
              + '<span class="btns">'
              +   button('checks', b.open ? 'hide checks' : 'checks', null, null, 'add', b.name)
              +   ' '
              +   button('setup', 'set up', null, null, 'add', b.name)
              +   ' '
              +   (b.authorable
                    ? button('new-stack-on', '+ stack', null, null, 'add', b.name)
                    : '<span class="ct">' + escapeHTML(b.note || '') + '</span>')
              + '</span>'
              + (b.open ? checksPanel(b) : '')
              + '</div>';
          }).join('');
        }

        function checksPanel(b) {
          if (!b.checks) return '<div class="bk-checks">checking…</div>';
          return '<div class="bk-checks"><div class="row2">'
            + b.checks.map(c =>
                '<span class="st-' + c.status + '">'
                + (c.status === 'ok' ? 'ok' : (c.status === 'failed' ? 'FAIL' : '--')) + '</span>'
                + '<span>' + escapeHTML(c.name) + '</span>'
                + '<span>' + escapeHTML(c.detail) + '</span>'
                + (c.remedy ? '<span class="fix">&rarr; ' + escapeHTML(c.remedy) + '</span>' : '')
              ).join('')
            + '</div></div>';
        }

        async function checkBackend(name) {
          const b = backends.find(x => x.name === name);
          if (!b) return;
          const res = await get('/api/preflight?backend=' + encodeURIComponent(name)
            + (b.knownHost ? '&host=' + encodeURIComponent(b.knownHost) : ''));
          const checks = res.ok ? res.data : [];
          // Skipped is not failure: it means something it depends on was not asked.
          const failed = checks.filter(c => c.status === 'failed');
          // The whole list is kept, not just a count — "2 of 3 failing" says there is a problem
          // and not which, and the remedy is the useful half of a failed check.
          b.checks = checks;
          b.readiness = {
            ok: failed.length === 0 && checks.length > 0,
            failing: failed.length, total: checks.length,
            first: failed.length ? failed[0].name : null,
          };
          renderBackends();
        }

        // A select only re-rendered when the dialog was confirmed, so changing it looked like
        // it did nothing until you pressed done — which reads as closing, not switching.
        document.addEventListener('change', event => {
          if (event.target && event.target.id === 'setup-backend') {
            $('wizard').returnValue = 'switch';
            $('wizard').close();
          }
        });

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
            case 'setup': showSetup(target.dataset.backend || null); break;
            case 'new-stack-on': newStack(target.dataset.backend); break;
            case 'seal': sealState(); break;
            case 'checks': {
              const b = backends.find(x => x.name === target.dataset.backend);
              if (b) { b.open = !b.open; renderBackends(); if (!b.checks) checkBackend(b.name); }
              break;
            }
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
          const heading = $('stacks-heading');
          if (heading) heading.style.display = stacks.length ? '' : 'none';
          if (!stacks.length) {
            $('stacks').innerHTML = '<div class="empty">' + MARK
              + '<h2>Nothing declared yet</h2>'
              + '<p>Pick a provider above to create a stack on it. hatchery will write the'
              + ' tofu, mint what it can, and tell you what it cannot.</p></div>';
            return;
          }

          // Grouped by provider only when more than one is in use. With a single provider a
          // heading over every stack is a level of nesting that says nothing, and the icon on
          // each header already carries it.
          const used = [...new Set(stacks.map(s => s.backend))];
          const label = (b) => {
            const found = (meta && meta.backends || []).find(x => x.name === b);
            return found ? found.label : b;
          };
          const drawStack = (stack) => {
            const rows = stack.services.map(svc => {
              const state = svc.state || 'unknown';
              const reasons = (svc.reasons || []).map(r =>
                '<div class="reason">' + escapeHTML(r) + '</div>').join('');
              const latency = svc.latencyMs == null ? '' : svc.latencyMs + 'ms';
              // A triangle, not a state: an incomplete config is a fact about the declaration
              // rather than about what the service is currently doing. A service can be running
              // happily on values that its declared config no longer contains.
              const cfg = svc.config;
              const warn = (cfg && !cfg.complete)
                ? '<span class="warn" title="' + escapeHTML(cfg.summary || 'config incomplete')
                  + '">&#9650;</span>' : '';
              const warnLine = (cfg && !cfg.complete)
                ? '<div class="warn-line">&#9650; ' + escapeHTML(cfg.summary || '') + '</div>' : '';
              return '<tr>'
                + '<td><div class="name">' + escapeHTML(svc.name) + warn + '</div>'
                +   '<div class="kind">' + escapeHTML(svc.kind) + '</div></td>'
                + '<td><span class="state ' + escapeHTML(state) + '">' + escapeHTML(state)
                +   '</span>' + reasons + warnLine + '</td>'
                + '<td class="num">' + latency + '</td>'
                + '<td class="actions">'
                +   button('logs', 'logs', stack.name, svc.name)
                +   ' '
                +   button('config', 'config', stack.name, svc.name)
                +   ' '
                // Beside `config` rather than only at the foot of the panel it opens. A service
                // flagged for missing keys needs the editor, and burying it under twenty rows
                // of values makes the fix harder to find than the problem.
                +   button('edit-config', 'edit', stack.name, svc.name,
                           cfg && !cfg.complete ? 'primary' : '')
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
            const incomplete = stack.services.filter(s => s.config && !s.config.complete).length;
            const stackWarn = incomplete
              ? '<span class="warn" title="' + incomplete + ' service(s) cannot boot as declared">'
                + '&#9650;</span>' : '';
            return '<section class="stack"><header>'
              + icon(stack.backend)
              + '<h2>' + escapeHTML(stack.name) + stackWarn + '</h2>'
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
          };

          $('stacks').innerHTML = used.length > 1
            ? used.map(b =>
                '<section class="group"><h3>' + icon(b) + escapeHTML(label(b))
                + ' <span class="ct">' + stacks.filter(s => s.backend === b).length
                + '</span></h3>'
                + stacks.filter(s => s.backend === b).map(drawStack).join('')
                + '</section>').join('')
            : stacks.map(drawStack).join('');
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

        async function newStack(chosenBackend) {
          if (!(await ensureMeta())) return;
          // Only backends hatchery can actually author are offered. Listing one it would refuse
          // turns a menu into a dead end you discover after filling the form in.
          const authorable = meta.backends.filter(b => b.authorable).map(b => b.name);
          // Settings are whatever the backend declares, so a new provider needs no change here.
          const settingsFor = {};
          meta.backends.forEach(b => { settingsFor[b.name] = b.settings || []; });
          const blocked = meta.backends.filter(b => !b.authorable);
          if (!authorable.length) { log('no backend can be created by this build', true); return; }

          // When a provider was chosen from the list above, it is shown rather than re-asked.
          // Nothing defaults to one backend: without a choice, every option is offered.
          const backendField = chosenBackend
            ? '<div class="field"><label>Backend</label><div>'
              + escapeHTML((meta.backends.find(b => b.name === chosenBackend) || {}).label
                           || chosenBackend)
              + '</div><input type="hidden" id="w-backend" value="'
              + escapeHTML(chosenBackend) + '"></div>'
            : select('w-backend', 'Backend', authorable,
                     'What runs the services. '
                     + (blocked.length
                        ? blocked.map(b => b.note).join('; ') + '.'
                        : 'Every backend this build supports is listed.'));

          const ok = await step('New stack', 'Step 1 of 3 — where it lives',
              field('w-name', 'Name', '',
                    'Identifies the stack in hatchery. Lowercase, dashes allowed.')
            + backendField
            + field('w-dir', 'Tofu directory', '~/infra-state/',
                    'Where the generated tofu configuration and the config file for each service are '
                    + 'written. Must be empty or not exist. Keep it somewhere durable and backed '
                    + 'up: it holds the state that maps tofu to the running apps.')
            + select('w-env', 'Environment', meta.environments,
                     'Labels the stack. A prod stack refuses to apply from the browser.'));
          if (!ok) { log('cancelled'); return; }

          const name = $('w-name').value.trim();
          const dir = $('w-dir').value.trim();
          const env = $('w-env').value;
          const backend = $('w-backend').value;

          // A second step, because which fields exist depends on the backend just chosen.
          const declared = (settingsFor[backend] || []).filter(s => s.source === 'declared');
          const fromEnv = (settingsFor[backend] || []).filter(s => s.source === 'environment');
          let values = {};
          if (declared.length || fromEnv.length) {
            const body = declared.map(s => field('set-' + s.key, s.label,
                s.defaultValue || '', s.help + (s.required ? '' : ' (optional)'))).join('')
              + fromEnv.map(s => '<div class="field"><label>' + escapeHTML(s.label) + '</label>'
                + '<div class="hint">Read from $' + escapeHTML(s.environmentKey || '')
                + ' at apply time. hatchery never stores it.</div></div>').join('');
            if (!(await step('Settings for ' + backend, 'what this backend needs to know', body))) {
              log('cancelled'); return;
            }
            declared.forEach(s => {
              const v = $('set-' + s.key).value.trim();
              if (v) values[s.key] = v;
            });
          }
          const host = values.host || '';

          // Check before creating rather than after. These failures otherwise surface halfway
          // through `tofu init`, as a provider error that never mentions the real cause.
          if (!(await preflight(backend, host || null))) return;

          busy = true;
          const res = await send('/api/stacks/new',
            {name, host, tofuDir: dir, environment: env, backend, settings: values, confirm: name});
          busy = false;
          log(res.data.message || res.data.error, !res.ok);
          if (!res.ok) return;
          await refresh();
          newService(name);
        }

        async function preflight(backend, host) {
          $('wiz-title').textContent = 'Checking prerequisites';
          $('wiz-body').innerHTML = '<div class="steps">Step 2 of 3 — is ' + escapeHTML(backend)
            + ' configured here?</div>'
            + '<div id="pf">checking ' + escapeHTML(host || backend) + '…</div>';
          $('wiz-ok').textContent = 'continue';
          const dialog = $('wizard');
          const done = new Promise(resolve => { dialog.onclose = () => resolve(dialog.returnValue === 'ok'); });
          dialog.showModal();

          const res = await get('/api/preflight?backend=' + encodeURIComponent(backend)
            + (host ? '&host=' + encodeURIComponent(host) : ''));
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
              + 'If it is not set up yet, close this and use "Set up a backend".</div>';
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
        async function showSetup(backend) {
          const chosen = backend || (meta && meta.backends.length ? meta.backends[0].name : 'dokku');
          const res = await get('/api/setup?backend=' + encodeURIComponent(chosen));
          if (!res.ok) { log('could not load the setup guide', true); return; }
          const body = res.data.map((step, i) =>
            '<div class="field"><label>' + (i + 1) + '. ' + escapeHTML(step.title)
            + '  · on the ' + escapeHTML(step.on) + '</label>'
            + '<div class="hint">' + escapeHTML(step.why) + '</div>'
            + '<pre class="out">' + step.commands.map(escapeHTML).join('\\n') + '</pre>'
            + (step.verify ? '<div class="hint">check: ' + escapeHTML(step.verify) + '</div>' : '')
            + '</div>').join('');
          // A picker inside the dialog, so you can read any backend's guide without restarting.
          const picker = meta ? '<div class="field"><label>Backend</label><select id="setup-backend">'
            + meta.backends.map(b => '<option value="' + escapeHTML(b.name) + '"'
                + (b.name === chosen ? ' selected' : '') + '>' + escapeHTML(b.label) + '</option>').join('')
            + '</select><div class="hint">Pick another to read its guide.</div></div>' : '';
          const dialog = $('wizard');
          const outcome = await step('Setting up ' + chosen,
                     'what this backend needs before hatchery can use it', picker + body, 'done');
          // `switch` is the change listener above closing the dialog to redraw it.
          if (dialog.returnValue === 'switch') {
            const next = $('setup-backend') && $('setup-backend').value;
            dialog.returnValue = '';
            if (next && next !== chosen) { return showSetup(next); }
            return showSetup(chosen);
          }
          void outcome;
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

          const missing = (c.issues || []).filter(i => i.severity === 'error');
          const missingList = missing.length
            ? '<div class="warn-line">&#9650; ' + missing.length
              + ' required key(s) missing: ' + escapeHTML(missing.map(i => i.key).join(', '))
              + '</div>' : '';
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
            + missingList + '<div class="kv">' + rows + '</div>' + issues
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
          const declared = Object.keys(c.declared || {}).sort();
          // A required key with no value has nothing in `declared` to build a field from, so it
          // is listed separately and rendered first — those are the ones stopping it booting.
          const missing = (c.missingKeys || []).filter(k => declared.indexOf(k) < 0);
          const keys = missing.concat(declared);

          const body = (missing.length
              ? '<div class="warn-line">&#9650; ' + missing.length
                + ' required key(s) missing — fill these in to let it boot</div>' : '')
            + missing.map(k => field('c-' + k, k, '',
                secret.has(k) ? 'required, secret — no value set' : 'required — no value set')).join('')
            + (missing.length && declared.length ? '<div class="steps">already set</div>' : '')
            + declared.map(k => field('c-' + k, k,
                secret.has(k) ? '' : c.declared[k],
                secret.has(k) ? 'secret — leave blank to keep it unchanged' : null)).join('')
            + '<div class="field"><label>Add a key</label>'
            + '<input id="c-new-key" placeholder="KEY" autocomplete="off">'
            + '<input id="c-new-val" placeholder="value" autocomplete="off"></div>';

          const ok = await step('Config for ' + service,
            missing.length ? missing.length + ' missing of ' + keys.length + ' key(s)'
                           : keys.length + ' key(s)', body, 'save');
          if (!ok) { log('cancelled'); return; }

          const values = {};
          const wasMissing = new Set(missing);
          keys.forEach(k => {
            const v = $('c-' + k).value;
            // A missing key left blank is still missing. Posting '' would write an empty value,
            // which dokku rejects outright and which reads as "set" everywhere else.
            if (wasMissing.has(k)) { if (v) values[k] = v; }
            else if (secret.has(k)) { if (v) values[k] = v; }
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

        loadBackends();
        loadState();
        refresh();
        setInterval(() => { if (!busy && !anyDialogOpen()) refresh(); }, 10000);
        </script>
        </body>
        </html>
        """
}
