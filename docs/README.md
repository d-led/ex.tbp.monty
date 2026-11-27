# Documentation

Every page here is one of four kinds: a lesson, a task, a fact, or an
explanation. Pick by the question you have, not by the file name.

The pages stay in one folder so existing links keep working, with the
walk-throughs that carry screenshots in a folder of their own. The four
headings below are the grouping.

## Learn it

| Page                                                   | Walks through                                        |
| ------------------------------------------------------ | ---------------------------------------------------- |
| [../README.md](../README.md)                           | the studio in Docker, then the first experiment      |
| [cad.md](cad.md)                                       | a STEP part becoming a memory, then being recognised |
| [experiments/cad/README.md](experiments/cad/README.md) | the same part, click by click, in screenshots        |

## Do a task

| Page                                         | Task                                                         |
| -------------------------------------------- | ------------------------------------------------------------ |
| [container.md](container.md)                 | run the image, with every variable and the one writable path |
| [desktop.md](desktop.md)                     | open the studio as an app, and find what it wrote            |
| [cluster.md](cluster.md)                     | run several nodes and know what they share                   |
| [mcp.md](mcp.md)                             | point an assistant at `/mcp` and call its tools              |
| [plugins.md](plugins.md)                     | call a plugin across a node                                  |
| [parallel-and-live.md](parallel-and-live.md) | run episodes in parallel, or an experiment that never stops  |

## Look up a fact

| Page                                               | Answers                                                         |
| -------------------------------------------------- | --------------------------------------------------------------- |
| [features.md](features.md)                         | what works, and what proves it                                  |
| [module-map.md](module-map.md)                     | where would Monty's `a/b.py::C` live here?                      |
| [from-monty.md](from-monty.md)                     | what is copied from Monty, where it lands, which task writes it |
| [config-compatibility.md](config-compatibility.md) | how far Hydra parity goes                                       |
| [readiness.md](readiness.md)                       | which experiments run here, and what the rest need              |
| [partial-classes.md](partial-classes.md)           | what a partly ported class is                                   |
| [planned-classes.md](planned-classes.md)           | which classes are still unwritten                               |
| [monty-differences.md](monty-differences.md)       | every deliberate difference, and what looks wrong upstream      |

## Understand why

| Page                                   | Explains                                               |
| -------------------------------------- | ------------------------------------------------------ |
| [architecture.md](architecture.md)     | what happens in one timestep, and where Python sits    |
| [simulator-port.md](simulator-port.md) | why the world is on the other side of a port           |
| [theories.md](theories.md)             | independent processes on theories, the plan            |
| [validation.md](validation.md)         | what has been compared with Monty, and how closely     |
| [speed.md](speed.md)                   | where a step's time goes                               |
| [training.md](training.md)             | what training exists, what is missing, and the order   |
| [cad-results.md](cad-results.md)       | one CAD run's numbers, with the command that made them |
| [open-ends.md](open-ends.md)           | what upstream itself says is not done                  |
| [roadmap.md](roadmap.md)               | the order the rest of Monty arrives in                 |

## Work on the code

| Page                           | Covers                                                  |
| ------------------------------ | ------------------------------------------------------- |
| [developers.md](developers.md) | invariants, tests, gates, and the loop for every change |
| [../AGENTS.md](../AGENTS.md)   | the rules an agent follows in this tree                 |
