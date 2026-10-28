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

  alias ExTbpMonty.Mcp.Tools.{Docs, Experiments, Port, Roadmap}

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
      "name" => "monty_search_docs",
      "title" => "Search Monty's documentation",
      "description" =>
        "Find the passage of Monty's documentation that answers a question — the theory, " <>
          "how Monty works, how to use it, its roadmap. Returns the best sections with the " <>
          "page they came from, a link to the published page, and a `path` for " <>
          "`monty_read_doc`. Search on the words the project uses (`learning module`, " <>
          "`evidence`, `voting`, `heterarchy`, `CMP`), not on a whole sentence.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "query" => %{"type" => "string", "description" => "Words to look for."},
          "area" => %{
            "type" => "string",
            "description" =>
              "Limit to one area of the docs: theory, overview, how-monty-works, " <>
                "how-to-use-monty, future-work, contributing, community."
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
          "path" => %{
            "type" => "string",
            "description" =>
              "A page path from `monty_docs_index`, e.g. `theory/theory-overview.md`."
          }
        },
        "required" => ["path"]
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
      "name" => "monty_roadmap",
      "title" => "Monty's roadmap",
      "description" =>
        ~s(The project's future-work tasks, one per page, with the status, scope, output type ) <>
          ~s(and skills the project itself records. Filter by section, status, skill or words. ) <>
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
          "path" => %{"type" => "string", "description" => "A page path from `monty_docs_index`."}
        },
        "required" => ["path"]
      },
      "annotations" => @read_only
    },
    %{
      "name" => "monty_list_experiments",
      "title" => "List experiments",
      "description" =>
        "Every experiment that can be opened here — Monty's own, plus this studio's drafts — " <>
          "with the choices its config makes. Filter by words in the name or the choices, or " <>
          "by one group's option (`group: \"monty/learning_module\", option: \"evidence_1lm\"`).",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "query" => %{"type" => "string", "description" => "Words the experiment must mention."},
          "group" => %{
            "type" => "string",
            "description" => "A group name, e.g. `monty/learning_module`."
          },
          "option" => %{"type" => "string", "description" => "The option that group must choose."}
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
      "name" => "monty_run_experiment",
      "title" => "Run an experiment",
      "description" =>
        "Queues a run of an experiment and answers with the run's id and a link to it. The " <>
          "run happens in the studio's queue at its own pace, and the page shows the sensors, " <>
          "the log and the summary as they arrive. A setup Monty would refuse is refused here " <>
          "instead of queued.",
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
      "description" => "The newest runs this studio has started, newest first, with links.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 50, "default" => 10}
        }
      },
      "annotations" => @read_only
    }
  ]

  # One entry per tool in `@tools`, so a definition without a function (or the
  # other way round) is a compile-time miss rather than a tool a client can see
  # and cannot call.
  @dispatch %{
    "monty_search_docs" => {Docs, :search},
    "monty_read_doc" => {Docs, :read},
    "monty_docs_index" => {Docs, :index},
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
    "monty_run_experiment" => {Experiments, :run},
    "monty_run_report" => {Experiments, :run_report},
    "monty_list_runs" => {Experiments, :list_runs}
  }

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
