defmodule ExTbpMonty.Mcp.Tools do
  @moduledoc """
  The tools the MCP server offers, and the one place a name becomes a function.

  Four groups, one per question a caller actually has:

    * the documentation — what the project says (`Tools.Docs`);
    * the roadmap — what the project intends (`Tools.Roadmap`);
    * the port — where that lives here (`Tools.Port`);
    * experiments — what is configured, what could be, and starting one
      (`Tools.Experiments`).

  A tool answers `{:ok, %{text: text, structured: map}}` or `{:error, message}`.
  The text is what a model reads; the structured part is the same answer for a
  program that would rather not parse prose. The protocol layer turns the second
  form into a tool execution error, which is the specification's way of saying
  "this call failed, the message says how" rather than "the server is broken".

  Every tool's annotations are honest about what it does: the ten that only read
  say so, and the two that write — a draft, a queued run — say that too.
  """

  alias ExTbpMonty.Mcp.Tools.{Docs, Experiments, Port, Roadmap, Studio}

  @type ctx :: %{base_url: String.t()}
  @type result :: {:ok, %{text: String.t(), structured: map()}} | {:error, String.t()}

  @read_only %{
    "readOnlyHint" => true,
    "destructiveHint" => false,
    "idempotentHint" => true,
    "openWorldHint" => false
  }

  @writes %{
    "readOnlyHint" => false,
    "destructiveHint" => false,
    "idempotentHint" => false,
    "openWorldHint" => false
  }

  @destructive %{
    "readOnlyHint" => false,
    "destructiveHint" => true,
    "idempotentHint" => true,
    "openWorldHint" => false
  }

  @attributes %{
    "type" => "object",
    "description" =>
      "What the experiment should be: `name`, `base` (an experiment to start from, " <>
        "`tutorial/first_experiment` by default), any group of " <>
        "`monty_experiment_options` as a key (`monty/learning_module`, `monty/sensor_module`, " <>
        "`environment`, `monty/connectivity`, `termination`, `telemetry`, " <>
        "`monty/motor_system_config`), and the config values `seed`, `n_train_epochs`, " <>
        "`n_eval_epochs`, `supervised_lm_ids`, `model_name_or_path`.",
    "additionalProperties" => true
  }

  @tools [
    %{
      "name" => "monty_studio",
      "title" => "About this studio",
      "description" =>
        "What this deployment is, as numbers: how many experiments are preconfigured, how " <>
          "many runs there are of each kind, how many episodes run at once (the queue's " <>
          "limit — the answer to \"can we run experiments in parallel here?\"), whether the " <>
          "world is Monty's or this port's stand-in, which data and model bundles are " <>
          "present, and how much room is left on the volumes runs and downloads write to. " <>
          "Ask this instead of reading a filesystem: the files an assistant would " <>
          "look for are not on its side of the connection.",
      "inputSchema" => %{"type" => "object", "properties" => %{}},
      "annotations" => @read_only
    },
    %{
      "name" => "monty_search_docs",
      "title" => "Search Monty's documentation",
      "description" =>
        "Searches Monty's published documentation at docs.thousandbrains.org — the theory, " <>
          "how Monty works, how to use it, the roadmap — and returns the pages it finds with " <>
          "the matched passage, the address the page is published at, and a `slug` for " <>
          "`monty_read_doc`. Search on the words the project uses (`learning module`, " <>
          "`evidence`, `voting`, `heterarchy`, `CMP`), not on a whole sentence.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "query" => %{"type" => "string", "description" => "Words to look for."},
          "area" => %{
            "type" => "string",
            "description" =>
              "Limit to one area of the site: overview, how-to-use-monty, how-monty-works, " <>
                "neuroscience-theory, contributing, community, future-work."
          },
          "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 20, "default" => 6}
        },
        "required" => ["query"]
      },
      "annotations" => @read_only
    },
    %{
      "name" => "monty_read_doc",
      "title" => "Read a documentation page",
      "description" =>
        "One page of Monty's documentation, whole, with its headings so a long page can be " <>
          "skimmed and its published address so a claim can be cited.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "slug" => %{
            "type" => "string",
            "description" =>
              "A page slug from `monty_docs_index`, e.g. `learning-modules` — the last " <>
                "part of the published address."
          }
        },
        "required" => ["slug"]
      },
      "annotations" => @read_only
    },
    %{
      "name" => "monty_docs_index",
      "title" => "List the documentation",
      "description" =>
        "What documentation there is: the areas, how many pages each holds, and the pages " <>
          "with their titles. Use it when you do not know what to search for yet.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "area" => %{"type" => "string", "description" => "Only this area."}
        }
      },
      "annotations" => @read_only
    },
    %{
      "name" => "monty_docs_map",
      "title" => "The documentation as the project indexes it",
      "description" =>
        "The documentation site's own machine index (`llms.txt`), verbatim: every page, " <>
          "under the area it belongs to, in the order the project lists them, with the " <>
          "one-line description it gives. Use it to see the whole map at once; " <>
          "monty_docs_index gives the same pages as a list of slugs to choose from.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "area" => %{
            "type" => "string",
            "description" =>
              "Only this area's block of the index: overview, how-to-use-monty, " <>
                "how-monty-works, neuroscience-theory, contributing, community, future-work."
          }
        }
      },
      "annotations" => @read_only
    },
    %{
      "name" => "monty_roadmap",
      "title" => "Monty's roadmap",
      "description" =>
        ~s(The project's future-work tasks, one per page, with the status, scope, output type ) <>
          ~s(and skills the project itself records — the same data the project's own roadmap ) <>
          ~s(page renders. Filter by section, status, skill or words. ) <>
          ~s(Use it to answer "what does the project plan", "what is still open" and ) <>
          ~s("what would this change touch".),
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "section" => %{
            "type" => "string",
            "description" =>
              "sensor-module-improvements, learning-module-improvements, motor-system-improvements, " <>
                "voting-improvements, cmp-hierarchy-improvements, environment-improvements, " <>
                "framework-improvements, monty-tooling, monty-demos, oss-communication-improvements"
          },
          "status" => %{
            "type" => "string",
            "description" => "`open`, `in-progress` or `completed`."
          },
          "skill" => %{"type" => "string", "description" => "A skill tag, e.g. `monty-advanced`."},
          "query" => %{"type" => "string", "description" => "Words the task must contain."},
          "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 200, "default" => 25}
        }
      },
      "annotations" => @read_only
    },
    %{
      "name" => "monty_roadmap_task",
      "title" => "Read a roadmap task",
      "description" => "One roadmap task, whole, with its metadata and its page.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "task" => %{
            "type" => "string",
            "description" => "A task id from `monty_roadmap`, e.g. `vote-on-state`, or its path."
          }
        },
        "required" => ["task"]
      },
      "annotations" => @read_only
    },
    %{
      "name" => "monty_lookup_module",
      "title" => "Where a Monty module lives here",
      "description" =>
        "The Elixir module a piece of Monty's Python becomes, and whether it is " <>
          "implemented, planned or excluded — with the reason for an exclusion. Accepts a " <>
          "dotted class (`tbp.monty.frameworks.models.sensor_modules.CameraSM`), a file " <>
          "(`src/tbp/monty/...py`) or the Elixir module itself.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "target" => %{
            "type" => "string",
            "description" => "A Python target or an Elixir module."
          }
        },
        "required" => ["target"]
      },
      "annotations" => @read_only
    },
    %{
      "name" => "monty_port_status",
      "title" => "How much of Monty is ported",
      "description" =>
        "The module map's counts: how many of Monty's modules exist here, which are still " <>
          "planned, and which are excluded and why. This is the honest answer to \"is this " <>
          "feature available on the BEAM yet\".",
      "inputSchema" => %{"type" => "object", "properties" => %{}},
      "annotations" => @read_only
    },
    %{
      "name" => "monty_code_in_doc",
      "title" => "The code a doc page refers to",
      "description" =>
        "Takes a documentation page and resolves every Monty module it refers to — by path " <>
          "or by dotted target — to its Elixir module and port status. The shortest path " <>
          "from a paragraph of theory to the code that implements it.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "slug" => %{"type" => "string", "description" => "A page slug from `monty_docs_index`."}
        },
        "required" => ["slug"]
      },
      "annotations" => @read_only
    },
    %{
      "name" => "monty_list_experiments",
      "title" => "List experiments (counts and facets)",
      "description" =>
        ~s|How many experiments there are, the choices they make counted, and a page of | <>
          ~s|the matching ones. `agent` (dist/surf), `modules` (learning modules, a | <>
          ~s|number), `learning_module`, `model` (pretrained/scratch) and a word `query` | <>
          ~s|are all optional and combine; the counts respect them. This is the tool for | <>
          ~s|"how many experiments", "which use surface agents", "how many with five | <>
          ~s|learning modules" — not a list to count yourself. Whether *this deployment* | <>
          ~s|runs several at once is `monty_studio`, and not a property of a config.|,
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "query" => %{
            "type" => "string",
            "description" => "Words the name or choices must contain."
          },
          "agent" => %{"type" => "string", "description" => "`dist`, `surf`, or `other`."},
          "modules" => %{
            "type" => "string",
            "description" => "How many learning modules, e.g. `5`."
          },
          "learning_module" => %{
            "type" => "string",
            "description" => "The learning module family, e.g. `evidence` or `feature`."
          },
          "model" => %{"type" => "string", "description" => "`pretrained` or `scratch`."},
          "group" => %{
            "type" => "string",
            "description" => "A group name, e.g. `monty/learning_module`."
          },
          "option" => %{"type" => "string", "description" => "The option that group must choose."},
          "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 200, "default" => 25},
          "offset" => %{"type" => "integer", "minimum" => 0, "default" => 0}
        }
      },
      "annotations" => @read_only
    },
    %{
      "name" => "monty_describe_experiment",
      "title" => "Describe an experiment",
      "description" =>
        "What an experiment is made of: the sensors, the learning modules and their configs, " <>
          "how they are connected, the motor system, the epochs, the seed, the findings, and " <>
          "how many of the classes it names are ported here. This is the tool for \"what are " <>
          "the parameters of that setup\".",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "name" => %{
            "type" => "string",
            "description" => "An experiment name, e.g. `base_10simobj_surf_agent`."
          }
        },
        "required" => ["name"]
      },
      "annotations" => @read_only
    },
    %{
      "name" => "monty_experiment_options",
      "title" => "The choices a config has",
      "description" =>
        "With no argument: the groups a config is built from. With a `group`: the options " <>
          "that group offers — every one of them a file in Monty's own `conf/` tree.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "group" => %{
            "type" => "string",
            "description" => "A group name, e.g. `monty/learning_module`."
          }
        }
      },
      "annotations" => @read_only
    },
    %{
      "name" => "monty_read_option",
      "title" => "Read one option's config",
      "description" =>
        "One option's own YAML: the parameters that module is handed, as Monty ships them. " <>
          "This is where a value a description mentions is actually set.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "group" => %{"type" => "string", "description" => "A group name."},
          "option" => %{"type" => "string", "description" => "An option of that group."}
        },
        "required" => ["group", "option"]
      },
      "annotations" => @read_only
    },
    %{
      "name" => "monty_preview_experiment",
      "title" => "Preview an experiment",
      "description" =>
        "What an experiment you are describing would compose to, without saving anything: the " <>
          "generated YAML, the findings (an option that does not exist, a sensor nothing " <>
          "listens to), and the setup it would produce. Do this before " <>
          "`monty_create_experiment`.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{"attributes" => @attributes},
        "required" => ["attributes"]
      },
      "annotations" => @read_only
    },
    %{
      "name" => "monty_create_experiment",
      "title" => "Save an experiment draft",
      "description" =>
        "Saves the experiment you described as a draft the studio can open, run and edit. " <>
          "Answers with the draft's URL. Preview it first: a draft that does not compose is a " <>
          "page that will not open.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{"attributes" => @attributes},
        "required" => ["attributes"]
      },
      "annotations" => @writes
    },
    %{
      "name" => "monty_export_experiment",
      "title" => "Export an experiment as a file",
      "description" =>
        "The experiment as the YAML file a person would edit — a draft as it was saved, a " <>
          "Monty experiment as its own short `defaults:` list. This is how you take one of " <>
          "Monty's experiments, change it to what you want, and keep the result: edit the " <>
          "text and bring it back with `monty_import_experiment`.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string", "description" => "The experiment to export."}
        },
        "required" => ["name"]
      },
      "annotations" => @read_only
    },
    %{
      "name" => "monty_import_experiment",
      "title" => "Import an experiment file",
      "description" =>
        "Keeps an experiment YAML file from somewhere else as a draft. It is composed " <>
          "before it is written, so a file that is not a Hydra config is refused; one that " <>
          "composes but would not run is saved and the findings say what is wrong. The name " <>
          "is a new draft's name (one file name, no slashes); replacing an existing draft " <>
          "takes `overwrite`.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string", "description" => "The draft's name."},
          "yaml" => %{"type" => "string", "description" => "The file's text."},
          "overwrite" => %{
            "type" => "boolean",
            "default" => false,
            "description" => "Replace a draft of the same name."
          }
        },
        "required" => ["name", "yaml"]
      },
      "annotations" => @writes
    },
    %{
      "name" => "monty_run_experiment",
      "title" => "Run an experiment",
      "description" =>
        "Queues a run of an experiment and answers with the run's id and a link to it. The " <>
          "run happens in the studio's queue at its own pace, and the page shows the sensors, " <>
          "the log and the summary as they arrive. `world` chooses which world it steps: " <>
          "`synthetic` is this port's stand-in scene, `monty` is Monty's own simulator out of " <>
          "process — absent, the deployment's default applies, and the run records which one " <>
          "it was given. A setup Monty would refuse is refused here instead of queued.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string", "description" => "An experiment name."},
          "steps" => %{
            "type" => "integer",
            "minimum" => 1,
            "maximum" => 500,
            "default" => 12,
            "description" => "How many timesteps the run should take."
          },
          "world" => %{
            "type" => "string",
            "enum" => ["synthetic", "monty"],
            "description" =>
              "`synthetic` steps this port's scene; `monty` steps Monty's own simulator " <>
                "through a Python peer, and needs MONTY_PYTHON. Default: the deployment's."
          }
        },
        "required" => ["name"]
      },
      "annotations" => @writes
    },
    %{
      "name" => "monty_run_report",
      "title" => "What a run did",
      "description" =>
        "A run's status, how far it got, its summary (goals, votes, modules that never " <>
          "received input) and its last few steps, with the link to the run.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "run_id" => %{
            "type" => "string",
            "description" => "The id `monty_run_experiment` answered with."
          }
        },
        "required" => ["run_id"]
      },
      "annotations" => @read_only
    },
    %{
      "name" => "monty_list_runs",
      "title" => "List runs",
      "description" =>
        "The runs this studio has started, newest first, each with a link — and how many " <>
          "there are of each kind. Filter by `state` (`running`, `finished`, `stopped`, " <>
          "`failed`) or by words in the experiment's name. For one run's detail ask " <>
          "`monty_run_report`.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "state" => %{
            "type" => "string",
            "description" => "running, finished, stopped, failed, or all (the default)."
          },
          "query" => %{
            "type" => "string",
            "description" => "Words the experiment's name must contain."
          },
          "page" => %{"type" => "integer", "minimum" => 1, "default" => 1},
          "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 50, "default" => 10}
        }
      },
      "annotations" => @read_only
    },
    %{
      "name" => "monty_delete_runs",
      "title" => "Delete runs",
      "description" =>
        "Forget runs and the files they wrote. Deletes nothing unless `confirm` is true: " <>
          "the first call answers exactly what would go, by id and experiment. Name the " <>
          "runs with `run_ids`, or narrow with `state`/`query` (at most 50 runs a call). " <>
          "A run that is still running is never deleted — it is the only thing that can " <>
          "record what it did.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "run_ids" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "The runs to delete, by id. Omit to delete by filter."
          },
          "state" => %{
            "type" => "string",
            "description" => "Delete the runs in this state, e.g. `failed`."
          },
          "query" => %{
            "type" => "string",
            "description" => "Delete the runs whose experiment's name contains these words."
          },
          "confirm" => %{
            "type" => "boolean",
            "default" => false,
            "description" => "False (the default) answers what would be deleted; true deletes."
          }
        }
      },
      "annotations" => @destructive
    }
  ]

  # One entry per tool in `@tools`, so a definition without a function (or the
  # other way round) is a compile-time miss rather than a tool a client can see
  # and cannot call.
  @dispatch %{
    "monty_studio" => {Studio, :about},
    "monty_search_docs" => {Docs, :search},
    "monty_read_doc" => {Docs, :read},
    "monty_docs_index" => {Docs, :index},
    "monty_docs_map" => {Docs, :map},
    "monty_roadmap" => {Roadmap, :tasks},
    "monty_roadmap_task" => {Roadmap, :task},
    "monty_lookup_module" => {Port, :lookup},
    "monty_port_status" => {Port, :status},
    "monty_code_in_doc" => {Port, :code_in_doc},
    "monty_list_experiments" => {Experiments, :list},
    "monty_describe_experiment" => {Experiments, :describe},
    "monty_experiment_options" => {Experiments, :options},
    "monty_read_option" => {Experiments, :read_option},
    "monty_preview_experiment" => {Experiments, :preview},
    "monty_create_experiment" => {Experiments, :create},
    "monty_export_experiment" => {Experiments, :export_experiment},
    "monty_import_experiment" => {Experiments, :import_experiment},
    "monty_run_experiment" => {Experiments, :run},
    "monty_run_report" => {Experiments, :run_report},
    "monty_list_runs" => {Experiments, :list_runs},
    "monty_delete_runs" => {Experiments, :delete_runs}
  }

  # How a reader asks for them, which is not how the protocol needs them ordered.
  # A test holds this to `@tools` in both directions, so a tool that is added and
  # not put in a family (or a family that names a tool that no longer exists) is
  # a failing test rather than a page that quietly lists the wrong thing.
  @families [
    {"The studio", ~w(monty_studio)},
    {"Documentation", ~w(monty_search_docs monty_read_doc monty_docs_index monty_docs_map)},
    {"Roadmap", ~w(monty_roadmap monty_roadmap_task)},
    {"The port", ~w(monty_lookup_module monty_port_status monty_code_in_doc)},
    {"Experiments", ~w(monty_list_experiments monty_describe_experiment monty_experiment_options
        monty_read_option monty_preview_experiment monty_create_experiment
        monty_export_experiment monty_import_experiment monty_run_experiment)},
    {"Runs", ~w(monty_list_runs monty_run_report monty_delete_runs)}
  ]

  # A family that names a tool nobody defined is a compile error, not a page
  # with a hole in it.
  for {_label, names} <- @families, name <- names do
    unless Enum.any?(@tools, &(&1["name"] == name)) do
      raise "the family list names #{inspect(name)}, which is not a tool"
    end
  end

  @doc """
  The tools, grouped the way a reader asks for them, as their own definitions.

  Each entry is `{label, [definition]}`, and a definition is the map the protocol
  serves — name, title, description, `inputSchema` and annotations — so a page
  that renders this shows what a client is actually offered, not a retelling.
  """
  @spec families() :: [{String.t(), [map()]}]
  def families do
    by_name = Map.new(@tools, &{&1["name"], &1})

    for {label, names} <- @families,
        do: {label, Enum.map(names, &Map.fetch!(by_name, &1))}
  end

  @doc "How many tools there are, for the pages that say so."
  @spec count() :: non_neg_integer()
  def count, do: length(@tools)

  @doc "The tools that change something, so a page need not claim it by hand."
  @spec writers() :: [map()]
  def writers, do: Enum.reject(@tools, &(&1["annotations"]["readOnlyHint"] == true))

  @doc "The `tools/list` result."
  @spec definitions() :: [map()]
  def definitions, do: @tools

  @doc "The tool names, sorted."
  @spec names() :: [String.t()]
  def names, do: @dispatch |> Map.keys() |> Enum.sort()

  @doc """
  Calls a tool.

  `ctx` carries what a tool cannot work out for itself and must not guess: the
  address this server answers on, so a run can be answered with a link that
  opens.
  """
  @spec call(String.t(), map(), ctx()) :: result() | :unknown_tool
  def call(name, arguments, ctx) when is_map(arguments) do
    case Map.fetch(@dispatch, name) do
      {:ok, {module, function}} -> apply(module, function, [arguments, ctx])
      :error -> :unknown_tool
    end
  end

  def call(_name, _arguments, _ctx), do: {:error, "Tool arguments must be a JSON object."}
end
