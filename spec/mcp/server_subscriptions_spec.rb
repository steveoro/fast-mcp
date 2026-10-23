# frozen_string_literal: true

# §1.3: per-session resource subscriptions with cleanup.
# Subscriptions are keyed by session_key, not request id.

RSpec.describe FastMcp::Server, 'per-session resource subscriptions (§1.3)' do
  let(:logger) { Logger.new(nil) }
  let(:server) { described_class.new(name: 't', version: '0', logger: logger) }

  let(:resource_class) do
    Class.new(FastMcp::Resource) do
      resource_name 'my-resource'
      uri 'res://my'
      mime_type 'text/plain'
      def content = 'hello'
    end
  end

  let(:transport) do
    dbl = instance_double('Transport')
    allow(dbl).to receive(:send_message)
    allow(dbl).to receive(:send_message_to)
    allow(dbl).to receive(:respond_to?).with(:send_message_to).and_return(true)
    dbl
  end

  before do
    server.register_resource(resource_class)
    server.transport = transport
    server.instance_variable_set(:@client_initialized, true)
  end

  describe '#remove_subscriber' do
    # Use fetch(key, nil) / key? rather than [] to avoid the default-proc creating new empty Sets.
    def subscriptions_for(uri)
      server.instance_variable_get(:@resource_subscriptions).fetch(uri, nil)
    end

    it 'removes all URIs for a session and returns the count of URIs touched' do
      subs = server.instance_variable_get(:@resource_subscriptions)
      subs['res://my'].add('session-A')
      subs['res://other'].add('session-A')
      subs['res://other'].add('session-B')

      touched = server.remove_subscriber('session-A')
      expect(touched).to eq(2)
      expect(subscriptions_for('res://my')).to be_nil
      expect(subscriptions_for('res://other')).to eq(Set.new(['session-B']))
    end

    it 'returns 0 and does not mutate state for an unknown session' do
      server.instance_variable_get(:@resource_subscriptions)['res://my'].add('session-X')
      expect(server.remove_subscriber('nobody')).to eq(0)
      expect(subscriptions_for('res://my')).to eq(Set.new(['session-X']))
    end

    it 'is safe to call concurrently from multiple threads' do
      subscriptions = server.instance_variable_get(:@resource_subscriptions)
      (1..20).each { |i| subscriptions["res://r#{i}"].add('session-Z') }

      threads = 4.times.map do
        Thread.new { server.remove_subscriber('session-Z') }
      end
      threads.each(&:join)

      # After all threads finish, no subscription for session-Z should remain
      subscriptions.each_value do |set|
        expect(set).not_to include('session-Z')
      end
    end
  end

  describe 'notify_resource_updated targets subscribed sessions only' do
    it 'calls send_message_to for each subscribed session' do
      server.instance_variable_get(:@resource_subscriptions)['res://my'].add('sess-1')
      server.instance_variable_get(:@resource_subscriptions)['res://my'].add('sess-2')

      server.notify_resource_updated('res://my')

      expect(transport).to have_received(:send_message_to).with('sess-1', anything)
      expect(transport).to have_received(:send_message_to).with('sess-2', anything)
      expect(transport).not_to have_received(:send_message)
    end

    it 'sends no notification when there are no subscribers' do
      server.notify_resource_updated('res://my')
      expect(transport).not_to have_received(:send_message_to)
      expect(transport).not_to have_received(:send_message)
    end

    it 'falls back to broadcast send_message when the transport lacks send_message_to' do
      simple_transport = instance_double('SimpleTransport', send_message: nil)
      allow(simple_transport).to receive(:respond_to?).with(:send_message_to).and_return(false)
      server.transport = simple_transport
      server.instance_variable_get(:@resource_subscriptions)['res://my'].add(:stdio)

      server.notify_resource_updated('res://my')
      expect(simple_transport).to have_received(:send_message)
    end
  end

  describe 'subscribe/unsubscribe via handle_request' do
    let(:session_id) { 'sess-42' }

    def with_session(&block)
      server.with_request_context(transport: transport, session_id: session_id, &block)
    end

    it 'subscribe adds the session key' do
      with_session do
        server.handle_request(
          JSON.generate(jsonrpc: '2.0', id: 1, method: 'resources/subscribe', params: { uri: 'res://my' })
        )
      end
      expect(server.instance_variable_get(:@resource_subscriptions)['res://my']).to include(session_id)
    end

    it 'unsubscribe removes the session key' do
      server.instance_variable_get(:@resource_subscriptions)['res://my'].add(session_id)

      with_session do
        server.handle_request(
          JSON.generate(jsonrpc: '2.0', id: 2, method: 'resources/unsubscribe', params: { uri: 'res://my' })
        )
      end
      # After removal the URI is deleted; fetch with a nil default avoids re-creating an empty Set.
      expect(server.instance_variable_get(:@resource_subscriptions).fetch('res://my', nil)).to be_nil
    end

    it 'unsubscribe of one session leaves other sessions intact' do
      subscriptions = server.instance_variable_get(:@resource_subscriptions)
      subscriptions['res://my'].add(session_id)
      subscriptions['res://my'].add('other-session')

      with_session do
        server.handle_request(
          JSON.generate(jsonrpc: '2.0', id: 3, method: 'resources/unsubscribe', params: { uri: 'res://my' })
        )
      end
      remaining = subscriptions.fetch('res://my', nil)
      expect(remaining).to include('other-session')
      expect(remaining).not_to include(session_id)
    end
  end

  it 'does not create subscription entries for URIs notified without subscribers' do
    server.notify_resource_updated('res://never-subscribed')

    expect(server.instance_variable_get(:@resource_subscriptions)).not_to have_key('res://never-subscribed')
  end
end
