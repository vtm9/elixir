defmodule EEx.Compiler do
  @moduledoc false

  # When changing this setting, don't forget to update the docs for EEx
  @default_engine EEx.SmartEngine

  @doc """
  This is the compilation entry point. It glues the tokenizer
  and the engine together by handling the tokens and invoking
  the engine every time a full expression or text is received.
  """
  @spec compile(String.t(), keyword) :: Macro.t()
  def compile(source, opts) when is_binary(source) and is_list(opts) do
    file = opts[:file] || "nofile"
    line = opts[:line] || 1
    column = 1
    indentation = opts[:indentation] || 0
    trim = opts[:trim] || false
    parser_options = opts[:parser_options] || Code.get_compiler_option(:parser_options)
    tokenizer_options = %{trim: trim, indentation: indentation, file: file}

    case EEx.Tokenizer.tokenize(source, line, column, tokenizer_options) do
      {:ok, tokens} ->
        state = %{
          engine: opts[:engine] || @default_engine,
          file: file,
          line: line,
          quoted: [],
          start_line: nil,
          start_column: nil,
          parser_options: parser_options
        }

        init = state.engine.init(opts)
        generate_buffer(tokens, init, [], state)

      {:error, message, %{column: column, line: line}} ->
        raise EEx.SyntaxError, file: file, line: line, column: column, message: message
    end
  end

  # Generates the buffers by handling each expression from the tokenizer.
  # It returns Macro.t/0 or it raises.

  defp generate_buffer([{:text, chars, meta} | rest], buffer, scope, state) do
    buffer =
      if function_exported?(state.engine, :handle_text, 3) do
        meta = [line: meta.line, column: meta.column]
        state.engine.handle_text(buffer, meta, IO.chardata_to_string(chars))
      else
        # TODO: Remove this branch on Elixir v2.0
        state.engine.handle_text(buffer, IO.chardata_to_string(chars))
      end

    generate_buffer(rest, buffer, scope, state)
  end

  defp generate_buffer([{:expr, mark, chars, meta} | rest], buffer, scope, state) do
    options =
      [file: state.file, line: meta.line, column: column(meta.column, mark)] ++
        state.parser_options

    expr = Code.string_to_quoted!(chars, options)
    buffer = state.engine.handle_expr(buffer, IO.chardata_to_string(mark), expr)
    generate_buffer(rest, buffer, scope, state)
  end

  defp generate_buffer(
         [{:start_expr, mark, chars, meta} | rest],
         buffer,
         scope,
         state
       ) do
    if mark == '' do
      message =
        "the contents of this expression won't be output unless the EEx block starts with \"<%=\""

      :elixir_errors.erl_warn({meta.line, meta.column}, state.file, message)
    end

    {rest, line, contents} = look_ahead_middle(rest, meta.line, chars) || {rest, meta.line, chars}

    {contents, rest} =
      generate_buffer(
        rest,
        state.engine.handle_begin(buffer),
        [contents | scope],
        %{
          state
          | quoted: [],
            line: line,
            start_line: meta.line,
            start_column: column(meta.column, mark)
        }
      )

    buffer = state.engine.handle_expr(buffer, IO.chardata_to_string(mark), contents)
    generate_buffer(rest, buffer, scope, state)
  end

  defp generate_buffer(
         [{:middle_expr, '', chars, meta} | rest],
         buffer,
         [current | scope],
         state
       ) do
    {wrapped, state} = wrap_expr(current, meta.line, buffer, chars, state)
    state = %{state | line: meta.line}
    generate_buffer(rest, state.engine.handle_begin(buffer), [wrapped | scope], state)
  end

  defp generate_buffer([{:middle_expr, _, chars, meta} | _], _buffer, [], state) do
    raise EEx.SyntaxError,
      message: "unexpected middle of expression <%#{chars}%>",
      file: state.file,
      line: meta.line,
      column: meta.column
  end

  defp generate_buffer(
         [{:end_expr, '', chars, meta} | rest],
         buffer,
         [current | _],
         state
       ) do
    {wrapped, state} = wrap_expr(current, meta.line, buffer, chars, state)
    column = state.start_column
    options = [file: state.file, line: state.start_line, column: column] ++ state.parser_options
    tuples = Code.string_to_quoted!(wrapped, options)
    buffer = insert_quoted(tuples, state.quoted)
    {buffer, rest}
  end

  defp generate_buffer([{:end_expr, _, chars, meta} | _], _buffer, [], state) do
    raise EEx.SyntaxError,
      message: "unexpected end of expression <%#{chars}%>",
      file: state.file,
      line: meta.line,
      column: meta.column
  end

  defp generate_buffer([{:eof, _meta}], buffer, [], state) do
    state.engine.handle_body(buffer)
  end

  defp generate_buffer([{:eof, meta}], _buffer, _scope, state) do
    raise EEx.SyntaxError,
      message: "unexpected end of string, expected a closing '<% end %>'",
      file: state.file,
      line: meta.line,
      column: meta.column
  end

  # Creates a placeholder and wrap it inside the expression block

  defp wrap_expr(current, line, buffer, chars, state) do
    new_lines = List.duplicate(?\n, line - state.line)
    key = length(state.quoted)
    placeholder = '__EEX__(' ++ Integer.to_charlist(key) ++ ');'
    count = current ++ placeholder ++ new_lines ++ chars
    new_state = %{state | quoted: [{key, state.engine.handle_end(buffer)} | state.quoted]}

    {count, new_state}
  end

  # Look middle expressions that immediately follow a start_expr

  defp look_ahead_middle([{:text, text, _meta} | rest], start, contents) do
    if only_spaces?(text) do
      look_ahead_middle(rest, start, contents ++ text)
    else
      nil
    end
  end

  defp look_ahead_middle([{:middle_expr, _, chars, meta} | rest], _start, contents) do
    {rest, meta.line, contents ++ chars}
  end

  defp look_ahead_middle(_tokens, _start, _contents) do
    nil
  end

  defp only_spaces?(chars) do
    Enum.all?(chars, &(&1 in [?\s, ?\t, ?\r, ?\n]))
  end

  # Changes placeholder to real expression

  defp insert_quoted({:__EEX__, _, [key]}, quoted) do
    {^key, value} = List.keyfind(quoted, key, 0)
    value
  end

  defp insert_quoted({left, line, right}, quoted) do
    {insert_quoted(left, quoted), line, insert_quoted(right, quoted)}
  end

  defp insert_quoted({left, right}, quoted) do
    {insert_quoted(left, quoted), insert_quoted(right, quoted)}
  end

  defp insert_quoted(list, quoted) when is_list(list) do
    Enum.map(list, &insert_quoted(&1, quoted))
  end

  defp insert_quoted(other, _quoted) do
    other
  end

  defp column(column, mark) do
    # length('<%') == 2
    column + 2 + length(mark)
  end
end
