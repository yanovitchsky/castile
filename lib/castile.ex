defmodule Castile do
  @moduledoc """
  Documentation for Castile.
  """

  @priv_dir Application.app_dir(:castile, "priv")

  import Record
  defrecord :wsdl_definitions, :"wsdl:tDefinitions",      [:attrs, :namespace, :name,     :docs,   :any,    :imports, :types, :messages, :port_types, :bindings, :services]
  defrecord :wsdl_service,     :"wsdl:tService",          [:attrs, :name,      :docs,     :choice, :ports]
  defrecord :wsdl_port,        :"wsdl:tPort",             [:attrs, :name,      :binding,  :docs,   :choice]
  defrecord :wsdl_binding,     :"wsdl:tBinding",          [:attrs, :name,      :type,     :docs,   :choice, :ops]
  defrecord :wsdl_binding_operation,   :"wsdl:tBindingOperation", [:attrs, :name,      :docs,     :choice, :input,  :output, :fault]
  defrecord :wsdl_import,      :"wsdl:tImport",           [:attrs, :namespace, :location, :docs]
  defrecord :wsdl_port_type,   :"wsdl:tPortType",         [:attrs, :name, :docs, :operations]
  defrecord :wsdl_part,        :"wsdl:tPart",             [:attrs, :name,      :element, :type,   :docs]
  defrecord :wsdl_message,     :"wsdl:tMessage",          [:attrs, :name,      :docs,    :choice, :part]
  defrecord :wsdl_operation,   :"wsdl:tOperation",        [:attrs, :name,      :parameterOrder,     :docs, :any,  :choice]
  defrecord :wsdl_request_response, :"wsdl:request-response-or-one-way-operation", [:attrs, :input, :output, :fault]
  defrecord :wsdl_param, :"wsdl:tParam", [:attrs, :name, :message, :docs]


  defrecord :soap_operation,   :"soap:tOperation",        [:attrs, :required,  :action,   :style]
  defrecord :soap_address,     :"soap:tAddress",          [:attrs, :required,  :location]
  # elixir uses defrecord to interface with erlang but uses nil instead of the
  # erlang default: undefined...?!
  defrecord :soap_fault,    :"soap:Fault",    [attrs: :undefined, faultcode: :undefined, faultstring: :undefined, faultactor: :undefined, detail: :undefined]
  defrecord :soap_body,     :"soap:Body",     [attrs: :undefined, choice: :undefined]
  defrecord :soap_header,   :"soap:Header",   [attrs: :undefined, choice: :undefined]
  defrecord :soap_envelope, :"soap:Envelope", [attrs: :undefined, header: :undefined, body: :undefined, choice: :undefined]

  defmodule Model do
    defstruct [:operations, :model]
    @type t :: %__MODULE__{operations: map, model: term}
  end

  # TODO: take namespaces as binary
  @spec init_model(String.t, namespaces :: list) :: Model.t
  def init_model(wsdl_file, namespaces \\ []) do
    wsdl = Path.join([@priv_dir, "wsdl.xsd"])
    {:ok, wsdl_model} = :erlsom.compile_xsd_file(
      Path.join([@priv_dir, "soap.xsd"]),
      prefix: 'soap',
      include_files: [{'http://schemas.xmlsoap.org/wsdl/', 'wsdl', wsdl}]
    )
    # add the xsd model
    wsdl_model = :erlsom.add_xsd_model(wsdl_model)

    include_dir = Path.dirname(wsdl_file)
    options = [dir_list: include_dir]

    # parse wsdl
    {model, wsdls} = parse_wsdls([wsdl_file], namespaces, wsdl_model, options, {nil, []})

    # TODO: add files as required
    # now compile envelope.xsd, and add Model
    {:ok, envelope_model} = :erlsom.compile_xsd_file(Path.join([@priv_dir, "envelope.xsd"]), prefix: 'soap')
    soap_model = :erlsom.add_model(envelope_model, model)
    # TODO: detergent enables you to pass some sort of AddFiles that will stitch together the soap model
    # SoapModel2 = addModels(AddFiles, SoapModel),

    # process
    ports = get_ports(wsdls)
    operations = get_operations(wsdls, ports, model)
    #Map.merge(acc_operations, operations, fn _,_,_ -> raise "Unexpected duplicate" end)

    %Model{operations: operations, model: soap_model}
  end

  def parse_wsdls([], _namespaces, _wsdl_model, _opts, acc), do: acc

  def parse_wsdls([path | rest], namespaces, wsdl_model, opts, {acc_model, acc_wsdl}) do
    {:ok, wsdl_file} = get_file(String.trim(path))
    {:ok, parsed, _} = :erlsom.scan(wsdl_file, wsdl_model)
    # get xsd elements from wsdl to compile
    xsds = extract_wsdl_xsds(parsed)
    # Now we need to build a list: [{Namespace, Prefix, Xsd}, ...] for all the Xsds in the WSDL.
    # This list is used when a schema includes one of the other schemas. The AXIS java2wsdl
    # generates wsdls that depend on this feature.
    import_list = Enum.map(xsds, fn xsd ->
      uri = :erlsom_lib.getTargetNamespaceFromXsd(xsd)
      prefix = :proplists.get_value(uri, namespaces, :undefined)
      {uri, prefix, xsd}
    end)

    # TODO: pass the right options here
    model = add_schemas(xsds, opts, import_list, acc_model)

    acc = {model, [parsed | acc_wsdl]}

    imports = get_imports(parsed)
    # process imports (recursively, so that imports in the imported files are
    # processed as well).
    # For the moment, the namespace is ignored on operations etc.
    # this makes it a bit easier to deal with imported wsdl's.
    acc = parse_wsdls(imports, namespaces, wsdl_model, opts, acc)
    parse_wsdls(rest, namespaces, wsdl_model, opts, acc)
  end

  # compile each of the schemas, and add it to the model.
  # Returns Model
  def add_schemas(xsds, opts, imports, acc_model \\ nil) do
    Enum.reduce(xsds, acc_model, fn xsd, acc ->
      case xsd do
        nil -> acc
        _ ->
          tns = :erlsom_lib.getTargetNamespaceFromXsd(xsd)
          prefix = elem(List.keyfind(imports, tns, 0), 1)
          {:ok, model} = :erlsom_compile.compile_parsed_xsd(xsd, [{:prefix, prefix}, {:include_files, imports} | opts])

          case acc_model do
            nil -> model
            _ -> :erlsom.add_model(acc_model, model)
          end
      end
    end)
  end

  def get_file(uri) do
    case URI.parse(uri) do
      %{scheme: scheme} when scheme in ["http", "https"] ->
        raise "Not implemented"
        # get_remote_file()
      _ ->
        get_local_file(uri)
    end
  end

  def get_local_file(uri) do
    File.read(uri)
  end

  def extract_wsdl_xsds(wsdl_definitions(types: types)) when is_list(types) do
    types
    |> Enum.map(fn {:"wsdl:tTypes", _attrs, _docs, types} -> types end)
    |> List.flatten()
  end
  def extract_wsdl_xsds(wsdl_definitions()), do: []

  # TODO: soap1.2

  # %% returns [#port{}]
  # %% -record(port, {service, port, binding, address}).

  def get_ports(wsdls) do
    Enum.reduce(wsdls, [], fn
      (wsdl_definitions(services: services), acc) when is_list(services) ->
        Enum.reduce(services, acc, fn service, acc ->
          wsdl_service(name: service_name, ports: ports) = service
          Enum.reduce(ports, acc, fn
            wsdl_port(name: name, binding: binding, choice: choice), acc ->
              Enum.reduce(choice, acc, fn
                soap_address(location: location), acc ->
                  [%{service: service_name, port: name, binding: binding, address: location} | acc]
                _, acc -> acc # non-soap bindings are ignored
              end)
              _, acc -> acc
          end)
        end)
      _, acc -> acc
    end)
  end

  def get_node(wsdls, qname, type_pos, pos) do
    uri   = :erlsom_lib.getUriFromQname(qname)
    local = :erlsom_lib.localName(qname)
    ns = get_namespace(wsdls, uri)

    objs = elem(ns, type_pos)
    List.keyfind(objs, local, pos)
  end

  # get service -> port --> binding --> portType -> operation -> response-or-one-way -> param -|-|-> message
  #                     |-> bindingOperation --> message
  def get_operations(wsdls, ports, model) do
    Enum.map(ports, fn %{binding: binding} = port ->
      bind = get_node(wsdls, binding, wsdl_definitions(:bindings), wsdl_binding(:name))
      wsdl_binding(ops: ops, type: pt) = bind

      Enum.reduce(ops, %{}, fn (wsdl_binding_operation(name: name, choice: choice), acc) ->
        case choice do
          [soap_operation(action: action)] ->
            # lookup Binding in PortType, and create a combined result
            port_type = get_node(wsdls, pt, wsdl_definitions(:port_types), wsdl_port_type(:name))
            operations = wsdl_port_type(port_type, :operations)

            operation = List.keyfind(operations, name, wsdl_operation(:name))
            params = wsdl_operation(operation, :choice)
            wsdl_request_response(input: input, output: output, fault: fault) = params

            Map.put_new(acc, to_string(name), %{
              service: port.service,
              port: port.port,
              binding: binding,
              address: port.address,
              action: action,
              input: extract_type(wsdls, model, input),
              output: extract_type(wsdls, model, output),
              #fault: extract_type(wsdls, model, fault) TODO
            })
          _ ->  acc
        end
      end)
    end)
  end

  def get_namespace(wsdls, uri) when is_list(wsdls) do
    List.keyfind(wsdls, uri, wsdl_definitions(:namespace))
  end

  def get_imports(wsdl_definitions(imports: :undefined)), do: []
  def get_imports(wsdl_definitions(imports: imports)) do
    Enum.map(imports, fn wsdl_import(location: location) -> to_string(location) end)
  end

  defp extract_type(wsdls, model, wsdl_param(message: message)) do
    parts =
      wsdls
      |> get_node(message, wsdl_definitions(:messages), wsdl_message(:name))
      |> wsdl_message(:part)
    extract_type(wsdls, model, parts)
  end
  defp extract_type(wsdls, model, [wsdl_part(element: :undefined, type: type, name: name)]) do
    raise "Unhandled"
  end
  defp extract_type(wsdls, model, [wsdl_part(element: el, name: name)]) do
    local = :erlsom_lib.localName(el)
    uri = :erlsom_lib.getUriFromQname(el)
    prefix = :erlsom_lib.getPrefixFromModel(model, uri)
    case prefix do
      :undefined -> local
      nil -> local
      "" -> local
      _ -> prefix <> ":" <> local
    end
    |> List.to_atom()
  end
  defp extract_type(_, _, nil), do: nil
  defp extract_type(_, _, :undefined), do: nil

  # --- Introspection --------

  defrecord :model, :model, [:types, :namespaces, :target_namespace, :type_hierarchy, :any_attribs, :value_fun]
  defrecord :type, [:name, :tp, :els, :attrs, :anyAttr, :nillable, :nr, :nm, :mx, :mxd, :typeName]
  defrecord :el,   [:alts, :mn, :mx, :nillable, :nr]
  defrecord :alt,  [:tag, :type, :nxt, :mn, :mx, :rl, :anyInfo]
  defrecord :attr, :att, [:name, :nr, :opt, :tp]

  @spec convert(Model.t, operation :: atom, params :: map) :: {:ok, binary} | {:error, term}
  def convert(%Model{model: model(types: types)} = model, operation, params) do
    get_in(model.operations, [to_string(operation), :input])
    |> cast_type(params, types)
    |> List.wrap()
    |> wrap_envelope()
    |> :erlsom.write(model.model, output: :binary)
  end

  @spec wrap_envelope(messages :: list, headers :: list) :: term
  def wrap_envelope(messages, headers \\ [])

  def wrap_envelope(messages, []) when is_list(messages) do
    soap_envelope(body: soap_body(choice: messages))
  end

  def wrap_envelope(messages, headers) when is_list(messages) and is_list(headers) do
    soap_envelope(body: soap_body(choice: messages), header: soap_header(choice: headers))
  end

  @spec cast_type(name :: atom, input :: map, types :: term) :: tuple
  def cast_type(name, input, types) do
    spec = List.keyfind(types, name, type(:name))
    IO.inspect spec

    # TODO: check type(spec, :tp) and handle other things than :sequence
    vals =
      spec
      |> type(:els)
      |> Enum.map(&convert_el(&1, input, types))
    List.to_tuple([name, [] | vals])
  end

  # TODO: will need to pass through parent type possibly
  def convert_el(el(alts: [alt(tag: tag, type: t, mn: 1, mx: 1)], mn: min, mx: max, nillable: nillable, nr: _nr), map, types) do
    case Map.get(map, tag) do
      nil ->
        cond do
          min == 0          -> :undefined
          nillable == true  -> nil
          true              -> raise "Non-nillable type #{tag} found nil"
        end
      val ->
        case t do
          # val # erlsom will happily accept binaries
          {:"#PCDATA", _} ->
            val
          t when is_atom(t) ->
            cast_type(t, val, types)
        end
    end
  end

  # ---

  @spec call(wsdl :: Model.t, operation :: atom, params :: map) :: {:ok, term} | {:error, term}
  def call(model, operation, params \\ %{}) do
    op = model.operations[to_string(operation)]
    params = convert(model, operation, params)

    # http call
  end
end
