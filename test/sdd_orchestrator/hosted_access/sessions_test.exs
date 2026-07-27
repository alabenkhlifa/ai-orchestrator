defmodule SddOrchestrator.HostedAccess.SessionsTest do
  use SddOrchestrator.DataCase, async: true

  alias SddOrchestrator.Accounts.{
    Account,
    DeviceWorkspace,
    HostedSession,
    Workspace
  }

  alias SddOrchestrator.HostedAccess.{SessionCookie, Sessions}
  alias SddOrchestrator.HostedAccessFixtures
  alias SddOrchestrator.ProjectStorage.ProjectStorageState

  test "restores the same hosted access after browser restart and slides activity" do
    result =
      HostedAccessFixtures.verified_hosted_session_fixture(
        email: "persistent@example.com",
        user_agent_family: "Firefox",
        os_family: "Linux"
      )

    original_expiry = result.session.expires_at
    earlier = DateTime.utc_now() |> DateTime.add(-60 * 60, :second)

    Repo.update_all(
      from(session in HostedSession, where: session.id == ^result.session.id),
      set: [last_seen_at: earlier]
    )

    # Reusing the protected browser credential models closing and reopening the
    # browser without creating a replacement device session.
    assert {:ok, restored} = Sessions.authenticate(result.session_cookie.value)
    assert restored.hosted_identity.id == result.hosted_identity.id
    assert restored.personal_workspace.id == result.personal_workspace.id
    assert restored.session.id == result.session.id
    assert DateTime.compare(restored.session.last_seen_at, earlier) == :gt
    assert restored.session.expires_at == original_expiry
    assert restored.session.user_agent_family == "Firefox"
    assert restored.session.os_family == "Linux"
    assert Repo.aggregate(HostedSession, :count) == 1
  end

  test "missing, tampered, expired, and disabled-account sessions fail closed" do
    expired =
      HostedAccessFixtures.verified_hosted_session_fixture(email: "expired-session@example.com")

    Repo.update_all(
      from(session in HostedSession, where: session.id == ^expired.session.id),
      set: [expires_at: DateTime.utc_now() |> DateTime.add(-1, :second)]
    )

    disabled =
      HostedAccessFixtures.verified_hosted_session_fixture(email: "disabled@example.com")

    Repo.update_all(
      from(account in Account, where: account.id == ^disabled.account.id),
      set: [state: "disabled"]
    )

    failures = [
      Sessions.authenticate(nil),
      Sessions.authenticate("not-a-cookie"),
      Sessions.authenticate(expired.session_cookie.value),
      Sessions.authenticate(disabled.session_cookie.value)
    ]

    assert Enum.uniq(failures) == [:error]
  end

  test "multiple devices remain independent and list only safe recognition data" do
    first =
      HostedAccessFixtures.verified_hosted_session_fixture(
        email: "devices@example.com",
        user_agent_family: "Firefox",
        os_family: "Linux"
      )

    assert {:ok, second_session, second_cookie} =
             Sessions.create(first.hosted_identity, %{
               user_agent_family: "Safari",
               os_family: "iOS"
             })

    listed = Sessions.list_active(first.hosted_identity, first.session_cookie.value)
    assert length(listed) == 2

    assert Enum.any?(listed, fn entry ->
             entry.session.id == first.session.id and entry.current?
           end)

    assert Enum.any?(listed, fn entry ->
             entry.session.id == second_session.id and not entry.current? and
               entry.session.user_agent_family == "Safari" and
               entry.session.os_family == "iOS"
           end)

    refute inspect(listed) =~ second_cookie.value

    :ok = Sessions.revoke(first.hosted_identity, second_session.id)
    assert {:ok, _access} = Sessions.authenticate(first.session_cookie.value)
    assert :error = Sessions.authenticate(second_cookie.value)
    assert Repo.get(HostedSession, first.session.id)
    refute Repo.get(HostedSession, second_session.id)
  end

  test "one identity cannot revoke another identity's session" do
    one = HostedAccessFixtures.verified_hosted_session_fixture(email: "one-owner@example.com")
    two = HostedAccessFixtures.verified_hosted_session_fixture(email: "two-owner@example.com")

    :ok = Sessions.revoke(one.hosted_identity, two.session.id)

    assert {:ok, _one_access} = Sessions.authenticate(one.session_cookie.value)
    assert {:ok, _two_access} = Sessions.authenticate(two.session_cookie.value)
    assert Repo.aggregate(HostedSession, :count) == 2
  end

  test "current-device and all-device revocation delete only their approved scope" do
    first = HostedAccessFixtures.verified_hosted_session_fixture(email: "revoke@example.com")

    assert {:ok, second_session, second_cookie} =
             Sessions.create(first.hosted_identity, %{})

    :ok = Sessions.revoke_current(first.session_cookie.value)
    assert :error = Sessions.authenticate(first.session_cookie.value)
    assert {:ok, _second_access} = Sessions.authenticate(second_cookie.value)
    refute Repo.get(HostedSession, first.session.id)
    assert Repo.get(HostedSession, second_session.id)

    :ok = Sessions.revoke_all(first.hosted_identity)
    assert :error = Sessions.authenticate(second_cookie.value)
    assert Repo.aggregate(HostedSession, :count) == 0
  end

  test "concurrent individual revocation is idempotent and never resurrects a session" do
    first = HostedAccessFixtures.verified_hosted_session_fixture(email: "race-revoke@example.com")

    assert {:ok, second_session, second_cookie} =
             Sessions.create(first.hosted_identity, %{})

    results =
      1..5
      |> Task.async_stream(fn _request ->
        Sessions.revoke(first.hosted_identity, second_session.id)
      end)
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.uniq(results) == [:ok]
    assert :error = Sessions.authenticate(second_cookie.value)
    assert {:ok, _first_access} = Sessions.authenticate(first.session_cookie.value)
    assert Repo.aggregate(HostedSession, :count) == 1
  end

  test "hosted sign-out does not mutate device-authoritative project ownership" do
    {:ok, root} = Workspace.device_root()
    {:ok, device_workspace} = DeviceWorkspace.from_workspace(root)

    project = %{
      id: Ecto.UUID.generate(),
      workspace_id: root.id,
      storage_mode: "device"
    }

    result = HostedAccessFixtures.verified_hosted_session_fixture(email: "device@example.com")
    assert DeviceWorkspace.owns_project?(device_workspace, project)

    :ok = Sessions.revoke_current(result.session_cookie.value)

    assert DeviceWorkspace.owns_project?(device_workspace, project)
    assert {:ok, state} = ProjectStorageState.from_project(project, root, :device_authoritative)
    assert state.storage_mode == "device"
    refute Map.has_key?(Map.from_struct(state), :session_cookie)
    refute Map.has_key?(Map.from_struct(device_workspace), :account_id)
  end

  test "session cookie digests remain outside ordinary inspection and domain state" do
    result = HostedAccessFixtures.verified_hosted_session_fixture(email: "secret@example.com")

    assert {:ok, digest} = SessionCookie.digest_from_signed(result.session_cookie.value)
    refute inspect(result.session) =~ Base.encode64(digest)
    refute inspect(result.hosted_identity) =~ result.session_cookie.value
    refute inspect(result.personal_workspace) =~ result.session_cookie.value
  end
end
