# A JUnit report is for a machine to read: GitHub's Checks tab takes one check
# per partition, with the failing tests inside it, and cannot read Elixir's own
# output. Writing one on every local run would leave a file behind for nobody,
# so `CI` decides — and the partition number goes into the name, because four
# runners write four reports.
if System.get_env("CI") do
  Application.put_env(:junit_formatter, :report_dir, "junit")

  Application.put_env(
    :junit_formatter,
    :report_file,
    "junit-#{System.get_env("MIX_TEST_PARTITION") || "local"}.xml"
  )

  Application.put_env(:junit_formatter, :automatic_create_dir?, true)
  # The file a test lives in, so a failing check can say where it is.
  Application.put_env(:junit_formatter, :include_filename?, true)

  ExUnit.configure(formatters: [ExUnit.CLIFormatter, JUnitFormatter])
end

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(ExTbpMonty.Repo.Postgres, :manual)
