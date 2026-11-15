The two sample plugin nodes
===========================

These are the two example plugin hosts from the repository, built as releases:
**example_plugin** (one experiment, one learning module, one motor policy) and
**flyverse_plugin** (the same contract, different answers). They are not part of
Monty Studio — they are a second and a third *node* that talk to it, which is
what a plugin is.

Start them while Monty Studio Desktop is running:

    ./start-plugins.sh          # macOS, Linux
    .\start-plugins.ps1         # Windows

The script asks the window for the name of the node it started (`/health`), and
hands that to both plugin nodes as the peer to dial. Within a few seconds
**Settings → Cluster** lists three nodes: this window and the two plugin nodes,
and the plugins chapter is where the example's modules appear.

`./start-plugins.sh --stop` (or `.\start-plugins.ps1 -Stop`) ends them.

Nothing here is installed, and nothing is remembered between runs: two nodes on
one machine share the user's `~/.erlang.cookie`, which is the only thing peers
have to agree on. The window can be started with clustering off
(`MONTY_STUDIO_CLUSTER=0`), and then these two have nothing to join — a node with
no name cannot be dialled, which is what the script says in that case.
