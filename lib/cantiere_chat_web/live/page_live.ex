defmodule CantiereChatWeb.PageLive do
  use CantiereChatWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, user_name: "")}
  end

  @impl true
  def handle_event("join", %{"user_name" => user_name}, socket) do
    {:noreply, assign(socket, user_name: user_name )}
  end
end
