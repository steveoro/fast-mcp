# frozen_string_literal: true

# §1.14.4 (MCP Ruby SDK 1.8.1 #623/#625): stdio frames are stripped as bytes; bad frames get
# -32700, other failures -32603 without exception text, and an unencodable reply no longer
# escapes the read loop.

RSpec.describe FastMcp::Transports::StdioTransport, 'frames (§1.14.4)' do
  let(:logger) { Logger.new(nil) }
  let(:expose_internal_errors) { false }
  let(:server) do
    FastMcp::Server.new(name: 't', version: '0', logger: logger, expose_internal_errors: expose_internal_errors)
                   .tap { |mcp_server| mcp_server.register_tools(bad_bytes_tool) }
  end
  let(:bad_bytes_tool) do
    Class.new(FastMcp::Tool) do
      tool_name 'bad_bytes'
      description 'Returns invalid UTF-8'
      def call = "\xFF".dup.force_encoding(Encoding::UTF_8)
    end
  end

  def run_stdio(*lines)
    input = StringIO.new(lines.map { |line| "#{line}\n" }.join.b)
    output = StringIO.new
    transport = described_class.new(server, logger: logger, input: input, output: output)
    server.transport = transport
    transport.start
    output.string.split("\n").map { |line| JSON.parse(line, symbolize_names: true) }
  end

  def call_tool(id, name)
    JSON.generate(jsonrpc: '2.0', id: id, method: 'tools/call', params: { name: name, arguments: {} })
  end

  let(:ping) { '{"jsonrpc":"2.0","id":99,"method":"ping"}' }

  { 'C' => Encoding::US_ASCII, 'C.UTF-8' => Encoding::UTF_8 }.each do |lang, external|
    context "with LANG=#{lang}" do
      around do |example|
        previous = Encoding.default_external
        Encoding.default_external = external
        example.run
      ensure
        Encoding.default_external = previous
      end

      it 'answers a frame that is not valid UTF-8 with -32700 and keeps reading' do
        replies = run_stdio("\xFF{}".b, ping)

        expect(replies.first[:error][:code]).to eq(-32_700)
        expect(replies.first).not_to have_key(:id)
        expect(replies.last).to include(id: 99, result: {})
      end

      it 'answers an unencodable tool result with -32603 and serves the next request' do
        replies = run_stdio(call_tool(5, 'bad_bytes'), ping)

        expect(replies.first).to include(id: 5, error: { code: -32_603, message: 'Internal error' })
        expect(replies.last).to include(id: 99, result: {})
      end
    end
  end

  it 'strips surrounding whitespace as bytes' do
    expect(run_stdio("  #{ping}  \r").first).to include(id: 99, result: {})
  end

  it 'hides exception text from a failure outside the server' do
    allow(server).to receive(:handle_request).and_raise(RuntimeError, 'secret internal detail')

    reply = run_stdio(ping).first

    expect(reply[:error]).to eq(code: -32_603, message: 'Internal error')
    expect(JSON.generate(reply)).not_to include('secret')
  end

  context 'with expose_internal_errors' do
    let(:expose_internal_errors) { true }

    it 'includes the exception text' do
      allow(server).to receive(:handle_request).and_raise(RuntimeError, 'visible detail')

      expect(run_stdio(ping).first[:error][:message]).to eq('Internal error: visible detail')
    end
  end
end
