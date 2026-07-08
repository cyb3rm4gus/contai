// Wiki REH Resolver — a minimal VSCodium remote authority resolver.
//
// Its ONLY job: when the editor opens `vscode-remote://wiki-reh+<name>/...`,
// tell it which host:port the container's REH server is listening on, plus the
// connection token. No SSH, no key handling, no process spawning, no downloads.
// That is why this file has ZERO dependencies (only the ambient `vscode` API,
// which is part of the editor). Nothing here to audit but the code you see.

const vscode = require('vscode');

function activate(context) {
  const log = vscode.window.createOutputChannel('Wiki REH');

  const getHosts = () =>
    vscode.workspace.getConfiguration().get('wikiReh.hosts') || [];
  const findHost = (name) => getHosts().find((h) => h && h.name === name);

  // --- the resolver: authority -> host:port(+token) ---
  context.subscriptions.push(
    vscode.workspace.registerRemoteAuthorityResolver('wiki-reh', {
      resolve(authority) {
        // authority looks like "wiki-reh+wiki-agent"
        const name = authority.split('+')[1];
        const h = findHost(name);
        if (!h) {
          throw vscode.RemoteAuthorityResolverError.NotAvailable(
            `No wikiReh.hosts entry named "${name}". Add one in settings.`,
            true
          );
        }
        const host = h.host || 'localhost';
        const port = Number(h.port) || 8000;
        log.appendLine(`resolve ${authority} -> ${host}:${port}`);
        return new vscode.ResolvedAuthority(
          host,
          port,
          h.connectionToken || undefined
        );
      },
    })
  );

  // --- convenience command: pick a target and open its folder ---
  context.subscriptions.push(
    vscode.commands.registerCommand('wikiReh.connect', async () => {
      const hosts = getHosts();
      if (!hosts.length) {
        vscode.window.showErrorMessage(
          'Wiki REH: no hosts configured. Set "wikiReh.hosts" in settings.'
        );
        return;
      }
      let target = hosts[0];
      if (hosts.length > 1) {
        const pick = await vscode.window.showQuickPick(
          hosts.map((h) => ({ label: h.name, description: `${h.host || 'localhost'}:${h.port || 8000}`, h })),
          { placeHolder: 'Connect to which container?' }
        );
        if (!pick) return;
        target = pick.h;
      }
      const folder =
        (target.folders && target.folders[0] && target.folders[0].path) ||
        '/home/agent';
      const uri = vscode.Uri.parse(
        `vscode-remote://wiki-reh+${target.name}${folder}`
      );
      await vscode.commands.executeCommand('vscode.openFolder', uri, {
        forceNewWindow: false,
      });
    })
  );

  log.appendLine('Wiki REH resolver activated.');
}

function deactivate() {}

module.exports = { activate, deactivate };
