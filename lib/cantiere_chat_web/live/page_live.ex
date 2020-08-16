defmodule CantiereChatWeb.PageLive do
  use CantiereChatWeb, :live_view
  alias CantiereChatWeb.Presence
  @pubsub_topic "chat"

  @impl true
  def mount(_params, _session, socket) do
    CantiereChatWeb.Endpoint.subscribe(@pubsub_topic)
    {:ok, socket, temporary_assigns: [messages: []]}
  end

  @impl true
  def handle_event("join", %{"user_name" => user_name}, socket) do
    {:noreply,
     socket
     |> push_patch(to: Routes.page_path(socket, :chat, user_name: user_name))}
  end

  @impl true
  def handle_event("send", %{"message" => ""}, socket), do: {:noreply, socket}

  @impl true
  def handle_event("send", %{"message" => message}, socket) do
    user_name = socket.assigns.user_name

    new_message = %{
      id: System.unique_integer([:positive]),
      type: :message,
      user: user_name,
      message: message
    }

    messages = List.insert_at(socket.assigns.messages, -1, new_message)

    CantiereChatWeb.Endpoint.broadcast_from(self(), @pubsub_topic, "message", %{
      message: new_message
    })

    {:noreply,
     socket
     |> assign(:message, "")
     |> assign(:messages, messages)
     # When user sends a message notify all users and stop the timer
     |> notify_users_that_stopped_typing()}
  end

  @impl true
  def handle_event("keyup", %{"key" => _any}, socket),
    do: {:noreply, notify_users_that_started_typing(socket)}

  @impl true
  def handle_params(params, _url, socket) do
    live_action = socket.assigns.live_action
    {:noreply, apply_action(socket, live_action, params)}
  end

  def handle_info(_any, %{assigns: %{live_action: :index}} = socket), do: {:noreply, socket}

  @impl true
  def handle_info(%{event: "message", payload: %{message: new_message}}, socket) do
    messages = List.insert_at(socket.assigns.messages, -1, new_message)

    {:noreply,
     socket
     |> assign(messages: messages)}
  end

  def handle_info(%{event: "presence_diff", payload: %{joins: joins, leaves: leaves}}, socket) do
    user_name = socket.assigns.user_name

    messages =
      socket.assigns.messages
      |> process_joins_and_leaves(user_name, joins, leaves)

    users =
      Presence.list(@pubsub_topic)
      |> Enum.map(fn {user_name, _data} -> user_name end)

    current_users_status = socket.assigns.users_statuses

    users_statuses =
      Enum.reduce(users, %{}, fn user_name, acc ->
        # If someone is typing during the presence_diff event we won't change that
        Map.put(acc, user_name, Map.get(current_users_status, user_name, :idle))
      end)

    {:noreply,
     socket
     |> assign(:users, users)
     |> assign(:users_statuses, users_statuses)
     |> assign(:messages, messages)}
  end

  @impl true
  def handle_info(%{event: "started_typing", payload: %{user_name: user_name}}, socket) do
    updated_users_statuses =
      socket.assigns.users_statuses
      |> Map.put(user_name, :typing)

    {:noreply, assign(socket, :users_statuses, updated_users_statuses)}
  end

  @impl true
  def handle_info(:stopped_typing_timer, socket),
    do: {:noreply, notify_users_that_stopped_typing(socket)}

  @impl true
  def handle_info(%{event: "stopped_typing", payload: %{user_name: user_name}}, socket) do
    updated_users_statuses =
      socket.assigns.users_statuses
      |> Map.put(user_name, :idle)

    {:noreply, assign(socket, :users_statuses, updated_users_statuses)}
  end

  def apply_action(socket, :chat, %{"user_name" => ""}), do: redirect_back(socket)

  def apply_action(socket, :chat, %{"user_name" => user_name}) do
    Presence.track(
      self(),
      @pubsub_topic,
      user_name,
      %{
        user_name: user_name
      }
    )

    socket
    |> assign(user_name: user_name)
    |> assign(messages: [])
    |> assign(message: "")
    |> assign(users: [])
    |> assign(users_statuses: %{})
  end

  def apply_action(socket, :chat, _other), do: redirect_back(socket)

  def apply_action(socket, :index, _params) do
    socket
    |> assign(user_name: "")
  end

  defp redirect_back(socket) do
    socket
    |> put_flash(:error, "You need to set your name to enter the chat.")
    |> push_redirect(to: Routes.page_path(socket, :index))
  end

  defp process_joins_and_leaves(messages, actual_user, joins, leaves) do
    messages = Enum.reverse(messages)

    joins = Enum.reject(joins, fn {user_name, _data} -> user_name == actual_user end)
    leaves = Enum.reject(leaves, fn {user_name, _data} -> user_name == actual_user end)

    messages =
      Enum.reduce(joins, messages, fn {user_name, _data}, _acc ->
        new_message = %{
          id: System.unique_integer([:positive]),
          type: :enter,
          user: user_name,
          message: "#{user_name} entered the chat."
        }

        [new_message | messages]
      end)

    messages =
      Enum.reduce(leaves, messages, fn {user_name, _data}, _acc ->
        new_message = %{
          id: System.unique_integer([:positive]),
          type: :leave,
          user: user_name,
          message: "#{user_name} left the chat."
        }

        [new_message | messages]
      end)

    Enum.reverse(messages)
  end

  defp render_users_with_statuses(users, users_statuses) do
    Enum.map(users, fn user ->
      case Map.get(users_statuses, user) do
        :idle -> user
        :typing -> "#{user}(typing)"
      end
    end)
    |> Enum.join(", ")
  end

  defp stop_typing_timer(%{assigns: %{typing_timer: timer}} = socket)
       when not is_nil(timer) do
    # if the timer is already stopped it will return false, but won't raise any error
    Process.cancel_timer(timer)
    assign(socket, :typing_timer, nil)
  end

  defp stop_typing_timer(socket), do: socket

  defp restart_typing_timer(socket) do
    socket
    |> stop_typing_timer()
    |> assign(:typing_timer, Process.send_after(self(), :stopped_typing_timer, 5_000))
  end

  defp notify_users_that_started_typing(socket) do
    user_name = socket.assigns.user_name

    CantiereChatWeb.Endpoint.broadcast_from(self(), @pubsub_topic, "started_typing", %{
      user_name: user_name
    })

    restart_typing_timer(socket)
  end

  defp notify_users_that_stopped_typing(socket) do
    user_name = socket.assigns.user_name

    CantiereChatWeb.Endpoint.broadcast_from(self(), @pubsub_topic, "stopped_typing", %{
      user_name: user_name
    })

    # Even if the timer is stopped, we will unassign here the type_timer variable
    stop_typing_timer(socket)
  end
end
