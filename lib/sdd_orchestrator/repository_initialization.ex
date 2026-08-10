defmodule SddOrchestrator.RepositoryInitialization do
  @moduledoc """
  Pre-project plan lifecycle for empty-repository initialization (specs/16 Task 2).

  A plan tracks the read-only, sequential product-first and
  technical-foundation question gate (AC-03) behind one eligible empty
  target (AC-01): `purpose -> users -> first_outcome -> constraints ->
  technical_foundation -> ready`. Only the plan's own `current_field` may be
  answered; accepting an answer both advances the cursor and creates a new
  plan version in the same update, so the version history is exactly the
  sequence of accepted answers. Nothing here ever touches the filesystem —
  the plan is a governed record only, matching AC-02's no-mutation rule.
  """

  alias SddOrchestrator.Repo
  alias SddOrchestrator.RepositoryInitialization.Plan

  @type create_attrs :: %{
          required(:device_workspace_id) => Ecto.UUID.t(),
          required(:target_reference) => String.t(),
          required(:eligibility) => String.t(),
          optional(:account_id) => Ecto.UUID.t() | nil
        }

  @doc "Creates one new plan at version 1, with the cursor on `purpose`."
  @spec create_plan(create_attrs()) :: {:ok, Plan.t()} | {:error, Ecto.Changeset.t()}
  def create_plan(attrs) do
    %Plan{}
    |> Plan.create_changeset(attrs)
    |> Repo.insert()
  end

  @doc "Fetches one plan by id."
  @spec get_plan(Ecto.UUID.t()) :: {:ok, Plan.t()} | {:error, :not_found}
  def get_plan(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %Plan{} = plan <- Repo.get(Plan, uuid) do
      {:ok, plan}
    else
      _not_found -> {:error, :not_found}
    end
  end

  @doc """
  Accepts one answer for the plan's current field.

  This is the decision gate (AC-03): `field` is only accepted when it equals
  `plan.current_field`, so a caller cannot skip ahead (for example, straight
  to `technical_foundation` before `purpose`, `users`, `first_outcome`, and
  `constraints` are all answered). A rejected field writes nothing. Acceptance
  writes the value, advances the cursor, and bumps `version` by exactly one,
  all in a single update — the versioning mechanism this plan relies on.
  """
  @spec answer_field(Plan.t(), String.t(), term()) ::
          {:ok, Plan.t()} | {:error, :out_of_order | :invalid_answer | Ecto.Changeset.t()}
  def answer_field(%Plan{} = plan, field, value) when is_binary(field) do
    with :ok <- validate_current_field(plan, field),
         {:ok, field_atom, cast_value} <- cast_answer(field, value) do
      plan
      |> Plan.answer_changeset(%{
        field_atom => cast_value,
        current_field: Plan.next_field(field),
        version: plan.version + 1
      })
      |> Repo.update()
    end
  end

  def answer_field(_plan, _field, _value), do: {:error, :invalid_answer}

  defp validate_current_field(%Plan{current_field: current_field}, field) do
    if field == current_field, do: :ok, else: {:error, :out_of_order}
  end

  defp cast_answer(field, value)
       when field in ["purpose", "users", "first_outcome", "constraints", "technical_foundation"] do
    normalize_value(Plan.field_atom(field), value)
  end

  defp cast_answer(_field, _value), do: {:error, :invalid_answer}

  defp normalize_value(:technical_foundation, %{} = value) when not is_struct(value) do
    if map_size(value) > 0,
      do: {:ok, :technical_foundation, value},
      else: {:error, :invalid_answer}
  end

  defp normalize_value(:technical_foundation, value) when is_binary(value) do
    with {:ok, trimmed} <- non_blank(value) do
      {:ok, :technical_foundation, %{"summary" => trimmed}}
    end
  end

  defp normalize_value(field, value) when is_binary(value) do
    with {:ok, trimmed} <- non_blank(value) do
      {:ok, field, trimmed}
    end
  end

  defp normalize_value(_field, _value), do: {:error, :invalid_answer}

  defp non_blank(value) do
    case String.trim(value) do
      "" -> {:error, :invalid_answer}
      trimmed -> {:ok, trimmed}
    end
  end
end
