# Prompts

Prompts publish reusable, argument-aware message templates through MCP
`prompts/list` and `prompts/get`.

```ruby
class RecallPrompt < FastMcp::Prompt
  prompt_name 'recall'
  description 'Recall project knowledge'
  argument :topic, description: 'Subject to recall', required: true

  def messages(topic:)
    [
      {
        role: 'user',
        content: { type: 'text', text: "Recall #{topic}" }
      }
    ]
  end
end

server.register_prompt(RecallPrompt)
# or
FastMcp.register_prompts(RecallPrompt)
```

`prompts/list` returns each prompt's name, description, and argument metadata.
`prompts/get` validates required arguments and returns the rendered messages.
Subclasses must implement `#messages`.

Prompt list-change notifications are not currently emitted, so the server
advertises `prompts.listChanged: false`. Tool and resource filters do not apply
to prompts; register only prompts appropriate for every client, or enforce
prompt-specific policy in the prompt implementation.
