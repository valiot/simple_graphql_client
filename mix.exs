defmodule SimpleGraphqlClient.MixProject do
  use Mix.Project
  @version "0.2.1"
  @github_url "https://github.com/gen1321/simple_graphql_client"

  def project do
    [
      app: :simple_graphql_client,
      description: "Elixir graphql client",
      start_permanent: Mix.env() == :prod,
      version: @version,
      elixir: "~> 1.3",
      package: package(),
      docs: docs(),
      source_url: @github_url,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:httpoison, "~> 1.3.1"},
      {:poison, "~> 3.1"},
      {:websockex, "~> 0.4.0"},
      {:ring_logger, "0.5.0"},
      {:dialyxir, "~> 1.0.0-rc.3", only: [:dev], runtime: false},
      {:credo, "~> 0.10.0", only: [:dev, :test], runtime: false},
      {:elixir_uuid, "~> 1.2"},
      {:mock, "~> 0.3.0", only: :test},
      {:ex_doc, "~> 0.19", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      files: [
        "lib",
        "mix.exs",
        "README.md",
        "LICENSE"
      ],
      links: %{"github" => @github_url},
      maintainers: ["Boris Beginin <gen3212@gmail.com>"],
      licenses: ["MIT"]
    ]
  end

  defp docs do
    [
      source_ref: "v#{@version}",
      main: "SimpleGraphqlClient",
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end
end
