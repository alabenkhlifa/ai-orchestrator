defmodule SddOrchestrator.HostedAccess.SessionCookie do
  @moduledoc """
  Signed-cookie issuance contract for a hosted session.

  The signed value contains an opaque 256-bit secret. Persistence receives only
  its SHA-256 digest, and struct inspection excludes the credential-bearing
  cookie value.
  """

  alias SddOrchestratorWeb.Endpoint

  @signing_salt "hosted-session-v1"
  @cookie_name "_sdd_orchestrator_hosted"

  @enforce_keys [:value]
  @derive {Inspect, only: []}
  defstruct [:value]

  @type t :: %__MODULE__{value: String.t()}

  @doc "Creates a signed cookie value and the digest to persist with its session."
  @spec issue() :: {binary(), t()}
  def issue do
    raw_token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    signed_value = Phoenix.Token.sign(Endpoint, @signing_salt, raw_token)

    {digest(raw_token), %__MODULE__{value: signed_value}}
  end

  @doc "Returns the protected digest represented by an untampered, unexpired cookie."
  @spec digest_from_signed(String.t()) :: {:ok, binary()} | :error
  def digest_from_signed(signed_value) when is_binary(signed_value) do
    case Phoenix.Token.verify(Endpoint, @signing_salt, signed_value,
           max_age: session_lifetime_seconds()
         ) do
      {:ok, raw_token} -> {:ok, digest(raw_token)}
      {:error, _reason} -> :error
    end
  end

  def digest_from_signed(_signed_value), do: :error

  @doc "Cookie name reserved for hosted browser authorization."
  @spec name() :: String.t()
  def name, do: @cookie_name

  @doc "Security attributes Task 5 must apply when writing the cookie."
  @spec options() :: keyword()
  def options do
    [
      http_only: true,
      secure: true,
      same_site: "Lax",
      max_age: session_lifetime_seconds()
    ]
  end

  @doc false
  @spec session_lifetime_seconds() :: pos_integer()
  def session_lifetime_seconds do
    :sdd_orchestrator
    |> Application.fetch_env!(:passwordless)
    |> Keyword.fetch!(:session_lifetime_seconds)
  end

  defp digest(raw_token), do: :crypto.hash(:sha256, raw_token)
end
