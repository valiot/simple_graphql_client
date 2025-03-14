defmodule SimpleGraphqlClient.Config do
  @moduledoc """
    Configuration for appliaction
  """
  @default_headers [{"Content-Type", "application/json"}]
  def api_url(opts) do
    required_url(opts, :url)
  end

  def ws_api_url(opts) do
    required_url(opts, :ws_url)
  end

  def headers(opts) do
    @default_headers ++ (Keyword.get(opts, :headers) || [])
  end

  def http_options(opts) do
    Keyword.get(opts, :http_options, [])
  end

  defp required_url(opts, key) do
    Keyword.get(opts, key) || raise "Please pass #{key} it in opts"
  end
end
