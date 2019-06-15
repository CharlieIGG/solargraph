module Solargraph
  # A static analysis tool for validating data types.
  #
  class TypeChecker
    # A problem reported by TypeChecker.
    #
    class Problem
      # @return [Solargraph::Location]
      attr_reader :location

      # @return [String]
      attr_reader :message

      # @return [String, nil]
      attr_reader :suggestion

      # @param location [Solargraph::Location]
      # @param message [String]
      # @param suggestion [String, nil]
      def initialize location, message, suggestion = nil
        @location = location
        @message = message
        @suggestion = suggestion
      end
    end

    # @return [String]
    attr_reader :filename

    # @param filename [String]
    # @param api_map [ApiMap]
    def initialize filename, api_map: nil
      @filename = filename
      # @todo Smarter directory resolution
      @api_map = api_map || Solargraph::ApiMap.load(File.dirname(filename))
    end

    # @return [Array<Problem>]
    def return_type_problems
      result = []
      smap = api_map.source_map(filename)
      pins = smap.pins.select { |pin| pin.is_a?(Solargraph::Pin::BaseMethod) }
      pins.each { |pin| result.concat check_return_type(pin) }
      result
    end

    # @return [Array<Problem>]
    def param_type_problems
      result = []
      smap = api_map.source_map(filename)
      smap.locals.select { |pin| pin.is_a?(Solargraph::Pin::Parameter) }.each do |par|
        next unless par.closure.is_a?(Solargraph::Pin::Method)
        result.concat check_param_tags(par.closure)
        type = par.typify(api_map)
        if type.undefined?
          if par.return_type.undefined?
            result.push Problem.new(
              par.location, "#{par.closure.name} has undefined @param type for #{par.name}")
          else
            result.push Problem.new(par.location, "#{par.closure.name} has unresolved @param type for #{par.name}")
          end
        end
      end
      result
    end

    # @return [Array<Problem>]
    def strict_type_problems
      result = []
      smap = api_map.source_map(filename)
      smap.pins.select { |pin| pin.is_a?(Pin::BaseMethod) }.each do |pin|
        result.concat confirm_return_type(pin)
      end
      result.concat check_send_args smap.source.node
      result
    end

    private

    # @return [ApiMap]
    attr_reader :api_map

    # @param pin [Pin::BaseMethod]
    # @return [Array<Problem>]
    def check_param_tags pin
      result = []
      pin.docstring.tags(:param).each do |par|
        next if pin.parameter_names.include?(par.name)
        result.push Problem.new(pin.location, "#{pin.name} has unknown @param #{par.name}")
      end
      result
    end

    # @param pin [Pin::BaseMethod]
    # @return [Array<Problem>]
    def check_return_type pin
      tagged = pin.typify(api_map)
      if tagged.undefined?
        if pin.return_type.undefined?
          probed = pin.probe(api_map)
          return [Problem.new(pin.location, "#{pin.name} has undefined @return type", probed.to_s)]
        else
          return [Problem.new(pin.location, "#{pin.name} has unresolved @return type #{pin.return_type}")]
        end
      end
      []
    end

    # @param pin [Solargraph::Pin::Base]
    # @return [Array<Problem>]
    def confirm_return_type pin
      tagged = pin.typify(api_map)
      return [] if tagged.void? || tagged.undefined? || pin.is_a?(Pin::Attribute)
      probed = pin.probe(api_map)
      return [] if probed.undefined?
      if tagged.to_s != probed.to_s
        if probed.name == 'Array' && probed.subtypes.empty?
          return [] if tagged.name == 'Array'
        end
        if probed.name == 'Hash' && probed.value_types.empty?
          return [] if tagged.name == 'Hash'
        end
        all = true
        probed.each do |pt|
          tagged.each do |tt|
            if pt.name == tt.name && !api_map.super_and_sub?(tt.namespace, pt.namespace) && !tagged.map(&:namespace).include?(pt.namespace)
              all = false
              break
            elsif pt.name == tt.name && ['Array', 'Class', 'Module'].include?(pt.name)
              if !(tt.subtypes.any? { |ttx| pt.subtypes.any? { |ptx| api_map.super_and_sub?(ttx.to_s, ptx.to_s) } })
                all = false
                break
              end
            elsif pt.name == tt.name && pt.name == 'Hash'
              if !(tt.key_types.empty? && !pt.key_types.empty?) && !(tt.key_types.any? { |ttx| pt.key_types.any? { |ptx| api_map.super_and_sub?(ttx.to_s, ptx.to_s) } })
                if !(tt.value_types.empty? && !pt.value_types.empty?) && !(tt.value_types.any? { |ttx| pt.value_types.any? { |ptx| api_map.super_and_sub?(ttx.to_s, ptx.to_s) } })
                  all = false
                  break
                end
              end
            elsif pt.name != tt.name && !api_map.super_and_sub?(tt.to_s, pt.to_s) && !tagged.map(&:to_s).include?(pt.to_s)
              all = false
              break
            end
          end
        end
        return [] if all
        return [Problem.new(pin.location, "@return type `#{tagged.to_s}` does not match inferred type `#{probed.to_s}`", probed.to_s)]
      end
      []
    end

    def check_send_args node
      result = []
      if node.type == :send
        smap = api_map.source_map(filename)
        locals = smap.locals_at(Solargraph::Location.new(filename, Solargraph::Range.from_node(node)))
        block = smap.locate_block_pin(node.loc.line, node.loc.column)
        chain = Solargraph::Source::NodeChainer.chain(node, filename)
        pins = chain.define(api_map, block, locals)
        if pins.empty?
          result.push Problem.new(Solargraph::Location.new(filename, Solargraph::Range.from_node(node)), "Unresolved method signature #{chain.links.map(&:word).join('.')}")
        else
          pin = pins.first
          ptypes = arg_types(pin)
          params = param_tags_from(pin)
          cursor = 0
          curtype = nil
          node.children[2..-1].each_with_index do |arg, index|
            curtype = ptypes[cursor] if curtype.nil? || curtype == :arg
            break if curtype == :restarg || curtype == :kwrestarg
            if curtype.nil?
              result.push Problem.new(Solargraph::Location.new(filename, Solargraph::Range.from_node(node)), "Not enough arguments send to #{pin.path}")
              break
            else
              if arg.is_a?(Parser::AST::Node) && arg.type == :hash
                # result.push Problem.new(Solargraph::Location.new(filename, Solargraph::Range.from_node(node)), "Can't handle hash in #{pin.parameter_names[index]} #{pin.path}")
                # break if curtype != :arg && ptypes.include?(:kwrestarg)
                arg.children.each do |pair|
                  sym = pair.children[0].children[0].to_s
                  partype = params[pin.parameter_names[index]]
                  if partype.nil?
                    if report_location?(pin.location)
                      unless ptypes.include?(:kwrestarg)
                        result.push Problem.new(Solargraph::Location.new(filename, Solargraph::Range.from_node(node)), "No @param type for #{pin.parameter_names[index]} in #{pin.path}")
                      end
                    end
                  else
                    chain = Solargraph::Source::NodeChainer.chain(pair.children[1], filename)
                    argtype = chain.infer(api_map, block, locals)
                    if argtype.tag != partype.tag
                      result.push Problem.new(Solargraph::Location.new(filename, Solargraph::Range.from_node(node)), "Wrong parameter type for #{pin.path}: #{pin.parameter_names[index]} expected #{partype.tag}, received #{argtype.tag}")
                    end
                  end
                end
              elsif arg.is_a?(Parser::AST::Node) && arg.type == :splat
                result.push Problem.new(Solargraph::Location.new(filename, Solargraph::Range.from_node(node)), "Can't handle splat in #{pin.parameter_names[index]} #{pin.path}")
                break if curtype != :arg && ptypes.include?(:restarg)
              else
                partype = params[pin.parameter_names[index]]
                if partype.nil?
                  if report_location?(pin.location)
                    result.push Problem.new(Solargraph::Location.new(filename, Solargraph::Range.from_node(node)), "No @param type for #{pin.parameter_names[index]} in #{pin.path}")
                  end
                else
                  chain = Solargraph::Source::NodeChainer.chain(arg, filename)
                  argtype = chain.infer(api_map, block, locals)
                  if argtype.tag != partype.tag
                    result.push Problem.new(Solargraph::Location.new(filename, Solargraph::Range.from_node(node)), "Wrong parameter type for #{pin.path}: #{pin.parameter_names[index]} expected #{partype.tag}, received #{argtype.tag}")
                  end
                end
              end
            end
            cursor += 1 if curtype == :arg
          end
        end
      end
      node.children.each do |child|
        next unless child.is_a?(Parser::AST::Node)
        result.concat check_send_args(child)
      end
      result
    end

    def check_arity pins, args
      args ||= []
      pins.each do |pin|
        return pin if pin.parameters.empty? && args.empty?
        return pin if pin.parameters.length == args.length
        return pin if pin.parameters.any? { |par| par.start_with?('*') }
      end
      return nil
    end

    def param_tags_from pin
      # @todo Look for see references
      #   and dig through all the pins
      return {} if pin.nil?
      tags = pin.docstring.tags(:param)
      result = {}
      tags.each do |tag|
        result[tag.name] = ComplexType::UNDEFINED
        result[tag.name] = ComplexType.try_parse(*tag.types).qualify(api_map, pin.context.namespace)
      end
      result
    end

    # @param pin [Pin::BaseMethod]
    # @return [Hash]
    def arg_types pin
      return [] if pin.nil?
      result = []
      pin.parameters.each_with_index do |full, index|
        result.push arg_type(full)
      end
      result
    end

    # @param string [String]
    # @return [Symbol]
    def arg_type string
      return :kwrestarg if string.start_with?('**')
      return :restarg if string.start_with?('*')
      return :optarg if string.include?('=')
      return :kwoptarg if string.end_with?(':')
      return :kwarg if string =~ /^[a-z0-9_]*?:/
      :arg
    end

    def report_location? location
      return false if location.nil?
      filename == location.filename || api_map.bundled?(location.filename)
    end

    class << self
      # @param filename [String]
      # @return [self]
      def load filename
        source = Solargraph::Source.load(filename)
        api_map = Solargraph::ApiMap.new
        api_map.map(source)
        new(filename, api_map: api_map)
      end

      # @param code [String]
      # @param filename [String, nil]
      # @return [self]
      def load_string code, filename = nil
        source = Solargraph::Source.load_string(code, filename)
        api_map = Solargraph::ApiMap.new
        api_map.map(source)
        new(filename, api_map: api_map)
      end
    end
  end
end