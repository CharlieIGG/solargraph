module Solargraph
  module Pin
    # Use this class to track method aliases for later remapping. Common
    # examples that defer mapping are aliases for superclass methods or
    # methods from included modules.
    #
    class MethodAlias < BaseMethod
      attr_reader :scope

      attr_reader :original

      def initialize scope: :instance, original: nil, **splat
        super(splat)
        @scope = scope
        @original = original
      end

      def kind
        Pin::METHOD_ALIAS
      end

      def visibility
        :public
      end

      def path
        @path ||= namespace + (scope == :instance ? '#' : '.') + name
      end
    end
  end
end
