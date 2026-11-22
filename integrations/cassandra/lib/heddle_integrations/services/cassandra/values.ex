defmodule HeddleIntegrations.Services.Cassandra.Values do
  @moduledoc false
  # Turns what a field holds into the type a column takes.

  def to_text(value) when is_binary(value), do: value
  def to_text(value) when is_map(value) or is_list(value), do: Jason.encode!(value)
  def to_text(value), do: to_string(value)

  def to_integer(value) when is_integer(value), do: {:ok, value}
  def to_integer(value) when is_float(value) and trunc(value) == value, do: {:ok, trunc(value)}

  def to_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} -> {:ok, number}
      _other -> :error
    end
  end

  def to_integer(_value), do: :error

  def to_float(value) when is_number(value), do: {:ok, value / 1}

  def to_float(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {number, ""} -> {:ok, number}
      _other -> :error
    end
  end

  def to_float(_value), do: :error

  def to_decimal(value) when is_integer(value), do: {:ok, Decimal.new(value)}
  def to_decimal(value) when is_float(value), do: {:ok, Decimal.from_float(value)}

  def to_decimal(value) when is_binary(value) do
    value = String.trim(value)

    if value =~ @decimal, do: {:ok, Decimal.new(value)}, else: :error
  end

  def to_decimal(_value), do: :error

  def to_boolean(value) when is_boolean(value), do: {:ok, value}
  def to_boolean(value) when value in ["true", "t", "1", 1], do: {:ok, true}
  def to_boolean(value) when value in ["false", "f", "0", 0], do: {:ok, false}
  def to_boolean(_value), do: :error

  def parse(value, parser) when is_binary(value) do
    case parser.(String.trim(value)) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, _reason} -> :error
    end
  end

  def parse(_value, _parser), do: :error

  def to_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(String.trim(value)) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _reason} -> naive_to_utc(value)
    end
  end

  def to_datetime(_value), do: :error

  defp naive_to_utc(value) do
    case NaiveDateTime.from_iso8601(String.trim(value)) do
      {:ok, naive} -> {:ok, DateTime.from_naive!(naive, "Etc/UTC")}
      {:error, _reason} -> parse(value, &date_to_utc/1)
    end
  end

  defp date_to_utc(value) do
    with {:ok, date} <- Date.from_iso8601(value) do
      {:ok, DateTime.new!(date, ~T[00:00:00])}
    end
  end

  def from_json(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> value
    end
  end

  def from_json(value), do: value
end
