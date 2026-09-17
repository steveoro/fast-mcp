# frozen_string_literal: true

module FastMcp
  # Base class for MCP prompts exposed through prompts/list and prompts/get.
  #
  # Subclasses declare metadata with `.prompt_name`, `.description`, and
  # `.argument`, then implement `#messages`.
  class Prompt
    class << self
      attr_accessor :server

      # Sets or returns the protocol prompt name.
      #
      # @param value [String, Symbol, nil]
      # @return [String, nil]
      def prompt_name(value = nil)
        @prompt_name = value.to_s if value
        @prompt_name || default_prompt_name
      end

      # Sets or returns the prompt description.
      #
      # @param value [String, nil]
      # @return [String, nil]
      def description(value = nil)
        @description = value if value
        @description
      end

      # Declares one prompt argument.
      #
      # @param name [String, Symbol]
      # @param description [String, nil]
      # @param required [Boolean]
      # @return [Hash] the normalized argument definition
      def argument(name, description: nil, required: false)
        @arguments ||= []
        definition = { name: name.to_s, required: required == true }
        definition[:description] = description if description
        @arguments << definition.freeze
        definition
      end

      # Returns inherited and locally declared prompt arguments.
      #
      # @return [Array<Hash>]
      def arguments
        inherited = superclass.respond_to?(:arguments) ? superclass.arguments : []
        (inherited + (@arguments || [])).uniq { |argument| argument[:name] }
      end

      # Returns the MCP prompts/list representation.
      #
      # @return [Hash]
      def metadata
        result = { name: prompt_name, description: description.to_s }
        result[:arguments] = arguments if arguments.any?
        result
      end

      private

      def default_prompt_name
        return if name.nil?

        name.split('::').last.sub(/Prompt\z/, '').gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
      end
    end

    # Renders MCP prompt messages.
    #
    # @param _arguments [Hash] validated argument values
    # @return [Array<Hash>] MCP role/content message objects
    def messages(**_arguments)
      raise NotImplementedError, "#{self.class.name} must implement #messages"
    end
  end
end
