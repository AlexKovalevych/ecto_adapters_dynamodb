defmodule Ecto.Adapters.DynamoDB.Mixfile do
  use Mix.Project

  def project do
    [app: :ecto_adapters_dynamodb,
     version: "0.1.0",
     elixir: "~> 1.4",
     build_embedded: Mix.env == :prod,
     start_permanent: Mix.env == :prod,
     deps: deps()]
  end

  # Configuration for the OTP application
  #
  # Type "mix help compile.app" for more information
  def application do
    # Specify extra applications you'll use from Erlang/Elixir
    [extra_applications: [:logger],
     mod: {Ecto.Adapters.DynamoDB.Application, []},
     applications: [:ex_aws, :hackney, :poison]
   ]
  end

  # Dependencies can be Hex packages:
  #
  #   {:my_dep, "~> 0.3.0"}
  #
  # Or git/path repositories:
  #
  #   {:my_dep, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
  #
  # Type "mix help deps" for more examples and options
  defp deps do
    [     
      {:ecto, ">= 2.1.4"},
      # {:ex_aws, "~> 1.0"},
      # github has a more updated version of ex_aws
      # but without specifying a version, we must keep track of 
      # bugs possibly introduced by updates to the dependency
      {:ex_aws, git: "https://github.com/CargoSense/ex_aws.git"},
      {:poison, "~> 2.0"},
      {:hackney, "~> 1.6"}
    ]
  end
end
