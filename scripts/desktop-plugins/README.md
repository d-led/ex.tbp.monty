The two sample plugin nodes
===========================

These are the two example plugin hosts from the repository, built as releases:
**example_plugin** (one experiment, one learning module, one motor policy) and
**flyverse_plugin** (the same contract, different answers). They are not part of
Monty Studio — they are a second and a third _node_ that talk to it, which is
what a plugin is.

Start them from the window itself: **Settings → Cluster → Start them**. The window
spawns both releases as its own children, lends them the node name and cookie it
answers with, and stops them again when it closes — so the demo needs no
terminal, and nothing is left running behind a window that is gone.

On macOS the same two nodes also come as two apps beside the window — **Example
Plugin.app** and **Flyverse Plugin.app** — whenever the window came from the
`.pkg`, from the `.dmg`, or from `run-desktop.sh`, which all install the three
together. Double-clicking one starts that node and joins it to the window; it
finds the window by being next to it, so the two have to stay in one folder.

The two scripts are the by-hand route, for when the window is not in front of you
or was killed outright (a killed window never reaches its own graceful stop, so
the two VMs keep their ports and their database until they are told):

    ./start-plugins.sh          # macOS, Linux
    .\start-plugins.ps1         # Windows

The script asks the window for the name of the node it started (`/health`), and
hands that to both plugin nodes as the peer to dial. Within a few seconds
**Settings → Cluster** lists three nodes: this window and the two plugin nodes,
and the plugins chapter is where the example's modules appear.

`./start-plugins.sh --stop` (or `.\start-plugins.ps1 -Stop`) ends them.

Nothing here is installed and nothing is remembered between runs. The one thing
peers have to agree on is the **cookie**, and they do not get it from the same
place: `mix release` writes a `releases/COOKIE` per build, so each of these three
releases has one of its own, and a node answering with a different one is refused
— which arrives as "no answer" rather than as an error. Both routes therefore
lend the plugin nodes the window's cookie: `../rel/ex_tbp_monty/releases/COOKIE`,
or `MONTY_CLUSTER_SECRET` when the window was given one, because that replaces
the file at boot. The window can be started with clustering off
(`MONTY_STUDIO_CLUSTER=0`), and then these two have nothing to join — a node with
no name cannot be dialled, which is what the script and the window both say in
that case.
