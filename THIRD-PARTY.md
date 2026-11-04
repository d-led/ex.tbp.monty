# Third-party components

This project's own source is under the Mozilla Public License 2.0 — see
[`LICENSE`](LICENSE). This file records what the repository and the image carry
that was written by somebody else, under which terms, and where that text can be
read.

## Thousand Brains Project — Monty (MIT)

This is a module-for-module rewrite of Monty, so it carries a great deal of
Monty: the config tree it composes, the snapshots it is checked against, the
pretrained memories a run recognises with, and the design of every module it
ports.

    Copyright 2025 Thousand Brains Project
    Copyright 2021-2024 Numenta Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

Source: <https://github.com/thousandbrainsproject/tbp.monty>. The full text is
kept beside the copy it applies to, as
[`priv/monty/LICENSE`](priv/monty/LICENSE).

What is shipped under it is Monty's Hydra config tree, the snapshots it was
composed into, and the pretrained learning-module memories exported for this
port — copied, verbatim where the format allows. Every path, the task that
writes it and the command that checks it are in
[`docs/from-monty.md`](docs/from-monty.md); the commit the copy was taken from
is `priv/monty/inputs.json`.

## Browser packages

| Component                                                                          | Licence | Where                                                            |
| ---------------------------------------------------------------------------------- | ------- | ---------------------------------------------------------------- |
| [driver.js](https://driverjs.com) 1.10 — the first-visit tour                      | MIT     | `assets/package.json` (installed by `npm ci`, not vendored)      |
| [topbar](http://buunguyen.github.io/topbar) 3.0 — the navigation progress bar      | MIT     | `assets/vendor/topbar.js`, notice in its header                  |
| [daisyUI](https://daisyui.com) 5.7.9 — the component classes used by the templates | MIT     | `mix.exs` (`{:daisyui, github: "saadeghi/daisyui"}`)             |
| [Heroicons](https://heroicons.com) — the icon set behind `<.icon name="hero-…">`   | MIT     | `assets/vendor/heroicons.js`, icons drawn from the Heroicons set |
| [Tailwind CSS](https://tailwindcss.com)                                            | MIT     | `mix.exs` (`{:tailwind, ...}`)                                   |

## Erlang and Elixir libraries

The dependency tree is pinned in `mix.lock`; each library keeps its own licence
in `deps/<name>/LICENSE*` once fetched. The ones that shape what ships:

| Library                         | Licence    | Role                                       |
| ------------------------------- | ---------- | ------------------------------------------ |
| Phoenix, Phoenix LiveView, Ecto | MIT        | the web application and its database layer |
| Bandit                          | ISC        | the HTTP server                            |
| Oban                            | Apache-2.0 | the job queue a run's steps go through     |
| Req                             | Apache-2.0 | HTTP client                                |
| YamlElixir                      | MIT        | reads Monty's YAML unchanged               |
| pythonx                         | Apache-2.0 | the embedded CPython (see below)           |
| Jason                           | Apache-2.0 | JSON                                       |

## Embedded runtime and its packages

The image carries one CPython, downloaded and assembled by `uv` at build time
(see `config/pythonx.exs`). That interpreter is Python Software Foundation
licensed; the one package installed into it is

| Package                                        | Licence    |
| ---------------------------------------------- | ---------- |
| [wandb](https://github.com/wandb/wandb) 0.19.1 | Apache-2.0 |

The base images of the container build are Debian (`docker.io/debian`,
`docker.io/hexpm/elixir`, `docker.io/node`) — each with its own licences and
notices, unchanged by this project.

## YCB object models

Runs use object models from the
[YCB benchmark](https://www.ycbbenchmark.org) suite, distributed with Monty's
data rather than with this project: they are a prerequisite a deployment
supplies (see `docs/container.md`), not something the image ships.
