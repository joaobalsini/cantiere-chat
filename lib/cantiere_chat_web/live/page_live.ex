defmodule CantiereChatWeb.PageLive do
  use CantiereChatWeb, :live_view
  alias CantiereChatWeb.Presence
  @pubsub_topic "chat"

  @impl true
  def mount(_params, _session, socket) do
    CantiereChatWeb.Endpoint.subscribe(@pubsub_topic)
    {:ok, socket}
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
    new_message = %{type: :message, user: user_name, message: message}

    messages = List.insert_at(socket.assigns.messages, -1, new_message)

    CantiereChatWeb.Endpoint.broadcast_from(self(), @pubsub_topic, "message", %{
      message: new_message
    })

    {:noreply,
     socket
     |> assign(message: "", messages: messages)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    live_action = socket.assigns.live_action
    {:noreply, apply_action(socket, live_action, params)}
  end

  @impl true
  def handle_info(%{event: "message", payload: %{message: new_message}}, socket) do
    messages = List.insert_at(socket.assigns.messages, -1, new_message)

    {:noreply,
     socket
     |> assign(messages: messages)}
  end

  def handle_info(%{event: "presence_diff", payload: %{joins: joins, leaves: leaves}}, socket) do
    user_name = socket.assigns.user_name
    live_action = socket.assigns.live_action

    case live_action do
      :index ->
        {:noreply, socket}

      :chat ->
        messages =
          socket.assigns.messages
          |> process_joins_and_leaves(user_name, joins, leaves)

        users =
          Presence.list(@pubsub_topic)
          |> Enum.map(fn {user_name, _data} -> user_name end)

        {:noreply, assign(socket, users: users, messages: messages)}
    end
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
        new_message = %{type: :enter, user: user_name, message: "#{user_name} entered the chat."}
        [new_message | messages]
      end)

    messages =
      Enum.reduce(leaves, messages, fn {user_name, _data}, _acc ->
        new_message = %{type: :enter, user: user_name, message: "#{user_name} left the chat."}
        [new_message | messages]
      end)

    Enum.reverse(messages)
  end
end
