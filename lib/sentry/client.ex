defmodule Sentry.Client do
  @moduledoc false

  # A Client is the part of the SDK that is responsible for event creation, running callbacks,
  # and sampling.
  # See https://develop.sentry.dev/sdk/unified-api/#client.

  alias Sentry.{Config, Envelope, Event, Interfaces, Transport}

  require Logger

  # Max message length per https://github.com/getsentry/sentry/blob/0fcec33ac94ad81a205f86f208072b0f57b39ff4/src/sentry/conf/server.py#L1021
  @max_message_length 8_192

  # We read this at compile time and use it exclusively for tests. Any user of the Sentry
  # application will get the real deal, but we'll be able to swap this out with a mock
  # in tests.
  @sender_module Application.compile_env(:sentry, :__sender_module__, Transport.Sender)

  # This is what executes the "Event Pipeline".
  # See: https://develop.sentry.dev/sdk/unified-api/#event-pipeline
  @spec send_event(Event.t(), keyword()) ::
          {:ok, event_id :: String.t()} | {:error, term()} | :unsampled | :excluded
  def send_event(%Event{} = event, opts) when is_list(opts) do
    result_type = Keyword.get_lazy(opts, :result, &Config.send_result/0)
    sample_rate = Keyword.get_lazy(opts, :sample_rate, &Config.sample_rate/0)

    # This is a "private" option, only really used in testing.
    request_retries =
      Keyword.get_lazy(opts, :request_retries, fn ->
        Application.get_env(:sentry, :request_retries, Transport.default_retries())
      end)

    with :ok <- sample_event(sample_rate),
         {:ok, %Event{} = event} <- maybe_call_before_send(event) do
      send_result = encode_and_send(event, result_type, request_retries)
      _ignored = maybe_call_after_send(event, send_result)
      send_result
    else
      :unsampled -> :unsampled
      :excluded -> :excluded
    end
  end

  defp sample_event(sample_rate) do
    cond do
      sample_rate == 1 -> :ok
      sample_rate == 0 -> :unsampled
      :rand.uniform() < sample_rate -> :ok
      true -> :unsampled
    end
  end

  defp maybe_call_before_send(event) do
    message = ":before_send_event must be an anonymous function or a {module, function} tuple"

    result =
      case Config.before_send_event() do
        function when is_function(function, 1) -> function.(event) || false
        {module, function} -> apply(module, function, [event]) || false
        nil -> event
        _other -> raise ArgumentError, message
      end

    if result, do: {:ok, result}, else: :excluded
  end

  defp maybe_call_after_send(%Event{} = event, result) do
    message = ":after_send_event must be an anonymous function or a {module, function} tuple"

    case Config.after_send_event() do
      function when is_function(function, 2) -> function.(event, result)
      {module, function} -> apply(module, function, [event, result])
      nil -> nil
      _ -> raise ArgumentError, message
    end
  end

  defp encode_and_send(_event, _result_type = :async, _request_retries) do
    raise ArgumentError, """
    the :async result type is not supported anymore. Instead, you can spawn a task yourself that \
    then calls Sentry.send_event/2 with result: :sync. The effect is exactly the same.
    """
  end

  defp encode_and_send(%Event{} = event, _result_type = :sync, request_retries) do
    envelope = Envelope.new([event])

    send_result = Transport.post_envelope(envelope, request_retries)

    if match?({:ok, _}, send_result) do
      Sentry.put_last_event_id_and_source(event.event_id, event.source)
    end

    _ = maybe_log_send_result(send_result, event)
    send_result
  end

  defp encode_and_send(%Event{} = event, _result_type = :none, _request_retries) do
    :ok = @sender_module.send_async(event)
    Sentry.put_last_event_id_and_source(event.event_id, event.source)
    {:ok, ""}
  end

  @spec render_event(Event.t()) :: map()
  def render_event(%Event{} = event) do
    json_library = Config.json_library()

    event
    |> Event.remove_non_payload_keys()
    |> update_if_present(:message, &String.slice(&1, 0, @max_message_length))
    |> update_if_present(:breadcrumbs, fn bcs -> Enum.map(bcs, &Map.from_struct/1) end)
    |> update_if_present(:sdk, &Map.from_struct/1)
    |> update_if_present(:request, &(&1 |> Map.from_struct() |> remove_nils()))
    |> update_if_present(:extra, &sanitize_non_jsonable_values(&1, json_library))
    |> update_if_present(:user, &sanitize_non_jsonable_values(&1, json_library))
    |> update_if_present(:tags, &sanitize_non_jsonable_values(&1, json_library))
    |> update_if_present(:exception, fn list -> Enum.map(list, &render_exception/1) end)
  end

  defp render_exception(%Interfaces.Exception{} = exception) do
    exception
    |> Map.from_struct()
    |> update_if_present(:stacktrace, fn %Interfaces.Stacktrace{frames: frames} ->
      %{frames: Enum.map(frames, &Map.from_struct/1)}
    end)
  end

  defp remove_nils(map) when is_map(map) do
    :maps.filter(fn _key, value -> not is_nil(value) end, map)
  end

  defp sanitize_non_jsonable_values(map, json_library) do
    # We update the existing map instead of building a new one from scratch
    # due to performance reasons. See the docs for :maps.map/2.
    Enum.reduce(map, map, fn {key, value}, acc ->
      case sanitize_non_jsonable_value(value, json_library) do
        :unchanged -> acc
        {:changed, value} -> Map.put(acc, key, value)
      end
    end)
  end

  # For performance, skip all the keys that we know for sure are JSON encodable.
  defp sanitize_non_jsonable_value(value, _json_library)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value) do
    :unchanged
  end

  defp sanitize_non_jsonable_value(value, json_library) when is_list(value) do
    {mapped, changed?} =
      Enum.map_reduce(value, _changed? = false, fn value, changed? ->
        case sanitize_non_jsonable_value(value, json_library) do
          :unchanged -> {value, changed?}
          {:changed, value} -> {value, true}
        end
      end)

    if changed? do
      {:changed, mapped}
    else
      :unchanged
    end
  end

  defp sanitize_non_jsonable_value(value, json_library)
       when is_map(value) and not is_struct(value) do
    {:changed, sanitize_non_jsonable_values(value, json_library)}
  end

  defp sanitize_non_jsonable_value(value, json_library) do
    case json_library.encode(value) do
      {:ok, _encoded} -> :unchanged
      {:error, _reason} -> {:changed, inspect(value)}
    end
  end

  defp update_if_present(map, key, fun) do
    case Map.pop(map, key) do
      {nil, _} -> map
      {value, map} -> Map.put(map, key, fun.(value))
    end
  end

  defp maybe_log_send_result(_send_result, %Event{source: :logger}) do
    :ok
  end

  defp maybe_log_send_result(send_result, %Event{}) do
    message =
      case send_result do
        {:error, :invalid_dsn} ->
          "Cannot send Sentry event because of invalid DSN"

        {:error, {:invalid_json, error}} ->
          "Unable to encode JSON Sentry error - #{inspect(error)}"

        {:error, {:request_failure, last_error}} ->
          case last_error do
            {kind, data, stacktrace}
            when kind in [:exit, :throw, :error] and is_list(stacktrace) ->
              Exception.format(kind, data, stacktrace)

            _other ->
              "Error in HTTP Request to Sentry - #{inspect(last_error)}"
          end

        {:ok, _} ->
          nil
      end

    if message do
      level = Config.log_level()
      Logger.log(level, fn -> ["Failed to send Sentry event. ", message] end, domain: [:sentry])
    end
  end
end
